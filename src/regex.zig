const std = @import("std");
const RegexError = @import("errors.zig").RegexError;
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const vm = @import("vm.zig");
const ast = @import("ast.zig");
const common = @import("common.zig");
const optimizer = @import("optimizer.zig");
const backtrack = @import("backtrack.zig");
const dfa = @import("dfa.zig");
const onepass = @import("onepass.zig");
const unicode_mod = @import("unicode.zig");

const MAX_NFA_REPEAT_EXPANSION: usize = 10_000;

/// Represents a match result from a regex operation
pub const Match = struct {
    /// The matched substring
    slice: []const u8,
    /// Start index in the input string
    start: usize,
    /// End index in the input string (exclusive)
    end: usize,
    /// Captured groups (if any)
    captures: []const []const u8 = &.{},
    /// Per-capture participation flag, parallel to `captures`: false for a group
    /// that did not match (an unmatched optional), so a caller can distinguish
    /// it from a group that matched the empty string. Empty when not provided.
    captures_present: []const bool = &.{},
    /// Per-capture `[start, end]` byte offsets into the input (parallel to
    /// `captures`), for the `d`/`hasIndices` flag's match-indices array. Only
    /// meaningful where `captures_present[i]` is true. Empty when not provided.
    capture_spans: []const [2]usize = &.{},

    pub fn init(slice: []const u8, start: usize, end: usize) Match {
        return .{
            .slice = slice,
            .start = start,
            .end = end,
        };
    }

    pub fn deinit(self: *Match, allocator: std.mem.Allocator) void {
        allocator.free(self.captures);
        if (self.captures_present.len != 0) allocator.free(self.captures_present);
        if (self.capture_spans.len != 0) allocator.free(self.capture_spans);
    }
};

/// Engine type used for regex matching
pub const EngineType = enum {
    thompson_nfa, // Fast O(n*m) but limited features
    backtracking, // Slower but supports all features
};

pub const NamedCapture = struct {
    name: []const u8,
    index: usize,
};

/// Main regex type - represents a compiled regular expression pattern
pub const Regex = struct {
    allocator: std.mem.Allocator,
    pattern: []const u8,
    nfa: compiler.NFA,
    backtrack_engine: ?backtrack.BacktrackEngine,
    ast_tree: ?ast.AST, // Kept for backtracking engine
    engine_type: EngineType,
    capture_count: usize,
    flags: common.CompileFlags,
    opt_info: optimizer.OptimizationInfo,
    named_captures: std.StringHashMap(usize), // name -> capture_index mapping
    named_capture_list: []NamedCapture,
    /// One-pass capture plan for eligible disjoint-boundary atom-sequence
    /// patterns; null when the pattern doesn't fit the shape.
    onepass: ?*onepass.Plan = null,

    /// A fixed literal wrapped only in zero-width assertions (`\bfn\b`, `^foo$`,
    /// `word\b`, …). The whole match is the literal, so it's found with a SIMD
    /// literal scan plus an inline boundary/anchor check — no per-position NFA.
    /// Null when the pattern isn't that shape.
    bounded_literal: ?BoundedLiteral = null,

    /// `\bfn\b`-style descriptor: a fixed `literal` that must be preceded by all
    /// `pre` assertions (checked at the literal's start) and followed by all
    /// `post` assertions (checked at its end). `literal` is owned by the regex.
    pub const BoundedLiteral = struct {
        literal: []const u8,
        pre: [4]ast.AnchorType = undefined,
        pre_len: u8 = 0,
        post: [4]ast.AnchorType = undefined,
        post_len: u8 = 0,
    };

    /// Compile a regex pattern with default flags
    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !Regex {
        return compileWithFlags(allocator, pattern, .{});
    }

    /// Compile a regex pattern with custom flags
    pub fn compileWithFlags(allocator: std.mem.Allocator, pattern: []const u8, flags: common.CompileFlags) !Regex {
        if (pattern.len == 0) {
            return RegexError.EmptyPattern;
        }

        // Parse the pattern into an AST
        var p = try parser.Parser.init(allocator, pattern);
        p.unicode_sets = flags.unicode_sets;
        p.unicode = flags.unicode;
        p.ecmascript = flags.ecmascript;
        // The `x`, `u`, and `v` flags affect lexing from the first token, so
        // enable them on the lexer and re-lex the already-fetched first token.
        if (flags.extended or flags.unicode or flags.unicode_sets) {
            p.extended = flags.extended;
            p.lexer.extended = flags.extended;
            p.lexer.unicode_strict = flags.unicode or flags.unicode_sets;
            p.lexer.reset();
            p.current_token = try p.lexer.next();
        }
        var tree = try p.parse();
        errdefer tree.deinit(); // Free AST if compilation fails

        // SECURITY: Analyze pattern for vulnerabilities (ReDoS, nested quantifiers, etc.)
        // Reject patterns that are too dangerous (critical risk only)
        // Medium and high risk patterns are allowed but will be protected by runtime step counter
        const pattern_analyzer = @import("pattern_analyzer.zig");
        try pattern_analyzer.analyzeAndValidate(allocator, tree.root, .high);

        // Store owned copy of pattern
        const owned_pattern = try allocator.dupe(u8, pattern);
        errdefer allocator.free(owned_pattern);

        // Analyze AST for optimizations
        var opt = optimizer.Optimizer.init(allocator);
        var opt_info = try opt.analyze(tree.root);
        errdefer opt_info.deinit(allocator);

        // Under `i`, the AST-derived byte prefilter is case-sensitive. Fold the
        // first-byte set so both cases are candidates (the byte engine is
        // case-folded), and drop the prefix / single-byte hints, which can't
        // represent both cases — the folded table-walk replaces them. This lets
        // the DFA prefilter skip non-candidate positions for `i` patterns too
        // (e.g. `(?i)pub\s+fn` was ~6x slower without it).
        if (flags.case_insensitive) {
            if (opt_info.first_bytes) |t| opt_info.first_bytes = foldTableCI(t);
            if (opt_info.literal_prefix) |lp| {
                allocator.free(lp);
                opt_info.literal_prefix = null;
            }
            opt_info.first_byte_single = null;
        }

        // Collect named captures from AST
        var named_captures = std.StringHashMap(usize).init(allocator);
        errdefer deinitNamedCaptureMap(allocator, &named_captures);
        var named_capture_list = std.ArrayList(NamedCapture).empty;
        errdefer deinitNamedCaptureList(allocator, &named_capture_list);
        try collectNamedCaptures(allocator, tree.root, &named_captures, &named_capture_list);

        // Detect if backtracking is required. One-pass keeps proven-unambiguous
        // capture patterns linear; when that plan cannot apply and adjacent
        // quantified capture boundaries overlap, ECMAScript capture precedence
        // needs the capture-aware backtracker.
        var onepass_plan: ?*onepass.Plan = null;
        var needs_backtracking = requiresBacktracking(tree.root, flags);
        if (!needs_backtracking and tree.capture_count > 0) {
            onepass_plan = try onepass.build(allocator, tree.root, tree.capture_count, flags);
            errdefer if (onepass_plan) |pl| pl.deinit();
            if (onepass_plan == null and hasAmbiguousCaptureBoundary(tree.root, flags))
                needs_backtracking = true;
        }

        if (needs_backtracking) {
            // Use backtracking engine
            var backtrack_engine = try backtrack.BacktrackEngine.init(allocator, tree.root, tree.capture_count, flags);
            errdefer backtrack_engine.deinit();

            // Create a dummy NFA (not used)
            var dummy_nfa = compiler.NFA.init(allocator);
            errdefer dummy_nfa.deinit();
            _ = try dummy_nfa.addState();

            return Regex{
                .allocator = allocator,
                .pattern = owned_pattern,
                .nfa = dummy_nfa,
                .backtrack_engine = backtrack_engine,
                .ast_tree = tree, // Keep AST for backtracking
                .engine_type = .backtracking,
                .capture_count = tree.capture_count,
                .flags = flags,
                .opt_info = opt_info,
                .named_captures = named_captures,
                .named_capture_list = try named_capture_list.toOwnedSlice(allocator),
            };
        } else {
            // Use Thompson NFA engine
            defer tree.deinit();

            // `\bfn\b`-style bounded literal (computed from the AST before it is
            // freed). Captures disable it (the fast path returns no groups).
            const bounded_literal = if (tree.capture_count == 0)
                try detectBoundedLiteral(allocator, tree.root, flags)
            else
                null;
            errdefer if (bounded_literal) |bl| allocator.free(bl.literal);

            var comp = compiler.Compiler.initWithFlags(allocator, flags);
            errdefer comp.deinit();
            _ = try comp.compile(&tree);

            return Regex{
                .allocator = allocator,
                .pattern = owned_pattern,
                .nfa = comp.nfa,
                .backtrack_engine = null,
                .ast_tree = null,
                .engine_type = .thompson_nfa,
                .capture_count = tree.capture_count,
                .flags = flags,
                .opt_info = opt_info,
                .named_captures = named_captures,
                .named_capture_list = try named_capture_list.toOwnedSlice(allocator),
                .onepass = onepass_plan,
                .bounded_literal = bounded_literal,
            };
        }
    }

    /// Free all resources associated with this regex
    pub fn deinit(self: *Regex) void {
        self.allocator.free(self.pattern);
        self.nfa.deinit();

        // Deinit backtracking engine if present
        if (self.backtrack_engine != null) {
            self.backtrack_engine.?.deinit();
        }

        // Deinit AST tree if present
        if (self.ast_tree != null) {
            self.ast_tree.?.deinit();
        }

        self.opt_info.deinit(self.allocator);
        if (self.onepass) |p| p.deinit();
        if (self.bounded_literal) |bl| self.allocator.free(bl.literal);

        deinitNamedCaptureMap(self.allocator, &self.named_captures);
        for (self.named_capture_list) |entry| self.allocator.free(entry.name);
        if (self.named_capture_list.len != 0) self.allocator.free(self.named_capture_list);
    }

    /// Get the capture group index for a named group
    /// Returns null if the name doesn't exist
    pub fn getCaptureIndex(self: *const Regex, name: []const u8) ?usize {
        return self.named_captures.get(name);
    }

    /// Get a named capture from a Match
    /// Returns null if the name doesn't exist or the capture wasn't matched
    pub fn getNamedCapture(self: *const Regex, match: *const Match, name: []const u8) ?[]const u8 {
        for (self.named_capture_list) |entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            if (entry.index == 0 or entry.index > match.captures.len) continue;
            if (entry.index - 1 < match.captures_present.len and !match.captures_present[entry.index - 1]) continue;
            return match.captures[entry.index - 1]; // Captures are 1-indexed in the API
        }
        return null;
    }

    const memmem_width = 16;
    const sample_budget = 16 * 1024; // small: keeps the one-time cost ~1% even on small inputs
    const sample_windows = 4;

    fn sampleLayout(input: []const u8) struct { win: usize, n: usize } {
        if (input.len <= sample_budget) return .{ .win = input.len, .n = 1 };
        return .{ .win = sample_budget / sample_windows, .n = sample_windows };
    }

    fn windowStart(input: []const u8, win: usize, n: usize, w: usize) usize {
        if (n <= 1) return 0;
        return (input.len - win) * w / (n - 1);
    }

    fn countByte(input: []const u8, b: u8) u32 {
        const L = sampleLayout(input);
        var c: u32 = 0;
        var w: usize = 0;
        while (w < L.n) : (w += 1) {
            const s = windowStart(input, L.win, L.n, w);
            c += @intCast(std.mem.count(u8, input[s .. s + L.win], &[_]u8{b}));
        }
        return c;
    }

    fn countPair(input: []const u8, b1: u8, b2: u8, o1: usize, o2: usize) u32 {
        const hi = @max(o1, o2);
        const L = sampleLayout(input);
        var c: u32 = 0;
        var w: usize = 0;
        while (w < L.n) : (w += 1) {
            const s = windowStart(input, L.win, L.n, w);
            if (s + L.win <= hi) continue;
            var p = s;
            const stop = s + L.win - hi;
            while (p < stop) : (p += 1) {
                if (input[p + o1] == b1 and input[p + o2] == b2) c += 1;
            }
        }
        return c;
    }

    /// Scalar two-byte-filtered substring search over starts in `[from, last]`.
    fn literalScalar(input: []const u8, lit: []const u8, from: usize, last: usize, o1: usize, o2: usize) ?usize {
        var p = from;
        while (p <= last) : (p += 1) {
            if (input[p + o1] == lit[o1] and input[p + o2] == lit[o2] and
                std.mem.eql(u8, input[p .. p + lit.len], lit)) return p;
        }
        return null;
    }

    /// Per-search literal prefilter, decided once from a small spread sample so
    /// it never regresses below a plain first-byte scan. Two strategies:
    ///   - **first-byte**: SIMD `indexOfScalar` on the rarer probe byte, then
    ///     verify — optimal when that byte is rare (e.g. `h` in `hello`);
    ///   - **memmem**: a vectorized two-byte filter (the generic-SIMD search
    ///     ripgrep/`memchr` use) testing two distinct probe bytes per 16-byte
    ///     block with a cheap `@reduce(.Or)` (no ARM-hostile per-lane movemask),
    ///     scalar-confirming only blocks that hit.
    /// memmem is chosen when the anchor byte occurs much more often than the
    /// two-byte pair (`anchor > 3·pair`): most anchor hits are then dead ends
    /// (`f` in `if`/`for` but `fn` is rare), so first-byte's many failed SIMD
    /// restarts cost more than memmem's filtered pass. When nearly every anchor
    /// hit is also a pair hit (every `h` precedes the `o` of `hello`), there are
    /// no wasted restarts and first-byte wins.
    const LiteralPrefilter = struct {
        lit: []const u8,
        o1: usize,
        o2: usize,
        use_memmem: bool,

        fn init(input: []const u8, lit: []const u8) LiteralPrefilter {
            if (lit.len < 2) return .{ .lit = lit, .o1 = 0, .o2 = 0, .use_memmem = false };
            const oa: usize = 0;
            var ob: usize = lit.len - 1;
            if (lit[ob] == lit[oa]) {
                var k: usize = 1;
                while (k < lit.len) : (k += 1) {
                    if (lit[k] != lit[oa]) {
                        ob = k;
                        break;
                    }
                }
            }
            const oa_count = countByte(input, lit[oa]);
            const ob_count = countByte(input, lit[ob]);
            const o1: usize = if (oa_count <= ob_count) oa else ob; // rarer = anchor
            const o2: usize = if (o1 == oa) ob else oa;
            const anchor_count = @min(oa_count, ob_count);
            const pair = countPair(input, lit[o1], lit[o2], o1, o2);
            return .{ .lit = lit, .o1 = o1, .o2 = o2, .use_memmem = anchor_count > pair *| 3 };
        }

        fn next(self: LiteralPrefilter, input: []const u8, from: usize) ?usize {
            const lit = self.lit;
            if (lit.len == 1) return std.mem.indexOfScalarPos(u8, input, from, lit[0]);
            if (from + lit.len > input.len) return null;
            const last = input.len - lit.len;

            if (!self.use_memmem) {
                var i = from + self.o1;
                while (std.mem.indexOfScalarPos(u8, input, i, lit[self.o1])) |q| {
                    const start = q - self.o1;
                    if (start > last) return null;
                    if (std.mem.eql(u8, input[start .. start + lit.len], lit)) return start;
                    i = q + 1;
                }
                return null;
            }

            const W = memmem_width;
            const v1: @Vector(W, u8) = @splat(lit[self.o1]);
            const v2: @Vector(W, u8) = @splat(lit[self.o2]);
            const hi = @max(self.o1, self.o2);
            var p = from;
            while (p + hi + W <= input.len) {
                const c1: @Vector(W, u8) = input[p + self.o1 ..][0..W].*;
                const c2: @Vector(W, u8) = input[p + self.o2 ..][0..W].*;
                const m: @Vector(W, bool) = (c1 == v1) & (c2 == v2);
                if (@reduce(.Or, m)) {
                    if (literalScalar(input, lit, p, @min(last, p + W - 1), self.o1, self.o2)) |r| return r;
                }
                p += W;
            }
            return literalScalar(input, lit, p, last, self.o1, self.o2);
        }
    };

    /// One-shot literal search (picks the strategy and searches once). Looping
    /// callers build a `LiteralPrefilter` once instead.
    fn literalSearch(input: []const u8, lit: []const u8, from: usize) ?usize {
        return LiteralPrefilter.init(input, lit).next(input, from);
    }

    /// Whether a `\b` word boundary holds at `pos` (same rule as `vm.isWordBoundary`).
    fn isWordBoundaryAt(input: []const u8, pos: usize) bool {
        const before = pos > 0 and common.CharClasses.word.matches(input[pos - 1]);
        const after = pos < input.len and common.CharClasses.word.matches(input[pos]);
        return before != after;
    }

    /// Whether a single zero-width assertion holds at `pos` — identical to the
    /// NFA's anchor evaluation (vm.zig), including multiline `^`/`$`.
    fn anchorHolds(self: *const Regex, a: ast.AnchorType, input: []const u8, pos: usize) bool {
        return switch (a) {
            .start_line => if (self.flags.multiline) (pos == 0 or input[pos - 1] == '\n') else pos == 0,
            .end_line => if (self.flags.multiline) (pos == input.len or input[pos] == '\n') else pos == input.len,
            .start_text => pos == 0,
            .end_text => pos == input.len,
            .word_boundary => isWordBoundaryAt(input, pos),
            .non_word_boundary => !isWordBoundaryAt(input, pos),
        };
    }

    fn anchorsHold(self: *const Regex, anchors: []const ast.AnchorType, input: []const u8, pos: usize) bool {
        for (anchors) |a| if (!self.anchorHolds(a, input, pos)) return false;
        return true;
    }

    /// Next `\bfn\b`-style match at or after `from`: a literal occurrence whose
    /// surrounding zero-width assertions all hold. Returns `{start, end}`.
    fn boundedLiteralNext(self: *const Regex, bl: BoundedLiteral, pf: LiteralPrefilter, input: []const u8, from: usize) ?[2]usize {
        var i = from;
        while (pf.next(input, i)) |p| {
            const e = p + bl.literal.len;
            if (self.anchorsHold(bl.pre[0..bl.pre_len], input, p) and
                self.anchorsHold(bl.post[0..bl.post_len], input, e))
                return .{ p, e };
            i = p + 1;
        }
        return null;
    }

    /// Stateful case-insensitive substring scanner. Keeps a SIMD cursor for each
    /// case of the first byte so it never rescans for an absent case (which would
    /// make repeated searches O(n²)). Yields non-overlapping match starts.
    /// Single-pass SIMD scan for the next byte equal to `lo` or `hi` at/after
    /// `from` (the two ASCII cases of a literal's first byte). One vector pass
    /// over the buffer instead of two separate memchr scans — the case-folded
    /// analogue of `memchr2`.
    fn indexOfCasePos(haystack: []const u8, from: usize, lo: u8, hi: u8) ?usize {
        if (lo == hi) return std.mem.indexOfScalarPos(u8, haystack, from, lo);
        var i = from;
        const V = @Vector(32, u8);
        const vlo: V = @splat(lo);
        const vhi: V = @splat(hi);
        while (i + 32 <= haystack.len) : (i += 32) {
            const chunk: V = haystack[i..][0..32].*;
            const m = (chunk == vlo) | (chunk == vhi);
            const bits: u32 = @bitCast(m);
            if (bits != 0) return i + @ctz(bits);
        }
        while (i < haystack.len) : (i += 1) {
            const c = haystack[i];
            if (c == lo or c == hi) return i;
        }
        return null;
    }

    const CiLiteralScanner = struct {
        input: []const u8,
        lit: []const u8,
        last: usize, // last viable start index
        lo0: u8,
        hi0: u8,
        loL: u8,
        hiL: u8,
        pos: usize,
        done: bool,

        fn init(input: []const u8, lit: []const u8, from: usize) CiLiteralScanner {
            if (lit.len == 0 or lit.len > input.len) {
                return .{ .input = input, .lit = lit, .last = 0, .lo0 = 0, .hi0 = 0, .loL = 0, .hiL = 0, .pos = 0, .done = true };
            }
            const last_byte = lit[lit.len - 1];
            return .{
                .input = input,
                .lit = lit,
                .last = input.len - lit.len,
                .lo0 = std.ascii.toLower(lit[0]),
                .hi0 = std.ascii.toUpper(lit[0]),
                .loL = std.ascii.toLower(last_byte),
                .hiL = std.ascii.toUpper(last_byte),
                .pos = from,
                .done = false,
            };
        }

        fn next(self: *CiLiteralScanner) ?usize {
            const len = self.lit.len;
            if (len == 1) {
                // Single byte: a plain case-folded memchr2.
                while (!self.done) {
                    const p = indexOfCasePos(self.input, self.pos, self.lo0, self.hi0) orelse {
                        self.done = true;
                        return null;
                    };
                    if (p > self.last) {
                        self.done = true;
                        return null;
                    }
                    self.pos = p + 1;
                    return p;
                }
                return null;
            }
            // Multi-byte: a single SIMD pass requires both the first and last
            // literal byte (case-folded) to line up `len-1` apart before any
            // verification — the case-insensitive analogue of ripgrep's
            // first/last-byte memmem, which collapses common-first-byte false
            // positives (e.g. the many `f`s when scanning for `fn`).
            const input = self.input;
            const V = @Vector(32, u8);
            const v_lo0: V = @splat(self.lo0);
            const v_hi0: V = @splat(self.hi0);
            const v_loL: V = @splat(self.loL);
            const v_hiL: V = @splat(self.hiL);
            const lastoff = len - 1;
            while (!self.done) {
                var i = self.pos;
                while (i + 32 + lastoff <= input.len) : (i += 32) {
                    const first: V = input[i..][0..32].*;
                    const lastv: V = input[i + lastoff ..][0..32].*;
                    const mf = (first == v_lo0) | (first == v_hi0);
                    const ml = (lastv == v_loL) | (lastv == v_hiL);
                    var bits: u32 = @bitCast(mf & ml);
                    while (bits != 0) {
                        const j = i + @ctz(bits);
                        if (j <= self.last and std.ascii.eqlIgnoreCase(input[j .. j + len], self.lit)) {
                            self.pos = j + len; // non-overlapping
                            return j;
                        }
                        bits &= bits - 1;
                    }
                }
                // Scalar tail.
                while (i <= self.last) : (i += 1) {
                    const c0 = input[i];
                    if ((c0 == self.lo0 or c0 == self.hi0) and
                        std.ascii.eqlIgnoreCase(input[i .. i + len], self.lit))
                    {
                        self.pos = i + len;
                        return i;
                    }
                }
                self.done = true;
                return null;
            }
            return null;
        }
    };

    /// Whether the lazy DFA can be used for capture-less search (count/isMatch):
    /// the fast byte-at-a-time engine for general patterns. Requires the Thompson
    /// engine, ASCII-exact matching, no position assertions, and all-greedy
    /// quantifiers (so longest-match equals the engine's semantics).
    fn dfaEligible(self: *const Regex) bool {
        // Case-insensitivity is handled by folding both ASCII cases into the
        // NFA's char transitions at compile time (compiler.caseFold*), so the
        // DFA — which matches case-sensitively — is correct for `i` too. (The
        // AST-derived byte prefilter is *not* folded, so it's disabled under `i`
        // by `dfaPrefilterActive`.)
        //
        // Empty-width assertions (`^` `$` `\A` `\z` `\b` `\B`, incl. multiline)
        // are now evaluated inside the lazy DFA, so anchored patterns are
        // eligible. Lazy quantifiers still keep NFA semantics (longest-match
        // would differ), and lookaround/backref/unicode-property patterns never
        // reach here (they compile to the backtracking engine).
        return self.engine_type == .thompson_nfa and
            !self.opt_info.has_lazy;
    }

    /// Whether the DFA loops have any candidate prefilter to apply. Under `i`,
    /// `compile` already folded `first_bytes` and cleared the case-sensitive
    /// `literal_prefix`/`first_byte_single`, so this stays correct for `i` too.
    fn dfaPrefilterActive(self: *const Regex) bool {
        return self.opt_info.literal_prefix != null or self.opt_info.first_bytes != null;
    }

    /// Skip to the next position >= `scan` that could start a match, or
    /// `input.len` if none. Prefers a multi-byte literal prefix (a `memmem`-style
    /// `indexOf`, far more selective than a single byte for patterns like
    /// `try\s+\w+` or `pub\s+fn`), then a single first byte (SIMD
    /// `indexOfScalar`), then a first-byte table walk. Callers invoke this only
    /// when `dfaPrefilterActive`.
    fn skipToCandidate(self: *const Regex, input: []const u8, scan: usize, pref: ?LiteralPrefilter) usize {
        if (pref) |pf| {
            // Vectorized literal-prefix scan (strategy chosen once per search).
            return pf.next(input, scan) orelse input.len;
        }
        if (self.opt_info.first_byte_single) |b| {
            return std.mem.indexOfScalarPos(u8, input, scan, b) orelse input.len;
        }
        const t = self.opt_info.first_bytes.?;
        var s = scan;
        while (s < input.len and !t[input[s]]) s += 1;
        return s;
    }

    /// Whether the byte-scanning `repeat_atom` fast paths may run for this
    /// pattern. They handle the unanchored case, leading `^` (anchored_start),
    /// and `^…$` (both), but NOT a trailing-`$`-only pattern — whose unanchored
    /// scan would report a match that ignores the `$`. Multiline patterns whose
    /// assertions span line boundaries are also excluded (the per-run scan can't
    /// evaluate `^`/`$` per line).
    fn repeatAtomFastPathOk(self: *const Regex) bool {
        if (self.flags.multiline and self.opt_info.has_assertions) return false;
        if (self.opt_info.anchored_end and !self.opt_info.anchored_start) return false;
        return true;
    }

    /// Smallest start position >= `pos` at which an `anchored_start` (leading `^`)
    /// pattern could begin: position 0, and — only under multiline — each index
    /// just past a '\n'. Returns null when no further line start exists. This lets
    /// the general scan loops skip directly between line starts instead of probing
    /// every byte (a match for `^…` can only begin at a line start).
    fn nextLineStart(self: *const Regex, input: []const u8, pos: usize) ?usize {
        if (pos == 0) return 0;
        if (!self.flags.multiline) return null; // only line start is 0
        const nl = std.mem.indexOfScalarPos(u8, input, pos - 1, '\n') orelse return null;
        const s = nl + 1;
        return if (s <= input.len) s else null;
    }

    /// Next start to try after a failed DFA match at `scan`, where `stop` is the
    /// position the DFA halted at. When the pattern begins with an unbounded
    /// greedy class, the DFA dies exactly at that class's run end, so we can jump
    /// straight to `stop` (no rescan) — no start within the run can match. Other
    /// patterns advance by one.
    ///
    /// This is unsound when the pattern carries assertions: a position-dependent
    /// constraint (e.g. a trailing `$`) can make a *later* start inside the run
    /// match where an earlier one failed — `\w+\s+\w+$` on "fn fn fn" matches at
    /// offset 3 though offset 0 fails. So the skip is restricted to assertion-free
    /// patterns.
    fn dfaFailSkip(self: *const Regex, scan: usize, stop: usize) usize {
        if (!self.opt_info.has_assertions and self.opt_info.first_unbounded_class != null) return @max(stop, scan + 1);
        return scan + 1;
    }

    /// The lazy DFA to use for this call: the reused one (from a `Matcher`) or a
    /// fresh temporary written into `tmp` (the caller deinits `tmp`). Returns
    /// null on OOM so the caller falls back to the NFA.
    fn obtainDfa(self: *const Regex, reuse: ?*dfa.LazyDfa, tmp: *?dfa.LazyDfa) ?*dfa.LazyDfa {
        if (reuse) |d| return d;
        tmp.* = dfa.LazyDfa.init(self.allocator, @constCast(&self.nfa), self.flags) catch return null;
        return &(tmp.*.?);
    }

    /// The unanchored search DFA for isMatch: the reused one (from a `Matcher`) or
    /// a fresh temporary written into `tmp` (the caller deinits `tmp`). Returns
    /// null on OOM so the caller falls back to the NFA.
    fn obtainSearchDfa(self: *const Regex, reuse: ?*dfa.LazyDfa, tmp: *?dfa.LazyDfa) ?*dfa.LazyDfa {
        if (reuse) |d| return d;
        tmp.* = dfa.LazyDfa.initSearch(self.allocator, @constCast(&self.nfa), self.flags) catch return null;
        return &(tmp.*.?);
    }

    /// The NFA VM to use for the per-position fallback: the reused one (from a
    /// `Matcher`) or a fresh temporary written into `tmp` (the caller deinits it).
    fn obtainVm(self: *const Regex, reuse: ?*vm.VM, tmp: *?vm.VM) *vm.VM {
        if (reuse) |v| return v;
        tmp.* = vm.VM.init(self.allocator, @constCast(&self.nfa), self.capture_count, self.flags);
        return &(tmp.*.?);
    }

    /// count() via the lazy DFA. Returns error.DfaOverflow if the DFA exceeds its
    /// state cap, so the caller can fall back to the NFA.
    fn countWithDfa(self: *const Regex, d: *dfa.LazyDfa, input: []const u8) dfa.Error!usize {
        const pf = self.dfaPrefilterActive();
        const pref: ?LiteralPrefilter = if (self.opt_info.literal_prefix) |p| LiteralPrefilter.init(input, p) else null;
        var n: usize = 0;
        var pos: usize = 0;
        while (pos <= input.len) {
            var scan = pos;
            var found_end: ?usize = null;
            while (scan <= input.len) {
                if (pf) {
                    scan = self.skipToCandidate(input, scan, pref);
                    if (scan >= input.len) break;
                }
                const sc = try d.longestMatchFrom(input, scan);
                if (sc.end) |end| {
                    found_end = end;
                    break;
                }
                scan = self.dfaFailSkip(scan, sc.stop);
            }
            const end = found_end orelse break;
            n += 1;
            pos = if (end > scan) end else end + 1;
        }
        return n;
    }

    /// find() via the lazy DFA. The DFA locates the match cheaply; for
    /// capture-free patterns its bounds are returned directly, otherwise the NFA
    /// runs once at the confirmed start to fill captures. Returns
    /// error.DfaOverflow to signal fallback.
    fn findWithDfa(self: *const Regex, d: *dfa.LazyDfa, input: []const u8) dfa.Error!?Match {
        var v: ?vm.VM = if (self.capture_count > 0)
            vm.VM.init(self.allocator, @constCast(&self.nfa), self.capture_count, self.flags)
        else
            null;
        defer if (v) |*vv| vv.deinit();

        const pf = self.dfaPrefilterActive();
        const pref: ?LiteralPrefilter = if (self.opt_info.literal_prefix) |p| LiteralPrefilter.init(input, p) else null;
        var scan: usize = 0;
        while (scan <= input.len) {
            if (pf) {
                scan = self.skipToCandidate(input, scan, pref);
                if (scan >= input.len) break;
            }
            const sc = try d.longestMatchFrom(input, scan);
            if (sc.end) |end| {
                if (v) |*vv| {
                    if (try vv.matchAt(input, scan)) |result| {
                        return try self.buildMatch(input, result);
                    }
                } else {
                    return Match{ .slice = input[scan..end], .start = scan, .end = end };
                }
            }
            // No match at scan (DFA and NFA agree); skip the leading run if any.
            scan = self.dfaFailSkip(scan, sc.stop);
        }
        return null;
    }

    /// findAll() via the lazy DFA. Fills `matches`. For capture-free patterns the
    /// DFA bounds are used directly; otherwise the NFA runs once per match start
    /// to fill captures (built with `allocator`). Returns error.DfaOverflow to
    /// signal fallback (the caller frees any partial results first).
    fn findAllWithDfa(self: *const Regex, d: *dfa.LazyDfa, allocator: std.mem.Allocator, matches: *std.ArrayList(Match), input: []const u8) dfa.Error!void {
        var v: ?vm.VM = if (self.capture_count > 0)
            vm.VM.init(self.allocator, @constCast(&self.nfa), self.capture_count, self.flags)
        else
            null;
        defer if (v) |*vv| vv.deinit();

        const pf = self.dfaPrefilterActive();
        const pref: ?LiteralPrefilter = if (self.opt_info.literal_prefix) |p| LiteralPrefilter.init(input, p) else null;
        var pos: usize = 0;
        while (pos <= input.len) {
            var scan = pos;
            var matched_end: ?usize = null;
            while (scan <= input.len) {
                if (pf) {
                    scan = self.skipToCandidate(input, scan, pref);
                    if (scan >= input.len) break;
                }
                const sc = try d.longestMatchFrom(input, scan);
                if (sc.end) |end| {
                    matched_end = end;
                    break;
                }
                scan = self.dfaFailSkip(scan, sc.stop);
            }
            const end = matched_end orelse break;
            if (v) |*vv| {
                if (try vv.matchAt(input, scan)) |result| {
                    const captures = try allocator.alloc([]const u8, result.captures.len);
                    for (result.captures, 0..) |cap, i| captures[i] = cap.text;
                    self.allocator.free(result.captures);
                    try matches.append(allocator, Match{ .slice = input[result.start..result.end], .start = result.start, .end = result.end, .captures = captures });
                    pos = if (result.end > result.start) result.end else result.end + 1;
                    continue;
                }
            }
            try matches.append(allocator, Match{ .slice = input[scan..end], .start = scan, .end = end });
            pos = if (end > scan) end else end + 1;
        }
    }

    /// Required-literal fast-fail: true when a mandatory literal substring is
    /// absent, so there can be no match. Skipped under the `i` flag and when the
    /// exact-literal path already covers the pattern. Uses the SIMD first-byte
    /// `literalSearch`.
    fn requiredAbsent(self: *const Regex, input: []const u8) bool {
        if (self.flags.case_insensitive) return false;
        if (self.opt_info.exact_literal != null) return false;
        if (self.opt_info.required_literal) |req| {
            return literalSearch(input, req, 0) == null;
        }
        return false;
    }

    /// ASCII case-fold a byte-membership table: include both cases of every set
    /// byte. Lets the repeated-atom fast path handle the case-insensitive flag.
    fn foldTableCI(t: [256]bool) [256]bool {
        var r = t;
        var b: usize = 0;
        while (b < 256) : (b += 1) {
            if (t[b]) {
                r[std.ascii.toLower(@intCast(b))] = true;
                r[std.ascii.toUpper(@intCast(b))] = true;
            }
        }
        return r;
    }

    /// The effective membership table for a repeated atom: the positive set
    /// (ASCII-case-folded under `i`), with negation applied last. Folding before
    /// negation is essential — folding a negated `[^a-c]` table would wrongly
    /// re-admit `a`-`c` (their uppercase matches `[^a-c]`, whose lowercase folds
    /// back in). `table[byte]` then means "byte matches the atom".
    fn repeatTable(ra: optimizer.OptimizationInfo.RepeatAtom, ci: bool) [256]bool {
        var t = if (ci) foldTableCI(ra.table) else ra.table;
        if (ra.negated) {
            var b: usize = 0;
            while (b < 256) : (b += 1) t[b] = !t[b];
        }
        return t;
    }

    /// First source-order literal in `set` that matches at `input[pos..]`, or 0
    /// if none. ECMAScript alternation is ordered (`a|ab` matches `a`).
    fn firstLiteralAt(set: []const []const u8, input: []const u8, pos: usize) usize {
        for (set) |s| {
            if (pos + s.len <= input.len and
                std.mem.eql(u8, input[pos .. pos + s.len], s)) return s.len;
        }
        return 0;
    }

    /// Candidate-position scanner for a literal alternation (`foo|bar|baz`). A
    /// DFA can't run these (ECMAScript alternation is leftmost-*first*, not
    /// longest), so the set path confirms each candidate with `firstLiteralAt`.
    /// When every literal is >= 2 bytes (and the first/second byte sets are
    /// small), this uses a vectorized **two-byte** filter — the simplified-Teddy
    /// idea: a position is a candidate only if `input[p]` is some literal's first
    /// byte AND `input[p+1]` is some literal's second byte. Testing two byte sets
    /// per 16-byte block (cheap `@reduce(.Or)`, no shuffle) cuts false candidates
    /// from ~|B1|/256 to ~|B1|·|B2|/65536 — e.g. `error|warning|debug` from ~1.2%
    /// to ~0.01%. Otherwise it falls back to the first-byte table walk.
    const set_pfx_cap = 32;
    const LiteralSetScanner = struct {
        /// Distinct little-endian 2-byte prefixes (`lit[0] | lit[1]<<8`) of the
        /// literals — the exact fingerprints, so the filter only fires on real
        /// literal prefixes (not the cross-product of first/second byte sets).
        pfx: [set_pfx_cap]u16 = undefined,
        np: usize = 0,
        two_byte: bool = false,
        fb: ?[256]bool,

        fn pairAt(input: []const u8, q: usize) u16 {
            return @as(u16, input[q]) | (@as(u16, input[q + 1]) << 8);
        }

        fn member(self: *const LiteralSetScanner, v: u16) bool {
            for (self.pfx[0..self.np]) |x| if (x == v) return true;
            return false;
        }

        fn init(set: []const []const u8, first_bytes: ?[256]bool) LiteralSetScanner {
            var sc: LiteralSetScanner = .{ .fb = first_bytes };
            var ok = set.len > 0;
            for (set) |lit| {
                if (lit.len < 2) {
                    ok = false;
                    break;
                }
                const v = @as(u16, lit[0]) | (@as(u16, lit[1]) << 8);
                var seen = false;
                for (sc.pfx[0..sc.np]) |x| {
                    if (x == v) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) {
                    if (sc.np >= sc.pfx.len) {
                        ok = false;
                        break;
                    }
                    sc.pfx[sc.np] = v;
                    sc.np += 1;
                }
            }
            sc.two_byte = ok and sc.np > 0;
            return sc;
        }

        /// Next position >= `from` that could begin a literal, or null.
        fn next(self: *const LiteralSetScanner, input: []const u8, from: usize) ?usize {
            if (!self.two_byte) {
                if (self.fb) |t| {
                    var p = from;
                    while (p < input.len and !t[input[p]]) p += 1;
                    return if (p < input.len) p else null;
                }
                return if (from < input.len) from else null;
            }
            const W = 16;
            const eight: @Vector(W, u16) = @splat(8);
            var p = from;
            while (p + 1 + W <= input.len) {
                // Overlapping 2-byte values at each lane: low byte at p+i, high at p+i+1.
                const c0: @Vector(W, u8) = input[p..][0..W].*;
                const c1: @Vector(W, u8) = input[p + 1 ..][0..W].*;
                const v16: @Vector(W, u16) = @as(@Vector(W, u16), c0) | (@as(@Vector(W, u16), c1) << eight);
                var hit: @Vector(W, bool) = v16 == @as(@Vector(W, u16), @splat(self.pfx[0]));
                for (self.pfx[1..self.np]) |pv| hit = hit | (v16 == @as(@Vector(W, u16), @splat(pv)));
                if (@reduce(.Or, hit)) {
                    var q = p;
                    while (q < p + W) : (q += 1) {
                        if (self.member(pairAt(input, q))) return q;
                    }
                }
                p += W;
            }
            while (p + 1 < input.len) : (p += 1) {
                if (self.member(pairAt(input, p))) return p;
            }
            return null;
        }
    };

    fn repeatRunAt(input: []const u8, table: [256]bool, start: usize, max: usize) usize {
        var p = start;
        var run: usize = 0;
        while (p < input.len and table[input[p]] and run < max) : (p += 1) run += 1;
        return run;
    }

    fn repeatBoundsOk(run: usize, min: usize, max: usize) bool {
        return run >= min and run <= max;
    }

    const UnicodeRepeatRun = struct { count: usize, end: usize };

    fn unicodePropMatches(cp: unicode_mod.Codepoint, up: ast.Node.UnicodeProp) bool {
        return unicode_mod.matchesSpec(cp, up.spec) != up.negated;
    }

    fn unicodeRepeatRunAt(input: []const u8, up: ast.Node.UnicodeProp, start: usize, max: usize) UnicodeRepeatRun {
        var p = start;
        var run: usize = 0;
        var spec_matcher = unicode_mod.SpecMatcher.init(up.spec);
        while (p < input.len and run < max) {
            const dec = unicode_mod.decodeUtf8Lenient(input[p..]) orelse break;
            if (spec_matcher.matches(dec.codepoint) == up.negated) break;
            p += dec.len;
            run += 1;
        }
        return .{ .count = run, .end = p };
    }

    fn nextCodepointStart(input: []const u8, pos: usize) usize {
        if (pos >= input.len) return input.len + 1;
        const dec = unicode_mod.decodeUtf8Lenient(input[pos..]) orelse return pos + 1;
        return pos + dec.len;
    }

    // --- Prefilter hints (issue #10) -------------------------------------
    //
    // The engine derives these from the pattern to skip non-candidate input.
    // Exposing them lets callers (e.g. a grep front-end) build their own
    // SIMD/multi-literal prefilter and avoid feeding the engine inputs that
    // cannot match. All are borrowed from the regex and live as long as it.

    /// A literal substring (>= 2 bytes) the pattern must start with, if any —
    /// suitable for an `indexOf`/`memchr` skip to candidate start positions.
    pub fn literalPrefix(self: *const Regex) ?[]const u8 {
        return self.opt_info.literal_prefix;
    }

    /// A literal substring that must appear *somewhere* in every match, if any.
    /// If it's absent from the input, the pattern cannot match at all.
    pub fn requiredLiteral(self: *const Regex) ?[]const u8 {
        return self.opt_info.required_literal;
    }

    /// The set of bytes a match can begin with, if a useful one exists: a
    /// 256-entry table where `set[b]` means byte `b` can start a match. Null
    /// when every byte is a candidate (no prefilter benefit).
    pub fn firstBytes(self: *const Regex) ?[256]bool {
        return self.opt_info.first_bytes;
    }

    /// When `firstBytes` is a single byte, that byte — the most selective case,
    /// ideal for a `memchr`/`indexOfScalar` scan.
    pub fn firstByte(self: *const Regex) ?u8 {
        return self.opt_info.first_byte_single;
    }

    /// A reusable, single-threaded matching context that **amortizes lazy-DFA
    /// construction across calls**. The plain `Regex.isMatch`/`find`/`count`/
    /// `findAll` build a fresh DFA every call (so the `Regex` stays immutable and
    /// concurrently shareable); that per-call build dominates when matching many
    /// small inputs (e.g. a grep over millions of lines — ~10-40x). A `Matcher`
    /// builds the DFA once and reuses it.
    ///
    /// NOT thread-safe: create one `Matcher` per thread (the `Regex` it borrows
    /// stays shareable). Lives no longer than the `Regex`.
    pub const Matcher = struct {
        re: *const Regex,
        dfa_cell: ?dfa.LazyDfa = null,
        dfa_failed: bool = false,
        search_dfa_cell: ?dfa.LazyDfa = null,
        search_dfa_failed: bool = false,
        vm_cell: ?vm.VM = null,

        pub fn deinit(self: *Matcher) void {
            if (self.dfa_cell) |*d| d.deinit();
            if (self.search_dfa_cell) |*d| d.deinit();
            if (self.vm_cell) |*v| v.deinit();
        }

        /// The cached unanchored search DFA for isMatch, built on first use.
        fn searchDfaPtr(self: *Matcher) ?*dfa.LazyDfa {
            if (self.search_dfa_cell) |*d| return d;
            if (self.search_dfa_failed or !self.re.dfaEligible()) return null;
            self.search_dfa_cell = dfa.LazyDfa.initSearch(self.re.allocator, @constCast(&self.re.nfa), self.re.flags) catch {
                self.search_dfa_failed = true;
                return null;
            };
            return &(self.search_dfa_cell.?);
        }

        /// The cached lazy DFA, built on first use; null when the pattern isn't
        /// DFA-eligible (the call then takes the same NFA/backtracking path as
        /// the plain API) or if construction hit OOM.
        fn dfaPtr(self: *Matcher) ?*dfa.LazyDfa {
            if (self.dfa_cell) |*d| return d;
            if (self.dfa_failed or !self.re.dfaEligible()) return null;
            self.dfa_cell = dfa.LazyDfa.init(self.re.allocator, @constCast(&self.re.nfa), self.re.flags) catch {
                self.dfa_failed = true;
                return null;
            };
            return &(self.dfa_cell.?);
        }

        /// The cached NFA VM, built on first use — reused across calls so the
        /// NFA-fallback path (mid-pattern assertions, lazy quantifiers) doesn't
        /// rebuild its thread/capture scratch every call. Only built for the
        /// Thompson engine (the backtracking engine is already stored on Regex).
        fn vmPtr(self: *Matcher) ?*vm.VM {
            if (self.vm_cell) |*v| return v;
            if (self.re.engine_type != .thompson_nfa) return null;
            self.vm_cell = vm.VM.init(self.re.allocator, @constCast(&self.re.nfa), self.re.capture_count, self.re.flags);
            return &(self.vm_cell.?);
        }

        pub fn isMatch(self: *Matcher, input: []const u8) !bool {
            return self.re.isMatchInner(input, self.vmPtr(), self.searchDfaPtr());
        }
        pub fn find(self: *Matcher, input: []const u8) !?Match {
            return self.re.findInner(input, self.dfaPtr(), self.vmPtr());
        }
        pub fn findAll(self: *Matcher, allocator: std.mem.Allocator, input: []const u8) ![]Match {
            return self.re.findAllInner(allocator, input, self.dfaPtr(), self.vmPtr());
        }
        pub fn count(self: *Matcher, input: []const u8) !usize {
            return self.re.countInner(input, self.dfaPtr(), self.vmPtr());
        }
        /// `countMatchingLines` reusing this matcher's cached search DFA — use in
        /// grep loops over many inputs so the lazy DFA is built once, not per call.
        pub fn countMatchingLines(self: *Matcher, input: []const u8) !usize {
            return self.re.countMatchingLinesInner(input, self.searchDfaPtr());
        }
        /// `forMatchingLines` reusing this matcher's cached search DFA.
        pub fn forMatchingLines(
            self: *Matcher,
            input: []const u8,
            ctx: anytype,
            comptime emit: fn (@TypeOf(ctx), usize, usize) anyerror!void,
        ) !void {
            return self.re.scanMatchingLines(input, self.searchDfaPtr(), ctx, emit);
        }
    };

    /// Create a reusable `Matcher` (see its docs) — use it for hot loops that
    /// match many inputs with the same compiled pattern. Call `deinit` when done.
    pub fn matcher(self: *const Regex) Matcher {
        return .{ .re = self };
    }

    /// Check if the pattern matches the entire input string
    pub fn isMatch(self: *const Regex, input: []const u8) !bool {
        return self.isMatchInner(input, null, null);
    }

    /// `reuse_dfa`/`reuse_search_dfa` let a `Matcher` pass cached lazy DFAs so
    /// per-call construction is amortized across calls (the grep hot path); null
    /// builds a fresh DFA per call (the thread-safe public path).
    fn isMatchInner(self: *const Regex, input: []const u8, reuse_vm: ?*vm.VM, reuse_search_dfa: ?*dfa.LazyDfa) !bool {
        // Required-literal fast-fail: a mandatory substring that's absent means
        // there can be no match (works for every engine).
        if (self.requiredAbsent(input)) return false;
        // `\bfn\b`-style bounded literal: SIMD literal scan + inline assertions.
        if (self.bounded_literal) |bl| return self.boundedLiteralNext(bl, LiteralPrefilter.init(input, bl.literal), input, 0) != null;
        // Exact-literal fast path: a fixed-string pattern is a substring search.
        if (self.opt_info.exact_literal) |lit| {
            if (self.flags.case_insensitive) {
                var sc = CiLiteralScanner.init(input, lit, 0);
                return sc.next() != null;
            }
            return literalSearch(input, lit, 0) != null;
        }
        // Repeated-atom fast path: a match exists iff some run of `table` bytes
        // reaches the minimum length. Only taken when the path can honor any
        // anchors: a trailing-`$`-only pattern (anchored_end without
        // anchored_start) has no branch here, so it falls through to the general
        // engine rather than the anchor-blind unanchored scan below.
        if (self.opt_info.repeat_atom) |ra| if (self.repeatAtomFastPathOk()) {
            const table = repeatTable(ra, self.flags.case_insensitive);
            const max = ra.max orelse std.math.maxInt(usize);
            if (self.opt_info.anchored_start and self.opt_info.anchored_end) {
                const run = repeatRunAt(input, table, 0, max);
                return run == input.len and repeatBoundsOk(run, ra.min, max);
            }
            if (self.opt_info.anchored_start) {
                const run = repeatRunAt(input, table, 0, max);
                return repeatBoundsOk(run, ra.min, max);
            }
            var p: usize = 0;
            while (p < input.len) {
                while (p < input.len and !table[input[p]]) p += 1;
                var run: usize = 0;
                while (p < input.len and table[input[p]]) : (p += 1) run += 1;
                if (run >= ra.min) return true;
            }
            return false;
        };
        // Repeated Unicode-property atom fast path. Keep `/i` on the general
        // path for now: complemented properties under ignore-case have
        // spec-specific folding semantics.
        if (self.opt_info.unicode_repeat_atom) |ura| if (!self.flags.case_insensitive and self.repeatAtomFastPathOk()) {
            const max = ura.max orelse std.math.maxInt(usize);
            if (self.opt_info.anchored_start and self.opt_info.anchored_end) {
                const run = unicodeRepeatRunAt(input, ura.property, 0, max);
                return run.end == input.len and repeatBoundsOk(run.count, ura.min, max);
            }
            if (self.opt_info.anchored_start) {
                const run = unicodeRepeatRunAt(input, ura.property, 0, max);
                return repeatBoundsOk(run.count, ura.min, max);
            }
            var p: usize = 0;
            while (p < input.len) {
                const run = unicodeRepeatRunAt(input, ura.property, p, max);
                if (run.count >= ura.min) return true;
                p = nextCodepointStart(input, p);
            }
            return false;
        };
        // Literal-alternation fast path.
        if (self.opt_info.literal_set) |set| {
            if (!self.flags.case_insensitive) {
                const scanner = LiteralSetScanner.init(set, self.opt_info.first_bytes);
                var p: usize = 0;
                while (scanner.next(input, p)) |cand| {
                    if (firstLiteralAt(set, input, cand) > 0) return true;
                    p = cand + 1;
                }
                return false;
            }
        }
        // Existence has no leftmost/longest subtlety, so the unanchored search
        // DFA settles it in one left-to-right pass (the re-seeded start makes every
        // position a candidate) — no per-position restart. O(n) even for sparse
        // matches like `fn\s+\w+|\w+\s+fn`.
        if (self.dfaEligible()) {
            var tmp: ?dfa.LazyDfa = null;
            defer if (tmp) |*t| t.deinit();
            if (self.obtainSearchDfa(reuse_search_dfa, &tmp)) |d| {
                if (d.anyMatch(input)) |b| {
                    return b;
                } else |err| switch (err) {
                    error.DfaOverflow => {}, // fall back to NFA
                    else => |e| return e,
                }
            }
        }
        switch (self.engine_type) {
            .thompson_nfa => {
                var tmp_vm: ?vm.VM = null;
                defer if (tmp_vm) |*v| v.deinit();
                const virtual_machine = self.obtainVm(reuse_vm, &tmp_vm);
                // First-byte-set prefilter: skip positions that can't start a match.
                if (self.opt_info.first_bytes) |fb| {
                    if (!self.flags.case_insensitive) {
                        var scan: usize = 0;
                        while (scan < input.len) {
                            while (scan < input.len and !fb[input[scan]]) scan += 1;
                            if (scan >= input.len) break;
                            if (try virtual_machine.matchAt(input, scan)) |result| {
                                var r = result;
                                r.deinit(self.allocator);
                                return true;
                            }
                            scan += 1;
                        }
                        return false;
                    }
                }
                return try virtual_machine.isMatch(input);
            },
            .backtracking => {
                const engine_mut = @constCast(&self.backtrack_engine.?);
                return engine_mut.isMatch(input);
            },
        }
    }

    /// Helper to build a Match from a VM MatchResult
    fn buildMatch(self: *const Regex, input: []const u8, result: vm.MatchResult) !Match {
        // Convert VM result to Match
        var captures_list = try std.ArrayList([]const u8).initCapacity(self.allocator, result.captures.len);
        errdefer captures_list.deinit(self.allocator);
        const present = try self.allocator.alloc(bool, result.captures.len);
        errdefer self.allocator.free(present);
        const spans = try self.allocator.alloc([2]usize, result.captures.len);
        errdefer self.allocator.free(spans);

        for (result.captures, 0..) |cap, i| {
            try captures_list.append(self.allocator, cap.text);
            present[i] = cap.matched;
            spans[i] = .{ cap.start, cap.end };
        }

        const captures = try captures_list.toOwnedSlice(self.allocator);

        const match_result = Match{
            .slice = input[result.start..result.end],
            .start = result.start,
            .end = result.end,
            .captures = captures,
            .captures_present = present,
            .capture_spans = spans,
        };

        // Free the VM result (but not the capture text which is from input)
        self.allocator.free(result.captures);

        return match_result;
    }

    /// Helper to build a Match from a Backtrack MatchResult
    fn buildBacktrackMatch(self: *const Regex, input: []const u8, result: backtrack.BacktrackMatch) !Match {
        var captures_list = try std.ArrayList([]const u8).initCapacity(self.allocator, result.captures.len);
        errdefer captures_list.deinit(self.allocator);
        const present = try self.allocator.alloc(bool, result.captures.len);
        errdefer self.allocator.free(present);
        const spans = try self.allocator.alloc([2]usize, result.captures.len);
        errdefer self.allocator.free(spans);

        for (result.captures, 0..) |cap, i| {
            present[i] = cap.matched;
            spans[i] = .{ cap.start, cap.end };
            if (cap.matched) {
                try captures_list.append(self.allocator, input[cap.start..cap.end]);
            } else {
                try captures_list.append(self.allocator, "");
            }
        }

        const captures = try captures_list.toOwnedSlice(self.allocator);

        return Match{
            .slice = input[result.start..result.end],
            .start = result.start,
            .end = result.end,
            .captures = captures,
            .captures_present = present,
            .capture_spans = spans,
        };
    }

    /// Find the first match in the input string
    pub fn find(self: *const Regex, input: []const u8) !?Match {
        return self.findInner(input, null, null);
    }

    fn findInner(self: *const Regex, input: []const u8, reuse_dfa: ?*dfa.LazyDfa, reuse_vm: ?*vm.VM) !?Match {
        if (self.requiredAbsent(input)) return null;
        // `\bfn\b`-style bounded literal: SIMD literal scan + inline assertions.
        if (self.bounded_literal) |bl| {
            if (self.boundedLiteralNext(bl, LiteralPrefilter.init(input, bl.literal), input, 0)) |m|
                return Match{ .slice = input[m[0]..m[1]], .start = m[0], .end = m[1] };
            return null;
        }
        // Exact-literal fast path: a fixed-string pattern is a substring search.
        if (self.opt_info.exact_literal) |lit| {
            const found = if (self.flags.case_insensitive) blk: {
                var sc = CiLiteralScanner.init(input, lit, 0);
                break :blk sc.next();
            } else literalSearch(input, lit, 0);
            if (found) |i| {
                return Match{ .slice = input[i .. i + lit.len], .start = i, .end = i + lit.len };
            }
            return null;
        }
        // Repeated-atom fast path: leftmost maximal run of `table` bytes.
        if (self.opt_info.repeat_atom) |ra| if (self.repeatAtomFastPathOk()) {
            const table = repeatTable(ra, self.flags.case_insensitive);
            const max = ra.max orelse std.math.maxInt(usize);
            if (self.opt_info.anchored_start and self.opt_info.anchored_end) {
                const run = repeatRunAt(input, table, 0, max);
                if (run == input.len and repeatBoundsOk(run, ra.min, max)) {
                    return Match{ .slice = input[0..run], .start = 0, .end = run };
                }
                return null;
            }
            if (self.opt_info.anchored_start) {
                const run = repeatRunAt(input, table, 0, max);
                if (repeatBoundsOk(run, ra.min, max)) {
                    return Match{ .slice = input[0..run], .start = 0, .end = run };
                }
                return null;
            }
            var p: usize = 0;
            while (p < input.len) {
                while (p < input.len and !table[input[p]]) p += 1;
                if (p >= input.len) break;
                const start = p;
                var run: usize = 0;
                while (p < input.len and table[input[p]] and run < max) : (p += 1) run += 1;
                if (run >= ra.min) return Match{ .slice = input[start..p], .start = start, .end = p };
            }
            return null;
        };
        // Repeated Unicode-property atom fast path.
        if (self.opt_info.unicode_repeat_atom) |ura| if (!self.flags.case_insensitive and self.repeatAtomFastPathOk()) {
            const max = ura.max orelse std.math.maxInt(usize);
            if (self.opt_info.anchored_start and self.opt_info.anchored_end) {
                const run = unicodeRepeatRunAt(input, ura.property, 0, max);
                if (run.end == input.len and repeatBoundsOk(run.count, ura.min, max)) {
                    return Match{ .slice = input[0..run.end], .start = 0, .end = run.end };
                }
                return null;
            }
            if (self.opt_info.anchored_start) {
                const run = unicodeRepeatRunAt(input, ura.property, 0, max);
                if (repeatBoundsOk(run.count, ura.min, max)) {
                    return Match{ .slice = input[0..run.end], .start = 0, .end = run.end };
                }
                return null;
            }
            var p: usize = 0;
            while (p < input.len) {
                const run = unicodeRepeatRunAt(input, ura.property, p, max);
                if (run.count >= ura.min) {
                    return Match{ .slice = input[p..run.end], .start = p, .end = run.end };
                }
                p = nextCodepointStart(input, p);
            }
            return null;
        };
        // Literal-alternation fast path: leftmost position, first source-order literal.
        if (self.opt_info.literal_set) |set| {
            if (!self.flags.case_insensitive) {
                const scanner = LiteralSetScanner.init(set, self.opt_info.first_bytes);
                var p: usize = 0;
                while (scanner.next(input, p)) |cand| {
                    const best = firstLiteralAt(set, input, cand);
                    if (best > 0) return Match{ .slice = input[cand .. cand + best], .start = cand, .end = cand + best };
                    p = cand + 1;
                }
                return null;
            }
        }
        // One-pass capture plan: deterministic capture matching, no NFA.
        if (self.onepass) |plan| {
            const fb = self.opt_info.first_bytes;
            var scan: usize = 0;
            while (scan <= input.len) {
                if (fb) |t| {
                    while (scan < input.len and !t[input[scan]]) scan += 1;
                    if (scan >= input.len) break;
                }
                if (try plan.matchAt(self.allocator, input, scan)) |result| {
                    return try self.buildMatch(input, result);
                }
                scan = plan.nextScan(input, scan);
            }
            return null;
        }
        // Lazy-DFA path for eligible general patterns: the DFA locates the match
        // (bounds directly, or NFA at the start for captures).
        if (self.dfaEligible()) {
            var tmp: ?dfa.LazyDfa = null;
            defer if (tmp) |*t| t.deinit();
            if (self.obtainDfa(reuse_dfa, &tmp)) |d| {
                if (self.findWithDfa(d, input)) |maybe| {
                    return maybe;
                } else |err| switch (err) {
                    error.DfaOverflow => {}, // fall back to NFA
                    else => |e| return e,
                }
            }
        }
        switch (self.engine_type) {
            .thompson_nfa => {
                var tmp_vm: ?vm.VM = null;
                defer if (tmp_vm) |*v| v.deinit();
                const virtual_machine = self.obtainVm(reuse_vm, &tmp_vm);

                // Use literal prefix optimization if available (but not in case-insensitive mode)
                if (self.opt_info.literal_prefix) |prefix| {
                    if (!self.flags.case_insensitive) {
                        // Skip ahead to each occurrence of the prefix and try matching there
                        var search_from: usize = 0;
                        while (std.mem.indexOf(u8, input[search_from..], prefix)) |rel_pos| {
                            const prefix_pos = search_from + rel_pos;
                            if (try virtual_machine.matchAt(input, prefix_pos)) |result| {
                                return try self.buildMatch(input, result);
                            }
                            // Try next occurrence
                            search_from = prefix_pos + 1;
                        }
                        // No prefix occurrence matched
                        return null;
                    }
                }

                // First-byte-set prefilter: only attempt matches where the byte
                // can start one. Same correctness basis as findAll/count.
                if (self.opt_info.first_bytes) |fb| {
                    if (!self.flags.case_insensitive) {
                        var scan: usize = 0;
                        while (scan < input.len) {
                            while (scan < input.len and !fb[input[scan]]) scan += 1;
                            if (scan >= input.len) break;
                            if (try virtual_machine.matchAt(input, scan)) |result| {
                                return try self.buildMatch(input, result);
                            }
                            scan += 1;
                        }
                        return null;
                    }
                }

                if (try virtual_machine.find(input)) |result| {
                    return try self.buildMatch(input, result);
                }

                return null;
            },
            .backtracking => {
                const engine_mut = @constCast(&self.backtrack_engine.?);
                if (engine_mut.find(input)) |result| {
                    var mut_result = result;
                    defer mut_result.deinit(self.allocator);
                    return try self.buildBacktrackMatch(input, result);
                }
                return null;
            },
        }
    }

    /// Find the first match at or after `start` while evaluating assertions
    /// against the original `input`. This is distinct from `find(input[start..])`:
    /// anchors such as `^` and word-boundary context must still see the whole
    /// string.
    pub fn findFrom(self: *const Regex, input: []const u8, start: usize) !?Match {
        if (start == 0) return self.find(input);
        if (self.requiredAbsent(input)) return null;

        if (self.opt_info.exact_literal) |lit| {
            const found = if (self.flags.case_insensitive) blk: {
                var sc = CiLiteralScanner.init(input, lit, @min(start, input.len));
                break :blk sc.next();
            } else literalSearch(input, lit, @min(start, input.len));
            if (found) |i| return Match{ .slice = input[i .. i + lit.len], .start = i, .end = i + lit.len };
            return null;
        }

        switch (self.engine_type) {
            .thompson_nfa => {
                const nfa_mut = @constCast(&self.nfa);
                var virtual_machine = vm.VM.init(self.allocator, nfa_mut, self.capture_count, self.flags);
                defer virtual_machine.deinit();

                if (self.onepass) |plan| {
                    const fb = self.opt_info.first_bytes;
                    var scan: usize = @min(start, input.len);
                    while (scan <= input.len) {
                        if (fb) |t| {
                            while (scan < input.len and !t[input[scan]]) scan += 1;
                            if (scan >= input.len) break;
                        }
                        if (try plan.matchAt(self.allocator, input, scan)) |result| {
                            return try self.buildMatch(input, result);
                        }
                        scan = plan.nextScan(input, scan);
                    }
                    return null;
                }

                if (self.opt_info.literal_prefix) |prefix| {
                    if (!self.flags.case_insensitive) {
                        var search_from: usize = @min(start, input.len);
                        while (std.mem.indexOf(u8, input[search_from..], prefix)) |rel_pos| {
                            const prefix_pos = search_from + rel_pos;
                            if (try virtual_machine.matchAt(input, prefix_pos)) |result| {
                                return try self.buildMatch(input, result);
                            }
                            search_from = prefix_pos + 1;
                        }
                        return null;
                    }
                }

                if (self.opt_info.first_bytes) |fb| {
                    if (!self.flags.case_insensitive) {
                        var scan: usize = @min(start, input.len);
                        while (scan < input.len) {
                            while (scan < input.len and !fb[input[scan]]) scan += 1;
                            if (scan >= input.len) break;
                            if (try virtual_machine.matchAt(input, scan)) |result| {
                                return try self.buildMatch(input, result);
                            }
                            scan += 1;
                        }
                        return null;
                    }
                }

                var scan: usize = @min(start, input.len);
                while (scan <= input.len) {
                    if (try virtual_machine.matchAt(input, scan)) |result| {
                        return try self.buildMatch(input, result);
                    }
                    if (scan == input.len) break;
                    scan += 1;
                }
                return null;
            },
            .backtracking => {
                const engine_mut = @constCast(&self.backtrack_engine.?);
                if (engine_mut.findFrom(input, start)) |result| {
                    var mut_result = result;
                    defer mut_result.deinit(self.allocator);
                    return try self.buildBacktrackMatch(input, result);
                }
                return null;
            },
        }
    }

    /// Find all matches in the input string
    pub fn findAll(self: *const Regex, allocator: std.mem.Allocator, input: []const u8) ![]Match {
        return self.findAllInner(allocator, input, null, null);
    }

    fn findAllInner(self: *const Regex, allocator: std.mem.Allocator, input: []const u8, reuse_dfa: ?*dfa.LazyDfa, reuse_vm: ?*vm.VM) ![]Match {
        var matches: std.ArrayList(Match) = .empty;
        errdefer matches.deinit(allocator);

        var pos: usize = 0;

        if (self.requiredAbsent(input)) return matches.toOwnedSlice(allocator);

        // `\bfn\b`-style bounded literal: SIMD literal scan + inline assertions.
        if (self.bounded_literal) |bl| {
            const bpf = LiteralPrefilter.init(input, bl.literal);
            while (self.boundedLiteralNext(bl, bpf, input, pos)) |m| {
                try matches.append(allocator, Match{ .slice = input[m[0]..m[1]], .start = m[0], .end = m[1] });
                pos = if (m[1] > m[0]) m[1] else m[1] + 1;
            }
            return matches.toOwnedSlice(allocator);
        }

        // Exact-literal fast path: repeated substring search, no NFA.
        if (self.opt_info.exact_literal) |lit| {
            if (self.flags.case_insensitive) {
                var sc = CiLiteralScanner.init(input, lit, 0);
                while (sc.next()) |i| {
                    try matches.append(allocator, Match{ .slice = input[i .. i + lit.len], .start = i, .end = i + lit.len });
                }
                return matches.toOwnedSlice(allocator);
            }
            const lpf = LiteralPrefilter.init(input, lit);
            while (lpf.next(input, pos)) |i| {
                try matches.append(allocator, Match{ .slice = input[i .. i + lit.len], .start = i, .end = i + lit.len });
                pos = i + lit.len;
            }
            return matches.toOwnedSlice(allocator);
        }
        // Repeated-atom fast path: each leftmost maximal run of `table` bytes
        // (capped at max) is one non-overlapping match. No NFA, no per-match
        // capture allocation. Honors anchors (see repeatAtomFastPathOk); an
        // anchored pattern yields at most one match.
        if (self.opt_info.repeat_atom) |ra| if (self.repeatAtomFastPathOk()) {
            const table = repeatTable(ra, self.flags.case_insensitive);
            const max = ra.max orelse std.math.maxInt(usize);
            if (self.opt_info.anchored_start and self.opt_info.anchored_end) {
                const run = repeatRunAt(input, table, 0, max);
                if (run == input.len and repeatBoundsOk(run, ra.min, max))
                    try matches.append(allocator, Match{ .slice = input[0..run], .start = 0, .end = run });
                return matches.toOwnedSlice(allocator);
            }
            if (self.opt_info.anchored_start) {
                const run = repeatRunAt(input, table, 0, max);
                if (repeatBoundsOk(run, ra.min, max))
                    try matches.append(allocator, Match{ .slice = input[0..run], .start = 0, .end = run });
                return matches.toOwnedSlice(allocator);
            }
            while (pos < input.len) {
                while (pos < input.len and !table[input[pos]]) pos += 1;
                if (pos >= input.len) break;
                const start = pos;
                var run: usize = 0;
                while (pos < input.len and table[input[pos]] and run < max) : (pos += 1) run += 1;
                if (run >= ra.min) {
                    try matches.append(allocator, Match{ .slice = input[start..pos], .start = start, .end = pos });
                }
            }
            return matches.toOwnedSlice(allocator);
        };
        // Literal-alternation fast path: each leftmost source-order literal match.
        if (self.opt_info.literal_set) |set| {
            if (!self.flags.case_insensitive) {
                const scanner = LiteralSetScanner.init(set, self.opt_info.first_bytes);
                while (scanner.next(input, pos)) |cand| {
                    const best = firstLiteralAt(set, input, cand);
                    if (best > 0) {
                        try matches.append(allocator, Match{ .slice = input[cand .. cand + best], .start = cand, .end = cand + best });
                        pos = cand + best;
                    } else {
                        pos = cand + 1;
                    }
                }
                return matches.toOwnedSlice(allocator);
            }
        }

        // One-pass capture plan: deterministic capture matching, no NFA.
        if (self.onepass) |plan| {
            const fb = self.opt_info.first_bytes;
            while (pos <= input.len) {
                var scan = pos;
                var found: ?vm.MatchResult = null;
                while (scan <= input.len) {
                    if (fb) |t| {
                        while (scan < input.len and !t[input[scan]]) scan += 1;
                        if (scan >= input.len) break;
                    }
                    if (try plan.matchAt(allocator, input, scan)) |r| {
                        found = r;
                        break;
                    }
                    scan = plan.nextScan(input, scan);
                }
                const result = found orelse break;
                const captures = try allocator.alloc([]const u8, result.captures.len);
                for (result.captures, 0..) |cap, i| captures[i] = cap.text;
                allocator.free(result.captures);
                try matches.append(allocator, Match{ .slice = input[result.start..result.end], .start = result.start, .end = result.end, .captures = captures });
                pos = if (result.end > result.start) result.end else result.end + 1;
            }
            return matches.toOwnedSlice(allocator);
        }
        // Lazy-DFA path for eligible general patterns. On overflow, free any
        // partial results (their captures are owned) and fall back to the NFA.
        if (self.dfaEligible()) {
            var tmp: ?dfa.LazyDfa = null;
            defer if (tmp) |*t| t.deinit();
            if (self.obtainDfa(reuse_dfa, &tmp)) |d| {
                if (self.findAllWithDfa(d, allocator, &matches, input)) |_| {
                    return matches.toOwnedSlice(allocator);
                } else |err| switch (err) {
                    error.DfaOverflow => {
                        for (matches.items) |*m| m.deinit(allocator);
                        matches.clearRetainingCapacity();
                    },
                    else => |e| return e,
                }
            }
        }

        // Thompson path: reuse a single VM across all matches (VM.init does not
        // allocate) and, when the pattern has a literal prefix, use it as a
        // prefilter — `std.mem.indexOf` skips whole non-matching regions instead
        // of running the NFA at every byte. This is the same prefilter `find`
        // uses; `findAll` previously rescanned every position, which is why it
        // was orders of magnitude slower on literal-led patterns.
        if (self.engine_type == .thompson_nfa) {
            var tmp_vm: ?vm.VM = null;
            defer if (tmp_vm) |*v| v.deinit();
            const virtual_machine = self.obtainVm(reuse_vm, &tmp_vm);
            // Prefilters (skipped under case-insensitive matching, where the
            // byte-exact sets don't hold): a literal prefix is strongest; else a
            // first-byte set rules out positions that can't start a match.
            const prefix: ?[]const u8 = if (self.flags.case_insensitive) null else self.opt_info.literal_prefix;
            const first_bytes: ?[256]bool = if (self.flags.case_insensitive or prefix != null) null else self.opt_info.first_bytes;

            while (pos <= input.len) {
                // Locate the next position >= pos where a match starts.
                var scan = pos;
                var result: ?vm.MatchResult = null;
                while (scan <= input.len) {
                    if (prefix) |p| {
                        const rel = std.mem.indexOf(u8, input[scan..], p) orelse break;
                        scan += rel;
                    } else if (first_bytes) |fb| {
                        while (scan < input.len and !fb[input[scan]]) scan += 1;
                        if (scan >= input.len) break;
                    }
                    if (try virtual_machine.matchAt(input, scan)) |r| {
                        result = r;
                        break;
                    }
                    scan += 1;
                }
                const r = result orelse break;
                // matchAt reports absolute positions; captures index into `input`.
                const captures = try allocator.alloc([]const u8, r.captures.len);
                for (r.captures, 0..) |cap, i| captures[i] = cap.text;
                self.allocator.free(r.captures);

                try matches.append(allocator, Match{
                    .slice = input[r.start..r.end],
                    .start = r.start,
                    .end = r.end,
                    .captures = captures,
                });

                // Advance past the match (avoid looping on zero-width matches).
                pos = if (r.end > r.start) r.end else r.end + 1;
            }
            return matches.toOwnedSlice(allocator);
        }

        // `<= input.len` so a zero-width match at end of input (e.g. `a*`, a lazy
        // quantifier, or an optional group on empty input) is found — matching the
        // Thompson path and find()/isMatch().
        while (pos <= input.len) {
            switch (self.engine_type) {
                .thompson_nfa => unreachable, // handled above
                .backtracking => {
                    const engine_mut = @constCast(&self.backtrack_engine.?);
                    if (engine_mut.find(input[pos..])) |result| {
                        var mut_result = result;
                        defer mut_result.deinit(self.allocator);

                        // Adjust positions relative to original input
                        const adjusted_start = pos + result.start;
                        const adjusted_end = pos + result.end;

                        var captures_list = try std.ArrayList([]const u8).initCapacity(allocator, result.captures.len);
                        errdefer captures_list.deinit(allocator);

                        for (result.captures) |cap| {
                            if (cap.matched) {
                                // Capture positions are relative to the sliced input (input[pos..])
                                try captures_list.append(allocator, input[pos + cap.start .. pos + cap.end]);
                            } else {
                                try captures_list.append(allocator, "");
                            }
                        }

                        const captures = try captures_list.toOwnedSlice(allocator);

                        try matches.append(allocator, Match{
                            .slice = input[adjusted_start..adjusted_end],
                            .start = adjusted_start,
                            .end = adjusted_end,
                            .captures = captures,
                        });

                        // Move past this match (avoid infinite loop on zero-width matches)
                        pos = if (adjusted_end > adjusted_start) adjusted_end else adjusted_end + 1;
                    } else {
                        break;
                    }
                },
            }
        }

        return matches.toOwnedSlice(allocator);
    }

    /// Count all non-overlapping matches without materializing them. This is the
    /// allocation-free counterpart to `findAll().len` and the fair counterpart to
    /// Rust's `find_iter().count()`. Reuses every fast path and, on the NFA path,
    /// a single VM with the prefilter — no `Match` structs, no capture slices.
    pub fn count(self: *const Regex, input: []const u8) !usize {
        return self.countInner(input, null, null);
    }

    /// Number of newline-delimited lines that contain at least one match — the
    /// `grep -c` workload. A fixed-string pattern is served by a single
    /// whole-buffer SIMD literal scan (one match per line, skip to the next
    /// line), avoiding per-line dispatch; every other pattern falls back to a
    /// reused Matcher's single-pass isMatch per line.
    /// Whether `req` is rare enough in `input` that prefiltering on it beats
    /// scanning every line. Multi-byte literals are assumed selective; a single
    /// byte is checked against an occurrence-density threshold (one SIMD pass).
    fn requiredLiteralSelective(self: *const Regex, input: []const u8, req: []const u8) bool {
        _ = self;
        if (input.len == 0) return false;
        if (req.len >= 2) return true;
        // Single byte: only worthwhile when it occurs in well under one-in-eight
        // bytes (so most lines are skipped).
        return countByte(input, req[0]) < @max(input.len / 8, 1);
    }

    pub fn countMatchingLines(self: *const Regex, input: []const u8) !usize {
        return self.countMatchingLinesInner(input, null);
    }

    fn countMatchingLinesInner(self: *const Regex, input: []const u8, reuse_search_dfa: ?*dfa.LazyDfa) !usize {
        var n: usize = 0;
        try self.scanMatchingLines(input, reuse_search_dfa, &n, struct {
            fn f(c: *usize, ls: usize, le: usize) dfa.Error!void {
                _ = ls;
                _ = le;
                c.* += 1;
            }
        }.f);
        return n;
    }

    /// Invoke `emit(ctx, line_start, line_end)` for every line of `input` that
    /// matches — the print-path companion to `countMatchingLines`, sharing all
    /// of its fast paths (whole-buffer literal/required-literal prefilters and
    /// the single-pass line DFA). `[line_start, line_end)` excludes the trailing
    /// newline. Lines are reported in order.
    pub fn forMatchingLines(
        self: *const Regex,
        input: []const u8,
        ctx: anytype,
        comptime emit: fn (@TypeOf(ctx), usize, usize) anyerror!void,
    ) !void {
        return self.scanMatchingLines(input, null, ctx, emit);
    }

    /// `reuse_search_dfa` (from a `Matcher`) lets the per-line DFA scan reuse a
    /// search DFA across many inputs — essential for grep over many files, where
    /// building a fresh lazy DFA per file otherwise dominates (each `processFile`
    /// would re-pay the construction). Null builds a throwaway DFA per call.
    fn scanMatchingLines(
        self: *const Regex,
        input: []const u8,
        reuse_search_dfa: ?*dfa.LazyDfa,
        ctx: anytype,
        comptime emit: anytype,
    ) !void {
        // Whole-buffer literal fast path: an exact-literal pattern has no anchors,
        // so a line matches iff it contains the literal. Scan for occurrences and
        // jump past the rest of each hit line. Skipped under `i` (case folding) and
        // when the literal itself spans a newline.
        if (self.opt_info.exact_literal) |lit| {
            if (!self.flags.case_insensitive and lit.len > 0 and
                std.mem.indexOfScalar(u8, lit, '\n') == null)
            {
                // Build the SIMD prefilter once (it analyzes the buffer to pick a
                // scan strategy) and reuse it across hits.
                const pf = LiteralPrefilter.init(input, lit);
                var pos: usize = 0;
                while (pf.next(input, pos)) |i| {
                    const le = std.mem.indexOfScalarPos(u8, input, i, '\n') orelse input.len;
                    const ls = if (std.mem.lastIndexOfScalar(u8, input[0..i], '\n')) |nl| nl + 1 else 0;
                    try emit(ctx, ls, le);
                    pos = le + 1;
                    if (pos > input.len) break;
                }
                return;
            }
            // Case-insensitive exact literal: a line matches iff it contains the
            // literal under ASCII case folding. The two-cursor memchr scanner
            // (both cases of the first byte) skips non-candidate bytes instead of
            // stepping the DFA over every byte — a big win for `grep -i word`.
            if (self.flags.case_insensitive and lit.len > 0 and
                std.mem.indexOfScalar(u8, lit, '\n') == null)
            {
                var sc = CiLiteralScanner.init(input, lit, 0);
                while (sc.next()) |i| {
                    const le = std.mem.indexOfScalarPos(u8, input, i, '\n') orelse input.len;
                    const ls = if (std.mem.lastIndexOfScalar(u8, input[0..i], '\n')) |nl| nl + 1 else 0;
                    try emit(ctx, ls, le);
                    if (le + 1 > input.len) break;
                    sc = CiLiteralScanner.init(input, lit, le + 1);
                }
                return;
            }
        }
        // Required-literal prefilter: every match contains `req`, so only lines
        // containing it can match. memchr `req` over the whole buffer (SIMD) and
        // run the matcher only on those candidate lines — the rest are skipped
        // entirely. A big win for rare-literal patterns (`\w+@\w+`, `\d+\.\d+`,
        // `fn\s+\w+`). Gated on selectivity so common literals don't add overhead.
        if (!self.flags.case_insensitive) {
            if (self.opt_info.required_literal) |req| {
                if (req.len > 0 and std.mem.indexOfScalar(u8, req, '\n') == null and
                    self.requiredLiteralSelective(input, req))
                {
                    // Per-candidate verification reuses one search DFA for the
                    // whole scan: the passed-in one (a `Matcher`'s, in grep loops)
                    // or a single throwaway built here — never one per candidate.
                    var tmp_dfa: ?dfa.LazyDfa = null;
                    defer if (tmp_dfa) |*t| t.deinit();
                    const sdfa = reuse_search_dfa orelse (if (self.dfaEligible()) self.obtainSearchDfa(null, &tmp_dfa) else null);
                    // If the bare literal is itself a complete match — no anchors
                    // or zero-width assertions constrain where it may sit — then
                    // every line containing it matches, so the per-candidate
                    // isMatch is redundant (e.g. `fn|fn\s`, whose `fn` branch is
                    // the literal). Verify once by matching the literal alone.
                    const lit_sufficient = !self.opt_info.has_assertions and
                        !self.opt_info.anchored_start and !self.opt_info.anchored_end and
                        (self.isMatchInner(req, null, sdfa) catch false);
                    const pf = LiteralPrefilter.init(input, req);
                    var pos: usize = 0;
                    while (pf.next(input, pos)) |hit| {
                        const le = std.mem.indexOfScalarPos(u8, input, hit, '\n') orelse input.len;
                        const ls = if (std.mem.lastIndexOfScalar(u8, input[0..hit], '\n')) |nl| nl + 1 else 0;
                        if (lit_sufficient or try self.isMatchInner(input[ls..le], null, sdfa)) try emit(ctx, ls, le);
                        pos = le + 1;
                        if (pos > input.len) break;
                    }
                    return;
                }
            }
        }
        // DFA-eligible patterns: step the search DFA over each line in a single
        // whole-buffer pass, skipping the per-line isMatchInner fast-path
        // dispatch. Anchor-free patterns use the plain line DFA; assertion-bearing
        // patterns (`^…$`, `…$`, `\b…`) use the fused anchored variant (each line
        // matched as standalone text) rather than dispatching `anyMatch` per line.
        // `resume_from` lets a rare mid-scan DFA overflow hand off to the general
        // matcher *from the unfinished line* — lines already emitted aren't redone.
        var resume_from: usize = 0;
        if (self.dfaEligible()) {
            var tmp: ?dfa.LazyDfa = null;
            defer if (tmp) |*t| t.deinit();
            if (self.obtainSearchDfa(reuse_search_dfa, &tmp)) |d| {
                const scan_res = if (!d.anchored)
                    d.forMatchingLines(input, ctx, emit)
                else
                    d.forMatchingLinesAnchored(input, ctx, emit);
                if (scan_res) |maybe_resume| {
                    if (maybe_resume) |r| {
                        resume_from = r; // overflowed; continue below from line `r`
                    } else return;
                } else |err| return err;
            }
        }
        var m = self.matcher();
        defer m.deinit();
        var ls: usize = resume_from;
        while (ls <= input.len) {
            const le = std.mem.indexOfScalarPos(u8, input, ls, '\n') orelse input.len;
            if (try m.isMatch(input[ls..le])) try emit(ctx, ls, le);
            if (le == input.len) break;
            ls = le + 1;
        }
    }

    /// `countMatchingLines` parallelized across CPU cores. Splits the buffer at
    /// newline boundaries into one chunk per worker (each chunk is whole lines,
    /// so per-line semantics hold and the separating newline is consumed between
    /// chunks — no double counting), runs the single-threaded path per chunk on a
    /// thread-local DFA (the `Regex` is read only), and sums. Falls back to serial
    /// for small inputs, a single core, or any spawn/worker error.
    ///
    /// NOTE: for the threads not to contend, the `Regex` must have been compiled
    /// with a fast thread-safe allocator (e.g. `std.heap.smp_allocator`), not a
    /// debug/locking allocator — otherwise per-thread DFA allocations serialize.
    pub fn countMatchingLinesParallel(self: *const Regex, input: []const u8) !usize {
        const MAX_WORKERS = 16;
        const MIN_PARALLEL = 1 << 20; // 1 MiB
        const cpu = std.Thread.getCpuCount() catch 1;
        var workers: usize = @min(@min(cpu, MAX_WORKERS), (input.len / MIN_PARALLEL) + 1);
        if (workers <= 1) return self.countMatchingLines(input);

        var starts: [MAX_WORKERS]usize = undefined;
        var ends: [MAX_WORKERS]usize = undefined;
        starts[0] = 0;
        var made: usize = 0;
        var w: usize = 0;
        while (w < workers) : (w += 1) {
            if (w == workers - 1) {
                ends[w] = input.len;
            } else {
                const approx = (input.len * (w + 1)) / workers;
                ends[w] = std.mem.indexOfScalarPos(u8, input, approx, '\n') orelse input.len;
            }
            made = w + 1;
            if (ends[w] >= input.len) break;
            starts[w + 1] = ends[w] + 1;
        }
        workers = made;
        if (workers <= 1) return self.countMatchingLines(input);

        const Worker = struct {
            re: *const Regex,
            chunk: []const u8,
            result: usize = 0,
            err: bool = false,
            fn run(ctx: *@This()) void {
                ctx.result = ctx.re.countMatchingLines(ctx.chunk) catch {
                    ctx.err = true;
                    return;
                };
            }
        };
        var ctxs: [MAX_WORKERS]Worker = undefined;
        var threads: [MAX_WORKERS]?std.Thread = undefined;
        for (&threads) |*thread| thread.* = null;
        var i: usize = 0;
        while (i < workers) : (i += 1) ctxs[i] = .{ .re = self, .chunk = input[starts[i]..ends[i]] };
        i = 1;
        while (i < workers) : (i += 1) threads[i] = std.Thread.spawn(.{}, Worker.run, .{&ctxs[i]}) catch null;
        Worker.run(&ctxs[0]);
        var any_err = ctxs[0].err;
        i = 1;
        while (i < workers) : (i += 1) {
            if (threads[i]) |t| t.join() else Worker.run(&ctxs[i]);
            any_err = any_err or ctxs[i].err;
        }
        if (any_err) return self.countMatchingLines(input);
        var total: usize = 0;
        i = 0;
        while (i < workers) : (i += 1) total += ctxs[i].result;
        return total;
    }

    fn countInner(self: *const Regex, input: []const u8, reuse_dfa: ?*dfa.LazyDfa, reuse_vm: ?*vm.VM) !usize {
        var n: usize = 0;
        var pos: usize = 0;

        if (self.requiredAbsent(input)) return 0;

        // `\bfn\b`-style bounded literal: SIMD literal scan + inline assertions.
        if (self.bounded_literal) |bl| {
            const bpf = LiteralPrefilter.init(input, bl.literal);
            while (self.boundedLiteralNext(bl, bpf, input, pos)) |m| {
                n += 1;
                pos = if (m[1] > m[0]) m[1] else m[1] + 1;
            }
            return n;
        }

        // Exact-literal: repeated substring search.
        if (self.opt_info.exact_literal) |lit| {
            if (self.flags.case_insensitive) {
                var sc = CiLiteralScanner.init(input, lit, 0);
                while (sc.next()) |_| n += 1;
                return n;
            }
            const lpf = LiteralPrefilter.init(input, lit);
            while (lpf.next(input, pos)) |i| {
                n += 1;
                pos = i + lit.len;
            }
            return n;
        }
        // Repeated-atom: count maximal runs of >= min table bytes. Honors anchors
        // (see repeatAtomFastPathOk); anchored patterns yield at most one match.
        if (self.opt_info.repeat_atom) |ra| if (self.repeatAtomFastPathOk()) {
            const table = repeatTable(ra, self.flags.case_insensitive);
            const max = ra.max orelse std.math.maxInt(usize);
            if (self.opt_info.anchored_start and self.opt_info.anchored_end) {
                const run = repeatRunAt(input, table, 0, max);
                return if (run == input.len and repeatBoundsOk(run, ra.min, max)) 1 else 0;
            }
            if (self.opt_info.anchored_start) {
                const run = repeatRunAt(input, table, 0, max);
                return if (repeatBoundsOk(run, ra.min, max)) 1 else 0;
            }
            while (pos < input.len) {
                while (pos < input.len and !table[input[pos]]) pos += 1;
                if (pos >= input.len) break;
                var run: usize = 0;
                while (pos < input.len and table[input[pos]] and run < max) : (pos += 1) run += 1;
                if (run >= ra.min) n += 1;
            }
            return n;
        };
        // Literal-alternation: leftmost source-order literal at each candidate.
        if (self.opt_info.literal_set) |set| {
            if (!self.flags.case_insensitive) {
                const scanner = LiteralSetScanner.init(set, self.opt_info.first_bytes);
                while (scanner.next(input, pos)) |cand| {
                    const best = firstLiteralAt(set, input, cand);
                    if (best > 0) {
                        n += 1;
                        pos = cand + best;
                    } else pos = cand + 1;
                }
                return n;
            }
        }

        // count needs no captures, so the lazy DFA (with the death-position skip)
        // handles one-pass patterns too. The plan is reserved for find/findAll.
        // Lazy-DFA path for eligible general patterns.
        if (self.dfaEligible()) {
            var tmp: ?dfa.LazyDfa = null;
            defer if (tmp) |*t| t.deinit();
            if (self.obtainDfa(reuse_dfa, &tmp)) |d| {
                if (self.countWithDfa(d, input)) |c| {
                    return c;
                } else |err| switch (err) {
                    error.DfaOverflow => {}, // fall back to NFA
                    else => |e| return e,
                }
            }
        }

        // Anchored-start patterns (`^…`) can only match at a line start, so probe
        // those positions instead of scanning every byte. matchAt evaluates the
        // rest of the pattern (including a trailing `$`) at each.
        if (self.engine_type == .thompson_nfa and self.opt_info.anchored_start) {
            var tmp_vm: ?vm.VM = null;
            defer if (tmp_vm) |*v| v.deinit();
            const machine = self.obtainVm(reuse_vm, &tmp_vm);
            while (self.nextLineStart(input, pos)) |s| {
                if (try machine.matchAt(input, s)) |r| {
                    var rr = r;
                    rr.deinit(self.allocator);
                    n += 1;
                    pos = if (r.end > s) r.end else s + 1;
                } else {
                    pos = s + 1;
                }
            }
            return n;
        }

        switch (self.engine_type) {
            .thompson_nfa => {
                var tmp_vm: ?vm.VM = null;
                defer if (tmp_vm) |*v| v.deinit();
                const virtual_machine = self.obtainVm(reuse_vm, &tmp_vm);
                const prefix: ?[]const u8 = if (self.flags.case_insensitive) null else self.opt_info.literal_prefix;
                const first_bytes: ?[256]bool = if (self.flags.case_insensitive or prefix != null) null else self.opt_info.first_bytes;

                while (pos <= input.len) {
                    var scan = pos;
                    var result: ?vm.MatchResult = null;
                    while (scan <= input.len) {
                        if (prefix) |p| {
                            const rel = std.mem.indexOf(u8, input[scan..], p) orelse break;
                            scan += rel;
                        } else if (first_bytes) |fb| {
                            while (scan < input.len and !fb[input[scan]]) scan += 1;
                            if (scan >= input.len) break;
                        }
                        if (try virtual_machine.matchAt(input, scan)) |r| {
                            result = r;
                            break;
                        }
                        scan += 1;
                    }
                    var r = result orelse break;
                    r.deinit(self.allocator);
                    n += 1;
                    pos = if (r.end > r.start) r.end else r.end + 1;
                }
                return n;
            },
            .backtracking => {
                const engine_mut = @constCast(&self.backtrack_engine.?);
                // `<= input.len` so a zero-width match at end of input is counted,
                // matching the Thompson path and find()/isMatch().
                while (pos <= input.len) {
                    if (engine_mut.find(input[pos..])) |result| {
                        var mut_result = result;
                        mut_result.deinit(self.allocator);
                        const adjusted_start = pos + result.start;
                        const adjusted_end = pos + result.end;
                        n += 1;
                        pos = if (adjusted_end > adjusted_start) adjusted_end else adjusted_end + 1;
                    } else break;
                }
                return n;
            },
        }
    }

    /// Expand replacement string with backreferences ($1, $2, etc.)
    fn expandReplacement(allocator: std.mem.Allocator, replacement: []const u8, captures: []const []const u8, full_match: []const u8) ![]u8 {
        var result = try std.ArrayList(u8).initCapacity(allocator, 0);
        defer result.deinit(allocator);

        var i: usize = 0;
        while (i < replacement.len) {
            if (replacement[i] == '$' and i + 1 < replacement.len) {
                const next_char = replacement[i + 1];

                // Check for $$  (escaped dollar sign)
                if (next_char == '$') {
                    try result.append(allocator, '$');
                    i += 2;
                    continue;
                }

                // Check for $0-$9
                if (next_char >= '0' and next_char <= '9') {
                    const capture_index = next_char - '0';

                    // $0 is the entire match, $1 is first capture (index 0 in captures array)
                    if (capture_index == 0) {
                        try result.appendSlice(allocator, full_match);
                    } else if (capture_index - 1 < captures.len) {
                        const capture = captures[capture_index - 1];
                        try result.appendSlice(allocator, capture);
                    } else {
                        // Invalid capture index, keep literal
                        try result.append(allocator, '$');
                        try result.append(allocator, next_char);
                    }
                    i += 2;
                    continue;
                }
            }

            try result.append(allocator, replacement[i]);
            i += 1;
        }

        return result.toOwnedSlice(allocator);
    }

    /// Replace the first match with the replacement string (supports backreferences $1, $2, etc.)
    pub fn replace(self: *const Regex, allocator: std.mem.Allocator, input: []const u8, replacement: []const u8) ![]u8 {
        if (try self.find(input)) |match_result| {
            defer {
                var mut_match = match_result;
                mut_match.deinit(self.allocator);
            }

            // Expand replacement with backreferences
            const expanded_replacement = try expandReplacement(allocator, replacement, match_result.captures, match_result.slice);
            defer allocator.free(expanded_replacement);

            // Build result: before + replacement + after
            const before = input[0..match_result.start];
            const after = input[match_result.end..];

            const total_len = before.len + expanded_replacement.len + after.len;
            var result = try allocator.alloc(u8, total_len);

            @memcpy(result[0..before.len], before);
            @memcpy(result[before.len .. before.len + expanded_replacement.len], expanded_replacement);
            @memcpy(result[before.len + expanded_replacement.len ..], after);

            return result;
        }

        // No match, return copy of input
        return allocator.dupe(u8, input);
    }

    /// Replace all matches with the replacement string
    pub fn replaceAll(self: *const Regex, allocator: std.mem.Allocator, input: []const u8, replacement: []const u8) ![]u8 {
        const matches = try self.findAll(allocator, input);
        defer {
            for (matches) |*match_result| {
                var mut_match = match_result;
                mut_match.deinit(allocator);
            }
            allocator.free(matches);
        }

        if (matches.len == 0) {
            return allocator.dupe(u8, input);
        }

        // Expand each replacement with its respective captures
        var expanded_replacements = try allocator.alloc([]u8, matches.len);
        defer {
            for (expanded_replacements) |repl| {
                allocator.free(repl);
            }
            allocator.free(expanded_replacements);
        }

        // Calculate result size
        var result_len: usize = input.len;
        for (matches, 0..) |match_result, i| {
            expanded_replacements[i] = try expandReplacement(allocator, replacement, match_result.captures, match_result.slice);
            result_len = result_len - (match_result.end - match_result.start) + expanded_replacements[i].len;
        }

        var result = try allocator.alloc(u8, result_len);
        var result_pos: usize = 0;
        var input_pos: usize = 0;

        for (matches, 0..) |match_result, i| {
            // Copy text before match
            const before = input[input_pos..match_result.start];
            @memcpy(result[result_pos .. result_pos + before.len], before);
            result_pos += before.len;

            // Copy expanded replacement
            const expanded = expanded_replacements[i];
            @memcpy(result[result_pos .. result_pos + expanded.len], expanded);
            result_pos += expanded.len;

            input_pos = match_result.end;
        }

        // Copy remaining text after last match
        const remaining = input[input_pos..];
        @memcpy(result[result_pos .. result_pos + remaining.len], remaining);

        return result;
    }

    /// Iterator for lazy matching - yields matches one at a time
    pub const MatchIterator = struct {
        regex: *const Regex,
        input: []const u8,
        pos: usize,
        done: bool,

        pub fn init(regex: *const Regex, input: []const u8) MatchIterator {
            return .{
                .regex = regex,
                .input = input,
                .pos = 0,
                .done = false,
            };
        }

        /// Get the next match, or null if no more matches
        pub fn next(self: *MatchIterator, allocator: std.mem.Allocator) !?Match {
            if (self.done) return null;

            while (self.pos <= self.input.len) {
                switch (self.regex.engine_type) {
                    .thompson_nfa => {
                        const nfa_mut = @constCast(&self.regex.nfa);
                        var virtual_machine = vm.VM.init(
                            allocator,
                            nfa_mut,
                            self.regex.capture_count,
                            self.regex.flags,
                        );
                        defer virtual_machine.deinit();

                        if (try virtual_machine.matchAt(self.input, self.pos)) |result| {
                            const adjusted_start = result.start;
                            const adjusted_end = result.end;

                            // Convert vm.Capture to []const u8
                            var captures_list = try std.ArrayList([]const u8).initCapacity(allocator, result.captures.len);
                            errdefer captures_list.deinit(allocator);

                            for (result.captures) |cap| {
                                try captures_list.append(allocator, cap.text);
                            }

                            const captures = try captures_list.toOwnedSlice(allocator);

                            // Free the VM result
                            allocator.free(result.captures);

                            const match_result = Match{
                                .slice = self.input[adjusted_start..adjusted_end],
                                .start = adjusted_start,
                                .end = adjusted_end,
                                .captures = captures,
                            };

                            // Move past this match (avoid infinite loop on zero-width matches)
                            self.pos = if (adjusted_end > adjusted_start) adjusted_end else adjusted_end + 1;

                            return match_result;
                        }
                    },
                    .backtracking => {
                        const engine_mut = @constCast(&self.regex.backtrack_engine.?);

                        // Try matching at current position
                        engine_mut.resetCaptures();
                        if (engine_mut.matchNode(engine_mut.ast_root, self.pos)) |end_pos| {
                            if (end_pos > self.pos or (end_pos == self.pos and engine_mut.canMatchEmpty(engine_mut.ast_root))) {
                                // Build match result
                                var captures_list = try std.ArrayList([]const u8).initCapacity(allocator, engine_mut.captures.len);
                                errdefer captures_list.deinit(allocator);

                                for (engine_mut.captures) |cap| {
                                    if (cap.matched) {
                                        try captures_list.append(allocator, self.input[cap.start..cap.end]);
                                    } else {
                                        try captures_list.append(allocator, "");
                                    }
                                }

                                const captures = try captures_list.toOwnedSlice(allocator);

                                const match_result = Match{
                                    .slice = self.input[self.pos..end_pos],
                                    .start = self.pos,
                                    .end = end_pos,
                                    .captures = captures,
                                };

                                // Move past this match
                                self.pos = if (end_pos > self.pos) end_pos else end_pos + 1;

                                return match_result;
                            }
                        }
                    },
                }

                self.pos += 1;
            }

            self.done = true;
            return null;
        }

        /// Reset the iterator to the beginning
        pub fn reset(self: *MatchIterator) void {
            self.pos = 0;
            self.done = false;
        }
    };

    /// Create an iterator for lazy matching
    pub fn iterator(self: *const Regex, input: []const u8) MatchIterator {
        return MatchIterator.init(self, input);
    }

    /// Split the input string by the pattern
    pub fn split(self: *const Regex, allocator: std.mem.Allocator, input: []const u8) ![][]const u8 {
        const matches = try self.findAll(allocator, input);
        defer {
            for (matches) |*match_result| {
                var mut_match = match_result;
                mut_match.deinit(allocator);
            }
            allocator.free(matches);
        }

        var parts: std.ArrayList([]const u8) = .empty;
        errdefer parts.deinit(allocator);

        var pos: usize = 0;
        for (matches) |match_result| {
            try parts.append(allocator, input[pos..match_result.start]);
            pos = match_result.end;
        }

        // Add remaining part
        try parts.append(allocator, input[pos..]);

        return parts.toOwnedSlice(allocator);
    }
};

/// Helper function to detect if AST requires backtracking engine
/// Append the literal/anchor leaves of a concatenation spine to `out`, in
/// order. Returns false if any node isn't a literal, anchor, concat, or empty —
/// i.e. the pattern isn't a plain literal wrapped in zero-width assertions.
fn flattenBoundedLeaves(node: *ast.Node, out: *std.ArrayList(*ast.Node), allocator: std.mem.Allocator) bool {
    switch (node.node_type) {
        .concat => return flattenBoundedLeaves(node.data.concat.left, out, allocator) and
            flattenBoundedLeaves(node.data.concat.right, out, allocator),
        .literal, .anchor => {
            out.append(allocator, node) catch return false;
            return true;
        },
        .empty => return true,
        else => return false,
    }
}

/// Detect a `\bfn\b`-style pattern: a fixed literal (>= 2 bytes, for
/// selectivity) wrapped only in zero-width assertions, with the assertions
/// partitioned into those before the literal and those after it. Returns an
/// owned descriptor or null. Disabled under `i` (the SIMD literal scan is
/// case-sensitive).
fn detectBoundedLiteral(allocator: std.mem.Allocator, root: *ast.Node, flags: common.CompileFlags) !?Regex.BoundedLiteral {
    if (flags.case_insensitive) return null;

    var leaves: std.ArrayList(*ast.Node) = .empty;
    defer leaves.deinit(allocator);
    if (!flattenBoundedLeaves(root, &leaves, allocator)) return null;

    var bl: Regex.BoundedLiteral = .{ .literal = &.{} };
    var lit: std.ArrayList(u8) = .empty;
    defer lit.deinit(allocator);
    var phase: u8 = 0; // 0 = before literal, 1 = in literal, 2 = after literal

    for (leaves.items) |n| {
        switch (n.node_type) {
            .anchor => {
                if (phase == 1) phase = 2;
                if (phase == 0) {
                    if (bl.pre_len >= bl.pre.len) return null;
                    bl.pre[bl.pre_len] = n.data.anchor;
                    bl.pre_len += 1;
                } else {
                    if (bl.post_len >= bl.post.len) return null;
                    bl.post[bl.post_len] = n.data.anchor;
                    bl.post_len += 1;
                }
            },
            .literal => {
                if (phase == 2) return null; // a second literal run after anchors
                phase = 1;
                try lit.append(allocator, n.data.literal);
            },
            else => return null,
        }
    }
    if (lit.items.len < 2) {
        return null;
    }
    bl.literal = try lit.toOwnedSlice(allocator);
    return bl;
}

fn requiresBacktracking(node: *ast.Node, flags: common.CompileFlags) bool {
    switch (node.node_type) {
        // These features require backtracking
        .lookahead, .lookbehind, .backref, .unicode_property => return true,

        // A `class_set` (`\s`, `\S`, `/v` Unicode brackets) lowers to a UTF-8
        // byte automaton when it's a union of code-point ranges — including under
        // plain `i`, where the compiler ASCII-case-folds the ranges. But `u`+`i`
        // needs *Unicode* simple case folds (e.g. U+0390↔U+1FD3), which only the
        // backtracker does; and unrepresentable shapes (Unicode properties,
        // multi-code-point strings, intersection/difference) also need it.
        .class_set => return (flags.case_insensitive and flags.unicode) or
            !@import("utf8_class.zig").compilable(node.data.class_set),

        // Check for lazy quantifiers
        .star, .plus, .optional => {
            const greedy = switch (node.node_type) {
                .star => node.data.star.greedy,
                .plus => node.data.plus.greedy,
                .optional => node.data.optional.greedy,
                else => unreachable,
            };
            if (!greedy) return true; // Lazy quantifiers need backtracking

            // Recursively check child
            const child = switch (node.node_type) {
                .star => node.data.star.child,
                .plus => node.data.plus.child,
                .optional => node.data.optional.child,
                else => unreachable,
            };
            if (containsAlternation(child)) return true;
            return requiresBacktracking(child, flags);
        },
        .repeat => {
            if (!node.data.repeat.greedy) return true;
            if (node.data.repeat.bounds.min > MAX_NFA_REPEAT_EXPANSION) return true;
            if (node.data.repeat.bounds.max) |max| {
                if (max > MAX_NFA_REPEAT_EXPANSION) return true;
            }
            if (containsAlternation(node.data.repeat.child)) return true;
            return requiresBacktracking(node.data.repeat.child, flags);
        },

        // Recursively check compound nodes
        .concat => {
            return requiresBacktracking(node.data.concat.left, flags) or
                requiresBacktracking(node.data.concat.right, flags);
        },
        .alternation => {
            if (containsCapture(node)) return true;
            return requiresBacktracking(node.data.alternation.left, flags) or
                requiresBacktracking(node.data.alternation.right, flags);
        },
        // A group carrying inline modifiers `(?i:...)` adjusts flags per-scope,
        // which only the backtracking engine honors.
        .group => return node.data.group.mod != null or requiresBacktracking(node.data.group.child, flags),

        // `.` lowers to a UTF-8 code-point automaton (compiler.compileAny):
        // one code point excluding line terminators (and astral unless the `u`
        // flag) — representable on the byte engine, so no backtracking needed.
        .any => return false,

        // These don't require backtracking
        .literal, .char_class, .anchor, .empty => return false,
    }
}

fn containsAlternation(node: *ast.Node) bool {
    return switch (node.node_type) {
        .alternation => true,
        .concat => containsAlternation(node.data.concat.left) or containsAlternation(node.data.concat.right),
        .star => containsAlternation(node.data.star.child),
        .plus => containsAlternation(node.data.plus.child),
        .optional => containsAlternation(node.data.optional.child),
        .repeat => containsAlternation(node.data.repeat.child),
        .group => containsAlternation(node.data.group.child),
        .lookahead => containsAlternation(node.data.lookahead.child),
        .lookbehind => containsAlternation(node.data.lookbehind.child),
        else => false,
    };
}

const ByteSet = [256]bool;

fn anyByteSet(flags: common.CompileFlags) ByteSet {
    var set: ByteSet = undefined;
    var b: usize = 0;
    while (b < 256) : (b += 1) set[b] = if (flags.dot_all) true else b != '\n';
    return set;
}

fn foldByteSetCI(set: ByteSet) ByteSet {
    var folded = set;
    var b: usize = 0;
    while (b < 256) : (b += 1) {
        if (!set[b]) continue;
        folded[std.ascii.toLower(@intCast(b))] = true;
        folded[std.ascii.toUpper(@intCast(b))] = true;
    }
    return folded;
}

fn literalByteSet(c: u8, flags: common.CompileFlags) ByteSet {
    var set: ByteSet = undefined;
    @memset(&set, false);
    set[c] = true;
    return if (flags.case_insensitive) foldByteSetCI(set) else set;
}

fn charClassByteSet(cc: common.CharClass, flags: common.CompileFlags) ByteSet {
    var set: ByteSet = undefined;
    var b: usize = 0;
    while (b < 256) : (b += 1) {
        set[b] = if (flags.case_insensitive) cc.matchesCI(@intCast(b)) else cc.matches(@intCast(b));
    }
    return set;
}

fn unionByteSet(a: ByteSet, b: ByteSet) ByteSet {
    var out = a;
    for (&out, b) |*slot, rhs| slot.* = slot.* or rhs;
    return out;
}

fn byteSetsOverlap(a: ByteSet, b: ByteSet) bool {
    for (a, b) |x, y| if (x and y) return true;
    return false;
}

fn canMatchEmpty(node: *ast.Node) bool {
    return switch (node.node_type) {
        .empty, .anchor, .lookahead, .lookbehind => true,
        .literal, .any, .char_class, .backref, .unicode_property, .class_set => false,
        .star, .optional => true,
        .plus => canMatchEmpty(node.data.plus.child),
        .repeat => node.data.repeat.bounds.min == 0 or canMatchEmpty(node.data.repeat.child),
        .group => canMatchEmpty(node.data.group.child),
        .concat => canMatchEmpty(node.data.concat.left) and canMatchEmpty(node.data.concat.right),
        .alternation => canMatchEmpty(node.data.alternation.left) or canMatchEmpty(node.data.alternation.right),
    };
}

fn firstByteSet(node: *ast.Node, flags: common.CompileFlags) ?ByteSet {
    return switch (node.node_type) {
        .literal => literalByteSet(node.data.literal, flags),
        .any => anyByteSet(flags),
        .char_class => charClassByteSet(node.data.char_class, flags),
        .group => firstByteSet(node.data.group.child, flags),
        .star => firstByteSet(node.data.star.child, flags),
        .plus => firstByteSet(node.data.plus.child, flags),
        .optional => firstByteSet(node.data.optional.child, flags),
        .repeat => if (node.data.repeat.bounds.max == 0) null else firstByteSet(node.data.repeat.child, flags),
        .concat => blk: {
            const left = firstByteSet(node.data.concat.left, flags);
            if (!canMatchEmpty(node.data.concat.left)) break :blk left;
            const right = firstByteSet(node.data.concat.right, flags);
            if (left) |l| {
                if (right) |r| break :blk unionByteSet(l, r);
                break :blk l;
            }
            break :blk right;
        },
        .alternation => blk: {
            const left = firstByteSet(node.data.alternation.left, flags);
            const right = firstByteSet(node.data.alternation.right, flags);
            if (left) |l| {
                if (right) |r| break :blk unionByteSet(l, r);
                break :blk l;
            }
            break :blk right;
        },
        .empty, .anchor, .lookahead, .lookbehind => null,
        .backref, .unicode_property, .class_set => null,
    };
}

fn variableQuantifierTailBytes(node: *ast.Node, flags: common.CompileFlags) ?ByteSet {
    switch (node.node_type) {
        .star => return firstByteSet(node.data.star.child, flags),
        .plus => return firstByteSet(node.data.plus.child, flags),
        .optional => return firstByteSet(node.data.optional.child, flags),
        .repeat => {
            const r = node.data.repeat;
            const variable = r.bounds.max == null or r.bounds.max.? != r.bounds.min;
            return if (variable) firstByteSet(r.child, flags) else null;
        },
        .group => return variableQuantifierTailBytes(node.data.group.child, flags),
        .concat => {
            if (variableQuantifierTailBytes(node.data.concat.right, flags)) |set| return set;
            if (canMatchEmpty(node.data.concat.right))
                return variableQuantifierTailBytes(node.data.concat.left, flags);
            return null;
        },
        else => return null,
    }
}

fn containsCapture(node: *ast.Node) bool {
    return switch (node.node_type) {
        .group => node.data.group.capture_index != null or containsCapture(node.data.group.child),
        .concat => containsCapture(node.data.concat.left) or containsCapture(node.data.concat.right),
        .alternation => containsCapture(node.data.alternation.left) or containsCapture(node.data.alternation.right),
        .star => containsCapture(node.data.star.child),
        .plus => containsCapture(node.data.plus.child),
        .optional => containsCapture(node.data.optional.child),
        .repeat => containsCapture(node.data.repeat.child),
        .lookahead => containsCapture(node.data.lookahead.child),
        .lookbehind => containsCapture(node.data.lookbehind.child),
        else => false,
    };
}

fn capturedVariableTailBytes(node: *ast.Node, flags: common.CompileFlags) ?ByteSet {
    switch (node.node_type) {
        .group => {
            if (node.data.group.capture_index != null)
                return variableQuantifierTailBytes(node.data.group.child, flags);
            return capturedVariableTailBytes(node.data.group.child, flags);
        },
        .optional => {
            const child = node.data.optional.child;
            if (containsCapture(child)) return variableQuantifierTailBytes(node, flags);
            return capturedVariableTailBytes(child, flags);
        },
        .repeat => {
            const child = node.data.repeat.child;
            const variable = node.data.repeat.bounds.max == null or
                node.data.repeat.bounds.max.? != node.data.repeat.bounds.min;
            const optional_like = node.data.repeat.bounds.min == 0 and
                node.data.repeat.bounds.max != null and
                node.data.repeat.bounds.max.? == 1;
            if (variable and optional_like and containsCapture(child)) return variableQuantifierTailBytes(node, flags);
            return capturedVariableTailBytes(child, flags);
        },
        .concat => {
            if (capturedVariableTailBytes(node.data.concat.right, flags)) |set| return set;
            if (canMatchEmpty(node.data.concat.right))
                return capturedVariableTailBytes(node.data.concat.left, flags);
            return null;
        },
        else => return null,
    }
}

fn hasAmbiguousCaptureBoundary(node: *ast.Node, flags: common.CompileFlags) bool {
    switch (node.node_type) {
        .concat => {
            const c = node.data.concat;
            if (capturedVariableTailBytes(c.left, flags)) |tail| {
                if (firstByteSet(c.right, flags)) |first| {
                    if (byteSetsOverlap(tail, first)) return true;
                } else if (!canMatchEmpty(c.right)) {
                    return true;
                }
            }
            return hasAmbiguousCaptureBoundary(c.left, flags) or
                hasAmbiguousCaptureBoundary(c.right, flags);
        },
        .group => return hasAmbiguousCaptureBoundary(node.data.group.child, flags),
        .alternation => return hasAmbiguousCaptureBoundary(node.data.alternation.left, flags) or
            hasAmbiguousCaptureBoundary(node.data.alternation.right, flags),
        .star => return hasAmbiguousCaptureBoundary(node.data.star.child, flags),
        .plus => return hasAmbiguousCaptureBoundary(node.data.plus.child, flags),
        .optional => return hasAmbiguousCaptureBoundary(node.data.optional.child, flags),
        .repeat => return hasAmbiguousCaptureBoundary(node.data.repeat.child, flags),
        .lookahead => return hasAmbiguousCaptureBoundary(node.data.lookahead.child, flags),
        .lookbehind => return hasAmbiguousCaptureBoundary(node.data.lookbehind.child, flags),
        else => return false,
    }
}

fn deinitNamedCaptureMap(allocator: std.mem.Allocator, map: *std.StringHashMap(usize)) void {
    var it = map.iterator();
    while (it.next()) |entry| allocator.free(entry.key_ptr.*);
    map.deinit();
}

fn deinitNamedCaptureList(allocator: std.mem.Allocator, list: *std.ArrayList(NamedCapture)) void {
    for (list.items) |entry| allocator.free(entry.name);
    list.deinit(allocator);
}

/// Helper function to recursively collect named captures from AST.
/// The map stores the first index for compatibility; the list stores every
/// occurrence in source order for ECMAScript duplicate-name alternatives.
fn collectNamedCaptures(
    allocator: std.mem.Allocator,
    node: *ast.Node,
    map: *std.StringHashMap(usize),
    list: *std.ArrayList(NamedCapture),
) !void {
    switch (node.node_type) {
        .group => {
            const group = node.data.group;
            if (group.name) |name| {
                if (group.capture_index) |index| {
                    if (!map.contains(name)) {
                        const key = try allocator.dupe(u8, name);
                        errdefer allocator.free(key);
                        try map.put(key, index);
                    }
                    const entry_name = try allocator.dupe(u8, name);
                    errdefer allocator.free(entry_name);
                    try list.append(allocator, .{ .name = entry_name, .index = index });
                }
            }
            try collectNamedCaptures(allocator, group.child, map, list);
        },
        .concat => {
            try collectNamedCaptures(allocator, node.data.concat.left, map, list);
            try collectNamedCaptures(allocator, node.data.concat.right, map, list);
        },
        .alternation => {
            try collectNamedCaptures(allocator, node.data.alternation.left, map, list);
            try collectNamedCaptures(allocator, node.data.alternation.right, map, list);
        },
        .star => try collectNamedCaptures(allocator, node.data.star.child, map, list),
        .plus => try collectNamedCaptures(allocator, node.data.plus.child, map, list),
        .optional => try collectNamedCaptures(allocator, node.data.optional.child, map, list),
        .repeat => try collectNamedCaptures(allocator, node.data.repeat.child, map, list),
        .lookahead, .lookbehind => {
            const child = switch (node.node_type) {
                .lookahead => node.data.lookahead.child,
                .lookbehind => node.data.lookbehind.child,
                else => unreachable,
            };
            try collectNamedCaptures(allocator, child, map, list);
        },
        else => {}, // Literals, character classes, anchors, backreferences don't contain groups
    }
}

test "compile empty pattern" {
    const allocator = std.testing.allocator;
    const result = Regex.compile(allocator, "");
    try std.testing.expectError(RegexError.EmptyPattern, result);
}

test "compile basic pattern" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "test");
    defer regex.deinit();
    try std.testing.expectEqualStrings("test", regex.pattern);
}

test "match literal" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "hello");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("hello"));
    try std.testing.expect(!try regex.isMatch("world"));
}

test "find literal" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "world");
    defer regex.deinit();

    if (try regex.find("hello world")) |match_result| {
        var mut_match = match_result;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("world", match_result.slice);
        try std.testing.expectEqual(@as(usize, 6), match_result.start);
        try std.testing.expectEqual(@as(usize, 11), match_result.end);
    } else {
        try std.testing.expect(false); // Should have found a match
    }
}

test "alternation" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "cat|dog");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("cat"));
    try std.testing.expect(try regex.isMatch("dog"));
    try std.testing.expect(!try regex.isMatch("bird"));
}

test "star quantifier" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a*");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch(""));
    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("aaa"));
}

test "plus quantifier" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a+");
    defer regex.deinit();

    try std.testing.expect(!try regex.isMatch(""));
    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("aaa"));
}

test "optional quantifier" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a?");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch(""));
    try std.testing.expect(try regex.isMatch("a"));
}

test "dot wildcard" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a.c");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(try regex.isMatch("axc"));
    try std.testing.expect(!try regex.isMatch("ac"));
}

test "character class \\d" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\d+");
    defer regex.deinit();

    if (try regex.find("abc123def")) |match_result| {
        var mut_match = match_result;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("123", match_result.slice);
    } else {
        try std.testing.expect(false);
    }
}

test "replace" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "world");
    defer regex.deinit();

    const result = try regex.replace(allocator, "hello world", "Zig");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("hello Zig", result);
}

test "replace all" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a");
    defer regex.deinit();

    const result = try regex.replaceAll(allocator, "banana", "o");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("bonono", result);
}

test "split" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, ",");
    defer regex.deinit();

    const parts = try regex.split(allocator, "a,b,c");
    defer allocator.free(parts);

    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualStrings("a", parts[0]);
    try std.testing.expectEqualStrings("b", parts[1]);
    try std.testing.expectEqualStrings("c", parts[2]);
}

test "compile rejects dangerous nested quantifiers" {
    const allocator = std.testing.allocator;

    // This pattern should be rejected as critical risk
    const result = Regex.compile(allocator, "(a+)+");
    try std.testing.expectError(RegexError.PatternTooComplex, result);
}

test "compile rejects nested stars" {
    const allocator = std.testing.allocator;

    // This pattern should be rejected
    const result = Regex.compile(allocator, "(a*)*");
    try std.testing.expectError(RegexError.PatternTooComplex, result);
}

test "compile accepts safe complex patterns" {
    const allocator = std.testing.allocator;

    // This pattern should be accepted (medium risk is OK)
    var regex = try Regex.compile(allocator, "a+b*c?d{2,5}");
    defer regex.deinit();
}

test "out-of-order ASCII character-class range is rejected" {
    const allocator = std.testing.allocator;
    // start code point > end code point (e.g. 'd' > 'G', 'z' > 'a') is a SyntaxError.
    try std.testing.expectError(RegexError.InvalidCharacterClass, Regex.compile(allocator, "[d-G]"));
    try std.testing.expectError(RegexError.InvalidCharacterClass, Regex.compile(allocator, "[z-a]"));
    try std.testing.expectError(RegexError.InvalidCharacterClass, Regex.compile(allocator, "[\\nd-G]"));
    // Valid ranges (ascending, single-point) still compile.
    inline for (.{ "[a-z]", "[0-9]", "[a-a]", "[A-Za-z0-9_]", "[a-]" }) |pat| {
        var ok = try Regex.compile(allocator, pat);
        ok.deinit();
    }
    // A multibyte (\u) range must NOT be falsely flagged by the byte-based check.
    var mb = try Regex.compile(allocator, "[\\u2000-\\u200A]");
    defer mb.deinit();
    try std.testing.expect(try mb.isMatch("\u{2005}"));
}

test "unicode surrogate escapes compile to WTF-8 code units" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\uDF06");
    defer regex.deinit();
    try std.testing.expect(try regex.isMatch(&.{ 0xED, 0xBC, 0x86 }));
}

test "capture spans give per-group byte offsets" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\d+)-(\\d+)");
    defer regex.deinit();
    if (try regex.find("ab12-345cd")) |match_result| {
        var m = match_result;
        defer m.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 2), m.capture_spans.len);
        // "12" at [2,4), "345" at [5,8)
        try std.testing.expectEqual([2]usize{ 2, 4 }, m.capture_spans[0]);
        try std.testing.expectEqual([2]usize{ 5, 8 }, m.capture_spans[1]);
        try std.testing.expect(m.captures_present[0] and m.captures_present[1]);
    } else try std.testing.expect(false);
}

test "capture spans: an unmatched optional group is marked absent" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(a)|(b)");
    defer regex.deinit();
    if (try regex.find("b")) |match_result| {
        var m = match_result;
        defer m.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 2), m.capture_spans.len);
        try std.testing.expect(!m.captures_present[0]); // (a) did not participate
        try std.testing.expect(m.captures_present[1]); // (b) matched
        try std.testing.expectEqual([2]usize{ 0, 1 }, m.capture_spans[1]);
    } else try std.testing.expect(false);
}

test "variable-length lookbehind explores backtracking (constrained match)" {
    const allocator = std.testing.allocator;
    // `\w*` greedily overshoots the lookbehind point, but a shorter match ends
    // there — the constrained matcher must find it.
    var re = try Regex.compile(allocator, "(?<=\\w*)[^a-c]{3}");
    defer re.deinit();
    if (try re.find("abcdef")) |mr| {
        var m = mr;
        defer m.deinit(allocator);
        try std.testing.expectEqualStrings("def", m.slice);
    } else try std.testing.expect(false);
    // A fixed-length positive lookbehind with a capture still matches + captures.
    var re2 = try Regex.compile(allocator, "(?<=(c))def");
    defer re2.deinit();
    try std.testing.expect(try re2.isMatch("abcdef"));
    // Negative lookbehind: `(?<!ab)c` must reject "c" preceded by "ab".
    var re3 = try Regex.compile(allocator, "(?<!ab)c");
    defer re3.deinit();
    try std.testing.expect(!(try re3.isMatch("abc")));
    try std.testing.expect(try re3.isMatch("xbc")); // not preceded by "ab"
}

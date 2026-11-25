const std = @import("std");
const RegexError = @import("errors.zig").RegexError;
const CompileErrorReason = @import("errors.zig").CompileErrorReason;
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
const factors = @import("factors.zig");

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

/// Parse `pattern` under `flags` into the tree `Regex.compileWithFlags`
/// compiles. The caller owns the tree (`deinit`).
pub fn parseTree(allocator: std.mem.Allocator, pattern: []const u8, flags: common.CompileFlags, diagnostic: ?*?CompileErrorReason) !ast.AST {
    // Byte mode has no code points, so the flags defined over them conflict.
    if (flags.bytes and (flags.unicode or flags.unicode_sets or flags.ecmascript))
        return RegexError.UnsupportedInBytesMode;
    var p = try parser.Parser.initWithDiagnostic(allocator, pattern, diagnostic);
    p.bytes = flags.bytes;
    p.unicode_sets = flags.unicode_sets;
    p.unicode = flags.unicode;
    p.case_insensitive = flags.case_insensitive;
    p.ecmascript = flags.ecmascript;
    // The `x`, `u`, `v` and byte-mode flags affect lexing from the first
    // token, so enable them on the lexer and re-lex the first token.
    if (flags.extended or flags.unicode or flags.unicode_sets or flags.bytes) {
        p.extended = flags.extended;
        p.lexer.extended = flags.extended;
        p.lexer.bytes = flags.bytes;
        p.lexer.unicode_strict = flags.unicode or flags.unicode_sets;
        p.lexer.reset();
        p.current_token = try p.lexer.next();
    }
    return p.parse();
}

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

    /// Search DFAs `isMatch` keeps warm between calls (see `SearchDfaPool`).
    /// Null for a pattern `isMatch` never runs on the lazy DFA.
    search_dfa_pool: ?*SearchDfaPool = null,

    /// A few unanchored search DFAs that `isMatch` returns after a call and
    /// takes again on the next, so the states it built stay built. Without it
    /// every call determinises from scratch, which on a large alternation costs
    /// far more than the search (CRS's keyword lists: milliseconds a call,
    /// against microseconds with the states kept).
    ///
    /// Each slot holds one DFA or nothing and is claimed with an atomic swap,
    /// so a shared `Regex` stays safe: a thread that finds every slot empty
    /// builds its own DFA, as before, and a returned DFA that finds every slot
    /// full is freed. A DFA is only kept while it is small (`retain_states`),
    /// so input that drives a pattern towards the DFA's state cap cannot leave
    /// that memory held after the call.
    pub const SearchDfaPool = struct {
        slots: [slot_count]std.atomic.Value(?*dfa.LazyDfa) = @splat(.init(null)),

        pub const slot_count = 4;
        /// About 1.3 KiB of transition table per state.
        pub const retain_states = 256;

        fn take(pool: *SearchDfaPool) ?*dfa.LazyDfa {
            for (&pool.slots) |*slot| if (slot.swap(null, .acquire)) |d| return d;
            return null;
        }

        /// Keep `d` for the next call, or report that it was not kept.
        fn give(pool: *SearchDfaPool, d: *dfa.LazyDfa) bool {
            if (d.overflow or d.stateCount() > retain_states) return false;
            for (&pool.slots) |*slot| if (slot.cmpxchgStrong(null, d, .release, .monotonic) == null) return true;
            return false;
        }

        fn destroy(pool: *SearchDfaPool, allocator: std.mem.Allocator) void {
            for (&pool.slots) |*slot| if (slot.swap(null, .acquire)) |d| {
                d.deinit();
                allocator.destroy(d);
            };
            allocator.destroy(pool);
        }
    };

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
        return compileWithFlagsInner(allocator, pattern, flags, null, true);
    }

    /// Compile `pattern` with every group treated as non-capturing: matches
    /// report spans only and `Match.captures` is empty. A pattern that needs
    /// the backtracker only to order its captures, such as an alternation of
    /// capture groups (`(etc/(passwd|shadow)|win\.ini)`), then stays on the
    /// linear Thompson engines. `Program.compile` compiles this way. A
    /// pattern with a backreference keeps its groups, which the reference
    /// needs, and compiles exactly as `compileWithFlags` would.
    pub fn compileWithoutCaptures(allocator: std.mem.Allocator, pattern: []const u8, flags: common.CompileFlags) !Regex {
        return compileWithFlagsInner(allocator, pattern, flags, null, false);
    }

    /// Compile while retaining the precise parse reason on failure. The
    /// ordinary error return remains source-compatible with `compileWithFlags`.
    pub fn compileWithFlagsDiagnostic(allocator: std.mem.Allocator, pattern: []const u8, flags: common.CompileFlags, diagnostic: *?CompileErrorReason) !Regex {
        diagnostic.* = null;
        return compileWithFlagsInner(allocator, pattern, flags, diagnostic, true);
    }

    fn compileWithFlagsInner(allocator: std.mem.Allocator, pattern: []const u8, flags: common.CompileFlags, diagnostic: ?*?CompileErrorReason, captures: bool) !Regex {
        var tree = try parseTree(allocator, pattern, flags, diagnostic);
        errdefer tree.deinit(); // Free AST if compilation fails
        if (!captures and tree.capture_count > 0 and try dropCaptures(allocator, tree.root))
            tree.capture_count = 0;

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
        // A capture-free compile for a `Program` reports spans only, with the Thompson
        // engine's leftmost-longest ends. Alternation order and lazy edges decide which of
        // several matches a backtracker reports, never whether one exists or where the
        // leftmost one starts, so they are no reason to leave the Thompson route here.
        const span_only = !captures;
        const ordered_captures = span_only or (flags.ecmascript and
            (tree.capture_count == 0 or hasSingleEntryCaptures(tree.root, false) or
                (tree.capture_count == 1 and hasSpanningAssertionCapture(tree.root))));
        // Inline modifiers (`(?i)`, `(?s:..)`, `(?-i:..)`, `(?m:..)`) only
        // change which bytes an atom accepts and what `^`/`$` mean where they
        // sit, which a byte-mode automaton can encode directly (see
        // `Compiler.initScopedModes`), so a capture-free byte-mode compile
        // keeps them on the Thompson route (#51). `Regex.compile` keeps them on
        // the backtracker, which honours them per scope too.
        const scoped_modes = span_only and flags.bytes and !flags.ecmascript and hasInlineModifier(tree.root);
        var needs_backtracking = requiresBacktracking(tree.root, flags, ordered_captures, scoped_modes);
        if (!needs_backtracking and tree.capture_count > 0) {
            onepass_plan = try onepass.build(allocator, tree.root, tree.capture_count, flags);
            if (onepass_plan == null and hasAmbiguousCaptureBoundary(tree.root, flags))
                needs_backtracking = true;
        }
        errdefer if (onepass_plan) |pl| pl.deinit();

        // SECURITY: reject patterns whose analysis is critical (nested
        // quantifiers and the like); medium and high risk patterns are allowed
        // and bounded by the backtracker's step counter. The danger is
        // exponential backtracking, which only the backtracking engine can do:
        // the Thompson engines (VM, lazy DFA, one-pass) run in time linear in the
        // input whatever the pattern, and the compiler caps their size
        // (`compiler.max_nfa_states`). So an ECMAScript pattern bound for them is
        // not refused -- /(a*)*/ is valid JavaScript -- while other dialects keep
        // refusing critical patterns on every engine.
        if ((!flags.ecmascript and !span_only) or needs_backtracking) {
            const pattern_analyzer = @import("pattern_analyzer.zig");
            try pattern_analyzer.analyzeAndValidate(allocator, tree.root, .high);
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
            // `\bfn\b`-style bounded literal (computed from the AST before it is
            // freed). Captures disable it (the fast path returns no groups).
            const bounded_literal = if (tree.capture_count == 0 and !scoped_modes)
                try detectBoundedLiteral(allocator, tree.root, flags)
            else
                null;
            errdefer if (bounded_literal) |bl| allocator.free(bl.literal);

            if (scoped_modes) {
                // The AST-derived hints read literals, `.` and anchors without
                // their modifiers; keep only those that do not depend on them.
                const lengths = .{ opt_info.min_length, opt_info.max_length, opt_info.has_lazy };
                opt_info.deinit(allocator);
                opt_info = .{ .has_assertions = true };
                opt_info.min_length, opt_info.max_length, opt_info.has_lazy = lengths;
            }
            var comp = if (scoped_modes)
                compiler.Compiler.initScopedModes(allocator, flags)
            else
                compiler.Compiler.initWithFlags(allocator, flags);
            errdefer comp.deinit();
            _ = try comp.compile(&tree);

            // Only a pattern isMatch runs on the lazy DFA needs the pool.
            const search_dfa_pool: ?*SearchDfaPool = if (comp.nfa.has_literal_assertions) null else blk: {
                const pool = try allocator.create(SearchDfaPool);
                pool.* = .{};
                break :blk pool;
            };
            errdefer if (search_dfa_pool) |pool| allocator.destroy(pool);

            const capture_count = tree.capture_count;
            const owned_named_capture_list = try named_capture_list.toOwnedSlice(allocator);
            tree.deinit();

            return Regex{
                .allocator = allocator,
                .pattern = owned_pattern,
                .nfa = comp.nfa,
                .backtrack_engine = null,
                .ast_tree = null,
                .engine_type = .thompson_nfa,
                .capture_count = capture_count,
                .flags = if (scoped_modes) compiler.Compiler.scopedModesFlags(flags) else flags,
                .opt_info = opt_info,
                .named_captures = named_captures,
                .named_capture_list = owned_named_capture_list,
                .onepass = onepass_plan,
                .bounded_literal = bounded_literal,
                .search_dfa_pool = search_dfa_pool,
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
        if (self.search_dfa_pool) |pool| pool.destroy(self.allocator);

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

    /// The literal strings every match must contain (see `factors`), or null
    /// when none of at least `options.min_len` bytes exists.
    pub fn requiredFactors(self: *const Regex, allocator: std.mem.Allocator, options: factors.Options) !?factors.Factors {
        return factors.requiredFactors(allocator, self.pattern, self.flags, options);
    }

    /// Cap the work one search may do on the backtracking engine: the steps
    /// it explores, 10,000,000 by default. A search that runs out fails with
    /// `error.Timeout`, never with "no match". Patterns on the Thompson
    /// engines run in time linear in the input and have no step budget here;
    /// for a hard bound on those, match through a `Program` and set
    /// `Scratch.step_budget`.
    pub fn setStepBudget(self: *Regex, steps: usize) void {
        if (self.backtrack_engine) |*engine| engine.max_steps = steps;
    }

    /// The backtracking engine's step budget, or null for a pattern that runs
    /// on the Thompson engines.
    pub fn stepBudget(self: *const Regex) ?usize {
        return if (self.backtrack_engine) |engine| engine.max_steps else null;
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
            .start_line => pos == 0 or (self.flags.multiline and common.lineTerminatorBefore(input, pos, self.flags)),
            .end_line => pos == input.len or (self.flags.multiline and common.lineTerminatorAt(input, pos, self.flags)),
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
        // would differ). Literal lookarounds need input at the current position
        // and stay on the VM; other lookarounds/backrefs/properties backtrack.
        return self.engine_type == .thompson_nfa and
            !self.nfa.has_literal_assertions and !self.opt_info.has_lazy;
    }

    /// Whether `isMatch` can answer with the unanchored search DFA. Wider than
    /// `dfaEligible`: a lazy quantifier only orders an NFA split, which changes
    /// which match is reported but never whether one exists, and existence is
    /// all the search DFA answers.
    fn searchDfaEligible(self: *const Regex) bool {
        return self.engine_type == .thompson_nfa and !self.nfa.has_literal_assertions;
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
        if (!self.flags.ecmascript) {
            const nl = std.mem.indexOfScalarPos(u8, input, pos - 1, '\n') orelse return null;
            const s = nl + 1;
            return if (s <= input.len) s else null;
        }
        // ECMAScript line terminators also include CR, U+2028 and U+2029, whose
        // WTF-8 encodings end in A8/A9. Those bytes also end other characters,
        // so each candidate is confirmed; the scan only moves forward.
        var i = pos - 1;
        while (std.mem.indexOfAnyPos(u8, input, i, "\n\r\xA8\xA9")) |t| {
            if (common.lineTerminatorBefore(input, t + 1, self.flags)) return t + 1;
            i = t + 1;
        }
        return null;
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
    /// A search DFA for one `isMatch` call: a warm one from the pool, else a
    /// new one. Null when none can be built (the call then takes the NFA).
    /// Every non-null result goes back through `returnSearchDfa`.
    fn takeSearchDfa(self: *const Regex) ?*dfa.LazyDfa {
        if (self.search_dfa_pool) |pool| if (pool.take()) |d| {
            // A DFA reads the NFA through a pointer to `Regex.nfa`, which is
            // inline: if this `Regex` was moved since the DFA was built (an
            // ArrayList that grew, a map that rehashed, a return by value),
            // the stored address is stale. Every copy shares the NFA's heap
            // contents, so pointing it at this copy is always right. The DFA
            // is this call's alone until it is returned.
            d.nfa = @constCast(&self.nfa);
            return d;
        };
        const d = self.allocator.create(dfa.LazyDfa) catch return null;
        d.* = dfa.LazyDfa.initSearch(self.allocator, @constCast(&self.nfa), self.flags) catch {
            self.allocator.destroy(d);
            return null;
        };
        return d;
    }

    fn returnSearchDfa(self: *const Regex, d: *dfa.LazyDfa) void {
        if (self.search_dfa_pool) |pool| if (pool.give(d)) return;
        self.freeSearchDfa(d);
    }

    fn freeSearchDfa(self: *const Regex, d: *dfa.LazyDfa) void {
        d.deinit();
        self.allocator.destroy(d);
    }

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
    /// The length of the literal of `set` that matches at `pos` (0 when none
    /// does), as the engine's semantics pick it: the first in source order
    /// for ECMAScript (leftmost-first), otherwise the longest, which is what
    /// the Thompson engines report for the same alternation (`a|ab` finds
    /// `ab`).
    fn literalAt(self: *const Regex, set: []const []const u8, input: []const u8, pos: usize) usize {
        var best: usize = 0;
        for (set) |s| {
            if (pos + s.len <= input.len and
                std.mem.eql(u8, input[pos .. pos + s.len], s))
            {
                if (self.flags.ecmascript) return s.len;
                best = @max(best, s.len);
            }
        }
        return best;
    }

    /// Candidate-position scanner for a literal alternation (`foo|bar|baz`).
    /// The set path confirms each candidate with `literalAt`, which follows
    /// ECMAScript's leftmost-first order or the Thompson engines' longest
    /// match.
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

    fn anchoredStartSkipped(self: *const Regex, start: usize) bool {
        return start > 0 and self.opt_info.anchored_start and !self.flags.multiline;
    }

    fn nextCodepointStart(input: []const u8, pos: usize) usize {
        if (pos >= input.len) return input.len + 1;
        const len = common.ecmaCodePointLen(input, pos) orelse return pos + 1;
        return pos + len;
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
        /// Persistent lazy-DFA and VM storage may outlive the allocator used
        /// for one match result. Keeping that allocator on the matcher avoids
        /// dangling cached scratch when callers recycle result arenas.
        scratch_allocator: std.mem.Allocator,
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
            if (self.search_dfa_failed or !self.re.searchDfaEligible()) return null;
            self.search_dfa_cell = dfa.LazyDfa.initSearch(self.scratch_allocator, @constCast(&self.re.nfa), self.re.flags) catch {
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
            self.dfa_cell = dfa.LazyDfa.init(self.scratch_allocator, @constCast(&self.re.nfa), self.re.flags) catch {
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
            self.vm_cell = vm.VM.init(self.scratch_allocator, @constCast(&self.re.nfa), self.re.capture_count, self.re.flags);
            return &(self.vm_cell.?);
        }

        pub fn isMatch(self: *Matcher, input: []const u8) !bool {
            return self.re.isMatchInner(input, self.vmPtr(), self.searchDfaPtr());
        }
        pub fn find(self: *Matcher, input: []const u8) !?Match {
            return self.re.findInner(input, self.dfaPtr(), self.vmPtr());
        }
        /// Find from an absolute byte offset while retaining this matcher's
        /// scratch state. Assertions still observe the original input.
        pub fn findFrom(self: *Matcher, input: []const u8, start: usize) !?Match {
            if (start == 0) return self.find(input);
            return self.re.findFromInner(input, start, self.vmPtr());
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
        return self.matcherWithScratchAllocator(self.allocator);
    }

    /// Create a reusable matcher whose persistent lazy-DFA and VM allocations
    /// are independent from `Regex.allocator`, which remains the allocator for
    /// per-call match results.
    pub fn matcherWithScratchAllocator(self: *const Regex, scratch_allocator: std.mem.Allocator) Matcher {
        return .{ .re = self, .scratch_allocator = scratch_allocator };
    }

    /// Check if the pattern matches the entire input string
    pub fn isMatch(self: *const Regex, input: []const u8) !bool {
        return self.isMatchInner(input, null, null);
    }

    /// `reuse_vm`/`reuse_search_dfa` let a `Matcher` pass its own cached VM and
    /// lazy DFA (the grep hot path). With null, the search DFA comes from the
    /// regex's `SearchDfaPool`, which keeps it warm across calls and threads
    /// (the shared public path); the VM is still built per call.
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
        if (self.engine_type == .thompson_nfa) if (self.opt_info.repeat_atom) |ra| if (self.repeatAtomFastPathOk()) {
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
                    if (self.literalAt(set, input, cand) > 0) return true;
                    p = cand + 1;
                }
                return false;
            }
        }
        // Existence has no leftmost/longest subtlety, so the unanchored search
        // DFA settles it in one left-to-right pass (the re-seeded start makes every
        // position a candidate) — no per-position restart. O(n) even for sparse
        // matches like `fn\s+\w+|\w+\s+fn`. A `Matcher` passes its own DFA;
        // otherwise one comes from the pool (or is built) and goes back to it.
        if (self.searchDfaEligible()) {
            const pooled = if (reuse_search_dfa == null) self.takeSearchDfa() else null;
            // A DFA whose search failed part-way (out of memory while adding a
            // state) is freed, never returned for another call to use.
            var reusable = true;
            defer if (pooled) |d| if (reusable) self.returnSearchDfa(d) else self.freeSearchDfa(d);
            if (reuse_search_dfa orelse pooled) |d| {
                if (d.anyMatch(input)) |b| {
                    return b;
                } else |err| switch (err) {
                    error.DfaOverflow => {}, // fall back to NFA
                    else => |e| {
                        reusable = false;
                        return e;
                    },
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
                if (try self.findBacktracking(input, 0)) |result| {
                    var hit = result;
                    hit.deinit(self.backtrack_engine.?.allocator);
                    return true;
                }
                return false;
            },
        }
    }

    // Keep the existing search-wide budget, but distinguish exhausted work
    // from a genuine non-match at every public search/transform entry point.
    //
    // The search runs on a copy of the stored engine. The engine holds the
    // search's input, captures and step count, so searching with the stored one
    // made a shared `Regex` unsafe: two threads searching at once overwrote each
    // other's state and could report a wrong result.
    fn findBacktracking(self: *const Regex, input: []const u8, start: usize) !?backtrack.BacktrackMatch {
        var engine = try self.backtrack_engine.?.forSearch();
        defer engine.deinit();
        return self.searchWith(&engine, input, start);
    }

    fn searchWith(self: *const Regex, engine: *backtrack.BacktrackEngine, input: []const u8, start: usize) !?backtrack.BacktrackMatch {
        const prefix: ?[]const u8 = blk: {
            const literal = self.opt_info.literal_prefix orelse break :blk null;
            for (literal) |byte| if (!std.ascii.isAscii(byte)) break :blk null;
            break :blk literal;
        };
        const result = engine.findFromWithPrefix(input, start, prefix);
        if (engine.match_error) |err| return err;
        if (engine.step_count > engine.max_steps) return error.Timeout;
        return result;
    }

    /// The step budget one backtracking search of `input` needs to give the
    /// answer it gives now, for choosing one with `setStepBudget`: its steps, or
    /// twice them when the search was answered by its attempt with the loop
    /// memo, which runs on half the budget. Null for a pattern on the Thompson
    /// engines, which have no step budget. Runs the search on a private copy,
    /// like every other search, so it reports and changes nothing shared.
    pub fn searchSteps(self: *const Regex, input: []const u8) !?usize {
        const stored = if (self.backtrack_engine) |*engine| engine else return null;
        var engine = try stored.forSearch();
        defer engine.deinit();
        if (self.searchWith(&engine, input, 0) catch |err| switch (err) {
            error.Timeout => null,
            else => return err,
        }) |found| {
            var discarded = found;
            discarded.deinit(engine.allocator);
        }
        // An answer from the attempt with the loop memo ran on half the
        // budget, so it needs twice its steps to come back the same.
        return if (engine.answered_with_memo) 2 * engine.step_count else engine.step_count;
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
        if (self.engine_type == .thompson_nfa) if (self.opt_info.repeat_atom) |ra| if (self.repeatAtomFastPathOk()) {
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
        // Literal-alternation fast path: leftmost position, then `literalAt`.
        if (self.opt_info.literal_set) |set| {
            if (!self.flags.case_insensitive) {
                const scanner = LiteralSetScanner.init(set, self.opt_info.first_bytes);
                var p: usize = 0;
                while (scanner.next(input, p)) |cand| {
                    const best = self.literalAt(set, input, cand);
                    if (best > 0) return Match{ .slice = input[cand .. cand + best], .start = cand, .end = cand + best };
                    p = cand + 1;
                }
                return null;
            }
        }
        // One-pass capture plan: deterministic capture matching, no NFA. Its
        // segment tables are per-byte, so it declines any input whose decision
        // would consume a non-ASCII byte (`onepass.Plan.NonAscii`); that falls
        // through to the general engine below, which matches whole code points.
        if (self.onepass) |plan| one_pass: {
            const fb = self.opt_info.first_bytes;
            var scan: usize = 0;
            while (scan <= input.len) {
                if (fb) |t| {
                    while (scan < input.len and !t[input[scan]]) scan += 1;
                    if (scan >= input.len) break;
                }
                const attempt = plan.matchAt(self.allocator, input, scan) catch |err| switch (err) {
                    error.OnePassNonAscii => break :one_pass,
                    else => return err,
                };
                if (attempt) |result| return try self.buildMatch(input, result);
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
                if (try self.findBacktracking(input, 0)) |result| {
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
        return self.findFromInner(input, start, null);
    }

    fn findFromInner(self: *const Regex, input: []const u8, start: usize, reuse_vm: ?*vm.VM) !?Match {
        if (self.requiredAbsent(input)) return null;
        const from = @min(start, input.len);
        if (self.anchoredStartSkipped(from)) return null;

        if (self.opt_info.exact_literal) |lit| {
            const found = if (self.flags.case_insensitive) blk: {
                var sc = CiLiteralScanner.init(input, lit, from);
                break :blk sc.next();
            } else literalSearch(input, lit, from);
            if (found) |i| return Match{ .slice = input[i .. i + lit.len], .start = i, .end = i + lit.len };
            return null;
        }
        if (self.engine_type == .thompson_nfa) if (self.opt_info.repeat_atom) |ra| if (self.repeatAtomFastPathOk()) {
            const table = repeatTable(ra, self.flags.case_insensitive);
            const max = ra.max orelse std.math.maxInt(usize);
            if (self.opt_info.anchored_end) {
                var p = from;
                while (p < input.len and !table[input[p]]) p += 1;
                if (p >= input.len) return null;
                const run = repeatRunAt(input, table, p, max);
                const end = p + run;
                if (end == input.len and repeatBoundsOk(run, ra.min, max))
                    return Match{ .slice = input[p..end], .start = p, .end = end };
                return null;
            }
            var p = from;
            while (p < input.len) {
                while (p < input.len and !table[input[p]]) p += 1;
                if (p >= input.len) break;
                const match_start = p;
                var run: usize = 0;
                while (p < input.len and table[input[p]] and run < max) : (p += 1) run += 1;
                if (run >= ra.min) return Match{ .slice = input[match_start..p], .start = match_start, .end = p };
            }
            return null;
        };
        if (self.opt_info.unicode_repeat_atom) |ura| if (!self.flags.case_insensitive and self.repeatAtomFastPathOk()) {
            const max = ura.max orelse std.math.maxInt(usize);
            if (self.opt_info.anchored_end) {
                var p = from;
                while (p < input.len) {
                    const run = unicodeRepeatRunAt(input, ura.property, p, max);
                    if (run.count >= ura.min) {
                        if (run.end == input.len)
                            return Match{ .slice = input[p..run.end], .start = p, .end = run.end };
                        return null;
                    }
                    p = nextCodepointStart(input, p);
                }
                return null;
            }
            var p = from;
            while (p < input.len) {
                const run = unicodeRepeatRunAt(input, ura.property, p, max);
                if (run.count >= ura.min) {
                    return Match{ .slice = input[p..run.end], .start = p, .end = run.end };
                }
                p = nextCodepointStart(input, p);
            }
            return null;
        };

        switch (self.engine_type) {
            .thompson_nfa => {
                var tmp_vm: ?vm.VM = null;
                defer if (tmp_vm) |*v| v.deinit();
                const virtual_machine = self.obtainVm(reuse_vm, &tmp_vm);

                // Declines non-ASCII input; see the one-pass note in `find`.
                if (self.onepass) |plan| one_pass: {
                    const fb = self.opt_info.first_bytes;
                    var scan: usize = from;
                    while (scan <= input.len) {
                        if (fb) |t| {
                            while (scan < input.len and !t[input[scan]]) scan += 1;
                            if (scan >= input.len) break;
                        }
                        const attempt = plan.matchAt(self.allocator, input, scan) catch |err| switch (err) {
                            error.OnePassNonAscii => break :one_pass,
                            else => return err,
                        };
                        if (attempt) |result| return try self.buildMatch(input, result);
                        scan = plan.nextScan(input, scan);
                    }
                    return null;
                }

                if (self.opt_info.literal_prefix) |prefix| {
                    if (!self.flags.case_insensitive) {
                        var search_from: usize = from;
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
                        var scan: usize = from;
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

                var scan: usize = from;
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
                if (try self.findBacktracking(input, start)) |result| {
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
        errdefer {
            for (matches.items) |*hit| hit.deinit(allocator);
            matches.deinit(allocator);
        }

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
        if (self.engine_type == .thompson_nfa) if (self.opt_info.repeat_atom) |ra| if (self.repeatAtomFastPathOk()) {
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
        // Literal-alternation fast path: each leftmost match, ended by `literalAt`.
        if (self.opt_info.literal_set) |set| {
            if (!self.flags.case_insensitive) {
                const scanner = LiteralSetScanner.init(set, self.opt_info.first_bytes);
                while (scanner.next(input, pos)) |cand| {
                    const best = self.literalAt(set, input, cand);
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

        // One-pass capture plan: deterministic capture matching, no NFA. Its
        // segment tables are per-byte, so it declines any input whose decision
        // would consume a non-ASCII byte (`onepass.Plan.NonAscii`); that falls
        // through to the general engine below, which matches whole code points.
        if (self.onepass) |plan| one_pass: {
            const fb = self.opt_info.first_bytes;
            while (pos <= input.len) {
                var scan = pos;
                var found: ?vm.MatchResult = null;
                while (scan <= input.len) {
                    if (fb) |t| {
                        while (scan < input.len and !t[input[scan]]) scan += 1;
                        if (scan >= input.len) break;
                    }
                    const attempt = plan.matchAt(allocator, input, scan) catch |err| switch (err) {
                        error.OnePassNonAscii => {
                            // Drop the prefix this plan produced and re-run the
                            // whole input on the general engine.
                            for (matches.items) |*m| m.deinit(allocator);
                            matches.clearRetainingCapacity();
                            pos = 0;
                            break :one_pass;
                        },
                        else => return err,
                    };
                    if (attempt) |r| {
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
                    if (try self.findBacktracking(input[pos..], 0)) |result| {
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
                    const sdfa = reuse_search_dfa orelse (if (self.searchDfaEligible()) self.obtainSearchDfa(null, &tmp_dfa) else null);
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
        if (self.searchDfaEligible()) {
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
        if (self.engine_type == .thompson_nfa) if (self.opt_info.repeat_atom) |ra| if (self.repeatAtomFastPathOk()) {
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
        // Literal-alternation: the `literalAt` match at each candidate.
        if (self.opt_info.literal_set) |set| {
            if (!self.flags.case_insensitive) {
                const scanner = LiteralSetScanner.init(set, self.opt_info.first_bytes);
                while (scanner.next(input, pos)) |cand| {
                    const best = self.literalAt(set, input, cand);
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
                // `<= input.len` so a zero-width match at end of input is counted,
                // matching the Thompson path and find()/isMatch().
                while (pos <= input.len) {
                    if (try self.findBacktracking(input[pos..], 0)) |result| {
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
                        // Search initializes the input and one budget for all
                        // candidate positions. Do not reuse stale search state
                        // or reset the budget independently at each position.
                        if (try self.regex.findBacktracking(self.input, self.pos)) |result| {
                            var hit = result;
                            defer hit.deinit(self.regex.allocator);
                            var captures_list = try std.ArrayList([]const u8).initCapacity(allocator, result.captures.len);
                            errdefer captures_list.deinit(allocator);
                            for (result.captures) |cap| {
                                try captures_list.append(allocator, if (cap.matched) self.input[cap.start..cap.end] else "");
                            }
                            const captures = try captures_list.toOwnedSlice(allocator);
                            self.pos = if (result.end > result.start) result.end else result.end + 1;
                            return Match{
                                .slice = self.input[result.start..result.end],
                                .start = result.start,
                                .end = result.end,
                                .captures = captures,
                            };
                        }
                        self.done = true;
                        return null;
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
fn flattenBoundedLeaves(root: *ast.Node, out: *std.ArrayList(*ast.Node), allocator: std.mem.Allocator) bool {
    // In source order along the right spine (#48).
    var node = root;
    while (true) switch (node.node_type) {
        .concat => {
            if (!flattenBoundedLeaves(node.data.concat.left, out, allocator)) return false;
            node = node.data.concat.right;
        },
        .literal, .anchor => {
            out.append(allocator, node) catch return false;
            return true;
        },
        .empty => return true,
        else => return false,
    };
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

// One consuming capture spanning the pattern has no competing capture
// histories at an NFA state. Boundary assertions consume nothing, so this
// shape preserves the capture while the ordered VM chooses the match end.
fn hasSpanningAssertionCapture(root: *ast.Node) bool {
    var pending: [128]*ast.Node = undefined;
    pending[0] = root;
    var count: usize = 1;
    var captured = false;
    var asserted = false;
    while (count != 0) {
        count -= 1;
        const node = pending[count];
        switch (node.node_type) {
            .empty, .anchor => {},
            .lookahead, .lookbehind => asserted = true,
            .group => {
                if (node.data.group.mod != null) return false;
                if (node.data.group.capture_index != null) {
                    if (captured) return false;
                    captured = true;
                } else {
                    pending[count] = node.data.group.child;
                    count += 1;
                }
            },
            .concat => {
                if (count + 2 > pending.len) return false;
                pending[count] = node.data.concat.right;
                pending[count + 1] = node.data.concat.left;
                count += 2;
            },
            else => return false,
        }
    }
    return captured and asserted;
}

// A capture outside every quantifier is entered at most once on any path.
// Prioritized Thompson threads can merge at the same state/offset by retaining
// the first capture history: later continuations cannot observe it (backrefs
// and capture-bearing assertions still require the backtracker). Repeated
// captures need separate empty-iteration/reset reasoning and stay excluded.
fn hasSingleEntryCaptures(node: *ast.Node, repeated: bool) bool {
    return switch (node.node_type) {
        .group => (node.data.group.capture_index == null or !repeated) and
            node.data.group.mod == null and hasSingleEntryCaptures(node.data.group.child, repeated),
        .concat => hasSingleEntryCaptures(node.data.concat.left, repeated) and
            hasSingleEntryCaptures(node.data.concat.right, repeated),
        .alternation => hasSingleEntryCaptures(node.data.alternation.left, repeated) and
            hasSingleEntryCaptures(node.data.alternation.right, repeated),
        .star => hasSingleEntryCaptures(node.data.star.child, true),
        .plus => hasSingleEntryCaptures(node.data.plus.child, true),
        .optional => hasSingleEntryCaptures(node.data.optional.child, true),
        .repeat => hasSingleEntryCaptures(node.data.repeat.child, true),
        .lookahead, .lookbehind, .backref => false,
        else => true,
    };
}

// The ECMAScript priority-ordered VM honors lazy edges and alternation order.
// Admit capture-free and single-entry capture paths, or one spanning capture
// with boundary assertions. Repeated capture histories retain the fallback.
fn requiresBacktracking(root: *ast.Node, flags: common.CompileFlags, ordered_quantifiers: bool, scoped_modes: bool) bool {
    // Sequences and alternations are walked along their spine, recursing only
    // into the element or branch beside it (see `spine`), so a long flat
    // pattern does not overflow the stack (#48).
    var node = root;
    // Set while walking down an alternation's spine whose capture check has
    // already been answered for every branch below.
    var branches_checked = false;
    while (true) {
        const in_checked_spine = branches_checked;
        branches_checked = false;
        switch (node.node_type) {
            // These features require backtracking
            .lookahead, .lookbehind => {
                const a = if (node.node_type == .lookahead) node.data.lookahead else node.data.lookbehind;
                return !flags.ecmascript or flags.case_insensitive or flags.unicode or flags.unicode_sets or
                    compiler.fixedAsciiLiteral(a.child) == null;
            },
            .backref, .unicode_property => return true,

            // Under `/iu`, ECMAScript word-boundary assertions treat characters
            // that canonicalize to ASCII word characters (U+017F, U+212A) as word
            // characters. The byte DFA only tracks ASCII word bytes.
            .anchor => return flags.unicode and flags.case_insensitive and
                (node.data.anchor == .word_boundary or node.data.anchor == .non_word_boundary),

            .char_class => return flags.unicode and flags.case_insensitive and
                isAsciiWordClass(node.data.char_class),

            // A positive `class_set` (`\s`, `/v` Unicode brackets) lowers to a
            // UTF-8 byte automaton when it's a union of code-point ranges. Negated
            // Unicode sets must stay code-point based: the byte automaton can match
            // a single WTF-8 surrogate code unit from an astral pair, while
            // ECMAScript `/u` classes consume the whole code point.
            // Case-invariant sets (including \s) need no extra folding. Keep
            // case-sensitive membership on the NFA rather than rejecting valid
            // nested quantifiers through the backtracking risk policy.
            .class_set => return (flags.case_insensitive and
                (!flags.ecmascript or !@import("utf8_class.zig").caseInvariant(node.data.class_set))) or
                ((flags.unicode or flags.unicode_sets) and @import("utf8_class.zig").containsComplement(node.data.class_set)) or
                !@import("utf8_class.zig").compilable(node.data.class_set),

            // Check for lazy quantifiers
            .star, .plus, .optional => {
                const greedy = switch (node.node_type) {
                    .star => node.data.star.greedy,
                    .plus => node.data.plus.greedy,
                    .optional => node.data.optional.greedy,
                    else => unreachable,
                };
                if (!greedy and !ordered_quantifiers) return true;

                const child = switch (node.node_type) {
                    .star => node.data.star.child,
                    .plus => node.data.plus.child,
                    .optional => node.data.optional.child,
                    else => unreachable,
                };
                if (!ordered_quantifiers and containsAlternation(child)) return true;
                node = child;
            },
            .repeat => {
                if (!node.data.repeat.greedy and !ordered_quantifiers) return true;
                if (node.data.repeat.bounds.min > MAX_NFA_REPEAT_EXPANSION) return true;
                if (node.data.repeat.bounds.max) |max| {
                    if (max > MAX_NFA_REPEAT_EXPANSION) return true;
                }
                if (!ordered_quantifiers and containsAlternation(node.data.repeat.child)) return true;
                node = node.data.repeat.child;
            },

            .concat, .alternation => {
                if (node.node_type == .alternation and !ordered_quantifiers and !in_checked_spine) {
                    if (containsCapture(node)) return true;
                }
                const step = ast.spine(node);
                if (requiresBacktracking(step.side, flags, ordered_quantifiers, scoped_modes)) return true;
                // No branch below a capture-free alternation holds a capture.
                branches_checked = node.node_type == .alternation and step.next.node_type == .alternation;
                node = step.next;
            },
            // A group carrying inline modifiers `(?i:...)` adjusts flags per-scope,
            // which only the backtracking engine honors.
            .group => {
                if (node.data.group.mod != null and !scoped_modes) return true;
                // An atomic group whose every match has one length has one
                // end, so it never has another way to match: the Thompson
                // engines run it as a plain group. Any other needs the
                // backtracker's commit.
                if (node.data.group.atomic and fixedWidth(node.data.group.child, flags) == null) return true;
                node = node.data.group.child;
            },

            // The byte NFA can lower ordinary UTF-8 code points directly. In
            // ECMAScript Unicode mode, however, adjacent WTF-8 high/low surrogate
            // encodings form one code point and must be consumed atomically; the
            // backtracker's common.dotMatchLen path implements that rule.
            .any => return flags.unicode,

            // These don't require backtracking
            .literal, .empty => return false,
        }
    }
}

fn isAsciiWordClass(char_class: common.CharClass) bool {
    const word = common.CharClasses.word;
    if (char_class.ranges.len != word.ranges.len) return false;
    for (char_class.ranges, word.ranges) |a, b| {
        if (a.start != b.start or a.end != b.end) return false;
    }
    return true;
}

/// The length in bytes of every match of `root`, when all have the same, or
/// null. Recursion follows nesting only; sequences and alternations are
/// walked along their spine.
fn fixedWidth(root: *ast.Node, flags: common.CompileFlags) ?usize {
    switch (root.node_type) {
        .literal => return 1,
        .any => return if (flags.bytes) 1 else null,
        .char_class => {
            if (flags.bytes) return 1;
            for (root.data.char_class.ranges) |r| if (r.end >= 0x80) return null;
            return if (root.data.char_class.negated) null else 1;
        },
        .anchor, .empty, .lookahead, .lookbehind => return 0,
        .group => return fixedWidth(root.data.group.child, flags),
        .repeat => {
            const r = root.data.repeat;
            const w = fixedWidth(r.child, flags) orelse return null;
            if (w == 0) return 0;
            const max = r.bounds.max orelse return null;
            if (max != r.bounds.min) return null;
            return std.math.mul(usize, w, max) catch null;
        },
        .star, .plus, .optional => {
            const child = ast.onlyChild(root).?;
            return if (fixedWidth(child, flags) == 0) 0 else null;
        },
        .concat => {
            var total: usize = 0;
            var node = root;
            while (node.node_type == .concat) {
                const step = ast.spine(node);
                total += fixedWidth(step.side, flags) orelse return null;
                node = step.next;
            }
            return total + (fixedWidth(node, flags) orelse return null);
        },
        .alternation => {
            var width: ?usize = null;
            var node = root;
            while (true) {
                const branch, const next = if (node.node_type == .alternation) blk: {
                    const step = ast.spine(node);
                    break :blk .{ step.side, @as(?*ast.Node, step.next) };
                } else .{ node, @as(?*ast.Node, null) };
                const w = fixedWidth(branch, flags) orelse return null;
                if (width) |known| {
                    if (known != w) return null;
                } else width = w;
                node = next orelse return width;
            }
        },
        .backref, .class_set, .unicode_property => return null,
    }
}

/// Whether the tree has an inline-modifier group (`(?i)`, `(?s:..)`).
fn hasInlineModifier(root: *ast.Node) bool {
    var node = root;
    while (true) {
        switch (node.node_type) {
            .group => {
                if (node.data.group.mod != null) return true;
                node = node.data.group.child;
            },
            .concat, .alternation => {
                const step = ast.spine(node);
                if (hasInlineModifier(step.side)) return true;
                node = step.next;
            },
            else => node = ast.onlyChild(node) orelse return false,
        }
    }
}

fn containsAlternation(root: *ast.Node) bool {
    var node = root;
    while (true) {
        switch (node.node_type) {
            .alternation => return true,
            .concat => {
                const step = ast.spine(node);
                if (containsAlternation(step.side)) return true;
                node = step.next;
            },
            else => node = ast.onlyChild(node) orelse return false,
        }
    }
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
    switch (node.node_type) {
        .empty, .anchor, .lookahead, .lookbehind => return true,
        .literal, .any, .char_class, .backref, .unicode_property, .class_set => return false,
        .star, .optional => return true,
        .plus => return canMatchEmpty(node.data.plus.child),
        .repeat => return node.data.repeat.bounds.min == 0 or canMatchEmpty(node.data.repeat.child),
        .group => return canMatchEmpty(node.data.group.child),
        .concat => {
            // Along the spine, for the reason `spine` documents.
            var rest = node;
            while (rest.node_type == .concat) {
                const step = ast.spine(rest);
                if (!canMatchEmpty(step.side)) return false;
                rest = step.next;
            }
            return canMatchEmpty(rest);
        },
        .alternation => {
            var rest = node;
            while (rest.node_type == .alternation) {
                const step = ast.spine(rest);
                if (canMatchEmpty(step.side)) return true;
                rest = step.next;
            }
            return canMatchEmpty(rest);
        },
    }
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
        // The bytes of each element up to the first that cannot match empty,
        // or of every branch, walked along the spine (see `spine`).
        .concat, .alternation => blk: {
            var set: ?ByteSet = null;
            var rest = node;
            while (rest.node_type == node.node_type) {
                const step = ast.spine(rest);
                set = unionOptional(set, firstByteSet(step.side, flags));
                if (node.node_type == .concat and !canMatchEmpty(step.side)) break :blk set;
                rest = step.next;
            }
            break :blk unionOptional(set, firstByteSet(rest, flags));
        },
        .empty, .anchor, .lookahead, .lookbehind => null,
        .backref, .unicode_property, .class_set => null,
    };
}

/// `tailOf` for a sequence: the tail of its last element that cannot match
/// empty, or of an element after it, the last that has one (the right-nested
/// rule `tail(R) orelse if R can match empty then tail(L)`, unrolled). Walked
/// forwards along the spine (see `spine`), keeping the latest candidate.
fn sequenceTail(node: *ast.Node, flags: common.CompileFlags, comptime tailOf: fn (*ast.Node, common.CompileFlags) ?ByteSet) ?ByteSet {
    var tail: ?ByteSet = null;
    var rest = node;
    while (true) {
        const element, const next = if (rest.node_type == .concat) blk: {
            const step = ast.spine(rest);
            break :blk .{ step.side, @as(?*ast.Node, step.next) };
        } else .{ rest, @as(?*ast.Node, null) };
        const element_tail = tailOf(element, flags);
        if (element_tail != null or !canMatchEmpty(element)) tail = element_tail;
        rest = next orelse return tail;
    }
}

fn unionOptional(a: ?ByteSet, b: ?ByteSet) ?ByteSet {
    const l = a orelse return b;
    const r = b orelse return l;
    return unionByteSet(l, r);
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
        .concat => return sequenceTail(node, flags, variableQuantifierTailBytes),
        else => return null,
    }
}

/// Make every group of the tree non-capturing, unless it has a
/// backreference (which needs its group); returns whether it did. Walks with
/// an explicit stack: concatenations nest once per element, so a long literal
/// would otherwise recurse once per byte.
fn dropCaptures(allocator: std.mem.Allocator, root: *ast.Node) !bool {
    var stack: std.ArrayList(*ast.Node) = .empty;
    defer stack.deinit(allocator);
    var groups: std.ArrayList(*ast.Node) = .empty;
    defer groups.deinit(allocator);
    try stack.append(allocator, root);
    while (stack.pop()) |node| {
        switch (node.node_type) {
            .backref => return false,
            .group => {
                if (node.data.group.capture_index != null) try groups.append(allocator, node);
                try stack.append(allocator, node.data.group.child);
            },
            .concat => try stack.appendSlice(allocator, &.{ node.data.concat.left, node.data.concat.right }),
            .alternation => try stack.appendSlice(allocator, &.{ node.data.alternation.left, node.data.alternation.right }),
            .star => try stack.append(allocator, node.data.star.child),
            .plus => try stack.append(allocator, node.data.plus.child),
            .optional => try stack.append(allocator, node.data.optional.child),
            .repeat => try stack.append(allocator, node.data.repeat.child),
            .lookahead => try stack.append(allocator, node.data.lookahead.child),
            .lookbehind => try stack.append(allocator, node.data.lookbehind.child),
            .literal, .any, .char_class, .anchor, .empty, .unicode_property, .class_set => {},
        }
    }
    // The name stays on the node so the tree still frees it; without an
    // index the group is not collected as a named capture.
    for (groups.items) |g| g.data.group.capture_index = null;
    return true;
}

fn containsCapture(root: *ast.Node) bool {
    var node = root;
    while (true) {
        switch (node.node_type) {
            .group => {
                if (node.data.group.capture_index != null) return true;
                node = node.data.group.child;
            },
            .concat, .alternation => {
                const step = ast.spine(node);
                if (containsCapture(step.side)) return true;
                node = step.next;
            },
            else => node = ast.onlyChild(node) orelse return false,
        }
    }
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
        .concat => return sequenceTail(node, flags, capturedVariableTailBytes),
        else => return null,
    }
}

fn hasAmbiguousCaptureBoundary(root: *ast.Node, flags: common.CompileFlags) bool {
    var node = root;
    while (true) {
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
                const step = ast.spine(node);
                if (hasAmbiguousCaptureBoundary(step.side, flags)) return true;
                node = step.next;
            },
            .alternation => {
                const step = ast.spine(node);
                if (hasAmbiguousCaptureBoundary(step.side, flags)) return true;
                node = step.next;
            },
            else => node = ast.onlyChild(node) orelse return false,
        }
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
    root: *ast.Node,
    map: *std.StringHashMap(usize),
    list: *std.ArrayList(NamedCapture),
) !void {
    // Source order matters (the list is ordered and the first of a duplicated
    // name wins in the map), so this walks with an explicit stack rather than
    // along a spine; recursion overflowed on long flat patterns (#48).
    var pending: std.ArrayList(*ast.Node) = .empty;
    defer pending.deinit(allocator);
    try pending.append(allocator, root);
    while (pending.pop()) |node| {
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
                try pending.append(allocator, group.child);
            },
            // Right first, so the left child pops first.
            .concat => try pending.appendSlice(allocator, &.{ node.data.concat.right, node.data.concat.left }),
            .alternation => try pending.appendSlice(allocator, &.{ node.data.alternation.right, node.data.alternation.left }),
            // Literals, character classes, anchors and backreferences hold no groups.
            else => if (ast.onlyChild(node)) |child| try pending.append(allocator, child),
        }
    }
}

test "compile empty pattern" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compileWithFlags(allocator, "", .{ .ecmascript = true });
    defer regex.deinit();

    var at_start = (try regex.find("abc")).?;
    defer at_start.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), at_start.start);
    try std.testing.expectEqual(@as(usize, 0), at_start.end);

    var after_two = (try regex.findFrom("abc", 2)).?;
    defer after_two.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), after_two.start);
    try std.testing.expectEqual(@as(usize, 2), after_two.end);

    var at_end = (try regex.findFrom("abc", 3)).?;
    defer at_end.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), at_end.start);
    try std.testing.expectEqual(@as(usize, 3), at_end.end);
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

test "compile diagnostic preserves ECMAScript failure reasons" {
    const Case = struct {
        pattern: []const u8,
        flags: common.CompileFlags = .{ .ecmascript = true },
        expected_error: RegexError,
        reason: CompileErrorReason,
    };
    const cases = [_]Case{
        .{ .pattern = "(", .expected_error = RegexError.UnexpectedCharacter, .reason = .missing_closing_parenthesis },
        .{ .pattern = "[a", .expected_error = RegexError.UnexpectedCharacter, .reason = .missing_character_class_terminator },
        .{ .pattern = "a{2,1}", .expected_error = RegexError.InvalidQuantifier, .reason = .quantifier_numbers_out_of_order },
        .{ .pattern = "*", .expected_error = RegexError.UnexpectedCharacter, .reason = .nothing_to_repeat },
        .{ .pattern = "a**", .expected_error = RegexError.InvalidQuantifier, .reason = .nothing_to_repeat },
        .{ .pattern = "a\\", .expected_error = RegexError.UnexpectedEndOfPattern, .reason = .trailing_backslash },
        .{ .pattern = "(?<1>a)", .expected_error = RegexError.InvalidCharacterClass, .reason = .invalid_group_specifier_name },
        .{ .pattern = "[z-a]", .expected_error = RegexError.InvalidCharacterClass, .reason = .range_out_of_order_in_character_class },
        .{ .pattern = "(?<a>x)(?<a>y)", .expected_error = RegexError.DuplicateGroupName, .reason = .duplicate_group_specifier_name },
        .{ .pattern = "\\k<z>(?<a>x)", .expected_error = RegexError.InvalidBackreference, .reason = .invalid_named_backreference },
        .{ .pattern = "\\p{Nope}", .flags = .{ .unicode = true, .ecmascript = true }, .expected_error = RegexError.InvalidEscapeSequence, .reason = .invalid_property_expression },
        .{ .pattern = "\\q", .flags = .{ .unicode = true, .ecmascript = true }, .expected_error = RegexError.InvalidEscapeSequence, .reason = .invalid_escaped_character_for_unicode_pattern },
        .{ .pattern = "\\u123", .flags = .{ .unicode = true, .ecmascript = true }, .expected_error = RegexError.InvalidEscapeSequence, .reason = .invalid_unicode_escape },
        .{ .pattern = "\\u{110000}", .flags = .{ .unicode = true, .ecmascript = true }, .expected_error = RegexError.InvalidEscapeSequence, .reason = .invalid_unicode_code_point_escape },
        .{ .pattern = "\\01", .flags = .{ .unicode = true, .ecmascript = true }, .expected_error = RegexError.InvalidEscapeSequence, .reason = .invalid_octal_escape_for_unicode_pattern },
        .{ .pattern = "[\\d-a]", .flags = .{ .unicode = true, .ecmascript = true }, .expected_error = RegexError.InvalidCharacterClass, .reason = .invalid_range_in_character_class_for_unicode_pattern },
        .{ .pattern = "\\1", .flags = .{ .unicode = true, .ecmascript = true }, .expected_error = RegexError.InvalidBackreference, .reason = .invalid_backreference_for_unicode_pattern },
        .{ .pattern = "(?", .expected_error = RegexError.UnexpectedCharacter, .reason = .unrecognized_character_after_group_start },
        .{ .pattern = ")", .expected_error = RegexError.UnmatchedParenthesis, .reason = .unmatched_parentheses },
    };

    for (cases) |case| {
        var diagnostic: ?CompileErrorReason = null;
        try std.testing.expectError(case.expected_error, Regex.compileWithFlagsDiagnostic(std.testing.allocator, case.pattern, case.flags, &diagnostic));
        try std.testing.expectEqual(case.reason, diagnostic.?);
    }
}

test "unicode surrogate escapes compile to WTF-8 code units" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\uDF06");
    defer regex.deinit();
    try std.testing.expect(try regex.isMatch(&.{ 0xED, 0xBC, 0x86 }));
}

test "unicode dot consumes WTF-8 surrogate pairs atomically" {
    const allocator = std.testing.allocator;
    const surrogate_pair = [_]u8{ 0xed, 0xa0, 0xbd, 0xed, 0xb8, 0x80, 'Z' };

    var legacy = try Regex.compileWithFlags(allocator, ".", .{ .ecmascript = true });
    defer legacy.deinit();
    var legacy_match = (try legacy.find(&surrogate_pair)).?;
    defer legacy_match.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), legacy_match.end);

    var unicode = try Regex.compileWithFlags(allocator, ".", .{ .unicode = true, .ecmascript = true });
    defer unicode.deinit();
    var unicode_match = (try unicode.find(&surrogate_pair)).?;
    defer unicode_match.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 6), unicode_match.end);

    var dot_all = try Regex.compileWithFlags(allocator, ".", .{ .unicode = true, .dot_all = true, .ecmascript = true });
    defer dot_all.deinit();
    var scalar_match = (try dot_all.find("\xf0\x9f\x98\x80")).?;
    defer scalar_match.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), scalar_match.end);
}

test "unicode shorthand classes consume code points atomically" {
    const allocator = std.testing.allocator;
    const surrogate_pair = [_]u8{ 0xed, 0xa0, 0xbd, 0xed, 0xb0, 0x80 };
    const scalar = "\xf0\x9f\x90\x80";

    inline for (.{ "\\D", "\\S", "\\W" }) |pattern| {
        var re_pair = try Regex.compileWithFlags(allocator, pattern, .{ .unicode = true, .ecmascript = true });
        defer re_pair.deinit();
        var pair_match = (try re_pair.find(&surrogate_pair)).?;
        defer pair_match.deinit(allocator);
        try std.testing.expectEqual(@as(usize, surrogate_pair.len), pair_match.end);

        var re_scalar = try Regex.compileWithFlags(allocator, pattern, .{ .unicode = true, .ecmascript = true });
        defer re_scalar.deinit();
        var scalar_match = (try re_scalar.find(scalar)).?;
        defer scalar_match.deinit(allocator);
        try std.testing.expectEqual(@as(usize, scalar.len), scalar_match.end);
    }
}

test "anchored unicode negated shorthand repeats without recursive stack growth" {
    const allocator = std.testing.allocator;
    const scalar = "\xf0\x9f\x90\x80";
    var input = std.ArrayList(u8).empty;
    defer input.deinit(allocator);
    for (0..8192) |_| try input.appendSlice(allocator, scalar);

    var re = try Regex.compileWithFlags(allocator, "^\\W+$", .{ .unicode = true, .ecmascript = true });
    defer re.deinit();
    try std.testing.expect(try re.isMatch(input.items));
}

test "annex b quantified lookahead remains zero-width" {
    const allocator = std.testing.allocator;

    var followed = try Regex.compileWithFlags(allocator, ".(?=Z)+", .{ .ecmascript = true });
    defer followed.deinit();
    var followed_match = (try followed.find("a bZ cZZ")).?;
    defer followed_match.deinit(allocator);
    try std.testing.expectEqualStrings("b", followed_match.slice);

    var not_followed = try Regex.compileWithFlags(allocator, "[a-e](?!Z)+", .{ .ecmascript = true });
    defer not_followed.deinit();
    var not_followed_match = (try not_followed.find("aZZZZ bZZZ cZZ dZ e")).?;
    defer not_followed_match.deinit(allocator);
    try std.testing.expectEqualStrings("e", not_followed_match.slice);
}

test "empty capture backreference repeats remain matchable" {
    const allocator = std.testing.allocator;

    var re = try Regex.compileWithFlags(allocator, "(a*)b\\1+", .{ .ecmascript = true });
    defer re.deinit();
    var match = (try re.find("baaaac")).?;
    defer match.deinit(allocator);

    try std.testing.expectEqualStrings("b", match.slice);
    try std.testing.expectEqual(@as(usize, 1), match.captures.len);
    try std.testing.expectEqualStrings("", match.captures[0]);
}

test "findFrom uses repeated atom fast paths after nonzero start" {
    const allocator = std.testing.allocator;

    var digits = try Regex.compile(allocator, "\\d+");
    defer digits.deinit();
    if (try digits.findFrom("xx123yy", 2)) |match_result| {
        try std.testing.expectEqualStrings("123", match_result.slice);
    } else try std.testing.expect(false);
    if (try digits.findFrom("xx123yy", 4)) |match_result| {
        try std.testing.expectEqualStrings("3", match_result.slice);
    } else try std.testing.expect(false);

    var letters = try Regex.compileWithFlags(allocator, "\\p{Letter}+", .{ .unicode = true });
    defer letters.deinit();
    if (try letters.findFrom("12abc", 2)) |match_result| {
        try std.testing.expectEqualStrings("abc", match_result.slice);
    } else try std.testing.expect(false);
    if (try letters.findFrom("12abc", 3)) |match_result| {
        try std.testing.expectEqualStrings("bc", match_result.slice);
    } else try std.testing.expect(false);

    var anchored = try Regex.compileWithFlags(allocator, "^\\p{Letter}+$", .{ .unicode = true });
    defer anchored.deinit();
    try std.testing.expect((try anchored.findFrom("abc", 1)) == null);
}

test "matcher findFrom reuses VM scratch and preserves absolute context" {
    const allocator = std.testing.allocator;
    const input = "id=418; state=ready; id=73; state=waiting; id=905; state=done";

    var regex = try Regex.compileWithFlags(allocator, "id=(\\d+);\\s+state=([a-z]+)", .{ .ecmascript = true });
    defer regex.deinit();
    var matcher = regex.matcher();
    defer matcher.deinit();

    var first = (try matcher.findFrom(input, 0)).?;
    defer first.deinit(allocator);
    var second = (try matcher.findFrom(input, first.end)).?;
    defer second.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 21), second.start);
    try std.testing.expectEqualStrings("73", second.captures[0]);
    try std.testing.expectEqualStrings("waiting", second.captures[1]);
    try std.testing.expect(matcher.vm_cell != null);

    var anchored = try Regex.compileWithFlags(allocator, "^id=(\\d+)", .{ .ecmascript = true });
    defer anchored.deinit();
    var anchored_matcher = anchored.matcher();
    defer anchored_matcher.deinit();
    try std.testing.expect((try anchored_matcher.findFrom(input, 1)) == null);
}

test "matcher scratch survives recycling the match-result allocator" {
    var compile_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer compile_arena.deinit();
    var scratch_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch_arena.deinit();
    var result_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena.deinit();

    var re = try Regex.compileWithFlags(compile_arena.allocator(), "(ab+)", .{ .ecmascript = true });
    re.allocator = result_arena.allocator();
    var matcher = re.matcherWithScratchAllocator(scratch_arena.allocator());
    defer matcher.deinit();

    // A nonzero start primes the VM, then a zero start lazily creates the DFA.
    // Both must remain valid after each result arena reset.
    var from_middle = (try matcher.findFrom("xxabbb", 2)).?;
    from_middle.deinit(result_arena.allocator());
    _ = result_arena.reset(.retain_capacity);

    var first = (try matcher.find("xxabbb")).?;
    first.deinit(result_arena.allocator());
    _ = result_arena.reset(.retain_capacity);

    var reused = (try matcher.find("xxabbb")).?;
    defer reused.deinit(result_arena.allocator());
    try std.testing.expectEqualStrings("abbb", reused.slice);
    try std.testing.expectEqualStrings("abbb", reused.captures[0]);
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

test "regex compilation is exhaustive-allocation-failure safe" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var compiled = try Regex.compile(allocator, "^sec-(alpha|beta)-[a-z]+$");
            defer compiled.deinit();
        }
    }.run, .{});
}

test "named capture compilation rolls back every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var compiled = try Regex.compile(allocator, "^(?<word>[a-z]+)(?=\\d)-[0-9]+$");
            defer compiled.deinit();
        }
    }.run, .{});
}

test "nested class-set compilation rolls back every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var compiled = try Regex.compileWithFlags(allocator, "[\\d\\-a]+", .{ .ecmascript = true });
            defer compiled.deinit();
        }
    }.run, .{});
}

// ECMAScript multiline ^ and $ (22.2.2.4) treat every LineTerminator (12.3) --
// LF, CR, U+2028, U+2029 -- as a line boundary, in every engine: the lazy DFA
// (including terminators it consumes mid-scan), the VM behind findFrom, the
// backtracker and the bounded-literal path. Each row was checked against node
// v24.4.1, with node's UTF-16 indices converted to byte offsets (zig-regex#28).
const EcmaLineOp = enum { find, from, all, is_match };
const EcmaLineCase = struct {
    op: EcmaLineOp,
    pattern: []const u8,
    multiline: bool,
    dot_all: bool = false,
    input: []const u8,
    from: usize = 0,
    span: ?[2]usize = null,
    spans: []const [2]usize = &.{},
    matches: bool = false,
};

const ecma_line_cases = [_]EcmaLineCase{
    // DFA: CR before ^
    .{ .op = .find, .pattern = "^b", .multiline = true, .input = "a\rb", .span = .{ 2, 3 } },
    // VM: findFrom past the CR
    .{ .op = .from, .pattern = "^b", .multiline = true, .input = "a\rb", .from = 1, .span = .{ 2, 3 } },
    // backtracker
    .{ .op = .find, .pattern = "(?=b)^b", .multiline = true, .input = "a\rb", .span = .{ 2, 3 } },
    // bounded literal
    .{ .op = .find, .pattern = "^bc", .multiline = true, .input = "a\rbc", .span = .{ 2, 4 } },
    // DFA: PS look-ahead for $
    .{ .op = .find, .pattern = "a$", .multiline = true, .input = "a\u{2029}b", .span = .{ 0, 1 } },
    // DFA: LS before ^
    .{ .op = .find, .pattern = "^b", .multiline = true, .input = "a\u{2028}b", .span = .{ 4, 5 } },
    // DFA consumes LS mid-scan
    .{ .op = .find, .pattern = "x.^b", .multiline = true, .dot_all = true, .input = "x\u{2028}b", .span = .{ 0, 5 } },
    // DFA consumes PS mid-scan
    .{ .op = .find, .pattern = "x.^b", .multiline = true, .dot_all = true, .input = "x\u{2029}b", .span = .{ 0, 5 } },
    // DFA consumes CR mid-scan
    .{ .op = .find, .pattern = "x.^b", .multiline = true, .dot_all = true, .input = "x\rb", .span = .{ 0, 3 } },
    // look-alike: e9 ends in A9
    .{ .op = .find, .pattern = "x.^b", .multiline = true, .dot_all = true, .input = "x\u{E9}b", .span = null },
    // look-alike: E2 82 AC
    .{ .op = .find, .pattern = "x.^b", .multiline = true, .dot_all = true, .input = "x\u{20AC}b", .span = null },
    // look-alike: C2 A8
    .{ .op = .find, .pattern = "x.^b", .multiline = true, .dot_all = true, .input = "x\u{A8}b", .span = null },
    // backtracker $ before CR
    .{ .op = .find, .pattern = "a(?=$)", .multiline = true, .input = "a\r", .span = .{ 0, 1 } },
    // backtracker $ before LS
    .{ .op = .find, .pattern = "a(?=$)", .multiline = true, .input = "a\u{2028}", .span = .{ 0, 1 } },
    // modifier turns multiline on
    .{ .op = .find, .pattern = "(?m:a$)", .multiline = false, .input = "a\rb", .span = .{ 0, 1 } },
    // modifier turns multiline off
    .{ .op = .find, .pattern = "(?-m:a$)", .multiline = true, .input = "a\rb", .span = null },
    // every terminator
    .{ .op = .all, .pattern = "^\\w$", .multiline = true, .input = "a\r\nb\rc\u{2028}d", .spans = &.{ .{ 0, 1 }, .{ 3, 4 }, .{ 5, 6 }, .{ 9, 10 } } },
    // line starts around LS
    .{ .op = .all, .pattern = "^", .multiline = true, .input = "\u{2028}", .spans = &.{ .{ 0, 0 }, .{ 3, 3 } } },
    // empty lines around CRLF
    .{ .op = .all, .pattern = "^$", .multiline = true, .input = "\r\n", .spans = &.{ .{ 0, 0 }, .{ 1, 1 }, .{ 2, 2 } } },
    // search DFA
    .{ .op = .is_match, .pattern = "^b", .multiline = true, .input = "a\u{2028}b", .matches = true },
    // search DFA $ before CR
    .{ .op = .is_match, .pattern = "a$", .multiline = true, .input = "a\r", .matches = true },
    // $ before CR is the first line end
    .{ .op = .find, .pattern = ".$", .multiline = true, .input = "ab\rcd", .span = .{ 1, 2 } },
    // no m: ^ is only the start
    .{ .op = .find, .pattern = "^b", .multiline = false, .input = "a\rb", .span = null },
};

fn expectEcmaLineCase(m: *Regex.Matcher, c: EcmaLineCase) !void {
    const allocator = std.testing.allocator;
    switch (c.op) {
        .find, .from => {
            var found = if (c.op == .find) try m.find(c.input) else try m.findFrom(c.input, c.from);
            defer if (found) |*f| f.deinit(allocator);
            if (c.span) |want| {
                const f = found orelse {
                    std.debug.print("no match: {s} on {any}\n", .{ c.pattern, c.input });
                    return error.TestExpectedMatch;
                };
                try std.testing.expectEqual(want, [2]usize{ f.start, f.end });
            } else if (found) |f| {
                std.debug.print("unexpected match {d}..{d}: {s} on {any}\n", .{ f.start, f.end, c.pattern, c.input });
                return error.TestUnexpectedMatch;
            }
        },
        .all => {
            const all = try m.findAll(allocator, c.input);
            defer {
                for (all) |*f| f.deinit(allocator);
                allocator.free(all);
            }
            try std.testing.expectEqual(c.spans.len, all.len);
            for (c.spans, all) |want, f| try std.testing.expectEqual(want, [2]usize{ f.start, f.end });
        },
        .is_match => try std.testing.expectEqual(c.matches, try m.isMatch(c.input)),
    }
}

test "ECMAScript multiline anchors treat CR, U+2028 and U+2029 as line terminators" {
    const allocator = std.testing.allocator;
    for (ecma_line_cases) |c| {
        var regex = try Regex.compileWithFlags(allocator, c.pattern, .{ .ecmascript = true, .multiline = c.multiline, .dot_all = c.dot_all });
        defer regex.deinit();
        // Twice on the same matcher, so the lazy DFA's cached transitions are
        // exercised as well as freshly computed ones.
        var m = regex.matcher();
        defer m.deinit();
        try expectEcmaLineCase(&m, c);
        try expectEcmaLineCase(&m, c);
    }
}

test "non-ECMAScript multiline anchors keep the LF-only rule" {
    const allocator = std.testing.allocator;
    const controls = [_]EcmaLineCase{
        .{ .op = .find, .pattern = "^b", .multiline = true, .input = "a\rb" },
        .{ .op = .from, .pattern = "^b", .multiline = true, .input = "a\rb", .from = 1 },
        .{ .op = .find, .pattern = "(?=b)^b", .multiline = true, .input = "a\rb" },
        .{ .op = .find, .pattern = "^bc", .multiline = true, .input = "a\rbc" },
        .{ .op = .find, .pattern = "a$", .multiline = true, .input = "a\u{2028}b" },
        .{ .op = .is_match, .pattern = "^b", .multiline = true, .input = "a\u{2028}b", .matches = false },
        .{ .op = .find, .pattern = "^b", .multiline = true, .input = "a\nb", .span = .{ 2, 3 } },
    };
    for (controls) |c| {
        var regex = try Regex.compileWithFlags(allocator, c.pattern, .{ .multiline = c.multiline });
        defer regex.deinit();
        var m = regex.matcher();
        defer m.deinit();
        try expectEcmaLineCase(&m, c);
    }
}

// ECMAScript matches and captures follow the spec's backtracking priority
// (leftmost-first: 22.2.2.3 MatchTwoAlternatives, 22.2.2.3.1 RepeatMatcher),
// on every engine a pattern can reach: the ordered lazy DFA for the match end,
// the priority VM for captures, and the VM alone on findFrom. Each row is
// node v24.4.1's answer for the pattern run with the g flag from `from`
// (zig-regex#27).
const LeftmostFirstCase = struct {
    pattern: []const u8,
    case_insensitive: bool,
    input: []const u8,
    from: usize,
    expected: ?struct { start: usize, end: usize, captures: []const ?[]const u8 },
};

const leftmost_first_cases = [_]LeftmostFirstCase{
    .{ .pattern = "(a|ab)(c|bcd)(d*)", .case_insensitive = false, .input = "abcd", .from = 0, .expected = .{ .start = 0, .end = 4, .captures = &.{ "a", "bcd", "" } } },
    .{ .pattern = "(a|ab)(c|bcd)(d+)?", .case_insensitive = false, .input = "abcd", .from = 0, .expected = .{ .start = 0, .end = 4, .captures = &.{ "a", "bcd", null } } },
    .{ .pattern = "(a|ab)(c|bcd)d?", .case_insensitive = false, .input = "abcd", .from = 0, .expected = .{ .start = 0, .end = 4, .captures = &.{ "a", "bcd" } } },
    .{ .pattern = "^(a|ab)(c|bcd)(d*)$", .case_insensitive = false, .input = "abcd", .from = 0, .expected = .{ .start = 0, .end = 4, .captures = &.{ "a", "bcd", "" } } },
    .{ .pattern = "(a|ab)(c|bcd)(d*)", .case_insensitive = true, .input = "ABCD", .from = 0, .expected = .{ .start = 0, .end = 4, .captures = &.{ "A", "BCD", "" } } },
    .{ .pattern = "(a|ab)(c|bcd)(d*)", .case_insensitive = false, .input = "xxabcd", .from = 1, .expected = .{ .start = 2, .end = 6, .captures = &.{ "a", "bcd", "" } } },
    .{ .pattern = "(x|xy)(z|yzw)(w*)", .case_insensitive = false, .input = "xyzw", .from = 0, .expected = .{ .start = 0, .end = 4, .captures = &.{ "x", "yzw", "" } } },
    .{ .pattern = "(a|ab)(c|bcd)", .case_insensitive = false, .input = "abcd", .from = 0, .expected = .{ .start = 0, .end = 4, .captures = &.{ "a", "bcd" } } },
    .{ .pattern = "ab|abcd", .case_insensitive = true, .input = "abcd", .from = 0, .expected = .{ .start = 0, .end = 2, .captures = &.{} } },
    .{ .pattern = "ab|abcd", .case_insensitive = false, .input = "abcd abcd", .from = 2, .expected = .{ .start = 5, .end = 7, .captures = &.{} } },
    .{ .pattern = "(?:ab)?(?:abcd)?", .case_insensitive = false, .input = "abcd", .from = 0, .expected = .{ .start = 0, .end = 2, .captures = &.{} } },
    .{ .pattern = "(?:ab)?(?:abcd)?", .case_insensitive = false, .input = "xabcd", .from = 1, .expected = .{ .start = 1, .end = 3, .captures = &.{} } },
    .{ .pattern = "in|instanceof", .case_insensitive = true, .input = "instanceof", .from = 0, .expected = .{ .start = 0, .end = 2, .captures = &.{} } },
    .{ .pattern = "a*(?:ab)?", .case_insensitive = false, .input = "aab", .from = 0, .expected = .{ .start = 0, .end = 2, .captures = &.{} } },
    .{ .pattern = "(\\d){2,4}", .case_insensitive = false, .input = "12", .from = 0, .expected = .{ .start = 0, .end = 2, .captures = &.{"2"} } },
    .{ .pattern = "(\\d){2,4}", .case_insensitive = false, .input = "12345", .from = 0, .expected = .{ .start = 0, .end = 4, .captures = &.{"4"} } },
    .{ .pattern = "([a-z]){1,3}", .case_insensitive = false, .input = "ab1", .from = 0, .expected = .{ .start = 0, .end = 2, .captures = &.{"b"} } },
    .{ .pattern = "(a){1,3}", .case_insensitive = false, .input = "a", .from = 0, .expected = .{ .start = 0, .end = 1, .captures = &.{"a"} } },
    .{ .pattern = "(a){2,3}", .case_insensitive = false, .input = "aa", .from = 0, .expected = .{ .start = 0, .end = 2, .captures = &.{"a"} } },
    .{ .pattern = "(a*){3}", .case_insensitive = false, .input = "aa", .from = 0, .expected = .{ .start = 0, .end = 2, .captures = &.{""} } },
    .{ .pattern = "(a*){2,3}", .case_insensitive = false, .input = "aa", .from = 0, .expected = .{ .start = 0, .end = 2, .captures = &.{""} } },
    .{ .pattern = "(a?){2}", .case_insensitive = false, .input = "a", .from = 0, .expected = .{ .start = 0, .end = 1, .captures = &.{""} } },
    .{ .pattern = "(?:(a)?b){1,3}", .case_insensitive = false, .input = "abb", .from = 0, .expected = .{ .start = 0, .end = 3, .captures = &.{null} } },
    .{ .pattern = "(?:(a)?b){2,}", .case_insensitive = false, .input = "ababb", .from = 0, .expected = .{ .start = 0, .end = 5, .captures = &.{null} } },
    .{ .pattern = "(a?)+", .case_insensitive = false, .input = "", .from = 0, .expected = .{ .start = 0, .end = 0, .captures = &.{""} } },
    .{ .pattern = "(a?)*", .case_insensitive = false, .input = "b", .from = 0, .expected = .{ .start = 0, .end = 0, .captures = &.{null} } },
    .{ .pattern = "(a*)?", .case_insensitive = false, .input = "b", .from = 0, .expected = .{ .start = 0, .end = 0, .captures = &.{null} } },
    .{ .pattern = "(?:(a)*){2}", .case_insensitive = false, .input = "a", .from = 0, .expected = .{ .start = 0, .end = 1, .captures = &.{null} } },
    .{ .pattern = "b*((?:a?b?)*)", .case_insensitive = false, .input = "bab", .from = 0, .expected = .{ .start = 0, .end = 3, .captures = &.{"ab"} } },
    .{ .pattern = "((a?){2})?", .case_insensitive = false, .input = "", .from = 0, .expected = .{ .start = 0, .end = 0, .captures = &.{ null, null } } },
    .{ .pattern = "(?:(a)|b)*", .case_insensitive = false, .input = "ab", .from = 0, .expected = .{ .start = 0, .end = 2, .captures = &.{null} } },
    .{ .pattern = "(a)*b", .case_insensitive = false, .input = "aab", .from = 0, .expected = .{ .start = 0, .end = 3, .captures = &.{"a"} } },
    .{ .pattern = "(?:(a)b)*", .case_insensitive = false, .input = "abab", .from = 0, .expected = .{ .start = 0, .end = 4, .captures = &.{"a"} } },
    .{ .pattern = "(z)((a+)?(b+)?(c))*", .case_insensitive = false, .input = "zaacbbbcac", .from = 0, .expected = .{ .start = 0, .end = 10, .captures = &.{ "z", "ac", "a", null, "c" } } },
    .{ .pattern = "((a)|b)+", .case_insensitive = false, .input = "ab", .from = 0, .expected = .{ .start = 0, .end = 2, .captures = &.{ "b", null } } },
    .{ .pattern = "(\\w+)\\s(\\w+)", .case_insensitive = false, .input = "hello big world", .from = 0, .expected = .{ .start = 0, .end = 9, .captures = &.{ "hello", "big" } } },
    .{ .pattern = "^(\\d+)-(\\d+)$", .case_insensitive = false, .input = "10-20", .from = 0, .expected = .{ .start = 0, .end = 5, .captures = &.{ "10", "20" } } },
    .{ .pattern = "(a+)(a+)", .case_insensitive = false, .input = "aaaa", .from = 0, .expected = .{ .start = 0, .end = 4, .captures = &.{ "aaa", "a" } } },
    .{ .pattern = "(a*)(a*)", .case_insensitive = false, .input = "aaa", .from = 0, .expected = .{ .start = 0, .end = 3, .captures = &.{ "aaa", "" } } },
    .{ .pattern = "x(a|b)*y", .case_insensitive = false, .input = "xababy", .from = 0, .expected = .{ .start = 0, .end = 6, .captures = &.{"b"} } },
    .{ .pattern = "(.)(.)", .case_insensitive = false, .input = "ab", .from = 0, .expected = .{ .start = 0, .end = 2, .captures = &.{ "a", "b" } } },
    .{ .pattern = "\\b(\\w)", .case_insensitive = false, .input = " hi", .from = 0, .expected = .{ .start = 1, .end = 2, .captures = &.{"h"} } },
    .{ .pattern = "(a|b|c)+?", .case_insensitive = false, .input = "abc", .from = 0, .expected = .{ .start = 0, .end = 1, .captures = &.{"a"} } },
};

fn expectLeftmostFirst(c: LeftmostFirstCase, found: ?Match) !void {
    const want = c.expected orelse {
        if (found) |m| {
            std.debug.print("unexpected match {d}..{d}: /{s}/ on {s}\n", .{ m.start, m.end, c.pattern, c.input });
            return error.TestUnexpectedMatch;
        }
        return;
    };
    const m = found orelse {
        std.debug.print("no match: /{s}/ on {s}\n", .{ c.pattern, c.input });
        return error.TestExpectedMatch;
    };
    if (m.start != want.start or m.end != want.end) {
        std.debug.print("/{s}/ on {s}: got {d}..{d}, want {d}..{d}\n", .{ c.pattern, c.input, m.start, m.end, want.start, want.end });
        return error.TestWrongSpan;
    }
    for (want.captures, 0..) |cap, i| {
        const present = if (m.captures_present.len > i) m.captures_present[i] else i < m.captures.len;
        if (cap) |text| {
            if (!present or !std.mem.eql(u8, text, m.captures[i])) {
                std.debug.print("/{s}/ on {s}: group {d} want \"{s}\"\n", .{ c.pattern, c.input, i + 1, text });
                return error.TestWrongCapture;
            }
        } else if (present) {
            std.debug.print("/{s}/ on {s}: group {d} want undefined, got \"{s}\"\n", .{ c.pattern, c.input, i + 1, m.captures[i] });
            return error.TestWrongCapture;
        }
    }
}

test "ECMAScript captures and match ends are leftmost-first" {
    const allocator = std.testing.allocator;
    for (leftmost_first_cases) |c| {
        var regex = try Regex.compileWithFlags(allocator, c.pattern, .{ .ecmascript = true, .case_insensitive = c.case_insensitive });
        defer regex.deinit();
        var m = regex.matcher();
        defer m.deinit();
        // findFrom (exec with lastIndex) and, from 0, find (the DFA path).
        var found = try m.findFrom(c.input, c.from);
        defer if (found) |*f| f.deinit(allocator);
        try expectLeftmostFirst(c, found);
        if (c.from == 0) {
            var again = try regex.find(c.input);
            defer if (again) |*f| f.deinit(allocator);
            try expectLeftmostFirst(c, again);
        }
    }
}

test "ECMAScript bounded backtracking repeats retain the last accepted captures" {
    const allocator = std.testing.allocator;
    // Node-confirmed RepeatMatcher cases, including unsuccessful additional
    // iterations, required empty matches, capture clearing, and direction/lazy controls.
    const cases = [_]LeftmostFirstCase{
        .{ .pattern = "(?=a)(a){1,3}", .case_insensitive = false, .input = "a", .from = 0, .expected = .{ .start = 0, .end = 1, .captures = &.{"a"} } },
        .{ .pattern = "(?=a)(a|b){1,3}", .case_insensitive = false, .input = "ab", .from = 0, .expected = .{ .start = 0, .end = 2, .captures = &.{"b"} } },
        .{ .pattern = "(?:((a+){2,3}|(.){3})){0,3}", .case_insensitive = false, .input = "aABBb", .from = 0, .expected = .{ .start = 0, .end = 3, .captures = &.{ "aAB", null, "B" } } },
        .{ .pattern = "((a?){1,2}|b)", .case_insensitive = false, .input = "", .from = 0, .expected = .{ .start = 0, .end = 0, .captures = &.{ "", "" } } },
        .{ .pattern = "(?=a)(?:(a)|b){1,3}", .case_insensitive = false, .input = "ab", .from = 0, .expected = .{ .start = 0, .end = 2, .captures = &.{null} } },
        .{ .pattern = "(?=a)(a){1,3}", .case_insensitive = false, .input = "aaa", .from = 0, .expected = .{ .start = 0, .end = 3, .captures = &.{"a"} } },
        .{ .pattern = "(?<=(a){1,3})b", .case_insensitive = false, .input = "aab", .from = 0, .expected = .{ .start = 2, .end = 3, .captures = &.{"a"} } },
        .{ .pattern = "(?=a)(a){1,3}?", .case_insensitive = false, .input = "aaa", .from = 0, .expected = .{ .start = 0, .end = 1, .captures = &.{"a"} } },
    };
    for (cases) |c| {
        var regex = try Regex.compileWithFlags(allocator, c.pattern, .{ .ecmascript = true });
        defer regex.deinit();
        // A fixed ASCII assertion can now use the NFA with a simple
        // bounded capture; the other histories still need the backtracker.
        const expected_engine: EngineType = if (std.mem.eql(u8, c.pattern, "(?=a)(a){1,3}")) .thompson_nfa else .backtracking;
        try std.testing.expectEqual(expected_engine, regex.engine_type);
        var found = try regex.findFrom(c.input, c.from);
        defer if (found) |*f| f.deinit(allocator);
        try expectLeftmostFirst(c, found);
        var again = try regex.find(c.input);
        defer if (again) |*f| f.deinit(allocator);
        try expectLeftmostFirst(c, again);
    }
}

test "ECMAScript patterns bound for linear engines are not refused as ReDoS risks" {
    const allocator = std.testing.allocator;
    // Nested quantifiers are valid JavaScript, and the Thompson engines match
    // them in linear time; node v24.4.1's answers.
    {
        var regex = try Regex.compileWithFlags(allocator, "(a*)*", .{ .ecmascript = true });
        defer regex.deinit();
        try std.testing.expectEqual(EngineType.thompson_nfa, regex.engine_type);
        var m = (try regex.find("b")).?;
        defer m.deinit(allocator);
        try std.testing.expectEqual([2]usize{ 0, 0 }, [2]usize{ m.start, m.end });
        try std.testing.expect(!m.captures_present[0]);
    }
    {
        var regex = try Regex.compileWithFlags(allocator, "(a+)+", .{ .ecmascript = true });
        defer regex.deinit();
        var m = (try regex.find("aaa")).?;
        defer m.deinit(allocator);
        try std.testing.expectEqualStrings("aaa", m.slice);
        try std.testing.expectEqualStrings("aaa", m.captures[0]);
    }
    {
        var regex = try Regex.compileWithFlags(allocator, "(?:a*)+b", .{ .ecmascript = true });
        defer regex.deinit();
        var m = (try regex.find("aab")).?;
        defer m.deinit(allocator);
        try std.testing.expectEqualStrings("aab", m.slice);
    }
    // A pattern the backtracker would run keeps the refusal, and so does
    // every dialect other than ECMAScript.
    try std.testing.expectError(RegexError.PatternTooComplex, Regex.compileWithFlags(allocator, "(a+)+\\1", .{ .ecmascript = true }));
    try std.testing.expectError(RegexError.PatternTooComplex, Regex.compile(allocator, "(a*)*"));
    // Nested counted repeats expand past the NFA size cap. The cap is
    // ECMAScript-only, so other dialects still build the million states this
    // pattern needs -- there the analyzer, not a size limit, is the guard.
    try std.testing.expectError(RegexError.PatternTooComplex, Regex.compileWithFlags(allocator, "(a{1000}){1000}", .{ .ecmascript = true }));
}

test "ECMAScript reports JavaScriptCore's reason for assertion and group-start defects" {
    const allocator = std.testing.allocator;
    const Case = struct {
        pattern: []const u8,
        unicode: bool = false,
        // null means the pattern compiles.
        reason: ?CompileErrorReason,
    };
    // Every row is what JavaScriptCore reports for the same pattern (Safari
    // 26 / home-tool), which is also where node v24.4.1 accepts and rejects.
    const cases = [_]Case{
        .{ .pattern = "^*", .reason = .nothing_to_repeat },
        .{ .pattern = "^+", .reason = .nothing_to_repeat },
        .{ .pattern = "^?", .reason = .nothing_to_repeat },
        .{ .pattern = "^{2}", .reason = .nothing_to_repeat },
        .{ .pattern = "$*", .reason = .nothing_to_repeat },
        .{ .pattern = "\\b*", .reason = .nothing_to_repeat },
        .{ .pattern = "\\B*", .reason = .nothing_to_repeat },
        .{ .pattern = "^*", .unicode = true, .reason = .nothing_to_repeat },
        // Annex B: a lookahead -- and only a lookahead -- is quantifiable, and
        // only outside unicode mode.
        .{ .pattern = "(?=a)*", .reason = null },
        .{ .pattern = "(?!a)*", .reason = null },
        .{ .pattern = "(?=a){2}", .reason = null },
        .{ .pattern = "(?=a)*", .unicode = true, .reason = .nothing_to_repeat },
        .{ .pattern = "(?<=a)*", .reason = .invalid_quantifier },
        .{ .pattern = "(?<!a)*", .reason = .invalid_quantifier },
        .{ .pattern = "(?<=a)*", .unicode = true, .reason = .invalid_quantifier },
        // `(?` takes only `:`, `=`, `!` and `<` in ECMAScript.
        .{ .pattern = "(?P<x>a)", .reason = .unrecognized_character_after_group_start },
        .{ .pattern = "(?P=x)", .reason = .unrecognized_character_after_group_start },
        .{ .pattern = "(?i)a", .reason = .unrecognized_character_after_group_start },
        // Unicode mode drops Annex B's literal readings of `{`, `]` and `}`.
        .{ .pattern = "a{", .unicode = true, .reason = .incomplete_quantifier_for_unicode_pattern },
        .{ .pattern = "a{1", .unicode = true, .reason = .incomplete_quantifier_for_unicode_pattern },
        .{ .pattern = "]", .unicode = true, .reason = .unmatched_bracket_for_unicode_pattern },
        .{ .pattern = "}", .unicode = true, .reason = .unmatched_bracket_for_unicode_pattern },
        .{ .pattern = "a{", .reason = null },
        .{ .pattern = "]", .reason = null },
        .{ .pattern = "}", .reason = null },
    };
    for (cases) |c| {
        var diagnostic: ?CompileErrorReason = null;
        const flags = common.CompileFlags{ .ecmascript = true, .unicode = c.unicode };
        if (Regex.compileWithFlagsDiagnostic(allocator, c.pattern, flags, &diagnostic)) |compiled| {
            var r = compiled;
            defer r.deinit();
            if (c.reason != null) {
                std.debug.print("expected /{s}/{s} to be refused\n", .{ c.pattern, if (c.unicode) "u" else "" });
                return error.TestUnexpectedResult;
            }
        } else |_| {
            if (c.reason) |want| {
                if (diagnostic != want) {
                    std.debug.print("/{s}/{s}: want {s}, got {?s}\n", .{
                        c.pattern,
                        if (c.unicode) "u" else "",
                        @tagName(want),
                        if (diagnostic) |d| @tagName(d) else null,
                    });
                    return error.TestUnexpectedResult;
                }
            } else {
                std.debug.print("expected /{s}/{s} to compile\n", .{ c.pattern, if (c.unicode) "u" else "" });
                return error.TestUnexpectedResult;
            }
        }
    }
    // Other dialects keep the pre-ECMAScript readings: `^*` and Python-style
    // named groups still compile.
    var plain = try Regex.compile(allocator, "^*");
    plain.deinit();
    var named = try Regex.compile(allocator, "(?P<x>a)");
    named.deinit();
}

test "ECMAScript capture-free ordered quantifiers use the NFA" {
    const allocator = std.testing.allocator;
    // Node-generated spans exercise leftmost branch priority, greedy/lazy
    // boundaries, empty iterations and repeated comment scanners. Captures,
    // backreferences and Unicode-only constructs keep their existing dispatch.
    const Case = struct { pattern: []const u8, input: []const u8, from: usize, span: ?[2]usize };
    const cases = [_]Case{
        .{ .pattern = "(?:\\s|\\/\\/.*|\\/\\*[^]*?\\*\\/)*", .input = "baabc", .from = 1, .span = .{ 1, 1 } },
        .{ .pattern = "(?:\\s|\\/\\/.*|\\/\\*[^]*?\\*\\/)*", .input = " /*comment*/ //line\n ", .from = 0, .span = .{ 0, 21 } },
        .{ .pattern = "(?:\\s|\\/\\/.*|\\/\\*[^]*?\\*\\/)*", .input = "/*first*/ /*second*/ !", .from = 0, .span = .{ 0, 21 } },
        .{ .pattern = "(?:\\s|\\/\\/.*|\\/\\*[^]*?\\*\\/)*", .input = "/*unterminated", .from = 0, .span = .{ 0, 0 } },
        .{ .pattern = "a*?", .input = "", .from = 0, .span = .{ 0, 0 } },
        .{ .pattern = "a*?", .input = "aaab", .from = 0, .span = .{ 0, 0 } },
        .{ .pattern = "a*?", .input = "ababac", .from = 0, .span = .{ 0, 0 } },
        .{ .pattern = "a*?", .input = "baabc", .from = 1, .span = .{ 1, 1 } },
        .{ .pattern = "a+?", .input = "", .from = 0, .span = null },
        .{ .pattern = "a+?", .input = "aaab", .from = 0, .span = .{ 0, 1 } },
        .{ .pattern = "a+?", .input = "ababac", .from = 0, .span = .{ 0, 1 } },
        .{ .pattern = "a+?", .input = "baabc", .from = 1, .span = .{ 1, 2 } },
        .{ .pattern = "a??", .input = "", .from = 0, .span = .{ 0, 0 } },
        .{ .pattern = "a??", .input = "aaab", .from = 0, .span = .{ 0, 0 } },
        .{ .pattern = "a??", .input = "ababac", .from = 0, .span = .{ 0, 0 } },
        .{ .pattern = "a??", .input = "baabc", .from = 1, .span = .{ 1, 1 } },
        .{ .pattern = "a{1,3}?", .input = "", .from = 0, .span = null },
        .{ .pattern = "a{1,3}?", .input = "aaab", .from = 0, .span = .{ 0, 1 } },
        .{ .pattern = "a{1,3}?", .input = "ababac", .from = 0, .span = .{ 0, 1 } },
        .{ .pattern = "a{1,3}?", .input = "baabc", .from = 1, .span = .{ 1, 2 } },
        .{ .pattern = "(?:a|ab)*", .input = "", .from = 0, .span = .{ 0, 0 } },
        .{ .pattern = "(?:a|ab)*", .input = "aaab", .from = 0, .span = .{ 0, 3 } },
        .{ .pattern = "(?:a|ab)*", .input = "ababac", .from = 0, .span = .{ 0, 1 } },
        .{ .pattern = "(?:a|ab)*", .input = "baabc", .from = 1, .span = .{ 1, 3 } },
        .{ .pattern = "(?:ab|a)*", .input = "", .from = 0, .span = .{ 0, 0 } },
        .{ .pattern = "(?:ab|a)*", .input = "aaab", .from = 0, .span = .{ 0, 4 } },
        .{ .pattern = "(?:ab|a)*", .input = "ababac", .from = 0, .span = .{ 0, 5 } },
        .{ .pattern = "(?:ab|a)*", .input = "baabc", .from = 1, .span = .{ 1, 4 } },
        .{ .pattern = "(?:a|ab)+?b", .input = "", .from = 0, .span = null },
        .{ .pattern = "(?:a|ab)+?b", .input = "aaab", .from = 0, .span = .{ 0, 4 } },
        .{ .pattern = "(?:a|ab)+?b", .input = "ababac", .from = 0, .span = .{ 0, 2 } },
        .{ .pattern = "(?:a|ab)+?b", .input = "baabc", .from = 1, .span = .{ 1, 4 } },
        .{ .pattern = "(?:a|ab)*?b", .input = "", .from = 0, .span = null },
        .{ .pattern = "(?:a|ab)*?b", .input = "aaab", .from = 0, .span = .{ 0, 4 } },
        .{ .pattern = "(?:a|ab)*?b", .input = "ababac", .from = 0, .span = .{ 0, 2 } },
        .{ .pattern = "(?:a|ab)*?b", .input = "baabc", .from = 1, .span = .{ 1, 4 } },
        .{ .pattern = "(?:a?|b)*", .input = "", .from = 0, .span = .{ 0, 0 } },
        .{ .pattern = "(?:a?|b)*", .input = "aaab", .from = 0, .span = .{ 0, 4 } },
        .{ .pattern = "(?:a?|b)*", .input = "ababac", .from = 0, .span = .{ 0, 5 } },
        .{ .pattern = "(?:a?|b)*", .input = "baabc", .from = 1, .span = .{ 1, 4 } },
        .{ .pattern = "(?:a*|b)*", .input = "", .from = 0, .span = .{ 0, 0 } },
        .{ .pattern = "(?:a*|b)*", .input = "aaab", .from = 0, .span = .{ 0, 4 } },
        .{ .pattern = "(?:a*|b)*", .input = "ababac", .from = 0, .span = .{ 0, 5 } },
        .{ .pattern = "(?:a*|b)*", .input = "baabc", .from = 1, .span = .{ 1, 4 } },
        .{ .pattern = "(?:a*?)*b", .input = "", .from = 0, .span = null },
        .{ .pattern = "(?:a*?)*b", .input = "aaab", .from = 0, .span = .{ 0, 4 } },
        .{ .pattern = "(?:a*?)*b", .input = "ababac", .from = 0, .span = .{ 0, 2 } },
        .{ .pattern = "(?:a*?)*b", .input = "baabc", .from = 1, .span = .{ 1, 4 } },
        .{ .pattern = "(?:a*?)*?b", .input = "", .from = 0, .span = null },
        .{ .pattern = "(?:a*?)*?b", .input = "aaab", .from = 0, .span = .{ 0, 4 } },
        .{ .pattern = "(?:a*?)*?b", .input = "ababac", .from = 0, .span = .{ 0, 2 } },
        .{ .pattern = "(?:a*?)*?b", .input = "baabc", .from = 1, .span = .{ 1, 4 } },
        .{ .pattern = "(?:ab|a){1,3}?", .input = "", .from = 0, .span = null },
        .{ .pattern = "(?:ab|a){1,3}?", .input = "aaab", .from = 0, .span = .{ 0, 1 } },
        .{ .pattern = "(?:ab|a){1,3}?", .input = "ababac", .from = 0, .span = .{ 0, 2 } },
        .{ .pattern = "(?:ab|a){1,3}?", .input = "baabc", .from = 1, .span = .{ 1, 2 } },
        .{ .pattern = "^(?:a|aa)*b$", .input = "", .from = 0, .span = null },
        .{ .pattern = "^(?:a|aa)*b$", .input = "aaab", .from = 0, .span = .{ 0, 4 } },
        .{ .pattern = "^(?:a|aa)*b$", .input = "ababac", .from = 0, .span = null },
        .{ .pattern = "^(?:a|aa)*b$", .input = "baabc", .from = 1, .span = null },
        .{ .pattern = "^(?:a|aa)*?b$", .input = "", .from = 0, .span = null },
        .{ .pattern = "^(?:a|aa)*?b$", .input = "aaab", .from = 0, .span = .{ 0, 4 } },
        .{ .pattern = "^(?:a|aa)*?b$", .input = "ababac", .from = 0, .span = null },
        .{ .pattern = "^(?:a|aa)*?b$", .input = "baabc", .from = 1, .span = null },
        .{ .pattern = "(?:ab|a)*?c", .input = "", .from = 0, .span = null },
        .{ .pattern = "(?:ab|a)*?c", .input = "aaab", .from = 0, .span = null },
        .{ .pattern = "(?:ab|a)*?c", .input = "ababac", .from = 0, .span = .{ 0, 6 } },
        .{ .pattern = "(?:ab|a)*?c", .input = "baabc", .from = 1, .span = .{ 1, 5 } },
        .{ .pattern = "(?:a*|b)+?c", .input = "", .from = 0, .span = null },
        .{ .pattern = "(?:a*|b)+?c", .input = "aaab", .from = 0, .span = null },
        .{ .pattern = "(?:a*|b)+?c", .input = "ababac", .from = 0, .span = .{ 0, 6 } },
        .{ .pattern = "(?:a*|b)+?c", .input = "baabc", .from = 1, .span = .{ 1, 5 } },
        .{ .pattern = "(?:ab|a){0,3}c", .input = "", .from = 0, .span = null },
        .{ .pattern = "(?:ab|a){0,3}c", .input = "aaab", .from = 0, .span = null },
        .{ .pattern = "(?:ab|a){0,3}c", .input = "ababac", .from = 0, .span = .{ 0, 6 } },
        .{ .pattern = "(?:ab|a){0,3}c", .input = "baabc", .from = 1, .span = .{ 1, 5 } },
        .{ .pattern = "(?:a??|b)*c", .input = "", .from = 0, .span = null },
        .{ .pattern = "(?:a??|b)*c", .input = "aaab", .from = 0, .span = null },
        .{ .pattern = "(?:a??|b)*c", .input = "ababac", .from = 0, .span = .{ 0, 6 } },
        .{ .pattern = "(?:a??|b)*c", .input = "baabc", .from = 1, .span = .{ 1, 5 } },
    };
    for (cases) |c| {
        var re = try Regex.compileWithFlags(allocator, c.pattern, .{ .ecmascript = true });
        defer re.deinit();
        try std.testing.expectEqual(EngineType.thompson_nfa, re.engine_type);
        var matcher = re.matcher();
        defer matcher.deinit();
        var found = try matcher.findFrom(c.input, c.from);
        defer if (found) |*m| m.deinit(allocator);
        if (c.span) |want| {
            const m = found orelse {
                std.debug.print("missing match: {s} input={any} from={d}\n", .{ c.pattern, c.input, c.from });
                return error.TestExpectedMatch;
            };
            if (!std.meta.eql(want, [2]usize{ m.start, m.end }))
                std.debug.print("span mismatch: {s} input={any} from={d}\n", .{ c.pattern, c.input, c.from });
            try std.testing.expectEqual(want, [2]usize{ m.start, m.end });
        } else try std.testing.expect(found == null);
    }
}

test "ECMAScript capture-free ordered dispatch preserves backtracking guards" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "(a)*?", "a*?(?=b+)", "(a)\\1", "(?i:a*?)" }) |pattern| {
        var re = try Regex.compileWithFlags(allocator, pattern, .{ .ecmascript = true });
        defer re.deinit();
        try std.testing.expectEqual(EngineType.backtracking, re.engine_type);
    }
    try std.testing.expectError(RegexError.PatternTooComplex, Regex.compileWithFlags(allocator, "(a+)+\\1", .{ .ecmascript = true }));
    try std.testing.expectError(RegexError.PatternTooComplex, Regex.compile(allocator, "(a*)*"));
    try std.testing.expectError(RegexError.PatternTooComplex, Regex.compileWithFlags(allocator, "(?:a{1000}){1000}", .{ .ecmascript = true }));
}

test "ECMAScript literal assertions retain ordered spans and a spanning capture" {
    const allocator = std.testing.allocator;
    const Case = struct { pattern: []const u8, input: []const u8, from: usize, span: ?[2]usize, capture: ?[]const u8 };
    // Node spans converted from UTF-16 indices to the library's byte offsets.
    const cases = [_]Case{
        .{ .pattern = "(?<=image-set\\()((?:[\\w-]{1,256}\\([^)]*\\)|[^)])*)(?=\\))", .input = "image-set(foo(a), bar(b))", .from = 0, .span = .{ 10, 24 }, .capture = "foo(a), bar(b)" },
        .{ .pattern = "(?<=image-set\\()((?:[\\w-]{1,256}\\([^)]*\\)|[^)])*)(?=\\))", .input = "image-set(foo(a), bar(b))", .from = 1, .span = .{ 10, 24 }, .capture = "foo(a), bar(b)" },
        .{ .pattern = "(?<=image-set\\()((?:[\\w-]{1,256}\\([^)]*\\)|[^)])*)(?=\\))", .input = "image-set(foo(a), bar(b))", .from = 10, .span = .{ 10, 24 }, .capture = "foo(a), bar(b)" },
        .{ .pattern = "(?<=image-set\\()((?:[\\w-]{1,256}\\([^)]*\\)|[^)])*)(?=\\))", .input = "", .from = 0, .span = null, .capture = null },
        .{ .pattern = "(?<=pre)(?:ab|a)*?b(?=!)", .input = "preaaab!", .from = 0, .span = .{ 3, 7 }, .capture = null },
        .{ .pattern = "(?<=pre)(?:ab|a)*?b(?=!)", .input = "preaaab!", .from = 1, .span = .{ 3, 7 }, .capture = null },
        .{ .pattern = "(?<=pre)(?:ab|a)*?b(?=!)", .input = "zpreaaab!q", .from = 0, .span = .{ 4, 8 }, .capture = null },
        .{ .pattern = "(?<=pre)(?:ab|a)*?b(?=!)", .input = "", .from = 0, .span = null, .capture = null },
        .{ .pattern = "(?<!pre)(?:ab|a)*b(?!x)", .input = "b", .from = 0, .span = .{ 0, 1 }, .capture = null },
        .{ .pattern = "(?<!pre)(?:ab|a)*b(?!x)", .input = "ab", .from = 0, .span = .{ 0, 2 }, .capture = null },
        .{ .pattern = "(?<!pre)(?:ab|a)*b(?!x)", .input = "ab", .from = 1, .span = .{ 1, 2 }, .capture = null },
        .{ .pattern = "(?<!pre)(?:ab|a)*b(?!x)", .input = "", .from = 0, .span = null, .capture = null },
        .{ .pattern = "(?<=pre)((?:ab|a)*?b)(?=!)", .input = "preaaab!", .from = 0, .span = .{ 3, 7 }, .capture = "aaab" },
        .{ .pattern = "(?<=pre)((?:ab|a)*?b)(?=!)", .input = "preaaab!", .from = 1, .span = .{ 3, 7 }, .capture = "aaab" },
        .{ .pattern = "(?<=pre)((?:ab|a)*?b)(?=!)", .input = "zpreaaab!q", .from = 0, .span = .{ 4, 8 }, .capture = "aaab" },
        .{ .pattern = "(?<=pre)((?:ab|a)*?b)(?=!)", .input = "", .from = 0, .span = null, .capture = null },
        .{ .pattern = "(?<=pre)(?<body>(?:ab|a)*b)(?!x)", .input = "preaaab!", .from = 0, .span = .{ 3, 7 }, .capture = "aaab" },
        .{ .pattern = "(?<=pre)(?<body>(?:ab|a)*b)(?!x)", .input = "preaaab!", .from = 1, .span = .{ 3, 7 }, .capture = "aaab" },
        .{ .pattern = "(?<=pre)(?<body>(?:ab|a)*b)(?!x)", .input = "zpreaaab!q", .from = 0, .span = .{ 4, 8 }, .capture = "aaab" },
        .{ .pattern = "(?<=pre)(?<body>(?:ab|a)*b)(?!x)", .input = "", .from = 0, .span = null, .capture = null },
        .{ .pattern = "a(?=b)b", .input = "ab", .from = 0, .span = .{ 0, 2 }, .capture = null },
        .{ .pattern = "a(?=b)b", .input = "abc", .from = 0, .span = .{ 0, 2 }, .capture = null },
        .{ .pattern = "a(?=b)b", .input = "baabc", .from = 0, .span = .{ 2, 4 }, .capture = null },
        .{ .pattern = "a(?=b)b", .input = "", .from = 0, .span = null, .capture = null },
        .{ .pattern = "a(?!b)c", .input = "ac", .from = 0, .span = .{ 0, 2 }, .capture = null },
        .{ .pattern = "a(?!b)c", .input = "", .from = 0, .span = null, .capture = null },
        .{ .pattern = "(?<=a)b", .input = "ab", .from = 0, .span = .{ 1, 2 }, .capture = null },
        .{ .pattern = "(?<=a)b", .input = "ab", .from = 1, .span = .{ 1, 2 }, .capture = null },
        .{ .pattern = "(?<=a)b", .input = "abc", .from = 0, .span = .{ 1, 2 }, .capture = null },
        .{ .pattern = "(?<=a)b", .input = "", .from = 0, .span = null, .capture = null },
        .{ .pattern = "(?<!a)b", .input = "b", .from = 0, .span = .{ 0, 1 }, .capture = null },
        .{ .pattern = "(?<!a)b", .input = "baabc", .from = 0, .span = .{ 0, 1 }, .capture = null },
        .{ .pattern = "(?<!a)b", .input = "preb!", .from = 0, .span = .{ 3, 4 }, .capture = null },
        .{ .pattern = "(?<!a)b", .input = "", .from = 0, .span = null, .capture = null },
        .{ .pattern = "(?=)a*?", .input = "", .from = 0, .span = .{ 0, 0 }, .capture = null },
        .{ .pattern = "(?=)a*?", .input = "a", .from = 0, .span = .{ 0, 0 }, .capture = null },
        .{ .pattern = "(?=)a*?", .input = "a", .from = 1, .span = .{ 1, 1 }, .capture = null },
        .{ .pattern = "(?!)a", .input = "", .from = 0, .span = null, .capture = null },
        .{ .pattern = "(?<=)a+", .input = "a", .from = 0, .span = .{ 0, 1 }, .capture = null },
        .{ .pattern = "(?<=)a+", .input = "ab", .from = 0, .span = .{ 0, 1 }, .capture = null },
        .{ .pattern = "(?<=)a+", .input = "ac", .from = 0, .span = .{ 0, 1 }, .capture = null },
        .{ .pattern = "(?<=)a+", .input = "", .from = 0, .span = null, .capture = null },
        .{ .pattern = "(?<!)a", .input = "", .from = 0, .span = null, .capture = null },
        .{ .pattern = "(?:(?<=a)b|a)*?c", .input = "ac", .from = 0, .span = .{ 0, 2 }, .capture = null },
        .{ .pattern = "(?:(?<=a)b|a)*?c", .input = "ac", .from = 1, .span = .{ 1, 2 }, .capture = null },
        .{ .pattern = "(?:(?<=a)b|a)*?c", .input = "abc", .from = 0, .span = .{ 0, 3 }, .capture = null },
        .{ .pattern = "(?:(?<=a)b|a)*?c", .input = "", .from = 0, .span = null, .capture = null },
        .{ .pattern = "(?<=pre)(a*?)(?=b)", .input = "preaaab!", .from = 0, .span = .{ 3, 6 }, .capture = "aaa" },
        .{ .pattern = "(?<=pre)(a*?)(?=b)", .input = "preaaab!", .from = 1, .span = .{ 3, 6 }, .capture = "aaa" },
        .{ .pattern = "(?<=pre)(a*?)(?=b)", .input = "xpreabx", .from = 0, .span = .{ 4, 5 }, .capture = "a" },
        .{ .pattern = "(?<=pre)(a*?)(?=b)", .input = "", .from = 0, .span = null, .capture = null },
        .{ .pattern = "(?<=pre)(a*)(?=a)", .input = "preaaab!", .from = 0, .span = .{ 3, 5 }, .capture = "aa" },
        .{ .pattern = "(?<=pre)(a*)(?=a)", .input = "preaaab!", .from = 1, .span = .{ 3, 5 }, .capture = "aa" },
        .{ .pattern = "(?<=pre)(a*)(?=a)", .input = "xpreabx", .from = 0, .span = .{ 4, 4 }, .capture = "" },
        .{ .pattern = "(?<=pre)(a*)(?=a)", .input = "", .from = 0, .span = null, .capture = null },
        .{ .pattern = "(?<=pre)(a*?)(?=a)", .input = "preaaab!", .from = 0, .span = .{ 3, 3 }, .capture = "" },
        .{ .pattern = "(?<=pre)(a*?)(?=a)", .input = "preaaab!", .from = 1, .span = .{ 3, 3 }, .capture = "" },
        .{ .pattern = "(?<=pre)(a*?)(?=a)", .input = "xpreabx", .from = 0, .span = .{ 4, 4 }, .capture = "" },
        .{ .pattern = "(?<=pre)(a*?)(?=a)", .input = "", .from = 0, .span = null, .capture = null },
        .{ .pattern = "(?<=(?:pre))(a+)(?!b)", .input = "preaaab!", .from = 0, .span = .{ 3, 5 }, .capture = "aa" },
        .{ .pattern = "(?<=(?:pre))(a+)(?!b)", .input = "preaaab!", .from = 1, .span = .{ 3, 5 }, .capture = "aa" },
        .{ .pattern = "(?<=(?:pre))(a+)(?!b)", .input = "preaaaa", .from = 0, .span = .{ 3, 7 }, .capture = "aaaa" },
        .{ .pattern = "(?<=(?:pre))(a+)(?!b)", .input = "", .from = 0, .span = null, .capture = null },
    };
    for (cases) |c| {
        var re = try Regex.compileWithFlags(allocator, c.pattern, .{ .ecmascript = true });
        defer re.deinit();
        try std.testing.expectEqual(EngineType.thompson_nfa, re.engine_type);
        try std.testing.expect(!re.dfaEligible());
        var matcher = re.matcher();
        defer matcher.deinit();
        var m = try matcher.findFrom(c.input, c.from);
        defer if (m) |*found| found.deinit(allocator);
        if (c.span) |span| {
            const found = m orelse return error.TestExpectedMatch;
            try std.testing.expectEqual(span, [2]usize{ found.start, found.end });
            if (c.capture) |capture| {
                try std.testing.expectEqual(@as(usize, 1), found.captures.len);
                try std.testing.expect(found.captures_present[0]);
                try std.testing.expectEqualStrings(capture, found.captures[0]);
            } else try std.testing.expectEqual(@as(usize, 0), found.captures.len);
        } else try std.testing.expect(m == null);
    }
}

test "ECMAScript literal assertions preserve searches and dispatch limits" {
    const allocator = std.testing.allocator;
    var re = try Regex.compileWithFlags(allocator, "(?<=pre)a+(?=!)", .{ .ecmascript = true });
    defer re.deinit();
    try std.testing.expect(try re.isMatch("preaa! x prea!"));
    try std.testing.expect(!try re.isMatch("praaaa!"));
    try std.testing.expectEqual(@as(usize, 2), try re.count("preaa! x prea!"));
    const all = try re.findAll(allocator, "preaa! x prea!");
    defer {
        for (all) |*m| m.deinit(allocator);
        allocator.free(all);
    }
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqualStrings("aa", all[0].slice);
    try std.testing.expectEqualStrings("a", all[1].slice);
    try std.testing.expectError(error.NotImplemented, dfa.LazyDfa.init(allocator, &re.nfa, re.flags));
    for ([_][]const u8{ "(?<=(a))b", "(?<=a+)b", "(?<=a|bc)d", "(?<=é)a", "(?<=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)b" }) |pattern| {
        var control = try Regex.compileWithFlags(allocator, pattern, .{ .ecmascript = true });
        defer control.deinit();
        try std.testing.expectEqual(EngineType.backtracking, control.engine_type);
    }
    for ([_]common.CompileFlags{ .{ .ecmascript = true, .unicode = true }, .{ .ecmascript = true, .case_insensitive = true } }) |flags| {
        var control = try Regex.compileWithFlags(allocator, "(?<=pre)a", flags);
        defer control.deinit();
        try std.testing.expectEqual(EngineType.backtracking, control.engine_type);
    }
}

test "compile BCP47 grammar with captured separator choices" {
    const allocator = std.testing.allocator;
    const pattern = "(^(x(-[A-Za-z0-9]{1,8})+)$)|(^(((en-GB-oed)|(i-ami)|(i-bnn)|(i-default)|(i-enochian)|(i-hak)|(i-klingon)|(i-lux)|(i-mingo)|(i-navajo)|(i-pwn)|(i-tao)|(i-tay)|(i-tsu)|(sgn-BE-FR)|(sgn-BE-NL)|(sgn-CH-DE))|((art-lojban)|(cel-gaulish)|(no-bok)|(no-nyn)|(zh-guoyu)|(zh-hakka)|(zh-min)|(zh-min-nan)|(zh-xiang)))$)|(^(([a-zA-Z]{2,3}(-([A-Za-z]{3}(-[A-Za-z]{3}){0,2}))?)|([a-zA-Z]{5,8}))((-|_)([A-Za-z]{4}))?((-|_)([A-Za-z]{2}|\\d{3}))?((-|_)([A-Za-z0-9]{5,8}|(\\d[A-Z-a-z0-9]{3})))*((-|_)((\\d|[A-W]|[Y-Z]|[a-w]|[y-z])(-[A-Za-z0-9]{2,8})+))*((-|_)(x(-[A-Za-z0-9]{1,8})+))?$)";
    for ([_]common.CompileFlags{
        .{ .ecmascript = true },
        .{ .ecmascript = true, .unicode = true },
        .{ .ecmascript = true, .case_insensitive = true },
        .{ .ecmascript = true, .unicode = true, .case_insensitive = true },
    }) |flags| {
        var re = try Regex.compileWithFlags(allocator, pattern, flags);
        defer re.deinit();
        try std.testing.expectEqual(@as(usize, 59), re.capture_count);
        for ([_][]const u8{ "en", "en-US", "en-GB-oed", "x-private", "en-a-foobar", "en_a-foobar", "zh-Hans-CN", "de-CH-1901" }) |input| {
            try std.testing.expect(try re.isMatch(input));
        }
        for ([_][]const u8{ "", "en-", "en--US", "en-a", "en-a-b", "_en", "en-abcdefghi", "x-" }) |input| {
            try std.testing.expect(!try re.isMatch(input));
        }
    }
}

test "ECMAScript single-entry captures preserve actual Svelte ordered matches" {
    const Case = struct {
        pattern: usize,
        input: []const u8,
        matches: []const struct { start: usize, end: usize, groups: []const ?[]const u8 },
    };
    const Fixture = struct { patterns: []const []const u8, cases: []const Case };
    const allocator = std.testing.allocator;
    const fixture = try std.json.parseFromSlice(Fixture, allocator, @embedFile("testdata/single_entry_captures.json"), .{});
    defer fixture.deinit();
    // Node26.10/Bun1.4.4 agree on all34 cases. ECMA-26222.2.2.3:
    // alternation priority and lazy captures must survive the NFA dispatch.
    for (fixture.value.cases) |c| {
        var re = try Regex.compileWithFlags(allocator, fixture.value.patterns[c.pattern], .{ .ecmascript = true });
        defer re.deinit();
        try std.testing.expectEqual(EngineType.thompson_nfa, re.engine_type);
        var from: usize = 0;
        for (c.matches) |expected| {
            var found = try re.findFrom(c.input, from);
            defer if (found) |*m| m.deinit(allocator);
            try expectLeftmostFirst(.{
                .pattern = fixture.value.patterns[c.pattern],
                .case_insensitive = false,
                .input = c.input,
                .from = from,
                .expected = .{ .start = expected.start, .end = expected.end, .captures = expected.groups[1..] },
            }, found);
            try std.testing.expectEqualStrings(expected.groups[0].?, found.?.slice);
            from = expected.end;
        }
        var trailing = try re.findFrom(c.input, from);
        defer if (trailing) |*m| m.deinit(allocator);
        try std.testing.expect(trailing == null);
    }
}

test "single-entry capture dispatch preserves backtracking and size guards" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "(a+)+\\1", "(?:a{1000}){1000}" }) |pattern|
        try std.testing.expectError(RegexError.PatternTooComplex, Regex.compileWithFlags(allocator, pattern, .{ .ecmascript = true }));
    var repeated = try Regex.compileWithFlags(allocator, "(?:(a)|b)*", .{ .ecmascript = true });
    defer repeated.deinit();
    try std.testing.expectEqual(EngineType.backtracking, repeated.engine_type);
    var unicode_complement = try Regex.compileWithFlags(allocator, "([\\S\\s])", .{ .ecmascript = true, .unicode = true });
    defer unicode_complement.deinit();
    try std.testing.expectEqual(EngineType.backtracking, unicode_complement.engine_type);
}

test "single-entry lazy capture retains its empty participating group" {
    const allocator = std.testing.allocator;
    var re = try Regex.compileWithFlags(allocator, "(a*?)", .{ .ecmascript = true });
    defer re.deinit();
    try std.testing.expectEqual(EngineType.thompson_nfa, re.engine_type);
    var found = try re.find("aaa");
    defer if (found) |*m| m.deinit(allocator);
    try expectLeftmostFirst(.{ .pattern = "(a*?)", .case_insensitive = false, .input = "aaa", .from = 0, .expected = .{ .start = 0, .end = 0, .captures = &.{""} } }, found);
}

test "atomic positive assertion tails retain acorn captures and do not retry" {
    const Case = struct { source: []const u8, input: []const u8, match: ?[]const ?[]const u8, index: ?usize, lastIndex: usize, start: ?usize, end: ?usize };
    const Fixture = struct { checks: usize, output: []const Case };
    const allocator = std.testing.allocator;
    const fixture = try std.json.parseFromSlice(Fixture, allocator, @embedFile("testdata/atomic_assertion_tail.json"), .{});
    defer fixture.deinit();
    try std.testing.expectEqual(@as(usize, 19), fixture.value.checks);
    for (fixture.value.output) |c| {
        // Anchoring reproduces sticky exec at lastIndex0 for the native API.
        const pattern = try std.mem.concat(allocator, u8, &.{ "^", c.source });
        defer allocator.free(pattern);
        var re = try Regex.compileWithFlags(allocator, pattern, .{ .ecmascript = true });
        defer re.deinit();
        try std.testing.expectEqual(EngineType.backtracking, re.engine_type);
        var found = try re.findFrom(c.input, 0);
        defer if (found) |*m| m.deinit(allocator);
        const want: ?struct { start: usize, end: usize, captures: []const ?[]const u8 } = if (c.match) |groups|
            .{ .start = c.start.?, .end = c.end.?, .captures = groups[1..] }
        else
            null;
        try expectLeftmostFirst(.{ .pattern = pattern, .case_insensitive = false, .input = c.input, .from = 0, .expected = if (want) |w| .{ .start = w.start, .end = w.end, .captures = w.captures } else null }, found);
        if (c.match) |groups| try std.testing.expectEqualStrings(groups[0].?, found.?.slice);
    }
}

test "atomic assertion classification retains dangerous bodies and forced sequels" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{
        "(?=(((a+)+b)*))\\1", // the body itself can fail exponentially
        "(?=((?:a+)*b))\\1", // a required sequel inside the assertion
        "(?!(?:a+)*)", // negative assertions are outside this rule
        "(?<=(a+)*)", // reverse matching is outside this rule
        "(?:x(?:(?=((?:a+)*))|y))*", // a quantified ancestor through alternation
        "(a+)+\\1", // the existing critical backreference refusal
    }) |pattern| try std.testing.expectError(RegexError.PatternTooComplex, Regex.compileWithFlags(allocator, pattern, .{ .ecmascript = true }));
}

test "atomic assertion tail execution retains the native search step limit" {
    const allocator = std.testing.allocator;
    const fixture = try std.json.parseFromSlice(struct { checks: usize, output: []const struct { source: []const u8 } }, allocator, @embedFile("testdata/atomic_assertion_tail.json"), .{ .ignore_unknown_fields = true });
    defer fixture.deinit();
    const pattern = try std.mem.concat(allocator, u8, &.{ "^", fixture.value.output[0].source });
    defer allocator.free(pattern);
    var re = try Regex.compileWithFlags(allocator, pattern, .{ .ecmascript = true });
    defer re.deinit();
    try std.testing.expectEqual(@as(usize, 10_000_000), re.backtrack_engine.?.max_steps);
    re.backtrack_engine.?.max_steps = 64;
    var input: [512]u8 = undefined;
    @memset(&input, ' ');
    try std.testing.expectError(error.Timeout, re.findFrom(&input, 0));
    // The search ran on a copy: the compiled regex carries no search state.
    try std.testing.expectEqual(@as(usize, 0), re.backtrack_engine.?.step_count);
    try std.testing.expect((try re.searchSteps(&input)).? > 64);
}

test "concurrent searches of one backtracking regex do not share state" {
    // A backtracking search used to run on the engine stored in the `Regex`, so
    // two threads searching the same compiled pattern overwrote each other's
    // input, captures and step count and could miss a match. Every search now
    // runs on its own copy.
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, "(?=[a-z/]*union)[a-z/]+select");
    defer re.deinit();
    try std.testing.expectEqual(EngineType.backtracking, re.engine_type);

    const Search = struct {
        regex: *const Regex,
        input: []const u8,
        expect: bool,
        wrong: usize = 0,
        failed: bool = false,

        fn run(self: *@This()) void {
            for (0..2_000) |_| {
                const found = self.regex.isMatch(self.input) catch {
                    self.failed = true;
                    return;
                };
                if (found != self.expect) self.wrong += 1;
            }
        }
    };
    // The clean input holds both words the pattern needs, and fails only at the
    // lookahead (`-` is outside `[a-z/]`). One without them is rejected by the
    // required-literal prefilter before the engine runs, so it would never
    // share the engine with the other threads, and the test would prove
    // nothing. Without per-search state this test hangs or fails.
    const hit = "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/union/select";
    const miss = "/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/select-union";
    var searches = [_]Search{
        .{ .regex = &re, .input = hit, .expect = true },
        .{ .regex = &re, .input = miss, .expect = false },
        .{ .regex = &re, .input = hit, .expect = true },
        .{ .regex = &re, .input = miss, .expect = false },
    };
    var threads: [searches.len]std.Thread = undefined;
    for (&searches, &threads) |*search, *thread| thread.* = try std.Thread.spawn(.{}, Search.run, .{search});
    for (threads) |thread| thread.join();
    for (searches) |search| {
        try std.testing.expect(!search.failed);
        try std.testing.expectEqual(@as(usize, 0), search.wrong);
    }
    // And nothing was written to the compiled pattern.
    try std.testing.expectEqual(@as(usize, 0), re.backtrack_engine.?.step_count);
}

/// The search DFA `isMatch` left in the pool, if any (test helper).
fn pooledSearchDfa(re: *const Regex) ?*dfa.LazyDfa {
    const pool = re.search_dfa_pool orelse return null;
    for (&pool.slots) |*slot| if (slot.load(.acquire)) |d| return d;
    return null;
}

test "isMatch keeps its search DFA warm between calls" {
    // isMatch used to build its lazy DFA from scratch on every call, which on a
    // large alternation cost milliseconds against microseconds for the search.
    const allocator = std.testing.allocator;
    var re = try Regex.compileWithoutCaptures(allocator, "(?i)[a-z]+\\s+(?:select|insert|update|delete)\\s+[0-9]+", .{ .bytes = true });
    defer re.deinit();
    try std.testing.expect(try re.isMatch("please update 42 rows"));
    const warm = pooledSearchDfa(&re) orelse return error.TestExpectedPooledDfa;
    const states = warm.stateCount();
    try std.testing.expect(states > 0);
    // The same input again walks only states the first call built.
    try std.testing.expect(try re.isMatch("please update 42 rows"));
    try std.testing.expectEqual(warm, pooledSearchDfa(&re).?);
    try std.testing.expectEqual(states, warm.stateCount());
    try std.testing.expect(!try re.isMatch("please update the rows"));
}

test "a regex moved after isMatch keeps matching with its pooled DFA" {
    // A pooled DFA reads the NFA through a pointer to the inline `Regex.nfa`
    // of the copy that built it. Moving the value (an ArrayList that grows, a
    // map that rehashes) left that pointer at freed memory for the next call.
    const allocator = std.testing.allocator;
    const old = try allocator.create(Regex);
    old.* = try Regex.compileWithoutCaptures(allocator, "(?i)(?:select|union|insert)\\s+[a-z]+\\s+from", .{ .bytes = true });
    try std.testing.expect(try old.isMatch("1 union all from t"));
    try std.testing.expect(pooledSearchDfa(old) != null);

    const moved = try allocator.create(Regex);
    defer allocator.destroy(moved);
    moved.* = old.*;
    // Free the first copy's memory, so a stale pointer reads freed bytes.
    allocator.destroy(old);
    defer moved.deinit();
    // New bytes need new DFA states, which reads the NFA.
    try std.testing.expect(!try moved.isMatch("x INSERT 42 from y"));
    try std.testing.expect(try moved.isMatch("x insert rows from y"));
    try std.testing.expect(try moved.isMatch("SELECT name FROM users"));
}

test "isMatch frees a search DFA that grew past what the pool keeps" {
    // `a[ab]{9}c` needs a DFA state for every arrangement of the last ten
    // bytes, so a long a/b input that never reaches a `c` after them builds far
    // more than `retain_states`. Keeping that would let input decide how much
    // memory a compiled pattern holds. The leading `c` keeps the required
    // literal present, so the search reaches the DFA at all.
    const allocator = std.testing.allocator;
    var re = try Regex.compileWithoutCaptures(allocator, "a[ab]{9}c", .{ .bytes = true });
    defer re.deinit();
    var input: [4096]u8 = undefined;
    var x: u32 = 0x9e3779b9;
    for (&input) |*c| {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        c.* = if (x & 1 == 0) 'a' else 'b';
    }
    input[0] = 'c';
    try std.testing.expect(!try re.isMatch(&input));
    try std.testing.expect(pooledSearchDfa(&re) == null);
    // A short input builds few states, and that DFA is kept.
    try std.testing.expect(try re.isMatch("aaaaaaaaaac"));
    const kept = pooledSearchDfa(&re) orelse return error.TestExpectedPooledDfa;
    try std.testing.expect(kept.stateCount() <= Regex.SearchDfaPool.retain_states);
}

test "a lazy quantifier answers isMatch through the search DFA, unchanged" {
    // Laziness only orders an NFA split: it changes which match is reported,
    // never whether one exists, so isMatch may use the search DFA for it.
    const allocator = std.testing.allocator;
    const cases = [_]struct { pattern: []const u8, input: []const u8 }{
        .{ .pattern = "a.*?b", .input = "xxaxxxbxx" },
        .{ .pattern = "a.*?b", .input = "xxaxxx" },
        .{ .pattern = "^x+?$", .input = "xxxx" },
        .{ .pattern = "^x+?$", .input = "xxyx" },
        .{ .pattern = "(?:ab)+?c", .input = "zzababc" },
        .{ .pattern = "(?:ab)+?c", .input = "zzababd" },
        .{ .pattern = "\\bsel.*?ect\\b", .input = "a select b" },
        .{ .pattern = "\\bsel.*?ect\\b", .input = "a selectx b" },
        .{ .pattern = "(?i)union.{0,20}?select", .input = "1 UNION all SELECT 2" },
        .{ .pattern = "(?i)union.{0,20}?select", .input = "1 union with far too many bytes before select" },
    };
    for (cases) |c| {
        var spans = try Regex.compileWithoutCaptures(allocator, c.pattern, .{ .bytes = true, .dot_all = true });
        defer spans.deinit();
        try std.testing.expect(spans.opt_info.has_lazy);
        // The backtracker, which follows lazy semantics step by step.
        var reference = try Regex.compileWithFlags(allocator, c.pattern, .{ .bytes = true, .dot_all = true });
        defer reference.deinit();
        const expected = try reference.isMatch(c.input);
        try std.testing.expectEqual(expected, try spans.isMatch(c.input));
        // A miss can be settled before any engine runs (a required literal is
        // absent); a match is found by the search DFA.
        if (expected) try std.testing.expect(pooledSearchDfa(&spans) != null);
    }
}

test "concurrent isMatch calls on one regex share the DFA pool safely" {
    const allocator = std.testing.allocator;
    var re = try Regex.compileWithoutCaptures(allocator, "(?i)(?:passthru|shell_exec|proc_open|popen|system)\\s*\\(", .{ .bytes = true });
    defer re.deinit();
    const Search = struct {
        regex: *const Regex,
        input: []const u8,
        expect: bool,
        wrong: usize = 0,
        failed: bool = false,

        fn run(self: *@This()) void {
            for (0..2_000) |_| {
                const found = self.regex.isMatch(self.input) catch {
                    self.failed = true;
                    return;
                };
                if (found != self.expect) self.wrong += 1;
            }
        }
    };
    const hit = "name=x&cmd=SHELL_EXEC ('id')";
    const miss = "name=x&cmd=shell exec of nothing";
    var searches: [8]Search = undefined;
    for (&searches, 0..) |*s, i| s.* = .{ .regex = &re, .input = if (i % 2 == 0) hit else miss, .expect = i % 2 == 0 };
    var threads: [searches.len]std.Thread = undefined;
    for (&searches, &threads) |*search, *thread| thread.* = try std.Thread.spawn(.{}, Search.run, .{search});
    for (threads) |thread| thread.join();
    for (searches) |search| {
        try std.testing.expect(!search.failed);
        try std.testing.expectEqual(@as(usize, 0), search.wrong);
    }
}

test "isMatch is correct or reports OutOfMemory at every allocation failure" {
    // The pool is a cache: when its DFA cannot be built, isMatch takes the NFA,
    // and a DFA whose search failed part-way is never handed to another call.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        var re = Regex.compileWithoutCaptures(allocator, "(?i)(?:select|union)\\s+[a-z]+.*?from", .{ .bytes = true }) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        defer re.deinit();
        const inputs = [_]struct { []const u8, bool }{
            .{ "1 UNION ALL SELECT name FROM users", true },
            .{ "select nothing here", false },
            .{ "1 UNION ALL SELECT name FROM users", true },
        };
        for (inputs) |in| {
            if (re.isMatch(in[0])) |found| {
                try std.testing.expectEqual(in[1], found);
            } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        }
        if (!failing.has_induced_failure) break;
    }
}

test "case invariant class sets preserve Node matches and capture boundaries" {
    const allocator = std.testing.allocator;
    const fixture = try std.json.parseFromSlice(struct {
        node: []const u8,
        checks: usize,
        output: []const struct {
            source: []const u8,
            flags: []const u8,
            nfa: bool,
            cases: []const struct {
                input: []const u8,
                from: usize,
                match: ?struct { start: usize, end: usize, captures: []const ?[]const u8 },
            },
        },
    }, allocator, @embedFile("testdata/case_invariant_sets.json"), .{});
    defer fixture.deinit();
    try std.testing.expectEqualStrings("v26.10.0", fixture.value.node);
    var checks: usize = 0;
    for (fixture.value.output) |spec| {
        var re = try Regex.compileWithFlags(allocator, spec.source, .{
            .ecmascript = true,
            .case_insensitive = std.mem.indexOfScalar(u8, spec.flags, 'i') != null,
            .dot_all = std.mem.indexOfScalar(u8, spec.flags, 's') != null,
            .multiline = std.mem.indexOfScalar(u8, spec.flags, 'm') != null,
            .unicode = std.mem.indexOfScalar(u8, spec.flags, 'u') != null,
            .unicode_sets = std.mem.indexOfScalar(u8, spec.flags, 'v') != null,
        });
        defer re.deinit();
        try std.testing.expectEqual(spec.nfa, re.engine_type != .backtracking);
        for (spec.cases) |c| {
            var found = try re.findFrom(c.input, c.from);
            defer if (found) |*m| m.deinit(allocator);
            try expectLeftmostFirst(.{
                .pattern = spec.source,
                .case_insensitive = true,
                .input = c.input,
                .from = c.from,
                .expected = if (c.match) |m| .{ .start = m.start, .end = m.end, .captures = m.captures } else null,
            }, found);
            if (found) |m| try std.testing.expectEqual(re.capture_count, m.captures.len);
            checks += 1;
        }
    }
    try std.testing.expectEqual(fixture.value.checks, checks);
}

test "case invariant class sets retain nested operand and Unicode guards" {
    const utf8_class = @import("utf8_class.zig");
    var one_case: ast.Node.ClassSet = .{ .op = .union_, .items = &.{.{ .range = .{ .lo = 'A', .hi = 'A' } }} };
    // The complete outer set is universal, but folding an unclosed nested
    // complement before the union is not justified by the outer closure.
    const nested: ast.Node.ClassSet = .{ .op = .union_, .items = &.{ .{ .nested = &one_case }, .{ .range = .{ .lo = 0, .hi = 0x10ffff } } } };
    try std.testing.expect(!utf8_class.caseInvariant(&nested));
    one_case.negated = true;
    try std.testing.expect(!utf8_class.caseInvariant(&nested));
    for ([_][]const u8{ "(a+)+\\1", "(?=(((a+)+b)*))\\1" }) |pattern|
        try std.testing.expectError(RegexError.PatternTooComplex, Regex.compileWithFlags(std.testing.allocator, pattern, .{ .ecmascript = true, .case_insensitive = true }));
}

test "backtracker repeats try every end of a loop body with choices" {
    // `*`, `+` and `{n,}` repeated their body at its first end only, so a body
    // ending in a lazy quantifier never grew: `(?:'b*?)*c` missed `'bc`. The
    // spans are PCRE2 10.47's (leftmost-first), the engine is the backtracker.
    const allocator = std.testing.allocator;
    const flags: common.CompileFlags = .{ .bytes = true, .dot_all = true, .multiline = true };
    const cases = [_]struct { pattern: []const u8, input: []const u8, span: ?[2]usize }{
        // The CRS 942xxx reduction the issue came from (zig-utils/zig-regex#57).
        .{ .pattern = "^(?:[^']*?'[^']*?'[^']*?)*?'", .input = "a'b'c'", .span = .{ 0, 6 } },
        .{ .pattern = "^(?:[^']*?'[^']*?'[^']*?)*?'", .input = "1' or 'a'='a", .span = .{ 0, 9 } },
        .{ .pattern = "^(?:[^']*?'[^']*?'[^']*?)*?'", .input = "a'b'", .span = null },
        .{ .pattern = "^(?:[^']*?'[^']*?'[^']*?)*?'", .input = "'''", .span = .{ 0, 1 } },
        .{ .pattern = "^(?:'b*?)*?c", .input = "'bc", .span = .{ 0, 3 } },
        .{ .pattern = "^(?:'b*?)*c", .input = "'bc", .span = .{ 0, 3 } },
        .{ .pattern = "^(?:'b*?)+?c", .input = "'bc", .span = .{ 0, 3 } },
        .{ .pattern = "^(?:'b??)*?c", .input = "'bc", .span = .{ 0, 3 } },
        .{ .pattern = "^(?:'b*?){1,}?c", .input = "'bc", .span = .{ 0, 3 } },
        .{ .pattern = "^(?:a*?'b*?)*'", .input = "a'b'", .span = .{ 0, 4 } },
        // Unanchored, the first start that matches is 0, not 2.
        .{ .pattern = "(?:'b*?)*?c", .input = "'bc", .span = .{ 0, 3 } },
        // The same in a lookbehind, which matches its body in reverse.
        .{ .pattern = "(?<=^(?:b*?')*)x", .input = "b'x", .span = .{ 2, 3 } },
        // A body whose first alternative is a prefix of a later one.
        .{ .pattern = "^(?:a|ab)*c", .input = "abc", .span = .{ 0, 3 } },
        .{ .pattern = "^(?:x(?:ab|a))*bc$", .input = "xabc", .span = .{ 0, 4 } },
        .{ .pattern = "^(?:[^\"]+|\"[^\"]*\")*ab$", .input = "xxab", .span = .{ 0, 4 } },
        // A min of 2 or more: the later required iterations follow the
        // first, even with nothing after the loop (0.5.2 found no match).
        .{ .pattern = "(?:b{1,3}){2,}?", .input = "bbb", .span = .{ 0, 3 } },
        .{ .pattern = "(?:x(?:a|ab)*?){2}", .input = "xabxab", .span = .{ 0, 4 } },
        .{ .pattern = "^(?:x(?:a|ab)*){2}", .input = "xabxab", .span = .{ 0, 5 } },
        .{ .pattern = "(?:a(?:'b*?)*){2}", .input = "a'ba'b", .span = .{ 0, 5 } },
    };
    for (cases) |c| {
        var re = try Regex.compileWithFlags(allocator, c.pattern, flags);
        defer re.deinit();
        try std.testing.expectEqual(EngineType.backtracking, re.engine_type);
        var found = try re.find(c.input);
        defer if (found) |*m| m.deinit(allocator);
        if (c.span) |span| {
            const m = found orelse {
                std.debug.print("no match: {s} on {s}\n", .{ c.pattern, c.input });
                return error.TestExpectedMatch;
            };
            try std.testing.expectEqual(span[0], m.start);
            try std.testing.expectEqual(span[1], m.end);
        } else try std.testing.expect(found == null);
    }
}

/// Every step one backtracking search takes, over both attempts when the
/// loop memo's attempt gives way to a rerun (test helper, for cost gates;
/// `searchSteps` reports the budget a search needs instead).
fn stepsFor(re: *const Regex, input: []const u8) !usize {
    const stored = if (re.backtrack_engine) |*engine| engine else return error.TestExpectedBacktracker;
    var engine = try stored.forSearch();
    defer engine.deinit();
    if (re.searchWith(&engine, input, 0) catch |err| switch (err) {
        error.Timeout => null,
        else => return err,
    }) |found| {
        var discarded = found;
        discarded.deinit(engine.allocator);
    }
    return engine.steps_taken;
}

test "backtracker loops stay linear on long inputs" {
    // A loop whose body has choices runs on the continuation matcher, which
    // takes the body's first end, continues, and comes back only on failure,
    // with failed states remembered (backtrack.SearchMemo). Trying every end
    // up front instead made these quadratic, and plain backtracking would
    // make the misses exponential. Steps are deterministic, so each bound is
    // an exact gate: 40 steps a byte, where quadratic growth would need about
    // 16 million at this size and hit the 10M-step budget.
    const allocator = std.testing.allocator;
    const n = 4000;
    const a_run: [n]u8 = @splat('a');
    const dashes: [2000]u8 = @splat('-');
    const short: [1000]u8 = @splat('a');
    const cases = [_]struct { pattern: []const u8, input: []const u8, span: ?[2]usize }{
        .{ .pattern = "^(?:[^\"]+|\"[^\"]*\")*$", .input = &a_run, .span = .{ 0, n } },
        // An unclosed quote: every decomposition fails.
        .{ .pattern = "^(?:[^\"]+|\"[^\"]*\")*$", .input = &(a_run ++ "\"".*), .span = null },
        .{ .pattern = "^(?:[^\\\\]+|\\\\.)*$", .input = &a_run, .span = .{ 0, n } },
        .{ .pattern = "(?:[a-z]+|-)*$", .input = &a_run, .span = .{ 0, n } },
        .{ .pattern = "(?:[a-z]+|-)*$", .input = &(a_run ++ "!".*), .span = .{ n + 1, n + 1 } },
        .{ .pattern = "^(?:-.*|_)*$", .input = &dashes, .span = .{ 0, dashes.len } },
        .{ .pattern = "(?<!x)(?:\\w+ ?)*$", .input = &(a_run ++ "!".*), .span = .{ n + 1, n + 1 } },
        .{ .pattern = "(?<!x)^(?:\\w+ ?)*$", .input = &(a_run ++ "!".*), .span = null },
        // A lookbehind over a loop, tried at every start position.
        .{ .pattern = "(?<=^(?:\\w+ ?)*)x", .input = &(a_run ++ "x".*), .span = .{ n, n + 1 } },
        // {n,} with a large min stays on the backtracker (min is past the
        // NFA's repeat expansion); 1000 bytes cannot reach 1500 iterations.
        .{ .pattern = "(?:a|aa){1500,}x", .input = &(a_run ++ "x".*), .span = .{ 0, n + 1 } },
        .{ .pattern = "(?:a|aa){1500,}x", .input = &(short ++ "x".*), .span = null },
        .{ .pattern = "^(?:[^']*?'[^']*?'[^']*?)*?'", .input = &(a_run ++ "'b''".*), .span = .{ 0, n + 4 } },
        .{ .pattern = "^(?:a|ab)*c", .input = &(a_run ++ "b".*), .span = null },
    };
    for (cases) |c| {
        var re = try Regex.compile(allocator, c.pattern);
        defer re.deinit();
        try std.testing.expectEqual(EngineType.backtracking, re.engine_type);
        const steps = try stepsFor(&re, c.input);
        if (steps > 40 * c.input.len) {
            std.debug.print("{s} on {d} bytes: {d} steps, bound {d}\n", .{ c.pattern, c.input.len, steps, 40 * c.input.len });
            return error.TestTooManySteps;
        }
        var found = try re.find(c.input);
        defer if (found) |*m| m.deinit(allocator);
        if (c.span) |span| {
            const m = found orelse {
                std.debug.print("no match: {s} on {d} bytes\n", .{ c.pattern, c.input.len });
                return error.TestExpectedMatch;
            };
            try std.testing.expectEqual(span[0], m.start);
            try std.testing.expectEqual(span[1], m.end);
        } else try std.testing.expect(found == null);
    }
}

test "a backtracker loop is correct or reports OutOfMemory at every allocation failure" {
    // The loop memo only prunes: when it cannot allocate, the search goes on
    // without it and still gives the right answer. The loop is in a lookahead
    // body, which runs on the continuation matcher as a whole; that matcher
    // reports allocation failures, while several paths of the concatenation
    // engine still turn them into misses, as in 0.5.2.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        var re = Regex.compile(allocator, "(?=(?:a|ab)*c)") catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        defer re.deinit();
        const inputs = [_]struct { []const u8, ?[2]usize }{
            .{ "ababc", .{ 0, 0 } },
            .{ "ababb", null },
            .{ "xabaabc", .{ 1, 1 } },
        };
        for (inputs) |in| {
            if (re.find(in[0])) |found| {
                var m = found;
                defer if (m) |*x| x.deinit(allocator);
                if (in[1]) |span| {
                    const x = m orelse return error.TestExpectedMatch;
                    try std.testing.expectEqual(span[0], x.start);
                    try std.testing.expectEqual(span[1], x.end);
                } else try std.testing.expect(m == null);
            } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        }
        if (!failing.has_induced_failure) break;
    }
}

test "loops follow their dialect's rules for empty iterations and captures" {
    // A loop over a body with choices runs on the continuation matcher, which
    // must not bring ECMAScript's rules to PCRE-style patterns: PCRE accepts an
    // optional iteration that matches empty and ends the loop, and keeps a
    // group's value from an earlier iteration that a later one does not set.
    // Spans and groups are PCRE2 10.47's and node 24's.
    const allocator = std.testing.allocator;
    const Group = ?[2]usize;
    const cases = [_]struct { pattern: []const u8, input: []const u8, ecmascript: bool, span: [2]usize, group1: ?Group = null }{
        .{ .pattern = "(?:a|b)*(?:c??)?", .input = "c", .ecmascript = false, .span = .{ 0, 0 } },
        .{ .pattern = "(?:a|b)*(c??)?", .input = "c", .ecmascript = false, .span = .{ 0, 0 }, .group1 = .{ 0, 0 } },
        .{ .pattern = "((?:a|b)*)?", .input = "", .ecmascript = false, .span = .{ 0, 0 }, .group1 = .{ 0, 0 } },
        .{ .pattern = "(?:(a)|c?){2,}$", .input = "a", .ecmascript = false, .span = .{ 0, 1 }, .group1 = .{ 0, 1 } },
        .{ .pattern = "(?:b(.)+|c?){2,}$", .input = "bxy", .ecmascript = false, .span = .{ 0, 3 }, .group1 = .{ 2, 3 } },
        .{ .pattern = "(?:a|b)*(?:c??)?", .input = "c", .ecmascript = true, .span = .{ 0, 1 } },
        .{ .pattern = "(?:(a)|c?){2,}$", .input = "a", .ecmascript = true, .span = .{ 0, 1 }, .group1 = @as(Group, null) },
        .{ .pattern = "(?:b(.)+|c?){2,}$", .input = "bxy", .ecmascript = true, .span = .{ 0, 3 }, .group1 = @as(Group, null) },
        // PCRE ends an unbounded loop at an empty iteration only once no
        // iteration is still required, and lets a bounded loop go on to its
        // next copy, which then captures.
        .{ .pattern = "(?:x|xy)*(a??){1,3}b", .input = "ab", .ecmascript = false, .span = .{ 0, 2 }, .group1 = .{ 0, 1 } },
        .{ .pattern = "(?:x|xy)*(|a){0,2}b", .input = "ab", .ecmascript = false, .span = .{ 0, 2 }, .group1 = .{ 0, 1 } },
        .{ .pattern = "(?:x|xy)*(a??)*b", .input = "ab", .ecmascript = false, .span = .{ 0, 2 }, .group1 = .{ 1, 1 } },
        .{ .pattern = "(?:(^)|a)+b", .input = "ab", .ecmascript = false, .span = .{ 0, 2 }, .group1 = @as(Group, null) },
        .{ .pattern = "(?:(?=(a))|a)+b", .input = "aab", .ecmascript = false, .span = .{ 0, 3 }, .group1 = @as(Group, null) },
        // Atomic groups keep the continuation matcher's own rules.
        .{ .pattern = "(?>z?)(a??){1,3}b", .input = "ab", .ecmascript = false, .span = .{ 0, 2 }, .group1 = .{ 0, 1 } },
    };
    for (cases) |c| {
        var re = try Regex.compileWithFlags(allocator, c.pattern, .{ .ecmascript = c.ecmascript });
        defer re.deinit();
        var found = try re.find(c.input);
        defer if (found) |*m| m.deinit(allocator);
        const m = found orelse {
            std.debug.print("no match: {s} (ecmascript={})\n", .{ c.pattern, c.ecmascript });
            return error.TestExpectedMatch;
        };
        errdefer std.debug.print("{s} on \"{s}\" (ecmascript={}): [{d},{d})\n", .{ c.pattern, c.input, c.ecmascript, m.start, m.end });
        try std.testing.expectEqual(c.span[0], m.start);
        try std.testing.expectEqual(c.span[1], m.end);
        if (c.group1) |want| {
            if (want) |span| {
                try std.testing.expect(m.captures_present[0]);
                try std.testing.expectEqual(span[0], m.capture_spans[0][0]);
                try std.testing.expectEqual(span[1], m.capture_spans[0][1]);
            } else try std.testing.expect(!m.captures_present[0]);
        }
    }
}

test "a loop after a large alternation leaves the alternation on the fast path" {
    // Only the part of a pattern that follows a loop over a body with choices
    // needs the continuation matcher. Sending the whole pattern there made the
    // leading alternation, tried at every start, about twice as costly (and
    // OWASP CRS 934120, this shape with 150 branches, time out on 128 KB). On
    // 64 KB of form data this takes about 27 steps a byte, as 0.5.2 did.
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, "(?i)(?:alpha|beta|gamma|delta|epsilon|zeta|theta|iota|kappa|lambda|omicron|sigma)(?:\\\\[a-z]\\.?_?)+:");
    defer re.deinit();
    const unit = "name=Ada+Lovelace&email=ada%40example.com&subject=order+question&";
    const body = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(body);
    for (body, 0..) |*b, i| b.* = unit[i % unit.len];
    const steps = try stepsFor(&re, body);
    if (steps > 35 * body.len) {
        std.debug.print("{d} steps on {d} bytes\n", .{ steps, body.len });
        return error.TestTooManySteps;
    }
    try std.testing.expect(try re.find(body) == null);
}

test "an end found twice does not make a loop state look failed" {
    // The concatenation engine can collect a loop's ends into one list more
    // than once at the same position. An invocation that reached only ends
    // already in the list was taken for one that reached none, so its loop
    // states were remembered as failing, and this missed the match PCRE2 finds.
    const allocator = std.testing.allocator;
    var re = try Regex.compileWithFlags(allocator, "aB+?((?-i:b[^a])|c){2,}?(?i)", .{ .bytes = true, .case_insensitive = true });
    defer re.deinit();
    var found = try re.find("Bb1aAbcbB aBac");
    defer if (found) |*m| m.deinit(allocator);
    const m = found orelse return error.TestExpectedMatch;
    try std.testing.expectEqual(@as(usize, 4), m.start);
    try std.testing.expectEqual(@as(usize, 9), m.end);
}

test "patterns the loop memo cannot serve keep their old cost" {
    // With a backreference the memo is off, and the continuation matcher
    // would explore a loop over a body with choices exponentially; such a
    // pattern keeps the concatenation engine's matching (zig-utils/zig-regex#57
    // stays open for it). These answered in a few hundred steps before.
    const allocator = std.testing.allocator;
    const cases = [_]struct { pattern: []const u8, input: []const u8, span: ?[2]usize }{
        .{ .pattern = "([\"'])(?:\\w+\\s?)*\\1", .input = "\"documentation_identifier\"", .span = .{ 0, 26 } },
        .{ .pattern = "(b)(?:a|aa)*\\1", .input = "baaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .span = null },
    };
    for (cases) |c| {
        var re = try Regex.compile(allocator, c.pattern);
        defer re.deinit();
        const steps = try stepsFor(&re, c.input);
        if (steps > 1000) {
            std.debug.print("{s}: {d} steps\n", .{ c.pattern, steps });
            return error.TestTooManySteps;
        }
        var found = try re.find(c.input);
        defer if (found) |*m| m.deinit(allocator);
        if (c.span) |span| {
            const m = found orelse return error.TestExpectedMatch;
            try std.testing.expectEqual(span[0], m.start);
            try std.testing.expectEqual(span[1], m.end);
        } else try std.testing.expect(found == null);
    }
}

test "a search the loop memo outgrows answers as before instead of timing out" {
    // A loop over an ambiguous body keeps a few to a dozen memo states per
    // input byte. Past the memo's budget the search runs again without it, as
    // 0.5.2 did, rather than going on unmemoized, which went exponential and
    // timed out at 24 KB here. The budget keeps the memo to a few megabytes.
    const allocator = std.testing.allocator;
    const cases = [_]struct { pattern: []const u8, head: []const u8, unit: []const u8, tail: []const u8 }{
        .{ .pattern = "(?i)select(?:\\s*(?:\\w+\\s*)+,?)*\\s+from", .head = "select ", .unit = "abcdefgh ", .tail = "" },
        .{ .pattern = "^(?:\\w+\\s?)*$(?<=d )", .head = "", .unit = "word ", .tail = "word" },
    };
    const body = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(body);
    for (cases) |c| {
        var re = try Regex.compile(allocator, c.pattern);
        defer re.deinit();
        @memcpy(body[0..c.head.len], c.head);
        for (body[c.head.len..], 0..) |*b, i| b.* = c.unit[i % c.unit.len];
        if (c.tail.len > 0) @memcpy(body[body.len - c.tail.len ..], c.tail);
        // The steps of the search that answered (the rerun, here).
        const steps = try stepsFor(&re, body);
        if (steps > 20 * body.len) {
            std.debug.print("{s}: {d} steps on {d} bytes\n", .{ c.pattern, steps, body.len });
            return error.TestTooManySteps;
        }
        try std.testing.expect(!try re.isMatch(body));
    }
}

test "a memo search that runs out of steps answers as before instead of timing out" {
    // The memo attempt gets half the step budget. A loop over a large
    // alternation costs many steps per memo state, so it can use that up before
    // the memo fills; it then runs again without the memo, with the whole
    // budget, rather than reporting a timeout the engine without the memo
    // would not have hit. With a 1M-step budget, the memo attempt here needs
    // 2.6M steps and the rerun 0.6M.
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, "(?i)^(?:[\\w./-]+\\s*(?:alias|apropos|apt|arch|awk|base64|bash|bzip2|cat|chmod|chown|crontab|curl|cut|dd|diff|dig|echo|env|eval|exec|find|ftp|gcc|grep|gzip|head|host|id|ifconfig|kill|less|ln|ls|make|more|mount|nc|netstat|nmap|nohup|perl|php|ping|ps|python|rm|rsync|ruby|scp|sed|sh|sleep|sort|ssh|sudo|tail|tar|tee|telnet|top|touch|uname|unzip|wget|whoami|xargs|zip|zsh)?\\s*[;|&]?)*\\$\\(");
    defer re.deinit();
    re.setStepBudget(1_000_000);
    const body = try allocator.alloc(u8, 8 * 1024);
    defer allocator.free(body);
    for (body, 0..) |*b, i| b.* = "hello there friend "[i % 19];
    try std.testing.expect(!try re.isMatch(body));
}

test "a loop inside one branch of an alternation leaves the alternation on the fast path" {
    // The loop in `\\((?:\\w+,?)+\\)` is followed by `\\)` within its own branch,
    // which hands it to the continuation matcher; the alternation around it,
    // tried at every start, stays here. Routing the whole alternation doubled
    // the steps (and timed out on 256 KB). On 64 KB of form data this takes
    // about 34 steps a byte, as 0.5.2 did.
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, "(?i)(?:alter|create|delete|drop|insert|select|update|union|truncate|rename|load|exec|declare|grant|revoke|\\((?:\\w+,?)+\\))\\s*\\(");
    defer re.deinit();
    const unit = "name=Ada+Lovelace&email=ada%40example.com&subject=order+question&";
    const body = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(body);
    for (body, 0..) |*b, i| b.* = unit[i % unit.len];
    const steps = try stepsFor(&re, body);
    if (steps > 40 * body.len) {
        std.debug.print("{d} steps on {d} bytes\n", .{ steps, body.len });
        return error.TestTooManySteps;
    }
    try std.testing.expect(!try re.isMatch(body));
    var found = try re.find("x (a,b) (");
    defer if (found) |*m| m.deinit(allocator);
    const m = found orelse return error.TestExpectedMatch;
    try std.testing.expectEqual(@as(usize, 2), m.start);
    try std.testing.expectEqual(@as(usize, 9), m.end);
}

test "a step budget from searchSteps gives the answer searchSteps measured" {
    // The attempt with the loop memo runs on half the budget, so a budget of
    // its steps alone sent the search back to the path without the memo, and
    // `^(?:'b*?)*c` lost the match this fix finds.
    const allocator = std.testing.allocator;
    const cases = [_]struct { pattern: []const u8, input: []const u8, span: [2]usize }{
        .{ .pattern = "^(?:'b*?)*c", .input = "'bc", .span = .{ 0, 3 } },
        .{ .pattern = "^(?:a|ab)*c", .input = "ababababababc", .span = .{ 0, 13 } },
        .{ .pattern = "(?:a|ab)*c", .input = "xxxxxxxxxxababababc", .span = .{ 10, 19 } },
        .{ .pattern = "^(?:[^']*?'[^']*?'[^']*?)*?'", .input = "1' or 'a'='a", .span = .{ 0, 9 } },
    };
    for (cases) |c| {
        var re = try Regex.compile(allocator, c.pattern);
        defer re.deinit();
        re.setStepBudget((try re.searchSteps(c.input)).?);
        var found = try re.find(c.input);
        defer if (found) |*m| m.deinit(allocator);
        const m = found orelse {
            std.debug.print("no match with the measured budget: {s}\n", .{c.pattern});
            return error.TestExpectedMatch;
        };
        try std.testing.expectEqual(c.span[0], m.start);
        try std.testing.expectEqual(c.span[1], m.end);
    }
}

test "the backtracker reports OutOfMemory instead of a miss at every allocation failure" {
    // Choice traversal used to turn a failed allocation into "no match" in
    // many places (a missed capture snapshot, a positions list that could not
    // grow), so a search under memory pressure answered wrongly instead of
    // failing. Every result here must be the right match or OutOfMemory.
    // Spans are PCRE2 10.47's; these patterns stay on the concatenation engine.
    const Case = struct { pattern: []const u8, input: []const u8, span: [2]usize };
    const cases = [_]Case{
        .{ .pattern = "(a|ab)(c|bcd)(d*?)", .input = "abcd", .span = .{ 0, 4 } },
        .{ .pattern = "(?:a|ab){2,3}c", .input = "aabc", .span = .{ 0, 4 } },
        .{ .pattern = "(\\w+)\\s(\\w+)", .input = "hello world", .span = .{ 0, 11 } },
        .{ .pattern = "(?<=a(b|bc))d", .input = "abcd", .span = .{ 3, 4 } },
        .{ .pattern = "(.*-)?x", .input = "a-b-x", .span = .{ 0, 5 } },
        .{ .pattern = "(a|ab)\\1c", .input = "ababc", .span = .{ 0, 5 } },
        .{ .pattern = "x(?:a|b)?y(c+?)d", .input = "xaycccd", .span = .{ 0, 7 } },
        .{ .pattern = "(?:ab|a){2,}?c", .input = "xaabc", .span = .{ 1, 5 } },
        .{ .pattern = "(a|ab)(?:c|bcd)?(d)", .input = "abcd", .span = .{ 0, 4 } },
        .{ .pattern = "(?:ab|a){2}(c)", .input = "aabc", .span = .{ 0, 4 } },
        // Lookbehinds match their body in reverse (node 24 for the unbounded one).
        .{ .pattern = "(?<=(?:a|ab){2})c", .input = "aabc", .span = .{ 3, 4 } },
        .{ .pattern = "(?<=(b|cb)a)x", .input = "cbax", .span = .{ 3, 4 } },
        .{ .pattern = "(?<=x(a|bc)+)d", .input = "xabcad", .span = .{ 5, 6 } },
        .{ .pattern = "(?<=(\\w+?)\\s)y", .input = "ab y", .span = .{ 3, 4 } },
    };
    for (cases) |c| {
        var fail_index: usize = 0;
        while (true) : (fail_index += 1) {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            var re = Regex.compile(allocator, c.pattern) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                continue;
            };
            defer re.deinit();
            try std.testing.expectEqual(EngineType.backtracking, re.engine_type);
            if (re.find(c.input)) |found| {
                var m = found orelse {
                    std.debug.print("{s} on \"{s}\": no match at allocation failure {d}\n", .{ c.pattern, c.input, fail_index });
                    return error.TestExpectedMatch;
                };
                defer m.deinit(allocator);
                try std.testing.expectEqual(c.span[0], m.start);
                try std.testing.expectEqual(c.span[1], m.end);
            } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
            if (!failing.has_induced_failure) break;
        }
    }
}

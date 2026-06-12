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
        // The global `x` (extended) flag affects lexing from the first token, so
        // enable it on the lexer and re-lex the already-fetched first token.
        if (flags.extended) {
            p.extended = true;
            p.lexer.extended = true;
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

        // Collect named captures from AST
        var named_captures = std.StringHashMap(usize).init(allocator);
        errdefer deinitNamedCaptureMap(allocator, &named_captures);
        var named_capture_list = std.ArrayList(NamedCapture).empty;
        errdefer deinitNamedCaptureList(allocator, &named_capture_list);
        try collectNamedCaptures(allocator, tree.root, &named_captures, &named_capture_list);

        // Detect if backtracking is required
        const needs_backtracking = requiresBacktracking(tree.root);

        if (needs_backtracking) {
            // Use backtracking engine
            var backtrack_engine = try backtrack.BacktrackEngine.init(
                allocator,
                tree.root,
                tree.capture_count,
                flags
            );
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

            // One-pass capture plan (built from the AST, independent of it).
            const onepass_plan = try onepass.build(allocator, tree.root, tree.capture_count, flags);
            errdefer if (onepass_plan) |pl| pl.deinit();

            var comp = compiler.Compiler.init(allocator);
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

    /// Substring search using a SIMD first-byte scan (`indexOfScalarPos`) plus a
    /// tail compare. For the literal patterns we fast-path, the first byte is
    /// usually rare, so this beats Boyer-Moore-Horspool (what `std.mem.indexOf`
    /// uses) by jumping directly between candidates.
    fn literalSearch(input: []const u8, lit: []const u8, from: usize) ?usize {
        if (lit.len == 1) return std.mem.indexOfScalarPos(u8, input, from, lit[0]);
        if (from + lit.len > input.len) return null;
        var i = from;
        const last = input.len - lit.len;
        while (std.mem.indexOfScalarPos(u8, input, i, lit[0])) |p| {
            if (p > last) return null;
            if (std.mem.eql(u8, input[p + 1 .. p + lit.len], lit[1..])) return p;
            i = p + 1;
        }
        return null;
    }

    /// Stateful case-insensitive substring scanner. Keeps a SIMD cursor for each
    /// case of the first byte so it never rescans for an absent case (which would
    /// make repeated searches O(n²)). Yields non-overlapping match starts.
    const CiLiteralScanner = struct {
        input: []const u8,
        lit: []const u8,
        last: usize, // last viable start index
        lo: u8,
        hi: u8,
        c_lo: ?usize,
        c_hi: ?usize,
        done: bool,

        fn init(input: []const u8, lit: []const u8, from: usize) CiLiteralScanner {
            if (lit.len > input.len) {
                return .{ .input = input, .lit = lit, .last = 0, .lo = 0, .hi = 0, .c_lo = null, .c_hi = null, .done = true };
            }
            const lo = std.ascii.toLower(lit[0]);
            const hi = std.ascii.toUpper(lit[0]);
            return .{
                .input = input,
                .lit = lit,
                .last = input.len - lit.len,
                .lo = lo,
                .hi = hi,
                .c_lo = std.mem.indexOfScalarPos(u8, input, from, lo),
                .c_hi = if (lo != hi) std.mem.indexOfScalarPos(u8, input, from, hi) else null,
                .done = false,
            };
        }

        fn advanceCursorsAt(self: *CiLiteralScanner, p: usize) void {
            if (self.c_lo) |x| {
                if (x <= p) self.c_lo = std.mem.indexOfScalarPos(u8, self.input, p + 1, self.lo);
            }
            if (self.c_hi) |x| {
                if (x <= p) self.c_hi = std.mem.indexOfScalarPos(u8, self.input, p + 1, self.hi);
            }
        }

        fn next(self: *CiLiteralScanner) ?usize {
            while (!self.done) {
                const p = blk: {
                    if (self.c_lo) |a| {
                        if (self.c_hi) |b| break :blk @min(a, b);
                        break :blk a;
                    }
                    break :blk self.c_hi orelse {
                        self.done = true;
                        return null;
                    };
                };
                if (p > self.last) {
                    self.done = true;
                    return null;
                }
                const matched = std.ascii.eqlIgnoreCase(self.input[p .. p + self.lit.len], self.lit);
                if (matched) {
                    // Non-overlapping: skip both cursors past the matched region.
                    self.advanceCursorsAt(p + self.lit.len - 1);
                    return p;
                }
                self.advanceCursorsAt(p);
            }
            return null;
        }
    };

    /// Whether the lazy DFA can be used for capture-less search (count/isMatch):
    /// the fast byte-at-a-time engine for general patterns. Requires the Thompson
    /// engine, ASCII-exact matching, no position assertions, and all-greedy
    /// quantifiers (so longest-match equals the engine's semantics).
    fn dfaEligible(self: *const Regex) bool {
        return self.engine_type == .thompson_nfa and
            !self.flags.case_insensitive and
            !self.opt_info.has_assertions and
            !self.opt_info.has_lazy;
    }

    /// Skip to the next position >= `scan` whose byte can start a match, or
    /// `input.len` if none. Uses a SIMD `indexOfScalar` when the first-byte set
    /// is a single byte; otherwise a scalar table walk. Callers only invoke this
    /// when `first_bytes` is set.
    fn skipToCandidate(self: *const Regex, input: []const u8, scan: usize) usize {
        if (self.opt_info.first_byte_single) |b| {
            return std.mem.indexOfScalarPos(u8, input, scan, b) orelse input.len;
        }
        const t = self.opt_info.first_bytes.?;
        var s = scan;
        while (s < input.len and !t[input[s]]) s += 1;
        return s;
    }

    /// Next start to try after a failed DFA match at `scan`, where `stop` is the
    /// position the DFA halted at. When the pattern begins with an unbounded
    /// greedy class, the DFA dies exactly at that class's run end, so we can jump
    /// straight to `stop` (no rescan) — no start within the run can match. Other
    /// patterns advance by one.
    fn dfaFailSkip(self: *const Regex, scan: usize, stop: usize) usize {
        if (self.opt_info.first_unbounded_class != null) return @max(stop, scan + 1);
        return scan + 1;
    }

    /// count() via the lazy DFA. Returns error.DfaOverflow if the DFA exceeds its
    /// state cap, so the caller can fall back to the NFA.
    fn countWithDfa(self: *const Regex, input: []const u8) dfa.Error!usize {
        var d = try dfa.LazyDfa.init(self.allocator, @constCast(&self.nfa), self.flags);
        defer d.deinit();
        const fb = self.opt_info.first_bytes;
        var n: usize = 0;
        var pos: usize = 0;
        while (pos <= input.len) {
            var scan = pos;
            var found_end: ?usize = null;
            while (scan <= input.len) {
                if (fb != null) {
                    scan = self.skipToCandidate(input, scan);
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
    fn findWithDfa(self: *const Regex, input: []const u8) dfa.Error!?Match {
        var d = try dfa.LazyDfa.init(self.allocator, @constCast(&self.nfa), self.flags);
        defer d.deinit();
        var v: ?vm.VM = if (self.capture_count > 0)
            vm.VM.init(self.allocator, @constCast(&self.nfa), self.capture_count, self.flags)
        else
            null;
        defer if (v) |*vv| vv.deinit();

        const fb = self.opt_info.first_bytes;
        var scan: usize = 0;
        while (scan <= input.len) {
            if (fb != null) {
                scan = self.skipToCandidate(input, scan);
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
    fn findAllWithDfa(self: *const Regex, allocator: std.mem.Allocator, matches: *std.ArrayList(Match), input: []const u8) dfa.Error!void {
        var d = try dfa.LazyDfa.init(self.allocator, @constCast(&self.nfa), self.flags);
        defer d.deinit();
        var v: ?vm.VM = if (self.capture_count > 0)
            vm.VM.init(self.allocator, @constCast(&self.nfa), self.capture_count, self.flags)
        else
            null;
        defer if (v) |*vv| vv.deinit();

        const fb = self.opt_info.first_bytes;
        var pos: usize = 0;
        while (pos <= input.len) {
            var scan = pos;
            var matched_end: ?usize = null;
            while (scan <= input.len) {
                if (fb != null) {
                    scan = self.skipToCandidate(input, scan);
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

    /// isMatch() via the lazy DFA.
    fn isMatchWithDfa(self: *const Regex, input: []const u8) dfa.Error!bool {
        var d = try dfa.LazyDfa.init(self.allocator, @constCast(&self.nfa), self.flags);
        defer d.deinit();
        const fb = self.opt_info.first_bytes;
        var pos: usize = 0;
        while (pos <= input.len) {
            if (fb != null) {
                pos = self.skipToCandidate(input, pos);
                if (pos >= input.len) break;
            }
            const sc = try d.longestMatchFrom(input, pos);
            if (sc.end) |_| return true;
            pos = self.dfaFailSkip(pos, sc.stop);
        }
        return false;
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

    /// Longest literal in `set` that matches at `input[pos..]`, or 0 if none.
    /// Longest wins, matching the engine's alternation semantics (`a|ab` → "ab").
    fn longestLiteralAt(set: []const []const u8, input: []const u8, pos: usize) usize {
        var best: usize = 0;
        for (set) |s| {
            if (s.len > best and pos + s.len <= input.len and
                std.mem.eql(u8, input[pos .. pos + s.len], s)) best = s.len;
        }
        return best;
    }

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
        var matcher = unicode_mod.SpecMatcher.init(up.spec);
        while (p < input.len and run < max) {
            const dec = unicode_mod.decodeUtf8Lenient(input[p..]) orelse break;
            if (matcher.matches(dec.codepoint) == up.negated) break;
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

    /// Check if the pattern matches the entire input string
    pub fn isMatch(self: *const Regex, input: []const u8) !bool {
        // Required-literal fast-fail: a mandatory substring that's absent means
        // there can be no match (works for every engine).
        if (self.requiredAbsent(input)) return false;
        // Exact-literal fast path: a fixed-string pattern is a substring search.
        if (self.opt_info.exact_literal) |lit| {
            if (self.flags.case_insensitive) {
                var sc = CiLiteralScanner.init(input, lit, 0);
                return sc.next() != null;
            }
            return literalSearch(input, lit, 0) != null;
        }
        // Repeated-atom fast path: a match exists iff some run of `table` bytes
        // reaches the minimum length.
        if (self.opt_info.repeat_atom) |ra| if (!(self.flags.multiline and self.opt_info.has_assertions)) {
            const table = if (self.flags.case_insensitive) foldTableCI(ra.table) else ra.table;
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
        if (self.opt_info.unicode_repeat_atom) |ura| if (!self.flags.case_insensitive and !(self.flags.multiline and self.opt_info.has_assertions)) {
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
                const fb = self.opt_info.first_bytes;
                var p: usize = 0;
                while (p < input.len) {
                    if (fb) |t| {
                        while (p < input.len and !t[input[p]]) p += 1;
                        if (p >= input.len) break;
                    }
                    if (longestLiteralAt(set, input, p) > 0) return true;
                    p += 1;
                }
                return false;
            }
        }
        // count/isMatch need no captures, so the lazy DFA (faster, with the
        // death-position skip) handles one-pass patterns too — every one-pass
        // pattern is DFA-eligible. The plan is reserved for find/findAll captures.
        // Lazy-DFA path for eligible general patterns.
        if (self.dfaEligible()) {
            if (self.isMatchWithDfa(input)) |b| {
                return b;
            } else |err| switch (err) {
                error.DfaOverflow => {}, // fall back to NFA
                else => |e| return e,
            }
        }
        switch (self.engine_type) {
            .thompson_nfa => {
                const nfa_mut = @constCast(&self.nfa);
                var virtual_machine = vm.VM.init(self.allocator, nfa_mut, self.capture_count, self.flags);
                defer virtual_machine.deinit();
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
        if (self.requiredAbsent(input)) return null;
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
        if (self.opt_info.repeat_atom) |ra| if (!(self.flags.multiline and self.opt_info.has_assertions)) {
            const table = if (self.flags.case_insensitive) foldTableCI(ra.table) else ra.table;
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
        if (self.opt_info.unicode_repeat_atom) |ura| if (!self.flags.case_insensitive and !(self.flags.multiline and self.opt_info.has_assertions)) {
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
        // Literal-alternation fast path: leftmost position, longest literal.
        if (self.opt_info.literal_set) |set| {
            if (!self.flags.case_insensitive) {
                const fb = self.opt_info.first_bytes;
                var p: usize = 0;
                while (p < input.len) {
                    if (fb) |t| {
                        while (p < input.len and !t[input[p]]) p += 1;
                        if (p >= input.len) break;
                    }
                    const best = longestLiteralAt(set, input, p);
                    if (best > 0) return Match{ .slice = input[p .. p + best], .start = p, .end = p + best };
                    p += 1;
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
            if (self.findWithDfa(input)) |maybe| {
                return maybe;
            } else |err| switch (err) {
                error.DfaOverflow => {}, // fall back to NFA
                else => |e| return e,
            }
        }
        switch (self.engine_type) {
            .thompson_nfa => {
                const nfa_mut = @constCast(&self.nfa);
                var virtual_machine = vm.VM.init(self.allocator, nfa_mut, self.capture_count, self.flags);
                defer virtual_machine.deinit();

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

    /// Find all matches in the input string
    pub fn findAll(self: *const Regex, allocator: std.mem.Allocator, input: []const u8) ![]Match {
        var matches: std.ArrayList(Match) = .empty;
        errdefer matches.deinit(allocator);

        var pos: usize = 0;

        if (self.requiredAbsent(input)) return matches.toOwnedSlice(allocator);

        // Exact-literal fast path: repeated substring search, no NFA.
        if (self.opt_info.exact_literal) |lit| {
            if (self.flags.case_insensitive) {
                var sc = CiLiteralScanner.init(input, lit, 0);
                while (sc.next()) |i| {
                    try matches.append(allocator, Match{ .slice = input[i .. i + lit.len], .start = i, .end = i + lit.len });
                }
                return matches.toOwnedSlice(allocator);
            }
            while (literalSearch(input, lit, pos)) |i| {
                try matches.append(allocator, Match{ .slice = input[i .. i + lit.len], .start = i, .end = i + lit.len });
                pos = i + lit.len;
            }
            return matches.toOwnedSlice(allocator);
        }
        // Repeated-atom fast path: each leftmost maximal run of `table` bytes
        // (capped at max) is one non-overlapping match. No NFA, no per-match
        // capture allocation.
        if (self.opt_info.repeat_atom) |ra| {
            const table = if (self.flags.case_insensitive) foldTableCI(ra.table) else ra.table;
            const max = ra.max orelse std.math.maxInt(usize);
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
        }
        // Literal-alternation fast path: each leftmost-longest literal match.
        if (self.opt_info.literal_set) |set| {
            if (!self.flags.case_insensitive) {
                const fb = self.opt_info.first_bytes;
                while (pos < input.len) {
                    if (fb) |t| {
                        while (pos < input.len and !t[input[pos]]) pos += 1;
                        if (pos >= input.len) break;
                    }
                    const best = longestLiteralAt(set, input, pos);
                    if (best > 0) {
                        try matches.append(allocator, Match{ .slice = input[pos .. pos + best], .start = pos, .end = pos + best });
                        pos += best;
                    } else {
                        pos += 1;
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
            if (self.findAllWithDfa(allocator, &matches, input)) |_| {
                return matches.toOwnedSlice(allocator);
            } else |err| switch (err) {
                error.DfaOverflow => {
                    for (matches.items) |*m| m.deinit(allocator);
                    matches.clearRetainingCapacity();
                },
                else => |e| return e,
            }
        }

        // Thompson path: reuse a single VM across all matches (VM.init does not
        // allocate) and, when the pattern has a literal prefix, use it as a
        // prefilter — `std.mem.indexOf` skips whole non-matching regions instead
        // of running the NFA at every byte. This is the same prefilter `find`
        // uses; `findAll` previously rescanned every position, which is why it
        // was orders of magnitude slower on literal-led patterns.
        if (self.engine_type == .thompson_nfa) {
            const nfa_mut = @constCast(&self.nfa);
            var virtual_machine = vm.VM.init(self.allocator, nfa_mut, self.capture_count, self.flags);
            defer virtual_machine.deinit();
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

        while (pos < input.len) {
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
        var n: usize = 0;
        var pos: usize = 0;

        if (self.requiredAbsent(input)) return 0;

        // Exact-literal: repeated substring search.
        if (self.opt_info.exact_literal) |lit| {
            if (self.flags.case_insensitive) {
                var sc = CiLiteralScanner.init(input, lit, 0);
                while (sc.next()) |_| n += 1;
                return n;
            }
            while (literalSearch(input, lit, pos)) |i| {
                n += 1;
                pos = i + lit.len;
            }
            return n;
        }
        // Repeated-atom: count maximal runs of >= min table bytes.
        if (self.opt_info.repeat_atom) |ra| {
            const table = if (self.flags.case_insensitive) foldTableCI(ra.table) else ra.table;
            const max = ra.max orelse std.math.maxInt(usize);
            while (pos < input.len) {
                while (pos < input.len and !table[input[pos]]) pos += 1;
                if (pos >= input.len) break;
                var run: usize = 0;
                while (pos < input.len and table[input[pos]] and run < max) : (pos += 1) run += 1;
                if (run >= ra.min) n += 1;
            }
            return n;
        }
        // Literal-alternation: leftmost-longest literal at each candidate.
        if (self.opt_info.literal_set) |set| {
            if (!self.flags.case_insensitive) {
                const fb = self.opt_info.first_bytes;
                while (pos < input.len) {
                    if (fb) |t| {
                        while (pos < input.len and !t[input[pos]]) pos += 1;
                        if (pos >= input.len) break;
                    }
                    const best = longestLiteralAt(set, input, pos);
                    if (best > 0) {
                        n += 1;
                        pos += best;
                    } else pos += 1;
                }
                return n;
            }
        }

        // count needs no captures, so the lazy DFA (with the death-position skip)
        // handles one-pass patterns too. The plan is reserved for find/findAll.
        // Lazy-DFA path for eligible general patterns.
        if (self.dfaEligible()) {
            if (self.countWithDfa(input)) |c| {
                return c;
            } else |err| switch (err) {
                error.DfaOverflow => {}, // fall back to NFA
                else => |e| return e,
            }
        }

        switch (self.engine_type) {
            .thompson_nfa => {
                const nfa_mut = @constCast(&self.nfa);
                var virtual_machine = vm.VM.init(self.allocator, nfa_mut, self.capture_count, self.flags);
                defer virtual_machine.deinit();
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
                while (pos < input.len) {
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
fn requiresBacktracking(node: *ast.Node) bool {
    switch (node.node_type) {
        // These features require backtracking
        .lookahead, .lookbehind, .backref, .unicode_property, .class_set => return true,

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
            return requiresBacktracking(child);
        },
        .repeat => {
            if (!node.data.repeat.greedy) return true;
            return requiresBacktracking(node.data.repeat.child);
        },

        // Recursively check compound nodes
        .concat => {
            return requiresBacktracking(node.data.concat.left) or
                   requiresBacktracking(node.data.concat.right);
        },
        .alternation => {
            return requiresBacktracking(node.data.alternation.left) or
                   requiresBacktracking(node.data.alternation.right);
        },
        // A group carrying inline modifiers `(?i:...)` adjusts flags per-scope,
        // which only the backtracking engine honors.
        .group => return node.data.group.mod != null or requiresBacktracking(node.data.group.child),

        // `.` consumes a decoded JS character (and respects Unicode vs
        // non-Unicode astral semantics), which the byte-oriented NFA/DFA paths
        // cannot model.
        .any => return true,

        // These don't require backtracking
        .literal, .char_class, .anchor, .empty => return false,
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

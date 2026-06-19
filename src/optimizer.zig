const std = @import("std");
const ast = @import("ast.zig");
const common = @import("common.zig");
const unicode = @import("unicode.zig");
const utf8_class = @import("utf8_class.zig");

/// Optimization information extracted from a pattern
pub const OptimizationInfo = struct {
    /// Literal prefix that must appear for the pattern to match
    /// This allows skipping ahead in the input using memchr/indexOf
    literal_prefix: ?[]const u8 = null,

    /// Set when the whole pattern is an exact literal string (only literals,
    /// concatenation, and non-capturing groups — no quantifiers, alternation,
    /// classes, anchors, or captures). Such a pattern reduces to a substring
    /// search, bypassing the NFA entirely.
    exact_literal: ?[]const u8 = null,

    /// A literal substring that must appear in every match (not under `?`/`*`/
    /// `{0,n}`/alternation). If it's absent from the input, there can be no
    /// match — a universal fast-fail that works for every engine. Owned.
    required_literal: ?[]const u8 = null,

    /// Set when the whole pattern is an alternation of two or more exact
    /// literals (`foo|bar|baz`). Matched by trying each literal directly in
    /// source order, matching ECMAScript ordered alternation, instead of
    /// running the NFA. Owned; freed in deinit.
    literal_set: ?[]const []const u8 = null,

    /// Set when the whole pattern is a single greedy-repeated byte atom with a
    /// minimum of at least one (`\w+`, `\d+`, `[a-z]+`, `a+`, `x{2,5}`, or a bare
    /// `\d`). Such a pattern is matched by a tight byte loop — maximal runs of
    /// bytes in `table` — instead of the NFA. Null otherwise.
    repeat_atom: ?RepeatAtom = null,

    /// Set when the whole pattern is a single greedy-repeated Unicode property
    /// atom (`\p{...}+`, `\P{...}+`, or bounded `{m,n}`). These cannot use the
    /// byte-table fast path, but they can still be matched by one linear
    /// code-point scan instead of the general backtracker.
    unicode_repeat_atom: ?UnicodeRepeatAtom = null,

    /// Set when the pattern begins with an unbounded greedy repeat (`+`/`*`/
    /// `{m,}`) of a byte class — the table is that class. If an anchored match
    /// fails at some position, no start within the class's run can match (a later
    /// start's match would imply one from the current start, which consumes more
    /// of the same class), so the DFA search can skip the whole run. Null when
    /// the pattern doesn't start that way.
    first_unbounded_class: ?[256]bool = null,

    /// The set of bytes that can begin a match, when the pattern always consumes
    /// at least one byte and that first byte is statically known (e.g. literal
    /// alternations, `\d+`). Lets the search skip positions whose byte can't
    /// start a match, generalizing `literal_prefix` to non-prefix patterns.
    /// Null when unknown / unhelpful (e.g. `.`, nullable patterns).
    first_bytes: ?[256]bool = null,

    /// Set when `first_bytes` contains exactly one byte: the search can then skip
    /// to candidates with a SIMD `indexOfScalar` instead of a scalar table walk.
    first_byte_single: ?u8 = null,

    /// Whether the pattern contains any position assertion (^ $ \A \z \b \B).
    /// The lazy DFA can't represent these, so it's disabled when true.
    has_assertions: bool = false,

    /// Whether the pattern contains any lazy (non-greedy) quantifier. Lazy
    /// matching isn't longest-match, so the lazy DFA is disabled when true.
    has_lazy: bool = false,

    /// Whether the pattern is anchored at start (^)
    anchored_start: bool = false,

    /// Whether the pattern is anchored at end ($)
    anchored_end: bool = false,

    /// Minimum length of any match
    min_length: usize = 0,

    /// Maximum length of any match (if bounded)
    max_length: ?usize = null,

    pub const RepeatAtom = struct {
        /// Positive membership table for the repeated byte atom (the class's
        /// ranges, *before* any negation). Kept positive so case-folding under
        /// `i` is correct — fold the set, then apply `negated` when matching.
        table: [256]bool,
        /// Whether the atom is a negated class (`[^…]`); membership is then the
        /// complement of `table`.
        negated: bool,
        min: usize,
        /// Null means unbounded (`+`, `{m,}`).
        max: ?usize,
    };

    pub const UnicodeRepeatAtom = struct {
        property: ast.Node.UnicodeProp,
        min: usize,
        /// Null means unbounded (`+`, `{m,}`).
        max: ?usize,
    };

    pub fn deinit(self: *OptimizationInfo, allocator: std.mem.Allocator) void {
        if (self.literal_prefix) |prefix| {
            allocator.free(prefix);
        }
        if (self.exact_literal) |lit| {
            allocator.free(lit);
        }
        if (self.literal_set) |set| {
            for (set) |s| allocator.free(s);
            allocator.free(set);
        }
        if (self.required_literal) |s| allocator.free(s);
    }
};

/// Optimizer that analyzes AST to extract optimization opportunities
pub const Optimizer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Optimizer {
        return .{ .allocator = allocator };
    }

    /// Analyze AST and extract optimization information
    pub fn analyze(self: *Optimizer, root: *ast.Node) !OptimizationInfo {
        var info = OptimizationInfo{};

        info.anchored_start = hasLeadingStartAnchor(root);
        info.anchored_end = hasTrailingEndAnchor(root);

        // Extract literal prefix
        if (try self.extractLiteralPrefix(root)) |prefix| {
            info.literal_prefix = prefix;
        }

        // Calculate min/max lengths
        info.min_length = self.calculateMinLength(root);
        info.max_length = self.calculateMaxLength(root);

        // Exact-literal fast path: the entire pattern is a fixed string.
        if (isExactLiteral(root)) {
            var buf = try std.ArrayList(u8).initCapacity(self.allocator, 0);
            errdefer buf.deinit(self.allocator);
            _ = try self.collectLiteralPrefix(root, &buf);
            if (buf.items.len >= 1) {
                info.exact_literal = try buf.toOwnedSlice(self.allocator);
            } else {
                buf.deinit(self.allocator);
            }
        }

        // Feature scan for lazy-DFA eligibility.
        scanFeatures(root, &info);

        // Longest mandatory literal substring (required-literal fast-fail).
        {
            var cur = try std.ArrayList(u8).initCapacity(self.allocator, 0);
            defer cur.deinit(self.allocator);
            var best = try std.ArrayList(u8).initCapacity(self.allocator, 0);
            errdefer best.deinit(self.allocator);
            try collectMandatory(self.allocator, root, &cur, &best);
            flushMandatory(self.allocator, &cur, &best) catch {};
            if (best.items.len >= 1) {
                info.required_literal = try best.toOwnedSlice(self.allocator);
            } else {
                best.deinit(self.allocator);
                // A concatenation breaks on alternation, so an all-alternative
                // pattern (`fn\s+\w+|\w+\s+fn`) yields no run above. But a literal
                // common to every branch is still required by every match — find
                // the longest one so the prefilter can use it.
                info.required_literal = try alternationCommonLiteral(self.allocator, root);
            }
        }

        // Single repeated-atom fast path (greedy, min >= 1), including the
        // common anchored wrapper `^ atom+ $`.
        info.repeat_atom = detectRepeatAtom(anchoredCore(root) orelse root);
        info.unicode_repeat_atom = detectUnicodeRepeatAtom(anchoredCore(root) orelse root);

        // Leading unbounded greedy class (for the DFA-search run-skip).
        info.first_unbounded_class = detectFirstUnboundedClass(root);

        // Alternation-of-literals fast path (>= 2 literals).
        if (info.exact_literal == null) {
            var list = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
            errdefer {
                for (list.items) |s| self.allocator.free(s);
                list.deinit(self.allocator);
            }
            if (try self.collectLiteralAlternatives(root, &list) and list.items.len >= 2) {
                info.literal_set = try list.toOwnedSlice(self.allocator);
            } else {
                for (list.items) |s| self.allocator.free(s);
                list.deinit(self.allocator);
            }
        }

        // First-byte set: usable only when every match consumes at least one
        // byte (min_length >= 1) and the leading byte set is fully determined.
        if (info.min_length >= 1) {
            var set = std.mem.zeroes([256]bool);
            if (collectFirstBytes(root, &set) == .ok_consumed) {
                // Only worthwhile if it actually rules some bytes out.
                var count: usize = 0;
                for (set) |b| {
                    if (b) count += 1;
                }
                if (count > 0 and count < 256) {
                    info.first_bytes = set;
                    if (count == 1) {
                        for (set, 0..) |b, i| {
                            if (b) {
                                info.first_byte_single = @intCast(i);
                                break;
                            }
                        }
                    }
                }
            }
        }

        return info;
    }

    /// Keep `best` as the longest run seen, then reset `cur`.
    fn flushMandatory(allocator: std.mem.Allocator, cur: *std.ArrayList(u8), best: *std.ArrayList(u8)) !void {
        if (cur.items.len > best.items.len) {
            best.clearRetainingCapacity();
            try best.appendSlice(allocator, cur.items);
        }
        cur.clearRetainingCapacity();
    }

    /// Accumulate the longest run of literals that must appear in every match.
    /// Only literals reached through concatenation and plain (min>=1) groups are
    /// mandatory; `?`/`*`/`{0,n}`/alternation and any non-literal break the run.
    fn collectMandatory(allocator: std.mem.Allocator, node: *ast.Node, cur: *std.ArrayList(u8), best: *std.ArrayList(u8)) !void {
        switch (node.node_type) {
            .literal => try cur.append(allocator, node.data.literal),
            .concat => {
                try collectMandatory(allocator, node.data.concat.left, cur, best);
                try collectMandatory(allocator, node.data.concat.right, cur, best);
            },
            .group => {
                // A plain group (always matched once) preserves the run.
                if (node.data.group.mod != null) {
                    try flushMandatory(allocator, cur, best);
                } else {
                    try collectMandatory(allocator, node.data.group.child, cur, best);
                }
            },
            // Anything else (quantifiers, alternation, classes, anchors, ...) is
            // not a guaranteed literal here: break the current run.
            else => try flushMandatory(allocator, cur, best),
        }
    }

    /// The longest literal substring required by *every* alternation branch (so
    /// by every match), or null. Returns null unless `root` is (a group wrapping)
    /// a top-level alternation whose branches share a common mandatory literal.
    /// Caller owns the returned slice.
    fn alternationCommonLiteral(allocator: std.mem.Allocator, root: *ast.Node) !?[]u8 {
        var node = root;
        while (node.node_type == .group and node.data.group.mod == null and node.data.group.capture_index == null)
            node = node.data.group.child;
        if (node.node_type != .alternation) return null;

        var branches = std.ArrayList(*ast.Node).empty;
        defer branches.deinit(allocator);
        try flattenAlternation(allocator, node, &branches);

        // Common substring across each branch's longest mandatory run.
        var common_lit: ?[]u8 = null;
        defer if (common_lit) |c| allocator.free(c);
        for (branches.items) |b| {
            var cur = std.ArrayList(u8).empty;
            defer cur.deinit(allocator);
            var run = std.ArrayList(u8).empty;
            defer run.deinit(allocator);
            try collectMandatory(allocator, b, &cur, &run);
            flushMandatory(allocator, &cur, &run) catch {};
            if (run.items.len == 0) return null; // a branch has no mandatory literal
            if (common_lit == null) {
                common_lit = try allocator.dupe(u8, run.items);
            } else {
                // `lcs` points into `common_lit`, so dupe before freeing it.
                const lcs = longestCommonSubstring(common_lit.?, run.items);
                const next = try allocator.dupe(u8, lcs);
                allocator.free(common_lit.?);
                common_lit = next;
                if (common_lit.?.len == 0) return null;
            }
        }
        if (common_lit) |c| {
            if (c.len >= 1) {
                const out = try allocator.dupe(u8, c);
                return out;
            }
        }
        return null;
    }

    fn flattenAlternation(allocator: std.mem.Allocator, node: *ast.Node, out: *std.ArrayList(*ast.Node)) !void {
        if (node.node_type == .alternation) {
            try flattenAlternation(allocator, node.data.alternation.left, out);
            try flattenAlternation(allocator, node.data.alternation.right, out);
        } else {
            try out.append(allocator, node);
        }
    }

    /// Longest common contiguous substring of `a` and `b` (brute force — literals
    /// here are short). Returns a slice into `a`.
    fn longestCommonSubstring(a: []const u8, b: []const u8) []const u8 {
        var best_start: usize = 0;
        var best_len: usize = 0;
        var i: usize = 0;
        while (i < a.len) : (i += 1) {
            var j: usize = 0;
            while (j < b.len) : (j += 1) {
                var k: usize = 0;
                while (i + k < a.len and j + k < b.len and a[i + k] == b[j + k]) k += 1;
                if (k > best_len) {
                    best_len = k;
                    best_start = i;
                }
            }
        }
        return a[best_start .. best_start + best_len];
    }

    /// Walk the AST recording features that disqualify the lazy DFA: position
    /// assertions (not representable) and lazy quantifiers (not longest-match).
    fn scanFeatures(node: *ast.Node, info: *OptimizationInfo) void {
        switch (node.node_type) {
            .anchor => info.has_assertions = true,
            .literal, .any, .char_class, .empty, .unicode_property, .class_set, .backref => {},
            .star => {
                if (!node.data.star.greedy) info.has_lazy = true;
                scanFeatures(node.data.star.child, info);
            },
            .plus => {
                if (!node.data.plus.greedy) info.has_lazy = true;
                scanFeatures(node.data.plus.child, info);
            },
            .optional => {
                if (!node.data.optional.greedy) info.has_lazy = true;
                scanFeatures(node.data.optional.child, info);
            },
            .repeat => {
                if (!node.data.repeat.greedy) info.has_lazy = true;
                scanFeatures(node.data.repeat.child, info);
            },
            .concat => {
                scanFeatures(node.data.concat.left, info);
                scanFeatures(node.data.concat.right, info);
            },
            .alternation => {
                scanFeatures(node.data.alternation.left, info);
                scanFeatures(node.data.alternation.right, info);
            },
            .group => scanFeatures(node.data.group.child, info),
            // Assertions/captures inside lookaround route to backtracking; flag
            // conservatively so the DFA is not used.
            .lookahead, .lookbehind => info.has_assertions = true,
        }
    }

    /// Collect, into `list`, the exact-literal strings of an alternation tree.
    /// Returns false (abandoning the fast path) if any branch is not an exact
    /// literal. Caller owns the appended strings.
    fn collectLiteralAlternatives(self: *Optimizer, node: *ast.Node, list: *std.ArrayList([]const u8)) !bool {
        switch (node.node_type) {
            .alternation => {
                const a = node.data.alternation;
                if (!try self.collectLiteralAlternatives(a.left, list)) return false;
                return try self.collectLiteralAlternatives(a.right, list);
            },
            else => {
                if (!isExactLiteral(node)) return false;
                var buf = try std.ArrayList(u8).initCapacity(self.allocator, 0);
                errdefer buf.deinit(self.allocator);
                _ = try self.collectLiteralPrefix(node, &buf);
                if (buf.items.len == 0) {
                    buf.deinit(self.allocator);
                    return false;
                }
                try list.append(self.allocator, try buf.toOwnedSlice(self.allocator));
                return true;
            },
        }
    }

    /// Byte-membership table for a literal or char-class node, or null.
    fn classTableOf(node: *ast.Node) ?[256]bool {
        var t = std.mem.zeroes([256]bool);
        switch (node.node_type) {
            .literal => t[node.data.literal] = true,
            .char_class => {
                const cc = node.data.char_class;
                var b: usize = 0;
                while (b < 256) : (b += 1) {
                    if (cc.matches(@intCast(b))) t[b] = true;
                }
            },
            // `.` — every byte but the line terminator (the death-skip only needs
            // a non-null table; the bytes matter solely as documentation here).
            .any => {
                var b: usize = 0;
                while (b < 256) : (b += 1) t[b] = true;
                t['\n'] = false;
            },
            else => return null,
        }
        return t;
    }

    /// If the pattern begins with an unbounded greedy repeat of a byte class,
    /// return that class's table. Descends the leftmost path through concat and
    /// plain groups.
    fn detectFirstUnboundedClass(node: *ast.Node) ?[256]bool {
        return switch (node.node_type) {
            .concat => detectFirstUnboundedClass(node.data.concat.left),
            .group => if (node.data.group.mod != null) null else detectFirstUnboundedClass(node.data.group.child),
            .plus => if (node.data.plus.greedy) classTableOf(node.data.plus.child) else null,
            .star => if (node.data.star.greedy) classTableOf(node.data.star.child) else null,
            .repeat => blk: {
                const r = node.data.repeat;
                if (!r.greedy or r.bounds.max != null) break :blk null;
                break :blk classTableOf(r.child);
            },
            else => null,
        };
    }

    fn isStartAnchor(node: *ast.Node) bool {
        return node.node_type == .anchor and node.data.anchor == .start_line;
    }

    fn isEndAnchor(node: *ast.Node) bool {
        return node.node_type == .anchor and node.data.anchor == .end_line;
    }

    fn stripLeadingStart(node: *ast.Node) ?*ast.Node {
        if (isStartAnchor(node)) return null;
        if (node.node_type == .concat and isStartAnchor(node.data.concat.left)) return node.data.concat.right;
        return null;
    }

    fn stripTrailingEnd(node: *ast.Node) ?*ast.Node {
        if (isEndAnchor(node)) return null;
        if (node.node_type == .concat and isEndAnchor(node.data.concat.right)) return node.data.concat.left;
        return null;
    }

    fn hasLeadingStartAnchor(node: *ast.Node) bool {
        const core = stripTrailingEnd(node) orelse node;
        if (isStartAnchor(core)) return true;
        return core.node_type == .concat and isStartAnchor(core.data.concat.left);
    }

    fn hasTrailingEndAnchor(node: *ast.Node) bool {
        const core = stripLeadingStart(node) orelse node;
        if (isEndAnchor(core)) return true;
        return core.node_type == .concat and isEndAnchor(core.data.concat.right);
    }

    fn anchoredCore(node: *ast.Node) ?*ast.Node {
        if (stripTrailingEnd(node)) |without_end| {
            if (stripLeadingStart(without_end)) |core| return core;
        }
        if (stripLeadingStart(node)) |without_start| {
            if (stripTrailingEnd(without_start)) |core| return core;
        }
        return null;
    }

    /// Detect a whole-pattern single greedy-repeated byte atom (min >= 1). Lazy
    /// quantifiers, nullable quantifiers (`*`, `?`, `{0,n}`), and non-byte atoms
    /// (Unicode property / set classes) are rejected — they keep NFA semantics.
    fn detectRepeatAtom(root: *ast.Node) ?OptimizationInfo.RepeatAtom {
        var node = root;
        var min: usize = 1;
        var max: ?usize = 1;
        switch (root.node_type) {
            .plus => {
                if (!root.data.plus.greedy) return null;
                min = 1;
                max = null;
                node = root.data.plus.child;
            },
            .repeat => {
                const r = root.data.repeat;
                if (!r.greedy or r.bounds.min < 1) return null;
                min = r.bounds.min;
                max = r.bounds.max;
                node = r.child;
            },
            else => {}, // bare atom: min = max = 1
        }
        var table = std.mem.zeroes([256]bool);
        var negated = false;
        switch (node.node_type) {
            .literal => table[node.data.literal] = true,
            .char_class => {
                const cc = node.data.char_class;
                negated = cc.negated;
                // Positive membership (ranges only); negation applied at match.
                const positive = common.CharClass{ .ranges = cc.ranges, .negated = false };
                var b: usize = 0;
                while (b < 256) : (b += 1) {
                    if (positive.matches(@intCast(b))) table[b] = true;
                }
            },
            else => return null,
        }
        return .{ .table = table, .negated = negated, .min = min, .max = max };
    }

    /// Detect a whole-pattern single greedy-repeated Unicode property atom
    /// (min >= 1). This mirrors `detectRepeatAtom` for code-point classes that
    /// cannot be represented as a 256-byte table.
    fn detectUnicodeRepeatAtom(root: *ast.Node) ?OptimizationInfo.UnicodeRepeatAtom {
        var node = root;
        var min: usize = 1;
        var max: ?usize = 1;
        switch (root.node_type) {
            .plus => {
                if (!root.data.plus.greedy) return null;
                min = 1;
                max = null;
                node = root.data.plus.child;
            },
            .repeat => {
                const r = root.data.repeat;
                if (!r.greedy or r.bounds.min < 1) return null;
                min = r.bounds.min;
                max = r.bounds.max;
                node = r.child;
            },
            else => {}, // bare atom: min = max = 1
        }
        if (node.node_type != .unicode_property) return null;
        return .{ .property = node.data.unicode_property, .min = min, .max = max };
    }

    /// Whether the pattern is exactly a fixed string: only literals,
    /// concatenation, and non-capturing groups. Capturing groups are excluded
    /// because the fast path does not populate capture slices.
    fn isExactLiteral(node: *ast.Node) bool {
        return switch (node.node_type) {
            .literal => true,
            .concat => isExactLiteral(node.data.concat.left) and isExactLiteral(node.data.concat.right),
            .group => node.data.group.capture_index == null and
                node.data.group.mod == null and
                isExactLiteral(node.data.group.child),
            else => false,
        };
    }

    /// Status of a first-byte collection over a sub-pattern.
    const FirstByteStatus = enum {
        /// Always consumes >= 1 byte; `set` holds every possible first byte.
        ok_consumed,
        /// May match empty; `set` holds first bytes for the consuming case, and
        /// the caller must also consider what can follow.
        ok_nullable,
        /// Indeterminate (e.g. `.`, backref, lookaround, Unicode/codepoint
        /// classes) — abandon the prefilter.
        fail,
    };

    /// Collect, into `set`, the bytes that can appear as the first consumed byte
    /// of a match of `node`. ASCII/byte level only.
    fn collectFirstBytes(node: *ast.Node, set: *[256]bool) FirstByteStatus {
        switch (node.node_type) {
            .literal => {
                set[node.data.literal] = true;
                return .ok_consumed;
            },
            .char_class => {
                const cc = node.data.char_class;
                var b: usize = 0;
                while (b < 256) : (b += 1) {
                    if (cc.matches(@intCast(b))) set[b] = true;
                }
                return .ok_consumed;
            },
            .concat => {
                const c = node.data.concat;
                switch (collectFirstBytes(c.left, set)) {
                    .fail => return .fail,
                    .ok_consumed => return .ok_consumed,
                    .ok_nullable => return collectFirstBytes(c.right, set),
                }
            },
            .alternation => {
                const a = node.data.alternation;
                const ls = collectFirstBytes(a.left, set);
                if (ls == .fail) return .fail;
                const rs = collectFirstBytes(a.right, set);
                if (rs == .fail) return .fail;
                return if (ls == .ok_nullable or rs == .ok_nullable) .ok_nullable else .ok_consumed;
            },
            .plus => {
                // Requires >= 1 child match: inherits the child's status.
                return collectFirstBytes(node.data.plus.child, set);
            },
            .star, .optional => {
                // May match empty; still record the child's first bytes. If the
                // child's first bytes are indeterminate, the consuming case
                // could begin with any byte, so the whole prefilter is unsound —
                // abandon it rather than under-report.
                if (collectFirstBytes(child_of(node), set) == .fail) return .fail;
                return .ok_nullable;
            },
            .repeat => {
                const r = node.data.repeat;
                const cs = collectFirstBytes(r.child, set);
                if (cs == .fail) return .fail;
                // {0,..} is nullable; {1,..} inherits the child's status.
                return if (r.bounds.min == 0) .ok_nullable else cs;
            },
            .group => return collectFirstBytes(node.data.group.child, set),
            // Anchors / empty don't consume — transparent, continue past them.
            .anchor, .empty => return .ok_nullable,
            // A lowerable `class_set` (`\s`, `\S`, `/v` brackets) consumes one
            // code point; mark the UTF-8 lead bytes it can start with.
            .class_set => {
                if (!utf8_class.compilable(node.data.class_set)) return .fail;
                markClassSetLeadBytes(node.data.class_set, set);
                return .ok_consumed;
            },
            // Everything else is indeterminate at the byte level.
            .any, .backref, .lookahead, .lookbehind, .unicode_property => return .fail,
        }
    }

    /// First byte of `cp`'s UTF-8 encoding (always valid for scalar values).
    fn leadByte(cp: u21) u8 {
        var buf: [4]u8 = undefined;
        _ = unicode.encodeUtf8(cp, &buf) catch return 0;
        return buf[0];
    }

    /// Mark, into `set`, every UTF-8 lead byte the code-point range [lo, hi] can
    /// begin with. Within one UTF-8 length the lead byte is monotonic, so each
    /// length-band contributes a contiguous lead-byte run.
    fn markRangeLeadBytes(lo: u21, hi: u21, set: *[256]bool) void {
        const bounds = [_]u21{ 0x7F, 0x7FF, 0xFFFF, 0x10FFFF };
        var prev: u21 = 0;
        for (bounds) |bnd| {
            const blo = @max(lo, prev);
            const bhi = @min(hi, bnd);
            if (blo <= bhi) {
                var x: usize = leadByte(blo);
                const top: usize = leadByte(bhi);
                while (x <= top) : (x += 1) set[x] = true;
            }
            if (bnd == 0x10FFFF) break;
            prev = bnd + 1;
        }
    }

    /// Recurse a lowerable union, marking the lead bytes of each contributed
    /// range. Caller guarantees `compilable(set)`.
    fn markUnionLeadBytes(set: *const ast.Node.ClassSet, out: *[256]bool) void {
        for (set.items) |it| {
            switch (it) {
                .range => |r| markRangeLeadBytes(r.lo, r.hi, out),
                .string => |s| if (s.len == 1) markRangeLeadBytes(@intCast(s[0]), @intCast(s[0]), out),
                .nested => |n| markUnionLeadBytes(n, out),
                .property => {},
            }
        }
    }

    /// Mark the possible first bytes of a lowerable `class_set`. For a plain
    /// union this is exact; for a complement (`[^…]`/`\S`) the ASCII bytes are
    /// computed exactly and the multi-byte lead bytes are over-approximated
    /// (a superset only loosens the prefilter, never drops a match).
    fn markClassSetLeadBytes(set: *const ast.Node.ClassSet, out: *[256]bool) void {
        if (set.negated) {
            var cp: u21 = 0;
            while (cp < 0x80) : (cp += 1) {
                if (set.matches(cp, false)) out[cp] = true;
            }
            var b: usize = 0xC2;
            while (b <= 0xF4) : (b += 1) out[b] = true;
        } else {
            markUnionLeadBytes(set, out);
        }
    }

    fn child_of(node: *ast.Node) *ast.Node {
        return switch (node.node_type) {
            .star => node.data.star.child,
            .optional => node.data.optional.child,
            else => unreachable,
        };
    }

    /// Try to extract a literal prefix from the pattern
    /// Returns null if no useful prefix can be extracted
    fn extractLiteralPrefix(self: *Optimizer, node: *ast.Node) !?[]const u8 {
        var prefix = try std.ArrayList(u8).initCapacity(self.allocator, 0);
        errdefer prefix.deinit(self.allocator);

        _ = try self.collectLiteralPrefix(node, &prefix);

        // Only useful if we got at least 2 characters
        if (prefix.items.len < 2) {
            prefix.deinit(self.allocator);
            return null;
        }

        return try prefix.toOwnedSlice(self.allocator);
    }

    /// Recursively collect literal characters from the start of the pattern
    fn collectLiteralPrefix(self: *Optimizer, node: *ast.Node, prefix: *std.ArrayList(u8)) !bool {
        return switch (node.node_type) {
            .literal => {
                try prefix.append(self.allocator, node.data.literal);
                return true;
            },
            .concat => {
                // For concatenation, try left side first
                const concat = node.data.concat;
                if (!try self.collectLiteralPrefix(concat.left, prefix)) {
                    return false;
                }
                // If left was successful and complete, try right
                return try self.collectLiteralPrefix(concat.right, prefix);
            },
            .group => {
                // For groups, recurse into child
                return try self.collectLiteralPrefix(node.data.group.child, prefix);
            },
            .anchor => {
                // Anchors don't affect prefix but don't stop collection
                return true;
            },
            // Any of these stop prefix collection
            .alternation, .star, .plus, .optional, .repeat, .any, .char_class, .backref, .unicode_property, .class_set => false,
            // Lookahead/lookbehind don't consume input
            .lookahead, .lookbehind => true,
            .empty => true,
        };
    }

    /// Calculate minimum possible match length
    fn calculateMinLength(self: *Optimizer, node: *ast.Node) usize {
        return switch (node.node_type) {
            .literal => 1,
            .any => 1,
            .char_class => 1,
            .concat => {
                const concat = node.data.concat;
                return self.calculateMinLength(concat.left) + self.calculateMinLength(concat.right);
            },
            .alternation => {
                const alt = node.data.alternation;
                const left_min = self.calculateMinLength(alt.left);
                const right_min = self.calculateMinLength(alt.right);
                return @min(left_min, right_min);
            },
            .star => 0, // * means 0 or more
            .optional => 0, // ? means 0 or 1
            .plus => {
                // + means 1 or more
                return self.calculateMinLength(node.data.plus.child);
            },
            .repeat => {
                const repeat = node.data.repeat;
                const child_min = self.calculateMinLength(repeat.child);
                return child_min * repeat.bounds.min;
            },
            .group => {
                return self.calculateMinLength(node.data.group.child);
            },
            .lookahead, .lookbehind => {
                // Lookaround assertions don't consume input
                return 0;
            },
            .backref => {
                // Backreferences have variable length (depends on what was captured)
                // Conservative estimate: 0 minimum
                return 0;
            },
            .unicode_property, .class_set => 1, // one code point (≥ 1 byte)
            .anchor, .empty => 0,
        };
    }

    /// Calculate maximum possible match length (if bounded)
    fn calculateMaxLength(self: *Optimizer, node: *ast.Node) ?usize {
        return switch (node.node_type) {
            .literal => 1,
            .any => 1,
            .char_class => 1,
            .concat => {
                const concat = node.data.concat;
                const left_max = self.calculateMaxLength(concat.left) orelse return null;
                const right_max = self.calculateMaxLength(concat.right) orelse return null;
                return left_max + right_max;
            },
            .alternation => {
                const alt = node.data.alternation;
                const left_max = self.calculateMaxLength(alt.left) orelse return null;
                const right_max = self.calculateMaxLength(alt.right) orelse return null;
                return @max(left_max, right_max);
            },
            .star => null, // * means unbounded
            .optional => {
                // ? means 0 or 1
                return self.calculateMaxLength(node.data.optional.child) orelse return null;
            },
            .plus => null, // + means unbounded
            .repeat => {
                const repeat = node.data.repeat;
                if (repeat.bounds.max) |max| {
                    const child_max = self.calculateMaxLength(repeat.child) orelse return null;
                    return child_max * max;
                }
                return null;
            },
            .group => {
                return self.calculateMaxLength(node.data.group.child);
            },
            .lookahead, .lookbehind => {
                // Lookaround assertions don't consume input
                return 0;
            },
            .backref => {
                // Backreferences have unbounded max length
                return null;
            },
            .unicode_property, .class_set => 4, // up to a 4-byte UTF-8 code point
            .anchor, .empty => 0,
        };
    }
};

test "optimizer: literal prefix extraction" {
    const allocator = std.testing.allocator;
    const Parser = @import("parser.zig").Parser;

    var parser = try Parser.init(allocator, "hello.*world");
    var tree = try parser.parse();
    defer tree.deinit();

    var optimizer = Optimizer.init(allocator);
    var info = try optimizer.analyze(tree.root);
    defer info.deinit(allocator);

    try std.testing.expect(info.literal_prefix != null);
    if (info.literal_prefix) |prefix| {
        try std.testing.expectEqualStrings("hello", prefix);
    }
}

test "optimizer: anchored detection" {
    const allocator = std.testing.allocator;
    const Parser = @import("parser.zig").Parser;

    var parser = try Parser.init(allocator, "^hello$");
    var tree = try parser.parse();
    defer tree.deinit();

    var optimizer = Optimizer.init(allocator);
    var info = try optimizer.analyze(tree.root);
    defer info.deinit(allocator);

    try std.testing.expect(info.anchored_start);
}

test "optimizer: min/max length calculation" {
    const allocator = std.testing.allocator;
    const Parser = @import("parser.zig").Parser;

    // Fixed length pattern
    var parser1 = try Parser.init(allocator, "hello");
    var tree1 = try parser1.parse();
    defer tree1.deinit();

    var optimizer = Optimizer.init(allocator);
    var info1 = try optimizer.analyze(tree1.root);
    defer info1.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), info1.min_length);
    try std.testing.expectEqual(@as(?usize, 5), info1.max_length);

    // Variable length pattern
    var parser2 = try Parser.init(allocator, "a+");
    var tree2 = try parser2.parse();
    defer tree2.deinit();

    var info2 = try optimizer.analyze(tree2.root);
    defer info2.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), info2.min_length);
    try std.testing.expectEqual(@as(?usize, null), info2.max_length);
}

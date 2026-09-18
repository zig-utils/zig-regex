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
        errdefer info.deinit(self.allocator);

        info.anchored_start = hasLeadingStartAnchor(root);
        info.anchored_end = hasTrailingEndAnchor(root);

        // Extract literal prefix
        if (try self.extractLiteralPrefix(root)) |prefix| {
            info.literal_prefix = prefix;
        }

        // Calculate min/max lengths
        info.min_length = try self.calculateMinLength(root);
        info.max_length = try self.calculateMaxLength(root);

        // Exact-literal fast path: the entire pattern is a fixed string.
        if (try self.isExactLiteral(root)) {
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
        try scanFeatures(self.allocator, root, &info);

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
    /// Iterative for the reason `scanFeatures` documents (#23).
    fn collectMandatory(allocator: std.mem.Allocator, node: *ast.Node, cur: *std.ArrayList(u8), best: *std.ArrayList(u8)) !void {
        var pending: std.ArrayList(*ast.Node) = .empty;
        defer pending.deinit(allocator);
        try pending.append(allocator, node);
        while (pending.pop()) |n| switch (n.node_type) {
            .literal => try cur.append(allocator, n.data.literal),
            .concat => {
                // Elements are walked left to right, so the run is collected in
                // source order.
                try pending.append(allocator, n.data.concat.right);
                try pending.append(allocator, n.data.concat.left);
            },
            .group => {
                // A plain group (always matched once) preserves the run.
                if (n.data.group.mod != null) {
                    try flushMandatory(allocator, cur, best);
                } else {
                    try pending.append(allocator, n.data.group.child);
                }
            },
            // Anything else (quantifiers, alternation, classes, anchors, ...) is
            // not a guaranteed literal here: break the current run.
            else => try flushMandatory(allocator, cur, best),
        };
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

    /// Iterative for the reason `scanFeatures` documents (#23).
    fn flattenAlternation(allocator: std.mem.Allocator, node: *ast.Node, out: *std.ArrayList(*ast.Node)) !void {
        var pending: std.ArrayList(*ast.Node) = .empty;
        defer pending.deinit(allocator);
        try pending.append(allocator, node);
        while (pending.pop()) |n| {
            if (n.node_type == .alternation) {
                // Pushed right-first so branches come out in source order.
                try pending.append(allocator, n.data.alternation.right);
                try pending.append(allocator, n.data.alternation.left);
            } else try out.append(allocator, n);
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
    /// Flag the features that decide which engine can run a pattern.
    ///
    /// Walked with an explicit stack: a flat pattern's spine is as deep as the
    /// pattern is long, and one native frame per element overflowed the stack on
    /// patterns other engines compile (#23).
    fn scanFeatures(allocator: std.mem.Allocator, node: *ast.Node, info: *OptimizationInfo) !void {
        var pending: std.ArrayList(*ast.Node) = .empty;
        defer pending.deinit(allocator);
        var current: ?*ast.Node = node;
        while (current) |n| : (current = pending.pop()) {
            var child: ?*ast.Node = null;
            switch (n.node_type) {
                .anchor => info.has_assertions = true,
                .literal, .any, .char_class, .empty, .unicode_property, .class_set, .backref => {},
                .star => {
                    if (!n.data.star.greedy) info.has_lazy = true;
                    child = n.data.star.child;
                },
                .plus => {
                    if (!n.data.plus.greedy) info.has_lazy = true;
                    child = n.data.plus.child;
                },
                .optional => {
                    if (!n.data.optional.greedy) info.has_lazy = true;
                    child = n.data.optional.child;
                },
                .repeat => {
                    if (!n.data.repeat.greedy) info.has_lazy = true;
                    child = n.data.repeat.child;
                },
                .concat => {
                    try pending.append(allocator, n.data.concat.right);
                    child = n.data.concat.left;
                },
                .alternation => {
                    try pending.append(allocator, n.data.alternation.right);
                    child = n.data.alternation.left;
                },
                .group => child = n.data.group.child,
                // Assertions/captures inside lookaround route to backtracking; flag
                // conservatively so the DFA is not used.
                .lookahead, .lookbehind => info.has_assertions = true,
            }
            if (child) |c| {
                try pending.append(allocator, c);
            }
        }
    }

    /// Collect, into `list`, the exact-literal strings of an alternation tree.
    /// Returns false (abandoning the fast path) if any branch is not an exact
    /// literal. Caller owns the appended strings.
    fn collectLiteralAlternatives(self: *Optimizer, node: *ast.Node, list: *std.ArrayList([]const u8)) !bool {
        // Branches are visited left to right with an explicit stack, for the
        // reason `scanFeatures` documents (#23).
        var pending: std.ArrayList(*ast.Node) = .empty;
        defer pending.deinit(self.allocator);
        try pending.append(self.allocator, node);
        while (pending.pop()) |n| {
            if (n.node_type == .alternation) {
                // Pushed right-first so the left branch pops first.
                try pending.append(self.allocator, n.data.alternation.right);
                try pending.append(self.allocator, n.data.alternation.left);
                continue;
            }
            if (!try self.isExactLiteral(n)) return false;
            var buf = try std.ArrayList(u8).initCapacity(self.allocator, 0);
            errdefer buf.deinit(self.allocator);
            _ = try self.collectLiteralPrefix(n, &buf);
            if (buf.items.len == 0) {
                buf.deinit(self.allocator);
                return false;
            }
            try list.append(self.allocator, try buf.toOwnedSlice(self.allocator));
        }
        return true;
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
    /// Walks only leftmost elements, which on a flat pattern is its whole spine
    /// (#23), so it steps down rather than recursing.
    fn detectFirstUnboundedClass(node: *ast.Node) ?[256]bool {
        var current = node;
        while (true) switch (current.node_type) {
            .concat => current = current.data.concat.left,
            .group => {
                if (current.data.group.mod != null) return null;
                current = current.data.group.child;
            },
            else => return detectFirstUnboundedClassAtom(current),
        };
    }

    fn detectFirstUnboundedClassAtom(node: *ast.Node) ?[256]bool {
        return switch (node.node_type) {
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
    /// Whether the whole sub-pattern is a fixed string. Walked with an explicit
    /// stack for the reason `scanFeatures` documents (#23).
    fn isExactLiteral(self: *Optimizer, node: *ast.Node) !bool {
        var pending: std.ArrayList(*ast.Node) = .empty;
        defer pending.deinit(self.allocator);
        try pending.append(self.allocator, node);
        while (pending.pop()) |n| switch (n.node_type) {
            .literal => {},
            .concat => {
                try pending.append(self.allocator, n.data.concat.right);
                try pending.append(self.allocator, n.data.concat.left);
            },
            .group => {
                if (n.data.group.capture_index != null or n.data.group.mod != null) return false;
                try pending.append(self.allocator, n.data.group.child);
            },
            else => return false,
        };
        return true;
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
                // A sequence hands its first bytes to the first element that
                // must consume one; stepping along it keeps a flat pattern to
                // one frame (#23).
                var current = node;
                while (current.node_type == .concat) {
                    switch (collectFirstBytes(current.data.concat.left, set)) {
                        .fail => return .fail,
                        .ok_consumed => return .ok_consumed,
                        .ok_nullable => current = current.data.concat.right,
                    }
                }
                return collectFirstBytes(current, set);
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
    /// Append the pattern's leading run of literal bytes, stopping at the first
    /// element that is not one. Walked with an explicit stack, for the reason
    /// `scanFeatures` documents (#23): the prefix of a flat pattern is the whole
    /// pattern, so this saw one native frame per character.
    fn collectLiteralPrefix(self: *Optimizer, node: *ast.Node, prefix: *std.ArrayList(u8)) !bool {
        var pending: std.ArrayList(*ast.Node) = .empty;
        defer pending.deinit(self.allocator);
        try pending.append(self.allocator, node);
        while (pending.pop()) |n| switch (n.node_type) {
            .literal => try prefix.append(self.allocator, n.data.literal),
            .concat => {
                // Elements are consumed left to right; the first one that is not
                // a literal ends the prefix, and the rest are never visited.
                try pending.append(self.allocator, n.data.concat.right);
                try pending.append(self.allocator, n.data.concat.left);
            },
            .group => try pending.append(self.allocator, n.data.group.child),
            // Anchors and lookaround consume nothing, so the prefix continues.
            .anchor, .lookahead, .lookbehind, .empty => {},
            // Any of these stop prefix collection.
            .alternation, .star, .plus, .optional, .repeat, .any, .char_class, .backref, .unicode_property, .class_set => return false,
        };
        return true;
    }

    /// Calculate minimum possible match length
    /// Shortest input the pattern can match, used to skip impossible positions.
    ///
    /// Evaluated with an explicit stack rather than recursively: a flat pattern
    /// is a spine as long as the pattern, and one native frame per element
    /// overflowed the stack (#23). Allocation failure propagates, as everywhere
    /// else in analysis.
    fn calculateMinLength(self: *Optimizer, node: *ast.Node) !usize {
        var work: std.ArrayList(Step) = .empty;
        defer work.deinit(self.allocator);
        var values: std.ArrayList(usize) = .empty;
        defer values.deinit(self.allocator);
        work.append(self.allocator, .{ .node = node, .phase = .visit }) catch |err| return err;
        while (work.pop()) |step| {
            const n = step.node;
            if (step.phase == .visit) {
                switch (n.node_type) {
                    .literal, .any, .char_class, .unicode_property, .class_set => values.append(self.allocator, 1) catch |err| return err,
                    .star, .optional, .lookahead, .lookbehind, .backref, .anchor, .empty => values.append(self.allocator, 0) catch |err| return err,
                    // Pass-through and combining nodes revisit themselves once
                    // their children's values are on the value stack.
                    .plus => self.pushChildFirst(&work, n, n.data.plus.child) catch |err| return err,
                    .group => self.pushChildFirst(&work, n, n.data.group.child) catch |err| return err,
                    .repeat => self.pushChildFirst(&work, n, n.data.repeat.child) catch |err| return err,
                    .concat => self.pushPairFirst(&work, n, n.data.concat.left, n.data.concat.right) catch |err| return err,
                    .alternation => self.pushPairFirst(&work, n, n.data.alternation.left, n.data.alternation.right) catch |err| return err,
                }
                continue;
            }
            switch (n.node_type) {
                .concat => {
                    const right = values.pop() orelse unreachable;
                    const left = values.pop() orelse unreachable;
                    values.append(self.allocator, left +| right) catch |err| return err;
                },
                .alternation => {
                    const right = values.pop() orelse unreachable;
                    const left = values.pop() orelse unreachable;
                    values.append(self.allocator, @min(left, right)) catch |err| return err;
                },
                .repeat => {
                    const child = values.pop() orelse unreachable;
                    values.append(self.allocator, child *| n.data.repeat.bounds.min) catch |err| return err;
                },
                // `plus` is one or more of its child, `group` is its child.
                else => {},
            }
        }
        return if (values.items.len == 1) values.items[0] else 0;
    }

    /// Longest input the pattern can match, or null when unbounded. Iterative
    /// for the reason `calculateMinLength` documents.
    fn calculateMaxLength(self: *Optimizer, node: *ast.Node) !?usize {
        var work: std.ArrayList(Step) = .empty;
        defer work.deinit(self.allocator);
        var values: std.ArrayList(?usize) = .empty;
        defer values.deinit(self.allocator);
        work.append(self.allocator, .{ .node = node, .phase = .visit }) catch |err| return err;
        while (work.pop()) |step| {
            const n = step.node;
            if (step.phase == .visit) {
                switch (n.node_type) {
                    .literal, .any, .char_class => values.append(self.allocator, 1) catch |err| return err,
                    .unicode_property, .class_set => values.append(self.allocator, 4) catch |err| return err, // up to a 4-byte UTF-8 code point
                    .lookahead, .lookbehind, .anchor, .empty => values.append(self.allocator, 0) catch |err| return err,
                    .star, .plus, .backref => values.append(self.allocator, null) catch |err| return err, // unbounded
                    .optional => self.pushChildFirst(&work, n, n.data.optional.child) catch |err| return err,
                    .group => self.pushChildFirst(&work, n, n.data.group.child) catch |err| return err,
                    .repeat => {
                        if (n.data.repeat.bounds.max == null) {
                            values.append(self.allocator, null) catch |err| return err;
                        } else {
                            self.pushChildFirst(&work, n, n.data.repeat.child) catch |err| return err;
                        }
                    },
                    .concat => self.pushPairFirst(&work, n, n.data.concat.left, n.data.concat.right) catch |err| return err,
                    .alternation => self.pushPairFirst(&work, n, n.data.alternation.left, n.data.alternation.right) catch |err| return err,
                }
                continue;
            }
            switch (n.node_type) {
                .concat => {
                    const right = values.pop() orelse unreachable;
                    const left = values.pop() orelse unreachable;
                    const sum: ?usize = if (left) |l| (if (right) |r| l +| r else null) else null;
                    values.append(self.allocator, sum) catch |err| return err;
                },
                .alternation => {
                    const right = values.pop() orelse unreachable;
                    const left = values.pop() orelse unreachable;
                    const widest: ?usize = if (left) |l| (if (right) |r| @max(l, r) else null) else null;
                    values.append(self.allocator, widest) catch |err| return err;
                },
                .repeat => {
                    const child = values.pop() orelse unreachable;
                    const bounded: ?usize = if (child) |c| c *| n.data.repeat.bounds.max.? else null;
                    values.append(self.allocator, bounded) catch |err| return err;
                },
                // `optional` is zero or one of its child, `group` is its child.
                else => {},
            }
        }
        return if (values.items.len == 1) values.items[0] else null;
    }

    /// One entry of the length walkers' work stack: a node to evaluate, or a
    /// node whose children's values are ready to combine.
    const Step = struct {
        node: *ast.Node,
        phase: enum { visit, combine },
    };

    fn pushChildFirst(self: *Optimizer, work: *std.ArrayList(Step), node: *ast.Node, child: *ast.Node) !void {
        try work.append(self.allocator, .{ .node = node, .phase = .combine });
        try work.append(self.allocator, .{ .node = child, .phase = .visit });
    }

    fn pushPairFirst(self: *Optimizer, work: *std.ArrayList(Step), node: *ast.Node, left: *ast.Node, right: *ast.Node) !void {
        try work.append(self.allocator, .{ .node = node, .phase = .combine });
        try work.append(self.allocator, .{ .node = right, .phase = .visit });
        try work.append(self.allocator, .{ .node = left, .phase = .visit });
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

test "optimizer analysis ownership is exhaustive-allocation-failure safe" {
    const Parser = @import("parser.zig").Parser;
    var parser = try Parser.init(std.testing.allocator, "^sec-(alpha|beta)-[a-z]+$");
    var tree = try parser.parse();
    defer tree.deinit();

    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, root: *ast.Node) !void {
            var optimizer = Optimizer.init(allocator);
            var info = try optimizer.analyze(root);
            defer info.deinit(allocator);
        }
    }.run, .{tree.root});
}

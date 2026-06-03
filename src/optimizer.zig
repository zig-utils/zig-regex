const std = @import("std");
const ast = @import("ast.zig");

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

    /// The set of bytes that can begin a match, when the pattern always consumes
    /// at least one byte and that first byte is statically known (e.g. literal
    /// alternations, `\d+`). Lets the search skip positions whose byte can't
    /// start a match, generalizing `literal_prefix` to non-prefix patterns.
    /// Null when unknown / unhelpful (e.g. `.`, nullable patterns).
    first_bytes: ?[256]bool = null,

    /// Whether the pattern is anchored at start (^)
    anchored_start: bool = false,

    /// Whether the pattern is anchored at end ($)
    anchored_end: bool = false,

    /// Minimum length of any match
    min_length: usize = 0,

    /// Maximum length of any match (if bounded)
    max_length: ?usize = null,

    pub fn deinit(self: *OptimizationInfo, allocator: std.mem.Allocator) void {
        if (self.literal_prefix) |prefix| {
            allocator.free(prefix);
        }
        if (self.exact_literal) |lit| {
            allocator.free(lit);
        }
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

        // Check for anchors
        if (root.node_type == .concat) {
            const concat = root.data.concat;
            // Check if starts with ^
            if (concat.left.node_type == .anchor and
                concat.left.data.anchor == .start_line)
            {
                info.anchored_start = true;
            }
        } else if (root.node_type == .anchor) {
            if (root.data.anchor == .start_line) {
                info.anchored_start = true;
            }
            if (root.data.anchor == .end_line) {
                info.anchored_end = true;
            }
        }

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

        // First-byte set: usable only when every match consumes at least one
        // byte (min_length >= 1) and the leading byte set is fully determined.
        if (info.min_length >= 1) {
            var set = [_]bool{false} ** 256;
            if (collectFirstBytes(root, &set) == .ok_consumed) {
                // Only worthwhile if it actually rules some bytes out.
                var count: usize = 0;
                for (set) |b| {
                    if (b) count += 1;
                }
                if (count > 0 and count < 256) info.first_bytes = set;
            }
        }

        return info;
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
                // May match empty; still record the child's first bytes.
                _ = collectFirstBytes(child_of(node), set);
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
            // Everything else is indeterminate at the byte level.
            .any, .backref, .lookahead, .lookbehind, .unicode_property, .class_set => return .fail,
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

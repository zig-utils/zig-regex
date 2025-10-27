const std = @import("std");
const ast = @import("ast.zig");

/// Optimization information extracted from a pattern
pub const OptimizationInfo = struct {
    /// Literal prefix that must appear for the pattern to match
    /// This allows skipping ahead in the input using memchr/indexOf
    literal_prefix: ?[]const u8 = null,

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

        return info;
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
            .alternation, .star, .plus, .optional, .repeat, .any, .char_class, .backref => false,
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

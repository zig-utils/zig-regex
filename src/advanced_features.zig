const std = @import("std");
const ast = @import("ast.zig");

/// Atomic Groups: (?>...) - No backtracking allowed
/// Once the group matches, the engine doesn't try alternatives
pub const AtomicGroupNode = struct {
    child: *ast.Node,

    pub fn init(allocator: std.mem.Allocator, child: *ast.Node) !*AtomicGroupNode {
        const node = try allocator.create(AtomicGroupNode);
        node.* = .{ .child = child };
        return node;
    }
};

/// Possessive Quantifiers: *+, ++, ?+, {n,m}+
/// Like greedy quantifiers but don't backtrack
pub const PossessiveQuantifier = enum {
    star_possessive,     // *+
    plus_possessive,     // ++
    optional_possessive, // ?+
    repeat_possessive,   // {n,m}+

    pub fn fromGreedy(_: bool) ?PossessiveQuantifier {
        // Helper to detect possessive syntax
        return null;
    }
};

/// Conditional type for condition checks
pub const ConditionType = union(enum) {
    group_number: usize,
    group_name: []const u8,
    assertion: *ast.Node,
};

/// Conditional Patterns: (?(condition)yes|no)
/// Matches 'yes' if condition is true, otherwise matches 'no'
pub const ConditionalNode = struct {
    /// Condition can be:
    /// - A number (backreference check): (?(1)...)
    /// - A name (named group check): (?(<name>)...)
    /// - A lookahead/lookbehind assertion
    condition: ConditionType,
    yes_branch: *ast.Node,
    no_branch: ?*ast.Node, // Optional - if null, matches empty on false

    pub fn init(
        allocator: std.mem.Allocator,
        cond: ConditionType,
        yes_branch: *ast.Node,
        no_branch: ?*ast.Node,
    ) !*ConditionalNode {
        const node = try allocator.create(ConditionalNode);
        node.* = .{
            .condition = cond,
            .yes_branch = yes_branch,
            .no_branch = no_branch,
        };
        return node;
    }
};

/// Extended AST node types for advanced features
pub const AdvancedNodeType = enum {
    atomic_group,
    possessive_star,
    possessive_plus,
    possessive_optional,
    possessive_repeat,
    conditional,
};

// Tests
test "atomic group creation" {
    const allocator = std.testing.allocator;
    
    // Create a simple child node (literal 'a')
    const child = try ast.Node.createLiteral(allocator, 'a', .{ .start = 0, .end = 1 });
    defer allocator.destroy(child);

    const atomic = try AtomicGroupNode.init(allocator, child);
    defer allocator.destroy(atomic);

    try std.testing.expect(atomic.child == child);
}

test "conditional node with group number" {
    const allocator = std.testing.allocator;
    
    const yes_node = try ast.Node.createLiteral(allocator, 'b', .{ .start = 0, .end = 1 });
    defer allocator.destroy(yes_node);
    
    const no_node = try ast.Node.createLiteral(allocator, 'c', .{ .start = 0, .end = 1 });
    defer allocator.destroy(no_node);

    const conditional = try ConditionalNode.init(
        allocator,
        .{ .group_number = 1 },
        yes_node,
        no_node,
    );
    defer allocator.destroy(conditional);

    try std.testing.expectEqual(@as(usize, 1), conditional.condition.group_number);
}

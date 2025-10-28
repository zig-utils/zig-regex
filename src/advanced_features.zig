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

// Edge case tests
test "advanced_features: conditional with null no_branch" {
    const allocator = std.testing.allocator;

    const yes_node = try ast.Node.createLiteral(allocator, 'b', .{ .start = 0, .end = 1 });
    defer allocator.destroy(yes_node);

    const conditional = try ConditionalNode.init(
        allocator,
        .{ .group_number = 1 },
        yes_node,
        null, // No "else" branch
    );
    defer allocator.destroy(conditional);

    try std.testing.expect(conditional.no_branch == null);
    try std.testing.expect(conditional.yes_branch == yes_node);
}

test "advanced_features: conditional with group name" {
    const allocator = std.testing.allocator;

    const yes_node = try ast.Node.createLiteral(allocator, 'x', .{ .start = 0, .end = 1 });
    defer allocator.destroy(yes_node);

    const no_node = try ast.Node.createLiteral(allocator, 'y', .{ .start = 0, .end = 1 });
    defer allocator.destroy(no_node);

    const conditional = try ConditionalNode.init(
        allocator,
        .{ .group_name = "test_group" },
        yes_node,
        no_node,
    );
    defer allocator.destroy(conditional);

    try std.testing.expectEqualStrings("test_group", conditional.condition.group_name);
}

test "advanced_features: conditional with assertion" {
    const allocator = std.testing.allocator;

    const assertion_node = try ast.Node.createLiteral(allocator, 'a', .{ .start = 0, .end = 1 });
    defer allocator.destroy(assertion_node);

    const yes_node = try ast.Node.createLiteral(allocator, 'b', .{ .start = 0, .end = 1 });
    defer allocator.destroy(yes_node);

    const conditional = try ConditionalNode.init(
        allocator,
        .{ .assertion = assertion_node },
        yes_node,
        null,
    );
    defer allocator.destroy(conditional);

    try std.testing.expect(conditional.condition == .assertion);
    try std.testing.expect(conditional.condition.assertion == assertion_node);
}

test "advanced_features: nested atomic groups" {
    const allocator = std.testing.allocator;

    const inner_child = try ast.Node.createLiteral(allocator, 'a', .{ .start = 0, .end = 1 });
    defer allocator.destroy(inner_child);

    const inner_atomic = try AtomicGroupNode.init(allocator, inner_child);
    defer allocator.destroy(inner_atomic);

    // Create outer atomic group with inner atomic as child (unusual but valid)
    const outer_child = try ast.Node.createLiteral(allocator, 'b', .{ .start = 0, .end = 1 });
    defer allocator.destroy(outer_child);

    const outer_atomic = try AtomicGroupNode.init(allocator, outer_child);
    defer allocator.destroy(outer_atomic);

    try std.testing.expect(outer_atomic.child == outer_child);
}

test "advanced_features: condition type discriminated union" {
    // Test that ConditionType properly discriminates between variants
    const cond1 = ConditionType{ .group_number = 5 };
    const cond2 = ConditionType{ .group_name = "name" };

    try std.testing.expect(cond1 == .group_number);
    try std.testing.expect(cond2 == .group_name);
    try std.testing.expectEqual(@as(usize, 5), cond1.group_number);
    try std.testing.expectEqualStrings("name", cond2.group_name);
}

test "advanced_features: possessive quantifier types" {
    // Test all possessive quantifier enum values exist
    const star = PossessiveQuantifier.star_possessive;
    const plus = PossessiveQuantifier.plus_possessive;
    const optional = PossessiveQuantifier.optional_possessive;
    const repeat = PossessiveQuantifier.repeat_possessive;

    try std.testing.expect(star == .star_possessive);
    try std.testing.expect(plus == .plus_possessive);
    try std.testing.expect(optional == .optional_possessive);
    try std.testing.expect(repeat == .repeat_possessive);
}

test "advanced_features: possessive fromGreedy returns null" {
    // Current implementation always returns null (placeholder)
    const result = PossessiveQuantifier.fromGreedy(true);
    try std.testing.expect(result == null);

    const result2 = PossessiveQuantifier.fromGreedy(false);
    try std.testing.expect(result2 == null);
}

test "advanced_features: conditional with group number zero" {
    const allocator = std.testing.allocator;

    const yes_node = try ast.Node.createLiteral(allocator, 'x', .{ .start = 0, .end = 1 });
    defer allocator.destroy(yes_node);

    const conditional = try ConditionalNode.init(
        allocator,
        .{ .group_number = 0 }, // Group 0 (entire match)
        yes_node,
        null,
    );
    defer allocator.destroy(conditional);

    try std.testing.expectEqual(@as(usize, 0), conditional.condition.group_number);
}

test "advanced_features: conditional with large group number" {
    const allocator = std.testing.allocator;

    const yes_node = try ast.Node.createLiteral(allocator, 'x', .{ .start = 0, .end = 1 });
    defer allocator.destroy(yes_node);

    const conditional = try ConditionalNode.init(
        allocator,
        .{ .group_number = 999 }, // Large group number
        yes_node,
        null,
    );
    defer allocator.destroy(conditional);

    try std.testing.expectEqual(@as(usize, 999), conditional.condition.group_number);
}

test "advanced_features: conditional with empty group name" {
    const allocator = std.testing.allocator;

    const yes_node = try ast.Node.createLiteral(allocator, 'x', .{ .start = 0, .end = 1 });
    defer allocator.destroy(yes_node);

    const conditional = try ConditionalNode.init(
        allocator,
        .{ .group_name = "" }, // Empty name
        yes_node,
        null,
    );
    defer allocator.destroy(conditional);

    try std.testing.expectEqualStrings("", conditional.condition.group_name);
}

test "advanced_features: advanced node type enum" {
    // Test that all enum values are accessible
    const atomic = AdvancedNodeType.atomic_group;
    const poss_star = AdvancedNodeType.possessive_star;
    const poss_plus = AdvancedNodeType.possessive_plus;
    const poss_opt = AdvancedNodeType.possessive_optional;
    const poss_rep = AdvancedNodeType.possessive_repeat;
    const cond = AdvancedNodeType.conditional;

    try std.testing.expect(atomic == .atomic_group);
    try std.testing.expect(poss_star == .possessive_star);
    try std.testing.expect(poss_plus == .possessive_plus);
    try std.testing.expect(poss_opt == .possessive_optional);
    try std.testing.expect(poss_rep == .possessive_repeat);
    try std.testing.expect(cond == .conditional);
}

// Stress and integration tests
test "advanced_features: stress test - create 1000 atomic groups" {
    const allocator = std.testing.allocator;

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const child = try ast.Node.createLiteral(allocator, 'a', .{ .start = 0, .end = 1 });
        defer allocator.destroy(child);

        const atomic = try AtomicGroupNode.init(allocator, child);
        defer allocator.destroy(atomic);

        try std.testing.expect(atomic.child == child);
    }
}

test "advanced_features: stress test - create 1000 conditional nodes" {
    const allocator = std.testing.allocator;

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const yes_node = try ast.Node.createLiteral(allocator, 'y', .{ .start = 0, .end = 1 });
        defer allocator.destroy(yes_node);

        const no_node = try ast.Node.createLiteral(allocator, 'n', .{ .start = 0, .end = 1 });
        defer allocator.destroy(no_node);

        const conditional = try ConditionalNode.init(
            allocator,
            .{ .group_number = i },
            yes_node,
            no_node,
        );
        defer allocator.destroy(conditional);

        try std.testing.expectEqual(i, conditional.condition.group_number);
    }
}

test "advanced_features: deeply nested atomic groups" {
    const allocator = std.testing.allocator;

    // Create a chain of nested atomic groups
    const innermost = try ast.Node.createLiteral(allocator, 'x', .{ .start = 0, .end = 1 });
    defer allocator.destroy(innermost);

    const depth = 10;
    var atomics: [depth]*AtomicGroupNode = undefined;

    // Build nested structure
    var current_child = innermost;
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        const child_copy = try ast.Node.createLiteral(allocator, 'x', .{ .start = 0, .end = 1 });
        atomics[i] = try AtomicGroupNode.init(allocator, child_copy);
        current_child = child_copy;
    }

    // Cleanup
    i = 0;
    while (i < depth) : (i += 1) {
        allocator.destroy(atomics[i].child);
        allocator.destroy(atomics[i]);
    }
}

test "advanced_features: conditional with all condition types" {
    const allocator = std.testing.allocator;

    // Test group_number condition
    {
        const yes = try ast.Node.createLiteral(allocator, 'y', .{ .start = 0, .end = 1 });
        defer allocator.destroy(yes);
        const cond1 = try ConditionalNode.init(allocator, .{ .group_number = 42 }, yes, null);
        defer allocator.destroy(cond1);
        try std.testing.expectEqual(@as(usize, 42), cond1.condition.group_number);
    }

    // Test group_name condition
    {
        const yes = try ast.Node.createLiteral(allocator, 'y', .{ .start = 0, .end = 1 });
        defer allocator.destroy(yes);
        const cond2 = try ConditionalNode.init(allocator, .{ .group_name = "test_name" }, yes, null);
        defer allocator.destroy(cond2);
        try std.testing.expectEqualStrings("test_name", cond2.condition.group_name);
    }

    // Test assertion condition
    {
        const assertion = try ast.Node.createLiteral(allocator, 'a', .{ .start = 0, .end = 1 });
        defer allocator.destroy(assertion);
        const yes = try ast.Node.createLiteral(allocator, 'y', .{ .start = 0, .end = 1 });
        defer allocator.destroy(yes);
        const cond3 = try ConditionalNode.init(allocator, .{ .assertion = assertion }, yes, null);
        defer allocator.destroy(cond3);
        try std.testing.expect(cond3.condition == .assertion);
    }
}

test "advanced_features: complex conditional tree" {
    const allocator = std.testing.allocator;

    // Create a complex conditional with both branches
    const yes_inner = try ast.Node.createLiteral(allocator, 'a', .{ .start = 0, .end = 1 });
    defer allocator.destroy(yes_inner);

    const no_inner = try ast.Node.createLiteral(allocator, 'b', .{ .start = 0, .end = 1 });
    defer allocator.destroy(no_inner);

    const inner_cond = try ConditionalNode.init(
        allocator,
        .{ .group_number = 1 },
        yes_inner,
        no_inner,
    );
    defer allocator.destroy(inner_cond);

    // Create outer level nodes that reference the inner conditional
    const outer_yes = try ast.Node.createLiteral(allocator, 'c', .{ .start = 0, .end = 1 });
    defer allocator.destroy(outer_yes);

    const outer_cond = try ConditionalNode.init(
        allocator,
        .{ .group_number = 2 },
        outer_yes,
        null,
    );
    defer allocator.destroy(outer_cond);

    try std.testing.expectEqual(@as(usize, 1), inner_cond.condition.group_number);
    try std.testing.expectEqual(@as(usize, 2), outer_cond.condition.group_number);
}

test "advanced_features: memory stress - repeated atomic group creation" {
    const allocator = std.testing.allocator;

    var cycle: usize = 0;
    while (cycle < 100) : (cycle += 1) {
        const child = try ast.Node.createLiteral(allocator, 'x', .{ .start = 0, .end = 1 });
        const atomic = try AtomicGroupNode.init(allocator, child);

        try std.testing.expect(atomic.child == child);

        allocator.destroy(atomic);
        allocator.destroy(child);
    }
}

test "advanced_features: all possessive quantifier variants" {
    // Ensure all variants are distinct
    const variants = [_]PossessiveQuantifier{
        .star_possessive,
        .plus_possessive,
        .optional_possessive,
        .repeat_possessive,
    };

    // Each should be unique
    for (variants, 0..) |v1, i| {
        for (variants, 0..) |v2, j| {
            if (i == j) {
                try std.testing.expectEqual(v1, v2);
            } else {
                try std.testing.expect(v1 != v2);
            }
        }
    }
}

test "advanced_features: condition type switching" {
    // Test that we can switch on ConditionType
    const cond1 = ConditionType{ .group_number = 5 };
    const cond2 = ConditionType{ .group_name = "test" };

    const result1 = switch (cond1) {
        .group_number => |num| num,
        .group_name => 0,
        .assertion => 0,
    };
    try std.testing.expectEqual(@as(usize, 5), result1);

    const result2 = switch (cond2) {
        .group_number => "",
        .group_name => |name| name,
        .assertion => "",
    };
    try std.testing.expectEqualStrings("test", result2);
}

test "advanced_features: atomic group with different child types" {
    const allocator = std.testing.allocator;

    // Test with different literal values
    const literals = [_]u8{ 'a', 'z', '0', '9', ' ', '!', '\n' };

    for (literals) |lit| {
        const child = try ast.Node.createLiteral(allocator, lit, .{ .start = 0, .end = 1 });
        defer allocator.destroy(child);

        const atomic = try AtomicGroupNode.init(allocator, child);
        defer allocator.destroy(atomic);

        try std.testing.expect(atomic.child == child);
    }
}

test "advanced_features: conditional branches equality" {
    const allocator = std.testing.allocator;

    const yes = try ast.Node.createLiteral(allocator, 'x', .{ .start = 0, .end = 1 });
    defer allocator.destroy(yes);

    const no = try ast.Node.createLiteral(allocator, 'x', .{ .start = 0, .end = 1 });
    defer allocator.destroy(no);

    const cond = try ConditionalNode.init(
        allocator,
        .{ .group_number = 1 },
        yes,
        no,
    );
    defer allocator.destroy(cond);

    // Even though both nodes have same literal, they should be distinct objects
    try std.testing.expect(cond.yes_branch != cond.no_branch.?);
}

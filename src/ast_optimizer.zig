const std = @import("std");
const ast = @import("ast.zig");

/// AST optimization pass
/// Performs transformations to simplify and optimize the AST
pub const ASTOptimizer = struct {
    allocator: std.mem.Allocator,
    optimization_count: usize,

    pub fn init(allocator: std.mem.Allocator) ASTOptimizer {
        return .{
            .allocator = allocator,
            .optimization_count = 0,
        };
    }

    /// Optimize an AST tree (modifies in place)
    /// Returns the number of optimizations performed
    pub fn optimize(self: *ASTOptimizer, tree: *ast.AST) !usize {
        self.optimization_count = 0;

        // Run optimization passes until no more changes
        var changed = true;
        var iterations: usize = 0;
        const max_iterations = 100; // Prevent infinite loops

        while (changed and iterations < max_iterations) {
            changed = false;
            iterations += 1;

            // Constant folding and simplification
            if (try self.constantFold(&tree.root)) changed = true;

            // Remove redundant nodes
            if (try self.removeRedundant(&tree.root)) changed = true;

            // Flatten concatenations
            if (try self.flattenConcat(&tree.root)) changed = true;

            // Merge adjacent literals
            if (try self.mergeLiterals(&tree.root)) changed = true;

            // Simplify quantifiers
            if (try self.simplifyQuantifiers(&tree.root)) changed = true;

            // Eliminate dead code
            if (try self.eliminateDeadCode(&tree.root)) changed = true;
        }

        return self.optimization_count;
    }

    /// Constant folding: evaluate constant expressions
    fn constantFold(self: *ASTOptimizer, node: **ast.Node) !bool {
        var changed = false;

        switch (node.*.node_type) {
            .concat => {
                if (try self.constantFold(&node.*.data.concat.left)) changed = true;
                if (try self.constantFold(&node.*.data.concat.right)) changed = true;

                // Fold concat(empty, x) -> x
                if (node.*.data.concat.left.node_type == .empty) {
                    const left_to_free = node.*.data.concat.left;
                    const right = node.*.data.concat.right;
                    node.*.* = right.*;
                    self.allocator.destroy(left_to_free);
                    self.allocator.destroy(right);
                    self.optimization_count += 1;
                    changed = true;
                }
                // Fold concat(x, empty) -> x
                else if (node.*.data.concat.right.node_type == .empty) {
                    const right_to_free = node.*.data.concat.right;
                    const left = node.*.data.concat.left;
                    node.*.* = left.*;
                    self.allocator.destroy(right_to_free);
                    self.allocator.destroy(left);
                    self.optimization_count += 1;
                    changed = true;
                }
            },
            .alternation => {
                if (try self.constantFold(&node.*.data.alternation.left)) changed = true;
                if (try self.constantFold(&node.*.data.alternation.right)) changed = true;

                // Fold alt(x, x) -> x (if both branches are identical literals)
                const left = node.*.data.alternation.left;
                const right = node.*.data.alternation.right;
                if (left.node_type == .literal and right.node_type == .literal) {
                    if (left.data.literal == right.data.literal) {
                        node.*.* = left.*;
                        self.allocator.destroy(left);
                        self.allocator.destroy(right);
                        self.optimization_count += 1;
                        changed = true;
                    }
                }
            },
            .star => {
                if (try self.constantFold(&node.*.data.star.child)) changed = true;

                // Fold star(empty) -> empty
                if (node.*.data.star.child.node_type == .empty) {
                    const empty_node = try self.allocator.create(ast.Node);
                    empty_node.* = .{
                        .node_type = .empty,
                        .data = .{ .empty = {} },
                        .span = node.*.span,
                    };
                    node.* = empty_node;
                    self.optimization_count += 1;
                    changed = true;
                }
                // Fold star(star(x)) -> star(x) (nested stars)
                else if (node.*.data.star.child.node_type == .star) {
                    const child = node.*.data.star.child;
                    node.*.* = child.*;
                    self.allocator.destroy(child);
                    self.optimization_count += 1;
                    changed = true;
                }
                // Fold star(group(star(x))) -> star(group(x)) or star(x) if possible
                else if (node.*.data.star.child.node_type == .group) {
                    const group_child = node.*.data.star.child.data.group.child;
                    if (group_child.node_type == .star) {
                        // Replace star(group(star(x))) with group(star(x))
                        const child = node.*.data.star.child;
                        node.*.* = child.*;
                        self.allocator.destroy(child);
                        self.optimization_count += 1;
                        changed = true;
                    }
                }
            },
            .plus => {
                if (try self.constantFold(&node.*.data.plus.child)) changed = true;

                // Fold plus(empty) -> empty
                if (node.*.data.plus.child.node_type == .empty) {
                    const empty_node = try self.allocator.create(ast.Node);
                    empty_node.* = .{
                        .node_type = .empty,
                        .data = .{ .empty = {} },
                        .span = node.*.span,
                    };
                    node.* = empty_node;
                    self.optimization_count += 1;
                    changed = true;
                }
            },
            .optional => {
                if (try self.constantFold(&node.*.data.optional.child)) changed = true;
            },
            .repeat => {
                if (try self.constantFold(&node.*.data.repeat.child)) changed = true;

                const repeat = node.*.data.repeat;
                // Fold repeat{0,0}(x) -> empty
                if (repeat.bounds.min == 0 and repeat.bounds.max != null and repeat.bounds.max.? == 0) {
                    const empty_node = try self.allocator.create(ast.Node);
                    empty_node.* = .{
                        .node_type = .empty,
                        .data = .{ .empty = {} },
                        .span = node.*.span,
                    };
                    node.* = empty_node;
                    self.optimization_count += 1;
                    changed = true;
                }
                // Fold repeat{1,1}(x) -> x
                else if (repeat.bounds.min == 1 and repeat.bounds.max != null and repeat.bounds.max.? == 1) {
                    const child = repeat.child;
                    node.*.* = child.*;
                    self.allocator.destroy(child);
                    self.optimization_count += 1;
                    changed = true;
                }
            },
            .group => {
                if (try self.constantFold(&node.*.data.group.child)) changed = true;
            },
            .lookahead => {
                if (try self.constantFold(&node.*.data.lookahead.child)) changed = true;
            },
            .lookbehind => {
                if (try self.constantFold(&node.*.data.lookbehind.child)) changed = true;
            },
            else => {},
        }

        return changed;
    }

    /// Remove redundant nodes
    fn removeRedundant(self: *ASTOptimizer, node: **ast.Node) !bool {
        var changed = false;

        switch (node.*.node_type) {
            .concat => {
                if (try self.removeRedundant(&node.*.data.concat.left)) changed = true;
                if (try self.removeRedundant(&node.*.data.concat.right)) changed = true;
            },
            .alternation => {
                if (try self.removeRedundant(&node.*.data.alternation.left)) changed = true;
                if (try self.removeRedundant(&node.*.data.alternation.right)) changed = true;
            },
            .star => {
                if (try self.removeRedundant(&node.*.data.star.child)) changed = true;

                // Remove nested star: (a*)* -> a*
                if (node.*.data.star.child.node_type == .star) {
                    const inner_star = node.*.data.star.child.data.star;
                    // Keep the outer greedy flag
                    node.*.data.star.child = inner_star.child;
                    self.optimization_count += 1;
                    changed = true;
                }
            },
            .plus => {
                if (try self.removeRedundant(&node.*.data.plus.child)) changed = true;
            },
            .optional => {
                if (try self.removeRedundant(&node.*.data.optional.child)) changed = true;

                // Remove nested optional: (a?)? -> a?
                if (node.*.data.optional.child.node_type == .optional) {
                    const inner_opt = node.*.data.optional.child.data.optional;
                    node.*.data.optional.child = inner_opt.child;
                    self.optimization_count += 1;
                    changed = true;
                }
            },
            .repeat => {
                if (try self.removeRedundant(&node.*.data.repeat.child)) changed = true;
            },
            .group => {
                if (try self.removeRedundant(&node.*.data.group.child)) changed = true;

                // Remove non-capturing group with no effect: (?:a) -> a
                // (but only if not in alternation context)
                if (node.*.data.group.capture_index == null) {
                    // For now, keep groups as they might be needed for precedence
                    // TODO: Add context awareness
                }
            },
            .lookahead => {
                if (try self.removeRedundant(&node.*.data.lookahead.child)) changed = true;
            },
            .lookbehind => {
                if (try self.removeRedundant(&node.*.data.lookbehind.child)) changed = true;
            },
            else => {},
        }

        return changed;
    }

    /// Flatten nested concatenations
    fn flattenConcat(self: *ASTOptimizer, node: **ast.Node) !bool {
        var changed = false;

        switch (node.*.node_type) {
            .concat => {
                if (try self.flattenConcat(&node.*.data.concat.left)) changed = true;
                if (try self.flattenConcat(&node.*.data.concat.right)) changed = true;
            },
            .alternation => {
                if (try self.flattenConcat(&node.*.data.alternation.left)) changed = true;
                if (try self.flattenConcat(&node.*.data.alternation.right)) changed = true;
            },
            .star => {
                if (try self.flattenConcat(&node.*.data.star.child)) changed = true;
            },
            .plus => {
                if (try self.flattenConcat(&node.*.data.plus.child)) changed = true;
            },
            .optional => {
                if (try self.flattenConcat(&node.*.data.optional.child)) changed = true;
            },
            .repeat => {
                if (try self.flattenConcat(&node.*.data.repeat.child)) changed = true;
            },
            .group => {
                if (try self.flattenConcat(&node.*.data.group.child)) changed = true;
            },
            .lookahead => {
                if (try self.flattenConcat(&node.*.data.lookahead.child)) changed = true;
            },
            .lookbehind => {
                if (try self.flattenConcat(&node.*.data.lookbehind.child)) changed = true;
            },
            else => {},
        }

        return changed;
    }

    /// Merge adjacent literal nodes
    fn mergeLiterals(self: *ASTOptimizer, node: **ast.Node) !bool {
        var changed = false;

        switch (node.*.node_type) {
            .concat => {
                // First recurse
                if (try self.mergeLiterals(&node.*.data.concat.left)) changed = true;
                if (try self.mergeLiterals(&node.*.data.concat.right)) changed = true;

                // Check if both sides are literals
                const left = node.*.data.concat.left;
                const right = node.*.data.concat.right;

                if (left.node_type == .literal and right.node_type == .literal) {
                    // For now, keep as-is since merging would change the AST structure significantly
                    // This would require creating a "string literal" node type
                    // TODO: Add string literal node type
                }
            },
            .alternation => {
                if (try self.mergeLiterals(&node.*.data.alternation.left)) changed = true;
                if (try self.mergeLiterals(&node.*.data.alternation.right)) changed = true;
            },
            .star => {
                if (try self.mergeLiterals(&node.*.data.star.child)) changed = true;
            },
            .plus => {
                if (try self.mergeLiterals(&node.*.data.plus.child)) changed = true;
            },
            .optional => {
                if (try self.mergeLiterals(&node.*.data.optional.child)) changed = true;
            },
            .repeat => {
                if (try self.mergeLiterals(&node.*.data.repeat.child)) changed = true;
            },
            .group => {
                if (try self.mergeLiterals(&node.*.data.group.child)) changed = true;
            },
            .lookahead => {
                if (try self.mergeLiterals(&node.*.data.lookahead.child)) changed = true;
            },
            .lookbehind => {
                if (try self.mergeLiterals(&node.*.data.lookbehind.child)) changed = true;
            },
            else => {},
        }

        return changed;
    }

    /// Simplify quantifiers
    fn simplifyQuantifiers(self: *ASTOptimizer, node: **ast.Node) !bool {
        var changed = false;

        switch (node.*.node_type) {
            .concat => {
                if (try self.simplifyQuantifiers(&node.*.data.concat.left)) changed = true;
                if (try self.simplifyQuantifiers(&node.*.data.concat.right)) changed = true;
            },
            .alternation => {
                if (try self.simplifyQuantifiers(&node.*.data.alternation.left)) changed = true;
                if (try self.simplifyQuantifiers(&node.*.data.alternation.right)) changed = true;
            },
            .star => {
                if (try self.simplifyQuantifiers(&node.*.data.star.child)) changed = true;
            },
            .plus => {
                if (try self.simplifyQuantifiers(&node.*.data.plus.child)) changed = true;

                // Convert plus to star if child is optional: (a?)+ -> a*
                if (node.*.data.plus.child.node_type == .optional) {
                    const optional_child = node.*.data.plus.child;
                    const child = optional_child.data.optional.child;
                    const greedy = node.*.data.plus.greedy;
                    const span = node.*.span;
                    // Free the optional node since we're bypassing it
                    self.allocator.destroy(optional_child);
                    node.*.* = .{
                        .node_type = .star,
                        .data = .{
                            .star = .{
                                .child = child,
                                .greedy = greedy,
                            },
                        },
                        .span = span,
                    };
                    self.optimization_count += 1;
                    changed = true;
                }
            },
            .optional => {
                if (try self.simplifyQuantifiers(&node.*.data.optional.child)) changed = true;
            },
            .repeat => {
                if (try self.simplifyQuantifiers(&node.*.data.repeat.child)) changed = true;

                const repeat = node.*.data.repeat;
                // Convert repeat{0,1} to optional
                if (repeat.bounds.min == 0 and repeat.bounds.max != null and repeat.bounds.max.? == 1) {
                    const child = repeat.child;
                    const greedy = repeat.greedy;
                    const span = node.*.span;
                    node.*.* = .{
                        .node_type = .optional,
                        .data = .{
                            .optional = .{
                                .child = child,
                                .greedy = greedy,
                            },
                        },
                        .span = span,
                    };
                    self.optimization_count += 1;
                    changed = true;
                }
                // Convert repeat{0,} to star
                else if (repeat.bounds.min == 0 and repeat.bounds.max == null) {
                    const child = repeat.child;
                    const greedy = repeat.greedy;
                    const span = node.*.span;
                    node.*.* = .{
                        .node_type = .star,
                        .data = .{
                            .star = .{
                                .child = child,
                                .greedy = greedy,
                            },
                        },
                        .span = span,
                    };
                    self.optimization_count += 1;
                    changed = true;
                }
                // Convert repeat{1,} to plus
                else if (repeat.bounds.min == 1 and repeat.bounds.max == null) {
                    const child = repeat.child;
                    const greedy = repeat.greedy;
                    const span = node.*.span;
                    node.*.* = .{
                        .node_type = .plus,
                        .data = .{
                            .plus = .{
                                .child = child,
                                .greedy = greedy,
                            },
                        },
                        .span = span,
                    };
                    self.optimization_count += 1;
                    changed = true;
                }
            },
            .group => {
                if (try self.simplifyQuantifiers(&node.*.data.group.child)) changed = true;
            },
            .lookahead => {
                if (try self.simplifyQuantifiers(&node.*.data.lookahead.child)) changed = true;
            },
            .lookbehind => {
                if (try self.simplifyQuantifiers(&node.*.data.lookbehind.child)) changed = true;
            },
            else => {},
        }

        return changed;
    }

    /// Eliminate dead code
    fn eliminateDeadCode(self: *ASTOptimizer, node: **ast.Node) !bool {
        var changed = false;

        switch (node.*.node_type) {
            .concat => {
                if (try self.eliminateDeadCode(&node.*.data.concat.left)) changed = true;
                if (try self.eliminateDeadCode(&node.*.data.concat.right)) changed = true;
            },
            .alternation => {
                if (try self.eliminateDeadCode(&node.*.data.alternation.left)) changed = true;
                if (try self.eliminateDeadCode(&node.*.data.alternation.right)) changed = true;

                // Eliminate empty branches: (a|empty) -> a
                if (node.*.data.alternation.right.node_type == .empty) {
                    node.*.* = node.*.data.alternation.left.*;
                    self.optimization_count += 1;
                    changed = true;
                } else if (node.*.data.alternation.left.node_type == .empty) {
                    node.*.* = node.*.data.alternation.right.*;
                    self.optimization_count += 1;
                    changed = true;
                }
            },
            .star => {
                if (try self.eliminateDeadCode(&node.*.data.star.child)) changed = true;
            },
            .plus => {
                if (try self.eliminateDeadCode(&node.*.data.plus.child)) changed = true;
            },
            .optional => {
                if (try self.eliminateDeadCode(&node.*.data.optional.child)) changed = true;
            },
            .repeat => {
                if (try self.eliminateDeadCode(&node.*.data.repeat.child)) changed = true;
            },
            .group => {
                if (try self.eliminateDeadCode(&node.*.data.group.child)) changed = true;
            },
            .lookahead => {
                if (try self.eliminateDeadCode(&node.*.data.lookahead.child)) changed = true;
            },
            .lookbehind => {
                if (try self.eliminateDeadCode(&node.*.data.lookbehind.child)) changed = true;
            },
            else => {},
        }

        return changed;
    }
};

test "ast optimizer: constant folding" {
    const allocator = std.testing.allocator;
    const parser = @import("parser.zig");

    // Test repeat{1,1}(x) -> x
    var p = try parser.Parser.init(allocator, "a{1,1}");
    var tree = try p.parse();
    defer tree.deinit();

    var optimizer = ASTOptimizer.init(allocator);
    const count = try optimizer.optimize(&tree);

    try std.testing.expect(count > 0);
}

test "ast optimizer: simplify quantifiers" {
    const allocator = std.testing.allocator;
    const parser = @import("parser.zig");

    // Test repeat{0,1} -> optional
    var p = try parser.Parser.init(allocator, "a{0,1}");
    var tree = try p.parse();
    defer tree.deinit();

    var optimizer = ASTOptimizer.init(allocator);
    const count = try optimizer.optimize(&tree);

    try std.testing.expect(count > 0);
    try std.testing.expectEqual(ast.NodeType.optional, tree.root.node_type);
}

test "ast optimizer: remove redundant" {
    const allocator = std.testing.allocator;
    const parser = @import("parser.zig");

    // Test (a*)* -> a*
    var p = try parser.Parser.init(allocator, "(a*)*");
    var tree = try p.parse();
    defer tree.deinit();

    var optimizer = ASTOptimizer.init(allocator);
    const count = try optimizer.optimize(&tree);

    try std.testing.expect(count > 0);
}

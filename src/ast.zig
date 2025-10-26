const std = @import("std");
const common = @import("common.zig");

/// Abstract Syntax Tree node types for regular expressions
pub const NodeType = enum {
    /// Matches a single literal character
    literal,
    /// Matches any character (.)
    any,
    /// Concatenation of two expressions
    concat,
    /// Alternation (|)
    alternation,
    /// Kleene star (*)
    star,
    /// Plus (+)
    plus,
    /// Optional (?)
    optional,
    /// Repetition {m,n}
    repeat,
    /// Character class [...]
    char_class,
    /// Capture group (...)
    group,
    /// Anchor (^, $, \b, \B)
    anchor,
    /// Empty/epsilon
    empty,
};

/// Anchor types
pub const AnchorType = enum {
    start_line, // ^
    end_line, // $
    start_text, // \A
    end_text, // \z or \Z
    word_boundary, // \b
    non_word_boundary, // \B
};

/// Repetition bounds for {m,n}
pub const RepeatBounds = struct {
    min: usize,
    max: ?usize, // null means unbounded

    pub fn init(min: usize, max: ?usize) RepeatBounds {
        return .{ .min = min, .max = max };
    }

    pub fn exactly(n: usize) RepeatBounds {
        return .{ .min = n, .max = n };
    }

    pub fn atLeast(n: usize) RepeatBounds {
        return .{ .min = n, .max = null };
    }

    pub fn between(min: usize, max: usize) RepeatBounds {
        return .{ .min = min, .max = max };
    }
};

/// AST Node
pub const Node = struct {
    node_type: NodeType,
    data: NodeData,
    span: common.Span,

    pub const NodeData = union(NodeType) {
        literal: u8,
        any: void,
        concat: Concat,
        alternation: Alternation,
        star: *Node,
        plus: *Node,
        optional: *Node,
        repeat: Repeat,
        char_class: common.CharClass,
        group: Group,
        anchor: AnchorType,
        empty: void,
    };

    pub const Concat = struct {
        left: *Node,
        right: *Node,
    };

    pub const Alternation = struct {
        left: *Node,
        right: *Node,
    };

    pub const Repeat = struct {
        child: *Node,
        bounds: RepeatBounds,
    };

    pub const Group = struct {
        child: *Node,
        capture_index: ?usize, // null for non-capturing groups
    };

    pub fn createLiteral(allocator: std.mem.Allocator, c: u8, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .literal,
            .data = .{ .literal = c },
            .span = span,
        };
        return node;
    }

    pub fn createAny(allocator: std.mem.Allocator, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .any,
            .data = .{ .any = {} },
            .span = span,
        };
        return node;
    }

    pub fn createConcat(allocator: std.mem.Allocator, left: *Node, right: *Node, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .concat,
            .data = .{ .concat = .{ .left = left, .right = right } },
            .span = span,
        };
        return node;
    }

    pub fn createAlternation(allocator: std.mem.Allocator, left: *Node, right: *Node, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .alternation,
            .data = .{ .alternation = .{ .left = left, .right = right } },
            .span = span,
        };
        return node;
    }

    pub fn createStar(allocator: std.mem.Allocator, child: *Node, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .star,
            .data = .{ .star = child },
            .span = span,
        };
        return node;
    }

    pub fn createPlus(allocator: std.mem.Allocator, child: *Node, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .plus,
            .data = .{ .plus = child },
            .span = span,
        };
        return node;
    }

    pub fn createOptional(allocator: std.mem.Allocator, child: *Node, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .optional,
            .data = .{ .optional = child },
            .span = span,
        };
        return node;
    }

    pub fn createRepeat(allocator: std.mem.Allocator, child: *Node, bounds: RepeatBounds, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .repeat,
            .data = .{ .repeat = .{ .child = child, .bounds = bounds } },
            .span = span,
        };
        return node;
    }

    pub fn createCharClass(allocator: std.mem.Allocator, char_class: common.CharClass, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .char_class,
            .data = .{ .char_class = char_class },
            .span = span,
        };
        return node;
    }

    pub fn createGroup(allocator: std.mem.Allocator, child: *Node, capture_index: ?usize, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .group,
            .data = .{ .group = .{ .child = child, .capture_index = capture_index } },
            .span = span,
        };
        return node;
    }

    pub fn createAnchor(allocator: std.mem.Allocator, anchor_type: AnchorType, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .anchor,
            .data = .{ .anchor = anchor_type },
            .span = span,
        };
        return node;
    }

    pub fn createEmpty(allocator: std.mem.Allocator, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .empty,
            .data = .{ .empty = {} },
            .span = span,
        };
        return node;
    }

    /// Recursively free an AST node and all its children
    pub fn destroy(self: *Node, allocator: std.mem.Allocator) void {
        switch (self.data) {
            .concat => |concat| {
                concat.left.destroy(allocator);
                concat.right.destroy(allocator);
            },
            .alternation => |alt| {
                alt.left.destroy(allocator);
                alt.right.destroy(allocator);
            },
            .star, .plus, .optional => |child| {
                child.destroy(allocator);
            },
            .repeat => |repeat| {
                repeat.child.destroy(allocator);
            },
            .group => |group| {
                group.child.destroy(allocator);
            },
            else => {},
        }
        allocator.destroy(self);
    }
};

/// AST represents the entire parsed regular expression
pub const AST = struct {
    root: *Node,
    allocator: std.mem.Allocator,
    capture_count: usize,

    pub fn init(allocator: std.mem.Allocator, root: *Node, capture_count: usize) AST {
        return .{
            .root = root,
            .allocator = allocator,
            .capture_count = capture_count,
        };
    }

    pub fn deinit(self: *AST) void {
        self.root.destroy(self.allocator);
    }
};

test "create literal node" {
    const allocator = std.testing.allocator;
    const span = common.Span.init(0, 1);
    const node = try Node.createLiteral(allocator, 'a', span);
    defer allocator.destroy(node);

    try std.testing.expectEqual(NodeType.literal, node.node_type);
    try std.testing.expectEqual(@as(u8, 'a'), node.data.literal);
}

test "create concat node" {
    const allocator = std.testing.allocator;
    const span = common.Span.init(0, 2);

    const left = try Node.createLiteral(allocator, 'a', common.Span.init(0, 1));
    const right = try Node.createLiteral(allocator, 'b', common.Span.init(1, 2));
    const concat = try Node.createConcat(allocator, left, right, span);
    defer concat.destroy(allocator);

    try std.testing.expectEqual(NodeType.concat, concat.node_type);
}

test "create star node" {
    const allocator = std.testing.allocator;
    const span = common.Span.init(0, 2);

    const child = try Node.createLiteral(allocator, 'a', common.Span.init(0, 1));
    const star = try Node.createStar(allocator, child, span);
    defer star.destroy(allocator);

    try std.testing.expectEqual(NodeType.star, star.node_type);
}

test "repeat bounds" {
    const exactly_3 = RepeatBounds.exactly(3);
    try std.testing.expectEqual(@as(usize, 3), exactly_3.min);
    try std.testing.expectEqual(@as(usize, 3), exactly_3.max.?);

    const at_least_2 = RepeatBounds.atLeast(2);
    try std.testing.expectEqual(@as(usize, 2), at_least_2.min);
    try std.testing.expectEqual(@as(?usize, null), at_least_2.max);

    const between_1_5 = RepeatBounds.between(1, 5);
    try std.testing.expectEqual(@as(usize, 1), between_1_5.min);
    try std.testing.expectEqual(@as(usize, 5), between_1_5.max.?);
}

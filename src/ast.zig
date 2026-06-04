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
    /// Lookahead assertion (?=...) or (?!...)
    lookahead,
    /// Lookbehind assertion (?<=...) or (?<!...)
    lookbehind,
    /// Backreference \1, \2, etc.
    backref,
    /// Unicode property escape `\p{...}` / `\P{...}`
    unicode_property,
    /// A `/v`-flag character class with set notation `[A&&B]`/`[A--B]`/`[AB]`.
    class_set,
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
        star: Quantifier,
        plus: Quantifier,
        optional: Quantifier,
        repeat: Repeat,
        char_class: common.CharClass,
        group: Group,
        anchor: AnchorType,
        empty: void,
        lookahead: Assertion,
        lookbehind: Assertion,
        backref: Backreference,
        unicode_property: UnicodeProp,
        class_set: *ClassSet,
    };

    pub const UnicodeProp = struct {
        spec: @import("unicode.zig").PropSpec,
        negated: bool = false,
    };

    /// A code-point range for a `/v` class set (code points, not bytes).
    pub const CpRange = struct { lo: u21, hi: u21 };

    pub const ClassOp = enum { union_, intersection, difference };

    pub const ClassItem = union(enum) {
        range: CpRange,
        property: struct { spec: @import("unicode.zig").PropSpec, negated: bool },
        nested: *ClassSet,
        /// A `\q{...}` string alternative — a (possibly multi-code-point) string
        /// the class can match as a unit.
        string: []const u21,
    };

    /// A `/v` class-set expression: a list of items combined by one operator,
    /// optionally complemented (`[^...]`).
    pub const ClassSet = struct {
        op: ClassOp,
        negated: bool = false,
        items: []const ClassItem,

        /// The longest byte length the class matches at `input[start..]`, or null.
        /// Strings (`\q{...}`) and nested sets can consume multiple code points;
        /// for intersection/difference (and complement) only single-code-point
        /// membership is considered.
        pub fn matchLongest(self: *const ClassSet, input: []const u8, start: usize, ignore_case: bool) ?usize {
            const u = @import("unicode.zig");
            if (self.op != .union_ or self.negated) {
                if (start >= input.len) return null;
                const dec = u.decodeUtf8Lenient(input[start..]) orelse return null;
                if (!self.matches(dec.codepoint, ignore_case)) return null;
                return start + dec.len;
            }
            var best: ?usize = null;
            for (self.items) |it| {
                const e: ?usize = switch (it) {
                    .string => |s| matchStringItem(input, start, s, ignore_case),
                    .nested => |n| n.matchLongest(input, start, ignore_case),
                    .range, .property => blk: {
                        if (start >= input.len) break :blk null;
                        const dec = u.decodeUtf8Lenient(input[start..]) orelse break :blk null;
                        break :blk if (itemMatches(it, dec.codepoint, ignore_case)) start + dec.len else null;
                    },
                };
                if (e) |end| {
                    if (best == null or end > best.?) best = end;
                }
            }
            return best;
        }

        pub fn matches(self: *const ClassSet, cp: u21, ignore_case: bool) bool {
            const r = switch (self.op) {
                .union_ => blk: {
                    for (self.items) |it| if (itemMatches(it, cp, ignore_case)) break :blk true;
                    break :blk false;
                },
                .intersection => blk: {
                    for (self.items) |it| if (!itemMatches(it, cp, ignore_case)) break :blk false;
                    break :blk true;
                },
                .difference => blk: {
                    if (self.items.len == 0) break :blk false;
                    if (!itemMatches(self.items[0], cp, ignore_case)) break :blk false;
                    for (self.items[1..]) |it| if (itemMatches(it, cp, ignore_case)) break :blk false;
                    break :blk true;
                },
            };
            return r != self.negated;
        }
    };

    fn itemMatches(it: ClassItem, cp: u21, ignore_case: bool) bool {
        const u = @import("unicode.zig");
        switch (it) {
            .range => |r| {
                if (cp >= r.lo and cp <= r.hi) return true;
                if (ignore_case) {
                    // Simple ASCII case folding for the common `i` cases.
                    if (cp >= 'A' and cp <= 'Z') {
                        const l = cp + 32;
                        if (l >= r.lo and l <= r.hi) return true;
                    } else if (cp >= 'a' and cp <= 'z') {
                        const up = cp - 32;
                        if (up >= r.lo and up <= r.hi) return true;
                    }
                }
                return false;
            },
            .property => |p| return u.matchesSpec(cp, p.spec) != p.negated,
            .nested => |n| return n.matches(cp, ignore_case),
            // A single-code-point string contributes that code point to membership.
            .string => |s| return s.len == 1 and (s[0] == cp or (ignore_case and asciiFoldEq(s[0], cp))),
        }
    }

    fn asciiFoldEq(a: u21, b: u21) bool {
        const la: u21 = if (a >= 'A' and a <= 'Z') a + 32 else a;
        const lb: u21 = if (b >= 'A' and b <= 'Z') b + 32 else b;
        return la == lb;
    }

    /// Match a `\q{...}` string (a sequence of code points) at `input[start..]`,
    /// returning the end byte position or null.
    fn matchStringItem(input: []const u8, start: usize, s: []const u21, ignore_case: bool) ?usize {
        const u = @import("unicode.zig");
        var pos = start;
        for (s) |scp| {
            if (pos >= input.len) return null;
            const dec = u.decodeUtf8Lenient(input[pos..]) orelse return null;
            if (dec.codepoint != scp and !(ignore_case and asciiFoldEq(dec.codepoint, scp))) return null;
            pos += dec.len;
        }
        return pos;
    }

    pub const Concat = struct {
        left: *Node,
        right: *Node,
    };

    pub const Alternation = struct {
        left: *Node,
        right: *Node,
    };

    pub const Quantifier = struct {
        child: *Node,
        greedy: bool = true, // true for greedy, false for lazy
    };

    pub const Repeat = struct {
        child: *Node,
        bounds: RepeatBounds,
        greedy: bool = true,
    };

    /// A per-group flag override from inline modifiers `(?imsu-imsu:...)`: each
    /// field is null (inherit), true (add) or false (remove). Only the
    /// match-time flags live here (i/m/s/u); the parse-time flags `x`
    /// (extended) and `U` (swap-greedy) are consumed by the parser and never
    /// reach the AST.
    pub const FlagDelta = struct {
        i: ?bool = null,
        m: ?bool = null,
        s: ?bool = null,
        u: ?bool = null,

        /// True if any match-time flag is set, i.e. this delta affects matching
        /// and the group must be carried by the backtracking engine.
        pub fn any(self: FlagDelta) bool {
            return self.i != null or self.m != null or self.s != null or self.u != null;
        }
    };

    pub const Group = struct {
        child: *Node,
        capture_index: ?usize, // null for non-capturing groups
        name: ?[]const u8 = null, // null for unnamed groups
        mod: ?FlagDelta = null, // inline-modifier flag override, if any
    };

    pub const Assertion = struct {
        child: *Node,
        positive: bool, // true for positive, false for negative
    };

    pub const Backreference = struct {
        index: usize, // 1-based capture group index
        name: ?[]const u8 = null, // optional name for named backreferences
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

    pub fn createStar(allocator: std.mem.Allocator, child: *Node, greedy: bool, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .star,
            .data = .{ .star = .{ .child = child, .greedy = greedy } },
            .span = span,
        };
        return node;
    }

    pub fn createPlus(allocator: std.mem.Allocator, child: *Node, greedy: bool, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .plus,
            .data = .{ .plus = .{ .child = child, .greedy = greedy } },
            .span = span,
        };
        return node;
    }

    pub fn createOptional(allocator: std.mem.Allocator, child: *Node, greedy: bool, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .optional,
            .data = .{ .optional = .{ .child = child, .greedy = greedy } },
            .span = span,
        };
        return node;
    }

    pub fn createRepeat(allocator: std.mem.Allocator, child: *Node, bounds: RepeatBounds, greedy: bool, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .repeat,
            .data = .{ .repeat = .{ .child = child, .bounds = bounds, .greedy = greedy } },
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

    pub fn createClassSet(allocator: std.mem.Allocator, set: *ClassSet, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .class_set,
            .data = .{ .class_set = set },
            .span = span,
        };
        return node;
    }

    pub fn createGroup(allocator: std.mem.Allocator, child: *Node, capture_index: ?usize, span: common.Span) !*Node {
        return createNamedGroup(allocator, child, capture_index, null, span);
    }

    pub fn createNamedGroup(allocator: std.mem.Allocator, child: *Node, capture_index: ?usize, name: ?[]const u8, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .group,
            .data = .{ .group = .{ .child = child, .capture_index = capture_index, .name = name } },
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

    pub fn createLookahead(allocator: std.mem.Allocator, child: *Node, positive: bool, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .lookahead,
            .data = .{ .lookahead = .{ .child = child, .positive = positive } },
            .span = span,
        };
        return node;
    }

    pub fn createLookbehind(allocator: std.mem.Allocator, child: *Node, positive: bool, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .lookbehind,
            .data = .{ .lookbehind = .{ .child = child, .positive = positive } },
            .span = span,
        };
        return node;
    }

    pub fn createBackreference(allocator: std.mem.Allocator, index: usize, name: ?[]const u8, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .backref,
            .data = .{ .backref = .{ .index = index, .name = name } },
            .span = span,
        };
        return node;
    }

    pub fn createUnicodeProperty(allocator: std.mem.Allocator, spec: @import("unicode.zig").PropSpec, negated: bool, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .unicode_property,
            .data = .{ .unicode_property = .{ .spec = spec, .negated = negated } },
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
            .star, .plus, .optional => |quant| {
                quant.child.destroy(allocator);
            },
            .repeat => |repeat| {
                repeat.child.destroy(allocator);
            },
            .group => |group| {
                if (group.name) |name| {
                    allocator.free(name);
                }
                group.child.destroy(allocator);
            },
            .lookahead, .lookbehind => |assertion| {
                assertion.child.destroy(allocator);
            },
            .backref => |backref| {
                if (backref.name) |name| {
                    allocator.free(name);
                }
            },
            .char_class => |char_class| {
                // Free the ranges array. This is safe because:
                // - For custom char classes ([a-z]), parser allocates ranges
                // - For predefined classes (\d, \w), they use static arrays
                // - Static arrays can't be freed, but we only reach here for parsed nodes
                // - NFA already duplicated these ranges, so we own the originals

                // Check if this is a heap-allocated slice (not a static array)
                // by checking if the pointer is in the heap range
                // For now, we'll free all of them - predefined classes aren't created via createCharClass from parser
                allocator.free(char_class.ranges);
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
    const star = try Node.createStar(allocator, child, true, span);
    defer star.destroy(allocator);

    try std.testing.expectEqual(NodeType.star, star.node_type);
    try std.testing.expectEqual(true, star.data.star.greedy);
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

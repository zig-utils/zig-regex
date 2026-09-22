const std = @import("std");
const common = @import("common.zig");
const casefold_data = @import("unicode_casefold_data.zig");

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
/// How many pending branch points `Node.destroy` holds without recursing. Only
/// a node whose two children both have children of their own uses a slot, so a
/// sequence or a chain of quantifiers needs none.
const max_teardown_branches = 256;

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

        pub const CaseFoldMode = enum { none, legacy, unicode };

        /// The longest byte length the class matches at `input[start..]`, or null.
        /// Strings (`\q{...}`) and nested sets can consume multiple code points;
        /// set operations compare exact elements so character operands do not
        /// subtract multi-code-point string literals that merely share a prefix.
        pub fn matchLongest(self: *const ClassSet, input: []const u8, start: usize, ignore_case: bool) ?usize {
            return self.matchLongestMode(input, start, if (ignore_case) .unicode else .none);
        }

        pub fn matchLongestMode(self: *const ClassSet, input: []const u8, start: usize, fold_mode: CaseFoldMode) ?usize {
            if (self.op == .union_ and self.negated) {
                if (start >= input.len) return null;
                const dec = decodeClassCodePoint(input, start) orelse return null;
                if (!self.matchesMode(dec.codepoint, fold_mode)) return null;
                return start + dec.len;
            }
            if (self.op != .union_) {
                if (self.items.len == 0) return null;
                const end = itemMatchLongest(self.items[0], input, start, fold_mode) orelse return null;
                if (!self.containsMatch(input, start, end, fold_mode)) return null;
                return end;
            }
            var best: ?usize = null;
            for (self.items) |it| {
                const e = itemMatchLongest(it, input, start, fold_mode);
                if (e) |end| {
                    if (best == null or end > best.?) best = end;
                }
            }
            return best;
        }

        pub fn matches(self: *const ClassSet, cp: u21, ignore_case: bool) bool {
            return self.matchesMode(cp, if (ignore_case) .unicode else .none);
        }

        pub fn matchesMode(self: *const ClassSet, cp: u21, fold_mode: CaseFoldMode) bool {
            const r = switch (self.op) {
                .union_ => blk: {
                    for (self.items) |it| if (itemMatches(it, cp, fold_mode)) break :blk true;
                    break :blk false;
                },
                .intersection => blk: {
                    for (self.items) |it| if (!itemMatches(it, cp, fold_mode)) break :blk false;
                    break :blk true;
                },
                .difference => blk: {
                    if (self.items.len == 0) break :blk false;
                    if (!itemMatches(self.items[0], cp, fold_mode)) break :blk false;
                    for (self.items[1..]) |it| if (itemMatches(it, cp, fold_mode)) break :blk false;
                    break :blk true;
                },
            };
            return r != self.negated;
        }

        fn containsMatch(self: *const ClassSet, input: []const u8, start: usize, end: usize, fold_mode: CaseFoldMode) bool {
            const r = switch (self.op) {
                .union_ => blk: {
                    for (self.items) |it| if (itemContainsMatch(it, input, start, end, fold_mode)) break :blk true;
                    break :blk false;
                },
                .intersection => blk: {
                    for (self.items) |it| if (!itemContainsMatch(it, input, start, end, fold_mode)) break :blk false;
                    break :blk true;
                },
                .difference => blk: {
                    if (self.items.len == 0) break :blk false;
                    if (!itemContainsMatch(self.items[0], input, start, end, fold_mode)) break :blk false;
                    for (self.items[1..]) |it| if (itemContainsMatch(it, input, start, end, fold_mode)) break :blk false;
                    break :blk true;
                },
            };
            return r != self.negated;
        }
    };

    fn itemMatchLongest(it: ClassItem, input: []const u8, start: usize, fold_mode: ClassSet.CaseFoldMode) ?usize {
        return switch (it) {
            .string => |s| matchStringItem(input, start, s, fold_mode),
            .nested => |n| n.matchLongestMode(input, start, fold_mode),
            .range, .property => blk: {
                if (start >= input.len) break :blk null;
                const dec = decodeClassCodePoint(input, start) orelse break :blk null;
                break :blk if (itemMatches(it, dec.codepoint, fold_mode)) start + dec.len else null;
            },
        };
    }

    fn itemContainsMatch(it: ClassItem, input: []const u8, start: usize, end: usize, fold_mode: ClassSet.CaseFoldMode) bool {
        return switch (it) {
            .string => |s| if (matchStringItem(input, start, s, fold_mode)) |e| e == end else false,
            .nested => |n| n.containsMatch(input, start, end, fold_mode),
            .range, .property => blk: {
                const dec = decodeClassCodePoint(input, start) orelse break :blk false;
                if (start + dec.len != end) break :blk false;
                break :blk itemMatches(it, dec.codepoint, fold_mode);
            },
        };
    }

    const ClassDecode = struct {
        codepoint: u21,
        len: usize,
    };

    fn decodeClassCodePoint(input: []const u8, start: usize) ?ClassDecode {
        const u = @import("unicode.zig");
        const first = u.decodeUtf8Lenient(input[start..]) orelse return null;
        if (first.codepoint >= 0xD800 and first.codepoint <= 0xDBFF) {
            const next = start + first.len;
            if (next < input.len) {
                if (u.decodeUtf8Lenient(input[next..])) |second| {
                    if (second.codepoint >= 0xDC00 and second.codepoint <= 0xDFFF) {
                        return .{
                            .codepoint = 0x10000 + ((first.codepoint - 0xD800) << 10) + (second.codepoint - 0xDC00),
                            .len = first.len + second.len,
                        };
                    }
                }
            }
        }
        return .{ .codepoint = first.codepoint, .len = first.len };
    }

    fn itemMatches(it: ClassItem, cp: u21, fold_mode: ClassSet.CaseFoldMode) bool {
        const u = @import("unicode.zig");
        switch (it) {
            .range => |r| {
                if (cp >= r.lo and cp <= r.hi) return true;
                if (fold_mode != .none) {
                    const folded = canonicalCaseFold(cp, fold_mode);
                    if (folded >= r.lo and folded <= r.hi) return true;
                    const folded_lo = canonicalCaseFold(r.lo, fold_mode);
                    const folded_hi = canonicalCaseFold(r.hi, fold_mode);
                    if (folded_lo <= folded_hi and folded >= folded_lo and folded <= folded_hi) return true;
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
            .nested => |n| return n.matchesMode(cp, fold_mode),
            // A single-code-point string contributes that code point to membership.
            .string => |s| return s.len == 1 and (s[0] == cp or (fold_mode != .none and canonicalCaseFold(s[0], fold_mode) == canonicalCaseFold(cp, fold_mode))),
        }
    }

    fn canonicalCaseFold(cp: u21, mode: ClassSet.CaseFoldMode) u21 {
        return switch (mode) {
            .none => cp,
            .legacy => legacyCaseFold(cp),
            .unicode => simpleCaseFold(cp),
        };
    }

    fn legacyCaseFold(cp: u21) u21 {
        if (cp >= 'A' and cp <= 'Z') return cp + 32;
        if (cp >= 0x00C0 and cp <= 0x00D6) return cp + 0x20;
        if (cp >= 0x00D8 and cp <= 0x00DE) return cp + 0x20;
        if (cp >= 0x0391 and cp <= 0x03A1) return cp + 0x20;
        if (cp >= 0x03A3 and cp <= 0x03AB) return cp + 0x20;
        return switch (cp) {
            0x00B5, 0x039C, 0x03BC => 0x03BC,
            0x0178, 0x00FF => 0x00FF,
            0x0345, 0x0399, 0x03B9, 0x1FBE => 0x03B9,
            0x03C2, 0x03A3, 0x03C3 => 0x03C3,
            0x03D0, 0x0392, 0x03B2 => 0x03B2,
            0x03D1, 0x0398, 0x03B8 => 0x03B8,
            0x03D5, 0x03A6, 0x03C6 => 0x03C6,
            0x03D6, 0x03A0, 0x03C0 => 0x03C0,
            0x03F0, 0x039A, 0x03BA => 0x03BA,
            0x03F1, 0x03A1, 0x03C1 => 0x03C1,
            0x03F5, 0x0395, 0x03B5 => 0x03B5,
            0x1E9B, 0x1E60, 0x1E61 => 0x1E61,
            else => cp,
        };
    }

    fn simpleCaseFold(cp: u21) u21 {
        return casefold_data.fold(cp);
    }

    /// An equality key for ECMA-262 Canonicalize (22.2.2.7.3): two characters
    /// get the same key exactly when Canonicalize maps them to the same
    /// character, which is all a backreference compares (22.2.2.7.2).
    ///
    /// With `u` or `v`, Canonicalize is simple case folding. Without them it is
    /// toUppercase kept to a single code unit, and that groups characters the
    /// same way as simple case folding except for the characters that
    /// `legacyCanonicalizeKeepsSelf` lists, which only match themselves.
    pub fn canonicalizeKey(cp: u21, mode: ClassSet.CaseFoldMode) u21 {
        return switch (mode) {
            .none => cp,
            .unicode => casefold_data.fold(cp),
            .legacy => if (cp > 0xFFFF or legacyCanonicalizeKeepsSelf(cp)) cp else casefold_data.fold(cp),
        };
    }

    /// Code units that non-`u` Canonicalize maps to themselves although simple
    /// case folding joins them to another class. The list was checked against
    /// the spec algorithm over every BMP code unit for the Unicode data in
    /// `unicode_casefold_data.zig`; re-derive it if that table is regenerated.
    fn legacyCanonicalizeKeepsSelf(cp: u21) bool {
        return switch (cp) {
            // Step 9: toUppercase maps a non-ASCII character to ASCII (ſ -> S).
            0x017F,
            // toUppercase is the character itself, but simple case folding joins
            // it to a class whose uppercase is another character (ϴ, ẞ, Ω, K, Å).
            0x03F4,
            0x1E9E,
            0x2126,
            0x212A,
            0x212B,
            // Step 7: toUppercase has more than one code point, so the character
            // is its own canonical form; both members of each such class.
            0x00DF,
            0x0390,
            0x03B0,
            0x1F80...0x1FAF,
            0x1FB3,
            0x1FBC,
            0x1FC3,
            0x1FCC,
            0x1FD3,
            0x1FE3,
            0x1FF3,
            0x1FFC,
            0xFB05,
            0xFB06,
            => true,
            else => false,
        };
    }

    /// Match a `\q{...}` string (a sequence of code points) at `input[start..]`,
    /// returning the end byte position or null.
    fn matchStringItem(input: []const u8, start: usize, s: []const u21, fold_mode: ClassSet.CaseFoldMode) ?usize {
        const u = @import("unicode.zig");
        var pos = start;
        for (s) |scp| {
            if (pos >= input.len) return null;
            const dec = u.decodeUtf8Lenient(input[pos..]) orelse return null;
            if (dec.codepoint != scp and !(fold_mode != .none and canonicalCaseFold(dec.codepoint, fold_mode) == canonicalCaseFold(scp, fold_mode))) return null;
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

    /// A per-group flag override from inline modifiers `(?ims-ims:...)`: each
    /// field is null (inherit), true (add) or false (remove). Only the
    /// ECMAScript match-time flags live here (i/m/s); the parse-time flags `x`
    /// (extended) and `U` (swap-greedy) are consumed by the parser and never
    /// reach the AST.
    pub const FlagDelta = struct {
        i: ?bool = null,
        m: ?bool = null,
        s: ?bool = null,

        /// True if any match-time flag is set, i.e. this delta affects matching
        /// and the group must be carried by the backtracking engine.
        pub fn any(self: FlagDelta) bool {
            return self.i != null or self.m != null or self.s != null;
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
    /// Free `self` and every node below it.
    ///
    /// Walked with a stack held in this frame: a flat pattern's spine is as long
    /// as the pattern, so tearing down `/aaaa…a/` used one native frame per
    /// character and overflowed the stack on patterns other engines handle
    /// (#23). Nothing here allocates -- a teardown runs on the rollback path of
    /// a failed allocation, where asking for memory is exactly what is not
    /// available -- so the stack is a fixed array, and childless nodes are freed
    /// where they are found rather than pushed. A sequence therefore never grows
    /// it: only a node whose *both* children have children does, which the
    /// parser's own nesting limit bounds well below this size.
    pub fn destroy(self: *Node, allocator: std.mem.Allocator) void {
        var stack: [max_teardown_branches]*Node = undefined;
        var depth: usize = 0;
        var current: ?*Node = self;
        while (current) |node| {
            const children = node.freeOwnedData(allocator);
            allocator.destroy(node);
            current = null;
            for (children) |maybe_child| {
                const child = maybe_child orelse continue;
                if (!child.hasChildren()) {
                    // A childless node needs no bookkeeping at all: free it
                    // where it is, so a sequence never touches the stack.
                    _ = child.freeOwnedData(allocator);
                    allocator.destroy(child);
                } else if (current == null) {
                    current = child;
                } else if (depth < stack.len) {
                    stack[depth] = child;
                    depth += 1;
                } else {
                    // Deeper branching than the array holds: fall back to the
                    // recursive teardown for this subtree, which is what this
                    // did before.
                    child.destroyRecursively(allocator);
                }
            }
            if (current == null and depth > 0) {
                depth -= 1;
                current = stack[depth];
            }
        }
    }

    /// Whether this node owns child nodes (as opposed to only bytes).
    fn hasChildren(self: *const Node) bool {
        return switch (self.data) {
            .concat, .alternation, .star, .plus, .optional, .repeat, .group, .lookahead, .lookbehind => true,
            else => false,
        };
    }

    fn destroyRecursively(self: *Node, allocator: std.mem.Allocator) void {
        const children = self.freeOwnedData(allocator);
        allocator.destroy(self);
        for (children) |maybe_child| if (maybe_child) |child| child.destroyRecursively(allocator);
    }

    /// Free what this node owns directly and hand back its child nodes, which
    /// the caller then owns.
    fn freeOwnedData(self: *Node, allocator: std.mem.Allocator) [2]?*Node {
        return switch (self.data) {
            .concat => |concat| .{ concat.left, concat.right },
            .alternation => |alt| .{ alt.left, alt.right },
            .star, .plus, .optional => |quant| .{ quant.child, null },
            .repeat => |repeat| .{ repeat.child, null },
            .group => |group| blk: {
                if (group.name) |name| allocator.free(name);
                break :blk .{ group.child, null };
            },
            .lookahead, .lookbehind => |assertion| .{ assertion.child, null },
            .backref => |backref| blk: {
                if (backref.name) |name| allocator.free(name);
                break :blk .{ null, null };
            },
            .char_class => |char_class| blk: {
                // Free the ranges array. This is safe because:
                // - For custom char classes ([a-z]), parser allocates ranges
                // - For predefined classes (\d, \w), they use static arrays
                // - Static arrays can't be freed, but we only reach here for parsed nodes
                // - NFA already duplicated these ranges, so we own the originals
                allocator.free(char_class.ranges);
                break :blk .{ null, null };
            },
            .class_set => |set| blk: {
                destroyClassSet(allocator, set);
                break :blk .{ null, null };
            },
            else => .{ null, null },
        };
    }

    fn destroyClassSet(allocator: std.mem.Allocator, set: *ClassSet) void {
        for (set.items) |item| switch (item) {
            .nested => |nested| destroyClassSet(allocator, nested),
            .string => |string| allocator.free(string),
            .range, .property => {},
        };
        allocator.free(set.items);
        allocator.destroy(set);
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

test "canonicalizeKey follows ECMAScript Canonicalize with and without u" {
    const key = Node.canonicalizeKey;
    // Pairs that Canonicalize joins in both modes.
    for ([_][2]u21{ .{ 0x0101, 0x0100 }, .{ 0x03C3, 0x03C2 }, .{ 0x03C3, 0x03A3 }, .{ 0x00B5, 0x039C }, .{ 0x01C6, 0x01C5 }, .{ 'a', 'A' } }) |p| {
        try std.testing.expectEqual(key(p[0], .legacy), key(p[1], .legacy));
        try std.testing.expectEqual(key(p[0], .unicode), key(p[1], .unicode));
    }
    // Pairs that only simple case folding (u, v) joins.
    for ([_][2]u21{ .{ 0x212A, 'k' }, .{ 0x017F, 's' }, .{ 0x00DF, 0x1E9E }, .{ 0x2126, 0x03C9 }, .{ 0x212B, 0x00E5 }, .{ 0x03F4, 0x03B8 } }) |p| {
        try std.testing.expectEqual(key(p[0], .unicode), key(p[1], .unicode));
        try std.testing.expect(key(p[0], .legacy) != key(p[1], .legacy));
    }
    // Without u these keep themselves although simple case folding moves them.
    for ([_]u21{ 0x017F, 0x03F4, 0x1E9E, 0x2126, 0x212A, 0x212B }) |cp| {
        try std.testing.expect(casefold_data.fold(cp) != cp);
        try std.testing.expectEqual(cp, key(cp, .legacy));
    }
    // Characters whose uppercase has more than one code point are their own
    // canonical form without u.
    for ([_]u21{ 0x00DF, 0x0390, 0x03B0, 0x1F80, 0x1F88, 0x1FAF, 0x1FB3, 0x1FBC, 0x1FF3, 0x1FFC, 0xFB05, 0xFB06 }) |cp| {
        try std.testing.expectEqual(cp, key(cp, .legacy));
    }
    try std.testing.expectEqual(@as(u21, 0x10428), key(0x10400, .unicode));
}

//! Required literal factors: strings every match of a pattern must contain.
//!
//! A prefilter (an Aho-Corasick atom table, a phrase set, `memmem`) can test
//! these before running the regex at all: when a required factor is absent
//! from the input, the pattern cannot match there.
//!
//! The analysis walks the parse tree and computes, for every node, what each
//! of its matches looks like from the outside:
//!
//!   - `exact`: the node always matches this one string (`abc`, `^`, `(?:x)`);
//!   - `prefix` / `suffix`: every match starts / ends with this string;
//!   - `inner`: every match contains each of these strings somewhere.
//!
//! Concatenation joins them (`ab` then `c` is exactly `abc`; a suffix followed
//! by a prefix is required across the join), alternation keeps what its
//! branches share (`bar|baz` starts with `ba`), and anything that may repeat
//! zero times, or match an unknown character, contributes nothing exact.
//! Every result is sound: a pattern match always contains each factor.
//!
//! Case-insensitive parts (the `case_insensitive` flag, `(?i:...)`, or a class
//! that is exactly both cases of one letter) yield factors marked
//! `case_folded`, whose bytes are lowercase and must be searched for ignoring
//! ASCII case.

const std = @import("std");
const ast = @import("ast.zig");
const common = @import("common.zig");
const regex_mod = @import("regex.zig");

/// One required string.
pub const Factor = struct {
    /// The bytes; lowercase ASCII letters when `case_folded`.
    bytes: []const u8,
    /// Match `bytes` ignoring ASCII case.
    case_folded: bool,
};

/// The factors of one pattern. `deinit` frees them.
pub const Factors = struct {
    /// Every match starts with this.
    prefix: ?Factor,
    /// Every match ends with this.
    suffix: ?Factor,
    /// Every match contains each of these. Factors already implied by the
    /// prefix, the suffix or a longer inner factor are left out.
    inner: []const Factor,

    pub fn deinit(self: *Factors, allocator: std.mem.Allocator) void {
        if (self.prefix) |f| allocator.free(f.bytes);
        if (self.suffix) |f| allocator.free(f.bytes);
        for (self.inner) |f| allocator.free(f.bytes);
        allocator.free(self.inner);
        self.* = undefined;
    }

    /// Every factor, prefix and suffix first.
    pub fn all(self: *const Factors, buffer: []Factor) []Factor {
        var n: usize = 0;
        if (self.prefix) |f| {
            buffer[n] = f;
            n += 1;
        }
        if (self.suffix) |f| {
            if (n == 0 or !std.mem.eql(u8, f.bytes, buffer[0].bytes) or f.case_folded != buffer[0].case_folded) {
                buffer[n] = f;
                n += 1;
            }
        }
        for (self.inner) |f| {
            buffer[n] = f;
            n += 1;
        }
        return buffer[0..n];
    }
};

pub const Options = struct {
    /// Shorter factors are not reported; with none left the result is null.
    min_len: usize = 3,
};

/// The longest string the analysis tracks. Longer strings keep their first
/// (prefix) or last (suffix) bytes, which keeps every factor sound.
pub const max_factor_len: usize = 256;

/// The required factors of `pattern` compiled with `flags`, or null when no
/// factor of at least `options.min_len` bytes exists.
pub fn requiredFactors(allocator: std.mem.Allocator, pattern: []const u8, flags: common.CompileFlags, options: Options) !?Factors {
    var tree = try regex_mod.parseTree(allocator, pattern, flags, null);
    defer tree.deinit();
    return fromTree(allocator, tree.root, flags, options);
}

/// The required factors of a parse tree (see `requiredFactors`).
pub fn fromTree(allocator: std.mem.Allocator, root: *ast.Node, flags: common.CompileFlags, options: Options) !?Factors {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var analyzer = Analyzer{ .arena = arena_state.allocator() };
    const info = try analyzer.analyze(root, flags.case_insensitive);
    return collect(allocator, info, options);
}

// ---------------------------------------------------------------------------

const Str = struct {
    bytes: []const u8 = "",
    folded: bool = false,
};

const Info = struct {
    exact: ?Str = null,
    prefix: Str = .{},
    suffix: Str = .{},
    inner: []const Str = &.{},

    const unknown: Info = .{};
    const empty: Info = .{ .exact = .{} };
};

const Analyzer = struct {
    arena: std.mem.Allocator,

    fn literal(self: *Analyzer, b: u8, fold: bool) !Info {
        const folded = fold and std.ascii.isAlphabetic(b);
        const bytes = try self.arena.alloc(u8, 1);
        bytes[0] = if (folded) std.ascii.toLower(b) else b;
        const s = Str{ .bytes = bytes, .folded = folded };
        return .{ .exact = s, .prefix = s, .suffix = s };
    }

    /// A byte class that is one byte, or both cases of one letter, is a
    /// literal; any other class is an unknown character.
    fn charClass(self: *Analyzer, cc: common.CharClass, fold: bool) !Info {
        var members: [2]u8 = undefined;
        var count: usize = 0;
        var b: usize = 0;
        while (b < 256) : (b += 1) {
            const c: u8 = @intCast(b);
            const hit = if (fold) cc.matchesCI(c) else cc.matches(c);
            if (!hit) continue;
            if (count == members.len) return .unknown;
            members[count] = c;
            count += 1;
        }
        if (count == 1) return self.literal(members[0], fold);
        if (count == 2 and std.ascii.isAlphabetic(members[0]) and
            std.ascii.toLower(members[0]) == std.ascii.toLower(members[1]))
            return self.literal(members[0], true);
        return .unknown;
    }

    fn analyze(self: *Analyzer, node: *ast.Node, fold: bool) anyerror!Info {
        return switch (node.node_type) {
            .literal => self.literal(node.data.literal, fold),
            .char_class => self.charClass(node.data.char_class, fold),
            .any, .class_set, .unicode_property, .backref => .unknown,
            .anchor, .empty, .lookahead, .lookbehind => .empty,
            .group => blk: {
                const g = node.data.group;
                const inner_fold = if (g.mod) |m| m.i orelse fold else fold;
                break :blk self.analyze(g.child, inner_fold);
            },
            .star, .optional => .unknown,
            .plus => self.repeat(node.data.plus.child, 1, null, fold),
            .repeat => self.repeat(node.data.repeat.child, node.data.repeat.bounds.min, node.data.repeat.bounds.max, fold),
            .concat => self.concatSpine(node, fold),
            .alternation => self.alternationSpine(node, fold),
        };
    }

    /// `child{min,max}`; `max` null is unbounded.
    fn repeat(self: *Analyzer, child: *ast.Node, min: usize, max: ?usize, fold: bool) !Info {
        if (min == 0) return .unknown;
        const one = try self.analyze(child, fold);
        if (one.exact != null) {
            // Exactly one string repeated: `min` copies are always there.
            var copies = Info.empty;
            var i: usize = 0;
            while (i < min and (copies.exact != null and copies.exact.?.bytes.len < max_factor_len)) : (i += 1)
                copies = try self.concat(copies, one);
            if (max != null and max.? == min and i == min) return copies;
            // More copies may follow: keep the guaranteed start and end.
            return .{ .prefix = copies.prefix, .suffix = if (copies.exact) |x| x else copies.suffix, .inner = copies.inner };
        }
        var result = one;
        result.exact = null;
        // Two or more copies join one copy's suffix to the next one's prefix.
        if (min >= 2) {
            const seam = try self.join(one.suffix, one.prefix);
            result.inner = try self.appendStr(one.inner, seam);
        }
        return result;
    }

    fn concatSpine(self: *Analyzer, node: *ast.Node, fold: bool) !Info {
        // Walk the spine with an explicit stack: long literal runs are long
        // left-leaning chains, and recursion per element would overflow.
        var pending: std.ArrayList(*ast.Node) = .empty;
        try pending.append(self.arena, node);
        var acc = Info.empty;
        while (pending.pop()) |current| {
            if (current.node_type == .concat) {
                try pending.append(self.arena, current.data.concat.right);
                try pending.append(self.arena, current.data.concat.left);
                continue;
            }
            acc = try self.concat(acc, try self.analyze(current, fold));
        }
        return acc;
    }

    fn alternationSpine(self: *Analyzer, node: *ast.Node, fold: bool) !Info {
        var pending: std.ArrayList(*ast.Node) = .empty;
        try pending.append(self.arena, node);
        var acc: ?Info = null;
        while (pending.pop()) |current| {
            if (current.node_type == .alternation) {
                try pending.append(self.arena, current.data.alternation.right);
                try pending.append(self.arena, current.data.alternation.left);
                continue;
            }
            const branch = try self.analyze(current, fold);
            acc = if (acc) |a| try self.alternate(a, branch) else branch;
        }
        return acc.?;
    }

    fn concat(self: *Analyzer, a: Info, b: Info) !Info {
        var result: Info = .{};
        if (a.exact != null and b.exact != null) {
            const joined = try self.join(a.exact.?, b.exact.?);
            if (a.exact.?.bytes.len + b.exact.?.bytes.len <= max_factor_len) {
                return .{ .exact = joined, .prefix = joined, .suffix = try self.joinTail(a.exact.?, b.exact.?), .inner = try self.mergeInner(a.inner, b.inner) };
            }
            // Too long to track exactly: keep both ends.
            result.prefix = joined;
            result.suffix = try self.joinTail(a.exact.?, b.exact.?);
            result.inner = try self.mergeInner(a.inner, b.inner);
            return result;
        }
        result.prefix = if (a.exact) |e| try self.join(e, b.prefix) else a.prefix;
        result.suffix = if (b.exact) |e| try self.joinTail(a.suffix, e) else b.suffix;
        result.inner = try self.mergeInner(a.inner, b.inner);
        if (a.exact == null and b.exact == null)
            result.inner = try self.appendStr(result.inner, try self.join(a.suffix, b.prefix));
        return result;
    }

    fn alternate(self: *Analyzer, a: Info, b: Info) !Info {
        var result: Info = .{};
        if (a.exact != null and b.exact != null and strEql(a.exact.?, b.exact.?)) result.exact = a.exact;
        result.prefix = try self.commonPrefix(a.prefix, b.prefix);
        result.suffix = try self.commonSuffix(a.suffix, b.suffix);
        if (result.exact) |e| {
            result.prefix = e;
            result.suffix = e;
            result.inner = try self.mergeInner(a.inner, b.inner);
        }
        return result;
    }

    // -- strings ----------------------------------------------------------

    fn normalized(self: *Analyzer, s: Str, folded: bool) ![]const u8 {
        if (!folded or s.folded) return s.bytes;
        const out = try self.arena.alloc(u8, s.bytes.len);
        for (out, s.bytes) |*o, c| o.* = std.ascii.toLower(c);
        return out;
    }

    /// `a` then `b`, keeping the first `max_factor_len` bytes.
    fn join(self: *Analyzer, a: Str, b: Str) !Str {
        const folded = a.folded or b.folded;
        const x = try self.normalized(a, folded);
        const y = try self.normalized(b, folded);
        const len = @min(x.len + y.len, max_factor_len);
        const out = try self.arena.alloc(u8, len);
        const from_x = @min(x.len, len);
        @memcpy(out[0..from_x], x[0..from_x]);
        @memcpy(out[from_x..], y[0 .. len - from_x]);
        return .{ .bytes = out, .folded = folded };
    }

    /// `a` then `b`, keeping the last `max_factor_len` bytes.
    fn joinTail(self: *Analyzer, a: Str, b: Str) !Str {
        const folded = a.folded or b.folded;
        const x = try self.normalized(a, folded);
        const y = try self.normalized(b, folded);
        const len = @min(x.len + y.len, max_factor_len);
        const out = try self.arena.alloc(u8, len);
        const from_y = @min(y.len, len);
        @memcpy(out[len - from_y ..], y[y.len - from_y ..]);
        @memcpy(out[0 .. len - from_y], x[x.len - (len - from_y) ..]);
        return .{ .bytes = out, .folded = folded };
    }

    fn commonPrefix(self: *Analyzer, a: Str, b: Str) !Str {
        const folded = a.folded or b.folded;
        const x = try self.normalized(a, folded);
        const y = try self.normalized(b, folded);
        var n: usize = 0;
        while (n < x.len and n < y.len and x[n] == y[n]) n += 1;
        return .{ .bytes = x[0..n], .folded = folded and n > 0 };
    }

    fn commonSuffix(self: *Analyzer, a: Str, b: Str) !Str {
        const folded = a.folded or b.folded;
        const x = try self.normalized(a, folded);
        const y = try self.normalized(b, folded);
        var n: usize = 0;
        while (n < x.len and n < y.len and x[x.len - 1 - n] == y[y.len - 1 - n]) n += 1;
        return .{ .bytes = x[x.len - n ..], .folded = folded and n > 0 };
    }

    fn mergeInner(self: *Analyzer, a: []const Str, b: []const Str) ![]const Str {
        if (a.len == 0) return b;
        if (b.len == 0) return a;
        const out = try self.arena.alloc(Str, a.len + b.len);
        @memcpy(out[0..a.len], a);
        @memcpy(out[a.len..], b);
        return out;
    }

    fn appendStr(self: *Analyzer, list: []const Str, s: Str) ![]const Str {
        if (s.bytes.len == 0) return list;
        const out = try self.arena.alloc(Str, list.len + 1);
        @memcpy(out[0..list.len], list);
        out[list.len] = s;
        return out;
    }
};

fn strEql(a: Str, b: Str) bool {
    return a.folded == b.folded and std.mem.eql(u8, a.bytes, b.bytes);
}

/// Whether every input containing `outer` also contains `inner`.
fn implies(outer: Str, inner: Str) bool {
    // A case-folded factor is a weaker demand than an exact one.
    if (outer.folded and !inner.folded) return false;
    if (!inner.folded) return std.mem.indexOf(u8, outer.bytes, inner.bytes) != null;
    // `inner` is folded (lowercase): look for it ignoring case.
    if (inner.bytes.len > outer.bytes.len) return false;
    var i: usize = 0;
    while (i + inner.bytes.len <= outer.bytes.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(outer.bytes[i..][0..inner.bytes.len], inner.bytes)) return true;
    }
    return false;
}

fn collect(allocator: std.mem.Allocator, info: Info, options: Options) !?Factors {
    const min = @max(options.min_len, 1);
    const prefix: ?Str = if (info.prefix.bytes.len >= min) info.prefix else null;
    const suffix: ?Str = if (info.suffix.bytes.len >= min) info.suffix else null;

    var kept: std.ArrayList(Str) = .empty;
    defer kept.deinit(allocator);
    // Longest first, so a factor implied by a longer one is dropped.
    const candidates = try allocator.dupe(Str, info.inner);
    defer allocator.free(candidates);
    std.mem.sort(Str, candidates, {}, struct {
        fn longer(_: void, a: Str, b: Str) bool {
            return a.bytes.len > b.bytes.len;
        }
    }.longer);
    outer: for (candidates) |candidate| {
        if (candidate.bytes.len < min) continue;
        if (prefix) |p| if (implies(p, candidate)) continue;
        if (suffix) |s| if (implies(s, candidate)) continue;
        for (kept.items) |k| if (implies(k, candidate)) continue :outer;
        try kept.append(allocator, candidate);
    }
    if (prefix == null and suffix == null and kept.items.len == 0) return null;

    var result = Factors{ .prefix = null, .suffix = null, .inner = &.{} };
    errdefer result.deinit(allocator);
    const inner = try allocator.alloc(Factor, kept.items.len);
    var filled: usize = 0;
    errdefer {
        for (inner[0..filled]) |f| allocator.free(f.bytes);
        allocator.free(inner);
    }
    for (kept.items, 0..) |s, i| {
        inner[i] = .{ .bytes = try allocator.dupe(u8, s.bytes), .case_folded = s.folded };
        filled += 1;
    }
    if (prefix) |p| result.prefix = .{ .bytes = try allocator.dupe(u8, p.bytes), .case_folded = p.folded };
    if (suffix) |s| result.suffix = .{ .bytes = try allocator.dupe(u8, s.bytes), .case_folded = s.folded };
    result.inner = inner;
    return result;
}

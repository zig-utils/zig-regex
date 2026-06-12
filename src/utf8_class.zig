//! Lower a code-point `class_set` (how `\s`, `\S`, and `/v` Unicode bracket
//! expressions are modelled) into a UTF-8 *byte* automaton so it can run on the
//! byte-oriented Thompson NFA / lazy DFA instead of the backtracking engine.
//!
//! A class such as `\s` matches a handful of code points, most of them ASCII
//! (`\t`..`\r`, space) plus a few multi-byte ones (NBSP, the Unicode spaces,
//! etc.). Encoding each code-point range as a sequence of byte ranges — the
//! classic "utf8-ranges" decomposition (Russ Cox) — lets a pattern like
//! `\w+\s+\w+` stay on the fast path end-to-end instead of collapsing onto the
//! O(n·…) backtracker the moment a `\s` appears.
//!
//! Only the representable shapes are lowered: a union (possibly complemented)
//! of code-point ranges, single-code-point string items, and nested unions of
//! the same. Unicode-property operands, multi-code-point `\q{...}` strings, and
//! intersection/difference sets return null so the caller keeps using the
//! backtracking engine (exact same behaviour as before).

const std = @import("std");
const ast = @import("ast.zig");
const unicode = @import("unicode.zig");

const CpRange = ast.Node.CpRange;
const ClassSet = ast.Node.ClassSet;

/// A single byte-range within a UTF-8 sequence: a byte matches if `lo <= b <= hi`.
pub const ByteRange = struct { lo: u8, hi: u8 };

/// One UTF-8 byte-range sequence (1–4 bytes). A code point matches the sequence
/// when each of its `len` bytes falls inside the corresponding range.
pub const Utf8Seq = struct {
    len: u3,
    ranges: [4]ByteRange,
};

/// Largest scalar value with `i+1`-byte UTF-8 encoding.
const MAX_FOR_LEN = [4]u21{ 0x7F, 0x7FF, 0xFFFF, 0x10FFFF };

const SURROGATE_LO: u21 = 0xD800;
const SURROGATE_HI: u21 = 0xDFFF;
const MAX_CP: u21 = 0x10FFFF;

/// Whether `set` is a shape we can lower to a byte automaton. Must agree with
/// `toCodepointRanges` returning non-null so the engine-selection check and the
/// compiler stay in lockstep.
pub fn compilable(set: *const ClassSet) bool {
    if (set.op != .union_) return false;
    for (set.items) |it| {
        switch (it) {
            .range => {},
            .string => |s| if (s.len != 1) return false,
            .property => return false,
            .nested => |n| {
                // Nested complements would need set-difference; keep those on
                // the backtracker. Plain nested unions are fine.
                if (n.negated or !compilable(n)) return false;
            },
        }
    }
    return true;
}

/// Collect every code-point range a `union_` set (and its nested unions)
/// contributes, appending to `out`. Caller guarantees `compilable(set)`.
fn collectUnion(set: *const ClassSet, out: *std.ArrayList(CpRange), allocator: std.mem.Allocator) !void {
    for (set.items) |it| {
        switch (it) {
            .range => |r| try out.append(allocator, r),
            .string => |s| try out.append(allocator, .{ .lo = @intCast(s[0]), .hi = @intCast(s[0]) }),
            .nested => |n| try collectUnion(n, out, allocator),
            .property => unreachable, // excluded by compilable()
        }
    }
}

fn lessThanRange(_: void, a: CpRange, b: CpRange) bool {
    return a.lo < b.lo;
}

/// Sort + merge overlapping/adjacent ranges and drop the surrogate gap
/// (UTF-8 never encodes lone surrogates). Returns a clean, ascending list.
fn normalize(allocator: std.mem.Allocator, ranges: []CpRange) ![]CpRange {
    var out: std.ArrayList(CpRange) = .empty;
    errdefer out.deinit(allocator);
    if (ranges.len == 0) return out.toOwnedSlice(allocator);

    std.mem.sort(CpRange, ranges, {}, lessThanRange);
    var cur = ranges[0];
    for (ranges[1..]) |r| {
        // Merge when overlapping or touching (r.lo <= cur.hi + 1).
        if (r.lo <= cur.hi + 1) {
            if (r.hi > cur.hi) cur.hi = r.hi;
        } else {
            try appendNonSurrogate(allocator, &out, cur);
            cur = r;
        }
    }
    try appendNonSurrogate(allocator, &out, cur);
    return out.toOwnedSlice(allocator);
}

/// Append `r` clamped to valid scalar space, splitting out the surrogate hole.
fn appendNonSurrogate(allocator: std.mem.Allocator, out: *std.ArrayList(CpRange), r: CpRange) !void {
    var lo = r.lo;
    var hi = r.hi;
    if (hi > MAX_CP) hi = MAX_CP;
    if (lo > hi) return;
    if (lo <= SURROGATE_HI and hi >= SURROGATE_LO) {
        if (lo < SURROGATE_LO) try out.append(allocator, .{ .lo = lo, .hi = SURROGATE_LO - 1 });
        if (hi > SURROGATE_HI) {
            lo = SURROGATE_HI + 1;
        } else return;
    }
    if (lo <= hi) try out.append(allocator, .{ .lo = lo, .hi = hi });
}

/// Complement an ascending, normalized range list over the scalar space
/// (surrogates already excluded from the result).
fn complement(allocator: std.mem.Allocator, ranges: []const CpRange) ![]CpRange {
    var out: std.ArrayList(CpRange) = .empty;
    errdefer out.deinit(allocator);
    var next: u21 = 0;
    for (ranges) |r| {
        if (r.lo > next) try appendNonSurrogate(allocator, &out, .{ .lo = next, .hi = r.lo - 1 });
        if (r.hi >= next) next = r.hi + 1;
    }
    if (next <= MAX_CP) try appendNonSurrogate(allocator, &out, .{ .lo = next, .hi = MAX_CP });
    return out.toOwnedSlice(allocator);
}

/// The set's matching code points as a clean ascending range list, or null if
/// the set isn't a lowerable shape. Caller owns the returned slice.
pub fn toCodepointRanges(allocator: std.mem.Allocator, set: *const ClassSet) !?[]CpRange {
    if (!compilable(set)) return null;

    var raw: std.ArrayList(CpRange) = .empty;
    defer raw.deinit(allocator);
    try collectUnion(set, &raw, allocator);

    const positive = try normalize(allocator, raw.items);
    if (!set.negated) return positive;
    defer allocator.free(positive);
    return try complement(allocator, positive);
}

inline fn utf8Len(cp: u21) u3 {
    return if (cp <= 0x7F) 1 else if (cp <= 0x7FF) 2 else if (cp <= 0xFFFF) 3 else 4;
}

/// Encode the same-length range [lo, hi] into byte-range sequences, recursing
/// at code-unit boundaries so every emitted sequence is a valid, non-overlong
/// rectangle of byte ranges.
fn encodeRange(allocator: std.mem.Allocator, out: *std.ArrayList(Utf8Seq), lo: u21, hi: u21) !void {
    if (lo > hi) return;

    // Split across UTF-8 length boundaries first.
    for (MAX_FOR_LEN) |max| {
        if (lo <= max and max < hi) {
            try encodeRange(allocator, out, lo, max);
            try encodeRange(allocator, out, max + 1, hi);
            return;
        }
    }

    // Same length: split so each continuation byte spans a full 0x80..0xBF run.
    var i: u5 = 1;
    while (i < 4) : (i += 1) {
        const m: u21 = (@as(u21, 1) << (6 * @as(u5, @intCast(i)))) - 1;
        if ((lo & ~m) != (hi & ~m)) {
            if ((lo & m) != 0) {
                try encodeRange(allocator, out, lo, lo | m);
                try encodeRange(allocator, out, (lo | m) + 1, hi);
                return;
            }
            if ((hi & m) != m) {
                try encodeRange(allocator, out, lo, (hi & ~m) - 1);
                try encodeRange(allocator, out, hi & ~m, hi);
                return;
            }
        }
    }

    // Emit [lo, hi] as one byte-range sequence.
    var lb: [4]u8 = undefined;
    var hb: [4]u8 = undefined;
    const n = unicode.encodeUtf8(lo, &lb) catch return;
    _ = unicode.encodeUtf8(hi, &hb) catch return;
    var seq: Utf8Seq = .{ .len = n, .ranges = undefined };
    var k: usize = 0;
    while (k < n) : (k += 1) seq.ranges[k] = .{ .lo = lb[k], .hi = hb[k] };
    try out.append(allocator, seq);
}

/// Decompose an ascending code-point range list into UTF-8 byte-range
/// sequences. Caller owns the returned slice.
pub fn toUtf8Sequences(allocator: std.mem.Allocator, ranges: []const CpRange) ![]Utf8Seq {
    var out: std.ArrayList(Utf8Seq) = .empty;
    errdefer out.deinit(allocator);
    for (ranges) |r| try encodeRange(allocator, &out, r.lo, r.hi);
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Reference: does any emitted sequence accept the UTF-8 encoding of `cp`?
fn seqsMatch(seqs: []const Utf8Seq, cp: u21) bool {
    var buf: [4]u8 = undefined;
    const n = unicode.encodeUtf8(cp, &buf) catch return false;
    for (seqs) |s| {
        if (s.len != n) continue;
        var ok = true;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            if (buf[k] < s.ranges[k].lo or buf[k] > s.ranges[k].hi) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

test "utf8 sequences cover ascii and multibyte ranges exactly" {
    const a = testing.allocator;
    const ranges = [_]CpRange{
        .{ .lo = 0x09, .hi = 0x0D },
        .{ .lo = 0x20, .hi = 0x20 },
        .{ .lo = 0xA0, .hi = 0xA0 },
        .{ .lo = 0x2000, .hi = 0x200A },
        .{ .lo = 0x3000, .hi = 0x3000 },
    };
    const seqs = try toUtf8Sequences(a, &ranges);
    defer a.free(seqs);

    // Spot-check membership across the whole BMP plus a couple astral points.
    var cp: u21 = 0;
    while (cp <= 0x3010) : (cp += 1) {
        if (cp >= SURROGATE_LO and cp <= SURROGATE_HI) continue;
        var want = false;
        for (ranges) |r| {
            if (cp >= r.lo and cp <= r.hi) want = true;
        }
        try testing.expectEqual(want, seqsMatch(seqs, cp));
    }
}

test "complement excludes surrogates and the positive set" {
    const a = testing.allocator;
    var raw = [_]CpRange{.{ .lo = 0x20, .hi = 0x20 }};
    const pos = try normalize(a, &raw);
    defer a.free(pos);
    const comp = try complement(a, pos);
    defer a.free(comp);

    const seqs = try toUtf8Sequences(a, comp);
    defer a.free(seqs);

    try testing.expect(!seqsMatch(seqs, 0x20)); // space excluded
    try testing.expect(seqsMatch(seqs, 'a')); // letters included
    try testing.expect(seqsMatch(seqs, 0x00E9)); // é included
    var sc: u21 = SURROGATE_LO;
    while (sc <= SURROGATE_HI) : (sc += 1) try testing.expect(!seqsMatch(seqs, sc));
}

test "ranges merge and normalize" {
    const a = testing.allocator;
    var raw = [_]CpRange{
        .{ .lo = 0x30, .hi = 0x39 },
        .{ .lo = 0x3A, .hi = 0x40 }, // adjacent -> merges
        .{ .lo = 0x10, .hi = 0x12 },
    };
    const norm = try normalize(a, &raw);
    defer a.free(norm);
    try testing.expectEqual(@as(usize, 2), norm.len);
    try testing.expectEqual(@as(u21, 0x10), norm[0].lo);
    try testing.expectEqual(@as(u21, 0x12), norm[0].hi);
    try testing.expectEqual(@as(u21, 0x30), norm[1].lo);
    try testing.expectEqual(@as(u21, 0x40), norm[1].hi);
}

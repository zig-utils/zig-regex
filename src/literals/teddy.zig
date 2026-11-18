//! Teddy: SIMD multi-literal search for small pattern sets (up to 64).
//!
//! Patterns are spread over 8 buckets. For each of the first `fp_len` bytes
//! of a pattern (`fp_len` is the shortest pattern length, capped at 3) two
//! 16-entry tables map the low and high nibble of a haystack byte to the set
//! of buckets holding a pattern with that nibble at that offset. Scanning
//! looks up 32 haystack positions at once with runtime byte shuffles and ANDs
//! the tables of every fingerprint offset; a nonzero lane is a candidate start
//! whose bucket bits name the patterns to verify with a full compare.
//!
//! The algorithm is Geoff Langdale's, from Hyperscan, as also described for
//! the Rust aho-corasick crate.

const std = @import("std");
const simd = @import("simd.zig");
const blob = @import("blob.zig");
const types = @import("types.zig");

const Pattern = types.Pattern;
const Match = types.Match;
const Options = types.Options;
const V16 = simd.V16;

pub const max_patterns = 64;
pub const num_buckets = 8;
pub const max_fingerprint = 3;

/// Haystack bytes examined per SIMD step.
const scan_width = 32;

pub const magic = "ZTDY".*;
pub const format_version: u16 = 1;

pub const BuildError = std.mem.Allocator.Error || error{
    /// No patterns, or more than `max_patterns`.
    BadPatternCount,
    /// An empty pattern matches everywhere; filter it out before building.
    EmptyPattern,
    /// A pattern longer than 4 GiB.
    PatternTooLong,
};

pub const LoadError = blob.LoadError;

const flag_nocase: u32 = 1;

const Header = extern struct {
    prefix: blob.Prefix,
    flags: u32,
    num_patterns: u32,
    fp_len: u32,
    min_len: u32,
    max_len: u32,
    bytes_len: u32,
    /// `PatternRec[num_patterns]`, grouped by bucket, by input order within a bucket.
    patterns_off: u64,
    /// Pattern bytes, ASCII-lowercased when `flag_nocase` is set.
    bytes_off: u64,
    /// Bucket b holds `patterns[bucket_start[b]..bucket_start[b + 1]]`.
    bucket_start: [num_buckets + 1]u8,
    _pad: [7]u8,
    /// Low and high nibble tables for fingerprint offsets 0, 1 and 2.
    lo: [max_fingerprint][16]u8,
    hi: [max_fingerprint][16]u8,
};

const PatternRec = extern struct {
    id: u32,
    /// Position in the pattern list given to `build`; breaks ties in `find`.
    index: u32,
    off: u32,
    len: u32,
};

comptime {
    std.debug.assert(@sizeOf(Header) == 168);
    std.debug.assert(@sizeOf(PatternRec) == 16);
}

/// A Teddy searcher viewing a blob. Copying it is cheap; searching never
/// allocates and never writes to the blob.
pub const Teddy = struct {
    nocase: bool,
    fp_len: u32,
    min_len: u32,
    max_len: u32,
    bucket_start: [num_buckets + 1]u8,
    lo: [max_fingerprint]V16,
    hi: [max_fingerprint]V16,
    patterns: []const PatternRec,
    bytes: []const u8,

    pub const Owned = blob.Owned(Teddy);

    /// Build a searcher for 1 to 64 non-empty patterns.
    pub fn build(gpa: std.mem.Allocator, patterns: []const Pattern, options: Options) BuildError!Owned {
        if (patterns.len == 0 or patterns.len > max_patterns) return error.BadPatternCount;
        var min_len: usize = std.math.maxInt(usize);
        var max_len: usize = 0;
        var total: u64 = 0;
        for (patterns) |p| {
            if (p.bytes.len == 0) return error.EmptyPattern;
            if (p.bytes.len > std.math.maxInt(u32)) return error.PatternTooLong;
            min_len = @min(min_len, p.bytes.len);
            max_len = @max(max_len, p.bytes.len);
            total += p.bytes.len;
        }
        if (total > std.math.maxInt(u32)) return error.PatternTooLong;
        const fp_len: usize = @min(max_fingerprint, min_len);
        const nocase = options.ascii_case_insensitive;

        // Sort by folded fingerprint so patterns sharing leading bytes share a
        // bucket and keep its nibble sets small.
        var order: [max_patterns]u8 = undefined;
        for (0..patterns.len) |i| order[i] = @intCast(i);
        const SortCtx = struct {
            patterns: []const Pattern,
            fp_len: usize,
            nocase: bool,
            fn lessThan(ctx: @This(), a: u8, b: u8) bool {
                const x = ctx.patterns[a].bytes;
                const y = ctx.patterns[b].bytes;
                for (0..ctx.fp_len) |k| {
                    const cx = if (ctx.nocase) types.fold(x[k]) else x[k];
                    const cy = if (ctx.nocase) types.fold(y[k]) else y[k];
                    if (cx != cy) return cx < cy;
                }
                return a < b;
            }
        };
        const ctx: SortCtx = .{ .patterns = patterns, .fp_len = fp_len, .nocase = nocase };
        std.mem.sort(u8, order[0..patterns.len], ctx, SortCtx.lessThan);

        // Contiguous runs of the sorted order become buckets; within a
        // bucket, patterns go back to input order.
        var bucket_start: [num_buckets + 1]u8 = undefined;
        const n = patterns.len;
        for (0..num_buckets + 1) |b| bucket_start[b] = @intCast(b * n / num_buckets);
        for (0..num_buckets) |b| {
            std.mem.sort(u8, order[bucket_start[b]..bucket_start[b + 1]], {}, std.sort.asc(u8));
        }

        var layout = blob.Layout.init(Header);
        const patterns_off = layout.reserve(PatternRec, n);
        const bytes_off = layout.reserve(u8, @intCast(total));
        const bytes = try blob.allocBlob(gpa, layout.total());
        errdefer gpa.free(bytes);

        const h: *Header = @ptrCast(bytes.ptr);
        h.* = .{
            .prefix = .{
                .magic = magic,
                .version = format_version,
                .header_size = @sizeOf(Header),
                .total_len = bytes.len,
            },
            .flags = if (nocase) flag_nocase else 0,
            .num_patterns = @intCast(n),
            .fp_len = @intCast(fp_len),
            .min_len = @intCast(min_len),
            .max_len = @intCast(max_len),
            .bytes_len = @intCast(total),
            .patterns_off = patterns_off,
            .bytes_off = bytes_off,
            .bucket_start = bucket_start,
            ._pad = @splat(0),
            .lo = @splat(@splat(0)),
            .hi = @splat(@splat(0)),
        };

        const recs = blob.sectionMut(PatternRec, bytes, patterns_off, n);
        const lit = blob.sectionMut(u8, bytes, bytes_off, @intCast(total));
        var cursor: u32 = 0;
        for (0..num_buckets) |b| {
            const bit: u8 = @as(u8, 1) << @intCast(b);
            for (bucket_start[b]..bucket_start[b + 1]) |slot| {
                const i = order[slot];
                const p = patterns[i];
                recs[slot] = .{ .id = p.id, .index = i, .off = cursor, .len = @intCast(p.bytes.len) };
                const dst = lit[cursor..][0..p.bytes.len];
                for (dst, p.bytes) |*d, c| d.* = if (nocase) types.fold(c) else c;
                cursor += @intCast(p.bytes.len);
                for (0..fp_len) |k| {
                    const c = dst[k];
                    h.lo[k][c & 15] |= bit;
                    h.hi[k][c >> 4] |= bit;
                    if (nocase and c >= 'a' and c <= 'z') h.hi[k][(c ^ 0x20) >> 4] |= bit;
                }
            }
        }

        const view = load(bytes) catch unreachable;
        return .{ .bytes = bytes, .view = view };
    }

    /// View a serialised searcher in place. `bytes` must start on an 8-byte
    /// boundary and stay alive and unchanged while the searcher is used.
    pub fn load(bytes: []const u8) LoadError!Teddy {
        const h, const b = try blob.readHeader(Header, bytes, magic, format_version);
        const n = h.num_patterns;
        if (n == 0 or n > max_patterns) return error.Corrupt;
        if (h.fp_len == 0 or h.fp_len > max_fingerprint or h.fp_len > h.min_len) return error.Corrupt;
        if (h.min_len > h.max_len) return error.Corrupt;
        if (h.flags & ~flag_nocase != 0) return error.Corrupt;
        if (h.bucket_start[0] != 0 or h.bucket_start[num_buckets] != n) return error.Corrupt;
        for (0..num_buckets) |k| {
            if (h.bucket_start[k] > h.bucket_start[k + 1]) return error.Corrupt;
        }
        const recs = try blob.section(PatternRec, b, h.patterns_off, n);
        const lit = try blob.section(u8, b, h.bytes_off, h.bytes_len);
        for (recs) |r| {
            if (r.len < h.min_len or r.len > h.max_len) return error.Corrupt;
            if (@as(u64, r.off) + r.len > lit.len) return error.Corrupt;
        }
        var self: Teddy = .{
            .nocase = h.flags & flag_nocase != 0,
            .fp_len = h.fp_len,
            .min_len = h.min_len,
            .max_len = h.max_len,
            .bucket_start = h.bucket_start,
            .lo = undefined,
            .hi = undefined,
            .patterns = recs,
            .bytes = lit,
        };
        for (0..max_fingerprint) |k| {
            self.lo[k] = h.lo[k];
            self.hi[k] = h.hi[k];
        }
        return self;
    }

    pub fn patternCount(self: *const Teddy) usize {
        return self.patterns.len;
    }

    /// The leftmost match starting at or after `from`. Among patterns that
    /// match at that position, the one listed first at build time wins.
    pub fn find(self: *const Teddy, haystack: []const u8, from: usize) ?Match {
        const Find = struct {
            t: *const Teddy,
            hay: []const u8,
            best: ?Match = null,
            fn onCandidate(c: *@This(), pos: usize, buckets: u8) bool {
                var best_index: u32 = std.math.maxInt(u32);
                var it = buckets;
                while (it != 0) : (it &= it - 1) {
                    const b = @ctz(it);
                    for (c.t.patterns[c.t.bucket_start[b]..c.t.bucket_start[b + 1]]) |r| {
                        if (r.index < best_index and c.t.verify(c.hay, pos, r)) {
                            best_index = r.index;
                            c.best = .{ .pattern = r.id, .start = pos, .end = pos + r.len };
                        }
                    }
                }
                return c.best == null;
            }
        };
        var c: Find = .{ .t = self, .hay = haystack };
        self.candidates(haystack, from, &c, Find.onCandidate);
        return c.best;
    }

    pub fn isMatch(self: *const Teddy, haystack: []const u8) bool {
        return self.find(haystack, 0) != null;
    }

    /// Report every occurrence of every pattern, overlapping ones included,
    /// in ascending start order (order among matches sharing a start is
    /// unspecified). `onMatch` returns false to stop; `scan` then returns
    /// false.
    pub fn scan(
        self: *const Teddy,
        haystack: []const u8,
        context: anytype,
        comptime onMatch: fn (@TypeOf(context), Match) bool,
    ) bool {
        const Scan = struct {
            t: *const Teddy,
            hay: []const u8,
            inner: @TypeOf(context),
            stopped: bool = false,
            fn onCandidate(c: *@This(), pos: usize, buckets: u8) bool {
                var it = buckets;
                while (it != 0) : (it &= it - 1) {
                    const b = @ctz(it);
                    for (c.t.patterns[c.t.bucket_start[b]..c.t.bucket_start[b + 1]]) |r| {
                        if (c.t.verify(c.hay, pos, r) and
                            !onMatch(c.inner, .{ .pattern = r.id, .start = pos, .end = pos + r.len }))
                        {
                            c.stopped = true;
                            return false;
                        }
                    }
                }
                return true;
            }
        };
        var c: Scan = .{ .t = self, .hay = haystack, .inner = context };
        self.candidates(haystack, 0, &c, Scan.onCandidate);
        return !c.stopped;
    }

    inline fn verify(self: *const Teddy, hay: []const u8, pos: usize, r: PatternRec) bool {
        if (r.len > hay.len - pos) return false;
        return types.eqlFolded(hay[pos..][0..r.len], self.bytes[r.off..][0..r.len], self.nocase);
    }

    /// Call `onCandidate(ctx, pos, buckets)` for each position at or after
    /// `from`, in ascending order, whose fingerprint matches some bucket.
    /// Stops when `onCandidate` returns false.
    fn candidates(
        self: *const Teddy,
        hay: []const u8,
        from: usize,
        ctx: anytype,
        comptime onCandidate: fn (@TypeOf(ctx), usize, u8) bool,
    ) void {
        switch (self.fp_len) {
            inline 1...max_fingerprint => |m| self.candidatesFp(m, hay, from, ctx, onCandidate),
            else => unreachable,
        }
    }

    fn candidatesFp(
        self: *const Teddy,
        comptime m: usize,
        hay: []const u8,
        from: usize,
        ctx: anytype,
        comptime onCandidate: fn (@TypeOf(ctx), usize, u8) bool,
    ) void {
        const W = scan_width;
        const V = @Vector(W, u8);
        var p = from;
        if (simd.has_shuffle and hay.len >= W + m - 1) {
            const last = hay.len - (W + m - 1);
            const low: V = @splat(0x0f);
            const four: V = @splat(4);
            var lo: [m]V16 = undefined;
            var hi: [m]V16 = undefined;
            inline for (0..m) |k| {
                lo[k] = self.lo[k];
                hi[k] = self.hi[k];
            }
            while (p <= last) : (p += W) {
                var acc: V = @splat(0xff);
                inline for (0..m) |k| {
                    const c: V = hay[p + k ..][0..W].*;
                    acc &= simd.lookup(W, lo[k], c & low) & simd.lookup(W, hi[k], c >> four);
                }
                if (@reduce(.Max, acc) != 0) {
                    const lanes: [W]u8 = acc;
                    var bits = simd.nonzeroMask(W, acc);
                    while (bits != 0) : (bits &= bits - 1) {
                        const j = @ctz(bits);
                        if (!onCandidate(ctx, p + j, lanes[j])) return;
                    }
                }
            }
        }
        var lo_s: [m][16]u8 = undefined;
        var hi_s: [m][16]u8 = undefined;
        inline for (0..m) |k| {
            lo_s[k] = self.lo[k];
            hi_s[k] = self.hi[k];
        }
        while (p + m <= hay.len) : (p += 1) {
            var buckets: u8 = 0xff;
            inline for (0..m) |k| {
                const c = hay[p + k];
                buckets &= lo_s[k][c & 15] & hi_s[k][c >> 4];
            }
            if (buckets != 0 and !onCandidate(ctx, p, buckets)) return;
        }
    }
};

const testing = std.testing;
const naive = @import("naive.zig");

fn collect(list: *std.ArrayList(Match), m: Match) bool {
    list.append(testing.allocator, m) catch return false;
    return true;
}

test "teddy finds patterns and reports ids" {
    const pats = [_]Pattern{
        .{ .bytes = "foo", .id = 10 },
        .{ .bytes = "bar", .id = 20 },
        .{ .bytes = "\x00\xff\x00", .id = 30 },
    };
    var t = try Teddy.build(testing.allocator, &pats, .{});
    defer t.deinit(testing.allocator);
    const hay = "xxbarxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxfoo\x00\xff\x00";
    const m = t.view.find(hay, 0).?;
    try testing.expectEqual(@as(u32, 20), m.pattern);
    try testing.expectEqual(@as(usize, 2), m.start);
    try testing.expectEqual(@as(usize, 5), m.end);
    const m2 = t.view.find(hay, 3).?;
    try testing.expectEqual(@as(u32, 10), m2.pattern);
    const m3 = t.view.find(hay, m2.end).?;
    try testing.expectEqual(@as(u32, 30), m3.pattern);
    try testing.expect(t.view.find(hay, m3.end) == null);
}

test "teddy case insensitive" {
    const pats = [_]Pattern{.{ .bytes = "SeLeCt", .id = 1 }};
    var t = try Teddy.build(testing.allocator, &pats, .{ .ascii_case_insensitive = true });
    defer t.deinit(testing.allocator);
    try testing.expect(t.view.isMatch("union all select * from"));
    try testing.expect(!t.view.isMatch("union all se1ect * from"));
}

test "teddy rejects bad pattern sets" {
    try testing.expectError(error.BadPatternCount, Teddy.build(testing.allocator, &.{}, .{}));
    try testing.expectError(error.EmptyPattern, Teddy.build(testing.allocator, &.{.{ .bytes = "", .id = 0 }}, .{}));
}

test "teddy blob round trips through a copy" {
    const pats = [_]Pattern{ .{ .bytes = "alpha", .id = 1 }, .{ .bytes = "beta", .id = 2 } };
    var t = try Teddy.build(testing.allocator, &pats, .{});
    defer t.deinit(testing.allocator);
    const copy = try blob.dupeAligned(testing.allocator, t.bytes);
    defer testing.allocator.free(copy);
    const v = try Teddy.load(copy);
    try testing.expectEqual(t.view.find("xxbetaalpha", 0), v.find("xxbetaalpha", 0));
    copy[0] = 'X';
    try testing.expectError(error.BadMagic, Teddy.load(copy));
}

test "teddy differential against naive search" {
    var prng = std.Random.DefaultPrng.init(0x7edd1);
    const r = prng.random();
    var pat_store: [max_patterns][8]u8 = undefined;
    var pats: [max_patterns]Pattern = undefined;
    var hay_buf: [300]u8 = undefined;
    for (0..400) |round| {
        // Small alphabets force many overlapping matches and candidates.
        const alpha: u8 = if (round % 3 == 0) 2 else if (round % 3 == 1) 4 else 255;
        const n = r.intRangeAtMost(usize, 1, max_patterns);
        for (0..n) |i| {
            const len = r.intRangeAtMost(usize, 1, 8);
            for (pat_store[i][0..len]) |*b| b.* = randByte(r, alpha);
            pats[i] = .{ .bytes = pat_store[i][0..len], .id = @intCast(i) };
        }
        const opts: Options = .{ .ascii_case_insensitive = round % 2 == 0 };
        var t = try Teddy.build(testing.allocator, pats[0..n], opts);
        defer t.deinit(testing.allocator);
        const hay = hay_buf[0..r.intRangeAtMost(usize, 0, hay_buf.len)];
        for (hay) |*b| b.* = randByte(r, alpha);

        const want = try naive.allMatches(testing.allocator, pats[0..n], hay, opts);
        defer testing.allocator.free(want);
        var got: std.ArrayList(Match) = .empty;
        defer got.deinit(testing.allocator);
        try testing.expect(t.view.scan(hay, &got, collect));
        std.mem.sort(Match, got.items, {}, naive.lessThan);
        try testing.expectEqualSlices(Match, want, got.items);

        var from: usize = 0;
        while (from <= hay.len) : (from += r.intRangeAtMost(usize, 1, 7)) {
            try testing.expectEqual(naive.leftmostFirst(pats[0..n], hay, from, opts), t.view.find(hay, from));
        }
    }
}

/// A random byte from a small alphabet that still exercises case folding and
/// the 0x00 and 0xff extremes.
pub fn randByte(r: std.Random, alpha: u8) u8 {
    const pool = "aAbB\x00\xff\x7f\x80";
    if (alpha < pool.len) return pool[r.uintLessThan(u8, alpha)];
    return r.int(u8);
}

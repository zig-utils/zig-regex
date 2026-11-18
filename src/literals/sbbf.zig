//! Sampled split-block Bloom prefilter over 4-byte grams.
//!
//! The filter is an array of 32-byte blocks of eight `u32` words. A gram (4
//! haystack bytes read little-endian) is hashed with a seed; the high bits of
//! the hash pick a block and eight odd multipliers ("salts") pick one bit in
//! each word. A gram is possibly present when all eight bits are set.
//!
//! Stride tiers: a filter built with stride `s` samples only positions
//! `start, start + s, start + 2s, ...`. Every anchor inserted must be at least
//! `s + 3` bytes long, and the grams at its offsets `0..s-1` are all inserted,
//! so wherever the anchor occurs one sampled position falls on one of them
//! and the anchor is never missed. A candidate position `q` therefore means
//! "some anchor may start in `q - s + 1 .. q`"; the verifier finds which.
//!
//! Probing has no loop-carried state: each batch hashes 16 sampled grams in
//! vector registers (built from one load with comptime shuffles), then tests
//! 16 blocks with scalar loads, so the CPU keeps many cache misses in flight.
//! There are no gathers (slow under the Downfall mitigation on Intel). Each
//! position is written to the candidate buffer unconditionally and the count
//! advances by the test result, so the probe loop has no data-dependent
//! branches.

const std = @import("std");
const blob = @import("blob.zig");

pub const magic = "ZSBF".*;
pub const format_version: u16 = 1;

/// Gram length in bytes.
pub const q = 4;
pub const max_stride = 16;
/// Sampled positions handled per probe batch; `Prober.next` needs an output
/// buffer at least this long.
pub const batch = 16;

pub const LoadError = blob.LoadError;

pub const BuildError = std.mem.Allocator.Error || error{
    /// `stride` is 0 or above `max_stride`, or `bits_per_key` is 0.
    BadOptions,
    /// An anchor shorter than `stride + 3` bytes could be missed by sampling.
    AnchorTooShort,
    /// More than 2^32 blocks.
    TooLarge,
};

pub const Options = struct {
    /// Sample every `stride`-th position: 1 (tier C), 4 (tier B), 8 (tier A).
    stride: u32 = 1,
    /// Filter size per distinct gram. About 16 gives 0.1 to 0.3 percent false
    /// positives.
    bits_per_key: u32 = 16,
    seed: u32 = 0,
};

/// Eight odd multipliers, one per word of a block (the Parquet SBBF salts).
pub const salts: [8]u32 = .{
    0x47b6137b, 0x44974d91, 0x8824ad5b, 0xa2b7289d,
    0x705495c7, 0x2df1424b, 0x9efc4947, 0x5c6bfb31,
};

const Header = extern struct {
    prefix: blob.Prefix,
    gram_len: u32,
    stride: u32,
    num_blocks: u32,
    seed: u32,
    /// Distinct grams inserted.
    num_keys: u64,
    bits_per_key: u32,
    _pad: u32 = 0,
    blocks_off: u64,
    _reserved: u64 = 0,
};

pub const Block = [8]u32;

comptime {
    std.debug.assert(@sizeOf(Header) == 64);
    std.debug.assert(@sizeOf(Block) == 32);
}

/// The 4 bytes at `bytes[0..4]` as a gram.
pub inline fn gramAt(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

/// A bijective 32-bit mix (Chris Wellons' lowbias32) of the seeded gram.
/// Works lane-wise on vectors too.
pub inline fn hash(gram: anytype, seed: u32) @TypeOf(gram) {
    const T = @TypeOf(gram);
    const sp = struct {
        inline fn s(v: u32) T {
            return if (@typeInfo(T) == .vector) @splat(v) else v;
        }
    }.s;
    var x = gram ^ sp(seed);
    x ^= x >> sp(16);
    x *%= sp(0x7feb352d);
    x ^= x >> sp(15);
    x *%= sp(0x846ca68b);
    x ^= x >> sp(16);
    return x;
}

/// The block a hash selects: `h * num_blocks / 2^32`.
pub inline fn blockIndex(h: u32, num_blocks: u32) u32 {
    return @intCast((@as(u64, h) * num_blocks) >> 32);
}

/// The eight one-bit masks a hash sets in its block.
pub inline fn masks(h: u32) @Vector(8, u32) {
    const k: @Vector(8, u32) = @splat(h);
    const shift: @Vector(8, u5) = @intCast((k *% @as(@Vector(8, u32), salts)) >> @splat(27));
    return @as(@Vector(8, u32), @splat(1)) << shift;
}

/// A filter viewing a blob. Copying it is cheap; probing never allocates
/// and never writes to the blob.
pub const Sbbf = struct {
    stride: u32,
    seed: u32,
    num_keys: u64,
    bits_per_key: u32,
    blocks: []const Block,

    pub const Owned = blob.Owned(Sbbf);

    /// Build a filter holding the grams at offsets `0..stride-1` of every
    /// anchor.
    pub fn build(gpa: std.mem.Allocator, anchors: []const []const u8, options: Options) BuildError!Owned {
        var b = try Builder.init(gpa, options);
        defer b.deinit();
        for (anchors) |a| try b.addAnchor(a);
        return b.finish();
    }

    /// View a serialised filter in place. Any bit pattern is a valid filter,
    /// so only the header and bounds are checked. `bytes` must start on an
    /// 8-byte boundary and stay alive and unchanged while the filter is used.
    pub fn load(bytes: []const u8) LoadError!Sbbf {
        const h, const b = try blob.readHeader(Header, bytes, magic, format_version);
        if (h.gram_len != q) return error.Corrupt;
        if (h.stride == 0 or h.stride > max_stride) return error.Corrupt;
        if (h.num_blocks == 0) return error.Corrupt;
        return .{
            .stride = h.stride,
            .seed = h.seed,
            .num_keys = h.num_keys,
            .bits_per_key = h.bits_per_key,
            .blocks = try blob.section(Block, b, h.blocks_off, h.num_blocks),
        };
    }

    /// True when `gram` may have been inserted; false means it was not.
    pub fn contains(self: *const Sbbf, gram: u32) bool {
        return self.test1(hash(gram, self.seed));
    }

    inline fn test1(self: *const Sbbf, h: u32) bool {
        const blk: @Vector(8, u32) = self.blocks[blockIndex(h, @intCast(self.blocks.len))];
        const m = masks(h);
        return @reduce(.And, (blk & m) == m);
    }

    /// The false-positive rate expected for a gram not in the filter, from
    /// the number of keys and blocks: the chance that all 8 bits are set in a
    /// block holding a Poisson-distributed number of keys.
    pub fn expectedFalsePositiveRate(self: *const Sbbf) f64 {
        return theoreticalFpr(self.num_keys, self.blocks.len);
    }

    /// Probe the sampled positions `start, start + stride, ...` of
    /// `haystack` (those with 4 bytes left).
    pub fn prober(self: *const Sbbf, haystack: []const u8, start: usize) Prober {
        return .{ .filter = self, .haystack = haystack, .pos = start };
    }
};

/// The false-positive rate of a split-block filter with `n` keys spread
/// uniformly over `blocks` blocks.
pub fn theoreticalFpr(n: u64, blocks: usize) f64 {
    const lambda = @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(blocks));
    // Sum the Poisson mixture until the tail is negligible.
    var p = @exp(-lambda);
    var total: f64 = 0;
    var i: usize = 0;
    const limit: usize = @intFromFloat(lambda * 4 + 64);
    while (i <= limit) : (i += 1) {
        const fi: f64 = @floatFromInt(i);
        total += p * std.math.pow(f64, 1 - std.math.pow(f64, 31.0 / 32.0, fi), 8);
        p *= lambda / (fi + 1);
    }
    return total;
}

/// Resumable probe over one haystack. Each `next` fills `out` with candidate
/// positions in ascending order and returns the filled part; an empty result
/// means the haystack is done.
pub const Prober = struct {
    filter: *const Sbbf,
    haystack: []const u8,
    pos: usize,

    pub fn next(self: *Prober, out: []usize) []usize {
        std.debug.assert(out.len >= batch);
        return switch (self.filter.stride) {
            inline 1...max_stride => |s| self.nextStride(s, out),
            else => unreachable,
        };
    }

    fn nextStride(self: *Prober, comptime s: usize, out: []usize) []usize {
        const f = self.filter;
        const hay = self.haystack;
        const nb: u32 = @intCast(f.blocks.len);
        // Bytes one batch reads: 16 grams `s` apart, rounded up to whole
        // 16-byte registers so the shuffle sources are full vectors.
        const span = comptime loadLen(s);
        var pos = self.pos;
        var n: usize = 0;
        if (hay.len >= span) {
            const last = hay.len - span;
            while (pos <= last and out.len - n >= batch) : (pos += batch * s) {
                const grams = loadGrams(s, hay[pos..][0..span]);
                const ha: [batch]u32 = hash(grams, f.seed);
                inline for (0..batch) |j| {
                    // Scalar: NEON has no 64-bit lane multiply, and the block
                    // address is needed in a general register anyway.
                    const blk: @Vector(8, u32) = f.blocks[blockIndex(ha[j], nb)];
                    const m = masks(ha[j]);
                    out[n] = pos + j * s;
                    n += @intFromBool(@reduce(.Or, m & ~blk) == 0);
                }
            }
        }
        if (hay.len >= span and pos <= hay.len - span) {
            // `out` is full; resume with whole batches on the next call.
            self.pos = pos;
            return out[0..n];
        }
        // Positions too close to the end for a whole batch.
        while (pos + q <= hay.len and n < out.len) : (pos += s) {
            out[n] = pos;
            n += @intFromBool(f.contains(gramAt(hay[pos..])));
        }
        self.pos = pos;
        return out[0..n];
    }
};

fn loadLen(comptime s: usize) usize {
    return std.mem.alignForward(usize, (batch - 1) * s + q, 16);
}

/// The 16 grams at offsets `0, s, 2s, ...` of `bytes`, built from one vector
/// load with a comptime shuffle.
inline fn loadGrams(comptime s: usize, bytes: *const [loadLen(s)]u8) @Vector(batch, u32) {
    const L: u32 = comptime loadLen(s);
    const v: @Vector(L, u8) = bytes.*;
    const mask = comptime blk: {
        @setEvalBranchQuota(10_000);
        var m: [batch * q]i32 = undefined;
        for (0..batch) |k| {
            for (0..q) |j| m[k * q + j] = @intCast(k * s + j);
        }
        break :blk m;
    };
    const lanes: @Vector(batch * q, u8) = @shuffle(u8, v, undefined, mask);
    return @bitCast(lanes);
}

/// Collects grams, then sizes and fills a filter.
pub const Builder = struct {
    gpa: std.mem.Allocator,
    options: Options,
    grams: std.ArrayList(u32) = .empty,

    pub fn init(gpa: std.mem.Allocator, options: Options) BuildError!Builder {
        if (options.stride == 0 or options.stride > max_stride or options.bits_per_key == 0) return error.BadOptions;
        return .{ .gpa = gpa, .options = options };
    }

    pub fn deinit(self: *Builder) void {
        self.grams.deinit(self.gpa);
        self.* = undefined;
    }

    /// Insert the grams at offsets `0..stride-1` of `anchor`, which must be
    /// at least `stride + 3` bytes long.
    pub fn addAnchor(self: *Builder, anchor: []const u8) BuildError!void {
        const s = self.options.stride;
        if (anchor.len < s + q - 1) return error.AnchorTooShort;
        try self.grams.ensureUnusedCapacity(self.gpa, s);
        for (0..s) |k| self.grams.appendAssumeCapacity(gramAt(anchor[k..]));
    }

    /// Insert one gram directly.
    pub fn addGram(self: *Builder, gram: u32) BuildError!void {
        try self.grams.append(self.gpa, gram);
    }

    /// Size the filter for the distinct grams added and serialise it.
    pub fn finish(self: *Builder) BuildError!Sbbf.Owned {
        const g = self.grams.items;
        std.mem.sort(u32, g, {}, std.sort.asc(u32));
        var distinct: usize = 0;
        for (g, 0..) |x, i| {
            if (i == 0 or x != g[distinct - 1]) {
                g[distinct] = x;
                distinct += 1;
            }
        }
        const bits = @as(u64, distinct) * self.options.bits_per_key;
        const nb = @max(1, std.math.divCeil(u64, bits, 256) catch unreachable);
        if (nb > std.math.maxInt(u32)) return error.TooLarge;

        var layout = blob.Layout.init(Header);
        const blocks_off = layout.reserve(Block, @intCast(nb));
        const bytes = try blob.allocBlob(self.gpa, layout.total());
        errdefer self.gpa.free(bytes);
        const h: *Header = @ptrCast(bytes.ptr);
        h.* = .{
            .prefix = .{
                .magic = magic,
                .version = format_version,
                .header_size = @sizeOf(Header),
                .total_len = bytes.len,
            },
            .gram_len = q,
            .stride = self.options.stride,
            .num_blocks = @intCast(nb),
            .seed = self.options.seed,
            .num_keys = distinct,
            .bits_per_key = self.options.bits_per_key,
            .blocks_off = blocks_off,
        };
        const blocks = blob.sectionMut(Block, bytes, blocks_off, @intCast(nb));
        for (g[0..distinct]) |gram| {
            const hv = hash(gram, self.options.seed);
            const b = &blocks[blockIndex(hv, @intCast(nb))];
            const set: @Vector(8, u32) = b.*;
            b.* = set | masks(hv);
        }
        const view = Sbbf.load(bytes) catch unreachable;
        return .{ .bytes = bytes, .view = view };
    }
};

const testing = std.testing;

test "loadGrams matches scalar reads" {
    var bytes: [loadLen(max_stride)]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @truncate(i *% 37 +% 11);
    inline for (1..max_stride + 1) |s| {
        const L = comptime loadLen(s);
        const got: [batch]u32 = loadGrams(s, bytes[0..L]);
        for (0..batch) |k| try testing.expectEqual(gramAt(bytes[k * s ..]), got[k]);
    }
}

test "vector hash matches scalar hash" {
    var prng = std.Random.DefaultPrng.init(3);
    var g: [batch]u32 = undefined;
    prng.random().bytes(std.mem.sliceAsBytes(&g));
    const v: [batch]u32 = hash(@as(@Vector(batch, u32), g), 0xdead);
    for (g, v) |x, y| try testing.expectEqual(hash(x, 0xdead), y);
}

test "inserted grams are always present" {
    var b = try Builder.init(testing.allocator, .{ .stride = 1, .bits_per_key = 8 });
    defer b.deinit();
    var prng = std.Random.DefaultPrng.init(4);
    const r = prng.random();
    var grams: [5000]u32 = undefined;
    for (&grams) |*g| {
        g.* = r.int(u32);
        try b.addGram(g.*);
    }
    var f = try b.finish();
    defer f.deinit(testing.allocator);
    for (grams) |g| try testing.expect(f.view.contains(g));
}

test "short anchors and bad options are rejected" {
    try testing.expectError(error.BadOptions, Builder.init(testing.allocator, .{ .stride = 0 }));
    try testing.expectError(error.BadOptions, Builder.init(testing.allocator, .{ .stride = max_stride + 1 }));
    try testing.expectError(error.AnchorTooShort, Sbbf.build(testing.allocator, &.{"abcdefghij"}, .{ .stride = 8 }));
}

test "serialised filter loads and probes identically" {
    var f = try Sbbf.build(testing.allocator, &.{ "malware!", "\x00\xff\x00\xff\x01" }, .{ .stride = 2 });
    defer f.deinit(testing.allocator);
    const copy = try blob.dupeAligned(testing.allocator, f.bytes);
    defer testing.allocator.free(copy);
    const v = try Sbbf.load(copy);
    const part = "xx malware! yy \x00\xff\x00\xff\x01 zz";
    const hay = part ++ part ++ part;
    var b1: [batch]usize = undefined;
    var b2: [batch]usize = undefined;
    var p1 = f.view.prober(hay, 0);
    var p2 = v.prober(hay, 0);
    while (true) {
        const c1 = p1.next(&b1);
        const c2 = p2.next(&b2);
        try testing.expectEqualSlices(usize, c1, c2);
        if (c1.len == 0) break;
    }
    copy[4] = 9;
    try testing.expectError(error.UnsupportedVersion, Sbbf.load(copy));
}

//! Shared plumbing for the relocatable serialised forms of the literal
//! searchers.
//!
//! Every searcher keeps its whole state in one byte blob: an `extern` header
//! followed by sections addressed by byte offsets from the start of the blob,
//! never by pointers. All integers are little-endian. A blob can therefore be
//! written to disk, mmapped read-only at any address that satisfies
//! `min_alignment`, and searched in place without allocating. The in-memory
//! searcher built at runtime is the same blob, so a loaded copy behaves
//! identically by construction.

const std = @import("std");
const builtin = @import("builtin");

/// The alignment a blob must have to be loaded. mmapped files are page
/// aligned; owned blobs are allocated with `owned_alignment`.
pub const min_alignment = 8;
pub const owned_alignment: std.mem.Alignment = .@"64";

pub const LoadError = error{
    /// Shorter than its header or than the length the header records.
    Truncated,
    /// The magic bytes name a different kind of blob.
    BadMagic,
    /// Written by an incompatible format version.
    UnsupportedVersion,
    /// The blob does not start on a `min_alignment` boundary.
    Misaligned,
    /// A section or index points outside the blob or breaks an invariant.
    Corrupt,
};

/// The first 16 bytes of every blob.
pub const Prefix = extern struct {
    magic: [4]u8,
    version: u16,
    header_size: u16,
    /// Length of the whole blob in bytes, header included.
    total_len: u64,
};

comptime {
    std.debug.assert(@sizeOf(Prefix) == 16);
}

/// Fail at compile time on hosts where the in-place typed views would read
/// the little-endian sections with the wrong byte order.
pub inline fn requireLittleEndian() void {
    if (comptime builtin.cpu.arch.endian() != .little)
        @compileError("literal blobs are little-endian and are only viewed in place on little-endian hosts");
}

/// Validate the prefix of `bytes` and return its typed header. `bytes` may be
/// longer than the blob; the returned slice length is `total_len`.
pub fn readHeader(comptime H: type, bytes: []const u8, magic: [4]u8, version: u16) LoadError!struct { *const H, []const u8 } {
    requireLittleEndian();
    comptime std.debug.assert(@alignOf(H) <= min_alignment);
    if (@intFromPtr(bytes.ptr) % min_alignment != 0) return error.Misaligned;
    if (bytes.len < @sizeOf(H)) return error.Truncated;
    const h: *const H = @ptrCast(@alignCast(bytes.ptr));
    const p: *const Prefix = &h.prefix;
    if (!std.mem.eql(u8, &p.magic, &magic)) return error.BadMagic;
    if (p.version != version) return error.UnsupportedVersion;
    if (p.header_size != @sizeOf(H)) return error.Corrupt;
    if (p.total_len < @sizeOf(H)) return error.Corrupt;
    if (p.total_len > bytes.len) return error.Truncated;
    return .{ h, bytes[0..@intCast(p.total_len)] };
}

/// A typed view of `count` items of `T` at byte offset `off` in `blob`.
pub fn section(comptime T: type, blob: []const u8, off: u64, count: u64) LoadError![]const T {
    const size = std.math.mul(u64, count, @sizeOf(T)) catch return error.Corrupt;
    const end = std.math.add(u64, off, size) catch return error.Corrupt;
    if (end > blob.len) return error.Corrupt;
    if (count == 0) return &.{};
    const start: usize = @intCast(off);
    if ((@intFromPtr(blob.ptr) + start) % @alignOf(T) != 0) return error.Corrupt;
    const ptr: [*]const T = @ptrCast(@alignCast(blob.ptr + start));
    return ptr[0..@intCast(count)];
}

/// A built searcher that owns its blob. `view` borrows `bytes`; write
/// `bytes` to disk to persist the searcher and `T.load` it back later.
pub fn Owned(comptime T: type) type {
    return struct {
        bytes: []align(64) u8,
        view: T,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.bytes);
            self.* = undefined;
        }
    };
}

/// Lays out sections while building a blob: each `reserve` returns the
/// offset of a section aligned to at least 8 bytes.
pub const Layout = struct {
    len: u64,

    pub fn init(comptime H: type) Layout {
        return .{ .len = @sizeOf(H) };
    }

    pub fn reserve(self: *Layout, comptime T: type, count: usize) u64 {
        const a = @max(@alignOf(T), min_alignment);
        const off = std.mem.alignForward(u64, self.len, a);
        self.len = off + @as(u64, count) * @sizeOf(T);
        return off;
    }

    /// Total blob length, padded to 8 bytes so blobs can be concatenated.
    pub fn total(self: Layout) u64 {
        return std.mem.alignForward(u64, self.len, min_alignment);
    }
};

/// Allocate a zeroed blob of `len` bytes with `owned_alignment`.
pub fn allocBlob(allocator: std.mem.Allocator, len: u64) std.mem.Allocator.Error![]align(64) u8 {
    const n = std.math.cast(usize, len) orelse return error.OutOfMemory;
    const buf = try allocator.alignedAlloc(u8, owned_alignment, n);
    @memset(buf, 0);
    return buf;
}

/// A mutable typed view used while filling a freshly allocated blob.
pub fn sectionMut(comptime T: type, blob: []align(64) u8, off: u64, count: usize) []T {
    if (count == 0) return &.{};
    const ptr: [*]T = @ptrCast(@alignCast(blob.ptr + @as(usize, @intCast(off))));
    return ptr[0..count];
}

/// Copy `bytes` into a fresh owned blob, for callers that read a blob from a
/// file into an unaligned buffer.
pub fn dupeAligned(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error![]align(64) u8 {
    const buf = try allocator.alignedAlloc(u8, owned_alignment, bytes.len);
    @memcpy(buf, bytes);
    return buf;
}

test "section rejects out of range and misaligned views" {
    var storage: [64]u8 align(8) = @splat(0);
    const blob: []const u8 = &storage;
    try std.testing.expectEqual(@as(usize, 4), (try section(u32, blob, 8, 4)).len);
    try std.testing.expectError(error.Corrupt, section(u32, blob, 60, 2));
    try std.testing.expectError(error.Corrupt, section(u32, blob, 2, 1));
    try std.testing.expectError(error.Corrupt, section(u64, blob, 0, std.math.maxInt(u64)));
}

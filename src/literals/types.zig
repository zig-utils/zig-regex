//! Types shared by every literal searcher.

const std = @import("std");

/// One literal to search for. `bytes` may hold any byte values, 0x00 and 0xff
/// included. `id` is reported back in every `Match`; ids need not be unique or
/// dense.
pub const Pattern = struct {
    bytes: []const u8,
    id: u32,
};

/// One occurrence of a pattern: `haystack[start..end]` equals the pattern
/// (under ASCII case folding when the searcher was built with it).
pub const Match = struct {
    /// The `id` of the pattern that matched.
    pattern: u32,
    start: usize,
    end: usize,
};

pub const Options = struct {
    /// Match ASCII letters regardless of case. Every other byte, including
    /// bytes 0x80 to 0xff, still has to match exactly.
    ascii_case_insensitive: bool = false,
};

/// Lowercase an ASCII letter and leave every other byte alone.
pub inline fn fold(b: u8) u8 {
    return b | (@as(u8, @intFromBool(b -% 'A' < 26)) << 5);
}

/// Compare `hay` with `lit`, where `lit` is already folded when `nocase`.
pub inline fn eqlFolded(hay: []const u8, lit: []const u8, nocase: bool) bool {
    std.debug.assert(hay.len == lit.len);
    if (!nocase) return std.mem.eql(u8, hay, lit);
    for (hay, lit) |a, b| {
        if (fold(a) != b) return false;
    }
    return true;
}

test "fold only touches ASCII letters" {
    for (0..256) |i| {
        const b: u8 = @intCast(i);
        try std.testing.expectEqual(std.ascii.toLower(b), fold(b));
    }
}

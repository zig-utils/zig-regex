//! Runtime byte shuffles for the literal searchers.
//!
//! `@shuffle` takes a comptime mask, so a table lookup indexed by runtime data
//! (the nibble lookups at the heart of Teddy) needs the target's own
//! instruction: `tbl` on aarch64 NEON, `pshufb` on x86_64 SSSE3 and `vpshufb`
//! on AVX2. Every other target uses a portable scalar loop with the same
//! result, so callers never branch on the architecture themselves.

const std = @import("std");
const builtin = @import("builtin");

pub const V16 = @Vector(16, u8);

const arch = builtin.cpu.arch;

/// True when `lookup16` compiles to a single shuffle instruction per 16 bytes.
pub const has_shuffle: bool = switch (arch) {
    .aarch64, .aarch64_be => std.Target.aarch64.featureSetHas(builtin.cpu.features, .neon),
    .x86_64, .x86 => std.Target.x86.featureSetHas(builtin.cpu.features, .ssse3),
    else => false,
};

const has_avx = switch (arch) {
    .x86_64, .x86 => std.Target.x86.featureSetHas(builtin.cpu.features, .avx),
    else => false,
};

const has_avx2 = switch (arch) {
    .x86_64, .x86 => std.Target.x86.featureSetHas(builtin.cpu.features, .avx2),
    else => false,
};

/// The widest vector `lookup` handles in one instruction-level step. Wider
/// requests are split into 16-byte halves by `lookup`.
pub const native_width: usize = if (has_avx2) 32 else 16;

/// Look up each byte of `idx` (each must be below 16) in the 16-entry `table`.
pub inline fn lookup16(table: V16, idx: V16) V16 {
    if (!has_shuffle) return lookupScalar(16, table, idx);
    switch (arch) {
        .aarch64, .aarch64_be => return asm ("tbl %[r].16b, { %[t].16b }, %[i].16b"
            : [r] "=w" (-> V16),
            : [t] "w" (table),
              [i] "w" (idx),
        ),
        .x86_64, .x86 => if (has_avx) {
            return asm ("vpshufb %[i], %[t], %[r]"
                : [r] "=x" (-> V16),
                : [t] "x" (table),
                  [i] "x" (idx),
            );
        } else {
            return asm ("pshufb %[i], %[r]"
                : [r] "=x" (-> V16),
                : [t] "0" (table),
                  [i] "x" (idx),
            );
        },
        else => unreachable,
    }
}

/// Look up each byte of the `W`-byte vector `idx` (each below 16) in `table`.
/// `W` must be a multiple of 16.
pub inline fn lookup(comptime W: usize, table: V16, idx: @Vector(W, u8)) @Vector(W, u8) {
    comptime std.debug.assert(W % 16 == 0);
    if (W == 16) return lookup16(table, idx);
    if (W == 32 and has_avx2) {
        const wide: @Vector(32, u8) = std.simd.join(table, table);
        return asm ("vpshufb %[i], %[t], %[r]"
            : [r] "=x" (-> @Vector(32, u8)),
            : [t] "x" (wide),
              [i] "x" (idx),
        );
    }
    var out: [W]u8 = undefined;
    const in: [W]u8 = idx;
    inline for (0..W / 16) |k| {
        const part: V16 = in[k * 16 ..][0..16].*;
        out[k * 16 ..][0..16].* = lookup16(table, part);
    }
    return out;
}

/// The portable reference for `lookup`; also the fallback on targets with no
/// byte shuffle instruction.
pub fn lookupScalar(comptime W: usize, table: V16, idx: @Vector(W, u8)) @Vector(W, u8) {
    const t: [16]u8 = table;
    const in: [W]u8 = idx;
    var out: [W]u8 = undefined;
    for (in, 0..) |b, k| out[k] = t[b & 15];
    return out;
}

/// Bit k of the result is set when lane k of `v` is nonzero.
pub inline fn nonzeroMask(comptime W: usize, v: @Vector(W, u8)) @Int(.unsigned, W) {
    const zero: @Vector(W, u8) = @splat(0);
    return @bitCast(v != zero);
}

test "lookup matches the scalar reference" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    for (0..2000) |_| {
        var t: [16]u8 = undefined;
        var i32b: [32]u8 = undefined;
        r.bytes(&t);
        r.bytes(&i32b);
        for (&i32b) |*b| b.* &= 15;
        const i16b: [16]u8 = i32b[0..16].*;
        const got16: [16]u8 = lookup16(t, i16b);
        const want16: [16]u8 = lookupScalar(16, t, i16b);
        try std.testing.expectEqualSlices(u8, &want16, &got16);
        const got32: [32]u8 = lookup(32, t, i32b);
        const want32: [32]u8 = lookupScalar(32, t, i32b);
        try std.testing.expectEqualSlices(u8, &want32, &got32);
    }
}

test "nonzeroMask sets one bit per nonzero lane" {
    var v: [16]u8 = @splat(0);
    v[0] = 1;
    v[5] = 0x80;
    v[15] = 3;
    try std.testing.expectEqual(@as(u16, 1 | (1 << 5) | (1 << 15)), nonzeroMask(16, v));
}

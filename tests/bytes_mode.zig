//! Byte-mode compilation (`CompileFlags.bytes`): every construct is checked in
//! byte mode and, where the modes differ, against the default UTF-8 mode.

const std = @import("std");
const regex = @import("regex");
const Regex = regex.Regex;
const CompileFlags = regex.common.CompileFlags;

const testing = std.testing;
const bytes_mode: CompileFlags = .{ .bytes = true };

/// Expect `pattern` to find exactly `expected` (a span, or no match) in
/// `input`, and every search entry point to agree with it.
fn expectFind(pattern: []const u8, flags: CompileFlags, input: []const u8, expected: ?[2]usize) !void {
    var re = try Regex.compileWithFlags(testing.allocator, pattern, flags);
    defer re.deinit();
    const found = try re.find(input);
    if (found) |m| {
        var owned = m;
        defer owned.deinit(testing.allocator);
        const want = expected orelse {
            std.debug.print("pattern {any} input {any}: unexpected match {d}..{d}\n", .{ pattern, input, m.start, m.end });
            return error.TestUnexpectedResult;
        };
        try testing.expectEqual(want[0], m.start);
        try testing.expectEqual(want[1], m.end);
    } else if (expected) |want| {
        std.debug.print("pattern {any} input {any}: expected {d}..{d}, got no match\n", .{ pattern, input, want[0], want[1] });
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(expected != null, try re.isMatch(input));
    var m = re.matcher();
    defer m.deinit();
    try testing.expectEqual(expected != null, try m.isMatch(input));
}

test "bytes: \\x80\\xff matches exactly those two bytes" {
    try expectFind("\\x80\\xff", bytes_mode, "\x80\xff", .{ 0, 2 });
    try expectFind("\\x80\\xff", bytes_mode, "ab\x80\xffcd", .{ 2, 4 });
    try expectFind("\\x80\\xff", bytes_mode, "\xc2\x80\xc3\xbf", null);
    try expectFind("^\\x80\\xff$", bytes_mode, "\x80\xff", .{ 0, 2 });
    try expectFind("^\\x80\\xff$", bytes_mode, "\x80\xff\x00", null);
}

test "bytes: \\xHH in UTF-8 mode still encodes the code point" {
    // Default mode is unchanged: \x80 is U+0080, two UTF-8 bytes.
    try expectFind("\\x80", .{}, "\xc2\x80", .{ 0, 2 });
    try expectFind("\\x80", .{}, "\x80", null);
    try expectFind("\\xff", .{}, "\xc3\xbf", .{ 0, 2 });
}

test "bytes: hex escape forms follow PCRE" {
    try expectFind("\\xA", bytes_mode, "\n", .{ 0, 1 }); // one digit
    try expectFind("\\x0g", bytes_mode, "\x00g", .{ 0, 2 }); // stops at a non-digit
    try expectFind("a\\xb", bytes_mode, "a\x0b", .{ 0, 2 });
    try expectFind("\\x", bytes_mode, "a\x00", .{ 1, 2 }); // no digits is NUL
    try expectFind("\\x{ff}", bytes_mode, "\xff", .{ 0, 1 });
    try expectFind("\\x{0}", bytes_mode, "\x00", .{ 0, 1 });
    try expectFind("\\x{00000041}", bytes_mode, "A", .{ 0, 1 });
    try expectFind("\\x414", bytes_mode, "A4", .{ 0, 2 }); // at most two digits
    try testing.expectError(error.InvalidEscapeSequence, Regex.compileWithFlags(testing.allocator, "\\x{100}", bytes_mode));
    try testing.expectError(error.InvalidEscapeSequence, Regex.compileWithFlags(testing.allocator, "\\x{}", bytes_mode));
    try testing.expectError(error.InvalidEscapeSequence, Regex.compileWithFlags(testing.allocator, "\\x{ff", bytes_mode));
}

test "bytes: a raw pattern byte is its own atom" {
    // UTF-8 mode groups a multi-byte character, so `+` repeats all of it.
    try expectFind("\xc3\xa9+", .{}, "\xc3\xa9\xc3\xa9", .{ 0, 4 });
    // Byte mode: `+` binds to the last byte only.
    try expectFind("\xc3\xa9+", bytes_mode, "\xc3\xa9\xa9\xa9", .{ 0, 4 });
    try expectFind("\xc3\xa9+", bytes_mode, "\xc3\xa9\xc3\xa9", .{ 0, 2 });
    try expectFind("\xff\xfe", bytes_mode, "\x00\xff\xfe", .{ 1, 3 });
}

test "bytes: dot matches any single byte" {
    try expectFind("^.$", bytes_mode, "\xff", .{ 0, 1 });
    try expectFind("^.$", bytes_mode, "\x00", .{ 0, 1 });
    try expectFind("^.$", bytes_mode, "\r", .{ 0, 1 });
    try expectFind("^.$", bytes_mode, "\n", null);
    try expectFind("^.$", .{ .bytes = true, .dot_all = true }, "\n", .{ 0, 1 });
    // A two-byte character is two dots in byte mode, one in UTF-8 mode.
    try expectFind("^.$", bytes_mode, "\xc3\xa9", null);
    try expectFind("^..$", bytes_mode, "\xc3\xa9", .{ 0, 2 });
    try expectFind("^.$", .{}, "\xc3\xa9", .{ 0, 2 });
    // Every byte value, one at a time.
    var b: usize = 0;
    while (b < 256) : (b += 1) {
        const one = [_]u8{@intCast(b)};
        try expectFind("^.$", .{ .bytes = true, .dot_all = true }, &one, .{ 0, 1 });
        try expectFind("^.$", bytes_mode, &one, if (b == '\n') null else .{ 0, 1 });
    }
    try expectFind("a.*z", bytes_mode, "a\x00\xff\x80z", .{ 0, 5 });
    try expectFind("a.+?z", bytes_mode, "a\xff\xfez\xffz", .{ 0, 4 });
}

test "bytes: character classes are byte sets" {
    try expectFind("[\\x80-\\xff]+", bytes_mode, "ab\x80\x90\xffcd", .{ 2, 5 });
    try expectFind("[\\x00-\\x1f]", bytes_mode, "ab\x07", .{ 2, 3 });
    try expectFind("[^a]", bytes_mode, "a\xff", .{ 1, 2 });
    try expectFind("^[^a]$", bytes_mode, "\xc3\xa9", null);
    try expectFind("^[^a]{2}$", bytes_mode, "\xc3\xa9", .{ 0, 2 });
    // A raw multi-byte character in a class is a set of its bytes.
    try expectFind("^[\xc3\xa9]$", bytes_mode, "\xa9", .{ 0, 1 });
    try expectFind("^[\xc3\xa9]$", .{}, "\xa9", null);
    try expectFind("^[\xc3\xa9]$", .{}, "\xc3\xa9", .{ 0, 2 });
    try expectFind("[\\x{41}-\\x{43}]+", bytes_mode, "zABCD", .{ 1, 4 });
    try expectFind("[\\d\\x80]+", bytes_mode, "a1\x802", .{ 1, 4 });
    try expectFind("[[:alpha:]\\xff]+", bytes_mode, "1a\xffb2", .{ 1, 4 });
    try testing.expectError(error.InvalidCharacterClass, Regex.compileWithFlags(testing.allocator, "[\\xff-\\x80]", bytes_mode));
}

test "bytes: \\s and \\S are ASCII" {
    // U+00A0 NO-BREAK SPACE is whitespace in UTF-8 mode only.
    try expectFind("\\s", .{}, "\xc2\xa0", .{ 0, 2 });
    try expectFind("\\s", bytes_mode, "\xc2\xa0", null);
    try expectFind("\\s+", bytes_mode, "a \t\r\n\x0b\x0cb", .{ 1, 7 });
    try expectFind("^\\S$", bytes_mode, "\xa0", .{ 0, 1 });
    try expectFind("^\\S+$", bytes_mode, "\xc2\xa0", .{ 0, 2 });
    try expectFind("[\\s]", bytes_mode, "\xa0 ", .{ 1, 2 });
    try expectFind("\\w+", bytes_mode, "\xffab_9\xff", .{ 1, 5 });
    try expectFind("\\W", bytes_mode, "ab\xe9", .{ 2, 3 });
    try expectFind("\\d+", bytes_mode, "\x00123\x00", .{ 1, 4 });
    try expectFind("\\D", bytes_mode, "12\x80", .{ 2, 3 });
}

test "bytes: case-insensitive folds ASCII only" {
    const ci: CompileFlags = .{ .bytes = true, .case_insensitive = true };
    try expectFind("abc", ci, "xABCx", .{ 1, 4 });
    try expectFind("[a-c]+", ci, "xAbCx", .{ 1, 4 });
    try expectFind("[^a]", ci, "Ab", .{ 1, 2 });
    // No Latin-1 or UTF-8 folding: \xe9 (e acute) does not match \xc9.
    try expectFind("\\xe9", ci, "\xc9", null);
    try expectFind("\\xe9", ci, "\xe9", .{ 0, 1 });
    try expectFind("\xc3\xa9", ci, "\xc3\x89", null);
    // UTF-8 mode with `i` folds the code point.
    try expectFind("\xc3\xa9", .{ .case_insensitive = true }, "\xc3\x89", .{ 0, 2 });
    // Backtracking engine (a backreference) folds ASCII too.
    try expectFind("(a\\xff)\\1", ci, "A\xffa\xff", .{ 0, 4 });
}

test "bytes: anchors" {
    try expectFind("^\\x00", bytes_mode, "\x00\x01", .{ 0, 1 });
    try expectFind("^\\x01", bytes_mode, "\x00\x01", null);
    try expectFind("\\xff$", bytes_mode, "\x00\xff", .{ 1, 2 });
    try expectFind("\\xff$", bytes_mode, "\xff\x00", null);
    try expectFind("^\\x80", .{ .bytes = true, .multiline = true }, "a\n\x80", .{ 2, 3 });
    try expectFind("\\x80$", .{ .bytes = true, .multiline = true }, "\x80\nb", .{ 0, 1 });
    try expectFind("\\A\\xff", bytes_mode, "\xff", .{ 0, 1 });
    try expectFind("\\xff\\z", bytes_mode, "\xff", .{ 0, 1 });
    // Bytes >= 0x80 are not word bytes.
    try expectFind("\\bA\\b", bytes_mode, "\xffA\xff", .{ 1, 2 });
    try expectFind("\\Ba", bytes_mode, "\xffa", null);
    try expectFind("\\B\\xff", bytes_mode, "\xfe\xff", .{ 1, 2 });
}

test "bytes: backtracking constructs" {
    try expectFind("(\\xff+)\\1", bytes_mode, "\x00\xff\xff\xff\xff", .{ 1, 5 });
    try expectFind("(?<=\\xff)a", bytes_mode, "a\xffa", .{ 2, 3 });
    // Lookbehind over `.` steps back one byte, not one code point.
    try expectFind("(?<=.)a", bytes_mode, "\xc3\xa9a", .{ 2, 3 });
    try expectFind("(?<=^.)\\xa9", bytes_mode, "\xc3\xa9", .{ 1, 2 });
    try expectFind("(?<=^..)a", bytes_mode, "\xc3\xa9a", .{ 2, 3 });
    try expectFind("\\x80(?=\\xff)", bytes_mode, "\x80\x80\xff", .{ 1, 2 });
    try expectFind("\\x80(?!\\xff)", bytes_mode, "\x80\xff\x80", .{ 2, 3 });
}

test "bytes: findAll and count over binary data" {
    var re = try Regex.compileWithFlags(testing.allocator, "\\x00[\\x80-\\xff]{2}", bytes_mode);
    defer re.deinit();
    const input = "\x00\x80\x81z\x00\xff\xfe\x00\x01\x02\x00\x90\x91";
    const all = try re.findAll(testing.allocator, input);
    defer {
        for (all) |*m| m.deinit(testing.allocator);
        testing.allocator.free(all);
    }
    try testing.expectEqual(@as(usize, 3), all.len);
    try testing.expectEqual(@as(usize, 0), all[0].start);
    try testing.expectEqual(@as(usize, 4), all[1].start);
    try testing.expectEqual(@as(usize, 10), all[2].start);
    try testing.expectEqual(@as(usize, 3), try re.count(input));
}

test "bytes: code-point constructs are rejected" {
    const unsupported = [_][]const u8{ "\\p{L}", "\\P{L}", "[\\p{L}]", "a[^\\P{Lu}]", "\\u0041", "\\u{41}" };
    for (unsupported) |pattern| {
        try testing.expectError(error.UnsupportedInBytesMode, Regex.compileWithFlags(testing.allocator, pattern, bytes_mode));
    }
    try testing.expectError(error.UnsupportedInBytesMode, Regex.compileWithFlags(testing.allocator, "a", .{ .bytes = true, .unicode = true }));
    try testing.expectError(error.UnsupportedInBytesMode, Regex.compileWithFlags(testing.allocator, "a", .{ .bytes = true, .unicode_sets = true }));
    try testing.expectError(error.UnsupportedInBytesMode, Regex.compileWithFlags(testing.allocator, "a", .{ .bytes = true, .ecmascript = true }));
    // The same patterns stay valid in UTF-8 mode.
    var re = try Regex.compileWithFlags(testing.allocator, "\\p{L}", .{});
    re.deinit();
}

test "bytes: extended mode keeps hex escapes as bytes" {
    try expectFind("\\x80  \\xff # comment", .{ .bytes = true, .extended = true }, "\x80\xff", .{ 0, 2 });
}

// ---------------------------------------------------------------------------
// Differential fuzzing against a reference matcher.
//
// Random patterns are concatenations of byte-set atoms (an escaped byte, a
// byte range class, a negated class or `.`) under `?`, `*`, `+` or nothing.
// A small backtracking reference decides whether any match exists; the
// library must agree for every random input, case-sensitive or not.

const Quant = enum { one, opt, star, plus };
const Atom = struct { set: [256]bool, quant: Quant };

fn refMatchAt(atoms: []const Atom, input: []const u8, pos: usize) bool {
    if (atoms.len == 0) return true;
    const a = atoms[0];
    const rest = atoms[1..];
    switch (a.quant) {
        .one => return pos < input.len and a.set[input[pos]] and refMatchAt(rest, input, pos + 1),
        .opt => return (pos < input.len and a.set[input[pos]] and refMatchAt(rest, input, pos + 1)) or
            refMatchAt(rest, input, pos),
        .star, .plus => {
            var end = pos;
            while (end < input.len and a.set[input[end]]) end += 1;
            const min = pos + @intFromBool(a.quant == .plus);
            var e = end;
            while (e + 1 > min) : (e -= 1) {
                if (refMatchAt(rest, input, e)) return true;
                if (e == 0) break;
            }
            return false;
        },
    }
}

fn refIsMatch(atoms: []const Atom, input: []const u8) bool {
    var p: usize = 0;
    while (p <= input.len) : (p += 1) if (refMatchAt(atoms, input, p)) return true;
    return false;
}

fn foldSet(set: *[256]bool) void {
    var b: usize = 0;
    while (b < 256) : (b += 1) {
        if (!set[b]) continue;
        set[std.ascii.toLower(@intCast(b))] = true;
        set[std.ascii.toUpper(@intCast(b))] = true;
    }
}

fn appendHex(buf: []u8, len: *usize, b: u8) void {
    const hex = "0123456789abcdef";
    buf[len.*] = '\\';
    buf[len.* + 1] = 'x';
    buf[len.* + 2] = hex[b >> 4];
    buf[len.* + 3] = hex[b & 15];
    len.* += 4;
}

test "bytes: differential fuzz against a reference matcher" {
    var prng = std.Random.DefaultPrng.init(0xB17E5);
    const random = prng.random();
    // A small alphabet makes matches likely: three high bytes, NUL, newline,
    // and ASCII letters of both cases.
    const alphabet = [_]u8{ 0x00, 0x80, 0xfe, 0xff, '\n', 'a', 'A', 'b' };

    var iteration: usize = 0;
    while (iteration < 400) : (iteration += 1) {
        const ci = random.boolean();
        var atoms: [6]Atom = undefined;
        var pattern: [128]u8 = undefined;
        var plen: usize = 0;
        const n = random.intRangeAtMost(usize, 1, atoms.len);
        for (atoms[0..n]) |*atom| {
            @memset(&atom.set, false);
            switch (random.intRangeAtMost(u8, 0, 3)) {
                0 => {
                    const b = alphabet[random.uintLessThan(usize, alphabet.len)];
                    atom.set[b] = true;
                    appendHex(&pattern, &plen, b);
                },
                1, 2 => |kind| {
                    var lo = alphabet[random.uintLessThan(usize, alphabet.len)];
                    var hi = alphabet[random.uintLessThan(usize, alphabet.len)];
                    if (lo > hi) std.mem.swap(u8, &lo, &hi);
                    const negated = kind == 2;
                    pattern[plen] = '[';
                    plen += 1;
                    if (negated) {
                        pattern[plen] = '^';
                        plen += 1;
                    }
                    appendHex(&pattern, &plen, lo);
                    pattern[plen] = '-';
                    plen += 1;
                    appendHex(&pattern, &plen, hi);
                    pattern[plen] = ']';
                    plen += 1;
                    var b: usize = lo;
                    while (b <= hi) : (b += 1) atom.set[b] = true;
                    if (ci) foldSet(&atom.set);
                    if (negated) {
                        for (&atom.set) |*bit| bit.* = !bit.*;
                    }
                },
                else => {
                    for (&atom.set, 0..) |*bit, b| bit.* = b != '\n';
                    pattern[plen] = '.';
                    plen += 1;
                },
            }
            if (ci) foldSet(&atom.set);
            atom.quant = random.enumValue(Quant);
            switch (atom.quant) {
                .one => {},
                .opt => pattern[plen] = '?',
                .star => pattern[plen] = '*',
                .plus => pattern[plen] = '+',
            }
            if (atom.quant != .one) plen += 1;
        }

        var re = try Regex.compileWithFlags(testing.allocator, pattern[0..plen], .{ .bytes = true, .case_insensitive = ci });
        defer re.deinit();

        var trial: usize = 0;
        while (trial < 8) : (trial += 1) {
            var input: [24]u8 = undefined;
            const ilen = random.uintAtMost(usize, input.len);
            for (input[0..ilen]) |*byte| byte.* = alphabet[random.uintLessThan(usize, alphabet.len)];
            const want = refIsMatch(atoms[0..n], input[0..ilen]);
            const got = try re.isMatch(input[0..ilen]);
            if (want != got) {
                std.debug.print("pattern \"{s}\" ci={} input {any}: reference {} library {}\n", .{ pattern[0..plen], ci, input[0..ilen], want, got });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "bytes: random byte patterns compile or fail cleanly" {
    var prng = std.Random.DefaultPrng.init(0xF00D);
    const random = prng.random();
    const pieces = [_][]const u8{ "\\x", "\\x{", "}", "\\xff", "\\x8", "[", "]", "^", "-", ".", "*", "+", "?", "(", ")", "|", "\\", "\xff", "\xc3", "\x00", "a", "\\p{L}", "\\s", "\\S", "{2}", "\\b" };
    var iteration: usize = 0;
    while (iteration < 2000) : (iteration += 1) {
        var pattern: [96]u8 = undefined;
        var plen: usize = 0;
        const count = random.intRangeAtMost(usize, 1, 12);
        var k: usize = 0;
        while (k < count) : (k += 1) {
            const piece = pieces[random.uintLessThan(usize, pieces.len)];
            if (plen + piece.len > pattern.len) break;
            @memcpy(pattern[plen..][0..piece.len], piece);
            plen += piece.len;
        }
        var re = Regex.compileWithFlags(testing.allocator, pattern[0..plen], .{ .bytes = true, .dot_all = random.boolean() }) catch continue;
        defer re.deinit();
        var input: [32]u8 = undefined;
        random.bytes(&input);
        _ = re.isMatch(&input) catch continue;
        if (re.find(&input) catch null) |found| {
            var m = found;
            m.deinit(testing.allocator);
        }
    }
}

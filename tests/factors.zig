//! Required literal factors (`regex.requiredFactors`).

const std = @import("std");
const regex = @import("regex");
const Regex = regex.Regex;
const factors = regex.factors;
const CompileFlags = regex.common.CompileFlags;

const testing = std.testing;

fn get(pattern: []const u8, flags: CompileFlags, min_len: usize) !?factors.Factors {
    return regex.requiredFactors(testing.allocator, pattern, flags, .{ .min_len = min_len });
}

fn expectFactor(f: ?factors.Factor, bytes: []const u8, folded: bool) !void {
    const got = f orelse {
        std.debug.print("expected factor {any}, got none\n", .{bytes});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualSlices(u8, bytes, got.bytes);
    try testing.expectEqual(folded, got.case_folded);
}

test "factors: foo(bar|baz)qux requires foo and qux" {
    var f = (try get("foo(bar|baz)qux", .{}, 3)).?;
    defer f.deinit(testing.allocator);
    // The prefix extends through what both branches share.
    try expectFactor(f.prefix, "fooba", false);
    try testing.expect(std.mem.startsWith(u8, f.prefix.?.bytes, "foo"));
    try expectFactor(f.suffix, "qux", false);
    try testing.expectEqual(@as(usize, 0), f.inner.len);
}

test "factors: (a|b)* reports nothing" {
    try testing.expectEqual(@as(?factors.Factors, null), try get("(a|b)*", .{}, 1));
    try testing.expectEqual(@as(?factors.Factors, null), try get("a*", .{}, 1));
    try testing.expectEqual(@as(?factors.Factors, null), try get(".+", .{}, 1));
    try testing.expectEqual(@as(?factors.Factors, null), try get("\\d{3}-\\d{4}", .{}, 2));
}

test "factors: below the minimum length there is nothing" {
    try testing.expectEqual(@as(?factors.Factors, null), try get("ab", .{}, 3));
    var f = (try get("ab", .{}, 2)).?;
    defer f.deinit(testing.allocator);
    try expectFactor(f.prefix, "ab", false);
    try expectFactor(f.suffix, "ab", false);
}

test "factors: inner factors across unknown parts" {
    var f = (try get("\\d+user=[a-z]+;admin\\w*", .{}, 3)).?;
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(?factors.Factor, null), f.prefix);
    try testing.expectEqual(@as(?factors.Factor, null), f.suffix);
    try testing.expectEqual(@as(usize, 2), f.inner.len);
    try expectFactor(f.inner[0], ";admin", false);
    try expectFactor(f.inner[1], "user=", false);
}

test "factors: optional parts and alternation" {
    {
        // An optional part breaks the literal run.
        var f = (try get("colou?r", .{}, 3)).?;
        defer f.deinit(testing.allocator);
        try expectFactor(f.prefix, "colo", false);
        try testing.expectEqual(@as(?factors.Factor, null), f.suffix);
    }
    {
        var f = (try get("(?:GET|POST) /admin", .{}, 3)).?;
        defer f.deinit(testing.allocator);
        try testing.expectEqual(@as(?factors.Factor, null), f.prefix);
        try expectFactor(f.suffix, "T /admin", false);
    }
    {
        // Branches with nothing in common give nothing.
        try testing.expectEqual(@as(?factors.Factors, null), try get("cat|dog", .{}, 2));
        var f = (try get("x(?:cat|dog)y", .{}, 1)).?;
        defer f.deinit(testing.allocator);
        try expectFactor(f.prefix, "x", false);
        try expectFactor(f.suffix, "y", false);
    }
    {
        // Identical branches stay exact.
        var f = (try get("(?:abc|abc)def", .{}, 3)).?;
        defer f.deinit(testing.allocator);
        try expectFactor(f.prefix, "abcdef", false);
    }
}

test "factors: repetition" {
    {
        var f = (try get("(?:ab){3}", .{}, 3)).?;
        defer f.deinit(testing.allocator);
        try expectFactor(f.prefix, "ababab", false);
        try expectFactor(f.suffix, "ababab", false);
    }
    {
        var f = (try get("x(?:ab){2,5}y", .{}, 3)).?;
        defer f.deinit(testing.allocator);
        try expectFactor(f.prefix, "xabab", false);
        try expectFactor(f.suffix, "ababy", false);
    }
    {
        var f = (try get("(?:abc)+", .{}, 3)).?;
        defer f.deinit(testing.allocator);
        try expectFactor(f.prefix, "abc", false);
        try expectFactor(f.suffix, "abc", false);
    }
    {
        // Two or more copies join one copy's end to the next one's start.
        var f = (try get("(?:a\\d+bc){2}", .{}, 3)).?;
        defer f.deinit(testing.allocator);
        try testing.expectEqual(@as(?factors.Factor, null), f.prefix);
        try testing.expectEqual(@as(?factors.Factor, null), f.suffix); // "bc" is short
        try testing.expectEqual(@as(usize, 1), f.inner.len);
        try expectFactor(f.inner[0], "bca", false);
    }
    try testing.expectEqual(@as(?factors.Factors, null), try get("(?:abc){0,3}", .{}, 1));
}

test "factors: case folding" {
    {
        var f = (try get("HeLLo world", .{ .case_insensitive = true }, 3)).?;
        defer f.deinit(testing.allocator);
        try expectFactor(f.prefix, "hello world", true);
    }
    {
        // Only the scoped part folds, which makes the joined factor folded.
        var f = (try get("ab(?i:CD)ef", .{}, 3)).?;
        defer f.deinit(testing.allocator);
        try expectFactor(f.prefix, "abcdef", true);
    }
    {
        // A class of both cases of one letter is a folded literal.
        var f = (try get("[Ss]elect", .{}, 3)).?;
        defer f.deinit(testing.allocator);
        try expectFactor(f.prefix, "select", true);
    }
    {
        // Folding leaves digits and punctuation alone.
        var f = (try get("id=42", .{ .case_insensitive = true }, 3)).?;
        defer f.deinit(testing.allocator);
        try expectFactor(f.prefix, "id=42", true);
    }
}

test "factors: bytes mode reports raw bytes" {
    var f = (try get("\\x80\\xff\\x00MZ[\\x90]", .{ .bytes = true }, 3)).?;
    defer f.deinit(testing.allocator);
    try expectFactor(f.prefix, "\x80\xff\x00MZ\x90", false);
    // UTF-8 mode encodes the same escapes as code points.
    var u = (try get("\\x80\\xff", .{}, 3)).?;
    defer u.deinit(testing.allocator);
    try expectFactor(u.prefix, "\xc2\x80\xc3\xbf", false);
    // Byte-mode folding is ASCII only: high bytes are left exact.
    var ci = (try get("\\xe9tat", .{ .bytes = true, .case_insensitive = true }, 3)).?;
    defer ci.deinit(testing.allocator);
    try expectFactor(ci.prefix, "\xe9tat", true);
}

test "factors: anchors and lookaround add nothing and break nothing" {
    var f = (try get("^\\bfoo(?=bar)baz$", .{}, 3)).?;
    defer f.deinit(testing.allocator);
    try expectFactor(f.prefix, "foobaz", false);
    try expectFactor(f.suffix, "foobaz", false);
}

test "factors: Regex.requiredFactors and long literal runs" {
    var re = try Regex.compile(testing.allocator, "\\w+@example\\.com");
    defer re.deinit();
    var f = (try re.requiredFactors(testing.allocator, .{})).?;
    defer f.deinit(testing.allocator);
    try expectFactor(f.suffix, "@example.com", false);

    // A literal longer than the tracked length is capped at both ends.
    const long = try testing.allocator.alloc(u8, 2_000);
    defer testing.allocator.free(long);
    @memset(long, 'q');
    var g = (try get(long, .{}, 3)).?;
    defer g.deinit(testing.allocator);
    try testing.expectEqual(factors.max_factor_len, g.prefix.?.bytes.len);
    try testing.expectEqual(factors.max_factor_len, g.suffix.?.bytes.len);
}

// Soundness: for random patterns, every match the engine finds contains the
// reported factors where they say.

fn containsFactor(text: []const u8, f: factors.Factor) bool {
    if (!f.case_folded) return std.mem.indexOf(u8, text, f.bytes) != null;
    if (f.bytes.len > text.len) return false;
    var i: usize = 0;
    while (i + f.bytes.len <= text.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(text[i..][0..f.bytes.len], f.bytes)) return true;
    }
    return false;
}

fn startsWithFactor(text: []const u8, f: factors.Factor) bool {
    if (f.bytes.len > text.len) return false;
    if (f.case_folded) return std.ascii.eqlIgnoreCase(text[0..f.bytes.len], f.bytes);
    return std.mem.eql(u8, text[0..f.bytes.len], f.bytes);
}

fn endsWithFactor(text: []const u8, f: factors.Factor) bool {
    if (f.bytes.len > text.len) return false;
    const tail = text[text.len - f.bytes.len ..];
    if (f.case_folded) return std.ascii.eqlIgnoreCase(tail, f.bytes);
    return std.mem.eql(u8, tail, f.bytes);
}

fn append(buf: []u8, len: *usize, text: []const u8) void {
    if (len.* + text.len > buf.len) return;
    @memcpy(buf[len.*..][0..text.len], text);
    len.* += text.len;
}

fn genPattern(random: std.Random, buf: []u8, len: *usize, depth: usize) void {
    const atoms = [_][]const u8{ "a", "b", "c", "ab", "abc", "ba", "[ab]", "[Aa]", "x", ".", "\\w", "^", "$", "\\b" };
    const quants = [_][]const u8{ "", "", "", "", "*", "+", "?", "{2}", "{1,2}" };
    const n = random.intRangeAtMost(usize, 1, 5);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (depth < 2 and random.uintLessThan(u8, 6) == 0) {
            append(buf, len, if (random.boolean()) "(?:" else "(?i:");
            genPattern(random, buf, len, depth + 1);
            if (random.boolean()) {
                append(buf, len, "|");
                genPattern(random, buf, len, depth + 1);
            }
            append(buf, len, ")");
        } else {
            append(buf, len, atoms[random.uintLessThan(usize, atoms.len)]);
        }
        append(buf, len, quants[random.uintLessThan(usize, quants.len)]);
    }
}

test "factors: every match contains the reported factors" {
    var prng = std.Random.DefaultPrng.init(0xFAC7);
    const random = prng.random();
    const alphabet = "aabbcxAB ";
    var checked: usize = 0;
    var iteration: usize = 0;
    while (iteration < 1500) : (iteration += 1) {
        var pattern: [96]u8 = undefined;
        var plen: usize = 0;
        genPattern(random, &pattern, &plen, 0);
        const flags: CompileFlags = .{ .case_insensitive = random.uintLessThan(u8, 4) == 0, .bytes = random.boolean() };
        var re = Regex.compileWithFlags(testing.allocator, pattern[0..plen], flags) catch continue;
        defer re.deinit();
        var f = (try re.requiredFactors(testing.allocator, .{ .min_len = 1 })) orelse continue;
        defer f.deinit(testing.allocator);

        var trial: usize = 0;
        while (trial < 12) : (trial += 1) {
            var input: [24]u8 = undefined;
            const n = random.uintAtMost(usize, input.len);
            for (input[0..n]) |*c| c.* = alphabet[random.uintLessThan(usize, alphabet.len)];
            const found = (re.find(input[0..n]) catch continue) orelse continue;
            var m = found;
            defer m.deinit(testing.allocator);
            errdefer std.debug.print("pattern \"{s}\" flags {any} match \"{s}\"\n", .{ pattern[0..plen], flags, m.slice });
            if (f.prefix) |p| try testing.expect(startsWithFactor(m.slice, p));
            if (f.suffix) |s| try testing.expect(endsWithFactor(m.slice, s));
            for (f.inner) |inner| try testing.expect(containsFactor(m.slice, inner));
            checked += 1;
        }
    }
    try testing.expect(checked > 500);
}

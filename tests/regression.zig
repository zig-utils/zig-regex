const std = @import("std");
const builtin = @import("builtin");
const Regex = @import("regex").Regex;
const RegexError = @import("regex").RegexError;

// =============================================================================
// Regression tests for specific fixes applied to the codebase
// =============================================================================

// --- $0 replacement (full match) ---

test "regression: $0 replacement expands to full match" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\d+");
    defer regex.deinit();

    const result = try regex.replace(allocator, "abc 123 def", "[$0]");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("abc [123] def", result);
}

test "regression: $0 replacement with captures" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\w+)@(\\w+)");
    defer regex.deinit();

    const result = try regex.replace(allocator, "email: user@host ok", "match=$0,user=$1,host=$2");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("email: match=user@host,user=user,host=host ok", result);
}

test "regression: $0 in replaceAll" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\w+");
    defer regex.deinit();

    const result = try regex.replaceAll(allocator, "a b c", "[$0]");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("[a] [b] [c]", result);
}

// --- Case-insensitive backreference ---

test "regression: case-insensitive backreference" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compileWithFlags(allocator, "(\\w+) \\1", .{ .case_insensitive = true });
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("hello HELLO"));
    try std.testing.expect(try regex.isMatch("ABC abc"));
    try std.testing.expect(try regex.isMatch("Test Test"));
}

test "regression: case-sensitive backreference rejects case mismatch" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\w+) \\1");
    defer regex.deinit();

    try std.testing.expect(!try regex.isMatch("hello HELLO"));
    try std.testing.expect(try regex.isMatch("hello hello"));
}

// --- min > max quantifier rejection ---

test "regression: {10,5} is rejected as invalid" {
    const allocator = std.testing.allocator;
    const result = Regex.compile(allocator, "a{10,5}");
    try std.testing.expectError(RegexError.InvalidQuantifier, result);
}

test "regression: {5,3} is rejected" {
    const allocator = std.testing.allocator;
    const result = Regex.compile(allocator, "x{5,3}");
    try std.testing.expectError(RegexError.InvalidQuantifier, result);
}

test "regression: {3,3} is accepted (min == max)" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a{3,3}");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("aaa"));
    try std.testing.expect(!try regex.isMatch("aa"));
}

// --- {0,n} quantifier correctness ---

test "regression: {0,3} matches 0 to 3 occurrences" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^a{0,3}$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch(""));
    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("aa"));
    try std.testing.expect(try regex.isMatch("aaa"));
    try std.testing.expect(!try regex.isMatch("aaaa"));
}

test "regression: {0,1} is equivalent to ?" {
    const allocator = std.testing.allocator;
    var regex1 = try Regex.compile(allocator, "^ab{0,1}c$");
    defer regex1.deinit();
    var regex2 = try Regex.compile(allocator, "^ab?c$");
    defer regex2.deinit();

    const inputs = [_][]const u8{ "ac", "abc", "abbc", "" };
    for (inputs) |input| {
        try std.testing.expectEqual(try regex1.isMatch(input), try regex2.isMatch(input));
    }
}

test "regression: {0,0} matches empty only" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^a{0,0}b$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("b"));
    try std.testing.expect(!try regex.isMatch("ab"));
}

// --- Prefix optimization searches all positions ---

test "regression: prefix optimization finds match after false prefix start" {
    const allocator = std.testing.allocator;
    // Pattern with prefix "ab" - but first "ab" at position 0 doesn't complete the full match
    var regex = try Regex.compile(allocator, "abc\\d+");
    defer regex.deinit();

    // "ab" appears at position 0, but "abc" + digits is only at position 5
    if (try regex.find("ab   abc123 end")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("abc123", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

// --- Step counter reset per position ---

test "regression: backtrack step counter resets between positions" {
    const allocator = std.testing.allocator;
    // This pattern uses backtracking via backreference.
    var regex = try Regex.compile(allocator, "(\\w+) \\1");
    defer regex.deinit();

    // Verify basic backreference works
    try std.testing.expect(try regex.isMatch("hello hello"));

    // Match appears after some non-matching prefix
    if (try regex.find("abc def hello hello xyz")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("hello hello", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

// --- deinit safety ---

test "regression: deinit on regex that was never used" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "test");
    regex.deinit();
    // Should not crash - just testing that deinit works without any find/match calls
}

test "regression: double pattern compile and deinit" {
    const allocator = std.testing.allocator;
    {
        var regex = try Regex.compile(allocator, "abc");
        defer regex.deinit();
        try std.testing.expect(try regex.isMatch("abc"));
    }
    {
        var regex = try Regex.compile(allocator, "def");
        defer regex.deinit();
        try std.testing.expect(try regex.isMatch("def"));
    }
}

// --- findAll quadratic blowup (issue: "findAll is O(n^2), not linear") ---
//
// Before the fix, matchAt kept iterating to input.len after all threads died,
// and findAll restarted matchAt per match, so a scan with m matches over n
// bytes cost ~O(n*m). The guard below doubles the input and checks the time
// ratio: a linear scan stays near ~2x, the pre-fix quadratic path was ~4x and
// growing. A ratio (not an absolute bound) keeps this independent of build
// mode (Debug vs ReleaseFast) and machine speed.

fn monotonicNs() u64 {
    const clk: std.c.clockid_t = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => .UPTIME_RAW,
        else => .MONOTONIC,
    };
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(clk, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

const FindAllScan = struct { ns: u64, count: usize, first_start: usize, last_end: usize };

fn timeFindAll(allocator: std.mem.Allocator, regex: *const Regex, n: usize) !FindAllScan {
    const buf = try allocator.alloc(u8, n);
    defer allocator.free(buf);
    @memset(buf, '.');
    var i: usize = 0;
    while (i + 8 <= n) : (i += 64) @memcpy(buf[i .. i + 8], "Sherlock");

    // Warm up (allocator caches, code paths), then take the min of a few runs
    // to suppress scheduler noise without depending on absolute timing.
    {
        const warm = try regex.findAll(allocator, buf);
        for (warm) |*m| {
            var mm = m.*;
            mm.deinit(allocator);
        }
        allocator.free(warm);
    }

    var best: u64 = std.math.maxInt(u64);
    var count: usize = 0;
    var first_start: usize = 0;
    var last_end: usize = 0;
    var rep: usize = 0;
    while (rep < 3) : (rep += 1) {
        const t0 = monotonicNs();
        const matches = try regex.findAll(allocator, buf);
        const dt = monotonicNs() - t0;
        count = matches.len;
        if (matches.len > 0) {
            first_start = matches[0].start;
            last_end = matches[matches.len - 1].end;
        }
        for (matches) |*m| {
            var mm = m.*;
            mm.deinit(allocator);
        }
        allocator.free(matches);
        if (dt < best) best = dt;
    }
    return .{ .ns = best, .count = count, .first_start = first_start, .last_end = last_end };
}

test "regression: findAll scales linearly (no O(n^2) blowup)" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compile(allocator, "Sherlock");
    defer regex.deinit();

    const n1: usize = 16 * 1024;
    const n2: usize = 32 * 1024; // exactly 2x

    const r1 = try timeFindAll(allocator, &regex, n1);
    const r2 = try timeFindAll(allocator, &regex, n2);

    // Correctness: a "Sherlock" every 64 bytes, found at the right places.
    try std.testing.expectEqual(n1 / 64, r1.count);
    try std.testing.expectEqual(n2 / 64, r2.count);
    try std.testing.expectEqual(@as(usize, 0), r2.first_start);
    try std.testing.expectEqual(((n2 - 8) / 64) * 64 + 8, r2.last_end);

    // Linearity guard: doubling input must not more-than-triple the time.
    // Linear ≈ 2x; the pre-fix quadratic path was ≈ 4x (and worsening).
    try std.testing.expect(r1.ns > 0);
    try std.testing.expect(r2.ns * 10 < r1.ns * 30); // r2/r1 < 3.0
}

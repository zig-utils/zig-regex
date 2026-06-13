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

test "regression: unmatched named backreference matches empty" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?:(?:(?<x>a)|(?<x>b)|c)\\k<x>){2}");
    defer regex.deinit();

    var match = (try regex.find("aac")).?;
    defer match.deinit(allocator);
    try std.testing.expectEqualStrings("aac", match.slice);
    try std.testing.expect(regex.getNamedCapture(&match, "x") == null);
}

test "regression: ambiguous adjacent quantified captures use ECMAScript partition" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compile(allocator, "(b+)(b*)");
    defer regex.deinit();

    if (try regex.find("abbbbbbbc")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);

        try std.testing.expectEqualStrings("bbbbbbb", match.slice);
        try std.testing.expectEqual(@as(usize, 2), match.captures.len);
        try std.testing.expectEqualStrings("bbbbbbb", match.captures[0]);
        try std.testing.expectEqualStrings("", match.captures[1]);
        try std.testing.expect(match.captures_present[0]);
        try std.testing.expect(match.captures_present[1]);
    } else {
        return error.TestExpectedMatch;
    }

    var suffix_regex = try Regex.compile(allocator, "(b+)(b*)c");
    defer suffix_regex.deinit();

    if (try suffix_regex.find("abbbbbbbc")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);

        try std.testing.expectEqualStrings("bbbbbbbc", match.slice);
        try std.testing.expectEqualStrings("bbbbbbb", match.captures[0]);
        try std.testing.expectEqualStrings("", match.captures[1]);
    } else {
        return error.TestExpectedMatch;
    }
}

test "regression: nullable quantified iteration can continue with progress" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compile(allocator, "(a?b??)*");
    defer regex.deinit();

    if (try regex.find("ab")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);

        try std.testing.expectEqualStrings("ab", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "regression: required zero-width quantified lookahead preserves captures" {
    const allocator = std.testing.allocator;

    var required = try Regex.compile(allocator, "(?:(?=(abc))){1,1}a");
    defer required.deinit();
    if (try required.find("abc")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("a", match.slice);
        try std.testing.expectEqualStrings("abc", match.captures[0]);
        try std.testing.expect(match.captures_present[0]);
    } else {
        return error.TestExpectedMatch;
    }

    var optional = try Regex.compile(allocator, "(?:(?=(abc)))?a");
    defer optional.deinit();
    if (try optional.find("abc")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("a", match.slice);
        try std.testing.expect(!match.captures_present[0]);
    } else {
        return error.TestExpectedMatch;
    }
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

test "regression: max-safe quantifier counts compile and fail short inputs" {
    const allocator = std.testing.allocator;

    var exact = try Regex.compile(allocator, "b{9007199254740991}");
    defer exact.deinit();
    try std.testing.expect(!try exact.isMatch(""));

    var unbounded = try Regex.compile(allocator, "b{9007199254740991,}?");
    defer unbounded.deinit();
    try std.testing.expect(!try unbounded.isMatch("a"));

    var bounded = try Regex.compile(allocator, "b{9007199254740991,9007199254740991}");
    defer bounded.deinit();
    try std.testing.expect(!try bounded.isMatch("b"));
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

test "regression: backreference backtracks captured quantifier" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^(a+)\\1*,\\1+$");
    defer regex.deinit();

    const match = try regex.find("aaaaaaaaaa,aaaaaaaaaaaaaaa") orelse return error.TestExpectedMatch;
    var mut_match = match;
    defer mut_match.deinit(allocator);

    try std.testing.expectEqualStrings("aaaaaaaaaa,aaaaaaaaaaaaaaa", match.slice);
    try std.testing.expectEqual(@as(usize, 1), match.captures.len);
    try std.testing.expectEqualStrings("aaaaa", match.captures[0]);
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

test "regression: anchored repeated class matches large UTF-8 input quickly" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compile(allocator, "^\\D+$");
    defer regex.deinit();

    var buf = try std.ArrayList(u8).initCapacity(allocator, 64 * 1024);
    defer buf.deinit(allocator);
    var i: usize = 0;
    while (i < 16 * 1024) : (i += 1) try buf.appendSlice(allocator, "é");

    try std.testing.expect(try regex.isMatch(buf.items));
    try std.testing.expect((try regex.find(buf.items)) != null);

    try buf.append(allocator, '5');
    try std.testing.expect(!try regex.isMatch(buf.items));
    try std.testing.expect((try regex.find(buf.items)) == null);
}

test "regression: anchored repeated Unicode property scans large UTF-8 input quickly" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compileWithFlags(allocator, "^\\p{Script_Extensions=Han}+$", .{ .unicode = true });
    defer regex.deinit();

    var buf = try std.ArrayList(u8).initCapacity(allocator, 64 * 1024);
    defer buf.deinit(allocator);
    var i: usize = 0;
    while (i < 16 * 1024) : (i += 1) try buf.appendSlice(allocator, "一");

    try std.testing.expect(try regex.isMatch(buf.items));
    const m = (try regex.find(buf.items)).?;
    try std.testing.expectEqual(@as(usize, 0), m.start);
    try std.testing.expectEqual(buf.items.len, m.end);

    try buf.append(allocator, 'a');
    try std.testing.expect(!try regex.isMatch(buf.items));
    try std.testing.expect((try regex.find(buf.items)) == null);
}

fn appendScalarUtf8(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, cp: u21) !void {
    var tmp: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(cp, &tmp);
    try buf.appendSlice(allocator, tmp[0..len]);
}

fn isCypriotScriptExtensionTestPoint(cp: u21) bool {
    return (cp >= 0x010100 and cp <= 0x010102) or
        (cp >= 0x010107 and cp <= 0x010133) or
        (cp >= 0x010137 and cp <= 0x01013F) or
        (cp >= 0x010800 and cp <= 0x010805) or
        cp == 0x010808 or
        (cp >= 0x01080A and cp <= 0x010835) or
        (cp >= 0x010837 and cp <= 0x010838) or
        cp == 0x01083C or
        cp == 0x01083F;
}

test "regression: Script_Extensions complement scans generated Cypriot gaps quickly" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compileWithFlags(allocator, "^\\P{Script_Extensions=Cypriot}+$", .{ .unicode = true });
    defer regex.deinit();

    var buf = try std.ArrayList(u8).initCapacity(allocator, 512 * 1024);
    defer buf.deinit(allocator);

    var cp: u21 = 0;
    while (cp <= 0x020000) : (cp += 1) {
        if (cp >= 0x00D800 and cp <= 0x00DFFF) continue;
        if (isCypriotScriptExtensionTestPoint(cp)) continue;
        try appendScalarUtf8(&buf, allocator, cp);
    }

    try std.testing.expect(try regex.isMatch(buf.items));
    try appendScalarUtf8(&buf, allocator, 0x010100);
    try std.testing.expect(!try regex.isMatch(buf.items));
}

// --- `\s` shorthand lowered to the byte engine (issue #10) ---
//
// `\s`/`\S` are code-point class sets (ECMAScript whitespace spans Unicode, not
// just ASCII), so they used to force the whole pattern onto the backtracking
// engine. A pattern such as `\w+\s+\w+` therefore fell off the lazy-DFA fast
// path and ran ~10-30x slower the instant a `\s` appeared. They now lower to a
// UTF-8 byte automaton; these guard correctness (incl. multi-byte whitespace)
// and that the pattern stays on the fast engine.

test "regression: `\\w+\\s+\\w+` matches like the reference engine" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\w+\\s+\\w+");
    defer regex.deinit();

    const matches = try regex.findAll(allocator, "foo bar  baz\tqux");
    defer {
        for (matches) |*m| {
            var mm = m.*;
            mm.deinit(allocator);
        }
        allocator.free(matches);
    }
    // Greedy `\s+` joins each adjacent word pair: "foo bar", "baz\tqux".
    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqualStrings("foo bar", matches[0].slice);
    try std.testing.expectEqualStrings("baz\tqux", matches[1].slice);
}

test "regression: `\\s` matches multi-byte Unicode whitespace" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a\\sb");
    defer regex.deinit();

    // U+00A0 NBSP (C2 A0), U+2003 EM SPACE (E2 80 83), U+3000 (E3 80 80).
    try std.testing.expect(try regex.isMatch("a\u{00A0}b"));
    try std.testing.expect(try regex.isMatch("a\u{2003}b"));
    try std.testing.expect(try regex.isMatch("a\u{3000}b"));
    try std.testing.expect(try regex.isMatch("a b"));
    try std.testing.expect(!try regex.isMatch("axb"));
    // A bare continuation byte must not be mistaken for whitespace.
    try std.testing.expect(!try regex.isMatch("a\xa0b"));
}

test "regression: `\\S` excludes whitespace, includes non-ASCII" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\S+");
    defer regex.deinit();

    const m = (try regex.find("  café  ")).?;
    try std.testing.expectEqualStrings("café", m.slice);
}

test "regression: leading optional `\\s*` keeps the prefilter sound" {
    const allocator = std.testing.allocator;
    // `\s*,\s*` can begin with whitespace OR the comma; the first-byte prefilter
    // must include both, or the leftmost match (the space) is skipped.
    var regex = try Regex.compile(allocator, "\\s*,\\s*");
    defer regex.deinit();

    const parts = try regex.split(allocator, "a , b , c");
    defer allocator.free(parts);
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualStrings("a", parts[0]);
    try std.testing.expectEqualStrings("b", parts[1]);
    try std.testing.expectEqualStrings("c", parts[2]);
}

test "regression: `\\w+\\s+\\w+` stays off the quadratic backtracker" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\w+\\s+\\w+");
    defer regex.deinit();

    // Build "wd wd wd ..." — dense matches; the old backtracking path was
    // ~O(n*m). Doubling the input must not more-than-triple the time.
    const make = struct {
        fn buf(a: std.mem.Allocator, words: usize) ![]u8 {
            var list = try std.ArrayList(u8).initCapacity(a, words * 3);
            errdefer list.deinit(a);
            var i: usize = 0;
            while (i < words) : (i += 1) {
                if (i != 0) try list.append(a, ' ');
                try list.appendSlice(a, "wd");
            }
            return list.toOwnedSlice(a);
        }
    };

    const time = struct {
        fn run(re: *const Regex, b: []const u8) !u64 {
            _ = try re.count(b); // warm up
            var best: u64 = std.math.maxInt(u64);
            var rep: usize = 0;
            while (rep < 3) : (rep += 1) {
                const t0 = monotonicNs();
                const c = try re.count(b);
                const dt = monotonicNs() - t0;
                std.mem.doNotOptimizeAway(c);
                if (dt < best) best = dt;
            }
            return best;
        }
    };

    const b1 = try make.buf(allocator, 20_000);
    defer allocator.free(b1);
    const b2 = try make.buf(allocator, 40_000); // exactly 2x
    defer allocator.free(b2);

    try std.testing.expectEqual(@as(usize, 10_000), try regex.count(b1));
    try std.testing.expectEqual(@as(usize, 20_000), try regex.count(b2));

    const t1 = try time.run(&regex, b1);
    const t2 = try time.run(&regex, b2);
    try std.testing.expect(t1 > 0);
    try std.testing.expect(t2 * 10 < t1 * 30); // t2/t1 < 3.0 (linear, not quadratic)
}

test "regression: prefilter hints are exposed to callers (issue #10)" {
    const allocator = std.testing.allocator;

    {
        var re = try Regex.compile(allocator, "Sherlock Holmes");
        defer re.deinit();
        try std.testing.expectEqualStrings("Sherlock Holmes", re.literalPrefix().?);
        try std.testing.expectEqualStrings("Sherlock Holmes", re.requiredLiteral().?);
        try std.testing.expectEqual(@as(?u8, 'S'), re.firstByte());
    }
    {
        // `foo\d+` has a required literal but no single first byte set beyond 'f'.
        var re = try Regex.compile(allocator, "foo\\d+");
        defer re.deinit();
        try std.testing.expectEqualStrings("foo", re.requiredLiteral().?);
        const fb = re.firstBytes().?;
        try std.testing.expect(fb['f']);
        try std.testing.expect(!fb['g']);
    }
}

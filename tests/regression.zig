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

test "regression: `\\w+\\s+\\w+` stays on the byte engine (not the backtracker)" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\w+\\s+\\w+");
    defer regex.deinit();

    // The whole point of the `\s` lowering: this must run on the Thompson/DFA
    // byte engine, not collapse onto the O(n*m) backtracker the moment a `\s`
    // appears. Asserting the engine is a stable structural invariant (no flaky
    // wall-clock ratio), and a large dense input confirms it stays linear.
    try std.testing.expect(regex.engine_type == .thompson_nfa);

    var list = try std.ArrayList(u8).initCapacity(allocator, 120_000);
    defer list.deinit(allocator);
    var i: usize = 0;
    while (i < 40_000) : (i += 1) {
        if (i != 0) try list.append(allocator, ' ');
        try list.appendSlice(allocator, "wd");
    }
    try std.testing.expectEqual(@as(usize, 20_000), try regex.count(list.items));
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

// --- `.` lowered to a UTF-8 code-point automaton (off the backtracker) ---
//
// `.` matches one code point excluding line terminators (`\n \r    `),
// and excludes astral code points unless the `u` flag is set. It used to force
// the whole pattern onto the backtracking engine; it now lowers to a UTF-8 byte
// automaton (compiler.compileAny), so `//.*`, `a.c`, `.*` run on the fast DFA.
// These guard the boundary semantics so the speedup can't silently change them.

test "regression: `.` excludes line terminators, matches everything else" {
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, "a.b");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("axb"));
    try std.testing.expect(try re.isMatch("a b"));
    try std.testing.expect(try re.isMatch("a\tb"));
    try std.testing.expect(try re.isMatch("a\u{00E9}b")); // é (one code point)
    try std.testing.expect(!try re.isMatch("a\nb"));
    try std.testing.expect(!try re.isMatch("a\rb"));
    try std.testing.expect(!try re.isMatch("a\u{2028}b")); // LINE SEPARATOR
}

test "regression: `.*` stops at a newline; dot_all crosses it" {
    const allocator = std.testing.allocator;

    var normal = try Regex.compile(allocator, "a.*");
    defer normal.deinit();
    const m1 = (try normal.find("axy\nz")).?;
    try std.testing.expectEqualStrings("axy", m1.slice);

    var dotall = try Regex.compileWithFlags(allocator, "a.*", .{ .dot_all = true });
    defer dotall.deinit();
    const m2 = (try dotall.find("axy\nz")).?;
    try std.testing.expectEqualStrings("axy\nz", m2.slice);
}

test "regression: `//.*` stays on the byte engine (not the backtracker)" {
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, "//.*");
    defer re.deinit();

    // `.` used to force the backtracking engine (the 44x-slower case in issue
    // #10); it now lowers to a byte automaton. Assert the engine (a stable
    // structural invariant, not a flaky timing ratio); a large input confirms
    // it counts correctly and finishes quickly on the linear path.
    try std.testing.expect(re.engine_type == .thompson_nfa);

    var list = try std.ArrayList(u8).initCapacity(allocator, 800_000);
    defer list.deinit(allocator);
    var i: usize = 0;
    while (i < 40_000) : (i += 1) try list.appendSlice(allocator, "x = 1; // note here\n");
    try std.testing.expectEqual(@as(usize, 40_000), try re.count(list.items));
}

test "regression: literal alternation preserves source order" {
    const allocator = std.testing.allocator;

    var short_first = try Regex.compile(allocator, "a|ab");
    defer short_first.deinit();
    const short_match = (try short_first.find("abc")).?;
    try std.testing.expectEqualStrings("a", short_match.slice);

    var long_first = try Regex.compile(allocator, "ab|a");
    defer long_first.deinit();
    const long_match = (try long_first.find("abc")).?;
    try std.testing.expectEqualStrings("ab", long_match.slice);
}

// --- `\bfn\b`-style bounded-literal fast path ---
//
// A fixed literal wrapped only in zero-width assertions (`\b`, `^`, `$`, `\A`,
// `\z`, `\B`) is the whole match, so it's found with a SIMD literal scan plus an
// inline assertion check instead of running the NFA at every candidate byte
// (`\bfn\b` was ~14x slower than ripgrep's engine). These lock the boundary
// semantics, which must stay identical to the NFA's anchor evaluation.

test "regression: `\\bfn\\b` matches only whole words" {
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, "\\bfn\\b");
    defer re.deinit();

    try std.testing.expectEqual(@as(usize, 2), try re.count("fn fnx xfn fn end"));
    try std.testing.expect(try re.isMatch("a fn b"));
    try std.testing.expect(!try re.isMatch("fnfn"));
    try std.testing.expect(!try re.isMatch("define"));
    const m = (try re.find("  fn  ")).?;
    try std.testing.expectEqual(@as(usize, 2), m.start);
    try std.testing.expectEqualStrings("fn", m.slice);
}

test "regression: bounded-literal half boundaries and `\\B`" {
    const allocator = std.testing.allocator;

    var pre = try Regex.compile(allocator, "\\bcat");
    defer pre.deinit();
    try std.testing.expectEqual(@as(usize, 2), try pre.count("cat scatter category")); // cat, cat(egory)

    var post = try Regex.compile(allocator, "cat\\b");
    defer post.deinit();
    try std.testing.expectEqual(@as(usize, 2), try post.count("cat bobcat dog")); // cat, (bob)cat

    var nb = try Regex.compile(allocator, "\\Bcat");
    defer nb.deinit();
    try std.testing.expectEqual(@as(usize, 1), try nb.count("cat bobcat")); // only (bob)cat
}

test "regression: bounded literal honors anchors and multiline" {
    const allocator = std.testing.allocator;

    var anchored = try Regex.compile(allocator, "^fn$");
    defer anchored.deinit();
    try std.testing.expect(try anchored.isMatch("fn"));
    try std.testing.expect(!try anchored.isMatch("fn\n")); // non-multiline `$` = end of text
    try std.testing.expect(!try anchored.isMatch(" fn"));

    var ml = try Regex.compileWithFlags(allocator, "^fn$", .{ .multiline = true });
    defer ml.deinit();
    try std.testing.expectEqual(@as(usize, 2), try ml.count("fn\nx\nfn"));
}

test "regression: optional capture participates before overlapping greedy capture" {
    const allocator = std.testing.allocator;

    var anchored = try Regex.compile(allocator, "^(A)?(A.*)$");
    defer anchored.deinit();
    if (try anchored.find("AAA")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("AAA", match.slice);
        try std.testing.expect(match.captures_present[0]);
        try std.testing.expectEqualStrings("A", match.captures[0]);
        try std.testing.expectEqualStrings("AA", match.captures[1]);
    } else {
        return error.TestExpectedMatch;
    }

    var unanchored = try Regex.compile(allocator, "(A)?(A.*)");
    defer unanchored.deinit();
    if (try unanchored.find("zxcasd;fl\\  ^AAaaAAaaaf;lrlrzs")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 13), match.start);
        try std.testing.expectEqualStrings("AAaaAAaaaf;lrlrzs", match.slice);
        try std.testing.expect(match.captures_present[0]);
        try std.testing.expectEqualStrings("A", match.captures[0]);
        try std.testing.expectEqualStrings("AaaAAaaaf;lrlrzs", match.captures[1]);
    } else {
        return error.TestExpectedMatch;
    }
}

test "regression: repeated capture can backtrack before trailing class" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compile(allocator, "^([a-z]+)*[a-z]$");
    defer regex.deinit();
    if (try regex.find("ab")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("ab", match.slice);
        try std.testing.expectEqualStrings("a", match.captures[0]);
    } else {
        return error.TestExpectedMatch;
    }
}

test "regression: unicode dot captures full code points in one-pass-shaped pattern" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compileWithFlags(allocator, "b(.).(.).", .{ .unicode = true });
    defer regex.deinit();
    if (try regex.find("ab\u{1D306}defg")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), match.start);
        try std.testing.expectEqualStrings("b\u{1D306}def", match.slice);
        try std.testing.expectEqualStrings("\u{1D306}", match.captures[0]);
        try std.testing.expectEqualStrings("e", match.captures[1]);
    } else {
        return error.TestExpectedMatch;
    }
}

test "regression: duplicate named captures backtrack alternatives before named backref" {
    const allocator = std.testing.allocator;

    var pair = try Regex.compile(allocator, "(?:(?<x>a)|(?<x>b))\\k<x>");
    defer pair.deinit();
    if (try pair.find("aa")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
    } else return error.TestExpectedMatch;
    if (try pair.find("bb")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
    } else return error.TestExpectedMatch;
    try std.testing.expect((try pair.find("abab")) == null);
    try std.testing.expect((try pair.find("cdef")) == null);

    var repeated = try Regex.compile(allocator, "(?:(?:(?<x>a)|(?<x>b))\\k<x>){2}");
    defer repeated.deinit();
    if (try repeated.find("aabb")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("aabb", match.slice);
        try std.testing.expect(!match.captures_present[0]);
        try std.testing.expect(match.captures_present[1]);
        try std.testing.expectEqualStrings("b", match.captures[1]);
    } else {
        return error.TestExpectedMatch;
    }
    try std.testing.expect((try repeated.find("abab")) == null);
}

test "regression: lookbehind evaluates captures in reverse direction" {
    const allocator = std.testing.allocator;

    var fixed = try Regex.compile(allocator, "(?<=(\\w){3})f");
    defer fixed.deinit();
    if (try fixed.find("abcdef")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("f", match.slice);
        try std.testing.expect(match.captures_present[0]);
        try std.testing.expectEqualStrings("c", match.captures[0]);
    } else return error.TestExpectedMatch;

    var greedy = try Regex.compile(allocator, "(?<=(?<a>\\w)+)f");
    defer greedy.deinit();
    if (try greedy.find("abcdef")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("f", match.slice);
        try std.testing.expectEqualStrings("a", greedy.getNamedCapture(&match, "a").?);
    } else return error.TestExpectedMatch;
}

test "regression: lookbehind backreferences can bind captures to their right" {
    const allocator = std.testing.allocator;

    var before_capture = try Regex.compileWithFlags(allocator, "(?<=\\1(\\w))d", .{ .case_insensitive = true });
    defer before_capture.deinit();
    if (try before_capture.find("abcCd")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("d", match.slice);
        try std.testing.expect(match.captures_present[0]);
        try std.testing.expectEqualStrings("C", match.captures[0]);
    } else return error.TestExpectedMatch;

    var mutual = try Regex.compile(allocator, "(?<=a(.\\2)b(\\1)).{4}");
    defer mutual.deinit();
    if (try mutual.find("aabcacbc")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("cacb", match.slice);
        try std.testing.expectEqualStrings("a", match.captures[0]);
        try std.testing.expectEqualStrings("", match.captures[1]);
    } else return error.TestExpectedMatch;
}

test "regression: negative lookbehind restores inner captures" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compile(allocator, "(?<!(?<a>\\D){3})f|f");
    defer regex.deinit();
    if (try regex.find("abcdef")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("f", match.slice);
        try std.testing.expect(regex.getNamedCapture(&match, "a") == null);
    } else return error.TestExpectedMatch;
}

test "regression: hex escapes above ascii match utf8 input" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compile(allocator, "\\xFF");
    defer regex.deinit();
    if (try regex.find("\u{00FF}")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("\u{00FF}", match.slice);
    } else return error.TestExpectedMatch;
}

test "regression: empty inline modifier arithmetic is rejected" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(RegexError.UnexpectedCharacter, Regex.compile(allocator, "(?-:a)"));
}

test "regression: repeated alternatives preserve source-order iterations" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compile(allocator, "(aa|aabaac|ba|b|c)*");
    defer regex.deinit();
    if (try regex.find("aabaac")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("aaba", match.slice);
        try std.testing.expect(match.captures_present[0]);
        try std.testing.expectEqualStrings("ba", match.captures[0]);
    } else return error.TestExpectedMatch;
}

test "regression: unicode surrogate escape pairs match astral input" {
    const allocator = std.testing.allocator;
    const flags = @import("regex").common.CompileFlags{ .unicode = true };

    var pair = try Regex.compileWithFlags(allocator, "\\uD834\\uDF06", flags);
    defer pair.deinit();
    try std.testing.expect(try pair.isMatch("\u{1D306}"));

    var codepoint = try Regex.compileWithFlags(allocator, "\\u{1D306}", flags);
    defer codepoint.deinit();
    try std.testing.expect(try codepoint.isMatch("\u{1D306}"));
}

test "regression: unicode ignore-case word characters include canonicalized ascii" {
    const allocator = std.testing.allocator;
    const flags = @import("regex").common.CompileFlags{ .unicode = true };

    var word = try Regex.compileWithFlags(allocator, "(?i:\\w)", flags);
    defer word.deinit();
    try std.testing.expect(try word.isMatch("\u{017F}"));
    try std.testing.expect(try word.isMatch("\u{212A}"));

    var non_word = try Regex.compileWithFlags(allocator, "(?i:\\W)", flags);
    defer non_word.deinit();
    try std.testing.expect(!try non_word.isMatch("\u{017F}"));
    try std.testing.expect(!try non_word.isMatch("\u{212A}"));

    var boundary = try Regex.compileWithFlags(allocator, "(?i:\\b)", flags);
    defer boundary.deinit();
    try std.testing.expect(try boundary.isMatch("\u{017F}"));
    try std.testing.expect(try boundary.isMatch("\u{212A}"));

    var non_boundary = try Regex.compileWithFlags(allocator, "(?i:Z\\B)", flags);
    defer non_boundary.deinit();
    try std.testing.expect(try non_boundary.isMatch("Z\u{017F}"));
    try std.testing.expect(try non_boundary.isMatch("Z\u{212A}"));

    var upper_prop = try Regex.compileWithFlags(allocator, "(?i:\\p{Lu})", flags);
    defer upper_prop.deinit();
    try std.testing.expect(try upper_prop.isMatch("A"));
    try std.testing.expect(try upper_prop.isMatch("a"));

    var not_upper_prop = try Regex.compileWithFlags(allocator, "(?i:\\P{Lu})", flags);
    defer not_upper_prop.deinit();
    try std.testing.expect(try not_upper_prop.isMatch("A"));
    try std.testing.expect(try not_upper_prop.isMatch("a"));
}

test "regression: unicode class ignore-case uses simple common folds" {
    const allocator = std.testing.allocator;
    const flags = @import("regex").common.CompileFlags{ .unicode = true, .case_insensitive = true };

    const cases = [_]struct {
        pattern: []const u8,
        input: []const u8,
    }{
        .{ .pattern = "[\\u0390]", .input = "\u{1FD3}" },
        .{ .pattern = "[\\u1FD3]", .input = "\u{0390}" },
        .{ .pattern = "[\\u03B0]", .input = "\u{1FE3}" },
        .{ .pattern = "[\\u1FE3]", .input = "\u{03B0}" },
        .{ .pattern = "[\\uFB05]", .input = "\u{FB06}" },
        .{ .pattern = "[\\uFB06]", .input = "\u{FB05}" },
    };
    for (cases) |case| {
        var regex = try Regex.compileWithFlags(allocator, case.pattern, flags);
        defer regex.deinit();
        try std.testing.expect(try regex.isMatch(case.input));
    }
}

test "regression: unicode set difference keeps string literals distinct from characters" {
    const allocator = std.testing.allocator;
    const flags = @import("regex").common.CompileFlags{ .unicode_sets = true };

    var regex = try Regex.compileWithFlags(allocator, "^[\\q{0|2|4|9\\uFE0F\\u20E3}--\\p{ASCII_Hex_Digit}]+$", flags);
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("9\u{FE0F}\u{20E3}"));
    try std.testing.expect(!try regex.isMatch("0"));
    try std.testing.expect(!try regex.isMatch("2"));
    try std.testing.expect(!try regex.isMatch("4"));
}

test "regression: unicode sets reject unescaped reserved punctuators" {
    const allocator = std.testing.allocator;
    const flags = @import("regex").common.CompileFlags{ .unicode_sets = true };

    const invalid = [_][]const u8{
        "[(]",
        "[)]",
        "[{]",
        "[}]",
        "[/]",
        "[-]",
        "[|]",
        "[&&]",
        "[!!]",
        "[##]",
        "[$$]",
        "[%%]",
        "[**]",
        "[++]",
        "[,,]",
        "[..]",
        "[::]",
        "[;;]",
        "[<<]",
        "[==]",
        "[>>]",
        "[??]",
        "[@@]",
        "[``]",
        "[~~]",
        "[^^^]",
        "[_^^]",
    };
    for (invalid) |pattern| {
        try std.testing.expectError(RegexError.UnexpectedCharacter, Regex.compileWithFlags(allocator, pattern, flags));
    }
}

test "regression: unicode sets reject complements containing strings" {
    const allocator = std.testing.allocator;
    const flags = @import("regex").common.CompileFlags{ .unicode_sets = true };

    try std.testing.expectError(
        RegexError.UnexpectedCharacter,
        Regex.compileWithFlags(allocator, "[^\\p{Emoji_Keycap_Sequence}]", flags),
    );
    try std.testing.expectError(
        RegexError.UnexpectedCharacter,
        Regex.compileWithFlags(allocator, "[^\\q{ab}]", flags),
    );
}

test "regression: unicode mode rejects restricted identity escapes" {
    const allocator = std.testing.allocator;
    const flags = @import("regex").common.CompileFlags{ .unicode = true };

    const invalid = [_][]const u8{
        "\\A",
        "\\z",
        "\\Z",
        "\\k",
        "[\\A]",
    };
    for (invalid) |pattern| {
        try std.testing.expectError(RegexError.InvalidEscapeSequence, Regex.compileWithFlags(allocator, pattern, flags));
    }
}

test "regression: unicode mode rejects quantified assertions" {
    const allocator = std.testing.allocator;
    const flags = @import("regex").common.CompileFlags{ .unicode = true };

    const invalid = [_][]const u8{
        "(?=.)*",
        "(?=.)+?",
        "(?=.){1,2}",
        "(?!.)?",
        "(?!.){1,}?",
    };
    for (invalid) |pattern| {
        try std.testing.expectError(RegexError.InvalidQuantifier, Regex.compileWithFlags(allocator, pattern, flags));
    }
}

test "regression: xml shallow parser delimiter pattern is not too complex" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compile(allocator, "[^\\]]*\\]([^\\]]+\\])*\\]+([^\\]>][^\\]]*\\]([^\\]]+\\])*\\]+)*>");
    defer regex.deinit();
    try std.testing.expect(try regex.isMatch("abc]]>"));

    var attrs = try Regex.compile(allocator, "[ \\n\\t\\r]+([A-Za-z_:]|[^\\x00-\\x7F])([A-Za-z0-9_:.-]|[^\\x00-\\x7F])*([ \\n\\t\\r]+(([A-Za-z_:]|[^\\x00-\\x7F])([A-Za-z0-9_:.-]|[^\\x00-\\x7F])*|\"[^\"]*\"|'[^']*'))*");
    defer attrs.deinit();
    try std.testing.expect(try attrs.isMatch(" name attr=\"value\""));

    var markup = try Regex.compile(allocator, "([^\\]\"'><]+|\"[^\"]*\"|'[^']*')*>");
    defer markup.deinit();
    try std.testing.expect(try markup.isMatch("name \"value\">"));
}

// --- two-byte memmem literal search (common first byte) ---
//
// Literal search picks a two-byte vectorized filter when the first byte is
// common (e.g. `fn` in a haystack full of `f`s). The decision is haystack-
// dependent, so exercise both strategies and the awkward boundaries (probe
// offsets, overlapping starts, repeated bytes) and confirm results match a
// naive scan.

test "regression: memmem literal search matches a naive scan" {
    const allocator = std.testing.allocator;

    const naive = struct {
        fn count(h: []const u8, n: []const u8) usize {
            var c: usize = 0;
            var i: usize = 0;
            while (i + n.len <= h.len) {
                if (std.mem.eql(u8, h[i .. i + n.len], n)) {
                    c += 1;
                    i += n.len;
                } else i += 1;
            }
            return c;
        }
    };
    const cases = [_]struct { pat: []const u8, hay: []const u8 }{
        .{ .pat = "fn", .hay = "fn if for fn self off fn" },
        .{ .pat = "ab", .hay = "ababab" }, // overlapping starts, non-overlapping count
        .{ .pat = "aa", .hay = "aaaa" }, // repeated byte → degenerate probes
        .{ .pat = "xyz", .hay = "xy xz xyz xyzz" },
        .{ .pat = "the", .hay = "the theme breathe other the" },
    };
    for (cases) |c| {
        var re = try Regex.compile(allocator, c.pat);
        defer re.deinit();
        try std.testing.expectEqual(naive.count(c.hay, c.pat), try re.count(c.hay));
        const want_first = std.mem.indexOf(u8, c.hay, c.pat).?;
        const m = (try re.find(c.hay)).?;
        try std.testing.expectEqual(want_first, m.start);
    }
}

test "regression: memmem holds on a large common-first-byte haystack" {
    const allocator = std.testing.allocator;
    // "xf...f xfn ..." — `f` everywhere (forces the two-byte filter), `fn` rare.
    var buf = try std.ArrayList(u8).initCapacity(allocator, 200 * 1000);
    defer buf.deinit(allocator);
    var i: usize = 0;
    while (i < 50_000) : (i += 1) {
        try buf.appendSlice(allocator, if (i % 100 == 0) "fn " else "ff ");
    }
    var re = try Regex.compile(allocator, "fn");
    defer re.deinit();
    try std.testing.expectEqual(@as(usize, 500), try re.count(buf.items));
}

test "regression: capture-bearing alternatives preserve participating captures" {
    const allocator = std.testing.allocator;

    var empty_left = try Regex.compile(allocator, "()|");
    defer empty_left.deinit();
    if (try empty_left.find("")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("", match.slice);
        try std.testing.expect(match.captures_present[0]);
        try std.testing.expectEqualStrings("", match.captures[0]);
    } else return error.TestExpectedMatch;

    var left_capture = try Regex.compile(allocator, "(.)..|abc");
    defer left_capture.deinit();
    if (try left_capture.find("abc")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("abc", match.slice);
        try std.testing.expect(match.captures_present[0]);
        try std.testing.expectEqualStrings("a", match.captures[0]);
    } else return error.TestExpectedMatch;
}

// --- reusable Matcher (amortized DFA, grep hot path) ---
//
// `Regex.matcher()` caches the lazy DFA across calls so per-line matching
// doesn't rebuild it every call (10-50x for DFA patterns). It must produce
// results identical to the plain (DFA-rebuilt-per-call) API, and reuse must be
// safe across many calls.

test "regression: Matcher matches the plain API and reuses safely" {
    const allocator = std.testing.allocator;
    const lines = [_][]const u8{
        "fn helper() void {}", "  return x + y;", "}", "", "const a = 1;",
        "a1 b2 c3", "no digits here", "x9", "    \t  ", "word another word",
    };
    // Mix of engines: DFA (`\w+\s+\w+`, `//.*`), literal (`fn`), bounded literal
    // (`\bfn\b`), and NFA-fallback (`\w+\b\w`, `a.*?x`) + backtracking (`(\w)\1`)
    // so both the cached DFA and the cached VM paths are exercised.
    const pats = [_][]const u8{ "\\w+\\s+\\w+", "\\w+[0-9]", "fn", "[a-z]+[0-9]+", "\\bfn\\b", "//.*", "\\w+\\b\\w", "a.*?x", "(\\w)\\1" };
    for (pats) |pat| {
        var re = try Regex.compile(allocator, pat);
        defer re.deinit();
        var m = re.matcher();
        defer m.deinit();
        // Two passes over the lines confirm the cached DFA is reused safely.
        var pass: usize = 0;
        while (pass < 2) : (pass += 1) {
            for (lines) |line| {
                try std.testing.expectEqual(try re.isMatch(line), try m.isMatch(line));
                try std.testing.expectEqual(try re.count(line), try m.count(line));
                const a_m = try re.find(line);
                const b_m = try m.find(line);
                try std.testing.expectEqual(a_m == null, b_m == null);
                if (a_m) |am| {
                    var aa = am;
                    defer aa.deinit(allocator);
                    var bb = b_m.?;
                    defer bb.deinit(allocator);
                    try std.testing.expectEqual(am.start, b_m.?.start);
                    try std.testing.expectEqual(am.end, b_m.?.end);
                }
            }
        }
    }
}

test "regression: Matcher leftmost-longest count over many lines equals plain" {
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, "\\w+\\s+\\w+");
    defer re.deinit();
    var m = re.matcher();
    defer m.deinit();

    var total_plain: usize = 0;
    var total_matcher: usize = 0;
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        const line = if (i % 3 == 0) "alpha beta gamma" else if (i % 3 == 1) "}" else "one two";
        total_plain += try re.count(line);
        total_matcher += try m.count(line);
    }
    try std.testing.expectEqual(total_plain, total_matcher);
    try std.testing.expect(total_plain > 0);
}

// --- case-insensitive on the byte engine (folded NFA/DFA) ---
//
// Under `i` (without the `u` flag) the compiler ASCII-case-folds char/class
// transitions, so case-insensitive patterns run on the fast byte NFA/DFA
// instead of the per-position NFA/backtracker. These guard the folding,
// especially **negated** classes (folding must precede negation) and the
// engine actually used.

test "regression: case-insensitive runs on the byte engine, not the backtracker" {
    const allocator = std.testing.allocator;
    inline for (.{ "\\w+\\s+\\w+", "[a-z]+[0-9]+", "foo.*bar" }) |p| {
        var re = try Regex.compileWithFlags(allocator, p, .{ .case_insensitive = true });
        defer re.deinit();
        try std.testing.expect(re.engine_type == .thompson_nfa);
    }
}

test "regression: case-insensitive matching folds both cases" {
    const allocator = std.testing.allocator;

    var lit = try Regex.compileWithFlags(allocator, "Foo", .{ .case_insensitive = true });
    defer lit.deinit();
    try std.testing.expect(try lit.isMatch("FOO"));
    try std.testing.expect(try lit.isMatch("foo"));
    try std.testing.expect(try lit.isMatch("fOo"));
    try std.testing.expect(!try lit.isMatch("bar"));

    var cls = try Regex.compileWithFlags(allocator, "[a-c]", .{ .case_insensitive = true });
    defer cls.deinit();
    for ([_][]const u8{ "a", "A", "b", "B", "c", "C" }) |s| try std.testing.expect(try cls.isMatch(s));
    try std.testing.expect(!try cls.isMatch("d"));
    try std.testing.expect(!try cls.isMatch("D"));
}

test "regression: negated class under `i` folds before negating" {
    const allocator = std.testing.allocator;
    // [^a-c] under `i` must exclude a-c AND A-C (folding the set, not the
    // complement). Previously the repeat-atom fold re-admitted them.
    var re = try Regex.compileWithFlags(allocator, "[^a-c]", .{ .case_insensitive = true });
    defer re.deinit();
    for ([_][]const u8{ "a", "A", "b", "B", "c", "C" }) |s| try std.testing.expect(!try re.isMatch(s));
    for ([_][]const u8{ "d", "D", "z", "Z", "0" }) |s| try std.testing.expect(try re.isMatch(s));

    var plus = try Regex.compileWithFlags(allocator, "[^a-c]+", .{ .case_insensitive = true });
    defer plus.deinit();
    try std.testing.expectEqual(@as(usize, 0), try plus.count("aAbBcC"));
    try std.testing.expectEqual(@as(usize, 1), try plus.count("xyZ"));
}

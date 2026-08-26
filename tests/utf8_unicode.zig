const std = @import("std");
const Regex = @import("regex").Regex;

// UTF-8 and Unicode Tests

test "UTF-8: literal matching" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "café");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("café"));
    try std.testing.expect(!try regex.isMatch("cafe"));
}

test "UTF-8: emoji matching" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "Hello 👋 World");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("Hello 👋 World"));
}

test "UTF-8: Chinese characters" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "你好");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("你好"));
    try std.testing.expect(try regex.isMatch("你好世界"));
}

test "UTF-8: mixed ASCII and Unicode" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "test-тест-テスト");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("test-тест-テスト"));
}

test "UTF-8: dot matches multi-byte character" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "c.fé");
    defer regex.deinit();

    // Currently .  matches one byte, not one character
    // This test documents current behavior
    try std.testing.expect(try regex.isMatch("café"));
}

test "UTF-8: alternation with Unicode" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "hello|你好|こんにちは");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("hello"));
    try std.testing.expect(try regex.isMatch("你好"));
    try std.testing.expect(try regex.isMatch("こんにちは"));
}

test "UTF-8: character class range with multi-byte" {
    const allocator = std.testing.allocator;
    // Character classes currently only work with single-byte ASCII
    var regex = try Regex.compile(allocator, "[a-z]+");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("hello"));
    // Multi-byte UTF-8 (é) won't match [a-z], but "caf" will
    const result = try regex.find("café");
    try std.testing.expect(result != null);
    if (result) |match| {
        defer {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        // Only matches ASCII part "caf", not the é
        try std.testing.expectEqualStrings("caf", match.slice);
    }
}

test "UTF-8: unicode character class consumes code points" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compileWithFlags(allocator, "[👨‍👩‍👧‍👦]", .{ .unicode = true });
    defer regex.deinit();

    const result = try regex.find("𠮷a𠮷b𠮷c👨‍👩‍👧‍👦d");
    try std.testing.expect(result != null);
    if (result) |match| {
        defer {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        try std.testing.expectEqual(@as(usize, "𠮷a𠮷b𠮷c".len), match.start);
        try std.testing.expectEqualStrings("👨", match.slice);
    }
}

test "UTF-8: quantifiers with Unicode literals" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "あ+");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("あ"));
    try std.testing.expect(try regex.isMatch("ああああ"));
}

test "UTF-8: capture groups with Unicode" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(你好)(世界)");
    defer regex.deinit();

    const result = try regex.find("你好世界");
    try std.testing.expect(result != null);
    if (result) |match| {
        defer {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        try std.testing.expectEqual(@as(usize, 2), match.captures.len);
        try std.testing.expectEqualStrings("你好", match.captures[0]);
        try std.testing.expectEqualStrings("世界", match.captures[1]);
    }
}

test "UTF-8: replacement with Unicode" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\w+)@(\\w+)");
    defer regex.deinit();

    // ASCII works
    const result1 = try regex.replace(allocator, "user@example", "$1 at $2");
    defer allocator.free(result1);
    try std.testing.expectEqualStrings("user at example", result1);
}

test "UTF-8: anchors with Unicode" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^你好$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("你好"));
    try std.testing.expect(!try regex.isMatch("你好世界"));
    try std.testing.expect(!try regex.isMatch("世界你好"));
}

test "UTF-8: non-capturing groups with Unicode" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?:안녕|hello) (world|세계)");
    defer regex.deinit();

    const result1 = try regex.find("hello world");
    try std.testing.expect(result1 != null);
    if (result1) |match| {
        defer {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        try std.testing.expectEqual(@as(usize, 1), match.captures.len);
        try std.testing.expectEqualStrings("world", match.captures[0]);
    }

    const result2 = try regex.find("안녕 세계");
    try std.testing.expect(result2 != null);
    if (result2) |match| {
        defer {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        try std.testing.expectEqual(@as(usize, 1), match.captures.len);
        try std.testing.expectEqualStrings("세계", match.captures[0]);
    }
}

test "UTF-8: dot consumes JavaScript characters" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^.$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("é"));
    try std.testing.expect(try regex.isMatch("你"));
    try std.testing.expect(!try regex.isMatch("𐌀"));

    var unicode_regex = try Regex.compileWithFlags(allocator, "^.$", .{ .unicode = true });
    defer unicode_regex.deinit();
    try std.testing.expect(try unicode_regex.isMatch("𐌀"));
}

test "UTF-8: dot rejects ECMAScript line terminators without dotAll" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^.$");
    defer regex.deinit();

    try std.testing.expect(!try regex.isMatch("\n"));
    try std.testing.expect(!try regex.isMatch("\r"));
    try std.testing.expect(!try regex.isMatch("\u{2028}"));
    try std.testing.expect(!try regex.isMatch("\u{2029}"));

    var dot_all = try Regex.compileWithFlags(allocator, "^.$", .{ .dot_all = true });
    defer dot_all.deinit();
    try std.testing.expect(try dot_all.isMatch("\n"));
    try std.testing.expect(try dot_all.isMatch("\r"));
    try std.testing.expect(try dot_all.isMatch("\u{2028}"));
    try std.testing.expect(try dot_all.isMatch("\u{2029}"));
}

test "UTF-8: known limitation - \\w is ASCII-only" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\w+");
    defer regex.deinit();

    // ASCII word characters work
    try std.testing.expect(try regex.isMatch("hello"));
    try std.testing.expect(try regex.isMatch("test123"));

    // Non-ASCII letters currently don't match \w
    // In Unicode mode, \w should match Unicode letters
    const result = try regex.find("café");
    if (result) |match| {
        defer {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        // Currently only matches "caf", not "café"
        try std.testing.expectEqualStrings("caf", match.slice);
    }
}

// The one-pass capture plan is a per-BYTE matcher: it is only consulted for
// simple patterns whose groups can be resolved without backtracking, and it
// counts one table hit as one character. That equivalence holds for ASCII only,
// so it declines any input whose decision would consume a non-ASCII byte and the
// caller re-runs the general engine. Before that guard, `(.)` inside a group
// consumed a single byte: `(caf)(.)` on "café" ended the match mid-sequence
// (yielding the malformed prefix "caf\xc3"), and `(.)(x)` on "éx" matched at
// byte 1 — inside 'é' — instead of at the start.
test "UTF-8: one-pass capture plan matches whole code points, not bytes" {
    const allocator = std.testing.allocator;

    {
        var regex = try Regex.compile(allocator, "(caf)(.)");
        defer regex.deinit();
        var match = (try regex.find("café")).?;
        defer match.deinit(allocator);
        try std.testing.expectEqualStrings("café", match.slice);
        try std.testing.expectEqual(@as(usize, 0), match.start);
        try std.testing.expectEqual(@as(usize, 5), match.end);
        try std.testing.expectEqualStrings("caf", match.captures[0]);
        try std.testing.expectEqualStrings("é", match.captures[1]);
    }

    {
        // Two dots must consume two characters (4 bytes), not two bytes.
        var regex = try Regex.compile(allocator, "(.)(.)");
        defer regex.deinit();
        var match = (try regex.find("éé")).?;
        defer match.deinit(allocator);
        try std.testing.expectEqualStrings("éé", match.slice);
        try std.testing.expectEqualStrings("é", match.captures[0]);
        try std.testing.expectEqualStrings("é", match.captures[1]);
    }

    {
        // A failed attempt must not resume inside a multi-byte sequence.
        var regex = try Regex.compile(allocator, "(.)(x)");
        defer regex.deinit();
        var match = (try regex.find("éx")).?;
        defer match.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 0), match.start);
        try std.testing.expectEqualStrings("é", match.captures[0]);
        try std.testing.expectEqualStrings("x", match.captures[1]);
    }

    {
        // Pure ASCII keeps taking the one-pass path and stays correct.
        var regex = try Regex.compile(allocator, "(a)(b)");
        defer regex.deinit();
        var match = (try regex.find("zab")).?;
        defer match.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), match.start);
        try std.testing.expectEqualStrings("a", match.captures[0]);
        try std.testing.expectEqualStrings("b", match.captures[1]);
    }

    {
        // findAll must discard the plan's partial results and re-run cleanly.
        var regex = try Regex.compile(allocator, "(.)(b)");
        defer regex.deinit();
        const all = try regex.findAll(allocator, "ab éb");
        defer {
            for (all) |*m| m.deinit(allocator);
            allocator.free(all);
        }
        try std.testing.expectEqual(@as(usize, 2), all.len);
        try std.testing.expectEqualStrings("ab", all[0].slice);
        try std.testing.expectEqualStrings("éb", all[1].slice);
    }
}

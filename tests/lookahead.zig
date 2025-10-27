const std = @import("std");
const Regex = @import("regex").Regex;

test "positive lookahead: basic (?=...)" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "foo(?=bar)");
    defer regex.deinit();

    // Should match "foo" only when followed by "bar"
    try std.testing.expect(try regex.isMatch("foobar"));

    if (try regex.find("foobar")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        // Should match only "foo", not "foobar" (lookahead doesn't consume)
        try std.testing.expectEqualStrings("foo", match.slice);
    } else {
        return error.TestExpectedMatch;
    }

    // Should not match when not followed by "bar"
    try std.testing.expect(!try regex.isMatch("foobaz"));
}

test "positive lookahead: at end of string" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "foo(?=bar)bar");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("foobar"));

    if (try regex.find("foobar")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("foobar", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "positive lookahead: with alternation" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "foo(?=bar|baz)");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("foobar"));
    try std.testing.expect(try regex.isMatch("foobaz"));
    try std.testing.expect(!try regex.isMatch("fooqux"));
}

test "negative lookahead: basic (?!...)" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "foo(?!bar)");
    defer regex.deinit();

    // Should match "foo" when NOT followed by "bar"
    try std.testing.expect(try regex.isMatch("foobaz"));
    try std.testing.expect(!try regex.isMatch("foobar"));

    if (try regex.find("foobaz")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("foo", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "negative lookahead: with character class" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\d+(?!\\d)");
    defer regex.deinit();

    // Should match digits not followed by another digit
    if (try regex.find("123abc")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("123", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "multiple lookaheads" {
    const allocator = std.testing.allocator;
    // Password validation: at least one digit AND at least one letter
    var regex = try Regex.compile(allocator, "(?=.*\\d)(?=.*[a-z]).+");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("abc123"));
    try std.testing.expect(try regex.isMatch("a1"));
    try std.testing.expect(!try regex.isMatch("abcdef")); // no digit
    try std.testing.expect(!try regex.isMatch("123456")); // no letter
}

test "lookahead in alternation" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?=foo)|(?=bar)");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("foo"));
    try std.testing.expect(try regex.isMatch("bar"));
}

test "lookahead with quantifiers" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a+(?=b+)");
    defer regex.deinit();

    if (try regex.find("aaabbb")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("aaa", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "nested lookahead" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "foo(?=bar(?=baz))");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("foobarbaz"));
    try std.testing.expect(!try regex.isMatch("foobarqux"));
}

test "lookahead: zero-width assertion" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?=a)a");
    defer regex.deinit();

    if (try regex.find("a")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        // The lookahead should not consume the 'a'
        try std.testing.expectEqualStrings("a", match.slice);
        try std.testing.expectEqual(@as(usize, 0), match.start);
        try std.testing.expectEqual(@as(usize, 1), match.end);
    } else {
        return error.TestExpectedMatch;
    }
}

test "lookahead with capture groups" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\w+)(?= world)");
    defer regex.deinit();

    if (try regex.find("hello world")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("hello", match.slice);
        try std.testing.expectEqual(@as(usize, 1), match.captures.len);
        try std.testing.expectEqualStrings("hello", match.captures[0]);
    } else {
        return error.TestExpectedMatch;
    }
}

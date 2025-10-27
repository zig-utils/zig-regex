const std = @import("std");
const Regex = @import("regex").Regex;

test "positive lookbehind: basic (?<=...)" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?<=foo)bar");
    defer regex.deinit();

    // Should match "bar" only when preceded by "foo"
    try std.testing.expect(try regex.isMatch("foobar"));

    if (try regex.find("foobar")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        // Should match only "bar", not "foobar" (lookbehind doesn't consume)
        try std.testing.expectEqualStrings("bar", match.slice);
        try std.testing.expectEqual(@as(usize, 3), match.start);
    } else {
        return error.TestExpectedMatch;
    }

    // Should not match when not preceded by "foo"
    try std.testing.expect(!try regex.isMatch("bazbar"));
}

test "positive lookbehind: at start of pattern" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?<=foo)bar");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("foobar"));
    try std.testing.expect(!try regex.isMatch("bar"));
}

test "positive lookbehind: with alternation" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?<=foo|baz)bar");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("foobar"));
    try std.testing.expect(try regex.isMatch("bazbar"));
    try std.testing.expect(!try regex.isMatch("quxbar"));
}

test "negative lookbehind: basic (?<!...)" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?<!foo)bar");
    defer regex.deinit();

    // Should match "bar" when NOT preceded by "foo"
    try std.testing.expect(try regex.isMatch("bazbar"));
    try std.testing.expect(!try regex.isMatch("foobar"));

    if (try regex.find("bazbar")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("bar", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "negative lookbehind: at string start" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?<!x)bar");
    defer regex.deinit();

    // "bar" at start should match (nothing before it, so not preceded by 'x')
    if (try regex.find("bar")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("bar", match.slice);
        try std.testing.expectEqual(@as(usize, 0), match.start);
    } else {
        return error.TestExpectedMatch;
    }
}

test "lookbehind with literal characters" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?<=\\$)\\d+");
    defer regex.deinit();

    // Match digits preceded by dollar sign
    if (try regex.find("$100")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("100", match.slice);
    } else {
        return error.TestExpectedMatch;
    }

    try std.testing.expect(!try regex.isMatch("100"));
}

test "lookbehind: zero-width assertion" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?<=a)b");
    defer regex.deinit();

    if (try regex.find("ab")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        // The lookbehind should not consume the 'a'
        try std.testing.expectEqualStrings("b", match.slice);
        try std.testing.expectEqual(@as(usize, 1), match.start);
        try std.testing.expectEqual(@as(usize, 2), match.end);
    } else {
        return error.TestExpectedMatch;
    }
}

test "combined lookahead and lookbehind" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?<=foo)bar(?=baz)");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("foobarbaz"));
    try std.testing.expect(!try regex.isMatch("foobar"));
    try std.testing.expect(!try regex.isMatch("barbaz"));

    if (try regex.find("foobarbaz")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("bar", match.slice);
        try std.testing.expectEqual(@as(usize, 3), match.start);
        try std.testing.expectEqual(@as(usize, 6), match.end);
    } else {
        return error.TestExpectedMatch;
    }
}

test "lookbehind with capture groups" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?<=@)(\\w+)");
    defer regex.deinit();

    if (try regex.find("@username")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("username", match.slice);
        try std.testing.expectEqual(@as(usize, 1), match.captures.len);
        try std.testing.expectEqualStrings("username", match.captures[0]);
    } else {
        return error.TestExpectedMatch;
    }
}

test "multiple lookbehinds" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?<=a)(?<=ab)c");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(!try regex.isMatch("ac"));
}

test "lookbehind in findAll" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?<=\\s)\\w+");
    defer regex.deinit();

    const matches = try regex.findAll(allocator, "hello world foo bar");
    defer {
        for (matches) |*match| {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        allocator.free(matches);
    }

    try std.testing.expectEqual(@as(usize, 3), matches.len);
    try std.testing.expectEqualStrings("world", matches[0].slice);
    try std.testing.expectEqualStrings("foo", matches[1].slice);
    try std.testing.expectEqualStrings("bar", matches[2].slice);
}

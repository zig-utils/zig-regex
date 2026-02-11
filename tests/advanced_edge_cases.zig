const std = @import("std");
const Regex = @import("regex").Regex;
const RegexError = @import("regex").RegexError;

// =============================================================================
// Advanced feature edge cases: lookahead, lookbehind, backreferences, etc.
// =============================================================================

// --- Lookahead edge cases ---

test "advanced: positive lookahead basic" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "foo(?=bar)");
    defer regex.deinit();

    // "foobar" should match "foo" (lookahead is zero-width)
    if (try regex.find("foobar")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("foo", match.slice);
    } else {
        return error.TestExpectedMatch;
    }

    // "foobaz" should not match (bar not following)
    try std.testing.expect(!try regex.isMatch("foobaz"));
}

test "advanced: negative lookahead basic" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "foo(?!bar)");
    defer regex.deinit();

    // "foobaz" should match "foo" (bar not following)
    try std.testing.expect(try regex.isMatch("foobaz"));
    // "foo" alone should match (nothing follows, which is not "bar")
    try std.testing.expect(try regex.isMatch("foo"));
    // "foobar" should not match
    try std.testing.expect(!try regex.isMatch("foobar"));
}

test "advanced: lookahead is zero-width" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "foo(?=bar)bar");
    defer regex.deinit();

    // Lookahead doesn't consume, so "bar" after it should match the same "bar"
    try std.testing.expect(try regex.isMatch("foobar"));
}

// --- Lookbehind edge cases ---

test "advanced: positive lookbehind" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?<=@)\\w+");
    defer regex.deinit();

    if (try regex.find("user@domain")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("domain", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "advanced: negative lookbehind" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?<!\\d)\\w+");
    defer regex.deinit();

    if (try regex.find("abc")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("abc", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

// --- Backreference edge cases ---

test "advanced: backreference repeated word" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\b(\\w+)\\s+\\1\\b");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("the the"));
    try std.testing.expect(try regex.isMatch("hello hello"));
    try std.testing.expect(!try regex.isMatch("hello world"));
}

test "advanced: backreference HTML tag matching" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "<(\\w+)>.*</\\1>");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("<b>bold</b>"));
    try std.testing.expect(try regex.isMatch("<div>content</div>"));
    try std.testing.expect(!try regex.isMatch("<b>bold</i>"));
}

// --- Non-capturing groups ---

test "advanced: non-capturing group doesn't affect capture numbering" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?:abc)(def)");
    defer regex.deinit();

    if (try regex.find("abcdef")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("abcdef", match.slice);
        // Only one capture group: (def)
        try std.testing.expect(match.captures.len >= 1);
        try std.testing.expectEqualStrings("def", match.captures[0]);
    } else {
        return error.TestExpectedMatch;
    }
}

test "advanced: non-capturing with alternation" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?:cat|dog)fish");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("catfish"));
    try std.testing.expect(try regex.isMatch("dogfish"));
    try std.testing.expect(!try regex.isMatch("ratfish"));
}

test "advanced: mixed capturing and non-capturing" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\w+)(?:\\s+)(\\w+)");
    defer regex.deinit();

    if (try regex.find("hello world")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expect(match.captures.len >= 2);
        try std.testing.expectEqualStrings("hello", match.captures[0]);
        try std.testing.expectEqualStrings("world", match.captures[1]);
    } else {
        return error.TestExpectedMatch;
    }
}

// --- Named captures ---

test "advanced: named capture python style" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?P<year>\\d{4})-(?P<month>\\d{2})");
    defer regex.deinit();

    if (try regex.find("date: 2024-01 ok")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("2024-01", match.slice);
        try std.testing.expect(match.captures.len >= 2);
        try std.testing.expectEqualStrings("2024", match.captures[0]);
        try std.testing.expectEqualStrings("01", match.captures[1]);
    } else {
        return error.TestExpectedMatch;
    }
}

test "advanced: named capture angle bracket style" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?<first>\\w+)\\s(?<last>\\w+)");
    defer regex.deinit();

    if (try regex.find("John Doe")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expect(match.captures.len >= 2);
        try std.testing.expectEqualStrings("John", match.captures[0]);
        try std.testing.expectEqualStrings("Doe", match.captures[1]);
    } else {
        return error.TestExpectedMatch;
    }
}

// --- Combined features ---

test "advanced: anchored pattern with captures" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^(\\w+)\\s+(\\w+)$");
    defer regex.deinit();

    if (try regex.find("hello world")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expect(match.captures.len >= 2);
        try std.testing.expectEqualStrings("hello", match.captures[0]);
        try std.testing.expectEqualStrings("world", match.captures[1]);
    } else {
        return error.TestExpectedMatch;
    }

    try std.testing.expect(!try regex.isMatch("hello world!"));
}

test "advanced: case insensitive find with captures" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compileWithFlags(allocator, "(hello) (world)", .{ .case_insensitive = true });
    defer regex.deinit();

    if (try regex.find("HELLO WORLD")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("HELLO WORLD", match.slice);
        try std.testing.expect(match.captures.len >= 2);
        try std.testing.expectEqualStrings("HELLO", match.captures[0]);
        try std.testing.expectEqualStrings("WORLD", match.captures[1]);
    } else {
        return error.TestExpectedMatch;
    }
}

// --- Practical patterns ---

test "advanced: IPv4 address pattern" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("192.168.1.1"));
    try std.testing.expect(try regex.isMatch("10.0.0.1"));
    try std.testing.expect(!try regex.isMatch("abc.def.ghi.jkl"));
}

test "advanced: hex color pattern" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "#[0-9a-fA-F]{6}");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("#ff0000"));
    try std.testing.expect(try regex.isMatch("#FF00FF"));
    try std.testing.expect(!try regex.isMatch("#xyz"));
}

test "advanced: semver pattern" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\d+)\\.(\\d+)\\.(\\d+)");
    defer regex.deinit();

    if (try regex.find("version 1.2.3-beta")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("1.2.3", match.slice);
        try std.testing.expect(match.captures.len >= 3);
        try std.testing.expectEqualStrings("1", match.captures[0]);
        try std.testing.expectEqualStrings("2", match.captures[1]);
        try std.testing.expectEqualStrings("3", match.captures[2]);
    } else {
        return error.TestExpectedMatch;
    }
}

test "advanced: log line pattern" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\[(\\w+)\\]\\s+(.+)");
    defer regex.deinit();

    if (try regex.find("[ERROR] Something went wrong")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expect(match.captures.len >= 2);
        try std.testing.expectEqualStrings("ERROR", match.captures[0]);
        try std.testing.expectEqualStrings("Something went wrong", match.captures[1]);
    } else {
        return error.TestExpectedMatch;
    }
}

test "advanced: URL extraction" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "https?://[a-zA-Z0-9._/-]+");
    defer regex.deinit();

    if (try regex.find("visit http://example.com/path today")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("http://example.com/path", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

// --- Iterator edge cases ---

test "advanced: iterator over empty result" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "xyz");
    defer regex.deinit();

    var iter = regex.iterator("hello world");
    const first = try iter.next(allocator);
    try std.testing.expect(first == null);
}

test "advanced: iterator collects all matches" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\d+");
    defer regex.deinit();

    var iter = regex.iterator("a1b23c456");
    var count: usize = 0;

    while (try iter.next(allocator)) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        count += 1;
    }

    try std.testing.expectEqual(@as(usize, 3), count);
}

// --- Multiline combined with other features ---

test "advanced: multiline with captures" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compileWithFlags(allocator, "^(\\w+):", .{ .multiline = true });
    defer regex.deinit();

    const matches = try regex.findAll(allocator, "key1: val\nkey2: val");
    defer {
        for (matches) |*m| {
            var mut_m = m;
            mut_m.deinit(allocator);
        }
        allocator.free(matches);
    }

    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expect(matches[0].captures.len >= 1);
    try std.testing.expectEqualStrings("key1", matches[0].captures[0]);
    try std.testing.expect(matches[1].captures.len >= 1);
    try std.testing.expectEqualStrings("key2", matches[1].captures[0]);
}

// --- Boundary condition: match at position 0 ---

test "advanced: match at very start of input" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\d+");
    defer regex.deinit();

    if (try regex.find("123abc")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 0), match.start);
        try std.testing.expectEqualStrings("123", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "advanced: match consuming entire input" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\w+");
    defer regex.deinit();

    if (try regex.find("hello")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 0), match.start);
        try std.testing.expectEqual(@as(usize, 5), match.end);
        try std.testing.expectEqualStrings("hello", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

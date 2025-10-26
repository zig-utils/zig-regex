const std = @import("std");
const Regex = @import("regex").Regex;

test "comprehensive: email-like pattern" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\w+@\\w+");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("user@domain"));
    try std.testing.expect(!try regex.isMatch("invalid"));
}

test "comprehensive: phone number pattern" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\d+-\\d+");
    defer regex.deinit();

    if (try regex.find("Call 555-1234 now")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("555-1234", match.slice);
    } else {
        try std.testing.expect(false);
    }
}

test "comprehensive: complex alternation" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "cat|dog|bird");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("cat"));
    try std.testing.expect(try regex.isMatch("dog"));
    try std.testing.expect(try regex.isMatch("bird"));
    try std.testing.expect(!try regex.isMatch("fish"));
}

test "comprehensive: nested grouping" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(a(b)c)");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(!try regex.isMatch("ac"));
}

test "comprehensive: multiple quantifiers" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a+b*c?");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("aaa"));
    try std.testing.expect(try regex.isMatch("aaabbb"));
    try std.testing.expect(try regex.isMatch("aaabbbccc"));
}

test "comprehensive: start and end anchors" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^hello$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("hello"));
    try std.testing.expect(!try regex.isMatch("hello world"));
    try std.testing.expect(!try regex.isMatch("say hello"));
}

test "comprehensive: character class ranges" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[a-z]+");
    defer regex.deinit();

    if (try regex.find("ABC123xyz")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("xyz", match.slice);
    } else {
        try std.testing.expect(false);
    }
}

test "comprehensive: negated character class" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[^0-9]+");
    defer regex.deinit();

    if (try regex.find("123abc456")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("abc", match.slice);
    } else {
        try std.testing.expect(false);
    }
}

test "comprehensive: findAll with multiple matches" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\d+");
    defer regex.deinit();

    const matches = try regex.findAll(allocator, "10 cats and 20 dogs");
    defer {
        for (matches) |*match| {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        allocator.free(matches);
    }

    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqualStrings("10", matches[0].slice);
    try std.testing.expectEqualStrings("20", matches[1].slice);
}

test "comprehensive: replaceAll multiple occurrences" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\d+");
    defer regex.deinit();

    const result = try regex.replaceAll(allocator, "I have 2 cats and 3 dogs", "many");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("I have many cats and many dogs", result);
}

test "comprehensive: split by whitespace pattern" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\s+");
    defer regex.deinit();

    const parts = try regex.split(allocator, "hello    world   test");
    defer allocator.free(parts);

    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualStrings("hello", parts[0]);
    try std.testing.expectEqualStrings("world", parts[1]);
    try std.testing.expectEqualStrings("test", parts[2]);
}

test "comprehensive: dot matches any character" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a.c");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(try regex.isMatch("a1c"));
    try std.testing.expect(try regex.isMatch("a c"));
    try std.testing.expect(!try regex.isMatch("ac"));
}

test "comprehensive: escape special characters" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\$\\d+\\.\\d+");
    defer regex.deinit();

    if (try regex.find("Price: $19.99")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("$19.99", match.slice);
    } else {
        try std.testing.expect(false);
    }
}

test "comprehensive: word boundary" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\bword\\b");
    defer regex.deinit();

    if (try regex.find("a word here")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("word", match.slice);
    } else {
        try std.testing.expect(false);
    }
}

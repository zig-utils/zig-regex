const std = @import("std");
const Regex = @import("regex").Regex;

// Match Iterator Tests

test "iterator: basic iteration" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\d+");
    defer regex.deinit();

    const text = "123 abc 456 def 789";
    var iter = regex.iterator(text);

    var match1 = (try iter.next(allocator)).?;
    defer match1.deinit(allocator);
    try std.testing.expectEqualStrings("123", match1.slice);

    var match2 = (try iter.next(allocator)).?;
    defer match2.deinit(allocator);
    try std.testing.expectEqualStrings("456", match2.slice);

    var match3 = (try iter.next(allocator)).?;
    defer match3.deinit(allocator);
    try std.testing.expectEqualStrings("789", match3.slice);

    const no_match = try iter.next(allocator);
    try std.testing.expect(no_match == null);
}

test "iterator: empty input" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\d+");
    defer regex.deinit();

    const text = "";
    var iter = regex.iterator(text);

    const no_match = try iter.next(allocator);
    try std.testing.expect(no_match == null);
}

test "iterator: no matches" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\d+");
    defer regex.deinit();

    const text = "abc def";
    var iter = regex.iterator(text);

    const no_match = try iter.next(allocator);
    try std.testing.expect(no_match == null);
}

test "iterator: reset functionality" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\w+");
    defer regex.deinit();

    const text = "hello world";
    var iter = regex.iterator(text);

    var match1 = (try iter.next(allocator)).?;
    defer match1.deinit(allocator);
    try std.testing.expectEqualStrings("hello", match1.slice);

    iter.reset();

    var match2 = (try iter.next(allocator)).?;
    defer match2.deinit(allocator);
    try std.testing.expectEqualStrings("hello", match2.slice);
}

test "iterator: captures in iteration" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\w+)@(\\w+)");
    defer regex.deinit();

    const text = "user@example and admin@test";
    var iter = regex.iterator(text);

    var match1 = (try iter.next(allocator)).?;
    defer match1.deinit(allocator);
    try std.testing.expectEqualStrings("user@example", match1.slice);
    try std.testing.expectEqual(@as(usize, 2), match1.captures.len);
    try std.testing.expectEqualStrings("user", match1.captures[0]);
    try std.testing.expectEqualStrings("example", match1.captures[1]);

    var match2 = (try iter.next(allocator)).?;
    defer match2.deinit(allocator);
    try std.testing.expectEqualStrings("admin@test", match2.slice);
    try std.testing.expectEqualStrings("admin", match2.captures[0]);
    try std.testing.expectEqualStrings("test", match2.captures[1]);
}

test "iterator: large input streaming" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\d+");
    defer regex.deinit();

    // Simulate processing large input without loading all matches
    const text = "1 2 3 4 5 6 7 8 9 10";
    var iter = regex.iterator(text);

    var count: usize = 0;
    while (try iter.next(allocator)) |match| {
        defer {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        count += 1;
    }

    try std.testing.expectEqual(@as(usize, 10), count);
}

test "iterator: manual loop pattern" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[a-z]+");
    defer regex.deinit();

    const text = "hello world test";
    var iter = regex.iterator(text);

    var words = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer {
        for (words.items) |word| {
            allocator.free(word);
        }
        words.deinit(allocator);
    }

    while (try iter.next(allocator)) |match| {
        defer {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        const word = try allocator.dupe(u8, match.slice);
        try words.append(allocator, word);
    }

    try std.testing.expectEqual(@as(usize, 3), words.items.len);
    try std.testing.expectEqualStrings("hello", words.items[0]);
    try std.testing.expectEqualStrings("world", words.items[1]);
    try std.testing.expectEqualStrings("test", words.items[2]);
}

test "iterator: memory efficiency" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\w+");
    defer regex.deinit();

    // Iterator should not allocate all matches at once
    const text = "one two three four five";
    var iter = regex.iterator(text);

    // Process one match at a time
    {
        var match1 = (try iter.next(allocator)).?;
        defer match1.deinit(allocator);
        try std.testing.expectEqualStrings("one", match1.slice);
        // match1 memory freed here
    }

    {
        var match2 = (try iter.next(allocator)).?;
        defer match2.deinit(allocator);
        try std.testing.expectEqualStrings("two", match2.slice);
        // match2 memory freed here
    }
}

test "iterator: overlapping matches prevention" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\w\\w");
    defer regex.deinit();

    const text = "abcd";
    var iter = regex.iterator(text);

    var match1 = (try iter.next(allocator)).?;
    defer match1.deinit(allocator);
    try std.testing.expectEqualStrings("ab", match1.slice);

    var match2 = (try iter.next(allocator)).?;
    defer match2.deinit(allocator);
    try std.testing.expectEqualStrings("cd", match2.slice);

    const no_match = try iter.next(allocator);
    try std.testing.expect(no_match == null);
}

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

// count(): allocation-free match counting must agree with findAll().len
// across the fast paths (exact literal, repeated atom, literal alternation)
// and the NFA path.
test "count: agrees with findAll across pattern shapes" {
    const allocator = std.testing.allocator;
    const cases = .{
        .{ "hello", "hello world hello there hello" }, // exact literal
        .{ "\\w+", "foo bar123 baz qux" }, // repeated atom
        .{ "\\d+", "a1 bb 22 ccc 333" }, // repeated atom (digits)
        .{ "cat|dog|bird", "cat dog fish bird cat" }, // literal alternation
        .{ "a.c", "abc axc adc xyz aqc" }, // lazy-DFA path
        .{ "a+b", "aab ab aaab b" }, // lazy-DFA path
        .{ "foo[0-9]+", "foo12 foo bar foo345 foobar" }, // literal-prefix + DFA
        .{ "ba[rz][0-9]+", "bar1 baz22 bat3 bar baz9" }, // DFA
        .{ "\\w+[0-9]", "abc1 word hello42 x9 noend" }, // DFA, greedy backtrack
        .{ "[a-z]+[0-9]+", "ab12 cd ef34 5 gh5" }, // DFA
        .{ "a.*c", "axxc a c abc xyz" }, // DFA, greedy star
        .{ "(ab|abc)(d|cd)", "abcd abd" }, // DFA, longest alternation
        .{ "x", "" }, // empty input
    };
    inline for (cases) |c| {
        var re = try Regex.compile(allocator, c[0]);
        defer re.deinit();
        const matches = try re.findAll(allocator, c[1]);
        defer {
            for (matches) |*m| m.deinit(allocator);
            allocator.free(matches);
        }
        const n = try re.count(c[1]);
        try std.testing.expectEqual(matches.len, n);
    }
}

// The capture-aware DFA hybrid (DFA locates the match, NFA fills captures for
// greedy/anchor-free capture patterns) must produce correct captures.
test "DFA hybrid: captures correct for greedy capture patterns" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "(\\d+)-(\\d+)");
    defer re.deinit();

    const matches = try re.findAll(allocator, "ab 12-34 xx 5-6 cd");
    defer {
        for (matches) |*m| m.deinit(allocator);
        allocator.free(matches);
    }
    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqualStrings("12-34", matches[0].slice);
    try std.testing.expectEqualStrings("12", matches[0].captures[0]);
    try std.testing.expectEqualStrings("34", matches[0].captures[1]);
    try std.testing.expectEqualStrings("5-6", matches[1].slice);
    try std.testing.expectEqualStrings("5", matches[1].captures[0]);
    try std.testing.expectEqualStrings("6", matches[1].captures[1]);

    // find() through the same hybrid.
    var m = (try re.find("xx 78-90 yy")).?;
    defer m.deinit(allocator);
    try std.testing.expectEqualStrings("78-90", m.slice);
    try std.testing.expectEqualStrings("78", m.captures[0]);
    try std.testing.expectEqualStrings("90", m.captures[1]);
}

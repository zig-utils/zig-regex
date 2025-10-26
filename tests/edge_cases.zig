const std = @import("std");
const Regex = @import("regex").Regex;
const RegexError = @import("regex").RegexError;

// Edge case: Empty input
test "edge: empty input with star" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a*");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch(""));
}

test "edge: empty input with plus should fail" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a+");
    defer regex.deinit();

    try std.testing.expect(!try regex.isMatch(""));
}

// Edge case: Single character patterns
test "edge: single character literal" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "x");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("x"));
    try std.testing.expect(!try regex.isMatch("y"));
    try std.testing.expect(!try regex.isMatch(""));
}

// Edge case: Nested quantifiers behavior
test "edge: star after plus" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a+b*");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("aaa"));
    try std.testing.expect(try regex.isMatch("aaabbb"));
}

// Edge case: Multiple alternations
test "edge: multiple alternations" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a|b|c|d");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("b"));
    try std.testing.expect(try regex.isMatch("c"));
    try std.testing.expect(try regex.isMatch("d"));
    try std.testing.expect(!try regex.isMatch("e"));
}

// Edge case: Alternation with empty branch
test "edge: alternation with quantifiers" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a*|b+");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch(""));
    try std.testing.expect(try regex.isMatch("aaa"));
    try std.testing.expect(try regex.isMatch("bbb"));
}

// Edge case: Complex nested groups
test "edge: nested groups" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "((a))");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a"));
}

// Edge case: Character class edge cases
test "edge: empty character class range" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[a]");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(!try regex.isMatch("b"));
}

test "edge: character class with single range" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[a-a]");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(!try regex.isMatch("b"));
}

test "edge: negated character class matching nothing in range" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[^a-z]");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("A"));
    try std.testing.expect(try regex.isMatch("1"));
    try std.testing.expect(!try regex.isMatch("a"));
}

// Edge case: Anchors at different positions
test "edge: start anchor not at beginning" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a^b");
    defer regex.deinit();

    // This should not match anything since ^ is not at the start
    try std.testing.expect(!try regex.isMatch("ab"));
}

test "edge: end anchor not at end" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a$b");
    defer regex.deinit();

    // This should not match anything since $ is not at the end
    try std.testing.expect(!try regex.isMatch("ab"));
}

// Edge case: Dot matching
test "edge: dot with quantifiers" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, ".*");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch(""));
    try std.testing.expect(try regex.isMatch("anything"));
    try std.testing.expect(try regex.isMatch("123!@#"));
}

// Edge case: Escape sequences
test "edge: escaped backslash" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\\\");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("\\"));
    try std.testing.expect(!try regex.isMatch("a"));
}

test "edge: escaped dot" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\.");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("."));
    try std.testing.expect(!try regex.isMatch("a"));
}

// Edge case: findAll edge cases
test "edge: findAll with no matches" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "x");
    defer regex.deinit();

    const matches = try regex.findAll(allocator, "aaabbb");
    defer allocator.free(matches);

    try std.testing.expectEqual(@as(usize, 0), matches.len);
}

test "edge: findAll with overlapping potential matches" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a+");
    defer regex.deinit();

    const matches = try regex.findAll(allocator, "aaa");
    defer {
        for (matches) |*match| {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        allocator.free(matches);
    }

    // Should match the whole "aaa" as one greedy match
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("aaa", matches[0].slice);
}

// Edge case: replace edge cases
test "edge: replace with empty string" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a");
    defer regex.deinit();

    const result = try regex.replace(allocator, "banana", "");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("bnana", result);
}

test "edge: replace in empty string" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a");
    defer regex.deinit();

    const result = try regex.replace(allocator, "", "x");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("", result);
}

// Edge case: split edge cases
test "edge: split empty string" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, ",");
    defer regex.deinit();

    const parts = try regex.split(allocator, "");
    defer allocator.free(parts);

    try std.testing.expectEqual(@as(usize, 1), parts.len);
    try std.testing.expectEqualStrings("", parts[0]);
}

test "edge: split with no delimiter found" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, ",");
    defer regex.deinit();

    const parts = try regex.split(allocator, "hello");
    defer allocator.free(parts);

    try std.testing.expectEqual(@as(usize, 1), parts.len);
    try std.testing.expectEqualStrings("hello", parts[0]);
}

// Edge case: Word boundaries
test "edge: word boundary at start" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\bword");
    defer regex.deinit();

    if (try regex.find("word here")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("word", match.slice);
    } else {
        try std.testing.expect(false);
    }
}

test "edge: word boundary at end" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "word\\b");
    defer regex.deinit();

    if (try regex.find("a word")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("word", match.slice);
    } else {
        try std.testing.expect(false);
    }
}

// Edge case: Character classes with special chars
test "edge: whitespace character class" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\s+");
    defer regex.deinit();

    if (try regex.find("hello   world")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 3), match.slice.len);
    } else {
        try std.testing.expect(false);
    }
}

test "edge: digit character class at boundaries" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^\\d+$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("123"));
    try std.testing.expect(!try regex.isMatch("abc"));
    try std.testing.expect(!try regex.isMatch("123abc"));
}

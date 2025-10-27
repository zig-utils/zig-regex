const std = @import("std");
const Regex = @import("regex").Regex;

// Backreference Tests

test "backreference: simple capture group replacement" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\w+)");
    defer regex.deinit();

    const result = try regex.replace(allocator, "hello", "$1!");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("hello!", result);
}

test "backreference: swap two words" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\w+) (\\w+)");
    defer regex.deinit();

    const result = try regex.replace(allocator, "hello world", "$2 $1");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("world hello", result);
}

test "backreference: repeat capture" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\w+)");
    defer regex.deinit();

    const result = try regex.replace(allocator, "test", "$1-$1");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("test-test", result);
}

test "backreference: multiple captures" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\d+)-(\\d+)-(\\d+)");
    defer regex.deinit();

    const result = try regex.replace(allocator, "2025-10-26", "$3/$2/$1");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("26/10/2025", result);
}

test "backreference: escaped dollar sign" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\d+)");
    defer regex.deinit();

    const result = try regex.replace(allocator, "100", "$$$1");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("$100", result);
}

test "backreference: replaceAll with captures" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\w+)@(\\w+)");
    defer regex.deinit();

    const result = try regex.replaceAll(allocator, "user@example and admin@test", "$1 at $2");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("user at example and admin at test", result);
}

test "backreference: extract and format phone numbers" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\d{3})-(\\d{3})-(\\d{4})");
    defer regex.deinit();

    const result = try regex.replace(allocator, "555-123-4567", "($1) $2-$3");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("(555) 123-4567", result);
}

test "backreference: reformat dates" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\d{4})-(\\d{2})-(\\d{2})");
    defer regex.deinit();

    const result = try regex.replaceAll(allocator, "2025-10-26 and 2024-12-31", "$2/$3/$1");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("10/26/2025 and 12/31/2024", result);
}

test "backreference: wrap matches in tags" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\w+)");
    defer regex.deinit();

    const result = try regex.replaceAll(allocator, "hello world", "<b>$1</b>");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("<b>hello</b> <b>world</b>", result);
}

test "backreference: invalid capture index" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\w+)");
    defer regex.deinit();

    // Only one capture group, $2 should be treated as literal
    const result = try regex.replace(allocator, "test", "$1 $2");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("test $2", result);
}

test "backreference: nested captures" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "((\\w+)@(\\w+))");
    defer regex.deinit();

    const result = try regex.replace(allocator, "user@example.com", "Email: $1 (user=$2, domain=$3)");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Email: user@example (user=user, domain=example).com", result);
}

test "backreference: quote words" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\b(\\w+)\\b");
    defer regex.deinit();

    const result = try regex.replaceAll(allocator, "hello world", "'$1'");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("'hello' 'world'", result);
}

test "backreference: transform case context" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(Mr|Mrs|Ms) (\\w+)");
    defer regex.deinit();

    const result = try regex.replace(allocator, "Hello Mr Smith", "$1. $2");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello Mr. Smith", result);
}

// Tests for backreferences in patterns (\\1, \\2)

test "pattern backreference: basic \\1" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\w+) \\1");
    defer regex.deinit();

    // Should match repeated words
    try std.testing.expect(try regex.isMatch("hello hello"));
    try std.testing.expect(!try regex.isMatch("hello world"));

    if (try regex.find("hello hello")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("hello hello", match.slice);
        try std.testing.expectEqual(@as(usize, 1), match.captures.len);
        try std.testing.expectEqualStrings("hello", match.captures[0]);
    } else {
        return error.TestExpectedMatch;
    }
}

test "pattern backreference: multiple captures" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\w+) (\\w+) \\1 \\2");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("foo bar foo bar"));
    try std.testing.expect(!try regex.isMatch("foo bar baz qux"));

    if (try regex.find("foo bar foo bar")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("foo bar foo bar", match.slice);
        try std.testing.expectEqual(@as(usize, 2), match.captures.len);
        try std.testing.expectEqualStrings("foo", match.captures[0]);
        try std.testing.expectEqualStrings("bar", match.captures[1]);
    } else {
        return error.TestExpectedMatch;
    }
}

test "pattern backreference: with quantifiers" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\d+)\\+\\1");
    defer regex.deinit();

    // Match patterns like "5+5", "123+123"
    try std.testing.expect(try regex.isMatch("5+5"));
    try std.testing.expect(try regex.isMatch("123+123"));
    try std.testing.expect(!try regex.isMatch("5+6"));
}

test "pattern backreference: HTML tag matching" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "<(\\w+)>.*</\\1>");
    defer regex.deinit();

    // Match matching HTML tags
    try std.testing.expect(try regex.isMatch("<div>content</div>"));
    try std.testing.expect(try regex.isMatch("<p>text</p>"));
    try std.testing.expect(!try regex.isMatch("<div>content</span>"));
}

test "pattern backreference: case sensitive" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\w+) \\1");
    defer regex.deinit();

    // Backreferences should be case sensitive
    try std.testing.expect(try regex.isMatch("Hello Hello"));
    try std.testing.expect(!try regex.isMatch("Hello hello"));
}

test "pattern backreference: nested groups" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "((\\w)\\w)\\2");
    defer regex.deinit();

    // \\2 refers to second group (single char), so "aba" should match:
    // - (\\w) captures 'a' (group 2)
    // - \\w matches 'b'
    // - \\2 matches 'a' again
    try std.testing.expect(try regex.isMatch("aba"));
    try std.testing.expect(!try regex.isMatch("abc")); // 'c' != 'a'

    if (try regex.find("aba")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 2), match.captures.len);
        try std.testing.expectEqualStrings("ab", match.captures[0]);
        try std.testing.expectEqualStrings("a", match.captures[1]);
    } else {
        return error.TestExpectedMatch;
    }
}

test "pattern backreference: with alternation" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(a|b)\\1");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("aa"));
    try std.testing.expect(try regex.isMatch("bb"));
    try std.testing.expect(!try regex.isMatch("ab"));
    try std.testing.expect(!try regex.isMatch("ba"));
}

test "pattern backreference: multiple in same pattern" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\w)\\1\\1");
    defer regex.deinit();

    // Match three of the same character
    try std.testing.expect(try regex.isMatch("aaa"));
    try std.testing.expect(try regex.isMatch("bbb"));
    try std.testing.expect(!try regex.isMatch("aab"));
    try std.testing.expect(!try regex.isMatch("abc"));
}

test "pattern backreference: findAll" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\w+) \\1");
    defer regex.deinit();

    const matches = try regex.findAll(allocator, "foo foo bar bar baz qux");
    defer {
        for (matches) |*match| {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        allocator.free(matches);
    }

    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqualStrings("foo foo", matches[0].slice);
    try std.testing.expectEqualStrings("bar bar", matches[1].slice);
}

test "pattern backreference: quoted strings" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(['\"]).*\\1");
    defer regex.deinit();

    // Match quoted strings with same quote type
    try std.testing.expect(try regex.isMatch("'hello'"));
    try std.testing.expect(try regex.isMatch("\"hello\""));
    try std.testing.expect(!try regex.isMatch("'hello\""));
}

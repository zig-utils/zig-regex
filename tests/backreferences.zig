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

test "pattern backreference: decimal escape can address capture ten" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "((((((((((A))))))))))\\10\\9\\8\\7\\6\\5\\4\\3\\2\\1");
    defer regex.deinit();

    if (try regex.find("AAAAAAAAAAA")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);

        try std.testing.expectEqualStrings("AAAAAAAAAAA", match.slice);
        try std.testing.expectEqual(@as(usize, 10), match.captures.len);
        for (match.captures) |capture| {
            try std.testing.expectEqualStrings("A", capture);
        }
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

test "pattern backreference: unicode dot keeps surrogate pair atomic" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compileWithFlags(allocator, "(.+).*\\1", .{ .unicode = true, .ecmascript = true });
    defer regex.deinit();

    const input = [_]u8{
        0xED, 0xA0, 0x80,
        0xED, 0xB0, 0x80,
        0xED, 0xA0, 0x80,
    };
    try std.testing.expect(!try regex.isMatch(&input));

    const normalized_input = [_]u8{
        0xF0, 0x90, 0x80, 0x80,
        0xED, 0xA0, 0x80,
    };
    try std.testing.expect(!try regex.isMatch(&normalized_input));
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

// ECMAScript IgnoreCase backreferences compare characters after Canonicalize
// (ECMA-262 22.2.2.7.2, 22.2.2.7.3): simple case folding under u, the
// single-code-unit toUppercase rule without it. Every row was checked against
// node v24.4.1 (zig-regex#29).
const IgnoreCaseBackrefCase = struct { pattern: []const u8, unicode: bool, input: []const u8, expected: ?[]const u8 };

const ignore_case_backref_cases = [_]IgnoreCaseBackrefCase{
    .{ .pattern = "(\u{E0})\\1", .unicode = false, .input = "\u{E0}\u{C0}", .expected = "\u{E0}\u{C0}" },
    .{ .pattern = "(\u{3C3})\\1", .unicode = false, .input = "\u{3C3}\u{3C2}", .expected = "\u{3C3}\u{3C2}" },
    .{ .pattern = "(\u{3A3})\\1\\1", .unicode = false, .input = "\u{3A3}\u{3C3}\u{3C2}", .expected = "\u{3A3}\u{3C3}\u{3C2}" },
    .{ .pattern = "(\u{101})\\1", .unicode = false, .input = "\u{101}\u{100}", .expected = "\u{101}\u{100}" },
    .{ .pattern = "(\u{434})\\1", .unicode = false, .input = "\u{434}\u{414}", .expected = "\u{434}\u{414}" },
    .{ .pattern = "(\u{1C6})\\1", .unicode = false, .input = "\u{1C6}\u{1C5}", .expected = "\u{1C6}\u{1C5}" },
    .{ .pattern = "(?<n>\u{3C3})\\k<n>", .unicode = false, .input = "\u{3C2}\u{3A3}", .expected = "\u{3C2}\u{3A3}" },
    .{ .pattern = "(.)\\1", .unicode = false, .input = "\u{23A}\u{2C65}", .expected = "\u{23A}\u{2C65}" },
    .{ .pattern = "(.)\\1", .unicode = false, .input = "\u{1FBE}\u{399}", .expected = "\u{1FBE}\u{399}" },
    .{ .pattern = "(\u{DF})\\1", .unicode = false, .input = "\u{DF}\u{1E9E}", .expected = null },
    .{ .pattern = "(.)\\1", .unicode = false, .input = "\u{17F}s", .expected = null },
    .{ .pattern = "(.)\\1", .unicode = false, .input = "\u{212A}k", .expected = null },
    .{ .pattern = "(.)\\1", .unicode = false, .input = "\u{2126}\u{3C9}", .expected = null },
    .{ .pattern = "(\u{E9}+)x\\1", .unicode = false, .input = "\u{E9}\u{E9}x\u{C9}\u{C9}", .expected = "\u{E9}\u{E9}x\u{C9}\u{C9}" },
    .{ .pattern = "(\u{17F})\\1", .unicode = true, .input = "\u{17F}s", .expected = "\u{17F}s" },
    .{ .pattern = "(s)\\1", .unicode = true, .input = "s\u{17F}", .expected = "s\u{17F}" },
    .{ .pattern = "(k)\\1", .unicode = true, .input = "\u{212A}K", .expected = "\u{212A}K" },
    .{ .pattern = "(K)\\1", .unicode = true, .input = "K\u{212A}", .expected = "K\u{212A}" },
    .{ .pattern = "(\u{DF})\\1", .unicode = true, .input = "\u{DF}\u{1E9E}", .expected = "\u{DF}\u{1E9E}" },
    .{ .pattern = "(\u{1E9E})\\1", .unicode = true, .input = "\u{1E9E}\u{DF}", .expected = "\u{1E9E}\u{DF}" },
    .{ .pattern = "(\u{DF})\\1", .unicode = true, .input = "\u{DF}ss", .expected = null },
    .{ .pattern = "(\u{17F})\\1", .unicode = true, .input = "\u{17F}", .expected = null },
    .{ .pattern = "(.)\\1", .unicode = true, .input = "\u{10400}\u{10428}", .expected = "\u{10400}\u{10428}" },
    .{ .pattern = "^(\u{17F}K)\\1x$", .unicode = true, .input = "\u{17F}KsKx", .expected = "\u{17F}KsKx" },
    .{ .pattern = "(?<n>k)\\k<n>", .unicode = true, .input = "\u{212A}k", .expected = "\u{212A}k" },
    .{ .pattern = "(?<=\\1(k))x", .unicode = true, .input = "\u{212A}kx", .expected = "x" },
    .{ .pattern = "(?<=\\1(k))x", .unicode = false, .input = "\u{212A}kx", .expected = null },
    .{ .pattern = "(?<=\\1(\u{17F}))x", .unicode = true, .input = "s\u{17F}x", .expected = "x" },
    .{ .pattern = "(?<=\\1(s))x", .unicode = true, .input = "\u{17F}sx", .expected = "x" },
    .{ .pattern = "(?<=\\1(s))x", .unicode = false, .input = "\u{17F}sx", .expected = null },
    .{ .pattern = "(?<=\\1(\u{E0}))x", .unicode = false, .input = "\u{C0}\u{E0}x", .expected = "x" },
    .{ .pattern = "(?<=\\1(\u{DF}))x", .unicode = false, .input = "\u{1E9E}\u{DF}x", .expected = null },
    .{ .pattern = "(?<=\\1(\u{DF}))x", .unicode = true, .input = "\u{1E9E}\u{DF}x", .expected = "x" },
    .{ .pattern = "(?<=\\1(.))x", .unicode = false, .input = "\u{23A}\u{2C65}x", .expected = "x" },
};

test "pattern backreference: ECMAScript ignoreCase compares canonicalized characters" {
    const allocator = std.testing.allocator;
    for (ignore_case_backref_cases) |c| {
        var regex = try Regex.compileWithFlags(allocator, c.pattern, .{ .case_insensitive = true, .ecmascript = true, .unicode = c.unicode });
        defer regex.deinit();
        var found = try regex.find(c.input);
        defer if (found) |*m| m.deinit(allocator);
        if (c.expected) |want| {
            const m = found orelse {
                std.debug.print("no match: /{s}/{s} on {s}\n", .{ c.pattern, if (c.unicode) "iu" else "i", c.input });
                return error.TestExpectedMatch;
            };
            try std.testing.expectEqualStrings(want, m.slice);
        } else if (found) |m| {
            std.debug.print("unexpected match {s}: /{s}/{s} on {s}\n", .{ m.slice, c.pattern, if (c.unicode) "iu" else "i", c.input });
            return error.TestUnexpectedMatch;
        }
    }
}

test "pattern backreference: non-ECMAScript ignoreCase keeps its ASCII-only comparison" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compileWithFlags(allocator, "(\u{E0})\\1", .{ .case_insensitive = true });
    defer regex.deinit();
    try std.testing.expect(!try regex.isMatch("\u{E0}\u{C0}"));
    try std.testing.expect(try regex.isMatch("\u{E0}\u{E0}"));
}

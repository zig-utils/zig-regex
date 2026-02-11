const std = @import("std");
const Regex = @import("regex").Regex;
const RegexError = @import("regex").RegexError;

// =============================================================================
// Stress tests and deep edge cases
// =============================================================================

// --- Empty and trivial patterns ---

test "stress: empty alternation branch" {
    const allocator = std.testing.allocator;
    // Pattern like (|a) should match empty string or "a"
    var regex = try Regex.compile(allocator, "^(|a)$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch(""));
    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(!try regex.isMatch("b"));
}

test "stress: pattern that only matches empty string" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch(""));
    try std.testing.expect(!try regex.isMatch("a"));
    try std.testing.expect(!try regex.isMatch(" "));
}

test "stress: dot star matches everything" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, ".*");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch(""));
    try std.testing.expect(try regex.isMatch("anything"));
    try std.testing.expect(try regex.isMatch("!@#$%^&*()"));
}

test "stress: single dot" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^.$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("1"));
    try std.testing.expect(try regex.isMatch(" "));
    try std.testing.expect(!try regex.isMatch(""));
    try std.testing.expect(!try regex.isMatch("ab"));
}

// --- Quantifier boundary conditions ---

test "stress: {1,1} is same as no quantifier" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^a{1,1}$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(!try regex.isMatch(""));
    try std.testing.expect(!try regex.isMatch("aa"));
}

test "stress: {2,} matches 2 or more" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^a{2,}$");
    defer regex.deinit();

    try std.testing.expect(!try regex.isMatch(""));
    try std.testing.expect(!try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("aa"));
    try std.testing.expect(try regex.isMatch("aaa"));
    try std.testing.expect(try regex.isMatch("aaaaaaaaaa"));
}

test "stress: exact repeat {5}" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^x{5}$");
    defer regex.deinit();

    try std.testing.expect(!try regex.isMatch("xxxx"));
    try std.testing.expect(try regex.isMatch("xxxxx"));
    try std.testing.expect(!try regex.isMatch("xxxxxx"));
}

test "stress: mixed quantifiers in sequence" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^a+b*c?d{2}$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("add"));
    try std.testing.expect(try regex.isMatch("aabbbcdd"));
    try std.testing.expect(try regex.isMatch("aabcdd"));
    try std.testing.expect(!try regex.isMatch("bdd"));
    try std.testing.expect(!try regex.isMatch("ad"));
}

// --- Character class edge cases ---

test "stress: character class with hyphen at start" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^[-abc]+$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("-"));
    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("-abc"));
    try std.testing.expect(!try regex.isMatch("d"));
}

test "stress: character class with hyphen at end" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^[abc-]+$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("-"));
    try std.testing.expect(try regex.isMatch("a-b-c"));
}

test "stress: negated character class" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^[^abc]+$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("xyz"));
    try std.testing.expect(try regex.isMatch("123"));
    try std.testing.expect(!try regex.isMatch("a"));
    try std.testing.expect(!try regex.isMatch("xay"));
}

test "stress: character class with single char range" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^[a-a]+$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("aaa"));
    try std.testing.expect(!try regex.isMatch("b"));
}

test "stress: overlapping ranges in character class" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^[a-zA-Z]+$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("hello"));
    try std.testing.expect(try regex.isMatch("HELLO"));
    try std.testing.expect(try regex.isMatch("HeLLo"));
    try std.testing.expect(!try regex.isMatch("hello123"));
}

test "stress: shorthand classes \\d \\w \\s" {
    const allocator = std.testing.allocator;
    {
        var regex = try Regex.compile(allocator, "^\\d+$");
        defer regex.deinit();
        try std.testing.expect(try regex.isMatch("12345"));
        try std.testing.expect(!try regex.isMatch("abc"));
        try std.testing.expect(!try regex.isMatch(""));
    }
    {
        var regex = try Regex.compile(allocator, "^\\w+$");
        defer regex.deinit();
        try std.testing.expect(try regex.isMatch("hello_123"));
        try std.testing.expect(!try regex.isMatch("hello world"));
    }
    {
        var regex = try Regex.compile(allocator, "^\\s+$");
        defer regex.deinit();
        try std.testing.expect(try regex.isMatch("   "));
        try std.testing.expect(try regex.isMatch("\t\n"));
        try std.testing.expect(!try regex.isMatch("a"));
    }
}

test "stress: negated shorthand classes \\D \\W \\S" {
    const allocator = std.testing.allocator;
    {
        var regex = try Regex.compile(allocator, "^\\D+$");
        defer regex.deinit();
        try std.testing.expect(try regex.isMatch("abc"));
        try std.testing.expect(!try regex.isMatch("123"));
    }
    {
        var regex = try Regex.compile(allocator, "^\\W+$");
        defer regex.deinit();
        try std.testing.expect(try regex.isMatch(" !@#"));
        try std.testing.expect(!try regex.isMatch("abc"));
    }
    {
        var regex = try Regex.compile(allocator, "^\\S+$");
        defer regex.deinit();
        try std.testing.expect(try regex.isMatch("abc"));
        try std.testing.expect(!try regex.isMatch("a b"));
    }
}

// --- Anchor edge cases ---

test "stress: ^ only matches at start" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^abc");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("abcdef"));
    try std.testing.expect(!try regex.isMatch("xabc"));
}

test "stress: $ only matches at end" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "abc$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("xyzabc"));
    try std.testing.expect(!try regex.isMatch("abcx"));
}

test "stress: ^$ on empty string" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch(""));
    try std.testing.expect(!try regex.isMatch("a"));
}

test "stress: word boundary \\b" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\bword\\b");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a word here"));
    try std.testing.expect(try regex.isMatch("word"));
    try std.testing.expect(!try regex.isMatch("password"));
    try std.testing.expect(!try regex.isMatch("wordy"));
}

test "stress: non-word boundary \\B" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\Bword\\B");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("swordwords"));
    try std.testing.expect(!try regex.isMatch("word"));
    try std.testing.expect(!try regex.isMatch("a word"));
}

// --- Alternation edge cases ---

test "stress: alternation with different lengths" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^(a|bb|ccc)$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("bb"));
    try std.testing.expect(try regex.isMatch("ccc"));
    try std.testing.expect(!try regex.isMatch("b"));
    try std.testing.expect(!try regex.isMatch("cc"));
}

test "stress: nested alternation" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^(a(b|c)d|efg)$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("abd"));
    try std.testing.expect(try regex.isMatch("acd"));
    try std.testing.expect(try regex.isMatch("efg"));
    try std.testing.expect(!try regex.isMatch("aed"));
    try std.testing.expect(!try regex.isMatch("abg"));
}

test "stress: NFA finds longest match for alternation" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "cat|catfish");
    defer regex.deinit();

    if (try regex.find("catfish")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        // NFA greedy matching: finds longest match "catfish"
        try std.testing.expectEqualStrings("catfish", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

// --- Capture group edge cases ---

test "stress: capture group with alternation - only one branch matches" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(a)|(b)");
    defer regex.deinit();

    if (try regex.find("b")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("b", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "stress: nested capture groups" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "((a)(b))");
    defer regex.deinit();

    if (try regex.find("ab")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("ab", match.slice);
        // Captures: $1="ab", $2="a", $3="b"
        try std.testing.expect(match.captures.len >= 3);
        try std.testing.expectEqualStrings("ab", match.captures[0]);
        try std.testing.expectEqualStrings("a", match.captures[1]);
        try std.testing.expectEqualStrings("b", match.captures[2]);
    } else {
        return error.TestExpectedMatch;
    }
}

test "stress: capture with quantifier" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(a)+");
    defer regex.deinit();

    if (try regex.find("aaa")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("aaa", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

// --- findAll edge cases ---

test "stress: findAll with no matches" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "xyz");
    defer regex.deinit();

    const matches = try regex.findAll(allocator, "abc def ghi");
    defer {
        for (matches) |*m| {
            var mut_m = m;
            mut_m.deinit(allocator);
        }
        allocator.free(matches);
    }

    try std.testing.expectEqual(@as(usize, 0), matches.len);
}

test "stress: findAll adjacent matches" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\d");
    defer regex.deinit();

    const matches = try regex.findAll(allocator, "123");
    defer {
        for (matches) |*m| {
            var mut_m = m;
            mut_m.deinit(allocator);
        }
        allocator.free(matches);
    }

    try std.testing.expectEqual(@as(usize, 3), matches.len);
    try std.testing.expectEqualStrings("1", matches[0].slice);
    try std.testing.expectEqualStrings("2", matches[1].slice);
    try std.testing.expectEqualStrings("3", matches[2].slice);
}

test "stress: findAll non-overlapping" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "aa");
    defer regex.deinit();

    const matches = try regex.findAll(allocator, "aaaa");
    defer {
        for (matches) |*m| {
            var mut_m = m;
            mut_m.deinit(allocator);
        }
        allocator.free(matches);
    }

    // "aaaa" should find "aa" at 0 and "aa" at 2 (non-overlapping)
    try std.testing.expectEqual(@as(usize, 2), matches.len);
}

// --- Replace edge cases ---

test "stress: replace with no match returns input" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "xyz");
    defer regex.deinit();

    const result = try regex.replace(allocator, "hello world", "!");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "stress: replace with empty replacement" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\s+");
    defer regex.deinit();

    const result = try regex.replace(allocator, "hello world", "");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("helloworld", result);
}

test "stress: replaceAll removes all matches" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\d");
    defer regex.deinit();

    const result = try regex.replaceAll(allocator, "a1b2c3", "");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("abc", result);
}

test "stress: replace with $$ escaped dollar" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "price");
    defer regex.deinit();

    const result = try regex.replace(allocator, "the price is", "$$5");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("the $5 is", result);
}

// --- split edge cases ---

test "stress: split with no match returns whole string" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, ",");
    defer regex.deinit();

    const parts = try regex.split(allocator, "hello");
    defer allocator.free(parts);

    try std.testing.expectEqual(@as(usize, 1), parts.len);
    try std.testing.expectEqualStrings("hello", parts[0]);
}

test "stress: split on every character" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, ",");
    defer regex.deinit();

    const parts = try regex.split(allocator, "a,b,c");
    defer allocator.free(parts);

    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualStrings("a", parts[0]);
    try std.testing.expectEqualStrings("b", parts[1]);
    try std.testing.expectEqualStrings("c", parts[2]);
}

test "stress: split with regex separator" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\s*,\\s*");
    defer regex.deinit();

    const parts = try regex.split(allocator, "a , b , c");
    defer allocator.free(parts);

    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualStrings("a", parts[0]);
    try std.testing.expectEqualStrings("b", parts[1]);
    try std.testing.expectEqualStrings("c", parts[2]);
}

// --- Escape sequence edge cases ---

test "stress: escaped special characters" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\(\\)\\[\\]\\{\\}");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("()[]{}"));
    try std.testing.expect(!try regex.isMatch("abc"));
}

test "stress: escaped dot matches literal dot" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a\\.b");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a.b"));
    try std.testing.expect(!try regex.isMatch("axb"));
}

test "stress: escaped backslash" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\\\");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("\\"));
    try std.testing.expect(!try regex.isMatch("a"));
}

// --- Long input stress ---

test "stress: match at end of long input" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "needle");
    defer regex.deinit();

    // Build a long haystack with needle at the very end
    var buf: [1024]u8 = undefined;
    @memset(buf[0..1018], 'x');
    @memcpy(buf[1018..1024], "needle");

    if (try regex.find(buf[0..1024])) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1018), match.start);
        try std.testing.expectEqualStrings("needle", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "stress: no match in long input" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "needle");
    defer regex.deinit();

    var buf: [1024]u8 = undefined;
    @memset(&buf, 'x');

    try std.testing.expect(!try regex.isMatch(&buf));
}

// --- Multiline and dot-all edge cases ---

test "stress: multiline ^ matches after each newline" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compileWithFlags(allocator, "^\\w+", .{ .multiline = true });
    defer regex.deinit();

    const matches = try regex.findAll(allocator, "hello\nworld\nfoo");
    defer {
        for (matches) |*m| {
            var mut_m = m;
            mut_m.deinit(allocator);
        }
        allocator.free(matches);
    }

    try std.testing.expectEqual(@as(usize, 3), matches.len);
    try std.testing.expectEqualStrings("hello", matches[0].slice);
    try std.testing.expectEqualStrings("world", matches[1].slice);
    try std.testing.expectEqualStrings("foo", matches[2].slice);
}

test "stress: dot does not match newline by default - find first line" {
    const allocator = std.testing.allocator;
    // Without multiline, $ only matches at end of input
    // So .+ matches "hello" but $ doesn't match at position 5
    // Use multiline to match lines, or just test .+ without $
    var regex = try Regex.compile(allocator, ".+");
    defer regex.deinit();

    if (try regex.find("hello\nworld")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        // dot doesn't match \n, so .+ stops at "hello"
        try std.testing.expectEqualStrings("hello", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "stress: dot_all makes dot match newline" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compileWithFlags(allocator, "^.+$", .{ .dot_all = true });
    defer regex.deinit();

    if (try regex.find("hello\nworld")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("hello\nworld", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

// --- Case insensitive edge cases ---

test "stress: case insensitive literal" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compileWithFlags(allocator, "hello", .{ .case_insensitive = true });
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("HELLO"));
    try std.testing.expect(try regex.isMatch("Hello"));
    try std.testing.expect(try regex.isMatch("hElLo"));
}

// --- Error handling edge cases ---

test "stress: unmatched closing paren" {
    const allocator = std.testing.allocator;
    const result = Regex.compile(allocator, "abc)");
    try std.testing.expectError(RegexError.UnmatchedParenthesis, result);
}

test "stress: unmatched opening paren" {
    const allocator = std.testing.allocator;
    const result = Regex.compile(allocator, "(abc");
    try std.testing.expectError(RegexError.UnexpectedCharacter, result);
}

test "stress: unmatched bracket" {
    const allocator = std.testing.allocator;
    const result = Regex.compile(allocator, "[abc");
    try std.testing.expectError(RegexError.UnexpectedCharacter, result);
}

test "stress: quantifier star at start" {
    const allocator = std.testing.allocator;
    const result = Regex.compile(allocator, "*abc");
    try std.testing.expectError(RegexError.UnexpectedCharacter, result);
}

test "stress: quantifier plus at start" {
    const allocator = std.testing.allocator;
    const result = Regex.compile(allocator, "+abc");
    try std.testing.expectError(RegexError.UnexpectedCharacter, result);
}

test "stress: empty character class" {
    const allocator = std.testing.allocator;
    // [] followed by ] - parser sees empty class then stray ]
    if (Regex.compile(allocator, "[]")) |*r| {
        var mut_r = r.*;
        mut_r.deinit();
    } else |_| {
        // Error is expected
    }
}

// --- Greedy vs non-greedy from NFA ---

test "stress: greedy star matches longest" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a.*b");
    defer regex.deinit();

    if (try regex.find("aXXbYYb")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        // Greedy: should match "aXXbYYb" (longest)
        try std.testing.expectEqualStrings("aXXbYYb", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "stress: complex pattern with multiple features" {
    const allocator = std.testing.allocator;
    // Email-like pattern with captures
    var regex = try Regex.compile(allocator, "([a-zA-Z0-9.]+)@([a-zA-Z0-9]+)\\.([a-zA-Z]{2,})");
    defer regex.deinit();

    if (try regex.find("contact: user.name@example.com today")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("user.name@example.com", match.slice);
        try std.testing.expect(match.captures.len >= 3);
        try std.testing.expectEqualStrings("user.name", match.captures[0]);
        try std.testing.expectEqualStrings("example", match.captures[1]);
        try std.testing.expectEqualStrings("com", match.captures[2]);
    } else {
        return error.TestExpectedMatch;
    }
}

// --- Repeated pattern compilation (memory test) ---

test "stress: compile many patterns sequentially" {
    const allocator = std.testing.allocator;

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var regex = try Regex.compile(allocator, "test\\d+");
        defer regex.deinit();
        try std.testing.expect(try regex.isMatch("test123"));
    }
}

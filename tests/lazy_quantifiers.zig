const std = @import("std");
const Regex = @import("regex").Regex;

// Tests for lazy/non-greedy quantifiers (*?, +?, ??, {m,n}?)
//
// Key principle: lazy quantifiers try the minimum first, but WILL backtrack
// at the same starting position before the engine moves to a new position.
// This means `a*?b` on "aaab" matches "aaab" (not "b"), because at position 0,
// `a*?` must expand to consume all 3 'a's before `b` can match.
//
// Lazy quantifiers make a difference when the delimiter after them can match
// at MULTIPLE positions, e.g. `<.*?>` on "<a><b>" matches "<a>" (not "<a><b>").

test "lazy star: a*?b backtracks at same position" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a*?b");
    defer regex.deinit();

    // At pos 0: a*? tries 0, b fails on 'a'. Backtracks to 1, 2, 3 a's, then b matches.
    if (try regex.find("aaab")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("aaab", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "lazy star vs greedy star with multiple delimiters" {
    const allocator = std.testing.allocator;

    // Greedy: matches as much as possible between first < and LAST >
    var greedy = try Regex.compile(allocator, "<.*>");
    defer greedy.deinit();

    if (try greedy.find("<a><b>")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("<a><b>", match.slice);
    } else {
        return error.TestExpectedMatch;
    }

    // Lazy: matches as little as possible - stops at FIRST >
    var lazy = try Regex.compile(allocator, "<.*?>");
    defer lazy.deinit();

    if (try lazy.find("<a><b>")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("<a>", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "lazy plus: a+?b backtracks at same position" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a+?b");
    defer regex.deinit();

    // At pos 0: a+? matches 1 'a', b fails. Backtracks to 2, 3 a's, then b matches.
    if (try regex.find("aaab")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("aaab", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "lazy plus vs greedy plus with multiple delimiters" {
    const allocator = std.testing.allocator;

    // Greedy: matches maximum between delimiters
    var greedy = try Regex.compile(allocator, "\\[.+\\]");
    defer greedy.deinit();

    if (try greedy.find("[a][b]")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("[a][b]", match.slice);
    } else {
        return error.TestExpectedMatch;
    }

    // Lazy: stops at first closing delimiter
    var lazy = try Regex.compile(allocator, "\\[.+?\\]");
    defer lazy.deinit();

    if (try lazy.find("[a][b]")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("[a]", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "lazy optional: a??b backtracks at same position" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a??b");
    defer regex.deinit();

    // At pos 0 of "ab": a?? tries 0, b fails on 'a'. Backtracks to match 'a', then b matches.
    if (try regex.find("ab")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("ab", match.slice);
    } else {
        return error.TestExpectedMatch;
    }

    // On "bab": at pos 0, a?? tries 0, b matches. Result: "b"
    if (try regex.find("bab")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("b", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "lazy repeat: a{2,4}? matches minimal when possible" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a{2,4}?b");
    defer regex.deinit();

    // "aab" - exactly 2 a's then b: lazy matches "aab"
    if (try regex.find("aab")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("aab", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "lazy repeat vs greedy repeat with multiple delimiters" {
    const allocator = std.testing.allocator;

    // Greedy: at pos 0, tries 4 chars first, then 3, then 2 - "xaax" matches (2 chars)
    var greedy = try Regex.compile(allocator, "x.{2,4}x");
    defer greedy.deinit();

    if (try greedy.find("xaaxbbx")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        // Both greedy and lazy find "xaax" as leftmost match
        try std.testing.expectEqualStrings("xaax", match.slice);
    } else {
        return error.TestExpectedMatch;
    }

    // Lazy: same result here since "xaax" is the leftmost match
    var lazy = try Regex.compile(allocator, "x.{2,4}?x");
    defer lazy.deinit();

    if (try lazy.find("xaaxbbx")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("xaax", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "lazy quantifier in alternation" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a*?b|c");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("b"));
    try std.testing.expect(try regex.isMatch("c"));
    try std.testing.expect(try regex.isMatch("aaab"));
}

test "multiple lazy quantifiers" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a*?b+?c");
    defer regex.deinit();

    // At pos 0 of "aaabbbbc": a*? starts with 0, b+? matches 1 'b'... but then 'c' fails.
    // Backtracking extends b+?, then a*?, until match is found.
    if (try regex.find("aaabbbbc")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("aaabbbbc", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "lazy quantifier with character class" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[a-z]+?\\d");
    defer regex.deinit();

    // At pos 0: [a-z]+? matches 1 char, then \d checks pos 1.
    // 'b' is not a digit, so backtrack: match 2, check pos 2... 'c' not digit...
    // match 3, check pos 3: '1' is digit! Match: "abc1"
    if (try regex.find("abc123")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("abc1", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "lazy star with dot" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, ".*?x");
    defer regex.deinit();

    // At pos 0: .*? tries 0, x fails on 'a'. Tries 1,2,3 then x matches.
    if (try regex.find("abcxyz")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("abcx", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "lazy quantifier in capture group" {
    const allocator = std.testing.allocator;
    // Use a pattern where lazy makes a difference: delimiters on both sides
    var regex = try Regex.compile(allocator, "\\((.+?)\\)");
    defer regex.deinit();

    if (try regex.find("(hello)(world)")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("(hello)", match.slice);
        try std.testing.expectEqual(@as(usize, 1), match.captures.len);
        try std.testing.expectEqualStrings("hello", match.captures[0]);
    } else {
        return error.TestExpectedMatch;
    }
}

test "lazy repeat {n,}?" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a{2,}?b");
    defer regex.deinit();

    // "aab": 2 a's then b, lazy matches minimum (2)
    if (try regex.find("aab")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("aab", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "lazy quantifier backtracking" {
    const allocator = std.testing.allocator;
    // Even though lazy, it must backtrack if necessary to match
    var regex = try Regex.compile(allocator, "a*?aab");
    defer regex.deinit();

    if (try regex.find("aaab")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        // a*? starts with 0, but must match at least 1 'a' to allow 'aab' to match
        try std.testing.expectEqualStrings("aaab", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "lazy quantifier at end of pattern" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a+?");
    defer regex.deinit();

    if (try regex.find("aaa")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        // Lazy at end still matches minimal
        try std.testing.expectEqualStrings("a", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "lazy vs greedy performance comparison" {
    const allocator = std.testing.allocator;

    const input = "a" ** 100 ++ "b";

    // Both should match the entire input since 'b' only appears at the end
    var greedy = try Regex.compile(allocator, "a*b");
    defer greedy.deinit();

    var lazy = try Regex.compile(allocator, "a*?b");
    defer lazy.deinit();

    // Greedy matches all 100 'a's + 'b'
    if (try greedy.find(input)) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 101), match.slice.len);
    } else {
        return error.TestExpectedMatch;
    }

    // Lazy also matches all 100 'a's + 'b' (b only at end, must backtrack)
    if (try lazy.find(input)) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 101), match.slice.len);
    } else {
        return error.TestExpectedMatch;
    }
}

// ============================================================================
// Regression tests for: https://github.com/zig-utils/zig-regex/issues/1
// Lazy quantifier .*? in $t\((.*?)\) should find minimal matches
// ============================================================================

test "regression: lazy dot-star with parentheses - findAll" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\$t\\((.*?)\\)");
    defer regex.deinit();

    const target = "$t(common.hello) abc $t(common.name)";
    const matches = try regex.findAll(allocator, target);
    defer {
        for (matches) |*m| {
            var mut_m = m;
            mut_m.deinit(allocator);
        }
        allocator.free(matches);
    }

    // Should find 2 matches, not 0 or 1
    try std.testing.expectEqual(@as(usize, 2), matches.len);

    // First match: $t(common.hello)
    try std.testing.expectEqualStrings("$t(common.hello)", matches[0].slice);
    try std.testing.expectEqual(@as(usize, 1), matches[0].captures.len);
    try std.testing.expectEqualStrings("common.hello", matches[0].captures[0]);

    // Second match: $t(common.name)
    try std.testing.expectEqualStrings("$t(common.name)", matches[1].slice);
    try std.testing.expectEqual(@as(usize, 1), matches[1].captures.len);
    try std.testing.expectEqualStrings("common.name", matches[1].captures[0]);
}

test "regression: greedy dot-star with parentheses matches too much" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\$t\\((.*)\\)");
    defer regex.deinit();

    const target = "$t(common.hello) abc $t(common.name)";
    const matches = try regex.findAll(allocator, target);
    defer {
        for (matches) |*m| {
            var mut_m = m;
            mut_m.deinit(allocator);
        }
        allocator.free(matches);
    }

    // Greedy .* matches from first ( to LAST ), so only 1 match
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("common.hello) abc $t(common.name", matches[0].captures[0]);
}

test "regression: lazy dot-star with adjacent matches" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\$t\\((.*?)\\)");
    defer regex.deinit();

    // Adjacent matches with no space between them
    const target = "$t(common.hello)$t(common.name)";
    const matches = try regex.findAll(allocator, target);
    defer {
        for (matches) |*m| {
            var mut_m = m;
            mut_m.deinit(allocator);
        }
        allocator.free(matches);
    }

    try std.testing.expectEqual(@as(usize, 2), matches.len);

    try std.testing.expectEqualStrings("$t(common.hello)", matches[0].slice);
    try std.testing.expectEqualStrings("common.hello", matches[0].captures[0]);

    try std.testing.expectEqualStrings("$t(common.name)", matches[1].slice);
    try std.testing.expectEqualStrings("common.name", matches[1].captures[0]);
}

test "regression: non-greedy S-star workaround also works for adjacent" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\$t\\((\\S*?)\\)");
    defer regex.deinit();

    // The \S* workaround should also work for adjacent matches
    const target = "$t(common.hello)$t(common.name)";
    const matches = try regex.findAll(allocator, target);
    defer {
        for (matches) |*m| {
            var mut_m = m;
            mut_m.deinit(allocator);
        }
        allocator.free(matches);
    }

    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqualStrings("common.hello", matches[0].captures[0]);
    try std.testing.expectEqualStrings("common.name", matches[1].captures[0]);
}

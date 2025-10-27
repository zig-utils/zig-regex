const std = @import("std");
const Regex = @import("regex").Regex;

// Tests for lazy/non-greedy quantifiers (*?, +?, ??, {m,n}?)

test "lazy star: a*? matches minimal" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a*?b");
    defer regex.deinit();

    // Greedy would match "aaab", lazy should match "b"
    if (try regex.find("aaab")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("b", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "lazy star vs greedy star" {
    const allocator = std.testing.allocator;

    // Greedy star
    var greedy = try Regex.compile(allocator, "a*b");
    defer greedy.deinit();

    if (try greedy.find("aaab")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        // Greedy matches as many 'a's as possible
        try std.testing.expectEqualStrings("aaab", match.slice);
    } else {
        return error.TestExpectedMatch;
    }

    // Lazy star
    var lazy = try Regex.compile(allocator, "a*?b");
    defer lazy.deinit();

    if (try lazy.find("aaab")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        // Lazy matches as few 'a's as possible (zero)
        try std.testing.expectEqualStrings("b", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "lazy plus: a+? matches minimal (at least one)" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a+?b");
    defer regex.deinit();

    // Lazy plus must match at least one 'a'
    if (try regex.find("aaab")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("ab", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "lazy plus vs greedy plus" {
    const allocator = std.testing.allocator;

    // Greedy plus
    var greedy = try Regex.compile(allocator, "a+b");
    defer greedy.deinit();

    if (try greedy.find("aaab")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        // Greedy matches as many 'a's as possible
        try std.testing.expectEqualStrings("aaab", match.slice);
    } else {
        return error.TestExpectedMatch;
    }

    // Lazy plus
    var lazy = try Regex.compile(allocator, "a+?b");
    defer lazy.deinit();

    if (try lazy.find("aaab")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        // Lazy matches minimal (one 'a')
        try std.testing.expectEqualStrings("ab", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "lazy optional: a?? matches minimal (zero)" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a??b");
    defer regex.deinit();

    // Lazy optional prefers zero matches
    if (try regex.find("ab")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("b", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "lazy optional vs greedy optional" {
    const allocator = std.testing.allocator;

    // Greedy optional
    var greedy = try Regex.compile(allocator, "a?b");
    defer greedy.deinit();

    if (try greedy.find("ab")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        // Greedy matches the 'a'
        try std.testing.expectEqualStrings("ab", match.slice);
    } else {
        return error.TestExpectedMatch;
    }

    // Lazy optional
    var lazy = try Regex.compile(allocator, "a??b");
    defer lazy.deinit();

    if (try lazy.find("ab")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        // Lazy prefers to skip the 'a'
        try std.testing.expectEqualStrings("b", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "lazy repeat: a{2,4}? matches minimal" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a{2,4}?b");
    defer regex.deinit();

    // Lazy repeat matches minimum (2 'a's)
    if (try regex.find("aaaaab")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("aab", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "lazy repeat vs greedy repeat" {
    const allocator = std.testing.allocator;

    // Greedy repeat
    var greedy = try Regex.compile(allocator, "a{2,4}b");
    defer greedy.deinit();

    if (try greedy.find("aaaaab")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        // Greedy matches maximum (4 'a's)
        try std.testing.expectEqualStrings("aaaab", match.slice);
    } else {
        return error.TestExpectedMatch;
    }

    // Lazy repeat
    var lazy = try Regex.compile(allocator, "a{2,4}?b");
    defer lazy.deinit();

    if (try lazy.find("aaaaab")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        // Lazy matches minimum (2 'a's)
        try std.testing.expectEqualStrings("aab", match.slice);
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

    if (try regex.find("aaabbbbc")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        // a*? matches zero, b+? matches one
        try std.testing.expectEqualStrings("bc", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "lazy quantifier with character class" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[a-z]+?\\d");
    defer regex.deinit();

    if (try regex.find("abc123")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        // Lazy plus matches minimal letters before digit
        try std.testing.expectEqualStrings("a1", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "lazy star with dot" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, ".*?x");
    defer regex.deinit();

    if (try regex.find("abcxyz")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        // Lazy .* matches minimal chars before 'x'
        try std.testing.expectEqualStrings("abcx", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "lazy quantifier in capture group" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(a+?)b");
    defer regex.deinit();

    if (try regex.find("aaab")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("ab", match.slice);

        // Check capture group captured minimal
        try std.testing.expectEqual(@as(usize, 1), match.captures.len);
        try std.testing.expectEqualStrings("a", match.captures[0]);
    } else {
        return error.TestExpectedMatch;
    }
}

test "lazy repeat {n,}?" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a{2,}?b");
    defer regex.deinit();

    if (try regex.find("aaaaab")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        // {2,}? matches minimum (2)
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

test "nested lazy quantifiers" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(a*?b+?)*?c");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("c"));
    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(try regex.isMatch("ababbc"));
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

    // Both should match, but with different lengths
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

    // Lazy matches zero 'a's + 'b'
    if (try lazy.find(input)) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), match.slice.len);
    } else {
        return error.TestExpectedMatch;
    }
}

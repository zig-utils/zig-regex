const std = @import("std");
const Regex = @import("regex").Regex;
const RegexError = @import("regex").RegexError;

// =============================================================================
// Regression tests for specific fixes applied to the codebase
// =============================================================================

// --- $0 replacement (full match) ---

test "regression: $0 replacement expands to full match" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\d+");
    defer regex.deinit();

    const result = try regex.replace(allocator, "abc 123 def", "[$0]");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("abc [123] def", result);
}

test "regression: $0 replacement with captures" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\w+)@(\\w+)");
    defer regex.deinit();

    const result = try regex.replace(allocator, "email: user@host ok", "match=$0,user=$1,host=$2");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("email: match=user@host,user=user,host=host ok", result);
}

test "regression: $0 in replaceAll" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\w+");
    defer regex.deinit();

    const result = try regex.replaceAll(allocator, "a b c", "[$0]");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("[a] [b] [c]", result);
}

// --- Case-insensitive backreference ---

test "regression: case-insensitive backreference" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compileWithFlags(allocator, "(\\w+) \\1", .{ .case_insensitive = true });
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("hello HELLO"));
    try std.testing.expect(try regex.isMatch("ABC abc"));
    try std.testing.expect(try regex.isMatch("Test Test"));
}

test "regression: case-sensitive backreference rejects case mismatch" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\w+) \\1");
    defer regex.deinit();

    try std.testing.expect(!try regex.isMatch("hello HELLO"));
    try std.testing.expect(try regex.isMatch("hello hello"));
}

// --- min > max quantifier rejection ---

test "regression: {10,5} is rejected as invalid" {
    const allocator = std.testing.allocator;
    const result = Regex.compile(allocator, "a{10,5}");
    try std.testing.expectError(RegexError.InvalidQuantifier, result);
}

test "regression: {5,3} is rejected" {
    const allocator = std.testing.allocator;
    const result = Regex.compile(allocator, "x{5,3}");
    try std.testing.expectError(RegexError.InvalidQuantifier, result);
}

test "regression: {3,3} is accepted (min == max)" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a{3,3}");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("aaa"));
    try std.testing.expect(!try regex.isMatch("aa"));
}

// --- {0,n} quantifier correctness ---

test "regression: {0,3} matches 0 to 3 occurrences" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^a{0,3}$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch(""));
    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("aa"));
    try std.testing.expect(try regex.isMatch("aaa"));
    try std.testing.expect(!try regex.isMatch("aaaa"));
}

test "regression: {0,1} is equivalent to ?" {
    const allocator = std.testing.allocator;
    var regex1 = try Regex.compile(allocator, "^ab{0,1}c$");
    defer regex1.deinit();
    var regex2 = try Regex.compile(allocator, "^ab?c$");
    defer regex2.deinit();

    const inputs = [_][]const u8{ "ac", "abc", "abbc", "" };
    for (inputs) |input| {
        try std.testing.expectEqual(try regex1.isMatch(input), try regex2.isMatch(input));
    }
}

test "regression: {0,0} matches empty only" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^a{0,0}b$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("b"));
    try std.testing.expect(!try regex.isMatch("ab"));
}

// --- Prefix optimization searches all positions ---

test "regression: prefix optimization finds match after false prefix start" {
    const allocator = std.testing.allocator;
    // Pattern with prefix "ab" - but first "ab" at position 0 doesn't complete the full match
    var regex = try Regex.compile(allocator, "abc\\d+");
    defer regex.deinit();

    // "ab" appears at position 0, but "abc" + digits is only at position 5
    if (try regex.find("ab   abc123 end")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("abc123", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

// --- Step counter reset per position ---

test "regression: backtrack step counter resets between positions" {
    const allocator = std.testing.allocator;
    // This pattern uses backtracking via backreference.
    var regex = try Regex.compile(allocator, "(\\w+) \\1");
    defer regex.deinit();

    // Verify basic backreference works
    try std.testing.expect(try regex.isMatch("hello hello"));

    // Match appears after some non-matching prefix
    if (try regex.find("abc def hello hello xyz")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("hello hello", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

// --- deinit safety ---

test "regression: deinit on regex that was never used" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "test");
    regex.deinit();
    // Should not crash - just testing that deinit works without any find/match calls
}

test "regression: double pattern compile and deinit" {
    const allocator = std.testing.allocator;
    {
        var regex = try Regex.compile(allocator, "abc");
        defer regex.deinit();
        try std.testing.expect(try regex.isMatch("abc"));
    }
    {
        var regex = try Regex.compile(allocator, "def");
        defer regex.deinit();
        try std.testing.expect(try regex.isMatch("def"));
    }
}

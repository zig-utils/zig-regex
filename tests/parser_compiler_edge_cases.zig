const std = @import("std");
const Regex = @import("regex").Regex;
const RegexError = @import("regex").RegexError;

// =============================================================================
// Parser and compiler edge cases - invalid patterns, boundary syntax, etc.
// =============================================================================

// --- Invalid pattern rejection ---

test "parser: quantifier ? at start is rejected" {
    const allocator = std.testing.allocator;
    const result = Regex.compile(allocator, std.testing.io, "?abc");
    try std.testing.expectError(RegexError.UnexpectedCharacter, result);
}

test "parser: nested empty groups" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "(())");
    defer regex.deinit();
    // Should compile without error
    try std.testing.expect(try regex.isMatch(""));
}

test "parser: deeply nested groups" {
    const allocator = std.testing.allocator;
    // 20 levels of nesting - should be within limits
    var regex = try Regex.compile(allocator, std.testing.io, "((((((((((((((((((((a))))))))))))))))))))");
    defer regex.deinit();
    try std.testing.expect(try regex.isMatch("a"));
}

test "parser: consecutive quantifiers rejected by analyzer" {
    const allocator = std.testing.allocator;
    // a** parses as (a*)* which is rejected as nested quantifiers
    const result = Regex.compile(allocator, std.testing.io, "a**");
    try std.testing.expectError(RegexError.PatternTooComplex, result);
}

test "parser: quantifier on quantifier rejected by analyzer" {
    const allocator = std.testing.allocator;
    // a+* parses as (a+)* which is rejected as nested quantifiers
    const result = Regex.compile(allocator, std.testing.io, "a+*");
    try std.testing.expectError(RegexError.PatternTooComplex, result);
}

test "parser: empty alternation branch is valid" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "a|");
    defer regex.deinit();
    // "a|" means "a or empty string" - should match empty
    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch(""));
}

test "parser: leading pipe alternation" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "|a");
    defer regex.deinit();
    // "|a" means "empty string or a"
    try std.testing.expect(try regex.isMatch(""));
    try std.testing.expect(try regex.isMatch("a"));
}

// --- Quantifier syntax edge cases ---

test "parser: {0} means zero occurrences" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "^a{0}b$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("b"));
    try std.testing.expect(!try regex.isMatch("ab"));
}

test "parser: {1} means exactly once" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "^a{1}$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(!try regex.isMatch("aa"));
    try std.testing.expect(!try regex.isMatch(""));
}

test "parser: large but valid quantifier" {
    const allocator = std.testing.allocator;
    // {0,100} should be valid
    var regex = try Regex.compile(allocator, std.testing.io, "a{0,100}");
    defer regex.deinit();
    try std.testing.expect(try regex.isMatch(""));
}

// --- Character class syntax edge cases ---

test "parser: character class with escaped ]" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "[\\]]");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("]"));
    try std.testing.expect(!try regex.isMatch("a"));
}

test "parser: character class with hyphen between ranges" {
    const allocator = std.testing.allocator;
    // Hyphen at start is literal, not range
    var regex = try Regex.compile(allocator, std.testing.io, "[-az]");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("-"));
    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("z"));
    try std.testing.expect(!try regex.isMatch("m"));
}

test "parser: negated class with range" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "^[^0-9]+$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(!try regex.isMatch("abc123"));
    try std.testing.expect(!try regex.isMatch("1"));
}

// --- Escape sequence edge cases ---

test "parser: tab and newline escapes" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "\\t");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("\t"));
    try std.testing.expect(!try regex.isMatch("t"));
}

test "parser: carriage return escape" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "\\r\\n");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("\r\n"));
}

test "parser: escaped caret and dollar" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "\\^\\$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("^$"));
    try std.testing.expect(!try regex.isMatch("ab"));
}

// --- Complex pattern compilation ---

test "compiler: alternation with quantifiers" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "^(ab+|cd*)e$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("abe"));
    try std.testing.expect(try regex.isMatch("abbbe"));
    try std.testing.expect(try regex.isMatch("ce"));
    try std.testing.expect(try regex.isMatch("cdddde"));
    try std.testing.expect(!try regex.isMatch("ae"));
    try std.testing.expect(!try regex.isMatch("de"));
}

test "compiler: character class in alternation" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "^([0-9]+|[a-z]+)$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("123"));
    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(!try regex.isMatch("abc123"));
    try std.testing.expect(!try regex.isMatch("ABC"));
}

test "compiler: optional group" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "^colou?r$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("color"));
    try std.testing.expect(try regex.isMatch("colour"));
    try std.testing.expect(!try regex.isMatch("colouur"));
}

test "compiler: optional group with parentheses" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "^(un)?happy$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("happy"));
    try std.testing.expect(try regex.isMatch("unhappy"));
    try std.testing.expect(!try regex.isMatch("unununhappy"));
}

test "compiler: multiple capture groups" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "(\\d{4})-(\\d{2})-(\\d{2})");
    defer regex.deinit();

    if (try regex.find("Today is 2024-01-15!")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("2024-01-15", match.slice);
        try std.testing.expect(match.captures.len >= 3);
        try std.testing.expectEqualStrings("2024", match.captures[0]);
        try std.testing.expectEqualStrings("01", match.captures[1]);
        try std.testing.expectEqualStrings("15", match.captures[2]);
    } else {
        return error.TestExpectedMatch;
    }
}

// --- Anchored optimization edge cases ---

test "compiler: anchored pattern only tries position 0" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "^abc");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("abcdef"));
    try std.testing.expect(!try regex.isMatch("xabc"));
    try std.testing.expect(!try regex.isMatch(""));
}

test "compiler: end-anchored pattern" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "abc$");
    defer regex.deinit();

    if (try regex.find("xyzabc")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 3), match.start);
    } else {
        return error.TestExpectedMatch;
    }
}

test "compiler: both anchors" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "^exact$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("exact"));
    try std.testing.expect(!try regex.isMatch("not exact"));
    try std.testing.expect(!try regex.isMatch("exact not"));
    try std.testing.expect(!try regex.isMatch(""));
}

// --- Complex real-world patterns ---

test "compiler: password strength check" {
    const allocator = std.testing.allocator;
    var has_digit = try Regex.compile(allocator, std.testing.io, "\\d");
    defer has_digit.deinit();
    var has_lower = try Regex.compile(allocator, std.testing.io, "[a-z]");
    defer has_lower.deinit();
    var has_upper = try Regex.compile(allocator, std.testing.io, "[A-Z]");
    defer has_upper.deinit();
    var min_length = try Regex.compile(allocator, std.testing.io, ".{8,}");
    defer min_length.deinit();

    const password = "MyP4ssword";
    try std.testing.expect(try has_digit.isMatch(password));
    try std.testing.expect(try has_lower.isMatch(password));
    try std.testing.expect(try has_upper.isMatch(password));
    try std.testing.expect(try min_length.isMatch(password));

    const weak = "weak";
    try std.testing.expect(!try has_digit.isMatch(weak));
    try std.testing.expect(!try has_upper.isMatch(weak));
    try std.testing.expect(!try min_length.isMatch(weak));
}

test "compiler: CSV field extraction" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "[^,]+");
    defer regex.deinit();

    const matches = try regex.findAll(allocator, "foo,bar,baz");
    defer {
        for (matches) |*m| {
            var mut_m = m;
            mut_m.deinit(allocator);
        }
        allocator.free(matches);
    }

    try std.testing.expectEqual(@as(usize, 3), matches.len);
    try std.testing.expectEqualStrings("foo", matches[0].slice);
    try std.testing.expectEqualStrings("bar", matches[1].slice);
    try std.testing.expectEqualStrings("baz", matches[2].slice);
}

test "compiler: whitespace normalization via replaceAll" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "\\s+");
    defer regex.deinit();

    const result = try regex.replaceAll(allocator, "  hello   world  ", " ");
    defer allocator.free(result);
    try std.testing.expectEqualStrings(" hello world ", result);
}

// --- Edge: pattern with only anchors ---

test "compiler: pattern with only ^ anchor" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "^");
    defer regex.deinit();

    // ^ matches at position 0 of any string (matches zero-width)
    try std.testing.expect(try regex.isMatch("anything"));
    try std.testing.expect(try regex.isMatch(""));
}

test "compiler: pattern with only $ anchor" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "$");
    defer regex.deinit();

    // $ matches at end of any string (zero-width)
    try std.testing.expect(try regex.isMatch("anything"));
    try std.testing.expect(try regex.isMatch(""));
}

// --- Dot with quantifiers ---

test "compiler: dot plus" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "^.+$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(!try regex.isMatch(""));
}

test "compiler: dot question" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "^.?$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch(""));
    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(!try regex.isMatch("ab"));
}

test "compiler: dot repeat" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "^.{3}$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(try regex.isMatch("123"));
    try std.testing.expect(!try regex.isMatch("ab"));
    try std.testing.expect(!try regex.isMatch("abcd"));
}

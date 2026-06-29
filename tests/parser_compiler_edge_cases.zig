const std = @import("std");
const Regex = @import("regex").Regex;
const RegexError = @import("regex").RegexError;
const common = @import("regex").common;

// =============================================================================
// Parser and compiler edge cases - invalid patterns, boundary syntax, etc.
// =============================================================================

// --- Invalid pattern rejection ---

test "parser: quantifier ? at start is rejected" {
    const allocator = std.testing.allocator;
    const result = Regex.compile(allocator, "?abc");
    try std.testing.expectError(RegexError.UnexpectedCharacter, result);
}

test "parser: nested empty groups" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(())");
    defer regex.deinit();
    // Should compile without error
    try std.testing.expect(try regex.isMatch(""));
}

test "parser: deeply nested groups" {
    const allocator = std.testing.allocator;
    // 20 levels of nesting - should be within limits
    var regex = try Regex.compile(allocator, "((((((((((((((((((((a))))))))))))))))))))");
    defer regex.deinit();
    try std.testing.expect(try regex.isMatch("a"));
}

test "parser: consecutive quantifiers rejected" {
    const allocator = std.testing.allocator;
    const result = Regex.compile(allocator, "a**");
    try std.testing.expectError(RegexError.InvalidQuantifier, result);
}

test "parser: quantifier on quantifier rejected" {
    const allocator = std.testing.allocator;
    const result = Regex.compile(allocator, "a+*");
    try std.testing.expectError(RegexError.InvalidQuantifier, result);
}

test "parser: bounded quantifier on quantifier rejected" {
    const allocator = std.testing.allocator;
    const result = Regex.compile(allocator, "x{1,2}{1}");
    try std.testing.expectError(RegexError.InvalidQuantifier, result);
}

test "parser: empty alternation branch is valid" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a|");
    defer regex.deinit();
    // "a|" means "a or empty string" - should match empty
    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch(""));
}

test "parser: leading pipe alternation" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "|a");
    defer regex.deinit();
    // "|a" means "empty string or a"
    try std.testing.expect(try regex.isMatch(""));
    try std.testing.expect(try regex.isMatch("a"));
}

// --- Quantifier syntax edge cases ---

test "parser: {0} means zero occurrences" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^a{0}b$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("b"));
    try std.testing.expect(!try regex.isMatch("ab"));
}

test "parser: {1} means exactly once" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^a{1}$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(!try regex.isMatch("aa"));
    try std.testing.expect(!try regex.isMatch(""));
}

test "parser: large but valid quantifier" {
    const allocator = std.testing.allocator;
    // {0,100} should be valid
    var regex = try Regex.compile(allocator, "a{0,100}");
    defer regex.deinit();
    try std.testing.expect(try regex.isMatch(""));
}

// --- Character class syntax edge cases ---

test "parser: character class with escaped ]" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[\\]]");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("]"));
    try std.testing.expect(!try regex.isMatch("a"));
}

test "parser: character class with hyphen between ranges" {
    const allocator = std.testing.allocator;
    // Hyphen at start is literal, not range
    var regex = try Regex.compile(allocator, "[-az]");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("-"));
    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("z"));
    try std.testing.expect(!try regex.isMatch("m"));
}

test "parser: negated class with range" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^[^0-9]+$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(!try regex.isMatch("abc123"));
    try std.testing.expect(!try regex.isMatch("1"));
}

// --- Escape sequence edge cases ---

test "parser: tab and newline escapes" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\t");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("\t"));
    try std.testing.expect(!try regex.isMatch("t"));
}

test "parser: carriage return escape" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\r\\n");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("\r\n"));
}

test "parser: escaped caret and dollar" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\^\\$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("^$"));
    try std.testing.expect(!try regex.isMatch("ab"));
}

test "parser: unicode mode rejects Annex B escape fallbacks" {
    const allocator = std.testing.allocator;
    const flags = common.CompileFlags{ .unicode = true };

    try std.testing.expectError(RegexError.InvalidBackreference, Regex.compileWithFlags(allocator, "\\1", flags));
    try std.testing.expectError(RegexError.InvalidBackreference, Regex.compileWithFlags(allocator, "\\9", flags));
    try std.testing.expectError(RegexError.InvalidEscapeSequence, Regex.compileWithFlags(allocator, "\\00", flags));
    try std.testing.expectError(RegexError.InvalidEscapeSequence, Regex.compileWithFlags(allocator, "\\c", flags));
    try std.testing.expectError(RegexError.InvalidEscapeSequence, Regex.compileWithFlags(allocator, "\\c_", flags));
    try std.testing.expectError(RegexError.InvalidEscapeSequence, Regex.compileWithFlags(allocator, "\\q", flags));

    var nul = try Regex.compileWithFlags(allocator, "\\0", flags);
    defer nul.deinit();
    try std.testing.expect(try nul.isMatch("\x00"));

    var backref = try Regex.compileWithFlags(allocator, "(a)\\1", flags);
    defer backref.deinit();
    try std.testing.expect(try backref.isMatch("aa"));
}

test "parser: unicode character class rejects invalid escapes and class ranges" {
    const allocator = std.testing.allocator;
    const flags = common.CompileFlags{ .unicode = true };

    try std.testing.expectError(RegexError.InvalidEscapeSequence, Regex.compileWithFlags(allocator, "[\\1]", flags));
    try std.testing.expectError(RegexError.InvalidEscapeSequence, Regex.compileWithFlags(allocator, "[\\00]", flags));
    try std.testing.expectError(RegexError.InvalidEscapeSequence, Regex.compileWithFlags(allocator, "[\\c]", flags));
    try std.testing.expectError(RegexError.InvalidEscapeSequence, Regex.compileWithFlags(allocator, "[\\c_]", flags));
    try std.testing.expectError(RegexError.InvalidCharacterClass, Regex.compileWithFlags(allocator, "[\\d-a]", flags));
    try std.testing.expectError(RegexError.InvalidCharacterClass, Regex.compileWithFlags(allocator, "[a-\\d]", flags));
    try std.testing.expectError(RegexError.InvalidCharacterClass, Regex.compileWithFlags(allocator, "[\\d-\\d]", flags));

    var control = try Regex.compileWithFlags(allocator, "[\\cA]", flags);
    defer control.deinit();
    try std.testing.expect(try control.isMatch("\x01"));
}

test "parser: annex b decimal escapes fall back to legacy octal or identity" {
    const allocator = std.testing.allocator;

    var single = try Regex.compile(allocator, "\\7");
    defer single.deinit();
    try std.testing.expect(try single.isMatch("\x07"));

    var bounded = try Regex.compile(allocator, "\\400");
    defer bounded.deinit();
    if (try bounded.find("\x200")) |match| {
        var owned = match;
        defer owned.deinit(allocator);
        try std.testing.expectEqualStrings("\x200", match.slice);
    } else return error.TestExpectedMatch;

    var three_digits = try Regex.compile(allocator, "\\0111");
    defer three_digits.deinit();
    if (try three_digits.find("\x091")) |match| {
        var owned = match;
        defer owned.deinit(allocator);
        try std.testing.expectEqualStrings("\x091", match.slice);
    } else return error.TestExpectedMatch;

    var high = try Regex.compile(allocator, "\\300");
    defer high.deinit();
    if (try high.find("\u{c0}")) |match| {
        var owned = match;
        defer owned.deinit(allocator);
        try std.testing.expectEqualStrings("\u{c0}", match.slice);
    } else return error.TestExpectedMatch;

    var identity = try Regex.compile(allocator, "7\\89");
    defer identity.deinit();
    try std.testing.expect(try identity.isMatch("789"));

    var backref = try Regex.compile(allocator, "(.)\\1");
    defer backref.deinit();
    try std.testing.expect(try backref.isMatch("aa"));
    try std.testing.expect(!try backref.isMatch("a\x01"));
}

test "parser: annex b character class escapes and shorthand ranges" {
    const allocator = std.testing.allocator;

    var outside = try Regex.compile(allocator, "\\c0");
    defer outside.deinit();
    try std.testing.expect(!try outside.isMatch("\x10"));

    var control_digit = try Regex.compile(allocator, "[\\c0]");
    defer control_digit.deinit();
    try std.testing.expect(try control_digit.isMatch("\x10"));

    var control_underscore = try Regex.compile(allocator, "[\\c_]");
    defer control_underscore.deinit();
    try std.testing.expect(try control_underscore.isMatch("\x1f"));

    var range_left_shorthand = try Regex.compile(allocator, "[\\d-a]+");
    defer range_left_shorthand.deinit();
    if (try range_left_shorthand.find(":a0123456789-:")) |match| {
        var owned = match;
        defer owned.deinit(allocator);
        try std.testing.expectEqualStrings("a0123456789-", match.slice);
    } else return error.TestExpectedMatch;

    var range_right_shorthand = try Regex.compile(allocator, "[%-\\d]+");
    defer range_right_shorthand.deinit();
    if (try range_right_shorthand.find("&%0123456789-&")) |match| {
        var owned = match;
        defer owned.deinit(allocator);
        try std.testing.expectEqualStrings("%0123456789-", match.slice);
    } else return error.TestExpectedMatch;
}

test "parser: annex b extended pattern characters are literals" {
    const allocator = std.testing.allocator;

    var bracket = try Regex.compile(allocator, "]");
    defer bracket.deinit();
    try std.testing.expect(try bracket.isMatch(" ]{}"));

    var left_brace = try Regex.compile(allocator, "{");
    defer left_brace.deinit();
    try std.testing.expect(try left_brace.isMatch(" ]{}"));

    var right_brace = try Regex.compile(allocator, "}");
    defer right_brace.deinit();
    try std.testing.expect(try right_brace.isMatch(" ]{}"));

    var braced_literal = try Regex.compile(allocator, "x{o}x");
    defer braced_literal.deinit();
    try std.testing.expect(try braced_literal.isMatch("x{o}x"));
}

// --- Complex pattern compilation ---

test "compiler: alternation with quantifiers" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^(ab+|cd*)e$");
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
    var regex = try Regex.compile(allocator, "^([0-9]+|[a-z]+)$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("123"));
    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(!try regex.isMatch("abc123"));
    try std.testing.expect(!try regex.isMatch("ABC"));
}

test "compiler: optional group" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^colou?r$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("color"));
    try std.testing.expect(try regex.isMatch("colour"));
    try std.testing.expect(!try regex.isMatch("colouur"));
}

test "compiler: optional group with parentheses" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^(un)?happy$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("happy"));
    try std.testing.expect(try regex.isMatch("unhappy"));
    try std.testing.expect(!try regex.isMatch("unununhappy"));
}

test "compiler: multiple capture groups" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\d{4})-(\\d{2})-(\\d{2})");
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
    var regex = try Regex.compile(allocator, "^abc");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("abcdef"));
    try std.testing.expect(!try regex.isMatch("xabc"));
    try std.testing.expect(!try regex.isMatch(""));
}

test "compiler: end-anchored pattern" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "abc$");
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
    var regex = try Regex.compile(allocator, "^exact$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("exact"));
    try std.testing.expect(!try regex.isMatch("not exact"));
    try std.testing.expect(!try regex.isMatch("exact not"));
    try std.testing.expect(!try regex.isMatch(""));
}

// --- Complex real-world patterns ---

test "compiler: password strength check" {
    const allocator = std.testing.allocator;
    var has_digit = try Regex.compile(allocator, "\\d");
    defer has_digit.deinit();
    var has_lower = try Regex.compile(allocator, "[a-z]");
    defer has_lower.deinit();
    var has_upper = try Regex.compile(allocator, "[A-Z]");
    defer has_upper.deinit();
    var min_length = try Regex.compile(allocator, ".{8,}");
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
    var regex = try Regex.compile(allocator, "[^,]+");
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
    var regex = try Regex.compile(allocator, "\\s+");
    defer regex.deinit();

    const result = try regex.replaceAll(allocator, "  hello   world  ", " ");
    defer allocator.free(result);
    try std.testing.expectEqualStrings(" hello world ", result);
}

// --- Edge: pattern with only anchors ---

test "compiler: pattern with only ^ anchor" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^");
    defer regex.deinit();

    // ^ matches at position 0 of any string (matches zero-width)
    try std.testing.expect(try regex.isMatch("anything"));
    try std.testing.expect(try regex.isMatch(""));
}

test "compiler: pattern with only $ anchor" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "$");
    defer regex.deinit();

    // $ matches at end of any string (zero-width)
    try std.testing.expect(try regex.isMatch("anything"));
    try std.testing.expect(try regex.isMatch(""));
}

// --- Dot with quantifiers ---

test "compiler: dot plus" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^.+$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(!try regex.isMatch(""));
}

test "compiler: dot question" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^.?$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch(""));
    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(!try regex.isMatch("ab"));
}

test "compiler: dot repeat" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^.{3}$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(try regex.isMatch("123"));
    try std.testing.expect(!try regex.isMatch("ab"));
    try std.testing.expect(!try regex.isMatch("abcd"));
}

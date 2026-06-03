const std = @import("std");
const Regex = @import("regex").Regex;

// Regression coverage for issue #9: inline flag groups `(?flags:…)` and inline
// flag toggles `(?flags)` / `(?-flags)` with correct sub-expression scoping.
// https://github.com/zig-utils/zig-regex/issues/9

test "issue #9: reproduction patterns compile" {
    const allocator = std.testing.allocator;
    inline for (.{
        "(?i:abc)", // scoped case-insensitive group
        "(?i)abc", // inline flag toggle (rest of pattern)
        "(?i:[sdmt]|ll|ve|re)", // the GPT-4 contraction sub-pattern
        "a(?-i:b)c", // scoped flag *un*set
    }) |pat| {
        var re = try Regex.compile(allocator, pat);
        re.deinit();
    }
}

test "scoped case-insensitive group (?i:abc) folds only inside the group" {
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, "(?i:abc)");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("abc"));
    try std.testing.expect(try re.isMatch("ABC"));
    try std.testing.expect(try re.isMatch("AbC"));
}

test "case folding does not leak outside (?i:..) group" {
    const allocator = std.testing.allocator;
    // Only the `b` is case-insensitive; the surrounding a/c stay sensitive.
    var re = try Regex.compile(allocator, "a(?i:b)c");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("abc"));
    try std.testing.expect(try re.isMatch("aBc"));
    try std.testing.expect(!try re.isMatch("Abc")); // leading A must stay literal
    try std.testing.expect(!try re.isMatch("abC")); // trailing C must stay literal
}

test "inline toggle (?i) applies to the rest of the pattern" {
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, "a(?i)bc");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("abc"));
    try std.testing.expect(try re.isMatch("aBC")); // bc folded
    try std.testing.expect(!try re.isMatch("Abc")); // leading a stays sensitive
}

test "scoped unset (?-i:..) re-enables case sensitivity inside a global fold" {
    const allocator = std.testing.allocator;
    var re = try Regex.compileWithFlags(allocator, "a(?-i:b)c", .{ .case_insensitive = true });
    defer re.deinit();

    try std.testing.expect(try re.isMatch("abc"));
    try std.testing.expect(try re.isMatch("AbC")); // a and c fold globally, b stays exact
    try std.testing.expect(!try re.isMatch("aBc")); // but B is forced sensitive
    try std.testing.expect(!try re.isMatch("ABC")); // middle B violates the (?-i:b)
}

test "issue #9: GPT-4 contraction sub-pattern matches like lower-case" {
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, "(?i:[sdmt]|ll|ve|re)");
    defer re.deinit();

    // lower-case originals
    try std.testing.expect(try re.isMatch("s"));
    try std.testing.expect(try re.isMatch("ll"));
    try std.testing.expect(try re.isMatch("ve"));
    try std.testing.expect(try re.isMatch("re"));
    // case-folded variants
    try std.testing.expect(try re.isMatch("S"));
    try std.testing.expect(try re.isMatch("LL"));
    try std.testing.expect(try re.isMatch("Ve"));
    try std.testing.expect(try re.isMatch("RE"));
}

test "combined add/remove flags (?i-s:..)" {
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, "(?i-s:a.b)");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("axb"));
    try std.testing.expect(try re.isMatch("AXB")); // i applied
    try std.testing.expect(!try re.isMatch("a\nb")); // s removed: dot does not match newline
}

test "scoped dot-all (?s:.) matches newline only inside the group" {
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, "(?s:a.b)");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("a\nb"));
    try std.testing.expect(try re.isMatch("axb"));
}

test "scoped multiline (?m:^) anchors at line starts inside the group" {
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, "(?m:^b)");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("a\nb"));
}

test "early error: repeated flag is rejected" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnexpectedCharacter, Regex.compile(allocator, "(?ii:a)"));
}

test "early error: flag both added and removed is rejected" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnexpectedCharacter, Regex.compile(allocator, "(?i-i:a)"));
}

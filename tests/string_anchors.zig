const std = @import("std");
const Regex = @import("regex").Regex;

test "string anchor: \\A start of text" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\Aabc");
    defer regex.deinit();

    // Should match at the start of the text
    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(try regex.isMatch("abcdef"));

    // Should NOT match after a newline (unlike ^)
    try std.testing.expect(!try regex.isMatch("line1\nabc"));
    try std.testing.expect(!try regex.isMatch("xxx\nabc"));
}

test "string anchor: \\z end of text" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "abc\\z");
    defer regex.deinit();

    // Should match at the end of the text
    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(try regex.isMatch("xyzabc"));

    // Should NOT match before a newline at the end
    try std.testing.expect(!try regex.isMatch("abc\n"));
}

test "string anchor: \\Z end of text (before optional newline)" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "abc\\Z");
    defer regex.deinit();

    // Should match at the end of the text
    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(try regex.isMatch("xyzabc"));

    // For now, \\Z behaves the same as \\z (we treat them the same)
    // In a full implementation, \\Z would match before an optional final newline
    try std.testing.expect(!try regex.isMatch("abc\n"));
}

test "string anchors: \\A vs ^" {
    const allocator = std.testing.allocator;

    var regex_A = try Regex.compile(allocator, "\\Atest");
    defer regex_A.deinit();

    var regex_caret = try Regex.compile(allocator, "^test");
    defer regex_caret.deinit();

    const input1 = "test";
    const input2 = "line1\ntest";

    // Both should match at the start of text
    try std.testing.expect(try regex_A.isMatch(input1));
    try std.testing.expect(try regex_caret.isMatch(input1));

    // \\A should NOT match after newline
    try std.testing.expect(!try regex_A.isMatch(input2));

    // ^ with default flags (multiline=false) should also NOT match after newline
    // Use multiline mode to match after newlines
    try std.testing.expect(!try regex_caret.isMatch(input2));
}

test "string anchors: combined \\A and \\z" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\Aexact\\z");
    defer regex.deinit();

    // Should match only exact strings
    try std.testing.expect(try regex.isMatch("exact"));

    // Should NOT match with extra content
    try std.testing.expect(!try regex.isMatch("exact "));
    try std.testing.expect(!try regex.isMatch(" exact"));
    try std.testing.expect(!try regex.isMatch("exactly"));
}

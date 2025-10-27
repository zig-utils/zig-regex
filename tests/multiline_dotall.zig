const std = @import("std");
const Regex = @import("regex").Regex;
const common = @import("regex").common;

test "multiline flag: ^ matches after newlines" {
    const allocator = std.testing.allocator;

    // Without multiline flag
    var regex_single = try Regex.compileWithFlags(allocator, "^test", .{ .multiline = false });
    defer regex_single.deinit();

    // With multiline flag
    var regex_multi = try Regex.compileWithFlags(allocator, "^test", .{ .multiline = true });
    defer regex_multi.deinit();

    const input = "line1\ntest";

    // Single-line mode: ^ only matches at start
    try std.testing.expect(!try regex_single.isMatch(input));

    // Multiline mode: ^ matches after newlines
    try std.testing.expect(try regex_multi.isMatch(input));
}

test "multiline flag: $ matches before newlines" {
    const allocator = std.testing.allocator;

    // Without multiline flag
    var regex_single = try Regex.compileWithFlags(allocator, "test$", .{ .multiline = false });
    defer regex_single.deinit();

    // With multiline flag
    var regex_multi = try Regex.compileWithFlags(allocator, "test$", .{ .multiline = true });
    defer regex_multi.deinit();

    const input = "test\nline2";

    // Single-line mode: $ only matches at end
    try std.testing.expect(!try regex_single.isMatch(input));

    // Multiline mode: $ matches before newlines
    try std.testing.expect(try regex_multi.isMatch(input));
}

test "multiline flag: complex pattern" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compileWithFlags(allocator, "^\\w+$", .{ .multiline = true });
    defer regex.deinit();

    // Should match each line
    try std.testing.expect(try regex.isMatch("hello\nworld\ntest"));
    try std.testing.expect(try regex.isMatch("oneline"));
}

test "dot-all flag: . matches newlines" {
    const allocator = std.testing.allocator;

    // Without dot-all flag
    var regex_normal = try Regex.compileWithFlags(allocator, "a.b", .{ .dot_all = false });
    defer regex_normal.deinit();

    // With dot-all flag
    var regex_dotall = try Regex.compileWithFlags(allocator, "a.b", .{ .dot_all = true });
    defer regex_dotall.deinit();

    const input_with_newline = "a\nb";
    const input_without_newline = "axb";

    // Normal mode: . doesn't match newlines
    try std.testing.expect(!try regex_normal.isMatch(input_with_newline));
    try std.testing.expect(try regex_normal.isMatch(input_without_newline));

    // Dot-all mode: . matches newlines
    try std.testing.expect(try regex_dotall.isMatch(input_with_newline));
    try std.testing.expect(try regex_dotall.isMatch(input_without_newline));
}

test "dot-all flag: .* matches across lines" {
    const allocator = std.testing.allocator;

    // Without dot-all flag
    var regex_normal = try Regex.compileWithFlags(allocator, "start.*end", .{ .dot_all = false });
    defer regex_normal.deinit();

    // With dot-all flag
    var regex_dotall = try Regex.compileWithFlags(allocator, "start.*end", .{ .dot_all = true });
    defer regex_dotall.deinit();

    const input = "start\nmiddle\nend";

    // Normal mode: .* stops at newlines
    try std.testing.expect(!try regex_normal.isMatch(input));

    // Dot-all mode: .* crosses newlines
    try std.testing.expect(try regex_dotall.isMatch(input));
}

test "combined multiline and dot-all flags" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compileWithFlags(allocator, "^.*$", .{
        .multiline = true,
        .dot_all = true,
    });
    defer regex.deinit();

    // Should match the entire input including newlines
    try std.testing.expect(try regex.isMatch("line1\nline2\nline3"));
}

test "multiline flag: multiple matches with findAll" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compileWithFlags(allocator, "^\\d+", .{ .multiline = true });
    defer regex.deinit();

    const matches = try regex.findAll(allocator, "123\n456\n789");
    defer {
        for (matches) |*match| {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        allocator.free(matches);
    }

    // Should find all three numbers at start of lines
    try std.testing.expectEqual(@as(usize, 3), matches.len);
    try std.testing.expectEqualStrings("123", matches[0].slice);
    try std.testing.expectEqualStrings("456", matches[1].slice);
    try std.testing.expectEqualStrings("789", matches[2].slice);
}

test "default flags: multiline and dot-all are false" {
    const allocator = std.testing.allocator;

    // Default compile should have multiline=false and dot_all=false
    var regex = try Regex.compile(allocator, "^test$");
    defer regex.deinit();

    // Should not match with newlines
    try std.testing.expect(!try regex.isMatch("prefix\ntest"));
    try std.testing.expect(!try regex.isMatch("test\nsuffix"));
    try std.testing.expect(try regex.isMatch("test"));
}

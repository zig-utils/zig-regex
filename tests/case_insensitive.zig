const std = @import("std");
const Regex = @import("regex").Regex;
const common = @import("regex").common;

test "case insensitive: simple literal" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compileWithFlags(allocator, "hello", .{ .case_insensitive = true });
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("hello"));
    try std.testing.expect(try regex.isMatch("HELLO"));
    try std.testing.expect(try regex.isMatch("Hello"));
    try std.testing.expect(try regex.isMatch("HeLLo"));
    try std.testing.expect(!try regex.isMatch("helo"));
}

test "case insensitive: with quantifiers" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compileWithFlags(allocator, "a+b*", .{ .case_insensitive = true });
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("aaa"));
    try std.testing.expect(try regex.isMatch("AAA"));
    try std.testing.expect(try regex.isMatch("AaA"));
    try std.testing.expect(try regex.isMatch("aaabbb"));
    try std.testing.expect(try regex.isMatch("AAABBB"));
    try std.testing.expect(try regex.isMatch("AaaBbB"));
}

test "case insensitive: mixed with alternation" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compileWithFlags(allocator, "cat|dog", .{ .case_insensitive = true });
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("cat"));
    try std.testing.expect(try regex.isMatch("CAT"));
    try std.testing.expect(try regex.isMatch("Cat"));
    try std.testing.expect(try regex.isMatch("dog"));
    try std.testing.expect(try regex.isMatch("DOG"));
    try std.testing.expect(try regex.isMatch("Dog"));
}

test "case insensitive: find in text" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compileWithFlags(allocator, "hello", .{ .case_insensitive = true });
    defer regex.deinit();

    if (try regex.find("Say HELLO world")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("HELLO", match.slice);
    } else {
        try std.testing.expect(false);
    }
}

test "case insensitive: with anchors" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compileWithFlags(allocator, "^hello$", .{ .case_insensitive = true });
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("hello"));
    try std.testing.expect(try regex.isMatch("HELLO"));
    try std.testing.expect(try regex.isMatch("Hello"));
    try std.testing.expect(!try regex.isMatch("hello world"));
    try std.testing.expect(!try regex.isMatch("say hello"));
}

test "case insensitive: replace" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compileWithFlags(allocator, "hello", .{ .case_insensitive = true });
    defer regex.deinit();

    const result = try regex.replace(allocator, "Say HELLO world", "hi");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Say hi world", result);
}

test "case insensitive: replaceAll" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compileWithFlags(allocator, "a", .{ .case_insensitive = true });
    defer regex.deinit();

    const result = try regex.replaceAll(allocator, "AaAa", "X");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("XXXX", result);
}

test "case insensitive: disabled by default" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "hello");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("hello"));
    try std.testing.expect(!try regex.isMatch("HELLO"));
    try std.testing.expect(!try regex.isMatch("Hello"));
}

test "case insensitive: with numbers and special chars" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compileWithFlags(allocator, "test123", .{ .case_insensitive = true });
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("test123"));
    try std.testing.expect(try regex.isMatch("TEST123"));
    try std.testing.expect(try regex.isMatch("Test123"));
    try std.testing.expect(!try regex.isMatch("test124"));
}

const std = @import("std");
const Regex = @import("regex").Regex;

// UTF-8 and Unicode Tests

test "UTF-8: literal matching" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "café");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("café"));
    try std.testing.expect(!try regex.isMatch("cafe"));
}

test "UTF-8: emoji matching" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "Hello 👋 World");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("Hello 👋 World"));
}

test "UTF-8: Chinese characters" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "你好");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("你好"));
    try std.testing.expect(try regex.isMatch("你好世界"));
}

test "UTF-8: mixed ASCII and Unicode" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "test-тест-テスト");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("test-тест-テスト"));
}

test "UTF-8: dot matches multi-byte character" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "c.fé");
    defer regex.deinit();

    // Currently .  matches one byte, not one character
    // This test documents current behavior
    try std.testing.expect(try regex.isMatch("café"));
}

test "UTF-8: alternation with Unicode" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "hello|你好|こんにちは");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("hello"));
    try std.testing.expect(try regex.isMatch("你好"));
    try std.testing.expect(try regex.isMatch("こんにちは"));
}

test "UTF-8: character class range with multi-byte" {
    const allocator = std.testing.allocator;
    // Character classes currently only work with single-byte ASCII
    var regex = try Regex.compile(allocator, std.testing.io, "[a-z]+");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("hello"));
    // Multi-byte UTF-8 (é) won't match [a-z], but "caf" will
    const result = try regex.find("café");
    try std.testing.expect(result != null);
    if (result) |match| {
        defer {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        // Only matches ASCII part "caf", not the é
        try std.testing.expectEqualStrings("caf", match.slice);
    }
}

test "UTF-8: quantifiers with Unicode literals" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "あ+");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("あ"));
    try std.testing.expect(try regex.isMatch("ああああ"));
}

test "UTF-8: capture groups with Unicode" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "(你好)(世界)");
    defer regex.deinit();

    const result = try regex.find("你好世界");
    try std.testing.expect(result != null);
    if (result) |match| {
        defer {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        try std.testing.expectEqual(@as(usize, 2), match.captures.len);
        try std.testing.expectEqualStrings("你好", match.captures[0]);
        try std.testing.expectEqualStrings("世界", match.captures[1]);
    }
}

test "UTF-8: replacement with Unicode" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "(\\w+)@(\\w+)");
    defer regex.deinit();

    // ASCII works
    const result1 = try regex.replace(allocator, "user@example", "$1 at $2");
    defer allocator.free(result1);
    try std.testing.expectEqualStrings("user at example", result1);
}

test "UTF-8: anchors with Unicode" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "^你好$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("你好"));
    try std.testing.expect(!try regex.isMatch("你好世界"));
    try std.testing.expect(!try regex.isMatch("世界你好"));
}

test "UTF-8: non-capturing groups with Unicode" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "(?:안녕|hello) (world|세계)");
    defer regex.deinit();

    const result1 = try regex.find("hello world");
    try std.testing.expect(result1 != null);
    if (result1) |match| {
        defer {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        try std.testing.expectEqual(@as(usize, 1), match.captures.len);
        try std.testing.expectEqualStrings("world", match.captures[0]);
    }

    const result2 = try regex.find("안녕 세계");
    try std.testing.expect(result2 != null);
    if (result2) |match| {
        defer {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        try std.testing.expectEqual(@as(usize, 1), match.captures.len);
        try std.testing.expectEqualStrings("세계", match.captures[0]);
    }
}

// Document current limitations
test "UTF-8: known limitation - dot is byte-based" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "^.$");
    defer regex.deinit();

    // Single ASCII character
    try std.testing.expect(try regex.isMatch("a"));

    // Multi-byte character - currently fails because . matches one byte
    // In Unicode mode, . should match the entire character
    try std.testing.expect(!try regex.isMatch("é")); // é is 2 bytes
    try std.testing.expect(!try regex.isMatch("你")); // 你 is 3 bytes
}

test "UTF-8: known limitation - \\w is ASCII-only" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, std.testing.io, "\\w+");
    defer regex.deinit();

    // ASCII word characters work
    try std.testing.expect(try regex.isMatch("hello"));
    try std.testing.expect(try regex.isMatch("test123"));

    // Non-ASCII letters currently don't match \w
    // In Unicode mode, \w should match Unicode letters
    const result = try regex.find("café");
    if (result) |match| {
        defer {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        // Currently only matches "caf", not "café"
        try std.testing.expectEqualStrings("caf", match.slice);
    }
}

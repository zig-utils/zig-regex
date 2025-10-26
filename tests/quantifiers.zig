const std = @import("std");
const Regex = @import("regex").Regex;

test "quantifier: exactly n times {3}" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a{3}");
    defer regex.deinit();

    try std.testing.expect(!try regex.isMatch("aa"));
    try std.testing.expect(try regex.isMatch("aaa"));
    try std.testing.expect(!try regex.isMatch("aaaa"));
}

test "quantifier: range {2,4}" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a{2,4}");
    defer regex.deinit();

    try std.testing.expect(!try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("aa"));
    try std.testing.expect(try regex.isMatch("aaa"));
    try std.testing.expect(try regex.isMatch("aaaa"));
    try std.testing.expect(!try regex.isMatch("aaaaa"));
}

test "quantifier: at least n {2,}" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a{2,}");
    defer regex.deinit();

    try std.testing.expect(!try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("aa"));
    try std.testing.expect(try regex.isMatch("aaa"));
    try std.testing.expect(try regex.isMatch("aaaaaaa"));
}

test "quantifier: {0,1} equivalent to ?" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a{0,1}");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch(""));
    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(!try regex.isMatch("aa"));
}

test "quantifier: {1,} equivalent to +" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a{1,}");
    defer regex.deinit();

    try std.testing.expect(!try regex.isMatch(""));
    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("aaaa"));
}

test "quantifier: {0,} equivalent to *" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a{0,}");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch(""));
    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("aaaa"));
}

test "quantifier: complex pattern with {m,n}" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\d{3}-\\d{4}");
    defer regex.deinit();

    if (try regex.find("Call 555-1234 now")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("555-1234", match.slice);
    } else {
        try std.testing.expect(false);
    }
}

test "quantifier: multiple bounded quantifiers" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a{2}b{3}");
    defer regex.deinit();

    try std.testing.expect(!try regex.isMatch("ab"));
    try std.testing.expect(!try regex.isMatch("aabbb"));
    try std.testing.expect(try regex.isMatch("aabbb"));
    try std.testing.expect(!try regex.isMatch("aaabbbb"));
}

test "quantifier: {m,n} with character class" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[a-z]{3,5}");
    defer regex.deinit();

    try std.testing.expect(!try regex.isMatch("ab"));
    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(try regex.isMatch("abcde"));
    try std.testing.expect(!try regex.isMatch("abcdef"));
}

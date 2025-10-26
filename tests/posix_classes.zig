const std = @import("std");
const Regex = @import("regex").Regex;

// POSIX Character Class Tests

test "posix: [:alpha:] matches letters" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[[:alpha:]]+");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("hello"));
    try std.testing.expect(try regex.isMatch("WORLD"));
    try std.testing.expect(try regex.isMatch("AbCdEf"));
    try std.testing.expect(!try regex.isMatch("123"));
    try std.testing.expect(!try regex.isMatch("@#$"));
}

test "posix: [:digit:] matches digits" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[[:digit:]]+");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("123"));
    try std.testing.expect(try regex.isMatch("0"));
    try std.testing.expect(try regex.isMatch("999"));
    try std.testing.expect(!try regex.isMatch("abc"));
    try std.testing.expect(!try regex.isMatch("a1b2"));
}

test "posix: [:alnum:] matches alphanumeric" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[[:alnum:]]+");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("hello123"));
    try std.testing.expect(try regex.isMatch("ABC789"));
    try std.testing.expect(try regex.isMatch("a1b2c3"));
    try std.testing.expect(!try regex.isMatch("@@@"));
    try std.testing.expect(!try regex.isMatch("!!!"));
}

test "posix: [:space:] matches whitespace" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[[:space:]]+");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("   "));
    try std.testing.expect(try regex.isMatch("\t\t"));
    try std.testing.expect(try regex.isMatch("\n\r"));
    try std.testing.expect(try regex.isMatch(" \t\n\r"));
    try std.testing.expect(!try regex.isMatch("abc"));
}

test "posix: [:upper:] matches uppercase" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[[:upper:]]+");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("HELLO"));
    try std.testing.expect(try regex.isMatch("ABC"));
    try std.testing.expect(try regex.isMatch("XYZ"));
    try std.testing.expect(!try regex.isMatch("hello"));
    try std.testing.expect(!try regex.isMatch("123"));
}

test "posix: [:lower:] matches lowercase" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[[:lower:]]+");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("hello"));
    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(try regex.isMatch("xyz"));
    try std.testing.expect(!try regex.isMatch("HELLO"));
    try std.testing.expect(!try regex.isMatch("123"));
}

test "posix: [:xdigit:] matches hex digits" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[[:xdigit:]]+");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("0123456789"));
    try std.testing.expect(try regex.isMatch("abcdef"));
    try std.testing.expect(try regex.isMatch("ABCDEF"));
    try std.testing.expect(try regex.isMatch("0x1A2B3C"));
    try std.testing.expect(!try regex.isMatch("xyz"));
    try std.testing.expect(!try regex.isMatch("GHI"));
}

test "posix: [:punct:] matches punctuation" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[[:punct:]]+");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("!@#$%"));
    try std.testing.expect(try regex.isMatch(".,;:"));
    try std.testing.expect(try regex.isMatch("()[]{}"));
    try std.testing.expect(!try regex.isMatch("abc"));
    try std.testing.expect(!try regex.isMatch("123"));
}

test "posix: [:blank:] matches space and tab" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[[:blank:]]+");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("   "));
    try std.testing.expect(try regex.isMatch("\t\t"));
    try std.testing.expect(try regex.isMatch(" \t "));
    try std.testing.expect(!try regex.isMatch("\n"));
    try std.testing.expect(!try regex.isMatch("abc"));
}

test "posix: [:print:] matches printable characters" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[[:print:]]+");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("Hello World!"));
    try std.testing.expect(try regex.isMatch("123 ABC xyz"));
    try std.testing.expect(try regex.isMatch("@#$%^&*()"));
}

test "posix: [:graph:] matches visible characters" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[[:graph:]]+");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("Hello"));
    try std.testing.expect(try regex.isMatch("123ABC"));
    try std.testing.expect(try regex.isMatch("!@#$%"));
    try std.testing.expect(!try regex.isMatch(" "));
    try std.testing.expect(!try regex.isMatch("\t"));
}

test "posix: [:cntrl:] matches control characters" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[[:cntrl:]]");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("\x00"));
    try std.testing.expect(try regex.isMatch("\x01"));
    try std.testing.expect(try regex.isMatch("\x1F"));
    try std.testing.expect(try regex.isMatch("\x7F"));
    try std.testing.expect(!try regex.isMatch("a"));
    try std.testing.expect(!try regex.isMatch("1"));
}

test "posix: combined with regular characters" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[[:alpha:]0-9_]+");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("hello123"));
    try std.testing.expect(try regex.isMatch("test_var"));
    try std.testing.expect(try regex.isMatch("ABC_123"));
}

test "posix: multiple POSIX classes in one bracket" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[[:alpha:][:digit:]]+");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("abc123"));
    try std.testing.expect(try regex.isMatch("XYZ789"));
    try std.testing.expect(!try regex.isMatch("@@@"));
}

test "posix: extract words with [:alpha:]" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[[:alpha:]]+");
    defer regex.deinit();

    const text = "Hello World 123";
    const matches = try regex.findAll(allocator, text);
    defer {
        for (matches) |*match| {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        allocator.free(matches);
    }

    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqualStrings("Hello", matches[0].slice);
    try std.testing.expectEqualStrings("World", matches[1].slice);
}

test "posix: extract hex numbers with [:xdigit:]" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "0x[[:xdigit:]]+");
    defer regex.deinit();

    const text = "Colors: 0xFF5733 and 0xABCDEF";
    const matches = try regex.findAll(allocator, text);
    defer {
        for (matches) |*match| {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        allocator.free(matches);
    }

    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqualStrings("0xFF5733", matches[0].slice);
    try std.testing.expectEqualStrings("0xABCDEF", matches[1].slice);
}

test "posix: validate identifier with [:alnum:]" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^[[:alpha:]_][[:alnum:]_]*$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("valid_identifier"));
    try std.testing.expect(try regex.isMatch("_private"));
    try std.testing.expect(try regex.isMatch("test123"));
    try std.testing.expect(!try regex.isMatch("123invalid"));
    try std.testing.expect(!try regex.isMatch("no-hyphens"));
}

test "posix: split on whitespace with [:space:]" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[[:space:]]+");
    defer regex.deinit();

    const text = "one\ttwo\nthree  four";
    const parts = try regex.split(allocator, text);
    defer allocator.free(parts);

    try std.testing.expectEqual(@as(usize, 4), parts.len);
    try std.testing.expectEqualStrings("one", parts[0]);
    try std.testing.expectEqualStrings("two", parts[1]);
    try std.testing.expectEqualStrings("three", parts[2]);
    try std.testing.expectEqualStrings("four", parts[3]);
}

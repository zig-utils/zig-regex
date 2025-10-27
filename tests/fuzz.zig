const std = @import("std");
const Regex = @import("regex").Regex;

// Simple fuzzing test - tries random patterns and inputs
test "fuzz: random valid patterns" {
    const allocator = std.testing.allocator;

    // Seed for reproducibility
    var prng = std.Random.DefaultPrng.init(0x12345678);
    const random = prng.random();

    const iterations = 100;
    var i: usize = 0;

    while (i < iterations) : (i += 1) {
        // Generate random simple pattern
        var pattern_buf: [32]u8 = undefined;
        const pattern_len = random.intRangeAtMost(usize, 1, 20);

        for (0..pattern_len) |j| {
            const char_choice = random.intRangeAtMost(u8, 0, 4);
            pattern_buf[j] = switch (char_choice) {
                0 => 'a' + random.intRangeAtMost(u8, 0, 25), // a-z
                1 => '0' + random.intRangeAtMost(u8, 0, 9),  // 0-9
                2 => '.', // wildcard
                3 => '*', // quantifier
                else => '+', // quantifier
            };
        }
        const pattern = pattern_buf[0..pattern_len];

        // Try to compile - some patterns will be invalid, that's ok
        var regex = Regex.compile(allocator, pattern) catch continue;
        defer regex.deinit();

        // Generate random input
        var input_buf: [64]u8 = undefined;
        const input_len = random.intRangeAtMost(usize, 0, 50);
        for (0..input_len) |j| {
            input_buf[j] = 'a' + random.intRangeAtMost(u8, 0, 25);
        }
        const input = input_buf[0..input_len];

        // Try matching - should not crash
        _ = regex.isMatch(input) catch continue;
    }
}

test "fuzz: stress test with alternations" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(0x87654321);
    const random = prng.random();

    const iterations = 50;
    var i: usize = 0;

    while (i < iterations) : (i += 1) {
        // Build pattern with alternations: a|b|c|d...
        var pattern_buf: [128]u8 = undefined;
        var pos: usize = 0;

        const num_alternatives = random.intRangeAtMost(usize, 2, 10);
        for (0..num_alternatives) |j| {
            if (j > 0) {
                pattern_buf[pos] = '|';
                pos += 1;
            }

            const alt_len = random.intRangeAtMost(usize, 1, 5);
            for (0..alt_len) |_| {
                if (pos < pattern_buf.len) {
                    pattern_buf[pos] = 'a' + random.intRangeAtMost(u8, 0, 25);
                    pos += 1;
                }
            }
        }

        const pattern = pattern_buf[0..pos];

        var regex = Regex.compile(allocator, pattern) catch continue;
        defer regex.deinit();

        // Test with various inputs
        _ = regex.isMatch("abc") catch {};
        _ = regex.isMatch("") catch {};
        _ = regex.isMatch("x") catch {};
    }
}

test "fuzz: stress test with groups and quantifiers" {
    const allocator = std.testing.allocator;

    const patterns = [_][]const u8{
        "(a|b)*c",
        "(x|y)+z",
        "(\\d{2,4})+",
        "([a-z]+\\d+)*",
        "(test|exam)+",
        "(a+b+)*c",
        "x{1,3}y{2,4}",
    };

    for (patterns) |pattern| {
        var regex = Regex.compile(allocator, pattern) catch continue;
        defer regex.deinit();

        // Try various inputs
        const test_inputs = [_][]const u8{
            "",
            "a",
            "aa",
            "aaa",
            "abc",
            "aaabbbccc",
            "test",
            "testexam",
            "xyz",
            "12345",
        };

        for (test_inputs) |input| {
            _ = regex.isMatch(input) catch {};
        }
    }
}

test "fuzz: malformed patterns should return errors" {
    const allocator = std.testing.allocator;

    const bad_patterns = [_][]const u8{
        "(abc",        // Unmatched paren
        "abc)",        // Unmatched paren
        "[abc",        // Unmatched bracket
        "abc]",        // Unmatched bracket
        "*",           // Quantifier without target
        "+abc",        // Quantifier without target
        "?abc",        // Quantifier without target
        "{2,3}",       // Quantifier without target
        "\\",          // Incomplete escape
        "[z-a]",       // Invalid range
        "{-1,5}",      // Invalid repetition
        "{5,2}",       // Invalid repetition (min > max)
    };

    for (bad_patterns) |pattern| {
        const result = Regex.compile(allocator, pattern);
        // Should return an error, not crash (any error is acceptable)
        if (result) |_| {
            return error.TestExpectedError;
        } else |_| {
            // Got an error as expected
        }
    }
}

test "fuzz: edge cases with empty strings" {
    const allocator = std.testing.allocator;

    const patterns = [_][]const u8{
        "",
        ".*",
        "a*",
        "()*",
        "a|",
        "|b",
        "a||b",
    };

    for (patterns) |pattern| {
        var regex = Regex.compile(allocator, pattern) catch continue;
        defer regex.deinit();

        // Test with empty input
        _ = regex.isMatch("") catch {};
        _ = regex.find("") catch {};
    }
}

test "fuzz: long input strings" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compile(allocator, "a*b+c?");
    defer regex.deinit();

    // Create progressively longer inputs
    const sizes = [_]usize{ 100, 1000, 5000 };

    for (sizes) |size| {
        const long_input = try allocator.alloc(u8, size);
        defer allocator.free(long_input);

        @memset(long_input, 'a');

        // Should handle long inputs without crashing
        _ = regex.isMatch(long_input) catch {};
    }
}

test "fuzz: deeply nested groups" {
    const allocator = std.testing.allocator;

    // Build nested pattern: ((((a))))
    var pattern_buf: [128]u8 = undefined;
    var pos: usize = 0;

    const depth = 10;

    // Opening parens
    for (0..depth) |_| {
        pattern_buf[pos] = '(';
        pos += 1;
    }

    // Content
    pattern_buf[pos] = 'a';
    pos += 1;

    // Closing parens
    for (0..depth) |_| {
        pattern_buf[pos] = ')';
        pos += 1;
    }

    const pattern = pattern_buf[0..pos];

    var regex = try Regex.compile(allocator, pattern);
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(!try regex.isMatch("b"));
}

test "fuzz: character class stress test" {
    const allocator = std.testing.allocator;

    const patterns = [_][]const u8{
        "[a-z]+",
        "[A-Z]+",
        "[0-9]+",
        "[a-zA-Z]+",
        "[a-zA-Z0-9]+",
        "[^a-z]+",
        "[^0-9]+",
        "[\\d\\w\\s]+",
        "[a-z]{10,20}",
        "([a-z][0-9])+",
    };

    const inputs = [_][]const u8{
        "abc",
        "ABC",
        "123",
        "aBc123",
        "!@#$",
        "hello world",
        "test123TEST",
    };

    for (patterns) |pattern| {
        var regex = try Regex.compile(allocator, pattern);
        defer regex.deinit();

        for (inputs) |input| {
            _ = regex.isMatch(input) catch {};
        }
    }
}

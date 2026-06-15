const std = @import("std");
const Regex = @import("regex").Regex;
const benchmark = @import("benchmark");

const smoke_iterations = 5;

/// Comptime string repetition (the `**` operator is unavailable in this Zig).
fn repeatStr(comptime s: []const u8, comptime n: usize) []const u8 {
    comptime {
        var out: []const u8 = "";
        var i: usize = 0;
        while (i < n) : (i += 1) out = out ++ s;
        return out;
    }
}

test "benchmark: simple literal" {
    const allocator = std.testing.allocator;
    try benchmark.benchmark(allocator, "Simple literal", "hello", "hello world", smoke_iterations);
}

test "benchmark: alternation" {
    const allocator = std.testing.allocator;
    try benchmark.benchmark(allocator, "Alternation", "cat|dog|bird", "I have a dog", smoke_iterations);
}

test "benchmark: quantifier" {
    const allocator = std.testing.allocator;
    try benchmark.benchmark(allocator, "Quantifier", "a+b*c?", "aaabbbccc", smoke_iterations);
}

test "benchmark: capture groups" {
    const allocator = std.testing.allocator;
    try benchmark.benchmark(allocator, "Capture groups", "(\\w+)@(\\w+)\\.(\\w+)", "user@example.com", smoke_iterations);
}

test "benchmark: email pattern" {
    const allocator = std.testing.allocator;
    const email_pattern = "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}";
    const email = "user.name+tag@example.co.uk";
    try benchmark.benchmark(allocator, "Email pattern", email_pattern, email, smoke_iterations);
}

test "benchmark: phone number" {
    const allocator = std.testing.allocator;
    const phone_pattern = "\\d{3}-\\d{3}-\\d{4}";
    const phone = "555-123-4567";
    try benchmark.benchmark(allocator, "Phone number", phone_pattern, phone, smoke_iterations);
}

test "benchmark: URL matching" {
    const allocator = std.testing.allocator;
    const url_pattern = "https?://[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}(/[a-zA-Z0-9._~:/?#\\[\\]@!$&'()*+,;=-]*)?";
    const url = "https://example.com/path/to/resource?query=value";
    try benchmark.benchmark(allocator, "URL matching", url_pattern, url, smoke_iterations);
}

test "benchmark: repeated pattern in long text" {
    const allocator = std.testing.allocator;
    const text = comptime repeatStr("The quick brown fox jumps over the lazy dog. ", 20);
    try benchmark.benchmark(allocator, "Long text search", "fox", text, smoke_iterations);
}

test "benchmark: compilation cost" {
    const allocator = std.testing.allocator;
    try benchmark.benchmarkCompile(allocator, "Simple compile", "hello", smoke_iterations);
    try benchmark.benchmarkCompile(allocator, "Complex compile", "(\\w+)@(\\w+)\\.(\\w+)", smoke_iterations);
}

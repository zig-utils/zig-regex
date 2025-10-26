const std = @import("std");
const Regex = @import("regex").Regex;
const benchmark = @import("benchmark");

test "benchmark: simple literal" {
    const allocator = std.testing.allocator;
    try benchmark.benchmark(allocator, "Simple literal", "hello", "hello world", 1000);
}

test "benchmark: alternation" {
    const allocator = std.testing.allocator;
    try benchmark.benchmark(allocator, "Alternation", "cat|dog|bird", "I have a dog", 1000);
}

test "benchmark: quantifier" {
    const allocator = std.testing.allocator;
    try benchmark.benchmark(allocator, "Quantifier", "a+b*c?", "aaabbbccc", 1000);
}

test "benchmark: capture groups" {
    const allocator = std.testing.allocator;
    try benchmark.benchmark(allocator, "Capture groups", "(\\w+)@(\\w+)\\.(\\w+)", "user@example.com", 1000);
}

test "benchmark: email pattern" {
    const allocator = std.testing.allocator;
    const email_pattern = "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}";
    const email = "user.name+tag@example.co.uk";
    try benchmark.benchmark(allocator, "Email pattern", email_pattern, email, 1000);
}

test "benchmark: phone number" {
    const allocator = std.testing.allocator;
    const phone_pattern = "\\d{3}-\\d{3}-\\d{4}";
    const phone = "555-123-4567";
    try benchmark.benchmark(allocator, "Phone number", phone_pattern, phone, 1000);
}

test "benchmark: URL matching" {
    const allocator = std.testing.allocator;
    const url_pattern = "https?://[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}(/[a-zA-Z0-9._~:/?#\\[\\]@!$&'()*+,;=-]*)?";
    const url = "https://example.com/path/to/resource?query=value";
    try benchmark.benchmark(allocator, "URL matching", url_pattern, url, 1000);
}

test "benchmark: repeated pattern in long text" {
    const allocator = std.testing.allocator;
    const text = "The quick brown fox jumps over the lazy dog. " ** 20;
    try benchmark.benchmark(allocator, "Long text search", "fox", text, 1000);
}

test "benchmark: compilation cost" {
    const allocator = std.testing.allocator;
    try benchmark.benchmarkCompile(allocator, "Simple compile", "hello", 1000);
    try benchmark.benchmarkCompile(allocator, "Complex compile", "(\\w+)@(\\w+)\\.(\\w+)", 1000);
}

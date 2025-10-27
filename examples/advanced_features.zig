const std = @import("std");
const Regex = @import("regex").Regex;
const Builder = @import("regex").Builder;
const Patterns = @import("regex").Patterns;
const Composer = @import("regex").Composer;
const Lint = @import("regex").Lint;
const ComplexityAnalyzer = @import("regex").ComplexityAnalyzer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Advanced Regex Features Examples ===\n\n", .{});

    // Example 1: Builder API - Type-safe pattern construction
    {
        std.debug.print("───────────────────────────────────────────────\n", .{});
        std.debug.print("Example 1: Builder API for Type-Safe Construction\n", .{});
        std.debug.print("───────────────────────────────────────────────\n", .{});

        var builder = Builder.init(allocator);
        defer builder.deinit();

        // Build a pattern for email validation
        _ = try builder.startOfLine();
        _ = try builder.charRange('a', 'z');
        _ = try builder.oneOrMore();
        _ = try builder.literal("@");
        _ = try builder.charRange('a', 'z');
        _ = try builder.oneOrMore();
        _ = try builder.literal(".");
        _ = try builder.charRange('a', 'z');
        _ = try builder.repeatRange(2, 4);
        _ = try builder.endOfLine();

        const pattern = try builder.build();
        defer allocator.free(pattern);

        std.debug.print("Built pattern: {s}\n", .{pattern});

        var regex = try Regex.compile(allocator, pattern);
        defer regex.deinit();

        const test_emails = [_][]const u8{
            "user@example.com",
            "test@test.co",
            "invalid@@test.com",
            "no-at-sign.com",
        };

        for (test_emails) |email| {
            const matches = try regex.isMatch(email);
            std.debug.print("  '{s}': {s}\n", .{ email, if (matches) "✓ valid" else "✗ invalid" });
        }

        std.debug.print("\n", .{});
    }

    // Example 2: Predefined Patterns (Macros)
    {
        std.debug.print("───────────────────────────────────────────────\n", .{});
        std.debug.print("Example 2: Predefined Pattern Macros\n", .{});
        std.debug.print("───────────────────────────────────────────────\n", .{});

        // Use predefined patterns
        const email_pattern = try Patterns.email(allocator);
        defer allocator.free(email_pattern);

        const url_pattern = try Patterns.url(allocator);
        defer allocator.free(url_pattern);

        const phone_pattern = try Patterns.phoneUS(allocator);
        defer allocator.free(phone_pattern);

        std.debug.print("Email pattern: {s}\n", .{email_pattern});
        std.debug.print("URL pattern: {s}\n", .{url_pattern});
        std.debug.print("Phone pattern: {s}\n\n", .{phone_pattern});

        // Test phone number pattern
        var phone_regex = try Regex.compile(allocator, phone_pattern);
        defer phone_regex.deinit();

        const test_phones = [_][]const u8{
            "555-123-4567",
            "(555) 123-4567",
            "5551234567",
            "invalid-phone",
        };

        std.debug.print("Testing phone numbers:\n", .{});
        for (test_phones) |phone| {
            const matches = try phone_regex.isMatch(phone);
            std.debug.print("  '{s}': {s}\n", .{ phone, if (matches) "✓ valid" else "✗ invalid" });
        }

        std.debug.print("\n", .{});
    }

    // Example 3: Pattern Composition
    {
        std.debug.print("───────────────────────────────────────────────\n", .{});
        std.debug.print("Example 3: Pattern Composition\n", .{});
        std.debug.print("───────────────────────────────────────────────\n", .{});

        var composer = Composer.init(allocator);
        defer composer.deinit();

        // Compose multiple patterns with OR
        _ = try composer.add("cat");
        _ = try composer.add("dog");
        _ = try composer.add("bird");

        const alternatives = try composer.alternatives();
        defer allocator.free(alternatives);

        std.debug.print("Composed pattern (OR): {s}\n", .{alternatives});

        var regex = try Regex.compile(allocator, alternatives);
        defer regex.deinit();

        const test_strings = [_][]const u8{
            "I have a cat",
            "The dog barked",
            "A bird flew by",
            "I have a fish",
        };

        std.debug.print("Testing composed pattern:\n", .{});
        for (test_strings) |str| {
            const matches = try regex.isMatch(str);
            std.debug.print("  '{s}': {s}\n", .{ str, if (matches) "✓ match" else "✗ no match" });
        }

        std.debug.print("\n", .{});
    }

    // Example 4: Regex Linting and Analysis
    {
        std.debug.print("───────────────────────────────────────────────\n", .{});
        std.debug.print("Example 4: Pattern Linting and Analysis\n", .{});
        std.debug.print("───────────────────────────────────────────────\n", .{});

        // Analyze a potentially problematic pattern
        const problematic_pattern = "(a+)+b";
        std.debug.print("Analyzing pattern: \"{s}\"\n\n", .{problematic_pattern});

        var lint = Lint.init(allocator, problematic_pattern);
        defer lint.deinit();

        try lint.analyze();
        lint.printWarnings();

        std.debug.print("\n", .{});

        // Analyze a good pattern
        const good_pattern = "^[a-z]+$";
        std.debug.print("Analyzing pattern: \"{s}\"\n\n", .{good_pattern});

        var lint2 = Lint.init(allocator, good_pattern);
        defer lint2.deinit();

        try lint2.analyze();
        lint2.printWarnings();

        std.debug.print("\n", .{});
    }

    // Example 5: Complexity Analysis
    {
        std.debug.print("───────────────────────────────────────────────\n", .{});
        std.debug.print("Example 5: Pattern Complexity Analysis\n", .{});
        std.debug.print("───────────────────────────────────────────────\n", .{});

        const patterns_to_analyze = [_][]const u8{
            "abc",
            "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$",
            "(((a+)+)+)|(((b*)*)*)",
        };

        for (patterns_to_analyze) |pattern| {
            const complexity = ComplexityAnalyzer.analyze(pattern);

            std.debug.print("Pattern: \"{s}\"\n", .{pattern});
            std.debug.print("  Length: {d}\n", .{complexity.pattern_length});
            std.debug.print("  Nesting depth: {d}\n", .{complexity.nesting_depth});
            std.debug.print("  Groups: {d}\n", .{complexity.group_count});
            std.debug.print("  Quantifiers: {d}\n", .{complexity.quantifier_count});
            std.debug.print("  Complexity score: {d}\n", .{complexity.complexity_score});
            std.debug.print("  Level: {s}\n\n", .{@tagName(complexity.getLevel())});
        }
    }

    // Example 6: Combining All Features
    {
        std.debug.print("───────────────────────────────────────────────\n", .{});
        std.debug.print("Example 6: Combining All Features\n", .{});
        std.debug.print("───────────────────────────────────────────────\n", .{});

        // Build a complex pattern using the builder
        var builder = Builder.init(allocator);
        defer builder.deinit();

        std.debug.print("Building a URL validator:\n", .{});

        _ = try builder.startOfLine();
        _ = try builder.startNonCapturingGroup();
        _ = try builder.literal("http");
        _ = try builder.literal("s");
        _ = try builder.optional();
        _ = try builder.endGroup();
        _ = try builder.literal("://");
        _ = try builder.charClass("a-zA-Z0-9.-");
        _ = try builder.oneOrMore();
        _ = try builder.endOfLine();

        const url_pattern_built = try builder.build();
        defer allocator.free(url_pattern_built);

        std.debug.print("Built pattern: {s}\n\n", .{url_pattern_built});

        // Lint the pattern
        std.debug.print("Linting the pattern:\n", .{});
        var lint = Lint.init(allocator, url_pattern_built);
        defer lint.deinit();

        try lint.analyze();
        lint.printWarnings();

        // Analyze complexity
        const complexity = ComplexityAnalyzer.analyze(url_pattern_built);
        std.debug.print("Complexity: {s} (score: {d})\n\n", .{ @tagName(complexity.getLevel()), complexity.complexity_score });

        // Test the pattern
        var regex = try Regex.compile(allocator, url_pattern_built);
        defer regex.deinit();

        const test_urls = [_][]const u8{
            "http://example.com",
            "https://example.com",
            "ftp://example.com",
            "not-a-url",
        };

        std.debug.print("Testing URLs:\n", .{});
        for (test_urls) |url| {
            const matches = try regex.isMatch(url);
            std.debug.print("  '{s}': {s}\n", .{ url, if (matches) "✓ valid" else "✗ invalid" });
        }

        std.debug.print("\n", .{});
    }

    // Example 7: Builder API for Complex Patterns
    {
        std.debug.print("───────────────────────────────────────────────\n", .{});
        std.debug.print("Example 7: Complex Pattern with Builder\n", .{});
        std.debug.print("───────────────────────────────────────────────\n", .{});

        var builder = Builder.init(allocator);
        defer builder.deinit();

        // Build a pattern for matching IPv4 addresses
        std.debug.print("Building IPv4 address pattern:\n", .{});

        _ = try builder.startOfLine();

        // First octet
        _ = try builder.startNonCapturingGroup();
        _ = try builder.digit();
        _ = try builder.repeatRange(1, 3);
        _ = try builder.endGroup();

        // Dot
        _ = try builder.literal(".");

        // Second octet
        _ = try builder.startNonCapturingGroup();
        _ = try builder.digit();
        _ = try builder.repeatRange(1, 3);
        _ = try builder.endGroup();

        // Dot
        _ = try builder.literal(".");

        // Third octet
        _ = try builder.startNonCapturingGroup();
        _ = try builder.digit();
        _ = try builder.repeatRange(1, 3);
        _ = try builder.endGroup();

        // Dot
        _ = try builder.literal(".");

        // Fourth octet
        _ = try builder.startNonCapturingGroup();
        _ = try builder.digit();
        _ = try builder.repeatRange(1, 3);
        _ = try builder.endGroup();

        _ = try builder.endOfLine();

        const ipv4_pattern = try builder.build();
        defer allocator.free(ipv4_pattern);

        std.debug.print("Built pattern: {s}\n\n", .{ipv4_pattern});

        var regex = try Regex.compile(allocator, ipv4_pattern);
        defer regex.deinit();

        const test_ips = [_][]const u8{
            "192.168.1.1",
            "10.0.0.1",
            "256.1.1.1", // Invalid (out of range)
            "192.168.1", // Invalid (incomplete)
        };

        std.debug.print("Testing IP addresses:\n", .{});
        for (test_ips) |ip| {
            const matches = try regex.isMatch(ip);
            std.debug.print("  '{s}': {s}\n", .{ ip, if (matches) "✓ valid format" else "✗ invalid format" });
        }

        std.debug.print("\n", .{});
    }

    std.debug.print("=== All advanced features demonstrated ===\n\n", .{});
}

const std = @import("std");
const Regex = @import("regex").Regex;
const ErrorContext = @import("regex").ErrorContext;
const ErrorHelper = @import("regex").ErrorHelper;
const RegexError = @import("regex").RegexError;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Regex Error Handling Examples ===\n\n", .{});

    // Example 1: Invalid patterns with helpful error messages
    const invalid_patterns = [_][]const u8{
        "abc(def",      // Unmatched parenthesis
        "abc[def",      // Unmatched bracket
        "abc+(",        // Invalid quantifier usage
        "abc\\q",       // Invalid escape sequence
        "[z-a]",        // Invalid character range
        "(a(b(c(d(e(f(g(h(i(j(k(l(m(n(o(p(q", // Too many nested groups
    };

    for (invalid_patterns) |pattern| {
        std.debug.print("───────────────────────────────────────────────\n", .{});
        std.debug.print("Testing pattern: \"{s}\"\n", .{pattern});
        std.debug.print("───────────────────────────────────────────────\n", .{});

        if (Regex.compile(allocator, pattern)) |regex_value| {
            var regex = regex_value;
            defer regex.deinit();
            std.debug.print("✓ Pattern compiled successfully (unexpected)\n\n", .{});
        } else |err| {
            std.debug.print("❌ Compilation failed: {s}\n", .{@errorName(err)});

            // Show how to create helpful error contexts
            const ctx = switch (err) {
                RegexError.UnmatchedParenthesis => ErrorHelper.unmatchedParen(3, pattern),
                RegexError.UnmatchedBracket => ErrorHelper.unmatchedBracket(3, pattern),
                RegexError.InvalidQuantifier => ErrorHelper.invalidQuantifier(3, pattern),
                else => ErrorContext.init(RegexError.CompilationFailed, 0, pattern, "Compilation failed"),
            };

            std.debug.print("{any}\n", .{ctx});
        }
    }

    // Example 2: Graceful error handling in production code
    std.debug.print("───────────────────────────────────────────────\n", .{});
    std.debug.print("Example: Safe pattern compilation\n", .{});
    std.debug.print("───────────────────────────────────────────────\n", .{});

    const user_pattern = "hello|world";
    std.debug.print("User provided pattern: \"{s}\"\n", .{user_pattern});

    if (Regex.compile(allocator, user_pattern)) |regex_value| {
        var regex = regex_value;
        defer regex.deinit();
        std.debug.print("✓ Pattern compiled successfully\n", .{});

        // Safe matching - won't panic
        const test_input = "hello there";
        if (regex.isMatch(test_input)) |matches| {
            if (matches) {
                std.debug.print("✓ Pattern matches input\n", .{});
            } else {
                std.debug.print("Pattern does not match input\n", .{});
            }
        } else |err| {
            std.debug.print("❌ Match error: {s}\n", .{@errorName(err)});
        }
    } else |err| {
        std.debug.print("❌ Invalid pattern: {s}\n", .{@errorName(err)});
        std.debug.print("Please check your pattern syntax\n", .{});
    }

    std.debug.print("\n", .{});

    // Example 3: Error recovery strategies
    std.debug.print("───────────────────────────────────────────────\n", .{});
    std.debug.print("Example: Error recovery\n", .{});
    std.debug.print("───────────────────────────────────────────────\n", .{});

    const problematic_pattern = "abc[def";
    std.debug.print("Problematic pattern: \"{s}\"\n", .{problematic_pattern});

    if (Regex.compile(allocator, problematic_pattern)) |regex_value| {
        var regex = regex_value;
        regex.deinit();
    } else |err| {
        std.debug.print("❌ Error: {s}\n", .{@errorName(err)});
        std.debug.print("💡 Attempting to fix automatically...\n", .{});

        // Simple recovery: add missing closing bracket
        const fixed_pattern = "abc[def]";
        std.debug.print("Fixed pattern: \"{s}\"\n", .{fixed_pattern});

        if (Regex.compile(allocator, fixed_pattern)) |regex_value| {
            var regex = regex_value;
            defer regex.deinit();
            std.debug.print("✓ Fixed pattern compiles successfully!\n", .{});
        } else |fix_err| {
            std.debug.print("❌ Still invalid: {s}\n", .{@errorName(fix_err)});
        }
    }

    std.debug.print("\n", .{});

    // Example 4: Defensive programming - validate before use
    std.debug.print("───────────────────────────────────────────────\n", .{});
    std.debug.print("Example: Pattern validation\n", .{});
    std.debug.print("───────────────────────────────────────────────\n", .{});

    const patterns_to_validate = [_][]const u8{
        "^[a-z]+$",
        "[0-9]{3}-[0-9]{4}",
        "(invalid",
    };

    for (patterns_to_validate) |pattern| {
        std.debug.print("Validating: \"{s}\" ... ", .{pattern});
        if (Regex.compile(allocator, pattern)) |regex_value| {
            var regex = regex_value;
            regex.deinit();
            std.debug.print("✓ Valid\n", .{});
        } else |_| {
            std.debug.print("✗ Invalid\n", .{});
        }
    }

    std.debug.print("\n=== All examples completed successfully ===\n\n", .{});
}

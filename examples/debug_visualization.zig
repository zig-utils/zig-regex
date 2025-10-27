const std = @import("std");
const Regex = @import("regex").Regex;
const debug = @import("regex").debug;
const Parser = @import("regex").parser.Parser;
const Optimizer = @import("regex").optimizer.Optimizer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Regex Debugging and Analysis Examples ===\n\n", .{});

    const patterns = [_][]const u8{
        "hello.*world",
        "^test$",
        "(a|b)+",
        "[0-9]{3}-[0-9]{4}",
        "a++",
    };

    for (patterns) |pattern| {
        std.debug.print("───────────────────────────────────────────────\n", .{});
        std.debug.print("Pattern: \"{s}\"\n", .{pattern});
        std.debug.print("───────────────────────────────────────────────\n", .{});

        // Example 1: Show optimization info
        var regex = Regex.compile(allocator, pattern) catch |err| {
            std.debug.print("  ❌ Compilation error: {}\n\n", .{err});
            continue;
        };
        defer regex.deinit();

        std.debug.print("\nOptimization Info:\n", .{});
        if (regex.opt_info.literal_prefix) |prefix| {
            std.debug.print("  ✓ Literal prefix: \"{s}\"\n", .{prefix});
        } else {
            std.debug.print("  ✗ No literal prefix\n", .{});
        }

        if (regex.opt_info.anchored_start) {
            std.debug.print("  ✓ Start-anchored (^)\n", .{});
        }
        if (regex.opt_info.anchored_end) {
            std.debug.print("  ✓ End-anchored ($)\n", .{});
        }

        std.debug.print("  Min length: {d}\n", .{regex.opt_info.min_length});
        if (regex.opt_info.max_length) |max| {
            std.debug.print("  Max length: {d}\n", .{max});
        } else {
            std.debug.print("  Max length: unbounded\n", .{});
        }

        // Example 2: Pattern analysis
        {
            var parser = Parser.init(allocator, pattern) catch continue;
            var tree = parser.parse() catch continue;
            defer tree.deinit();

            var opt = Optimizer.init(allocator);
            var opt_info = try opt.analyze(tree.root);
            defer opt_info.deinit(allocator);

            var analyzer = debug.PatternAnalyzer.init(allocator);
            var analysis = try analyzer.analyze(pattern, &tree, &opt_info);
            defer analysis.deinit();

            std.debug.print("\nPattern Analysis:\n", .{});
            std.debug.print("  Complexity score: {d}\n", .{analysis.complexity});
            std.debug.print("  Can match empty string: {}\n", .{analysis.can_match_empty});
            std.debug.print("  Finite length: {}\n", .{analysis.is_finite});

            if (analysis.warnings.items.len > 0) {
                std.debug.print("\n  ⚠️  Warnings:\n", .{});
                for (analysis.warnings.items) |warning| {
                    std.debug.print("    • {s}\n", .{warning});
                }
            }
        }

        std.debug.print("\n", .{});
    }

    // Example 3: Test matching with debug info
    std.debug.print("───────────────────────────────────────────────\n", .{});
    std.debug.print("Testing pattern matching\n", .{});
    std.debug.print("───────────────────────────────────────────────\n", .{});

    const test_pattern = "hello.*world";
    var test_regex = try Regex.compile(allocator, test_pattern);
    defer test_regex.deinit();

    const test_inputs = [_][]const u8{
        "hello world",
        "hello beautiful world",
        "goodbye world",
        "hello",
    };

    for (test_inputs) |input| {
        const matches = try test_regex.isMatch(input);
        if (matches) {
            std.debug.print("  ✓ \"{s}\" matches\n", .{input});
        } else {
            std.debug.print("  ✗ \"{s}\" does not match\n", .{input});
        }
    }

    std.debug.print("\n", .{});
}

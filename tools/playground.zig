const std = @import("std");
const Regex = @import("regex").Regex;
const debug = @import("regex").debug;
const Parser = @import("regex").parser.Parser;
const Optimizer = @import("regex").optimizer.Optimizer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdin = std.io.getStdIn();
    const reader = stdin.reader();

    std.debug.print("\n", .{});
    std.debug.print("╔════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║           Zig Regex Playground & Debugger                 ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    var debug_config = debug.DebugConfig{
        .show_ast = false,
        .show_nfa = false,
        .show_optimizations = false,
        .use_colors = true,
    };

    while (true) {
        std.debug.print("\nOptions:\n", .{});
        std.debug.print("  1. Test a pattern\n", .{});
        std.debug.print("  2. Visualize AST\n", .{});
        std.debug.print("  3. Visualize NFA\n", .{});
        std.debug.print("  4. Show optimizations\n", .{});
        std.debug.print("  5. Export NFA to DOT (Graphviz)\n", .{});
        std.debug.print("  6. Analyze pattern\n", .{});
        std.debug.print("  7. Toggle colors\n", .{});
        std.debug.print("  8. Quick match test\n", .{});
        std.debug.print("  9. Exit\n", .{});
        std.debug.print("\nChoice: ", .{});

        var buf: [1024]u8 = undefined;
        const line = (try reader.readUntilDelimiterOrEof(&buf, '\n')) orelse continue;
        const choice = std.mem.trim(u8, line, &std.ascii.whitespace);

        if (std.mem.eql(u8, choice, "1")) {
            try testPattern(allocator, reader);
        } else if (std.mem.eql(u8, choice, "2")) {
            try visualizeAST(allocator, reader, &debug_config);
        } else if (std.mem.eql(u8, choice, "3")) {
            try visualizeNFA(allocator, reader, &debug_config);
        } else if (std.mem.eql(u8, choice, "4")) {
            try showOptimizations(allocator, reader, &debug_config);
        } else if (std.mem.eql(u8, choice, "5")) {
            try exportDotGraph(allocator, reader);
        } else if (std.mem.eql(u8, choice, "6")) {
            try analyzePattern(allocator, reader);
        } else if (std.mem.eql(u8, choice, "7")) {
            debug_config.use_colors = !debug_config.use_colors;
            if (debug_config.use_colors) {
                std.debug.print("✓ Colors enabled\n", .{});
            } else {
                std.debug.print("Colors disabled\n", .{});
            }
        } else if (std.mem.eql(u8, choice, "8")) {
            try quickMatchTest(allocator, reader);
        } else if (std.mem.eql(u8, choice, "9")) {
            std.debug.print("\nGoodbye!\n", .{});
            break;
        } else {
            std.debug.print("Invalid choice\n", .{});
        }
    }
}

fn testPattern(allocator: std.mem.Allocator, stdin: anytype) !void {
    std.debug.print("\nEnter regex pattern: ", .{});
    var pattern_buf: [1024]u8 = undefined;
    const pattern_line = (try stdin.readUntilDelimiterOrEof(&pattern_buf, '\n')) orelse return;
    const pattern = std.mem.trim(u8, pattern_line, &std.ascii.whitespace);

    std.debug.print("Enter test string: ", .{});
    var text_buf: [4096]u8 = undefined;
    const text_line = (try stdin.readUntilDelimiterOrEof(&text_buf, '\n')) orelse return;
    const text = std.mem.trim(u8, text_line, &std.ascii.whitespace);

    var regex = Regex.compile(allocator, pattern) catch |err| {
        std.debug.print("\n❌ Compilation error: {}\n", .{err});
        return;
    };
    defer regex.deinit();

    // Test isMatch
    const is_match = regex.isMatch(text) catch |err| {
        std.debug.print("\n❌ Match error: {}\n", .{err});
        return;
    };

    if (is_match) {
        std.debug.print("\n✓ Pattern matches!\n", .{});

        // Try to find the match
        if (try regex.find(text)) |match| {
            defer {
                var mut_match = match;
                mut_match.deinit(allocator);
            }

            std.debug.print("\nMatch: \"{s}\"\n", .{match.slice});
            std.debug.print("Position: {d}-{d}\n", .{ match.start, match.end });

            if (match.captures.len > 0) {
                std.debug.print("\nCapture groups:\n", .{});
                for (match.captures, 0..) |capture, i| {
                    std.debug.print("  Group {d}: \"{s}\"\n", .{ i + 1, capture });
                }
            }
        }
    } else {
        std.debug.print("\n✗ Pattern does not match\n", .{});
    }
}

fn visualizeAST(allocator: std.mem.Allocator, stdin: anytype, config: *debug.DebugConfig) !void {
    std.debug.print("\nEnter regex pattern: ", .{});
    var pattern_buf: [1024]u8 = undefined;
    const pattern_line = (try stdin.readUntilDelimiterOrEof(&pattern_buf, '\n')) orelse return;
    const pattern = std.mem.trim(u8, pattern_line, &std.ascii.whitespace);

    var parser = Parser.init(allocator, pattern) catch |err| {
        std.debug.print("\n❌ Parse error: {}\n", .{err});
        return;
    };
    var tree = parser.parse() catch |err| {
        std.debug.print("\n❌ Parse error: {}\n", .{err});
        return;
    };
    defer tree.deinit();

    const stderr = std.io.getStdErr();
    const writer = stderr.writer();
    var visualizer = debug.Visualizer.init(allocator, config.*, writer.any());
    try visualizer.visualizeAST(tree.root);
}

fn visualizeNFA(allocator: std.mem.Allocator, stdin: anytype, config: *debug.DebugConfig) !void {
    std.debug.print("\nEnter regex pattern: ", .{});
    var pattern_buf: [1024]u8 = undefined;
    const pattern_line = (try stdin.readUntilDelimiterOrEof(&pattern_buf, '\n')) orelse return;
    const pattern = std.mem.trim(u8, pattern_line, &std.ascii.whitespace);

    var regex = Regex.compile(allocator, pattern) catch |err| {
        std.debug.print("\n❌ Compilation error: {}\n", .{err});
        return;
    };
    defer regex.deinit();

    const stderr = std.io.getStdErr();
    const writer = stderr.writer();
    var visualizer = debug.Visualizer.init(allocator, config.*, writer.any());
    try visualizer.visualizeNFA(&regex.nfa);
}

fn showOptimizations(allocator: std.mem.Allocator, stdin: anytype, config: *debug.DebugConfig) !void {
    std.debug.print("\nEnter regex pattern: ", .{});
    var pattern_buf: [1024]u8 = undefined;
    const pattern_line = (try stdin.readUntilDelimiterOrEof(&pattern_buf, '\n')) orelse return;
    const pattern = std.mem.trim(u8, pattern_line, &std.ascii.whitespace);

    var regex = Regex.compile(allocator, pattern) catch |err| {
        std.debug.print("\n❌ Compilation error: {}\n", .{err});
        return;
    };
    defer regex.deinit();

    const stderr = std.io.getStdErr();
    const writer = stderr.writer();
    var visualizer = debug.Visualizer.init(allocator, config.*, writer.any());
    try visualizer.visualizeOptimizations(&regex.opt_info);
}

fn exportDotGraph(allocator: std.mem.Allocator, stdin: anytype) !void {
    std.debug.print("\nEnter regex pattern: ", .{});
    var pattern_buf: [1024]u8 = undefined;
    const pattern_line = (try stdin.readUntilDelimiterOrEof(&pattern_buf, '\n')) orelse return;
    const pattern = std.mem.trim(u8, pattern_line, &std.ascii.whitespace);

    std.debug.print("Enter output file (default: nfa.dot): ", .{});
    var file_buf: [256]u8 = undefined;
    const file_line = (try stdin.readUntilDelimiterOrEof(&file_buf, '\n')) orelse "nfa.dot";
    const filename = std.mem.trim(u8, file_line, &std.ascii.whitespace);
    const output_file = if (filename.len == 0) "nfa.dot" else filename;

    var regex = Regex.compile(allocator, pattern) catch |err| {
        std.debug.print("\n❌ Compilation error: {}\n", .{err});
        return;
    };
    defer regex.deinit();

    const file = try std.fs.cwd().createFile(output_file, .{});
    defer file.close();

    const file_writer = file.writer();
    const config = debug.DebugConfig{ .use_colors = false };
    var visualizer = debug.Visualizer.init(allocator, config, file_writer.any());
    try visualizer.generateDotGraph(&regex.nfa, pattern);

    std.debug.print("\n✓ DOT graph exported to: {s}\n", .{output_file});
    std.debug.print("  To visualize: dot -Tpng {s} -o nfa.png\n", .{output_file});
}

fn analyzePattern(allocator: std.mem.Allocator, stdin: anytype) !void {
    std.debug.print("\nEnter regex pattern: ", .{});
    var pattern_buf: [1024]u8 = undefined;
    const pattern_line = (try stdin.readUntilDelimiterOrEof(&pattern_buf, '\n')) orelse return;
    const pattern = std.mem.trim(u8, pattern_line, &std.ascii.whitespace);

    var parser = Parser.init(allocator, pattern) catch |err| {
        std.debug.print("\n❌ Parse error: {}\n", .{err});
        return;
    };
    var tree = parser.parse() catch |err| {
        std.debug.print("\n❌ Parse error: {}\n", .{err});
        return;
    };
    defer tree.deinit();

    var opt = Optimizer.init(allocator);
    var opt_info = try opt.analyze(tree.root);
    defer opt_info.deinit(allocator);

    var analyzer = debug.PatternAnalyzer.init(allocator);
    var analysis = try analyzer.analyze(pattern, &tree, &opt_info);
    defer analysis.deinit();

    std.debug.print("\n=== Pattern Analysis ===\n", .{});
    std.debug.print("Pattern: \"{s}\"\n", .{analysis.pattern});
    std.debug.print("Complexity: {d}\n", .{analysis.complexity});
    std.debug.print("Can match empty: {}\n", .{analysis.can_match_empty});
    std.debug.print("Finite length: {}\n", .{analysis.is_finite});

    if (analysis.warnings.items.len > 0) {
        std.debug.print("\n⚠️  Warnings:\n", .{});
        for (analysis.warnings.items) |warning| {
            std.debug.print("  • {s}\n", .{warning});
        }
    }

    if (analysis.suggestions.items.len > 0) {
        std.debug.print("\n💡 Suggestions:\n", .{});
        for (analysis.suggestions.items) |suggestion| {
            std.debug.print("  • {s}\n", .{suggestion});
        }
    }
}

fn quickMatchTest(allocator: std.mem.Allocator, stdin: anytype) !void {
    std.debug.print("\nEnter regex pattern: ", .{});
    var pattern_buf: [1024]u8 = undefined;
    const pattern_line = (try stdin.readUntilDelimiterOrEof(&pattern_buf, '\n')) orelse return;
    const pattern = std.mem.trim(u8, pattern_line, &std.ascii.whitespace);

    var regex = Regex.compile(allocator, pattern) catch |err| {
        std.debug.print("\n❌ Compilation error: {}\n", .{err});
        return;
    };
    defer regex.deinit();

    std.debug.print("\nEnter test strings (empty line to finish):\n", .{});

    var test_num: usize = 1;
    while (true) {
        std.debug.print("{d}. ", .{test_num});
        var text_buf: [4096]u8 = undefined;
        const text_line = (try stdin.readUntilDelimiterOrEof(&text_buf, '\n')) orelse break;
        const text = std.mem.trim(u8, text_line, &std.ascii.whitespace);

        if (text.len == 0) break;

        const is_match = regex.isMatch(text) catch |err| {
            std.debug.print("   ❌ Error: {}\n", .{err});
            test_num += 1;
            continue;
        };

        if (is_match) {
            std.debug.print("   ✓ Match\n", .{});
        } else {
            std.debug.print("   ✗ No match\n", .{});
        }

        test_num += 1;
    }
}

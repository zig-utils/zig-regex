const std = @import("std");
const Regex = @import("regex").Regex;

/// Simple benchmark framework
const Benchmark = struct {
    name: []const u8,
    iterations: usize = 10000,

    fn run(self: Benchmark, comptime func: anytype, args: anytype) !void {
        var timer = try std.time.Timer.start();
        const start = timer.read();

        var i: usize = 0;
        while (i < self.iterations) : (i += 1) {
            _ = try @call(.auto, func, args);
        }

        const end = timer.read();
        const elapsed_ns = end - start;
        const avg_ns = elapsed_ns / self.iterations;
        const avg_us = @as(f64, @floatFromInt(avg_ns)) / 1000.0;

        std.debug.print("{s}:\n", .{self.name});
        std.debug.print("  Total:   {d:.2} ms\n", .{@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0});
        std.debug.print("  Average: {d:.2} µs/op\n", .{avg_us});
        std.debug.print("  Ops/sec: {d:.0}\n\n", .{1_000_000_000.0 / @as(f64, @floatFromInt(avg_ns))});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Regex Benchmarks ===\n\n", .{});

    // Benchmark 1: Simple literal matching
    {
        var regex = try Regex.compile(allocator, "hello");
        defer regex.deinit();
        const input = "hello world";

        const bench = Benchmark{ .name = "Simple literal match", .iterations = 10000 };
        try bench.run(struct {
            fn f(r: *const Regex, i: []const u8) !bool {
                return try r.isMatch(i);
            }
        }.f, .{ &regex, input });
    }

    // Benchmark 2: Quantifier matching
    {
        var regex = try Regex.compile(allocator, "a+b*c?");
        defer regex.deinit();
        const input = "aaabbbbc";

        const bench = Benchmark{ .name = "Quantifier match (a+b*c?)", .iterations = 10000 };
        try bench.run(struct {
            fn f(r: *const Regex, i: []const u8) !bool {
                return try r.isMatch(i);
            }
        }.f, .{ &regex, input });
    }

    // Benchmark 3: Alternation
    {
        var regex = try Regex.compile(allocator, "cat|dog|bird");
        defer regex.deinit();
        const input = "dog";

        const bench = Benchmark{ .name = "Alternation (cat|dog|bird)", .iterations = 10000 };
        try bench.run(struct {
            fn f(r: *const Regex, i: []const u8) !bool {
                return try r.isMatch(i);
            }
        }.f, .{ &regex, input });
    }

    // Benchmark 4: Character class
    {
        var regex = try Regex.compile(allocator, "[a-z]+");
        defer regex.deinit();
        const input = "abcdefghijklmnop";

        const bench = Benchmark{ .name = "Character class [a-z]+", .iterations = 10000 };
        try bench.run(struct {
            fn f(r: *const Regex, i: []const u8) !bool {
                return try r.isMatch(i);
            }
        }.f, .{ &regex, input });
    }

    // Benchmark 5: Digit matching
    {
        var regex = try Regex.compile(allocator, "\\d{3}-\\d{4}");
        defer regex.deinit();
        const input = "555-1234";

        const bench = Benchmark{ .name = "Digit pattern (\\d{3}-\\d{4})", .iterations = 10000 };
        try bench.run(struct {
            fn f(r: *const Regex, i: []const u8) !bool {
                return try r.isMatch(i);
            }
        }.f, .{ &regex, input });
    }

    // Benchmark 6: Email-like pattern
    {
        var regex = try Regex.compile(allocator, "\\w+@\\w+\\.\\w+");
        defer regex.deinit();
        const input = "user@example.com";

        const bench = Benchmark{ .name = "Email pattern (\\w+@\\w+\\.\\w+)", .iterations = 5000 };
        try bench.run(struct {
            fn f(r: *const Regex, i: []const u8) !bool {
                return try r.isMatch(i);
            }
        }.f, .{ &regex, input });
    }

    // Benchmark 7: Find operation
    {
        var regex = try Regex.compile(allocator, "\\d+");
        defer regex.deinit();
        const input = "The price is $123 and tax is $45";

        const bench = Benchmark{ .name = "Find first match", .iterations = 5000 };
        try bench.run(struct {
            fn f(r: *const Regex, i: []const u8, a: std.mem.Allocator) !void {
                if (try r.find(i)) |match| {
                    var mut_match = match;
                    mut_match.deinit(a);
                }
            }
        }.f, .{ &regex, input, allocator });
    }

    // Benchmark 8: Replace operation
    {
        var regex = try Regex.compile(allocator, "\\d+");
        defer regex.deinit();
        const input = "Call 555-1234 or 555-5678";

        const bench = Benchmark{ .name = "Replace first", .iterations = 10000 };
        try bench.run(struct {
            fn f(r: *const Regex, i: []const u8, a: std.mem.Allocator) !void {
                const result = try r.replace(a, i, "XXX");
                a.free(result);
            }
        }.f, .{ &regex, input, allocator });
    }

    // Benchmark 9: Case-insensitive matching
    {
        var regex = try Regex.compileWithFlags(allocator, "hello", .{ .case_insensitive = true });
        defer regex.deinit();
        const input = "HELLO world";

        const bench = Benchmark{ .name = "Case-insensitive match", .iterations = 10000 };
        try bench.run(struct {
            fn f(r: *const Regex, i: []const u8) !bool {
                return try r.isMatch(i);
            }
        }.f, .{ &regex, input });
    }

    // Benchmark 10: Complex pattern
    {
        var regex = try Regex.compile(allocator, "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$");
        defer regex.deinit();
        const input = "test.user+tag@example.co.uk";

        const bench = Benchmark{ .name = "Complex email validation", .iterations = 10000 };
        try bench.run(struct {
            fn f(r: *const Regex, i: []const u8) !bool {
                return try r.isMatch(i);
            }
        }.f, .{ &regex, input });
    }

    std.debug.print("=== Benchmarks Complete ===\n", .{});
}

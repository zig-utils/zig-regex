const std = @import("std");
const Regex = @import("regex").Regex;

pub fn main(init: std.process.Init) !void {
    std.debug.print("=== Simple Regex Benchmarks ===\n\n", .{});

    // Test 1: Literal matching
    {
        std.debug.print("Test 1: Literal matching...\n", .{});
        var regex = try Regex.compile(init.gpa, "hello");
        defer regex.deinit();

        const start = std.Io.Timestamp.now(init.io, .real);
        const iterations: usize = 10000;
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            _ = try regex.isMatch("hello world");
        }

        const end = std.Io.Timestamp.now(init.io, .real);
        const elapsed = start.durationTo(end);

        const avg_ns = @divTrunc(elapsed.nanoseconds, iterations);

        std.debug.print("  {d} iterations in {d:.2}ms ({d:.2}µs/op)\n\n", .{
            iterations,
            @as(f64, @floatFromInt(elapsed.toMilliseconds())),
            @as(f64, @floatFromInt(avg_ns)) / std.time.us_per_ms,
        });
    }

    // Test 2: Quantifiers
    {
        std.debug.print("Test 2: Quantifiers (a+)...\n", .{});
        var regex = try Regex.compile(init.gpa, "a+");
        defer regex.deinit();

        const start = std.Io.Timestamp.now(init.io, .real);

        const iterations: usize = 10000;
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            _ = try regex.isMatch("aaaa");
        }

        const end = std.Io.Timestamp.now(init.io, .real);
        const elapsed = start.durationTo(end);
        const avg_ns = @divTrunc(elapsed.nanoseconds, iterations);

        std.debug.print("  {d} iterations in {d:.2}ms ({d:.2}µs/op)\n\n", .{
            iterations,
            @as(f64, @floatFromInt(elapsed.toMilliseconds())),
            @as(f64, @floatFromInt(avg_ns)) / std.time.us_per_ms,
        });
    }

    // Test 3: Character classes
    {
        std.debug.print("Test 3: Digit matching (\\d+)...\n", .{});
        var regex = try Regex.compile(init.gpa, "\\d+");
        defer regex.deinit();

        const start = std.Io.Timestamp.now(init.io, .real);

        const iterations: usize = 10000;
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            _ = try regex.isMatch("12345");
        }

        const end = std.Io.Timestamp.now(init.io, .real);
        const elapsed = start.durationTo(end);
        const avg_ns = @divTrunc(elapsed.nanoseconds, iterations);

        std.debug.print("  {d} iterations in {d:.2}ms ({d:.2}µs/op)\n\n", .{
            iterations,
            @as(f64, @floatFromInt(elapsed.toMilliseconds())),
            @as(f64, @floatFromInt(avg_ns)) / std.time.us_per_ms,
        });
    }

    // Test 4: Case-insensitive
    {
        std.debug.print("Test 4: Case-insensitive matching...\n", .{});
        var regex = try Regex.compileWithFlags(init.gpa, "hello", .{ .case_insensitive = true });
        defer regex.deinit();

        const start = std.Io.Timestamp.now(init.io, .real);

        const iterations: usize = 10000;
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            _ = try regex.isMatch("HELLO");
        }

        const end = std.Io.Timestamp.now(init.io, .real);
        const elapsed = start.durationTo(end);
        const avg_ns = @divTrunc(elapsed.nanoseconds, iterations);

        std.debug.print("  {d} iterations in {d:.2}ms ({d:.2}µs/op)\n\n", .{
            iterations,
            @as(f64, @floatFromInt(elapsed.toMilliseconds())),
            @as(f64, @floatFromInt(avg_ns)) / std.time.us_per_ms,
        });
    }

    std.debug.print("=== Benchmarks Complete ===\n", .{});
}

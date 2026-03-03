const std = @import("std");
const Clock = std.Io.Clock;
const Regex = @import("regex").Regex;

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const io = init.io;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Simple Regex Benchmarks ===\n\n", .{});

    // Test 1: Literal matching
    {
        std.debug.print("Test 1: Literal matching...\n", .{});
        var regex = try Regex.compile(allocator, io, "hello");
        defer regex.deinit();

        const start = Clock.awake.now(io);

        const iterations: usize = 10000;
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            _ = try regex.isMatch("hello world");
        }

        const elapsed = start.untilNow(io, .awake).toNanoseconds();
        const avg_ns = @divExact(elapsed, iterations);
        std.debug.print("  {d} iterations in {d:.2}ms ({d:.2}µs/op)\n\n", .{
            iterations,
            @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
            @as(f64, @floatFromInt(avg_ns)) / 1000.0,
        });
    }

    // Test 2: Quantifiers
    {
        std.debug.print("Test 2: Quantifiers (a+)...\n", .{});
        var regex = try Regex.compile(allocator, init.io, "a+");
        defer regex.deinit();

        const start = Clock.awake.now(init.io);

        const iterations: usize = 10000;
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            _ = try regex.isMatch("aaaa");
        }

        const elapsed = start.untilNow(init.io, .awake).toNanoseconds();
        const avg_ns = @divExact(elapsed, iterations);
        std.debug.print("  {d} iterations in {d:.2}ms ({d:.2}µs/op)\n\n", .{
            iterations,
            @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
            @as(f64, @floatFromInt(avg_ns)) / 1000.0,
        });
    }

    // Test 3: Character classes
    {
        std.debug.print("Test 3: Digit matching (\\d+)...\n", .{});
        var regex = try Regex.compile(allocator, init.io, "\\d+");
        defer regex.deinit();

        const start = Clock.awake.now(init.io);

        const iterations: usize = 10000;
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            _ = try regex.isMatch("12345");
        }

        const elapsed = start.untilNow(init.io, .awake).toNanoseconds();
        const avg_ns = @divExact(elapsed, iterations);
        std.debug.print("  {d} iterations in {d:.2}ms ({d:.2}µs/op)\n\n", .{
            iterations,
            @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
            @as(f64, @floatFromInt(avg_ns)) / 1000.0,
        });
    }

    // Test 4: Case-insensitive
    {
        std.debug.print("Test 4: Case-insensitive matching...\n", .{});
        var regex = try Regex.compileWithFlags(allocator, init.io, "hello", .{ .case_insensitive = true });
        defer regex.deinit();

        const start = Clock.awake.now(init.io);

        const iterations: usize = 10000;
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            _ = try regex.isMatch("HELLO");
        }

        const elapsed = start.untilNow(init.io, .awake).toNanoseconds();
        const avg_ns = @divExact(elapsed, iterations);
        std.debug.print("  {d} iterations in {d:.2}ms ({d:.2}µs/op)\n\n", .{
            iterations,
            @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
            @as(f64, @floatFromInt(avg_ns)) / 1000.0,
        });
    }

    std.debug.print("=== Benchmarks Complete ===\n", .{});
}

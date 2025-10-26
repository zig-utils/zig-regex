const std = @import("std");
const Regex = @import("regex.zig").Regex;

pub fn benchmark(
    allocator: std.mem.Allocator,
    name: []const u8,
    pattern: []const u8,
    input: []const u8,
    iterations: usize,
) !void {
    var regex = try Regex.compile(allocator, pattern);
    defer regex.deinit();

    const start = std.time.nanoTimestamp();

    for (0..iterations) |_| {
        const result = try regex.find(input);
        if (result) |match| {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
    }

    const end = std.time.nanoTimestamp();
    const elapsed_ns = @as(u64, @intCast(end - start));
    const avg_ns = elapsed_ns / iterations;
    const avg_us = avg_ns / 1000;

    std.debug.print("{s}: {d} iterations, avg {d}μs per match\n", .{name, iterations, avg_us});
}

pub fn benchmarkCompile(
    allocator: std.mem.Allocator,
    name: []const u8,
    pattern: []const u8,
    iterations: usize,
) !void {
    const start = std.time.nanoTimestamp();

    for (0..iterations) |_| {
        var regex = try Regex.compile(allocator, pattern);
        regex.deinit();
    }

    const end = std.time.nanoTimestamp();
    const elapsed_ns = @as(u64, @intCast(end - start));
    const avg_ns = elapsed_ns / iterations;
    const avg_us = avg_ns / 1000;

    std.debug.print("{s}: {d} compilations, avg {d}μs per compile\n", .{name, iterations, avg_us});
}

const std = @import("std");
const builtin = @import("builtin");
const Regex = @import("regex").Regex;

fn monotonicNs() u64 {
    const clk: std.c.clockid_t = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => .UPTIME_RAW,
        else => .MONOTONIC,
    };
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(clk, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn benchmark(
    allocator: std.mem.Allocator,
    name: []const u8,
    pattern: []const u8,
    input: []const u8,
    iterations: usize,
) !void {
    var regex = try Regex.compile(allocator, pattern);
    defer regex.deinit();

    const start = monotonicNs();

    for (0..iterations) |_| {
        const result = try regex.find(input);
        if (result) |match| {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
    }

    const end = monotonicNs();
    const elapsed_ns = @as(u64, @intCast(end - start));
    const avg_ns = elapsed_ns / iterations;
    const avg_us = avg_ns / 1000;

    std.debug.print("{s}: {d} iterations, avg {d}μs per match\n", .{ name, iterations, avg_us });
}

pub fn benchmarkCompile(
    allocator: std.mem.Allocator,
    name: []const u8,
    pattern: []const u8,
    iterations: usize,
) !void {
    const start = monotonicNs();

    for (0..iterations) |_| {
        var regex = try Regex.compile(allocator, pattern);
        regex.deinit();
    }

    const end = monotonicNs();
    const elapsed_ns = @as(u64, @intCast(end - start));
    const avg_ns = elapsed_ns / iterations;
    const avg_us = avg_ns / 1000;

    std.debug.print("{s}: {d} compilations, avg {d}μs per compile\n", .{ name, iterations, avg_us });
}

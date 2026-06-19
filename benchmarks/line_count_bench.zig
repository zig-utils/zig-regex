//! Reliable in-process benchmark for matching-line counting: serial vs a
//! bench-local multi-threaded chunking. Reads the haystack from stdin once,
//! times with a monotonic clock (excludes stdin I/O and process startup), and
//! reports ms/iter for each. Used to settle whether multi-threading actually
//! helps (and isolate thread-spawn cost from allocator contention).
//!
//!   line_count_bench <pattern> [iters]   < haystack

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

const Worker = struct {
    re: *const Regex,
    chunk: []const u8,
    result: usize = 0,
    fn run(ctx: *Worker) void {
        ctx.result = ctx.re.countMatchingLines(ctx.chunk) catch 0;
    }
};

fn parallelCount(re: *const Regex, input: []const u8, workers: usize) usize {
    var starts: [32]usize = undefined;
    var ends: [32]usize = undefined;
    starts[0] = 0;
    var made: usize = 0;
    var w: usize = 0;
    while (w < workers) : (w += 1) {
        if (w == workers - 1) {
            ends[w] = input.len;
        } else {
            const approx = (input.len * (w + 1)) / workers;
            ends[w] = std.mem.indexOfScalarPos(u8, input, approx, '\n') orelse input.len;
        }
        made = w + 1;
        if (ends[w] >= input.len) break;
        starts[w + 1] = ends[w] + 1;
    }
    var ctxs: [32]Worker = undefined;
    var threads: [32]?std.Thread = .{null} ** 32;
    var i: usize = 0;
    while (i < made) : (i += 1) ctxs[i] = .{ .re = re, .chunk = input[starts[i]..ends[i]] };
    i = 1;
    while (i < made) : (i += 1) threads[i] = std.Thread.spawn(.{}, Worker.run, .{&ctxs[i]}) catch null;
    Worker.run(&ctxs[0]);
    var total: usize = 0;
    i = 1;
    while (i < made) : (i += 1) {
        if (threads[i]) |t| t.join() else Worker.run(&ctxs[i]);
    }
    i = 0;
    while (i < made) : (i += 1) total += ctxs[i].result;
    return total;
}

fn readStdin(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var rbuf: [64 * 1024]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &rbuf);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try reader.interface.readSliceShort(&chunk);
        if (n == 0) break;
        try out.appendSlice(allocator, chunk[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("usage: line_count_bench <pattern> [iters] < haystack\n", .{});
        return;
    }
    const pattern = args[1];
    const iters: usize = if (args.len >= 3) try std.fmt.parseInt(usize, args[2], 10) else 30;

    const input = try readStdin(allocator, init.io);
    defer allocator.free(input);

    var re = try Regex.compileWithFlags(allocator, pattern, .{ .multiline = true });
    defer re.deinit();

    const ncpu = std.Thread.getCpuCount() catch 1;

    // Serial.
    var sink: usize = 0;
    var t0 = monotonicNs();
    var k: usize = 0;
    while (k < iters) : (k += 1) sink +%= try re.countMatchingLines(input);
    const serial_ns = monotonicNs() - t0;

    // Parallel via the library (shared pre-built DFA across threads).
    _ = parallelCount; // (bench-local chunking kept for reference)
    t0 = monotonicNs();
    k = 0;
    while (k < iters) : (k += 1) sink +%= try re.countMatchingLinesParallel(input);
    const par_ns = monotonicNs() - t0;

    const ser_ms = @as(f64, @floatFromInt(serial_ns)) / @as(f64, @floatFromInt(iters)) / 1e6;
    const par_ms = @as(f64, @floatFromInt(par_ns)) / @as(f64, @floatFromInt(iters)) / 1e6;
    std.debug.print("pattern={s} bytes={d} cpus={d}\n  serial   {d:.2} ms/iter\n  parallel {d:.2} ms/iter  ({d:.2}x)\n  (sink={d})\n", .{
        pattern, input.len, ncpu, ser_ms, par_ms, ser_ms / par_ms, sink % 100,
    });
}

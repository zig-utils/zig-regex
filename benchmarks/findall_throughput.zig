//! findAll throughput benchmark — mirrors zig-utils/zig-regex#10.
//!
//! Measures engine-only search throughput (compile, single `find`, and
//! `findAll`) on a ~1.17 MB synthetic haystack, excluding process startup and
//! stdin reading. Designed to be compared head-to-head with the Rust `regex`
//! crate (see benchmarks/rust-bench and benchmarks/compare.sh).
//!
//! Modes:
//!   (no args)            run the full internal benchmark table
//!   gen [words]          write a deterministic haystack to stdout
//!   <pattern> [iters]    read a haystack from stdin, time findAll, and print
//!                        `total iterations elapsed_ns` (matches #10's program)
//!
//! Build with -Doptimize=ReleaseFast and libc linked (clock_gettime).

const std = @import("std");
const builtin = @import("builtin");
const Regex = @import("regex").Regex;

const WORDS = [_][]const u8{ "hello", "world", "foo123", "bar456", "baz789", "test", "regex", "zig", "rust" };
const DEFAULT_WORDS: usize = 200_000;

fn monotonicNs() u64 {
    const clk: std.c.clockid_t = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => .UPTIME_RAW,
        else => .MONOTONIC,
    };
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(clk, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// Build a deterministic haystack of `n` space-joined words from the pool, using
/// a small xorshift PRNG so runs are reproducible across machines.
fn buildHaystack(allocator: std.mem.Allocator, n: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var state: u64 = 0x9E3779B97F4A7C15;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        // xorshift64
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        const w = WORDS[@intCast(state % WORDS.len)];
        if (i != 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, w);
    }
    return out.toOwnedSlice(allocator);
}

fn countFindAll(allocator: std.mem.Allocator, re: *const Regex, haystack: []const u8) !usize {
    const matches = try re.findAll(allocator, haystack);
    defer {
        for (matches) |*m| m.deinit(allocator);
        allocator.free(matches);
    }
    return matches.len;
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

fn writeStdout(io: std.Io, bytes: []const u8) !void {
    var wbuf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &wbuf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    // Use the release-grade SMP allocator for the engine work — `init.gpa` is a
    // safety/debug allocator, which would dominate the timing and skew the
    // comparison against Rust's fast global allocator.
    const gpa = std.heap.smp_allocator;
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    // gen mode: emit a haystack to stdout.
    if (args.len >= 2 and std.mem.eql(u8, args[1], "gen")) {
        const n = if (args.len >= 3) try std.fmt.parseInt(usize, args[2], 10) else DEFAULT_WORDS;
        const haystack = try buildHaystack(gpa, n);
        defer gpa.free(haystack);
        try writeStdout(io, haystack);
        return;
    }

    // stdin mode: <pattern> [iters] — time findAll over a stdin haystack and
    // print `total iterations elapsed_ns` for head-to-head comparison.
    if (args.len >= 2) {
        const pattern = args[1];
        const iterations: usize = if (args.len >= 3) try std.fmt.parseInt(usize, args[2], 10) else 1;
        const haystack = try readStdin(gpa, io);
        defer gpa.free(haystack);

        var re = try Regex.compile(gpa, pattern);
        defer re.deinit();

        // Use count() — the allocation-free counterpart of Rust's
        // find_iter().count(), so the head-to-head is apples-to-apples.
        _ = try re.count(haystack); // warmup

        const start = monotonicNs();
        var total: usize = 0;
        var i: usize = 0;
        while (i < iterations) : (i += 1) total += try re.count(haystack);
        const elapsed = monotonicNs() - start;

        var buf: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "{d} {d} {d}\n", .{ total, iterations, elapsed });
        try writeStdout(io, line);
        return;
    }

    // Default: the full internal table.
    const haystack = try buildHaystack(gpa, DEFAULT_WORDS);
    defer gpa.free(haystack);

    std.debug.print("=== findAll throughput (issue #10) ===\n", .{});
    std.debug.print("haystack: {d} bytes ({d} words)\n\n", .{ haystack.len, DEFAULT_WORDS });

    const patterns = [_][]const u8{ "hello", "hello|world|test", "\\d+", "\\w+" };
    const ITERS: usize = 20;

    // Compile timing (1000x).
    {
        const N: usize = 1000;
        const start = monotonicNs();
        var k: usize = 0;
        while (k < N) : (k += 1) {
            var re = try Regex.compile(gpa, "hello");
            re.deinit();
        }
        const elapsed = monotonicNs() - start;
        std.debug.print("compile `hello`        : {d:.3} us/op\n\n", .{usPer(elapsed, N)});
    }

    std.debug.print("{s:<22} {s:>10} {s:>14} {s:>14}\n", .{ "pattern", "matches", "find us/op", "findAll ms/op" });
    std.debug.print("{s:-<62}\n", .{""});
    for (patterns) |pat| {
        var re = try Regex.compile(gpa, pat);
        defer re.deinit();

        const match_count = try countFindAll(gpa, &re, haystack);

        // single find
        var find_per: u64 = 0;
        {
            const N: usize = 1000;
            const start = monotonicNs();
            var k: usize = 0;
            while (k < N) : (k += 1) {
                if (try re.find(haystack)) |m| std.mem.doNotOptimizeAway(m.start);
            }
            find_per = (monotonicNs() - start) / N;
        }

        // findAll
        var fa_per: u64 = 0;
        {
            const start = monotonicNs();
            var k: usize = 0;
            while (k < ITERS) : (k += 1) _ = try countFindAll(gpa, &re, haystack);
            fa_per = (monotonicNs() - start) / ITERS;
        }

        std.debug.print("{s:<22} {d:>10} {d:>14.3} {d:>14.3}\n", .{
            pat,
            match_count,
            @as(f64, @floatFromInt(find_per)) / 1000.0,
            @as(f64, @floatFromInt(fa_per)) / 1_000_000.0,
        });
    }
    std.debug.print("\n", .{});
}

fn usPer(elapsed_ns: u64, n: usize) f64 {
    return (@as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(n))) / 1000.0;
}

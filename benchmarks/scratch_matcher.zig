//! Allocation-free matcher benchmark: `Program` + `Scratch` against the
//! reusable `Regex.Matcher`, on the same patterns and inputs.
//!
//! Two workloads: one large haystack (throughput), and many small buffers
//! (the per-call cost a scanner pays per file or per chunk). Build with
//! `zig build bench-scratch` (ReleaseFast, libc for clock_gettime).

const std = @import("std");
const builtin = @import("builtin");
const regex = @import("regex");
const Regex = regex.Regex;
const Program = regex.Program;
const Scratch = regex.Scratch;

fn monotonicNs() u64 {
    const clk: std.c.clockid_t = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => .UPTIME_RAW,
        else => .MONOTONIC,
    };
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(clk, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

const Case = struct {
    name: []const u8,
    pattern: []const u8,
    flags: regex.common.CompileFlags = .{},
};

const cases = [_]Case{
    .{ .name = "literal", .pattern = "regex" },
    .{ .name = "class run", .pattern = "[0-9]{3,}" },
    .{ .name = "word pair", .pattern = "\\w+\\s+zig" },
    .{ .name = "alternation", .pattern = "(?:foo|bar|baz)[0-9]+" },
    .{ .name = "anchored line", .pattern = "^test\\b", .flags = .{ .multiline = true } },
    .{ .name = "bytes sig", .pattern = "MZ.{2}\\x50\\x45\\x00\\x00", .flags = .{ .bytes = true } },
    .{ .name = "bytes class", .pattern = "[\\x80-\\xff]{4}\\x00", .flags = .{ .bytes = true } },
    .{ .name = "case-insens", .pattern = "hello[ \\t]+world", .flags = .{ .case_insensitive = true } },
};

fn buildHaystack(buf: []u8) void {
    const words = [_][]const u8{ "hello", "world", "foo123", "bar456", "baz789", "test", "regex", "zig", "rust", "\x90\x91\x92", "MZ\x90\x00PE" };
    var state: u64 = 0x9E3779B97F4A7C15;
    var i: usize = 0;
    while (i < buf.len) {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        const w = words[@intCast(state % words.len)];
        const sep: u8 = if (state % 17 == 0) '\n' else ' ';
        for (w) |c| {
            if (i == buf.len) break;
            buf[i] = c;
            i += 1;
        }
        if (i < buf.len) {
            buf[i] = sep;
            i += 1;
        }
    }
}

const Result = struct { ns: u64, sink: usize };
const Op = enum { is_match, count };

fn timeMatcher(re: *const Regex, input: []const u8, chunk: usize, reps: usize, op: Op) !Result {
    var m = re.matcher();
    defer m.deinit();
    var sink: usize = 0;
    const t0 = monotonicNs();
    var r: usize = 0;
    while (r < reps) : (r += 1) {
        var off: usize = 0;
        while (off < input.len) : (off += chunk) {
            const piece = input[off..@min(input.len, off + chunk)];
            sink += switch (op) {
                .is_match => @intFromBool(try m.isMatch(piece)),
                .count => try m.count(piece),
            };
        }
    }
    return .{ .ns = monotonicNs() - t0, .sink = sink };
}

fn timeProgram(program: *const Program, scratch: *Scratch, input: []const u8, chunk: usize, reps: usize, op: Op) !Result {
    var sink: usize = 0;
    const t0 = monotonicNs();
    var r: usize = 0;
    while (r < reps) : (r += 1) {
        var off: usize = 0;
        while (off < input.len) : (off += chunk) {
            const piece = input[off..@min(input.len, off + chunk)];
            sink += switch (op) {
                .is_match => @intFromBool(try program.isMatch(scratch, piece)),
                .count => try program.count(scratch, piece),
            };
        }
    }
    return .{ .ns = monotonicNs() - t0, .sink = sink };
}

pub fn main(init: std.process.Init) !void {
    // The release allocator: `init.gpa` is a debug allocator and would skew
    // the Matcher side, which allocates while it warms up.
    const allocator = std.heap.smp_allocator;
    const io = init.io;
    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buf);
    const w = &out.interface;

    const haystack = try allocator.alloc(u8, 4 << 20);
    defer allocator.free(haystack);
    buildHaystack(haystack);

    try w.print("{s:<14} {s:<9} {s:>12} {s:>12} {s:>8}\n", .{ "case", "workload", "Matcher", "Scratch", "ratio" });
    for (cases) |c| {
        var re = try Regex.compileWithFlags(allocator, c.pattern, c.flags);
        defer re.deinit();
        var program = Program.fromRegex(allocator, &re) catch |err| {
            try w.print("{s:<14} skipped: {t}\n", .{ c.name, err });
            continue;
        };
        defer program.deinit(allocator);
        var scratch = try Scratch.init(allocator, &program);
        defer scratch.deinit(allocator);

        const Workload = struct { name: []const u8, chunk: usize, reps: usize, count: bool };
        const workloads = [_]Workload{
            .{ .name = "count 4MB", .chunk = haystack.len, .reps = 3, .count = true },
            .{ .name = "isMatch 256B", .chunk = 256, .reps = 3, .count = false },
        };
        for (workloads) |wl| {
            const op: Op = if (wl.count) .count else .is_match;
            // Warm both caches, then time.
            _ = try timeMatcher(&re, haystack[0..65536], wl.chunk, 1, op);
            _ = try timeProgram(&program, &scratch, haystack[0..65536], wl.chunk, 1, op);
            const a = try timeMatcher(&re, haystack, wl.chunk, wl.reps, op);
            const b = try timeProgram(&program, &scratch, haystack, wl.chunk, wl.reps, op);
            if (a.sink != b.sink) {
                try w.print("MISMATCH {s} {s}: matcher {d} scratch {d}\n", .{ c.name, wl.name, a.sink, b.sink });
            }
            const mbps_a = @as(f64, @floatFromInt(haystack.len * wl.reps)) / @as(f64, @floatFromInt(a.ns)) * 1000.0;
            const mbps_b = @as(f64, @floatFromInt(haystack.len * wl.reps)) / @as(f64, @floatFromInt(b.ns)) * 1000.0;
            try w.print("{s:<14} {s:<12} {d:>8.0} MB/s {d:>8.0} MB/s {d:>6.2}x\n", .{ c.name, wl.name, mbps_a, mbps_b, mbps_b / mbps_a });
        }
    }
    try w.flush();
}

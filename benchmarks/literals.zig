//! Throughput benchmarks for the multi-literal engines in src/literals.
//!
//!   zig build bench-literals                 run every benchmark
//!   zig build bench-literals -- teddy        run one group (teddy, ac, sbbf)
//!
//! Haystacks are deterministic (xorshift), so numbers compare across runs and
//! machines. Each case reports the best of several timed passes in GB/s
//! (10^9 bytes per second).

const std = @import("std");
const builtin = @import("builtin");
const lit = @import("regex").literals;

const Pattern = lit.Pattern;
const Match = lit.Match;

extern "c" fn memmem(big: [*]const u8, big_len: usize, little: [*]const u8, little_len: usize) ?[*]const u8;

fn monotonicNs() u64 {
    const clk: std.c.clockid_t = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => .UPTIME_RAW,
        else => .MONOTONIC,
    };
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(clk, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

const Rng = struct {
    s: u64,
    fn next(self: *Rng) u64 {
        self.s ^= self.s << 13;
        self.s ^= self.s >> 7;
        self.s ^= self.s << 17;
        return self.s;
    }
};

const words = [_][]const u8{
    "the",   "of",    "and",    "to",     "in",      "a",      "is",      "that",  "for",
    "it",    "as",    "was",    "with",   "be",      "by",     "on",      "not",   "he",
    "this",  "are",   "or",     "his",    "from",    "at",     "which",   "but",   "have",
    "an",    "had",   "they",   "you",    "were",    "their",  "one",     "all",   "we",
    "can",   "her",   "has",    "there",  "been",    "if",     "more",    "when",  "will",
    "would", "who",   "so",     "no",     "she",     "other",  "its",     "may",   "these",
    "about", "them",  "than",   "some",   "time",    "into",   "only",    "do",    "could",
    "new",   "after", "first",  "also",   "made",    "two",    "like",    "over",  "such",
    "most",  "where", "people", "before", "through", "should", "between", "under", "never",
};

fn randomBytes(gpa: std.mem.Allocator, len: usize, seed: u64) ![]u8 {
    const buf = try gpa.alloc(u8, len);
    var r: Rng = .{ .s = seed };
    var i: usize = 0;
    while (i + 8 <= len) : (i += 8) std.mem.writeInt(u64, buf[i..][0..8], r.next(), .little);
    while (i < len) : (i += 1) buf[i] = @truncate(r.next());
    return buf;
}

/// Words drawn from `words`, with one of `plants` (if any) about every 2 KiB.
fn englishText(gpa: std.mem.Allocator, len: usize, seed: u64, plants: []const []const u8) ![]u8 {
    const buf = try gpa.alloc(u8, len);
    var r: Rng = .{ .s = seed };
    var i: usize = 0;
    while (i < len) {
        const w = if (plants.len > 0 and r.next() % 400 == 0)
            plants[r.next() % plants.len]
        else
            words[r.next() % words.len];
        for (w) |c| {
            if (i == len) break;
            buf[i] = c;
            i += 1;
        }
        if (i < len) {
            buf[i] = if (r.next() % 12 == 0) '\n' else ' ';
            i += 1;
        }
    }
    return buf;
}

/// Run `f` until about 0.3 s have passed and return the best GB/s.
fn measure(bytes: usize, ctx: anytype, comptime f: fn (@TypeOf(ctx)) usize) struct { gbps: f64, result: usize } {
    var best: u64 = std.math.maxInt(u64);
    var result: usize = 0;
    const start = monotonicNs();
    var passes: usize = 0;
    while (passes < 3 or monotonicNs() - start < 300_000_000) : (passes += 1) {
        const t0 = monotonicNs();
        result = f(ctx);
        const dt = monotonicNs() - t0;
        best = @min(best, dt);
        std.mem.doNotOptimizeAway(result);
    }
    return .{ .gbps = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(@max(best, 1))), .result = result };
}

fn report(name: []const u8, bytes: usize, gbps: f64, result: usize) void {
    std.debug.print("  {s:<60} {d:>8.2} GB/s  ({d} MiB, result {d})\n", .{ name, gbps, bytes >> 20, result });
}

// ---------------------------------------------------------------- Teddy

const TeddyCase = struct {
    t: *const lit.Teddy,
    hay: []const u8,
    pats: []const Pattern,

    fn countScan(c: *const TeddyCase) usize {
        var n: usize = 0;
        _ = c.t.scan(c.hay, &n, struct {
            fn on(k: *usize, _: Match) bool {
                k.* += 1;
                return true;
            }
        }.on);
        return n;
    }

    fn countFind(c: *const TeddyCase) usize {
        var n: usize = 0;
        var from: usize = 0;
        while (c.t.find(c.hay, from)) |m| : (n += 1) from = m.start + 1;
        return n;
    }

    /// The baseline: one libc memmem pass per pattern.
    fn countMemmem(c: *const TeddyCase) usize {
        var n: usize = 0;
        for (c.pats) |p| {
            var from: usize = 0;
            while (from < c.hay.len) : (n += 1) {
                const hit = memmem(c.hay.ptr + from, c.hay.len - from, p.bytes.ptr, p.bytes.len) orelse break;
                from = @intFromPtr(hit) - @intFromPtr(c.hay.ptr) + 1;
            }
        }
        return n;
    }
};

fn benchTeddy(gpa: std.mem.Allocator) !void {
    std.debug.print("teddy\n", .{});
    const size = 16 << 20;
    const rand = try randomBytes(gpa, size, 0x1234567);
    defer gpa.free(rand);
    const names = [_][]const u8{ "Sherlock", "Holmes", "Watson", "Moriarty", "Lestrade", "Hudson", "Adler", "Baskerville" };
    const text = try englishText(gpa, size, 0x7654321, &names);
    defer gpa.free(text);

    var pats8: [8]Pattern = undefined;
    for (names, 0..) |s, i| pats8[i] = .{ .bytes = s, .id = @intCast(i) };

    var pats_bin: [8]Pattern = undefined;
    const bin_store = try randomBytes(gpa, 8 * 6, 99);
    defer gpa.free(bin_store);
    for (0..8) |i| pats_bin[i] = .{ .bytes = bin_store[i * 6 ..][0..6], .id = @intCast(i) };

    var pats32: [32]Pattern = undefined;
    for (0..32) |i| pats32[i] = .{ .bytes = bin_store[(i % 8) * 6 ..][0 .. 3 + i % 4], .id = @intCast(i) };

    const Set = struct { name: []const u8, pats: []const Pattern, nocase: bool };
    const sets = [_]Set{
        .{ .name = "8 words", .pats = &pats8, .nocase = false },
        .{ .name = "8 words nocase", .pats = &pats8, .nocase = true },
        .{ .name = "8 binary", .pats = &pats_bin, .nocase = false },
        .{ .name = "32 binary", .pats = &pats32, .nocase = false },
    };
    const Hay = struct { name: []const u8, bytes: []const u8 };
    const hays = [_]Hay{ .{ .name = "random", .bytes = rand }, .{ .name = "text", .bytes = text } };

    var buf: [128]u8 = undefined;
    for (sets) |set| {
        var t = try lit.Teddy.build(gpa, set.pats, .{ .ascii_case_insensitive = set.nocase });
        defer t.deinit(gpa);
        for (hays) |h| {
            const c: TeddyCase = .{ .t = &t.view, .hay = h.bytes, .pats = set.pats };
            const s = measure(h.bytes.len, &c, TeddyCase.countScan);
            report(try std.fmt.bufPrint(&buf, "{s}, {s}, scan", .{ set.name, h.name }), h.bytes.len, s.gbps, s.result);
            const f = measure(h.bytes.len, &c, TeddyCase.countFind);
            report(try std.fmt.bufPrint(&buf, "{s}, {s}, find loop", .{ set.name, h.name }), h.bytes.len, f.gbps, f.result);
            if (!set.nocase) {
                const m = measure(h.bytes.len, &c, TeddyCase.countMemmem);
                report(try std.fmt.bufPrint(&buf, "{s}, {s}, naive multi-memmem", .{ set.name, h.name }), h.bytes.len, m.gbps, m.result);
            }
        }
    }
}

// ---------------------------------------------------------- Aho-Corasick

const AcCase = struct {
    ac: *const lit.AhoCorasick,
    hay: []const u8,

    fn countAll(c: *const AcCase) usize {
        var n: usize = 0;
        _ = c.ac.scanAll(c.hay, &n, struct {
            fn on(k: *usize, _: Match) bool {
                k.* += 1;
                return true;
            }
        }.on);
        return n;
    }

    fn countLeftmostLongest(c: *const AcCase) usize {
        var n: usize = 0;
        var it = c.ac.iterator(c.hay);
        while (it.next()) |_| n += 1;
        return n;
    }
};

/// `n` random lowercase words of 4 to 12 letters.
fn randomWords(gpa: std.mem.Allocator, n: usize, seed: u64) ![][]u8 {
    const out = try gpa.alloc([]u8, n);
    var r: Rng = .{ .s = seed };
    for (out) |*w| {
        w.* = try gpa.alloc(u8, 4 + r.next() % 9);
        for (w.*) |*c| c.* = 'a' + @as(u8, @intCast(r.next() % 26));
    }
    return out;
}

fn benchAc(gpa: std.mem.Allocator) !void {
    std.debug.print("aho-corasick\n", .{});
    const size = 16 << 20;
    const rand = try randomBytes(gpa, size, 0xabcdef);
    defer gpa.free(rand);

    var buf: [128]u8 = undefined;
    for ([_]usize{ 8, 100, 1000, 10000 }) |n| {
        const vocab = try randomWords(gpa, n, n);
        defer {
            for (vocab) |w| gpa.free(w);
            gpa.free(vocab);
        }
        const plants: []const []const u8 = vocab;
        const text = try englishText(gpa, size, 0x5151, plants);
        defer gpa.free(text);
        const pats = try gpa.alloc(Pattern, n);
        defer gpa.free(pats);
        for (vocab, 0..) |w, i| pats[i] = .{ .bytes = w, .id = @intCast(i) };

        for ([_]lit.aho_corasick.Layout{ .dense, .sparse }) |layout| {
            var ac = try lit.AhoCorasick.build(gpa, pats, .{ .layout = layout });
            defer ac.deinit(gpa);
            const kib = ac.bytes.len >> 10;
            for ([_][]const u8{ "random", "text" }, [_][]const u8{ rand, text }) |hname, hay| {
                const c: AcCase = .{ .ac = &ac.view, .hay = hay };
                const a = measure(hay.len, &c, AcCase.countAll);
                report(try std.fmt.bufPrint(&buf, "{d} words {s} ({d} KiB), {s}, all", .{ n, @tagName(layout), kib, hname }), hay.len, a.gbps, a.result);
                const l = measure(hay.len, &c, AcCase.countLeftmostLongest);
                report(try std.fmt.bufPrint(&buf, "{d} words {s} ({d} KiB), {s}, leftmost-longest", .{ n, @tagName(layout), kib, hname }), hay.len, l.gbps, l.result);
            }
        }
    }
}

// ------------------------------------------------------------------ SBBF

const SbbfCase = struct {
    f: *const lit.Sbbf,
    hay: []const u8,

    fn countCandidates(c: *const SbbfCase) usize {
        var buf: [1024]usize = undefined;
        var n: usize = 0;
        var p = c.f.prober(c.hay, 0);
        while (true) {
            const got = p.next(&buf);
            if (got.len == 0) break;
            n += got.len;
        }
        return n;
    }
};

/// Nominal P-core clock used to turn GB/s into cycles per byte.
const nominal_ghz = 4.05;

fn benchSbbf(gpa: std.mem.Allocator) !void {
    std.debug.print("sbbf (cycles per byte assume {d:.2} GHz)\n", .{nominal_ghz});
    const size = 16 << 20;
    const rand = try randomBytes(gpa, size, 0x5bbf);
    defer gpa.free(rand);
    const text = try englishText(gpa, size, 0x7e47, &.{});
    defer gpa.free(text);

    var buf: [128]u8 = undefined;
    for ([_]usize{ 64 << 10, 1 << 20, 16 << 20, 64 << 20 }) |filter_bytes| {
        // 16 bits per key.
        const keys = filter_bytes * 8 / 16;
        for ([_]u32{ 1, 4, 8 }) |stride| {
            var b = try lit.sbbf.Builder.init(gpa, .{ .stride = stride, .bits_per_key = 16, .seed = 7 });
            defer b.deinit();
            var r: Rng = .{ .s = keys + stride };
            for (0..keys) |_| try b.addGram(@truncate(r.next()));
            var f = try b.finish();
            defer f.deinit(gpa);
            for ([_][]const u8{ "random", "text" }, [_][]const u8{ rand, text }) |hname, hay| {
                const c: SbbfCase = .{ .f = &f.view, .hay = hay };
                const m = measure(hay.len, &c, SbbfCase.countCandidates);
                const name = try std.fmt.bufPrint(&buf, "{d} KiB filter, stride {d}, {s} ({d:.2} c/B)", .{
                    f.bytes.len >> 10, stride, hname, nominal_ghz / m.gbps,
                });
                report(name, hay.len, m.gbps, m.result);
            }
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const args = try init.minimal.args.toSlice(arena_state.allocator());
    const only: ?[]const u8 = if (args.len >= 2) args[1] else null;
    std.debug.print("literals benchmarks ({s}, {s})\n", .{ @tagName(builtin.cpu.arch), builtin.cpu.model.name });
    if (only == null or std.mem.eql(u8, only.?, "teddy")) try benchTeddy(gpa);
    if (only == null or std.mem.eql(u8, only.?, "ac")) try benchAc(gpa);
    if (only == null or std.mem.eql(u8, only.?, "sbbf")) try benchSbbf(gpa);
}

//! `zig build bench`: the numbers in docs/BENCHMARKS.md.
//!
//!   zig build bench                      every section, as Markdown tables
//!   zig build bench -- literals          the multi-literal matchers only
//!   zig build bench -- regex             the byte-mode regex programs only
//!
//! Literal matchers (Teddy, Aho-Corasick in both layouts, the Bloom
//! prefilter at strides 1, 4 and 8, and a naive one-pass-per-literal
//! baseline) run over set sizes 8, 64, 1k, 100k and 400k, each on a text and
//! a binary corpus. Throughput is timed in this process. Memory is measured
//! from outside, with zig-benchmarks' process mode sampling a child copy of
//! this program the way the operating system accounts for it:
//!
//! - build peak: peak RSS (the kernel's high-water mark) of a child that
//!   builds the structure, minus that of a child holding only the inputs;
//! - mapped RSS and mapped dirty: resident and private dirty memory of a
//!   child that mmaps the serialised structure and scans the corpus with it,
//!   minus those of a child holding only the corpus, both sampled once the
//!   inputs are generated. Searching in place should cost clean, shareable
//!   pages and no dirty ones.
//!
//! The regex section runs each pattern of `patterns/clamav.txt` and
//! `patterns/crs.txt` as a byte-mode `Program`. The same program also backs
//! benchmarks/pcre2/compare.sh, the external comparison with PCRE2:
//!
//!   bench_suite gen <patterns.txt> <binary|http> <out>   write a corpus
//!   bench_suite regex-file <patterns.txt> <corpus>       one TSV row per pattern

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const regex = @import("regex");
const lit = regex.literals;
const process = @import("process");
const gen = @import("gen.zig");

const clamav_patterns = @embedFile("patterns/clamav.txt");
const crs_patterns = @embedFile("patterns/crs.txt");

const corpus_len = 16 << 20;
const set_sizes = [_]usize{ 8, 64, 1_000, 100_000, 400_000 };
/// How long a memory child holds its state so the sampler sees it. The
/// mapped figures come from the last three quarters of this window, after
/// the inputs are generated.
const hold_ms = 400;
const sample_hz = 100;
/// Dense Aho-Corasick is skipped when its full DFA would exceed this.
const dense_cap: u64 = 256 << 20;
const bits_per_key = 16;
const blob_dir = ".zig-cache/bench-suite";
const blob_path = blob_dir ++ "/structure.bin";

const Matcher = enum {
    naive,
    teddy,
    ac_dense,
    ac_sparse,
    bloom_s1,
    bloom_s4,
    bloom_s8,

    fn label(m: Matcher) []const u8 {
        return switch (m) {
            .naive => "naive (one pass per literal)",
            .teddy => "Teddy",
            .ac_dense => "Aho-Corasick dense",
            .ac_sparse => "Aho-Corasick sparse",
            .bloom_s1 => "Bloom, stride 1",
            .bloom_s4 => "Bloom, stride 4",
            .bloom_s8 => "Bloom, stride 8",
        };
    }

    fn stride(m: Matcher) u32 {
        return switch (m) {
            .bloom_s1 => 1,
            .bloom_s4 => 4,
            .bloom_s8 => 8,
            else => unreachable,
        };
    }

    fn isBloom(m: Matcher) bool {
        return m == .bloom_s1 or m == .bloom_s4 or m == .bloom_s8;
    }
};

const View = union(enum) {
    naive: []const lit.Pattern,
    teddy: lit.Teddy,
    ac: lit.AhoCorasick,
    bloom: lit.Sbbf,
};

const Built = struct {
    /// The serialised structure, null for the naive baseline.
    bytes: ?[]align(64) u8,
    view: View,

    fn deinit(self: *Built, gpa: std.mem.Allocator) void {
        if (self.bytes) |b| gpa.free(b);
        self.* = undefined;
    }
};

const NotApplicable = error{NotApplicable};

/// An upper bound on the dense automaton: one row of a power-of-two stride
/// of `u32` per trie node, and at most one node per pattern byte.
fn denseEstimate(set: *const gen.LiteralSet) u64 {
    var seen: [256]bool = @splat(false);
    for (set.store) |b| seen[b] = true;
    var classes: u64 = 1;
    for (seen) |s| classes += @intFromBool(s);
    const stride = std.math.ceilPowerOfTwoAssert(u64, classes);
    return (set.store.len + 1) * stride * 4;
}

fn build(gpa: std.mem.Allocator, m: Matcher, set: *const gen.LiteralSet, pats: []const lit.Pattern) !Built {
    switch (m) {
        .naive => {
            if (pats.len > lit.teddy.max_patterns) return error.NotApplicable;
            return .{ .bytes = null, .view = .{ .naive = pats } };
        },
        .teddy => {
            if (pats.len > lit.teddy.max_patterns) return error.NotApplicable;
            const o = try lit.Teddy.build(gpa, pats, .{});
            return .{ .bytes = o.bytes, .view = .{ .teddy = o.view } };
        },
        .ac_dense, .ac_sparse => {
            if (m == .ac_dense and denseEstimate(set) > dense_cap) return error.NotApplicable;
            const o = try lit.AhoCorasick.build(gpa, pats, .{ .layout = if (m == .ac_dense) .dense else .sparse });
            return .{ .bytes = o.bytes, .view = .{ .ac = o.view } };
        },
        .bloom_s1, .bloom_s4, .bloom_s8 => {
            const o = try lit.Sbbf.build(gpa, set.items, .{ .stride = m.stride(), .bits_per_key = bits_per_key });
            return .{ .bytes = o.bytes, .view = .{ .bloom = o.view } };
        },
    }
}

fn load(m: Matcher, bytes: []const u8) !View {
    return switch (m) {
        .naive => unreachable,
        .teddy => .{ .teddy = try lit.Teddy.load(bytes) },
        .ac_dense, .ac_sparse => .{ .ac = try lit.AhoCorasick.load(bytes) },
        .bloom_s1, .bloom_s4, .bloom_s8 => .{ .bloom = try lit.Sbbf.load(bytes) },
    };
}

fn countMatch(n: *usize, _: lit.Match) bool {
    n.* += 1;
    return true;
}

/// Every match (every candidate position, for the Bloom prefilter).
fn scanCount(view: *const View, hay: []const u8) usize {
    var n: usize = 0;
    switch (view.*) {
        .naive => |pats| for (pats) |p| {
            var from: usize = 0;
            while (std.mem.indexOfPos(u8, hay, from, p.bytes)) |at| : (n += 1) from = at + 1;
        },
        .teddy => |*t| _ = t.scan(hay, &n, countMatch),
        .ac => |*a| _ = a.scanAll(hay, &n, countMatch),
        .bloom => |*f| {
            var buf: [1024]usize = undefined;
            var p = f.prober(hay, 0);
            while (true) {
                const got = p.next(&buf);
                if (got.len == 0) break;
                n += got.len;
            }
        },
    }
    return n;
}

fn nowNs(io: Io) u64 {
    return @intCast(Io.Timestamp.now(io, .awake).nanoseconds);
}

const Timing = struct { best_ns: u64, result: usize };

/// Minimum timing window for a literal matcher and for a regex pattern. The
/// regex window is longer: compare.sh times PCRE2 with the same one, and a
/// longer window is likelier to contain an undisturbed pass.
const literal_window_ms = 300;
const regex_window_ms = 1000;

/// Run `f` at least three times and for at least `window_ms`; keep the best
/// pass.
fn measure(io: Io, window_ms: u64, ctx: anytype, comptime f: fn (@TypeOf(ctx)) usize) Timing {
    var best: u64 = std.math.maxInt(u64);
    var result: usize = 0;
    const start = nowNs(io);
    var passes: usize = 0;
    while (passes < 3 or nowNs(io) - start < window_ms * std.time.ns_per_ms) : (passes += 1) {
        const t0 = nowNs(io);
        result = f(ctx);
        best = @min(best, nowNs(io) - t0);
        std.mem.doNotOptimizeAway(result);
    }
    return .{ .best_ns = @max(best, 1), .result = result };
}

fn gbps(bytes: usize, ns: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(ns));
}

/// Bytes as B, KiB, MiB or GiB with three significant digits.
fn fmtBytes(buf: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB" };
    var v: f64 = @floatFromInt(bytes);
    var u: usize = 0;
    while (v >= 1024 and u + 1 < units.len) : (u += 1) v /= 1024;
    return if (u == 0)
        std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch unreachable
    else if (v >= 100)
        std.fmt.bufPrint(buf, "{d:.0} {s}", .{ v, units[u] }) catch unreachable
    else if (v >= 10)
        std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[u] }) catch unreachable
    else
        std.fmt.bufPrint(buf, "{d:.2} {s}", .{ v, units[u] }) catch unreachable;
}

fn fmtNs(buf: []u8, ns: u64) []const u8 {
    const v: f64 = @floatFromInt(ns);
    return if (ns < 1000 * std.time.ns_per_us)
        std.fmt.bufPrint(buf, "{d:.0} us", .{v / 1e3}) catch unreachable
    else if (ns < 1000 * std.time.ns_per_ms)
        std.fmt.bufPrint(buf, "{d:.1} ms", .{v / 1e6}) catch unreachable
    else
        std.fmt.bufPrint(buf, "{d:.2} s", .{v / 1e9}) catch unreachable;
}

fn fmtCount(buf: []u8, n: usize) []const u8 {
    return if (n >= 10_000_000)
        std.fmt.bufPrint(buf, "{d:.1}M", .{@as(f64, @floatFromInt(n)) / 1e6}) catch unreachable
    else
        std.fmt.bufPrint(buf, "{d}", .{n}) catch unreachable;
}

fn fmtSize(buf: []u8, n: usize) []const u8 {
    return if (n >= 1000 and n % 1000 == 0)
        std.fmt.bufPrint(buf, "{d}k", .{n / 1000}) catch unreachable
    else
        std.fmt.bufPrint(buf, "{d}", .{n}) catch unreachable;
}

// ------------------------------------------------------------ inputs

const Inputs = struct {
    set: gen.LiteralSet,
    pats: []lit.Pattern,
    hay: []u8,

    fn init(gpa: std.mem.Allocator, family: gen.Family, n: usize) !Inputs {
        var set = try gen.literalSet(gpa, family, n);
        errdefer set.deinit(gpa);
        const pats = try gpa.alloc(lit.Pattern, n);
        errdefer gpa.free(pats);
        for (set.items, pats, 0..) |s, *p, i| p.* = .{ .bytes = s, .id = @intCast(i) };
        const hay = switch (family) {
            .text => try gen.textCorpus(gpa, corpus_len, 0x7e47, set.items),
            .binary => try gen.binaryCorpus(gpa, corpus_len, 0xb1a, set.items),
        };
        return .{ .set = set, .pats = pats, .hay = hay };
    }

    fn deinit(self: *Inputs, gpa: std.mem.Allocator) void {
        gpa.free(self.hay);
        gpa.free(self.pats);
        self.set.deinit(gpa);
        self.* = undefined;
    }
};

// ------------------------------------------------------------ memory

/// What a memory child does before it holds still for the sampler.
const Phase = enum {
    /// Generate the literal set and the corpus.
    inputs,
    /// `inputs`, then build the structure and scan the corpus once.
    build,
    /// `inputs`, then free everything but the corpus.
    corpus,
    /// `corpus`, then mmap the serialised structure and scan with it
    /// repeatedly while the sampler runs.
    load,
};

fn childMain(gpa: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    if (args.len != 4) return error.BadArguments;
    const phase = std.meta.stringToEnum(Phase, args[0]) orelse return error.BadArguments;
    const family = std.meta.stringToEnum(gen.Family, args[1]) orelse return error.BadArguments;
    const n = try std.fmt.parseInt(usize, args[2], 10);
    const m = std.meta.stringToEnum(Matcher, args[3]) orelse return error.BadArguments;

    var inputs = try Inputs.init(gpa, family, n);
    defer gpa.free(inputs.hay);
    var keep_set = true;
    defer if (keep_set) {
        gpa.free(inputs.pats);
        inputs.set.deinit(gpa);
    };

    switch (phase) {
        .inputs => {},
        .build => {
            var b = try build(gpa, m, &inputs.set, inputs.pats);
            defer b.deinit(gpa);
            std.mem.doNotOptimizeAway(scanCount(&b.view, inputs.hay));
            try io.sleep(.fromMilliseconds(hold_ms), .awake);
            return;
        },
        .corpus, .load => {
            gpa.free(inputs.pats);
            inputs.set.deinit(gpa);
            keep_set = false;
        },
    }
    if (phase != .load) {
        std.mem.doNotOptimizeAway(inputs.hay.ptr);
        try io.sleep(.fromMilliseconds(hold_ms), .awake);
        return;
    }

    const file = try Io.Dir.cwd().openFile(io, blob_path, .{});
    defer file.close(io);
    const len: usize = @intCast(try file.length(io));
    const mapped = try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
    defer std.posix.munmap(mapped);
    const view = try load(m, mapped);
    const start = nowNs(io);
    while (true) {
        std.mem.doNotOptimizeAway(scanCount(&view, inputs.hay));
        if (nowNs(io) - start >= hold_ms * std.time.ns_per_ms) break;
    }
}

const Usage = struct {
    /// The kernel's high-water mark over the child's whole life.
    max_rss: u64,
    /// The highest samples in the hold window: resident and private dirty
    /// memory once the inputs are in place, without generation transients.
    rss_steady: u64,
    dirty_steady: u64,
};

fn sampleChild(gpa: std.mem.Allocator, io: Io, self_exe: []const u8, phase: Phase, family: gen.Family, n: usize, m: Matcher) !Usage {
    var nbuf: [24]u8 = undefined;
    const argv = [_][]const u8{
        self_exe,                                               "child",     @tagName(phase), @tagName(family),
        std.fmt.bufPrint(&nbuf, "{d}", .{n}) catch unreachable, @tagName(m),
    };
    var result = try process.run(gpa, io, .{ .argv = &argv, .sample_hz = sample_hz });
    defer result.deinit();
    if (!result.term.success()) return error.ChildFailed;
    const window_start = result.wall_ns -| hold_ms * std.time.ns_per_ms * 3 / 4;
    var usage: Usage = .{ .max_rss = result.max_rss orelse 0, .rss_steady = 0, .dirty_steady = 0 };
    var in_window: usize = 0;
    for (result.samples) |sample| {
        if (sample.t_ns < window_start) continue;
        in_window += 1;
        usage.rss_steady = @max(usage.rss_steady, sample.values.rss orelse 0);
        usage.dirty_steady = @max(usage.dirty_steady, sample.values.private_dirty orelse 0);
    }
    if (in_window == 0) return error.NoSamplesInHoldWindow;
    return usage;
}

fn writeBlob(io: Io, bytes: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, blob_dir);
    const file = try Io.Dir.cwd().createFile(io, blob_path, .{});
    defer file.close(io);
    try file.writePositionalAll(io, bytes, 0);
    // Pages still dirty in the page cache would count as dirty in the
    // child; write them back first.
    try file.sync(io);
}

// ------------------------------------------------------------ literals

const ScanCase = struct {
    view: *const View,
    hay: []const u8,
    fn run(c: *const ScanCase) usize {
        return scanCount(c.view, c.hay);
    }
};

fn literalsSection(gpa: std.mem.Allocator, io: Io, w: *Io.Writer, self_exe: []const u8) !void {
    try w.print(
        \\## Multi-literal matchers
        \\
        \\Corpora are {d} MiB. Literals are {d} to {d} bytes; one from the set is planted
        \\about every {d} bytes. Hits are matches, overlapping ones included (candidate
        \\positions for the Bloom prefilter, which a verifier then checks). Build peak is
        \\peak RSS over a child holding only the inputs. Mapped RSS and dirty are a child
        \\scanning with the serialised structure mmapped read-only, over a child holding
        \\only the corpus. GB/s is 10^9 bytes per second, best of at least three passes
        \\and 0.3 s.
        \\
        \\
    , .{ corpus_len >> 20, gen.min_literal, gen.max_literal, gen.plant_every });

    for ([_]gen.Family{ .text, .binary }) |family| {
        try w.print(
            \\### {s}
            \\
            \\| Literals | Matcher | Build | Blob | Build peak | GB/s | Hits | Mapped RSS | Mapped dirty |
            \\|---:|---|---:|---:|---:|---:|---:|---:|---:|
            \\
        , .{switch (family) {
            .text => "Text corpus (lowercase literals, English-like text)",
            .binary => "Binary corpus (any-byte literals, executable-like data)",
        }});
        try w.flush();
        for (set_sizes) |n| {
            var inputs = try Inputs.init(gpa, family, n);
            defer inputs.deinit(gpa);
            const base_inputs = try sampleChild(gpa, io, self_exe, .inputs, family, n, .teddy);
            const base_corpus = try sampleChild(gpa, io, self_exe, .corpus, family, n, .teddy);
            var exact_hits: ?usize = null;
            for (std.enums.values(Matcher)) |m| {
                var b1: [32]u8 = undefined;
                var b2: [32]u8 = undefined;
                var b3: [32]u8 = undefined;
                var b4: [32]u8 = undefined;
                var b5: [32]u8 = undefined;
                var b6: [32]u8 = undefined;
                var b7: [32]u8 = undefined;
                const size = fmtSize(&b7, n);
                std.debug.print("  {s} {s} {s}\n", .{ @tagName(family), size, m.label() });
                const t0 = nowNs(io);
                var built = build(gpa, m, &inputs.set, inputs.pats) catch |err| switch (err) {
                    error.NotApplicable => {
                        const why: []const u8 = switch (m) {
                            .naive, .teddy => "at most 64 literals",
                            else => "dense DFA over the size cap",
                        };
                        try w.print("| {s} | {s} | n/a ({s}) | | | | | | |\n", .{ size, m.label(), why });
                        continue;
                    },
                    else => return err,
                };
                defer built.deinit(gpa);
                const build_ns = nowNs(io) - t0;
                const case: ScanCase = .{ .view = &built.view, .hay = inputs.hay };
                const t = measure(io, literal_window_ms, &case, ScanCase.run);
                if (!m.isBloom()) {
                    if (exact_hits) |h| {
                        if (h != t.result) std.debug.print("    MISMATCH: {d} hits, expected {d}\n", .{ t.result, h });
                    } else exact_hits = t.result;
                }
                if (built.bytes) |bytes| {
                    try writeBlob(io, bytes);
                    const at_build = try sampleChild(gpa, io, self_exe, .build, family, n, m);
                    const at_load = try sampleChild(gpa, io, self_exe, .load, family, n, m);
                    try w.print("| {s} | {s} | {s} | {s} | {s} | {d:.2} | {s} | {s} | {s} |\n", .{
                        size,
                        m.label(),
                        fmtNs(&b1, build_ns),
                        fmtBytes(&b2, bytes.len),
                        fmtBytes(&b3, at_build.max_rss -| base_inputs.max_rss),
                        gbps(inputs.hay.len, t.best_ns),
                        fmtCount(&b4, t.result),
                        fmtBytes(&b5, at_load.rss_steady -| base_corpus.rss_steady),
                        fmtBytes(&b6, at_load.dirty_steady -| base_corpus.dirty_steady),
                    });
                } else {
                    try w.print("| {s} | {s} | - | - | - | {d:.2} | {s} | - | - |\n", .{
                        size, m.label(), gbps(inputs.hay.len, t.best_ns), fmtCount(&b4, t.result),
                    });
                }
                try w.flush();
            }
        }
        try w.writeAll("\n");
    }
}

// ------------------------------------------------------------ regex

fn regexFlags(line: gen.PatternLine) regex.common.CompileFlags {
    return .{ .bytes = true, .case_insensitive = line.case_insensitive, .dot_all = line.dot_all };
}

const CountCase = struct {
    program: *const regex.Program,
    scratch: *regex.Scratch,
    hay: []const u8,
    fn run(c: *const CountCase) usize {
        return c.program.count(c.scratch, c.hay) catch |err| std.debug.panic("count failed: {t}", .{err});
    }
};

const RegexRow = struct {
    name: []const u8,
    program_bytes: usize = 0,
    scratch_bytes: usize = 0,
    timing: ?Timing = null,
    err: ?anyerror = null,
};

fn runPattern(gpa: std.mem.Allocator, io: Io, line: gen.PatternLine, hay: []const u8) !RegexRow {
    var row: RegexRow = .{ .name = line.name };
    var program = regex.Program.compile(gpa, line.pattern, regexFlags(line)) catch |err| {
        row.err = err;
        return row;
    };
    defer program.deinit(gpa);
    var scratch = try regex.Scratch.init(gpa, &program);
    defer scratch.deinit(gpa);
    row.program_bytes = program.bytes().len;
    row.scratch_bytes = scratch.memory.len;
    const case: CountCase = .{ .program = &program, .scratch = &scratch, .hay = hay };
    row.timing = measure(io, regex_window_ms, &case, CountCase.run);
    return row;
}

fn regexTable(gpa: std.mem.Allocator, io: Io, w: *Io.Writer, title: []const u8, text: []const u8, kind: gen.RegexCorpus) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const lines = try gen.parsePatternFile(arena_state.allocator(), text);
    const hay = try gen.regexCorpus(gpa, kind, lines);
    defer gpa.free(hay);
    try w.print(
        \\### {s}
        \\
        \\| Pattern | Program | Scratch | MB/s | Matches |
        \\|---|---:|---:|---:|---:|
        \\
    , .{title});
    var total_ns: u64 = 0;
    for (lines) |line| {
        std.debug.print("  regex {s}\n", .{line.name});
        const row = try runPattern(gpa, io, line, hay);
        if (row.err) |err| {
            try w.print("| `{s}` | {t} | | | |\n", .{ row.name, err });
            continue;
        }
        const t = row.timing.?;
        total_ns += t.best_ns;
        var b1: [32]u8 = undefined;
        var b2: [32]u8 = undefined;
        try w.print("| `{s}` | {s} | {s} | {d:.0} | {d} |\n", .{
            row.name, fmtBytes(&b1, row.program_bytes), fmtBytes(&b2, row.scratch_bytes), gbps(hay.len, t.best_ns) * 1000, t.result,
        });
        try w.flush();
    }
    var b: [32]u8 = undefined;
    try w.print("| all {d} in sequence | | | {d:.0} | {s} total |\n\n", .{ lines.len, gbps(hay.len, total_ns) * 1000, fmtNs(&b, total_ns) });
}

fn regexSection(gpa: std.mem.Allocator, io: Io, w: *Io.Writer) !void {
    try w.print(
        \\## Byte-mode regex programs
        \\
        \\Each pattern is compiled with `CompileFlags.bytes` into a `Program` and counts
        \\its non-overlapping matches over a {d} MiB corpus with one `Scratch` (default
        \\DFA cap). Each pattern's sample match is planted about every {d} bytes, cycling
        \\through the file. Program and Scratch are the serialised program and the
        \\scratch's whole allocation. MB/s is 10^6 bytes per second, best of at least
        \\three passes and 1 s. benchmarks/pcre2/compare.sh runs the same patterns and corpora
        \\through PCRE2.
        \\
        \\
    , .{ gen.regex_corpus_len >> 20, gen.plant_every });
    try regexTable(gpa, io, w, "ClamAV-style signatures (patterns/clamav.txt, executable-like corpus)", clamav_patterns, .binary);
    try regexTable(gpa, io, w, "CRS-style request rules (patterns/crs.txt, HTTP request corpus)", crs_patterns, .http);
}

/// `gen <patterns.txt> <binary|http> <out>`: write the corpus the regex
/// section uses, for the PCRE2 comparison.
fn genMain(gpa: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    if (args.len != 3) return error.BadArguments;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = try Io.Dir.cwd().readFileAlloc(io, args[0], arena, .unlimited);
    const kind = std.meta.stringToEnum(gen.RegexCorpus, args[1]) orelse return error.BadArguments;
    const lines = try gen.parsePatternFile(arena, text);
    const hay = try gen.regexCorpus(gpa, kind, lines);
    defer gpa.free(hay);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = hay });
}

/// `regex-file <patterns.txt> <corpus>`: one TSV row per pattern:
/// name, matches, best pass in ns, corpus bytes, program bytes.
fn regexFileMain(gpa: std.mem.Allocator, io: Io, w: *Io.Writer, args: []const []const u8) !void {
    if (args.len != 2) return error.BadArguments;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = try Io.Dir.cwd().readFileAlloc(io, args[0], arena, .unlimited);
    const hay = try Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .unlimited);
    defer gpa.free(hay);
    for (try gen.parsePatternFile(arena, text)) |line| {
        const row = try runPattern(gpa, io, line, hay);
        if (row.err) |err| {
            try w.print("{s}\terror:{t}\t0\t{d}\t0\n", .{ row.name, err, hay.len });
        } else {
            try w.print("{s}\t{d}\t{d}\t{d}\t{d}\n", .{ row.name, row.timing.?.result, row.timing.?.best_ns, hay.len, row.program_bytes });
        }
        try w.flush();
    }
}

pub fn main(init: std.process.Init) !void {
    // The release allocator: `init.gpa` is a debug allocator in debug builds
    // and would distort build times and memory.
    const gpa = std.heap.smp_allocator;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var out_buf: [8192]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const w = &out.interface;
    defer w.flush() catch {};

    const cmd: []const u8 = if (args.len >= 2) args[1] else "all";
    if (std.mem.eql(u8, cmd, "child")) return childMain(gpa, io, args[2..]);
    if (std.mem.eql(u8, cmd, "gen")) return genMain(gpa, io, args[2..]);
    if (std.mem.eql(u8, cmd, "regex-file")) return regexFileMain(gpa, io, w, args[2..]);

    const all = std.mem.eql(u8, cmd, "all");
    if (!all and !std.mem.eql(u8, cmd, "literals") and !std.mem.eql(u8, cmd, "regex")) {
        std.debug.print("usage: bench_suite [all|literals|regex]\n", .{});
        return error.BadArguments;
    }
    if ((all or std.mem.eql(u8, cmd, "literals")) and !process.supported) return error.UnsupportedPlatform;

    const self_exe = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(self_exe);
    try w.print("Measured on {s} ({s}), Zig {s}, ReleaseFast.\n\n", .{
        @tagName(builtin.cpu.arch), builtin.cpu.model.name, builtin.zig_version_string,
    });
    if (all or std.mem.eql(u8, cmd, "literals")) try literalsSection(gpa, io, w, self_exe);
    if (all or std.mem.eql(u8, cmd, "regex")) try regexSection(gpa, io, w);
}

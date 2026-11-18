//! Differential tests for the multi-literal engines against the naive
//! reference matchers in src/literals/naive.zig.

const std = @import("std");
const lit = @import("regex").literals;

const testing = std.testing;
const Pattern = lit.Pattern;
const Match = lit.Match;
const Options = lit.Options;
const naive = lit.naive;

fn collect(list: *std.ArrayList(Match), m: Match) bool {
    list.append(testing.allocator, m) catch return false;
    return true;
}

/// A random byte from a small alphabet that still exercises case folding and
/// the 0x00 and 0xff extremes, or any byte when `alpha` is large.
fn randByte(r: std.Random, alpha: u8) u8 {
    const pool = "aAbB\x00\xff\x7f\x80";
    if (alpha < pool.len) return pool[r.uintLessThan(u8, alpha)];
    return r.int(u8);
}

const PatternSet = struct {
    store: [][]u8,
    pats: []Pattern,

    fn random(gpa: std.mem.Allocator, r: std.Random, n: usize, min_len: usize, max_len: usize, alpha: u8) !PatternSet {
        const store = try gpa.alloc([]u8, n);
        const pats = try gpa.alloc(Pattern, n);
        for (0..n) |i| {
            store[i] = try gpa.alloc(u8, r.intRangeAtMost(usize, min_len, max_len));
            for (store[i]) |*b| b.* = randByte(r, alpha);
            pats[i] = .{ .bytes = store[i], .id = @intCast(i) };
        }
        return .{ .store = store, .pats = pats };
    }

    fn deinit(self: PatternSet, gpa: std.mem.Allocator) void {
        for (self.store) |s| gpa.free(s);
        gpa.free(self.store);
        gpa.free(self.pats);
    }
};

/// A haystack of random bytes with patterns planted at random positions.
fn plantedHaystack(gpa: std.mem.Allocator, r: std.Random, len: usize, pats: []const Pattern, alpha: u8) ![]u8 {
    const hay = try gpa.alloc(u8, len);
    for (hay) |*b| b.* = randByte(r, alpha);
    if (len == 0) return hay;
    const plants = r.uintAtMost(usize, len / 16 + 1);
    for (0..plants) |_| {
        const p = pats[r.uintLessThan(usize, pats.len)].bytes;
        if (p.len > len) continue;
        const at = r.uintAtMost(usize, len - p.len);
        @memcpy(hay[at..][0..p.len], p);
        if (r.boolean()) {
            for (hay[at..][0..p.len]) |*b| {
                if (std.ascii.isAlphabetic(b.*)) b.* ^= 0x20;
            }
        }
    }
    return hay;
}

test "teddy agrees with naive search on random inputs" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x7edd7);
    const r = prng.random();
    for (0..1500) |round| {
        const alpha: u8 = switch (round % 4) {
            0 => 2,
            1 => 4,
            2 => 8,
            else => 255,
        };
        const n = r.intRangeAtMost(usize, 1, lit.teddy.max_patterns);
        const set = try PatternSet.random(gpa, r, n, 1 + round % 4, 1 + round % 4 + r.uintAtMost(usize, 12), alpha);
        defer set.deinit(gpa);
        const opts: Options = .{ .ascii_case_insensitive = r.boolean() };
        var t = try lit.Teddy.build(gpa, set.pats, opts);
        defer t.deinit(gpa);

        const hay = try plantedHaystack(gpa, r, r.uintAtMost(usize, 2000), set.pats, alpha);
        defer gpa.free(hay);

        const want = try naive.allMatches(gpa, set.pats, hay, opts);
        defer gpa.free(want);
        var got: std.ArrayList(Match) = .empty;
        defer got.deinit(gpa);
        try testing.expect(t.view.scan(hay, &got, collect));
        std.mem.sort(Match, got.items, {}, naive.lessThan);
        try testing.expectEqualSlices(Match, want, got.items);

        var from: usize = 0;
        while (from <= hay.len) {
            const m = t.view.find(hay, from);
            try testing.expectEqual(naive.leftmostFirst(set.pats, hay, from, opts), m);
            from = if (m) |x| x.start + 1 else hay.len + 1;
        }
    }
}

test "teddy finds a pattern planted at every offset" {
    const gpa = testing.allocator;
    const pats = [_]Pattern{
        .{ .bytes = "\xff\x00\xff", .id = 1 },
        .{ .bytes = "Zq", .id = 2 },
        .{ .bytes = "\x00", .id = 3 },
    };
    for (pats) |p| {
        var t = try lit.Teddy.build(gpa, &.{p}, .{});
        defer t.deinit(gpa);
        for (0..130) |len| {
            const hay = try gpa.alloc(u8, len);
            defer gpa.free(hay);
            if (len < p.bytes.len) continue;
            for (0..len - p.bytes.len + 1) |at| {
                @memset(hay, 'x');
                @memcpy(hay[at..][0..p.bytes.len], p.bytes);
                const m = t.view.find(hay, 0) orelse return error.Missed;
                try testing.expectEqual(at, m.start);
                try testing.expectEqual(p.id, m.pattern);
            }
        }
    }
}

fn checkAhoCorasick(gpa: std.mem.Allocator, ac: *const lit.AhoCorasick, pats: []const Pattern, hay: []const u8, r: std.Random) !void {
    const opts: Options = .{ .ascii_case_insensitive = ac.nocase };
    const want = try naive.allMatches(gpa, pats, hay, opts);
    defer gpa.free(want);

    // Whole haystack.
    var got: std.ArrayList(Match) = .empty;
    defer got.deinit(gpa);
    try testing.expect(ac.scanAll(hay, &got, collect));
    std.mem.sort(Match, got.items, {}, naive.lessThan);
    try testing.expectEqualSlices(Match, want, got.items);
    try testing.expectEqual(want.len != 0, ac.isMatch(hay));

    // The same haystack fed as a stream of random chunks.
    got.clearRetainingCapacity();
    var stream: lit.aho_corasick.Stream = .{};
    var pos: usize = 0;
    while (pos < hay.len) {
        const len = @min(hay.len - pos, r.uintAtMost(usize, 40));
        try testing.expect(ac.scanStream(&stream, hay[pos..][0..len], &got, collect));
        pos += len;
    }
    std.mem.sort(Match, got.items, {}, naive.lessThan);
    try testing.expectEqualSlices(Match, want, got.items);

    // Non-overlapping leftmost-longest.
    const want_ll = try naive.leftmostLongest(gpa, pats, hay, opts);
    defer gpa.free(want_ll);
    got.clearRetainingCapacity();
    var it = ac.iterator(hay);
    while (it.next()) |m| try got.append(gpa, m);
    try testing.expectEqualSlices(Match, want_ll, got.items);
}

test "aho-corasick agrees with naive search on random inputs in every layout, reloaded too" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xac0ac0);
    const r = prng.random();
    for (0..600) |round| {
        const alpha: u8 = switch (round % 4) {
            0 => 2,
            1 => 4,
            2 => 8,
            else => 255,
        };
        const n = r.intRangeAtMost(usize, 1, if (round % 10 == 0) 300 else 40);
        const set = try PatternSet.random(gpa, r, n, 1, 1 + r.uintAtMost(usize, 10), alpha);
        defer set.deinit(gpa);
        const hay = try plantedHaystack(gpa, r, r.uintAtMost(usize, 1500), set.pats, alpha);
        defer gpa.free(hay);
        const nocase = r.boolean();
        const configs = [_]lit.aho_corasick.Options{
            .{ .ascii_case_insensitive = nocase, .layout = .dense },
            .{ .ascii_case_insensitive = nocase, .layout = .sparse },
            // Root row only, so failure walks run all the way down.
            .{ .ascii_case_insensitive = nocase, .layout = .sparse, .shallow_depth = 0 },
            // A row budget that cuts the shallow states off part way.
            .{ .ascii_case_insensitive = nocase, .layout = .sparse, .shallow_depth = 3, .shallow_max_bytes = 4096 },
        };
        for (configs) |config| {
            var ac = try lit.AhoCorasick.build(gpa, set.pats, config);
            defer ac.deinit(gpa);
            try checkAhoCorasick(gpa, &ac.view, set.pats, hay, r);

            // A copy at a different address, loaded with full validation.
            const copy = try lit.blob.dupeAligned(gpa, ac.bytes);
            defer gpa.free(copy);
            const loaded = try lit.AhoCorasick.load(copy);
            try checkAhoCorasick(gpa, &loaded, set.pats, hay, r);
        }
    }
}

test "aho-corasick agrees with teddy on small sets" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x7eac);
    const r = prng.random();
    for (0..200) |_| {
        const set = try PatternSet.random(gpa, r, r.intRangeAtMost(usize, 1, 64), 1, 6, 4);
        defer set.deinit(gpa);
        const hay = try plantedHaystack(gpa, r, 1000, set.pats, 4);
        defer gpa.free(hay);
        var t = try lit.Teddy.build(gpa, set.pats, .{});
        defer t.deinit(gpa);
        var ac = try lit.AhoCorasick.build(gpa, set.pats, .{});
        defer ac.deinit(gpa);
        var a: std.ArrayList(Match) = .empty;
        defer a.deinit(gpa);
        var b: std.ArrayList(Match) = .empty;
        defer b.deinit(gpa);
        _ = t.view.scan(hay, &a, collect);
        _ = ac.view.scanAll(hay, &b, collect);
        std.mem.sort(Match, a.items, {}, naive.lessThan);
        std.mem.sort(Match, b.items, {}, naive.lessThan);
        try testing.expectEqualSlices(Match, a.items, b.items);
    }
}

test "aho-corasick exhaustive over a two-byte alphabet" {
    // Every set of patterns of length 1 and 2 over {0x00, 0xff}, against
    // every haystack of length up to 10 over the same bytes.
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(1);
    const strings = [_][]const u8{ "\x00", "\xff", "\x00\x00", "\x00\xff", "\xff\x00", "\xff\xff" };
    var pats: [strings.len]Pattern = undefined;
    var hay: [10]u8 = undefined;
    for (1..(1 << strings.len)) |set| {
        var n: usize = 0;
        for (strings, 0..) |s, i| {
            if (set & (@as(usize, 1) << @intCast(i)) != 0) {
                pats[n] = .{ .bytes = s, .id = @intCast(i) };
                n += 1;
            }
        }
        for ([_]lit.aho_corasick.Layout{ .dense, .sparse }) |layout| {
            var ac = try lit.AhoCorasick.build(gpa, pats[0..n], .{ .layout = layout });
            defer ac.deinit(gpa);
            for (0..hay.len + 1) |len| {
                for (0..(@as(usize, 1) << @intCast(len))) |bits| {
                    for (0..len) |k| hay[k] = if (bits & (@as(usize, 1) << @intCast(k)) != 0) 0xff else 0x00;
                    try checkAhoCorasick(gpa, &ac.view, pats[0..n], hay[0..len], prng.random());
                }
            }
        }
    }
}

/// Every candidate the prober reports for `hay` from `start`, in order.
fn allCandidates(gpa: std.mem.Allocator, f: *const lit.Sbbf, hay: []const u8, start: usize, buf_len: usize) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(gpa);
    const buf = try gpa.alloc(usize, buf_len);
    defer gpa.free(buf);
    var p = f.prober(hay, start);
    while (true) {
        const c = p.next(buf);
        if (c.len == 0) break;
        try out.appendSlice(gpa, c);
    }
    return out.toOwnedSlice(gpa);
}

test "sbbf never misses a planted anchor at strides 1 to 16" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5bbf);
    const r = prng.random();
    const strides = [_]u32{ 1, 4, 8, 1, 2, 3, 5, 7, 16 };
    for (0..120) |round| {
        const stride = strides[round % strides.len];
        const n = r.intRangeAtMost(usize, 1, 200);
        const set = try PatternSet.random(gpa, r, n, stride + 3, stride + 3 + r.uintAtMost(usize, 20), if (round % 2 == 0) 4 else 255);
        defer set.deinit(gpa);
        const anchors = try gpa.alloc([]const u8, n);
        defer gpa.free(anchors);
        for (set.pats, anchors) |p, *a| a.* = p.bytes;
        var f = try lit.Sbbf.build(gpa, anchors, .{ .stride = stride, .bits_per_key = r.intRangeAtMost(u32, 2, 20), .seed = r.int(u32) });
        defer f.deinit(gpa);

        const hay = try gpa.alloc(u8, r.uintAtMost(usize, 3000));
        defer gpa.free(hay);
        for (hay) |*b| b.* = r.int(u8);
        const start = r.uintAtMost(usize, 3);
        var planted: std.ArrayList(struct { at: usize, len: usize }) = .empty;
        defer planted.deinit(gpa);
        for (0..r.uintAtMost(usize, 40)) |_| {
            const a = anchors[r.uintLessThan(usize, n)];
            if (a.len + start > hay.len) continue;
            const at = r.intRangeAtMost(usize, start, hay.len - a.len);
            @memcpy(hay[at..][0..a.len], a);
            try planted.append(gpa, .{ .at = at, .len = a.len });
        }
        const cands = try allCandidates(gpa, &f.view, hay, start, lit.sbbf.batch + r.uintAtMost(usize, 20));
        defer gpa.free(cands);

        // Candidates are sampled positions, strictly ascending.
        for (cands, 0..) |c, i| {
            try testing.expectEqual(@as(usize, 0), (c - start) % stride);
            try testing.expect(c + 4 <= hay.len);
            if (i > 0) try testing.expect(cands[i - 1] < c);
        }
        // Every planted anchor that survived later plants has a candidate
        // inside its first `stride` bytes.
        for (planted.items) |p| {
            var intact = false;
            for (anchors) |a| {
                if (a.len == p.len and std.mem.eql(u8, a, hay[p.at..][0..p.len])) intact = true;
            }
            if (!intact) continue;
            var found = false;
            for (cands) |c| {
                if (c >= p.at and c < p.at + stride) found = true;
            }
            try testing.expect(found);
        }
    }
}

test "sbbf false-positive rate is within 20 percent of theory" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xf9);
    const r = prng.random();
    const Case = struct { keys: usize, bits_per_key: u32 };
    for ([_]Case{
        .{ .keys = 100_000, .bits_per_key = 16 },
        .{ .keys = 50_000, .bits_per_key = 10 },
        .{ .keys = 20_000, .bits_per_key = 8 },
    }) |case| {
        var b = try lit.sbbf.Builder.init(gpa, .{ .bits_per_key = case.bits_per_key, .seed = r.int(u32) });
        defer b.deinit();
        var inserted: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer inserted.deinit(gpa);
        while (inserted.count() < case.keys) {
            const g = r.int(u32);
            try inserted.put(gpa, g, {});
            try b.addGram(g);
        }
        var f = try b.finish();
        defer f.deinit(gpa);
        const expected = f.view.expectedFalsePositiveRate();

        var queries: usize = 0;
        var hits: usize = 0;
        // Enough queries for about 4000 expected false positives, so the
        // sampling error (about 1.6 percent) is far inside the tolerance.
        const want_queries: usize = @intFromFloat(4000 / expected);
        while (queries < want_queries) {
            const g = r.int(u32);
            if (inserted.contains(g)) continue;
            queries += 1;
            hits += @intFromBool(f.view.contains(g));
        }
        const measured = @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(queries));
        try testing.expect(@abs(measured - expected) <= 0.2 * expected);
    }
}

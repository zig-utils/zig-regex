//! Bounded-backtracking programs (`regex.bt`): PCRE2 agreement, loading,
//! limits and allocation-free matching.

const std = @import("std");
const regex = @import("regex");
const bt = regex.bt;
const CompileFlags = regex.common.CompileFlags;
const testing = std.testing;

fn flagsFrom(text: []const u8) CompileFlags {
    var flags: CompileFlags = .{ .bytes = true };
    for (text) |f| switch (f) {
        'i' => flags.case_insensitive = true,
        'm' => flags.multiline = true,
        's' => flags.dot_all = true,
        else => {},
    };
    return flags;
}

// Cases from `MODE=bt benchmarks/pcre2/diff.sh` with the spans PCRE2 10.49
// reported, so CI checks agreement without PCRE2: backreferences, lookahead,
// lookbehind, atomic groups and counted repeats among alternations, greedy
// and lazy repeats, classes, anchors and inline modifiers.
test "bt: programs agree with PCRE2 on recorded cases" {
    const data = @embedFile("testdata/pcre2_backtrack.tsv");
    var lines = std.mem.splitScalar(u8, data, '\n');
    var checked: usize = 0;
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const flag_text = fields.next().?;
        var pattern_buf: [256]u8 = undefined;
        var subject_buf: [128]u8 = undefined;
        const pattern = try std.fmt.hexToBytes(&pattern_buf, fields.next().?);
        const subject = try std.fmt.hexToBytes(&subject_buf, fields.next().?);
        const want = fields.rest();
        var program = try bt.Program.compile(testing.allocator, pattern, flagsFrom(flag_text));
        defer program.deinit(testing.allocator);
        // Matching through a loaded copy covers the blob round trip too.
        const loaded = try bt.Program.load(program.bytes());
        var scratch = try bt.Scratch.init(testing.allocator, &loaded);
        defer scratch.deinit(testing.allocator);
        got.clearRetainingCapacity();
        var it = loaded.iterator(&scratch, subject);
        while (try it.next()) |m| {
            if (got.items.len > 0) try got.append(testing.allocator, ' ');
            try got.print(testing.allocator, "{d} {d}", .{ m.start, m.end });
        }
        errdefer std.debug.print("pattern \"{s}\" flags {s} subject {any}\n", .{ pattern, flag_text, subject });
        try testing.expectEqualStrings(want, got.items);
        checked += 1;
    }
    try testing.expectEqual(@as(usize, 1000), checked);
}

test "bt: the constructs Thompson programs refuse" {
    const Case = struct { pattern: []const u8, flags: CompileFlags = .{ .bytes = true }, input: []const u8, want: ?[2]usize };
    const cases = [_]Case{
        // Backreferences, numbered and named, folded under `i`.
        .{ .pattern = "(\\w{3,8}) \\1", .input = "xx foo foo", .want = .{ 3, 10 } },
        .{ .pattern = "(?P<n>[a-z]{4})[^a-z]{1,8}(?P=n)", .input = "abcd--abce abcd==abcd", .want = .{ 11, 21 } },
        .{ .pattern = "(?<q>['\"]).*?\\k<q>", .input = "say 'hi\" there' ok", .want = .{ 4, 15 } },
        .{ .pattern = "(ab)\\1", .flags = .{ .bytes = true, .case_insensitive = true }, .input = "abAB", .want = .{ 0, 4 } },
        // A reference inside its own group sees the previous iteration.
        .{ .pattern = "(a|b\\1)+", .input = "aba", .want = .{ 0, 3 } },
        .{ .pattern = "(a)|\\1", .input = "x", .want = null },
        // Lookaround.
        .{ .pattern = "union(?=\\s+select)", .input = "union all union select", .want = .{ 10, 15 } },
        .{ .pattern = "select(?!\\s+1)\\b", .input = "select 1 select x", .want = .{ 9, 15 } },
        .{ .pattern = "(?<=\\x00\\x00)MZ", .input = "\x01MZ\x00\x00MZ", .want = .{ 5, 7 } },
        .{ .pattern = "(?<!\\.)exe", .input = ".exe exe", .want = .{ 5, 8 } },
        .{ .pattern = "(?<=ab|c{2,3})x", .input = "cx ccx abx", .want = .{ 5, 6 } },
        // Atomic groups.
        .{ .pattern = "(?>a+)a", .input = "aaaa", .want = null },
        .{ .pattern = "(?>[a-z]+)=", .input = "name=1", .want = .{ 0, 5 } },
        // Counted repeats keep a counter, not copies.
        .{ .pattern = "(?:ab){1000,}", .input = "ab", .want = null },
        .{ .pattern = "[\\x20-\\x7e]{50000,}", .input = "short", .want = null },
        // A repeated group stops after an iteration that matched empty.
        .{ .pattern = "(a|)*b", .input = "aab", .want = .{ 0, 3 } },
    };
    for (cases) |c| {
        var program = try bt.Program.compile(testing.allocator, c.pattern, c.flags);
        defer program.deinit(testing.allocator);
        var scratch = try bt.Scratch.init(testing.allocator, &program);
        defer scratch.deinit(testing.allocator);
        const got = try program.find(&scratch, c.input);
        errdefer std.debug.print("{s} on {any}: {any}\n", .{ c.pattern, c.input, got });
        if (c.want) |w| {
            try testing.expectEqual(w[0], got.?.start);
            try testing.expectEqual(w[1], got.?.end);
        } else try testing.expect(got == null);
    }
    // Large repeats stay small.
    var huge = try bt.Program.compile(testing.allocator, "(?P<n>ab)(?:x|\\k<n>){1000,}[\\x20-\\x7e]{50000,}", .{ .bytes = true });
    defer huge.deinit(testing.allocator);
    try testing.expect(huge.bytes().len < 1024);
}

test "bt: what this form refuses" {
    const gpa = testing.allocator;
    try testing.expectError(error.UnsupportedByProgram, bt.Program.compile(gpa, "(a)\\1", .{}));
    try testing.expectError(error.UnsupportedByProgram, bt.Program.compile(gpa, "(?<=a+)b", .{ .bytes = true }));
    try testing.expectError(error.UnsupportedByProgram, bt.Program.compile(gpa, "(?<=\\1)b(a)", .{ .bytes = true }));
}

test "bt: matching never allocates" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    const gpa = failing.allocator();
    var program = try bt.Program.compile(gpa, "(\\w+)\\s+(?=\\w)(?>\\1)(?<!x)", .{ .bytes = true });
    defer program.deinit(gpa);
    var scratch = try bt.Scratch.init(gpa, &program);
    defer scratch.deinit(gpa);
    failing.fail_index = failing.alloc_index;
    try testing.expectEqual(@as(usize, 2), try program.count(&scratch, "hello hello there there x"));
    try testing.expect(!failing.has_induced_failure);
    failing.fail_index = std.math.maxInt(usize);

    var buffer: [4096]u8 align(8) = undefined;
    var capacity = program.capacity();
    capacity.frames = 64;
    var in_buffer = try bt.Scratch.initBuffer(&buffer, capacity);
    try testing.expect((try program.find(&in_buffer, "ab ab")) != null);
}

test "bt: budgets and the stack bound a search" {
    const gpa = testing.allocator;
    // Exponential backtracking: a budget ends it with an error, never a "no match".
    var program = try bt.Program.compile(gpa, "(?:a|a)*(?:a|a)*b", .{ .bytes = true });
    defer program.deinit(gpa);
    var scratch = try bt.Scratch.init(gpa, &program);
    defer scratch.deinit(gpa);
    const input = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    for ([_]u64{ 1, 100, 10_000, 1_000_000 }) |budget| {
        scratch.step_budget = budget;
        try testing.expectError(error.BudgetExceeded, program.find(&scratch, input));
        try testing.expect(scratch.steps <= budget);
    }
    // A long run of group iterations needs a frame each: a small stack ends
    // the search with StackExhausted.
    var groups = try bt.Program.compile(gpa, "(?:ab)*c", .{ .bytes = true });
    defer groups.deinit(gpa);
    var capacity = groups.capacity();
    capacity.frames = 16;
    var small = try bt.Scratch.initCapacity(gpa, capacity);
    defer small.deinit(gpa);
    try testing.expectError(error.StackExhausted, groups.find(&small, "abababababababababababababc"));
    var roomy = try bt.Scratch.init(gpa, &groups);
    defer roomy.deinit(gpa);
    try testing.expect((try groups.find(&roomy, "abababababababababababababc")) != null);
}

test "bt: corrupted blobs fail to load or match without faulting" {
    var prng = std.Random.DefaultPrng.init(0xB7B7);
    const random = prng.random();
    const seeds = [_][]const u8{ "(\\w+) \\1", "(?<=ab)c(?!d)", "(?>a|ab)(?:xy){3,}", "(?i)(a|b\\1)+z" };
    const inputs = [_][]const u8{ "", "ab ab abc abd", "abxyxyxyxy", "ABBAz aba z" };
    var buf: [8192]u8 = undefined;
    var loaded: usize = 0;
    for (seeds) |seed| {
        var program = try bt.Program.compile(testing.allocator, seed, .{ .bytes = true });
        defer program.deinit(testing.allocator);
        const good = program.bytes();
        for (0..3000) |_| {
            var len = good.len;
            @memcpy(buf[0..len], good);
            for (0..random.intRangeAtMost(usize, 1, 4)) |_| {
                if (len == 0) break;
                switch (random.uintLessThan(u8, 3)) {
                    0 => buf[random.uintLessThan(usize, len)] ^= @as(u8, 1) << random.int(u3),
                    1 => buf[random.uintLessThan(usize, len)] = random.int(u8),
                    else => len = random.uintAtMost(usize, len),
                }
            }
            if (random.boolean() and len >= 64) {
                std.mem.writeInt(u32, buf[44..48], 0, .little);
                std.mem.writeInt(u32, buf[44..48], std.hash.Crc32.hash(buf[0..len]), .little);
            }
            const p = bt.Program.load(buf[0..len]) catch continue;
            loaded += 1;
            var capacity = p.capacity();
            capacity.frames = 256;
            var scratch = try bt.Scratch.initCapacity(testing.allocator, capacity);
            defer scratch.deinit(testing.allocator);
            scratch.step_budget = 1 << 16;
            for (inputs) |input| {
                var it = p.iterator(&scratch, input);
                var n: usize = 0;
                while (n < 16) : (n += 1) {
                    const m = (it.next() catch break) orelse break;
                    try testing.expect(m.start <= m.end and m.end <= input.len);
                }
            }
        }
    }
    try testing.expect(loaded > 20);
}

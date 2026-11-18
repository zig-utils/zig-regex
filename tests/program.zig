//! Flat programs and the allocation-free matcher, checked against `Regex`.

const std = @import("std");
const regex = @import("regex");
const Regex = regex.Regex;
const Program = regex.Program;
const Scratch = regex.Scratch;
const Span = regex.program.Span;
const CompileFlags = regex.common.CompileFlags;

const testing = std.testing;

const flag_sets = [_]CompileFlags{
    .{},
    .{ .case_insensitive = true },
    .{ .multiline = true },
    .{ .dot_all = true },
    .{ .bytes = true },
    .{ .bytes = true, .case_insensitive = true, .multiline = true },
    .{ .bytes = true, .dot_all = true },
};

const corpus_patterns = [_][]const u8{
    "a",                     "abc",               "a|b",                       "ab|cd|ef",
    "a|ab",                  "ab|a",              "colou?r",                   "a*",
    "a+",                    "a?",                "a*b",                       "(a|b)*c",
    "(ab)+",                 "a{3}",              "a{2,4}",                    "a{2,}",
    "[abc]+",                "[^abc]+",           "[a-z]+[0-9]*",              "\\d+",
    "\\D+",                  "\\w+",              "\\W",                       "\\s+",
    "\\S+",                  ".",                 ".*",                        ".+x",
    "a.c",                   "^abc",              "abc$",                      "^$",
    "^a*$",                  "\\bfoo\\b",         "\\Bfoo",                    "foo\\B",
    "\\Aab",                 "ab\\z",             "^\\w+$",                    "(?:ab|cd)+e",
    "x(a|bc|def)*y",         "[\\x00-\\x1f]",     "\\x41\\x42",                "[[:alpha:]]+",
    "[[:digit:][:upper:]]+", "\\t|\\n",           "a\\.b",                     "[.]+",
    "(a|b|c|d|e|f)+g",       "(foo|foobar)baz",   "[a-c]*[b-d]+",              "(x+x+)+y",
    "a{0,3}b",               "(?:a?){5}a{5}",     "^(?:[a-z]+\\.)+[a-z]{2,}$", "[^\\n]*\\n",
    "(?:\\r?\\n)+",          "\\bA",              "Z\\b",                      "^.",
    ".$",                    "(a*)*b",            "(a|aa)+$",                  "fn\\s+\\w+",
    "\\w+@\\w+\\.com",       "[0-9]{3}-[0-9]{4}", "(?:x|y|z){2,3}",            "",
};

const corpus_inputs = [_][]const u8{
    "",
    "a",
    "abc",
    "xabcx",
    "aaaa",
    "ab ab abab",
    "color colour colr",
    "foo foobar foobaz foo_bar",
    "line1\nline2\r\nabc\n",
    "  \t tabs and spaces \t ",
    "x12345y 555-1234 99",
    "aaaaaaaaaaaaaaaaaaaaaaaab",
    "aaaaaaaaaaaaaaaaaaaaaaaa",
    "xxxxxxxxxxxxxy",
    "user@example.com, other@test.com",
    "fn main() { fn helper }",
    "ABC abc AbC",
    "www.example.org",
    "\x00\x01\x02\x1f\x7f",
    "caf\xc3\xa9 \xff\xfe\x80 na\xc3\xafve",
    "abcdefg zyx",
    "\n\n\n",
    "AZ aZ Z_Z",
    "xay xbcy xdefy xy xbcbcy",
};

/// A FailingAllocator that admits every allocation until `freeze`, then
/// fails any further allocation, and remembers whether one was attempted.
const Freezer = struct {
    failing: std.testing.FailingAllocator,

    fn init() Freezer {
        return .{ .failing = std.testing.FailingAllocator.init(testing.allocator, .{}) };
    }

    fn allocator(self: *Freezer) std.mem.Allocator {
        return self.failing.allocator();
    }

    fn freeze(self: *Freezer) void {
        self.failing.fail_index = self.failing.alloc_index;
    }

    fn thaw(self: *Freezer) !void {
        // No allocation was attempted while frozen.
        try testing.expect(!self.failing.has_induced_failure);
        try testing.expectEqual(self.failing.fail_index, self.failing.alloc_index);
        self.failing.fail_index = std.math.maxInt(usize);
    }
};

const Outcome = enum { compared, unsupported, invalid };

/// The Thompson engine of record: the NFA VM, run at each start in turn,
/// gives the leftmost match extended as far as possible.
fn vmFindFrom(machine: *regex.vm.VM, input: []const u8, from: usize) !?[2]usize {
    var pos = from;
    while (pos <= input.len) : (pos += 1) {
        if (try machine.matchAt(input, pos)) |result| {
            var owned = result;
            defer owned.deinit(testing.allocator);
            return .{ result.start, result.end };
        }
    }
    return null;
}

/// Compare every program entry point with the engines `Regex` uses for the
/// same pattern: `Regex.isMatch` and the start of `Regex.find` must agree
/// exactly, and spans must equal the NFA VM's. (`Regex.find` takes a
/// literal-alternation fast path that reports the first alternative in
/// source order, so its match end can be shorter than the VM's for `a|ab`.)
/// Matching runs while the allocator that built the program and scratch
/// refuses any allocation.
fn compareOne(pattern: []const u8, flags: CompileFlags, inputs: []const []const u8) !Outcome {
    var re = Regex.compileWithFlags(testing.allocator, pattern, flags) catch return .invalid;
    defer re.deinit();

    var freezer = Freezer.init();
    var program = Program.fromRegex(freezer.allocator(), &re) catch |err| switch (err) {
        error.UnsupportedByProgram => return .unsupported,
        else => return err,
    };
    defer program.deinit(freezer.allocator());
    var scratch = try Scratch.init(freezer.allocator(), &program);
    defer scratch.deinit(freezer.allocator());
    var machine = regex.vm.VM.init(testing.allocator, &re.nfa, re.capture_count, re.flags);
    defer machine.deinit();

    for (inputs) |input| {
        // Reference results first: Regex and the VM allocate.
        const want_match = try re.isMatch(input);
        const regex_start: ?usize = if (try re.find(input)) |m| blk: {
            var owned = m;
            defer owned.deinit(testing.allocator);
            break :blk m.start;
        } else null;
        const want_find = try vmFindFrom(&machine, input, 0);
        var want_all: [64][2]usize = undefined;
        var want_count: usize = 0;
        var pos: usize = 0;
        while (pos <= input.len) {
            const m = (try vmFindFrom(&machine, input, pos)) orelse break;
            want_all[want_count] = m;
            want_count += 1;
            pos = if (m[1] > m[0]) m[1] else m[1] + 1;
        }
        var froms: [4]usize = .{ 0, 1, input.len / 2, input.len };
        var want_from: [4]?[2]usize = undefined;
        for (&froms, &want_from) |*from, *want| {
            from.* = @min(from.*, input.len);
            want.* = try vmFindFrom(&machine, input, from.*);
        }

        freezer.freeze();
        const got_match = try program.isMatch(&scratch, input);
        const got_find = try program.find(&scratch, input);
        var got_all: [64]Span = undefined;
        const got_count = try program.findAll(&scratch, input, &got_all);
        const counted = try program.count(&scratch, input);
        var got_from: [4]?Span = undefined;
        for (froms, &got_from) |from, *got| got.* = try program.findFrom(&scratch, input, from);
        try freezer.thaw();

        errdefer std.debug.print("pattern \"{s}\" flags {any} input {any}\n", .{ pattern, flags, input });
        try testing.expectEqual(want_match, got_match);
        try testing.expectEqual(regex_start, if (got_find) |m| m.start else null);
        try expectSpan(want_find, got_find);
        try testing.expectEqual(want_count, got_count);
        try testing.expectEqual(want_count, counted);
        for (want_all[0..want_count], got_all[0..got_count]) |w, g| try expectSpan(w, g);
        for (want_from, got_from) |w, g| try expectSpan(w, g);
    }
    return .compared;
}

fn expectSpan(want: ?[2]usize, got: ?Span) !void {
    if (want) |w| {
        const g = got orelse {
            std.debug.print("expected {d}..{d}, got no match\n", .{ w[0], w[1] });
            return error.TestUnexpectedResult;
        };
        if (w[0] != g.start or w[1] != g.end) {
            std.debug.print("expected {d}..{d}, got {d}..{d}\n", .{ w[0], w[1], g.start, g.end });
            return error.TestUnexpectedResult;
        }
    } else if (got) |g| {
        std.debug.print("expected no match, got {d}..{d}\n", .{ g.start, g.end });
        return error.TestUnexpectedResult;
    }
}

test "program: corpus matches Regex with no allocation while matching" {
    var compared: usize = 0;
    var unsupported: usize = 0;
    for (corpus_patterns) |pattern| {
        for (flag_sets) |flags| {
            switch (try compareOne(pattern, flags, &corpus_inputs)) {
                .compared => compared += 1,
                .unsupported => unsupported += 1,
                .invalid => {},
            }
        }
    }
    // 416 pairs compare and 46 need backtracking at the time of writing.
    try testing.expect(unsupported < compared / 4);
    try testing.expect(compared > corpus_patterns.len * flag_sets.len * 3 / 4);
}

// Random patterns from a small grammar, on random inputs over a small
// alphabet, against Regex.
fn genAtom(random: std.Random, buf: []u8, len: *usize, depth: usize) void {
    const atoms = [_][]const u8{ "a", "b", "c", "A", ".", "[ab]", "[^a]", "[a-c]", "\\w", "\\d", "\\s", "\\xff", "\\x80", "\\n", "x" };
    const assertions = [_][]const u8{ "^", "$", "\\b", "\\B", "\\A", "\\z" };
    const choice = random.uintLessThan(u8, 10);
    if (choice == 0 and depth < 3) {
        append(buf, len, "(?:");
        genAlt(random, buf, len, depth + 1);
        append(buf, len, ")");
    } else if (choice == 1) {
        append(buf, len, assertions[random.uintLessThan(usize, assertions.len)]);
        return;
    } else {
        append(buf, len, atoms[random.uintLessThan(usize, atoms.len)]);
    }
    const quants = [_][]const u8{ "", "", "", "*", "+", "?", "{2}", "{1,3}", "{0,2}" };
    append(buf, len, quants[random.uintLessThan(usize, quants.len)]);
}

fn genSeq(random: std.Random, buf: []u8, len: *usize, depth: usize) void {
    const n = random.intRangeAtMost(usize, 1, 4);
    var i: usize = 0;
    while (i < n) : (i += 1) genAtom(random, buf, len, depth);
}

fn genAlt(random: std.Random, buf: []u8, len: *usize, depth: usize) void {
    genSeq(random, buf, len, depth);
    if (random.uintLessThan(u8, 4) == 0) {
        append(buf, len, "|");
        genSeq(random, buf, len, depth);
    }
}

fn append(buf: []u8, len: *usize, text: []const u8) void {
    if (len.* + text.len > buf.len) return;
    @memcpy(buf[len.*..][0..text.len], text);
    len.* += text.len;
}

test "program: random patterns match Regex" {
    var prng = std.Random.DefaultPrng.init(0x5EED_0042);
    const random = prng.random();
    const alphabet = "aabbcAx1 \n\xff\x80_";
    var compared: usize = 0;
    var iteration: usize = 0;
    while (iteration < 600) : (iteration += 1) {
        var pattern: [96]u8 = undefined;
        var plen: usize = 0;
        genAlt(random, &pattern, &plen, 0);
        var inputs: [6][]const u8 = undefined;
        var storage: [6][20]u8 = undefined;
        for (&inputs, &storage) |*input, *buf| {
            const n = random.uintAtMost(usize, buf.len);
            for (buf[0..n]) |*c| c.* = alphabet[random.uintLessThan(usize, alphabet.len)];
            input.* = buf[0..n];
        }
        const flags = flag_sets[random.uintLessThan(usize, flag_sets.len)];
        if (try compareOne(pattern[0..plen], flags, &inputs) == .compared) compared += 1;
    }
    try testing.expect(compared > 300);
}

test "program: patterns that need backtracking are reported" {
    const unsupported = [_][]const u8{ "(a)\\1", "(?<=a)b", "a(?=b)", "a+?", "(?i:a)b", "\\p{L}" };
    for (unsupported) |pattern| {
        var re = try Regex.compile(testing.allocator, pattern);
        defer re.deinit();
        try testing.expectError(error.UnsupportedByProgram, Program.fromRegex(testing.allocator, &re));
    }
    try testing.expectError(error.UnsupportedByProgram, Program.compile(testing.allocator, "a|b", .{ .ecmascript = true }));
}

test "program: capture groups inside alternations still compile" {
    // `Regex` orders these captures on the backtracker; a program reports
    // spans only, so `Program.compile` drops the groups and stays linear.
    const Case = struct { pattern: []const u8, flags: CompileFlags, input: []const u8, span: [2]usize };
    const cases = [_]Case{
        .{ .pattern = "(etc/(passwd|shadow)|proc/self/environ|win\\.ini)", .flags = .{}, .input = "GET /../etc/shadow HTTP", .span = .{ 8, 18 } },
        .{ .pattern = "(\\.\\./|%2e%2e(/|%2f))", .flags = .{ .bytes = true, .case_insensitive = true }, .input = "f=%2E%2E%2Fx", .span = .{ 2, 11 } },
        .{ .pattern = "x(a(b|c)|d)y", .flags = .{}, .input = "zxacy", .span = .{ 1, 5 } },
        .{ .pattern = "(?<n>ab|cd(e|f))", .flags = .{}, .input = "--cdf", .span = .{ 2, 5 } },
    };
    for (cases) |c| {
        var re = try Regex.compileWithFlags(testing.allocator, c.pattern, c.flags);
        defer re.deinit();
        try testing.expectError(error.UnsupportedByProgram, Program.fromRegex(testing.allocator, &re));

        var spans_only = try Regex.compileWithoutCaptures(testing.allocator, c.pattern, c.flags);
        defer spans_only.deinit();
        try testing.expectEqual(@as(usize, 0), spans_only.capture_count);

        var program = try Program.compile(testing.allocator, c.pattern, c.flags);
        defer program.deinit(testing.allocator);
        var scratch = try Scratch.init(testing.allocator, &program);
        defer scratch.deinit(testing.allocator);
        const span = (try program.find(&scratch, c.input)).?;
        try testing.expectEqual(c.span, [2]usize{ span.start, span.end });
        try testing.expect(try re.isMatch(c.input));
    }
    // A backreference needs its group: still the backtracker, still refused.
    try testing.expectError(error.UnsupportedByProgram, Program.compile(testing.allocator, "(a|b)\\1", .{}));
}

test "program: the NFA fallback agrees with the DFA" {
    const patterns = [_][]const u8{ "[ab]*a[ab]{6}", "x[abcdef]*y", "\\bfoo\\b", "^\\w+$", "(foo|foobar)baz", "a{2,4}", "(?:ab)+e|cde" };
    const inputs = [_][]const u8{ "abababbbaabababa", "xay xbcy xdefy xbcbcy", "foo foobar foo", "line1\nline2", "foobarbaz foobaz", "aaaaa", "ababcde" };
    for (patterns) |pattern| {
        for ([_]CompileFlags{ .{}, .{ .multiline = true, .bytes = true } }) |flags| {
            var program = try Program.compile(testing.allocator, pattern, flags);
            defer program.deinit(testing.allocator);
            var dfa_scratch = try Scratch.init(testing.allocator, &program);
            defer dfa_scratch.deinit(testing.allocator);
            // A two-state DFA cache overflows at once, so every call falls
            // back to the NFA simulation.
            var tiny = program.capacity();
            tiny.dfa_states = 2;
            var nfa_scratch = try Scratch.initCapacity(testing.allocator, tiny);
            defer nfa_scratch.deinit(testing.allocator);
            for (inputs) |input| {
                try testing.expectEqual(try program.isMatch(&dfa_scratch, input), try program.isMatch(&nfa_scratch, input));
                var from: usize = 0;
                while (from <= input.len) : (from += 1) {
                    const a = try program.findFrom(&dfa_scratch, input, from);
                    const b = try program.findFrom(&nfa_scratch, input, from);
                    try expectSpan(if (a) |m| .{ m.start, m.end } else null, b);
                }
            }
        }
    }
}

test "program: one scratch serves several programs" {
    var small = try Program.compile(testing.allocator, "ab+c", .{});
    defer small.deinit(testing.allocator);
    var large = try Program.compile(testing.allocator, "(foo|bar|baz)[0-9]{2,5}\\b", .{});
    defer large.deinit(testing.allocator);

    var scratch = try Scratch.initCapacity(testing.allocator, small.capacity().max(large.capacity()));
    defer scratch.deinit(testing.allocator);
    var round: usize = 0;
    while (round < 3) : (round += 1) {
        try expectSpan(.{ 1, 5 }, try small.find(&scratch, "xabbc"));
        try expectSpan(.{ 2, 8 }, try large.find(&scratch, "x bar123 baz1"));
        try testing.expect(!try small.isMatch(&scratch, "abd"));
        try testing.expectEqual(@as(usize, 1), try large.count(&scratch, "bar123 baz1 foo1234567"));
    }

    var tiny = try Scratch.init(testing.allocator, &small);
    defer tiny.deinit(testing.allocator);
    try testing.expectError(error.ScratchTooSmall, large.isMatch(&tiny, "bar12"));
}

test "program: scratch in caller memory" {
    var program = try Program.compile(testing.allocator, "[a-f0-9]{8}", .{ .bytes = true });
    defer program.deinit(testing.allocator);
    const need = Scratch.bytesNeeded(program.capacity());
    const buffer = try testing.allocator.alignedAlloc(u8, .@"8", need);
    defer testing.allocator.free(buffer);
    try testing.expectError(error.BufferTooSmall, Scratch.initBuffer(buffer[0 .. need - 8], program.capacity()));
    var scratch = try Scratch.initBuffer(buffer, program.capacity());
    try expectSpan(.{ 3, 11 }, try program.find(&scratch, "id=deadbeef01"));
}

test "program: findAll reports a short buffer instead of dropping matches" {
    var program = try Program.compile(testing.allocator, "\\d+", .{});
    defer program.deinit(testing.allocator);
    var scratch = try Scratch.init(testing.allocator, &program);
    defer scratch.deinit(testing.allocator);
    var out: [2]Span = undefined;
    try testing.expectError(error.NoSpaceLeft, program.findAll(&scratch, "1 22 333", &out));
    try testing.expectEqual(@as(usize, 2), try program.findAll(&scratch, "1 22", &out));
    var it = program.iterator(&scratch, "1 22 333");
    try expectSpan(.{ 0, 1 }, try it.next());
    try expectSpan(.{ 2, 4 }, try it.next());
    try expectSpan(.{ 5, 8 }, try it.next());
    try testing.expectEqual(@as(?Span, null), try it.next());
}

const ThreadCtx = struct {
    program: *const Program,
    input: []const u8,
    expected: usize,
    ok: bool = false,

    fn run(ctx: *ThreadCtx) void {
        var scratch = Scratch.init(std.heap.page_allocator, ctx.program) catch return;
        defer scratch.deinit(std.heap.page_allocator);
        var round: usize = 0;
        while (round < 200) : (round += 1) {
            const n = ctx.program.count(&scratch, ctx.input) catch return;
            if (n != ctx.expected) return;
        }
        ctx.ok = true;
    }
};

test "program: one program shared read-only across threads" {
    var program = try Program.compile(testing.allocator, "\\b[a-z]+[0-9]{1,3}\\b", .{});
    defer program.deinit(testing.allocator);
    const unit = "abc1 de22 x f333 gh4444 ij5 ";
    var storage: [unit.len * 20]u8 = undefined;
    for (0..20) |i| @memcpy(storage[i * unit.len ..][0..unit.len], unit);
    const input: []const u8 = &storage;
    var scratch = try Scratch.init(testing.allocator, &program);
    defer scratch.deinit(testing.allocator);
    const expected = try program.count(&scratch, input);
    try testing.expectEqual(@as(usize, 80), expected);

    var contexts: [4]ThreadCtx = undefined;
    var threads: [4]std.Thread = undefined;
    for (&contexts, &threads) |*ctx, *thread| {
        ctx.* = .{ .program = &program, .input = input, .expected = expected };
        thread.* = try std.Thread.spawn(.{}, ThreadCtx.run, .{ctx});
    }
    for (threads) |thread| thread.join();
    for (contexts) |ctx| try testing.expect(ctx.ok);
}

// ---------------------------------------------------------------------------
// Limits: the DFA state cap and the step budget.

fn withDfaStates(program: *const Program, states: u32) regex.program.Capacity {
    var capacity = program.capacity();
    capacity.dfa_states = states;
    return capacity;
}

test "limits: a 256-state cap keeps scratch memory under the documented bound" {
    const patterns = [_][]const u8{
        "abc",
        "[ab]*a[ab]{12}",
        "\\b[a-z]{1,40}@[a-z]{1,40}\\.(?:com|org|net)\\b",
        "(?:GET|POST|PUT|DELETE) /[a-zA-Z0-9/_.-]{1,200} HTTP/1\\.[01]",
        "MZ.{58}PE\\x00\\x00[\\x4c\\x64]\\x01",
    };
    for (patterns, 0..) |pattern, i| {
        var program = try Program.compile(testing.allocator, pattern, .{ .bytes = i == 4 });
        defer program.deinit(testing.allocator);
        const capacity = withDfaStates(&program, 256);
        const need = Scratch.bytesNeeded(capacity);
        try testing.expect(need <= Scratch.boundFor(capacity));
        // The bound written out for D = 256 in the Scratch docs.
        const n: usize = program.state_count;
        const c: usize = program.class_count;
        const w = (n + 31) / 32;
        try testing.expect(need <= 36 * n + 1024 * (c + w + 2) + 12 * w + 2056);
    }
}

test "limits: a DFA that outgrows its cap falls back to the NFA without failing" {
    // Recognising "an a twelve bytes from the end" takes 2^13 DFA states.
    var program = try Program.compile(testing.allocator, "[ab]*a[ab]{12}c", .{});
    defer program.deinit(testing.allocator);
    var capped = try Scratch.initCapacity(testing.allocator, withDfaStates(&program, 256));
    defer capped.deinit(testing.allocator);
    var nfa_only = try Scratch.initCapacity(testing.allocator, withDfaStates(&program, 0));
    defer nfa_only.deinit(testing.allocator);
    var roomy = try Scratch.initCapacity(testing.allocator, withDfaStates(&program, 1 << 15));
    defer roomy.deinit(testing.allocator);

    var prng = std.Random.DefaultPrng.init(0xCA9);
    const random = prng.random();
    var input: [4096]u8 = undefined;
    var round: usize = 0;
    while (round < 8) : (round += 1) {
        for (&input) |*c| c.* = if (random.boolean()) 'a' else 'b';
        // Plant a match in some rounds.
        if (round % 2 == 0) {
            const at = random.uintLessThan(usize, input.len - 14);
            input[at] = 'a';
            input[at + 13] = 'c';
        }
        const want = try program.find(&roomy, &input);
        try testing.expectEqual(want, try program.find(&capped, &input));
        try testing.expectEqual(want, try program.find(&nfa_only, &input));
        try testing.expectEqual(want != null, try program.isMatch(&capped, &input));
        try testing.expect(capped.dfa_len <= 256);
    }
}

test "limits: a catastrophic search returns BudgetExceeded within the budget" {
    // On the NFA (DFA disabled) every byte advances about 14 threads.
    var program = try Program.compile(testing.allocator, "[ab]*a[ab]{12}c", .{});
    defer program.deinit(testing.allocator);
    const input = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(input);
    // Random a/b text drives the DFA through thousands of states, so the
    // 256-state cap overflows and the search runs on the NFA as well.
    var prng = std.Random.DefaultPrng.init(0xBAD);
    for (input) |*c| c.* = if (prng.random().boolean()) 'a' else 'b';

    for ([_]u32{ 0, 256 }) |dfa_states| {
        var scratch = try Scratch.initCapacity(testing.allocator, withDfaStates(&program, dfa_states));
        defer scratch.deinit(testing.allocator);
        for ([_]u64{ 1, 100, 10_000, 250_000 }) |budget| {
            scratch.step_budget = budget;
            try testing.expectError(error.BudgetExceeded, program.isMatch(&scratch, input));
            try testing.expect(scratch.steps <= budget);
            try testing.expectError(error.BudgetExceeded, program.find(&scratch, input));
            try testing.expect(scratch.steps <= budget);
            var it = program.iterator(&scratch, input);
            try testing.expectError(error.BudgetExceeded, it.next());
            try testing.expect(scratch.steps <= budget);
        }
        // With room to finish, the same search reports a genuine "no match",
        // and from the same cold cache a budget of exactly the steps it took
        // is enough.
        scratch.step_budget = null;
        scratch.reset();
        try testing.expect(!try program.isMatch(&scratch, input));
        const needed = scratch.steps;
        scratch.reset();
        scratch.step_budget = needed;
        try testing.expect(!try program.isMatch(&scratch, input));
        try testing.expectEqual(needed, scratch.steps);
    }
}

test "limits: the DFA budget counts input bytes" {
    var program = try Program.compile(testing.allocator, "needle", .{});
    defer program.deinit(testing.allocator);
    var scratch = try Scratch.init(testing.allocator, &program);
    defer scratch.deinit(testing.allocator);
    var input: [10_000]u8 = @splat('x');
    @memcpy(input[9_000..][0..6], "needle");
    scratch.step_budget = 5_000;
    try testing.expectError(error.BudgetExceeded, program.find(&scratch, &input));
    try testing.expect(scratch.steps <= 5_000);
    scratch.step_budget = 20_000;
    const m = (try program.find(&scratch, &input)).?;
    try testing.expectEqual(@as(usize, 9_000), m.start);
    try testing.expect(scratch.steps <= 20_000);
}

test "limits: the backtracker's step budget is configurable" {
    const input = "zaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaX";
    var re = try Regex.compileWithFlags(testing.allocator, "(?=a+X)", .{ .ecmascript = true });
    defer re.deinit();
    try testing.expectEqual(@as(?usize, 10_000_000), re.stepBudget());
    re.setStepBudget(25);
    try testing.expectEqual(@as(?usize, 25), re.stepBudget());
    try testing.expectError(error.Timeout, re.isMatch(input));
    try testing.expectError(error.Timeout, re.find(input));
    re.setStepBudget(10_000);
    try testing.expect(try re.isMatch(input));

    var linear = try Regex.compile(testing.allocator, "a+X");
    defer linear.deinit();
    try testing.expectEqual(@as(?usize, null), linear.stepBudget());
}

// ---------------------------------------------------------------------------
// Serialisation: programs written to bytes and loaded back without allocation.

fn expectSameResults(a: *const Program, b: *const Program, inputs: []const []const u8) !void {
    var sa = try Scratch.init(testing.allocator, a);
    defer sa.deinit(testing.allocator);
    var sb = try Scratch.init(testing.allocator, b);
    defer sb.deinit(testing.allocator);
    for (inputs) |input| {
        try testing.expectEqual(try a.isMatch(&sa, input), try b.isMatch(&sb, input));
        var ia = a.iterator(&sa, input);
        var ib = b.iterator(&sb, input);
        while (true) {
            const ma = try ia.next();
            const mb = try ib.next();
            try testing.expectEqual(ma, mb);
            if (ma == null) break;
        }
    }
}

test "serialise: every corpus pattern matches identically after a round trip" {
    var storage: [1 << 16]u8 = undefined;
    var round_trips: usize = 0;
    for (corpus_patterns) |pattern| {
        for (flag_sets) |flags| {
            var original = Program.compile(testing.allocator, pattern, flags) catch continue;
            defer original.deinit(testing.allocator);
            const blob = original.bytes();
            try testing.expect(blob.len + 3 <= storage.len);
            // Load from an odd address, with trailing bytes after the
            // program, the way a section of a larger mmapped file looks.
            const copy = storage[1..][0 .. blob.len + 2];
            @memcpy(copy[0..blob.len], blob);
            copy[blob.len] = 0xAA;
            copy[blob.len + 1] = 0x55;

            var freezer = Freezer.init();
            freezer.freeze();
            var loaded = try Program.load(copy);
            try freezer.thaw();
            defer loaded.deinit(testing.allocator); // borrowed: frees nothing
            try testing.expectEqual(blob.len, loaded.bytes().len);
            try testing.expectEqualSlices(u8, blob, loaded.bytes());
            try expectSameResults(&original, &loaded, &corpus_inputs);
            round_trips += 1;
        }
    }
    try testing.expect(round_trips > 300);
}

test "serialise: dupe owns a copy of a loaded program" {
    var original = try Program.compile(testing.allocator, "\\x7fELF[\\x01\\x02]", .{ .bytes = true });
    defer original.deinit(testing.allocator);
    const borrowed = try testing.allocator.dupe(u8, original.bytes());
    var loaded = try Program.load(borrowed);
    var owned = try loaded.dupe(testing.allocator);
    defer owned.deinit(testing.allocator);
    testing.allocator.free(borrowed);
    var scratch = try Scratch.init(testing.allocator, &owned);
    defer scratch.deinit(testing.allocator);
    try expectSpan(.{ 2, 7 }, try owned.find(&scratch, "ab\x7fELF\x02"));
}

test "serialise: malformed blobs are rejected with a precise error" {
    var program = try Program.compile(testing.allocator, "ab[0-9]+\\b", .{});
    defer program.deinit(testing.allocator);
    const good = program.bytes();
    var buf: [4096]u8 = undefined;
    const blob = buf[0..good.len];

    try testing.expectError(error.Truncated, Program.load(good[0..10]));
    try testing.expectError(error.Truncated, Program.load(good[0 .. good.len - 1]));

    @memcpy(blob, good);
    blob[0] = 'X';
    try testing.expectError(error.BadMagic, Program.load(blob));

    @memcpy(blob, good);
    std.mem.writeInt(u16, blob[4..6], 99, .little);
    try testing.expectError(error.UnsupportedVersion, Program.load(blob));

    @memcpy(blob, good);
    blob[blob.len - 1] ^= 1;
    try testing.expectError(error.ChecksumMismatch, Program.load(blob));

    // A structural error with a recomputed checksum: an edge to a state that
    // does not exist.
    @memcpy(blob, good);
    const edges_off = std.mem.readInt(u32, blob[40..44], .little);
    std.mem.writeInt(u32, blob[edges_off..][0..4], 0xFFFF_FF00, .little);
    fixChecksum(blob);
    try testing.expectError(error.InvalidProgram, Program.load(blob));
}

/// Recompute a blob's CRC-32 (over the blob with the checksum field zeroed)
/// so a mutation reaches the structural checks.
fn fixChecksum(blob: []u8) void {
    std.mem.writeInt(u32, blob[56..60], 0, .little);
    std.mem.writeInt(u32, blob[56..60], std.hash.Crc32.hash(blob), .little);
}

/// Load a mutated blob: it must either fail cleanly or give a program that
/// matches without faulting (safety checks catch any out-of-bounds access).
fn loadMutated(blob: []const u8, inputs: []const []const u8) !bool {
    const program = Program.load(blob) catch return false;
    var capacity = program.capacity();
    capacity.dfa_states = 64;
    var scratch = try Scratch.initCapacity(testing.allocator, capacity);
    defer scratch.deinit(testing.allocator);
    scratch.step_budget = 1 << 16;
    for (inputs) |input| {
        _ = program.isMatch(&scratch, input) catch {};
        var it = program.iterator(&scratch, input);
        var n: usize = 0;
        while (n < 16) : (n += 1) {
            const m = (it.next() catch break) orelse break;
            try testing.expect(m.start <= m.end and m.end <= input.len);
        }
    }
    return true;
}

const seed_patterns = [_]struct { pattern: []const u8, flags: CompileFlags }{
    .{ .pattern = "ab[0-9]+\\b", .flags = .{} },
    .{ .pattern = "^(?:GET|POST) /[a-z]{1,8}$", .flags = .{ .multiline = true } },
    .{ .pattern = "MZ.{2}\\x50\\x45[\\x00-\\x1f]*", .flags = .{ .bytes = true } },
    .{ .pattern = "\\Bfoo|bar\\z", .flags = .{ .case_insensitive = true } },
};
const fuzz_inputs = [_][]const u8{ "", "ab12 ab3x", "GET /abc\nPOST /x", "MZ\x90\x00PE\x01\x02", "xfoo bar", "\xff\x00\n" };

test "serialise: corrupted blobs fail cleanly (randomised)" {
    var prng = std.Random.DefaultPrng.init(0x10AD);
    const random = prng.random();
    var buf: [8192]u8 = undefined;
    var loaded: usize = 0;
    for (seed_patterns) |seed| {
        var program = try Program.compile(testing.allocator, seed.pattern, seed.flags);
        defer program.deinit(testing.allocator);
        const good = program.bytes();
        var iteration: usize = 0;
        while (iteration < 3000) : (iteration += 1) {
            var len = good.len;
            @memcpy(buf[0..len], good);
            const mutations = random.intRangeAtMost(usize, 1, 4);
            var k: usize = 0;
            while (k < mutations and len > 0) : (k += 1) {
                switch (random.uintLessThan(u8, 4)) {
                    0 => buf[random.uintLessThan(usize, len)] ^= @as(u8, 1) << random.int(u3),
                    1 => buf[random.uintLessThan(usize, len)] = random.int(u8),
                    2 => len = random.uintAtMost(usize, len),
                    else => {
                        // A header word: counts, offsets and flags.
                        const word = random.uintLessThan(usize, 16) * 4;
                        if (word + 4 <= len) std.mem.writeInt(u32, buf[word..][0..4], random.int(u32), .little);
                    },
                }
            }
            // Half the time, repair the checksum so the structural checks
            // see the damage instead of the CRC.
            if (random.boolean() and len >= 64) fixChecksum(buf[0..len]);
            if (try loadMutated(buf[0..len], &fuzz_inputs)) loaded += 1;
        }
    }
    // Some damage leaves a valid program (a flipped accepting bit, another
    // in-range edge target), which then has to match without faulting.
    try testing.expect(loaded > 100);
}

fn fuzzLoad(_: void, smith: *std.testing.Smith) anyerror!void {
    const seed = seed_patterns[smith.index(seed_patterns.len)];
    var program = try Program.compile(testing.allocator, seed.pattern, seed.flags);
    defer program.deinit(testing.allocator);
    var buf: [8192]u8 = undefined;
    const good = program.bytes();
    var len = good.len;
    @memcpy(buf[0..len], good);
    while (!smith.eosWeightedSimple(1, 3)) {
        const at = smith.index(len);
        buf[at] = smith.value(u8);
    }
    if (smith.boolWeighted(1, 1)) len = smith.valueRangeAtMost(u32, 0, @intCast(len));
    if (smith.boolWeighted(1, 3) and len >= 64) fixChecksum(buf[0..len]);
    _ = try loadMutated(buf[0..len], &fuzz_inputs);
}

test "serialise: loader fuzz target" {
    // `zig build test-program --fuzz` explores this with coverage guidance;
    // a plain test run replays the corpus.
    try std.testing.fuzz({}, fuzzLoad, .{ .corpus = &.{ "", "\x00\x01\x02\x03", "\xff\xff\xff\xff\xff\xff\xff\xff" } });
}

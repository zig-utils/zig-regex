//! zig-regex side of benchmarks/pcre2/diff.sh: a differential test of
//! leftmost-first programs against PCRE2.
//!
//!   pcre2_diff gen <count> <seed>           random cases on stdout
//!   (gen-bt, check-bt and fixture-bt do the same for `regex.bt` programs,
//!   with backreferences, lookaround, atomic groups and large repeats)
//!   pcre2_diff check <cases.tsv> <spans.tsv> agreement counts and the first
//!                                            disagreements
//!   pcre2_diff fixture <cases.tsv> <spans.tsv> <count>
//!                                            the first `count` cases with
//!                                            PCRE2's spans appended, for
//!                                            tests/testdata (agreeing cases
//!                                            only; see docs/BENCHMARKS.md for
//!                                            the known differences)
//!
//! A case is flags<TAB>pattern-hex<TAB>subject-hex, the format
//! `pcre2_spans.c` reads. Patterns come from a small grammar over the
//! constructs whose match ends depend on the match kind: alternation order,
//! greedy and lazy repeats (`*?`, `+?`, `??`, `{m,n}?`, `{,n}`), repeated
//! groups and alternations, classes, `.`, `\b`, anchors, case folding and
//! inline modifiers (scoped `(?i:..)` and standalone `(?i)`). Each case is
//! compiled as a byte-mode leftmost-first `Program` and its `g`-style matches
//! (`Program.iterator`) are compared with PCRE2's.

const std = @import("std");
const regex = @import("regex");
const Io = std.Io;

const max_pattern = 96;

/// `gen-bt`/`check-bt`: the grammar also emits backreferences, lookahead,
/// lookbehind, atomic groups and large counted repeats, and cases run as
/// `regex.bt` backtracking programs.
var bt_mode = false;

fn genLookbehindBody(random: std.Random, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    // Bounded length, as PCRE2 requires of a lookbehind.
    const n = 1 + random.uintLessThan(usize, 3);
    for (0..n) |_| {
        try out.appendSlice(gpa, ([_][]const u8{ "a", "b", "c", " ", ".", "[ab]", "\\w", "\\b" })[random.uintLessThan(usize, 8)]);
        if (random.uintLessThan(u8, 4) == 0) try out.appendSlice(gpa, "{1,2}");
    }
    if (random.uintLessThan(u8, 3) == 0) {
        try out.append(gpa, '|');
        try out.append(gpa, "ab"[random.uintLessThan(usize, 2)]);
    }
}

fn genAtom(random: std.Random, out: *std.ArrayList(u8), gpa: std.mem.Allocator, depth: usize) !void {
    const pick = if (bt_mode and random.uintLessThan(u8, 4) == 0)
        20 + random.uintLessThan(u8, 6)
    else
        random.uintLessThan(u8, if (depth > 2) 15 else 20);
    switch (pick) {
        // A backreference to a group opened earlier in the pattern.
        20 => {
            var groups: usize = 0;
            for (out.items, 0..) |c, k| {
                if (c == '(' and (k + 1 == out.items.len or out.items[k + 1] != '?') and (k == 0 or out.items[k - 1] != '\\')) groups += 1;
            }
            if (groups == 0) return out.append(gpa, 'a');
            try out.print(gpa, "\\{d}", .{1 + random.uintLessThan(usize, @min(groups, 3))});
        },
        21, 22 => {
            try out.appendSlice(gpa, if (random.boolean()) "(?=" else "(?!");
            try genAlt(random, out, gpa, depth + 1);
            try out.append(gpa, ')');
        },
        23 => {
            try out.appendSlice(gpa, if (random.boolean()) "(?<=" else "(?<!");
            try genLookbehindBody(random, out, gpa);
            try out.append(gpa, ')');
        },
        24 => {
            try out.appendSlice(gpa, "(?>");
            try genAlt(random, out, gpa, depth + 1);
            try out.append(gpa, ')');
        },
        25 => {
            try out.appendSlice(gpa, ([_][]const u8{ "(?:ab|a)", "[ab]", "(a|b)" })[random.uintLessThan(usize, 3)]);
            try out.appendSlice(gpa, ([_][]const u8{ "{20,}", "{5,30}", "{12}" })[random.uintLessThan(usize, 3)]);
            return;
        },
        0...4 => try out.append(gpa, "abc"[random.uintLessThan(usize, 3)]),
        5 => try out.append(gpa, '.'),
        6 => try out.appendSlice(gpa, ([_][]const u8{ "[ab]", "[^a]", "[a-c]", "[^\\n]", "\\w", "\\W", "\\d", "\\s" })[random.uintLessThan(usize, 8)]),
        7 => try out.appendSlice(gpa, ([_][]const u8{ "\\b", "\\B", "^", "$", "\\A", "\\z" })[random.uintLessThan(usize, 6)]),
        8 => try out.append(gpa, ' '),
        9 => try out.append(gpa, "AB1"[random.uintLessThan(usize, 3)]),
        10...13 => try out.append(gpa, "ab"[random.uintLessThan(usize, 2)]),
        // A standalone inline modifier, for the rest of the enclosing group.
        14 => try out.appendSlice(gpa, ([_][]const u8{ "(?i)", "(?-i)", "(?s)", "(?m)", "(?-s)", "(?im)" })[random.uintLessThan(usize, 6)]),
        else => {
            const opens = [_][]const u8{ "(?:", "(", "(", "(?i:", "(?-i:", "(?s:", "(?m:", "(?is-m:" };
            try out.appendSlice(gpa, opens[random.uintLessThan(usize, if (pick == 15 or pick == 16) 3 else opens.len)]);
            try genAlt(random, out, gpa, depth + 1);
            try out.append(gpa, ')');
        },
    }
}

fn genQuantified(random: std.Random, out: *std.ArrayList(u8), gpa: std.mem.Allocator, depth: usize) !void {
    const start = out.items.len;
    try genAtom(random, out, gpa, depth);
    const atom = out.items[start..];
    // A quantifier may not follow an assertion.
    const assertion = atom.len > 0 and (atom[0] == '^' or atom[0] == '$' or
        (atom.len == 2 and atom[0] == '\\' and (atom[1] == 'b' or atom[1] == 'B' or atom[1] == 'A' or atom[1] == 'z')));
    const directive = (std.mem.startsWith(u8, atom, "(?") and std.mem.indexOfScalar(u8, atom, ':') == null) or
        (atom.len > 0 and atom[atom.len - 1] == '}');
    if (assertion or directive or random.uintLessThan(u8, 3) != 0) return;
    const quantifiers = [_][]const u8{ "*", "+", "?", "{2}", "{1,3}", "{0,2}", "{2,}", "{,2}" };
    try out.appendSlice(gpa, quantifiers[random.uintLessThan(usize, quantifiers.len)]);
    if (random.boolean()) try out.append(gpa, '?');
}

fn genSeq(random: std.Random, out: *std.ArrayList(u8), gpa: std.mem.Allocator, depth: usize) !void {
    const n = 1 + random.uintLessThan(usize, 4);
    for (0..n) |_| try genQuantified(random, out, gpa, depth);
}

fn genAlt(random: std.Random, out: *std.ArrayList(u8), gpa: std.mem.Allocator, depth: usize) error{OutOfMemory}!void {
    try genSeq(random, out, gpa, depth);
    while (random.uintLessThan(u8, 3) == 0) {
        try out.append(gpa, '|');
        try genSeq(random, out, gpa, depth);
    }
}

fn writeHex(w: *Io.Writer, bytes: []const u8) !void {
    for (bytes) |b| try w.print("{x:0>2}", .{b});
}

fn genMain(gpa: std.mem.Allocator, w: *Io.Writer, args: []const []const u8) !void {
    if (args.len != 2) return error.BadArguments;
    const count = try std.fmt.parseInt(usize, args[0], 10);
    var prng = std.Random.DefaultPrng.init(try std.fmt.parseInt(u64, args[1], 10));
    const random = prng.random();
    var pattern: std.ArrayList(u8) = .empty;
    defer pattern.deinit(gpa);
    var subject: [48]u8 = undefined;
    var made: usize = 0;
    while (made < count) {
        pattern.clearRetainingCapacity();
        try genAlt(random, &pattern, gpa, 0);
        if (pattern.items.len > max_pattern) continue;
        const flags = ([_][]const u8{ "-", "-", "i", "m", "s", "im" })[random.uintLessThan(usize, 6)];
        const n = random.uintLessThan(usize, subject.len + 1);
        for (subject[0..n]) |*c| c.* = "aabbc AB1\n_"[random.uintLessThan(usize, 11)];
        try w.print("{s}\t", .{flags});
        try writeHex(w, pattern.items);
        try w.writeByte('\t');
        try writeHex(w, subject[0..n]);
        try w.writeByte('\n');
        made += 1;
    }
}

pub const Case = struct {
    flags: regex.common.CompileFlags,
    flag_text: []const u8,
    pattern: []u8,
    subject: []u8,
};

fn unhex(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, text.len / 2);
    _ = try std.fmt.hexToBytes(out, text);
    return out;
}

pub fn parseCase(arena: std.mem.Allocator, line: []const u8) !Case {
    var fields = std.mem.splitScalar(u8, line, '\t');
    const flag_text = fields.next() orelse return error.BadCase;
    const pattern = try unhex(arena, fields.next() orelse return error.BadCase);
    const subject = try unhex(arena, fields.next() orelse "");
    var flags: regex.common.CompileFlags = .{ .bytes = true };
    for (flag_text) |f| switch (f) {
        'i' => flags.case_insensitive = true,
        'm' => flags.multiline = true,
        's' => flags.dot_all = true,
        else => {},
    };
    return .{ .flags = flags, .flag_text = flag_text, .pattern = pattern, .subject = subject };
}

/// The program's `g`-style spans as PCRE2's line prints them, or null when
/// zig-regex does not compile the pattern as a program.
fn programSpans(gpa: std.mem.Allocator, case: Case, out: *std.ArrayList(u8)) !?void {
    if (bt_mode) {
        var p = regex.bt.Program.compile(gpa, case.pattern, case.flags) catch return null;
        defer p.deinit(gpa);
        var s = try regex.bt.Scratch.init(gpa, &p);
        defer s.deinit(gpa);
        var it = p.iterator(&s, case.subject);
        var first = true;
        while (it.next() catch |err| return err) |m| {
            try out.print(gpa, "{s}{d} {d}", .{ if (first) "" else " ", m.start, m.end });
            first = false;
        }
        return;
    }
    var program = regex.Program.compileWithOptions(gpa, case.pattern, case.flags, .{ .match_kind = .leftmost_first }) catch return null;
    defer program.deinit(gpa);
    var scratch = try regex.Scratch.init(gpa, &program);
    defer scratch.deinit(gpa);
    var it = program.iterator(&scratch, case.subject);
    var first = true;
    while (try it.next()) |m| {
        try out.print(gpa, "{s}{d} {d}", .{ if (first) "" else " ", m.start, m.end });
        first = false;
    }
}

fn checkMain(gpa: std.mem.Allocator, io: Io, w: *Io.Writer, args: []const []const u8) !void {
    if (args.len != 2 and args.len != 3) return error.BadArguments;
    const fixture_count: ?usize = if (args.len == 3) try std.fmt.parseInt(usize, args[2], 10) else null;
    var written: usize = 0;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases_text = try Io.Dir.cwd().readFileAlloc(io, args[0], arena, .unlimited);
    const spans_text = try Io.Dir.cwd().readFileAlloc(io, args[1], arena, .unlimited);
    var cases = std.mem.splitScalar(u8, cases_text, '\n');
    var spans = std.mem.splitScalar(u8, spans_text, '\n');
    var total: usize = 0;
    var agree: usize = 0;
    var pcre_error: usize = 0;
    var not_program: usize = 0;
    var limited: usize = 0;
    var shown: usize = 0;
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(gpa);
    while (cases.next()) |line| {
        if (line.len == 0) continue;
        const want = spans.next() orelse return error.SpansTooShort;
        const case = try parseCase(arena, line);
        if (std.mem.eql(u8, want, "error")) {
            pcre_error += 1;
            continue;
        }
        got.clearRetainingCapacity();
        const compiled = programSpans(gpa, case, &got) catch |err| switch (err) {
            error.BudgetExceeded, error.StackExhausted => {
                limited += 1;
                continue;
            },
            else => return err,
        };
        if (compiled == null) {
            not_program += 1;
            continue;
        }
        total += 1;
        if (fixture_count) |limit| {
            if (written < limit and std.mem.eql(u8, got.items, want)) {
                try w.print("{s}\t{s}\n", .{ line, want });
                written += 1;
            }
            continue;
        }
        if (std.mem.eql(u8, got.items, want)) {
            agree += 1;
        } else if (shown < 40) {
            shown += 1;
            try w.print("DIFF flags={s} pattern={f} subject={f}\n  pcre2: {s}\n  zig:   {s}\n", .{
                case.flag_text, std.zig.fmtString(case.pattern), std.zig.fmtString(case.subject), want, got.items,
            });
        }
    }
    if (fixture_count != null) return;
    try w.print("compared {d}: {d} agree, {d} differ; {d} not compiled as programs, {d} PCRE2 errors, {d} zig-regex limits\n", .{
        total, agree, total - agree, not_program, pcre_error, limited,
    });
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var out_buf: [8192]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const w = &out.interface;
    defer w.flush() catch {};
    const cmd: []const u8 = if (args.len >= 2) args[1] else "";
    bt_mode = std.mem.endsWith(u8, cmd, "-bt");
    if (std.mem.eql(u8, cmd, "gen") or std.mem.eql(u8, cmd, "gen-bt")) return genMain(gpa, w, args[2..]);
    if (std.mem.eql(u8, cmd, "check-bt")) return checkMain(gpa, io, w, args[2..]);
    if (std.mem.eql(u8, cmd, "check")) return checkMain(gpa, io, w, args[2..]);
    if (std.mem.eql(u8, cmd, "fixture") or std.mem.eql(u8, cmd, "fixture-bt")) return checkMain(gpa, io, w, args[2..]);
    std.debug.print("usage: pcre2_diff gen <count> <seed> | check <cases.tsv> <spans.tsv> | fixture <cases.tsv> <spans.tsv> <count>\n", .{});
    return error.BadArguments;
}

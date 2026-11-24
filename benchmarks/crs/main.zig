//! The CRS benchmark: every `@rx` pattern of an OWASP CRS checkout, matched
//! against the request values in inputs.txt, the way a WAF matches them.
//! benchmarks/crs/compare.sh runs it next to PCRE2 (pcre2_crs.c).
//!
//!   bench_crs prepare <crs-dir> <work-dir>   write patterns.tsv and inputs.bin
//!   bench_crs run <work-dir> [spans|captures|matcher]  one TSV row per pattern
//!
//! `prepare` reads `rules/*.conf` in name order and keeps each `SecRule`
//! whose operator is `@rx` (or `!@rx`, or a bare pattern, which ModSecurity
//! treats as `@rx`), so no CRS text is vendored here. Rows are named by rule
//! id, with `-chainN` for the Nth chained rule after it.
//!
//! `run` compiles each pattern in byte mode with `dot_all` and `multiline`,
//! the options ModSecurity and zig-waf compile `@rx` with, and calls
//! `isMatch` once per input. `spans` (the default) compiles without captures,
//! as a WAF does for the match test; `captures` compiles with them; `matcher`
//! compiles span-only and matches through one `Regex.Matcher` per pattern,
//! which holds its own lazy DFA (plain `isMatch` takes one from the regex's
//! shared `SearchDfaPool`). A row is
//! name, `ok` or `error:<reason>` (`error:match:<reason>` when a match call
//! failed), one `0`/`1` per input, the best pass in nanoseconds, and the first
//! repetition of the first pass (the pattern's first calls, before anything it
//! builds lazily is warm).
//! A pass matches every input `reps` times and is reported per repetition, so
//! a pattern's time stays well above the clock's resolution.

const std = @import("std");
const Io = std.Io;
const regex = @import("regex");

const inputs_txt = @embedFile("inputs.txt");

/// The options ModSecurity compiles `@rx` with (PCRE2_DOTALL |
/// PCRE2_MULTILINE, no UTF), which zig-waf matches.
const flags: regex.common.CompileFlags = .{ .bytes = true, .dot_all = true, .multiline = true };

/// Each pattern is timed for at least this many passes over every input and
/// at least this long; the best pass is kept.
const min_passes = 5;
const min_window_ns = 10 * std.time.ns_per_ms;
/// Times every input is matched within one pass; pcre2_crs.c uses the same.
const reps = 16;

fn nowNs(io: Io) u64 {
    return @intCast(Io.Timestamp.now(io, .awake).nanoseconds);
}

// ----------------------------------------------------------------- prepare

const Rule = struct { name: []const u8, pattern: []const u8 };

/// Join `\`-newline continuations, as ModSecurity's configuration reader does.
fn joinContinuations(arena: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\' and i + 1 < text.len and text[i + 1] == '\n') {
            i += 1;
            continue;
        }
        if (text[i] == '\\' and i + 2 < text.len and text[i + 1] == '\r' and text[i + 2] == '\n') {
            i += 2;
            continue;
        }
        try out.append(arena, text[i]);
    }
    return out.items;
}

/// Read a double-quoted argument at `s[i.*]`. Inside it `\"` is a quote and
/// every other backslash pair is kept as it is, as ModSecurity reads
/// operator arguments.
fn readQuoted(arena: std.mem.Allocator, s: []const u8, i: *usize) !?[]u8 {
    if (i.* >= s.len or s[i.*] != '"') return null;
    i.* += 1;
    var out: std.ArrayList(u8) = .empty;
    while (i.* < s.len) : (i.* += 1) {
        const c = s[i.*];
        if (c == '\\' and i.* + 1 < s.len) {
            // A backslash and the byte after it are one unit: `\"` is a
            // quote, and `\\` stays two backslashes (so `\\"` still ends
            // the argument at its quote), as ModSecurity reads them.
            if (s[i.* + 1] == '"') {
                try out.append(arena, '"');
            } else {
                try out.appendSlice(arena, s[i.* .. i.* + 2]);
            }
            i.* += 1;
        } else if (c == '"') {
            i.* += 1;
            return out.items;
        } else {
            try out.append(arena, c);
        }
    }
    return error.UnterminatedQuote;
}

fn skipSpace(s: []const u8, i: *usize) void {
    while (i.* < s.len and (s[i.*] == ' ' or s[i.*] == '\t')) i.* += 1;
}

/// The `@rx` pattern of an operator argument, or null for another operator.
fn rxPattern(op: []const u8) ?[]const u8 {
    const body = if (std.mem.startsWith(u8, op, "!")) op[1..] else op;
    if (std.mem.startsWith(u8, body, "@rx ")) return std.mem.trimStart(u8, body[4..], " ");
    if (std.mem.startsWith(u8, body, "@")) return null;
    return body;
}

fn ruleId(actions: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, actions, "id:") orelse return null;
    var end = at + 3;
    while (end < actions.len and std.ascii.isDigit(actions[end])) end += 1;
    if (end == at + 3) return null;
    return actions[at + 3 .. end];
}

fn parseRules(arena: std.mem.Allocator, file_text: []const u8, rules: *std.ArrayList(Rule)) !void {
    const text = try joinContinuations(arena, file_text);
    var parent: []const u8 = "unknown";
    var chain: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "SecRule ")) continue;
        var i: usize = "SecRule ".len;
        skipSpace(line, &i);
        // Variables: unquoted, or quoted when they hold spaces.
        if (i < line.len and line[i] == '"') {
            _ = try readQuoted(arena, line, &i);
        } else {
            while (i < line.len and line[i] != ' ' and line[i] != '\t') i += 1;
        }
        skipSpace(line, &i);
        const op = (try readQuoted(arena, line, &i)) orelse return error.MissingOperator;
        skipSpace(line, &i);
        const actions = (try readQuoted(arena, line, &i)) orelse "";
        const name = if (ruleId(actions)) |id| blk: {
            parent = id;
            chain = 0;
            break :blk id;
        } else blk: {
            chain += 1;
            break :blk try std.fmt.allocPrint(arena, "{s}-chain{d}", .{ parent, chain });
        };
        const pattern = rxPattern(op) orelse continue;
        if (std.mem.indexOfAny(u8, pattern, "\t\n") != null) return error.PatternHasTabOrNewline;
        try rules.append(arena, .{ .name = name, .pattern = pattern });
    }
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Decode one inputs.txt line: `\xHH`, `\t`, `\r`, `\n` and `\\`.
fn decodeInput(arena: std.mem.Allocator, line: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] != '\\' or i + 1 == line.len) {
            try out.append(arena, line[i]);
            continue;
        }
        i += 1;
        switch (line[i]) {
            't' => try out.append(arena, '\t'),
            'r' => try out.append(arena, '\r'),
            'n' => try out.append(arena, '\n'),
            '\\' => try out.append(arena, '\\'),
            'x' => {
                if (i + 3 > line.len) return error.BadEscape;
                try out.append(arena, try std.fmt.parseInt(u8, line[i + 1 .. i + 3], 16));
                i += 2;
            },
            else => return error.BadEscape,
        }
    }
    return out.items;
}

fn prepareMain(arena: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    if (args.len != 2) return error.BadArguments;
    const cwd = Io.Dir.cwd();
    var rules_dir = try cwd.openDir(io, try std.fs.path.join(arena, &.{ args[0], "rules" }), .{ .iterate = true });
    defer rules_dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = rules_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".conf"))
            try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);

    var rules: std.ArrayList(Rule) = .empty;
    for (names.items) |name| {
        const text = try rules_dir.readFileAlloc(io, name, arena, .unlimited);
        try parseRules(arena, text, &rules);
    }

    var tsv: std.ArrayList(u8) = .empty;
    for (rules.items) |r| try tsv.print(arena, "{s}\t{s}\n", .{ r.name, r.pattern });

    var bin: std.ArrayList(u8) = .empty;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, inputs_txt, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const input = try decodeInput(arena, line);
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(input.len), .little);
        try bin.appendSlice(arena, &len);
        try bin.appendSlice(arena, input);
        count += 1;
    }

    try cwd.createDirPath(io, args[1]);
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ args[1], "patterns.tsv" }), .data = tsv.items });
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ args[1], "inputs.bin" }), .data = bin.items });
    std.debug.print("{d} @rx patterns from {d} rule files, {d} inputs\n", .{ rules.items.len, names.items.len, count });
}

// --------------------------------------------------------------------- run

fn readInputs(arena: std.mem.Allocator, bin: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < bin.len) {
        if (bin.len - i < 4) return error.BadInputs;
        const n = std.mem.readInt(u32, bin[i..][0..4], .little);
        i += 4;
        if (bin.len - i < n) return error.BadInputs;
        try list.append(arena, bin[i .. i + n]);
        i += n;
    }
    return list.items;
}

fn runMain(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: Io, w: *Io.Writer, args: []const []const u8) !void {
    if (args.len != 1 and args.len != 2) return error.BadArguments;
    const Mode = enum { spans, captures, matcher };
    const mode: Mode = if (args.len == 2) std.meta.stringToEnum(Mode, args[1]) orelse return error.BadArguments else .spans;
    const captures = mode == .captures;
    const cwd = Io.Dir.cwd();
    const tsv = try cwd.readFileAlloc(io, try std.fs.path.join(arena, &.{ args[0], "patterns.tsv" }), arena, .unlimited);
    const bin = try cwd.readFileAlloc(io, try std.fs.path.join(arena, &.{ args[0], "inputs.bin" }), arena, .unlimited);
    const inputs = try readInputs(arena, bin);
    const hits = try arena.alloc(u8, inputs.len);

    var lines = std.mem.splitScalar(u8, tsv, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.BadPatterns;
        const name = line[0..tab];
        const pattern = line[tab + 1 ..];

        var re = (if (captures)
            regex.Regex.compileWithFlags(gpa, pattern, flags)
        else
            regex.Regex.compileWithoutCaptures(gpa, pattern, flags)) catch |err| {
            try w.print("{s}\terror:{t}\t-\t0\t0\n", .{ name, err });
            try w.flush();
            continue;
        };
        defer re.deinit();
        var m = re.matcher();
        defer m.deinit();

        var best: u64 = std.math.maxInt(u64);
        var first: u64 = 0;
        var failed: ?anyerror = null;
        const start = nowNs(io);
        var passes: usize = 0;
        while (passes < min_passes or nowNs(io) - start < min_window_ns) : (passes += 1) {
            const t0 = nowNs(io);
            for (0..reps) |r| {
                for (inputs, 0..) |input, k| {
                    const hit = (if (mode == .matcher) m.isMatch(input) else re.isMatch(input)) catch |err| {
                        failed = err;
                        break;
                    };
                    hits[k] = if (hit) '1' else '0';
                }
                if (failed != null) break;
                // The very first repetition is the cold one.
                if (passes == 0 and r == 0) first = nowNs(io) - t0;
            }
            if (failed != null) break;
            best = @min(best, (nowNs(io) - t0) / reps);
        }
        if (failed) |err| {
            try w.print("{s}\terror:match:{t}\t-\t0\t0\n", .{ name, err });
        } else {
            try w.print("{s}\tok\t{s}\t{d}\t{d}\n", .{ name, hits, best, first });
        }
        try w.flush();
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [8192]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const w = &out.interface;
    defer w.flush() catch {};

    if (args.len >= 2 and std.mem.eql(u8, args[1], "prepare")) return prepareMain(arena, io, args[2..]);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "run")) return runMain(arena, gpa, io, w, args[2..]);
    std.debug.print("usage: bench_crs prepare <crs-dir> <work-dir> | run <work-dir> [spans|captures|matcher]\n", .{});
    return error.BadArguments;
}

test "a chained rule takes its parent's id" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rules: std.ArrayList(Rule) = .empty;
    try parseRules(arena,
        \\# SecRule ARGS "@rx commented" "id:1"
        \\SecRule ARGS "@rx a\"b" \
        \\    "id:942100,phase:2,chain"
        \\    SecRule MATCHED_VAR "!@rx ^x$" "t:none"
        \\SecRule ARGS "@pm one two" "id:942101"
        \\SecRule ARGS "^bare$" "id:942102"
        \\
    , &rules);
    try std.testing.expectEqual(@as(usize, 3), rules.items.len);
    try std.testing.expectEqualStrings("942100", rules.items[0].name);
    try std.testing.expectEqualStrings("a\"b", rules.items[0].pattern);
    try std.testing.expectEqualStrings("942100-chain1", rules.items[1].name);
    try std.testing.expectEqualStrings("^x$", rules.items[1].pattern);
    try std.testing.expectEqualStrings("942102", rules.items[2].name);
    try std.testing.expectEqualStrings("^bare$", rules.items[2].pattern);
}

test "a backslash pair before the closing quote does not escape it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rules: std.ArrayList(Rule) = .empty;
    try parseRules(arena,
        \\SecRule ARGS "@rx a\\" "id:1"
        \\SecRule ARGS "@rx \x5c\"b" "id:2"
        \\
    , &rules);
    try std.testing.expectEqual(@as(usize, 2), rules.items.len);
    try std.testing.expectEqualStrings("a\\\\", rules.items[0].pattern);
    try std.testing.expectEqualStrings("1", rules.items[0].name);
    try std.testing.expectEqualStrings("\\x5c\"b", rules.items[1].pattern);
}

test "inputs decode their escapes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("a\tb\x00\\", try decodeInput(arena_state.allocator(), "a\\tb\\x00\\\\"));
}

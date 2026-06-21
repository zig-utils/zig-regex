//! Differential / invariant tests for anchored and line-oriented searching.
//!
//! These guard the fast paths that special-case `^…`/`…$` patterns (and the
//! multiline line-start skipping) by asserting the cross-API invariants that
//! must hold for *every* pattern and input regardless of which engine path is
//! taken:
//!
//!   * count(input)        == findAll(input).len
//!   * isMatch(input)      == (find(input) != null)
//!   * find(input).start   == findAll(input)[0].start   (when any match)
//!
//! A break in any of these means an optimized path disagrees with the general
//! engine — exactly the class of bug a hand-written example would miss.

const std = @import("std");
const regex = @import("regex");
const Regex = regex.Regex;

const Flags = struct { multiline: bool = false, case_insensitive: bool = false };

fn checkInvariants(pattern: []const u8, input: []const u8, flags: Flags) !void {
    const allocator = std.testing.allocator;
    var re = try Regex.compileWithFlags(allocator, pattern, .{
        .multiline = flags.multiline,
        .case_insensitive = flags.case_insensitive,
    });
    defer re.deinit();

    const n = try re.count(input);

    const matches = try re.findAll(allocator, input);
    defer {
        for (matches) |*m| {
            var mm = m;
            mm.deinit(allocator);
        }
        allocator.free(matches);
    }

    const is = try re.isMatch(input);
    var first = try re.find(input);
    defer if (first) |*f| f.deinit(allocator);

    // count() and findAll() must agree on the number of non-overlapping matches.
    if (n != matches.len) {
        std.debug.print(
            "MISMATCH count vs findAll: pattern=\"{s}\" ml={} ci={} input=\"{s}\" count={d} findAll={d}\n",
            .{ pattern, flags.multiline, flags.case_insensitive, input, n, matches.len },
        );
        return error.CountFindAllMismatch;
    }

    // isMatch() and find() must agree on whether anything matched.
    try std.testing.expectEqual(is, first != null);
    try std.testing.expectEqual(is, matches.len > 0);

    // The first match must agree across find() and findAll().
    if (first) |f| {
        try std.testing.expectEqual(f.start, matches[0].start);
        try std.testing.expectEqual(f.end, matches[0].end);
    }
}

// Patterns chosen to exercise leading `^`, trailing `$`, both, word boundaries,
// dot-star, fixed repeats, and alternations — the shapes that hit the anchored
// and line-oriented fast paths.
const patterns = [_][]const u8{
    "^",
    "$",
    "^$",
    "^a",
    "a$",
    "^a$",
    "^abc",
    "abc$",
    "^abc$",
    "^.+$",
    ".+$",
    "^.*$",
    "^\\w+$",
    "^\\w+\\s+\\w+$",
    "\\w+\\s+\\w+",
    "^\\s*pub",
    "^//",
    "fn\\s+\\w+",
    "^fn\\s+\\w+|\\w+\\s+fn$",
    "^\\d+$",
    "\\bword\\b",
    "^\\W*$",
    "^x?$",
    "^(ab)+$",
    "^a{2,4}$",
    "end$",
    "^start",
};

const inputs = [_][]const u8{
    "",
    "\n",
    "a",
    "a\n",
    "\na",
    "abc",
    "abc\ndef\nghi",
    "abc\ndef\nghi\n",
    "\n\n\n",
    "fn main\nfn foo\npub fn bar",
    "  pub fn x\n//comment\nword here\n",
    "a b\nc d\ne f",
    "x\r\ny\r\n",
    "trailing no newline",
    "123\n456\n\n789",
    "the word boundary word test",
    "end\nthe end\nend",
    "start of line\nnot start",
    "aaaa\nbb\naaaaaa",
    "ab\nabab\nababab",
};

test "anchored search invariants: count == findAll across patterns/inputs" {
    for (patterns) |p| {
        for (inputs) |in| {
            checkInvariants(p, in, .{ .multiline = true }) catch |err| {
                std.debug.print("  (multiline) failed on pattern=\"{s}\"\n", .{p});
                return err;
            };
            checkInvariants(p, in, .{ .multiline = false }) catch |err| {
                std.debug.print("  (single-line) failed on pattern=\"{s}\"\n", .{p});
                return err;
            };
        }
    }
}

test "death-skip soundness: trailing-dollar match starts inside a leading class run" {
    // `\w+\s+\w+$` matches "fn fn" at offset 3 of "fn fn fn" (last word at EOL),
    // even though a match attempt at offset 0 fails. The DFA death-skip must not
    // jump past offset 3. Regression for the assertion-aware dfaFailSkip.
    try checkInvariants("\\w+\\s+\\w+$", "fn fn fn", .{ .multiline = true });
    try checkInvariants("\\w+\\s+\\w+$", "a b c d e", .{ .multiline = true });
    try checkInvariants("\\d+$", "12 34 56", .{ .multiline = true });
    try checkInvariants("\\w+@\\w+\\.\\w+$", "x a@b.com", .{ .multiline = true });

    const allocator = std.testing.allocator;
    var re = try Regex.compileWithFlags(allocator, "\\w+\\s+\\w+$", .{ .multiline = true });
    defer re.deinit();
    try std.testing.expect(try re.isMatch("fn fn fn"));
    var m = try re.find("fn fn fn");
    defer if (m) |*mm| mm.deinit(allocator);
    try std.testing.expect(m != null);
    try std.testing.expectEqualStrings("fn fn", m.?.slice);
    try std.testing.expectEqual(@as(usize, 1), try re.count("fn fn fn"));
}

test "countMatchingLines agrees with per-line reference" {
    const allocator = std.testing.allocator;
    // The whole-buffer literal fast path and the general per-line path must both
    // equal a naive per-line isMatch reference.
    const cases = [_]struct { pat: []const u8, in: []const u8 }{
        .{ .pat = "fn", .in = "fn x\nyfn\nno\nfn\n" }, // literal fast path
        .{ .pat = "fn", .in = "" },
        .{ .pat = "fn", .in = "nofnhere" },
        .{ .pat = "fn", .in = "fn\nfn\nfn" }, // no trailing newline
        .{ .pat = "abc", .in = "xabcy\nab c\nabc" },
        .{ .pat = "\\w+\\s+\\w+", .in = "a b\nc\nd e f\n" }, // general path
        .{ .pat = "^\\d+$", .in = "12\nx3\n45\n" },
        .{ .pat = "\\bfn\\b", .in = "fn\nxfn\nfn x\n" },
        // Required-literal prefilter paths (rare literal in each match).
        .{ .pat = "\\w+@\\w+", .in = "a@b\nno at here\nx@y z\n@bad\ngood@\n" },
        .{ .pat = "\\d+\\.\\d+", .in = "3.14\nfoo.bar\n1.2.3\nno dot\n.5\n" },
        .{ .pat = "fn\\s+\\w+", .in = "fn main\nxfn y\nfn\nfn  go\n" },
        .{ .pat = "\\w+:\\w+", .in = "a:b\nno colon\n:x\ny:\nk:v here\n" },
    };
    for (cases) |c| {
        var re = try Regex.compileWithFlags(allocator, c.pat, .{ .multiline = true });
        defer re.deinit();
        const got = try re.countMatchingLines(c.in);

        var expected: usize = 0;
        var it = std.mem.splitScalar(u8, c.in, '\n');
        while (it.next()) |line| {
            if (try re.isMatch(line)) expected += 1;
        }
        if (got != expected) {
            std.debug.print("countMatchingLines mismatch pat=\"{s}\" in=\"{s}\": got={d} expected={d}\n", .{ c.pat, c.in, got, expected });
            return error.LineCountMismatch;
        }
    }
}

test "forMatchingLines yields the same lines countMatchingLines counts" {
    const allocator = std.testing.allocator;
    // forMatchingLines must visit exactly the matching lines (in order) that a
    // naive per-line reference selects, across every fast path: literal,
    // required-literal prefilter, unanchored DFA, and the anchored per-line DFA.
    const cases = [_]struct { pat: []const u8, in: []const u8 }{
        .{ .pat = "fn", .in = "fn x\nyfn\nno\nfn\n" },
        .{ .pat = "fn", .in = "fn\nfn\nfn" },
        .{ .pat = "\\w+\\s+\\w+", .in = "a b\nc\nd e f\n" },
        .{ .pat = "^\\w+\\s+\\w+$", .in = "a b\nc d e\nx\nfoo bar\n" },
        .{ .pat = ".+$", .in = "abc\n\nxyz\n" },
        .{ .pat = "[A-Z]+", .in = "Foo\nbar\nBAZ qux\n" },
        .{ .pat = "fn\\s+\\w+", .in = "fn main\nxfn y\nfn\nfn  go\n" },
        .{ .pat = "\\w+@\\w+", .in = "a@b\nno at here\nx@y z\n@bad\ngood@\n" },
    };
    const Collector = struct {
        lines: *std.ArrayList([]const u8),
        alloc: std.mem.Allocator,
        data: []const u8,
        fn emit(self: *@This(), ls: usize, le: usize) anyerror!void {
            try self.lines.append(self.alloc, self.data[ls..le]);
        }
    };
    for (cases) |c| {
        var re = try Regex.compileWithFlags(allocator, c.pat, .{ .multiline = true });
        defer re.deinit();

        var got: std.ArrayList([]const u8) = .empty;
        defer got.deinit(allocator);
        var collector = Collector{ .lines = &got, .alloc = allocator, .data = c.in };
        try re.forMatchingLines(c.in, &collector, Collector.emit);

        var expected: std.ArrayList([]const u8) = .empty;
        defer expected.deinit(allocator);
        var it = std.mem.splitScalar(u8, c.in, '\n');
        while (it.next()) |line| {
            if (try re.isMatch(line)) try expected.append(allocator, line);
        }

        try std.testing.expectEqual(expected.items.len, got.items.len);
        for (expected.items, got.items) |e, g| try std.testing.expectEqualStrings(e, g);
        // And the count must agree with countMatchingLines.
        try std.testing.expectEqual(try re.countMatchingLines(c.in), got.items.len);
    }
}

test "countMatchingLinesParallel equals serial" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const lines = [_][]const u8{ "fn main", "  pub fn x", "// comment", "word here too", "", "a b c", "nope", "fn fn fn" };
    var i: usize = 0;
    while (i < 60000) : (i += 1) {
        try buf.appendSlice(allocator, lines[i % lines.len]);
        try buf.append(allocator, '\n');
    }
    const input = buf.items;
    const pats = [_][]const u8{ "fn", "\\w+\\s+\\w+", "fn\\s+\\w+|\\w+\\s+fn", "^fn", "\\bfn\\b", "\\d+" };
    for (pats) |p| {
        var re = try Regex.compileWithFlags(allocator, p, .{ .multiline = true });
        defer re.deinit();
        const serial = try re.countMatchingLines(input);
        const parallel = try re.countMatchingLinesParallel(input);
        if (serial != parallel) {
            std.debug.print("parallel mismatch pat=\"{s}\": serial={d} parallel={d}\n", .{ p, serial, parallel });
            return error.ParallelMismatch;
        }
    }
}

test "anchored search invariants: case-insensitive" {
    const ci_patterns = [_][]const u8{ "^fn", "FN$", "^Pub\\s+Fn$", "^\\w+$" };
    const ci_inputs = [_][]const u8{ "FN\nfn\nFn", "PUB FN\npub fn", "Hello\nWORLD" };
    for (ci_patterns) |p| {
        for (ci_inputs) |in| {
            try checkInvariants(p, in, .{ .multiline = true, .case_insensitive = true });
            try checkInvariants(p, in, .{ .multiline = false, .case_insensitive = true });
        }
    }
}

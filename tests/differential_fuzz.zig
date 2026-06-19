//! Generative differential fuzzer for engine self-consistency.
//!
//! For every (pattern, input, flags) triple we assert the invariants that must
//! hold no matter which internal path (exact-literal, repeat-atom, literal-set,
//! bounded-literal, one-pass, lazy DFA, NFA, backtracker) services the call:
//!
//!   1. count(input)            == findAll(input).len
//!   2. isMatch(input)          == (find(input) != null)
//!   3. find(input).{start,end} == findAll(input)[0].{start,end}
//!   4. findAll matches are ordered, non-overlapping, in-bounds, and each
//!      slice equals input[start..end].
//!
//! Patterns are assembled from components deliberately chosen to land on the
//! byte-scanning fast paths (literals, alternations, `\w+`/`{m,n}` repeats)
//! while wrapped in `^`/`$` anchors — the shape that previously let a fast path
//! disagree with the general engine.

const std = @import("std");
const Regex = @import("regex").Regex;

const Flags = struct { multiline: bool, case_insensitive: bool };

fn checkConsistency(pattern: []const u8, input: []const u8, flags: Flags) !void {
    const allocator = std.testing.allocator;
    var re = Regex.compileWithFlags(allocator, pattern, .{
        .multiline = flags.multiline,
        .case_insensitive = flags.case_insensitive,
    }) catch return; // invalid pattern combos are skipped
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

    if (n != matches.len or
        is != (first != null) or
        is != (matches.len > 0))
    {
        std.debug.print(
            "INCONSISTENT pattern=\"{s}\" ml={} ci={} input=\"{s}\": count={d} findAll={d} isMatch={} find={}\n",
            .{ pattern, flags.multiline, flags.case_insensitive, input, n, matches.len, is, first != null },
        );
        return error.Inconsistent;
    }

    if (first) |f| {
        try std.testing.expectEqual(f.start, matches[0].start);
        try std.testing.expectEqual(f.end, matches[0].end);
    }

    // Structural checks on findAll.
    var prev_end: usize = 0;
    for (matches, 0..) |m, idx| {
        try std.testing.expect(m.start <= m.end);
        try std.testing.expect(m.end <= input.len);
        try std.testing.expectEqualStrings(input[m.start..m.end], m.slice);
        if (idx > 0) try std.testing.expect(m.start >= prev_end); // non-overlapping, ordered
        prev_end = m.end;
    }
}

// Pattern fragments that exercise the byte-scanning fast paths.
const cores = [_][]const u8{
    "a",       "ab",     "abc",
    "x",       "fn",     "foo",
    "\\w",     "\\w+",   "\\w{2}",
    "\\w{2,3}", "\\d+",  "[a-c]+",
    ".",       ".+",     ".*",
    "a+",      "a*",     "a?",
    "ab+",     "(ab)+",  "a{2}",
    "foo|bar", "a|bc",   "(a|b)+",
    "\\s",     "\\s+",   "\\bfn\\b",
};

const lead = [_][]const u8{ "", "^" };
const trail = [_][]const u8{ "", "$" };

const inputs = [_][]const u8{
    "",
    "a",
    "abc",
    "abcabc",
    "fn fn fn",
    "the fn here",
    "aaa bbb ccc",
    "a\nb\nc",
    "abc\ndef\nghi",
    "foo\nbar\nbaz",
    "x\r\ny\r\nz",
    "  ab  cd  ",
    "123 456 789",
    "\n\n",
    "a1b2c3",
    "fnfnfn",
    "trailing",
    "ab\nabc\nabcd",
    "no match here zzz",
    "aXbXc",
};

test "differential fuzz: anchored fast-path consistency" {
    var checked: usize = 0;
    for (lead) |l| {
        for (cores) |c| {
            for (trail) |t| {
                var buf: [64]u8 = undefined;
                const pattern = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ l, c, t }) catch continue;
                for (inputs) |in| {
                    inline for (.{ true, false }) |ml| {
                        try checkConsistency(pattern, in, .{ .multiline = ml, .case_insensitive = false });
                        checked += 1;
                    }
                }
            }
        }
    }
    try std.testing.expect(checked > 1000);
}

test "differential fuzz: two-core concatenations with anchors" {
    const c2 = [_][]const u8{ "\\w+\\s+\\w+", "fn\\s+\\w+", "\\d+\\.\\d+", "a+b+", "[a-z]+ [a-z]+" };
    for (lead) |l| {
        for (c2) |c| {
            for (trail) |t| {
                var buf: [64]u8 = undefined;
                const pattern = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ l, c, t }) catch continue;
                for (inputs) |in| {
                    inline for (.{ true, false }) |ml| {
                        try checkConsistency(pattern, in, .{ .multiline = ml, .case_insensitive = false });
                    }
                }
            }
        }
    }
}

test "differential fuzz: case-insensitive anchored consistency" {
    const ci_cores = [_][]const u8{ "fn", "abc", "\\w+", "foo|bar", "a+", "FN", "[a-c]+" };
    const ci_inputs = [_][]const u8{ "FN fn Fn", "ABC\nabc\nAbC", "FOO bar BAZ", "AaAa", "" };
    for (lead) |l| {
        for (ci_cores) |c| {
            for (trail) |t| {
                var buf: [64]u8 = undefined;
                const pattern = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ l, c, t }) catch continue;
                for (ci_inputs) |in| {
                    inline for (.{ true, false }) |ml| {
                        try checkConsistency(pattern, in, .{ .multiline = ml, .case_insensitive = true });
                    }
                }
            }
        }
    }
}

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

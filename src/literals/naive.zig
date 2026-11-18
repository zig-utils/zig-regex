//! Naive reference matchers, the oracle for the differential tests and the
//! baseline for the benchmarks. Quadratic and allocation-happy on purpose:
//! every line is obviously correct.

const std = @import("std");
const types = @import("types.zig");

const Pattern = types.Pattern;
const Match = types.Match;
const Options = types.Options;

fn occursAt(hay: []const u8, pos: usize, lit: []const u8, opts: Options) bool {
    if (pos + lit.len > hay.len) return false;
    for (lit, hay[pos..][0..lit.len]) |a, b| {
        const x = if (opts.ascii_case_insensitive) std.ascii.toLower(a) else a;
        const y = if (opts.ascii_case_insensitive) std.ascii.toLower(b) else b;
        if (x != y) return false;
    }
    return true;
}

/// Order matches by start, then end, then pattern id.
pub fn lessThan(_: void, a: Match, b: Match) bool {
    if (a.start != b.start) return a.start < b.start;
    if (a.end != b.end) return a.end < b.end;
    return a.pattern < b.pattern;
}

/// Every occurrence of every non-empty pattern, sorted by `lessThan`.
pub fn allMatches(gpa: std.mem.Allocator, patterns: []const Pattern, hay: []const u8, opts: Options) ![]Match {
    var out: std.ArrayList(Match) = .empty;
    errdefer out.deinit(gpa);
    for (0..hay.len + 1) |pos| {
        for (patterns) |p| {
            if (p.bytes.len == 0) continue;
            if (occursAt(hay, pos, p.bytes, opts))
                try out.append(gpa, .{ .pattern = p.id, .start = pos, .end = pos + p.bytes.len });
        }
    }
    std.mem.sort(Match, out.items, {}, lessThan);
    return out.toOwnedSlice(gpa);
}

/// The match with the smallest start at or after `from`; among those, the
/// pattern that comes first in `patterns`.
pub fn leftmostFirst(patterns: []const Pattern, hay: []const u8, from: usize, opts: Options) ?Match {
    var pos = from;
    while (pos <= hay.len) : (pos += 1) {
        for (patterns) |p| {
            if (p.bytes.len == 0) continue;
            if (occursAt(hay, pos, p.bytes, opts))
                return .{ .pattern = p.id, .start = pos, .end = pos + p.bytes.len };
        }
    }
    return null;
}

/// Non-overlapping leftmost-longest matches: at each step the smallest start,
/// then the longest pattern there, then the first such pattern in `patterns`;
/// the next search starts at that match's end.
pub fn leftmostLongest(gpa: std.mem.Allocator, patterns: []const Pattern, hay: []const u8, opts: Options) ![]Match {
    var out: std.ArrayList(Match) = .empty;
    errdefer out.deinit(gpa);
    var pos: usize = 0;
    while (pos <= hay.len) {
        var best: ?Match = null;
        for (patterns) |p| {
            if (p.bytes.len == 0) continue;
            if (!occursAt(hay, pos, p.bytes, opts)) continue;
            if (best == null or p.bytes.len > best.?.end - best.?.start)
                best = .{ .pattern = p.id, .start = pos, .end = pos + p.bytes.len };
        }
        if (best) |m| {
            try out.append(gpa, m);
            pos = m.end;
        } else pos += 1;
    }
    return out.toOwnedSlice(gpa);
}

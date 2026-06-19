//! Reverse-NFA construction — the foundation for an inner-literal prefilter.
//!
//! For sparse patterns with a required inner literal that sits behind an
//! unbounded prefix (e.g. the `fn` in `\w+\s+fn`, the `@` in `\w+@\w+`), the
//! plan is: scan forward for the literal (SIMD memchr/memmem), then for each
//! occurrence find the match *start* by matching backwards. Matching backwards
//! is exactly running a forward automaton over the reversed input — so we build
//! a reverse NFA here and drive it with the existing `LazyDfa`.
//!
//! Reversal flips every transition `u --x--> v` into `v --x--> u`, adds a fresh
//! start state with epsilon edges to each forward accepting state, and makes the
//! forward start state accepting. Empty-width anchors swap orientation
//! (`start_line` <-> `end_line`, `start_text` <-> `end_text`); word boundaries
//! are symmetric. Captures are dropped — the reverse pass is used only to locate
//! match starts, never to report groups.
//!
//! This module is intentionally standalone and fully unit-tested before being
//! wired into the search paths, so it cannot regress the live engine.

const std = @import("std");
const compiler = @import("compiler.zig");
const common = @import("common.zig");
const ast = @import("ast.zig");

const NFA = compiler.NFA;
const Transition = compiler.Transition;
const StateId = compiler.StateId;

fn swapAnchor(a: ast.AnchorType) ast.AnchorType {
    return switch (a) {
        .start_line => .end_line,
        .end_line => .start_line,
        .start_text => .end_text,
        .end_text => .start_text,
        .word_boundary => .word_boundary,
        .non_word_boundary => .non_word_boundary,
    };
}

/// A reverse transition of `t` (which originally pointed at some `v`) that now
/// points back at `from`. char-class ranges are duplicated so the reverse NFA
/// owns them; captures are dropped.
fn reverseTransition(allocator: std.mem.Allocator, t: Transition, from: StateId) !Transition {
    return switch (t.transition_type) {
        .epsilon => Transition.epsilon(from),
        .char => Transition.char(t.data.char, from),
        .any => Transition.any(from),
        .anchor => Transition.anchor(swapAnchor(t.data.anchor), from),
        .char_class => try Transition.charClass(allocator, t.data.char_class, from),
    };
}

/// Build the reverse NFA of `fwd`. The result recognizes the reversal of `fwd`'s
/// language: a string `s` matches the reverse NFA iff `reverse(s)` matches the
/// forward NFA. Caller owns the returned NFA and must `deinit` it.
pub fn buildReverse(allocator: std.mem.Allocator, fwd: *NFA) !NFA {
    var rev = NFA.init(allocator);
    errdefer rev.deinit();

    // One reverse state per forward state (same indices), then a new start.
    for (fwd.states.items) |_| _ = try rev.addState();
    const new_start = try rev.addState();
    rev.start_state = new_start;

    // Flip every edge u --x--> v into v --x--> u.
    for (fwd.states.items, 0..) |st, u| {
        for (st.transitions.items) |t| {
            const rt = try reverseTransition(allocator, t, u);
            try rev.getState(t.to).addTransition(rt);
        }
    }

    // New start reaches (epsilon) every forward accepting state...
    for (fwd.states.items, 0..) |st, i| {
        if (st.is_accepting) try rev.getState(new_start).addTransition(Transition.epsilon(i));
    }
    // ...and the forward start becomes the (sole) reverse accepting state.
    try rev.markAccepting(fwd.start_state);

    return rev;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const dfa = @import("dfa.zig");

/// Compile `pattern` to a forward NFA via the public Regex path, then return its
/// reverse NFA. The forward Regex is returned too so the caller keeps its NFA
/// alive (the reverse NFA borrows nothing, but the forward must outlive use).
fn reverseOf(allocator: std.mem.Allocator, re: *@import("regex.zig").Regex) !NFA {
    return buildReverse(allocator, @constCast(&re.nfa));
}

fn reversedAlloc(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| out[s.len - 1 - i] = c;
    return out;
}

const Regex = @import("regex.zig").Regex;

/// The reverse DFA, run over reversed input, must accept exactly when the
/// forward pattern matches the original — anchored at both ends here (whole
/// string), which isolates the construction from search/leftmost concerns.
fn expectReverseWholeMatch(pattern: []const u8, input: []const u8, should_match: bool) !void {
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, pattern);
    defer re.deinit();
    // Only meaningful for DFA-representable patterns.
    if (re.engine_type != .thompson_nfa) return;

    var rev = try reverseOf(allocator, &re);
    defer rev.deinit();

    var d = try dfa.LazyDfa.init(allocator, &rev, re.flags);
    defer d.deinit();

    const rinput = try reversedAlloc(allocator, input);
    defer allocator.free(rinput);

    // Whole-string match in reverse == whole-string match forward.
    const sc = d.longestMatchFrom(rinput, 0) catch return;
    const matched = if (sc.end) |e| e == rinput.len else false;
    try std.testing.expectEqual(should_match, matched);
}

test "reverse NFA: recognizes reversed language (whole-string)" {
    try expectReverseWholeMatch("abc", "abc", true);
    try expectReverseWholeMatch("abc", "abx", false);
    try expectReverseWholeMatch("a[bc]d", "abd", true);
    try expectReverseWholeMatch("a[bc]d", "acd", true);
    try expectReverseWholeMatch("a[bc]d", "aed", false);
    try expectReverseWholeMatch("\\w+", "hello", true);
    try expectReverseWholeMatch("\\d+", "12345", true);
    try expectReverseWholeMatch("\\d+", "12a45", false);
    try expectReverseWholeMatch("(ab)+", "ababab", true);
    try expectReverseWholeMatch("(ab)+", "ababa", false);
    try expectReverseWholeMatch("foo|bar", "bar", true);
    try expectReverseWholeMatch("foo|bar", "baz", false);
}

test "reverse NFA: longest match from end locates the start" {
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, "\\d+");
    defer re.deinit();
    var rev = try buildReverse(allocator, @constCast(&re.nfa));
    defer rev.deinit();
    var d = try dfa.LazyDfa.init(allocator, &rev, re.flags);
    defer d.deinit();

    // input "ab123cd": the digit run is [2,5). Reversed input is "dc321ba";
    // the run's end (5) maps to reversed offset len-5 = 2. A reverse longest
    // match from offset 2 should consume "321" (length 3) -> the start is 5-3=2.
    const input = "ab123cd";
    const rinput = try reversedAlloc(allocator, input);
    defer allocator.free(rinput);
    const end_pos: usize = 5;
    const sc = try d.longestMatchFrom(rinput, input.len - end_pos);
    try std.testing.expect(sc.end != null);
    const back_len = sc.end.? - (input.len - end_pos);
    try std.testing.expectEqual(@as(usize, 3), back_len); // "123" has length 3
    try std.testing.expectEqual(@as(usize, 2), end_pos - back_len); // start offset
}

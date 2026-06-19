//! Lazy DFA for fast search, now with empty-width assertion support.
//!
//! The Thompson NFA simulation (`vm.matchAt`) pays per-byte thread bookkeeping;
//! this builds an equivalent DFA on demand — each DFA state is a set of NFA
//! states, and each byte is a single cached table lookup. It powers `count`,
//! `isMatch`, and the match-locating half of `find`/`findAll` for all-greedy,
//! capture-free-equivalent patterns where longest-match equals the engine's
//! semantics.
//!
//! Assertions (`^` `$` `\A` `\z` `\b` `\B`, including multiline) are handled the
//! RE2 way: a DFA state carries, in addition to its NFA-state set, the
//! "look-behind" context that was true on entry — whether we're at the start of
//! text, whether the previous byte was a newline, and whether it was a word
//! byte. Each step evaluates the empty-width assertions that hold at the current
//! boundary from (those stored flags, the byte about to be read), follows the
//! enabled anchor transitions, then consumes the byte. A virtual end-of-input
//! symbol (`EOF`, column 256) lets `$`/`\z`/`\b` fire at end of input. Because
//! the boundary assertions are a pure function of (stored flags, current byte),
//! every transition stays keyed on (state, byte) and remains cacheable.
//!
//! Match boundaries are identical to `vm.matchAt`: from a start position it
//! returns the end of the longest match, tracking the last accepting position.

const std = @import("std");
const compiler = @import("compiler.zig");
const common = @import("common.zig");
const ast = @import("ast.zig");

pub const Error = error{ DfaOverflow, OutOfMemory };

const UNCOMPUTED: i32 = -2;
const DEAD: i32 = -1;

/// Transition/accept tables are this wide: 256 byte values plus one virtual
/// end-of-input symbol at index 256.
const EOF: usize = 256;
const ALPHA: usize = 257;

/// Cap on materialized DFA states; beyond this we bail to the NFA. Pathological
/// patterns (huge bounded repeats, many alternations) can blow up the subset
/// construction, so this keeps memory and build time bounded. Assertion context
/// can multiply states by up to the 8 look-behind combinations, so the cap is a
/// little higher than the assertion-free engine needed.
const MAX_STATES: usize = 16384;

// Look-behind flag bits stored per DFA state (the context on entry).
const FLAG_START: u8 = 1; // position 0 of the text
const FLAG_PREV_WORD: u8 = 2; // previous byte was a word byte
const FLAG_PREV_NL: u8 = 4; // previous byte was '\n'

pub const LazyDfa = struct {
    allocator: std.mem.Allocator,
    nfa: *compiler.NFA,
    flags: common.CompileFlags,
    num_states: usize,
    word_count: usize, // bytes per NFA-state-set bitset
    key_len: usize, // word_count + 1 flag byte
    anchored: bool, // NFA contains an anchor transition (else look-behind flags are inert)
    unanchored: bool, // search mode: every step re-seeds the start (implicit `.*` prefix)
    start_closure: []u8, // epsilon closure of the NFA start state (the re-seed set)

    // Flat tables indexed by DFA state for cache-friendly stepping:
    //   trans[state * ALPHA + sym]  -> UNCOMPUTED / DEAD / next state
    //   acc[state * ALPHA + sym]    -> accepting at this position (with this sym)?
    //   acc_state[state]            -> stored set accepts (sym-independent; valid
    //                                  only for anchor-free patterns, where the
    //                                  hot loop reads it instead of the wide acc)
    //   keys[state]                 -> owned (NFA set | flag byte) bitset / map key
    trans: std.ArrayList(i32),
    acc: std.ArrayList(bool),
    acc_state: std.ArrayList(bool),
    keys: std.ArrayList([]u8),
    map: std.StringHashMapUnmanaged(i32), // key bytes -> dfa index

    start_cache: [8]i32, // start state per look-behind flag combination
    overflow: bool,

    // scratch reused across steps
    move_buf: []u8,
    closure_buf: []u8,
    stack: std.ArrayList(usize),

    pub fn init(allocator: std.mem.Allocator, nfa: *compiler.NFA, flags: common.CompileFlags) !LazyDfa {
        return initMode(allocator, nfa, flags, false);
    }

    /// Unanchored search DFA: every step re-seeds the NFA start state, so a single
    /// left-to-right pass finds whether the pattern matches anywhere (an implicit
    /// `.*` prefix). Used by isMatch; correct because existence has no
    /// leftmost/longest subtlety.
    pub fn initSearch(allocator: std.mem.Allocator, nfa: *compiler.NFA, flags: common.CompileFlags) !LazyDfa {
        return initMode(allocator, nfa, flags, true);
    }

    fn initMode(allocator: std.mem.Allocator, nfa: *compiler.NFA, flags: common.CompileFlags, unanchored: bool) !LazyDfa {
        const num_states = nfa.states.items.len;
        const word_count = (num_states + 7) / 8;
        // Look-behind flags only matter when some state has an anchor transition;
        // otherwise keeping them at 0 avoids splitting DFA states by context.
        var anchored = false;
        for (nfa.states.items) |st| {
            for (st.transitions.items) |t| {
                if (t.transition_type == .anchor) {
                    anchored = true;
                    break;
                }
            }
            if (anchored) break;
        }
        var self: LazyDfa = .{
            .allocator = allocator,
            .nfa = nfa,
            .flags = flags,
            .num_states = num_states,
            .word_count = word_count,
            .key_len = word_count + 1,
            .anchored = anchored,
            .unanchored = unanchored,
            .start_closure = try allocator.alloc(u8, word_count),
            .trans = .empty,
            .acc = .empty,
            .acc_state = .empty,
            .keys = .empty,
            .map = .{},
            .start_cache = .{ UNCOMPUTED, UNCOMPUTED, UNCOMPUTED, UNCOMPUTED, UNCOMPUTED, UNCOMPUTED, UNCOMPUTED, UNCOMPUTED },
            .overflow = false,
            .move_buf = try allocator.alloc(u8, word_count),
            .closure_buf = try allocator.alloc(u8, word_count),
            .stack = .empty,
        };
        // Precompute the start state's epsilon closure (the re-seed set for
        // unanchored search). Anchor transitions are deferred to per-step masks,
        // so this is epsilon-only.
        @memset(self.start_closure, 0);
        @memset(self.move_buf, 0);
        bitSet(self.move_buf, nfa.start_state);
        self.closure(self.move_buf, 0, self.start_closure) catch {
            // Fall back to just the start state if scratch closure fails (OOM).
            @memset(self.start_closure, 0);
            bitSet(self.start_closure, nfa.start_state);
        };
        @memset(self.move_buf, 0);
        return self;
    }

    pub fn deinit(self: *LazyDfa) void {
        for (self.keys.items) |k| self.allocator.free(k);
        self.keys.deinit(self.allocator);
        self.trans.deinit(self.allocator);
        self.acc.deinit(self.allocator);
        self.acc_state.deinit(self.allocator);
        self.map.deinit(self.allocator);
        self.allocator.free(self.start_closure);
        self.allocator.free(self.move_buf);
        self.allocator.free(self.closure_buf);
        self.stack.deinit(self.allocator);
    }

    inline fn bitSet(buf: []u8, i: usize) void {
        buf[i >> 3] |= (@as(u8, 1) << @intCast(i & 7));
    }
    inline fn bitTest(buf: []const u8, i: usize) bool {
        return (buf[i >> 3] & (@as(u8, 1) << @intCast(i & 7))) != 0;
    }

    inline fn isWordByte(c: u8) bool {
        return common.CharClasses.word.matches(c);
    }

    /// Bitmask of the empty-width assertions (indexed by `@intFromEnum(AnchorType)`)
    /// that hold at the boundary described by the entry `flags` and the symbol
    /// `sym` about to be read (`sym == EOF` at end of input). Mirrors the anchor
    /// evaluation in `vm.addEpsilonClosure` exactly.
    fn emptyMask(self: *const LazyDfa, flags: u8, sym: usize) u8 {
        const at_start = (flags & FLAG_START) != 0;
        const prev_word = (flags & FLAG_PREV_WORD) != 0;
        const prev_nl = (flags & FLAG_PREV_NL) != 0;
        const at_eof = sym == EOF;

        const begin_text = at_start;
        const end_text = at_eof;
        const begin_line = if (self.flags.multiline) (at_start or prev_nl) else at_start;
        const end_line = if (self.flags.multiline) (at_eof or sym == '\n') else at_eof;
        const cur_word = !at_eof and isWordByte(@intCast(sym));
        const word_boundary = prev_word != cur_word;

        var m: u8 = 0;
        if (begin_line) m |= @as(u8, 1) << @intFromEnum(ast.AnchorType.start_line);
        if (end_line) m |= @as(u8, 1) << @intFromEnum(ast.AnchorType.end_line);
        if (begin_text) m |= @as(u8, 1) << @intFromEnum(ast.AnchorType.start_text);
        if (end_text) m |= @as(u8, 1) << @intFromEnum(ast.AnchorType.end_text);
        if (word_boundary) m |= @as(u8, 1) << @intFromEnum(ast.AnchorType.word_boundary);
        if (!word_boundary) m |= @as(u8, 1) << @intFromEnum(ast.AnchorType.non_word_boundary);
        return m;
    }

    /// Expand `seed` into a closed set in `out`, following epsilon transitions
    /// always and anchor transitions whose assertion bit is set in `mask`. With
    /// `mask == 0` this is the plain epsilon closure (used to store moved sets,
    /// whose anchors are evaluated on the next step instead).
    fn closure(self: *LazyDfa, seed: []const u8, mask: u8, out: []u8) !void {
        @memset(out, 0);
        self.stack.clearRetainingCapacity();
        var i: usize = 0;
        while (i < self.num_states) : (i += 1) {
            if (bitTest(seed, i)) {
                bitSet(out, i);
                try self.stack.append(self.allocator, i);
            }
        }
        while (self.stack.pop()) |id| {
            const state = &self.nfa.states.items[id];
            for (state.transitions.items) |t| {
                switch (t.transition_type) {
                    .epsilon => {
                        if (!bitTest(out, t.to)) {
                            bitSet(out, t.to);
                            try self.stack.append(self.allocator, t.to);
                        }
                    },
                    .anchor => {
                        const bit = @as(u8, 1) << @intFromEnum(t.data.anchor);
                        if (mask & bit != 0 and !bitTest(out, t.to)) {
                            bitSet(out, t.to);
                            try self.stack.append(self.allocator, t.to);
                        }
                    },
                    else => {},
                }
            }
        }
    }

    fn matchesByte(self: *const LazyDfa, t: compiler.Transition, c: u8) bool {
        return switch (t.transition_type) {
            .char => t.data.char == c,
            .any => if (self.flags.dot_all) true else c != '\n',
            .char_class => t.data.char_class.matches(c),
            else => false,
        };
    }

    fn hasAccepting(self: *const LazyDfa, set: []const u8) bool {
        var i: usize = 0;
        while (i < self.num_states) : (i += 1) {
            if (bitTest(set, i) and self.nfa.states.items[i].is_accepting) return true;
        }
        return false;
    }

    /// Maximum supported key length (NFA-set bytes + 1 flag byte) for the
    /// stack-composed lookup key. Larger NFAs bail to the slower engine.
    const MAX_KEY: usize = 2048;

    /// Intern a closed NFA-state set plus look-behind `flags` as a DFA state,
    /// returning its index. May reallocate `trans`/`acc`/`keys` — callers must
    /// re-fetch cached slices afterwards.
    fn intern(self: *LazyDfa, set: []const u8, flags: u8) Error!i32 {
        if (self.key_len > MAX_KEY) {
            self.overflow = true;
            return Error.DfaOverflow;
        }
        // Compose the lookup key = set bytes followed by the flag byte.
        var key_buf: [MAX_KEY]u8 = undefined;
        @memcpy(key_buf[0..self.word_count], set[0..self.word_count]);
        key_buf[self.word_count] = flags;
        const key = key_buf[0..self.key_len];

        if (self.map.get(key)) |idx| return idx;
        if (self.keys.items.len >= MAX_STATES) {
            self.overflow = true;
            return Error.DfaOverflow;
        }
        const owned = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned);

        const idx: i32 = @intCast(self.keys.items.len);
        try self.trans.appendNTimes(self.allocator, UNCOMPUTED, ALPHA);
        try self.acc.appendNTimes(self.allocator, false, ALPHA);
        try self.acc_state.append(self.allocator, self.hasAccepting(set));
        try self.keys.append(self.allocator, owned);
        try self.map.put(self.allocator, owned, idx);
        return idx;
    }

    inline fn stateSet(self: *const LazyDfa, idx: i32) []const u8 {
        return self.keys.items[@intCast(idx)][0..self.word_count];
    }
    inline fn stateFlags(self: *const LazyDfa, idx: i32) u8 {
        return self.keys.items[@intCast(idx)][self.word_count];
    }

    /// Compute and cache the transition and accept bit for `dfa_index` on symbol
    /// `sym` (0..=EOF). Slow path of stepping; may grow the tables.
    fn computeStep(self: *LazyDfa, dfa_index: i32, sym: usize) Error!i32 {
        const flags = self.stateFlags(dfa_index);
        const mask = self.emptyMask(flags, sym);
        // Follow enabled anchors + epsilon from the stored (epsilon-closed) set.
        try self.closure(self.stateSet(dfa_index), mask, self.closure_buf);
        const accept_val = self.hasAccepting(self.closure_buf);

        var result: i32 = DEAD;
        if (sym != EOF) {
            const c: u8 = @intCast(sym);
            // Move on the byte from the anchor-closed set.
            @memset(self.move_buf, 0);
            var any_move = false;
            var i: usize = 0;
            while (i < self.num_states) : (i += 1) {
                if (!bitTest(self.closure_buf, i)) continue;
                for (self.nfa.states.items[i].transitions.items) |t| {
                    if (self.matchesByte(t, c)) {
                        bitSet(self.move_buf, t.to);
                        any_move = true;
                    }
                }
            }
            // Unanchored search re-seeds the start state on every byte so a match
            // may begin at the next position (an implicit `.*` prefix). The seeded
            // states inherit the just-consumed byte's look-behind context.
            if (self.unanchored) {
                var w: usize = 0;
                while (w < self.word_count) : (w += 1) self.move_buf[w] |= self.start_closure[w];
                any_move = true;
            }
            if (any_move) {
                var new_flags: u8 = 0; // not at start after consuming a byte
                if (isWordByte(c)) new_flags |= FLAG_PREV_WORD;
                if (c == '\n') new_flags |= FLAG_PREV_NL;
                // Store the epsilon-only closure of the moved set; its anchors
                // are evaluated on the next step.
                try self.closure(self.move_buf, 0, self.closure_buf);
                result = try self.intern(self.closure_buf, if (self.anchored) new_flags else 0); // may realloc
            }
        }

        self.trans.items[@as(usize, @intCast(dfa_index)) * ALPHA + sym] = result;
        self.acc.items[@as(usize, @intCast(dfa_index)) * ALPHA + sym] = accept_val;
        return result;
    }

    /// Look-behind flags for a scan starting at `start` within `input`. Inert
    /// (always 0) for anchor-free patterns so the DFA isn't split by context.
    fn startFlags(self: *const LazyDfa, input: []const u8, start: usize) u8 {
        if (!self.anchored) return 0;
        var f: u8 = 0;
        if (start == 0) f |= FLAG_START;
        if (start > 0) {
            const prev = input[start - 1];
            if (isWordByte(prev)) f |= FLAG_PREV_WORD;
            if (prev == '\n') f |= FLAG_PREV_NL;
        }
        return f;
    }

    fn getStart(self: *LazyDfa, flags: u8) Error!i32 {
        if (self.start_cache[flags] != UNCOMPUTED) return self.start_cache[flags];
        const seed = self.move_buf; // borrow as scratch
        @memset(seed, 0);
        bitSet(seed, self.nfa.start_state);
        try self.closure(seed, 0, self.closure_buf); // epsilon-only; anchors evaluated per step
        const idx = try self.intern(self.closure_buf, flags);
        self.start_cache[flags] = idx;
        return idx;
    }

    /// Result of an anchored scan: the longest match end (or null), plus `stop` —
    /// the position where the DFA halted (died or end of input).
    pub const Scan = struct { end: ?usize, stop: usize };

    /// Longest match starting at `start` (identical boundaries to `vm.matchAt`),
    /// reporting where the scan stopped. Hot loop caches the flat slices and
    /// re-fetches only when a transition is computed (which may grow them).
    pub fn longestMatchFrom(self: *LazyDfa, input: []const u8, start: usize) Error!Scan {
        const anchored = self.anchored;
        var s: i32 = try self.getStart(self.startFlags(input, start));
        var trans = self.trans.items;
        var acc = self.acc.items;
        var acc_state = self.acc_state.items;
        var last: ?usize = null;
        var p = start;
        while (true) {
            const sym: usize = if (p < input.len) input[p] else EOF;
            const row = @as(usize, @intCast(s)) * ALPHA + sym;
            var t = trans[row];
            if (t == UNCOMPUTED) {
                t = try self.computeStep(s, sym);
                trans = self.trans.items; // re-fetch after possible realloc
                acc = self.acc.items;
                acc_state = self.acc_state.items;
            }
            // Anchor-free patterns accept independently of the byte, so read the
            // compact per-state flag instead of the wide per-(state,byte) table.
            const accepting = if (anchored) acc[row] else acc_state[@intCast(s)];
            if (accepting) last = p;
            if (sym == EOF) break;
            if (t == DEAD) break;
            s = t;
            p += 1;
        }
        return .{ .end = last, .stop = p };
    }

    /// Whether the pattern matches anywhere in `input`, in a single left-to-right
    /// pass. Requires an unanchored (search-mode) DFA; the re-seeded start makes
    /// every position a potential match start, so the first accepting state seen
    /// proves a match exists. O(n) regardless of match sparsity.
    pub fn anyMatch(self: *LazyDfa, input: []const u8) Error!bool {
        std.debug.assert(self.unanchored);
        const anchored = self.anchored;
        var s: i32 = try self.getStart(self.startFlags(input, 0));
        var trans = self.trans.items;
        var acc = self.acc.items;
        var acc_state = self.acc_state.items;
        var p: usize = 0;
        while (true) {
            const sym: usize = if (p < input.len) input[p] else EOF;
            const row = @as(usize, @intCast(s)) * ALPHA + sym;
            var t = trans[row];
            if (t == UNCOMPUTED) {
                t = try self.computeStep(s, sym);
                trans = self.trans.items;
                acc = self.acc.items;
                acc_state = self.acc_state.items;
            }
            const accepting = if (anchored) acc[row] else acc_state[@intCast(s)];
            if (accepting) return true;
            if (sym == EOF) return false;
            if (t == DEAD) return false; // only reachable in anchored mode
            s = t;
            p += 1;
        }
    }
};

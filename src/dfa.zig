//! Lazy DFA for fast search on "longest-match-equivalent" patterns.
//!
//! The Thompson NFA simulation (`vm.matchAt`) pays per-byte thread bookkeeping;
//! this builds an equivalent DFA on demand — each DFA state is a set of NFA
//! states, and each byte is a single cached table lookup. It powers `count` and
//! `isMatch` for patterns where longest-match equals the engine's semantics:
//! all-greedy, no anchors / `\b` (position-dependent), no captures needed, and
//! ASCII-exact (not case-insensitive). The caller falls back to the NFA when a
//! pattern isn't eligible or when the DFA would grow past `MAX_STATES`.
//!
//! Match boundaries are identical to `vm.matchAt`: from a start position it
//! returns the end of the longest match, tracking the last accepting position.

const std = @import("std");
const compiler = @import("compiler.zig");
const common = @import("common.zig");

pub const Error = error{ DfaOverflow, OutOfMemory };

const UNCOMPUTED: i32 = -2;
const DEAD: i32 = -1;

/// Cap on materialized DFA states; beyond this we bail to the NFA. Pathological
/// patterns (huge bounded repeats, many alternations) can blow up the subset
/// construction, so this keeps memory and build time bounded.
const MAX_STATES: usize = 8192;

pub const LazyDfa = struct {
    allocator: std.mem.Allocator,
    nfa: *compiler.NFA,
    flags: common.CompileFlags,
    num_states: usize,
    word_count: usize, // bytes per state-set bitset

    // Flat tables indexed by DFA state for cache-friendly stepping:
    //   trans[state * 256 + byte] -> UNCOMPUTED / DEAD / next state
    //   acc[state]                -> accepting?
    //   keys[state]               -> owned NFA-state-set bitset (also map key)
    trans: std.ArrayList(i32),
    acc: std.ArrayList(bool),
    keys: std.ArrayList([]u8),
    map: std.StringHashMapUnmanaged(i32), // bitset bytes -> dfa index

    start_index: i32, // UNCOMPUTED until first use
    overflow: bool,

    // scratch reused across steps
    move_buf: []u8,
    closure_buf: []u8,
    stack: std.ArrayList(usize),

    pub fn init(allocator: std.mem.Allocator, nfa: *compiler.NFA, flags: common.CompileFlags) !LazyDfa {
        const num_states = nfa.states.items.len;
        const word_count = (num_states + 7) / 8;
        return .{
            .allocator = allocator,
            .nfa = nfa,
            .flags = flags,
            .num_states = num_states,
            .word_count = word_count,
            .trans = .empty,
            .acc = .empty,
            .keys = .empty,
            .map = .{},
            .start_index = UNCOMPUTED,
            .overflow = false,
            .move_buf = try allocator.alloc(u8, word_count),
            .closure_buf = try allocator.alloc(u8, word_count),
            .stack = .empty,
        };
    }

    pub fn deinit(self: *LazyDfa) void {
        for (self.keys.items) |k| self.allocator.free(k);
        self.keys.deinit(self.allocator);
        self.trans.deinit(self.allocator);
        self.acc.deinit(self.allocator);
        self.map.deinit(self.allocator);
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

    /// Expand `seed` state ids by epsilon transitions into `out` (a closed set).
    /// Returns error.DfaOverflow if an anchor transition is encountered (the
    /// DFA can't represent position assertions — caller should not have built it
    /// for such a pattern, but this is a safety net).
    fn closure(self: *LazyDfa, seed: []const u8, out: []u8) Error!void {
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
                    .anchor => return Error.DfaOverflow, // not representable
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

    /// Intern a closed state-set bitset as a DFA state, returning its index.
    /// May reallocate `trans`/`acc`/`keys` — callers must re-fetch cached slices.
    fn intern(self: *LazyDfa, key_set: []const u8) Error!i32 {
        if (self.map.get(key_set)) |idx| return idx;
        if (self.keys.items.len >= MAX_STATES) {
            self.overflow = true;
            return Error.DfaOverflow;
        }
        const owned = try self.allocator.dupe(u8, key_set);
        errdefer self.allocator.free(owned);

        var is_acc = false;
        var i: usize = 0;
        while (i < self.num_states) : (i += 1) {
            if (bitTest(owned, i) and self.nfa.states.items[i].is_accepting) {
                is_acc = true;
                break;
            }
        }

        const idx: i32 = @intCast(self.keys.items.len);
        try self.trans.appendNTimes(self.allocator, UNCOMPUTED, 256);
        try self.acc.append(self.allocator, is_acc);
        try self.keys.append(self.allocator, owned);
        try self.map.put(self.allocator, owned, idx);
        return idx;
    }

    fn getStart(self: *LazyDfa) Error!i32 {
        if (self.start_index != UNCOMPUTED) return self.start_index;
        const seed = self.move_buf; // borrow as scratch
        @memset(seed, 0);
        bitSet(seed, self.nfa.start_state);
        try self.closure(seed, self.closure_buf);
        self.start_index = try self.intern(self.closure_buf);
        return self.start_index;
    }

    /// Compute and cache the transition from `dfa_index` on byte `c`. Slow path
    /// of stepping; may grow the tables.
    fn computeStep(self: *LazyDfa, dfa_index: i32, c: u8) Error!i32 {
        @memset(self.move_buf, 0);
        var any_move = false;
        // `set` points into the owned key allocation, which survives table growth.
        const set = self.keys.items[@intCast(dfa_index)];
        var i: usize = 0;
        while (i < self.num_states) : (i += 1) {
            if (!bitTest(set, i)) continue;
            for (self.nfa.states.items[i].transitions.items) |t| {
                if (self.matchesByte(t, c)) {
                    bitSet(self.move_buf, t.to);
                    any_move = true;
                }
            }
        }
        var result: i32 = DEAD;
        if (any_move) {
            try self.closure(self.move_buf, self.closure_buf);
            result = try self.intern(self.closure_buf); // may realloc tables
        }
        self.trans.items[@as(usize, @intCast(dfa_index)) * 256 + c] = result;
        return result;
    }

    /// Result of an anchored scan: the longest match end (or null), plus `stop` —
    /// the position where the DFA halted (died or end of input).
    pub const Scan = struct { end: ?usize, stop: usize };

    /// Longest match starting at `start` (identical boundaries to `vm.matchAt`),
    /// reporting where the scan stopped. Hot loop caches the flat slices and
    /// re-fetches only when a transition is computed (which may grow them).
    pub fn longestMatchFrom(self: *LazyDfa, input: []const u8, start: usize) Error!Scan {
        var s: usize = @intCast(try self.getStart());
        var trans = self.trans.items;
        var acc = self.acc.items;
        var last: ?usize = if (acc[s]) start else null;
        var p = start;
        while (p < input.len) {
            var ns = trans[s * 256 + input[p]];
            if (ns == UNCOMPUTED) {
                ns = try self.computeStep(@intCast(s), input[p]);
                trans = self.trans.items; // re-fetch after possible realloc
                acc = self.acc.items;
            }
            if (ns == DEAD) break;
            s = @intCast(ns);
            p += 1;
            if (acc[s]) last = p;
        }
        return .{ .end = last, .stop = p };
    }
};

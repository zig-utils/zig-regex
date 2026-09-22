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
//! ECMAScript's multiline `^`/`$` also treat CR, U+2028 and U+2029 as line
//! terminators. U+2028/U+2029 are three WTF-8 bytes (`E2 80 A8/A9`), so a
//! second virtual symbol (`LT_LEAD`, column 257) stands for an `E2` that starts
//! one — giving `$` its look-ahead — and two transient look-behind bits carry
//! the triple through its last byte, where `^` becomes true.
//!
//! Match boundaries are identical to `vm.matchAt`: from a start position it
//! returns the end of the longest match, tracking the last accepting position.
//!
//! ECMAScript is leftmost-first, not leftmost-longest (`/ab|abcd/` matches
//! "ab" in "abcd"), so a match-end DFA for an `ecmascript` pattern runs in
//! `ordered` mode, the way RE2's DFA does for leftmost-first search: a state is
//! the priority-ordered list of NFA states its threads resume at, each step
//! recomputes that list's closure depth-first in transition order -- with the
//! VM's empty-iteration rule -- and the closure stops at the first accepting
//! state, dropping every lower-priority thread. The search DFA behind
//! `anyMatch` only asks whether a match exists, which does not depend on
//! priority, so it keeps the unordered sets.

const std = @import("std");
const compiler = @import("compiler.zig");
const common = @import("common.zig");
const ast = @import("ast.zig");

pub const Error = error{ DfaOverflow, OutOfMemory };

const UNCOMPUTED: i32 = -2;
const DEAD: i32 = -1;

// Transition encoding for the branch-reduced hot loop. A computed transition is
// non-negative: bits 0..29 hold the target state id, bit 30 is set when the
// target is an (anchor-free) accepting state. So the common case — a normal,
// non-accepting transition — is a single `0 <= t < ACCEPT_BIT` test that skips
// the dead / uncomputed / accept handling entirely.
const ACCEPT_BIT: i32 = 1 << 30;
const STATE_MASK: i32 = ACCEPT_BIT - 1;

/// Transition/accept tables are this wide: 256 byte values, a virtual
/// end-of-input symbol at index 256, and at 257 a virtual symbol for an `E2`
/// byte that starts U+2028 or U+2029 (read only when `ecma_lines` is set).
const EOF: usize = 256;
const LT_LEAD: usize = 257;
const ALPHA: usize = 258;

/// Cap on materialized DFA states; beyond this we bail to the NFA. Pathological
/// patterns (huge bounded repeats, many alternations) can blow up the subset
/// construction, so this keeps memory and build time bounded. Assertion context
/// can multiply states by the look-behind combinations (8, and at most 32 with
/// ECMAScript line anchors, where the two transient bits occur only inside a
/// U+2028/U+2029 triple), so the cap is a little higher than the assertion-free
/// engine needed.
const MAX_STATES: usize = 16384;

// Look-behind flag bits stored per DFA state (the context on entry).
const FLAG_START: u8 = 1; // position 0 of the text
const FLAG_PREV_WORD: u8 = 2; // previous byte was a word byte
const FLAG_PREV_NL: u8 = 4; // previous character was a line terminator
// Under `ecma_lines` only: inside U+2028/U+2029, after its first (LT2) or
// second (LT1) byte. The third byte turns them into FLAG_PREV_NL.
const FLAG_LT2: u8 = 8;
const FLAG_LT1: u8 = 16;

pub const LazyDfa = struct {
    allocator: std.mem.Allocator,
    nfa: *compiler.NFA,
    flags: common.CompileFlags,
    num_states: usize,
    word_count: usize, // bytes per NFA-state-set bitset
    key_len: usize, // word_count + 1 flag byte
    anchored: bool, // NFA contains an anchor transition (else look-behind flags are inert)
    // ECMAScript multiline `^`/`$`: CR, U+2028 and U+2029 end lines as '\n' does.
    ecma_lines: bool,
    unanchored: bool, // search mode: every step re-seeds the start (implicit `.*` prefix)
    // Leftmost-first match ends (ECMAScript): states are ordered NFA-state
    // lists keyed as [flags][u32 ids...], not bitsets.
    ordered: bool,
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
    // State acceleration: a state that loops to itself on a large non-accepting
    // byte set (a `\w+`/`\s+` run) skips that run with one tight membership loop.
    // Built lazily — only once a state is observed self-looping mid-scan — so
    // non-self-loop states (e.g. `\w{5}`'s) pay nothing. kind[s]: 0 unknown,
    // 1 not-accelerable, 2 accelerable (set[s] is the self-loop byte set).
    accel_kind: std.ArrayList(u8),
    accel_set: std.ArrayList([256]bool),
    keys: std.ArrayList([]u8),
    map: std.StringHashMapUnmanaged(i32), // key bytes -> dfa index

    start_cache: [32]i32, // start state per look-behind flag combination
    overflow: bool,

    // scratch reused across steps
    move_buf: []u8,
    closure_buf: []u8,
    stack: std.ArrayList(usize),
    // ordered-mode scratch: the depth-first frames, the quantifier loops each
    // path entered since the last consumed byte, and two NFA-state lists
    ostack: std.ArrayList(OFrame),
    ochain: std.ArrayList(OLink),
    olist: std.ArrayList(u32),
    onext: std.ArrayList(u32),

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
        var line_anchor = false;
        for (nfa.states.items) |st| {
            for (st.transitions.items) |t| {
                if (t.transition_type == .anchor) {
                    anchored = true;
                    if (t.data.anchor == .start_line or t.data.anchor == .end_line) line_anchor = true;
                }
            }
        }
        var self: LazyDfa = .{
            .allocator = allocator,
            .nfa = nfa,
            .flags = flags,
            .num_states = num_states,
            .word_count = word_count,
            .key_len = word_count + 1,
            .anchored = anchored,
            .ordered = flags.ecmascript and !unanchored,
            .ecma_lines = flags.ecmascript and flags.multiline and line_anchor,
            .unanchored = unanchored,
            .start_closure = try allocator.alloc(u8, word_count),
            .trans = .empty,
            .acc = .empty,
            .acc_state = .empty,
            .accel_kind = .empty,
            .accel_set = .empty,
            .keys = .empty,
            .map = .{},
            .start_cache = @splat(UNCOMPUTED),
            .overflow = false,
            .move_buf = try allocator.alloc(u8, word_count),
            .closure_buf = try allocator.alloc(u8, word_count),
            .stack = .empty,
            .ostack = .empty,
            .ochain = .empty,
            .olist = .empty,
            .onext = .empty,
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
        self.accel_kind.deinit(self.allocator);
        self.accel_set.deinit(self.allocator);
        self.map.deinit(self.allocator);
        self.allocator.free(self.start_closure);
        self.allocator.free(self.move_buf);
        self.allocator.free(self.closure_buf);
        self.stack.deinit(self.allocator);
        self.ostack.deinit(self.allocator);
        self.ochain.deinit(self.allocator);
        self.olist.deinit(self.allocator);
        self.onext.deinit(self.allocator);
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
        const end_line = if (self.flags.multiline)
            (at_eof or sym == '\n' or (self.ecma_lines and (sym == '\r' or sym == LT_LEAD)))
        else
            at_eof;
        const cur_word = sym < 256 and isWordByte(@intCast(sym));
        const word_boundary = prev_word != cur_word;

        var m: u8 = 0;
        if (begin_line) m |= @as(u8, 1) << @backingInt(ast.AnchorType.start_line);
        if (end_line) m |= @as(u8, 1) << @backingInt(ast.AnchorType.end_line);
        if (begin_text) m |= @as(u8, 1) << @backingInt(ast.AnchorType.start_text);
        if (end_text) m |= @as(u8, 1) << @backingInt(ast.AnchorType.end_text);
        if (word_boundary) m |= @as(u8, 1) << @backingInt(ast.AnchorType.word_boundary);
        if (!word_boundary) m |= @as(u8, 1) << @backingInt(ast.AnchorType.non_word_boundary);
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
                        const bit = @as(u8, 1) << @backingInt(t.data.anchor);
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
        try self.accel_kind.append(self.allocator, 0);
        try self.accel_set.append(self.allocator, undefined);
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
        if (self.ordered) return self.computeStepOrdered(dfa_index, sym);
        const flags = self.stateFlags(dfa_index);
        const mask = self.emptyMask(flags, sym);
        // Follow enabled anchors + epsilon from the stored (epsilon-closed) set.
        try self.closure(self.stateSet(dfa_index), mask, self.closure_buf);
        const accept_val = self.hasAccepting(self.closure_buf);

        var result: i32 = DEAD;
        if (sym != EOF) {
            const c: u8 = if (sym == LT_LEAD) 0xE2 else @intCast(sym);
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
                if (self.ecma_lines) {
                    if (c == '\r') {
                        new_flags |= FLAG_PREV_NL;
                    } else if (sym == LT_LEAD) {
                        new_flags |= FLAG_LT2;
                    } else if (flags & FLAG_LT2 != 0 and c == 0x80) {
                        new_flags |= FLAG_LT1;
                    } else if (flags & FLAG_LT1 != 0 and (c == 0xA8 or c == 0xA9)) {
                        new_flags |= FLAG_PREV_NL;
                    }
                }
                // Store the epsilon-only closure of the moved set; its anchors
                // are evaluated on the next step.
                try self.closure(self.move_buf, 0, self.closure_buf);
                result = try self.intern(self.closure_buf, if (self.anchored) new_flags else 0); // may realloc
            }
        }

        // Fold the target's (anchor-free) accept flag into the stored value so the
        // hot loop needs no separate accept lookup. DEAD stays negative.
        var stored = result;
        if (result != DEAD and self.acc_state.items[@intCast(result)]) stored = result | ACCEPT_BIT;
        self.trans.items[@as(usize, @intCast(dfa_index)) * ALPHA + sym] = stored;
        self.acc.items[@as(usize, @intCast(dfa_index)) * ALPHA + sym] = accept_val;
        return stored;
    }

    const no_link: u32 = std.math.maxInt(u32);
    const OLink = struct { loop: u32, parent: u32 };
    const OFrame = struct { state: u32, chain: u32 };

    /// An ordered-mode state's look-behind flags and NFA-state list.
    inline fn orderedFlags(self: *const LazyDfa, idx: i32) u8 {
        return self.keys.items[@intCast(idx)][0];
    }
    inline fn orderedIds(self: *const LazyDfa, idx: i32) []align(1) const u32 {
        const key = self.keys.items[@intCast(idx)];
        return std.mem.bytesAsSlice(u32, key[1..]);
    }

    /// Intern a priority-ordered NFA-state list with look-behind `flags`.
    fn internOrdered(self: *LazyDfa, ids: []const u32, flags: u8) Error!i32 {
        const len = 1 + ids.len * @sizeOf(u32);
        if (len > MAX_KEY) {
            self.overflow = true;
            return Error.DfaOverflow;
        }
        var key_buf: [MAX_KEY]u8 = undefined;
        key_buf[0] = flags;
        @memcpy(key_buf[1..len], std.mem.sliceAsBytes(ids));
        const key = key_buf[0..len];

        if (self.map.get(key)) |idx| return idx;
        if (self.keys.items.len >= MAX_STATES) {
            self.overflow = true;
            return Error.DfaOverflow;
        }
        const owned = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned);
        // Whether arriving here is a match, for the anchor-free hot loop (whose
        // closure does not depend on the next symbol).
        const accepts = try self.closureOrdered(ids, 0, null);

        const idx: i32 = @intCast(self.keys.items.len);
        try self.trans.appendNTimes(self.allocator, UNCOMPUTED, ALPHA);
        try self.acc.appendNTimes(self.allocator, false, ALPHA);
        try self.acc_state.append(self.allocator, accepts);
        try self.accel_kind.append(self.allocator, 0);
        try self.accel_set.append(self.allocator, undefined);
        try self.keys.append(self.allocator, owned);
        try self.map.put(self.allocator, owned, idx);
        return idx;
    }

    /// The closure of `seeds` in priority order: each seed's epsilon and
    /// enabled-anchor successors depth-first in transition order, a state kept
    /// for the first path that reaches it. The consuming states go to `out` in
    /// that order. Returns true, and stops, at the first accepting state: every
    /// state after it has lower priority, and leftmost-first drops them. A
    /// path that ends a quantifier iteration it entered without consuming is
    /// dropped without claiming the state (RepeatMatcher, 22.2.2.3.1), as in
    /// `vm.matchAtLeftmostFirst`.
    fn closureOrdered(self: *LazyDfa, seeds: []align(1) const u32, mask: u8, out: ?*std.ArrayList(u32)) Error!bool {
        if (out) |o| o.clearRetainingCapacity();
        const visited = self.closure_buf;
        @memset(visited, 0);
        self.ochain.clearRetainingCapacity();
        for (seeds) |seed| {
            self.ostack.clearRetainingCapacity();
            try self.ostack.append(self.allocator, .{ .state = seed, .chain = no_link });
            while (self.ostack.pop()) |frame| {
                const id: usize = frame.state;
                if (bitTest(visited, id)) continue;
                const state = &self.nfa.states.items[id];
                if (state.loop_exit) |loop| {
                    if (self.orderedChainHas(frame.chain, loop)) continue;
                }
                bitSet(visited, id);
                if (state.is_accepting) return true;
                var consuming = false;
                var t = state.transitions.items.len;
                while (t > 0) {
                    t -= 1;
                    const tr = state.transitions.items[t];
                    const follow = switch (tr.transition_type) {
                        .epsilon => true,
                        .anchor => mask & (@as(u8, 1) << @backingInt(tr.data.anchor)) != 0,
                        else => blk: {
                            consuming = true;
                            break :blk false;
                        },
                    };
                    if (!follow or bitTest(visited, tr.to)) continue;
                    var chain = frame.chain;
                    if (tr.enters_loop) |loop| {
                        try self.ochain.append(self.allocator, .{ .loop = loop, .parent = chain });
                        chain = @intCast(self.ochain.items.len - 1);
                    }
                    try self.ostack.append(self.allocator, .{ .state = @intCast(tr.to), .chain = chain });
                }
                if (consuming) if (out) |o| try o.append(self.allocator, @intCast(id));
            }
        }
        return false;
    }

    fn orderedChainHas(self: *const LazyDfa, chain: u32, loop: u32) bool {
        var link = chain;
        while (link != no_link) {
            const node = self.ochain.items[link];
            if (node.loop == loop) return true;
            link = node.parent;
        }
        return false;
    }

    /// `computeStep` for ordered mode: close the state's list at this boundary,
    /// then move its consuming states on the byte, in order, keeping the first
    /// arrival at each target.
    fn computeStepOrdered(self: *LazyDfa, dfa_index: i32, sym: usize) Error!i32 {
        const flags = self.orderedFlags(dfa_index);
        const mask = self.emptyMask(flags, sym);
        const accept_val = try self.closureOrdered(self.orderedIds(dfa_index), mask, &self.olist);

        var result: i32 = DEAD;
        if (sym != EOF) {
            const c: u8 = if (sym == LT_LEAD) 0xE2 else @intCast(sym);
            self.onext.clearRetainingCapacity();
            @memset(self.move_buf, 0);
            for (self.olist.items) |id| {
                for (self.nfa.states.items[id].transitions.items) |tr| {
                    if (!self.matchesByte(tr, c) or bitTest(self.move_buf, tr.to)) continue;
                    bitSet(self.move_buf, tr.to);
                    try self.onext.append(self.allocator, @intCast(tr.to));
                }
            }
            if (self.onext.items.len != 0) {
                var new_flags: u8 = 0;
                if (isWordByte(c)) new_flags |= FLAG_PREV_WORD;
                if (c == '\n') new_flags |= FLAG_PREV_NL;
                if (self.ecma_lines) {
                    if (c == '\r') {
                        new_flags |= FLAG_PREV_NL;
                    } else if (sym == LT_LEAD) {
                        new_flags |= FLAG_LT2;
                    } else if (flags & FLAG_LT2 != 0 and c == 0x80) {
                        new_flags |= FLAG_LT1;
                    } else if (flags & FLAG_LT1 != 0 and (c == 0xA8 or c == 0xA9)) {
                        new_flags |= FLAG_PREV_NL;
                    }
                }
                result = try self.internOrdered(self.onext.items, if (self.anchored) new_flags else 0); // may realloc
            }
        }

        var stored = result;
        if (result != DEAD and self.acc_state.items[@intCast(result)]) stored = result | ACCEPT_BIT;
        self.trans.items[@as(usize, @intCast(dfa_index)) * ALPHA + sym] = stored;
        self.acc.items[@as(usize, @intCast(dfa_index)) * ALPHA + sym] = accept_val;
        return stored;
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
            if (self.ecma_lines) {
                // A scan can begin inside U+2028/U+2029; the bits carry `^` to
                // the byte after its last one.
                if (common.lineTerminatorBefore(input, start, self.flags)) {
                    f |= FLAG_PREV_NL;
                } else if (common.isLsPsAt(input, start - 1)) {
                    f |= FLAG_LT2;
                } else if (start >= 2 and common.isLsPsAt(input, start - 2)) {
                    f |= FLAG_LT1;
                }
            }
        }
        return f;
    }

    /// The table column for `input[p]`: `LT_LEAD` for an `E2` that starts
    /// U+2028/U+2029 when ECMAScript line anchors need to see it, else the byte.
    inline fn symAt(self: *const LazyDfa, input: []const u8, p: usize) usize {
        const c = input[p];
        if (c == 0xE2 and self.ecma_lines and common.isLsPsAt(input, p)) return LT_LEAD;
        return c;
    }

    fn getStart(self: *LazyDfa, flags: u8) Error!i32 {
        if (self.start_cache[flags] != UNCOMPUTED) return self.start_cache[flags];
        if (self.ordered) {
            const idx = try self.internOrdered(&[_]u32{@intCast(self.nfa.start_state)}, flags);
            self.start_cache[flags] = idx;
            return idx;
        }
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
        var s: i32 = try self.getStart(self.startFlags(input, start));
        var last: ?usize = null;
        var p = start;

        if (!self.anchored) {
            // Branch-reduced hot loop: accept and dead are folded into the stored
            // transition value, so the common step is a single signed compare.
            var trans = self.trans.items;
            if (self.acc_state.items[@intCast(s)]) last = start; // empty/start match
            while (p < input.len) {
                const t = trans[@as(usize, @intCast(s)) * ALPHA + input[p]];
                if (t < 0) {
                    if (t == UNCOMPUTED) {
                        _ = try self.computeStep(s, input[p]);
                        trans = self.trans.items; // re-fetch after possible realloc
                        continue; // re-read the now-computed cell
                    }
                    break; // DEAD
                }
                s = t & STATE_MASK;
                p += 1;
                if (t >= ACCEPT_BIT) last = p; // arrived in an accepting state
            }
            return .{ .end = last, .stop = p };
        }

        // Anchored: acceptance is byte-dependent (assertions), so consult the
        // wide accept table and evaluate the EOF column for trailing `$`/`\b`.
        var trans = self.trans.items;
        var acc = self.acc.items;
        while (true) {
            const sym: usize = if (p < input.len) self.symAt(input, p) else EOF;
            const row = @as(usize, @intCast(s)) * ALPHA + sym;
            var t = trans[row];
            if (t == UNCOMPUTED) {
                t = try self.computeStep(s, sym);
                trans = self.trans.items;
                acc = self.acc.items;
            }
            if (acc[row]) last = p;
            if (sym == EOF) break;
            if (t == DEAD) break;
            s = t & STATE_MASK;
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
        var s: i32 = try self.getStart(self.startFlags(input, 0));
        var p: usize = 0;

        if (!self.anchored) {
            var trans = self.trans.items;
            if (self.acc_state.items[@intCast(s)]) return true;
            while (p < input.len) {
                const t = trans[@as(usize, @intCast(s)) * ALPHA + input[p]];
                if (t < 0) {
                    if (t == UNCOMPUTED) {
                        _ = try self.computeStep(s, input[p]);
                        trans = self.trans.items;
                        continue;
                    }
                    return false; // DEAD (rare under re-seeded search)
                }
                s = t & STATE_MASK;
                p += 1;
                if (t >= ACCEPT_BIT) return true;
            }
            return false;
        }

        var trans = self.trans.items;
        var acc = self.acc.items;
        while (true) {
            const sym: usize = if (p < input.len) self.symAt(input, p) else EOF;
            const row = @as(usize, @intCast(s)) * ALPHA + sym;
            var t = trans[row];
            if (t == UNCOMPUTED) {
                t = try self.computeStep(s, sym);
                trans = self.trans.items;
                acc = self.acc.items;
            }
            if (acc[row]) return true;
            if (sym == EOF) return false;
            if (t == DEAD) return false;
            s = t & STATE_MASK;
            p += 1;
        }
    }

    /// Count newline-delimited lines containing a match, in a single pass over
    /// the buffer — no per-line call/setup overhead. Requires an anchor-free
    /// unanchored search DFA (the caller checks `!anchored`): the start state is
    /// the same for every line, the search re-seed means a line never dies, and
    /// matches never cross a '\n' (each line is scanned over [ls, le) only). For
    /// each line, memchr finds the line end, then the DFA steps until a match
    /// (early exit) — so matching lines cost only their prefix.
    /// Record state `s`'s self-loop byte set (the bytes that stay in `s` without
    /// accepting) so the hot loop can skip such runs. Materializes its 256
    /// transitions once. Marks `s` non-accelerable if too few bytes loop.
    fn prepAccel(self: *LazyDfa, s: usize) Error!void {
        var set: [256]bool = undefined;
        var loops: usize = 0;
        var c: usize = 0;
        while (c < 256) : (c += 1) {
            if (self.trans.items[s * ALPHA + c] == UNCOMPUTED) _ = try self.computeStep(@intCast(s), c);
            const t = self.trans.items[s * ALPHA + c];
            const is_self = t >= 0 and t < ACCEPT_BIT and (t & STATE_MASK) == @as(i32, @intCast(s));
            set[c] = is_self;
            if (is_self) loops += 1;
        }
        if (loops >= 32) {
            self.accel_set.items[s] = set;
            self.accel_kind.items[s] = 2;
        } else {
            self.accel_kind.items[s] = 1;
        }
    }

    /// `prepAccel` for an assertion-bearing (anchored) DFA, where acceptance is
    /// byte-dependent and lives in `acc` rather than folded into the transition.
    /// A byte is skippable only if it self-loops AND does not accept at that
    /// position — so skipping the run can't miss a match (e.g. the `.` run in
    /// `.+$`, which only accepts at EOF).
    fn prepAccelAnchored(self: *LazyDfa, s: usize) Error!void {
        var set: [256]bool = undefined;
        var loops: usize = 0;
        var c: usize = 0;
        while (c < 256) : (c += 1) {
            const row = s * ALPHA + c;
            if (self.trans.items[row] == UNCOMPUTED) _ = try self.computeStep(@intCast(s), c);
            const t = self.trans.items[row];
            // An `E2` may start U+2028/U+2029, whose column is `LT_LEAD`: never
            // skip one blindly.
            const is_self = t >= 0 and (t & STATE_MASK) == @as(i32, @intCast(s)) and !self.acc.items[row] and
                !(self.ecma_lines and c == 0xE2);
            set[c] = is_self;
            if (is_self) loops += 1;
        }
        if (loops >= 32) {
            self.accel_set.items[s] = set;
            self.accel_kind.items[s] = 2;
        } else {
            self.accel_kind.items[s] = 1;
        }
    }

    pub fn countMatchingLines(self: *LazyDfa, input: []const u8) Error!usize {
        var count: usize = 0;
        const resume_at = try self.forMatchingLines(input, &count, struct {
            fn f(c: *usize, ls: usize, le: usize) Error!void {
                _ = ls;
                _ = le;
                c.* += 1;
            }
        }.f);
        // Standalone count is atomic: a mid-scan overflow can't be resumed here,
        // so surface it (the partial count is discarded by the caller).
        if (resume_at != null) return Error.DfaOverflow;
        return count;
    }

    /// Match a single line `[ls, le)` against an anchor-free unanchored search
    /// DFA. Inlined into the fused line loop; returns whether the line matched.
    inline fn lineMatchesUnanchored(
        self: *LazyDfa,
        input: []const u8,
        ls: usize,
        le: usize,
        start_s: usize,
        start_accepts: bool,
    ) Error!bool {
        if (start_accepts) return true;
        var trans = self.trans.items;
        var s = start_s;
        var p = ls;
        while (p < le) {
            // Accelerated state: skip the whole self-loop run at once.
            if (self.accel_kind.items[s] == 2) {
                const set = &self.accel_set.items[s];
                while (p < le and set[input[p]]) p += 1;
                if (p >= le) break;
            }
            const t = trans[s * ALPHA + input[p]];
            if (t == UNCOMPUTED) {
                _ = try self.computeStep(@intCast(s), input[p]);
                trans = self.trans.items;
                continue; // re-read the now-computed cell
            }
            // unanchored search never produces DEAD (start is re-seeded).
            const next: usize = @intCast(t & STATE_MASK);
            p += 1;
            if (t >= ACCEPT_BIT) return true;
            // Lazily promote a state the moment it's seen self-looping, so
            // non-self-loop states never pay the materialization cost.
            if (next == s and self.accel_kind.items[s] == 0) {
                try self.prepAccel(s);
                trans = self.trans.items;
            }
            s = next;
        }
        return false;
    }

    /// Like `countMatchingLines`, but invokes `emit(ctx, line_start, line_end)`
    /// for every matching line instead of counting — the shared engine behind
    /// both the `-c` count path and the print path. `[line_start, line_end)`
    /// excludes the trailing newline. Returns `null` on a complete pass, or the
    /// start offset of the line at which the DFA overflowed (that line and all
    /// after it are *not* reported) so the caller can resume with the general
    /// matcher without double-reporting the lines already emitted.
    pub fn forMatchingLines(
        self: *LazyDfa,
        input: []const u8,
        ctx: anytype,
        comptime emit: anytype,
    ) !?usize {
        std.debug.assert(self.unanchored and !self.anchored);
        const start_i = self.getStart(0) catch |e| switch (e) {
            error.DfaOverflow => return @as(?usize, 0),
            else => return e,
        };
        const start_s: usize = @intCast(start_i);
        const start_accepts = self.acc_state.items[start_s]; // pattern matches empty
        var ls: usize = 0;
        while (true) {
            const le = std.mem.indexOfScalarPos(u8, input, ls, '\n') orelse input.len;
            const matched = self.lineMatchesUnanchored(input, ls, le, start_s, start_accepts) catch |e| switch (e) {
                error.DfaOverflow => return @as(?usize, ls),
                else => return e,
            };
            if (matched) try emit(ctx, ls, le);
            if (le == input.len) break;
            ls = le + 1;
        }
        return null;
    }

    /// Match a single line `[ls, le)` against an assertion-bearing (anchored)
    /// DFA, treating the line as standalone text. Inlined into the fused loop.
    inline fn lineMatchesAnchored(
        self: *LazyDfa,
        input: []const u8,
        ls: usize,
        le: usize,
        start_s: i32,
    ) Error!bool {
        var trans = self.trans.items;
        var acc = self.acc.items;
        var s: i32 = start_s;
        var p = ls;
        while (true) {
            // Accelerated state: skip the whole non-accepting self-loop run.
            if (self.accel_kind.items[@intCast(s)] == 2) {
                const set = &self.accel_set.items[@intCast(s)];
                while (p < le and set[input[p]]) p += 1;
            }
            const sym: usize = if (p < le) self.symAt(input[0..le], p) else EOF;
            const row = @as(usize, @intCast(s)) * ALPHA + sym;
            var t = trans[row];
            if (t == UNCOMPUTED) {
                t = try self.computeStep(s, sym);
                trans = self.trans.items;
                acc = self.acc.items;
            }
            if (acc[row]) return true;
            if (sym == EOF or t == DEAD) return false;
            const next = t & STATE_MASK;
            // Lazily promote the first time a state is seen self-looping.
            if (next == s and self.accel_kind.items[@intCast(s)] == 0) {
                try self.prepAccelAnchored(@intCast(s));
                trans = self.trans.items;
                acc = self.acc.items;
            }
            s = next;
            p += 1;
        }
    }

    /// `forMatchingLines` for an assertion-bearing (anchored) DFA. Each line is
    /// matched as its own standalone text — so `^`/`$` bind to the line edges and
    /// the start flags are constant (`FLAG_START`) for every line — in one fused
    /// pass over the buffer, avoiding the per-line `anyMatch` call/setup overhead.
    /// `emit(ctx, line_start, line_end)` fires for each matching line; ranges
    /// exclude the trailing newline. Overflow handling mirrors `forMatchingLines`.
    pub fn forMatchingLinesAnchored(
        self: *LazyDfa,
        input: []const u8,
        ctx: anytype,
        comptime emit: anytype,
    ) !?usize {
        std.debug.assert(self.anchored);
        // Every line begins a fresh text, so the start state never varies.
        const start_s = self.getStart(self.startFlags(input, 0)) catch |e| switch (e) {
            error.DfaOverflow => return @as(?usize, 0),
            else => return e,
        };
        var ls: usize = 0;
        while (true) {
            const le = std.mem.indexOfScalarPos(u8, input, ls, '\n') orelse input.len;
            const matched = self.lineMatchesAnchored(input, ls, le, start_s) catch |e| switch (e) {
                error.DfaOverflow => return @as(?usize, ls),
                else => return e,
            };
            if (matched) try emit(ctx, ls, le);
            if (le == input.len) break;
            ls = le + 1;
        }
        return null;
    }
};

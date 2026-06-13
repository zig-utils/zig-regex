const std = @import("std");
const compiler = @import("compiler.zig");
const common = @import("common.zig");
const ast = @import("ast.zig");

/// Capture information for a matched group. `matched` is false for a group
/// that did not participate in the match (e.g. an unmatched optional `(x)?`),
/// distinguishing it from a group that matched the empty string.
pub const Capture = struct {
    start: usize,
    end: usize,
    text: []const u8,
    matched: bool = false,
};

/// Result of a successful match
pub const MatchResult = struct {
    start: usize,
    end: usize,
    captures: []Capture,

    pub fn deinit(self: *MatchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.captures);
    }
};

/// Thread in the NFA simulation (represents a possible execution path)
const Thread = struct {
    state: compiler.StateId,
    capture_starts: []?usize,
    capture_ends: []?usize,

    pub fn init(allocator: std.mem.Allocator, state: compiler.StateId, num_captures: usize) !Thread {
        // No capture groups → no per-thread allocation at all. This is the
        // common case (counting / boolean / capture-less patterns) and the hot
        // path of matchAt, which clones a thread per surviving transition.
        if (num_captures == 0) {
            return .{ .state = state, .capture_starts = &.{}, .capture_ends = &.{} };
        }
        const starts = try allocator.alloc(?usize, num_captures);
        const ends = try allocator.alloc(?usize, num_captures);

        @memset(starts, null);
        @memset(ends, null);

        return .{
            .state = state,
            .capture_starts = starts,
            .capture_ends = ends,
        };
    }

    pub fn deinit(self: *Thread, allocator: std.mem.Allocator) void {
        if (self.capture_starts.len != 0) allocator.free(self.capture_starts);
        if (self.capture_ends.len != 0) allocator.free(self.capture_ends);
    }

    pub fn clone(self: *const Thread, allocator: std.mem.Allocator) !Thread {
        const new_thread = try Thread.init(allocator, self.state, self.capture_starts.len);
        @memcpy(new_thread.capture_starts, self.capture_starts);
        @memcpy(new_thread.capture_ends, self.capture_ends);
        return new_thread;
    }
};

/// Virtual Machine for executing NFA
pub const VM = struct {
    nfa: *compiler.NFA,
    allocator: std.mem.Allocator,
    num_captures: usize,
    flags: common.CompileFlags,
    /// Scratch "visited" bitmap for epsilon-closure, allocated once and reused
    /// across every `matchAt`. Sized to the NFA state count. Reuse matters
    /// because `find`/`findAll` call `matchAt` once per input position.
    visited: []bool = &.{},
    /// Reused thread lists for the simulation. Kept on the VM so their backing
    /// capacity survives across the many `matchAt` calls a single `find` /
    /// `findAll` makes, instead of being reallocated each call.
    cur_threads: std.ArrayList(Thread) = .empty,
    nxt_threads: std.ArrayList(Thread) = .empty,
    /// Free-list of reusable capture buffers (each `num_captures` long). Thread
    /// cloning in the hot loop otherwise allocates and frees two of these per
    /// surviving transition; pooling removes that malloc churn for capture
    /// patterns.
    cap_pool: std.ArrayList([]?usize) = .empty,

    pub fn init(allocator: std.mem.Allocator, nfa: *compiler.NFA, num_captures: usize, flags: common.CompileFlags) VM {
        return .{
            .nfa = nfa,
            .allocator = allocator,
            .num_captures = num_captures,
            .flags = flags,
        };
    }

    /// Release scratch buffers. Safe to call on a VM that never ran.
    pub fn deinit(self: *VM) void {
        if (self.visited.len != 0) self.allocator.free(self.visited);
        self.visited = &.{};
        self.clearThreadList(&self.cur_threads);
        self.clearThreadList(&self.nxt_threads);
        self.cur_threads.deinit(self.allocator);
        self.nxt_threads.deinit(self.allocator);
        for (self.cap_pool.items) |buf| self.allocator.free(buf);
        self.cap_pool.deinit(self.allocator);
    }

    /// Take a capture buffer from the pool, or allocate one.
    fn acquireCaps(self: *VM) ![]?usize {
        if (self.cap_pool.pop()) |buf| return buf;
        return try self.allocator.alloc(?usize, self.num_captures);
    }

    /// Return a capture buffer to the pool (or free it if the pool can't grow).
    fn releaseCaps(self: *VM, buf: []?usize) void {
        self.cap_pool.append(self.allocator, buf) catch self.allocator.free(buf);
    }

    /// Create a fresh thread (capture slots cleared), using pooled buffers.
    fn newThread(self: *VM, state: compiler.StateId) !Thread {
        if (self.num_captures == 0) return .{ .state = state, .capture_starts = &.{}, .capture_ends = &.{} };
        const s = try self.acquireCaps();
        errdefer self.releaseCaps(s);
        const e = try self.acquireCaps();
        @memset(s, null);
        @memset(e, null);
        return .{ .state = state, .capture_starts = s, .capture_ends = e };
    }

    /// Clone a thread (copying capture slots), using pooled buffers.
    fn cloneThread(self: *VM, t: Thread) !Thread {
        if (self.num_captures == 0) return .{ .state = t.state, .capture_starts = &.{}, .capture_ends = &.{} };
        const s = try self.acquireCaps();
        errdefer self.releaseCaps(s);
        const e = try self.acquireCaps();
        @memcpy(s, t.capture_starts);
        @memcpy(e, t.capture_ends);
        return .{ .state = t.state, .capture_starts = s, .capture_ends = e };
    }

    /// Return a thread's capture buffers to the pool.
    fn freeThread(self: *VM, t: *Thread) void {
        if (t.capture_starts.len != 0) self.releaseCaps(t.capture_starts);
        if (t.capture_ends.len != 0) self.releaseCaps(t.capture_ends);
    }

    /// Free the per-thread state in a list and reset its length (keeping the
    /// backing capacity for reuse by the next matchAt).
    fn clearThreadList(self: *VM, list: *std.ArrayList(Thread)) void {
        for (list.items) |*thread| self.freeThread(thread);
        list.clearRetainingCapacity();
    }

    /// Helper to compare characters with case-insensitive support
    fn charsMatch(self: *const VM, pattern_char: u8, input_char: u8) bool {
        if (!self.flags.case_insensitive) {
            return pattern_char == input_char;
        }

        // Convert both to lowercase for comparison
        const p_lower = if (pattern_char >= 'A' and pattern_char <= 'Z')
            pattern_char + ('a' - 'A')
        else
            pattern_char;

        const i_lower = if (input_char >= 'A' and input_char <= 'Z')
            input_char + ('a' - 'A')
        else
            input_char;

        return p_lower == i_lower;
    }

    fn applyTransitionCaptures(self: *const VM, thread: *Thread, transition: compiler.Transition, pos: usize) void {
        for (transition.clear_captures) |cap_idx| {
            if (cap_idx > 0 and cap_idx <= self.num_captures) {
                thread.capture_starts[cap_idx - 1] = null;
                thread.capture_ends[cap_idx - 1] = null;
            }
        }

        const state = self.nfa.getState(transition.to);
        if (state.capture_start) |cap_idx| {
            if (cap_idx > 0 and cap_idx <= self.num_captures) {
                thread.capture_starts[cap_idx - 1] = pos;
            }
        }
        if (state.capture_end) |cap_idx| {
            if (cap_idx > 0 and cap_idx <= self.num_captures) {
                thread.capture_ends[cap_idx - 1] = pos;
            }
        }
    }

    /// Check if the pattern matches at a specific position in the input
    pub fn matchAt(self: *VM, input: []const u8, start_pos: usize) !?MatchResult {
        // Borrow the VM's reusable thread lists (empty on entry) and hand them
        // back — threads freed, capacity retained — when done. This keeps the
        // backing buffers alive across the many matchAt calls per find/findAll.
        var current_threads = self.cur_threads;
        var next_threads = self.nxt_threads;
        defer {
            self.clearThreadList(&current_threads);
            self.clearThreadList(&next_threads);
            self.cur_threads = current_threads;
            self.nxt_threads = next_threads;
        }

        // Visited bitmap for epsilon closure — reused across matchAt calls
        // (grown once to the state count) rather than reallocated per position.
        const num_states = self.nfa.states.items.len;
        if (self.visited.len < num_states) {
            if (self.visited.len != 0) self.allocator.free(self.visited);
            self.visited = try self.allocator.alloc(bool, num_states);
        }
        const visited_buf = self.visited[0..num_states];

        // Start with initial thread at start state
        var initial_thread = try self.newThread(self.nfa.start_state);

        // Check if initial state has capture markers
        const initial_state = self.nfa.getState(self.nfa.start_state);
        if (initial_state.capture_start) |cap_idx| {
            if (cap_idx > 0 and cap_idx <= self.num_captures) {
                initial_thread.capture_starts[cap_idx - 1] = start_pos;
            }
        }
        if (initial_state.capture_end) |cap_idx| {
            if (cap_idx > 0 and cap_idx <= self.num_captures) {
                initial_thread.capture_ends[cap_idx - 1] = start_pos;
            }
        }

        try current_threads.append(self.allocator, initial_thread);

        // Process epsilon closures for initial state
        try self.addEpsilonClosure(&current_threads, start_pos, input, visited_buf);

        var pos = start_pos;
        var last_match: ?MatchResult = null;

        while (pos <= input.len) {
            // Check if any thread is in an accepting state - save it but continue for greedy matching
            for (current_threads.items) |*thread| {
                const state = self.nfa.getState(thread.state);
                if (state.is_accepting) {
                    // Free previous match if any
                    if (last_match) |*prev| {
                        self.allocator.free(prev.captures);
                    }

                    // Save this match (might be overwritten by a longer match).
                    // Every capture slot is initialized — a group that did not
                    // participate stays `matched=false` (rather than holding
                    // uninitialized memory).
                    var captures = try self.allocator.alloc(Capture, self.num_captures);
                    for (0..self.num_captures) |i| {
                        captures[i] = Capture{ .start = 0, .end = 0, .text = "", .matched = false };
                        if (thread.capture_starts[i]) |cap_start| {
                            if (thread.capture_ends[i]) |cap_end| {
                                captures[i] = Capture{
                                    .start = cap_start,
                                    .end = cap_end,
                                    .text = input[cap_start..cap_end],
                                    .matched = true,
                                };
                            }
                        }
                    }

                    last_match = MatchResult{
                        .start = start_pos,
                        .end = pos,
                        .captures = captures,
                    };
                    break; // Found at least one, continue to see if we can match more
                }
            }

            if (pos >= input.len) break;

            const c = input[pos];

            // Process all current threads
            for (current_threads.items) |*thread| {
                const state = self.nfa.getState(thread.state);

                for (state.transitions.items) |transition| {
                    const matches = switch (transition.transition_type) {
                        .char => self.charsMatch(transition.data.char, c),
                        .any => if (self.flags.dot_all)
                            true
                        else
                            c != '\n',
                        .char_class => if (self.flags.case_insensitive)
                            transition.data.char_class.matchesCI(c)
                        else
                            transition.data.char_class.matches(c),
                        .anchor => false, // Anchors don't consume input
                        .epsilon => false, // Already handled in epsilon closure
                    };

                    if (matches) {
                        var new_thread = try self.cloneThread(thread.*);
                        new_thread.state = transition.to;
                        self.applyTransitionCaptures(&new_thread, transition, pos + 1);

                        try next_threads.append(self.allocator, new_thread);
                    }
                }
            }

            // Process epsilon closures for next threads
            try self.addEpsilonClosure(&next_threads, pos + 1, input, visited_buf);

            // Swap thread lists
            const tmp = current_threads;
            current_threads = next_threads;
            next_threads = tmp;

            // Clear next threads for next iteration
            self.clearThreadList(&next_threads);

            pos += 1;

            // No live threads remain. matchAt only ever seeds the start-state
            // thread (at start_pos), and threads can only be spawned by cloning
            // existing ones, so once the set is empty no further match can
            // begin from this start_pos — the longest match found so far
            // (last_match) is final. Without this break the loop walks every
            // remaining byte doing nothing; because findAll restarts matchAt
            // per match, that dead-walk is what makes findAll O(n^2). Any
            // accepting state reached on the consumed input was already
            // recorded by the accept check at the top of the loop.
            if (current_threads.items.len == 0) break;
        }

        // Return the last (longest) match we found
        return last_match;
    }

    /// Find the first match anywhere in the input
    pub fn find(self: *VM, input: []const u8) !?MatchResult {
        // Try matching at each position
        var pos: usize = 0;
        while (pos <= input.len) : (pos += 1) {
            if (try self.matchAt(input, pos)) |result| {
                return result;
            }
        }
        return null;
    }

    /// Check if the pattern matches anywhere in the input
    pub fn isMatch(self: *VM, input: []const u8) !bool {
        if (try self.find(input)) |result| {
            defer {
                var mut_result = result;
                mut_result.deinit(self.allocator);
            }
            return true;
        }
        return false;
    }

    /// Add epsilon closure - follow all epsilon transitions
    /// Uses a pre-allocated visited buffer (boolean array indexed by state ID)
    /// to avoid HashMap allocation overhead on every call.
    fn addEpsilonClosure(self: *VM, threads: *std.ArrayList(Thread), pos: usize, input: []const u8, visited: []bool) !void {
        // Reset visited array
        @memset(visited, false);

        var i: usize = 0;
        while (i < threads.items.len) : (i += 1) {
            // IMPORTANT: Pass thread by value to avoid dangling pointer issues
            // when ArrayList reallocates during followEpsilons
            try self.followEpsilons(threads.items[i], threads, visited, pos, input);
        }
    }

    fn followEpsilons(
        self: *VM,
        thread: Thread,
        threads: *std.ArrayList(Thread),
        visited: []bool,
        pos: usize,
        input: []const u8,
    ) !void {
        if (visited[thread.state]) return;
        visited[thread.state] = true;

        const state = self.nfa.getState(thread.state);

        for (state.transitions.items) |transition| {
            switch (transition.transition_type) {
                .epsilon => {
                    // Check if we've already visited this state
                    if (visited[transition.to]) continue;

                    var new_thread = try self.cloneThread(thread);
                    new_thread.state = transition.to;
                    self.applyTransitionCaptures(&new_thread, transition, pos);

                    try threads.append(self.allocator, new_thread);
                    // Don't recurse immediately - let addEpsilonClosure handle it iteratively
                },
                .anchor => {
                    const anchor_type = transition.data.anchor;
                    // Check if anchor matches at current position
                    const anchor_matches = switch (anchor_type) {
                        .start_line => if (self.flags.multiline)
                            pos == 0 or (pos > 0 and input[pos - 1] == '\n')
                        else
                            pos == 0,
                        .end_line => if (self.flags.multiline)
                            pos == input.len or (pos < input.len and input[pos] == '\n')
                        else
                            pos == input.len,
                        .start_text => pos == 0,
                        .end_text => pos == input.len,
                        .word_boundary => self.isWordBoundary(input, pos),
                        .non_word_boundary => !self.isWordBoundary(input, pos),
                    };

                    if (anchor_matches) {
                        // Check if we've already visited this state
                        if (visited[transition.to]) continue;

                        var new_thread = try self.cloneThread(thread);
                        new_thread.state = transition.to;
                        self.applyTransitionCaptures(&new_thread, transition, pos);

                        try threads.append(self.allocator, new_thread);
                        // Don't recurse immediately - let addEpsilonClosure handle it iteratively
                    }
                },
                else => {},
            }
        }
    }

    fn isWordBoundary(self: *VM, input: []const u8, pos: usize) bool {
        _ = self;

        const before_is_word = if (pos > 0) common.CharClasses.word.matches(input[pos - 1]) else false;
        const after_is_word = if (pos < input.len) common.CharClasses.word.matches(input[pos]) else false;

        return before_is_word != after_is_word;
    }
};

test "vm match literal" {
    const allocator = std.testing.allocator;

    // Create simple NFA for "a"
    var nfa = compiler.NFA.init(allocator);
    defer nfa.deinit();

    const s0 = try nfa.addState();
    const s1 = try nfa.addState();

    nfa.start_state = s0;
    try nfa.markAccepting(s1);

    var state0 = nfa.getState(s0);
    try state0.addTransition(compiler.Transition.char('a', s1));

    var vm = VM.init(allocator, &nfa, 0, .{});
    defer vm.deinit();
    const result = try vm.matchAt("a", 0);
    try std.testing.expect(result != null);
    if (result) |res| {
        var mut_res = res;
        defer mut_res.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 0), res.start);
        try std.testing.expectEqual(@as(usize, 1), res.end);
    }
}

test "vm find in string" {
    const allocator = std.testing.allocator;

    // Create simple NFA for "b"
    var nfa = compiler.NFA.init(allocator);
    defer nfa.deinit();

    const s0 = try nfa.addState();
    const s1 = try nfa.addState();

    nfa.start_state = s0;
    try nfa.markAccepting(s1);

    var state0 = nfa.getState(s0);
    try state0.addTransition(compiler.Transition.char('b', s1));

    var vm = VM.init(allocator, &nfa, 0, .{});
    defer vm.deinit();
    const result = try vm.find("abc");
    try std.testing.expect(result != null);
    if (result) |res| {
        var mut_res = res;
        defer mut_res.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), res.start);
        try std.testing.expectEqual(@as(usize, 2), res.end);
    }
}

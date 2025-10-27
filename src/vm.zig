const std = @import("std");
const compiler = @import("compiler.zig");
const common = @import("common.zig");
const ast = @import("ast.zig");

/// Capture information for a matched group
pub const Capture = struct {
    start: usize,
    end: usize,
    text: []const u8,
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
        allocator.free(self.capture_starts);
        allocator.free(self.capture_ends);
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

    pub fn init(allocator: std.mem.Allocator, nfa: *compiler.NFA, num_captures: usize, flags: common.CompileFlags) VM {
        return .{
            .nfa = nfa,
            .allocator = allocator,
            .num_captures = num_captures,
            .flags = flags,
        };
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

    /// Check if the pattern matches at a specific position in the input
    pub fn matchAt(self: *VM, input: []const u8, start_pos: usize) !?MatchResult {
        var current_threads = std.ArrayList(Thread).initCapacity(self.allocator, 0) catch unreachable;
        defer {
            for (current_threads.items) |*thread| {
                thread.deinit(self.allocator);
            }
            current_threads.deinit(self.allocator);
        }

        var next_threads = std.ArrayList(Thread).initCapacity(self.allocator, 0) catch unreachable;
        defer {
            for (next_threads.items) |*thread| {
                thread.deinit(self.allocator);
            }
            next_threads.deinit(self.allocator);
        }

        // Start with initial thread at start state
        var initial_thread = try Thread.init(self.allocator, self.nfa.start_state, self.num_captures);

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
        try self.addEpsilonClosure(&current_threads, start_pos, input);

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

                    // Save this match (might be overwritten by a longer match)
                    var captures = try self.allocator.alloc(Capture, self.num_captures);
                    for (0..self.num_captures) |i| {
                        if (thread.capture_starts[i]) |cap_start| {
                            if (thread.capture_ends[i]) |cap_end| {
                                captures[i] = Capture{
                                    .start = cap_start,
                                    .end = cap_end,
                                    .text = input[cap_start..cap_end],
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
                        .char_class => transition.data.char_class.matches(c),
                        .anchor => false, // Anchors don't consume input
                        .epsilon => false, // Already handled in epsilon closure
                    };

                    if (matches) {
                        var new_thread = try thread.clone(self.allocator);
                        new_thread.state = transition.to;

                        // Update captures if this state marks a capture boundary
                        const next_state = self.nfa.getState(transition.to);
                        if (next_state.capture_start) |cap_idx| {
                            if (cap_idx > 0 and cap_idx <= self.num_captures) {
                                new_thread.capture_starts[cap_idx - 1] = pos;
                            }
                        }
                        if (next_state.capture_end) |cap_idx| {
                            if (cap_idx > 0 and cap_idx <= self.num_captures) {
                                new_thread.capture_ends[cap_idx - 1] = pos + 1;
                            }
                        }

                        try next_threads.append(self.allocator, new_thread);
                    }
                }
            }

            // Process epsilon closures for next threads
            try self.addEpsilonClosure(&next_threads, pos + 1, input);

            // Swap thread lists
            const tmp = current_threads;
            current_threads = next_threads;
            next_threads = tmp;

            // Clear next threads for next iteration
            for (next_threads.items) |*thread| {
                thread.deinit(self.allocator);
            }
            next_threads.clearRetainingCapacity();

            pos += 1;
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
    fn addEpsilonClosure(self: *VM, threads: *std.ArrayList(Thread), pos: usize, input: []const u8) !void {
        var visited = std.AutoHashMap(compiler.StateId, void).init(self.allocator);
        defer visited.deinit();

        var i: usize = 0;
        while (i < threads.items.len) : (i += 1) {
            // IMPORTANT: Pass thread by value to avoid dangling pointer issues
            // when ArrayList reallocates during followEpsilons
            try self.followEpsilons(threads.items[i], threads, &visited, pos, input);
        }
    }

    fn followEpsilons(
        self: *VM,
        thread: Thread,
        threads: *std.ArrayList(Thread),
        visited: *std.AutoHashMap(compiler.StateId, void),
        pos: usize,
        input: []const u8,
    ) !void {
        if (visited.contains(thread.state)) return;
        try visited.put(thread.state, {});

        const state = self.nfa.getState(thread.state);

        for (state.transitions.items) |transition| {
            switch (transition.transition_type) {
                .epsilon => {
                    // Check if we've already visited this state
                    if (visited.contains(transition.to)) continue;

                    var new_thread = try thread.clone(self.allocator);
                    new_thread.state = transition.to;

                    // Update captures if this state marks a capture boundary
                    const next_state = self.nfa.getState(transition.to);
                    if (next_state.capture_start) |cap_idx| {
                        if (cap_idx > 0 and cap_idx <= self.num_captures) {
                            new_thread.capture_starts[cap_idx - 1] = pos;
                        }
                    }
                    if (next_state.capture_end) |cap_idx| {
                        if (cap_idx > 0 and cap_idx <= self.num_captures) {
                            new_thread.capture_ends[cap_idx - 1] = pos;
                        }
                    }

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
                        if (visited.contains(transition.to)) continue;

                        var new_thread = try thread.clone(self.allocator);
                        new_thread.state = transition.to;

                        // Update captures if this state marks a capture boundary
                        const next_state = self.nfa.getState(transition.to);
                        if (next_state.capture_start) |cap_idx| {
                            if (cap_idx > 0 and cap_idx <= self.num_captures) {
                                new_thread.capture_starts[cap_idx - 1] = pos;
                            }
                        }
                        if (next_state.capture_end) |cap_idx| {
                            if (cap_idx > 0 and cap_idx <= self.num_captures) {
                                new_thread.capture_ends[cap_idx - 1] = pos;
                            }
                        }

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
    const result = try vm.find("abc");
    try std.testing.expect(result != null);
    if (result) |res| {
        var mut_res = res;
        defer mut_res.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), res.start);
        try std.testing.expectEqual(@as(usize, 2), res.end);
    }
}

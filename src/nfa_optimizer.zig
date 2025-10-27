const std = @import("std");
const compiler = @import("compiler.zig");

/// NFA Optimization pass
/// Optimizes NFA by removing redundant epsilon transitions, merging equivalent states,
/// and optimizing state transitions for better performance.
pub const NFAOptimizer = struct {
    allocator: std.mem.Allocator,
    nfa: *compiler.NFA,

    pub fn init(allocator: std.mem.Allocator, nfa: *compiler.NFA) NFAOptimizer {
        return .{
            .allocator = allocator,
            .nfa = nfa,
        };
    }

    /// Run all optimization passes
    pub fn optimize(self: *NFAOptimizer) !usize {
        var total_optimizations: usize = 0;

        // Pass 1: Remove redundant epsilon transitions
        total_optimizations += try self.removeRedundantEpsilons();

        // Pass 2: Merge equivalent states
        total_optimizations += try self.mergeEquivalentStates();

        // Pass 3: Optimize state transitions
        total_optimizations += try self.optimizeTransitions();

        return total_optimizations;
    }

    /// Remove redundant epsilon transitions
    /// An epsilon transition is redundant if it creates a path that already exists
    fn removeRedundantEpsilons(self: *NFAOptimizer) !usize {
        var removed_count: usize = 0;

        // For each state
        for (self.nfa.states.items) |*state| {
            // Build epsilon closure for this state
            var closure = std.AutoHashMap(compiler.StateId, void).init(self.allocator);
            defer closure.deinit();

            try self.buildEpsilonClosure(state.id, &closure);

            // Check each epsilon transition
            var i: usize = 0;
            while (i < state.transitions.items.len) {
                const transition = state.transitions.items[i];

                if (transition.transition_type == .epsilon) {
                    // Check if this epsilon transition creates a redundant path
                    // by checking if the target is already in our epsilon closure
                    // through another path
                    var closure_without_this = std.AutoHashMap(compiler.StateId, void).init(self.allocator);
                    defer closure_without_this.deinit();

                    // Build closure without this specific transition
                    for (state.transitions.items, 0..) |other_trans, j| {
                        if (i != j and other_trans.transition_type == .epsilon) {
                            try self.buildEpsilonClosureFrom(other_trans.to, &closure_without_this);
                        }
                    }

                    // If the target is still reachable, this epsilon is redundant
                    if (closure_without_this.contains(transition.to)) {
                        _ = state.transitions.orderedRemove(i);
                        removed_count += 1;
                        continue; // Don't increment i, check same position again
                    }
                }

                i += 1;
            }
        }

        return removed_count;
    }

    /// Build epsilon closure for a state (all states reachable via epsilon transitions)
    fn buildEpsilonClosure(self: *NFAOptimizer, state_id: compiler.StateId, closure: *std.AutoHashMap(compiler.StateId, void)) !void {
        if (closure.contains(state_id)) return;
        try closure.put(state_id, {});

        const state = self.nfa.getState(state_id);
        for (state.transitions.items) |transition| {
            if (transition.transition_type == .epsilon) {
                try self.buildEpsilonClosure(transition.to, closure);
            }
        }
    }

    /// Build epsilon closure starting from a specific state
    fn buildEpsilonClosureFrom(self: *NFAOptimizer, state_id: compiler.StateId, closure: *std.AutoHashMap(compiler.StateId, void)) !void {
        try self.buildEpsilonClosure(state_id, closure);
    }

    /// Merge equivalent states
    /// Two states are equivalent if they have the same transitions and accepting status
    fn mergeEquivalentStates(self: *NFAOptimizer) !usize {
        var merged_count: usize = 0;
        var state_map = std.AutoHashMap(compiler.StateId, compiler.StateId).init(self.allocator);
        defer state_map.deinit();

        // Find equivalent states
        var i: usize = 0;
        while (i < self.nfa.states.items.len) : (i += 1) {
            var j: usize = i + 1;
            while (j < self.nfa.states.items.len) {
                const state_i = &self.nfa.states.items[i];
                const state_j = &self.nfa.states.items[j];

                if (self.statesAreEquivalent(state_i, state_j)) {
                    // Map state_j to state_i
                    try state_map.put(state_j.id, state_i.id);
                    merged_count += 1;
                }

                j += 1;
            }
        }

        // If we found equivalent states, update all transitions
        if (merged_count > 0) {
            for (self.nfa.states.items) |*state| {
                for (state.transitions.items) |*transition| {
                    if (state_map.get(transition.to)) |new_target| {
                        transition.to = new_target;
                    }
                }
            }

            // Update start state if needed
            if (state_map.get(self.nfa.start_state)) |new_start| {
                self.nfa.start_state = new_start;
            }

            // Remove merged states (mark for removal)
            var new_states = std.ArrayList(compiler.State).initCapacity(self.allocator, self.nfa.states.items.len) catch unreachable;
            for (self.nfa.states.items) |state| {
                if (!state_map.contains(state.id)) {
                    try new_states.append(self.allocator, state);
                }
            }

            // Replace states list
            self.nfa.states.deinit(self.allocator);
            self.nfa.states = new_states;
        }

        return merged_count;
    }

    /// Check if two states are equivalent
    fn statesAreEquivalent(self: *NFAOptimizer, state1: *const compiler.State, state2: *const compiler.State) bool {
        // Must have same accepting status
        if (state1.is_accepting != state2.is_accepting) return false;

        // Must have same capture markers
        if (state1.capture_start != state2.capture_start) return false;
        if (state1.capture_end != state2.capture_end) return false;

        // Must have same number of transitions
        if (state1.transitions.items.len != state2.transitions.items.len) return false;

        // Must have equivalent transitions (same type and target)
        // Note: This is a simplified check; a more sophisticated version would
        // use a canonical ordering of transitions
        for (state1.transitions.items) |trans1| {
            var found = false;
            for (state2.transitions.items) |trans2| {
                if (self.transitionsAreEquivalent(&trans1, &trans2)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }

        return true;
    }

    /// Check if two transitions are equivalent
    fn transitionsAreEquivalent(_: *NFAOptimizer, trans1: *const compiler.Transition, trans2: *const compiler.Transition) bool {
        if (trans1.transition_type != trans2.transition_type) return false;
        if (trans1.to != trans2.to) return false;

        return switch (trans1.transition_type) {
            .epsilon, .any => true,
            .char => trans1.data.char == trans2.data.char,
            .char_class => {
                // Compare character classes
                const cc1 = trans1.data.char_class;
                const cc2 = trans2.data.char_class;
                if (cc1.negated != cc2.negated) return false;
                if (cc1.ranges.len != cc2.ranges.len) return false;
                for (cc1.ranges, cc2.ranges) |r1, r2| {
                    if (r1.start != r2.start or r1.end != r2.end) return false;
                }
                return true;
            },
            .anchor => trans1.data.anchor == trans2.data.anchor,
        };
    }

    /// Optimize state transitions
    /// Removes duplicate transitions and sorts them for better cache locality
    fn optimizeTransitions(self: *NFAOptimizer) !usize {
        var optimized_count: usize = 0;

        for (self.nfa.states.items) |*state| {
            // Remove duplicate transitions
            var seen = std.AutoHashMap(u64, void).init(self.allocator);
            defer seen.deinit();

            var i: usize = 0;
            while (i < state.transitions.items.len) {
                const hash = self.transitionHash(&state.transitions.items[i]);

                if (seen.contains(hash)) {
                    _ = state.transitions.orderedRemove(i);
                    optimized_count += 1;
                    continue;
                }

                try seen.put(hash, {});
                i += 1;
            }
        }

        return optimized_count;
    }

    /// Compute a hash for a transition (for deduplication)
    fn transitionHash(_: *NFAOptimizer, trans: *const compiler.Transition) u64 {
        var hasher = std.hash.Wyhash.init(0);

        // Hash type
        std.hash.autoHash(&hasher, @intFromEnum(trans.transition_type));

        // Hash target
        std.hash.autoHash(&hasher, trans.to);

        // Hash data based on type
        switch (trans.transition_type) {
            .epsilon, .any => {},
            .char => std.hash.autoHash(&hasher, trans.data.char),
            .char_class => {
                std.hash.autoHash(&hasher, trans.data.char_class.negated);
                for (trans.data.char_class.ranges) |range| {
                    std.hash.autoHash(&hasher, range.start);
                    std.hash.autoHash(&hasher, range.end);
                }
            },
            .anchor => std.hash.autoHash(&hasher, @intFromEnum(trans.data.anchor)),
        }

        return hasher.final();
    }
};

/// Visualization helpers
pub const NFAVisualizer = struct {
    allocator: std.mem.Allocator,
    nfa: *const compiler.NFA,

    pub fn init(allocator: std.mem.Allocator, nfa: *const compiler.NFA) NFAVisualizer {
        return .{
            .allocator = allocator,
            .nfa = nfa,
        };
    }

    /// Generate DOT format for Graphviz visualization
    pub fn toDot(self: *NFAVisualizer, writer: anytype) !void {
        try writer.writeAll("digraph NFA {\n");
        try writer.writeAll("  rankdir=LR;\n");
        try writer.writeAll("  node [shape=circle];\n");

        // Mark accepting states
        try writer.writeAll("  node [shape=doublecircle];\n");
        for (self.nfa.states.items) |state| {
            if (state.is_accepting) {
                try writer.print("  s{d};\n", .{state.id});
            }
        }
        try writer.writeAll("  node [shape=circle];\n");

        // Mark start state
        try writer.print("  start [shape=none,label=\"\"];\n");
        try writer.print("  start -> s{d};\n", .{self.nfa.start_state});

        // Draw transitions
        for (self.nfa.states.items) |state| {
            for (state.transitions.items) |transition| {
                const label = try self.transitionLabel(&transition);
                defer self.allocator.free(label);

                try writer.print("  s{d} -> s{d} [label=\"{s}\"];\n", .{
                    state.id,
                    transition.to,
                    label,
                });
            }
        }

        try writer.writeAll("}\n");
    }

    /// Get a human-readable label for a transition
    fn transitionLabel(self: *NFAVisualizer, trans: *const compiler.Transition) ![]u8 {
        return switch (trans.transition_type) {
            .epsilon => try self.allocator.dupe(u8, "ε"),
            .char => try std.fmt.allocPrint(self.allocator, "{c}", .{trans.data.char}),
            .char_class => try std.fmt.allocPrint(self.allocator, "[class]", .{}),
            .any => try self.allocator.dupe(u8, "."),
            .anchor => try std.fmt.allocPrint(self.allocator, "{s}", .{@tagName(trans.data.anchor)}),
        };
    }

    /// Print NFA statistics
    pub fn printStats(self: *NFAVisualizer, writer: anytype) !void {
        var epsilon_count: usize = 0;
        var char_count: usize = 0;
        var class_count: usize = 0;
        var any_count: usize = 0;
        var anchor_count: usize = 0;
        var accepting_count: usize = 0;

        for (self.nfa.states.items) |state| {
            if (state.is_accepting) accepting_count += 1;

            for (state.transitions.items) |transition| {
                switch (transition.transition_type) {
                    .epsilon => epsilon_count += 1,
                    .char => char_count += 1,
                    .char_class => class_count += 1,
                    .any => any_count += 1,
                    .anchor => anchor_count += 1,
                }
            }
        }

        try writer.writeAll("NFA Statistics:\n");
        try writer.print("  States: {d}\n", .{self.nfa.states.items.len});
        try writer.print("  Accepting States: {d}\n", .{accepting_count});
        try writer.writeAll("  Transitions:\n");
        try writer.print("    Epsilon: {d}\n", .{epsilon_count});
        try writer.print("    Char: {d}\n", .{char_count});
        try writer.print("    CharClass: {d}\n", .{class_count});
        try writer.print("    Any: {d}\n", .{any_count});
        try writer.print("    Anchor: {d}\n", .{anchor_count});
        try writer.print("  Total Transitions: {d}\n", .{epsilon_count + char_count + class_count + any_count + anchor_count});
    }
};

// Tests
test "nfa_optimizer: remove redundant epsilons" {
    const allocator = std.testing.allocator;

    // Create a simple NFA with redundant epsilon transitions
    var nfa = compiler.NFA.init(allocator);
    defer nfa.deinit();

    _ = try nfa.addState(); // 0
    _ = try nfa.addState(); // 1
    _ = try nfa.addState(); // 2

    // Add redundant epsilon: 0 -> 1 -> 2 and 0 -> 2
    try nfa.states.items[0].transitions.append(allocator, compiler.Transition.epsilon(1));
    try nfa.states.items[1].transitions.append(allocator, compiler.Transition.epsilon(2));
    try nfa.states.items[0].transitions.append(allocator, compiler.Transition.epsilon(2)); // Redundant

    var optimizer = NFAOptimizer.init(allocator, &nfa);
    const removed = try optimizer.removeRedundantEpsilons();

    try std.testing.expect(removed > 0);
}

test "nfa_optimizer: optimize transitions" {
    const allocator = std.testing.allocator;

    var nfa = compiler.NFA.init(allocator);
    defer nfa.deinit();

    _ = try nfa.addState(); // 0
    _ = try nfa.addState(); // 1

    // Add duplicate transitions
    try nfa.states.items[0].transitions.append(allocator, compiler.Transition.char('a', 1));
    try nfa.states.items[0].transitions.append(allocator, compiler.Transition.char('a', 1)); // Duplicate

    var optimizer = NFAOptimizer.init(allocator, &nfa);
    const optimized = try optimizer.optimizeTransitions();

    try std.testing.expectEqual(@as(usize, 1), optimized);
}

test "nfa_optimizer: visualizer stats" {
    const allocator = std.testing.allocator;

    var nfa = compiler.NFA.init(allocator);
    defer nfa.deinit();

    _ = try nfa.addState(); // 0
    _ = try nfa.addState(); // 1
    nfa.states.items[1].is_accepting = true;

    try nfa.states.items[0].transitions.append(allocator, compiler.Transition.epsilon(1));

    var visualizer = NFAVisualizer.init(allocator, &nfa);

    var buffer = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    defer buffer.deinit(allocator);

    try visualizer.printStats(buffer.writer(allocator));
    try std.testing.expect(buffer.items.len > 0);
}

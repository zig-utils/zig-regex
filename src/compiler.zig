const std = @import("std");
const ast = @import("ast.zig");
const common = @import("common.zig");
const utf8_class = @import("utf8_class.zig");
const RegexError = @import("errors.zig").RegexError;

/// State ID in the NFA
pub const StateId = usize;

/// Special value for no state
pub const NO_STATE: StateId = std.math.maxInt(StateId);

/// Transition type
pub const TransitionType = enum {
    epsilon, // ε transition
    char, // Match a specific character
    char_class, // Match a character class
    any, // Match any character (.)
    anchor, // Anchor (^, $, \b, \B)
};

/// Transition in the NFA
pub const Transition = struct {
    transition_type: TransitionType,
    to: StateId,
    data: TransitionData,
    clear_captures: []const usize = &.{},

    pub const TransitionData = union(TransitionType) {
        epsilon: void,
        char: u8,
        char_class: common.CharClass,
        any: void,
        anchor: ast.AnchorType,
    };

    pub fn epsilon(to: StateId) Transition {
        return .{
            .transition_type = .epsilon,
            .to = to,
            .data = .{ .epsilon = {} },
        };
    }

    pub fn epsilonClearing(to: StateId, captures: []const usize) Transition {
        return .{
            .transition_type = .epsilon,
            .to = to,
            .data = .{ .epsilon = {} },
            .clear_captures = captures,
        };
    }

    pub fn char(c: u8, to: StateId) Transition {
        return .{
            .transition_type = .char,
            .to = to,
            .data = .{ .char = c },
        };
    }

    pub fn charClass(allocator: std.mem.Allocator, class: common.CharClass, to: StateId) !Transition {
        // Duplicate the ranges so we own them and can free them later
        const ranges_copy = try allocator.dupe(common.CharRange, class.ranges);
        return .{
            .transition_type = .char_class,
            .to = to,
            .data = .{ .char_class = .{
                .ranges = ranges_copy,
                .negated = class.negated,
            } },
        };
    }

    pub fn any(to: StateId) Transition {
        return .{
            .transition_type = .any,
            .to = to,
            .data = .{ .any = {} },
        };
    }

    pub fn anchor(anchor_type: ast.AnchorType, to: StateId) Transition {
        return .{
            .transition_type = .anchor,
            .to = to,
            .data = .{ .anchor = anchor_type },
        };
    }
};

/// NFA State
pub const State = struct {
    id: StateId,
    transitions: std.ArrayList(Transition),
    allocator: std.mem.Allocator,
    is_accepting: bool = false,
    capture_start: ?usize = null, // Capture group start marker
    capture_end: ?usize = null, // Capture group end marker

    pub fn init(allocator: std.mem.Allocator, id: StateId) State {
        return .{
            .id = id,
            .transitions = .empty,
            .allocator = allocator,
            .is_accepting = false,
        };
    }

    pub fn deinit(self: *State) void {
        // Free owned transition payloads.
        for (self.transitions.items) |transition| {
            if (transition.transition_type == .char_class) {
                self.allocator.free(transition.data.char_class.ranges);
            }
            if (transition.clear_captures.len != 0) {
                self.allocator.free(transition.clear_captures);
            }
        }
        self.transitions.deinit(self.allocator);
    }

    pub fn addTransition(self: *State, transition: Transition) !void {
        try self.transitions.append(self.allocator, transition);
    }
};

/// NFA Fragment - intermediate structure during Thompson construction
pub const Fragment = struct {
    start: StateId,
    accept: StateId,
};

/// Non-deterministic Finite Automaton
pub const NFA = struct {
    states: std.ArrayList(State),
    start_state: StateId,
    accept_states: std.ArrayList(StateId),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) NFA {
        return .{
            .states = .empty,
            .start_state = 0,
            .accept_states = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *NFA) void {
        for (self.states.items) |*state| {
            state.deinit();
        }
        self.states.deinit(self.allocator);
        self.accept_states.deinit(self.allocator);
    }

    pub fn addState(self: *NFA) !StateId {
        const id = self.states.items.len;
        try self.states.append(self.allocator, State.init(self.allocator, id));
        return id;
    }

    pub fn getState(self: *NFA, id: StateId) *State {
        return &self.states.items[id];
    }

    pub fn markAccepting(self: *NFA, state_id: StateId) !void {
        self.states.items[state_id].is_accepting = true;
        try self.accept_states.append(self.allocator, state_id);
    }
};

/// Compiler that converts AST to NFA using Thompson's construction
pub const Compiler = struct {
    nfa: NFA,
    allocator: std.mem.Allocator,
    flags: common.CompileFlags,

    pub fn init(allocator: std.mem.Allocator) Compiler {
        return initWithFlags(allocator, .{});
    }

    pub fn initWithFlags(allocator: std.mem.Allocator, flags: common.CompileFlags) Compiler {
        return .{
            .nfa = NFA.init(allocator),
            .allocator = allocator,
            .flags = flags,
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.nfa.deinit();
    }

    /// Compile an AST into an NFA
    pub fn compile(self: *Compiler, tree: *ast.AST) !*NFA {
        const fragment = try self.compileNode(tree.root);

        // Set start state
        self.nfa.start_state = fragment.start;

        // Mark accept state
        try self.nfa.markAccepting(fragment.accept);

        return &self.nfa;
    }

    /// Compile a single AST node into an NFA fragment
    fn compileNode(self: *Compiler, node: *ast.Node) anyerror!Fragment {
        return switch (node.node_type) {
            .literal => try self.compileLiteral(node.data.literal),
            .any => try self.compileAny(),
            .concat => try self.compileConcat(node.data.concat),
            .alternation => try self.compileAlternation(node.data.alternation),
            .star => try self.compileStar(node.data.star.child, node.data.star.greedy),
            .plus => try self.compilePlus(node.data.plus.child, node.data.plus.greedy),
            .optional => try self.compileOptional(node.data.optional.child, node.data.optional.greedy),
            .repeat => try self.compileRepeat(node.data.repeat),
            .char_class => try self.compileCharClass(node.data.char_class),
            .group => try self.compileGroup(node.data.group),
            .anchor => try self.compileAnchor(node.data.anchor),
            .empty => try self.compileEmpty(),
            // A `class_set` of code-point ranges (e.g. `\s`, `\S`, `/v` Unicode
            // brackets) lowers to a UTF-8 byte automaton so it runs on the fast
            // byte engine; unrepresentable shapes are kept on the backtracker by
            // `requiresBacktracking`, so this only fires when lowerable.
            .class_set => try self.compileClassSet(node.data.class_set),
            // These features require backtracking engine
            .lookahead, .lookbehind, .backref, .unicode_property => @import("errors.zig").RegexError.NotImplemented,
        };
    }

    /// Compile a literal character
    /// ASCII-case-fold byte ranges: add each range's opposite-case letter span,
    /// so a folded class matched case-*sensitively* (`.matches`) accepts both
    /// cases. Lets case-insensitive patterns run on the byte NFA / lazy DFA
    /// instead of the per-position NFA. (`negated` is carried unchanged: folding
    /// the *set* and keeping the negation gives the correct `[^a]`→`[^aA]`.)
    fn caseFoldByteRanges(allocator: std.mem.Allocator, ranges: []const common.CharRange, negated: bool) !common.CharClass {
        var list: std.ArrayList(common.CharRange) = .empty;
        errdefer list.deinit(allocator);
        for (ranges) |r| {
            try list.append(allocator, r);
            const lo_a = @max(r.start, 'a');
            const hi_a = @min(r.end, 'z');
            if (lo_a <= hi_a) try list.append(allocator, .{ .start = lo_a - 'a' + 'A', .end = hi_a - 'a' + 'A' });
            const lo_b = @max(r.start, 'A');
            const hi_b = @min(r.end, 'Z');
            if (lo_b <= hi_b) try list.append(allocator, .{ .start = lo_b - 'A' + 'a', .end = hi_b - 'A' + 'a' });
        }
        return .{ .ranges = try list.toOwnedSlice(allocator), .negated = negated };
    }

    fn compileLiteral(self: *Compiler, c: u8) !Fragment {
        // Under `i`, an ASCII letter matches both cases — emit a folded class.
        if (self.flags.case_insensitive and ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z'))) {
            const folded = try caseFoldByteRanges(self.allocator, &[_]common.CharRange{.{ .start = c, .end = c }}, false);
            defer self.allocator.free(folded.ranges);
            return self.compileCharClassValue(folded);
        }
        const start = try self.nfa.addState();
        const accept = try self.nfa.addState();

        const start_state = self.nfa.getState(start);
        try start_state.addTransition(Transition.char(c, accept));

        return Fragment{ .start = start, .accept = accept };
    }

    /// Compile any character (`.`) as a UTF-8 code-point automaton, matching
    /// `common.dotMatchLen` for valid UTF-8: one code point in `[0, max]` (max =
    /// `0x10FFFF` with the `u` flag, else `0xFFFF`), excluding the ECMAScript
    /// line terminators `\n \r    ` unless `dot_all`. This keeps `.` on
    /// the fast byte engine instead of forcing the whole pattern to backtrack.
    fn compileAny(self: *Compiler) !Fragment {
        const max: u21 = if (self.flags.unicode) 0x10FFFF else 0xFFFF;
        if (self.flags.dot_all) {
            const ranges = [_]ast.Node.CpRange{.{ .lo = 0, .hi = max }};
            return self.compileCodepointRanges(&ranges);
        }
        // [0, max] minus { 0x0A, 0x0D, 0x2028, 0x2029 }.
        var buf: [5]ast.Node.CpRange = undefined;
        var n: usize = 0;
        const cuts = [_]u21{ 0x0A, 0x0D, 0x2028, 0x2029 };
        var lo: u21 = 0;
        for (cuts) |cut| {
            if (cut > max) break;
            if (cut > lo) {
                buf[n] = .{ .lo = lo, .hi = cut - 1 };
                n += 1;
            }
            lo = cut + 1;
        }
        if (lo <= max) {
            buf[n] = .{ .lo = lo, .hi = max };
            n += 1;
        }
        return self.compileCodepointRanges(buf[0..n]);
    }

    /// Compile concatenation
    fn compileConcat(self: *Compiler, concat: ast.Node.Concat) !Fragment {
        const left_frag = try self.compileNode(concat.left);
        const right_frag = try self.compileNode(concat.right);

        // Connect left accept to right start with epsilon
        const left_accept = self.nfa.getState(left_frag.accept);
        try left_accept.addTransition(Transition.epsilon(right_frag.start));

        return Fragment{
            .start = left_frag.start,
            .accept = right_frag.accept,
        };
    }

    /// Compile alternation (|)
    fn compileAlternation(self: *Compiler, alt: ast.Node.Alternation) !Fragment {
        const left_frag = try self.compileNode(alt.left);
        const right_frag = try self.compileNode(alt.right);

        const start = try self.nfa.addState();
        const accept = try self.nfa.addState();

        // Start state has epsilon transitions to both branches
        const start_state = self.nfa.getState(start);
        try self.addBranchTransition(start_state, left_frag.start, alt.right);
        try self.addBranchTransition(start_state, right_frag.start, alt.left);

        // Both branch accepts transition to final accept
        const left_accept = self.nfa.getState(left_frag.accept);
        try left_accept.addTransition(Transition.epsilon(accept));

        const right_accept = self.nfa.getState(right_frag.accept);
        try right_accept.addTransition(Transition.epsilon(accept));

        return Fragment{ .start = start, .accept = accept };
    }

    /// Compile Kleene star (*) or lazy star (*?)
    fn compileStar(self: *Compiler, child: *ast.Node, greedy: bool) !Fragment {
        const child_frag = try self.compileNode(child);

        const start = try self.nfa.addState();
        const accept = try self.nfa.addState();

        const start_state = self.nfa.getState(start);
        const child_accept = self.nfa.getState(child_frag.accept);

        if (greedy) {
            // Greedy: try to match first, then skip
            // Start can go to child or skip to accept
            try start_state.addTransition(Transition.epsilon(child_frag.start));
            try start_state.addTransition(Transition.epsilon(accept));
            // Child accept can loop back or go to final accept
            try child_accept.addTransition(Transition.epsilon(child_frag.start));
            try child_accept.addTransition(Transition.epsilon(accept));
        } else {
            // Lazy: try to skip first, then match
            // Start can skip to accept or go to child
            try start_state.addTransition(Transition.epsilon(accept));
            try start_state.addTransition(Transition.epsilon(child_frag.start));
            // Child accept can go to final accept or loop back
            try child_accept.addTransition(Transition.epsilon(accept));
            try child_accept.addTransition(Transition.epsilon(child_frag.start));
        }

        return Fragment{ .start = start, .accept = accept };
    }

    /// Compile plus (+) or lazy plus (+?)
    fn compilePlus(self: *Compiler, child: *ast.Node, greedy: bool) !Fragment {
        const child_frag = try self.compileNode(child);

        const start = try self.nfa.addState();
        const accept = try self.nfa.addState();

        // Start goes to child (at least one match required)
        const start_state = self.nfa.getState(start);
        try start_state.addTransition(Transition.epsilon(child_frag.start));

        const child_accept = self.nfa.getState(child_frag.accept);

        if (greedy) {
            // Greedy: try to loop back first, then accept
            try child_accept.addTransition(Transition.epsilon(child_frag.start));
            try child_accept.addTransition(Transition.epsilon(accept));
        } else {
            // Lazy: try to accept first, then loop back
            try child_accept.addTransition(Transition.epsilon(accept));
            try child_accept.addTransition(Transition.epsilon(child_frag.start));
        }

        return Fragment{ .start = start, .accept = accept };
    }

    /// Compile optional (?) or lazy optional (??)
    fn compileOptional(self: *Compiler, child: *ast.Node, greedy: bool) !Fragment {
        const child_frag = try self.compileNode(child);

        const start = try self.nfa.addState();
        const accept = try self.nfa.addState();

        const start_state = self.nfa.getState(start);

        if (greedy) {
            // Greedy: try to match first, then skip
            try start_state.addTransition(Transition.epsilon(child_frag.start));
            try self.addBranchTransition(start_state, accept, child);
        } else {
            // Lazy: try to skip first, then match
            try self.addBranchTransition(start_state, accept, child);
            try start_state.addTransition(Transition.epsilon(child_frag.start));
        }

        // Child accept goes to final accept
        const child_accept = self.nfa.getState(child_frag.accept);
        try child_accept.addTransition(Transition.epsilon(accept));

        return Fragment{ .start = start, .accept = accept };
    }

    /// Compile repetition {m,n} or lazy repetition {m,n}?
    fn compileRepeat(self: *Compiler, repeat: ast.Node.Repeat) !Fragment {
        // Implement {m,n} as m mandatory copies concatenated with (n-m) optional copies

        const min = repeat.bounds.min;
        const max = repeat.bounds.max;
        const greedy = repeat.greedy;

        // SECURITY: Defense-in-depth - prevent excessive state allocation
        // Parser should already limit quantifiers to 100,000, but check again
        const MAX_REPEAT_EXPANSION: usize = 10_000; // Conservative limit for actual NFA expansion
        if (max) |max_val| {
            if (max_val > MAX_REPEAT_EXPANSION) {
                return RegexError.PatternTooComplex;
            }
        }
        if (min > MAX_REPEAT_EXPANSION) {
            return RegexError.PatternTooComplex;
        }

        if (min == 0 and max == null) {
            // {0,} is equivalent to * or *?
            return self.compileStar(repeat.child, greedy);
        }

        if (min == 1 and max == null) {
            // {1,} is equivalent to + or +?
            return self.compilePlus(repeat.child, greedy);
        }

        // Handle min == 0 with bounded max: all copies are optional
        if (min == 0) {
            if (max) |max_val| {
                // {0,0}: matches empty string only
                if (max_val == 0) {
                    const start = try self.nfa.addState();
                    const accept = try self.nfa.addState();
                    const start_state = self.nfa.getState(start);
                    try start_state.addTransition(Transition.epsilon(accept));
                    return Fragment{ .start = start, .accept = accept };
                }

                // {0,n}: n optional copies
                var current_frag = try self.compileOptional(repeat.child, greedy);
                var i: usize = 1;
                while (i < max_val) : (i += 1) {
                    const opt_fragment = try self.compileOptional(repeat.child, greedy);
                    const accept_state = self.nfa.getState(current_frag.accept);
                    try accept_state.addTransition(Transition.epsilon(opt_fragment.start));
                    current_frag.accept = opt_fragment.accept;
                }
                return current_frag;
            }
        }

        // Build min required (mandatory) copies
        var current_frag = try self.compileNode(repeat.child);

        var i: usize = 1;
        while (i < min) : (i += 1) {
            const next_frag = try self.compileNode(repeat.child);
            const accept_state = self.nfa.getState(current_frag.accept);
            try accept_state.addTransition(Transition.epsilon(next_frag.start));
            current_frag.accept = next_frag.accept;
        }

        if (max) |max_val| {
            // Add optional copies for the difference (max - min)
            const diff = max_val - min;
            i = 0;
            while (i < diff) : (i += 1) {
                const opt_fragment = try self.compileOptional(repeat.child, greedy);
                const accept_state = self.nfa.getState(current_frag.accept);
                try accept_state.addTransition(Transition.epsilon(opt_fragment.start));
                current_frag.accept = opt_fragment.accept;
            }
        } else {
            // {min,} - unbounded: add a star after the mandatory copies
            const star_frag = try self.compileStar(repeat.child, greedy);
            const accept_state = self.nfa.getState(current_frag.accept);
            try accept_state.addTransition(Transition.epsilon(star_frag.start));
            current_frag.accept = star_frag.accept;
        }

        return current_frag;
    }

    /// Compile character class
    fn compileCharClass(self: *Compiler, char_class: common.CharClass) !Fragment {
        // Under `i`, fold the class so it matches both cases case-sensitively.
        if (self.flags.case_insensitive) {
            const folded = try caseFoldByteRanges(self.allocator, char_class.ranges, char_class.negated);
            defer self.allocator.free(folded.ranges);
            return self.compileCharClassValue(folded);
        }
        return self.compileCharClassValue(char_class);
    }

    fn compileCharClassValue(self: *Compiler, char_class: common.CharClass) !Fragment {
        const start = try self.nfa.addState();
        const accept = try self.nfa.addState();

        const start_state = self.nfa.getState(start);
        try start_state.addTransition(try Transition.charClass(self.nfa.allocator, char_class, accept));

        return Fragment{ .start = start, .accept = accept };
    }

    /// Compile a code-point `class_set` into a UTF-8 byte automaton: an
    /// alternation of byte-range sequences, one per range produced by the
    /// utf8-ranges decomposition. Each sequence is a chain of single-range
    /// `char_class` byte transitions, all sharing one start/accept pair. A set
    /// that matches nothing yields an (unreachable-accept) dead fragment.
    fn compileClassSet(self: *Compiler, set: *ast.Node.ClassSet) !Fragment {
        // Folding happens on the positive set before any complement (inside
        // toCodepointRanges), so negated classes stay correct under `i`.
        const ranges = (try utf8_class.toCodepointRanges(self.allocator, set, self.flags.case_insensitive)) orelse
            return RegexError.NotImplemented;
        defer self.allocator.free(ranges);
        return self.compileCodepointRanges(ranges);
    }

    /// Build a UTF-8 byte automaton accepting exactly the code points in
    /// `ranges`: an alternation of byte-range sequences (utf8-ranges
    /// decomposition), each a chain of single-range `char_class` byte
    /// transitions sharing one start/accept pair. An empty set yields an
    /// (unreachable-accept) dead fragment.
    fn compileCodepointRanges(self: *Compiler, ranges: []const ast.Node.CpRange) !Fragment {
        const seqs = try utf8_class.toUtf8Sequences(self.allocator, ranges);
        defer self.allocator.free(seqs);

        const start = try self.nfa.addState();
        const accept = try self.nfa.addState();

        for (seqs) |seq| {
            var cur = start;
            var k: usize = 0;
            while (k < seq.len) : (k += 1) {
                const dst = if (k + 1 == seq.len) accept else try self.nfa.addState();
                const br = seq.ranges[k];
                const cc = common.CharClass{
                    .ranges = &[_]common.CharRange{.{ .start = br.lo, .end = br.hi }},
                    .negated = false,
                };
                // `charClass` dupes the ranges, so the stack slice is fine here.
                try self.nfa.getState(cur).addTransition(try Transition.charClass(self.nfa.allocator, cc, dst));
                cur = dst;
            }
        }

        return Fragment{ .start = start, .accept = accept };
    }

    /// Compile capture group
    fn compileGroup(self: *Compiler, group: ast.Node.Group) !Fragment {
        const child_frag = try self.compileNode(group.child);

        if (group.capture_index) |capture_idx| {
            // Create new states to mark capture boundaries
            // This is needed for nested groups to work correctly
            const start = try self.nfa.addState();
            const accept = try self.nfa.addState();

            // Mark the new states with capture markers
            const start_state = self.nfa.getState(start);
            start_state.capture_start = capture_idx;
            try start_state.addTransition(Transition.epsilon(child_frag.start));

            // Connect child accept to our accept state
            const child_accept = self.nfa.getState(child_frag.accept);
            try child_accept.addTransition(Transition.epsilon(accept));

            const accept_state = self.nfa.getState(accept);
            accept_state.capture_end = capture_idx;

            return Fragment{ .start = start, .accept = accept };
        }

        return child_frag;
    }

    fn addBranchTransition(self: *Compiler, state: *State, to: StateId, skipped: *ast.Node) !void {
        const captures = try self.captureIndicesIn(skipped);
        errdefer self.allocator.free(captures);
        if (captures.len == 0) {
            self.allocator.free(captures);
            try state.addTransition(Transition.epsilon(to));
        } else {
            try state.addTransition(Transition.epsilonClearing(to, captures));
        }
    }

    fn captureIndicesIn(self: *Compiler, node: *ast.Node) ![]usize {
        var captures: std.ArrayList(usize) = .empty;
        errdefer captures.deinit(self.allocator);
        try self.collectCaptureIndices(node, &captures);
        return captures.toOwnedSlice(self.allocator);
    }

    fn collectCaptureIndices(self: *Compiler, node: *ast.Node, captures: *std.ArrayList(usize)) !void {
        switch (node.node_type) {
            .group => {
                const group = node.data.group;
                if (group.capture_index) |index| try captures.append(self.allocator, index);
                try self.collectCaptureIndices(group.child, captures);
            },
            .concat => {
                try self.collectCaptureIndices(node.data.concat.left, captures);
                try self.collectCaptureIndices(node.data.concat.right, captures);
            },
            .alternation => {
                try self.collectCaptureIndices(node.data.alternation.left, captures);
                try self.collectCaptureIndices(node.data.alternation.right, captures);
            },
            .star => try self.collectCaptureIndices(node.data.star.child, captures),
            .plus => try self.collectCaptureIndices(node.data.plus.child, captures),
            .optional => try self.collectCaptureIndices(node.data.optional.child, captures),
            .repeat => try self.collectCaptureIndices(node.data.repeat.child, captures),
            .lookahead => try self.collectCaptureIndices(node.data.lookahead.child, captures),
            .lookbehind => try self.collectCaptureIndices(node.data.lookbehind.child, captures),
            else => {},
        }
    }

    /// Compile anchor
    fn compileAnchor(self: *Compiler, anchor_type: ast.AnchorType) !Fragment {
        const start = try self.nfa.addState();
        const accept = try self.nfa.addState();

        const start_state = self.nfa.getState(start);
        try start_state.addTransition(Transition.anchor(anchor_type, accept));

        return Fragment{ .start = start, .accept = accept };
    }

    /// Compile empty node
    fn compileEmpty(self: *Compiler) !Fragment {
        const start = try self.nfa.addState();
        const accept = try self.nfa.addState();

        const start_state = self.nfa.getState(start);
        try start_state.addTransition(Transition.epsilon(accept));

        return Fragment{ .start = start, .accept = accept };
    }
};

test "compile literal" {
    const allocator = std.testing.allocator;
    var compiler = Compiler.init(allocator);
    defer compiler.deinit();

    const span = common.Span.init(0, 1);
    const node = try ast.Node.createLiteral(allocator, 'a', span);
    defer allocator.destroy(node);

    const frag = try compiler.compileLiteral('a');
    try std.testing.expect(frag.start != frag.accept);
}

test "compile concatenation" {
    const allocator = std.testing.allocator;
    var parser = try @import("parser.zig").Parser.init(allocator, "ab");
    var tree = try parser.parse();
    defer tree.deinit();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();

    _ = try compiler.compile(&tree);
    try std.testing.expect(compiler.nfa.states.items.len > 0);
}

test "compile alternation" {
    const allocator = std.testing.allocator;
    var parser = try @import("parser.zig").Parser.init(allocator, "a|b");
    var tree = try parser.parse();
    defer tree.deinit();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();

    _ = try compiler.compile(&tree);
    try std.testing.expect(compiler.nfa.states.items.len > 0);
}

test "compile star" {
    const allocator = std.testing.allocator;
    var parser = try @import("parser.zig").Parser.init(allocator, "a*");
    var tree = try parser.parse();
    defer tree.deinit();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();

    _ = try compiler.compile(&tree);
    try std.testing.expect(compiler.nfa.states.items.len > 0);
}

test "compiler: repeat expansion limit" {
    const allocator = std.testing.allocator;

    // Pattern with quantifier exceeding MAX_REPEAT_EXPANSION (10,000)
    // Parser allows up to 100,000, but compiler should reject > 10,000
    var parser = try @import("parser.zig").Parser.init(allocator, "a{50000}");
    var tree = try parser.parse();
    defer tree.deinit();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();

    const result = compiler.compile(&tree);
    try std.testing.expectError(RegexError.PatternTooComplex, result);
}

test "compiler: acceptable repeat expansion" {
    const allocator = std.testing.allocator;

    // Pattern with quantifier within MAX_REPEAT_EXPANSION
    var parser = try @import("parser.zig").Parser.init(allocator, "a{100}");
    var tree = try parser.parse();
    defer tree.deinit();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();

    _ = try compiler.compile(&tree);
    try std.testing.expect(compiler.nfa.states.items.len > 0);
}

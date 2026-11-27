const std = @import("std");
const ast = @import("ast.zig");
const common = @import("common.zig");
const unicode_mod = @import("unicode.zig");

/// Backtracking-based regex engine
/// Supports: lazy quantifiers, lookahead/lookbehind, backreferences
/// Trade-off: O(2^n) worst case, but supports features impossible in Thompson NFA
/// Match result from backtracking engine
pub const BacktrackMatch = struct {
    start: usize,
    end: usize,
    captures: []CaptureGroup,

    pub const CaptureGroup = struct {
        start: usize,
        end: usize,
        matched: bool,
    };

    pub fn deinit(self: *BacktrackMatch, allocator: std.mem.Allocator) void {
        allocator.free(self.captures);
    }
};

/// Backtracking engine state
pub const BacktrackEngine = struct {
    allocator: std.mem.Allocator,
    ast_root: *ast.Node,
    capture_count: usize,
    flags: common.CompileFlags,
    input: []const u8,
    captures: []CaptureGroup,
    /// ReDoS protection: count of matching steps
    step_count: usize,
    /// Maximum steps before aborting (prevents catastrophic backtracking)
    max_steps: usize,
    /// Search-local, with the same serialized matcher ownership as input,
    /// captures and step_count. Reset at findFrom entry; no process-global state.
    /// Choice traversal must not turn allocation failures into ordinary misses.
    match_error: ?anyerror = null,
    /// The current search's memo of failed continuation states, owned by
    /// `findFromWithPrefix` while it runs (see `SearchMemo`). Null outside a
    /// search and for patterns the memo would be wrong for.
    memo: ?*SearchMemo = null,
    /// Set for a search whose loops over a body with choices go to the
    /// continuation matcher piece by piece (see `continuationFirst`): the
    /// pattern has such a loop and no atomic group, so the memo can keep those
    /// pieces from going exponential. Their loops follow
    /// the pattern's own dialect (`pcreLoops`); a pattern the continuation
    /// matcher runs whole keeps its rules as they were.
    hybrid: bool = false,
    /// Whether the pattern holds a loop `loopNeedsContinuations` names
    /// (`memoApplies`), found by `init`.
    bounded_choice_repeat: ?bool = null,
    /// The groups a backreference in the pattern can read (`referencedGroups`),
    /// found by `init` and shared by the copies `forSearch` makes.
    referenced: []usize = &.{},
    owns_referenced: bool = false,
    /// Each capture index's group node (index 0 unused), found by `init`
    /// for a pattern with a backreference and shared like `referenced`.
    group_nodes: []?*ast.Node = &.{},
    /// Each lookbehind body `forwardLookbehind` matches forwards, keyed by
    /// its address, with its branches; found by `init` in PCRE mode and
    /// shared like `referenced`.
    lookbehind_plans: std.AutoHashMapUnmanaged(usize, []LookbehindBranch) = .empty,
    owns_plans: bool = false,
    /// Whether the last search was answered by the attempt with the loop
    /// memo, which ran on half the step budget (see `findFromWithPrefix`).
    answered_with_memo: bool = false,
    /// Every step the last search took, over both its attempts when it ran
    /// two (`step_count` holds only the last attempt's).
    steps_taken: usize = 0,

    pub const CaptureGroup = struct {
        start: usize,
        end: usize,
        matched: bool,
    };

    /// Default maximum steps: 10 million (prevents ReDoS while allowing complex patterns)
    pub const DEFAULT_MAX_STEPS: usize = 10_000_000;

    pub fn init(allocator: std.mem.Allocator, root: *ast.Node, capture_count: usize, flags: common.CompileFlags) !BacktrackEngine {
        try analyze(allocator, root);
        const captures = try allocator.alloc(CaptureGroup, capture_count);
        for (captures) |*cap| {
            cap.* = .{ .start = 0, .end = 0, .matched = false };
        }

        var engine = BacktrackEngine{
            .allocator = allocator,
            .ast_root = root,
            .capture_count = capture_count,
            .flags = flags,
            .input = &[_]u8{},
            .captures = captures,
            .step_count = 0,
            .max_steps = DEFAULT_MAX_STEPS,
        };
        errdefer allocator.free(captures);
        // What the loop memo needs to know about a pattern with a
        // backreference, found once here rather than on every search.
        if (engine.hasBackreference(root)) {
            engine.referenced = try engine.referencedGroups();
            engine.owns_referenced = true;
            errdefer allocator.free(engine.referenced);
            engine.group_nodes = try allocator.alloc(?*ast.Node, capture_count + 1);
            errdefer allocator.free(engine.group_nodes);
            @memset(engine.group_nodes, null);
            var pending: std.ArrayList(*ast.Node) = .empty;
            defer pending.deinit(allocator);
            var current: ?*ast.Node = root;
            while (current) |n| : (current = pending.pop()) {
                if (n.node_type == .group) if (n.data.group.capture_index) |index| {
                    if (index <= capture_count) engine.group_nodes[index] = n;
                };
                try engine.pushNodeChildren(&pending, n);
            }
        }
        errdefer if (engine.owns_referenced) {
            allocator.free(engine.referenced);
            allocator.free(engine.group_nodes);
        };
        engine.bounded_choice_repeat = engine.anyNodeMatches(root, boundedChoiceRepeatVerdict);
        if (engine.match_error) |err| return err;
        if (!flags.ecmascript and engine.hasLookbehind(root)) {
            engine.owns_plans = true;
            errdefer engine.freeLookbehindPlans();
            try engine.buildLookbehindPlans();
        }
        return engine;
    }

    pub fn deinit(self: *BacktrackEngine) void {
        self.allocator.free(self.captures);
        if (self.owns_referenced) {
            self.allocator.free(self.referenced);
            self.allocator.free(self.group_nodes);
        }
        if (self.owns_plans) self.freeLookbehindPlans();
    }

    /// A copy of this engine for one search, with its own captures, input, step
    /// count and error. A compiled `Regex` keeps one engine for its pattern,
    /// flags and step budget and searches only with copies, so concurrent
    /// searches of one `Regex` never share match state. Release with `deinit`.
    pub fn forSearch(self: *const BacktrackEngine) std.mem.Allocator.Error!BacktrackEngine {
        var copy = self.*;
        copy.owns_referenced = false;
        copy.owns_plans = false;
        copy.captures = try self.allocator.alloc(CaptureGroup, self.captures.len);
        for (copy.captures) |*cap| cap.* = .{ .start = 0, .end = 0, .matched = false };
        copy.input = &[_]u8{};
        copy.step_count = 0;
        copy.match_error = null;
        return copy;
    }

    /// Test if pattern matches entire input
    pub fn isMatch(self: *BacktrackEngine, input: []const u8) bool {
        if (self.find(input)) |match| {
            self.allocator.free(match.captures);
            return true;
        }
        return false;
    }

    /// Find first match in input
    pub fn find(self: *BacktrackEngine, input: []const u8) ?BacktrackMatch {
        return self.findFrom(input, 0);
    }

    /// Find first match in input at or after `start`, preserving assertions that
    /// refer to the original input rather than a sliced search window.
    pub fn findFrom(self: *BacktrackEngine, input: []const u8, start: usize) ?BacktrackMatch {
        return self.findFromWithPrefix(input, start, null);
    }

    /// `prefix`, when supplied, must be a case-sensitive ASCII literal at the
    /// start of every match. It borrows the caller's immutable analysis. ASCII
    /// candidate positions also preserve Unicode code-point search boundaries.
    pub fn findFromWithPrefix(self: *BacktrackEngine, input: []const u8, start: usize, prefix: ?[]const u8) ?BacktrackMatch {
        // A search with the loop memo gets half the step budget. If it outgrows
        // the memo's tables or that half (a long input over a loop with an
        // ambiguous body, or a loop over a large alternation, where each state
        // costs many steps), it runs again without the memo, as the engine did
        // before the memo, with the whole budget: its cost stays within 0.5.2's
        // plus half a budget, at 0.5.2's accuracy. `Regex.searchSteps` reports
        // the attempt that answered.
        self.answered_with_memo = false;
        if (!self.memoApplies()) {
            const found = self.findOnce(input, start, prefix, false);
            self.steps_taken = self.step_count;
            return found;
        }
        const budget = self.max_steps;
        self.max_steps = budget / 2;
        const found = self.findOnce(input, start, prefix, true);
        self.max_steps = budget;
        const first_attempt = self.step_count;
        const outgrown = found == null and (self.step_count > budget / 2 or
            (if (self.match_error) |err| err == error.MemoExhausted or err == error.Timeout else false));
        if (outgrown) {
            const rerun = self.findOnce(input, start, prefix, false);
            self.steps_taken = first_attempt + self.step_count;
            return rerun;
        }
        self.steps_taken = first_attempt;
        self.answered_with_memo = true;
        return found;
    }

    /// Whether a search of this pattern uses the loop memo: it has a loop
    /// over a body with choices, and no atomic group, which the memo would be
    /// wrong for. A backreference is fine: the memo's states then carry the
    /// spans of the groups it reads (`SearchMemo.referenced`).
    fn memoApplies(self: *BacktrackEngine) bool {
        if (self.hasAtomicGroup(self.ast_root)) return false;
        if (self.ast_root.facts.choice_loop) return true;
        // A loop this engine leaves to its first ends in a pattern with a
        // backreference, or whose empty iterations it takes differently from
        // PCRE (`loopNeedsContinuations`), needs the continuation matcher
        // too, which needs the memo.
        if (self.bounded_choice_repeat == null)
            self.bounded_choice_repeat = self.anyNodeMatches(self.ast_root, boundedChoiceRepeatVerdict);
        return self.bounded_choice_repeat.?;
    }

    fn boundedChoiceRepeatVerdict(self: *BacktrackEngine, n: *ast.Node) NodeVerdict {
        if (self.loopNeedsContinuations(n)) return .matched;
        return switch (n.node_type) {
            .concat, .alternation, .group, .star, .plus, .optional, .repeat, .lookahead, .lookbehind => .descend,
            else => .skip,
        };
    }

    /// The capture indices (1-based) a backreference in the pattern can read:
    /// a numbered one's group, every group of a named one's name. Sorted, each
    /// once, allocated with `self.allocator`.
    fn referencedGroups(self: *BacktrackEngine) ![]usize {
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.allocator);
        var indices: std.ArrayList(usize) = .empty;
        errdefer indices.deinit(self.allocator);
        var pending: std.ArrayList(*ast.Node) = .empty;
        defer pending.deinit(self.allocator);
        var current: ?*ast.Node = self.ast_root;
        while (current) |n| : (current = pending.pop()) {
            if (n.node_type == .backref) {
                const backref = n.data.backref;
                if (backref.name) |name| try names.append(self.allocator, name) else try indices.append(self.allocator, backref.index);
            }
            try self.pushNodeChildren(&pending, n);
        }
        if (names.items.len != 0) {
            current = self.ast_root;
            while (current) |n| : (current = pending.pop()) {
                if (n.node_type == .group) {
                    const group = n.data.group;
                    if (group.name) |group_name| if (group.capture_index) |index| for (names.items) |name| {
                        if (std.mem.eql(u8, name, group_name)) {
                            try indices.append(self.allocator, index);
                            break;
                        }
                    };
                }
                try self.pushNodeChildren(&pending, n);
            }
        }
        std.mem.sort(usize, indices.items, {}, std.sort.asc(usize));
        var kept: usize = 0;
        for (indices.items) |index| {
            if (index == 0 or index > self.captures.len) continue;
            if (kept != 0 and indices.items[kept - 1] == index) continue;
            indices.items[kept] = index;
            kept += 1;
        }
        indices.shrinkRetainingCapacity(kept);
        return indices.toOwnedSlice(self.allocator);
    }

    /// One search; `allow_memo` false runs it without the loop memo and the
    /// pieces that need it (see `SearchMemo`), as 0.5.2 did.
    fn findOnce(self: *BacktrackEngine, input: []const u8, start: usize, prefix: ?[]const u8, allow_memo: bool) ?BacktrackMatch {
        self.input = input;

        const codepoint_search = self.flags.unicode or containsCodepointAtom(self.ast_root);
        var pos: usize = @min(start, input.len);
        // One ReDoS step budget for the whole search, NOT per start position.
        // Resetting it each position let total backtracking reach
        // O(input.len * max_steps): on a large input that never matches, every
        // one of millions of start positions could burn the full per-position
        // budget, an effective (Zig-level, uninterruptible) infinite loop. With a
        // single budget, once it is spent matchNode fail-fasts at every remaining
        // position, so the search terminates.
        self.step_count = 0;
        self.match_error = null;
        // Atomic groups need the continuation matcher, whose choice stack an
        // atomic group can cut.
        // Loops over a body with choices are not a reason to take the whole
        // pattern there: the matchNode engine hands just the parts that need
        // it to the continuation matcher (see `continuationFirst`).
        const capture_continuations = (self.flags.ecmascript and
            (self.hasBackreference(self.ast_root) or self.hasLazyQuantifier(self.ast_root))) or
            self.hasAtomicGroup(self.ast_root);
        // The memo keeps those loops from re-exploring failed states, which
        // plain backtracking does exponentially often (see `SearchMemo`).
        var memo: SearchMemo = .{};
        defer memo.deinit(self.allocator);
        // Only a loop over a body with choices can re-explore states; other
        // continuation patterns (a lazy scan) keep the matcher's own memory.
        const use_memo = self.memoApplies();
        // Without the memo the continuation matcher is exponential where this
        // engine is not, so a search the memo has outgrown keeps 0.5.2's
        // matching here, its loops included (`findFromWithPrefix`).
        memo.referenced = self.referenced;
        self.memo = if (use_memo and allow_memo) &memo else null;
        self.hybrid = use_memo and allow_memo and !capture_continuations;
        defer {
            self.memo = null;
            self.hybrid = false;
        }
        while (pos <= input.len) {
            if (prefix) |literal| {
                // ECMA-262 RegExpBuiltinExec searches starts in order. A
                // required literal rules out intervening starts without
                // executing matching states; all real candidates still share
                // the single budget initialized above.
                pos += std.mem.indexOf(u8, input[pos..], literal) orelse return null;
            }
            self.resetCaptures();
            const end = if (capture_continuations)
                self.matchWithContinuations(self.ast_root, pos, false, .first) catch |err| {
                    self.match_error = err;
                    return null;
                }
            else
                self.matchNode(self.ast_root, pos);
            // Exhaustion is not a failed assertion: a negative lookaround can
            // invert that failure into success. The public Regex boundary
            // reports Timeout, and must never receive an unverified match.
            if (self.match_error != null or self.step_count > self.max_steps) return null;
            if (end) |end_pos| {
                // The continuation matcher has already validated every node,
                // including an unmatched backreference that consumes nothing.
                // A backreference to an empty or (in ECMAScript) unset group
                // matches empty, which canMatchEmpty does not count.
                if (end_pos > pos or (end_pos == pos and (capture_continuations or self.canMatchEmpty(self.ast_root) or self.hasBackreference(self.ast_root)))) {
                    // Found a match
                    const captures = self.allocator.alloc(BacktrackMatch.CaptureGroup, self.captures.len) catch |err| {
                        self.match_error = err;
                        return null;
                    };
                    for (self.captures, 0..) |cap, i| {
                        captures[i] = .{
                            .start = cap.start,
                            .end = cap.end,
                            .matched = cap.matched,
                        };
                    }

                    return BacktrackMatch{
                        .start = pos,
                        .end = end_pos,
                        .captures = captures,
                    };
                }
            }
            if (pos == input.len) break;
            pos = if (codepoint_search) nextCodepointStart(input, pos) else pos + 1;
        }
        return null;
    }

    const FlagsInt = @typeInfo(common.CompileFlags).@"struct".backing_integer.?;

    /// One continuation task, as the memo identifies it.
    const ChainKey = struct { tag: u8, a: usize = 0, b: usize = 0, c: usize = 0, d: usize = 0, e: usize = 0, next: u32 };

    /// A loop about to run one more iteration, with everything its outcome
    /// depends on: the loop, the rest of the match after it, the position, the
    /// scoped flags, the direction, and the spans a backreference can read.
    ///
    /// `pending` stands in for the start positions of the iterations still
    /// open in the rest (their `advance` tasks), which `chain_ids` leaves out.
    /// Along one path the position only moves one way, so an open iteration
    /// that started anywhere but here can no longer end empty, and how far
    /// back it started cannot matter; bit i is set when the i-th open
    /// iteration started exactly here, the one case where it can.
    ///
    /// `captures` stands in for the spans of the groups a backreference reads
    /// (`SearchMemo.captureId`), 0 when the pattern has none: the rest can
    /// only go differently from equal states when a reference reads a
    /// different span.
    const StateKey = struct { child: usize, min: usize, max: usize, greedy: bool, rest: u32, pending: u64, position: usize, flags: FlagsInt, reverse: bool, captures: u32 };

    /// The memo's budget: the most loop states, chain ids, or choices one
    /// continuation invocation may hold, each. A loop over an ambiguous body
    /// keeps a few to a dozen states per input byte, so a long enough input
    /// outgrows it; the search then stops with `error.MemoExhausted` and runs
    /// again without the memo (`findFromWithPrefix`), rather than going on
    /// unmemoized, which can be exponential. This caps what the memo can make
    /// one search allocate at a few tens of megabytes.
    const memo_state_floor = 1 << 16;

    const MemoVerdict = enum { explore, fail, succeed };

    /// What the memo says about one loop step (see `SearchMemo`), recording the
    /// state as it goes. An error means the memo could not allocate; the
    /// caller turns it off and explores normally.
    fn memoStep(
        self: *BacktrackEngine,
        memo: *SearchMemo,
        repeat: ContinuationRepeat,
        head: ?*ContinuationLink,
        position: usize,
        comptime reverse: bool,
        generation: u32,
        path: *std.ArrayList(StateKey),
        record_successes: bool,
        arena: std.mem.Allocator,
    ) !MemoVerdict {
        // Iterations still required that cannot fit in the input left fail
        // now: below min the count is part of the state, and a large min
        // would otherwise try count x position states before giving up.
        if (repeat.min > 0) {
            const width = try memo.minWidth(self.allocator, repeat.child);
            const remaining = if (reverse) position else self.input.len - position;
            if (width > 0 and repeat.min > remaining / width) return .fail;
        }
        const pending = pendingIterations(head, position) orelse return .explore;
        const key = StateKey{
            .child = @intFromPtr(repeat.child),
            .min = repeat.min,
            .max = if (repeat.max) |m| m + 1 else 0,
            .greedy = repeat.greedy,
            .rest = try memo.chainIdOf(self.allocator, head),
            .pending = pending,
            .position = position,
            .flags = @bitCast(self.flags),
            .reverse = reverse,
            .captures = try memo.captureId(self.allocator, self.captures),
        };
        if (record_successes and memo.succeeded.contains(key)) {
            for (path.items) |earlier| if (memo.succeeded.count() < memo.cap) try memo.succeeded.put(self.allocator, earlier, {});
            return .succeed;
        }
        if (memo.states.getPtr(key)) |seen| {
            if (seen.* == generation or memo.isFailed(seen.*)) return .fail;
            // Reached before by an invocation that did not fail (a lookaround
            // that succeeded, or one collecting ends): no verdict to reuse.
            seen.* = generation;
        } else {
            if (memo.states.count() >= memo.cap) return error.MemoExhausted;
            try memo.states.put(self.allocator, key, generation);
        }
        if (record_successes and memo.succeeded.count() < memo.cap) try path.append(arena, key);
        return .explore;
    }

    /// The `pending` bits of a state at `position` with rest `head` (see
    /// `StateKey`), or null when the rest holds more open iterations than
    /// the bits can tell apart, and the state is not memoized.
    fn pendingIterations(head: ?*ContinuationLink, position: usize) ?u64 {
        var bits: u64 = 0;
        var index: u7 = 0;
        var link = head;
        while (link) |current| : (link = current.next) {
            if (current.task != .advance) continue;
            if (index == 64) return null;
            if (current.task.advance.start == position) bits |= @as(u64, 1) << @intCast(index);
            index += 1;
        }
        return bits;
    }

    /// What one search has learned about its continuation states.
    ///
    /// The continuation matcher explores choices in priority order and returns
    /// as soon as a path reaches the end of the match, so a state it reaches a
    /// second time can only have failed the first time: had it succeeded, the
    /// search would already be over. A loop state is therefore explored once
    /// per invocation, which keeps a loop over a body with choices from trying
    /// the same decompositions exponentially often (RE2's bit-state
    /// backtracker uses the same rule). States from an invocation that failed
    /// outright stay failed for the rest of the search, so a later start
    /// position, or the same lookaround at another position, reuses them; an
    /// invocation that succeeded leaves nothing behind.
    ///
    /// States are compared by structure, not by link address: `chain_ids`
    /// gives equal ids to continuations with equal tasks and equal rests, so
    /// the same loop at the same position with the same remainder is the same
    /// state wherever it is reached. A backreference makes the rest depend on
    /// the spans it reads, so those are part of each state (`referenced`).
    /// Only valid when no atomic group cuts choices; `findFromWithPrefix`
    /// leaves the memo off otherwise.
    pub const SearchMemo = struct {
        chain_ids: std.AutoHashMapUnmanaged(ChainKey, u32) = .empty,
        /// Each loop state reached, with the generation (one per matcher
        /// invocation) that last reached it. A state whose generation is the
        /// current invocation's, or one that failed outright, fails.
        states: std.AutoHashMapUnmanaged(StateKey, u32) = .empty,
        /// Generations whose invocation failed: marking one bit replaces
        /// copying every state it reached.
        failed_generations: std.DynamicBitSetUnmanaged = .{},
        next_generation: u32 = 0,
        /// The most entries each table holds (`memo_state_floor`).
        cap: usize = memo_state_floor,
        /// States on a path that completed a lookaround body with no
        /// capturing group. A lookaround's result depends only on where it
        /// is tried, so reaching one of these again in such a body is a
        /// success; with no capture to set, nothing is lost by stopping. This
        /// keeps a lookbehind over a loop, tried at every start, from
        /// rescanning everything before it each time.
        succeeded: std.AutoHashMapUnmanaged(StateKey, void) = .empty,
        /// Each loop body's fewest bytes, computed on first use.
        min_widths: std.AutoHashMapUnmanaged(usize, usize) = .empty,
        /// The groups a backreference can read (1-based, sorted), whose spans
        /// are part of every state; empty when the pattern has none. Borrowed
        /// from the engine.
        referenced: []const usize = &.{},
        /// The ids `captureId` gives those spans, keyed by their encoding.
        capture_ids: std.StringHashMapUnmanaged(u32) = .empty,
        /// Scratch for encoding the spans of one state.
        capture_scratch: std.ArrayList(u8) = .empty,

        fn deinit(memo: *SearchMemo, allocator: std.mem.Allocator) void {
            memo.chain_ids.deinit(allocator);
            memo.states.deinit(allocator);
            memo.failed_generations.deinit(allocator);
            memo.succeeded.deinit(allocator);
            memo.min_widths.deinit(allocator);
            var keys = memo.capture_ids.keyIterator();
            while (keys.next()) |key| allocator.free(key.*);
            memo.capture_ids.deinit(allocator);
            memo.capture_scratch.deinit(allocator);
        }

        fn isReferenced(memo: *const SearchMemo, index: usize) bool {
            return std.sort.binarySearch(usize, memo.referenced, index, struct {
                fn order(wanted: usize, item: usize) std.math.Order {
                    return std.math.order(wanted, item);
                }
            }.order) != null;
        }

        /// The id of the referenced groups' spans in `captures`: equal spans,
        /// equal ids. 0 when the pattern has no backreference.
        fn captureId(memo: *SearchMemo, allocator: std.mem.Allocator, captures: []const CaptureGroup) !u32 {
            if (memo.referenced.len == 0) return 0;
            memo.capture_scratch.clearRetainingCapacity();
            for (memo.referenced) |index| {
                const capture = captures[index - 1];
                const span: [2]u64 = if (capture.matched) .{ capture.start, capture.end } else .{ std.math.maxInt(u64), 0 };
                try memo.capture_scratch.appendSlice(allocator, std.mem.asBytes(&span));
            }
            if (memo.capture_ids.get(memo.capture_scratch.items)) |id| return id;
            if (memo.capture_ids.count() >= memo.cap) return error.MemoExhausted;
            const owned = try allocator.dupe(u8, memo.capture_scratch.items);
            errdefer allocator.free(owned);
            const id: u32 = @intCast(memo.capture_ids.count() + 1);
            try memo.capture_ids.put(allocator, owned, id);
            return id;
        }

        fn newGeneration(memo: *SearchMemo) u32 {
            const generation = memo.next_generation;
            memo.next_generation += 1;
            return generation;
        }

        fn markFailed(memo: *SearchMemo, allocator: std.mem.Allocator, generation: u32) !void {
            if (generation >= memo.failed_generations.bit_length)
                try memo.failed_generations.resize(allocator, @max(64, 2 * (@as(usize, generation) + 1)), false);
            memo.failed_generations.set(generation);
        }

        fn isFailed(memo: *const SearchMemo, generation: u32) bool {
            return generation < memo.failed_generations.bit_length and memo.failed_generations.isSet(generation);
        }

        /// The fewest bytes one iteration of `child` consumes; 0 when that is
        /// not known, as for a Unicode set, which may match the empty string.
        fn minWidth(memo: *SearchMemo, allocator: std.mem.Allocator, child: *ast.Node) !usize {
            if (child.facts.codepoint_atom) return 0;
            const entry = try memo.min_widths.getOrPut(allocator, @intFromPtr(child));
            if (!entry.found_existing) {
                var opt = @import("optimizer.zig").Optimizer.init(allocator);
                entry.value_ptr.* = opt.minLength(child) catch |err| {
                    _ = memo.min_widths.remove(@intFromPtr(child));
                    return err;
                };
            }
            return entry.value_ptr.*;
        }

        /// The id of the chain `task` followed by the chain `next` (0 for
        /// the empty chain).
        fn chainId(memo: *SearchMemo, allocator: std.mem.Allocator, task: ContinuationTask, next: u32) !u32 {
            const key: ChainKey = switch (task) {
                .node => |node| .{ .tag = 0, .a = @intFromPtr(node), .next = next },
                // An open group's start matters only to a backreference that
                // reads the group; for any other it is not part of the state.
                .finish_group => |group| .{
                    .tag = 1,
                    .a = if (group.index) |i| i + 1 else 0,
                    .b = if (group.index) |i| (if (memo.isReferenced(i)) group.start + 1 else 0) else 0,
                    .c = @as(FlagsInt, @bitCast(group.flags)),
                    .next = next,
                },
                .repeat => |repeat| .{ .tag = 2, .a = @intFromPtr(repeat.child), .b = repeat.min, .c = if (repeat.max) |m| m + 1 else 0, .d = @intFromBool(repeat.greedy), .next = next },
                // The iteration's start is left out here and carried by
                // `StateKey.pending` instead.
                .advance => |advance| .{
                    .tag = 3,
                    .a = @intFromPtr(advance.next.child),
                    .b = advance.next.min,
                    .c = if (advance.next.max) |m| m + 1 else 0,
                    .e = @as(usize, @intFromBool(advance.next.greedy)) | @as(usize, @intFromBool(advance.required)) << 1,
                    .next = next,
                },
                .clear => |node| .{ .tag = 4, .a = @intFromPtr(node), .next = next },
                .commit => |depth| .{ .tag = 5, .a = depth, .next = next },
            };
            if (memo.chain_ids.count() >= memo.cap and !memo.chain_ids.contains(key)) return error.MemoExhausted;
            const entry = try memo.chain_ids.getOrPut(allocator, key);
            // 0 is "not computed" and 1 the empty chain.
            if (!entry.found_existing) entry.value_ptr.* = @intCast(memo.chain_ids.count() + 1);
            return entry.value_ptr.*;
        }

        /// The structural id of the chain starting at `head`, computed for
        /// every link on it that does not have one yet. Only loop steps need
        /// ids, so most links never get one.
        fn chainIdOf(memo: *SearchMemo, allocator: std.mem.Allocator, head: ?*ContinuationLink) !u32 {
            var unknown: std.ArrayList(*ContinuationLink) = .empty;
            defer unknown.deinit(allocator);
            var link = head;
            var id: u32 = 1;
            while (link) |current| {
                if (current.id != 0) {
                    id = current.id;
                    break;
                }
                try unknown.append(allocator, current);
                link = current.next;
            }
            while (unknown.pop()) |current| {
                id = try memo.chainId(allocator, current.task, id);
                current.id = id;
            }
            return id;
        }
    };

    const ContinuationRepeat = struct {
        child: *ast.Node,
        min: usize,
        max: ?usize,
        greedy: bool,
    };

    const ContinuationTask = union(enum) {
        node: *ast.Node,
        finish_group: struct { index: ?usize, start: usize, flags: common.CompileFlags },
        repeat: ContinuationRepeat,
        advance: struct { next: ContinuationRepeat, start: usize, required: bool },
        clear: *ast.Node,
        /// The end of an atomic group's body: drop every choice made since
        /// the group began, so the match never returns into it.
        commit: usize,
    };

    const ContinuationLink = struct {
        task: ContinuationTask,
        next: ?*ContinuationLink,
        references: usize,
        /// This chain's structural id, computed on first use by `chainIdOf`
        /// (0 until then).
        id: u32 = 0,
    };

    // Choice heads share immutable tails. Recycle a link only when neither the
    // running path nor a saved alternative can reach it. A lazy scan otherwise
    // retains every visited character's state until the whole match returns.
    const ContinuationPool = struct {
        allocator: std.mem.Allocator,
        free: ?*ContinuationLink = null,

        fn share(head: ?*ContinuationLink) ?*ContinuationLink {
            if (head) |link| link.references += 1;
            return head;
        }

        // Transfers the caller's tail reference into the new link.
        fn push(self: *ContinuationPool, next: ?*ContinuationLink, task: ContinuationTask) !*ContinuationLink {
            const link = if (self.free) |available| blk: {
                self.free = available.next;
                break :blk available;
            } else try self.allocator.create(ContinuationLink);
            link.* = .{ .task = task, .next = next, .references = 1 };
            return link;
        }

        fn release(self: *ContinuationPool, head: ?*ContinuationLink) void {
            var current = head;
            while (current) |link| {
                std.debug.assert(link.references != 0);
                link.references -= 1;
                if (link.references != 0) return;
                current = link.next;
                link.next = self.free;
                self.free = link;
            }
        }

        fn pop(self: *ContinuationPool, head: *?*ContinuationLink) ?ContinuationTask {
            const link = head.* orelse return null;
            const task = link.task;
            head.* = share(link.next);
            self.release(link);
            return task;
        }
    };

    /// What one continuation-matcher invocation is asked for.
    const ContinuationMode = union(enum) {
        /// The first end, in priority order.
        first,
        /// Whether a lookaround body matches; true when the body has no
        /// capturing group, so the memo may record successes
        /// (`SearchMemo.succeeded`).
        assertion: bool,
        /// Every end, in priority order and each once, appended here. The
        /// invocation then reports no match and restores the captures.
        collect: *std.ArrayList(usize),
        /// A match ending exactly here, with its captures.
        target: usize,
    };

    fn matchWithContinuations(self: *BacktrackEngine, root: *ast.Node, start: usize, comptime reverse: bool, mode: ContinuationMode) anyerror!?usize {
        // ECMA-262 CompileSubpattern passes a continuation through every choice.
        // An ending position alone cannot represent paths whose captures differ:
        // a later backreference must be able to reject one and accept another.
        const Choice = struct {
            head: ?*ContinuationLink,
            position: usize,
            flags: common.CompileFlags,
            captures: []CaptureGroup,
            /// The length of `path` when this choice was saved.
            path_len: usize,
        };
        const initial = try self.allocator.dupe(CaptureGroup, self.captures);
        defer self.allocator.free(initial);
        var completed = false;
        defer if (!completed) {
            @memcpy(self.captures, initial);
        };
        const original_flags = self.flags;
        defer self.flags = original_flags;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var pool = ContinuationPool{ .allocator = allocator };
        // This invocation's generation in the memo (see `SearchMemo`), and the
        // loop states on the path being tried, which all succeed if it does.
        const generation: u32 = if (self.memo) |memo| memo.newGeneration() else 0;
        var path: std.ArrayList(StateKey) = .empty;
        const record_successes = self.memo != null and switch (mode) {
            .assertion => |capture_free| capture_free,
            else => false,
        };
        // Reaching the end decides an invocation only in these modes; one that
        // collects ends or wants a given end keeps going, so its states never
        // count as failed.
        const decides = mode == .first or mode == .assertion;
        // Ends this invocation reached, when it collects them: one that
        // reached none failed outright, like a deciding one. `listed` holds
        // the ends already in the caller's list (it may collect into one list
        // more than once), so each is added once in constant time.
        var collected: usize = 0;
        var listed: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer listed.deinit(self.allocator);
        if (mode == .collect) for (mode.collect.items) |end| try listed.put(self.allocator, end, {});
        var retired_captures: std.ArrayList([]CaptureGroup) = .empty;
        var choices: std.ArrayList(Choice) = .empty;
        defer choices.deinit(self.allocator);
        var head: ?*ContinuationLink = try pool.push(null, .{ .node = root });
        var position = start;
        while (true) {
            if (self.match_error) |err| return err;
            if (self.step_count > self.max_steps) return error.Timeout;
            var failed = false;
            const next_task = pool.pop(&head);
            if (next_task == null) {
                switch (mode) {
                    .first, .assertion => {
                        if (record_successes) if (self.memo) |memo| for (path.items) |key| {
                            if (memo.succeeded.count() >= memo.cap) break;
                            memo.succeeded.put(self.allocator, key, {}) catch {
                                self.memo = null;
                                break;
                            };
                        };
                        completed = true;
                        return position;
                    },
                    .target => |end| if (position == end) {
                        completed = true;
                        return position;
                    },
                    .collect => |ends| {
                        // Counted even when the list already holds it (the
                        // caller may collect into one list more than once):
                        // an end was reached, so this invocation did not fail.
                        collected += 1;
                        if (!(try listed.getOrPut(self.allocator, position)).found_existing)
                            try ends.append(self.allocator, position);
                    },
                }
                // Not the end wanted, or every end wanted: try the next path.
                failed = true;
            }
            if (next_task) |task| {
                self.step_count += 1;
                if (self.step_count > self.max_steps) return error.Timeout;
                switch (task) {
                    .node => |node| switch (node.node_type) {
                        .concat => {
                            const pair = node.data.concat;
                            head = try pool.push(head, .{ .node = if (reverse) pair.left else pair.right });
                            head = try pool.push(head, .{ .node = if (reverse) pair.right else pair.left });
                        },
                        .alternation => {
                            const alt = node.data.alternation;
                            if (self.memo != null and choices.items.len >= self.choiceBudget()) return error.MemoExhausted;
                            try choices.append(self.allocator, .{
                                .head = try pool.push(ContinuationPool.share(head), .{ .node = alt.right }),
                                .position = position,
                                .flags = self.flags,
                                .captures = try snapshotCaptures(allocator, &retired_captures, self.captures),
                                .path_len = path.items.len,
                            });
                            head = try pool.push(head, .{ .node = alt.left });
                        },
                        .group => {
                            const group = node.data.group;
                            const flags = self.enterGroupFlags(group);
                            head = try pool.push(head, .{ .finish_group = .{ .index = group.capture_index, .start = position, .flags = flags } });
                            if (group.atomic) head = try pool.push(head, .{ .commit = choices.items.len });
                            head = try pool.push(head, .{ .node = group.child });
                        },
                        .star, .plus, .optional, .repeat => {
                            const repeat: ContinuationRepeat = switch (node.node_type) {
                                .star => .{ .child = node.data.star.child, .min = 0, .max = null, .greedy = node.data.star.greedy },
                                .plus => .{ .child = node.data.plus.child, .min = 1, .max = null, .greedy = node.data.plus.greedy },
                                .optional => .{ .child = node.data.optional.child, .min = 0, .max = 1, .greedy = node.data.optional.greedy },
                                .repeat => .{ .child = node.data.repeat.child, .min = node.data.repeat.bounds.min, .max = node.data.repeat.bounds.max, .greedy = node.data.repeat.greedy },
                                else => unreachable,
                            };
                            head = try pool.push(head, .{ .repeat = repeat });
                        },
                        .lookahead, .lookbehind => {
                            const assertion = if (node.node_type == .lookahead) node.data.lookahead else node.data.lookbehind;
                            const saved = if (!assertion.positive) try allocator.dupe(CaptureGroup, self.captures) else null;
                            // Assertions are atomic: later failure cannot resume an
                            // alternative inside an already successful assertion.
                            const matched = if (node.node_type == .lookbehind)
                                (if (try self.forwardLookbehind(assertion.child, position)) |forward| forward else (try self.matchWithContinuations(assertion.child, position, true, .{ .assertion = !assertion.child.facts.capturing_group })) != null)
                            else
                                (try self.matchWithContinuations(assertion.child, position, false, .{ .assertion = !assertion.child.facts.capturing_group })) != null;
                            if (saved) |caps| @memcpy(self.captures, caps);
                            failed = matched != assertion.positive;
                        },
                        else => {
                            const end = if (reverse) self.matchReverseNode(node, position) else self.matchNode(node, position);
                            if (end) |next| position = next else failed = true;
                        },
                    },
                    .finish_group => |group| {
                        if (group.index) |index| {
                            if (index > 0 and index <= self.captures.len) self.captures[index - 1] = .{
                                .start = if (reverse) position else group.start,
                                .end = if (reverse) group.start else position,
                                .matched = true,
                            };
                        }
                        self.flags = group.flags;
                    },
                    .repeat => |repeat| repeat: {
                        if (self.memo) |memo| {
                            const verdict = self.memoStep(memo, repeat, head, position, reverse, generation, &path, record_successes, allocator) catch |err| switch (err) {
                                // The memo only prunes: without memory for it,
                                // go on without it.
                                error.OutOfMemory => blk: {
                                    self.memo = null;
                                    break :blk .explore;
                                },
                                else => |e| return e,
                            };
                            switch (verdict) {
                                .explore => {},
                                .fail => {
                                    failed = true;
                                    break :repeat;
                                },
                                .succeed => {
                                    completed = true;
                                    return position;
                                },
                            }
                        }
                        if (repeat.max == null or repeat.max.? != 0) {
                            const next = ContinuationRepeat{ .child = repeat.child, .min = repeat.min -| 1, .max = if (repeat.max) |max| max - 1 else null, .greedy = repeat.greedy };
                            var child = try pool.push(ContinuationPool.share(head), .{ .advance = .{ .next = next, .start = position, .required = repeat.min != 0 } });
                            child = try pool.push(child, .{ .node = repeat.child });
                            // ECMAScript resets the body's captures at each
                            // iteration; PCRE keeps a group's value from an earlier
                            // iteration that a later one does not set.
                            if (!self.pcreLoops()) child = try pool.push(child, .{ .clear = repeat.child });
                            if (repeat.min == 0) {
                                if (self.memo != null and choices.items.len >= self.choiceBudget()) return error.MemoExhausted;
                                try choices.append(self.allocator, .{
                                    .head = if (repeat.greedy) head else child,
                                    .position = position,
                                    .flags = self.flags,
                                    .captures = try snapshotCaptures(allocator, &retired_captures, self.captures),
                                    .path_len = path.items.len,
                                });
                                if (repeat.greedy) head = child;
                            } else {
                                pool.release(head);
                                head = child;
                            }
                        }
                    },
                    .advance => |advance| {
                        // An iteration that consumed nothing. ECMAScript's
                        // RepeatMatcher rejects it once min is met (required
                        // empty iterations still consume the budget). PCRE ends
                        // an unbounded loop there once no iteration is still
                        // required, going on with the rest, and lets a bounded
                        // one go on to its next copy.
                        const empty = position == advance.start;
                        if (empty and self.pcreLoops()) {
                            if (advance.next.max != null or advance.next.min != 0)
                                head = try pool.push(head, .{ .repeat = advance.next });
                        } else if (empty and !advance.required) {
                            failed = true;
                        } else head = try pool.push(head, .{ .repeat = advance.next });
                    },
                    .clear => |node| {
                        self.clearCapturesIn(node);
                        if (self.match_error) |err| return err;
                    },
                    .commit => |depth| {
                        while (choices.items.len > depth) {
                            const choice = choices.pop().?;
                            pool.release(choice.head);
                            try retired_captures.append(allocator, choice.captures);
                        }
                    },
                }
            }
            if (failed) {
                const choice = choices.pop() orelse {
                    // Every path failed, so every state this invocation reached
                    // fails wherever else it is reached in this search.
                    const failed_outright = decides or (mode == .collect and collected == 0);
                    if (failed_outright) if (self.memo) |memo| memo.markFailed(self.allocator, generation) catch {
                        self.memo = null;
                    };
                    return null;
                };
                pool.release(head);
                head = choice.head;
                position = choice.position;
                path.shrinkRetainingCapacity(choice.path_len);
                self.flags = choice.flags;
                @memcpy(self.captures, choice.captures);
                try retired_captures.append(allocator, choice.captures);
            }
        }
    }

    fn snapshotCaptures(allocator: std.mem.Allocator, retired: *std.ArrayList([]CaptureGroup), captures: []const CaptureGroup) ![]CaptureGroup {
        const copy = retired.pop() orelse return allocator.dupe(CaptureGroup, captures);
        @memcpy(copy, captures);
        return copy;
    }

    fn containsCodepointAtom(node: *ast.Node) bool {
        if (node.facts.known) return node.facts.codepoint_atom;
        return switch (node.node_type) {
            .unicode_property, .class_set => true,
            .concat => containsCodepointAtom(node.data.concat.left) or containsCodepointAtom(node.data.concat.right),
            .alternation => containsCodepointAtom(node.data.alternation.left) or containsCodepointAtom(node.data.alternation.right),
            .star => containsCodepointAtom(node.data.star.child),
            .plus => containsCodepointAtom(node.data.plus.child),
            .optional => containsCodepointAtom(node.data.optional.child),
            .repeat => containsCodepointAtom(node.data.repeat.child),
            .group => containsCodepointAtom(node.data.group.child),
            .lookahead => containsCodepointAtom(node.data.lookahead.child),
            .lookbehind => containsCodepointAtom(node.data.lookbehind.child),
            else => false,
        };
    }

    fn nextCodepointStart(input: []const u8, pos: usize) usize {
        const len = common.ecmaCodePointLen(input, pos) orelse return pos + 1;
        return pos + len;
    }

    /// Reset all capture groups
    pub fn resetCaptures(self: *BacktrackEngine) void {
        for (self.captures) |*cap| {
            cap.matched = false;
            cap.start = 0;
            cap.end = 0;
        }
    }

    /// Check if a node can match empty string
    pub fn canMatchEmpty(self: *BacktrackEngine, node: *ast.Node) bool {
        return switch (node.node_type) {
            .literal, .any, .char_class, .backref, .unicode_property, .class_set => false,
            .empty, .anchor, .lookahead, .lookbehind => true,
            .concat => self.canMatchEmpty(node.data.concat.left) and self.canMatchEmpty(node.data.concat.right),
            .alternation => self.canMatchEmpty(node.data.alternation.left) or self.canMatchEmpty(node.data.alternation.right),
            .star, .optional => true,
            .plus => self.canMatchEmpty(node.data.plus.child),
            .repeat => node.data.repeat.bounds.min == 0 or self.canMatchEmpty(node.data.repeat.child),
            .group => self.canMatchEmpty(node.data.group.child),
        };
    }

    /// Match a node starting at position, returns end position or null if no match
    /// Returns position where match ended, or null if no match
    pub fn matchNode(self: *BacktrackEngine, node: *ast.Node, pos: usize) ?usize {
        // ReDoS protection: increment step counter and check limit
        self.step_count += 1;
        if (self.match_error != null or self.step_count > self.max_steps) {
            return null; // Abort matching to prevent catastrophic backtracking
        }

        return switch (node.node_type) {
            .literal => self.matchLiteral(node.data.literal, pos),
            .any => self.matchAny(pos),
            .concat => if (self.hybrid and node.data.concat.left.facts.trailing_choice_loop)
                self.continuationFirst(node, pos)
            else
                self.matchConcat(node.data.concat, pos),
            .alternation => self.matchAlternation(node.data.alternation, pos),
            .star => if (self.hybrid and self.loopNeedsContinuations(node))
                self.continuationFirst(node, pos)
            else
                self.matchStar(node.data.star, pos),
            .plus => if (self.hybrid and self.loopNeedsContinuations(node))
                self.continuationFirst(node, pos)
            else
                self.matchPlus(node.data.plus, pos),
            .optional => self.matchOptional(node.data.optional, pos),
            .repeat => if (self.hybrid and self.loopNeedsContinuations(node))
                self.continuationFirst(node, pos)
            else
                self.matchRepeat(node.data.repeat, pos),
            .char_class => self.matchCharClass(node.data.char_class, pos),
            .group => self.matchGroup(node.data.group, pos),
            .anchor => self.matchAnchor(node.data.anchor, pos),
            .empty => pos,
            .lookahead => self.matchLookahead(node.data.lookahead, pos),
            .lookbehind => self.matchLookbehind(node.data.lookbehind, pos),
            .backref => self.matchBackreference(node.data.backref, pos),
            .unicode_property => self.matchUnicodeProperty(node.data.unicode_property, pos),
            .class_set => self.matchClassSet(node.data.class_set, pos),
        };
    }

    fn matchNodeProgress(self: *BacktrackEngine, node: *ast.Node, pos: usize) ?usize {
        const saved = self.allocator.alloc(CaptureGroup, self.captures.len) catch |err| return self.failWith(err, @as(?usize, null));
        defer self.allocator.free(saved);
        @memcpy(saved, self.captures);

        if (self.matchNode(node, pos)) |end| {
            if (end > pos) return end;
        }

        @memcpy(self.captures, saved);
        var positions = std.ArrayList(usize).initCapacity(self.allocator, 0) catch |err| return self.failWith(err, @as(?usize, null));
        defer positions.deinit(self.allocator);
        self.collectAllMatches(node, pos, &positions) catch |err| return self.failWith(err, @as(?usize, null));
        for (positions.items) |end| {
            if (end <= pos) continue;
            @memcpy(self.captures, saved);
            if (self.matchNodeConstrained(node, pos, end)) return end;
        }
        @memcpy(self.captures, saved);
        return null;
    }

    /// `\p{...}` / `\P{...}` — decode the UTF-8 code point at `pos`, test the
    /// General_Category property, and consume the whole code point on a match.
    fn matchUnicodeProperty(self: *BacktrackEngine, up: ast.Node.UnicodeProp, pos: usize) ?usize {
        if (pos >= self.input.len) return null;
        const dec = unicode_mod.decodeUtf8Lenient(self.input[pos..]) orelse return null;
        if (!self.matchesUnicodeProperty(up, dec.codepoint)) return null;
        return pos + dec.len;
    }

    fn matchLiteral(self: *BacktrackEngine, c: u8, pos: usize) ?usize {
        if (pos >= self.input.len) return null;

        const input_char = self.input[pos];
        const matches = if (self.flags.case_insensitive)
            std.ascii.toLower(input_char) == std.ascii.toLower(c)
        else
            input_char == c;

        return if (matches) pos + 1 else null;
    }

    fn matchAny(self: *BacktrackEngine, pos: usize) ?usize {
        const len = common.dotMatchLen(self.input, pos, self.flags) orelse return null;
        return pos + len;
    }

    fn matchConcat(self: *BacktrackEngine, concat: ast.Node.Concat, pos: usize) ?usize {
        const left_has_choices = self.hasQuantifiers(concat.left) or self.hasAlternation(concat.left);
        const right_has_choices = self.hasQuantifiers(concat.right) or self.hasAlternation(concat.right);

        if (left_has_choices or right_has_choices) {
            // Save captures before collecting positions (collection may corrupt them)
            const clean_captures = self.allocator.alloc(CaptureGroup, self.captures.len) catch |err| return self.failWith(err, @as(?usize, null));
            defer self.allocator.free(clean_captures);
            @memcpy(clean_captures, self.captures);

            // Collect all possible left-side ending positions
            var left_positions = std.ArrayList(usize).initCapacity(self.allocator, 0) catch |err| return self.failWith(err, @as(?usize, null));
            defer left_positions.deinit(self.allocator);

            if (left_has_choices) {
                self.collectAllMatches(concat.left, pos, &left_positions) catch |err| return self.failWith(err, @as(?usize, null));
            } else {
                if (self.matchNode(concat.left, pos)) |end| {
                    left_positions.append(self.allocator, end) catch |err| return self.failWith(err, @as(?usize, null));
                }
            }

            // The capture-fixup re-match below is only needed when the left side
            // actually has groups; skipping it keeps `\p{…}+`-style scans linear.
            const left_has_groups = self.hasCapturingGroup(concat.left);
            for (left_positions.items) |left_end| {
                // Restore clean captures before each attempt
                @memcpy(self.captures, clean_captures);

                // Re-match left to this specific end position to set captures correctly
                if (left_has_groups) {
                    if (left_has_choices) {
                        if (!self.matchNodeConstrained(concat.left, pos, left_end)) continue;
                    } else {
                        const fixed_end = self.matchNode(concat.left, pos) orelse continue;
                        if (fixed_end != left_end) continue;
                    }
                }

                // Save captures after left match
                const saved_captures = self.allocator.alloc(CaptureGroup, self.captures.len) catch |err| return self.failWith(err, @as(?usize, null));
                defer self.allocator.free(saved_captures);
                @memcpy(saved_captures, self.captures);

                if (right_has_choices and self.hybrid and self.tailLoopNeedsContinuations(concat.right)) {
                    // Only the right side's first end matters here, and the
                    // continuation matcher finds it without collecting the
                    // others (`continuationFirst`).
                    if (self.matchNode(concat.right, left_end)) |result| return result;
                } else if (right_has_choices) {
                    // Right side also has choices - collect all right positions
                    var right_positions = std.ArrayList(usize).initCapacity(self.allocator, 0) catch |err| return self.failWith(err, @as(?usize, null));
                    defer right_positions.deinit(self.allocator);

                    self.collectAllMatches(concat.right, left_end, &right_positions) catch |err| return self.failWith(err, @as(?usize, null));

                    for (right_positions.items) |right_end| {
                        @memcpy(self.captures, saved_captures);
                        if (self.matchNodeConstrained(concat.right, left_end, right_end)) return right_end;
                    }
                } else {
                    if (self.matchNode(concat.right, left_end)) |result| {
                        return result;
                    }
                }

                @memcpy(self.captures, saved_captures);
            }
            if (!right_has_choices and self.needsAnchoredRepeatedAlternationRecovery(concat.left, concat.right)) {
                var target = self.input.len;
                while (target >= pos) {
                    @memcpy(self.captures, clean_captures);
                    const screened = self.matchNode(concat.right, target) orelse {
                        if (target == pos) break;
                        target -= 1;
                        continue;
                    };
                    @memcpy(self.captures, clean_captures);
                    if (self.matchNodeConstrained(concat.left, pos, target)) {
                        @memcpy(self.captures, clean_captures);
                        _ = self.matchNodeConstrained(concat.left, pos, target);
                        if (self.matchNode(concat.right, target)) |result| return result;
                    }
                    _ = screened;
                    if (target == pos) break;
                    target -= 1;
                }
            }
            @memcpy(self.captures, clean_captures);
            return null;
        } else {
            // No choices anywhere in this sequence, so each element either
            // matches where the previous one ended or the whole sequence fails:
            // there is nothing to backtrack into. Walking the spine keeps a
            // 31,000-element sequence to one native frame (#23); only nesting
            // inside an element recurses, and the stack is touched at all only
            // for a left-leaning spine.
            var pending: std.ArrayList(*ast.Node) = .empty;
            defer pending.deinit(self.allocator);
            var current_pos = pos;
            var element = concat.left;
            var tail: ?*ast.Node = concat.right;
            while (true) {
                if (element.node_type == .concat) {
                    pending.append(self.allocator, element.data.concat.right) catch |err| return self.failWith(err, @as(?usize, null));
                    element = element.data.concat.left;
                    continue;
                }
                current_pos = self.matchNode(element, current_pos) orelse return null;
                if (pending.pop()) |deferred| {
                    element = deferred;
                    continue;
                }
                element = tail orelse return current_pos;
                tail = null;
            }
        }
    }

    /// Match a node from pos, constrained to end at exactly target_end.
    /// Sets captures correctly for groups along the way.
    fn matchNodeConstrained(self: *BacktrackEngine, node: *ast.Node, pos: usize, target_end: usize) bool {
        switch (node.node_type) {
            .literal => return if (self.matchLiteral(node.data.literal, pos)) |end| end == target_end else false,
            .any => return if (self.matchAny(pos)) |end| end == target_end else false,
            .char_class => return if (self.matchCharClass(node.data.char_class, pos)) |end| end == target_end else false,
            .unicode_property => return if (self.matchUnicodeProperty(node.data.unicode_property, pos)) |end| end == target_end else false,
            .class_set => return if (self.matchClassSet(node.data.class_set, pos)) |end| end == target_end else false,
            .anchor => return if (self.matchAnchor(node.data.anchor, pos)) |end| end == target_end else false,
            .empty => return pos == target_end,
            .group => {
                const group = node.data.group;
                const saved_flags = self.enterGroupFlags(group);
                defer self.flags = saved_flags;
                if (self.matchNodeConstrained(group.child, pos, target_end)) {
                    if (group.capture_index) |index| {
                        if (index > 0 and index <= self.captures.len) {
                            self.captures[index - 1] = .{
                                .start = pos,
                                .end = target_end,
                                .matched = true,
                            };
                        }
                    }
                    return true;
                }
                return false;
            },
            .concat => {
                const c = node.data.concat;
                if (self.hybrid and c.left.facts.trailing_choice_loop) return self.continuationTarget(node, pos, target_end);
                if (!self.hasQuantifiers(c.left) and !self.hasAlternation(c.left)) {
                    // Left is deterministic, match it and constrain right
                    if (self.matchNode(c.left, pos)) |split| {
                        return self.matchNodeConstrained(c.right, split, target_end);
                    }
                    return false;
                } else {
                    // Left has quantifiers or ordered alternatives: enumerate
                    // endpoints in the subtree's own order. Raw ascending splits
                    // choose the shortest valid capture and break ECMAScript
                    // backreference and alternation backtracking semantics.
                    const base_captures = self.allocator.alloc(CaptureGroup, self.captures.len) catch |err| return self.failWith(err, false);
                    defer self.allocator.free(base_captures);
                    @memcpy(base_captures, self.captures);

                    var splits = std.ArrayList(usize).initCapacity(self.allocator, 0) catch |err| return self.failWith(err, false);
                    defer splits.deinit(self.allocator);
                    self.collectAllMatches(c.left, pos, &splits) catch |err| return self.failWith(err, false);

                    for (splits.items) |split| {
                        if (split > target_end) continue;
                        @memcpy(self.captures, base_captures);
                        if (!self.matchNodeConstrained(c.left, pos, split)) continue;

                        if (self.hasQuantifiers(c.right) or self.hasAlternation(c.right)) {
                            if (self.matchNodeConstrained(c.right, split, target_end)) return true;
                        } else if (self.matchNode(c.right, split)) |right_end| {
                            if (right_end == target_end) return true;
                        }
                    }
                    if (self.canMatchEmpty(c.right)) {
                        @memcpy(self.captures, base_captures);
                        if (self.matchNodeConstrained(c.left, pos, target_end) and
                            self.matchNodeConstrained(c.right, target_end, target_end)) return true;
                    }
                    @memcpy(self.captures, base_captures);
                    return false;
                }
            },
            .star, .plus, .optional, .repeat => {
                if (self.hybrid and self.loopNeedsContinuations(node)) return self.continuationTarget(node, pos, target_end);
                return self.matchQuantifierConstrained(node, pos, target_end);
            },
            .alternation => {
                const saved = self.allocator.dupe(CaptureGroup, self.captures) catch |err| {
                    self.match_error = err;
                    return false;
                };
                defer self.allocator.free(saved);
                const left = self.matchNodeConstrained(node.data.alternation.left, pos, target_end);
                if (left and self.match_error == null) return true;
                @memcpy(self.captures, saved);
                if (self.match_error != null) return false;
                const right = self.matchNodeConstrained(node.data.alternation.right, pos, target_end);
                if (!right or self.match_error != null) @memcpy(self.captures, saved);
                return right and self.match_error == null;
            },
            .backref => {
                return if (self.matchBackreference(node.data.backref, pos)) |end| end == target_end else false;
            },
            .lookahead => {
                return if (self.matchLookahead(node.data.lookahead, pos)) |end| end == target_end else false;
            },
            .lookbehind => {
                return if (self.matchLookbehind(node.data.lookbehind, pos)) |end| end == target_end else false;
            },
        }
    }

    fn matchQuantifierConstrained(self: *BacktrackEngine, node: *ast.Node, pos: usize, target_end: usize) bool {
        if (node.node_type == .repeat and self.boundedRepeatHasChoices(node.data.repeat)) {
            return self.matchBoundedRepeatConstrained(node.data.repeat, pos, target_end, false);
        }
        if (node.node_type == .repeat and self.fixedRepeatHasChoices(node.data.repeat)) {
            return self.matchFixedRepeatConstrained(node.data.repeat, pos, target_end, false);
        }
        switch (node.node_type) {
            .star, .plus, .optional, .repeat => {
                const child = switch (node.node_type) {
                    .star => node.data.star.child,
                    .plus => node.data.plus.child,
                    .optional => node.data.optional.child,
                    .repeat => node.data.repeat.child,
                    else => unreachable,
                };
                const min: usize = switch (node.node_type) {
                    .star, .optional => 0,
                    .plus => 1,
                    .repeat => node.data.repeat.bounds.min,
                    else => unreachable,
                };

                if (node.node_type == .optional) {
                    if (pos == target_end) {
                        // A greedy PCRE `?` tries its body first, and takes it
                        // when it matches empty, captures and all (`(b?)?`
                        // sets group 1 to an empty span). ECMAScript rejects
                        // that empty iteration.
                        if (!self.flags.ecmascript and node.data.optional.greedy) self.keepEmptyIteration(child, pos);
                        return true;
                    }
                    return self.matchNodeConstrained(child, pos, target_end);
                }

                const max: ?usize = switch (node.node_type) {
                    .star, .plus => null,
                    .repeat => node.data.repeat.bounds.max,
                    else => unreachable,
                };
                if (!self.canMatchEmpty(child) and !self.hasQuantifiers(child) and !self.hasAlternation(child) and !self.hasBackreference(child))
                    return self.matchRepeatedChildConstrainedLinear(child, pos, target_end, min, max);
                const greedy = switch (node.node_type) {
                    .star => node.data.star.greedy,
                    .plus => node.data.plus.greedy,
                    .repeat => node.data.repeat.greedy,
                    else => unreachable,
                };
                return self.matchRepeatedChildConstrained(child, pos, target_end, 0, min, max, greedy);
            },
            else => return false,
        }
    }

    fn matchRepeatedChildConstrainedLinear(self: *BacktrackEngine, child: *ast.Node, pos: usize, target_end: usize, min: usize, max: ?usize) bool {
        const saved = self.allocator.alloc(CaptureGroup, self.captures.len) catch |err| return self.failWith(err, false);
        defer self.allocator.free(saved);
        @memcpy(saved, self.captures);

        var current = pos;
        var count: usize = 0;
        while (current < target_end) {
            if (max) |m| if (count >= m) {
                @memcpy(self.captures, saved);
                return false;
            };

            self.clearIterationCaptures(child);
            const end = self.matchNode(child, current) orelse {
                @memcpy(self.captures, saved);
                return false;
            };
            if (end <= current or end > target_end) {
                @memcpy(self.captures, saved);
                return false;
            }

            current = end;
            count += 1;
        }

        if (count < min) {
            @memcpy(self.captures, saved);
            return false;
        }
        return current == target_end;
    }

    /// `matchRepeatedChildConstrained` in PCRE mode, which takes an empty
    /// iteration where it comes in the body's order, a required one included:
    /// a bounded loop goes on to its next copy, an unbounded one ends there
    /// once no iteration is still required (`(a??){2}b` on `ab` makes the
    /// first copy empty and captures `a`). A greedy loop tries one more
    /// iteration before stopping, a lazy one stops first.
    fn matchRepeatedChildConstrainedPcre(self: *BacktrackEngine, child: *ast.Node, pos: usize, target_end: usize, count: usize, min: usize, max: ?usize, greedy: bool) bool {
        if (pos > target_end) return false;
        const can_stop = count >= min and pos == target_end;
        if (can_stop and !greedy) return true;
        if (max == null or count < max.?) {
            var saved: CaptureSnapshot = undefined;
            const caps = saved.take(self) orelse return false;
            defer saved.release(self);
            var ends = std.ArrayList(usize).initCapacity(self.allocator, 0) catch |err| return self.failWith(err, false);
            defer ends.deinit(self.allocator);
            self.collectAllMatches(child, pos, &ends) catch |err| return self.failWith(err, false);
            for (ends.items) |end| {
                if (end < pos or end > target_end) continue;
                @memcpy(self.captures, caps);
                if (!self.matchNodeConstrained(child, pos, end)) continue;
                if (end == pos and max == null and count + 1 >= min) {
                    // An unbounded loop ends at an empty iteration.
                    if (pos == target_end) return true;
                    continue;
                }
                if (self.matchRepeatedChildConstrainedPcre(child, end, target_end, count + 1, min, max, greedy)) return true;
                if (self.match_error != null) return false;
            }
            @memcpy(self.captures, caps);
        }
        return can_stop;
    }

    fn matchRepeatedChildConstrained(self: *BacktrackEngine, child: *ast.Node, pos: usize, target_end: usize, count: usize, min: usize, max: ?usize, greedy: bool) bool {
        if (!self.flags.ecmascript) return self.matchRepeatedChildConstrainedPcre(child, pos, target_end, count, min, max, greedy);
        if (count >= min and pos == target_end) return true;
        if (pos == target_end) {
            var n = count;
            while (n < min) : (n += 1) {
                if (!self.matchNodeConstrained(child, pos, target_end)) return false;
            }
            return true;
        }
        if (pos >= target_end) return false;
        if (max) |m| if (count >= m) return false;

        const saved = self.allocator.alloc(CaptureGroup, self.captures.len) catch |err| return self.failWith(err, false);
        defer self.allocator.free(saved);
        @memcpy(saved, self.captures);

        var ends = std.ArrayList(usize).initCapacity(self.allocator, 0) catch |err| return self.failWith(err, false);
        defer ends.deinit(self.allocator);
        self.collectAllMatches(child, pos, &ends) catch |err| return self.failWith(err, false);

        for (ends.items) |end| {
            if (end <= pos or end > target_end) continue;
            @memcpy(self.captures, saved);
            self.clearIterationCaptures(child);
            if (!self.matchNodeConstrained(child, pos, end)) continue;
            if (self.matchRepeatedChildConstrained(child, end, target_end, count + 1, min, max, greedy)) return true;
        }

        if (self.hasAlternation(child) and self.hasCapturingGroup(child)) {
            @memcpy(self.captures, saved);
            self.clearIterationCaptures(child);
            if (self.matchNodeConstrained(child, pos, target_end)) {
                if (self.matchRepeatedChildConstrained(child, target_end, target_end, count + 1, min, max, greedy)) return true;
            }
        }

        @memcpy(self.captures, saved);
        return false;
    }

    /// What a structural check decides about one node.
    const NodeVerdict = enum { matched, descend, skip };

    /// Store every structural fact the matcher asks about on each node of the
    /// tree, children before parents, so a search reads a node's facts instead
    /// of walking its subtree at every step. Those walks made matching cost the
    /// pattern size times the input length again for every node visited, which
    /// dominated long inputs (#53).
    ///
    /// It runs while the engine is built, before the tree can be shared, and a
    /// search only reads the facts, so concurrent searches stay safe. It uses an
    /// explicit stack for the reason `anyNodeMatches` documents (#23).
    pub fn analyze(allocator: std.mem.Allocator, root: *ast.Node) std.mem.Allocator.Error!void {
        const Visit = struct { node: *ast.Node, children_done: bool };
        var pending: std.ArrayList(Visit) = .empty;
        defer pending.deinit(allocator);
        try pending.append(allocator, .{ .node = root, .children_done = false });
        while (pending.pop()) |visit| {
            const node = visit.node;
            if (node.facts.known) continue;
            if (!visit.children_done) {
                try pending.append(allocator, .{ .node = node, .children_done = true });
                var buffer: [2]*ast.Node = undefined;
                for (children(node, &buffer)) |child| {
                    if (!child.facts.known) try pending.append(allocator, .{ .node = child, .children_done = false });
                }
                continue;
            }
            node.facts = factsOf(node);
        }
    }

    /// A node's direct children, in the order `pushNodeChildren` visits them.
    fn children(node: *ast.Node, buffer: *[2]*ast.Node) []*ast.Node {
        switch (node.node_type) {
            .concat => {
                buffer.* = .{ node.data.concat.left, node.data.concat.right };
                return buffer[0..2];
            },
            .alternation => {
                buffer.* = .{ node.data.alternation.left, node.data.alternation.right };
                return buffer[0..2];
            },
            .group => buffer[0] = node.data.group.child,
            .star => buffer[0] = node.data.star.child,
            .plus => buffer[0] = node.data.plus.child,
            .optional => buffer[0] = node.data.optional.child,
            .repeat => buffer[0] = node.data.repeat.child,
            .lookahead => buffer[0] = node.data.lookahead.child,
            .lookbehind => buffer[0] = node.data.lookbehind.child,
            else => return buffer[0..0],
        }
        return buffer[0..1];
    }

    /// One node's facts from its own type and its children's facts, which
    /// `analyze` has already stored. Each fact follows the verdict its walking
    /// form uses: a node that matches answers true, one that is skipped answers
    /// false, and one that descends answers whether any child does.
    fn factsOf(node: *ast.Node) ast.Node.Facts {
        var buffer: [2]*ast.Node = undefined;
        const kids = children(node, &buffer);
        var facts: ast.Node.Facts = .{ .known = true };
        facts.quantifiers = fromVerdict(quantifierVerdict(node), kids, "quantifiers");
        facts.alternation = fromVerdict(alternationVerdict(node), kids, "alternation");
        facts.backreference = fromVerdict(backreferenceVerdict(node), kids, "backreference");
        facts.atomic_group = fromVerdict(atomicGroupVerdict(node), kids, "atomic_group");
        facts.lazy_quantifier = fromVerdict(lazyQuantifierVerdict(node), kids, "lazy_quantifier");
        facts.capturing_group = fromVerdict(capturingGroupVerdict(node), kids, "capturing_group");
        facts.groups = fromVerdict(groupVerdict(node), kids, "groups");
        facts.repeated_alternation = if (repeatedChild(node)) |child|
            child.facts.alternation or child.facts.repeated_alternation
        else switch (node.node_type) {
            .optional, .concat, .alternation, .group, .lookahead, .lookbehind => anyChild(kids, "repeated_alternation"),
            else => false,
        };
        facts.choice_loop = switch (node.node_type) {
            .star, .plus => blk: {
                const child = repeatedChild(node).?;
                break :blk child.facts.quantifiers or child.facts.alternation or child.facts.choice_loop;
            },
            .repeat => if (node.data.repeat.bounds.max == null)
                node.data.repeat.child.facts.quantifiers or node.data.repeat.child.facts.alternation or node.data.repeat.child.facts.choice_loop
            else
                node.data.repeat.child.facts.choice_loop,
            else => anyChild(kids, "choice_loop"),
        };
        facts.nullable = switch (node.node_type) {
            .literal, .any, .char_class, .unicode_property, .class_set => false,
            .star, .optional, .anchor, .lookahead, .lookbehind, .backref, .empty => true,
            .plus => node.data.plus.child.facts.nullable,
            .repeat => node.data.repeat.bounds.min == 0 or node.data.repeat.child.facts.nullable,
            .group => node.data.group.child.facts.nullable,
            .concat => node.data.concat.left.facts.nullable and node.data.concat.right.facts.nullable,
            .alternation => node.data.alternation.left.facts.nullable or node.data.alternation.right.facts.nullable,
        };
        facts.trailing_choice_loop = switch (node.node_type) {
            .star, .plus => facts.choice_loop,
            .repeat => (node.data.repeat.bounds.max == null and facts.choice_loop) or
                node.data.repeat.child.facts.trailing_choice_loop,
            .optional => node.data.optional.child.facts.trailing_choice_loop,
            .group => node.data.group.child.facts.trailing_choice_loop,
            .concat => node.data.concat.right.facts.trailing_choice_loop or
                (node.data.concat.right.facts.nullable and node.data.concat.left.facts.trailing_choice_loop),
            .alternation => node.data.alternation.left.facts.trailing_choice_loop or
                node.data.alternation.right.facts.trailing_choice_loop,
            else => false,
        };
        facts.codepoint_atom = switch (node.node_type) {
            .unicode_property, .class_set => true,
            .concat, .alternation, .star, .plus, .optional, .repeat, .group, .lookahead, .lookbehind => anyChild(kids, "codepoint_atom"),
            else => false,
        };
        return facts;
    }

    fn fromVerdict(verdict: NodeVerdict, kids: []*ast.Node, comptime fact: []const u8) bool {
        return switch (verdict) {
            .matched => true,
            .skip => false,
            .descend => anyChild(kids, fact),
        };
    }

    fn anyChild(kids: []*ast.Node, comptime fact: []const u8) bool {
        for (kids) |kid| if (@field(kid.facts, fact)) return true;
        return false;
    }

    /// Visit `root` and its children with an explicit stack, answering true at
    /// the first node `decide` accepts.
    ///
    /// A pattern's spine is as deep as the pattern is long, so these checks
    /// cannot recurse: `/aaaa…a/` with 30,000 elements is an ordinary pattern
    /// that other engines run, and one native frame per element overflowed the
    /// stack (#23). Allocation failure answers conservatively and records OOM
    /// so the public search cannot export a result from incomplete analysis.
    fn anyNodeMatches(self: *BacktrackEngine, root: *ast.Node, comptime decide: fn (*BacktrackEngine, *ast.Node) NodeVerdict) bool {
        var pending: std.ArrayList(*ast.Node) = .empty;
        defer pending.deinit(self.allocator);
        var current: ?*ast.Node = root;
        while (current) |node| : (current = pending.pop()) {
            switch (decide(self, node)) {
                .matched => return true,
                .skip => {},
                .descend => self.pushNodeChildren(&pending, node) catch {
                    self.match_error = error.OutOfMemory;
                    return true;
                },
            }
        }
        return false;
    }

    /// Push every child of `node`, right-to-left so they pop in source order.
    fn pushNodeChildren(self: *BacktrackEngine, pending: *std.ArrayList(*ast.Node), node: *ast.Node) !void {
        switch (node.node_type) {
            .concat => {
                try pending.append(self.allocator, node.data.concat.right);
                try pending.append(self.allocator, node.data.concat.left);
            },
            .alternation => {
                try pending.append(self.allocator, node.data.alternation.right);
                try pending.append(self.allocator, node.data.alternation.left);
            },
            .group => try pending.append(self.allocator, node.data.group.child),
            .star => try pending.append(self.allocator, node.data.star.child),
            .plus => try pending.append(self.allocator, node.data.plus.child),
            .optional => try pending.append(self.allocator, node.data.optional.child),
            .repeat => try pending.append(self.allocator, node.data.repeat.child),
            .lookahead => try pending.append(self.allocator, node.data.lookahead.child),
            .lookbehind => try pending.append(self.allocator, node.data.lookbehind.child),
            else => {},
        }
    }

    // Each structural check below has two forms. On an analyzed tree (every
    // tree a `Regex` compiles) it reads the fact `analyze` stored on the node;
    // on any other tree it walks the subtree as before. Both use the same
    // per-node verdict, so they cannot disagree (#53).

    fn quantifierVerdict(n: *ast.Node) NodeVerdict {
        return switch (n.node_type) {
            // Any quantifier needs backtracking support
            .star, .plus, .optional, .repeat => .matched,
            .concat, .alternation, .group => .descend,
            else => .skip,
        };
    }

    fn alternationVerdict(n: *ast.Node) NodeVerdict {
        return switch (n.node_type) {
            .alternation => .matched,
            .concat, .group, .star, .plus, .optional, .repeat, .lookahead, .lookbehind => .descend,
            else => .skip,
        };
    }

    fn backreferenceVerdict(n: *ast.Node) NodeVerdict {
        return switch (n.node_type) {
            .backref => .matched,
            .concat, .alternation, .group, .star, .plus, .optional, .repeat, .lookahead, .lookbehind => .descend,
            else => .skip,
        };
    }

    fn atomicGroupVerdict(n: *ast.Node) NodeVerdict {
        return switch (n.node_type) {
            .group => if (n.data.group.atomic) .matched else .descend,
            .concat, .alternation, .star, .plus, .optional, .repeat, .lookahead, .lookbehind => .descend,
            else => .skip,
        };
    }

    fn lazyQuantifierVerdict(n: *ast.Node) NodeVerdict {
        return switch (n.node_type) {
            .star => if (!n.data.star.greedy) .matched else .descend,
            .plus => if (!n.data.plus.greedy) .matched else .descend,
            .optional => if (!n.data.optional.greedy) .matched else .descend,
            .repeat => if (!n.data.repeat.greedy) .matched else .descend,
            .concat, .alternation, .group, .lookahead, .lookbehind => .descend,
            else => .skip,
        };
    }

    fn capturingGroupVerdict(n: *ast.Node) NodeVerdict {
        return switch (n.node_type) {
            .group => if (n.data.group.capture_index != null) .matched else .descend,
            .concat, .alternation, .star, .plus, .optional, .repeat, .lookahead, .lookbehind => .descend,
            else => .skip,
        };
    }

    fn groupVerdict(n: *ast.Node) NodeVerdict {
        return switch (n.node_type) {
            .group, .lookahead, .lookbehind => .matched,
            .concat, .alternation, .star, .plus, .optional, .repeat => .descend,
            else => .skip,
        };
    }

    /// The child a repetition repeats, for the repeated-alternation check.
    fn repeatedChild(n: *ast.Node) ?*ast.Node {
        return switch (n.node_type) {
            .star => n.data.star.child,
            .plus => n.data.plus.child,
            .repeat => n.data.repeat.child,
            else => null,
        };
    }

    fn repeatedAlternationVerdict(engine: *BacktrackEngine, n: *ast.Node) NodeVerdict {
        // A repetition *of* an alternation is the shape that matters;
        // anything else only passes the question to its children.
        if (repeatedChild(n)) |child| return if (engine.hasAlternation(child)) .matched else .descend;
        return switch (n.node_type) {
            .optional, .concat, .alternation, .group, .lookahead, .lookbehind => .descend,
            else => .skip,
        };
    }

    fn walkWith(comptime verdict: fn (*ast.Node) NodeVerdict) fn (*BacktrackEngine, *ast.Node) NodeVerdict {
        return struct {
            fn decide(_: *BacktrackEngine, n: *ast.Node) NodeVerdict {
                return verdict(n);
            }
        }.decide;
    }

    fn hasQuantifiers(self: *BacktrackEngine, node: *ast.Node) bool {
        if (node.facts.known) return node.facts.quantifiers;
        return self.anyNodeMatches(node, walkWith(quantifierVerdict));
    }

    fn hasAlternation(self: *BacktrackEngine, node: *ast.Node) bool {
        if (node.facts.known) return node.facts.alternation;
        return self.anyNodeMatches(node, walkWith(alternationVerdict));
    }

    fn hasBackreference(self: *BacktrackEngine, node: *ast.Node) bool {
        if (node.facts.known) return node.facts.backreference;
        return self.anyNodeMatches(node, walkWith(backreferenceVerdict));
    }

    fn hasLookbehind(self: *BacktrackEngine, node: *ast.Node) bool {
        return self.anyNodeMatches(node, walkWith(lookbehindVerdict));
    }

    fn lookbehindVerdict(n: *ast.Node) NodeVerdict {
        return switch (n.node_type) {
            .lookbehind => .matched,
            .concat, .alternation, .group, .star, .plus, .optional, .repeat, .lookahead => .descend,
            else => .skip,
        };
    }

    fn hasAtomicGroup(self: *BacktrackEngine, node: *ast.Node) bool {
        if (node.facts.known) return node.facts.atomic_group;
        return self.anyNodeMatches(node, walkWith(atomicGroupVerdict));
    }

    fn hasLazyQuantifier(self: *BacktrackEngine, node: *ast.Node) bool {
        // ECMA-262 RepeatMatcher tries the continuation before extending a
        // non-greedy match. Eagerly enumerating all endings can exhaust the
        // budget on a long tail even when a short match already succeeds.
        if (node.facts.known) return node.facts.lazy_quantifier;
        return self.anyNodeMatches(node, walkWith(lazyQuantifierVerdict));
    }

    fn hasRepeatedAlternation(self: *BacktrackEngine, node: *ast.Node) bool {
        if (node.facts.known) return node.facts.repeated_alternation;
        return self.anyNodeMatches(node, repeatedAlternationVerdict);
    }

    fn needsAnchoredRepeatedAlternationRecovery(self: *BacktrackEngine, left: *ast.Node, right: *ast.Node) bool {
        return self.hasRepeatedAlternation(left) and self.hasCapturingGroup(left) and self.isEndAnchorOnly(right);
    }

    fn hasCapturingGroup(self: *BacktrackEngine, node: *ast.Node) bool {
        if (node.facts.known) return node.facts.capturing_group;
        return self.anyNodeMatches(node, walkWith(capturingGroupVerdict));
    }

    fn isEndAnchorOnly(self: *BacktrackEngine, node: *ast.Node) bool {
        // Walks the tail of a sequence, which is as long as the pattern (#23).
        var current = node;
        while (true) switch (current.node_type) {
            .anchor => return current.data.anchor == .end_line or current.data.anchor == .end_text,
            .group => current = current.data.group.child,
            .concat => {
                if (!self.canMatchEmpty(current.data.concat.left)) return false;
                current = current.data.concat.right;
            },
            else => return false,
        };
    }

    /// Whether a subtree contains a group (whose captures a constrained re-match
    /// would need to set). Conservative: any group counts. When false, the
    /// capture-fixup re-match in matchConcat/collectAllMatches is pure waste and
    /// can be skipped — turning `\p{…}+`-style scans from O(n²) into O(n).
    fn hasGroups(self: *BacktrackEngine, node: *ast.Node) bool {
        if (node.facts.known) return node.facts.groups;
        return self.anyNodeMatches(node, walkWith(groupVerdict));
    }

    /// Reset a loop body's captures before an iteration, in ECMAScript mode
    /// only: its RepeatMatcher clears them, so a group the iteration does not
    /// set reads as unset. PCRE keeps a group's value from an earlier
    /// iteration instead (`(?:b|(a))*` on `ab` captures `a`). Without the
    /// clear, a capture left by an attempt that failed or was only enumerated
    /// would survive, so each path restores the captures it saved before the
    /// attempt, and bounded and counted repeats rebuild every iteration of the
    /// path they settle on (rebuildIterationCaptures).
    fn clearIterationCaptures(self: *BacktrackEngine, node: *ast.Node) void {
        if (self.flags.ecmascript) self.clearCapturesIn(node);
    }

    /// A copy of the captures that stays on the stack for up to 16 groups, so
    /// a path that saves them on every call does not allocate each time.
    const CaptureSnapshot = struct {
        small: [16]CaptureGroup,
        heap: ?[]CaptureGroup,

        fn take(snapshot: *CaptureSnapshot, engine: *BacktrackEngine) ?[]CaptureGroup {
            snapshot.heap = null;
            if (engine.captures.len <= snapshot.small.len) {
                const caps = snapshot.small[0..engine.captures.len];
                @memcpy(caps, engine.captures);
                return caps;
            }
            snapshot.heap = engine.allocator.dupe(CaptureGroup, engine.captures) catch |err| return engine.failWith(err, @as(?[]CaptureGroup, null));
            return snapshot.heap;
        }

        fn release(snapshot: *CaptureSnapshot, engine: *BacktrackEngine) void {
            if (snapshot.heap) |caps| engine.allocator.free(caps);
        }
    };

    /// One iteration of a repeat: the child matched from `start` to `end`
    /// (`start` is the right end when matching in reverse).
    const IterationSpan = struct { start: usize, end: usize };

    /// Set the captures a PCRE repeat leaves after the iterations in `spans`,
    /// listed in the order the engine matched them. It starts from `entry`, the
    /// captures before the repeat, so nothing an enumeration or an abandoned
    /// iteration set survives, and it replays each iteration so a group keeps
    /// the value from the last iteration that set it. A lookbehind is matched
    /// right to left here but forwards by PCRE2, so in reverse the leftmost
    /// iteration is replayed first and the rightmost one wins.
    fn rebuildIterationCaptures(self: *BacktrackEngine, child: *ast.Node, entry: []const CaptureGroup, spans: []const IterationSpan, comptime reverse: bool) bool {
        @memcpy(self.captures, entry);
        for (0..spans.len) |i| {
            const span = if (reverse) spans[spans.len - 1 - i] else spans[i];
            const matched = if (reverse)
                self.matchReverseNodeConstrained(child, span.start, span.end)
            else
                self.matchNodeConstrained(child, span.start, span.end);
            if (!matched or self.match_error != null) {
                @memcpy(self.captures, entry);
                return false;
            }
        }
        return true;
    }

    /// Reset every capture declared inside `node`. Walked with an explicit
    /// stack for the reason `anyNodeMatches` documents (#23).
    fn clearCapturesIn(self: *BacktrackEngine, node: *ast.Node) void {
        var pending: std.ArrayList(*ast.Node) = .empty;
        defer pending.deinit(self.allocator);
        var current: ?*ast.Node = node;
        while (current) |n| : (current = pending.pop()) {
            if (n.node_type == .group) {
                const group = n.data.group;
                if (group.capture_index) |index| {
                    if (index > 0 and index <= self.captures.len) {
                        self.captures[index - 1] = .{ .start = 0, .end = 0, .matched = false };
                    }
                }
            }
            self.pushNodeChildren(&pending, n) catch {
                self.match_error = error.OutOfMemory;
                return;
            };
        }
    }

    /// Collect all possible ending positions for matching a node at a given position
    /// For lazy quantifiers, this returns positions in order: minimal first
    /// For greedy quantifiers, this returns positions in order: maximal first
    fn collectAllMatches(self: *BacktrackEngine, node: *ast.Node, pos: usize, positions: *std.ArrayList(usize)) !void {
        if ((node.node_type == .star or node.node_type == .plus) and self.hybrid and self.loopNeedsContinuations(node))
            return self.continuationEnds(node, pos, positions);
        switch (node.node_type) {
            .star => {
                const quant = node.data.star;
                if (quant.greedy) {
                    // Greedy: try maximal first, then backtrack
                    try self.collectGreedyStarMatches(quant.child, pos, positions);
                } else {
                    // Lazy: try minimal first, then more
                    try self.collectLazyStarMatches(quant.child, pos, positions);
                }
            },
            .plus => {
                const quant = node.data.plus;
                // Must match at least once
                self.clearIterationCaptures(quant.child);
                const first_match = self.matchNode(quant.child, pos) orelse return;

                if (quant.greedy) {
                    // Greedy: try maximal first
                    try self.collectGreedyStarMatches(quant.child, first_match, positions);
                } else {
                    // Lazy: try minimal (one match) first, then more
                    try positions.append(self.allocator, first_match);
                    try self.collectLazyStarMatches(quant.child, first_match, positions);
                }
            },
            .optional => {
                const quant = node.data.optional;
                // Enumerate ALL of the child's possible endings (not just its
                // single greedy match) so a later element — e.g. a backreference
                // after `(.*-)?` — can drive the optional's inner quantifier to a
                // shorter match. Greedy tries the matched branch first, then zero.
                if (quant.greedy) {
                    try self.collectAllMatches(quant.child, pos, positions);
                    try positions.append(self.allocator, pos); // zero matches
                } else {
                    try positions.append(self.allocator, pos); // zero matches first
                    try self.collectAllMatches(quant.child, pos, positions);
                }
            },
            .repeat => {
                if (self.hybrid and self.loopNeedsContinuations(node)) return self.continuationEnds(node, pos, positions);
                const repeat = node.data.repeat;
                // ECMA-262 RepeatMatcher with min=max=1 still permits the
                // continuation to backtrack inside its one required child.
                // Greediness only orders optional additional iterations.
                if (self.boundedRepeatHasChoices(repeat)) {
                    try self.collectBoundedRepeatMatches(repeat, pos, positions, false, false);
                } else if (self.fixedRepeatHasChoices(repeat)) {
                    try self.collectFixedRepeatMatches(repeat, pos, positions, false);
                } else if (repeat.bounds.min == 1 and repeat.bounds.max != null and repeat.bounds.max.? == 1) {
                    self.clearIterationCaptures(repeat.child);
                    try self.collectAllMatches(repeat.child, pos, positions);
                } else if (repeat.greedy) {
                    try self.collectGreedyRepeatMatches(repeat, pos, positions);
                } else {
                    try self.collectLazyRepeatMatches(repeat, pos, positions);
                }
            },
            .concat => {
                // Recursively collect all possible endings for concat nodes
                const c = node.data.concat;
                if (self.hybrid and c.left.facts.trailing_choice_loop) return self.continuationEnds(node, pos, positions);
                const left_has_choices = self.hasQuantifiers(c.left) or self.hasAlternation(c.left);
                const right_has_choices = self.hasQuantifiers(c.right) or self.hasAlternation(c.right);

                if (left_has_choices or right_has_choices) {
                    const clean_captures = self.allocator.alloc(CaptureGroup, self.captures.len) catch |err| return self.failWithError(err);
                    defer self.allocator.free(clean_captures);
                    @memcpy(clean_captures, self.captures);
                    const before_len = positions.items.len;

                    // Collect all possible left-side endings
                    var left_positions = std.ArrayList(usize).initCapacity(self.allocator, 0) catch |err| return self.failWithError(err);
                    defer left_positions.deinit(self.allocator);

                    if (left_has_choices) {
                        try self.collectAllMatches(c.left, pos, &left_positions);
                    } else {
                        if (self.matchNode(c.left, pos)) |end| {
                            try left_positions.append(self.allocator, end);
                        }
                    }

                    // For each left ending, set captures and try right side
                    const left_has_groups = self.hasCapturingGroup(c.left);
                    for (left_positions.items) |left_end| {
                        // Enumerating the left side ran its loop bodies, and PCRE
                        // does not clear them per iteration, so start each end
                        // from the captures before the enumeration.
                        if (!self.flags.ecmascript) @memcpy(self.captures, clean_captures);
                        // Save captures, set them for this left position, try right
                        const saved = self.allocator.alloc(CaptureGroup, self.captures.len) catch |err| return self.failWithError(err);
                        defer self.allocator.free(saved);
                        @memcpy(saved, self.captures);

                        // Set captures correctly for this left end position (only
                        // needed when the left side has groups — else pure waste).
                        if (left_has_groups) {
                            if (left_has_choices) {
                                if (!self.matchNodeConstrained(c.left, pos, left_end)) continue;
                            } else {
                                const fixed_end = self.matchNode(c.left, pos) orelse continue;
                                if (fixed_end != left_end) continue;
                            }
                        }

                        if (right_has_choices) {
                            try self.collectAllMatches(c.right, left_end, positions);
                        } else {
                            if (self.matchNode(c.right, left_end)) |end| {
                                try positions.append(self.allocator, end);
                            }
                        }

                        @memcpy(self.captures, saved);
                    }
                    if (positions.items.len == before_len and !right_has_choices and self.needsAnchoredRepeatedAlternationRecovery(c.left, c.right)) {
                        var target = self.input.len;
                        while (target >= pos) {
                            @memcpy(self.captures, clean_captures);
                            const screened = self.matchNode(c.right, target) orelse {
                                if (target == pos) break;
                                target -= 1;
                                continue;
                            };
                            @memcpy(self.captures, clean_captures);
                            if (self.matchNodeConstrained(c.left, pos, target)) {
                                try positions.append(self.allocator, screened);
                            }
                            if (target == pos) break;
                            target -= 1;
                        }
                    }
                    @memcpy(self.captures, clean_captures);
                } else {
                    // No quantifiers in either side, single match
                    if (self.matchNode(node, pos)) |end| {
                        try positions.append(self.allocator, end);
                    }
                }
            },
            .group => {
                // Recursively collect through groups to reach quantifiers inside
                // NOTE: Don't set captures here - they'll be set by matchNodeConstrained
                // when matchConcat picks a specific position
                const group = node.data.group;
                const saved_flags = self.enterGroupFlags(group);
                defer self.flags = saved_flags;
                if (self.hasQuantifiers(group.child) or self.hasAlternation(group.child)) {
                    try self.collectAllMatches(group.child, pos, positions);
                } else {
                    if (self.matchNode(node, pos)) |end| {
                        try positions.append(self.allocator, end);
                    }
                }
            },
            .alternation => {
                // Collect from both branches
                try self.collectAllMatches(node.data.alternation.left, pos, positions);
                try self.collectAllMatches(node.data.alternation.right, pos, positions);
            },
            else => {
                // For non-quantifiers, there's only one possible match
                if (self.matchNode(node, pos)) |end| {
                    try positions.append(self.allocator, end);
                }
            },
        }
    }

    fn collectGreedyStarMatches(self: *BacktrackEngine, child: *ast.Node, pos: usize, positions: *std.ArrayList(usize)) anyerror!void {
        // Collect all matches from longest to shortest.
        var all_positions = std.ArrayList(usize).initCapacity(self.allocator, 0) catch |err| return self.failWithError(err);
        defer all_positions.deinit(self.allocator);

        try all_positions.append(self.allocator, pos); // zero matches

        var current_pos = pos;
        while (true) {
            self.clearIterationCaptures(child);
            const next_pos = self.matchNodeProgress(child, current_pos) orelse break;
            current_pos = next_pos;
            try all_positions.append(self.allocator, current_pos);
        }

        // Return in reverse order (greedy: longest first).
        var i: usize = all_positions.items.len;
        while (i > 0) {
            i -= 1;
            try positions.append(self.allocator, all_positions.items[i]);
        }
    }

    fn collectLazyStarMatches(self: *BacktrackEngine, child: *ast.Node, pos: usize, positions: *std.ArrayList(usize)) anyerror!void {
        // Collect all matches from shortest to longest
        try positions.append(self.allocator, pos); // zero matches first

        var current_pos = pos;
        while (true) {
            self.clearIterationCaptures(child);
            const next_pos = self.matchNodeProgress(child, current_pos) orelse break;
            current_pos = next_pos;
            try positions.append(self.allocator, current_pos);
        }
    }

    fn fixedRepeatHasChoices(self: *BacktrackEngine, repeat: ast.Node.Repeat) bool {
        // Backreferences can make a continuation require a different capture
        // state at the same ending position. Keep that case on the existing
        // path until continuation enumeration carries those distinct states.
        return repeat.bounds.min > 1 and repeat.bounds.max != null and
            repeat.bounds.max.? == repeat.bounds.min and
            !(self.hasCapturingGroup(repeat.child) and self.hasBackreference(self.ast_root)) and
            (self.hasQuantifiers(repeat.child) or self.hasAlternation(repeat.child));
    }

    fn boundedRepeatHasChoices(self: *BacktrackEngine, repeat: ast.Node.Repeat) bool {
        return repeat.bounds.max != null and repeat.bounds.max.? > repeat.bounds.min and
            !(self.hasCapturingGroup(repeat.child) and self.hasBackreference(self.ast_root)) and
            (self.hasQuantifiers(repeat.child) or self.hasAlternation(repeat.child));
    }

    fn collectBoundedRepeatMatches(self: *BacktrackEngine, repeat: ast.Node.Repeat, pos: usize, positions: *std.ArrayList(usize), comptime reverse: bool, comptime first_only: bool) anyerror!void {
        _ = self.collectBoundedRepeatMatchesInner(repeat, pos, positions, null, null, reverse, first_only) catch |err| {
            self.match_error = err;
            return err;
        };
    }

    fn matchBoundedRepeatConstrained(self: *BacktrackEngine, repeat: ast.Node.Repeat, pos: usize, target: usize, comptime reverse: bool) bool {
        const saved = self.allocator.dupe(CaptureGroup, self.captures) catch |err| {
            self.match_error = err;
            return false;
        };
        defer self.allocator.free(saved);
        var unused: std.ArrayList(usize) = .empty;
        defer unused.deinit(self.allocator);
        const matched = self.collectBoundedRepeatMatchesInner(repeat, pos, &unused, target, saved, reverse, false) catch |err| {
            self.match_error = err;
            @memcpy(self.captures, saved);
            return false;
        };
        if (!matched) @memcpy(self.captures, saved);
        return matched;
    }

    const BoundedRepeatState = struct { count: usize, pos: usize };
    const BoundedRepeatFrame = struct {
        state: BoundedRepeatState,
        last_start: usize,
        /// Reached by an empty iteration after the minimum, which only PCRE
        /// takes: its count is kept as it is in the seen set.
        empty: bool = false,
        phase: enum { enter, expand, leave } = .enter,
        ends: std.ArrayList(usize) = .empty,
        next: usize = 0,
    };

    /// `path` is the search stack, the repeat's start first and the candidate
    /// last; `entry` holds the captures from before the repeat whenever a
    /// target is given.
    fn recordBoundedRepeatMatch(self: *BacktrackEngine, repeat: ast.Node.Repeat, path: []const BoundedRepeatFrame, has_captures: bool, positions: *std.ArrayList(usize), target: ?usize, entry: ?[]const CaptureGroup, comptime reverse: bool, comptime first_only: bool) anyerror!bool {
        const top = path[path.len - 1];
        const count = top.state.count;
        const pos = top.state.pos;
        const last_start = top.last_start;
        if (count < repeat.bounds.min) return false;
        if (target) |end| {
            if (pos != end) return false;
            if (!has_captures) return true;
            if (!self.flags.ecmascript) {
                // PCRE keeps what earlier iterations captured, so replay the
                // whole path rather than its last iteration.
                var spans: std.ArrayList(IterationSpan) = .empty;
                defer spans.deinit(self.allocator);
                for (path[1..]) |frame| try spans.append(self.allocator, .{ .start = frame.last_start, .end = frame.state.pos });
                const matched = self.rebuildIterationCaptures(repeat.child, entry.?, spans.items, reverse);
                if (self.match_error) |err| return err;
                return matched;
            }
            self.clearCapturesIn(repeat.child);
            if (self.match_error) |err| return err;
            if (count == 0) return true;
            const matched = if (reverse)
                self.matchReverseNodeConstrained(repeat.child, last_start, pos)
            else
                self.matchNodeConstrained(repeat.child, last_start, pos);
            if (self.match_error) |err| return err;
            return matched;
        }
        try positions.append(self.allocator, pos);
        return first_only;
    }

    fn collectBoundedRepeatMatchesInner(self: *BacktrackEngine, repeat: ast.Node.Repeat, pos: usize, positions: *std.ArrayList(usize), target: ?usize, entry: ?[]const CaptureGroup, comptime reverse: bool, comptime first_only: bool) anyerror!bool {
        const State = BoundedRepeatState;
        const Frame = BoundedRepeatFrame;
        const has_captures = self.hasCapturingGroup(repeat.child);
        if (self.match_error) |err| return err;
        const saved: ?[]CaptureGroup = if (has_captures and target == null) try self.allocator.dupe(CaptureGroup, self.captures) else null;
        defer if (saved) |caps| {
            @memcpy(self.captures, caps);
            self.allocator.free(caps);
        };
        var stack: std.ArrayList(Frame) = .empty;
        defer {
            for (stack.items) |*frame| frame.ends.deinit(self.allocator);
            stack.deinit(self.allocator);
        }
        var seen = std.AutoHashMap(State, void).init(self.allocator);
        defer seen.deinit();
        try stack.append(self.allocator, .{ .state = .{ .count = 0, .pos = pos }, .last_start = pos });
        while (stack.items.len != 0) {
            if (self.match_error) |err| return err;
            self.step_count += 1;
            if (self.step_count > self.max_steps) return error.Timeout;
            const frame = &stack.items[stack.items.len - 1];
            switch (frame.phase) {
                .enter => {
                    // RepeatMatcher visits choices depth-first. Sorting by count
                    // changes priority when a shorter count's child alternative
                    // precedes a longer count on another path.
                    var key = frame.state;
                    const remaining = if (reverse) key.pos else self.input.len - key.pos;
                    // Once min is met, each further iteration must advance.
                    // If max cannot bind even at one byte per iteration, count
                    // no longer distinguishes future choices. This also keeps
                    // a long ordinary match from exhausting its old budget just
                    // by revisiting equivalent decompositions at lower counts.
                    // An empty iteration (PCRE) does not advance, so it is
                    // kept apart: folded, it would be its own parent state and
                    // lose its place in the order of ends.
                    if (!frame.empty and key.count >= repeat.bounds.min and repeat.bounds.max.? - key.count >= remaining)
                        key.count = repeat.bounds.min;
                    const seen_key = try seen.getOrPut(key);
                    if (seen_key.found_existing) {
                        var discarded = stack.pop().?;
                        discarded.ends.deinit(self.allocator);
                        continue;
                    }
                    if (!repeat.greedy and try self.recordBoundedRepeatMatch(repeat, stack.items, has_captures, positions, target, entry, reverse, first_only)) return true;
                    frame.phase = .expand;
                    if (frame.state.count < repeat.bounds.max.?) {
                        if (has_captures) self.clearIterationCaptures(repeat.child);
                        if (self.match_error) |err| return err;
                        if (reverse) {
                            try self.collectAllReverseMatches(repeat.child, frame.state.pos, &frame.ends);
                        } else {
                            try self.collectAllMatches(repeat.child, frame.state.pos, &frame.ends);
                        }
                    }
                },
                .expand => {
                    if (frame.next == frame.ends.items.len) {
                        frame.phase = .leave;
                        continue;
                    }
                    const end = frame.ends.items[frame.next];
                    frame.next += 1;
                    if (reverse) {
                        if (end > frame.state.pos) continue;
                    } else if (end < frame.state.pos) continue;
                    // RepeatMatcher's continuation rejects empty optional
                    // iterations after the required minimum has been met.
                    // PCRE takes one where it comes and goes on to the next
                    // copy, up to max (`(?:.{0,2}?){1,3}` matches empty). A
                    // lookbehind, matched right to left here, keeps the
                    // RepeatMatcher rule until it is matched forwards as PCRE2
                    // does (zig-utils/zig-regex#63).
                    if (end == frame.state.pos and frame.state.count >= repeat.bounds.min and (self.flags.ecmascript or reverse)) continue;
                    const state = State{ .count = frame.state.count + 1, .pos = end };
                    const start = frame.state.pos;
                    // Without capture-sensitive backreferences, equal
                    // count/position states have equal continuations; retain
                    // the first path. A target rebuilds the captures of the
                    // path it settles on.
                    try stack.append(self.allocator, .{ .state = state, .last_start = start, .empty = end == start and frame.state.count >= repeat.bounds.min });
                },
                .leave => {
                    if (repeat.greedy and try self.recordBoundedRepeatMatch(repeat, stack.items, has_captures, positions, target, entry, reverse, first_only)) return true;
                    var finished = stack.pop().?;
                    finished.ends.deinit(self.allocator);
                },
            }
        }
        return false;
    }

    fn collectFixedRepeatMatches(self: *BacktrackEngine, repeat: ast.Node.Repeat, pos: usize, positions: *std.ArrayList(usize), comptime reverse: bool) anyerror!void {
        _ = self.collectFixedRepeatMatchesInner(repeat, pos, positions, null, null, reverse) catch |err| {
            self.match_error = err;
            return err;
        };
    }

    fn matchFixedRepeatConstrained(self: *BacktrackEngine, repeat: ast.Node.Repeat, pos: usize, target: usize, comptime reverse: bool) bool {
        const saved = self.allocator.dupe(CaptureGroup, self.captures) catch |err| {
            self.match_error = err;
            return false;
        };
        defer self.allocator.free(saved);
        var unused: std.ArrayList(usize) = .empty;
        defer unused.deinit(self.allocator);
        const matched = self.collectFixedRepeatMatchesInner(repeat, pos, &unused, target, saved, reverse) catch |err| {
            self.match_error = err;
            @memcpy(self.captures, saved);
            return false;
        };
        if (!matched) @memcpy(self.captures, saved);
        return matched;
    }

    fn collectFixedRepeatMatchesInner(self: *BacktrackEngine, repeat: ast.Node.Repeat, pos: usize, positions: *std.ArrayList(usize), target: ?usize, entry: ?[]const CaptureGroup, comptime reverse: bool) anyerror!bool {
        const has_captures = self.hasCapturingGroup(repeat.child);
        if (self.match_error) |err| return err;
        // PCRE keeps what earlier iterations captured, so a target replays the
        // whole path it settles on. Each frontier entry then remembers the
        // entry of the previous iteration it was first reached from.
        const PathNode = struct { pos: usize, parent: usize };
        const track = has_captures and target != null and !self.flags.ecmascript;
        var nodes: std.ArrayList(PathNode) = .empty;
        defer nodes.deinit(self.allocator);
        var frontier_ids: std.ArrayList(usize) = .empty;
        defer frontier_ids.deinit(self.allocator);
        var next_ids: std.ArrayList(usize) = .empty;
        defer next_ids.deinit(self.allocator);
        var spans: std.ArrayList(IterationSpan) = .empty;
        defer spans.deinit(self.allocator);
        if (track) {
            try nodes.append(self.allocator, .{ .pos = pos, .parent = std.math.maxInt(usize) });
            try frontier_ids.append(self.allocator, 0);
        }
        const saved: ?[]CaptureGroup = if (has_captures and target == null) try self.allocator.dupe(CaptureGroup, self.captures) else null;
        defer if (saved) |caps| {
            @memcpy(self.captures, caps);
            self.allocator.free(caps);
        };
        var frontier: std.ArrayList(usize) = .empty;
        defer frontier.deinit(self.allocator);
        var next: std.ArrayList(usize) = .empty;
        defer next.deinit(self.allocator);
        var ends: std.ArrayList(usize) = .empty;
        defer ends.deinit(self.allocator);
        var seen = std.AutoHashMap(usize, void).init(self.allocator);
        defer seen.deinit();
        try frontier.append(self.allocator, pos);

        var count: usize = 0;
        while (count < repeat.bounds.min) : (count += 1) {
            // A nullable child may enumerate endings without matching an atom.
            // Charge the iteration too so even enormous empty repeats stop.
            self.step_count += 1;
            if (self.step_count > self.max_steps) return error.Timeout;
            next.clearRetainingCapacity();
            next_ids.clearRetainingCapacity();
            seen.clearRetainingCapacity();
            for (frontier.items, 0..) |start, k| {
                ends.clearRetainingCapacity();
                if (has_captures) self.clearIterationCaptures(repeat.child);
                if (self.match_error) |err| return err;
                if (reverse) {
                    try self.collectAllReverseMatches(repeat.child, start, &ends);
                } else {
                    try self.collectAllMatches(repeat.child, start, &ends);
                }
                if (self.match_error) |err| return err;
                if (self.step_count > self.max_steps) return error.Timeout;
                for (ends.items) |end| {
                    if (target != null and count + 1 == repeat.bounds.min) {
                        if (end != target.?) continue;
                        if (!has_captures) return true;
                        if (track) {
                            spans.clearRetainingCapacity();
                            try spans.append(self.allocator, .{ .start = start, .end = end });
                            var id = frontier_ids.items[k];
                            while (id != 0) : (id = nodes.items[id].parent) {
                                const node = nodes.items[id];
                                try spans.append(self.allocator, .{ .start = nodes.items[node.parent].pos, .end = node.pos });
                            }
                            std.mem.reverse(IterationSpan, spans.items);
                            const rebuilt = self.rebuildIterationCaptures(repeat.child, entry.?, spans.items, reverse);
                            if (self.match_error) |err| return err;
                            if (rebuilt) return true;
                            continue;
                        }
                        self.clearCapturesIn(repeat.child);
                        const matched = if (reverse)
                            self.matchReverseNodeConstrained(repeat.child, start, end)
                        else
                            self.matchNodeConstrained(repeat.child, start, end);
                        if (self.match_error) |err| return err;
                        if (matched) return true;
                        continue;
                    }
                    // Without capture-sensitive backreferences, equal
                    // iteration/position states have equal continuations;
                    // preserve the earliest path. Targeted reconstruction above
                    // sets the captures of the path it settles on.
                    const seen_end = try seen.getOrPut(end);
                    if (!seen_end.found_existing) {
                        try next.append(self.allocator, end);
                        if (track) {
                            try next_ids.append(self.allocator, nodes.items.len);
                            try nodes.append(self.allocator, .{ .pos = end, .parent = frontier_ids.items[k] });
                        }
                    }
                }
            }
            if (next.items.len == 0) return false;
            std.mem.swap(std.ArrayList(usize), &frontier, &next);
            std.mem.swap(std.ArrayList(usize), &frontier_ids, &next_ids);
        }
        try positions.appendSlice(self.allocator, frontier.items);
        return frontier.items.len != 0;
    }

    fn collectGreedyRepeatMatches(self: *BacktrackEngine, repeat: ast.Node.Repeat, pos: usize, positions: *std.ArrayList(usize)) !void {
        const min = repeat.bounds.min;
        const max = repeat.bounds.max;

        // Match minimum required times
        var current_pos = pos;
        var i: usize = 0;
        while (i < min) : (i += 1) {
            self.clearIterationCaptures(repeat.child);
            current_pos = self.matchNode(repeat.child, current_pos) orelse return;
        }

        // Collect all positions from min to max (or unbounded)
        var all_positions = std.ArrayList(usize).initCapacity(self.allocator, 0) catch |err| return self.failWithError(err);
        defer all_positions.deinit(self.allocator);

        try all_positions.append(self.allocator, current_pos);

        if (max) |max_count| {
            while (i < max_count) : (i += 1) {
                self.clearIterationCaptures(repeat.child);
                if (self.matchNodeProgress(repeat.child, current_pos)) |next_pos| {
                    current_pos = next_pos;
                    try all_positions.append(self.allocator, current_pos);
                } else break;
            }
        } else {
            // Unbounded: keep matching until we can't
            while (true) {
                self.clearIterationCaptures(repeat.child);
                const next_pos = self.matchNodeProgress(repeat.child, current_pos) orelse break;
                current_pos = next_pos;
                try all_positions.append(self.allocator, current_pos);
            }
        }

        // Return in reverse order (greedy: longest first)
        var j: usize = all_positions.items.len;
        while (j > 0) {
            j -= 1;
            try positions.append(self.allocator, all_positions.items[j]);
        }
    }

    fn collectLazyRepeatMatches(self: *BacktrackEngine, repeat: ast.Node.Repeat, pos: usize, positions: *std.ArrayList(usize)) !void {
        const min = repeat.bounds.min;
        const max = repeat.bounds.max;

        // Match minimum required times
        var current_pos = pos;
        var i: usize = 0;
        while (i < min) : (i += 1) {
            self.clearIterationCaptures(repeat.child);
            current_pos = self.matchNode(repeat.child, current_pos) orelse return;
        }

        // Return positions from min to max (lazy: shortest first)
        try positions.append(self.allocator, current_pos);

        if (max) |max_count| {
            while (i < max_count) : (i += 1) {
                self.clearIterationCaptures(repeat.child);
                if (self.matchNodeProgress(repeat.child, current_pos)) |next_pos| {
                    current_pos = next_pos;
                    try positions.append(self.allocator, current_pos);
                } else break;
            }
        } else {
            // Unbounded: keep matching until we can't
            while (true) {
                self.clearIterationCaptures(repeat.child);
                const next_pos = self.matchNodeProgress(repeat.child, current_pos) orelse break;
                current_pos = next_pos;
                try positions.append(self.allocator, current_pos);
            }
        }
    }

    fn matchAlternation(self: *BacktrackEngine, alt: ast.Node.Alternation, pos: usize) ?usize {
        // CompileSubpattern (Disjunction): a failed alternative must not leak
        // captured strings into the next alternative's MatchState.
        const saved = self.allocator.dupe(CaptureGroup, self.captures) catch |err| {
            self.match_error = err;
            return null;
        };
        defer self.allocator.free(saved);
        const left = self.matchNode(alt.left, pos);
        if (self.match_error == null) if (left) |end| return end;
        @memcpy(self.captures, saved);
        if (self.match_error != null) return null;
        const right = self.matchNode(alt.right, pos);
        if (right == null or self.match_error != null) @memcpy(self.captures, saved);
        return if (self.match_error == null) right else null;
    }

    fn matchStar(self: *BacktrackEngine, quant: ast.Node.Quantifier, pos: usize) ?usize {
        if (quant.greedy) {
            // Greedy: match as many as possible
            return self.matchStarGreedy(quant.child, pos);
        } else {
            // Lazy: match as few as possible
            return self.matchStarLazy(quant.child, pos);
        }
    }

    fn matchStarGreedy(self: *BacktrackEngine, child: *ast.Node, pos: usize) ?usize {
        // Try to match as many as possible, backtrack if needed
        var current_pos = pos;
        var match_positions = std.ArrayList(usize).initCapacity(self.allocator, 0) catch |err| return self.failWith(err, @as(?usize, null));
        defer match_positions.deinit(self.allocator);

        match_positions.append(self.allocator, current_pos) catch |err| return self.failWith(err, @as(?usize, null));

        // Collect all possible match positions
        while (true) {
            const saved = self.allocator.alloc(CaptureGroup, self.captures.len) catch |err| return self.failWith(err, @as(?usize, null));
            defer self.allocator.free(saved);
            @memcpy(saved, self.captures);

            self.clearIterationCaptures(child);
            const next_pos = self.matchNodeProgress(child, current_pos) orelse {
                @memcpy(self.captures, saved);
                break;
            };
            if (next_pos <= current_pos) {
                @memcpy(self.captures, saved);
                break;
            }
            current_pos = next_pos;
            match_positions.append(self.allocator, current_pos) catch |err| return self.failWith(err, @as(?usize, null));
        }

        // Greedy: return the longest match
        std.debug.assert(match_positions.items.len != 0);
        return match_positions.items[match_positions.items.len - 1];
    }

    fn matchStarLazy(self: *BacktrackEngine, _: *ast.Node, pos: usize) ?usize {
        _ = self;
        // Lazy: try zero matches first, then one, two, etc.
        // For lazy, we start with the minimum (zero) and only match more if needed
        // The caller will handle backtracking if the rest of the pattern fails
        return pos;
    }

    fn matchPlus(self: *BacktrackEngine, quant: ast.Node.Quantifier, pos: usize) ?usize {
        // Must match at least once
        self.clearIterationCaptures(quant.child);
        const first_match = self.matchNode(quant.child, pos) orelse return null;

        if (quant.greedy) {
            return self.matchStarGreedy(quant.child, first_match);
        } else {
            return first_match; // Lazy: just one match
        }
    }

    fn matchOptional(self: *BacktrackEngine, quant: ast.Node.Quantifier, pos: usize) ?usize {
        if (quant.greedy) {
            // Greedy: try to match first
            if (self.matchNode(quant.child, pos)) |end| {
                return end;
            }
            return pos; // Or match zero
        } else {
            // Lazy: match zero first
            return pos;
        }
    }

    fn matchRepeat(self: *BacktrackEngine, repeat: ast.Node.Repeat, pos: usize) ?usize {
        if (self.boundedRepeatHasChoices(repeat)) {
            var ends: std.ArrayList(usize) = .empty;
            defer ends.deinit(self.allocator);
            self.collectBoundedRepeatMatches(repeat, pos, &ends, false, true) catch |err| return self.failWith(err, @as(?usize, null));
            if (ends.items.len == 0) return null;
            const target = ends.items[0];
            if (self.hasCapturingGroup(repeat.child) and !self.matchBoundedRepeatConstrained(repeat, pos, target, false)) return null;
            return target;
        }
        if (self.fixedRepeatHasChoices(repeat)) {
            var ends: std.ArrayList(usize) = .empty;
            defer ends.deinit(self.allocator);
            self.collectFixedRepeatMatches(repeat, pos, &ends, false) catch |err| return self.failWith(err, @as(?usize, null));
            if (ends.items.len == 0) return null;
            const target = ends.items[0];
            if (self.hasCapturingGroup(repeat.child) and !self.matchFixedRepeatConstrained(repeat, pos, target, false)) return null;
            return target;
        }
        const min = repeat.bounds.min;
        const max = repeat.bounds.max;

        // Match minimum required times
        // A failed required iteration fails the repeat; PCRE did not clear the
        // earlier ones, so put back the captures from before them.
        var current_pos = pos;
        var i: usize = 0;
        const entry: ?[]CaptureGroup = if (min > 1 and !self.flags.ecmascript and self.hasCapturingGroup(repeat.child)) self.allocator.dupe(CaptureGroup, self.captures) catch |err| return self.failWith(err, @as(?usize, null)) else null;
        defer if (entry) |caps| self.allocator.free(caps);
        while (i < min) : (i += 1) {
            self.clearIterationCaptures(repeat.child);
            current_pos = self.matchNode(repeat.child, current_pos) orelse {
                if (entry) |caps| @memcpy(self.captures, caps);
                return null;
            };
        }

        // If no max, behave like star after minimum
        if (max == null) {
            if (repeat.greedy) {
                return self.matchStarGreedy(repeat.child, current_pos);
            } else {
                return current_pos; // Lazy: stop at minimum
            }
        }

        // Match up to max times
        const max_count = max.?;
        if (repeat.greedy and i < max_count) {
            const saved = self.allocator.alloc(CaptureGroup, self.captures.len) catch |err| return self.failWith(err, @as(?usize, null));
            defer self.allocator.free(saved);
            // Greedy: try to match as many as possible
            while (i < max_count) : (i += 1) {
                // ECMA-262 RepeatMatcher continues with the previous matchState
                // when an additional iteration fails (including no progress).
                // Clearing the trial's captures must not erase the last accepted
                // iteration, just as in matchStarGreedy and matchReverseRepeat.
                @memcpy(saved, self.captures);
                self.clearIterationCaptures(repeat.child);
                if (self.matchNodeProgress(repeat.child, current_pos)) |next_pos| {
                    current_pos = next_pos;
                } else {
                    @memcpy(self.captures, saved);
                    break;
                }
            }
        }
        // Lazy or reached max: return current position
        return current_pos;
    }

    fn matchCharClass(self: *BacktrackEngine, char_class: common.CharClass, pos: usize) ?usize {
        if (pos >= self.input.len) return null;
        if (self.flags.unicode and isUtf8Continuation(self.input[pos])) return null;

        if (self.flags.unicode and self.flags.case_insensitive and isAsciiWordClass(char_class)) {
            const dec = unicode_mod.decodeUtf8Lenient(self.input[pos..]) orelse return null;
            const word = self.isEcmaWordCodepoint(dec.codepoint);
            return if (word != char_class.negated) pos + dec.len else null;
        }

        const c = self.input[pos];
        const matches = if (self.flags.case_insensitive)
            char_class.matchesCI(c)
        else
            char_class.matches(c);

        return if (matches) pos + 1 else null;
    }

    /// A `/v` set-notation class: decode the code point at `pos` and test
    /// membership, consuming the whole code point on a match.
    fn matchClassSet(self: *BacktrackEngine, set: *ast.Node.ClassSet, pos: usize) ?usize {
        // The longest match (a `\q{...}` string can consume several code points).
        return set.matchLongestMode(self.input, pos, self.classSetCaseFoldMode());
    }

    // Endpoint collection and constrained capture reconstruction must execute
    // a group's child under the same lexical modifiers as an ordinary match.
    fn enterGroupFlags(self: *BacktrackEngine, group: ast.Node.Group) common.CompileFlags {
        const saved = self.flags;
        if (group.mod) |m| {
            if (m.i) |v| self.flags.case_insensitive = v;
            if (m.m) |v| self.flags.multiline = v;
            if (m.s) |v| self.flags.dot_all = v;
        }
        return saved;
    }

    fn matchGroup(self: *BacktrackEngine, group: ast.Node.Group, pos: usize) ?usize {
        const start_pos = pos;

        // Inline modifiers `(?ims:...)` adjust i/m/s only within the group
        // body. (The local `x` and `U` flags are parse-time and never reach
        // here; ECMAScript does not allow `u` as an inline modifier.)
        const saved_flags = self.flags;
        if (group.mod) |m| {
            if (m.i) |b| self.flags.case_insensitive = b;
            if (m.m) |b| self.flags.multiline = b;
            if (m.s) |b| self.flags.dot_all = b;
        }
        defer if (group.mod != null) {
            self.flags = saved_flags;
        };

        const end_pos = self.matchNode(group.child, pos) orelse return null;

        // Save capture if this is a capturing group
        if (group.capture_index) |index| {
            if (index > 0 and index <= self.captures.len) {
                self.captures[index - 1] = .{
                    .start = start_pos,
                    .end = end_pos,
                    .matched = true,
                };
            }
        }

        return end_pos;
    }

    fn matchAnchor(self: *BacktrackEngine, anchor_type: ast.AnchorType, pos: usize) ?usize {
        const matches = switch (anchor_type) {
            .start_line => pos == 0 or (self.flags.multiline and common.lineTerminatorBefore(self.input, pos, self.flags)),
            .end_line => pos == self.input.len or (self.flags.multiline and common.lineTerminatorAt(self.input, pos, self.flags)),
            .start_text => pos == 0,
            .end_text => pos == self.input.len,
            .word_boundary => self.isWordBoundary(pos),
            .non_word_boundary => !self.isWordBoundary(pos),
        };

        return if (matches) pos else null;
    }

    fn isWordBoundary(self: *BacktrackEngine, pos: usize) bool {
        const before_is_word = if (self.flags.unicode and self.flags.case_insensitive)
            self.isEcmaWordBefore(pos)
        else if (pos > 0) isWordChar(self.input[pos - 1]) else false;
        const after_is_word = if (self.flags.unicode and self.flags.case_insensitive)
            self.isEcmaWordAfter(pos)
        else if (pos < self.input.len) isWordChar(self.input[pos]) else false;
        return before_is_word != after_is_word;
    }

    fn isEcmaWordBefore(self: *BacktrackEngine, pos: usize) bool {
        const start = self.previousCodepointStart(pos) orelse return false;
        const dec = unicode_mod.decodeUtf8Lenient(self.input[start..]) orelse return false;
        if (start + dec.len != pos) return false;
        return self.isEcmaWordCodepoint(dec.codepoint);
    }

    fn isEcmaWordAfter(self: *BacktrackEngine, pos: usize) bool {
        if (pos >= self.input.len) return false;
        const dec = unicode_mod.decodeUtf8Lenient(self.input[pos..]) orelse return false;
        return self.isEcmaWordCodepoint(dec.codepoint);
    }

    fn isEcmaWordCodepoint(_: *BacktrackEngine, cp: u21) bool {
        return (cp >= 'a' and cp <= 'z') or
            (cp >= 'A' and cp <= 'Z') or
            (cp >= '0' and cp <= '9') or
            cp == '_' or
            cp == 0x017F or
            cp == 0x212A;
    }

    fn isWordChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_';
    }

    fn isUtf8Continuation(c: u8) bool {
        return (c & 0xC0) == 0x80;
    }

    fn matchLookahead(self: *BacktrackEngine, assertion: ast.Node.Assertion, pos: usize) ?usize {
        // A negative lookahead leaves no captures behind in PCRE. Without the
        // per-iteration clears, a loop in its body could leave some.
        const saved: ?[]CaptureGroup = if (assertion.positive or self.flags.ecmascript) null else self.allocator.dupe(CaptureGroup, self.captures) catch |err| return self.failWith(err, @as(?usize, null));
        defer if (saved) |caps| {
            @memcpy(self.captures, caps);
            self.allocator.free(caps);
        };
        // Lookahead: test if pattern matches at current position without consuming input
        const matches = if (self.hybrid and assertion.child.facts.choice_loop)
            self.continuationAssertion(assertion.child, pos, false)
        else
            self.matchNode(assertion.child, pos) != null;

        // For positive lookahead (?=...), return pos if matched
        // For negative lookahead (?!...), return pos if NOT matched
        const success = if (assertion.positive) matches else !matches;
        return if (success) pos else null;
    }

    fn matchLookbehind(self: *BacktrackEngine, assertion: ast.Node.Assertion, pos: usize) ?usize {
        if (assertion.positive) {
            // ECMAScript evaluates lookbehind patterns with direction = -1:
            // concatenations run right-to-left and captures inside repetitions end
            // up with the leftmost participating iteration.
            return if (self.lookbehindBody(assertion.child, pos)) pos else null;
        }

        const saved = self.allocator.alloc(CaptureGroup, self.captures.len) catch |err| return self.failWith(err, @as(?usize, null));
        defer self.allocator.free(saved);
        @memcpy(saved, self.captures);

        const matches = self.lookbehindBody(assertion.child, pos);
        @memcpy(self.captures, saved);
        return if (matches) null else pos;
    }

    fn lookbehindBody(self: *BacktrackEngine, child: *ast.Node, pos: usize) bool {
        if (self.forwardLookbehind(child, pos) catch |err| return self.failWith(err, false)) |matched| return matched;
        if (self.hybrid and child.facts.choice_loop) return self.continuationAssertion(child, pos, true);
        return self.matchReverseNode(child, pos) != null;
    }

    /// The most bytes a lookbehind branch may span to be matched forwards:
    /// PCRE2's default limit of 255 characters, at up to four bytes each.
    const max_forward_lookbehind = 255 * 4;
    /// A branch with one length has one start, tried directly; a wider one
    /// asks `reachingStarts` for the few that can match. Trying every start
    /// of even a narrow range costs a forward match each.
    const narrow_lookbehind = 1;
    /// How many backreferences deep `lookbehindLength` follows a group.
    const max_lookbehind_reference_depth = 8;

    const LengthRange = struct { min: usize, max: usize };

    /// One top-level branch of a lookbehind body, as `forwardLookbehind`
    /// matches it.
    const LookbehindBranch = struct {
        node: *ast.Node,
        range: LengthRange,
        /// A backreference reads captures that matching right to left would
        /// set in the wrong order, so its starts cannot come from there.
        backref: bool,
    };

    /// Match a lookbehind body as PCRE2 does, in PCRE mode: each top-level
    /// branch in order, and for each the starts it can begin at from the
    /// furthest back, matching forwards to end exactly at `pos`. A group in
    /// the body is then set before a reference to its right, and a loop's last
    /// iteration is its rightmost (`(?<=(a)\1)c` matches `aac` with 0:1).
    /// The starts come from this engine's right-to-left enumeration, which
    /// finds where the branch can begin as cheaply as before; a branch with a
    /// backreference tries every start its length allows instead. Null when
    /// this does not apply (`lookbehind_plans`): ECMAScript mode, whose
    /// lookbehinds run backwards by the spec, a branch with no bounded length,
    /// which PCRE2 rejects, or an atomic group; the body then runs right to
    /// left as before.
    fn forwardLookbehind(self: *BacktrackEngine, child: *ast.Node, pos: usize) !?bool {
        if (self.flags.ecmascript) return null;
        const branches = self.lookbehind_plans.get(@intFromPtr(child)) orelse return null;
        var saved: CaptureSnapshot = undefined;
        const entry = saved.take(self) orelse return error.OutOfMemory;
        defer saved.release(self);
        for (branches) |branch| {
            if (branch.range.min > pos) continue;
            const furthest = pos - @min(branch.range.max, pos);
            const nearest = pos - branch.range.min;
            if (nearest - furthest < narrow_lookbehind) {
                // A narrow range is cheaper to try start by start.
                var start = furthest;
                while (start <= nearest) : (start += 1) {
                    @memcpy(self.captures, entry);
                    if (self.matchNodeConstrained(branch.node, start, pos)) return true;
                    if (self.match_error) |err| return err;
                }
                continue;
            }
            // Where the branch can begin, found right to left over the
            // positions in reach; the forward match below decides.
            const size = pos - furthest + 1;
            var ends = LookbehindWindow.empty;
            ends.set(pos - furthest);
            const reach = self.reachingStarts(branch.node, ends, furthest, size);
            if (self.match_error) |err| return err;
            var bits = reach.iterator(.{});
            while (bits.next()) |bit| {
                const start = furthest + bit;
                if (start > nearest) break;
                @memcpy(self.captures, entry);
                if (self.matchNodeConstrained(branch.node, start, pos)) return true;
                if (self.match_error) |err| return err;
            }
        }
        @memcpy(self.captures, entry);
        return false;
    }

    /// The positions a lookbehind branch can span, one bit each: at most
    /// `max_forward_lookbehind + 1`, so a set lives on the stack.
    const LookbehindWindow = std.StaticBitSet(max_forward_lookbehind + 1);

    /// The positions in a window of `size` starting at `lo` where `node` can
    /// begin and end at one of `ends`, found right to left. A lookaround
    /// passes every position through and a backreference every length its
    /// group allows, so the set can hold starts that do not match, never miss
    /// one that does: `forwardLookbehind` checks each forwards.
    fn reachingStarts(self: *BacktrackEngine, node: *ast.Node, ends: LookbehindWindow, lo: usize, size: usize) LookbehindWindow {
        var out = LookbehindWindow.empty;
        if (self.match_error != null) return out;
        switch (node.node_type) {
            .literal, .any, .char_class, .unicode_property, .class_set => {
                const widest: usize = if (node.node_type == .literal or self.flags.bytes) 1 else 4;
                var it = ends.iterator(.{});
                while (it.next()) |bit| {
                    const end = lo + bit;
                    var width: usize = 1;
                    while (width <= widest and width <= bit) : (width += 1) {
                        if (self.matchNode(node, end - width) == end) out.set(bit - width);
                    }
                }
            },
            .anchor => {
                var it = ends.iterator(.{});
                while (it.next()) |bit| if (self.matchAnchor(node.data.anchor, lo + bit) != null) out.set(bit);
            },
            .empty, .lookahead, .lookbehind => out = ends,
            .backref => {
                const range = self.lookbehindLength(node, 0) orelse LengthRange{ .min = 0, .max = size };
                var it = ends.iterator(.{});
                while (it.next()) |bit| {
                    var width = range.min;
                    while (width <= range.max and width <= bit) : (width += 1) out.set(bit - width);
                }
            },
            .group => return self.reachingStarts(node.data.group.child, ends, lo, size),
            .concat => return self.reachingStarts(node.data.concat.left, self.reachingStarts(node.data.concat.right, ends, lo, size), lo, size),
            .alternation => {
                out = self.reachingStarts(node.data.alternation.left, ends, lo, size);
                out.setUnion(self.reachingStarts(node.data.alternation.right, ends, lo, size));
            },
            .star, .plus, .optional, .repeat => {
                const child, const min: usize, const max: ?usize = switch (node.node_type) {
                    .star => .{ node.data.star.child, 0, null },
                    .plus => .{ node.data.plus.child, 1, null },
                    .optional => .{ node.data.optional.child, 0, 1 },
                    .repeat => .{ node.data.repeat.child, node.data.repeat.bounds.min, node.data.repeat.bounds.max },
                    else => unreachable,
                };
                if (min == 0) out = ends;
                var current = ends;
                var count: usize = 0;
                while (max == null or count < max.?) {
                    if (self.match_error != null) break;
                    current = self.reachingStarts(child, current, lo, size);
                    count += 1;
                    if (current.count() == 0) break;
                    if (count >= min) {
                        // Past the minimum, a pass that adds nothing new
                        // cannot add anything later either.
                        const before = out.count();
                        out.setUnion(current);
                        if (out.count() == before) break;
                    }
                }
            },
        }
        return out;
    }

    /// The plan `forwardLookbehind` follows for each lookbehind body it can
    /// match forwards, found once by `init` in PCRE mode.
    fn buildLookbehindPlans(self: *BacktrackEngine) !void {
        var pending: std.ArrayList(*ast.Node) = .empty;
        defer pending.deinit(self.allocator);
        var nodes: std.ArrayList(*ast.Node) = .empty;
        defer nodes.deinit(self.allocator);
        var current: ?*ast.Node = self.ast_root;
        while (current) |n| : (current = pending.pop()) {
            if (n.node_type == .lookbehind) blk: {
                const child = n.data.lookbehind.child;
                if (child.facts.atomic_group) break :blk;
                nodes.clearRetainingCapacity();
                try self.lookbehindBranches(child, &nodes);
                const branches = try self.allocator.alloc(LookbehindBranch, nodes.items.len);
                var usable = true;
                for (nodes.items, branches) |node, *branch| {
                    const range = self.lookbehindLength(node, 0) orelse {
                        usable = false;
                        break;
                    };
                    if (range.max > max_forward_lookbehind) {
                        usable = false;
                        break;
                    }
                    branch.* = .{ .node = node, .range = range, .backref = self.hasBackreference(node) };
                }
                if (!usable) {
                    self.allocator.free(branches);
                    break :blk;
                }
                const entry = self.lookbehind_plans.getOrPut(self.allocator, @intFromPtr(child)) catch |err| {
                    self.allocator.free(branches);
                    return err;
                };
                if (entry.found_existing) self.allocator.free(entry.value_ptr.*);
                entry.value_ptr.* = branches;
            }
            try self.pushNodeChildren(&pending, n);
        }
    }

    fn freeLookbehindPlans(self: *BacktrackEngine) void {
        var plans = self.lookbehind_plans.valueIterator();
        while (plans.next()) |branches| self.allocator.free(branches.*);
        self.lookbehind_plans.deinit(self.allocator);
    }

    /// A lookbehind body's top-level branches, in order.
    fn lookbehindBranches(self: *BacktrackEngine, node: *ast.Node, out: *std.ArrayList(*ast.Node)) !void {
        if (node.node_type == .alternation) {
            try self.lookbehindBranches(node.data.alternation.left, out);
            try self.lookbehindBranches(node.data.alternation.right, out);
        } else try out.append(self.allocator, node);
    }

    /// The fewest and most bytes `node` can match, or null when that is not
    /// bounded. A backreference spans what its group does.
    fn lookbehindLength(self: *BacktrackEngine, node: *ast.Node, depth: usize) ?LengthRange {
        if (depth > max_lookbehind_reference_depth) return null;
        const cap = max_forward_lookbehind + 1;
        // Outside bytes mode `.` and a class match one character, of up to
        // four bytes.
        const char_max: usize = if (self.flags.bytes) 1 else 4;
        return switch (node.node_type) {
            .literal => .{ .min = 1, .max = 1 },
            .any, .char_class, .unicode_property => .{ .min = 1, .max = char_max },
            // A set may hold `\q{...}` strings of any length.
            .class_set => null,
            .anchor, .empty, .lookahead, .lookbehind => .{ .min = 0, .max = 0 },
            .group => self.lookbehindLength(node.data.group.child, depth),
            .concat => blk: {
                const left = self.lookbehindLength(node.data.concat.left, depth) orelse break :blk null;
                const right = self.lookbehindLength(node.data.concat.right, depth) orelse break :blk null;
                break :blk .{ .min = @min(left.min + right.min, cap), .max = @min(left.max + right.max, cap) };
            },
            .alternation => blk: {
                const left = self.lookbehindLength(node.data.alternation.left, depth) orelse break :blk null;
                const right = self.lookbehindLength(node.data.alternation.right, depth) orelse break :blk null;
                break :blk .{ .min = @min(left.min, right.min), .max = @max(left.max, right.max) };
            },
            .star, .plus, .optional, .repeat => blk: {
                const child, const min: usize, const max: ?usize = switch (node.node_type) {
                    .star => .{ node.data.star.child, 0, null },
                    .plus => .{ node.data.plus.child, 1, null },
                    .optional => .{ node.data.optional.child, 0, 1 },
                    .repeat => .{ node.data.repeat.child, node.data.repeat.bounds.min, node.data.repeat.bounds.max },
                    else => unreachable,
                };
                const range = self.lookbehindLength(child, depth) orelse break :blk null;
                const hi = max orelse break :blk if (range.max == 0) LengthRange{ .min = 0, .max = 0 } else null;
                break :blk .{ .min = @min(range.min *| min, cap), .max = @min(range.max *| hi, cap) };
            },
            .backref => blk: {
                const backref = node.data.backref;
                var out: ?LengthRange = null;
                for (self.group_nodes, 0..) |maybe, i| {
                    const group_node = maybe orelse continue;
                    const group = group_node.data.group;
                    const wanted = if (backref.name) |name|
                        (if (group.name) |group_name| std.mem.eql(u8, name, group_name) else false)
                    else
                        i == backref.index;
                    if (!wanted) continue;
                    const range = self.lookbehindLength(group.child, depth + 1) orelse break :blk null;
                    // An unset group fails the reference, an empty one spans 0.
                    out = if (out) |o| .{ .min = @min(o.min, range.min), .max = @max(o.max, range.max) } else range;
                }
                break :blk out;
            },
        };
    }

    // A loop whose body has choices (`(?:'b*?)*`, `(?:a|ab)*`) cannot be
    // matched here when something follows it: this engine collects a loop's
    // ends by repeating its body at the body's first end, so `(?:'b*?)*c`
    // missed `'bc` and `(?:a|ab)*c` missed `abc` (zig-utils/zig-regex#57). A
    // concatenation whose left side can end in such a loop
    // (`trailing_choice_loop`), and a lookaround whose body holds one, go to
    // the continuation matcher, which takes the first end, continues and comes
    // back for the others only on failure. A loop followed by more within the
    // left side is handed over by its own concatenation, so a large
    // alternation with a loop inside one branch stays here. A loop with nothing
    // after it is already right here: its first path is the one that matches.

    /// Record that a search failed for `err` (an allocation that failed, or an
    /// error from a step it depends on) and give up with `result`. The first
    /// error is kept, so an earlier timeout is not replaced. Choice traversal
    /// must report these, not turn them into a miss: `findOnce` returns no
    /// match when `match_error` is set, and the `Regex` boundary reports it.
    fn failWith(self: *BacktrackEngine, err: anyerror, result: anytype) @TypeOf(result) {
        if (self.match_error == null) self.match_error = err;
        return result;
    }

    /// `failWith` for a function that returns an error union.
    fn failWithError(self: *BacktrackEngine, err: anyerror) anyerror {
        if (self.match_error == null) self.match_error = err;
        return err;
    }

    /// The most choices one continuation invocation may hold while the memo is
    /// on: each saves a copy of every capture, so the budget shrinks as groups
    /// are added, keeping those copies to a few megabytes.
    fn choiceBudget(self: *const BacktrackEngine) usize {
        return memo_state_floor / @max(1, self.captures.len / 4);
    }

    /// Whether the continuation matcher's loops follow PCRE's rules for empty
    /// iterations and captures: in the pieces of a PCRE-style pattern this
    /// engine hands it (`hybrid`). A pattern it runs whole keeps ECMAScript's.
    fn pcreLoops(self: *const BacktrackEngine) bool {
        return self.hybrid and !self.flags.ecmascript;
    }

    /// A repeat with a min of 2 or more whose iterations can end in more than
    /// one place this engine would not try: `{n,}` over a body with choices,
    /// or `{n,m}` over a body holding a loop with choices. Its own later
    /// required iterations follow the first, so it needs the continuation
    /// matcher even with nothing after it (`(?:b*c.*c){2,}` must give back part
    /// of the first `.*`). With a min of 0 or 1, stopping after any iteration
    /// is allowed and the first path is the one that matches.
    /// Whether a repeat goes to the continuation matcher in the pieces this
    /// engine hands it (`hybrid`): one `requiredChoiceIterations` names, or a
    /// bounded one over a body with choices and a group in a pattern with a
    /// backreference. This engine enumerates a bounded body's choices itself,
    /// keeping the first path to each count and position, but a backreference
    /// can need a later path's captures there (`(?:b+|(a)|\1){2}` on `bbb`),
    /// so it leaves such a repeat to its first ends (`boundedRepeatHasChoices`).
    /// Whether a loop goes to the continuation matcher in the pieces this
    /// engine hands it: one `repeatNeedsContinuations` names, or in PCRE mode
    /// an unbounded one whose body can match empty. PCRE takes an empty
    /// iteration where it comes in the body's order and ends the loop there
    /// (`(a??)+` on `aa` matches empty); this engine follows ECMAScript's
    /// RepeatMatcher, which rejects it and makes the body consume. The
    /// continuation matcher's PCRE pieces take it (`pcreLoops`). A bounded
    /// repeat's own enumeration takes it in PCRE mode instead
    /// (`collectBoundedRepeatMatchesInner`).
    fn loopNeedsContinuations(self: *BacktrackEngine, node: *ast.Node) bool {
        if (self.repeatNeedsContinuations(node)) return true;
        if (self.flags.ecmascript) return false;
        return switch (node.node_type) {
            .star => node.data.star.child.facts.nullable,
            .plus => node.data.plus.child.facts.nullable,
            .repeat => node.data.repeat.child.facts.nullable and node.data.repeat.bounds.max == null,
            else => false,
        };
    }

    /// `loopNeedsContinuations` for the loop `node` ends in: the node itself,
    /// through groups around it and the right sides of concatenations.
    fn tailLoopNeedsContinuations(self: *BacktrackEngine, node: *ast.Node) bool {
        var current = node;
        while (true) switch (current.node_type) {
            .group => current = current.data.group.child,
            .concat => current = current.data.concat.right,
            else => return self.loopNeedsContinuations(current),
        };
    }

    fn repeatNeedsContinuations(self: *BacktrackEngine, node: *ast.Node) bool {
        if (requiredChoiceIterations(node)) return true;
        if (node.node_type != .repeat) return false;
        const repeat = node.data.repeat;
        const child = repeat.child.facts;
        return repeat.bounds.max != null and (child.quantifiers or child.alternation) and
            child.capturing_group and self.hasBackreference(self.ast_root);
    }

    fn requiredChoiceIterations(node: *ast.Node) bool {
        if (node.node_type != .repeat) return false;
        const repeat = node.data.repeat;
        if (repeat.bounds.min < 2) return false;
        const child = repeat.child.facts;
        // A bounded body's own choices are enumerated here; only a loop
        // inside it repeats from its first end (`(?:x(?:a|ab)*?){2}`).
        if (repeat.bounds.max != null) return child.choice_loop;
        return child.quantifiers or child.alternation or child.choice_loop;
    }

    fn continuationFirst(self: *BacktrackEngine, node: *ast.Node, pos: usize) ?usize {
        return self.matchWithContinuations(node, pos, false, .first) catch |err| {
            self.match_error = err;
            return null;
        };
    }

    fn continuationTarget(self: *BacktrackEngine, node: *ast.Node, pos: usize, target_end: usize) bool {
        const end = self.matchWithContinuations(node, pos, false, .{ .target = target_end }) catch |err| {
            self.match_error = err;
            return false;
        };
        return end != null;
    }

    fn continuationEnds(self: *BacktrackEngine, node: *ast.Node, pos: usize, positions: *std.ArrayList(usize)) !void {
        _ = self.matchWithContinuations(node, pos, false, .{ .collect = positions }) catch |err| {
            self.match_error = err;
            return err;
        };
    }

    fn continuationAssertion(self: *BacktrackEngine, child: *ast.Node, pos: usize, comptime reverse: bool) bool {
        const end = self.matchWithContinuations(child, pos, reverse, .{ .assertion = !child.facts.capturing_group }) catch |err| {
            self.match_error = err;
            return false;
        };
        return end != null;
    }

    fn matchReverseNode(self: *BacktrackEngine, node: *ast.Node, pos: usize) ?usize {
        self.step_count += 1;
        if (self.match_error != null or self.step_count > self.max_steps) return null;

        return switch (node.node_type) {
            .literal => self.matchReverseLiteral(node.data.literal, pos),
            .any => self.matchReverseAny(pos),
            .concat => self.matchReverseConcat(node.data.concat, pos),
            .alternation => self.matchReverseAlternation(node.data.alternation, pos),
            .star => self.matchReverseStar(node.data.star, pos),
            .plus => self.matchReversePlus(node.data.plus, pos),
            .optional => self.matchReverseOptional(node.data.optional, pos),
            .repeat => self.matchReverseRepeat(node.data.repeat, pos),
            .char_class => self.matchReverseCharClass(node.data.char_class, pos),
            .group => self.matchReverseGroup(node.data.group, pos),
            .anchor => self.matchAnchor(node.data.anchor, pos),
            .empty => pos,
            .lookahead => self.matchLookahead(node.data.lookahead, pos),
            .lookbehind => self.matchLookbehind(node.data.lookbehind, pos),
            .backref => self.matchReverseBackreference(node.data.backref, pos),
            .unicode_property => self.matchReverseUnicodeProperty(node.data.unicode_property, pos),
            .class_set => self.matchReverseClassSet(node.data.class_set, pos),
        };
    }

    fn matchReverseConcat(self: *BacktrackEngine, concat: ast.Node.Concat, pos: usize) ?usize {
        const right_has_choices = self.hasQuantifiers(concat.right) or self.hasAlternation(concat.right);

        if (!right_has_choices) {
            const split = self.matchReverseNode(concat.right, pos) orelse return null;
            return self.matchReverseNode(concat.left, split);
        }

        const base_captures = self.allocator.alloc(CaptureGroup, self.captures.len) catch |err| return self.failWith(err, @as(?usize, null));
        defer self.allocator.free(base_captures);
        @memcpy(base_captures, self.captures);

        var splits = std.ArrayList(usize).initCapacity(self.allocator, 0) catch |err| return self.failWith(err, @as(?usize, null));
        defer splits.deinit(self.allocator);
        self.collectAllReverseMatches(concat.right, pos, &splits) catch |err| return self.failWith(err, @as(?usize, null));

        for (splits.items) |split| {
            @memcpy(self.captures, base_captures);
            if (!self.matchReverseNodeConstrained(concat.right, pos, split)) continue;
            if (self.matchReverseNode(concat.left, split)) |start| return start;
        }

        @memcpy(self.captures, base_captures);
        return null;
    }

    fn matchReverseAlternation(self: *BacktrackEngine, alt: ast.Node.Alternation, pos: usize) ?usize {
        // CompileSubpattern (Disjunction): a failed alternative must not leak
        // captured strings into the next alternative's MatchState.
        const saved = self.allocator.dupe(CaptureGroup, self.captures) catch |err| {
            self.match_error = err;
            return null;
        };
        defer self.allocator.free(saved);
        const left = self.matchReverseNode(alt.left, pos);
        if (self.match_error == null) if (left) |end| return end;
        @memcpy(self.captures, saved);
        if (self.match_error != null) return null;
        const right = self.matchReverseNode(alt.right, pos);
        if (right == null or self.match_error != null) @memcpy(self.captures, saved);
        return if (self.match_error == null) right else null;
    }

    fn matchReverseGroup(self: *BacktrackEngine, group: ast.Node.Group, pos: usize) ?usize {
        const saved_flags = self.flags;
        if (group.mod) |m| {
            if (m.i) |b| self.flags.case_insensitive = b;
            if (m.m) |b| self.flags.multiline = b;
            if (m.s) |b| self.flags.dot_all = b;
        }
        defer if (group.mod != null) {
            self.flags = saved_flags;
        };

        const start_pos = self.matchReverseNode(group.child, pos) orelse return null;
        if (group.capture_index) |index| {
            if (index > 0 and index <= self.captures.len) {
                self.captures[index - 1] = .{
                    .start = start_pos,
                    .end = pos,
                    .matched = true,
                };
            }
        }
        return start_pos;
    }

    fn matchReverseStar(self: *BacktrackEngine, quant: ast.Node.Quantifier, pos: usize) ?usize {
        if (!quant.greedy) return pos;
        var current = pos;
        while (true) {
            const saved = self.allocator.alloc(CaptureGroup, self.captures.len) catch |err| return self.failWith(err, @as(?usize, null));
            defer self.allocator.free(saved);
            @memcpy(saved, self.captures);

            self.clearIterationCaptures(quant.child);
            const next = self.matchReverseNode(quant.child, current) orelse {
                @memcpy(self.captures, saved);
                break;
            };
            if (next >= current) {
                @memcpy(self.captures, saved);
                break;
            }
            current = next;
        }
        return current;
    }

    fn matchReversePlus(self: *BacktrackEngine, quant: ast.Node.Quantifier, pos: usize) ?usize {
        self.clearIterationCaptures(quant.child);
        var current = self.matchReverseNode(quant.child, pos) orelse return null;
        if (!quant.greedy) return current;

        while (true) {
            const saved = self.allocator.alloc(CaptureGroup, self.captures.len) catch |err| return self.failWith(err, @as(?usize, null));
            defer self.allocator.free(saved);
            @memcpy(saved, self.captures);

            self.clearIterationCaptures(quant.child);
            const next = self.matchReverseNode(quant.child, current) orelse {
                @memcpy(self.captures, saved);
                break;
            };
            if (next >= current) {
                @memcpy(self.captures, saved);
                break;
            }
            current = next;
        }
        return current;
    }

    fn matchReverseOptional(self: *BacktrackEngine, quant: ast.Node.Quantifier, pos: usize) ?usize {
        if (!quant.greedy) return pos;
        return self.matchReverseNode(quant.child, pos) orelse pos;
    }

    fn matchReverseRepeat(self: *BacktrackEngine, repeat: ast.Node.Repeat, pos: usize) ?usize {
        if (self.boundedRepeatHasChoices(repeat)) {
            var starts: std.ArrayList(usize) = .empty;
            defer starts.deinit(self.allocator);
            self.collectBoundedRepeatMatches(repeat, pos, &starts, true, true) catch |err| return self.failWith(err, @as(?usize, null));
            if (starts.items.len == 0) return null;
            const target = starts.items[0];
            if (self.hasCapturingGroup(repeat.child) and !self.matchBoundedRepeatConstrained(repeat, pos, target, true)) return null;
            return target;
        }
        if (self.fixedRepeatHasChoices(repeat)) {
            var starts: std.ArrayList(usize) = .empty;
            defer starts.deinit(self.allocator);
            self.collectFixedRepeatMatches(repeat, pos, &starts, true) catch |err| return self.failWith(err, @as(?usize, null));
            if (starts.items.len == 0) return null;
            const target = starts.items[0];
            if (self.hasCapturingGroup(repeat.child) and !self.matchFixedRepeatConstrained(repeat, pos, target, true)) return null;
            return target;
        }
        const min = repeat.bounds.min;
        const max = repeat.bounds.max;

        var current = pos;
        var count: usize = 0;
        const entry: ?[]CaptureGroup = if (min > 1 and !self.flags.ecmascript and self.hasCapturingGroup(repeat.child)) self.allocator.dupe(CaptureGroup, self.captures) catch |err| return self.failWith(err, @as(?usize, null)) else null;
        defer if (entry) |caps| self.allocator.free(caps);
        while (count < min) : (count += 1) {
            self.clearIterationCaptures(repeat.child);
            const next = self.matchReverseNode(repeat.child, current) orelse {
                if (entry) |caps| @memcpy(self.captures, caps);
                return null;
            };
            if (next > current) {
                if (entry) |caps| @memcpy(self.captures, caps);
                return null;
            }
            current = next;
        }

        if (!repeat.greedy) return current;

        while (max == null or count < max.?) : (count += 1) {
            const saved = self.allocator.alloc(CaptureGroup, self.captures.len) catch |err| return self.failWith(err, @as(?usize, null));
            defer self.allocator.free(saved);
            @memcpy(saved, self.captures);

            self.clearIterationCaptures(repeat.child);
            const next = self.matchReverseNode(repeat.child, current) orelse {
                @memcpy(self.captures, saved);
                break;
            };
            if (next >= current) {
                @memcpy(self.captures, saved);
                break;
            }
            current = next;
        }
        return current;
    }

    fn matchReverseNodeConstrained(self: *BacktrackEngine, node: *ast.Node, pos: usize, target_start: usize) bool {
        if (node.node_type == .repeat and self.boundedRepeatHasChoices(node.data.repeat)) {
            return self.matchBoundedRepeatConstrained(node.data.repeat, pos, target_start, true);
        }
        if (node.node_type == .repeat and self.fixedRepeatHasChoices(node.data.repeat)) {
            return self.matchFixedRepeatConstrained(node.data.repeat, pos, target_start, true);
        }
        if (node.node_type == .repeat) {
            const repeat = node.data.repeat;
            if (repeat.bounds.min == 1 and repeat.bounds.max != null and repeat.bounds.max.? == 1) {
                self.clearIterationCaptures(repeat.child);
                return self.matchReverseNodeConstrained(repeat.child, pos, target_start);
            }
        }
        switch (node.node_type) {
            .literal => return if (self.matchReverseLiteral(node.data.literal, pos)) |start| start == target_start else false,
            .any => return if (self.matchReverseAny(pos)) |start| start == target_start else false,
            .char_class => return if (self.matchReverseCharClass(node.data.char_class, pos)) |start| start == target_start else false,
            .unicode_property => return if (self.matchReverseUnicodeProperty(node.data.unicode_property, pos)) |start| start == target_start else false,
            .class_set => return if (self.matchReverseClassSet(node.data.class_set, pos)) |start| start == target_start else false,
            .anchor => return if (self.matchAnchor(node.data.anchor, pos)) |start| start == target_start else false,
            .empty => return pos == target_start,
            .group => {
                const group = node.data.group;
                const saved_flags = self.enterGroupFlags(group);
                defer self.flags = saved_flags;
                if (self.matchReverseNodeConstrained(group.child, pos, target_start)) {
                    if (group.capture_index) |index| {
                        if (index > 0 and index <= self.captures.len) {
                            self.captures[index - 1] = .{
                                .start = target_start,
                                .end = pos,
                                .matched = true,
                            };
                        }
                    }
                    return true;
                }
                return false;
            },
            .concat => {
                const c = node.data.concat;
                var splits = std.ArrayList(usize).initCapacity(self.allocator, 0) catch |err| return self.failWith(err, false);
                defer splits.deinit(self.allocator);
                self.collectAllReverseMatches(c.right, pos, &splits) catch |err| return self.failWith(err, false);

                const base_captures = self.allocator.alloc(CaptureGroup, self.captures.len) catch |err| return self.failWith(err, false);
                defer self.allocator.free(base_captures);
                @memcpy(base_captures, self.captures);

                for (splits.items) |split| {
                    if (split < target_start) continue;
                    @memcpy(self.captures, base_captures);
                    if (!self.matchReverseNodeConstrained(c.right, pos, split)) continue;
                    if (self.matchReverseNodeConstrained(c.left, split, target_start)) return true;
                }
                @memcpy(self.captures, base_captures);
                return false;
            },
            .star, .plus, .optional, .repeat => {
                // PCRE: enumerating the loop's starts would leave the captures
                // of iterations it does not keep, and nothing clears them, so
                // match the iterations that reach the target instead.
                if (!self.flags.ecmascript and self.hasCapturingGroup(node)) {
                    var saved: CaptureSnapshot = undefined;
                    const caps = saved.take(self) orelse return false;
                    defer saved.release(self);
                    if (self.replayReverseLoop(node, pos, target_start)) return true;
                    @memcpy(self.captures, caps);
                    return false;
                }
                var starts = std.ArrayList(usize).initCapacity(self.allocator, 0) catch |err| return self.failWith(err, false);
                defer starts.deinit(self.allocator);
                self.collectAllReverseMatches(node, pos, &starts) catch |err| return self.failWith(err, false);
                return std.mem.indexOfScalar(usize, starts.items, target_start) != null;
            },
            .alternation => {
                const saved = self.allocator.dupe(CaptureGroup, self.captures) catch |err| {
                    self.match_error = err;
                    return false;
                };
                defer self.allocator.free(saved);
                const left = self.matchReverseNodeConstrained(node.data.alternation.left, pos, target_start);
                if (left and self.match_error == null) return true;
                @memcpy(self.captures, saved);
                if (self.match_error != null) return false;
                const right = self.matchReverseNodeConstrained(node.data.alternation.right, pos, target_start);
                if (!right or self.match_error != null) @memcpy(self.captures, saved);
                return right and self.match_error == null;
            },
            .backref => return if (self.matchReverseBackreference(node.data.backref, pos)) |start| start == target_start else false,
            .lookahead => return if (self.matchLookahead(node.data.lookahead, pos)) |start| start == target_start else false,
            .lookbehind => return if (self.matchLookbehind(node.data.lookbehind, pos)) |start| start == target_start else false,
        }
    }

    /// Match a loop right to left from `pos` to exactly `target_start`, along
    /// the starts collectAllReverseMatches lists for it: an optional's body
    /// may end at any of its starts; a star, plus or plain repeat follows the
    /// chain where each iteration takes the body's first match.
    fn replayReverseLoop(self: *BacktrackEngine, node: *ast.Node, pos: usize, target_start: usize) bool {
        if (node.node_type == .optional) {
            const quant = node.data.optional;
            if (target_start != pos) return self.matchReverseNodeConstrained(quant.child, pos, target_start);
            if (quant.greedy) self.keepEmptyReverseIteration(quant.child, pos);
            return true;
        }
        const child, const min: usize, const max: ?usize, const greedy = switch (node.node_type) {
            .star => .{ node.data.star.child, 0, null, node.data.star.greedy },
            .plus => .{ node.data.plus.child, 1, null, node.data.plus.greedy },
            .repeat => .{ node.data.repeat.child, node.data.repeat.bounds.min, node.data.repeat.bounds.max, node.data.repeat.greedy },
            else => unreachable,
        };
        var current = pos;
        var count: usize = 0;
        while (true) {
            if (current == target_start and count >= min) {
                // A greedy PCRE loop tries one more iteration at its end; one
                // that matches empty is kept, captures and all, and ends it.
                if (greedy and (max == null or count < max.?)) self.keepEmptyReverseIteration(child, current);
                return true;
            }
            if (current < target_start) return false;
            if (max) |m| if (count >= m) return false;
            const next = self.matchReverseNode(child, current) orelse return false;
            if (next > current or (next == current and count >= min)) return false;
            current = next;
            count += 1;
        }
    }

    /// Take one iteration of `child` that matches empty at `pos` if there is
    /// one, keeping its captures (PCRE's last iteration of a greedy loop).
    fn keepEmptyIteration(self: *BacktrackEngine, child: *ast.Node, pos: usize) void {
        var saved: CaptureSnapshot = undefined;
        const caps = saved.take(self) orelse return;
        defer saved.release(self);
        if (!self.matchNodeConstrained(child, pos, pos)) @memcpy(self.captures, caps);
    }

    fn keepEmptyReverseIteration(self: *BacktrackEngine, child: *ast.Node, pos: usize) void {
        var saved: CaptureSnapshot = undefined;
        const caps = saved.take(self) orelse return;
        defer saved.release(self);
        if (!self.matchReverseNodeConstrained(child, pos, pos)) @memcpy(self.captures, caps);
    }

    fn collectAllReverseMatches(self: *BacktrackEngine, node: *ast.Node, pos: usize, positions: *std.ArrayList(usize)) !void {
        switch (node.node_type) {
            .star => {
                const quant = node.data.star;
                if (!quant.greedy) try positions.append(self.allocator, pos);

                var all = std.ArrayList(usize).initCapacity(self.allocator, 0) catch |err| return self.failWithError(err);
                defer all.deinit(self.allocator);
                try all.append(self.allocator, pos);

                var current = pos;
                while (true) {
                    self.clearIterationCaptures(quant.child);
                    const next = self.matchReverseNode(quant.child, current) orelse break;
                    if (next >= current) break;
                    current = next;
                    try all.append(self.allocator, current);
                }

                if (quant.greedy) {
                    var i = all.items.len;
                    while (i > 0) {
                        i -= 1;
                        try positions.append(self.allocator, all.items[i]);
                    }
                } else {
                    for (all.items[1..]) |start| try positions.append(self.allocator, start);
                }
            },
            .plus => {
                const quant = node.data.plus;
                self.clearIterationCaptures(quant.child);
                const first = self.matchReverseNode(quant.child, pos) orelse return;
                try self.collectReverseQuantifierTail(quant.child, first, quant.greedy, positions);
            },
            .optional => {
                const quant = node.data.optional;
                if (quant.greedy) {
                    try self.collectAllReverseMatches(quant.child, pos, positions);
                    try positions.append(self.allocator, pos);
                } else {
                    try positions.append(self.allocator, pos);
                    try self.collectAllReverseMatches(quant.child, pos, positions);
                }
            },
            .repeat => {
                const repeat = node.data.repeat;
                if (self.boundedRepeatHasChoices(repeat)) {
                    try self.collectBoundedRepeatMatches(repeat, pos, positions, true, false);
                } else if (self.fixedRepeatHasChoices(repeat)) {
                    try self.collectFixedRepeatMatches(repeat, pos, positions, true);
                } else if (repeat.bounds.min == 1 and repeat.bounds.max != null and repeat.bounds.max.? == 1) {
                    self.clearIterationCaptures(repeat.child);
                    try self.collectAllReverseMatches(repeat.child, pos, positions);
                } else try self.collectReverseRepeatMatches(repeat, pos, positions);
            },
            .concat => {
                const c = node.data.concat;
                var right_positions = std.ArrayList(usize).initCapacity(self.allocator, 0) catch |err| return self.failWithError(err);
                defer right_positions.deinit(self.allocator);
                const base_captures = self.allocator.alloc(CaptureGroup, self.captures.len) catch |err| return self.failWithError(err);
                defer self.allocator.free(base_captures);
                // PCRE does not clear loop bodies per iteration, so what the
                // enumeration ran stays set; take the captures from before it.
                @memcpy(base_captures, self.captures);
                try self.collectAllReverseMatches(c.right, pos, &right_positions);
                if (self.flags.ecmascript) @memcpy(base_captures, self.captures);

                for (right_positions.items) |split| {
                    @memcpy(self.captures, base_captures);
                    _ = self.matchReverseNodeConstrained(c.right, pos, split);
                    try self.collectAllReverseMatches(c.left, split, positions);
                }
                @memcpy(self.captures, base_captures);
            },
            .group => {
                const group = node.data.group;
                const saved_flags = self.enterGroupFlags(group);
                defer self.flags = saved_flags;
                if (self.hasQuantifiers(group.child) or self.hasAlternation(group.child)) {
                    try self.collectAllReverseMatches(group.child, pos, positions);
                } else if (self.matchReverseNode(node, pos)) |start| {
                    try positions.append(self.allocator, start);
                }
            },
            .alternation => {
                try self.collectAllReverseMatches(node.data.alternation.left, pos, positions);
                try self.collectAllReverseMatches(node.data.alternation.right, pos, positions);
            },
            else => {
                if (self.matchReverseNode(node, pos)) |start| try positions.append(self.allocator, start);
            },
        }
    }

    fn collectReverseQuantifierTail(self: *BacktrackEngine, child: *ast.Node, pos: usize, greedy: bool, positions: *std.ArrayList(usize)) !void {
        var all = std.ArrayList(usize).initCapacity(self.allocator, 0) catch |err| return self.failWithError(err);
        defer all.deinit(self.allocator);
        try all.append(self.allocator, pos);

        var current = pos;
        while (true) {
            self.clearIterationCaptures(child);
            const next = self.matchReverseNode(child, current) orelse break;
            if (next >= current) break;
            current = next;
            try all.append(self.allocator, current);
        }

        if (greedy) {
            var i = all.items.len;
            while (i > 0) {
                i -= 1;
                try positions.append(self.allocator, all.items[i]);
            }
        } else {
            for (all.items) |start| try positions.append(self.allocator, start);
        }
    }

    fn collectReverseRepeatMatches(self: *BacktrackEngine, repeat: ast.Node.Repeat, pos: usize, positions: *std.ArrayList(usize)) !void {
        var current = pos;
        var count: usize = 0;
        while (count < repeat.bounds.min) : (count += 1) {
            self.clearIterationCaptures(repeat.child);
            const next = self.matchReverseNode(repeat.child, current) orelse return;
            if (next > current) return;
            current = next;
        }

        var all = std.ArrayList(usize).initCapacity(self.allocator, 0) catch |err| return self.failWithError(err);
        defer all.deinit(self.allocator);
        try all.append(self.allocator, current);

        while (repeat.bounds.max == null or count < repeat.bounds.max.?) : (count += 1) {
            self.clearIterationCaptures(repeat.child);
            const next = self.matchReverseNode(repeat.child, current) orelse break;
            if (next >= current) break;
            current = next;
            try all.append(self.allocator, current);
        }

        if (repeat.greedy) {
            var i = all.items.len;
            while (i > 0) {
                i -= 1;
                try positions.append(self.allocator, all.items[i]);
            }
        } else {
            for (all.items) |start| try positions.append(self.allocator, start);
        }
    }

    fn matchReverseLiteral(self: *BacktrackEngine, c: u8, pos: usize) ?usize {
        if (pos == 0) return null;
        const start = pos - 1;
        const input_char = self.input[start];
        const matches = if (self.flags.case_insensitive)
            std.ascii.toLower(input_char) == std.ascii.toLower(c)
        else
            input_char == c;
        return if (matches) start else null;
    }

    fn previousCodepointStart(self: *BacktrackEngine, pos: usize) ?usize {
        if (pos == 0 or pos > self.input.len) return null;
        if (self.flags.bytes) return pos - 1;
        var start = pos - 1;
        while (start > 0 and (self.input[start] & 0xC0) == 0x80) : (start -= 1) {}
        if (self.flags.unicode) {
            const dec = unicode_mod.decodeUtf8Lenient(self.input[start..]) orelse return start;
            if (common.isLowSurrogate(dec.codepoint) and start >= 3) {
                var prev = start - 1;
                while (prev > 0 and (self.input[prev] & 0xC0) == 0x80) : (prev -= 1) {}
                if (unicode_mod.decodeUtf8Lenient(self.input[prev..])) |before| {
                    if (common.isHighSurrogate(before.codepoint) and prev + before.len == start) return prev;
                }
            }
        }
        return start;
    }

    fn matchReverseAny(self: *BacktrackEngine, pos: usize) ?usize {
        const start = self.previousCodepointStart(pos) orelse return null;
        const len = common.dotMatchLen(self.input, start, self.flags) orelse return null;
        return if (start + len == pos) start else null;
    }

    fn matchReverseCharClass(self: *BacktrackEngine, char_class: common.CharClass, pos: usize) ?usize {
        if (pos == 0) return null;

        if (self.flags.unicode and self.flags.case_insensitive and isAsciiWordClass(char_class)) {
            const start = self.previousCodepointStart(pos) orelse return null;
            const dec = unicode_mod.decodeUtf8Lenient(self.input[start..]) orelse return null;
            if (start + dec.len != pos) return null;
            const word = self.isEcmaWordCodepoint(dec.codepoint);
            return if (word != char_class.negated) start else null;
        }

        const start = pos - 1;
        const c = self.input[start];
        const matches = if (self.flags.case_insensitive)
            char_class.matchesCI(c)
        else
            char_class.matches(c);
        return if (matches) start else null;
    }

    fn matchReverseUnicodeProperty(self: *BacktrackEngine, up: ast.Node.UnicodeProp, pos: usize) ?usize {
        const start = self.previousCodepointStart(pos) orelse return null;
        const dec = unicode_mod.decodeUtf8Lenient(self.input[start..]) orelse return null;
        if (start + dec.len != pos) return null;
        if (!self.matchesUnicodeProperty(up, dec.codepoint)) return null;
        return start;
    }

    fn matchesUnicodeProperty(self: *BacktrackEngine, up: ast.Node.UnicodeProp, cp: u21) bool {
        if (!self.flags.case_insensitive) {
            const matched = unicode_mod.matchesSpec(cp, up.spec);
            return matched != up.negated;
        }

        if (up.negated) {
            return !unicode_mod.matchesSpec(canonicalizeForPropertyComplement(cp), up.spec);
        }

        if (unicode_mod.matchesSpec(cp, up.spec)) return true;
        return unicode_mod.matchesSpec(asciiSwapCase(cp), up.spec);
    }

    fn asciiSwapCase(cp: u21) u21 {
        if (cp >= 'a' and cp <= 'z') return cp - ('a' - 'A');
        if (cp >= 'A' and cp <= 'Z') return cp + ('a' - 'A');
        return cp;
    }

    fn canonicalizeForPropertyComplement(cp: u21) u21 {
        if (cp >= 'A' and cp <= 'Z') return cp + ('a' - 'A');
        if (cp == 0x212A) return 'k';
        if (cp == 0x017F) return 's';
        return cp;
    }

    fn matchReverseClassSet(self: *BacktrackEngine, set: *ast.Node.ClassSet, pos: usize) ?usize {
        var start: usize = 0;
        while (start < pos) : (start += 1) {
            if (set.matchLongestMode(self.input, start, self.classSetCaseFoldMode())) |end| {
                if (end == pos) return start;
            }
        }
        return null;
    }

    fn classSetCaseFoldMode(self: *const BacktrackEngine) ast.Node.ClassSet.CaseFoldMode {
        if (!self.flags.case_insensitive) return .none;
        return if (self.flags.unicode or self.flags.unicode_sets) .unicode else .legacy;
    }

    /// One character of a case-insensitive ECMAScript backreference: its
    /// Canonicalize key (`ast.Node.canonicalizeKey`) and its length in bytes.
    const CanonUnit = struct { key: u21, len: usize };

    /// A byte that does not decode compares only with the same byte.
    const undecodable_key_base: u21 = 0x110000;

    /// The character that starts at `i`, read no further than `hi`. With `u`
    /// or `v` a high and a low surrogate triple form one character; without
    /// them every WTF-8 sequence is one UTF-16 code unit, since zig-js splits
    /// astral characters into surrogate triples before non-`u` matching.
    fn canonUnitAt(self: *const BacktrackEngine, i: usize, hi: usize, mode: ast.Node.ClassSet.CaseFoldMode) CanonUnit {
        const b = self.input[i];
        if (b < 0x80) return .{ .key = std.ascii.toLower(b), .len = 1 };
        const dec = unicode_mod.decodeUtf8Lenient(self.input[i..hi]) orelse
            return .{ .key = undecodable_key_base + b, .len = 1 };
        var cp: u21 = dec.codepoint;
        var len: usize = dec.len;
        if (mode == .unicode and common.isHighSurrogate(cp) and i + len < hi) {
            if (unicode_mod.decodeUtf8Lenient(self.input[i + len .. hi])) |low| {
                if (common.isLowSurrogate(low.codepoint)) {
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (low.codepoint - 0xDC00);
                    len += low.len;
                }
            }
        }
        return .{ .key = ast.Node.canonicalizeKey(cp, mode), .len = len };
    }

    /// The character that ends at `end`, starting no earlier than `lo`; the
    /// mirror of `canonUnitAt` for backreferences matched backward.
    fn canonUnitBefore(self: *const BacktrackEngine, lo: usize, end: usize, mode: ast.Node.ClassSet.CaseFoldMode) CanonUnit {
        const last = self.input[end - 1];
        if (last < 0x80) return .{ .key = std.ascii.toLower(last), .len = 1 };
        var start = end - 1;
        var back: usize = 0;
        while (start > lo and back < 3 and (self.input[start] & 0xC0) == 0x80) : ({
            start -= 1;
            back += 1;
        }) {}
        const dec = unicode_mod.decodeUtf8Lenient(self.input[start..end]) orelse
            return .{ .key = undecodable_key_base + last, .len = 1 };
        if (start + dec.len != end) return .{ .key = undecodable_key_base + last, .len = 1 };
        var cp: u21 = dec.codepoint;
        var len: usize = dec.len;
        if (mode == .unicode and common.isLowSurrogate(cp) and start >= lo + 3) {
            if (unicode_mod.decodeUtf8Lenient(self.input[start - 3 .. start])) |high| {
                if (high.len == 3 and common.isHighSurrogate(high.codepoint)) {
                    cp = 0x10000 + ((high.codepoint - 0xD800) << 10) + (cp - 0xDC00);
                    len += 3;
                }
            }
        }
        return .{ .key = ast.Node.canonicalizeKey(cp, mode), .len = len };
    }

    /// BackreferenceMatcher (22.2.2.7.2) under IgnoreCase: the captured
    /// characters and the input's compare one by one after Canonicalize. Folded
    /// pairs can differ in byte length (ſ and s, K and k, ẞ and ß), so the two
    /// spans advance on separate cursors instead of being sliced to one length.
    fn matchCaptureTextCanonical(self: *BacktrackEngine, capture: CaptureGroup, pos: usize) ?usize {
        const mode = self.classSetCaseFoldMode();
        var c = capture.start;
        var i = pos;
        while (c < capture.end) {
            if (i >= self.input.len) return null;
            const a = self.canonUnitAt(c, capture.end, mode);
            const b = self.canonUnitAt(i, self.input.len, mode);
            if (a.key != b.key) return null;
            c += a.len;
            i += b.len;
        }
        return i;
    }

    /// `matchCaptureTextCanonical` for a backreference matched backward (in a
    /// lookbehind): both spans are walked from their ends.
    fn matchCaptureTextCanonicalReverse(self: *BacktrackEngine, capture: CaptureGroup, pos: usize) ?usize {
        const mode = self.classSetCaseFoldMode();
        var c = capture.end;
        var i = pos;
        while (c > capture.start) {
            if (i == 0) return null;
            const a = self.canonUnitBefore(capture.start, c, mode);
            const b = self.canonUnitBefore(0, i, mode);
            if (a.key != b.key) return null;
            c -= a.len;
            i -= b.len;
        }
        return i;
    }

    fn matchReverseBackreference(self: *BacktrackEngine, backref: ast.Node.Backreference, pos: usize) ?usize {
        if (backref.name) |name| return self.matchNamedBackreferenceReverse(self.ast_root, name, pos);
        return self.matchCaptureBackreferenceReverse(backref.index, pos);
    }

    fn matchCaptureBackreferenceReverse(self: *BacktrackEngine, capture_index: usize, pos: usize) ?usize {
        if (capture_index == 0 or capture_index > self.captures.len) return null;
        const capture = self.captures[capture_index - 1];
        if (!capture.matched) return self.unsetBackreference(pos);
        return self.matchCaptureTextReverse(capture, pos);
    }

    fn matchPresentCaptureBackreferenceReverse(self: *BacktrackEngine, capture_index: usize, pos: usize) ?usize {
        if (capture_index == 0 or capture_index > self.captures.len) return null;
        const capture = self.captures[capture_index - 1];
        if (!capture.matched) return null;
        return self.matchCaptureTextReverse(capture, pos);
    }

    fn matchCaptureTextReverse(self: *BacktrackEngine, capture: CaptureGroup, pos: usize) ?usize {
        if (self.flags.case_insensitive and self.flags.ecmascript) return self.matchCaptureTextCanonicalReverse(capture, pos);
        const captured_text = self.input[capture.start..capture.end];
        if (captured_text.len > pos) return null;
        const start = pos - captured_text.len;
        const text_to_match = self.input[start..pos];

        if (self.flags.case_insensitive) {
            for (captured_text, text_to_match) |a, b| {
                if (std.ascii.toLower(a) != std.ascii.toLower(b)) return null;
            }
            return start;
        }

        return if (std.mem.eql(u8, captured_text, text_to_match)) start else null;
    }

    fn matchNamedBackreferenceReverse(self: *BacktrackEngine, node: *ast.Node, name: []const u8, pos: usize) ?usize {
        var found_name = false;
        var found_participating = false;
        if (self.matchNamedBackreferenceParticipatingReverse(node, name, pos, &found_name, &found_participating)) |start| return start;
        return if (found_name and !found_participating) self.unsetBackreference(pos) else null;
    }

    fn matchNamedBackreferenceParticipatingReverse(self: *BacktrackEngine, node: *ast.Node, name: []const u8, pos: usize, found_name: *bool, found_participating: *bool) ?usize {
        // PCRE keeps captures across iterations, so several groups sharing the
        // name can be set at once; PCRE2 refers to the lowest-numbered set one.
        // Groups are numbered in this walk's pre-order. In ECMAScript at most
        // one of them participates.
        if (!self.flags.ecmascript and found_participating.*) return null;
        switch (node.node_type) {
            .group => {
                const group = node.data.group;
                if (group.name) |group_name| {
                    if (std.mem.eql(u8, group_name, name)) {
                        found_name.* = true;
                        if (group.capture_index) |index| {
                            if (index > 0 and index <= self.captures.len and self.captures[index - 1].matched)
                                found_participating.* = true;
                            if (self.matchPresentCaptureBackreferenceReverse(index, pos)) |start| return start;
                        }
                    }
                }
                return self.matchNamedBackreferenceParticipatingReverse(group.child, name, pos, found_name, found_participating);
            },
            .concat => {
                if (self.matchNamedBackreferenceParticipatingReverse(node.data.concat.left, name, pos, found_name, found_participating)) |start| return start;
                return self.matchNamedBackreferenceParticipatingReverse(node.data.concat.right, name, pos, found_name, found_participating);
            },
            .alternation => {
                if (self.matchNamedBackreferenceParticipatingReverse(node.data.alternation.left, name, pos, found_name, found_participating)) |start| return start;
                return self.matchNamedBackreferenceParticipatingReverse(node.data.alternation.right, name, pos, found_name, found_participating);
            },
            .star => return self.matchNamedBackreferenceParticipatingReverse(node.data.star.child, name, pos, found_name, found_participating),
            .plus => return self.matchNamedBackreferenceParticipatingReverse(node.data.plus.child, name, pos, found_name, found_participating),
            .optional => return self.matchNamedBackreferenceParticipatingReverse(node.data.optional.child, name, pos, found_name, found_participating),
            .repeat => return self.matchNamedBackreferenceParticipatingReverse(node.data.repeat.child, name, pos, found_name, found_participating),
            .lookahead => return self.matchNamedBackreferenceParticipatingReverse(node.data.lookahead.child, name, pos, found_name, found_participating),
            .lookbehind => return self.matchNamedBackreferenceParticipatingReverse(node.data.lookbehind.child, name, pos, found_name, found_participating),
            else => return null,
        }
    }

    fn isAsciiWordClass(char_class: common.CharClass) bool {
        const word = common.CharClasses.word;
        if (char_class.ranges.len != word.ranges.len) return false;
        for (char_class.ranges, word.ranges) |a, b| {
            if (a.start != b.start or a.end != b.end) return false;
        }
        return true;
    }

    fn matchBackreference(self: *BacktrackEngine, backref: ast.Node.Backreference, pos: usize) ?usize {
        // Backreference: match the same text that was captured by a previous group
        if (backref.name) |name| return self.matchNamedBackreference(self.ast_root, name, pos);

        const capture_index = backref.index;
        return self.matchCaptureBackreference(capture_index, pos);
    }

    /// A backreference to a group that has not participated matches the empty
    /// string in ECMAScript and fails in PCRE (without
    /// PCRE2_MATCH_UNSET_BACKREF): `(a)?b\1` matches `b` only in ECMAScript.
    fn unsetBackreference(self: *const BacktrackEngine, pos: usize) ?usize {
        return if (self.flags.ecmascript) pos else null;
    }

    fn matchCaptureBackreference(self: *BacktrackEngine, capture_index: usize, pos: usize) ?usize {
        // Validate capture index (1-based)
        if (capture_index == 0 or capture_index > self.captures.len) {
            return null;
        }

        const capture = self.captures[capture_index - 1];

        if (!capture.matched) return self.unsetBackreference(pos);

        return self.matchCaptureText(capture, pos);
    }

    fn matchPresentCaptureBackreference(self: *BacktrackEngine, capture_index: usize, pos: usize) ?usize {
        if (capture_index == 0 or capture_index > self.captures.len) return null;
        const capture = self.captures[capture_index - 1];
        if (!capture.matched) return null;
        return self.matchCaptureText(capture, pos);
    }

    fn matchCaptureText(self: *BacktrackEngine, capture: CaptureGroup, pos: usize) ?usize {
        if (self.flags.case_insensitive and self.flags.ecmascript) return self.matchCaptureTextCanonical(capture, pos);
        // Get the captured text
        const captured_text = self.input[capture.start..capture.end];

        // Try to match the same text at current position
        if (pos + captured_text.len > self.input.len) {
            return null;
        }

        const text_to_match = self.input[pos .. pos + captured_text.len];

        if (self.flags.case_insensitive) {
            // Case-insensitive comparison
            for (captured_text, text_to_match) |a, b| {
                const a_lower = if (a >= 'A' and a <= 'Z') a + ('a' - 'A') else a;
                const b_lower = if (b >= 'A' and b <= 'Z') b + ('a' - 'A') else b;
                if (a_lower != b_lower) return null;
            }
            return pos + captured_text.len;
        }

        if (std.mem.eql(u8, captured_text, text_to_match)) {
            return pos + captured_text.len;
        }

        return null;
    }

    fn matchNamedBackreference(self: *BacktrackEngine, node: *ast.Node, name: []const u8, pos: usize) ?usize {
        var found_name = false;
        var found_participating = false;
        if (self.matchNamedBackreferenceParticipating(node, name, pos, &found_name, &found_participating)) |end| return end;
        return if (found_name and !found_participating) self.unsetBackreference(pos) else null;
    }

    fn matchNamedBackreferenceParticipating(self: *BacktrackEngine, node: *ast.Node, name: []const u8, pos: usize, found_name: *bool, found_participating: *bool) ?usize {
        // PCRE keeps captures across iterations, so several groups sharing the
        // name can be set at once; PCRE2 refers to the lowest-numbered set one.
        // Groups are numbered in this walk's pre-order. In ECMAScript at most
        // one of them participates.
        if (!self.flags.ecmascript and found_participating.*) return null;
        switch (node.node_type) {
            .group => {
                const group = node.data.group;
                if (group.name) |group_name| {
                    if (std.mem.eql(u8, group_name, name)) {
                        found_name.* = true;
                        if (group.capture_index) |index| {
                            if (index > 0 and index <= self.captures.len and self.captures[index - 1].matched)
                                found_participating.* = true;
                            if (self.matchPresentCaptureBackreference(index, pos)) |end| return end;
                        }
                    }
                }
                return self.matchNamedBackreferenceParticipating(group.child, name, pos, found_name, found_participating);
            },
            .concat => {
                if (self.matchNamedBackreferenceParticipating(node.data.concat.left, name, pos, found_name, found_participating)) |end| return end;
                return self.matchNamedBackreferenceParticipating(node.data.concat.right, name, pos, found_name, found_participating);
            },
            .alternation => {
                if (self.matchNamedBackreferenceParticipating(node.data.alternation.left, name, pos, found_name, found_participating)) |end| return end;
                return self.matchNamedBackreferenceParticipating(node.data.alternation.right, name, pos, found_name, found_participating);
            },
            .star => return self.matchNamedBackreferenceParticipating(node.data.star.child, name, pos, found_name, found_participating),
            .plus => return self.matchNamedBackreferenceParticipating(node.data.plus.child, name, pos, found_name, found_participating),
            .optional => return self.matchNamedBackreferenceParticipating(node.data.optional.child, name, pos, found_name, found_participating),
            .repeat => return self.matchNamedBackreferenceParticipating(node.data.repeat.child, name, pos, found_name, found_participating),
            .lookahead => return self.matchNamedBackreferenceParticipating(node.data.lookahead.child, name, pos, found_name, found_participating),
            .lookbehind => return self.matchNamedBackreferenceParticipating(node.data.lookbehind.child, name, pos, found_name, found_participating),
            else => return null,
        }
    }
};

// ============================================================================
// SECURITY TESTS: ReDoS Protection
// ============================================================================

test "backtrack: lazy continuation retires unreachable scan state" {
    const allocator = std.testing.allocator;
    var p = try @import("parser.zig").Parser.init(allocator, "^(.+?)!$");
    var tree = try p.parse();
    defer tree.deinit();
    const input = try allocator.alloc(u8, 65537);
    defer allocator.free(input);
    @memset(input, 'a');
    input[input.len - 1] = '!';
    const scratch = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(scratch);
    var fixed = std.heap.FixedBufferAllocator.init(scratch);
    var engine = try BacktrackEngine.init(fixed.allocator(), tree.root, tree.capture_count, .{ .ecmascript = true });
    defer engine.deinit();
    var found = engine.find(input) orelse return engine.match_error orelse error.ExpectedMatch;
    defer found.deinit(fixed.allocator());
    try std.testing.expectEqual(input.len, found.end);
    try std.testing.expectEqual(@as(usize, 0), found.captures[0].start);
    try std.testing.expectEqual(input.len - 1, found.captures[0].end);
}

test "backtrack: continuation pool preserves shared tails while recycling dead heads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pool = BacktrackEngine.ContinuationPool{ .allocator = arena.allocator() };
    const tail = try pool.push(null, .{ .finish_group = .{ .index = null, .start = 42, .flags = .{} } });
    var left: ?*BacktrackEngine.ContinuationLink = try pool.push(tail, .{ .finish_group = .{ .index = null, .start = 1, .flags = .{} } });
    var right: ?*BacktrackEngine.ContinuationLink = try pool.push(BacktrackEngine.ContinuationPool.share(tail), .{ .finish_group = .{ .index = null, .start = 2, .flags = .{} } });
    try std.testing.expectEqual(@as(usize, 1), pool.pop(&left).?.finish_group.start);
    try std.testing.expectEqual(@as(usize, 42), pool.pop(&left).?.finish_group.start);
    try std.testing.expect(left == null);
    // The retired left head can be overwritten; the shared tail stays live.
    var reused: ?*BacktrackEngine.ContinuationLink = try pool.push(null, .{ .finish_group = .{ .index = null, .start = 3, .flags = .{} } });
    try std.testing.expectEqual(@as(usize, 2), pool.pop(&right).?.finish_group.start);
    try std.testing.expectEqual(@as(usize, 42), pool.pop(&right).?.finish_group.start);
    try std.testing.expectEqual(@as(usize, 3), pool.pop(&reused).?.finish_group.start);
    try std.testing.expect(right == null and reused == null);
}

test "backtrack: pooled continuations propagate every allocation failure" {
    var p = try @import("parser.zig").Parser.init(std.testing.allocator, "^(a|aa)+?b$");
    var tree = try p.parse();
    defer tree.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, root: *ast.Node, capture_count: usize) !void {
            var engine = try BacktrackEngine.init(allocator, root, capture_count, .{ .ecmascript = true });
            defer engine.deinit();
            var found = engine.find("aaaab") orelse return engine.match_error orelse error.ExpectedMatch;
            defer found.deinit(allocator);
            try std.testing.expectEqual(@as(usize, 5), found.end);
        }
    }.run, .{ tree.root, tree.capture_count });
}

test "backtrack: ReDoS protection - nested quantifiers (a+)+b" {
    const allocator = std.testing.allocator;

    // Pattern: (a+)+b - classic ReDoS pattern
    // Input: "aaaaaaaaaaaaaaaaaaaac" (20 'a's followed by 'c' instead of 'b')
    // This causes O(2^n) backtracking without protection

    const parser = @import("parser.zig");
    const compiler = @import("compiler.zig");

    var p = try parser.Parser.init(allocator, "(a+)+b");
    var tree = try p.parse();
    defer tree.deinit();

    var comp = compiler.Compiler.init(allocator);
    defer comp.deinit();
    _ = try comp.compile(&tree);

    // Input that doesn't match but would cause catastrophic backtracking
    const input = "aaaaaaaaaaaaaaaaaaaac";

    var engine = try BacktrackEngine.init(allocator, tree.root, tree.capture_count, .{});
    defer engine.deinit();

    // Should timeout/abort instead of hanging
    const result = engine.find(input);

    // Either returns null (no match) or completes quickly
    // The key is that it DOES return, not hang forever
    try std.testing.expect(result == null);

    // Verify step counter was incremented (shows protection is working)
    // We don't assert a specific minimum since the actual count depends on implementation
    try std.testing.expect(engine.step_count > 0);
}

test "backtrack: ReDoS protection - nested stars (a*)*b" {
    const allocator = std.testing.allocator;

    // Pattern: (a*)*b - another catastrophic backtracking pattern

    const parser = @import("parser.zig");
    const compiler = @import("compiler.zig");

    var p = try parser.Parser.init(allocator, "(a*)*b");
    var tree = try p.parse();
    defer tree.deinit();

    var comp = compiler.Compiler.init(allocator);
    defer comp.deinit();
    _ = try comp.compile(&tree);

    const input = "aaaaaaaaaaaaaaaaaac";

    var engine = try BacktrackEngine.init(allocator, tree.root, tree.capture_count, .{});
    defer engine.deinit();

    const result = engine.find(input);
    try std.testing.expect(result == null);
}

test "backtrack: ReDoS protection - ambiguous alternation (a|a)*b" {
    const allocator = std.testing.allocator;

    // Pattern: (a|a)*b - ambiguous alternation causing exponential backtracking

    const parser = @import("parser.zig");
    const compiler = @import("compiler.zig");

    var p = try parser.Parser.init(allocator, "(a|a)*b");
    var tree = try p.parse();
    defer tree.deinit();

    var comp = compiler.Compiler.init(allocator);
    defer comp.deinit();
    _ = try comp.compile(&tree);

    const input = "aaaaaaaaaaaaaaaac";

    var engine = try BacktrackEngine.init(allocator, tree.root, tree.capture_count, .{});
    defer engine.deinit();

    const result = engine.find(input);
    try std.testing.expect(result == null);
}

test "backtrack: configurable step limit" {
    const allocator = std.testing.allocator;

    // Test that we can configure a lower step limit

    const parser = @import("parser.zig");
    const compiler = @import("compiler.zig");

    var p = try parser.Parser.init(allocator, "(a+)+b");
    var tree = try p.parse();
    defer tree.deinit();

    var comp = compiler.Compiler.init(allocator);
    defer comp.deinit();
    _ = try comp.compile(&tree);

    const input = "aaaaaaaaaaaac";

    var engine = try BacktrackEngine.init(allocator, tree.root, tree.capture_count, .{});
    defer engine.deinit();

    // Set a very low limit to test timeout behavior
    engine.max_steps = 100;

    const result = engine.find(input);
    try std.testing.expect(result == null);

    // Should have done some steps (may or may not hit the limit depending on pattern)
    try std.testing.expect(engine.step_count > 0);
}

test "backtrack: step counter increments" {
    const allocator = std.testing.allocator;

    // Verify that step counter actually increments during matching

    const parser = @import("parser.zig");
    const compiler = @import("compiler.zig");

    var p = try parser.Parser.init(allocator, "a+b+");
    var tree = try p.parse();
    defer tree.deinit();

    var comp = compiler.Compiler.init(allocator);
    defer comp.deinit();
    _ = try comp.compile(&tree);

    const input = "aaaabbbbb";

    var engine = try BacktrackEngine.init(allocator, tree.root, tree.capture_count, .{});
    defer engine.deinit();

    const initial_count = engine.step_count;
    _ = engine.find(input);

    // Step counter should have increased
    try std.testing.expect(engine.step_count > initial_count);
}

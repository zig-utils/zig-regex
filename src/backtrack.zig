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

    pub const CaptureGroup = struct {
        start: usize,
        end: usize,
        matched: bool,
    };

    /// Default maximum steps: 10 million (prevents ReDoS while allowing complex patterns)
    pub const DEFAULT_MAX_STEPS: usize = 10_000_000;

    pub fn init(allocator: std.mem.Allocator, root: *ast.Node, capture_count: usize, flags: common.CompileFlags) !BacktrackEngine {
        const captures = try allocator.alloc(CaptureGroup, capture_count);
        for (captures) |*cap| {
            cap.* = .{ .start = 0, .end = 0, .matched = false };
        }

        return BacktrackEngine{
            .allocator = allocator,
            .ast_root = root,
            .capture_count = capture_count,
            .flags = flags,
            .input = &[_]u8{},
            .captures = captures,
            .step_count = 0,
            .max_steps = DEFAULT_MAX_STEPS,
        };
    }

    pub fn deinit(self: *BacktrackEngine) void {
        self.allocator.free(self.captures);
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
        self.input = input;

        const codepoint_search = containsCodepointAtom(self.ast_root);
        var pos: usize = @min(start, input.len);
        // One ReDoS step budget for the whole search, NOT per start position.
        // Resetting it each position let total backtracking reach
        // O(input.len * max_steps): on a large input that never matches, every
        // one of millions of start positions could burn the full per-position
        // budget, an effective (Zig-level, uninterruptible) infinite loop. With a
        // single budget, once it is spent matchNode fail-fasts at every remaining
        // position, so the search terminates.
        self.step_count = 0;
        while (pos <= input.len) {
            self.resetCaptures();
            if (self.matchNode(self.ast_root, pos)) |end_pos| {
                if (end_pos > pos or (end_pos == pos and self.canMatchEmpty(self.ast_root))) {
                    // Found a match
                    const captures = self.allocator.alloc(BacktrackMatch.CaptureGroup, self.captures.len) catch return null;
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

    fn containsCodepointAtom(node: *ast.Node) bool {
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
        const dec = unicode_mod.decodeUtf8Lenient(input[pos..]) orelse return pos + 1;
        return pos + dec.len;
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
        if (self.step_count > self.max_steps) {
            return null; // Abort matching to prevent catastrophic backtracking
        }

        return switch (node.node_type) {
            .literal => self.matchLiteral(node.data.literal, pos),
            .any => self.matchAny(pos),
            .concat => self.matchConcat(node.data.concat, pos),
            .alternation => self.matchAlternation(node.data.alternation, pos),
            .star => self.matchStar(node.data.star, pos),
            .plus => self.matchPlus(node.data.plus, pos),
            .optional => self.matchOptional(node.data.optional, pos),
            .repeat => self.matchRepeat(node.data.repeat, pos),
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
        const saved = self.allocator.alloc(CaptureGroup, self.captures.len) catch return null;
        defer self.allocator.free(saved);
        @memcpy(saved, self.captures);

        if (self.matchNode(node, pos)) |end| {
            if (end > pos) return end;
        }

        @memcpy(self.captures, saved);
        var positions = std.ArrayList(usize).initCapacity(self.allocator, 0) catch return null;
        defer positions.deinit(self.allocator);
        self.collectAllMatches(node, pos, &positions) catch return null;
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
            const clean_captures = self.allocator.alloc(CaptureGroup, self.captures.len) catch return null;
            defer self.allocator.free(clean_captures);
            @memcpy(clean_captures, self.captures);

            // Collect all possible left-side ending positions
            var left_positions = std.ArrayList(usize).initCapacity(self.allocator, 0) catch return null;
            defer left_positions.deinit(self.allocator);

            if (left_has_choices) {
                self.collectAllMatches(concat.left, pos, &left_positions) catch return null;
            } else {
                if (self.matchNode(concat.left, pos)) |end| {
                    left_positions.append(self.allocator, end) catch return null;
                }
            }

            // The capture-fixup re-match below is only needed when the left side
            // actually has groups; skipping it keeps `\p{…}+`-style scans linear.
            const left_has_groups = self.hasGroups(concat.left);
            for (left_positions.items) |left_end| {
                // Restore clean captures before each attempt
                @memcpy(self.captures, clean_captures);

                // Re-match left to this specific end position to set captures correctly
                if (left_has_groups) {
                    if (left_has_choices) {
                        _ = self.matchNodeConstrained(concat.left, pos, left_end);
                    } else {
                        _ = self.matchNode(concat.left, pos);
                    }
                }

                // Save captures after left match
                const saved_captures = self.allocator.alloc(CaptureGroup, self.captures.len) catch continue;
                defer self.allocator.free(saved_captures);
                @memcpy(saved_captures, self.captures);

                if (right_has_choices) {
                    // Right side also has choices - collect all right positions
                    var right_positions = std.ArrayList(usize).initCapacity(self.allocator, 0) catch continue;
                    defer right_positions.deinit(self.allocator);

                    self.collectAllMatches(concat.right, left_end, &right_positions) catch continue;

                    for (right_positions.items) |right_end| {
                        @memcpy(self.captures, saved_captures);
                        _ = self.matchNodeConstrained(concat.right, left_end, right_end);
                        return right_end;
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
            // For simple patterns without quantifiers, just try once
            if (self.matchNode(concat.left, pos)) |left_end| {
                if (self.matchNode(concat.right, left_end)) |right_end| {
                    return right_end;
                }
            }
            return null;
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
                    const base_captures = self.allocator.alloc(CaptureGroup, self.captures.len) catch return false;
                    defer self.allocator.free(base_captures);
                    @memcpy(base_captures, self.captures);

                    var splits = std.ArrayList(usize).initCapacity(self.allocator, 0) catch return false;
                    defer splits.deinit(self.allocator);
                    self.collectAllMatches(c.left, pos, &splits) catch return false;

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
                return self.matchQuantifierConstrained(node, pos, target_end);
            },
            .alternation => {
                if (self.matchNodeConstrained(node.data.alternation.left, pos, target_end)) return true;
                return self.matchNodeConstrained(node.data.alternation.right, pos, target_end);
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
                    if (pos == target_end) return true;
                    return self.matchNodeConstrained(child, pos, target_end);
                }

                const max: ?usize = switch (node.node_type) {
                    .star, .plus => null,
                    .repeat => node.data.repeat.bounds.max,
                    else => unreachable,
                };
                return self.matchRepeatedChildConstrained(child, pos, target_end, 0, min, max);
            },
            else => return false,
        }
    }

    fn matchRepeatedChildConstrained(self: *BacktrackEngine, child: *ast.Node, pos: usize, target_end: usize, count: usize, min: usize, max: ?usize) bool {
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

        const saved = self.allocator.alloc(CaptureGroup, self.captures.len) catch return false;
        defer self.allocator.free(saved);
        @memcpy(saved, self.captures);

        var ends = std.ArrayList(usize).initCapacity(self.allocator, 0) catch return false;
        defer ends.deinit(self.allocator);
        self.collectAllMatches(child, pos, &ends) catch return false;

        for (ends.items) |end| {
            if (end <= pos or end > target_end) continue;
            @memcpy(self.captures, saved);
            if (!self.matchNodeConstrained(child, pos, end)) continue;
            if (self.matchRepeatedChildConstrained(child, end, target_end, count + 1, min, max)) return true;
        }

        if (self.hasAlternation(child) and self.hasCapturingGroup(child)) {
            @memcpy(self.captures, saved);
            if (self.matchNodeConstrained(child, pos, target_end)) {
                if (self.matchRepeatedChildConstrained(child, target_end, target_end, count + 1, min, max)) return true;
            }
        }

        @memcpy(self.captures, saved);
        return false;
    }

    fn hasQuantifiers(self: *BacktrackEngine, node: *ast.Node) bool {
        return switch (node.node_type) {
            // Any quantifier needs backtracking support
            .star, .plus, .optional, .repeat => true,
            // Recursively check children
            .concat => self.hasQuantifiers(node.data.concat.left) or self.hasQuantifiers(node.data.concat.right),
            .alternation => self.hasQuantifiers(node.data.alternation.left) or self.hasQuantifiers(node.data.alternation.right),
            .group => self.hasQuantifiers(node.data.group.child),
            else => false,
        };
    }

    fn hasAlternation(self: *BacktrackEngine, node: *ast.Node) bool {
        return switch (node.node_type) {
            .alternation => true,
            .concat => self.hasAlternation(node.data.concat.left) or self.hasAlternation(node.data.concat.right),
            .group => self.hasAlternation(node.data.group.child),
            .star => self.hasAlternation(node.data.star.child),
            .plus => self.hasAlternation(node.data.plus.child),
            .optional => self.hasAlternation(node.data.optional.child),
            .repeat => self.hasAlternation(node.data.repeat.child),
            .lookahead => self.hasAlternation(node.data.lookahead.child),
            .lookbehind => self.hasAlternation(node.data.lookbehind.child),
            else => false,
        };
    }

    fn hasRepeatedAlternation(self: *BacktrackEngine, node: *ast.Node) bool {
        return switch (node.node_type) {
            .star => self.hasAlternation(node.data.star.child) or self.hasRepeatedAlternation(node.data.star.child),
            .plus => self.hasAlternation(node.data.plus.child) or self.hasRepeatedAlternation(node.data.plus.child),
            .repeat => self.hasAlternation(node.data.repeat.child) or self.hasRepeatedAlternation(node.data.repeat.child),
            .optional => self.hasRepeatedAlternation(node.data.optional.child),
            .concat => self.hasRepeatedAlternation(node.data.concat.left) or self.hasRepeatedAlternation(node.data.concat.right),
            .alternation => self.hasRepeatedAlternation(node.data.alternation.left) or self.hasRepeatedAlternation(node.data.alternation.right),
            .group => self.hasRepeatedAlternation(node.data.group.child),
            .lookahead => self.hasRepeatedAlternation(node.data.lookahead.child),
            .lookbehind => self.hasRepeatedAlternation(node.data.lookbehind.child),
            else => false,
        };
    }

    fn needsAnchoredRepeatedAlternationRecovery(self: *BacktrackEngine, left: *ast.Node, right: *ast.Node) bool {
        return self.hasRepeatedAlternation(left) and self.hasCapturingGroup(left) and self.isEndAnchorOnly(right);
    }

    fn hasCapturingGroup(self: *BacktrackEngine, node: *ast.Node) bool {
        return switch (node.node_type) {
            .group => node.data.group.capture_index != null or self.hasCapturingGroup(node.data.group.child),
            .concat => self.hasCapturingGroup(node.data.concat.left) or self.hasCapturingGroup(node.data.concat.right),
            .alternation => self.hasCapturingGroup(node.data.alternation.left) or self.hasCapturingGroup(node.data.alternation.right),
            .star => self.hasCapturingGroup(node.data.star.child),
            .plus => self.hasCapturingGroup(node.data.plus.child),
            .optional => self.hasCapturingGroup(node.data.optional.child),
            .repeat => self.hasCapturingGroup(node.data.repeat.child),
            .lookahead => self.hasCapturingGroup(node.data.lookahead.child),
            .lookbehind => self.hasCapturingGroup(node.data.lookbehind.child),
            else => false,
        };
    }

    fn isEndAnchorOnly(self: *BacktrackEngine, node: *ast.Node) bool {
        return switch (node.node_type) {
            .anchor => node.data.anchor == .end_line or node.data.anchor == .end_text,
            .group => self.isEndAnchorOnly(node.data.group.child),
            .concat => self.canMatchEmpty(node.data.concat.left) and self.isEndAnchorOnly(node.data.concat.right),
            else => false,
        };
    }

    /// Whether a subtree contains a group (whose captures a constrained re-match
    /// would need to set). Conservative: any group counts. When false, the
    /// capture-fixup re-match in matchConcat/collectAllMatches is pure waste and
    /// can be skipped — turning `\p{…}+`-style scans from O(n²) into O(n).
    fn hasGroups(self: *BacktrackEngine, node: *ast.Node) bool {
        return switch (node.node_type) {
            .group => true,
            .concat => self.hasGroups(node.data.concat.left) or self.hasGroups(node.data.concat.right),
            .alternation => self.hasGroups(node.data.alternation.left) or self.hasGroups(node.data.alternation.right),
            .star => self.hasGroups(node.data.star.child),
            .plus => self.hasGroups(node.data.plus.child),
            .optional => self.hasGroups(node.data.optional.child),
            .repeat => self.hasGroups(node.data.repeat.child),
            .lookahead, .lookbehind => true,
            else => false,
        };
    }

    fn clearCapturesIn(self: *BacktrackEngine, node: *ast.Node) void {
        switch (node.node_type) {
            .group => {
                const group = node.data.group;
                if (group.capture_index) |index| {
                    if (index > 0 and index <= self.captures.len) {
                        self.captures[index - 1] = .{ .start = 0, .end = 0, .matched = false };
                    }
                }
                self.clearCapturesIn(group.child);
            },
            .concat => {
                self.clearCapturesIn(node.data.concat.left);
                self.clearCapturesIn(node.data.concat.right);
            },
            .alternation => {
                self.clearCapturesIn(node.data.alternation.left);
                self.clearCapturesIn(node.data.alternation.right);
            },
            .star => self.clearCapturesIn(node.data.star.child),
            .plus => self.clearCapturesIn(node.data.plus.child),
            .optional => self.clearCapturesIn(node.data.optional.child),
            .repeat => self.clearCapturesIn(node.data.repeat.child),
            .lookahead => self.clearCapturesIn(node.data.lookahead.child),
            .lookbehind => self.clearCapturesIn(node.data.lookbehind.child),
            else => {},
        }
    }

    /// Collect all possible ending positions for matching a node at a given position
    /// For lazy quantifiers, this returns positions in order: minimal first
    /// For greedy quantifiers, this returns positions in order: maximal first
    fn collectAllMatches(self: *BacktrackEngine, node: *ast.Node, pos: usize, positions: *std.ArrayList(usize)) !void {
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
                self.clearCapturesIn(quant.child);
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
                const repeat = node.data.repeat;
                if (repeat.greedy) {
                    try self.collectGreedyRepeatMatches(repeat, pos, positions);
                } else {
                    try self.collectLazyRepeatMatches(repeat, pos, positions);
                }
            },
            .concat => {
                // Recursively collect all possible endings for concat nodes
                const c = node.data.concat;
                const left_has_choices = self.hasQuantifiers(c.left) or self.hasAlternation(c.left);
                const right_has_choices = self.hasQuantifiers(c.right) or self.hasAlternation(c.right);

                if (left_has_choices or right_has_choices) {
                    const clean_captures = self.allocator.alloc(CaptureGroup, self.captures.len) catch return;
                    defer self.allocator.free(clean_captures);
                    @memcpy(clean_captures, self.captures);
                    const before_len = positions.items.len;

                    // Collect all possible left-side endings
                    var left_positions = std.ArrayList(usize).initCapacity(self.allocator, 0) catch return;
                    defer left_positions.deinit(self.allocator);

                    if (left_has_choices) {
                        try self.collectAllMatches(c.left, pos, &left_positions);
                    } else {
                        if (self.matchNode(c.left, pos)) |end| {
                            try left_positions.append(self.allocator, end);
                        }
                    }

                    // For each left ending, set captures and try right side
                    const left_has_groups = self.hasGroups(c.left);
                    for (left_positions.items) |left_end| {
                        // Save captures, set them for this left position, try right
                        const saved = self.allocator.alloc(CaptureGroup, self.captures.len) catch continue;
                        defer self.allocator.free(saved);
                        @memcpy(saved, self.captures);

                        // Set captures correctly for this left end position (only
                        // needed when the left side has groups — else pure waste).
                        if (left_has_groups) {
                            if (left_has_choices) {
                                _ = self.matchNodeConstrained(c.left, pos, left_end);
                            } else {
                                _ = self.matchNode(c.left, pos);
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
        var all_positions = std.ArrayList(usize).initCapacity(self.allocator, 0) catch return;
        defer all_positions.deinit(self.allocator);

        try all_positions.append(self.allocator, pos); // zero matches

        var current_pos = pos;
        while (true) {
            self.clearCapturesIn(child);
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
            self.clearCapturesIn(child);
            const next_pos = self.matchNodeProgress(child, current_pos) orelse break;
            current_pos = next_pos;
            try positions.append(self.allocator, current_pos);
        }
    }

    fn collectGreedyRepeatMatches(self: *BacktrackEngine, repeat: ast.Node.Repeat, pos: usize, positions: *std.ArrayList(usize)) !void {
        const min = repeat.bounds.min;
        const max = repeat.bounds.max;

        // Match minimum required times
        var current_pos = pos;
        var i: usize = 0;
        while (i < min) : (i += 1) {
            self.clearCapturesIn(repeat.child);
            current_pos = self.matchNode(repeat.child, current_pos) orelse return;
        }

        // Collect all positions from min to max (or unbounded)
        var all_positions = std.ArrayList(usize).initCapacity(self.allocator, 0) catch return;
        defer all_positions.deinit(self.allocator);

        try all_positions.append(self.allocator, current_pos);

        if (max) |max_count| {
            while (i < max_count) : (i += 1) {
                self.clearCapturesIn(repeat.child);
                if (self.matchNodeProgress(repeat.child, current_pos)) |next_pos| {
                    current_pos = next_pos;
                    try all_positions.append(self.allocator, current_pos);
                } else break;
            }
        } else {
            // Unbounded: keep matching until we can't
            while (true) {
                self.clearCapturesIn(repeat.child);
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
            self.clearCapturesIn(repeat.child);
            current_pos = self.matchNode(repeat.child, current_pos) orelse return;
        }

        // Return positions from min to max (lazy: shortest first)
        try positions.append(self.allocator, current_pos);

        if (max) |max_count| {
            while (i < max_count) : (i += 1) {
                self.clearCapturesIn(repeat.child);
                if (self.matchNodeProgress(repeat.child, current_pos)) |next_pos| {
                    current_pos = next_pos;
                    try positions.append(self.allocator, current_pos);
                } else break;
            }
        } else {
            // Unbounded: keep matching until we can't
            while (true) {
                self.clearCapturesIn(repeat.child);
                const next_pos = self.matchNodeProgress(repeat.child, current_pos) orelse break;
                current_pos = next_pos;
                try positions.append(self.allocator, current_pos);
            }
        }
    }

    fn matchAlternation(self: *BacktrackEngine, alt: ast.Node.Alternation, pos: usize) ?usize {
        // Try left first
        if (self.matchNode(alt.left, pos)) |end| {
            return end;
        }
        // Try right
        return self.matchNode(alt.right, pos);
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
        var match_positions = std.ArrayList(usize).initCapacity(self.allocator, 0) catch return null;
        defer match_positions.deinit(self.allocator);

        match_positions.append(self.allocator, current_pos) catch return null;

        // Collect all possible match positions
        while (true) {
            const saved = self.allocator.alloc(CaptureGroup, self.captures.len) catch break;
            defer self.allocator.free(saved);
            @memcpy(saved, self.captures);

            self.clearCapturesIn(child);
            const next_pos = self.matchNodeProgress(child, current_pos) orelse {
                @memcpy(self.captures, saved);
                break;
            };
            if (next_pos <= current_pos) {
                @memcpy(self.captures, saved);
                break;
            }
            current_pos = next_pos;
            match_positions.append(self.allocator, current_pos) catch break;
        }

        // Greedy: return the longest match
        return match_positions.getLast();
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
        self.clearCapturesIn(quant.child);
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
        const min = repeat.bounds.min;
        const max = repeat.bounds.max;

        // Match minimum required times
        var current_pos = pos;
        var i: usize = 0;
        while (i < min) : (i += 1) {
            self.clearCapturesIn(repeat.child);
            current_pos = self.matchNode(repeat.child, current_pos) orelse return null;
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
        if (repeat.greedy) {
            // Greedy: try to match as many as possible
            while (i < max_count) : (i += 1) {
                self.clearCapturesIn(repeat.child);
                if (self.matchNodeProgress(repeat.child, current_pos)) |next_pos| {
                    current_pos = next_pos;
                } else {
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
        return set.matchLongest(self.input, pos, self.flags.case_insensitive);
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
            .start_line => if (self.flags.multiline)
                pos == 0 or (pos > 0 and self.input[pos - 1] == '\n')
            else
                pos == 0,
            .end_line => if (self.flags.multiline)
                pos == self.input.len or (pos < self.input.len and self.input[pos] == '\n')
            else
                pos == self.input.len,
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
        // Lookahead: test if pattern matches at current position without consuming input
        const matches = self.matchNode(assertion.child, pos) != null;

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
            return if (self.matchReverseNode(assertion.child, pos) != null) pos else null;
        }

        const saved = self.allocator.alloc(CaptureGroup, self.captures.len) catch return null;
        defer self.allocator.free(saved);
        @memcpy(saved, self.captures);

        const matches = self.matchReverseNode(assertion.child, pos) != null;
        @memcpy(self.captures, saved);
        return if (matches) null else pos;
    }

    fn matchReverseNode(self: *BacktrackEngine, node: *ast.Node, pos: usize) ?usize {
        self.step_count += 1;
        if (self.step_count > self.max_steps) return null;

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

        const base_captures = self.allocator.alloc(CaptureGroup, self.captures.len) catch return null;
        defer self.allocator.free(base_captures);
        @memcpy(base_captures, self.captures);

        var splits = std.ArrayList(usize).initCapacity(self.allocator, 0) catch return null;
        defer splits.deinit(self.allocator);
        self.collectAllReverseMatches(concat.right, pos, &splits) catch return null;

        for (splits.items) |split| {
            @memcpy(self.captures, base_captures);
            if (!self.matchReverseNodeConstrained(concat.right, pos, split)) continue;
            if (self.matchReverseNode(concat.left, split)) |start| return start;
        }

        @memcpy(self.captures, base_captures);
        return null;
    }

    fn matchReverseAlternation(self: *BacktrackEngine, alt: ast.Node.Alternation, pos: usize) ?usize {
        if (self.matchReverseNode(alt.left, pos)) |start| return start;
        return self.matchReverseNode(alt.right, pos);
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
            const saved = self.allocator.alloc(CaptureGroup, self.captures.len) catch return null;
            defer self.allocator.free(saved);
            @memcpy(saved, self.captures);

            self.clearCapturesIn(quant.child);
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
        self.clearCapturesIn(quant.child);
        var current = self.matchReverseNode(quant.child, pos) orelse return null;
        if (!quant.greedy) return current;

        while (true) {
            const saved = self.allocator.alloc(CaptureGroup, self.captures.len) catch return null;
            defer self.allocator.free(saved);
            @memcpy(saved, self.captures);

            self.clearCapturesIn(quant.child);
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
        const min = repeat.bounds.min;
        const max = repeat.bounds.max;

        var current = pos;
        var count: usize = 0;
        while (count < min) : (count += 1) {
            self.clearCapturesIn(repeat.child);
            const next = self.matchReverseNode(repeat.child, current) orelse return null;
            if (next > current) return null;
            current = next;
        }

        if (!repeat.greedy) return current;

        while (max == null or count < max.?) : (count += 1) {
            const saved = self.allocator.alloc(CaptureGroup, self.captures.len) catch return null;
            defer self.allocator.free(saved);
            @memcpy(saved, self.captures);

            self.clearCapturesIn(repeat.child);
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
                var splits = std.ArrayList(usize).initCapacity(self.allocator, 0) catch return false;
                defer splits.deinit(self.allocator);
                self.collectAllReverseMatches(c.right, pos, &splits) catch return false;

                const base_captures = self.allocator.alloc(CaptureGroup, self.captures.len) catch return false;
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
                var starts = std.ArrayList(usize).initCapacity(self.allocator, 0) catch return false;
                defer starts.deinit(self.allocator);
                self.collectAllReverseMatches(node, pos, &starts) catch return false;
                for (starts.items) |start| {
                    if (start == target_start) return true;
                }
                return false;
            },
            .alternation => {
                if (self.matchReverseNodeConstrained(node.data.alternation.left, pos, target_start)) return true;
                return self.matchReverseNodeConstrained(node.data.alternation.right, pos, target_start);
            },
            .backref => return if (self.matchReverseBackreference(node.data.backref, pos)) |start| start == target_start else false,
            .lookahead => return if (self.matchLookahead(node.data.lookahead, pos)) |start| start == target_start else false,
            .lookbehind => return if (self.matchLookbehind(node.data.lookbehind, pos)) |start| start == target_start else false,
        }
    }

    fn collectAllReverseMatches(self: *BacktrackEngine, node: *ast.Node, pos: usize, positions: *std.ArrayList(usize)) !void {
        switch (node.node_type) {
            .star => {
                const quant = node.data.star;
                if (!quant.greedy) try positions.append(self.allocator, pos);

                var all = std.ArrayList(usize).initCapacity(self.allocator, 0) catch return;
                defer all.deinit(self.allocator);
                try all.append(self.allocator, pos);

                var current = pos;
                while (true) {
                    self.clearCapturesIn(quant.child);
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
                self.clearCapturesIn(quant.child);
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
            .repeat => try self.collectReverseRepeatMatches(node.data.repeat, pos, positions),
            .concat => {
                const c = node.data.concat;
                var right_positions = std.ArrayList(usize).initCapacity(self.allocator, 0) catch return;
                defer right_positions.deinit(self.allocator);
                try self.collectAllReverseMatches(c.right, pos, &right_positions);

                const base_captures = self.allocator.alloc(CaptureGroup, self.captures.len) catch return;
                defer self.allocator.free(base_captures);
                @memcpy(base_captures, self.captures);

                for (right_positions.items) |split| {
                    @memcpy(self.captures, base_captures);
                    _ = self.matchReverseNodeConstrained(c.right, pos, split);
                    try self.collectAllReverseMatches(c.left, split, positions);
                }
                @memcpy(self.captures, base_captures);
            },
            .group => {
                const group = node.data.group;
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
        var all = std.ArrayList(usize).initCapacity(self.allocator, 0) catch return;
        defer all.deinit(self.allocator);
        try all.append(self.allocator, pos);

        var current = pos;
        while (true) {
            self.clearCapturesIn(child);
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
            self.clearCapturesIn(repeat.child);
            const next = self.matchReverseNode(repeat.child, current) orelse return;
            if (next > current) return;
            current = next;
        }

        var all = std.ArrayList(usize).initCapacity(self.allocator, 0) catch return;
        defer all.deinit(self.allocator);
        try all.append(self.allocator, current);

        while (repeat.bounds.max == null or count < repeat.bounds.max.?) : (count += 1) {
            self.clearCapturesIn(repeat.child);
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
        var start = pos - 1;
        while (start > 0 and (self.input[start] & 0xC0) == 0x80) : (start -= 1) {}
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
            if (set.matchLongest(self.input, start, self.flags.case_insensitive)) |end| {
                if (end == pos) return start;
            }
        }
        return null;
    }

    fn matchReverseBackreference(self: *BacktrackEngine, backref: ast.Node.Backreference, pos: usize) ?usize {
        if (backref.name) |name| return self.matchNamedBackreferenceReverse(self.ast_root, name, pos);
        return self.matchCaptureBackreferenceReverse(backref.index, pos);
    }

    fn matchCaptureBackreferenceReverse(self: *BacktrackEngine, capture_index: usize, pos: usize) ?usize {
        if (capture_index == 0 or capture_index > self.captures.len) return null;
        const capture = self.captures[capture_index - 1];
        if (!capture.matched) return pos;
        return self.matchCaptureTextReverse(capture, pos);
    }

    fn matchPresentCaptureBackreferenceReverse(self: *BacktrackEngine, capture_index: usize, pos: usize) ?usize {
        if (capture_index == 0 or capture_index > self.captures.len) return null;
        const capture = self.captures[capture_index - 1];
        if (!capture.matched) return null;
        return self.matchCaptureTextReverse(capture, pos);
    }

    fn matchCaptureTextReverse(self: *BacktrackEngine, capture: CaptureGroup, pos: usize) ?usize {
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
        return if (found_name and !found_participating) pos else null;
    }

    fn matchNamedBackreferenceParticipatingReverse(self: *BacktrackEngine, node: *ast.Node, name: []const u8, pos: usize, found_name: *bool, found_participating: *bool) ?usize {
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

    fn matchCaptureBackreference(self: *BacktrackEngine, capture_index: usize, pos: usize) ?usize {
        // Validate capture index (1-based)
        if (capture_index == 0 or capture_index > self.captures.len) {
            return null;
        }

        const capture = self.captures[capture_index - 1];

        // ECMAScript: a backreference to a group that has not participated
        // matches the empty string.
        if (!capture.matched) {
            return pos;
        }

        return self.matchCaptureText(capture, pos);
    }

    fn matchPresentCaptureBackreference(self: *BacktrackEngine, capture_index: usize, pos: usize) ?usize {
        if (capture_index == 0 or capture_index > self.captures.len) return null;
        const capture = self.captures[capture_index - 1];
        if (!capture.matched) return null;
        return self.matchCaptureText(capture, pos);
    }

    fn matchCaptureText(self: *BacktrackEngine, capture: CaptureGroup, pos: usize) ?usize {
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
        return if (found_name and !found_participating) pos else null;
    }

    fn matchNamedBackreferenceParticipating(self: *BacktrackEngine, node: *ast.Node, name: []const u8, pos: usize, found_name: *bool, found_participating: *bool) ?usize {
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

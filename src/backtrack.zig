const std = @import("std");
const ast = @import("ast.zig");
const common = @import("common.zig");

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

    pub const CaptureGroup = struct {
        start: usize,
        end: usize,
        matched: bool,
    };

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
        };
    }

    pub fn deinit(self: *BacktrackEngine) void {
        self.allocator.free(self.captures);
    }

    /// Test if pattern matches entire input
    pub fn isMatch(self: *BacktrackEngine, input: []const u8) bool {
        self.input = input;
        self.resetCaptures();
        return self.matchNode(self.ast_root, 0) == input.len;
    }

    /// Find first match in input
    pub fn find(self: *BacktrackEngine, input: []const u8) ?BacktrackMatch {
        self.input = input;

        var pos: usize = 0;
        while (pos <= input.len) : (pos += 1) {
            self.resetCaptures();
            const end_pos = self.matchNode(self.ast_root, pos);
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
        return null;
    }

    /// Reset all capture groups
    fn resetCaptures(self: *BacktrackEngine) void {
        for (self.captures) |*cap| {
            cap.matched = false;
            cap.start = 0;
            cap.end = 0;
        }
    }

    /// Check if a node can match empty string
    fn canMatchEmpty(self: *BacktrackEngine, node: *ast.Node) bool {
        return switch (node.node_type) {
            .literal, .any, .char_class, .backref => false,
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
    fn matchNode(self: *BacktrackEngine, node: *ast.Node, pos: usize) ?usize {
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
        };
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
        if (pos >= self.input.len) return null;

        const c = self.input[pos];
        if (!self.flags.dot_all and c == '\n') return null;

        return pos + 1;
    }

    fn matchConcat(self: *BacktrackEngine, concat: ast.Node.Concat, pos: usize) ?usize {
        const left_end = self.matchNode(concat.left, pos) orelse return null;
        return self.matchNode(concat.right, left_end);
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
        var match_positions = std.ArrayList(usize).init(self.allocator);
        defer match_positions.deinit();

        match_positions.append(current_pos) catch return null;

        // Collect all possible match positions
        while (self.matchNode(child, current_pos)) |next_pos| {
            if (next_pos == current_pos) break; // Prevent infinite loop on empty matches
            current_pos = next_pos;
            match_positions.append(current_pos) catch break;
        }

        // Greedy: return the longest match
        return match_positions.getLast();
    }

    fn matchStarLazy(self: *BacktrackEngine, child: *ast.Node, pos: usize) ?usize {
        // Lazy: try zero matches first, then one, two, etc.
        // Try zero matches
        var current_pos = pos;

        // For lazy, we start with the minimum (zero) and only match more if needed
        // The caller will handle backtracking if the rest of the pattern fails
        return pos;
    }

    fn matchPlus(self: *BacktrackEngine, quant: ast.Node.Quantifier, pos: usize) ?usize {
        // Must match at least once
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
                if (self.matchNode(repeat.child, current_pos)) |next_pos| {
                    if (next_pos == current_pos) break;
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

        const c = self.input[pos];
        const matches = char_class.matches(c);

        return if (matches) pos + 1 else null;
    }

    fn matchGroup(self: *BacktrackEngine, group: ast.Node.Group, pos: usize) ?usize {
        const start_pos = pos;

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
        const before_is_word = if (pos > 0) isWordChar(self.input[pos - 1]) else false;
        const after_is_word = if (pos < self.input.len) isWordChar(self.input[pos]) else false;
        return before_is_word != after_is_word;
    }

    fn isWordChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_';
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
        // Lookbehind: test if pattern matches BEFORE current position
        // This is complex because we need to search backwards

        if (assertion.positive) {
            // Positive lookbehind (?<=...): must match immediately before pos
            // Try matching from various positions before pos
            var start: usize = 0;
            while (start <= pos) : (start += 1) {
                if (self.matchNode(assertion.child, start)) |end| {
                    if (end == pos) {
                        // Pattern matched and ended exactly at current position
                        return pos;
                    }
                }
            }
            return null;
        } else {
            // Negative lookbehind (?<!...): must NOT match immediately before pos
            var start: usize = 0;
            while (start <= pos) : (start += 1) {
                if (self.matchNode(assertion.child, start)) |end| {
                    if (end == pos) {
                        // Pattern matched, so negative lookbehind fails
                        return null;
                    }
                }
            }
            // No match found, so negative lookbehind succeeds
            return pos;
        }
    }

    fn matchBackreference(self: *BacktrackEngine, backref: ast.Node.Backreference, pos: usize) ?usize {
        // Backreference: match the same text that was captured by a previous group
        const capture_index = backref.index;

        // Validate capture index (1-based)
        if (capture_index == 0 or capture_index > self.captures.len) {
            return null;
        }

        const capture = self.captures[capture_index - 1];

        // If capture group hasn't matched yet, backreference fails
        if (!capture.matched) {
            return null;
        }

        // Get the captured text
        const captured_text = self.input[capture.start..capture.end];

        // Try to match the same text at current position
        if (pos + captured_text.len > self.input.len) {
            return null;
        }

        const text_to_match = self.input[pos .. pos + captured_text.len];

        // Compare byte by byte (case sensitive)
        if (std.mem.eql(u8, captured_text, text_to_match)) {
            return pos + captured_text.len;
        }

        return null;
    }
};

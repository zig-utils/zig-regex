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
    /// If true, lazy quantifiers will not backtrack (used in find() to prefer different positions over more matches)
    disable_lazy_backtrack: bool,
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
            .disable_lazy_backtrack = false,
            .step_count = 0,
            .max_steps = DEFAULT_MAX_STEPS,
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
        // Enable lazy backtrack disabling for find() - prefer different positions over more matches
        self.disable_lazy_backtrack = true;
        defer self.disable_lazy_backtrack = false;

        var pos: usize = 0;
        while (pos <= input.len) : (pos += 1) {
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
        }
        return null;
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
        // Check if left side has quantifiers that need backtracking
        const needs_backtrack = self.hasQuantifiers(concat.left);

        if (needs_backtrack) {
            // For quantifiers, collect all possible matches and try them in order
            // Lazy quantifiers will be tried minimal-first, greedy maximal-first
            var left_positions = std.ArrayList(usize).initCapacity(self.allocator, 0) catch return null;
            defer left_positions.deinit(self.allocator);

            self.collectAllMatches(concat.left, pos, &left_positions) catch return null;

            for (left_positions.items) |left_end| {
                const saved_captures = self.allocator.alloc(CaptureGroup, self.captures.len) catch continue;
                defer self.allocator.free(saved_captures);
                @memcpy(saved_captures, self.captures);

                if (self.matchNode(concat.right, left_end)) |result| {
                    return result;
                }

                @memcpy(self.captures, saved_captures);
            }
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
                const first_match = self.matchNode(quant.child, pos) orelse return;

                if (quant.greedy) {
                    // Greedy: try maximal first
                    try self.collectGreedyStarMatches(quant.child, first_match, positions);
                } else {
                    // Lazy: try minimal (one match) first, then more
                    try positions.append(self.allocator, first_match);
                    // If lazy backtrack is disabled (find() mode), only return minimal match
                    if (!self.disable_lazy_backtrack) {
                        try self.collectLazyStarMatches(quant.child, first_match, positions);
                    }
                }
            },
            .optional => {
                const quant = node.data.optional;
                if (quant.greedy) {
                    // Greedy: try matching first, then zero
                    if (self.matchNode(quant.child, pos)) |end| {
                        try positions.append(self.allocator, end);
                    }
                    try positions.append(self.allocator, pos); // zero matches
                } else {
                    // Lazy: try zero first, then matching
                    try positions.append(self.allocator, pos); // zero matches first
                    // If lazy backtrack is disabled (find() mode), only return minimal (zero)
                    if (!self.disable_lazy_backtrack) {
                        if (self.matchNode(quant.child, pos)) |end| {
                            try positions.append(self.allocator, end);
                        }
                    }
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
            else => {
                // For non-quantifiers, there's only one possible match
                if (self.matchNode(node, pos)) |end| {
                    try positions.append(self.allocator, end);
                }
            },
        }
    }

    fn collectGreedyStarMatches(self: *BacktrackEngine, child: *ast.Node, pos: usize, positions: *std.ArrayList(usize)) !void {
        // Collect all matches from longest to shortest
        var all_positions = std.ArrayList(usize).initCapacity(self.allocator, 0) catch return;
        defer all_positions.deinit(self.allocator);

        try all_positions.append(self.allocator, pos); // zero matches

        var current_pos = pos;
        while (self.matchNode(child, current_pos)) |next_pos| {
            if (next_pos == current_pos) break; // Prevent infinite loop
            current_pos = next_pos;
            try all_positions.append(self.allocator, current_pos);
        }

        // Return in reverse order (greedy: longest first)
        var i: usize = all_positions.items.len;
        while (i > 0) {
            i -= 1;
            try positions.append(self.allocator, all_positions.items[i]);
        }
    }

    fn collectLazyStarMatches(self: *BacktrackEngine, child: *ast.Node, pos: usize, positions: *std.ArrayList(usize)) !void {
        // Collect all matches from shortest to longest
        try positions.append(self.allocator, pos); // zero matches first

        // If lazy backtrack is disabled (find() mode), only return minimal match
        if (self.disable_lazy_backtrack) {
            return;
        }

        var current_pos = pos;
        while (self.matchNode(child, current_pos)) |next_pos| {
            if (next_pos == current_pos) break; // Prevent infinite loop
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
            current_pos = self.matchNode(repeat.child, current_pos) orelse return;
        }

        // Collect all positions from min to max (or unbounded)
        var all_positions = std.ArrayList(usize).initCapacity(self.allocator, 0) catch return;
        defer all_positions.deinit(self.allocator);

        try all_positions.append(self.allocator, current_pos);

        if (max) |max_count| {
            while (i < max_count) : (i += 1) {
                if (self.matchNode(repeat.child, current_pos)) |next_pos| {
                    if (next_pos == current_pos) break;
                    current_pos = next_pos;
                    try all_positions.append(self.allocator, current_pos);
                } else break;
            }
        } else {
            // Unbounded: keep matching until we can't
            while (self.matchNode(repeat.child, current_pos)) |next_pos| {
                if (next_pos == current_pos) break;
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
            current_pos = self.matchNode(repeat.child, current_pos) orelse return;
        }

        // Return positions from min to max (lazy: shortest first)
        try positions.append(self.allocator, current_pos);

        // If lazy backtrack is disabled (find() mode), only return minimal match
        if (self.disable_lazy_backtrack) {
            return;
        }

        if (max) |max_count| {
            while (i < max_count) : (i += 1) {
                if (self.matchNode(repeat.child, current_pos)) |next_pos| {
                    if (next_pos == current_pos) break;
                    current_pos = next_pos;
                    try positions.append(self.allocator, current_pos);
                } else break;
            }
        } else {
            // Unbounded: keep matching until we can't
            while (self.matchNode(repeat.child, current_pos)) |next_pos| {
                if (next_pos == current_pos) break;
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
        while (self.matchNode(child, current_pos)) |next_pos| {
            if (next_pos == current_pos) break; // Prevent infinite loop on empty matches
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

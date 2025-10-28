const std = @import("std");
const RegexError = @import("errors.zig").RegexError;
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const vm = @import("vm.zig");
const ast = @import("ast.zig");
const common = @import("common.zig");
const optimizer = @import("optimizer.zig");
const backtrack = @import("backtrack.zig");

/// Represents a match result from a regex operation
pub const Match = struct {
    /// The matched substring
    slice: []const u8,
    /// Start index in the input string
    start: usize,
    /// End index in the input string (exclusive)
    end: usize,
    /// Captured groups (if any)
    captures: []const []const u8 = &.{},

    pub fn init(slice: []const u8, start: usize, end: usize) Match {
        return .{
            .slice = slice,
            .start = start,
            .end = end,
        };
    }

    pub fn deinit(self: *Match, allocator: std.mem.Allocator) void {
        allocator.free(self.captures);
    }
};

/// Engine type used for regex matching
pub const EngineType = enum {
    thompson_nfa, // Fast O(n*m) but limited features
    backtracking, // Slower but supports all features
};

/// Main regex type - represents a compiled regular expression pattern
pub const Regex = struct {
    allocator: std.mem.Allocator,
    pattern: []const u8,
    nfa: compiler.NFA,
    backtrack_engine: ?backtrack.BacktrackEngine,
    ast_tree: ?ast.AST, // Kept for backtracking engine
    engine_type: EngineType,
    capture_count: usize,
    flags: common.CompileFlags,
    opt_info: optimizer.OptimizationInfo,
    named_captures: std.StringHashMap(usize), // name -> capture_index mapping

    /// Compile a regex pattern with default flags
    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !Regex {
        return compileWithFlags(allocator, pattern, .{});
    }

    /// Compile a regex pattern with custom flags
    pub fn compileWithFlags(allocator: std.mem.Allocator, pattern: []const u8, flags: common.CompileFlags) !Regex {
        if (pattern.len == 0) {
            return RegexError.EmptyPattern;
        }

        // Parse the pattern into an AST
        var p = try parser.Parser.init(allocator, pattern);
        var tree = try p.parse();
        errdefer tree.deinit(); // Free AST if compilation fails

        // SECURITY: Analyze pattern for vulnerabilities (ReDoS, nested quantifiers, etc.)
        // Reject patterns that are too dangerous (critical risk only)
        // Medium and high risk patterns are allowed but will be protected by runtime step counter
        const pattern_analyzer = @import("pattern_analyzer.zig");
        try pattern_analyzer.analyzeAndValidate(allocator, tree.root, .high);

        // Store owned copy of pattern
        const owned_pattern = try allocator.dupe(u8, pattern);
        errdefer allocator.free(owned_pattern);

        // Analyze AST for optimizations
        var opt = optimizer.Optimizer.init(allocator);
        var opt_info = try opt.analyze(tree.root);
        errdefer opt_info.deinit(allocator);

        // Collect named captures from AST
        var named_captures = std.StringHashMap(usize).init(allocator);
        errdefer named_captures.deinit();
        try collectNamedCaptures(tree.root, &named_captures);

        // Detect if backtracking is required
        const needs_backtracking = requiresBacktracking(tree.root);

        if (needs_backtracking) {
            // Use backtracking engine
            var backtrack_engine = try backtrack.BacktrackEngine.init(
                allocator,
                tree.root,
                tree.capture_count,
                flags
            );
            errdefer backtrack_engine.deinit();

            // Create a dummy NFA (not used)
            var dummy_nfa = compiler.NFA.init(allocator);
            errdefer dummy_nfa.deinit();
            _ = try dummy_nfa.addState();

            return Regex{
                .allocator = allocator,
                .pattern = owned_pattern,
                .nfa = dummy_nfa,
                .backtrack_engine = backtrack_engine,
                .ast_tree = tree, // Keep AST for backtracking
                .engine_type = .backtracking,
                .capture_count = tree.capture_count,
                .flags = flags,
                .opt_info = opt_info,
                .named_captures = named_captures,
            };
        } else {
            // Use Thompson NFA engine
            defer tree.deinit();

            var comp = compiler.Compiler.init(allocator);
            errdefer comp.deinit();
            _ = try comp.compile(&tree);

            return Regex{
                .allocator = allocator,
                .pattern = owned_pattern,
                .nfa = comp.nfa,
                .backtrack_engine = null,
                .ast_tree = null,
                .engine_type = .thompson_nfa,
                .capture_count = tree.capture_count,
                .flags = flags,
                .opt_info = opt_info,
                .named_captures = named_captures,
            };
        }
    }

    /// Free all resources associated with this regex
    pub fn deinit(self: *Regex) void {
        self.allocator.free(self.pattern);
        self.nfa.deinit();

        // Deinit backtracking engine if present
        if (self.backtrack_engine) |*engine| {
            var mut_engine = engine.*;
            mut_engine.deinit();
        }

        // Deinit AST tree if present
        if (self.ast_tree) |*tree| {
            var mut_tree = tree.*;
            mut_tree.deinit();
        }

        var mut_opt_info = self.opt_info;
        mut_opt_info.deinit(self.allocator);

        // Free named capture keys and deinit map
        var it = self.named_captures.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        var mut_named_captures = self.named_captures;
        mut_named_captures.deinit();
    }

    /// Get the capture group index for a named group
    /// Returns null if the name doesn't exist
    pub fn getCaptureIndex(self: *const Regex, name: []const u8) ?usize {
        return self.named_captures.get(name);
    }

    /// Get a named capture from a Match
    /// Returns null if the name doesn't exist or the capture wasn't matched
    pub fn getNamedCapture(self: *const Regex, match: *const Match, name: []const u8) ?[]const u8 {
        const index = self.getCaptureIndex(name) orelse return null;
        if (index == 0 or index > match.captures.len) return null;
        return match.captures[index - 1]; // Captures are 1-indexed in the API
    }

    /// Check if the pattern matches the entire input string
    pub fn isMatch(self: *const Regex, input: []const u8) !bool {
        switch (self.engine_type) {
            .thompson_nfa => {
                const nfa_mut = @constCast(&self.nfa);
                var virtual_machine = vm.VM.init(self.allocator, nfa_mut, self.capture_count, self.flags);
                return try virtual_machine.isMatch(input);
            },
            .backtracking => {
                const engine_mut = @constCast(&self.backtrack_engine.?);
                return engine_mut.isMatch(input);
            },
        }
    }

    /// Helper to build a Match from a VM MatchResult
    fn buildMatch(self: *const Regex, input: []const u8, result: vm.MatchResult) !Match {
        // Convert VM result to Match
        var captures_list = try std.ArrayList([]const u8).initCapacity(self.allocator, result.captures.len);
        errdefer captures_list.deinit(self.allocator);

        for (result.captures) |cap| {
            try captures_list.append(self.allocator, cap.text);
        }

        const captures = try captures_list.toOwnedSlice(self.allocator);

        const match_result = Match{
            .slice = input[result.start..result.end],
            .start = result.start,
            .end = result.end,
            .captures = captures,
        };

        // Free the VM result (but not the capture text which is from input)
        self.allocator.free(result.captures);

        return match_result;
    }

    /// Helper to build a Match from a Backtrack MatchResult
    fn buildBacktrackMatch(self: *const Regex, input: []const u8, result: backtrack.BacktrackMatch) !Match {
        var captures_list = try std.ArrayList([]const u8).initCapacity(self.allocator, result.captures.len);
        errdefer captures_list.deinit(self.allocator);

        for (result.captures) |cap| {
            if (cap.matched) {
                try captures_list.append(self.allocator, input[cap.start..cap.end]);
            } else {
                try captures_list.append(self.allocator, "");
            }
        }

        const captures = try captures_list.toOwnedSlice(self.allocator);

        return Match{
            .slice = input[result.start..result.end],
            .start = result.start,
            .end = result.end,
            .captures = captures,
        };
    }

    /// Find the first match in the input string
    pub fn find(self: *const Regex, input: []const u8) !?Match {
        switch (self.engine_type) {
            .thompson_nfa => {
                const nfa_mut = @constCast(&self.nfa);
                var virtual_machine = vm.VM.init(self.allocator, nfa_mut, self.capture_count, self.flags);

                // Use literal prefix optimization if available (but not in case-insensitive mode)
                if (self.opt_info.literal_prefix) |prefix| {
                    if (!self.flags.case_insensitive) {
                        // Quick check: if input doesn't contain the prefix, no match possible
                        if (std.mem.indexOf(u8, input, prefix)) |prefix_pos| {
                            // Try matching from the prefix position
                            if (try virtual_machine.matchAt(input, prefix_pos)) |result| {
                                return try self.buildMatch(input, result);
                            }
                            // If that didn't work, fall through to regular search
                        } else {
                            // Prefix not found, no match possible
                            return null;
                        }
                    }
                }

                if (try virtual_machine.find(input)) |result| {
                    return try self.buildMatch(input, result);
                }

                return null;
            },
            .backtracking => {
                const engine_mut = @constCast(&self.backtrack_engine.?);
                if (engine_mut.find(input)) |result| {
                    var mut_result = result;
                    defer mut_result.deinit(self.allocator);
                    return try self.buildBacktrackMatch(input, result);
                }
                return null;
            },
        }
    }

    /// Find all matches in the input string
    pub fn findAll(self: *const Regex, allocator: std.mem.Allocator, input: []const u8) ![]Match {
        var matches = std.ArrayList(Match).initCapacity(allocator, 0) catch unreachable;
        errdefer matches.deinit(allocator);

        var pos: usize = 0;
        while (pos < input.len) {
            switch (self.engine_type) {
                .thompson_nfa => {
                    const nfa_mut = @constCast(&self.nfa);
                    var virtual_machine = vm.VM.init(self.allocator, nfa_mut, self.capture_count, self.flags);

                    if (try virtual_machine.find(input[pos..])) |result| {
                        // Adjust positions relative to original input
                        const adjusted_start = pos + result.start;
                        const adjusted_end = pos + result.end;

                        var captures_list = try std.ArrayList([]const u8).initCapacity(allocator, result.captures.len);
                        errdefer captures_list.deinit(allocator);

                        for (result.captures) |cap| {
                            try captures_list.append(allocator, cap.text);
                        }

                        const captures = try captures_list.toOwnedSlice(allocator);

                        try matches.append(allocator, Match{
                            .slice = input[adjusted_start..adjusted_end],
                            .start = adjusted_start,
                            .end = adjusted_end,
                            .captures = captures,
                        });

                        // Free the VM result
                        self.allocator.free(result.captures);

                        // Move past this match (avoid infinite loop on zero-width matches)
                        pos = if (adjusted_end > adjusted_start) adjusted_end else adjusted_end + 1;
                    } else {
                        break;
                    }
                },
                .backtracking => {
                    const engine_mut = @constCast(&self.backtrack_engine.?);
                    if (engine_mut.find(input[pos..])) |result| {
                        var mut_result = result;
                        defer mut_result.deinit(self.allocator);

                        // Adjust positions relative to original input
                        const adjusted_start = pos + result.start;
                        const adjusted_end = pos + result.end;

                        var captures_list = try std.ArrayList([]const u8).initCapacity(allocator, result.captures.len);
                        errdefer captures_list.deinit(allocator);

                        for (result.captures) |cap| {
                            if (cap.matched) {
                                try captures_list.append(allocator, input[cap.start..cap.end]);
                            } else {
                                try captures_list.append(allocator, "");
                            }
                        }

                        const captures = try captures_list.toOwnedSlice(allocator);

                        try matches.append(allocator, Match{
                            .slice = input[adjusted_start..adjusted_end],
                            .start = adjusted_start,
                            .end = adjusted_end,
                            .captures = captures,
                        });

                        // Move past this match (avoid infinite loop on zero-width matches)
                        pos = if (adjusted_end > adjusted_start) adjusted_end else adjusted_end + 1;
                    } else {
                        break;
                    }
                },
            }
        }

        return matches.toOwnedSlice(allocator);
    }

    /// Expand replacement string with backreferences ($1, $2, etc.)
    fn expandReplacement(allocator: std.mem.Allocator, replacement: []const u8, captures: []const []const u8) ![]u8 {
        var result = try std.ArrayList(u8).initCapacity(allocator, 0);
        defer result.deinit(allocator);

        var i: usize = 0;
        while (i < replacement.len) {
            if (replacement[i] == '$' and i + 1 < replacement.len) {
                const next_char = replacement[i + 1];

                // Check for $$  (escaped dollar sign)
                if (next_char == '$') {
                    try result.append(allocator, '$');
                    i += 2;
                    continue;
                }

                // Check for $0-$9
                if (next_char >= '0' and next_char <= '9') {
                    const capture_index = next_char - '0';

                    // $0 is the entire match (index 0), $1 is first capture (index 0 in captures array)
                    if (capture_index == 0) {
                        // For $0, we'd need the whole match text, which isn't in captures
                        // Skip for now or handle specially
                        try result.append(allocator, '$');
                        try result.append(allocator, next_char);
                    } else if (capture_index - 1 < captures.len) {
                        const capture = captures[capture_index - 1];
                        try result.appendSlice(allocator, capture);
                    } else {
                        // Invalid capture index, keep literal
                        try result.append(allocator, '$');
                        try result.append(allocator, next_char);
                    }
                    i += 2;
                    continue;
                }
            }

            try result.append(allocator, replacement[i]);
            i += 1;
        }

        return result.toOwnedSlice(allocator);
    }

    /// Replace the first match with the replacement string (supports backreferences $1, $2, etc.)
    pub fn replace(self: *const Regex, allocator: std.mem.Allocator, input: []const u8, replacement: []const u8) ![]u8 {
        if (try self.find(input)) |match_result| {
            defer {
                var mut_match = match_result;
                mut_match.deinit(self.allocator);
            }

            // Expand replacement with backreferences
            const expanded_replacement = try expandReplacement(allocator, replacement, match_result.captures);
            defer allocator.free(expanded_replacement);

            // Build result: before + replacement + after
            const before = input[0..match_result.start];
            const after = input[match_result.end..];

            const total_len = before.len + expanded_replacement.len + after.len;
            var result = try allocator.alloc(u8, total_len);

            @memcpy(result[0..before.len], before);
            @memcpy(result[before.len .. before.len + expanded_replacement.len], expanded_replacement);
            @memcpy(result[before.len + expanded_replacement.len ..], after);

            return result;
        }

        // No match, return copy of input
        return allocator.dupe(u8, input);
    }

    /// Replace all matches with the replacement string
    pub fn replaceAll(self: *const Regex, allocator: std.mem.Allocator, input: []const u8, replacement: []const u8) ![]u8 {
        const matches = try self.findAll(allocator, input);
        defer {
            for (matches) |*match_result| {
                var mut_match = match_result;
                mut_match.deinit(allocator);
            }
            allocator.free(matches);
        }

        if (matches.len == 0) {
            return allocator.dupe(u8, input);
        }

        // Expand each replacement with its respective captures
        var expanded_replacements = try allocator.alloc([]u8, matches.len);
        defer {
            for (expanded_replacements) |repl| {
                allocator.free(repl);
            }
            allocator.free(expanded_replacements);
        }

        // Calculate result size
        var result_len: usize = input.len;
        for (matches, 0..) |match_result, i| {
            expanded_replacements[i] = try expandReplacement(allocator, replacement, match_result.captures);
            result_len = result_len - (match_result.end - match_result.start) + expanded_replacements[i].len;
        }

        var result = try allocator.alloc(u8, result_len);
        var result_pos: usize = 0;
        var input_pos: usize = 0;

        for (matches, 0..) |match_result, i| {
            // Copy text before match
            const before = input[input_pos..match_result.start];
            @memcpy(result[result_pos .. result_pos + before.len], before);
            result_pos += before.len;

            // Copy expanded replacement
            const expanded = expanded_replacements[i];
            @memcpy(result[result_pos .. result_pos + expanded.len], expanded);
            result_pos += expanded.len;

            input_pos = match_result.end;
        }

        // Copy remaining text after last match
        const remaining = input[input_pos..];
        @memcpy(result[result_pos .. result_pos + remaining.len], remaining);

        return result;
    }

    /// Iterator for lazy matching - yields matches one at a time
    pub const MatchIterator = struct {
        regex: *const Regex,
        input: []const u8,
        pos: usize,
        done: bool,

        pub fn init(regex: *const Regex, input: []const u8) MatchIterator {
            return .{
                .regex = regex,
                .input = input,
                .pos = 0,
                .done = false,
            };
        }

        /// Get the next match, or null if no more matches
        pub fn next(self: *MatchIterator, allocator: std.mem.Allocator) !?Match {
            if (self.done) return null;

            while (self.pos <= self.input.len) {
                switch (self.regex.engine_type) {
                    .thompson_nfa => {
                        const nfa_mut = @constCast(&self.regex.nfa);
                        var virtual_machine = vm.VM.init(
                            allocator,
                            nfa_mut,
                            self.regex.capture_count,
                            self.regex.flags,
                        );

                        if (try virtual_machine.matchAt(self.input, self.pos)) |result| {
                            const adjusted_start = result.start;
                            const adjusted_end = result.end;

                            // Convert vm.Capture to []const u8
                            var captures_list = try std.ArrayList([]const u8).initCapacity(allocator, result.captures.len);
                            errdefer captures_list.deinit(allocator);

                            for (result.captures) |cap| {
                                try captures_list.append(allocator, cap.text);
                            }

                            const captures = try captures_list.toOwnedSlice(allocator);

                            // Free the VM result
                            allocator.free(result.captures);

                            const match_result = Match{
                                .slice = self.input[adjusted_start..adjusted_end],
                                .start = adjusted_start,
                                .end = adjusted_end,
                                .captures = captures,
                            };

                            // Move past this match (avoid infinite loop on zero-width matches)
                            self.pos = if (adjusted_end > adjusted_start) adjusted_end else adjusted_end + 1;

                            return match_result;
                        }
                    },
                    .backtracking => {
                        const engine_mut = @constCast(&self.regex.backtrack_engine.?);

                        // Try matching at current position
                        engine_mut.resetCaptures();
                        if (engine_mut.matchNode(engine_mut.ast_root, self.pos)) |end_pos| {
                            if (end_pos > self.pos or (end_pos == self.pos and engine_mut.canMatchEmpty(engine_mut.ast_root))) {
                                // Build match result
                                var captures_list = try std.ArrayList([]const u8).initCapacity(allocator, engine_mut.captures.len);
                                errdefer captures_list.deinit(allocator);

                                for (engine_mut.captures) |cap| {
                                    if (cap.matched) {
                                        try captures_list.append(allocator, self.input[cap.start..cap.end]);
                                    } else {
                                        try captures_list.append(allocator, "");
                                    }
                                }

                                const captures = try captures_list.toOwnedSlice(allocator);

                                const match_result = Match{
                                    .slice = self.input[self.pos..end_pos],
                                    .start = self.pos,
                                    .end = end_pos,
                                    .captures = captures,
                                };

                                // Move past this match
                                self.pos = if (end_pos > self.pos) end_pos else end_pos + 1;

                                return match_result;
                            }
                        }
                    },
                }

                self.pos += 1;
            }

            self.done = true;
            return null;
        }

        /// Reset the iterator to the beginning
        pub fn reset(self: *MatchIterator) void {
            self.pos = 0;
            self.done = false;
        }
    };

    /// Create an iterator for lazy matching
    pub fn iterator(self: *const Regex, input: []const u8) MatchIterator {
        return MatchIterator.init(self, input);
    }

    /// Split the input string by the pattern
    pub fn split(self: *const Regex, allocator: std.mem.Allocator, input: []const u8) ![][]const u8 {
        const matches = try self.findAll(allocator, input);
        defer {
            for (matches) |*match_result| {
                var mut_match = match_result;
                mut_match.deinit(allocator);
            }
            allocator.free(matches);
        }

        var parts = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;
        errdefer parts.deinit(allocator);

        var pos: usize = 0;
        for (matches) |match_result| {
            try parts.append(allocator, input[pos..match_result.start]);
            pos = match_result.end;
        }

        // Add remaining part
        try parts.append(allocator, input[pos..]);

        return parts.toOwnedSlice(allocator);
    }
};

/// Helper function to detect if AST requires backtracking engine
fn requiresBacktracking(node: *ast.Node) bool {
    switch (node.node_type) {
        // These features require backtracking
        .lookahead, .lookbehind, .backref => return true,

        // Check for lazy quantifiers
        .star, .plus, .optional => {
            const greedy = switch (node.node_type) {
                .star => node.data.star.greedy,
                .plus => node.data.plus.greedy,
                .optional => node.data.optional.greedy,
                else => unreachable,
            };
            if (!greedy) return true; // Lazy quantifiers need backtracking

            // Recursively check child
            const child = switch (node.node_type) {
                .star => node.data.star.child,
                .plus => node.data.plus.child,
                .optional => node.data.optional.child,
                else => unreachable,
            };
            return requiresBacktracking(child);
        },
        .repeat => {
            if (!node.data.repeat.greedy) return true;
            return requiresBacktracking(node.data.repeat.child);
        },

        // Recursively check compound nodes
        .concat => {
            return requiresBacktracking(node.data.concat.left) or
                   requiresBacktracking(node.data.concat.right);
        },
        .alternation => {
            return requiresBacktracking(node.data.alternation.left) or
                   requiresBacktracking(node.data.alternation.right);
        },
        .group => return requiresBacktracking(node.data.group.child),

        // These don't require backtracking
        .literal, .any, .char_class, .anchor, .empty => return false,
    }
}

/// Helper function to recursively collect named captures from AST
fn collectNamedCaptures(node: *ast.Node, map: *std.StringHashMap(usize)) !void {
    switch (node.node_type) {
        .group => {
            const group = node.data.group;
            if (group.name) |name| {
                if (group.capture_index) |index| {
                    try map.put(name, index);
                }
            }
            try collectNamedCaptures(group.child, map);
        },
        .concat => {
            try collectNamedCaptures(node.data.concat.left, map);
            try collectNamedCaptures(node.data.concat.right, map);
        },
        .alternation => {
            try collectNamedCaptures(node.data.alternation.left, map);
            try collectNamedCaptures(node.data.alternation.right, map);
        },
        .star => try collectNamedCaptures(node.data.star.child, map),
        .plus => try collectNamedCaptures(node.data.plus.child, map),
        .optional => try collectNamedCaptures(node.data.optional.child, map),
        .repeat => try collectNamedCaptures(node.data.repeat.child, map),
        .lookahead, .lookbehind => {
            const child = switch (node.node_type) {
                .lookahead => node.data.lookahead.child,
                .lookbehind => node.data.lookbehind.child,
                else => unreachable,
            };
            try collectNamedCaptures(child, map);
        },
        else => {}, // Literals, character classes, anchors, backreferences don't contain groups
    }
}

test "compile empty pattern" {
    const allocator = std.testing.allocator;
    const result = Regex.compile(allocator, "");
    try std.testing.expectError(RegexError.EmptyPattern, result);
}

test "compile basic pattern" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "test");
    defer regex.deinit();
    try std.testing.expectEqualStrings("test", regex.pattern);
}

test "match literal" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "hello");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("hello"));
    try std.testing.expect(!try regex.isMatch("world"));
}

test "find literal" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "world");
    defer regex.deinit();

    if (try regex.find("hello world")) |match_result| {
        var mut_match = match_result;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("world", match_result.slice);
        try std.testing.expectEqual(@as(usize, 6), match_result.start);
        try std.testing.expectEqual(@as(usize, 11), match_result.end);
    } else {
        try std.testing.expect(false); // Should have found a match
    }
}

test "alternation" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "cat|dog");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("cat"));
    try std.testing.expect(try regex.isMatch("dog"));
    try std.testing.expect(!try regex.isMatch("bird"));
}

test "star quantifier" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a*");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch(""));
    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("aaa"));
}

test "plus quantifier" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a+");
    defer regex.deinit();

    try std.testing.expect(!try regex.isMatch(""));
    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("aaa"));
}

test "optional quantifier" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a?");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch(""));
    try std.testing.expect(try regex.isMatch("a"));
}

test "dot wildcard" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a.c");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(try regex.isMatch("axc"));
    try std.testing.expect(!try regex.isMatch("ac"));
}

test "character class \\d" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\d+");
    defer regex.deinit();

    if (try regex.find("abc123def")) |match_result| {
        var mut_match = match_result;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("123", match_result.slice);
    } else {
        try std.testing.expect(false);
    }
}

test "replace" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "world");
    defer regex.deinit();

    const result = try regex.replace(allocator, "hello world", "Zig");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("hello Zig", result);
}

test "replace all" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a");
    defer regex.deinit();

    const result = try regex.replaceAll(allocator, "banana", "o");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("bonono", result);
}

test "split" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, ",");
    defer regex.deinit();

    const parts = try regex.split(allocator, "a,b,c");
    defer allocator.free(parts);

    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualStrings("a", parts[0]);
    try std.testing.expectEqualStrings("b", parts[1]);
    try std.testing.expectEqualStrings("c", parts[2]);
}

test "compile rejects dangerous nested quantifiers" {
    const allocator = std.testing.allocator;

    // This pattern should be rejected as critical risk
    const result = Regex.compile(allocator, "(a+)+");
    try std.testing.expectError(RegexError.PatternTooComplex, result);
}

test "compile rejects nested stars" {
    const allocator = std.testing.allocator;

    // This pattern should be rejected
    const result = Regex.compile(allocator, "(a*)*");
    try std.testing.expectError(RegexError.PatternTooComplex, result);
}

test "compile accepts safe complex patterns" {
    const allocator = std.testing.allocator;

    // This pattern should be accepted (medium risk is OK)
    var regex = try Regex.compile(allocator, "a+b*c?d{2,5}");
    defer regex.deinit();
}

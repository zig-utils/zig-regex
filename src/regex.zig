const std = @import("std");
const RegexError = @import("errors.zig").RegexError;
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const vm = @import("vm.zig");
const ast = @import("ast.zig");
const common = @import("common.zig");

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

/// Main regex type - represents a compiled regular expression pattern
pub const Regex = struct {
    allocator: std.mem.Allocator,
    pattern: []const u8,
    nfa: compiler.NFA,
    capture_count: usize,
    flags: common.CompileFlags,

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
        defer tree.deinit();

        // Compile AST to NFA
        var comp = compiler.Compiler.init(allocator);
        errdefer comp.deinit();

        _ = try comp.compile(&tree);

        // Store owned copy of pattern
        const owned_pattern = try allocator.dupe(u8, pattern);
        errdefer allocator.free(owned_pattern);

        return Regex{
            .allocator = allocator,
            .pattern = owned_pattern,
            .nfa = comp.nfa,
            .capture_count = tree.capture_count,
            .flags = flags,
        };
    }

    /// Free all resources associated with this regex
    pub fn deinit(self: *Regex) void {
        self.allocator.free(self.pattern);
        self.nfa.deinit();
    }

    /// Check if the pattern matches the entire input string
    pub fn isMatch(self: *const Regex, input: []const u8) !bool {
        const nfa_mut = @constCast(&self.nfa);
        var virtual_machine = vm.VM.init(self.allocator, nfa_mut, self.capture_count, self.flags);
        return try virtual_machine.isMatch(input);
    }

    /// Find the first match in the input string
    pub fn find(self: *const Regex, input: []const u8) !?Match {
        const nfa_mut = @constCast(&self.nfa);
        var virtual_machine = vm.VM.init(self.allocator, nfa_mut, self.capture_count, self.flags);

        if (try virtual_machine.find(input)) |result| {
            // Convert VM result to Match
            var captures = try self.allocator.alloc([]const u8, result.captures.len);
            for (result.captures, 0..) |cap, i| {
                captures[i] = cap.text;
            }

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

        return null;
    }

    /// Find all matches in the input string
    pub fn findAll(self: *const Regex, allocator: std.mem.Allocator, input: []const u8) ![]Match {
        var matches = std.ArrayList(Match).initCapacity(allocator, 0) catch unreachable;
        errdefer matches.deinit(allocator);

        var pos: usize = 0;
        while (pos < input.len) {
            const nfa_mut = @constCast(&self.nfa);
            var virtual_machine = vm.VM.init(self.allocator, nfa_mut, self.capture_count, self.flags);

            if (try virtual_machine.find(input[pos..])) |result| {
                // Adjust positions relative to original input
                const adjusted_start = pos + result.start;
                const adjusted_end = pos + result.end;

                var captures = try allocator.alloc([]const u8, result.captures.len);
                for (result.captures, 0..) |cap, i| {
                    captures[i] = cap.text;
                }

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
        }

        return matches.toOwnedSlice(allocator);
    }

    /// Replace the first match with the replacement string
    pub fn replace(self: *const Regex, allocator: std.mem.Allocator, input: []const u8, replacement: []const u8) ![]u8 {
        if (try self.find(input)) |match_result| {
            defer {
                var mut_match = match_result;
                mut_match.deinit(self.allocator);
            }

            // Build result: before + replacement + after
            const before = input[0..match_result.start];
            const after = input[match_result.end..];

            const total_len = before.len + replacement.len + after.len;
            var result = try allocator.alloc(u8, total_len);

            @memcpy(result[0..before.len], before);
            @memcpy(result[before.len .. before.len + replacement.len], replacement);
            @memcpy(result[before.len + replacement.len ..], after);

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

        // Calculate result size
        var result_len: usize = input.len;
        for (matches) |match_result| {
            result_len = result_len - (match_result.end - match_result.start) + replacement.len;
        }

        var result = try allocator.alloc(u8, result_len);
        var result_pos: usize = 0;
        var input_pos: usize = 0;

        for (matches) |match_result| {
            // Copy text before match
            const before = input[input_pos..match_result.start];
            @memcpy(result[result_pos .. result_pos + before.len], before);
            result_pos += before.len;

            // Copy replacement
            @memcpy(result[result_pos .. result_pos + replacement.len], replacement);
            result_pos += replacement.len;

            input_pos = match_result.end;
        }

        // Copy remaining text after last match
        const remaining = input[input_pos..];
        @memcpy(result[result_pos .. result_pos + remaining.len], remaining);

        return result;
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

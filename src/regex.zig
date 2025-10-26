const std = @import("std");
const RegexError = @import("errors.zig").RegexError;

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
};

/// Main regex type - represents a compiled regular expression pattern
pub const Regex = struct {
    allocator: std.mem.Allocator,
    pattern: []const u8,
    // TODO: Add NFA/DFA state machines here
    // nfa: *NFA,
    // compiled: bool,

    /// Compile a regex pattern
    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !Regex {
        if (pattern.len == 0) {
            return RegexError.EmptyPattern;
        }

        // TODO: Implement actual compilation
        // For now, just store the pattern
        const owned_pattern = try allocator.dupe(u8, pattern);

        return Regex{
            .allocator = allocator,
            .pattern = owned_pattern,
        };
    }

    /// Free all resources associated with this regex
    pub fn deinit(self: *Regex) void {
        self.allocator.free(self.pattern);
        // TODO: Free NFA/DFA structures
    }

    /// Check if the pattern matches anywhere in the input string
    pub fn isMatch(self: *const Regex, input: []const u8) !bool {
        _ = self;
        _ = input;
        // TODO: Implement actual matching
        return false;
    }

    /// Find the first match in the input string
    pub fn find(self: *const Regex, input: []const u8) !?Match {
        _ = self;
        _ = input;
        // TODO: Implement actual matching
        return null;
    }

    /// Find all matches in the input string
    pub fn findAll(self: *const Regex, allocator: std.mem.Allocator, input: []const u8) ![]Match {
        _ = self;
        _ = allocator;
        _ = input;
        // TODO: Implement actual matching
        return &.{};
    }

    /// Replace the first match with the replacement string
    pub fn replace(self: *const Regex, allocator: std.mem.Allocator, input: []const u8, replacement: []const u8) ![]u8 {
        _ = self;
        _ = allocator;
        _ = input;
        _ = replacement;
        // TODO: Implement replacement
        return &.{};
    }

    /// Replace all matches with the replacement string
    pub fn replaceAll(self: *const Regex, allocator: std.mem.Allocator, input: []const u8, replacement: []const u8) ![]u8 {
        _ = self;
        _ = allocator;
        _ = input;
        _ = replacement;
        // TODO: Implement replacement
        return &.{};
    }

    /// Split the input string by the pattern
    pub fn split(self: *const Regex, allocator: std.mem.Allocator, input: []const u8) ![][]const u8 {
        _ = self;
        _ = allocator;
        _ = input;
        // TODO: Implement split
        return &.{};
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

test "match initialization" {
    const input = "hello world";
    const match = Match.init(input[0..5], 0, 5);
    try std.testing.expectEqualStrings("hello", match.slice);
    try std.testing.expectEqual(@as(usize, 0), match.start);
    try std.testing.expectEqual(@as(usize, 5), match.end);
}

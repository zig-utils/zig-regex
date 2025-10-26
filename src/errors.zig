const std = @import("std");

/// All possible errors that can occur when compiling or executing regex patterns
pub const RegexError = error{
    // Parsing errors
    InvalidPattern,
    UnexpectedCharacter,
    UnexpectedEndOfPattern,
    InvalidEscapeSequence,
    InvalidCharacterClass,
    InvalidQuantifier,
    UnmatchedParenthesis,
    UnmatchedBracket,
    EmptyPattern,

    // Compilation errors
    CompilationFailed,
    TooManyStates,
    TooManyCaptures,

    // Runtime errors
    MatchFailed,
    OutOfMemory,

    // General errors
    InvalidArgument,
};

/// Error context for better error reporting
pub const ErrorContext = struct {
    position: usize,
    pattern: []const u8,
    message: []const u8,

    pub fn format(
        self: ErrorContext,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("Regex error at position {d}: {s}\n", .{ self.position, self.message });
        try writer.print("Pattern: {s}\n", .{self.pattern});

        // Print pointer to error location
        var i: usize = 0;
        while (i < self.position + 9) : (i += 1) {
            try writer.writeByte(' ');
        }
        try writer.writeAll("^\n");
    }
};

test "error context formatting" {
    const ctx = ErrorContext{
        .position = 5,
        .pattern = "abc[def",
        .message = "Unmatched bracket",
    };

    var buf: [256]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{any}", .{ctx});
    try std.testing.expect(result.len > 0);
}

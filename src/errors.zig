const std = @import("std");

/// All possible errors that can occur when compiling or executing regex patterns
pub const RegexError = error{
    // Parsing errors
    InvalidPattern,
    UnexpectedCharacter,
    UnexpectedEndOfPattern,
    InvalidEscapeSequence,
    InvalidCharacterClass,
    InvalidCharacterRange,
    InvalidQuantifier,
    InvalidRepetitionRange,
    UnmatchedParenthesis,
    UnmatchedBracket,
    EmptyPattern,
    EmptyGroup,
    EmptyCharacterClass,
    InvalidGroupName,
    InvalidBackreference,
    DuplicateGroupName,
    NestingTooDeep,

    // Compilation errors
    CompilationFailed,
    TooManyStates,
    TooManyCaptures,
    TooManyAlternations,
    PatternTooComplex,
    StackOverflow,

    // Runtime errors
    MatchFailed,
    OutOfMemory,
    InputTooLong,
    Timeout,

    // General errors
    InvalidArgument,
    NotImplemented,
};

/// Error context for better error reporting
pub const ErrorContext = struct {
    error_type: RegexError,
    position: usize,
    pattern: []const u8,
    message: []const u8,
    hint: ?[]const u8 = null,
    recovery_suggestion: ?[]const u8 = null,

    pub fn init(error_type: RegexError, position: usize, pattern: []const u8, message: []const u8) ErrorContext {
        return .{
            .error_type = error_type,
            .position = position,
            .pattern = pattern,
            .message = message,
        };
    }

    pub fn withHint(self: ErrorContext, hint: []const u8) ErrorContext {
        var ctx = self;
        ctx.hint = hint;
        return ctx;
    }

    pub fn withRecoverySuggestion(self: ErrorContext, suggestion: []const u8) ErrorContext {
        var ctx = self;
        ctx.recovery_suggestion = suggestion;
        return ctx;
    }

    pub fn format(
        self: ErrorContext,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("\n❌ Regex Error: {s}\n", .{@errorName(self.error_type)});
        try writer.print("Position: {d}\n", .{self.position});
        try writer.print("Message: {s}\n\n", .{self.message});

        // Show pattern with error marker
        try writer.print("Pattern: {s}\n", .{self.pattern});
        try writer.writeAll("         ");
        var i: usize = 0;
        while (i < self.position) : (i += 1) {
            try writer.writeByte(' ');
        }
        try writer.writeAll("^\n");

        // Show hint if available
        if (self.hint) |hint| {
            try writer.print("\n💡 Hint: {s}\n", .{hint});
        }

        // Show recovery suggestion if available
        if (self.recovery_suggestion) |suggestion| {
            try writer.print("🔧 Suggestion: {s}\n", .{suggestion});
        }

        try writer.writeByte('\n');
    }
};

/// Helper to create common error contexts
pub const ErrorHelper = struct {
    /// Create error context for unmatched parenthesis
    pub fn unmatchedParen(position: usize, pattern: []const u8) ErrorContext {
        return ErrorContext.init(
            RegexError.UnmatchedParenthesis,
            position,
            pattern,
            "Unmatched opening parenthesis '('",
        ).withHint("Every '(' must have a matching ')'").withRecoverySuggestion("Add a closing ')' or remove the opening '('");
    }

    /// Create error context for unmatched bracket
    pub fn unmatchedBracket(position: usize, pattern: []const u8) ErrorContext {
        return ErrorContext.init(
            RegexError.UnmatchedBracket,
            position,
            pattern,
            "Unmatched opening bracket '['",
        ).withHint("Every '[' must have a matching ']'").withRecoverySuggestion("Add a closing ']' or remove the opening '['");
    }

    /// Create error context for invalid escape sequence
    pub fn invalidEscape(position: usize, pattern: []const u8, char: u8) ErrorContext {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Invalid escape sequence '\\{c}'", .{char}) catch "Invalid escape sequence";
        return ErrorContext.init(
            RegexError.InvalidEscapeSequence,
            position,
            pattern,
            msg,
        ).withHint("Valid escapes: \\d \\w \\s \\n \\t \\r or use \\\\ for literal backslash");
    }

    /// Create error context for invalid quantifier
    pub fn invalidQuantifier(position: usize, pattern: []const u8) ErrorContext {
        return ErrorContext.init(
            RegexError.InvalidQuantifier,
            position,
            pattern,
            "Quantifier without preceding element",
        ).withHint("Quantifiers (+, *, ?, {n,m}) must follow a character, group, or class").withRecoverySuggestion("Add a character or group before the quantifier");
    }

    /// Create error context for invalid character range
    pub fn invalidCharRange(position: usize, pattern: []const u8, start: u8, end: u8) ErrorContext {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Invalid character range '{c}-{c}'", .{ start, end }) catch "Invalid character range";
        return ErrorContext.init(
            RegexError.InvalidCharacterRange,
            position,
            pattern,
            msg,
        ).withHint("Range end must be greater than or equal to range start");
    }

    /// Create error context for too many captures
    pub fn tooManyCaptures(position: usize, pattern: []const u8, max: usize) ErrorContext {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Too many capture groups (maximum: {d})", .{max}) catch "Too many capture groups";
        return ErrorContext.init(
            RegexError.TooManyCaptures,
            position,
            pattern,
            msg,
        ).withRecoverySuggestion("Use non-capturing groups (?:...) where captures aren't needed");
    }

    /// Create error context for pattern too complex
    pub fn patternTooComplex(position: usize, pattern: []const u8) ErrorContext {
        return ErrorContext.init(
            RegexError.PatternTooComplex,
            position,
            pattern,
            "Pattern is too complex and may cause performance issues",
        ).withHint("Consider simplifying the pattern or breaking it into multiple regexes").withRecoverySuggestion("Avoid deeply nested groups and excessive alternations");
    }
};

test "error context formatting" {
    const ctx = ErrorContext.init(
        RegexError.UnmatchedBracket,
        5,
        "abc[def",
        "Unmatched bracket",
    ).withHint("Add closing bracket").withRecoverySuggestion("Use \\[ to match literal bracket");

    var buf: [1024]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{any}", .{ctx});
    try std.testing.expect(result.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result, "UnmatchedBracket") != null);
}

test "error helper functions" {
    const pattern = "abc(def";
    const ctx = ErrorHelper.unmatchedParen(3, pattern);
    try std.testing.expectEqual(RegexError.UnmatchedParenthesis, ctx.error_type);
    try std.testing.expectEqual(@as(usize, 3), ctx.position);
    try std.testing.expect(ctx.hint != null);
    try std.testing.expect(ctx.recovery_suggestion != null);
}

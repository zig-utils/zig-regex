const std = @import("std");

/// Zig Regex Library
///
/// A modern, performant regular expression library for Zig with zero external dependencies.
/// This library implements Thompson NFA construction for efficient pattern matching.
///
/// Example usage:
/// ```zig
/// const Regex = @import("regex").Regex;
/// const regex = try Regex.compile(allocator, "\\d+");
/// defer regex.deinit();
/// if (try regex.find("abc123")) |match| {
///     std.debug.print("Found: {s}\n", .{match.slice});
/// }
/// ```

// Public API exports
pub const Regex = @import("regex.zig").Regex;
pub const Match = @import("regex.zig").Match;
pub const RegexError = @import("errors.zig").RegexError;

// Version information
pub const version = std.SemanticVersion{
    .major = 0,
    .minor = 1,
    .patch = 0,
};

test {
    // Run all tests from imported modules
    std.testing.refAllDecls(@This());
}

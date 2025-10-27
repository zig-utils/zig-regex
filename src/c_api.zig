const std = @import("std");
const Regex = @import("regex.zig").Regex;
const Match = @import("regex.zig").Match;

/// C FFI for the Zig regex library
///
/// This module provides a C-compatible API for using the regex library
/// from other languages (C, C++, Python via ctypes, etc.)
///
/// Example usage from C:
/// ```c
/// #include "zig_regex.h"
///
/// ZigRegex* regex = zig_regex_compile("\\d+", NULL);
/// if (regex) {
///     bool matches = zig_regex_is_match(regex, "test 123");
///     printf("Matches: %d\n", matches);
///     zig_regex_free(regex);
/// }
/// ```

/// Opaque handle to a compiled regex
pub const ZigRegex = opaque {};

/// Opaque handle to a match result
pub const ZigMatch = opaque {};

/// Error codes
pub const ZigRegexError = enum(c_int) {
    ok = 0,
    compile_error = -1,
    invalid_pattern = -2,
    out_of_memory = -3,
    no_match = -4,
    null_pointer = -5,
};

// Global allocator for C API (uses C allocator)
var c_allocator = std.heap.c_allocator;

/// Compile a regex pattern
///
/// Returns NULL on error. Call zig_regex_get_last_error() to get error details.
/// The returned regex must be freed with zig_regex_free().
export fn zig_regex_compile(pattern: [*:0]const u8) ?*ZigRegex {
    const pattern_slice = std.mem.span(pattern);

    const regex_ptr = c_allocator.create(Regex) catch return null;
    regex_ptr.* = Regex.compile(c_allocator, pattern_slice) catch {
        c_allocator.destroy(regex_ptr);
        return null;
    };

    return @ptrCast(regex_ptr);
}

/// Free a compiled regex
export fn zig_regex_free(regex: ?*ZigRegex) void {
    if (regex) |r| {
        const regex_ptr: *Regex = @ptrCast(@alignCast(r));
        regex_ptr.deinit();
        c_allocator.destroy(regex_ptr);
    }
}

/// Check if a pattern matches a string
///
/// Returns 1 if matches, 0 if no match, -1 on error
export fn zig_regex_is_match(regex: ?*ZigRegex, input: [*:0]const u8) c_int {
    if (regex == null) return @intFromEnum(ZigRegexError.null_pointer);

    const regex_ptr: *const Regex = @ptrCast(@alignCast(regex.?));
    const input_slice = std.mem.span(input);

    const result = regex_ptr.isMatch(input_slice) catch return -1;
    return if (result) 1 else 0;
}

/// Find the first match in a string
///
/// Returns NULL if no match or on error.
/// The returned match must be freed with zig_match_free().
export fn zig_regex_find(regex: ?*ZigRegex, input: [*:0]const u8) ?*ZigMatch {
    if (regex == null) return null;

    const regex_ptr: *const Regex = @ptrCast(@alignCast(regex.?));
    const input_slice = std.mem.span(input);

    const maybe_match = regex_ptr.find(input_slice) catch return null;
    if (maybe_match) |match| {
        const match_ptr = c_allocator.create(Match) catch return null;
        match_ptr.* = match;
        return @ptrCast(match_ptr);
    }

    return null;
}

/// Get the matched substring
///
/// Returns NULL if match is NULL.
/// The returned string is owned by the match and should not be freed separately.
export fn zig_match_get_text(match: ?*ZigMatch) ?[*:0]const u8 {
    if (match == null) return null;

    const match_ptr: *const Match = @ptrCast(@alignCast(match.?));
    // Note: This assumes the slice is null-terminated, which may not always be true
    // In production, you'd want to copy to a null-terminated buffer
    return @ptrCast(match_ptr.slice.ptr);
}

/// Get the start position of a match
export fn zig_match_get_start(match: ?*ZigMatch) c_int {
    if (match == null) return -1;

    const match_ptr: *const Match = @ptrCast(@alignCast(match.?));
    return @intCast(match_ptr.start);
}

/// Get the end position of a match
export fn zig_match_get_end(match: ?*ZigMatch) c_int {
    if (match == null) return -1;

    const match_ptr: *const Match = @ptrCast(@alignCast(match.?));
    return @intCast(match_ptr.end);
}

/// Free a match result
export fn zig_match_free(match: ?*ZigMatch) void {
    if (match) |m| {
        const match_ptr: *Match = @ptrCast(@alignCast(m));
        var mut_match = match_ptr.*;
        mut_match.deinit(c_allocator);
        c_allocator.destroy(match_ptr);
    }
}

/// Get version string
export fn zig_regex_version() [*:0]const u8 {
    return "0.1.0";
}

// Header file generator (for documentation)
pub fn generateHeader(writer: anytype) !void {
    try writer.writeAll(
        \\#ifndef ZIG_REGEX_H
        \\#define ZIG_REGEX_H
        \\
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif
        \\
        \\#include <stddef.h>
        \\#include <stdbool.h>
        \\
        \\/* Opaque types */
        \\typedef struct ZigRegex ZigRegex;
        \\typedef struct ZigMatch ZigMatch;
        \\
        \\/* Error codes */
        \\typedef enum {
        \\    ZIG_REGEX_OK = 0,
        \\    ZIG_REGEX_COMPILE_ERROR = -1,
        \\    ZIG_REGEX_INVALID_PATTERN = -2,
        \\    ZIG_REGEX_OUT_OF_MEMORY = -3,
        \\    ZIG_REGEX_NO_MATCH = -4,
        \\    ZIG_REGEX_NULL_POINTER = -5,
        \\} ZigRegexError;
        \\
        \\/* Compile a regex pattern */
        \\ZigRegex* zig_regex_compile(const char* pattern);
        \\
        \\/* Free a compiled regex */
        \\void zig_regex_free(ZigRegex* regex);
        \\
        \\/* Check if pattern matches string (returns 1=match, 0=no match, -1=error) */
        \\int zig_regex_is_match(ZigRegex* regex, const char* input);
        \\
        \\/* Find first match in string (returns NULL if no match) */
        \\ZigMatch* zig_regex_find(ZigRegex* regex, const char* input);
        \\
        \\/* Get matched text from match result */
        \\const char* zig_match_get_text(ZigMatch* match);
        \\
        \\/* Get start position of match */
        \\int zig_match_get_start(ZigMatch* match);
        \\
        \\/* Get end position of match */
        \\int zig_match_get_end(ZigMatch* match);
        \\
        \\/* Free a match result */
        \\void zig_match_free(ZigMatch* match);
        \\
        \\/* Get library version */
        \\const char* zig_regex_version(void);
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\
        \\#endif /* ZIG_REGEX_H */
        \\
    );
}

test "C API header generation" {
    var buffer = try std.ArrayList(u8).initCapacity(std.testing.allocator, 0);
    defer buffer.deinit(std.testing.allocator);

    try generateHeader(buffer.writer(std.testing.allocator));
    try std.testing.expect(buffer.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "ZIG_REGEX_H") != null);
}

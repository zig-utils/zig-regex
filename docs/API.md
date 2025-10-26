# API Reference

Complete API documentation for the zig-regex library.

## Table of Contents

- [Core Types](#core-types)
- [Compilation](#compilation)
- [Matching](#matching)
- [Searching](#searching)
- [Replacement](#replacement)
- [Splitting](#splitting)
- [Flags](#flags)
- [Error Handling](#error-handling)

---

## Core Types

### `Regex`

The main regex type representing a compiled regular expression pattern.

```zig
pub const Regex = struct {
    allocator: std.mem.Allocator,
    pattern: []const u8,
    nfa: compiler.NFA,
    capture_count: usize,
    flags: common.CompileFlags,
}
```

### `Match`

Represents a match result from a regex operation.

```zig
pub const Match = struct {
    /// The matched substring
    slice: []const u8,
    /// Start index in the input string
    start: usize,
    /// End index in the input string (exclusive)
    end: usize,
    /// Captured groups (if any)
    captures: []const []const u8,
}
```

**Methods:**
- `deinit(allocator: std.mem.Allocator)` - Free capture group memory

---

## Compilation

### `compile()`

Compile a regex pattern with default flags.

```zig
pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !Regex
```

**Parameters:**
- `allocator` - Memory allocator for the regex and its internal structures
- `pattern` - The regex pattern string

**Returns:** `Regex` or error

**Errors:**
- `RegexError.EmptyPattern` - Pattern string is empty
- `RegexError.InvalidPattern` - Syntax error in pattern
- `RegexError.UnexpectedCharacter` - Invalid character in pattern
- `RegexError.UnexpectedEndOfPattern` - Pattern ended unexpectedly
- `RegexError.InvalidEscapeSequence` - Invalid escape sequence
- `RegexError.InvalidCharacterClass` - Malformed character class
- `RegexError.UnmatchedParenthesis` - Unbalanced parentheses
- `RegexError.UnmatchedBracket` - Unbalanced brackets

**Example:**
```zig
const allocator = std.heap.page_allocator;
var regex = try Regex.compile(allocator, "\\d{3}-\\d{4}");
defer regex.deinit();
```

### `compileWithFlags()`

Compile a regex pattern with custom flags.

```zig
pub fn compileWithFlags(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    flags: common.CompileFlags
) !Regex
```

**Parameters:**
- `allocator` - Memory allocator
- `pattern` - The regex pattern string
- `flags` - Compilation flags (see [Flags](#flags))

**Returns:** `Regex` or error

**Example:**
```zig
var regex = try Regex.compileWithFlags(
    allocator,
    "hello",
    .{ .case_insensitive = true }
);
defer regex.deinit();
```

### `deinit()`

Free all resources associated with the regex.

```zig
pub fn deinit(self: *Regex) void
```

**Example:**
```zig
var regex = try Regex.compile(allocator, "pattern");
defer regex.deinit(); // Always call deinit when done
```

---

## Matching

### `isMatch()`

Check if the pattern matches anywhere in the input string.

```zig
pub fn isMatch(self: *const Regex, input: []const u8) !bool
```

**Parameters:**
- `input` - The string to search in

**Returns:** `true` if match found, `false` otherwise

**Example:**
```zig
var regex = try Regex.compile(allocator, "\\d+");
defer regex.deinit();

if (try regex.isMatch("abc123")) {
    std.debug.print("Found digits!\n", .{});
}
```

---

## Searching

### `find()`

Find the first match in the input string.

```zig
pub fn find(self: *const Regex, input: []const u8) !?Match
```

**Parameters:**
- `input` - The string to search in

**Returns:** `Match` if found, `null` otherwise

**Example:**
```zig
var regex = try Regex.compile(allocator, "\\d+");
defer regex.deinit();

if (try regex.find("Price: $123")) |match| {
    var mut_match = match;
    defer mut_match.deinit(allocator);

    std.debug.print("Found: {s}\n", .{match.slice}); // "123"
    std.debug.print("At position: {d}-{d}\n", .{match.start, match.end});
}
```

### `findAll()`

Find all non-overlapping matches in the input string.

```zig
pub fn findAll(
    self: *const Regex,
    allocator: std.mem.Allocator,
    input: []const u8
) ![]Match
```

**Parameters:**
- `allocator` - Allocator for the results array
- `input` - The string to search in

**Returns:** Array of `Match` objects (caller owns, must free)

**Example:**
```zig
var regex = try Regex.compile(allocator, "\\d+");
defer regex.deinit();

const matches = try regex.findAll(allocator, "Call 555-1234 or 555-5678");
defer {
    for (matches) |*match| {
        var mut_match = match;
        mut_match.deinit(allocator);
    }
    allocator.free(matches);
}

for (matches) |match| {
    std.debug.print("Found: {s}\n", .{match.slice});
}
// Output:
// Found: 555
// Found: 1234
// Found: 555
// Found: 5678
```

---

## Replacement

### `replace()`

Replace the first match with a replacement string.

```zig
pub fn replace(
    self: *const Regex,
    allocator: std.mem.Allocator,
    input: []const u8,
    replacement: []const u8
) ![]u8
```

**Parameters:**
- `allocator` - Allocator for the result string
- `input` - The input string
- `replacement` - The replacement string

**Returns:** New string with first match replaced (caller owns, must free)

**Example:**
```zig
var regex = try Regex.compile(allocator, "\\d+");
defer regex.deinit();

const result = try regex.replace(allocator, "Price: $123", "XXX");
defer allocator.free(result);

std.debug.print("{s}\n", .{result}); // "Price: $XXX"
```

### `replaceAll()`

Replace all matches with a replacement string.

```zig
pub fn replaceAll(
    self: *const Regex,
    allocator: std.mem.Allocator,
    input: []const u8,
    replacement: []const u8
) ![]u8
```

**Parameters:**
- `allocator` - Allocator for the result string
- `input` - The input string
- `replacement` - The replacement string

**Returns:** New string with all matches replaced (caller owns, must free)

**Example:**
```zig
var regex = try Regex.compile(allocator, "\\d+");
defer regex.deinit();

const result = try regex.replaceAll(allocator, "Call 555-1234 or 555-5678", "XXX");
defer allocator.free(result);

std.debug.print("{s}\n", .{result}); // "Call XXX-XXX or XXX-XXX"
```

---

## Splitting

### `split()`

Split the input string by the regex pattern.

```zig
pub fn split(
    self: *const Regex,
    allocator: std.mem.Allocator,
    input: []const u8
) ![][]const u8
```

**Parameters:**
- `allocator` - Allocator for the results array
- `input` - The string to split

**Returns:** Array of string slices (caller owns array, must free)

**Example:**
```zig
var regex = try Regex.compile(allocator, ",");
defer regex.deinit();

const parts = try regex.split(allocator, "a,b,c");
defer allocator.free(parts);

for (parts) |part| {
    std.debug.print("Part: {s}\n", .{part});
}
// Output:
// Part: a
// Part: b
// Part: c
```

---

## Flags

### `CompileFlags`

Flags that control regex compilation and matching behavior.

```zig
pub const CompileFlags = packed struct {
    case_insensitive: bool = false,
    multiline: bool = false,        // Not yet implemented
    dot_all: bool = false,           // Not yet implemented
    extended: bool = false,          // Not yet implemented
    unicode: bool = false,           // Not yet implemented
}
```

#### `case_insensitive`

When `true`, the pattern matches both uppercase and lowercase letters.

**Example:**
```zig
var regex = try Regex.compileWithFlags(
    allocator,
    "hello",
    .{ .case_insensitive = true }
);
defer regex.deinit();

try std.testing.expect(try regex.isMatch("HELLO")); // true
try std.testing.expect(try regex.isMatch("Hello")); // true
try std.testing.expect(try regex.isMatch("hello")); // true
```

---

## Error Handling

All errors are defined in the `RegexError` error set:

```zig
pub const RegexError = error{
    // Parse errors
    InvalidPattern,
    UnexpectedCharacter,
    UnexpectedEndOfPattern,
    InvalidEscapeSequence,
    InvalidCharacterClass,
    InvalidQuantifier,
    UnmatchedParenthesis,
    UnmatchedBracket,
    EmptyPattern,

    // Runtime errors
    CompilationFailed,
    TooManyStates,
    OutOfMemory,
};
```

**Error Handling Example:**
```zig
const regex = Regex.compile(allocator, "[invalid") catch |err| {
    switch (err) {
        RegexError.UnmatchedBracket => {
            std.debug.print("Unclosed character class\n", .{});
        },
        RegexError.InvalidPattern => {
            std.debug.print("Invalid regex pattern\n", .{});
        },
        else => {
            std.debug.print("Error: {}\n", .{err});
        },
    }
    return err;
};
```

---

## Pattern Syntax

### Literals

- `a`, `b`, `1`, etc. - Match exact characters

### Wildcards

- `.` - Match any character (except newline by default)

### Quantifiers

- `*` - Zero or more (greedy)
- `+` - One or more (greedy)
- `?` - Zero or one (optional)
- `{n}` - Exactly n times
- `{n,}` - n or more times
- `{n,m}` - Between n and m times (inclusive)

### Alternation

- `|` - Match either left or right side

### Character Classes

- `[abc]` - Match any of a, b, or c
- `[a-z]` - Match any lowercase letter
- `[^abc]` - Match anything except a, b, or c
- `\d` - Match any digit [0-9]
- `\D` - Match any non-digit
- `\w` - Match word character [a-zA-Z0-9_]
- `\W` - Match non-word character
- `\s` - Match whitespace [ \t\n\r]
- `\S` - Match non-whitespace

### Anchors

- `^` - Match start of string/line
- `$` - Match end of string/line
- `\b` - Match word boundary
- `\B` - Match non-word boundary

### Groups

- `(...)` - Capture group

### Escaping

- `\\` - Literal backslash
- `\.` - Literal dot
- `\*` - Literal asterisk
- `\+` - Literal plus
- `\?` - Literal question mark
- `\n` - Newline
- `\t` - Tab
- `\r` - Carriage return

---

## Memory Management

### Ownership Rules

1. **Regex object**: Caller owns the `Regex` returned by `compile()` and must call `deinit()`
2. **Match objects**: Caller owns `Match` objects from `find()` and `findAll()` and must call `deinit()`
3. **String results**: Caller owns strings returned by `replace()` and `replaceAll()` and must free
4. **Arrays**: Caller owns arrays returned by `findAll()` and `split()` and must free

### Best Practices

```zig
// Use defer for automatic cleanup
var regex = try Regex.compile(allocator, pattern);
defer regex.deinit();

// Clean up match results
if (try regex.find(input)) |match| {
    var mut_match = match;
    defer mut_match.deinit(allocator);
    // Use match...
}

// Clean up arrays and their contents
const matches = try regex.findAll(allocator, input);
defer {
    for (matches) |*match| {
        var mut_match = match;
        mut_match.deinit(allocator);
    }
    allocator.free(matches);
}
```

---

## Performance Considerations

### Time Complexity

- **Compilation**: O(p) where p is pattern length
- **isMatch**: O(n × m) where n is input length, m is NFA state count
- **find**: O(n × m × k) where k is number of positions to try
- **findAll**: O(n × m) amortized
- **replace/replaceAll**: O(n + r) where r is replacement length

### Space Complexity

- **NFA**: O(p) persistent storage
- **VM execution**: O(m × c) where c is capture group count
- **Results**: O(r) where r is result count

### Optimization Tips

1. Compile patterns once and reuse them
2. Use `isMatch()` when you only need a boolean result
3. Prefer simpler patterns when possible
4. Consider using character classes instead of alternation for single characters

---

## Complete Example

```zig
const std = @import("std");
const Regex = @import("regex").Regex;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Email validation pattern
    var regex = try Regex.compile(
        allocator,
        "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$"
    );
    defer regex.deinit();

    const emails = [_][]const u8{
        "user@example.com",
        "invalid.email",
        "test.user+tag@example.co.uk",
    };

    for (emails) |email| {
        if (try regex.isMatch(email)) {
            std.debug.print("✓ Valid: {s}\n", .{email});
        } else {
            std.debug.print("✗ Invalid: {s}\n", .{email});
        }
    }
}
```

---

**Last Updated:** 2025-01-26
**Version:** 0.1.0
**Zig Version:** 0.15.1

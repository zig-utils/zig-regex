# Usage Examples

Practical examples demonstrating common use cases for the zig-regex library.

## Table of Contents

- [Basic Pattern Matching](#basic-pattern-matching)
- [Email Validation](#email-validation)
- [URL Extraction](#url-extraction)
- [Phone Number Formatting](#phone-number-formatting)
- [Text Processing](#text-processing)
- [Data Extraction](#data-extraction)
- [Input Sanitization](#input-sanitization)
- [Log Parsing](#log-parsing)
- [Case-Insensitive Search](#case-insensitive-search)
- [Advanced Patterns](#advanced-patterns)

---

## Basic Pattern Matching

### Simple Literal Match

```zig
const std = @import("std");
const Regex = @import("regex").Regex;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex = try Regex.compile(allocator, "hello");
    defer regex.deinit();

    if (try regex.isMatch("hello world")) {
        std.debug.print("Match found!\n", .{});
    }
}
```

### Finding Digits

```zig
var regex = try Regex.compile(allocator, "\\d+");
defer regex.deinit();

if (try regex.find("Order #12345")) |match| {
    var mut_match = match;
    defer mut_match.deinit(allocator);
    std.debug.print("Order number: {s}\n", .{match.slice}); // "12345"
}
```

---

## Email Validation

### Basic Email Validator

```zig
const std = @import("std");
const Regex = @import("regex").Regex;

pub fn isValidEmail(allocator: std.mem.Allocator, email: []const u8) !bool {
    var regex = try Regex.compile(
        allocator,
        "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$"
    );
    defer regex.deinit();

    return try regex.isMatch(email);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_emails = [_][]const u8{
        "user@example.com",
        "test.user+tag@example.co.uk",
        "invalid.email",
        "@invalid.com",
        "user@",
    };

    for (test_emails) |email| {
        const valid = try isValidEmail(allocator, email);
        const status = if (valid) "✓ Valid" else "✗ Invalid";
        std.debug.print("{s}: {s}\n", .{ status, email });
    }
}
```

### Extract Email from Text

```zig
var regex = try Regex.compile(allocator, "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}");
defer regex.deinit();

const text = "Contact us at support@example.com or sales@example.org";
const emails = try regex.findAll(allocator, text);
defer {
    for (emails) |*match| {
        var mut_match = match;
        mut_match.deinit(allocator);
    }
    allocator.free(emails);
}

for (emails) |email| {
    std.debug.print("Found email: {s}\n", .{email.slice});
}
```

---

## URL Extraction

### Extract URLs from Text

```zig
const std = @import("std");
const Regex = @import("regex").Regex;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Simple URL pattern
    var regex = try Regex.compile(
        allocator,
        "https?://[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}"
    );
    defer regex.deinit();

    const text = "Visit https://example.com or http://test.org for more info.";
    const urls = try regex.findAll(allocator, text);
    defer {
        for (urls) |*match| {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        allocator.free(urls);
    }

    for (urls) |url| {
        std.debug.print("Found URL: {s}\n", .{url.slice});
    }
}
```

---

## Phone Number Formatting

### Validate Phone Numbers

```zig
const std = @import("std");
const Regex = @import("regex").Regex;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // US phone number format: XXX-XXXX or (XXX) XXX-XXXX
    var regex = try Regex.compile(allocator, "\\d{3}-\\d{4}");
    defer regex.deinit();

    const numbers = [_][]const u8{
        "555-1234",
        "123-4567",
        "invalid",
    };

    for (numbers) |number| {
        const valid = try regex.isMatch(number);
        std.debug.print("{s}: {s}\n", .{
            number,
            if (valid) "valid" else "invalid",
        });
    }
}
```

### Extract Phone Numbers

```zig
var regex = try Regex.compile(allocator, "\\d{3}-\\d{3}-\\d{4}");
defer regex.deinit();

const text = "Call 555-123-4567 or 555-987-6543 for assistance.";
const phones = try regex.findAll(allocator, text);
defer {
    for (phones) |*match| {
        var mut_match = match;
        mut_match.deinit(allocator);
    }
    allocator.free(phones);
}

for (phones) |phone| {
    std.debug.print("Phone: {s}\n", .{phone.slice});
}
```

---

## Text Processing

### Remove Extra Whitespace

```zig
const std = @import("std");
const Regex = @import("regex").Regex;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex = try Regex.compile(allocator, "\\s+");
    defer regex.deinit();

    const text = "This   has    extra     spaces";
    const result = try regex.replaceAll(allocator, text, " ");
    defer allocator.free(result);

    std.debug.print("Original: '{s}'\n", .{text});
    std.debug.print("Cleaned:  '{s}'\n", .{result});
}
```

### Extract Words

```zig
var regex = try Regex.compile(allocator, "\\w+");
defer regex.deinit();

const text = "Hello, world! This is a test.";
const words = try regex.findAll(allocator, text);
defer {
    for (words) |*match| {
        var mut_match = match;
        mut_match.deinit(allocator);
    }
    allocator.free(words);
}

for (words, 0..) |word, i| {
    std.debug.print("Word {d}: {s}\n", .{ i + 1, word.slice });
}
```

---

## Data Extraction

### Parse CSV-like Data

```zig
const std = @import("std");
const Regex = @import("regex").Regex;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex = try Regex.compile(allocator, ",");
    defer regex.deinit();

    const csv_line = "John,Doe,30,Engineer";
    const fields = try regex.split(allocator, csv_line);
    defer allocator.free(fields);

    const field_names = [_][]const u8{ "First", "Last", "Age", "Job" };
    for (fields, field_names) |field, name| {
        std.debug.print("{s}: {s}\n", .{ name, field });
    }
}
```

### Extract Key-Value Pairs

```zig
var regex = try Regex.compile(allocator, "(\\w+)=(\\w+)");
defer regex.deinit();

const config = "host=localhost port=8080 debug=true";
const matches = try regex.findAll(allocator, config);
defer {
    for (matches) |*match| {
        var mut_match = match;
        mut_match.deinit(allocator);
    }
    allocator.free(matches);
}

for (matches) |match| {
    std.debug.print("Config: {s}\n", .{match.slice});
}
```

---

## Input Sanitization

### Remove Non-Alphanumeric Characters

```zig
const std = @import("std");
const Regex = @import("regex").Regex;

pub fn sanitizeInput(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var regex = try Regex.compile(allocator, "[^a-zA-Z0-9]");
    defer regex.deinit();

    return try regex.replaceAll(allocator, input, "");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const dirty_input = "Hello, World! @#$% 123";
    const clean = try sanitizeInput(allocator, dirty_input);
    defer allocator.free(clean);

    std.debug.print("Original: {s}\n", .{dirty_input});
    std.debug.print("Sanitized: {s}\n", .{clean}); // "HelloWorld123"
}
```

### Validate Username

```zig
pub fn isValidUsername(allocator: std.mem.Allocator, username: []const u8) !bool {
    // Username: 3-16 alphanumeric characters, underscores allowed
    var regex = try Regex.compile(allocator, "^[a-zA-Z0-9_]{3,16}$");
    defer regex.deinit();

    return try regex.isMatch(username);
}
```

---

## Log Parsing

### Extract Error Messages

```zig
const std = @import("std");
const Regex = @import("regex").Regex;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex = try Regex.compile(allocator, "ERROR: .+");
    defer regex.deinit();

    const logs = [_][]const u8{
        "INFO: Application started",
        "ERROR: Connection timeout",
        "DEBUG: Processing request",
        "ERROR: Invalid credentials",
    };

    std.debug.print("Errors found:\n", .{});
    for (logs) |log| {
        if (try regex.find(log)) |match| {
            var mut_match = match;
            defer mut_match.deinit(allocator);
            std.debug.print("  {s}\n", .{match.slice});
        }
    }
}
```

### Parse Timestamps

```zig
var regex = try Regex.compile(allocator, "\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}");
defer regex.deinit();

const log = "[2025-01-26 14:30:45] User logged in";
if (try regex.find(log)) |match| {
    var mut_match = match;
    defer mut_match.deinit(allocator);
    std.debug.print("Timestamp: {s}\n", .{match.slice});
}
```

---

## Case-Insensitive Search

### Search Regardless of Case

```zig
const std = @import("std");
const Regex = @import("regex").Regex;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex = try Regex.compileWithFlags(
        allocator,
        "error",
        .{ .case_insensitive = true }
    );
    defer regex.deinit();

    const texts = [_][]const u8{
        "ERROR: System failure",
        "Error: File not found",
        "error: Invalid input",
    };

    for (texts) |text| {
        if (try regex.find(text)) |match| {
            var mut_match = match;
            defer mut_match.deinit(allocator);
            std.debug.print("Found '{s}' in: {s}\n", .{ match.slice, text });
        }
    }
}
```

### Case-Insensitive Replace

```zig
var regex = try Regex.compileWithFlags(
    allocator,
    "the",
    .{ .case_insensitive = true }
);
defer regex.deinit();

const text = "The quick brown fox. the fox jumps.";
const result = try regex.replaceAll(allocator, text, "a");
defer allocator.free(result);

std.debug.print("{s}\n", .{result}); // "a quick brown fox. a fox jumps."
```

---

## Advanced Patterns

### Validate Password Strength

```zig
const std = @import("std");
const Regex = @import("regex").Regex;

pub fn isStrongPassword(allocator: std.mem.Allocator, password: []const u8) !bool {
    // At least 8 characters with digits
    var regex = try Regex.compile(allocator, "^.{8,}");
    defer regex.deinit();

    if (!try regex.isMatch(password)) {
        return false;
    }

    // Check for digits
    var digit_regex = try Regex.compile(allocator, "\\d");
    defer digit_regex.deinit();

    return try digit_regex.isMatch(password);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const passwords = [_][]const u8{
        "short",
        "longenough",
        "password123",
    };

    for (passwords) |pwd| {
        const strong = try isStrongPassword(allocator, pwd);
        std.debug.print("{s}: {s}\n", .{
            pwd,
            if (strong) "Strong" else "Weak",
        });
    }
}
```

### Extract Hashtags

```zig
var regex = try Regex.compile(allocator, "#\\w+");
defer regex.deinit();

const tweet = "Loving #Zig programming! #opensource #systems";
const hashtags = try regex.findAll(allocator, tweet);
defer {
    for (hashtags) |*match| {
        var mut_match = match;
        mut_match.deinit(allocator);
    }
    allocator.free(hashtags);
}

std.debug.print("Hashtags:\n", .{});
for (hashtags) |tag| {
    std.debug.print("  {s}\n", .{tag.slice});
}
```

### Parse Markdown Links

```zig
// Pattern: [text](url)
var regex = try Regex.compile(allocator, "\\[.+\\]\\(.+\\)");
defer regex.deinit();

const markdown = "Check out [Zig](https://ziglang.org) and [GitHub](https://github.com)";
const links = try regex.findAll(allocator, markdown);
defer {
    for (links) |*match| {
        var mut_match = match;
        mut_match.deinit(allocator);
    }
    allocator.free(links);
}

for (links) |link| {
    std.debug.print("Link: {s}\n", .{link.slice});
}
```

---

## Best Practices

### 1. Always Use defer for Cleanup

```zig
var regex = try Regex.compile(allocator, pattern);
defer regex.deinit(); // Automatically cleanup

// Your code here...
```

### 2. Reuse Compiled Regexes

```zig
// Good: Compile once, use many times
var regex = try Regex.compile(allocator, "\\d+");
defer regex.deinit();

for (strings) |str| {
    _ = try regex.isMatch(str);
}

// Bad: Compiling in loop
for (strings) |str| {
    var regex = try Regex.compile(allocator, "\\d+");
    defer regex.deinit();
    _ = try regex.isMatch(str);
}
```

### 3. Handle Matches Properly

```zig
if (try regex.find(input)) |match| {
    var mut_match = match;
    defer mut_match.deinit(allocator); // Clean up captures
    // Use match...
}
```

### 4. Use isMatch() for Boolean Checks

```zig
// Good: Use isMatch when you only need true/false
if (try regex.isMatch(input)) {
    // ...
}

// Less efficient: Using find() when you don't need the match
if (try regex.find(input)) |match| {
    var mut_match = match;
    defer mut_match.deinit(allocator);
    // Not using match data...
}
```

---

**Last Updated:** 2025-01-26
**Version:** 0.1.0

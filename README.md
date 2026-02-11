# zig-regex

<div align="center">

**A modern, high-performance regular expression library for Zig**

[![Zig](https://img.shields.io/badge/Zig-0.16+-orange.svg)](https://ziglang.org)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[Features](#features) - [Installation](#installation) - [Quick Start](#quick-start) - [CLI](#cli) - [Documentation](#documentation)

</div>

---

## Overview

zig-regex is a regular expression engine for Zig featuring Thompson NFA construction with linear time complexity, a backtracking engine for advanced features, and extensive pattern support. Built with zero external dependencies and full memory control through Zig allocators.

## Features

### Core Regex Features

| Feature | Syntax | Status |
|---------|--------|--------|
| **Literals** | `abc`, `123` | Stable |
| **Quantifiers** | `*`, `+`, `?`, `{n}`, `{m,n}` | Stable |
| **Alternation** | `a\|b\|c` | Stable |
| **Character Classes** | `\d`, `\w`, `\s`, `\D`, `\W`, `\S` | Stable |
| **Custom Classes** | `[abc]`, `[a-z]`, `[^0-9]` | Stable |
| **Anchors** | `^`, `$`, `\b`, `\B` | Stable |
| **Wildcards** | `.` | Stable |
| **Capturing Groups** | `(...)` | Stable |
| **Named Groups** | `(?P<name>...)`, `(?<name>...)` | Stable |
| **Non-capturing** | `(?:...)` | Stable |
| **Lookahead** | `(?=...)`, `(?!...)` | Stable |
| **Lookbehind** | `(?<=...)`, `(?<!...)` | Stable |
| **Backreferences** | `\1`, `\2` | Stable |
| **Case-insensitive** | `compileWithFlags(..., .{.case_insensitive = true})` | Stable |
| **Multiline** | `compileWithFlags(..., .{.multiline = true})` | Stable |
| **Dot-all** | `compileWithFlags(..., .{.dot_matches_newline = true})` | Stable |
| **Escaping** | `\\`, `\.`, `\n`, `\t`, `\r` | Stable |

### Advanced Features

- **Hybrid Execution Engine**: Automatically selects between Thompson NFA (O(n*m)) and optimized backtracking
- **AST Optimization**: Constant folding, dead code elimination, quantifier simplification
- **NFA Optimization**: Epsilon transition removal, state merging, transition optimization
- **Pattern Macros**: Composable, reusable pattern definitions
- **Type-Safe Builder API**: Fluent interface for programmatic pattern construction
- **Thread Safety**: Safe concurrent matching with `SharedRegex` and `RegexCache`
- **Pattern Analysis**: Built-in ReDoS detection and pattern linting
- **Comprehensive API**: `compile`, `find`, `findAll`, `replace`, `replaceAll`, `split`, iterator support

### Quality

- **Zero Dependencies**: Only Zig standard library
- **Linear Time Matching**: Thompson NFA guarantees O(n*m) worst-case
- **Memory Safety**: Full control via Zig allocators, no hidden allocations, zero leaks
- **500+ Tests**: Comprehensive test suite covering core features, edge cases, regressions, and stress tests

## Installation

### Using Zig Package Manager

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .regex = .{
        .url = "https://github.com/zig-utils/zig-regex/archive/main.tar.gz",
        .hash = "...", // zig will provide this
    },
},
```

Then in `build.zig`:

```zig
const regex = b.dependency("regex", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("regex", regex.module("regex"));
```

### Manual Installation

```bash
git clone https://github.com/zig-utils/zig-regex.git
cd zig-regex
zig build
zig build test
```

## Quick Start

### Basic Pattern Matching

```zig
const std = @import("std");
const Regex = @import("regex").Regex;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex = try Regex.compile(allocator, "\\d{3}-\\d{4}");
    defer regex.deinit();

    if (try regex.find("Call me at 555-1234")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        std.debug.print("Found: {s}\n", .{match.slice}); // "555-1234"
    }
}
```

### Find All Matches

```zig
var regex = try Regex.compile(allocator, "\\d+");
defer regex.deinit();

const matches = try regex.findAll(allocator, "a1b23c456");
defer {
    for (matches) |*m| {
        var mut_m = m;
        mut_m.deinit(allocator);
    }
    allocator.free(matches);
}

// matches: "1", "23", "456"
```

### Replace

```zig
var regex = try Regex.compile(allocator, "(\\w+)@(\\w+)");
defer regex.deinit();

const result = try regex.replace(allocator, "email: user@host ok", "[$0]");
defer allocator.free(result);
// result: "email: [user@host] ok"
```

### Capture Groups

```zig
var regex = try Regex.compile(allocator, "(\\d{4})-(\\d{2})-(\\d{2})");
defer regex.deinit();

if (try regex.find("Date: 2024-03-15")) |match| {
    var mut_match = match;
    defer mut_match.deinit(allocator);

    // match.captures[0] = "2024"
    // match.captures[1] = "03"
    // match.captures[2] = "15"
}
```

### Case-Insensitive / Multiline

```zig
var regex = try Regex.compileWithFlags(allocator, "^hello", .{
    .case_insensitive = true,
    .multiline = true,
});
defer regex.deinit();
```

## CLI

zig-regex includes a command-line tool:

```bash
# Find first match
regex '\d+' 'hello 123 world'
# Output: 123

# Find all matches
regex -g '\d+' 'hello 123 world 456'
# Output:
# 123
# 456

# Replace
regex -r '[$0]' '\d+' 'hello 123 world'
# Output: hello [123] world

# Case-insensitive
regex -i 'hello' 'HELLO world'

# Read from stdin
echo "hello 123 world" | regex '\d+'

# Version
regex -v
```

## Building

```bash
zig build           # Build library and CLI
zig build test      # Run all tests
zig build run       # Run CLI
zig build example   # Run basic example
zig build bench     # Run benchmarks
```

## Documentation

- [API Reference](docs/API.md)
- [Advanced Features Guide](docs/ADVANCED_FEATURES.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Examples](docs/EXAMPLES.md)
- [Performance Guide](docs/BENCHMARKS.md)

## Requirements

- Zig 0.16 or later
- No external dependencies

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass (`zig build test`)
5. Submit a pull request

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Acknowledgments

Inspired by:
- Ken Thompson's NFA construction algorithm
- RE2 (Google's regex engine)
- Rust's regex crate

## Support

- [GitHub Issues](https://github.com/zig-utils/zig-regex/issues)

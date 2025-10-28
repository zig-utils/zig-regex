# zig-regex

<div align="center">

**A modern, high-performance regular expression library for Zig**

[![Zig](https://img.shields.io/badge/Zig-0.15.1-orange.svg)](https://ziglang.org)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[Features](#features) • [Installation](#installation) • [Quick Start](#quick-start) • [Documentation](#documentation) • [Performance](#performance)

</div>

---

## Overview

zig-regex is a comprehensive regular expression engine for Zig featuring Thompson NFA construction with linear time complexity, extensive pattern support, and advanced optimization capabilities. Built with zero external dependencies and full memory control through Zig allocators.

## Features

### Core Regex Features

| Feature | Syntax | Description |
|---------|--------|-------------|
| **Literals** | `abc`, `123` | Match exact characters and strings |
| **Quantifiers** | `*`, `+`, `?`, `{n}`, `{m,n}` | Greedy repetition |
| **Lazy Quantifiers** | `*?`, `+?`, `??`, `{n,m}?` | Non-greedy repetition |
| **Possessive Quantifiers** | `*+`, `++`, `?+`, `{n,m}+` | Atomic repetition (no backtracking) |
| **Alternation** | `a\|b\|c` | Match any alternative |
| **Character Classes** | `\d`, `\w`, `\s`, `\D`, `\W`, `\S` | Predefined character sets |
| **Custom Classes** | `[abc]`, `[a-z]`, `[^0-9]` | User-defined character sets |
| **Unicode Classes** | `\p{Letter}`, `\p{Number}`, `\X` | Unicode property support |
| **Anchors** | `^`, `$`, `\A`, `\z`, `\Z`, `\b`, `\B` | Position matching |
| **Wildcards** | `.` | Match any character |
| **Groups** | `(...)` | Capturing groups |
| **Named Groups** | `(?P<name>...)`, `(?<name>...)` | Named capturing groups |
| **Non-capturing** | `(?:...)` | Grouping without capture |
| **Atomic Groups** | `(?>...)` | Possessive grouping |
| **Lookahead** | `(?=...)`, `(?!...)` | Positive/negative lookahead |
| **Lookbehind** | `(?<=...)`, `(?<!...)` | Positive/negative lookbehind |
| **Backreferences** | `\1`, `\2`, `\k<name>` | Reference previous captures |
| **Conditionals** | `(?(condition)yes\|no)` | Conditional patterns |
| **Escaping** | `\\`, `\.`, `\n`, `\t`, etc. | Special character escaping |

### Advanced Features

- **Hybrid Execution Engine**: Automatically selects between Thompson NFA (O(n×m)) and optimized backtracking
- **AST Optimization**: Constant folding, dead code elimination, quantifier simplification
- **NFA Optimization**: Epsilon transition removal, state merging, transition optimization
- **Pattern Macros**: Composable, reusable pattern definitions
- **Type-Safe Builder API**: Fluent interface for programmatic pattern construction
- **Thread Safety**: Safe concurrent matching with proper synchronization
- **C FFI**: Complete C API for interoperability
- **WASM Support**: WebAssembly compilation target
- **Profiling & Analysis**: Built-in performance profiling and pattern linting
- **Comprehensive API**: `compile`, `find`, `findAll`, `replace`, `replaceAll`, `split`, iterator support

### Quality & Performance

- **Zero Dependencies**: Only Zig standard library
- **Linear Time Matching**: Thompson NFA guarantees O(n×m) worst-case
- **Memory Safety**: Full control via Zig allocators, no hidden allocations
- **Extensive Tests**: Comprehensive test suite with 150+ test cases
- **Battle-Tested**: Compliance tests against standard regex behavior

## Installation

### Using Zig Package Manager (zon)

```zig
// build.zig.zon
.{
    .name = "your-project",
    .version = "0.1.0",
    .dependencies = .{
        .regex = .{
            .url = "https://github.com/zig-utils/zig-regex/archive/main.tar.gz",
            .hash = "...", // zig will provide this
        },
    },
}
```

```zig
// build.zig
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

    // Simple matching
    const regex = try Regex.compile(allocator, "\\d{3}-\\d{4}");
    defer regex.deinit();

    if (try regex.find("Call me at 555-1234")) |match| {
        std.debug.print("Found: {s}\n", .{match.slice}); // "555-1234"
    }
}
```

### Named Capture Groups

```zig
const regex = try Regex.compile(allocator, "(?P<year>\\d{4})-(?P<month>\\d{2})-(?P<day>\\d{2})");
defer regex.deinit();

if (try regex.find("Date: 2024-03-15")) |match| {
    const year = match.getCapture("year");   // "2024"
    const month = match.getCapture("month"); // "03"
    const day = match.getCapture("day");     // "15"
}
```

### Unicode Support

```zig
// Match any Unicode letter
const regex = try Regex.compile(allocator, "\\p{Letter}+");

// Match emoji
const emoji_regex = try Regex.compile(allocator, "\\p{Emoji}");

// Match grapheme clusters
const grapheme_regex = try Regex.compile(allocator, "\\X+");
```

### Atomic Groups & Possessive Quantifiers

```zig
// Prevent catastrophic backtracking
const regex = try Regex.compile(allocator, "(?>a+)b");
const poss_regex = try Regex.compile(allocator, "a++b");

// These won't match "aaaa" - no backtracking allowed
try std.testing.expect(try regex.find("aaaa") == null);
try std.testing.expect(try poss_regex.find("aaaa") == null);
```

### Conditional Patterns

```zig
// Match different patterns based on a condition
const regex = try Regex.compile(allocator, "(a)?(?(1)b|c)");

try std.testing.expectEqualStrings("ab", (try regex.find("ab")).?.slice);
try std.testing.expectEqualStrings("c", (try regex.find("c")).?.slice);
```

### Builder API

```zig
const Builder = @import("regex").Builder;

var builder = Builder.init(allocator);
defer builder.deinit();

const pattern = try builder
    .startGroup()
    .literal("https?://")
    .oneOrMore(Builder.Patterns.word())
    .literal(".")
    .oneOrMore(Builder.Patterns.alpha())
    .endGroup()
    .build();

const regex = try Regex.compile(allocator, pattern);
defer regex.deinit();
```

### Pattern Macros

```zig
const MacroRegistry = @import("regex").MacroRegistry;
const CommonMacros = @import("regex").CommonMacros;

var macros = MacroRegistry.init(allocator);
defer macros.deinit();

// Load common macros
try CommonMacros.loadInto(&macros);

// Define custom macros
try macros.define("phone", "\\d{3}-\\d{4}");
try macros.define("email", "${email_local}@${email_domain}");

// Expand macros in patterns
const pattern = try macros.expand("Contact: ${email} or ${phone}");
defer allocator.free(pattern);
```

## Documentation

- [API Reference](docs/API.md) - Complete API documentation
- [Advanced Features Guide](docs/ADVANCED_FEATURES.md) - Detailed feature explanations
- [Architecture](docs/ARCHITECTURE.md) - Design and implementation
- [Examples](docs/EXAMPLES.md) - Real-world usage examples
- [Performance Guide](docs/BENCHMARKS.md) - Optimization tips
- [Limitations](docs/LIMITATIONS.md) - Known constraints and workarounds

## Performance

zig-regex uses Thompson NFA construction to guarantee **O(n×m)** worst-case time complexity:
- **n** = input string length
- **m** = pattern length

This prevents catastrophic backtracking that plagues traditional regex engines.

### Benchmarks

```
Pattern: /\d{3}-\d{4}/
Input: 1000-byte string
Time: ~850ns (M1 MacBook Pro)

Pattern: /(?:a|b)*c/
Input: 10000 'a's + 'c'
Time: Linear growth (no exponential backtracking)
```

Run benchmarks: `zig build bench`

## Building

```bash
# Build library
zig build

# Run tests
zig build test

# Run examples
zig build example

# Run benchmarks
zig build bench

# Generate documentation
zig build docs
```

## Development Roadmap

See [TODO.md](TODO.md) for the complete development roadmap and planned features.

## Requirements

- Zig 0.15.1 or later
- No external dependencies

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass
5. Submit a pull request

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Acknowledgments

Inspired by:
- Ken Thompson's NFA construction algorithm
- RE2 (Google's regex engine)
- Rust's regex crate
- PCRE (Perl Compatible Regular Expressions)

## Support

- [GitHub Issues](https://github.com/zig-utils/zig-regex/issues)
- [Discussions](https://github.com/zig-utils/zig-regex/discussions)

---

<div align="center">
Made with ❤️ for the Zig community
</div>

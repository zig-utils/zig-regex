# zig-regex

A modern, performant regular expression library for Zig.

## Status

**Currently in early development (Phase 1)**

This library is being built from the ground up to provide native regex support for Zig, which doesn't have built-in regular expression functionality.

## Goals

- **Zero external dependencies** - stdlib only
- **Full memory control** - use Zig allocators throughout
- **Fast pattern matching** - Thompson NFA construction with linear time complexity
- **Thread-safe** - compiled patterns safe for concurrent use
- **Comprehensive syntax** - support for common regex features
- **Well-tested** - extensive test coverage and compliance tests

## Planned Features

- Basic pattern matching (literals, character classes, quantifiers)
- Capture groups (numbered and named)
- Anchors and boundaries (`^`, `$`, `\b`)
- Character class shortcuts (`\d`, `\w`, `\s`, etc.)
- Look-ahead and look-behind assertions
- Case-insensitive matching
- Unicode support (UTF-8)
- Replace and split operations

## Installation

Coming soon. This library will be installable via Zig's package manager once it reaches a usable state.

## Usage Example

```zig
const std = @import("std");
const Regex = @import("regex").Regex;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Compile a regex pattern
    const regex = try Regex.compile(allocator, "\\d{3}-\\d{4}");
    defer regex.deinit();

    // Match against input
    const text = "Call me at 555-1234";
    if (try regex.find(text)) |match| {
        std.debug.print("Found: {s}\n", .{match.slice});
    }
}
```

## Development Roadmap

See [TODO.md](TODO.md) for the complete development roadmap with all planned phases and tasks.

## Building

```bash
# Build the library
zig build

# Run tests
zig build test

# Run example (when available)
zig build run
```

## Requirements

- Zig 0.15.1 or later

## Contributing

This project is in early development. Contributions will be welcome once the core functionality is established.

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Resources

- [Project TODO](TODO.md) - Detailed development roadmap
- [Architecture Documentation](docs/ARCHITECTURE.md) - Design decisions (coming soon)
- [API Reference](docs/API.md) - API documentation (coming soon)

## Acknowledgments

Inspired by:
- Ken Thompson's NFA construction algorithm
- RE2 (Google's regex engine)
- Rust's regex crate
- Other Zig regex implementations (mvzr, tiehuis/zig-regex)

# zig-regex

<div align="center">

**A modern, high-performance regular expression library for Zig**

[![Zig](https://img.shields.io/badge/Zig-0.17.0--dev.1857+-orange.svg)](https://ziglang.org)
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

### Multi-literal search

`regex.literals` holds the engines for searching many fixed byte strings at
once, shared by zig-anti-virus and zig-waf. Patterns may contain any bytes,
0x00 and 0xff included, and every match reports the pattern's `id`. Each
engine is built into a relocatable little-endian blob: write `owned.bytes` to
disk, mmap it later and `load` it in place. Searching never allocates.

```zig
const lit = @import("regex").literals;

const patterns = [_]lit.Pattern{
    .{ .bytes = "select", .id = 1 },
    .{ .bytes = "\x00\xffMZ", .id = 2 },
};

// Teddy: SIMD search for up to 64 literals.
var teddy = try lit.Teddy.build(allocator, &patterns, .{ .ascii_case_insensitive = true });
defer teddy.deinit(allocator);
if (teddy.view.find(haystack, 0)) |m| std.debug.print("{d} at {d}..{d}\n", .{ m.pattern, m.start, m.end });

// Aho-Corasick: any number of literals, every match or leftmost-longest,
// and streaming over chunks with `scanStream`.
var ac = try lit.AhoCorasick.build(allocator, &patterns, .{});
defer ac.deinit(allocator);
var it = ac.view.iterator(haystack);
while (it.next()) |m| std.debug.print("{d} at {d}\n", .{ m.pattern, m.start });

// Sampled Bloom prefilter: candidate positions for very large sets. With
// stride 8 every anchor must be at least 11 bytes long.
var filter = try lit.Sbbf.build(allocator, &.{"\x4d\x5a\x90\x00\x03\x00\x00\x00\x04\x00\x00"}, .{ .stride = 8 });
defer filter.deinit(allocator);
var buf: [256]usize = undefined;
var probe = filter.view.prober(haystack, 0);
while (true) {
    const candidates = probe.next(&buf);
    if (candidates.len == 0) break;
    // An anchor may start in the 8 bytes ending at each candidate.
}
```

### Byte Mode (binary data)

By default a pattern describes UTF-8 text: `\xHH` is the code point U+00HH
(two bytes when HH >= 80) and `.` matches one code point. Set `.bytes = true`
to match raw bytes instead, as PCRE does without its UTF option:

```zig
var sig = try Regex.compileWithFlags(allocator, "MZ.{2}\\x80\\xff[\\x00-\\x1f]+", .{ .bytes = true });
defer sig.deinit();
_ = try sig.isMatch(file_bytes);
```

In byte mode:

- `\xHH` (one or two hex digits, none meaning NUL) and `\x{H..}` (up to `FF`)
  are one byte.
- `.` matches any single byte; without `dot_all` it excludes `\n` only.
- A raw byte in the pattern is its own atom, so `\xc3\xa9+` repeats `\xa9` only.
- Character classes are byte sets (`[\x80-\xff]`, `[^a]` matches one byte) and
  `\s`, `\S`, `\d`, `\w` and the POSIX classes are their ASCII forms.
- `case_insensitive` folds ASCII letters only.
- `^`, `$`, `\A`, `\z`, `\b` and `\B` work as in UTF-8 mode; bytes `>= 0x80`
  are not word bytes.
- `\p{..}`, `\P{..}` and `\u` escapes, and the `unicode`, `unicode_sets` and
  `ecmascript` flags, are rejected with `error.UnsupportedInBytesMode`.

### Allocation-Free Matching (`Program` and `Scratch`)

A `Program` is a compiled pattern flattened into one immutable byte blob, so
a single program can be shared read-only by every thread. All mutable
matching state (the lazy DFA cache, NFA thread lists) lives in a `Scratch`
that each thread creates once and reuses. Matching never allocates.

```zig
const regex = @import("regex");

var program = try regex.Program.compile(allocator, "MZ.{2}\\x50\\x45", .{ .bytes = true });
defer program.deinit(allocator);

// Once per thread. `Scratch.initBuffer` takes caller memory instead.
var scratch = try regex.Scratch.init(allocator, &program);
defer scratch.deinit(allocator);

_ = try program.isMatch(&scratch, data);           // bool
if (try program.find(&scratch, data)) |span| {     // ?Span{ start, end }
    _ = data[span.start..span.end];
}
var it = program.iterator(&scratch, data);         // every match, no allocation
while (try it.next()) |span| _ = span;
var spans: [64]regex.program.Span = undefined;
const n = try program.findAll(&scratch, data, &spans); // error.NoSpaceLeft if more
_ = n;
```

- `Program.fromRegex(allocator, &re)` flattens an already compiled `Regex`.
- Programs cover every pattern the Thompson engine runs. Patterns that need
  the backtracking engine (backreferences, general lookaround, scoped inline
  modifiers, Unicode property escapes) and ECMAScript mode return
  `error.UnsupportedByProgram`. `Program.compile` builds lazy repeats and
  repeated alternations (`(?:\x90|\xcc){4,}`, `a.+?b`) like their greedy
  forms: they only change which match end a backtracker reports, and program
  ends are leftmost-longest anyway.
- Results are spans without capture groups. Match ends follow the Thompson
  engine (the leftmost match, extended as far as possible). `Regex.find`
  agrees, except on its literal-alternation fast path, which reports the
  first alternative in source order (`a|ab` finds `a`).
- One scratch can serve several programs: size it with
  `Scratch.initCapacity(allocator, a.capacity().max(b.capacity()))`. A
  program larger than the scratch returns `error.ScratchTooSmall`.
- When a pattern's DFA outgrows the scratch's state cache, the cache resets
  and that call finishes on an NFA simulation of the same program, still in
  time linear in the input.

#### Bounding memory and time

Hostile input cannot make a scratch grow or a search run unbounded:

```zig
var capacity = program.capacity();
capacity.dfa_states = 256;                  // DFA state cap (default 1024, 0 = NFA only)
var scratch = try regex.Scratch.initCapacity(allocator, capacity);
scratch.step_budget = 1_000_000;            // per search; null = unlimited

const hit = program.isMatch(&scratch, data) catch |err| switch (err) {
    error.BudgetExceeded => return .limit_event, // never reported as "no match"
    else => return err,
};
```

- `Scratch.bytesNeeded(capacity)` is the exact size and is fixed when the
  scratch is made. For N program states, C byte classes and a cap of D DFA
  states it is at most `36N + 4D(C+1) + 4D(W+1) + 4H + 12W + 8` bytes, with
  `W = ceil(N/32)` and `H` the smallest power of two that is at least 16 and
  at least `2D` (`Scratch.boundFor`). With `D = 256` that is at most
  `36N + 1024(C + W + 2) + 12W + 2056` bytes.
- A step is one input byte the DFA reads or skips, or one unit of NFA work.
  The budget applies to each `isMatch`, `find` and `findFrom`, and to each
  match an iterator, `findAll` or `count` looks for. `scratch.steps` reports
  what the last search used, never more than the budget.
- The backtracking engine behind `Regex` has its own budget,
  `re.setStepBudget(n)` (default 10,000,000 steps); running out fails with
  `error.Timeout`.

#### Storing programs (serialisation)

A program's bytes are its serialised form: position independent (offsets,
no pointers), little-endian, versioned and protected by a CRC-32. Write them
into a file or a database section, then load them back without allocating:

```zig
const blob: []const u8 = program.bytes(); // store these bytes anywhere

// Later, for example over an mmapped region (any alignment):
const loaded = try regex.Program.load(mapped[offset..]); // borrows `mapped`
_ = try loaded.isMatch(&scratch, data);
// `loaded.bytes().len` is the program's length within the region;
// `loaded.dupe(allocator)` makes an owned copy.
```

`Program.load` checks the header, the version, the checksum and every
structural invariant matching relies on (section layout, edge ranges and
targets, byte-set indices, the byte-class map) and fails with
`error.Truncated`, `BadMagic`, `UnsupportedVersion`, `ChecksumMismatch` or
`InvalidProgram`, never with a fault. A loaded program borrows its bytes:
they must outlive it and stay unchanged.

### Required Literal Factors (prefilters)

`requiredFactors` reports literal strings every match must contain, so a
prefilter can skip the regex entirely when none of them is in the input:

```zig
if (try regex.requiredFactors(allocator, "foo(bar|baz)qux", .{}, .{ .min_len = 3 })) |found| {
    var f = found;
    defer f.deinit(allocator);
    // f.prefix = "fooba" (every match starts with it), f.suffix = "qux",
    // f.inner = factors found elsewhere in every match.
}
// Same analysis for a compiled regex: try re.requiredFactors(allocator, .{}).
```

- Each `Factor` has `bytes` and `case_folded`; a folded factor is lowercase
  and must be searched for ignoring ASCII case (from the `case_insensitive`
  flag, `(?i:...)`, or a class such as `[Ss]`).
- Factors are sound: every match contains them where they say. Alternation
  keeps what its branches share (`bar|baz` contributes `ba`), and anything
  that can repeat zero times or match an unknown character breaks a factor.
- In byte mode the factors are raw bytes (`\x80\xff` gives those two bytes).
- The result is null when no factor of at least `min_len` bytes (default 3)
  exists, as for `(a|b)*`.

## CLI

zig-regex includes a command-line tool:

```bash
# Find first match
regex '\d+' 'hello 123 world'
# Output: 123

# Find all matches
regex -g '\d+' 'hello 123 world 456'
# Output
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

- Zig 0.17.0-dev.1857 or later
- No external dependencies

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass (`zig build test`)
5. Submit a pull request

## Community

For help, discussion about best practices, or any other conversation that would benefit from being searchable:

[Discussions on GitHub](https://github.com/zig-utils/zig-regex/discussions)

For casual chit-chat with others using this package:

[Join the zig-utils Discord Server](https://discord.gg/f7wBym6JF2)

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Acknowledgments

Inspired by:

- Ken Thompson's NFA construction algorithm
- RE2 (Google's regex engine)
- Rust's regex crate

## Support

- [GitHub Issues](https://github.com/zig-utils/zig-regex/issues)

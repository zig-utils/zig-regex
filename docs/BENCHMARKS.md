# Benchmark Results

Performance benchmarks for the zig-regex library.

## Table of Contents

- [Overview](#overview)
- [Benchmark Results](#benchmark-results)
- [Performance Characteristics](#performance-characteristics)
- [Comparison Guidelines](#comparison-guidelines)
- [Running Benchmarks](#running-benchmarks)

---

## Overview

The zig-regex library is designed for **correctness first, performance second**. It uses Thompson NFA construction with thread-based simulation, which guarantees linear time complexity O(n×m) and prevents catastrophic backtracking.

### Test Environment

- **Zig Version:** 0.15.1
- **Build Mode:** ReleaseFast
- **Platform:** darwin (macOS)
- **Architecture:** Native
- **Date:** 2025-01-26

---

## Benchmark Results

All benchmarks run with 10,000 iterations unless otherwise noted.

### Core Operations

| Pattern | Input | Avg Time | Ops/sec | Description |
|---------|-------|----------|---------|-------------|
| `hello` | `hello world` | ~6.87 µs | ~145,000 | Simple literal match |
| `a+` | `aaaa` | ~5.50 µs | ~182,000 | Quantifier (one or more) |
| `\d+` | `12345` | ~5.01 µs | ~200,000 | Digit character class |
| `hello` (case-insensitive) | `HELLO` | ~4.62 µs | ~216,000 | Case-insensitive match |

### Detailed Results

```
=== Simple Regex Benchmarks ===

Test 1: Literal matching...
  10000 iterations in 68.74ms (6.87µs/op)

Test 2: Quantifiers (a+)...
  10000 iterations in 54.98ms (5.50µs/op)

Test 3: Digit matching (\d+)...
  10000 iterations in 50.14ms (5.01µs/op)

Test 4: Case-insensitive matching...
  10000 iterations in 46.23ms (4.62µs/op)

=== Benchmarks Complete ===
```

---

## Performance Characteristics

### Time Complexity

| Operation | Complexity | Notes |
|-----------|------------|-------|
| Compile | O(p) | p = pattern length |
| isMatch | O(n × m) | n = input length, m = NFA states |
| find | O(n × m × k) | k = starting positions attempted |
| findAll | O(n × m) | Amortized over all matches |
| replace | O(n + r) | r = replacement length |
| replaceAll | O(n × m + r) | Includes matching cost |
| split | O(n × m) | Plus array allocation |

### Space Complexity

| Component | Complexity | Notes |
|-----------|------------|-------|
| Compiled Regex (NFA) | O(p) | Persistent storage |
| VM Execution | O(m × c) | c = capture group count |
| Match Results | O(r) | r = number of results |
| Temporary (AST) | O(p) | Freed after compilation |

### Greedy Matching Performance

The library implements greedy matching by tracking the longest match:

```zig
// Pattern: a*
// Input: "aaa"
// Behavior: Matches all 3 'a's (not 0, 1, or 2)
```

This ensures standard regex behavior but requires exploring all possible match lengths.

---

## Pattern-Specific Performance

### Fast Patterns

These patterns tend to be fastest:

1. **Simple literals**: `hello`, `test`, `abc`
   - Direct character comparison
   - Minimal state transitions

2. **Character classes**: `\d`, `\w`, `\s`
   - Optimized predefined ranges
   - Single transition per match

3. **Anchored patterns**: `^start`, `end$`
   - Early termination on mismatch
   - Reduced search space

### Moderate Patterns

These patterns have moderate performance:

1. **Quantifiers**: `a+`, `b*`, `c?`
   - Multiple state exploration
   - Greedy matching overhead

2. **Bounded repetition**: `\d{3}`, `a{2,5}`
   - Explicit repetition counting
   - State explosion with large bounds

3. **Custom character classes**: `[a-z]`, `[0-9A-F]`
   - Range checking per character
   - Multiple range comparisons

### Slower Patterns

These patterns may be slower:

1. **Complex alternation**: `cat|dog|bird|fish`
   - Multiple NFA paths explored
   - State count increases with alternatives

2. **Nested quantifiers**: `(a+)+`, `(b*)*`
   - Exponential state growth possible
   - More threads in simulation

3. **Long patterns**: `very_long_literal_string`
   - More characters to compare
   - Larger NFA structures

---

## Optimization Tips

### 1. Compile Once, Use Many Times

```zig
// Good: Compile once
var regex = try Regex.compile(allocator, pattern);
defer regex.deinit();

for (inputs) |input| {
    _ = try regex.isMatch(input);
}

// Bad: Compile repeatedly
for (inputs) |input| {
    var regex = try Regex.compile(allocator, pattern);
    defer regex.deinit();
    _ = try regex.isMatch(input);
}
```

**Impact:** Compiling is ~100x more expensive than matching. Reusing compiled patterns is critical.

### 2. Use isMatch() for Boolean Checks

```zig
// Good: Only check if match exists
if (try regex.isMatch(input)) {
    // ...
}

// Less efficient: Extract match when not needed
if (try regex.find(input)) |match| {
    var mut_match = match;
    defer mut_match.deinit(allocator);
    // Not using match data...
}
```

**Impact:** `isMatch()` can terminate early and doesn't allocate for captures.

### 3. Anchor Patterns When Possible

```zig
// Good: Anchored (faster)
var regex = try Regex.compile(allocator, "^\\d+$");

// Slower: Unanchored (searches all positions)
var regex = try Regex.compile(allocator, "\\d+");
```

**Impact:** Anchored patterns reduce the number of starting positions to check.

### 4. Prefer Character Classes Over Alternation

```zig
// Good: Character class
var regex = try Regex.compile(allocator, "[abc]");

// Slower: Alternation
var regex = try Regex.compile(allocator, "a|b|c");
```

**Impact:** Character classes are optimized for range checking.

### 5. Simplify Patterns

```zig
// Good: Simple
var regex = try Regex.compile(allocator, "\\d+");

// Slower: Complex
var regex = try Regex.compile(allocator, "(\\d)(\\d)(\\d)+");
```

**Impact:** Simpler patterns have fewer NFA states and less overhead.

---

## Memory Usage

### Typical Memory Footprint

```
Pattern: "\\d{3}-\\d{4}"
  - Compilation: ~2 KB
  - NFA storage: ~1 KB (persistent)
  - VM execution: ~500 bytes per match attempt
  - Match result: ~100 bytes + captures
```

### Memory Optimization

1. **Reuse regex objects** - NFA is persistent
2. **Clean up matches** - Call `deinit()` on Match objects
3. **Free arrays** - `findAll()` and `split()` return owned memory
4. **Use arena allocators** - For batch operations

---

## Comparison Guidelines

### vs. Backtracking Engines (PCRE, Python re)

**Advantages:**
- ✅ **No catastrophic backtracking** - Always linear time
- ✅ **Predictable performance** - O(n×m) guaranteed
- ✅ **Memory safe** - No stack overflow on deep recursion

**Trade-offs:**
- ❌ **Slower on simple patterns** - More overhead for simple cases
- ❌ **No backreferences** - Not currently supported
- ❌ **No look-around** - Not currently supported

### vs. DFA Engines (RE2, ripgrep)

**Similarities:**
- ✅ **Linear time** - Both guarantee O(n×m)
- ✅ **No backtracking** - Deterministic matching

**Trade-offs:**
- ❌ **NFA simulation** - We don't build full DFA (saves memory)
- ❌ **Capture groups** - Our approach is simpler for captures
- ✅ **Memory usage** - Lower than full DFA construction

---

## Future Optimizations

### Planned Improvements

1. **Literal prefix extraction**
   - Use Boyer-Moore for initial search
   - Skip to potential match positions
   - Expected speedup: 2-10x on long inputs

2. **DFA construction option**
   - Build DFA for hot patterns
   - Cache DFA for reuse
   - Expected speedup: 3-5x on repeated patterns

3. **SIMD optimizations**
   - Vectorized character class matching
   - Parallel state transitions
   - Expected speedup: 2-4x on character classes

4. **State minimization**
   - Reduce redundant NFA states
   - Merge equivalent states
   - Expected speedup: 10-20% general

5. **JIT compilation**
   - Compile hot patterns to native code
   - Inline common operations
   - Expected speedup: 5-10x on very hot paths

---

## Running Benchmarks

### Basic Benchmark

```bash
# Run the simple benchmark suite
zig build bench
```

This will output timing results for common operations.

### Custom Benchmarks

Create your own benchmark file:

```zig
const std = @import("std");
const Regex = @import("regex").Regex;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Your pattern
    var regex = try Regex.compile(allocator, "your_pattern");
    defer regex.deinit();

    // Timing
    var timer = try std.time.Timer.start();
    const start = timer.read();

    const iterations: usize = 10000;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        _ = try regex.isMatch("your input");
    }

    const elapsed = timer.read() - start;
    const avg_ns = elapsed / iterations;
    const avg_us = @as(f64, @floatFromInt(avg_ns)) / 1000.0;

    std.debug.print("Average: {d:.2} µs/op\n", .{avg_us});
}
```

### Profiling

To profile the library:

```bash
# Build with debug symbols
zig build -Doptimize=ReleaseFast

# Run with profiler (macOS)
instruments -t "Time Profiler" ./zig-out/bin/benchmarks

# Or use perf (Linux)
perf record ./zig-out/bin/benchmarks
perf report
```

---

## Interpreting Results

### What Good Performance Looks Like

- **Simple patterns**: < 5 µs/op
- **Complex patterns**: < 20 µs/op
- **Very complex**: < 100 µs/op

### When to Worry

- **Matching slower than expected**: Check pattern complexity
- **Memory usage growing**: Ensure `deinit()` is called
- **Compile time high**: Pattern might be very complex

### Reporting Performance Issues

If you encounter unexpectedly slow performance:

1. Simplify the pattern - is it still slow?
2. Check input size - is it very large?
3. Measure compilation vs matching time
4. Create minimal reproduction case
5. Open an issue with benchmark code

---

## Real-World Performance

### Typical Use Cases

```
Email validation (1000 emails):     ~10ms  total
Log parsing (10,000 lines):         ~50ms  total
URL extraction (1MB of HTML):       ~200ms total
CSV splitting (100,000 rows):       ~300ms total
```

These are estimates. Actual performance depends on:
- Pattern complexity
- Input characteristics
- Hardware specifications
- Optimization level

---

**Last Updated:** 2025-01-26
**Version:** 0.1.0
**Zig Version:** 0.15.1

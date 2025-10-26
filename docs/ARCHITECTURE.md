# Architecture Documentation

## Overview

The zig-regex library implements a regular expression engine using **Thompson's NFA construction** algorithm combined with **thread-based simulation** for pattern matching. This architecture provides linear time complexity O(n*m) for matching, where n is the input length and m is the pattern size.

## Design Philosophy

1. **Zero Dependencies** - Uses only Zig's standard library
2. **Memory Safety** - Full allocator control, no hidden allocations
3. **Correctness First** - Focus on correct implementation before optimization
4. **Clean Separation** - Each phase (parsing, compilation, execution) is isolated
5. **Testability** - Every component is independently testable

## Component Architecture

```
┌─────────────────┐
│  User Input     │
│  Pattern String │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│     LEXER       │  ← Tokenizes pattern into tokens
│  (parser.zig)   │    (literals, operators, etc.)
└────────┬────────┘
         │ Tokens
         ▼
┌─────────────────┐
│     PARSER      │  ← Builds Abstract Syntax Tree
│  (parser.zig)   │    using recursive descent
└────────┬────────┘
         │ AST
         ▼
┌─────────────────┐
│   COMPILER      │  ← Thompson NFA Construction
│ (compiler.zig)  │    Converts AST → NFA
└────────┬────────┘
         │ NFA
         ▼
┌─────────────────┐
│   VIRTUAL       │  ← Thread-based simulation
│   MACHINE       │    Matches input against NFA
│   (vm.zig)      │
└────────┬────────┘
         │ Match Results
         ▼
┌─────────────────┐
│  Public API     │  ← High-level matching functions
│  (regex.zig)    │    find(), replace(), split()
└─────────────────┘
```

## Module Breakdown

### 1. common.zig (174 lines)
**Purpose:** Shared types and utilities

**Key Components:**
- `CharRange` - Represents a character range (e.g., 'a'-'z')
- `CharClass` - Set of character ranges with negation support
- `CharClasses` - Predefined classes (\d, \w, \s, etc.)
- `CompileFlags` - Future support for flags (i, m, s, x, u)
- `Span` - Source position for error reporting

**Design Notes:**
- Character classes use ranges for memory efficiency
- Negation handled at match time, not during construction

### 2. ast.zig (267 lines)
**Purpose:** Abstract Syntax Tree representation

**Node Types:**
```zig
pub const NodeType = enum {
    literal,      // Single character 'a'
    any,          // Wildcard '.'
    concat,       // Implicit concatenation 'ab'
    alternation,  // Choice 'a|b'
    star,         // Zero or more 'a*'
    plus,         // One or more 'a+'
    optional,     // Zero or one 'a?'
    repeat,       // Bounded 'a{m,n}'
    char_class,   // Character set '[a-z]'
    group,        // Capture group '(a)'
    anchor,       // Position assertion '^', '$', '\b'
    empty,        // Epsilon transition
};
```

**Key Features:**
- Tagged union for type-safe node data
- Recursive structure for nested expressions
- Memory management via allocator
- Span tracking for error messages

**Design Notes:**
- Each node owns its children (tree ownership)
- `destroy()` recursively frees the entire tree
- Factory methods ensure proper initialization

### 3. parser.zig (395 lines)
**Purpose:** Lexical analysis and parsing

**Architecture:**
```
Lexer (Tokenizer)
    │
    ├─ peek()     - Look at current char
    ├─ advance()  - Move to next char
    ├─ makeToken()- Create token
    └─ parseEscape() - Handle \ sequences

Parser (Recursive Descent)
    │
    ├─ parseAlternation()  (lowest precedence)
    ├─ parseConcat()
    ├─ parseRepeat()
    ├─ parsePrimary()      (highest precedence)
    └─ parseCharClass()
```

**Operator Precedence (high to low):**
1. Literals, groups, character classes
2. Quantifiers (*, +, ?, {m,n})
3. Concatenation (implicit)
4. Alternation (|)

**Design Notes:**
- Single-pass parsing
- Error recovery not implemented (fails fast)
- Lookahead limited to one token
- Character classes parsed separately

### 4. compiler.zig (455 lines)
**Purpose:** NFA construction via Thompson's algorithm

**NFA Components:**
```zig
pub const State = struct {
    id: StateId,
    transitions: ArrayList(Transition),
    is_accepting: bool,
    capture_start: ?usize,
    capture_end: ?usize,
};

pub const Transition = struct {
    transition_type: TransitionType,
    to: StateId,
    data: TransitionData,
};
```

**Thompson Construction Rules:**

| Pattern | NFA Fragment |
|---------|--------------|
| Literal 'a' | `s0 --a--> s1` |
| Concatenation 'ab' | `s0 --a--> s1 --ε--> s2 --b--> s3` |
| Alternation 'a\|b' | `s0 --ε--> (s1 --a--> s2)<br>&nbsp;&nbsp;&nbsp;&nbsp;└--ε--> (s3 --b--> s4)` |
| Star 'a*' | `s0 --ε--> s1 --a--> s2 --ε--> s1<br>&nbsp;&nbsp;&nbsp;&nbsp;└--ε--> accept` |

**Design Notes:**
- Each AST node compiles to a Fragment (start, accept states)
- Epsilon transitions used for control flow
- Greedy matching achieved through simulation order
- Capture groups marked on states, not transitions

### 5. vm.zig (340 lines)
**Purpose:** NFA simulation engine

**Thread-Based Simulation:**
```
Thread = {
    state: StateId,
    capture_starts: []?usize,
    capture_ends: []?usize,
}

Algorithm:
1. Start with one thread at start state
2. Compute epsilon closure
3. For each input character:
   a. For each thread, try all transitions
   b. Create new threads for matches
   c. Track longest match (greedy)
4. Return longest accepting match
```

**Key Features:**
- **Greedy Matching:** Continues matching to find longest match
- **Epsilon Closure:** Precomputed before consuming input
- **Capture Tracking:** Each thread maintains capture positions
- **No Backtracking:** All paths explored simultaneously

**Time Complexity:**
- O(n * m) where n = input length, m = number of states
- Worst case: O(n * 2^p) where p = number of alternations

**Space Complexity:**
- O(m * c) where m = states, c = capture groups
- Thread list grows with state complexity

**Design Notes:**
- Threads represent possible execution paths
- Visited states tracked to avoid infinite loops
- Anchors checked during epsilon closure
- Match preference: longer match > earlier match

### 6. regex.zig (385 lines)
**Purpose:** Public API and convenience functions

**API Surface:**
```zig
// Compilation
Regex.compile(allocator, pattern) -> Regex
regex.deinit()

// Matching
regex.isMatch(input) -> bool
regex.find(input) -> ?Match
regex.findAll(allocator, input) -> []Match

// Transformation
regex.replace(allocator, input, replacement) -> []u8
regex.replaceAll(allocator, input, replacement) -> []u8
regex.split(allocator, input) -> [][]const u8
```

**Design Notes:**
- Immutable compiled patterns (can reuse)
- All allocations explicit and user-controlled
- Match results contain slices (no copies)
- Iterator pattern not yet implemented

### 7. errors.zig (67 lines)
**Purpose:** Error types and reporting

**Error Types:**
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

**Error Context:**
- Position tracking in pattern
- Human-readable messages
- Pointer to error location

## Algorithms

### Thompson's NFA Construction

**Why Thompson?**
1. Simple to implement
2. Guaranteed linear time matching
3. No catastrophic backtracking
4. Naturally supports alternation

**How it works:**
1. Each regex operator has a standard NFA fragment pattern
2. Fragments compose recursively
3. Epsilon transitions connect fragments
4. Result is a single NFA with one start and one accept state

### Thread-Based Simulation

**Why Threads?**
- Simulates NFA without building DFA (space efficient)
- Handles large state spaces
- Natural support for captures

**Greedy Matching:**
- Continue simulation even after finding a match
- Keep longest match found
- Ensures `a*` matches "aaa" not ""

**Epsilon Closure:**
- Precompute all states reachable via ε-transitions
- Check anchors during closure
- Avoids redundant state exploration

## Memory Management

**Ownership Model:**
```
Regex
  └─ owns NFA
       └─ owns States
            └─ own Transitions

AST (temporary)
  └─ owns Nodes (recursively)

Matches
  └─ borrows input (slices)
  └─ owns capture array
```

**Allocation Points:**
1. Pattern string duplication
2. AST node creation (freed after compilation)
3. NFA states and transitions
4. VM threads during matching (freed each match)
5. Match results and captures

**Guidelines:**
- User provides allocator for all operations
- No hidden global allocations
- Clear ownership semantics
- defer patterns for cleanup

## Performance Characteristics

### Time Complexity

| Operation | Complexity | Notes |
|-----------|------------|-------|
| Compile | O(p) | p = pattern length |
| isMatch | O(n * m) | n = input, m = states |
| find | O(n * m * k) | k = positions to try |
| findAll | O(n * m) | Amortized |
| replace | O(n + r) | r = replacement length |
| split | O(n * m) | Plus allocation |

### Space Complexity

| Component | Complexity | Notes |
|-----------|------------|-------|
| AST | O(p) | Temporary |
| NFA | O(p) | Persistent |
| VM Threads | O(m * c) | c = captures |
| Matches | O(r) | r = result count |

### Optimization Opportunities

**Not Yet Implemented:**
1. DFA construction for static patterns
2. State minimization
3. Literal prefix extraction
4. Boyer-Moore-style searching
5. JIT compilation
6. SIMD for character classes

## Testing Strategy

**Test Categories:**
1. **Unit Tests** - Each module tested independently
2. **Integration Tests** - End-to-end pattern matching
3. **Edge Cases** - Empty strings, boundary conditions
4. **Compliance Tests** - Standard regex behaviors
5. **Property Tests** - Invariants (future)

**Current Coverage:**
- 35+ tests across all modules
- All basic features tested
- Edge cases covered
- No fuzzing yet

## Future Enhancements

### Phase 6: Quality & Testing
- Comprehensive fuzzing
- Property-based tests
- Performance regression tests
- Memory leak detection

### Phase 7: Performance
- DFA construction option
- Literal prefix optimization
- State minimization
- Benchmark suite

### Phase 8: Extended Features
- Named capture groups
- Backreferences
- Lookahead/lookbehind
- Conditional patterns
- Unicode properties

### Phase 9: API Improvements
- Iterator interface
- Streaming matches
- Partial matching
- Match options/flags

## References

**Algorithms:**
- Thompson, Ken (1968). "Regular Expression Search Algorithm"
- Cox, Russ (2007). "Regular Expression Matching Can Be Simple And Fast"

**Implementations:**
- RE2 (Google) - Inspiration for architecture
- Rust regex crate - API design reference
- PCRE - Feature completeness reference

## Contributing

When modifying the architecture:
1. Maintain phase separation
2. Keep allocations explicit
3. Preserve linear time guarantees
4. Add tests for new features
5. Update this document

---

**Last Updated:** 2025-01-26
**Zig Version:** 0.15.1
**Lines of Code:** ~2,300

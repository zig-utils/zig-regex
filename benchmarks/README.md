# Benchmarks

## findAll throughput vs the Rust `regex` crate

Mirrors the methodology from [issue #10](https://github.com/zig-utils/zig-regex/issues/10):
count all matches of a pattern in a ~1.17 MB synthetic haystack, timing only the
search (compile, stdin read, and process startup excluded).

### Run it

```sh
# Zig-only table (compile / single find / findAll):
zig build bench-findall

# Stdin mode — same program the comparison uses (prints "total iters elapsed_ns"):
zig-out/bin/findall_bench gen > haystack.txt          # deterministic ~1.17 MB
zig-out/bin/findall_bench 'hello' 50 < haystack.txt

# Head-to-head against the Rust regex crate (needs cargo):
./benchmarks/compare.sh 50
```

`benchmarks/rust-bench/` is the Rust counterpart (uses `regex::find_iter`), built
with `--release` + LTO. `compare.sh` generates one haystack and feeds it to both
binaries so the comparison is apples-to-apples.

### Results (Apple M4, Zig 0.16, regex crate 1.x, 50 iterations)

Time per scan of the 1.17 MB haystack, counting all matches — `Regex.count`
(zig) vs `find_iter().count()` (rust): both lazy, allocation-free, so it's an
apples-to-apples comparison. The "#10 baseline" column is the original numbers
from the issue (which used the allocating `findAll`); "ratio" is zig ÷ rust
(< 1.0 means zig is faster).

| pattern               | zig `count` | rust | ratio |
|-----------------------|--------:|-----:|------:|
| `hello`               |  0.30 ms | 0.44 ms | **0.68x** |
| `hello\|world\|test`  |  2.1 ms | 2.8 ms | **0.76x** |
| `\d+`                 |  1.0 ms | 3.3 ms | **0.31x** |
| `\w+`                 |  1.8 ms | 4.6 ms | **0.39x** |
| `[A-Za-z]+`           |  2.1 ms | 5.0 ms | **0.41x** |
| `\d{1,3}`             |  1.1 ms | 3.4 ms | **0.31x** |
| `foo[0-9]+`           |  0.70 ms | 0.83 ms | **0.85x** |
| `\w+[0-9]`            |  3.9 ms | 4.2 ms | **0.92x** |
| `([a-z]+)([0-9]+)`    |  3.5 ms | 2.9 ms | 1.24x |
| `a.c`                 |  1.1 ms | 0.89 ms | 1.28x |

(`Regex.count` vs `find_iter().count()` — both lazy & allocation-free, best of 3
runs. Match counts verified identical.) The original #10 baseline (allocating
`findAll`) was 13–118x **slower** than Rust; the engine is now **faster on 8 of
these 10 patterns** (down to ~0.31x) and within ~1.3x on the rest. Single `find`
is a few nanoseconds. `findAll` materializes a `Match[]`, so use `count` when you
only need the tally. Numbers vary by machine; run `compare.sh` for your own.

The remaining `~1.25x` cases (`a.c`, `([a-z]+)([0-9]+)`) are already O(n) — the gap
is pure constant factor in the per-byte DFA step vs Rust's hand-tuned compiled
DFA (byte-class tables, Teddy SIMD, 4× loop unrolling). At this scale (tiny DFAs)
byte classes would add a load rather than save one, so the gain isn't worth the
complexity; it's within run-to-run noise.

Case-insensitive search is also fast-pathed: `(?i)hello` via the global flag
counts in ~0.4 ms (≈3x faster than Rust), and `[a-z]+`/`\w+`/`\d+` keep the byte
loop under the `i` flag.

### What changed

A series of fast paths that recognize common pattern shapes and bypass the NFA,
plus allocation cuts in the VM:

- **Exact-literal fast path.** A fixed-string pattern (`hello`) becomes a
  substring search via a SIMD first-byte scan (`indexOfScalarPos`) + tail compare.
- **Repeated-atom fast path.** A single greedy-repeated byte atom (`\w+`, `\d+`,
  `[a-z]+`, `a+`, `x{2,5}`) is matched by a tight byte loop over maximal runs of a
  membership table — no NFA. This is what made `\d+`/`\w+` match/beat Rust.
- **Literal-alternation fast path.** `foo|bar|baz` tries each literal directly
  (longest wins) at first-byte-set candidates instead of running the NFA.
- **First-byte-set prefilter.** When matches must begin with one of a known byte
  set, the search skips positions whose byte can't start a match (generalizes the
  single literal-prefix filter).
- **VM allocation cuts.** The epsilon-closure `visited` bitmap and the two thread
  lists are allocated once per VM and reused across positions; capture-less
  threads allocate nothing. `findAll` reuses a single VM.
- **`Regex.count`** — allocation-free match counting (no `Match[]`, no capture
  slices), reusing every fast path and a single VM. The benchmark uses it for the
  head-to-head, matching Rust's lazy `find_iter().count()`.
- **Lazy DFA** (`src/dfa.zig`) — for general patterns that don't hit a fast path,
  `count`/`isMatch` run a DFA built on demand (each state is a set of NFA states;
  each byte is a cached table lookup) instead of per-byte thread simulation. Used
  only where longest-match equals the engine's semantics: all-greedy, no anchors /
  `\b`, ASCII-exact; falls back to the NFA otherwise or if the DFA would exceed its
  state cap. This took general patterns from 7–51x slower to ~1–2x:

  | pattern | before | after | rust | ratio |
  |---|--:|--:|--:|--:|
  | `foo[0-9]+`  | ~5.8 ms | ~1.3 ms | ~0.7 ms | 1.8x |
  | `ba[rz][0-9]+` | ~12 ms | ~1.4 ms | ~1.3 ms | 1.1x |
  | `\w+[0-9]`   | ~145 ms | ~6.7 ms | ~2.9 ms | 2.3x |
  | `a.c`        | —       | ~0.8 ms | ~0.6 ms | 1.3x |

- **Required-literal fast-fail.** If a mandatory literal substring (one outside
  `?`/`*`/alternation) is absent, there's no match — return immediately. Works for
  every engine; e.g. `(\d+)-(\d+)` on dash-free input went ~2.5 ms → ~20 µs.
- **Leading-class run-skip.** When a pattern starts with an unbounded class
  (`\w+…`), a failed anchored match skips that class's whole run (no start within
  it can match), removing O(word²) rescans.
- **SIMD single-byte prefilter + flat DFA table.** When the first-byte set is a
  single byte, candidates are found with a SIMD `indexOfScalar`; the lazy DFA uses
  a flat `state*256+byte` transition table with a cached hot loop. Took `a.c` to
  parity and `\w+[0-9]` from ~1.9x to ~1.3–1.5x.
- **One-pass capture plan** (`src/onepass.zig`) — disjoint-boundary atom sequences
  (`(\w+)@(\w+)`, `([a-z]+)([0-9]+)`) extract captures with a deterministic byte
  walk, differential-tested against the NFA.
- **Case-insensitive fast paths** — exact-literal (SIMD dual-case scan) and folded
  repeated-atom tables, so the `i` flag keeps the fast loop.
- **UTF-8 byte automaton for `\s`/Unicode class-sets** (`src/utf8_class.zig`).
  `\s`/`\S` (and `/v` Unicode bracket sets) match code points, not bytes, so they
  used to force the whole pattern onto the backtracker — a pattern like
  `\w+\s+\w+` fell off the DFA the instant a `\s` appeared (~45 ms vs ~2 ms for
  `\w+`). They now lower to an alternation of UTF-8 byte-range sequences
  (the classic utf8-ranges decomposition), so `\w+\s+\w+` stays on the lazy DFA
  end-to-end: ~45 ms → ~3 ms (faster than the Rust `regex` crate on the same
  haystack), with multi-byte whitespace still matched correctly.
- **The benchmark uses the release-grade SMP allocator** (not a debug allocator),
  for a fair comparison with Rust's global allocator.

All fast paths and the DFA preserve the engine's exact match semantics (verified
by the full test suite, including count-vs-findAll cross-checks) and fall back to
the NFA whenever they don't apply (captures, case-insensitive, lazy/nullable
quantifiers, anchors, lookaround, Unicode property classes, …).

`find`/`findAll` also use the lazy DFA now for capture-free general patterns —
the DFA gives the match bounds directly, no NFA pass. e.g. `findAll` of
`\w+[0-9]` over the 1.17 MB haystack dropped from ~145 ms (NFA) to ~9 ms.

- **One-pass capture plan** (`src/onepass.zig`) — for capture patterns that are a
  concatenation of disjoint-boundary atoms (`(\w+)@(\w+)`, `(\d+)-(\d+)`,
  `([a-z]+)([0-9]+)`, `(foo)(\d+)`), `find`/`findAll` extract captures with a
  deterministic greedy byte walk per atom — no NFA. Eligibility requires that
  each variable atom's byte set is disjoint from the next, which makes greedy
  matching provably backtrack-free. A differential test cross-checks the plan
  against `vm.matchAt` over many patterns/inputs/positions. `findAll` captures:
  `([a-z]+)([0-9]+)` ~55 ms → ~18 ms, `(foo)([0-9]+)` ~12 ms → ~1.8 ms (vs ~260 ms
  originally).

### What's left

Capture patterns *outside* the one-pass shape (alternation, overlapping
boundaries, nullable atoms) still use the NFA. A general tagged/one-pass DFA
would cover those. Beyond that: **Teddy-style SIMD multi-literal prefilters** and
a zero-allocation `findAll`-style iterator.

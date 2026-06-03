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

`findAll` time per scan of the 1.17 MB haystack. The "#10 baseline" column is the
original numbers from the issue; "ratio" is zig-now ÷ rust (< 1.0 means zig is
faster).

| pattern            | matches | #10 baseline | zig now | rust | ratio |
|--------------------|--------:|------------:|--------:|-----:|------:|
| `hello`            |  22,202 |      ~60 ms |  ~0.6 ms | ~0.7 ms | **0.8x** |
| `hello\|world\|test` |  66,631 |     ~173 ms | ~2.8 ms | ~2.3 ms  | 1.2x |
| `\d+`              |  66,651 |      ~83 ms | ~1.7 ms | ~2.8 ms  | **0.6x** |
| `\w+`              | 200,000 |      ~83 ms | ~4.7 ms | ~4.6 ms  | 1.2x |

From 13–118x slower at the time of #10 to **0.6–1.2x** — faster than the Rust
regex crate on `hello` and `\d+`, near parity on the rest. Single `find` is now a
few nanoseconds. Numbers vary by machine; run `compare.sh` for your own.

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
- **The benchmark uses the release-grade SMP allocator** (not a debug allocator),
  for a fair comparison with Rust's global allocator.

All fast paths preserve the engine's exact match semantics (verified by the full
test suite) and fall back to the NFA whenever they don't apply (captures,
case-insensitive, lazy/nullable quantifiers, lookaround, Unicode classes, …).

### What's left

The fast paths cover the common shapes; arbitrary patterns that don't match one
still run the Thompson NFA (`matchAt` per position). Pushing those to Rust's level
needs a **lazy DFA** and **Teddy-style SIMD multi-literal prefilters**, plus a
**zero-allocation match iterator** for counting. Tracked as the #10 roadmap.

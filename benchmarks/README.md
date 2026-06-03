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
original numbers from the issue.

| pattern            | matches | #10 baseline | zig now | rust | ratio now |
|--------------------|--------:|------------:|--------:|-----:|------:|
| `hello`            |  22,202 |      ~60 ms |  ~3.2 ms | ~0.42 ms | ~8x |
| `hello\|world\|test` |  66,631 |     ~173 ms | ~19 ms  | ~2.4 ms  | ~8x |
| `\d+`              |  66,651 |      ~83 ms | ~12 ms  | ~3.0 ms  | ~4x |
| `\w+`              | 200,000 |      ~83 ms | ~55 ms  | ~4.2 ms  | ~13x |

Numbers vary by machine; run `compare.sh` for your own.

### What changed

Successive rounds have closed most of the gap #10 reported (e.g. literal
`findAll` ~118x → ~8x):

- **Exact-literal fast path.** A fixed-string pattern (`hello`) skips the NFA
  entirely and runs a plain `std.mem.indexOf` substring search.
- **First-byte-set prefilter.** When every match must start with one of a known
  set of bytes (literal alternations, `\d+`, …), the search skips positions whose
  byte can't start a match — generalizes the single literal-prefix filter and is
  what dropped `hello|world|test` (~55x → ~8x) and `\d+` (~20x → ~4x).
- **Single VM + literal-prefix prefilter in `findAll`** (previously it re-ran the
  NFA at every byte).
- **Allocation cuts in the VM.** The epsilon-closure `visited` bitmap and the two
  thread lists are allocated once per VM and reused across positions; threads with
  no capture groups allocate nothing.
- **The benchmark uses the release-grade SMP allocator** (not a debug allocator),
  for a fair comparison with Rust's global allocator.

### What's left

The remaining gap is dense-match patterns like `\w+` (matches almost everywhere,
so prefilters don't help) — that's the per-byte NFA simulation cost. Matching Rust
there needs the techniques its engine uses:

1. **Lazy DFA** — compile NFA→DFA states on demand for byte-at-a-time scanning
   with no per-step thread bookkeeping. Biggest remaining win for `\w+` / `\d+`.
2. **Multi-literal / SIMD prefilters (Teddy)** — further accelerate literal
   alternations.
3. **Zero-allocation match iterator / `count`** — avoid materializing a `Match`
   per result when only counting/iterating.

These are tracked as the performance roadmap for #10.

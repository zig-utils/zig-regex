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

| pattern            | matches | zig ms/iter | rust ms/iter | ratio |
|--------------------|--------:|------------:|-------------:|------:|
| `hello`            |  22,202 |        ~6.7 |         ~0.42 | ~16x |
| `hello\|world\|test` |  66,631 |       ~132  |         ~2.4  | ~55x |
| `\d+`              |  66,651 |        ~60  |         ~3.0  | ~20x |
| `\w+`              | 200,000 |        ~68  |         ~4.2  | ~16x |

Numbers vary by machine; run `compare.sh` for your own.

### What changed (and what's left)

Recent work closed a large part of the gap that #10 reported:

- **Literal `findAll` went from ~118x → ~16x.** `findAll` now reuses a single VM
  and applies the literal-prefix prefilter (`std.mem.indexOf`) that `find`
  already used — previously it re-ran the NFA at every byte.
- **Per-match allocation cut.** The epsilon-closure `visited` bitmap is allocated
  once per VM and reused across positions instead of per `matchAt`.

The remaining gap on non-literal / multi-match workloads is **architectural**, and
matching Rust here needs the same techniques its engine uses:

1. **Single-pass (Pike) VM.** Today `find` runs `matchAt` from every start
   position — O(n²) on patterns that match densely (`\w+`, `\d+`). A leftmost
   unanchored single pass is O(n·states) and is the biggest remaining win.
2. **Lazy DFA.** Compile NFA→DFA states on demand for byte-at-a-time scanning
   with no per-step thread bookkeeping.
3. **Multi-literal / SIMD prefilters (Teddy).** Accelerates literal alternations
   like `hello|world|test`, which have no single prefix today.

These are tracked as the performance roadmap for #10.

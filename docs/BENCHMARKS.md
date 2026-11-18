# Benchmarks

Measured throughput and memory for the multi-literal matchers in
`src/literals` and for byte-mode regex programs, so that engine and prefilter
choices in zig-anti-virus and zig-waf rest on data. Every number below comes
from one command:

```sh
zig build bench                 # multi-literal matchers and byte-mode regex programs
benchmarks/pcre2/compare.sh     # the same regex patterns and corpora through PCRE2
```

Inputs are generated from fixed seeds, so the same command produces the same
bytes on every machine. The suite lives in `benchmarks/suite/`; the pattern
sets are `benchmarks/suite/patterns/clamav.txt` and `crs.txt`. Other,
narrower benchmarks (`bench-literals`, `bench-scratch`, `bench-findall`, the
ripgrep comparison) are described in [benchmarks/README.md](../benchmarks/README.md).

## Environment

| | |
|---|---|
| Machine | Apple M3 Pro (5 performance and 6 efficiency cores), 18 GiB, macOS 27.2.1 (Darwin arm64) |
| Toolchain | Zig 0.17.0-dev.1857+3c46da14d, every benchmark built ReleaseFast |
| Library | zig-regex f8ddb54 (`fix(program): compile capture groups inside alternations as programs`), with the suite committed alongside this file |
| PCRE2 | 10.47 (2025-10-21) from `pantry install`, statically linked, `cc -O2`, JIT and interpreter |
| Date | 2026-11-18 |

The machine is a shared development box. Both runs were taken while it was
nearly idle (one-minute load average 6 at the start, under 20 at the end), and
every figure is the best of several passes, but treat differences under about
10 percent as noise. An earlier run of the literal suite under similar load
agreed with these figures to within that.

Memory is measured from outside the process with the process mode of
[zig-benchmarks](https://github.com/zig-utils/zig-benchmarks) 0.2.2. On macOS
it reads `proc_pid_rusage`: resident size, and `phys_footprint` as private
dirty memory (dirty plus compressed pages, what the kernel charges the
process for). Linux has no footprint figure; there the same suite reports
`/proc/<pid>/smaps_rollup` Private_Dirty. Peak RSS is the kernel's high-water
mark from `wait4`.

## Multi-literal matchers

Each set size runs on two corpora of 16 MiB:

- **text**: words from a small English list, separated by spaces and
  newlines; literals are random lowercase strings.
- **binary**: executable-like data (zero padding, high-entropy runs, ASCII
  strings, little-endian integer tables, 0xcc/0x90 padding); literals are
  random bytes, 0x00 and 0xff included.

Literals are 12 to 24 bytes, and one literal of the set is planted about every
4 KiB, so every matcher has real hits to report. The columns:

- **Build**: wall time to build the structure from the literal list.
- **Blob**: the serialised structure, which is also what a loaded matcher
  occupies: it is searched in place, mmapped or not.
- **Build peak**: peak RSS of a process that builds the structure, minus that
  of a process holding only the inputs: the builder's transient memory.
- **GB/s**: 10^9 bytes per second over the corpus, best of at least three
  passes and 0.3 s. Teddy and Aho-Corasick report every match, overlapping
  ones included; the Bloom prefilter reports candidate positions, which a
  verifier then has to check.
- **Hits**: matches, or candidates for the Bloom prefilter.
- **Mapped RSS / dirty**: resident and private dirty memory of a process that
  mmaps the serialised structure read-only and scans the corpus with it,
  minus those of a process holding only the corpus.

Teddy holds at most 64 literals by design (eight buckets of a 3-byte
fingerprint), so it, and the naive one-pass-per-literal baseline, stop at 64.
The dense Aho-Corasick layout is skipped when its full DFA would exceed 256 MiB
(one row of up to 256 `u32` targets per trie node).

### Text corpus (lowercase literals, English-like text)

| Literals | Matcher | Build | Blob | Build peak | GB/s | Hits | Mapped RSS | Mapped dirty |
|---:|---|---:|---:|---:|---:|---:|---:|---:|
| 8 | naive (one pass per literal) | - | - | - | 0.49 | 4090 | - | - |
| 8 | Teddy | 15 us | 456 B | 112 KiB | 5.30 | 4090 | 80.0 KiB | 0 B |
| 8 | Aho-Corasick dense | 52 us | 22.1 KiB | 272 KiB | 0.72 | 4090 | 80.0 KiB | 0 B |
| 8 | Aho-Corasick sparse | 38 us | 7.73 KiB | 272 KiB | 0.29 | 4090 | 64.0 KiB | 0 B |
| 8 | Bloom, stride 1 | 1 us | 96 B | 112 KiB | 0.82 | 4090 | 96.0 KiB | 0 B |
| 8 | Bloom, stride 4 | 2 us | 128 B | 112 KiB | 3.56 | 6546 | 96.0 KiB | 0 B |
| 8 | Bloom, stride 8 | 3 us | 192 B | 112 KiB | 7.07 | 4403 | 96.0 KiB | 0 B |
| 64 | naive (one pass per literal) | - | - | - | 0.06 | 4090 | - | - |
| 64 | Teddy | 17 us | 2.26 KiB | 112 KiB | 0.69 | 4090 | 80.0 KiB | 0 B |
| 64 | Aho-Corasick dense | 108 us | 152 KiB | 576 KiB | 0.71 | 4090 | 208 KiB | 0 B |
| 64 | Aho-Corasick sparse | 106 us | 48.9 KiB | 480 KiB | 0.30 | 4090 | 112 KiB | 0 B |
| 64 | Bloom, stride 1 | 7 us | 192 B | 128 KiB | 0.82 | 21372 | 96.0 KiB | 0 B |
| 64 | Bloom, stride 4 | 10 us | 576 B | 144 KiB | 3.50 | 5781 | 96.0 KiB | 0 B |
| 64 | Bloom, stride 8 | 20 us | 1.06 KiB | 176 KiB | 6.94 | 5024 | 96.0 KiB | 0 B |
| 1k | naive (one pass per literal) | n/a (at most 64 literals) | | | | | | |
| 1k | Teddy | n/a (at most 64 literals) | | | | | | |
| 1k | Aho-Corasick dense | 2.1 ms | 2.28 MiB | 3.86 MiB | 0.60 | 4090 | 2.33 MiB | 0 B |
| 1k | Aho-Corasick sparse | 2.1 ms | 668 KiB | 2.30 MiB | 0.22 | 4090 | 720 KiB | 0 B |
| 1k | Bloom, stride 1 | 48 us | 2.03 KiB | 192 KiB | 0.70 | 134452 | 96.0 KiB | 0 B |
| 1k | Bloom, stride 4 | 184 us | 7.84 KiB | 240 KiB | 3.52 | 39320 | 96.0 KiB | 0 B |
| 1k | Bloom, stride 8 | 383 us | 15.6 KiB | 256 KiB | 6.83 | 28577 | 96.0 KiB | 0 B |
| 100k | naive (one pass per literal) | n/a (at most 64 literals) | | | | | | |
| 100k | Teddy | n/a (at most 64 literals) | | | | | | |
| 100k | Aho-Corasick dense | 675.1 ms | 208 MiB | 298 MiB | 0.54 | 4090 | 208 MiB | 96.1 KiB |
| 100k | Aho-Corasick sparse | 604.0 ms | 54.4 MiB | 151 MiB | 0.16 | 4090 | 54.4 MiB | 32.0 KiB |
| 100k | Bloom, stride 1 | 6.2 ms | 176 KiB | 928 KiB | 0.81 | 560762 | 256 KiB | 0 B |
| 100k | Bloom, stride 4 | 29.2 ms | 521 KiB | 2.97 MiB | 3.57 | 450493 | 608 KiB | 0 B |
| 100k | Bloom, stride 8 | 61.7 ms | 738 KiB | 5.00 MiB | 6.76 | 329140 | 832 KiB | 0 B |
| 400k | naive (one pass per literal) | n/a (at most 64 literals) | | | | | | |
| 400k | Teddy | n/a (at most 64 literals) | | | | | | |
| 400k | Aho-Corasick dense | n/a (dense DFA over the size cap) | | | | | | |
| 400k | Aho-Corasick sparse | 3.49 s | 212 MiB | 589 MiB | 0.14 | 4090 | 212 MiB | 112 KiB |
| 400k | Bloom, stride 1 | 30.4 ms | 521 KiB | 2.69 MiB | 0.80 | 1632246 | 608 KiB | 0 B |
| 400k | Bloom, stride 4 | 130.5 ms | 866 KiB | 9.66 MiB | 3.53 | 740373 | 960 KiB | 0 B |
| 400k | Bloom, stride 8 | 283.4 ms | 892 KiB | 24.6 MiB | 6.79 | 380446 | 976 KiB | 0 B |

### Binary corpus (any-byte literals, executable-like data)

| Literals | Matcher | Build | Blob | Build peak | GB/s | Hits | Mapped RSS | Mapped dirty |
|---:|---|---:|---:|---:|---:|---:|---:|---:|
| 8 | naive (one pass per literal) | - | - | - | 0.56 | 3808 | - | - |
| 8 | Teddy | 3 us | 432 B | 112 KiB | 11.30 | 3808 | 80.0 KiB | 0 B |
| 8 | Aho-Corasick dense | 29 us | 71.1 KiB | 320 KiB | 0.72 | 3808 | 128 KiB | 0 B |
| 8 | Aho-Corasick sparse | 17 us | 12.9 KiB | 272 KiB | 1.30 | 3808 | 64.0 KiB | 0 B |
| 8 | Bloom, stride 1 | 1 us | 96 B | 112 KiB | 0.83 | 3957 | 96.0 KiB | 0 B |
| 8 | Bloom, stride 4 | 2 us | 128 B | 112 KiB | 3.58 | 6528 | 96.0 KiB | 0 B |
| 8 | Bloom, stride 8 | 3 us | 192 B | 112 KiB | 7.10 | 5265 | 96.0 KiB | 0 B |
| 64 | naive (one pass per literal) | - | - | - | 0.07 | 3819 | - | - |
| 64 | Teddy | 41 us | 2.30 KiB | 112 KiB | 2.12 | 3819 | 80.0 KiB | 0 B |
| 64 | Aho-Corasick dense | 258 us | 1.14 MiB | 1.56 MiB | 0.72 | 3819 | 1.20 MiB | 0 B |
| 64 | Aho-Corasick sparse | 146 us | 167 KiB | 592 KiB | 0.38 | 3819 | 224 KiB | 0 B |
| 64 | Bloom, stride 1 | 3 us | 192 B | 128 KiB | 0.83 | 14962 | 96.0 KiB | 0 B |
| 64 | Bloom, stride 4 | 10 us | 576 B | 160 KiB | 3.58 | 8386 | 96.0 KiB | 0 B |
| 64 | Bloom, stride 8 | 17 us | 1.06 KiB | 176 KiB | 7.09 | 6297 | 96.0 KiB | 0 B |
| 1k | naive (one pass per literal) | n/a (at most 64 literals) | | | | | | |
| 1k | Teddy | n/a (at most 64 literals) | | | | | | |
| 1k | Aho-Corasick dense | 8.4 ms | 17.2 MiB | 18.8 MiB | 0.26 | 3819 | 17.3 MiB | 0 B |
| 1k | Aho-Corasick sparse | 1.9 ms | 1.62 MiB | 3.27 MiB | 0.16 | 3819 | 1.67 MiB | 0 B |
| 1k | Bloom, stride 1 | 42 us | 2.03 KiB | 192 KiB | 0.83 | 18940 | 96.0 KiB | 0 B |
| 1k | Bloom, stride 4 | 185 us | 7.88 KiB | 240 KiB | 3.47 | 8311 | 96.0 KiB | 0 B |
| 1k | Bloom, stride 8 | 375 us | 15.7 KiB | 256 KiB | 6.82 | 5863 | 96.0 KiB | 0 B |
| 100k | naive (one pass per literal) | n/a (at most 64 literals) | | | | | | |
| 100k | Teddy | n/a (at most 64 literals) | | | | | | |
| 100k | Aho-Corasick dense | n/a (dense DFA over the size cap) | | | | | | |
| 100k | Aho-Corasick sparse | 676.7 ms | 59.7 MiB | 162 MiB | 0.06 | 3809 | 59.7 MiB | 32.0 KiB |
| 100k | Bloom, stride 1 | 6.2 ms | 195 KiB | 928 KiB | 0.78 | 23689 | 288 KiB | 0 B |
| 100k | Bloom, stride 4 | 27.5 ms | 781 KiB | 2.97 MiB | 3.18 | 10160 | 864 KiB | 0 B |
| 100k | Bloom, stride 8 | 60.3 ms | 1.52 MiB | 5.00 MiB | 6.01 | 8051 | 1.61 MiB | 0 B |
| 400k | naive (one pass per literal) | n/a (at most 64 literals) | | | | | | |
| 400k | Teddy | n/a (at most 64 literals) | | | | | | |
| 400k | Aho-Corasick dense | n/a (dense DFA over the size cap) | | | | | | |
| 400k | Aho-Corasick sparse | 3.38 s | 232 MiB | 634 MiB | 0.04 | 3809 | 232 MiB | 128 KiB |
| 400k | Bloom, stride 1 | 27.1 ms | 781 KiB | 2.69 MiB | 0.72 | 29512 | 864 KiB | 0 B |
| 400k | Bloom, stride 4 | 121.4 ms | 3.05 MiB | 9.66 MiB | 3.08 | 16843 | 3.14 MiB | 16.0 KiB |
| 400k | Bloom, stride 8 | 257.8 ms | 6.09 MiB | 24.6 MiB | 5.76 | 14659 | 6.17 MiB | 16.0 KiB |

### What the numbers say

- **Up to 64 literals, Teddy.** 11.3 GB/s for 8 binary literals and 5.3 GB/s
  for 8 lowercase ones, 11 to 30 times the naive pass per literal. It slows
  with the candidate rate, not the set size as such: 64 lowercase literals
  have 3-byte fingerprints that English trigrams hit constantly (0.69 GB/s),
  while 64 binary ones still run at 2.1 GB/s. The blob is under 3 KiB.
- **Dense Aho-Corasick is flat until it leaves the cache.** One dependent load
  per byte gives 0.5 to 0.7 GB/s from 8 to 100k text literals, whatever the
  input. Its size is the catch: 208 MiB at 100k text literals and 17 MiB at
  only 1k binary ones (any-byte literals need all 256 byte classes, so a row
  is 1 KiB), where throughput drops to 0.26 GB/s. Past the 256 MiB cap
  (400k text, 100k binary) it is not built.
- **Sparse Aho-Corasick is the only exact matcher for the large sets, and it
  is slow there.** 0.14 GB/s on 400k text literals and 0.04 GB/s (40 MB/s) on
  400k binary ones, with a 232 MiB blob, a 3.4 s build and a 634 MiB build
  peak. On binary input every byte value starts some literal and failure
  walks dominate. It is fast only while the input rarely leaves the root
  (1.3 GB/s for 8 binary literals).
- **The Bloom prefilter's speed does not depend on the set size.** about 0.8, 3.5
  and 7 GB/s at strides 1, 4 and 8 from 8 to 100k literals, still 0.72,
  3.08 and 5.76 GB/s at 400k binary literals, where the filter (0.8 to
  6.1 MiB) no longer fits in cache. At 400k binary literals stride 1 reports
  29.5k candidates for 3.8k planted hits, about 0.15 percent of positions;
  strides 4 and 8 report 16.8k and 14.7k, each a window of 4 or 8 start
  positions for the verifier.
- **4-byte grams of lowercase text are not selective.** There are only 26^4
  = 457k of them, so from 1k text literals on the filter holds most grams
  English produces: 134k candidates at 1k and 1.6M at 400k (stride 1), against
  4k true hits. A phrase list over text wants Aho-Corasick; the Bloom
  prefilter wants high-entropy anchors such as binary signature bytes.
- **Searching in place costs clean pages only.** For every structure the
  mapped dirty column is zero to within a few pages (at most 128 KiB, against
  blobs up to 232 MiB), and mapped RSS tracks the part of the blob the scan
  touches: all of it for Aho-Corasick, whose states the input visits
  everywhere, and a page floor of 64 to 96 KiB for blobs smaller than that.
  Several scanner processes mapping one file share those pages.
- **Builders need two to three times the blob, transiently.** Sparse
  Aho-Corasick peaks at 589 to 634 MiB for 212 to 232 MiB blobs; the Bloom
  builder sorts every gram, so stride 8 at 400k peaks at 24.6 MiB for a
  6.1 MiB filter. Building offline and shipping the blob avoids paying this
  on the scanning host.

For zig-anti-virus this points at Teddy for small literal sets and a Bloom
prefilter at stride 4 or 8 over signature anchors, with a verifier behind it,
for the 100k to 400k range, rather than one Aho-Corasick automaton over every
signature. For zig-waf phrase lists over text, dense Aho-Corasick fits up to
about 100k phrases.

## Byte-mode regex against PCRE2

Each pattern is compiled with `CompileFlags.bytes` into a `Program` and counts
its non-overlapping matches over an 8 MiB corpus with one `Scratch`; PCRE2
compiles the same pattern without UTF (so the subject is bytes too) and runs
the same count loop. The ClamAV-style set runs over the executable-like
corpus and the CRS-style set over generated HTTP requests; each pattern's
sample match is planted about every 4 KiB. **Program** is the serialised
program and **Scratch** the scratch's whole allocation (default 1024-state DFA
cap). MB/s is 10^6 bytes per second, best of at least three passes and 1 s.
Match
counts agree with PCRE2 on every pattern; programs report leftmost-longest
matches and PCRE2 leftmost-first ones, and these patterns do not tell the two
apart.

### ClamAV-style signatures (`clamav.txt`, executable-like corpus)

| Pattern | Program | Scratch | zig-regex MB/s | PCRE2 JIT MB/s | PCRE2 interpreter MB/s | zig-regex / JIT | Matches |
|---|---:|---:|---:|---:|---:|---:|---:|
| `dos_stub` | 1016 B | 53.0 KiB | 25712 | 46091 | 6781 | 0.56x | 176 |
| `pe_machine` | 864 B | 52.6 KiB | 28577 | 46603 | 6916 | 0.61x | 160 |
| `getpc` | 760 B | 44.6 KiB | 27545 | 46603 | 6985 | 0.59x | 152 |
| `wildcards` | 792 B | 44.6 KiB | 27214 | 46864 | 6996 | 0.58x | 180 |
| `bounded_gap` | 1.84 KiB | 62.6 KiB | 27761 | 45590 | 6781 | 0.61x | 160 |
| `alternation` | 872 B | 48.7 KiB | 2371 | 46864 | 633 | 0.05x | 156 |
| `nibble` | 696 B | 36.5 KiB | 22996 | 21237 | 4745 | 1.08x | 163 |
| `xor_loop` | 984 B | 52.9 KiB | 28951 | 46603 | 6716 | 0.62x | 163 |
| `nocase_api` | 1.30 KiB | 77.3 KiB | 2361 | 36003 | 2921 | 0.07x | 160 |
| `wide_string` | 1016 B | 53.0 KiB | 2481 | 43240 | 2891 | 0.06x | 160 |
| `stub_gap` | 19.8 KiB | 270 KiB | 16120 | 37283 | 3862 | 0.43x | 143 |
| `class_run` | 1.34 KiB | 69.5 KiB | 171 | 468 | 70 | 0.37x | 147 |
| all, in sequence | | | 135 | 414 | 56 | 0.33x | |

### CRS-style request rules (`crs.txt`, HTTP request corpus)

| Pattern | Program | Scratch | zig-regex MB/s | PCRE2 JIT MB/s | PCRE2 interpreter MB/s | zig-regex / JIT | Matches |
|---|---:|---:|---:|---:|---:|---:|---:|
| `sqli_union` | 1.33 KiB | 77.4 KiB | 340 | 22982 | 1345 | 0.01x | 165 |
| `sqli_tautology` | 1.30 KiB | 53.6 KiB | 31931 | 57065 | 52759 | 0.56x | 139 |
| `sqli_sleep` | 1.92 KiB | 102 KiB | 313 | 1181 | 201 | 0.26x | 171 |
| `sqli_schema` | 1.91 KiB | 102 KiB | 1966 | 38836 | 641 | 0.05x | 149 |
| `xss_script` | 968 B | 56.7 KiB | 30601 | 39199 | 47127 | 0.78x | 126 |
| `xss_handler` | 1.84 KiB | 94.3 KiB | 324 | 5726 | 442 | 0.06x | 169 |
| `xss_js_uri` | 1.10 KiB | 68.9 KiB | 1183 | 29747 | 661 | 0.04x | 142 |
| `traversal` | 1.17 KiB | 57.4 KiB | 2198 | 4043 | 314 | 0.54x | 302 |
| `lfi_files` | 2.59 KiB | 116 KiB | 1230 | 1113 | 77 | 1.11x | 149 |
| `cmd_injection` | 1.73 KiB | 90.0 KiB | 981 | 1883 | 285 | 0.52x | 154 |
| `php_tag` | 664 B | 44.4 KiB | 387 | 43919 | 45100 | 0.01x | 149 |
| `scanner_ua` | 1.84 KiB | 90.4 KiB | 382 | 1325 | 136 | 0.29x | 146 |
| `rfi` | 1.46 KiB | 73.7 KiB | 766 | 7530 | 287 | 0.10x | 135 |
| all, in sequence | | | 51 | 266 | 24 | 0.19x | |

### What the numbers say

- **Signatures that start with one fixed byte run at memory-scan speed.**
  Every ClamAV-style pattern led by a single byte (`dos_stub`, `pe_machine`,
  `getpc`, `wildcards`, `bounded_gap`, `xor_loop`) counts at 26 to 29 GB/s,
  0.56 to 0.62 times PCRE2's JIT and about four times its interpreter; the
  program skips straight to occurrences of its first byte. `nibble` (`\x0f[\x80-\x8f].{4}\xe8`) beats the JIT at 23 GB/s, and the
  256-byte gap of `stub_gap` still runs at 16 GB/s.
- **Several possible first bytes cost a factor of ten.** An alternation of
  first bytes (`alternation`) or an ASCII case-insensitive literal
  (`nocase_api`, `wide_string`, `sqli_schema`, `xss_js_uri`) has no single
  first byte, so the DFA steps through every input byte: 1.2 to 2.5 GB/s,
  0.04 to 0.07 times the JIT, which starts from its own first-code-unit and
  required-byte searches. A start prefilter for small first-byte sets (or
  Teddy over `requiredFactors`) inside `Program` is the obvious next step.
- **Word boundaries set the speed.** Every pattern with `\b` (`sqli_union`,
  `sqli_sleep`, `xss_handler`, `php_tag`, `scanner_ua`) runs at 310 to
  390 MB/s whatever its literals, so the assertion path, not the pattern,
  is the bottleneck there.
- **Restarting at every candidate start hurts long runs.** `class_run`
  (`[\x20-\x7e]{6,}\.(exe|dll|scr)\x00`) counts at 171 MB/s against 468 for the
  JIT: `find` and `count` try an anchored match from each candidate start, so
  long printable runs are rescanned. A reverse DFA to find match starts would
  make this linear.
- **Where PCRE2 has no shortcut, programs keep up or win.** `lfi_files` (1.11
  times the JIT), `cmd_injection` and `traversal` (0.52 to 0.54) and
  `scanner_ua` and `sqli_sleep` (0.26 to 0.29) are alternations PCRE2 cannot
  anchor on one byte; against the PCRE2 interpreter, which is what PCRE2 runs
  where JIT is unavailable, programs are 1.6 to 16 times faster on those.
- **Programs are small.** 0.7 to 2.6 KiB for every pattern but `stub_gap`
  (19.8 KiB, its counted gap unrolled), with a scratch of 36 to 270 KiB that
  is allocated once and reused for every search.

Matching all 12 ClamAV-style patterns one after another runs at 0.33 times
the JIT and 2.4 times the interpreter; the 13 CRS-style patterns at 0.19 and
2.1 times. Both sets match exactly the same number of times as PCRE2.
`traversal` and `lfi_files` became programs only with this change: before it,
a capture group inside an alternation sent the pattern to the backtracker and
`Program.compile` refused it.

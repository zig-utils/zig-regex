# Benchmarks

Measured throughput and memory for the multi-literal matchers in
`src/literals` and for byte-mode regex programs, so that engine and prefilter
choices in zig-anti-virus and zig-waf rest on data. Every number below comes
from one command:

```sh
zig build bench                 # multi-literal matchers and byte-mode regex programs
benchmarks/pcre2/compare.sh     # the same regex patterns and corpora through PCRE2
benchmarks/pcre2/diff.sh        # leftmost-first agreement with PCRE2
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
| Library | literal matchers: zig-regex f8ddb54; regex programs: zig-regex 56d39f1 (`feat(program): add leftmost-first programs, reverse start search and prefilters`), against 0.3.1 (111f6df) on the same day |
| PCRE2 | 10.49 (2026-09-28) from `pantry install`, statically linked, `cc -O2`, JIT and interpreter (the literal tables predate it; they do not involve PCRE2) |
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
cap), both for the leftmost-first build. MB/s is 10^6 bytes per second, best
of at least three passes and 1 s. **0.3.1** is the previous release
(leftmost-longest, the only kind it had) measured in the same session;
**first / JIT** compares the leftmost-first program with the JIT.
`compare.sh` measures leftmost-first programs and `MATCH_KIND=longest
compare.sh` the default kind. Leftmost-first match counts equal PCRE2's on
every pattern (so do leftmost-longest ones: these patterns do not tell the
kinds apart).

### ClamAV-style signatures (`clamav.txt`, executable-like corpus)

| Pattern | Program | Scratch | 0.3.1 MB/s | leftmost-longest MB/s | leftmost-first MB/s | PCRE2 JIT MB/s | PCRE2 interpreter MB/s | first / JIT | Matches |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `dos_stub` | 1.47 KiB | 85.6 KiB | 26025 | 26266 | 26143 | 41121 | 6066 | 0.64x | 176 |
| `pe_machine` | 1.17 KiB | 85.1 KiB | 26560 | 26801 | 27388 | 41943 | 6564 | 0.65x | 160 |
| `getpc` | 1.03 KiB | 77.0 KiB | 25984 | 26462 | 26532 | 41528 | 6214 | 0.64x | 152 |
| `wildcards` | 1.06 KiB | 77.0 KiB | 26905 | 26529 | 26769 | 41121 | 6279 | 0.65x | 180 |
| `bounded_gap` | 3.13 KiB | 96.2 KiB | 26038 | 25848 | 26797 | 39946 | 6242 | 0.67x | 160 |
| `alternation` | 1.22 KiB | 81.2 KiB | 2242 | 27317 | 27888 | 41323 | 612 | 0.67x | 156 |
| `nibble` | 960 B | 68.9 KiB | 21639 | 26532 | 27451 | 18040 | 4562 | 1.52x | 163 |
| `xor_loop` | 1.38 KiB | 85.4 KiB | 26262 | 27115 | 26969 | 41323 | 6399 | 0.65x | 163 |
| `nocase_api` | 1.91 KiB | 110 KiB | 2360 | 10388 | 10306 | 31655 | 2714 | 0.33x | 160 |
| `wide_string` | 1.47 KiB | 85.6 KiB | 2343 | 27137 | 27284 | 39569 | 2746 | 0.69x | 160 |
| `stub_gap` | 38.8 KiB | 324 KiB | 14894 | 17109 | 17121 | 33421 | 3576 | 0.51x | 143 |
| `class_run` | 2.06 KiB | 102 KiB | 164 | 522 | 521 | 416 | 66 | 1.25x | 147 |
| all, in sequence | | | 129 | 415 | 415 | 368 | 53 | 1.13x | |

### CRS-style request rules (`crs.txt`, HTTP request corpus)

| Pattern | Program | Scratch | 0.3.1 MB/s | leftmost-longest MB/s | leftmost-first MB/s | PCRE2 JIT MB/s | PCRE2 interpreter MB/s | first / JIT | Matches |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `sqli_union` | 2.02 KiB | 110 KiB | 309 | 5814 | 5574 | 22075 | 1265 | 0.25x | 165 |
| `sqli_tautology` | 2.13 KiB | 86.5 KiB | 31820 | 69375 | 66117 | 54471 | 46864 | 1.21x | 139 |
| `sqli_sleep` | 3.02 KiB | 140 KiB | 286 | 1138 | 1094 | 1129 | 189 | 0.97x | 171 |
| `sqli_schema` | 2.98 KiB | 136 KiB | 1997 | 29888 | 28472 | 37283 | 596 | 0.76x | 149 |
| `xss_script` | 1.31 KiB | 89.2 KiB | 30555 | 66709 | 62855 | 37449 | 44151 | 1.68x | 126 |
| `xss_handler` | 2.92 KiB | 132 KiB | 297 | 2307 | 2089 | 5256 | 417 | 0.40x | 169 |
| `xss_js_uri` | 1.56 KiB | 102 KiB | 1162 | 13006 | 12242 | 28533 | 634 | 0.43x | 142 |
| `traversal` | 1.83 KiB | 90.2 KiB | 2209 | 3814 | 3606 | 3822 | 303 | 0.94x | 302 |
| `lfi_files` | 4.28 KiB | 150 KiB | 1213 | 916 | 864 | 1056 | 76 | 0.82x | 149 |
| `cmd_injection` | 2.70 KiB | 123 KiB | 976 | 3919 | 3697 | 1828 | 285 | 2.02x | 154 |
| `php_tag` | 896 B | 76.8 KiB | 370 | 43455 | 41146 | 41943 | 43464 | 0.98x | 149 |
| `scanner_ua` | 2.97 KiB | 124 KiB | 371 | 932 | 865 | 1291 | 134 | 0.67x | 146 |
| `rfi` | 2.28 KiB | 107 KiB | 786 | 2571 | 2428 | 7410 | 271 | 0.33x | 135 |
| all, in sequence | | | 49 | 212 | 199 | 255 | 23 | 0.78x | |

### What the numbers say

- **Several possible first bytes no longer cost a factor of ten.** 0.3.1
  skipped ahead only when every match began with one byte. A program now
  stores the rarest set of at most 3 bytes at a fixed offset in the first 16
  bytes of every match (plus a second one to verify candidates) and finds it
  with a vector search: `alternation` (three first bytes) goes from 2.2 to 28
  GB/s, the ASCII case-insensitive literals `wide_string`, `sqli_schema` and
  `xss_js_uri` from 1.2 to 2.3 GB/s to 12 to 28 GB/s, `nocase_api` from 2.4 to
  10 GB/s. They run at 0.33 to 0.76 times the JIT.
- **Word boundaries no longer pin a pattern to 300-400 MB/s.** The skip used
  to need a start state that does not depend on the previous byte, which
  `\b` and `^` break. Transitions into a start state are now flagged and the
  scan restarts in the start state for the context at the candidate, so
  `php_tag` (`<\?php\b`) runs at 41 GB/s, level with the JIT, `sqli_union`
  at 5.6 GB/s (18 times 0.3.1) and `xss_handler` at 2.1 GB/s. `sqli_sleep`
  and `scanner_ua` have six to eight first bytes, common letters, and stay
  at 0.87 to 1.1 GB/s, 0.67 to 0.97 times the JIT.
- **Long runs are linear.** `class_run` (`[\x20-\x7e]{6,}\.(exe|dll|scr)\x00`)
  used to retry an anchored run from every start in a long printable run. The
  forward DFA now finds the match end and a DFA over the reversed program
  walks back to the start, so it counts at 521 MB/s, 3.2 times 0.3.1 and 1.25
  times the JIT. Storing row offsets in the transition table (no multiply per
  byte) took the plain DFA step from about 360 to 525 MB/s.
- **Single-first-byte signatures are unchanged** at 26 to 27 GB/s, 0.64 to
  0.67 times the JIT, and `stub_gap` is a little faster (17 GB/s) now that
  bounded repeats compile as nested optionals.
- **One pattern is slower.** `lfi_files` (first bytes `e`, `p`, `b`, `w` in
  both cases, about one HTTP byte in ten) drops from 1213 to 864 MB/s, 0.82
  times the JIT: every candidate leaves and re-enters the start state, which
  costs more than 0.3.1's inline table loop did. Its match count still agrees.
- **Leftmost-first costs 0 to 10 percent** against leftmost-longest on these
  patterns; ordered DFA states hold the same threads as the unordered ones
  here.
- **Programs are larger.** The reversed program roughly doubles the edge
  sections: 0.9 to 4.3 KiB per pattern (38.8 KiB for `stub_gap`), with a
  scratch of 69 to 324 KiB, about 1.6 times 0.3.1's.

Matching all 12 ClamAV-style patterns one after another runs at 1.13 times
the JIT and 7.8 times the interpreter; the 13 CRS-style patterns at 0.78 and
8.7 times. In 0.3.1 the same sequences ran at 0.34 and 0.19 times the JIT.

## Leftmost-first agreement with PCRE2

```sh
benchmarks/pcre2/diff.sh [count] [seed]   # default 20000 cases, seed 1
```

generates random cases from a grammar of alternations, greedy and lazy
repeats (`*?`, `+?`, `??`, `{m,n}?`), repeated and capture groups, classes,
`.`, `\b`, `\B`, `^`, `$`, `\A`, `\z` and the `i`, `m` and `s` flags,
with subjects of up to 48 bytes, and compares every `g`-style match of a
byte-mode leftmost-first program with PCRE2's (no UTF; `PCRE2_DOLLAR_ENDONLY`
and `PCRE2_ALT_CIRCUMFLEX` give `$` and multiline `^` zig-regex's
conventions). Three seeds of 100,000 cases:

| Seed | Compared | Agree | Differ | PCRE2 errors |
|---:|---:|---:|---:|---:|
| 1 | 99,988 | 99,982 | 6 | 12 |
| 2 | 99,989 | 99,984 | 5 | 11 |
| 3 | 99,985 | 99,976 | 9 | 15 |
| all | 299,962 | 299,942 | 20 | 38 |

Every pattern compiled as a program. All 20 differences repeat a group that
can match empty inside an iteration (`(?:.{0,2}?){2,}b`, `(b|\W??)*a??`):
PCRE2 accepts one empty iteration and then leaves the loop, at that
iteration's priority, while a Pike VM (and so the DFA built from it) never
revisits a state within one step and drops that path. RE2 and Rust's regex
differ from PCRE2 the same way. The 38 PCRE2 errors are searches PCRE2 abandoned with
`PCRE2_ERROR_MATCHLIMIT` (nested quantifiers backtracking past its default
limit of 10 million calls); programs answer those in linear time, and they are
not counted.
`tests/testdata/pcre2_leftmost_first.tsv` keeps 1,000 agreeing cases with
PCRE2's spans, which the test suite checks without needing PCRE2.

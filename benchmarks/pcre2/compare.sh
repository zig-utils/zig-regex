#!/usr/bin/env bash
# zig-regex byte-mode programs against PCRE2 (JIT and interpreter) on the
# benchmark suite's ClamAV-style and CRS-style pattern sets.
#
#   benchmarks/pcre2/compare.sh
#
# Both sides read benchmarks/suite/patterns/*.txt, search the same generated
# corpus (8 MiB, written by `bench_suite gen`), count non-overlapping matches
# and keep the best of at least three passes. Needs a C compiler and PCRE2:
# PCRE2_PREFIX=<dir with include/ and lib/>, else pkg-config's libpcre2-8,
# else ./pantry/pcre.org/v2 (`pantry install` provisions it from deps.yaml).
#
# Match counts can differ where semantics do: zig-regex programs report
# leftmost-longest matches, PCRE2 leftmost-first ones.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
work="$root/.zig-cache/bench-pcre2"
mkdir -p "$work"

zig build -Dinstall-benchmarks --prefix "$work/zig" >/dev/null
suite="$work/zig/bin/bench_suite"

cflags=()
libs=()
if [ -n "${PCRE2_PREFIX:-}" ]; then
  prefix="$PCRE2_PREFIX"
elif pkg-config --exists libpcre2-8 2>/dev/null; then
  prefix=""
  read -r -a cflags <<<"$(pkg-config --cflags libpcre2-8)"
  read -r -a libs <<<"$(pkg-config --libs libpcre2-8)"
else
  prefix="$(ls -d pantry/pcre.org/v2/v*.*.* 2>/dev/null | sort -V | tail -1 || true)"
  if [ -z "$prefix" ]; then
    echo "PCRE2 not found: set PCRE2_PREFIX, install libpcre2-8 for pkg-config, or run pantry install" >&2
    exit 1
  fi
fi
if [ -n "$prefix" ]; then
  cflags=("-I$prefix/include")
  if [ -f "$prefix/lib/libpcre2-8.a" ]; then
    libs=("$prefix/lib/libpcre2-8.a")
  else
    libs=("-L$prefix/lib" "-lpcre2-8" "-Wl,-rpath,$prefix/lib")
  fi
fi
cc -O2 -o "$work/pcre2_bench" benchmarks/pcre2/pcre2_bench.c "${cflags[@]}" "${libs[@]}"

echo "zig-regex $(git rev-parse --short HEAD) ($(zig version)) vs PCRE2 $("$work/pcre2_bench" version), $(uname -sm)"
echo

for set in clamav:binary crs:http; do
  name="${set%%:*}"
  kind="${set##*:}"
  patterns="benchmarks/suite/patterns/$name.txt"
  corpus="$work/$name.corpus"
  "$suite" gen "$patterns" "$kind" "$corpus"
  "$suite" regex-file "$patterns" "$corpus" >"$work/$name.zig.tsv"
  "$work/pcre2_bench" "$patterns" "$corpus" jit >"$work/$name.jit.tsv"
  "$work/pcre2_bench" "$patterns" "$corpus" interp >"$work/$name.interp.tsv"

  echo "### $name.txt ($kind corpus)"
  echo
  echo "| Pattern | zig-regex MB/s | PCRE2 JIT MB/s | PCRE2 interpreter MB/s | zig-regex / JIT | Matches |"
  echo "|---|---:|---:|---:|---:|---:|"
  awk -F'\t' '
    function mbps(ns) { return ns > 0 ? sprintf("%.0f", bytes / ns * 1000) : "-" }
    FILENAME ~ /jit/ { jc[$1] = $2; jn[$1] = $3; next }
    FILENAME ~ /interp/ { in_[$1] = $3; next }
    {
      bytes = $4
      z = $3; j = jn[$1]; i = in_[$1]
      ratio = (z > 0 && j > 0) ? sprintf("%.2fx", j / z) : "-"
      counts = ($2 == jc[$1]) ? $2 : $2 " vs " jc[$1]
      printf "| `%s` | %s | %s | %s | %s | %s |\n", $1, (z > 0 ? mbps(z) : $2), mbps(j), mbps(i), ratio, counts
      tz += z; tj += j; ti += i
    }
    END { printf "| all, in sequence | %s | %s | %s | %.2fx | |\n", mbps(tz), mbps(tj), mbps(ti), tj / tz }
  ' "$work/$name.jit.tsv" "$work/$name.interp.tsv" "$work/$name.zig.tsv"
  echo
done

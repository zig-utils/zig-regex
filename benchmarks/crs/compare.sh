#!/usr/bin/env bash
# zig-regex against PCRE2 on every @rx pattern of an OWASP CRS checkout.
#
#   benchmarks/crs/compare.sh <crs-checkout>
#
# Patterns are read from <crs-checkout>/rules/*.conf at run time and matched
# once against each request value in benchmarks/crs/inputs.txt, compiled the
# way ModSecurity compiles @rx (dotall, multiline, bytes). zig-regex runs
# span-only (as a WAF tests a match) and with captures; PCRE2 runs with JIT
# (as ModSecurity runs it) and without. Each pattern keeps its best pass over
# all inputs, and its first pass (before anything built lazily is warm);
# totals are the sums. The script fails when any engine disagrees with the
# PCRE2 interpreter on any input for a pattern both compile, or when a match
# call fails.
#
# Needs a C compiler and PCRE2: PCRE2_PREFIX=<dir with include/ and lib/>,
# else pkg-config's libpcre2-8, else ./pantry/pcre.org/v2.
set -euo pipefail

if [ $# -ne 1 ] || [ ! -d "$1/rules" ]; then
  echo "usage: benchmarks/crs/compare.sh <crs-checkout>" >&2
  exit 2
fi
crs="$(cd "$1" && pwd)"
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
work="$root/.zig-cache/bench-crs"
mkdir -p "$work"

zig build -Dinstall-benchmarks --prefix "$work/zig" >/dev/null
bench="$work/zig/bin/bench_crs"

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
cc -O2 -o "$work/pcre2_crs" benchmarks/crs/pcre2_crs.c "${cflags[@]}" "${libs[@]}"

crs_version="$(git -C "$crs" describe --tags --always 2>/dev/null || echo unknown)"
echo "zig-regex $(git rev-parse --short HEAD) ($(zig version)) vs PCRE2 $("$work/pcre2_crs" version), CRS $crs_version, $(uname -sm)"
"$bench" prepare "$crs" "$work"
echo

"$bench" run "$work" spans >"$work/zig-spans.tsv"
"$bench" run "$work" captures >"$work/zig-captures.tsv"
"$work/pcre2_crs" "$work" interp >"$work/pcre2-interp.tsv"
"$work/pcre2_crs" "$work" jit >"$work/pcre2-jit.tsv"

# Totals per engine, then the mismatch check and the slowest patterns.
awk -F'\t' '
  FNR == 1 { file++; label[file] = FILENAME; sub(/.*\//, "", label[file]); sub(/\.tsv$/, "", label[file]) }
  { rows[file]++ }
  $2 ~ /^error:match/ { printf "MATCH ERROR %s %s: %s\n", label[file], $1, $2 > "/dev/stderr"; merr++ }
  $2 == "ok" { ok[file]++; total[file] += $4; cold[file] += $5; hits[file, $1] = $3; ns[file, $1] = $4 }
  file == 1 { order[++n] = $1 }
  END {
    printf "| Engine | Compiled | Best pass, all patterns and inputs | First pass |\n| --- | ---: | ---: | ---: |\n"
    for (f = 1; f <= file; f++) printf "| %s | %d of %d | %.2f ms | %.2f ms |\n", label[f], ok[f], rows[f], total[f] / 1e6, cold[f] / 1e6
    # Files: 1 zig-spans, 2 zig-captures, 3 pcre2-interp, 4 pcre2-jit. Every
    # other engine is compared with the PCRE2 interpreter. The hit strings are
    # compared as strings: awk would compare 24 digits as numbers, and lose
    # the last ones to floating point.
    bad = 0
    for (i = 1; i <= n; i++) {
      p = order[i]
      for (f = 1; f <= 4; f++) if (f != 3 && ((f, p) in hits) && ((3, p) in hits) && (hits[f, p] "") != (hits[3, p] "")) {
        printf "MISMATCH %s %s: %s, pcre2-interp %s\n", label[f], p, hits[f, p], hits[3, p] > "/dev/stderr"
        bad++
      }
    }
    printf "\nMatch results: %s\n\n", bad ? bad " mismatches against PCRE2" : "identical to PCRE2 on every pattern both compile"
    failed = bad
    printf "Slowest patterns, zig-regex span-only (best pass over all inputs):\n\n| Rule | zig-regex | PCRE2 interp | PCRE2 JIT |\n| --- | ---: | ---: | ---: |\n"
    for (i = 1; i <= n; i++) if ((1, order[i]) in ns) slow[i] = ns[1, order[i]]
    for (k = 1; k <= 15; k++) {
      top = 0
      for (i in slow) if (!top || slow[i] > slow[top]) top = i
      if (!top) break
      p = order[top]
      printf "| %s | %.1f us | %.1f us | %.1f us |\n", p, ns[1, p] / 1e3, ns[3, p] / 1e3, ns[4, p] / 1e3
      delete slow[top]
    }
    if (merr) printf "%d match calls failed\n", merr
    exit (failed || merr) ? 1 : 0
  }
' "$work/zig-spans.tsv" "$work/zig-captures.tsv" "$work/pcre2-interp.tsv" "$work/pcre2-jit.tsv"

echo
for f in zig-spans zig-captures pcre2-interp pcre2-jit; do
  if grep -q $'\terror:' "$work/$f.tsv"; then
    echo "$f: not compiled: $(grep $'\terror:' "$work/$f.tsv" | cut -f1,2 | tr '\t' ' ' | tr '\n' ',' | sed 's/,$//;s/,/, /g')"
  fi
done

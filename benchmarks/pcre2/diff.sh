#!/usr/bin/env bash
# Differential test of leftmost-first zig-regex programs against PCRE2.
#
#   benchmarks/pcre2/diff.sh [count] [seed]
#
# Generates `count` random cases (pattern, flags, subject; default 20000)
# from a grammar of alternations, greedy and lazy repeats, classes, `.`,
# anchors and `\b`, runs each through PCRE2 (no UTF, `g`-style match loop)
# and through a byte-mode leftmost-first Program, and prints how many agree,
# then the first disagreements. Needs a C compiler and PCRE2, found as
# compare.sh finds it (PCRE2_PREFIX, pkg-config, or ./pantry).
#
# PCRE2_DOLLAR_ENDONLY and PCRE2_ALT_CIRCUMFLEX align `$` and multiline `^`
# with zig-regex's conventions; see pcre2_spans.c.
set -euo pipefail

count="${1:-20000}"
seed="${2:-1}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
work="$root/.zig-cache/pcre2-diff"
mkdir -p "$work"

zig build -Dinstall-benchmarks --prefix "$work/zig" >/dev/null
diff_tool="$work/zig/bin/pcre2_diff"

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
cc -O2 -o "$work/pcre2_spans" benchmarks/pcre2/pcre2_spans.c "${cflags[@]}" "${libs[@]}"

"$diff_tool" gen "$count" "$seed" >"$work/cases.tsv"
"$work/pcre2_spans" <"$work/cases.tsv" >"$work/spans.tsv"
"$diff_tool" check "$work/cases.tsv" "$work/spans.tsv"

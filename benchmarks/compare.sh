#!/usr/bin/env bash
#
# Head-to-head findAll throughput: zig-regex vs the Rust `regex` crate.
# Mirrors the methodology in zig-utils/zig-regex#10.
#
#   ./benchmarks/compare.sh [iterations]
#
# Generates a deterministic ~1.17 MB haystack, then for each pattern runs both
# engines counting all matches over N iterations (excluding stdin read and
# process startup) and prints time-per-iteration plus the ratio.
#
# Requires: the project's Zig (auto-detected) and, for the Rust column, cargo.
set -euo pipefail

cd "$(dirname "$0")/.."

ITERS="${1:-50}"
PATTERNS=("hello" "hello|world|test" "\d+" "\w+" "\w+\s+\w+" "\w+\s+\w+\s+\w+" "[A-Za-z]+\s+[A-Za-z]+")

# Locate Zig 0.16 (project-local pantry install preferred, else PATH).
if [[ -x "./pantry/ziglang.org/v0.16.0/zig" ]]; then
  ZIG="./pantry/ziglang.org/v0.16.0/zig"
else
  ZIG="zig"
fi

echo "Building zig-regex benchmark (ReleaseFast)..."
"$ZIG" build >/dev/null 2>&1 || true
ZIG_BIN="zig-out/bin/findall_bench"
if [[ ! -x "$ZIG_BIN" ]]; then
  echo "error: $ZIG_BIN not found (build failed?)" >&2
  exit 1
fi

HAYSTACK="$(mktemp)"
trap 'rm -f "$HAYSTACK"' EXIT
echo "Generating haystack..."
"$ZIG_BIN" gen > "$HAYSTACK"
BYTES=$(wc -c < "$HAYSTACK" | tr -d ' ')

RUST_BIN=""
if command -v cargo >/dev/null 2>&1; then
  echo "Building Rust regex benchmark (release)..."
  ( cd benchmarks/rust-bench && cargo build --release >/dev/null 2>&1 ) || true
  if [[ -x "benchmarks/rust-bench/target/release/rust-bench" ]]; then
    RUST_BIN="benchmarks/rust-bench/target/release/rust-bench"
  fi
fi

# per_iter_ms <binary> <pattern> -> prints matches and ms/iter
run() {
  local bin="$1" pat="$2"
  local out elapsed iters total
  out=$("$bin" "$pat" "$ITERS" < "$HAYSTACK")
  total=$(echo "$out" | awk '{print $1}')
  iters=$(echo "$out" | awk '{print $2}')
  elapsed=$(echo "$out" | awk '{print $3}')
  awk -v t="$total" -v i="$iters" -v e="$elapsed" \
    'BEGIN { printf "%d %.4f", t/i, (e/i)/1e6 }'
}

echo
echo "haystack: $BYTES bytes | iterations: $ITERS"
echo
if [[ -n "$RUST_BIN" ]]; then
  printf "%-20s %10s %14s %14s %10s\n" "pattern" "matches" "zig ms/iter" "rust ms/iter" "ratio"
  printf -- "%.0s-" {1..72}; echo
  for pat in "${PATTERNS[@]}"; do
    z=$(run "$ZIG_BIN" "$pat"); zc=${z% *}; zt=${z#* }
    r=$(run "$RUST_BIN" "$pat"); rt=${r#* }
    ratio=$(awk -v a="$zt" -v b="$rt" 'BEGIN { if (b>0) printf "%.1fx", a/b; else print "n/a" }')
    printf "%-20s %10s %14s %14s %10s\n" "$pat" "$zc" "$zt" "$rt" "$ratio"
  done
else
  echo "(cargo not found — Zig only; install Rust to enable the comparison column)"
  printf "%-20s %10s %14s\n" "pattern" "matches" "zig ms/iter"
  printf -- "%.0s-" {1..46}; echo
  for pat in "${PATTERNS[@]}"; do
    z=$(run "$ZIG_BIN" "$pat"); zc=${z% *}; zt=${z#* }
    printf "%-20s %10s %14s\n" "$pat" "$zc" "$zt"
  done
fi

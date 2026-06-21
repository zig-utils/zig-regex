#!/usr/bin/env bash
# Head-to-head zg vs rg using hyperfine, mirroring issue #10.
# Usage: rgbench.sh <target>   where target is a file or directory.
set -uo pipefail
cd "$(dirname "$0")/.."

RG="${RG:-/opt/homebrew/bin/rg}"
ZG="./zig-out/bin/zg"
TARGET="${1:-/tmp/cat_zig.txt}"
WARMUP="${WARMUP:-3}"
RUNS="${RUNS:-8}"

NAMES=(literal count-only alternation no-literal anchored dot-plus kernel-style word-skip large-alt ci-literal)
FLAGS=(""      "-c"       ""          ""         ""       ""       ""           ""        ""        "-i")
PATS=('fn'  'fn'  'fn|fn\s'  '\w+\s+\w+'  '^\w+\s+\w+$'  '.+$'  '[A-Z]+'  '\w{5}\s+\w{5}'  'fn\s+\w+|\w+\s+fn'  'FN')

printf "%-14s %-22s %12s %12s %8s\n" "name" "pattern" "rg(ms)" "zg(ms)" "ratio"
printf -- '-%.0s' {1..72}; echo
for idx in "${!NAMES[@]}"; do
  name="${NAMES[$idx]}"; flags="${FLAGS[$idx]}"; pat="${PATS[$idx]}"
  rgcmd="$RG $flags -- '$pat' '$TARGET' >/dev/null 2>&1 || true"
  zgcmd="$ZG $flags '$pat' '$TARGET' >/dev/null 2>&1 || true"
  hyperfine -w "$WARMUP" -r "$RUNS" --style none --export-json /tmp/rgbench.json \
      "$rgcmd" "$zgcmd" >/dev/null 2>&1
  rgms=$(/opt/homebrew/bin/python3 -c "import json;d=json.load(open('/tmp/rgbench.json'));print(f\"{d['results'][0]['mean']*1000:.1f}\")" 2>/dev/null)
  zgms=$(/opt/homebrew/bin/python3 -c "import json;d=json.load(open('/tmp/rgbench.json'));print(f\"{d['results'][1]['mean']*1000:.1f}\")" 2>/dev/null)
  ratio=$(awk -v r="$rgms" -v z="$zgms" 'BEGIN{ if(r>0) printf "%.2f", z/r; else print "n/a" }')
  printf "%-14s %-22s %12s %12s %8s\n" "$name" "$pat" "$rgms" "$zgms" "$ratio"
done
echo
echo "ratio = zg/rg time; <1.0 means zg faster (WIN), >1.0 means zg slower."

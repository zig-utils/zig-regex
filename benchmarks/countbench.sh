#!/usr/bin/env bash
# Engine-isolating benchmark: all patterns in count mode (-c) zg vs rg.
set -uo pipefail
cd "$(dirname "$0")/.."
RG="${RG:-/opt/homebrew/bin/rg}"
ZG="./zig-out/bin/zg"
T="${1:-/tmp/cat_zig.txt}"
W="${WARMUP:-3}"; R="${RUNS:-8}"

NAMES=(literal alternation no-literal anchored dot-plus kernel-style word-skip large-alt ci-literal)
FLAGS=(""      ""          ""         ""       ""       ""           ""        ""        "-i")
PATS=('fn' 'fn|fn\s' '\w+\s+\w+' '^\w+\s+\w+$' '.+$' '[A-Z]+' '\w{5}\s+\w{5}' 'fn\s+\w+|\w+\s+fn' 'FN')

printf "%-14s %-20s %9s %9s %7s\n" name pattern "rg(ms)" "zg(ms)" ratio
printf -- '-%.0s' {1..62}; echo
for i in "${!NAMES[@]}"; do
  pat="${PATS[$i]}"; fl="${FLAGS[$i]}"
  hyperfine -w "$W" -r "$R" --style none --export-json /tmp/cb.json \
    "$RG -c $fl -- '$pat' '$T' >/dev/null 2>&1 || true" \
    "$ZG -c $fl '$pat' '$T' >/dev/null 2>&1 || true" >/dev/null 2>&1
  r=$(python3 -c "import json;d=json.load(open('/tmp/cb.json'));print(f\"{d['results'][0]['mean']*1000:.1f}\")")
  z=$(python3 -c "import json;d=json.load(open('/tmp/cb.json'));print(f\"{d['results'][1]['mean']*1000:.1f}\")")
  ra=$(awk -v r="$r" -v z="$z" 'BEGIN{printf "%.2f", z/r}')
  printf "%-14s %-20s %9s %9s %7s\n" "${NAMES[$i]}" "$pat" "$r" "$z" "$ra"
done
echo "ratio = zg/rg; <1.0 = zg faster"

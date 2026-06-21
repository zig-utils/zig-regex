#!/usr/bin/env bash
# Load-independent engine comparison: user-CPU time (both tools single-threaded
# on one file). Robust on a busy machine where wall-clock is noisy.
set -uo pipefail
cd "$(dirname "$0")/.."
RG="/opt/homebrew/bin/rg"; ZG="./zig-out/bin/zg"; T="${1:-/tmp/cat_zig.txt}"
NAMES=(literal alternation no-literal anchored dot-plus kernel word-skip large-alt ci-literal)
FLAGS=(""      ""          ""         ""       ""       ""     ""        ""        "-i")
PATS=('fn' 'fn|fn\s' '\w+\s+\w+' '^\w+\s+\w+$' '.+$' '[A-Z]+' '\w{5}\s+\w{5}' 'fn\s+\w+|\w+\s+fn' 'FN')
printf "%-12s %-20s %10s %10s %7s\n" name pattern "rg(uCPU)" "zg(uCPU)" ratio
printf -- '-%.0s' {1..62}; echo
for i in "${!NAMES[@]}"; do
  pat="${PATS[$i]}"; fl="${FLAGS[$i]}"
  hyperfine -w 4 -r 15 --style none --export-json /tmp/u.json \
    "$RG $fl -- '$pat' '$T' >/dev/null 2>&1 || true" \
    "$ZG $fl '$pat' '$T' >/dev/null 2>&1 || true" >/dev/null 2>&1
  python3 -c "
import json
d=json.load(open('/tmp/u.json'))
r=d['results'][0]['user']*1000; z=d['results'][1]['user']*1000
print('%-12s %-20s %10.1f %10.1f %7.2f' % ('${NAMES[$i]}','$pat',r,z,z/r))"
done
echo "uCPU = user CPU ms; ratio = zg/rg; <1.0 = zg less CPU (faster engine)"

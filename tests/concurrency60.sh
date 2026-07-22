#!/usr/bin/env bash
# Fire N concurrent tiny generate requests at local Ollama and time each one.
set -u
MODEL=${MODEL:-gemma4:26b}
N=${N:-60}
OUT=${OUT:-/tmp/gemma_conc60}
mkdir -p "$OUT"
rm -f "$OUT"/*.json

one() {
  i=$1
  start=$(date +%s%N)
  code=$(curl -s -o "$OUT/$i.json" -w '%{http_code}' \
    http://127.0.0.1:11434/api/generate \
    -d "{\"model\":\"$MODEL\",\"prompt\":\"Say hi in one word. (request $i)\",\"stream\":false,\"options\":{\"num_predict\":8}}")
  end=$(date +%s%N)
  ms=$(( (end - start) / 1000000 ))
  echo "$i $code $ms"
}
export MODEL OUT
export -f one

seq 1 "$N" | xargs -P "$N" -I{} bash -c 'one "$@"' _ {} > "$OUT/timings.txt" 2>&1

echo "== summary =="
awk '{ok+=($2==200); ms[NR]=$3} END {
  asort(ms);
  printf "total=%d ok=%d fail=%d\n", NR, ok, NR-ok;
  printf "min=%dms p50=%dms p90=%dms max=%dms\n", ms[1], ms[int(NR*0.5)], ms[int(NR*0.9)], ms[NR];
}' "$OUT/timings.txt"

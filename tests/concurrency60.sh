#!/usr/bin/env bash
# Fire N concurrent tiny generate requests at local Ollama and time each one.
set -u
MODEL=${MODEL:-gemma4:26b}
N=${N:-60}
export N
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

seq 1 "$N" | xargs -P "$N" -I{} bash -c 'one "$@"' _ {} > "$OUT/timings.txt"

echo "== summary =="
# Keep only well-formed "<idx> <http-code> <ms>" rows: curl stderr must never
# leak into the data file (stderr is not redirected, but guard anyway).
awk '/^[0-9]+ [0-9]{3} [0-9]+$/ {ok+=($2==200); ms[n++]=$3} END {
  if (ok > 0) asort(ms);
  printf "total=%d ok=%d fail=%d\n", n, ok, n-ok;
  printf "min=%dms p50=%dms p90=%dms max=%dms\n", ms[1], ms[int((n+1)/2)], ms[int((90*n+99)/100)], ms[n];
  if (n != ENVIRON["N"]) printf "WARNING: expected %d rows, got %d\n", ENVIRON["N"], n > "/dev/stderr";
}' "$OUT/timings.txt"

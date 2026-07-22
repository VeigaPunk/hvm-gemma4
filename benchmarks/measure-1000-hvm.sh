#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
COUNT=${COUNT:-1000}
CONCURRENCY=${CONCURRENCY:-8}
ENDPOINT=${ENDPOINT:-http://127.0.0.1:11437}
RUN_DIR=${RUN_DIR:-$ROOT/benchmarks/hvm-1000-run}
METRICS=$RUN_DIR/ollama-metrics.jsonl
REQUESTS=$RUN_DIR/hvm-requests.jsonl
SUMMARY=$RUN_DIR/summary.json
PROXY_LOG=$RUN_DIR/proxy.log

if [[ "${1:-}" == worker ]]; then
  id=$2
  prompt=$(printf '[Q%04d] What is %d plus %d? Give only the integer.' "$id" "$id" "$id")
  output=$(mktemp)
  start=$(date +%s%N)
  set +e
  HVM_GEMMA_ENDPOINT="$ENDPOINT" \
  HVM_GEMMA_MODEL=gemma4:26b \
  HVM_GEMMA_NUM_PREDICT=32 \
  HVM_GEMMA_NUM_CTX=2048 \
  HVM_GEMMA_KEEP_ALIVE=10m \
  HVM_GEMMA_TEMPERATURE=0 \
  HVM_GEMMA_SEED=42 \
  HVM_GEMMA_THINK=false \
    "$ROOT/run.sh" "$prompt" >"$output" 2>&1
  status=$?
  set -e
  end=$(date +%s%N)
  passed=false
  [[ $status == 0 ]] && rg -q "$((id + id))" "$output" && passed=true
  row=$(jq -nc --argjson id "$id" --argjson status "$status" \
    --argjson wall_ms "$(( (end-start)/1000000 ))" --argjson passed "$passed" \
    --argjson bytes "$(wc -c <"$output")" \
    '{id:$id,status:$status,wall_ms:$wall_ms,passed:$passed,output_bytes:$bytes}')
  flock "$REQUESTS.lock" bash -c 'printf "%s\n" "$1" >>"$2"' _ "$row" "$REQUESTS"
  rm -f -- "$output"
  exit "$((status != 0))"
fi

mkdir -p "$RUN_DIR"
if [[ "${RESUME:-0}" != 1 ]]; then
  : >"$METRICS"
  : >"$REQUESTS"
fi
: >"$PROXY_LOG"

METRICS_FILE="$METRICS" PROXY_PORT=11437 UPSTREAM=http://127.0.0.1:11434 \
  bun run "$ROOT/benchmarks/hvm-metrics-proxy.ts" >"$PROXY_LOG" 2>&1 &
proxy_pid=$!
cleanup() { kill "$proxy_pid" 2>/dev/null || true; wait "$proxy_pid" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
for _ in $(seq 1 100); do
  curl -fsS --max-time 1 "$ENDPOINT/api/version" >/dev/null 2>&1 && break
  kill -0 "$proxy_pid" 2>/dev/null || { sed -n '1,120p' "$PROXY_LOG" >&2; exit 1; }
  sleep 0.25
done

if [[ "${RESUME:-0}" == 1 && -s "$REQUESTS" ]]; then
  born=$(stat -c %W "$REQUESTS")
  (( born > 0 )) && start=$((born * 1000000000)) || start=$(date +%s%N)
else
  start=$(date +%s%N)
fi
export ROOT ENDPOINT RUN_DIR METRICS REQUESTS
if [[ "${RESUME:-0}" == 1 ]]; then
  awk 'NR == FNR { done[$1] = 1; next } !done[$1]' <(jq -r 'select(.passed) | .id' "$REQUESTS") <(seq 1 "$COUNT") \
    | xargs -P "$CONCURRENCY" -n 1 "$ROOT/benchmarks/measure-1000-hvm.sh" worker
else
  seq 1 "$COUNT" | xargs -P "$CONCURRENCY" -n 1 "$ROOT/benchmarks/measure-1000-hvm.sh" worker
fi
end=$(date +%s%N)
cleanup
trap - EXIT

for _ in $(seq 1 100); do
  [[ $(wc -l <"$METRICS") -ge $COUNT ]] && break
  sleep 0.25
done

jq -n \
  --argjson count "$COUNT" --argjson concurrency "$CONCURRENCY" \
  --argjson wall_ns "$((end-start))" \
  --slurpfile requests "$REQUESTS" --slurpfile metrics "$METRICS" \
  ($requests | sort_by(.id) | group_by(.id) | map(max_by(.passed))) as $r |
   ($metrics | map(select(.id != null)) | sort_by(.id) | group_by(.id) | map(last)) as $m |
   ($r|sort_by(.wall_ms)) as $sorted |
   {questions:$count,concurrency:$concurrency,wall_s:($wall_ns/1e9),
    completed:($r|length),passed:($r|map(select(.passed))|length),failed:($r|map(select(.passed|not))|length),
    requests_per_s:(($r|length)/($wall_ns/1e9)),
    output_tokens:($m|map(.eval_count // 0)|add),
    aggregate_output_tok_s:(($m|map(.eval_count // 0)|add)/($wall_ns/1e9)),
    mean_decode_tok_s:(($m|map(.eval_count // 0)|add)/(($m|map(.eval_duration // 0)|add)/1e9)),
    p50_hvm_ms:($sorted[((($sorted|length)*0.50)|floor)].wall_ms),
    p95_hvm_ms:($sorted[((($sorted|length)*0.95)|floor)].wall_ms),
    p99_hvm_ms:($sorted[((($sorted|length)*0.99)|floor)].wall_ms),
    ollama_metric_rows:($m|length)}' | tee "$SUMMARY"

#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${1:-$ROOT/benchmarks/knob-results.jsonl}
MODEL=${HVM_GEMMA_MODEL:-gemma4:26b}
PRIMARY=${HVM_GEMMA_ENDPOINT:-http://127.0.0.1:11434}
ISOLATED=http://127.0.0.1:11436
PROMPT='Reply exactly with CALIBRATION_OK and nothing else.'
SERVER_PID=

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

snapshot() {
  local endpoint=$1
  curl -fsS --max-time 3 "$endpoint/api/ps" 2>/dev/null || printf '{"models":[]}'
}

run_case() {
  local axis=$1 value=$2 endpoint=$3
  shift 3
  local tmp start end status output ps gpu bytes passed
  tmp=$(mktemp)
  start=$(date +%s%N)
  set +e
  env \
    HVM_GEMMA_MODEL="$MODEL" \
    HVM_GEMMA_ENDPOINT="$endpoint" \
    HVM_GEMMA_NUM_PREDICT=96 \
    HVM_GEMMA_NUM_CTX=2048 \
    HVM_GEMMA_KEEP_ALIVE=10m \
    HVM_GEMMA_TEMPERATURE=0 \
    OLLAMA_NUM_PARALLEL=1 \
    "$@" \
    "$ROOT/run.sh" "$PROMPT" >"$tmp" 2>&1
  status=$?
  set -e
  end=$(date +%s%N)
  output=$(<"$tmp")
  bytes=$(wc -c <"$tmp")
  ps=$(snapshot "$endpoint")
  gpu=$(nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || true)
  passed=false
  if [[ $status == 0 && "$output" == *CALIBRATION_OK* && "$output" != *HVM_GEMMA_ERROR:* ]]; then
    passed=true
  fi
  jq -nc \
    --arg ts "$(date -u +%FT%TZ)" \
    --arg axis "$axis" --arg value "$value" --arg model "$MODEL" --arg endpoint "$endpoint" \
    --argjson status "$status" --argjson wall_ms "$(( (end - start) / 1000000 ))" \
    --argjson output_bytes "$bytes" --arg output "$output" --argjson passed "$passed" \
    --argjson ollama_ps "$ps" --arg gpu "$gpu" \
    '{ts:$ts,axis:$axis,value:$value,model:$model,endpoint:$endpoint,status:$status,wall_ms:$wall_ms,output_bytes:$output_bytes,passed:$passed,output:$output,ollama_ps:$ollama_ps,gpu_csv:$gpu}' \
    | tee -a "$OUT"
  rm -f -- "$tmp"
}

start_isolated() {
  local kv=$1 parallel=$2
  cleanup
  SERVER_PID=
  OLLAMA_HOST=127.0.0.1:11436 \
  OLLAMA_MODELS="${OLLAMA_MODELS:-${XDG_CACHE_HOME:-$HOME/.cache}/ollama/models}" \
  OLLAMA_FLASH_ATTENTION=1 \
  OLLAMA_KV_CACHE_TYPE="$kv" \
  OLLAMA_NUM_PARALLEL="$parallel" \
  OLLAMA_MAX_LOADED_MODELS=1 \
    ollama serve >"$ROOT/build/ollama-tuning-$kv-p$parallel.log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 120); do
    curl -fsS --max-time 1 "$ISOLATED/api/version" >/dev/null 2>&1 && return 0
    kill -0 "$SERVER_PID" 2>/dev/null || return 1
    sleep 0.25
  done
  return 1
}

: >"$OUT"

for value in 32 96 224; do
  run_case num_predict "$value" "$PRIMARY" HVM_GEMMA_NUM_PREDICT="$value"
done
for value in 1024 2048 4096; do
  run_case num_ctx "$value" "$PRIMARY" HVM_GEMMA_NUM_CTX="$value"
done
for value in 0 10m; do
  run_case keep_alive "$value" "$PRIMARY" HVM_GEMMA_KEEP_ALIVE="$value"
done
for value in 0 0.2 0.7; do
  run_case temperature "$value" "$PRIMARY" HVM_GEMMA_TEMPERATURE="$value"
done

# Free the primary model before loading isolated server variants on the same GPU.
ollama stop "$MODEL" >/dev/null 2>&1 || true
for value in f16 q8_0; do
  start_isolated "$value" 1
  run_case kv_cache "$value" "$ISOLATED" OLLAMA_KV_CACHE_TYPE="$value"
done
for value in 1 2; do
  start_isolated q8_0 "$value"
  run_case parallelism "$value" "$ISOLATED" OLLAMA_NUM_PARALLEL="$value"
done
cleanup
SERVER_PID=

jq -s '{runs:length,passed:map(select(.passed))|length,failed:map(select(.passed|not))|length,by_axis:(group_by(.axis)|map({axis:.[0].axis,fastest:(min_by(.wall_ms)|{value,wall_ms}),runs:map({value,wall_ms,passed,gpu_csv})}))}' "$OUT"

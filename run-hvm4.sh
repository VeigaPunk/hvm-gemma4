#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HVM4_ROOT=${HVM4_ROOT:-/home/arara/Projects/HVM4}

# Toolchain identity + compatibility gates
BEND_BIN=${BEND_BIN:-${BEND:-$(command -v bend 2>/dev/null || true)}}
HVM4_BIN=${HVM4_BIN:-$HVM4_ROOT/src/hvm}

BEND_REQUIRED_MAJOR=0
BEND_REQUIRED_MINOR=2
BEND_REQUIRED_PATCH=38
HVM4_REQUIRED_MAJOR=4
HVM4_REQUIRED_MINOR=0

MODEL=${HVM_GEMMA_MODEL:-gemma4-hvm:a4b-q4-k-m}
ENDPOINT=${HVM_GEMMA_ENDPOINT:-http://127.0.0.1:11434}
CONNECT_TIMEOUT=${HVM_GEMMA_CONNECT_TIMEOUT:-2}
HTTP_TIMEOUT=${HVM_GEMMA_HTTP_TIMEOUT:-300}
NUM_CTX=${HVM_GEMMA_NUM_CTX:-2048}
REQUESTED_PREDICT=${HVM_GEMMA_NUM_PREDICT:-96}
TEMPERATURE=${HVM_GEMMA_TEMPERATURE:-0.2}
SEED=${HVM_GEMMA_SEED:-42}
KEEP_ALIVE=${HVM_GEMMA_KEEP_ALIVE:-10m}
THINK=${HVM_GEMMA_THINK:-false}
SYSTEM=${HVM_GEMMA_SYSTEM:-Follow the requested output format exactly. Do not add markdown fences, explanations, or commentary.}
PROMPT=${*:-Reply exactly: HVM4_OK}

system_command() {
  local cmd=$1
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "HVM4_CONTROL_ERROR: missing command '$cmd'" >&2
    exit 1
  fi
}

parse_version() {
  local input=$1
  local out_major out_minor out_patch
  IFS='.' read -r out_major out_minor out_patch <<<"${input#v}"
  if [[ -z "$out_major" || -z "$out_minor" ]]; then
    return 1
  fi
  out_patch=${out_patch:-0}
  if ! [[ $out_major =~ ^[0-9]+$ && $out_minor =~ ^[0-9]+$ && $out_patch =~ ^[0-9]+$ ]]; then
    return 1
  fi
  echo "$out_major $out_minor $out_patch"
}

require_bend_version() {
  local output major minor patch
  if ! output=$("$1" --version 2>&1); then
    echo "HVM4_CONTROL_ERROR: failed to run '$1 --version'" >&2
    exit 1
  fi
  read -r major minor patch <<<"$(parse_version "$(printf '%s' "$output" | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)" || true)"
  if [[ -z "$major" || -z "$minor" || "$major" -ne "$2" || "$minor" -ne "$3" || "$patch" -ne "$4" ]]; then
    echo "HVM4_CONTROL_ERROR: unsupported Bend version (found $output; require ${2}.${3}.${4})" >&2
    exit 1
  fi
}

require_hvm4_version() {
  local output major minor patch
  if ! output=$("$1" --version 2>&1); then
    echo "HVM4_CONTROL_ERROR: failed to run '$1 --version'" >&2
    exit 1
  fi
  read -r major minor patch <<<"$(parse_version "$(printf '%s' "$output" | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)" || true)"
  if [[ -z "$major" || -z "$minor" || "$major" -ne "$2" || "$minor" -ne "$3" ]]; then
    echo "HVM4_CONTROL_ERROR: unsupported HVM4 version (found $output; require ${2}.${3}.x)" >&2
    exit 1
  fi
}

validate_endpoint() {
  local endpoint=$1
  if [[ -z "$endpoint" || ! "$endpoint" =~ ^https?://[^[:space:]]+$ ]]; then
    echo "HVM4_CONTROL_ERROR: invalid endpoint" >&2
    return 1
  fi
  while [[ "$endpoint" == */ ]]; do
    endpoint=${endpoint%/}
  done
  if [[ -z "$endpoint" ]]; then
    echo "HVM4_CONTROL_ERROR: invalid endpoint" >&2
    return 1
  fi
  ENDPOINT=$endpoint
}

validate_model() {
  local value=$1
  if [[ -z "$value" ]] || [[ "$value" =~ [[:space:]] ]]; then
    echo "HVM4_CONTROL_ERROR: invalid model" >&2
    return 1
  fi
}

validate_int_range() {
  local label=$1 value=$2 min=$3 max=$4
  if ! [[ $value =~ ^-?[0-9]+$ ]]; then
    echo "HVM4_CONTROL_ERROR: ${label} must be integer" >&2
    return 1
  fi
  if (( value < min || value > max )); then
    echo "HVM4_CONTROL_ERROR: ${label} out of range" >&2
    return 1
  fi
}

validate_double_range() {
  local label=$1 value=$2 min=$3 max=$4
  if ! [[ $value =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    echo "HVM4_CONTROL_ERROR: ${label} must be numeric" >&2
    return 1
  fi
  if awk -v v="$value" -v min="$min" -v max="$max" 'BEGIN{if(v+0<min || v+0>max) exit 1}'; then
    :
  else
    echo "HVM4_CONTROL_ERROR: ${label} out of range" >&2
    return 1
  fi
}

validate_bool() {
  local value=$1
  case "$value" in
    true|false|1|0)
      ;;
    *)
      echo "HVM4_CONTROL_ERROR: think must be true|false|1|0" >&2
      return 1
      ;;
  esac
}

validate_keep_alive() {
  local value=$1
  # Ollama accepts duration strings (10m, 1h) or bare seconds. Also accept
  # legacy parenthesized defaults like "(10m)" by stripping surrounding parens.
  value=${value#(}
  value=${value%)}
  if ! [[ $value =~ ^-?[0-9]+([smhd])?$ ]]; then
    echo "HVM4_CONTROL_ERROR: keep_alive invalid" >&2
    return 1
  fi
  KEEP_ALIVE=$value
}

system_command "$BEND_BIN"
system_command "curl"
system_command "jq"
[[ -x "$BEND_BIN" ]] || { echo "HVM4_CONTROL_ERROR: BEND_BIN not executable" >&2; exit 1; }
[[ -x "$HVM4_BIN" ]] || { echo "HVM4_ERROR: build $HVM4_ROOT/src/hvm first" >&2; exit 1; }

# Hardened preflight identity checks for the exact toolchain we target.
require_bend_version "$BEND_BIN" "$BEND_REQUIRED_MAJOR" "$BEND_REQUIRED_MINOR" "$BEND_REQUIRED_PATCH"
require_hvm4_version "$HVM4_BIN" "$HVM4_REQUIRED_MAJOR" "$HVM4_REQUIRED_MINOR"

if ! validate_endpoint "$ENDPOINT"; then
  exit 1
fi
if ! validate_model "$MODEL"; then
  exit 1
fi
if ! validate_int_range "connect timeout" "$CONNECT_TIMEOUT" 1 86400; then
  exit 1
fi
if ! validate_int_range "http timeout" "$HTTP_TIMEOUT" 1 86400; then
  exit 1
fi
if ! validate_int_range "num_ctx" "$NUM_CTX" 128 1048576; then
  exit 1
fi
if ! validate_int_range "num_predict" "$REQUESTED_PREDICT" 1 1048576; then
  exit 1
fi
if ! validate_double_range "temperature" "$TEMPERATURE" 0 2; then
  exit 1
fi
if ! validate_int_range "seed" "$SEED" -2147483648 2147483647; then
  exit 1
fi
if ! validate_bool "$THINK"; then
  exit 1
fi
if ! validate_keep_alive "$KEEP_ALIVE"; then
  exit 1
fi
if [[ ${#SYSTEM} -gt 4096 ]]; then
  echo "HVM4_CONTROL_ERROR: system prompt too long" >&2
  exit 1
fi

if [[ "$THINK" == "1" ]]; then
  THINK_JSON=true
elif [[ "$THINK" == "0" ]]; then
  THINK_JSON=false
else
  THINK_JSON=$THINK
fi

umask 077
REQUEST_FILE=$(mktemp)
RESPONSE_FILE=$(mktemp)
CONTROL_SOURCE=$(mktemp)
CONTROL_PROGRAM=$(mktemp)
cleanup() { rm -f -- "$REQUEST_FILE" "$RESPONSE_FILE" "$CONTROL_SOURCE" "$CONTROL_PROGRAM"; }
trap cleanup EXIT INT TERM

cat >"$CONTROL_SOURCE" <<EOF
# Generated by run-hvm4.sh

def main:
  return $REQUESTED_PREDICT
EOF

set +e
"$BEND_BIN" gen-hvm "$CONTROL_SOURCE" --hvm-bin "$HVM4_BIN" >"$CONTROL_PROGRAM"
status=$?
set -e
if (( status != 0 )); then
  echo "HVM4_CONTROL_ERROR: Bend generation failed (status $status)" >&2
  exit "$status"
fi
set +e
NUM_PREDICT_OUTPUT=$("$HVM4_BIN" "$CONTROL_PROGRAM" -C1)
status=$?
set -e
if (( status != 0 )); then
  echo "HVM4_CONTROL_ERROR: HVM4 execution failed (status $status)" >&2
  exit "$status"
fi

NUM_PREDICT=$(printf '%s\n' "$NUM_PREDICT_OUTPUT" | grep -Eo '^[0-9]+' | head -n1)
if [[ -z "$NUM_PREDICT" || "$NUM_PREDICT" != "$REQUESTED_PREDICT" ]]; then
  echo "HVM4_CONTROL_ERROR: unexpected budget result" >&2
  exit 1
fi

jq -nc \
  --arg model "$MODEL" \
  --arg prompt "$PROMPT" \
  --arg system "$SYSTEM" \
  --arg keep_alive "$KEEP_ALIVE" \
  --argjson num_ctx "$NUM_CTX" \
  --argjson num_predict "$NUM_PREDICT" \
  --argjson temperature "$TEMPERATURE" \
  --argjson seed "$SEED" \
  --argjson think "$THINK_JSON" \
  '{model:$model,prompt:$prompt,system:$system,stream:false,think:$think,keep_alive:$keep_alive,
    options:{num_ctx:$num_ctx,num_predict:$num_predict,temperature:$temperature,seed:$seed}}' \
  >"$REQUEST_FILE"

curl -fsS --connect-timeout "$CONNECT_TIMEOUT" --max-time "$HTTP_TIMEOUT" \
  "$ENDPOINT/api/generate" -H 'Content-Type: application/json' \
  --data-binary @"$REQUEST_FILE" >"$RESPONSE_FILE"
if ! jq -er '.response | strings' "$RESPONSE_FILE"; then
  error=$(jq -r '.error // "invalid response"' "$RESPONSE_FILE" 2>/dev/null || printf 'invalid JSON response')
  printf 'HVM4_GEMMA_ERROR: %s\n' "$error" >&2
  exit 1
fi

if [[ "${HVM4_GEMMA_METRICS:-0}" == 1 ]]; then
  jq '{eval_count,eval_duration,prompt_eval_count,prompt_eval_duration,total_duration,load_duration,
       output_tok_s:(.eval_count/(.eval_duration/1000000000))}' "$RESPONSE_FILE" >&2
fi

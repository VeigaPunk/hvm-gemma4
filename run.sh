#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
PROJECT_DIR=$(dirname -- "$SCRIPT_PATH")

# Prefer env pin, then cargo registry build of HVM 2.0.22, then PATH.
if [[ -z "${HVM_PATH:-}" ]]; then
  CANDIDATE=$(find "${CARGO_HOME:-$HOME/.cargo}/registry/src" -path '*/hvm-2.0.22/target/debug/hvm' -type f 2>/dev/null | head -1 || true)
  if [[ -n "$CANDIDATE" ]]; then
    HVM_PATH=$CANDIDATE
  elif command -v hvm >/dev/null 2>&1; then
    HVM_PATH=$(command -v hvm)
  else
    echo "HVM_GEMMA_ERROR: set HVM_PATH to an HVM 2.0.22 binary" >&2
    exit 1
  fi
fi

if (( $# == 0 )); then
  PROMPT='In one sentence, explain why a mixture-of-experts model activates only some experts.'
else
  PROMPT="$*"
fi
umask 077
PROMPT_FILE=$(mktemp)
printf '%s' "$PROMPT" >"$PROMPT_FILE"
unset HVM_GEMMA_PROMPT

OLLAMA_ENDPOINT=${HVM_GEMMA_ENDPOINT:-${OLLAMA_ENDPOINT:-http://127.0.0.1:11434}}
OLLAMA_READY_TIMEOUT=${OLLAMA_READY_TIMEOUT:-15}
OLLAMA_READY_MAX_ATTEMPTS=${OLLAMA_READY_MAX_ATTEMPTS:-60}
OLLAMA_READY_INTERVAL=${OLLAMA_READY_INTERVAL:-0.25}
OLLAMA_READY_REQUEST_TIMEOUT=${OLLAMA_READY_REQUEST_TIMEOUT:-2}
OLLAMA_CONNECT_TIMEOUT=${OLLAMA_CONNECT_TIMEOUT:-2}
OLLAMA_MAX_TIME=${OLLAMA_MAX_TIME:-5}
OLLAMA_SHUTDOWN_GRACE=${OLLAMA_SHUTDOWN_GRACE:-2}
STARTED_OLLAMA=0
OLLAMA_PID=

cleanup() {
  if [[ "$STARTED_OLLAMA" == 1 && -n "$OLLAMA_PID" ]]; then
    terminate_owned_ollama
    STARTED_OLLAMA=0
    OLLAMA_PID=
  fi
  rm -f -- "$PROMPT_FILE"
}

terminate_owned_ollama() {
  local grace_ns start_ns elapsed_ns

  kill -TERM "$OLLAMA_PID" 2>/dev/null || true

  grace_ns=$(awk -v value="$OLLAMA_SHUTDOWN_GRACE" 'BEGIN {
      if (value ~ /^[0-9]+(\.[0-9]+)?$/) {
        printf "%d", value * 1000000000;
      } else if (value ~ /^0+$/) {
        print 0;
      } else {
        print 2000000000;
      }
    }')
  if (( grace_ns <= 0 )); then
    kill -KILL "$OLLAMA_PID" 2>/dev/null || true
    wait "$OLLAMA_PID" 2>/dev/null || true
    return
  fi
  start_ns=$(date +%s%N)

  while kill -0 "$OLLAMA_PID" 2>/dev/null; do
    elapsed_ns=$(( $(date +%s%N) - start_ns ))
    if (( elapsed_ns >= grace_ns )); then
      kill -KILL "$OLLAMA_PID" 2>/dev/null || true
      break
    fi
    sleep 0.05
  done
  wait "$OLLAMA_PID" 2>/dev/null || true
}

on_signal() {
  cleanup
  case "$1" in
    INT) exit 130 ;;
    TERM) exit 143 ;;
  esac
}

trap cleanup EXIT
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

ollama_ready() {
  local command=(curl -fsS --connect-timeout "$OLLAMA_CONNECT_TIMEOUT" --max-time "$OLLAMA_MAX_TIME" "$OLLAMA_ENDPOINT/api/version")
  local response

  if [[ -x /usr/bin/timeout ]]; then
    response=$(/usr/bin/timeout "$OLLAMA_READY_REQUEST_TIMEOUT" "${command[@]}" 2>/dev/null) || return 1
  else
    response=$("${command[@]}" 2>/dev/null) || return 1
  fi

  jq -e '.version? and (.version | type == "string" and test("^[0-9]+(\\.[0-9]+){1,2}$"))' >/dev/null 2>&1 <<<"$response"
}

ollama_ready_loop() {
  local deadline=$((SECONDS + OLLAMA_READY_TIMEOUT))

  if ollama_ready; then
    return 0
  fi

  OLLAMA_MODELS="${OLLAMA_MODELS:-${XDG_CACHE_HOME:-$HOME/.cache}/ollama/models}"
  OLLAMA_FLASH_ATTENTION="${OLLAMA_FLASH_ATTENTION:-1}"
  OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-f16}"
  OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-128}"
  OLLAMA_MAX_LOADED_MODELS="${OLLAMA_MAX_LOADED_MODELS:-1}"

  env \
    OLLAMA_MODELS="$OLLAMA_MODELS" \
    OLLAMA_FLASH_ATTENTION="$OLLAMA_FLASH_ATTENTION" \
    OLLAMA_KV_CACHE_TYPE="$OLLAMA_KV_CACHE_TYPE" \
    OLLAMA_NUM_PARALLEL="$OLLAMA_NUM_PARALLEL" \
    OLLAMA_MAX_LOADED_MODELS="$OLLAMA_MAX_LOADED_MODELS" \
    ollama serve >build/ollama.log 2>&1 &
  OLLAMA_PID=$!
  STARTED_OLLAMA=1

  for _ in $(seq 1 "$OLLAMA_READY_MAX_ATTEMPTS"); do
    if ! kill -0 "$OLLAMA_PID" 2>/dev/null; then
      echo "HVM_GEMMA_ERROR: owned Ollama exited during startup" >&2
      return 1
    fi
    if ollama_ready; then
      return 0
    fi
    if (( SECONDS >= deadline )); then
      break
    fi
    sleep "$OLLAMA_READY_INTERVAL"
  done

  return 1
}

cd "$PROJECT_DIR"
make --no-print-directory >/dev/null
export HVM_GEMMA_ENDPOINT="$OLLAMA_ENDPOINT"

if ! ollama_ready_loop; then
  if [[ "$STARTED_OLLAMA" == 1 ]] && ! kill -0 "$OLLAMA_PID" 2>/dev/null; then
    echo "HVM_GEMMA_ERROR: owned Ollama exited during startup" >&2
  else
    echo "HVM_GEMMA_ERROR: Ollama did not become ready" >&2
  fi
  exit 1
fi

set +e
HVM_GEMMA_PROMPT_FILE="$PROMPT_FILE" bend --hvm-bin "$HVM_PATH" run-c main.bend -s
STATUS=$?
set -e
cleanup
exit "$STATUS"

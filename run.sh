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
PROMPT_FILE=$(mktemp)
trap 'rm -f -- "$PROMPT_FILE"' EXIT
printf '%s' "$PROMPT" >"$PROMPT_FILE"

OLLAMA_ENDPOINT=${OLLAMA_ENDPOINT:-http://127.0.0.1:11434}
OLLAMA_READY_TIMEOUT=${OLLAMA_READY_TIMEOUT:-15}
OLLAMA_READY_MAX_ATTEMPTS=${OLLAMA_READY_MAX_ATTEMPTS:-60}
OLLAMA_READY_INTERVAL=${OLLAMA_READY_INTERVAL:-0.25}
OLLAMA_READY_REQUEST_TIMEOUT=${OLLAMA_READY_REQUEST_TIMEOUT:-2}
OLLAMA_CONNECT_TIMEOUT=${OLLAMA_CONNECT_TIMEOUT:-2}
OLLAMA_MAX_TIME=${OLLAMA_MAX_TIME:-5}
STARTED_OLLAMA=0
OLLAMA_PID=

cleanup() {
  if [[ "$STARTED_OLLAMA" == 1 && -n "$OLLAMA_PID" ]]; then
    kill "$OLLAMA_PID" 2>/dev/null || true
    wait "$OLLAMA_PID" 2>/dev/null || true
  fi
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
  local command=(curl -fsS --connect-timeout "$OLLAMA_CONNECT_TIMEOUT" --max-time "$OLLAMA_MAX_TIME" "$OLLAMA_ENDPOINT/")
  if [[ -x /usr/bin/timeout ]]; then
    /usr/bin/timeout "$OLLAMA_READY_REQUEST_TIMEOUT" "${command[@]}" >/dev/null 2>&1
  else
    "${command[@]}" >/dev/null 2>&1
  fi
}

ollama_ready_loop() {
  local deadline=$((SECONDS + OLLAMA_READY_TIMEOUT))

  if ollama_ready; then
    return 0
  fi

  OLLAMA_MODELS="${OLLAMA_MODELS:-/home/arara/.cache/ollama/models}"
  OLLAMA_FLASH_ATTENTION="${OLLAMA_FLASH_ATTENTION:-1}"
  OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-f16}"
  OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-128}"
  OLLAMA_MAX_LOADED_MODELS="${OLLAMA_MAX_LOADED_MODELS:-1}"

  umask 077
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

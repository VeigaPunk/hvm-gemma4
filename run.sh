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
PROMPT=${*:-In one sentence, explain why a mixture-of-experts model activates only some experts.}
STARTED_OLLAMA=0
OLLAMA_PID=

cleanup() {
  if [[ "$STARTED_OLLAMA" == 1 && -n "$OLLAMA_PID" ]]; then
    kill "$OLLAMA_PID" 2>/dev/null || true
    wait "$OLLAMA_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

cd "$PROJECT_DIR"
make --no-print-directory >/dev/null

if ! curl -fsS http://127.0.0.1:11434/ >/dev/null 2>&1; then
  OLLAMA_MODELS=/home/arara/.cache/ollama/models \
  OLLAMA_FLASH_ATTENTION=1 \
  OLLAMA_KV_CACHE_TYPE=f16 \
  OLLAMA_NUM_PARALLEL=1 \
  OLLAMA_MAX_LOADED_MODELS=1 \
    ollama serve >build/ollama.log 2>&1 &
  OLLAMA_PID=$!
  STARTED_OLLAMA=1
  for _ in $(seq 1 60); do
    if curl -fsS http://127.0.0.1:11434/ >/dev/null 2>&1; then
      break
    fi
    sleep 0.25
  done
fi

if ! curl -fsS http://127.0.0.1:11434/ >/dev/null 2>&1; then
  echo "HVM_GEMMA_ERROR: Ollama did not become ready" >&2
  exit 1
fi

PROMPT_EXPR=$(jq -Rn --arg prompt "$PROMPT" '$prompt')
exec bend --hvm-bin "$HVM_PATH" run-c main.bend "$PROMPT_EXPR" -s

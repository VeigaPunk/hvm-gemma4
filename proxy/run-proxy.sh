#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
cd "$SCRIPT_DIR"
export XBREED_HVM_PORT="${XBREED_HVM_PORT:-11435}"
export HVM_GEMMA_MODEL="${HVM_GEMMA_MODEL:-gemma4-hvm:a4b-q4-k-m}"
export XBREED_HVM_API_KEY="${XBREED_HVM_API_KEY:-xbreed-hvm}"
export XBREED_HVM_VIA="${XBREED_HVM_VIA:-gemma-hvm4}"
export HVM_GEMMA_BIN="${HVM_GEMMA_BIN:-$SCRIPT_DIR/../run-hvm4.sh}"
export MODEL_TAG="${MODEL_TAG:-$HVM_GEMMA_MODEL}"

CHECK_SCRIPT=${HVM4_PROVENANCE_CHECK_SCRIPT:-"$SCRIPT_DIR/../check-hvm4-provenance.sh"}
"$CHECK_SCRIPT"
exec bun run src/server.ts

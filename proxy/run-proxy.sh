#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"
export XBREED_HVM_PORT="${XBREED_HVM_PORT:-11435}"
export HVM_GEMMA_MODEL="${HVM_GEMMA_MODEL:-gemma4-hvm:official-q4}"
export XBREED_HVM_API_KEY="${XBREED_HVM_API_KEY:-xbreed-hvm}"
# Prefer direct gemma-hvm (same path xbreed ask gemma uses under the hood)
export XBREED_HVM_VIA="${XBREED_HVM_VIA:-gemma-hvm}"
exec bun run src/server.ts

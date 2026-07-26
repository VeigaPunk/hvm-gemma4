#!/usr/bin/env bash
# xbreed g- lane proxy, pinned to the locally-registered official-q4 build.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
cd "$ROOT"
# shellcheck disable=SC1091
. ./local.env
# shellcheck disable=SC1091
. ./tuned.env

export MODEL_TAG="gemma4-hvm:official-q4"
export HVM_GEMMA_MODEL="$MODEL_TAG"
export GGUF_SOURCE_PATH="$HOME/.local/share/hvm-gemma4/models/google-gemma-4-26B-A4B-it-qat-q4_0/gemma-4-26B_q4_0-it.gguf"
export SCRIPT_SOURCE_SHA256=3eca3b8f6d7baf218a7dd6bba5fb59a56ee25fe2d567b6f5f589b4f697eca51d
export EXPECTED_TAG_DIGEST=23686e1fe3248deb4fc19071e07bb151464979cbfc3501414f3ad7fd1ac6e0f4
export EXPECTED_QUANTIZATION=Q4_0
export EXPECTED_PARAMETER_SIZE=25.2B
export XBREED_HVM_PORT="${XBREED_HVM_PORT:-11435}"
export XBREED_HVM_API_KEY="${XBREED_HVM_API_KEY:-xbreed-hvm}"
export XBREED_HVM_STREAMING="${XBREED_HVM_STREAMING:-1}"
export HVM_GEMMA_BIN="$ROOT/run-hvm4.sh"

exec ./proxy/run-proxy.sh

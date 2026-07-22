#!/usr/bin/env bash
set -euo pipefail

MODEL_TAG=${MODEL_TAG:-"gemma4-hvm:a4b-q4-k-m"}
ENDPOINT=${HVM_GEMMA_ENDPOINT:-${OLLAMA_ENDPOINT:-http://127.0.0.1:11434}}
GGUF_SOURCE_PATH=${GGUF_SOURCE_PATH:-"${XDG_DATA_HOME:-$HOME/.local/share}/hvm-gemma4/models/google-gemma-4-26B-A4B-it-qat-q4_0/gemma-4-26B_q4_0-it.gguf"}
SCRIPT_SOURCE_SHA256=${SCRIPT_SOURCE_SHA256:-"9b80864609ad06712727eb3ec0ef5d06fe8c2c781bb5a09558ac5c6031b7ecb3"}
EXPECTED_TAG_DIGEST=${EXPECTED_TAG_DIGEST:-"d23853cf4d7858342b66aeadc47258ce68f348ccc0dd5c757065844a7b6266a8"}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "HVM4_PROVENANCE_ERROR: missing required command '$1'" >&2
    return 1
  }
}

require_cmd sha256sum
require_cmd curl
require_cmd jq

if [[ ! -f "$GGUF_SOURCE_PATH" ]]; then
  echo "HVM4_PROVENANCE_ERROR: source GGUF missing: $GGUF_SOURCE_PATH" >&2
  exit 1
fi

source_sha=$(sha256sum -- "$GGUF_SOURCE_PATH" | awk '{print $1}')
if [[ "$source_sha" != "$SCRIPT_SOURCE_SHA256" ]]; then
  echo "HVM4_PROVENANCE_ERROR: source GGUF sha mismatch (found $source_sha, expected $SCRIPT_SOURCE_SHA256)" >&2
  exit 1
fi

request=$(jq -c -n --arg model "$MODEL_TAG" '{name:$model}')
response=$(mktemp)
trap 'rm -f "$response"' EXIT

if ! curl -fsS -H 'Content-Type: application/json' --data-binary "$request" "$ENDPOINT/api/show" >"$response"; then
  echo "HVM4_PROVENANCE_ERROR: failed to query $ENDPOINT/api/show for $MODEL_TAG" >&2
  exit 1
fi

if ! jq -e '.["name"] or .details.model' "$response" >/dev/null 2>&1; then
  # tolerate shape shifts, but require valid JSON for fail-closed behavior
  echo "HVM4_PROVENANCE_ERROR: invalid ollama show response for $MODEL_TAG" >&2
  exit 1
fi

tag_digest=$(jq -r '.details.digest // .modelinfo.digest // .model_info.digest // .digest // empty' "$response")
quantization=$(jq -r '.details.quantization_level // empty' "$response")
parameter_size=$(jq -r '.details.parameter_size // empty' "$response")

if [[ -z "$tag_digest" ]]; then
  echo "HVM4_PROVENANCE_ERROR: missing model digest for $MODEL_TAG" >&2
  exit 1
fi
if [[ "$tag_digest" != "$EXPECTED_TAG_DIGEST" ]]; then
  echo "HVM4_PROVENANCE_ERROR: digest mismatch for $MODEL_TAG (found $tag_digest, expected $EXPECTED_TAG_DIGEST)" >&2
  exit 1
fi

if [[ "$quantization" != "Q4_K_M" ]]; then
  echo "HVM4_PROVENANCE_ERROR: unexpected quantization for $MODEL_TAG (found '$quantization', expected 'Q4_K_M')" >&2
  exit 1
fi
if [[ "$parameter_size" != "25.2B" ]]; then
  echo "HVM4_PROVENANCE_ERROR: unexpected parameter_size for $MODEL_TAG (found '$parameter_size', expected '25.2B')" >&2
  exit 1
fi

cat <<EOF
OK model provenance verified
model=$MODEL_TAG
source_sha256=$SCRIPT_SOURCE_SHA256
tag_digest=$tag_digest
parameter_size=$parameter_size
quantization=$quantization
EOF

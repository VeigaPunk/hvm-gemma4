#!/usr/bin/env bash
set -euo pipefail

REPOSITORY=google/gemma-4-26B-A4B-it-qat-q4_0-gguf
REVISION=d1c082be9cf3c8a514acf63b8761f4b41935842e
FILENAME=gemma-4-26B_q4_0-it.gguf
MODEL_DIR=${MODEL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/hvm-gemma4/models/google-gemma-4-26B-A4B-it-qat-q4_0}

mkdir -p "$MODEL_DIR"
hf download \
  "$REPOSITORY" \
  "$FILENAME" \
  --revision "$REVISION" \
  --local-dir "$MODEL_DIR"

sha256sum "$MODEL_DIR/$FILENAME"

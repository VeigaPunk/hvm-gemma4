#!/usr/bin/env bash
# Default Gemma lane: Bend 0.2.38 control generation → HVM4 4.0.x → Ollama.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec "$ROOT/run-hvm4.sh" "$@"

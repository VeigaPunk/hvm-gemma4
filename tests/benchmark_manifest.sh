#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
MANIFEST_PATH=${MANIFEST:-"$SCRIPT_DIR/../benchmarks/manifest.json"}

if [[ ! -f "$MANIFEST_PATH" ]]; then
  echo "MANIFEST_MISSING: $MANIFEST_PATH" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "MISSING_DEPENDENCY: jq" >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { echo "MISSING_DEPENDENCY: sha256sum" >&2; exit 2; }

declared_count=$(jq '.checks.prompt_count' "$MANIFEST_PATH")
if [[ "$declared_count" == "null" ]]; then
  echo "INVALID_MANIFEST: checks.prompt_count missing" >&2
  exit 2
fi

cal_count=$(jq '.calibration | length' "$MANIFEST_PATH")
hold_count=$(jq '.heldout | length' "$MANIFEST_PATH")
actual_count=$((cal_count + hold_count))
if [[ "$actual_count" -ne "$declared_count" ]]; then
  echo "PROMPT_COUNT_MISMATCH: declared=$declared_count actual=$actual_count" >&2
  exit 2
fi

declared_hash=$(jq -r '.checks.prompt_hash' "$MANIFEST_PATH")
if [[ -z "$declared_hash" || "$declared_hash" == "__PLACEHOLDER__" ]]; then
  echo "INVALID_MANIFEST: checks.prompt_hash unset" >&2
  exit 2
fi

audit_payload=$(jq -cS '{calibration: .calibration, heldout: .heldout}' "$MANIFEST_PATH")
actual_hash=$(printf '%s' "$audit_payload" | sha256sum | awk '{print $1}')
if [[ "$actual_hash" != "$declared_hash" ]]; then
  echo "PROMPT_HASH_MISMATCH: declared=$declared_hash actual=$actual_hash" >&2
  exit 2
fi

# Required fields and split correctness.
jq -e '.calibration[] | (.id|type=="string" and length>0) and (.prompt|type=="string" and length>0) and (.split=="calibration") and (.case_type|type=="string" and length>0)' "$MANIFEST_PATH" >/dev/null
jq -e '.heldout[] | (.id|type=="string" and length>0) and (.prompt|type=="string" and length>0) and (.split=="heldout") and (.case_type|type=="string" and length>0)' "$MANIFEST_PATH" >/dev/null
jq -e '(.calibration + .heldout)[] | (.validator.kind == "exact" and (.validator.expected|type=="string" and length>0)) or (.validator.kind == "regex" and (.validator.pattern|type=="string" and length>0)) or (.validator.kind == "canonical_json" and (.validator.expected != null))' "$MANIFEST_PATH" >/dev/null

id_count=$(jq '[.calibration[].id, .heldout[].id] | length' "$MANIFEST_PATH")
uniq_count=$(jq '[.calibration[].id, .heldout[].id] | unique | length' "$MANIFEST_PATH")
if [[ "$id_count" -ne "$uniq_count" ]]; then
  echo "DUPLICATE_IDS: manifest has duplicate prompt IDs" >&2
  exit 2
fi

# No exact prompt overlap across splits (anti-pseudoreplication check).
common_prompts=$(jq -r '[.calibration[].prompt] as $cal | [.heldout[].prompt | . as $prompt | select($cal | index($prompt))] | length' "$MANIFEST_PATH")
if [[ "$common_prompts" -ne 0 ]]; then
  echo "LEAKAGE_CONTROL_FAIL: identical text appears across calibration and heldout" >&2
  exit 2
fi

echo "BENCHMARK_MANIFEST_OK"
echo "count=$actual_count"
echo "hash=$actual_hash"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
PROJECT_DIR=$(dirname -- "$SCRIPT_PATH")
REPO_ROOT=$(dirname -- "$PROJECT_DIR")

MANIFEST_PATH=${MANIFEST:-"$PROJECT_DIR/manifest.json"}
OUT=${OUT:-"$PROJECT_DIR/output.jsonl"}
MODE=${MODE:-all}
DRY_RUN_RAW=${DRY_RUN:-false}
RUNNER=${RUNNER:-"$REPO_ROOT/run.sh"}

DRY_RUN=false
case "${DRY_RUN_RAW,,}" in
  1|true|yes|on) DRY_RUN=true ;;
esac

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "REQUIRED_MISSING: $1" >&2
    exit 2
  }
}

require_cmd jq
require_cmd sha256sum

if [[ ! -f "$MANIFEST_PATH" ]]; then
  echo "MANIFEST_MISSING: $MANIFEST_PATH" >&2
  exit 2
fi

manifest_check_count=$(jq -r '.checks.prompt_count' "$MANIFEST_PATH")
if [[ "$manifest_check_count" == "null" || -z "$manifest_check_count" ]]; then
  echo "MANIFEST_INVALID: missing checks.prompt_count" >&2
  exit 2
fi

cal_count=$(jq '.calibration | length' "$MANIFEST_PATH")
hold_count=$(jq '.heldout | length' "$MANIFEST_PATH")
actual_count=$((cal_count + hold_count))
if [[ "$actual_count" -ne "$manifest_check_count" ]]; then
  echo "MANIFEST_COUNT_MISMATCH: checks=$manifest_check_count actual=$actual_count" >&2
  exit 2
fi

manifest_payload=$(jq -cS '{calibration: .calibration, heldout: .heldout}' "$MANIFEST_PATH")
manifest_hash=$(printf '%s' "$manifest_payload" | sha256sum | awk '{print $1}')
expected_hash=$(jq -r '.checks.prompt_hash' "$MANIFEST_PATH")
if [[ "$expected_hash" == "__PLACEHOLDER__" || -z "$expected_hash" ]]; then
  echo "MANIFEST_HASH_UNSET: checks.prompt_hash is placeholder or empty" >&2
  exit 2
fi
if [[ "$manifest_hash" != "$expected_hash" ]]; then
  echo "MANIFEST_HASH_MISMATCH: $manifest_hash != $expected_hash" >&2
  exit 2
fi

case "$MODE" in
  calibration|heldout|all) ;;
  *)
    echo "MODE must be one of: calibration|heldout|all" >&2
    exit 2
    ;;
esac

# Effective benchmark-time env used by run.sh / bridge
HVM_GEMMA_MODEL=${HVM_GEMMA_MODEL:-gemma4-hvm:official-q4}
HVM_GEMMA_NUM_CTX=${HVM_GEMMA_NUM_CTX:-2048}
HVM_GEMMA_NUM_PREDICT=${HVM_GEMMA_NUM_PREDICT:-256}
HVM_GEMMA_TEMPERATURE=${HVM_GEMMA_TEMPERATURE:-0}
HVM_GEMMA_SEED=${HVM_GEMMA_SEED:-42}
HVM_GEMMA_KEEP_ALIVE=${HVM_GEMMA_KEEP_ALIVE:-10m}
HVM_GEMMA_THINK=${HVM_GEMMA_THINK:-false}
HVM_GEMMA_ENDPOINT=${HVM_GEMMA_ENDPOINT:-${OLLAMA_ENDPOINT:-http://127.0.0.1:11434}}

export HVM_GEMMA_MODEL HVM_GEMMA_NUM_CTX HVM_GEMMA_NUM_PREDICT HVM_GEMMA_TEMPERATURE HVM_GEMMA_SEED HVM_GEMMA_KEEP_ALIVE HVM_GEMMA_THINK HVM_GEMMA_ENDPOINT

collect_env_json() {
  local env_json='{}'
  while IFS='=' read -r k v; do
    env_json=$(jq -c --arg key "$k" --arg val "$v" '. + {($key): $val}' <<<"$env_json")
  done < <(env | grep -E '^HVM_GEMMA_|^OLLAMA_ENDPOINT=' | sort)
  printf '%s' "$env_json"
}

collect_cache_state() {
  local endpoint=$1
  curl -fsS --max-time 2 "$endpoint/api/ps" 2>/dev/null || printf '{"models":[]}'
}

collect_model_digest() {
  local endpoint=$1
  local payload
  payload=$(curl -fsS --max-time 2 -X POST "$endpoint/api/show" -H 'Content-Type: application/json' \
    -d "{\"name\":\"$HVM_GEMMA_MODEL\"}" 2>/dev/null || printf '{}')
  jq -r 'if .digest then .digest elif .modelinfo and .modelinfo.digest then .modelinfo.digest else empty end' <<<"$payload"
}

build_record() {
  local prompt_id=$1 split=$2 case_type=$3 prompt=$4 status=$5 wall_time_ms=$6
  local stdout_file=$7 stderr_file=$8
  local digest=$9 cache_before=${10} cache_after=${11}

  local env_json now_ns
  env_json=$(collect_env_json)
  now_ns=$(date +%s%N)

  jq -c -n \
    --arg run_id "$RUN_ID" \
    --arg manifest_path "$MANIFEST_PATH" \
    --arg manifest_hash "$manifest_hash" \
    --arg run_mode "$MODE" \
    --arg prompt_id "$prompt_id" \
    --arg split "$split" \
    --arg case_type "$case_type" \
    --arg prompt "$prompt" \
    --arg model "$HVM_GEMMA_MODEL" \
    --arg endpoint "$HVM_GEMMA_ENDPOINT" \
    --argjson num_ctx "$HVM_GEMMA_NUM_CTX" \
    --argjson num_predict "$HVM_GEMMA_NUM_PREDICT" \
    --arg temperature "$HVM_GEMMA_TEMPERATURE" \
    --argjson seed "$HVM_GEMMA_SEED" \
    --arg keep_alive "$HVM_GEMMA_KEEP_ALIVE" \
    --arg think "$HVM_GEMMA_THINK" \
    --arg dry "$DRY_RUN" \
    --argjson status "$status" \
    --arg wall_time_ms "$wall_time_ms" \
    --arg digest "$digest" \
    --argjson count_ok true \
    --arg now_ns "$now_ns" \
    --argjson prompt_len ${#prompt} \
    --rawfile stdout "$stdout_file" \
    --rawfile stderr "$stderr_file" \
    --arg cache_before "$cache_before" \
    --arg cache_after "$cache_after" \
    --argjson env_json "$env_json" \
    '{
      ts: ($now_ns | tonumber / 1000000000 | strftime("%Y-%m-%dT%H:%M:%SZ")),
      run_id: $run_id,
      manifest: { path: $manifest_path, prompt_hash: $manifest_hash },
      run_mode: $run_mode,
      split: $split,
      prompt_id: $prompt_id,
      case_type: $case_type,
      prompt: $prompt,
      prompt_len_bytes: $prompt_len,
      hvm_gemma_env: $env_json,
      request: {
        model: $model,
        endpoint: $endpoint,
        keep_alive: $keep_alive,
        options: {
          num_ctx: $num_ctx,
          num_predict: $num_predict,
          temperature: ($temperature | tonumber),
          seed: $seed
        },
        think: ($think == "true" or $think == "1" or $think == "TRUE" or $think == "True" or $think == "yes"),
        stream: false
      },
      result: {
        mode: (if $dry == "true" then "dry-run" else "runtime" end),
        status: $status,
        wall_time_ms: ($wall_time_ms | tonumber),
        stdout: $stdout,
        stderr: $stderr,
        stdout_bytes: ($stdout | length),
        stderr_bytes: ($stderr | length)
      },
      diagnostics: {
        model_digest: $digest,
        cache_state: {
          before: ($cache_before | fromjson),
          after: ($cache_after | fromjson)
        }
      },
      validators: {
        manifest_count_match: $count_ok,
        prompt_nonempty: ($prompt_len > 0),
        runner_invoked: (if $dry == "true" then false else true end),
        exit_ok: ($status == 0),
        no_drop: true
      }
    }' >>"$OUT"
}

run_case() {
  local prompt_id=$1 split=$2 case_type=$3 prompt=$4
  local stdout_file stderr_file
  local cache_before digest_before cache_after status
  local start_ns end_ns wall_ms

  stdout_file=$(mktemp)
  stderr_file=$(mktemp)

  cache_before=$(collect_cache_state "$HVM_GEMMA_ENDPOINT")
  digest_before=$(collect_model_digest "$HVM_GEMMA_ENDPOINT")

  start_ns=$(date +%s%N)
  if [[ "$DRY_RUN" == "true" ]]; then
    printf 'DRY-RUN: skipped execution\n' >"$stdout_file"
    printf 'DRY-RUN mode; no model execution\n' >"$stderr_file"
    status=0
  else
    set +e
    "$RUNNER" "$prompt" >"$stdout_file" 2>"$stderr_file"
    status=$?
    set -e
  fi
  end_ns=$(date +%s%N)
  wall_ms=$(awk -v s="$start_ns" -v e="$end_ns" 'BEGIN { printf "%.3f", (e - s)/1000000 }')

  cache_after=$(collect_cache_state "$HVM_GEMMA_ENDPOINT")
  digest_after=$(collect_model_digest "$HVM_GEMMA_ENDPOINT")
  if [[ -z "$digest_after" ]]; then
    digest_after=$digest_before
  fi

  build_record "$prompt_id" "$split" "$case_type" "$prompt" "$status" "$wall_ms" "$stdout_file" "$stderr_file" "$digest_after" "$cache_before" "$cache_after"

  rm -f -- "$stdout_file" "$stderr_file"
  if [[ "$status" -ne 0 ]]; then
    ((failed_count+=1))
  fi
}

run_cases_from_group() {
  local expr=$1
  while IFS= read -r line; do
    case_index=$((case_index + 1))
    run_case "$(jq -r '.id' <<<"$line")" \
      "$(jq -r '.split' <<<"$line")" \
      "$(jq -r '.case_type' <<<"$line")" \
      "$(jq -r '.prompt' <<<"$line")"
  done < <(jq -c "$expr" "$MANIFEST_PATH")
}

RUN_ID="bench-$(date +%s)-$$"
case_index=0
failed_count=0
mkdir -p -- "$(dirname -- "$OUT")"
: >"$OUT"

if [[ "$MODE" == "calibration" || "$MODE" == "all" ]]; then
  run_cases_from_group '.calibration[]'
fi
if [[ "$MODE" == "heldout" || "$MODE" == "all" ]]; then
  run_cases_from_group '.heldout[]'
fi

echo "WROTE=$OUT"
echo "FAILED=$failed_count"

if [[ "$failed_count" -gt 0 ]]; then
  exit 1
fi

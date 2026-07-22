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

HVM_GEMMA_MODEL=${HVM_GEMMA_MODEL:-gemma4-hvm:official-q4}
HVM_GEMMA_NUM_CTX=${HVM_GEMMA_NUM_CTX:-2048}
HVM_GEMMA_NUM_PREDICT=${HVM_GEMMA_NUM_PREDICT:-256}
HVM_GEMMA_TEMPERATURE=${HVM_GEMMA_TEMPERATURE:-0}
HVM_GEMMA_SEED=${HVM_GEMMA_SEED:-42}
HVM_GEMMA_KEEP_ALIVE=${HVM_GEMMA_KEEP_ALIVE:-10m}
HVM_GEMMA_THINK=${HVM_GEMMA_THINK:-false}
HVM_GEMMA_SYSTEM=${HVM_GEMMA_SYSTEM:-Follow the requested output format exactly. Do not add markdown fences, explanations, or commentary.}
HVM_GEMMA_ENDPOINT=${HVM_GEMMA_ENDPOINT:-${OLLAMA_ENDPOINT:-http://127.0.0.1:11434}}

export HVM_GEMMA_MODEL HVM_GEMMA_NUM_CTX HVM_GEMMA_NUM_PREDICT HVM_GEMMA_TEMPERATURE HVM_GEMMA_SEED HVM_GEMMA_KEEP_ALIVE HVM_GEMMA_THINK HVM_GEMMA_SYSTEM HVM_GEMMA_ENDPOINT

collect_env_json() {
  local env_json='{}'
  while IFS='=' read -r k v; do
    env_json=$(jq -c --arg key "$k" --arg val "$v" '. + {($key): $val}' <<<"$env_json")
  done < <(env | grep -E '^HVM_GEMMA_|^OLLAMA_ENDPOINT=' | sort)
  printf '%s' "$env_json"
}

collect_cache_state() {
  local endpoint=$1
  local payload status='ok'
  if ! payload=$(curl -fsS --max-time 2 "$endpoint/api/ps" 2>/dev/null); then
    status='error'
    payload='{}'
  fi
  if ! jq -e . >/dev/null 2>&1 <<<"$payload"; then
    status='parse_error'
    payload='{}'
  fi
  jq -c -n --arg status "$status" --argjson state "$payload" '{status: $status, state: $state}'
}

collect_model_digest() {
  local endpoint=$1
  local payload status='ok' digest
  if ! payload=$(curl -fsS --max-time 2 -X POST "$endpoint/api/show" -H 'Content-Type: application/json' \
      -d "{\"name\":\"$HVM_GEMMA_MODEL\"}" 2>/dev/null); then
    status='error'
    payload='{}'
  fi

  if ! jq -e . >/dev/null 2>&1 <<<"$payload"; then
    status='parse_error'
    payload='{}'
  fi

  digest=$(jq -r 'if .digest then .digest elif .modelinfo and .modelinfo.digest then .modelinfo.digest else empty end' <<<"$payload")
  if [[ -z "$digest" && "$status" == 'ok' ]]; then
    status='missing'
  fi

  jq -c -n --arg status "$status" --arg value "$digest" '{status: $status, value: $value}'
}

collect_runner_provenance() {
  local configured=$1
  local resolved hash status

  if [[ -x "$configured" || -f "$configured" ]]; then
    resolved=$(readlink -f -- "$configured" || printf '%s' "$configured")
    if [[ -f "$resolved" ]]; then
      hash=$(sha256sum -- "$resolved" 2>/dev/null | awk '{print $1}')
      if [[ -n "$hash" ]]; then
        status='ok'
      else
        status='unreadable'
      fi
    else
      status='unresolved'
    fi
  else
    status='missing'
  fi

  printf '%s' "$(jq -c -n --arg configured "$configured" --arg resolved "${resolved:-}" --arg hash "${hash:-}" --arg status "$status" '{configured: $configured, resolved: $resolved, sha256: $hash, status: $status}')"
}

collect_first_response() {
  local text=$1
  local started=0 output=''
  while IFS= read -r line || [[ -n "$line" ]]; do
    if ((started == 0)); then
      if [[ "$line" == response:* ]]; then
        started=1
        output=${line#*response:}
      elif [[ "$line" != * ]]; then
        :
      fi
      if (( started == 0 )) && [[ -n "$line" ]]; then
        output=$line
        started=1
      fi
    else
      output+=$'\n'"$line"
    fi
  done <<<"$text"

  if [[ -z "$output" ]]; then
    output=$text
  fi
  printf '%s' "$output"
}

normalize_output() {
  local text line last
  local -a lines
  text=$(collect_first_response "$1")
  mapfile -t lines <<<"$text"

  while ((${#lines[@]} > 0)); do
    last=$((${#lines[@]} - 1))
    line=${lines[$last]%$'\r'}
    if [[ -z "$line" || "$line" =~ ^(Result:|-[[:space:]]ITRS:|-[[:space:]]TIME:|-[[:space:]]MIPS:)[[:space:]] ]]; then
      unset 'lines[last]'
    else
      break
    fi
  done
  while ((${#lines[@]} > 0)) && [[ -z "${lines[0]}" ]]; do
    lines=("${lines[@]:1}")
  done
  ((${#lines[@]} > 0)) && printf '%s' "$(printf '%s\n' "${lines[@]}")" || true
}

validate_output() {
  local kind=$1
  local expected=$2
  local normalized=$3

  case "$kind" in
    exact)
      [[ "$normalized" == "$expected" ]]
      return
      ;;
    regex)
      [[ "$normalized" =~ ^($expected)$ ]]
      return
      ;;
    json|canonical_json)
      local actual_json expected_json
      actual_json=$(jq -ceS --slurp 'if length == 1 then .[0] else error("expected one JSON value") end' <<<"$normalized") || return 2
      expected_json=$(jq -ceS --slurp 'if length == 1 then .[0] else error("expected one JSON value") end' <<<"$expected") || return 2
      [[ "$actual_json" == "$expected_json" ]]
      return
      ;;
    *)
      return 3
      ;;
  esac
}

build_record() {
  local prompt_id=$1 split=$2 case_type=$3 prompt=$4 status=$5 wall_time_ms=$6
  local stdout_file=$7 stderr_file=$8
  local digest_before=${9} digest_after=${10} cache_before=${11} cache_after=${12}
  local validator_kind=${13:-unsupported} validator_expected=${14:-} validator_passed=${15:-false}
  local validator_error=${16:-} no_drop_flag=${17:-true}

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
    --arg system_prompt "$HVM_GEMMA_SYSTEM" \
    --arg dry "$DRY_RUN" \
    --argjson status "$status" \
    --arg wall_time_ms "$wall_time_ms" \
    --arg validator_kind "$validator_kind" \
    --arg validator_expected "$validator_expected" \
    --arg validator_passed "$validator_passed" \
    --arg validator_error "$validator_error" \
    --arg no_drop_flag "$no_drop_flag" \
    --arg env_json "$env_json" \
    --arg env_json "$env_json" \
    --argjson prompt_len ${#prompt} \
    --arg now_ns "$now_ns" \
    --argjson count_ok true \
    --arg runner_resolved "$RUNNER_RESOLVED" \
    --arg runner_configured "$RUNNER_CONFIGURED" \
    --arg runner_hash "$RUNNER_HASH" \
    --arg runner_hash_status "$RUNNER_HASH_STATUS" \
    --rawfile stdout "$stdout_file" \
    --rawfile stderr "$stderr_file" \
    --arg digest_before "$digest_before" \
    --arg digest_after "$digest_after" \
    --arg cache_before "$cache_before" \
    --arg cache_after "$cache_after" \
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
      hvm_gemma_env: ($env_json | fromjson),
      request: {
        model: $model,
        endpoint: $endpoint,
        keep_alive: $keep_alive,
        system: $system_prompt,
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
        runner: {
          configured_path: $runner_configured,
          resolved_path: $runner_resolved,
          sha256: $runner_hash,
          sha256_status: $runner_hash_status
        },
        model_digest: {
          before: ($digest_before | try fromjson catch {}),
          after: ($digest_after | try fromjson catch {})
        },
        validator: {
          kind: $validator_kind,
          expected: $validator_expected,
          passed: ($validator_passed == "true"),
          error: ($validator_error | length > 0),
          error_message: ($validator_error | if length > 0 then . else null end)
        },
        cache_state: {
          before: ($cache_before | try fromjson catch {}),
          after: ($cache_after | try fromjson catch {})
        }
      },
      validators: {
        manifest_count_match: $count_ok,
        prompt_nonempty: ($prompt_len > 0),
        runner_invoked: (if $dry == "true" then false else true end),
        exit_ok: ($status == 0),
        validator_passed: ($validator_passed == "true"),
        validator_error: ($validator_error | length > 0),
        no_drop: ($no_drop_flag == "true")
      }
    }' >>"$OUT"
}

run_case() {
  local prompt_id=$1 split=$2 case_type=$3 prompt=$4
  local stdout_file stderr_file
  local cache_before cache_after digest_before digest_after
  local status start_ns end_ns wall_ms rc
  local validator_kind='unsupported' validator_expected='' validator_passed='false' validator_error=''

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
    if [[ "$RUNNER_HASH_STATUS" == ok ]]; then
      "$RUNNER_RESOLVED" "$prompt" >"$stdout_file" 2>"$stderr_file"
      status=$?
    else
      printf 'RUNNER_INVALID: %s\n' "$RUNNER_CONFIGURED" >"$stderr_file"
      status=126
    fi
    set -e
  fi
  end_ns=$(date +%s%N)
  wall_ms=$(awk -v s="$start_ns" -v e="$end_ns" 'BEGIN { printf "%.3f", (e - s)/1000000 }')

  cache_after=$(collect_cache_state "$HVM_GEMMA_ENDPOINT")
  digest_after=$(collect_model_digest "$HVM_GEMMA_ENDPOINT")

  local normalized
  normalized=$(normalize_output "$(<"$stdout_file")")
  if [[ -n "$DRY_RUN" && "$DRY_RUN" == "true" && -z "$normalized" ]]; then
    normalized=$(cat "$stdout_file")
  fi

  validator_kind=$(jq -r '.validator.kind // "unsupported"' <<<"$case_json")
  case "$validator_kind" in
    exact)
      validator_expected=$(jq -r '.validator.expected' <<<"$case_json")
      ;;
    regex)
      validator_expected=$(jq -r '.validator.pattern // empty' <<<"$case_json")
      ;;
    json|canonical_json)
      validator_expected=$(jq -c '.validator.expected // empty' <<<"$case_json")
      ;;
  esac

  if [[ "$validator_kind" == "exact" || "$validator_kind" == "regex" || "$validator_kind" == "json" || "$validator_kind" == "canonical_json" ]]; then
    if validate_output "$validator_kind" "$validator_expected" "$normalized"; then
      validator_passed=true
    else
      rc=$?
      if [[ "$rc" -gt 1 ]]; then
        validator_error="validate-output-$rc"
      fi
    fi
  fi

  emitted_case_order+=("$prompt_id")
  emitted_case_count["$prompt_id"]=$(( ${emitted_case_count["$prompt_id"]:-0} + 1 ))

  build_record "$prompt_id" "$split" "$case_type" "$prompt" "$status" "$wall_ms" \
    "$stdout_file" "$stderr_file" "$digest_before" "$digest_after" "$cache_before" "$cache_after" \
    "$validator_kind" "$validator_expected" "$validator_passed" "$validator_error" true

  if [[ "$status" -ne 0 || "$validator_passed" != true ]]; then
    failed_count=$((failed_count + 1))
  fi

  rm -f -- "$stdout_file" "$stderr_file"
}

build_missing_row() {
  local case_json=$1
  local prompt_id split case_type prompt

  prompt_id=$(jq -r '.id' <<<"$case_json")
  split=$(jq -r '.split' <<<"$case_json")
  case_type=$(jq -r '.case_type' <<<"$case_json")
  prompt=$(jq -r '.prompt' <<<"$case_json")

  local md='{"status":"missing"}'

  emitted_case_order+=("$prompt_id")
  emitted_case_count["$prompt_id"]=$(( ${emitted_case_count["$prompt_id"]:-0} + 1 ))

  build_record "$prompt_id" "$split" "$case_type" "$prompt" 2 0 /dev/null /dev/null \
    '{"status":"ok","state":{}}' '{"status":"ok","state":{}}' \
    '{"status":"ok","state":{}}' '{"status":"ok","state":{}}' \
    'unsupported' '' 'false' 'missing-row' false

  failed_count=$((failed_count + 1))
}

run_cases_from_group() {
  local expr=$1
  while IFS= read -r line; do
    case_json=$line
    run_case "$(jq -r '.id' <<<"$line")" \
      "$(jq -r '.split' <<<"$line")" \
      "$(jq -r '.case_type' <<<"$line")" \
      "$(jq -r '.prompt' <<<"$line")"
  done < <(jq -c "$expr" "$MANIFEST_PATH")
}

validate_no_drop() {
  local expected_ids_json emitted_ids_json
  expected_ids_json='[]'
  for id in "${expected_case_order[@]}"; do
    expected_ids_json=$(jq -c --arg id "$id" '. + [$id]' <<<"$expected_ids_json")
  done

  emitted_ids_json='[]'
  for id in "${emitted_case_order[@]}"; do
    emitted_ids_json=$(jq -c --arg id "$id" '. + [$id]' <<<"$emitted_ids_json")
  done

  for id in "${expected_case_order[@]}"; do
    if [[ ${emitted_case_count["$id"]:-0} -eq 0 ]]; then
      build_missing_row "${expected_case_lookup[$id]}"
      emitted_ids_json=$(jq -c --arg id "$id" '. + [$id]' <<<"$emitted_ids_json")
    fi
  done

  if [[ "$(jq -c 'sort' <<<"$expected_ids_json")" == "$(jq -c 'sort' <<<"$emitted_ids_json")" ]]; then
    no_drop_pass=true
  else
    no_drop_pass=false
    failed_count=$((failed_count + 1))
  fi

  if [[ "$no_drop_pass" == false ]]; then
    # annotate existing rows as no-drop failed
    jq -c '.validators.no_drop = false' "$OUT" >"$OUT.tmp"
    mv -- "$OUT.tmp" "$OUT"
  fi
}

RUN_ID="bench-$(date +%s)-$$"
failed_count=0
RUNNER_INFO=$(collect_runner_provenance "$RUNNER")
RUNNER_CONFIGURED=$(jq -r '.configured' <<<"$RUNNER_INFO")
RUNNER_RESOLVED=$(jq -r '.resolved' <<<"$RUNNER_INFO")
RUNNER_HASH=$(jq -r '.sha256' <<<"$RUNNER_INFO")
RUNNER_HASH_STATUS=$(jq -r '.status' <<<"$RUNNER_INFO")

declare -a expected_case_order emitted_case_order
declare -A expected_case_lookup emitted_case_count

mkdir -p -- "$(dirname -- "$OUT")"
: >"$OUT"

case "$MODE" in
  calibration) expected_expr='.calibration[]' ;;
  heldout) expected_expr='.heldout[]' ;;
  all) expected_expr='.calibration[], .heldout[]' ;;
esac
while IFS= read -r expected_case; do
  expected_id=$(jq -r '.id' <<<"$expected_case")
  expected_case_order+=("$expected_id")
  expected_case_lookup["$expected_id"]=$expected_case
done < <(jq -c "$expected_expr" "$MANIFEST_PATH")

if [[ "$MODE" == "calibration" || "$MODE" == "all" ]]; then
  run_cases_from_group '.calibration[]'
fi
if [[ "$MODE" == "heldout" || "$MODE" == "all" ]]; then
  run_cases_from_group '.heldout[]'
fi

validate_no_drop

echo "WROTE=$OUT"
echo "FAILED=$failed_count"
echo "NO_DROP_PASS=$no_drop_pass"
echo "RUNNER_PATH=$RUNNER_RESOLVED"
echo "RUNNER_HASH=$RUNNER_HASH"
echo "RUNNER_HASH_STATUS=$RUNNER_HASH_STATUS"

if [[ "$failed_count" -gt 0 || "$no_drop_pass" != true ]]; then
  exit 1
fi

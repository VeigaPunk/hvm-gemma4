#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE=$ROOT/benchmarks/run.sh
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT INT TERM HUP

command -v jq >/dev/null 2>&1 || { echo 'Bail out! jq not found' >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { echo 'Bail out! sha256sum not found' >&2; exit 2; }

PASS=0
FAIL=0

ok() {
  printf 'ok %02d - %s\n' "$((PASS + FAIL + 1))" "$1"
  PASS=$((PASS + 1))
}

not_ok() {
  printf 'not ok %02d - %s\n' "$((PASS + FAIL + 1))" "$1"
  FAIL=$((FAIL + 1))
}

replace_once() {
  local old=$1 new=$2 file=$3
  OLD=$old NEW=$new perl -0pi -e '
    BEGIN { $old = $ENV{OLD}; $new = $ENV{NEW}; }
    $count = s/\Q$old\E/$new/;
    END { exit 65 unless $count == 1; }
  ' "$file"
}

delete_once() {
  replace_once "$1" '' "$2"
}

write_fixture_manifest() {
  local path=$1 hash payload
  jq -n '{
    schema_version: "1.0",
    suite: "benchmark-runner-mutation-fixture",
    checks: {prompt_count: 4, prompt_hash: "__HASH__"},
    calibration: [
      {id:"cal-1", split:"calibration", case_type:"fixture", prompt:"alpha"},
      {id:"cal-2", split:"calibration", case_type:"fixture", prompt:"fail"}
    ],
    heldout: [
      {id:"hold-1", split:"heldout", case_type:"fixture", prompt:"charlie"},
      {id:"hold-2", split:"heldout", case_type:"fixture", prompt:"delta"}
    ]
  }' >"$path"
  payload=$(jq -cS '{calibration: .calibration, heldout: .heldout}' "$path")
  hash=$(printf '%s' "$payload" | sha256sum | awk '{print $1}')
  jq --arg hash "$hash" '.checks.prompt_hash = $hash' "$path" >"$path.next"
  mv -- "$path.next" "$path"
}

make_stubs() {
  mkdir -p "$TMP/bin"

  cat >"$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
url=
for arg in "$@"; do
  case "$arg" in
    */api/ps|*/api/show) url=$arg ;;
  esac
done
if [[ "$url" == */api/ps ]]; then
  count_file=$MUT_STATE/cache.count
  count=0
  [[ -f "$count_file" ]] && count=$(<"$count_file")
  count=$((count + 1))
  printf '%s' "$count" >"$count_file"
  printf '{"models":[{"name":"cache-%s"}]}\n' "$count"
  exit 0
fi
if [[ "$url" == */api/show ]]; then
  count_file=$MUT_STATE/show.count
  count=0
  [[ -f "$count_file" ]] && count=$(<"$count_file")
  count=$((count + 1))
  printf '%s' "$count" >"$count_file"
  if [[ ${SHOW_SCENARIO:-stable} == retry ]]; then
    case "$count" in
      1) printf '{"digest":"digest-base"}\n' ;;
      2) printf '{}\n' ;;
      3) printf '{"digest":"digest-retry"}\n' ;;
      *) printf '{"digest":"digest-later"}\n' ;;
    esac
  else
    printf '{"digest":"digest-%s"}\n' "$count"
  fi
  exit 0
fi
printf '{}\n'
STUB

  cat >"$TMP/runner" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >>"$MUT_STATE/runner.log"
if [[ "$1" == fail ]]; then
  printf 'fixture failure\n' >&2
  exit 7
fi
printf 'response:%s\n' "$1"
STUB
  chmod +x "$TMP/bin/curl" "$TMP/runner"
}

prepare_mutant() {
  local id=$1 description=$2
  local work=$TMP/$id
  mkdir -p "$work"
  cp -- "$SOURCE" "$work/run.sh"
  shift 2
  "$@" "$work/run.sh"
  if cmp -s -- "$SOURCE" "$work/run.sh"; then
    not_ok "$id $description (mutation did not land)"
    return 1
  fi
  if ! bash -n "$work/run.sh"; then
    not_ok "$id $description (not executable shell)"
    return 1
  fi
  chmod +x "$work/run.sh"
}

execute_mutant() {
  local id=$1 scenario=${2:-stable}
  local work=$TMP/$id
  rm -rf -- "$work/state"
  mkdir -p "$work/state"
  : >"$work/state/runner.log"
  set +e
  PATH="$TMP/bin:/usr/bin:/bin" \
    MUT_STATE="$work/state" \
    SHOW_SCENARIO="$scenario" \
    MANIFEST="$TMP/manifest.json" \
    OUT="$work/output.jsonl" \
    RUNNER="$TMP/runner" \
    HVM_GEMMA_ENDPOINT=http://fixture.invalid \
    "$work/run.sh" >"$work/stdout" 2>"$work/stderr"
  STATUS=$?
  set -e
}

check_mutant() {
  local id=$1 category=$2 description=$3 assertion=$4 scenario=${5:-stable}
  execute_mutant "$id" "$scenario"
  if eval "$assertion"; then
    ok "$id $category: $description"
  else
    not_ok "$id $category: $description"
    sed 's/^/# stdout: /' "$TMP/$id/stdout"
    sed 's/^/# stderr: /' "$TMP/$id/stderr"
  fi
}

write_fixture_manifest "$TMP/manifest.json"
make_stubs

printf '1..16\n'

prepare_mutant M01 'manifest equality inverted' replace_once \
  'if [[ "$actual_count" -ne "$manifest_check_count" ]]; then' \
  'if [[ "$actual_count" -eq "$manifest_check_count" ]]; then'
check_mutant M01 'semantic inversion' 'valid manifest is rejected' \
  '[[ $STATUS == 2 ]] && grep -q "MANIFEST_COUNT_MISMATCH" "$TMP/M01/stderr"'

prepare_mutant M02 'suite result predicate inverted' replace_once \
  'if [[ "$failed_count" -gt 0 ]]; then' \
  'if [[ "$failed_count" -eq 0 ]]; then'
check_mutant M02 'semantic inversion' 'failed suite returns success' \
  '[[ $STATUS == 0 ]] && grep -q "FAILED=1" "$TMP/M02/stdout"'

prepare_mutant M03 'failure counter dropped' replace_once \
  '    ((failed_count+=1))' \
  '    :'
check_mutant M03 'dropped failures' 'nonzero case is not counted' \
  '[[ $STATUS == 0 ]] && grep -q "FAILED=0" "$TMP/M03/stdout" && jq -e "select(.prompt_id == \"cal-2\") | .result.status == 7" "$TMP/M03/output.jsonl" >/dev/null'

prepare_mutant M04 'runner status discarded' replace_once \
  '    status=$?' \
  '    status=0'
check_mutant M04 'dropped failures' 'runner exit status becomes zero' \
  '[[ $STATUS == 0 ]] && jq -e "select(.prompt_id == \"cal-2\") | .result.status == 0 and .validators.exit_ok" "$TMP/M04/output.jsonl" >/dev/null'

prepare_mutant M05 'configured runner bypassed' replace_once \
  '    "$RUNNER" "$prompt" >"$stdout_file" 2>"$stderr_file"' \
  '    : "$prompt" >"$stdout_file" 2>"$stderr_file"'
check_mutant M05 'route bypass' 'cases skip the configured runner' \
  '[[ $STATUS == 0 ]] && [[ ! -s "$TMP/M05/state/runner.log" ]] && jq -e ".validators.runner_invoked and .result.stdout == \"\"" "$TMP/M05/output.jsonl" >/dev/null'

prepare_mutant M06 'calibration routed to heldout' replace_once \
  "  run_cases_from_group '.calibration[]'" \
  "  run_cases_from_group '.heldout[]'"
check_mutant M06 'route bypass' 'calibration route executes heldout twice' \
  '[[ $STATUS == 0 ]] && [[ $(jq -r .prompt_id "$TMP/M06/output.jsonl" | paste -sd, -) == "hold-1,hold-2,hold-1,hold-2" ]]'

prepare_mutant M07 'cache labels swapped' replace_once \
  $'          before: ($cache_before | fromjson),\n          after: ($cache_after | fromjson)' \
  $'          before: ($cache_after | fromjson),\n          after: ($cache_before | fromjson)'
check_mutant M07 'cache mislabel' 'before and after cache samples are reversed' \
  '[[ $(jq -sr "first | .diagnostics.cache_state.before.models[0].name" "$TMP/M07/output.jsonl") == cache-2 ]] && [[ $(jq -sr "first | .diagnostics.cache_state.after.models[0].name" "$TMP/M07/output.jsonl") == cache-1 ]]'

prepare_mutant M08 'cache before overwritten' replace_once \
  '          before: ($cache_before | fromjson),' \
  '          before: ($cache_after | fromjson),'
check_mutant M08 'cache mislabel' 'both cache labels report the after sample' \
  '[[ $(jq -sr "first | [.diagnostics.cache_state.before.models[0].name, .diagnostics.cache_state.after.models[0].name] | join(\",\")" "$TMP/M08/output.jsonl") == cache-2,cache-2 ]]'

prepare_mutant M09 'digest value omitted' replace_once \
  '        model_digest: $digest,' \
  '        model_digest: "",'
check_mutant M09 'digest omission' 'record carries an empty digest' \
  '[[ $(jq -sr "first | .diagnostics.model_digest" "$TMP/M09/output.jsonl") == "" ]]'

prepare_mutant M10 'calibration order reversed' replace_once \
  "  run_cases_from_group '.calibration[]'" \
  "  run_cases_from_group '.calibration | reverse[]'"
check_mutant M10 'order leak' 'manifest order is not preserved' \
  '[[ $(jq -r .prompt_id "$TMP/M10/output.jsonl" | paste -sd, -) == "cal-2,cal-1,hold-1,hold-2" ]]'

prepare_mutant M11 'stdout truncated before record' replace_once \
  '  build_record "$prompt_id" "$split" "$case_type" "$prompt" "$status" "$wall_ms" "$stdout_file" "$stderr_file" "$digest_after" "$cache_before" "$cache_after"' \
  $'  : >"$stdout_file"\n  build_record "$prompt_id" "$split" "$case_type" "$prompt" "$status" "$wall_ms" "$stdout_file" "$stderr_file" "$digest_after" "$cache_before" "$cache_after"'
check_mutant M11 'truncation pass' 'successful case accepts empty captured output' \
  'jq -e "select(.prompt_id == \"cal-1\") | .validators.exit_ok and .result.stdout == \"\" and .result.stdout_bytes == 0" "$TMP/M11/output.jsonl" >/dev/null'

prepare_mutant M12 'stdout byte count forced to zero' replace_once \
  '        stdout_bytes: ($stdout | length),' \
  '        stdout_bytes: 0,'
check_mutant M12 'truncation pass' 'nonempty output is labeled zero bytes' \
  'jq -e "select(.prompt_id == \"cal-1\") | (.result.stdout | length) > 0 and .result.stdout_bytes == 0 and .validators.exit_ok" "$TMP/M12/output.jsonl" >/dev/null'

prepare_mutant M13 'only missing post-run digest retried' replace_once \
  '    digest_after=$digest_before' \
  '    digest_after=$(collect_model_digest "$HVM_GEMMA_ENDPOINT")'
check_mutant M13 'retry asymmetry' 'post-run digest gets an unpaired retry' \
  '[[ $(<"$TMP/M13/state/show.count") -ge 3 ]] && [[ $(jq -sr "first | .diagnostics.model_digest" "$TMP/M13/output.jsonl") == digest-retry ]]' retry

prepare_mutant M14 'calibration sample reduced' replace_once \
  "  run_cases_from_group '.calibration[]'" \
  "  run_cases_from_group '.calibration[0]'"
check_mutant M14 'sample reduction' 'only first calibration case executes' \
  '[[ $STATUS == 0 ]] && [[ $(wc -l <"$TMP/M14/output.jsonl") == 3 ]] && [[ $(jq -r .prompt_id "$TMP/M14/output.jsonl" | paste -sd, -) == "cal-1,hold-1,hold-2" ]]'

prepare_mutant M15 'heldout sample reduced' replace_once \
  "  run_cases_from_group '.heldout[]'" \
  "  run_cases_from_group '.heldout[0]'"
check_mutant M15 'sample reduction' 'only first heldout case executes' \
  '[[ $STATUS == 1 ]] && [[ $(wc -l <"$TMP/M15/output.jsonl") == 3 ]] && [[ $(jq -r .prompt_id "$TMP/M15/output.jsonl" | paste -sd, -) == "cal-1,cal-2,hold-1" ]]'

prepare_mutant M16 'cache resource omitted' replace_once \
  $'        cache_state: {\n          before: ($cache_before | fromjson),\n          after: ($cache_after | fromjson)\n        }' \
  '        cache_state: {}'
check_mutant M16 'resource omission' 'cache diagnostics are empty' \
  'jq -se "first | .diagnostics.cache_state == {}" "$TMP/M16/output.jsonl" >/dev/null'

if [[ "$FAIL" -ne 0 ]]; then
  printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
  exit 1
fi
printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"

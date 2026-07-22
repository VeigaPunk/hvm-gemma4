#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT INT TERM

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; exit 2; }
}

require_cmd jq
require_cmd sha256sum

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

write_manifest() {
  jq -n '{
    schema_version: "test-runtime-v1",
    suite: "benchmark-runner-runtime-fixture",
    checks: {prompt_count: 3, prompt_hash: "__HASH__"},
    calibration: [
      {id: "cal-1", split: "calibration", case_type: "exact-format", prompt: "say pong", validator: {kind: "exact", expected: "pong"}},
      {id: "cal-2", split: "calibration", case_type: "regex-format", prompt: "say ready", validator: {kind: "regex", pattern: "^ready$"}}
    ],
    heldout: [
      {id: "hold-1", split: "heldout", case_type: "canonical-json-format", prompt: "return json", validator: {kind: "canonical_json", expected: {ok: true}}}
    ]
  }' >"$TMP/manifest.json"

  local payload hash
  payload=$(jq -cS '{calibration: .calibration, heldout: .heldout}' "$TMP/manifest.json")
  hash=$(printf '%s' "$payload" | sha256sum | awk '{print $1}')
  jq --arg hash "$hash" '.checks.prompt_hash = $hash' "$TMP/manifest.json" >"$TMP/manifest.json.next"
  mv -- "$TMP/manifest.json.next" "$TMP/manifest.json"
}

write_stubs() {
  mkdir -p "$TMP/bin"

  cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *"/api/ps")
    printf '{"models":[{"name":"cache-a"}]}'
    ;;
  *"/api/show")
    printf '{"digest":"fixture-digest"}'
    ;;
  *)
    printf '{}'
    ;;
esac
EOF

  cat >"$TMP/runner-real" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  *"say pong")
    printf 'response:pong\nHVM_GEMMA_ERROR:\n'
    ;;
  *"say ready")
    printf 'response:ready-now\n'
    ;;
  *"return json")
    printf 'response:{"ok":true}\n'
    ;;
  *)
    printf 'response:unexpected\n'
    ;;
esac
EOF

  mkdir -p "$TMP/bin"
  ln -sfn "$TMP/runner-real" "$TMP/bin/runner-link"
  chmod +x "$TMP/bin/curl" "$TMP/runner-real"
}

run_suite() {
  PATH="$TMP/bin:/usr/bin:/bin" \
    MANIFEST="$TMP/manifest.json" \
    OUT="$TMP/output.jsonl" \
    RUNNER="$TMP/bin/runner-link" \
    HVM_GEMMA_ENDPOINT=http://fixture.invalid \
    bash "$ROOT/benchmarks/run.sh" >"$TMP/stdout" 2>"$TMP/stderr"
  return $?
}

write_manifest
write_stubs
set +e
run_suite
status=$?
set -e

if [[ $status -ne 1 ]]; then
  not_ok 'suite fails when regex validator mismatches output'
elif [[ $(grep -o 'FAILED=[0-9]*' "$TMP/stdout" | head -n1 | cut -d= -f2) -ne 1 ]]; then
  not_ok 'FAILED counter tracks a validator failure'
else
  rows=$(wc -l <"$TMP/output.jsonl")
  if [[ "$rows" -ne 3 ]]; then
    not_ok "three result rows are emitted (got $rows)"
  elif ! jq -e 'select(.prompt_id == "cal-2") | .validators.validator_passed == false and .validators.exit_ok == true' "$TMP/output.jsonl" >/dev/null; then
    not_ok 'validator failure emits a structured failing row'
  elif ! jq -e '.diagnostics.runner.resolved_path == "'$TMP'/runner-real"' "$TMP/output.jsonl" >/dev/null; then
    not_ok 'runner provenance records resolved runner path'
  elif ! jq -e '.diagnostics.model_digest.before.status and .diagnostics.model_digest.after.status' "$TMP/output.jsonl" >/dev/null; then
    not_ok 'digest fetch status is emitted'
  elif ! jq -e '.diagnostics.cache_state.before.status and .diagnostics.cache_state.after.status' "$TMP/output.jsonl" >/dev/null; then
    not_ok 'cache status includes explicit states'
  else
    ok 'runtime benchmark suite emits a failing row and captures validator provenance plus fetch statuses'
  fi
fi

if [[ $FAIL -ne 0 ]]; then
  printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
  exit 1
fi

printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"

#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$ROOT/run-hvm4.sh

TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT INT TERM

PASS=0
FAIL=0

REAL_BEND=$(command -v bend)
if [[ -z "$REAL_BEND" ]]; then
  echo 'Bail out! bend not installed' >&2
  exit 2
fi

SYSTEM_TEXT='Follow the requested output format exactly. Do not add markdown fences, explanations, or commentary.'
LONG_SYSTEM=$(python3 - <<'PY'
print('x' * 4100)
PY
)
BEND_LOG=$TMP/bend.log
HVM4_LOG=$TMP/hvm4.log
mkdir -p "$TMP/case"

cat >"$TMP/bend" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  echo "0.2.38"
  exit 0
fi
printf '%s\n' "$*" >>"$BEND_LOG"
exec "$REAL_BEND" "$@"
EOF
chmod +x "$TMP/bend"

cat >"$TMP/bend-old" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  echo "0.2.37"
  exit 0
fi
printf '%s\n' "$*" >>"$BEND_LOG"
exec "$REAL_BEND" "$@"
EOF
chmod +x "$TMP/bend-old"

export BEND_LOG
export HVM4_LOG
export REAL_BEND

cat >"$TMP/fake-hvm4" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  echo "4.0.2"
  exit 0
fi
printf '%s\n' "$*" >>"$HVM4_LOG"
program=${1:-}
if [[ ! -f "${program:-}" ]]; then
  echo "HVM4 fake runtime: missing program path" >&2
  exit 1
fi
EXPECTED="${HVM4_EXPECTED_PREDICT:?missing HVM4_EXPECTED_PREDICT}"
if ! grep -q "@main = $EXPECTED" "$program"; then
  echo "HVM4 fake runtime: unexpected control program" >&2
  exit 2
fi
if (( $# != 2 )) || [[ "$2" != "-C1" ]]; then
  echo "HVM4 fake runtime: unsupported scoped IO invocation" >&2
  echo "HVM4 fake runtime args: $*" >&2
  exit 4
fi
echo "$EXPECTED"
cat -- "$program" >"$HVM4_PROGRAM_PATH"
EOF
chmod +x "$TMP/fake-hvm4"

cat >"$TMP/fake-hvm4-old" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  echo "3.9.9"
  exit 0
fi
exit 2
EOF
chmod +x "$TMP/fake-hvm4-old"

cat >"$TMP/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

default_url=""
payload_file=""
prev_was_data=0
for arg in "$@"; do
  if (( prev_was_data == 1 )); then
    if [[ $arg == @* ]]; then
      payload_file="${arg#@}"
    fi
    prev_was_data=0
    continue
  fi
  if [[ $arg == "--data-binary" ]]; then
    prev_was_data=1
    continue
  fi
  if [[ $arg == http* ]]; then
    default_url=$arg
  fi
done

if [[ ! -f "$HVM4_PROGRAM_PATH" ]]; then
  echo "HVM4 fake runtime not executed before curl" >&2
  exit 3
fi

if [[ -n "$payload_file" ]]; then
  cp "$payload_file" "$CURL_PAYLOAD_FILE"
fi
if [[ -n "$default_url" ]]; then
  printf '%s\n' "$default_url" > "$CURL_URL_FILE"
fi

echo '{"response":"HVM4_OK"}'
EOF
chmod +x "$TMP/curl"

assert_body() {
  local payload=$1
  local model=$2
  local keep_alive=$3
  local num_ctx=$4
  local num_predict=$5
  local temperature=$6
  local seed=$7
  local think=$8
  local system=$9

  jq -e \
    --arg model "$model" \
    --arg keep_alive "$keep_alive" \
    --arg system "$system" \
    --argjson num_ctx "$num_ctx" \
    --argjson num_predict "$num_predict" \
    --argjson temperature "$temperature" \
    --argjson seed "$seed" \
    --argjson think "$think" \
    '
      .model == $model and
      .prompt == "pong" and
      .stream == false and
      .system == $system and
      .think == $think and
      .keep_alive == $keep_alive and
      (.options | type == "object") and
      (.options | keys == ["num_ctx","num_predict","seed","temperature"]) and
      .options.num_ctx == $num_ctx and
      .options.num_predict == $num_predict and
      (((.options.temperature - $temperature) | abs) < 1e-12) and
      .options.seed == $seed and
      (keys == ["keep_alive","model","options","prompt","stream","system","think"])
    ' "$payload" >/dev/null
}

run_case() {
  local label=$1
  local expected_endpoint=${2:-http://127.0.0.1:11434}
  local expected_model=${3:-gemma4:26b-hvm4}
  local expected_num_ctx=${4:-2048}
  local expected_num_predict=${5:-96}
  local expected_temperature=${6:-0.2}
  local expected_seed=${7:-42}
  local expected_keep_alive=${8:-10m}
  local expected_think=${9:-false}
  local expected_system=${10:-$SYSTEM_TEXT}

  local case_dir="$TMP/case"
  local body_file="$case_dir/body.json"
  local url_file="$case_dir/url.txt"
  local control_program="$case_dir/program.hvm"

  : > "$BEND_LOG"; : > "$HVM4_LOG"
  rm -f -- "$body_file" "$url_file" "$control_program"

  set +e
  HVM4_EXPECTED_PREDICT=$expected_num_predict \
  HVM4_PROGRAM_PATH=$control_program \
  CURL_PAYLOAD_FILE=$body_file \
  CURL_URL_FILE=$url_file \
  HVM4_BIN="$TMP/fake-hvm4" \
  BEND_BIN="$TMP/bend" \
  HVM4_GEMMA_CONNECT_TIMEOUT=1 \
  HVM4_GEMMA_HTTP_TIMEOUT=2 \
  HVM4_GEMMA_NUM_PREDICT=$expected_num_predict \
  HVM_GEMMA_ENDPOINT=$expected_endpoint \
  HVM_GEMMA_MODEL=$expected_model \
  HVM_GEMMA_NUM_CTX=$expected_num_ctx \
  HVM_GEMMA_TEMPERATURE=$expected_temperature \
  HVM_GEMMA_SEED=$expected_seed \
  HVM_GEMMA_THINK=$expected_think \
  HVM_GEMMA_KEEP_ALIVE=$expected_keep_alive \
  HVM_GEMMA_SYSTEM="$expected_system" \
  PATH="$TMP:$PATH" \
  bash "$SCRIPT" "pong" >/dev/null
  status=$?
  set -e

  if [[ $status != 0 ]]; then
    printf 'not ok - %s (run failed: %s)\n' "$label" "$status"
    FAIL=$((FAIL + 1))
    return 1
  fi

  if ! grep -q '^gen-hvm ' "$BEND_LOG"; then
    printf 'not ok - %s (did not call bend gen-hvm)\n' "$label"
    FAIL=$((FAIL + 1))
    return 1
  fi

  if ! assert_body "$body_file" "$expected_model" "$expected_keep_alive" \
      "$expected_num_ctx" "$expected_num_predict" "$expected_temperature" "$expected_seed" "$expected_think" "$expected_system"; then
    printf 'not ok - %s (request shape mismatch)\n' "$label"
    sed 's/^/# body: /' "$body_file"
    FAIL=$((FAIL + 1))
    return 1
  fi

  if ! grep -q "^@main = $expected_num_predict" "$control_program"; then
    printf 'not ok - %s (control program omitted requested budget)\n' "$label"
    FAIL=$((FAIL + 1))
    return 1
  fi

  if ! grep -q "^$expected_endpoint/api/generate$" "$url_file" 2>/dev/null; then
    printf 'not ok - %s (endpoint mismatch)\n' "$label"
    sed 's/^/# url: /' "$url_file"
    FAIL=$((FAIL + 1))
    return 1
  fi

  if ! grep -q '\-C1$' "$HVM4_LOG"; then
    printf 'not ok - %s (runtime scope changed)\n' "$label"
    sed 's/^/# hvm4: /' "$HVM4_LOG"
    FAIL=$((FAIL + 1))
    return 1
  fi

  printf 'ok - %s\n' "$label"
  PASS=$((PASS + 1))
}

run_invalid_case() {
  local label=$1
  local out=$TMP/case/invalid.out

  shift
  set +e
  (
    HVM4_EXPECTED_PREDICT=96
    HVM4_PROGRAM_PATH=$TMP/case/program.hvm
    CURL_PAYLOAD_FILE=$TMP/case/body.json
    CURL_URL_FILE=$TMP/case/url.txt
    HVM4_BIN=$TMP/fake-hvm4
    BEND_BIN=$TMP/bend
    HVM4_GEMMA_CONNECT_TIMEOUT=1
    HVM4_GEMMA_HTTP_TIMEOUT=2
    HVM4_GEMMA_NUM_PREDICT=96
    HVM_GEMMA_ENDPOINT=http://127.0.0.1:11434
    HVM_GEMMA_MODEL=gemma4:26b-hvm4
    HVM_GEMMA_NUM_CTX=2048
    HVM_GEMMA_TEMPERATURE=0.2
    HVM_GEMMA_SEED=42
    HVM_GEMMA_THINK=false
    HVM_GEMMA_KEEP_ALIVE=10m
    HVM_GEMMA_SYSTEM=$SYSTEM_TEXT
    PATH=$TMP:$PATH

    for kv in "$@"; do
      export "$kv"
    done

    bash "$SCRIPT" "pong" >/dev/null
  ) >"$out" 2>&1
  status=$?
  set -e

  if [[ $status == 0 ]]; then
    printf 'not ok - %s (expected validation failure)\n' "$label"
    FAIL=$((FAIL + 1))
    return 1
  fi

  if ! grep -Fq 'HVM4_CONTROL_ERROR' "$out"; then
    printf 'not ok - %s (expected control error marker)\n' "$label"
    sed 's/^/# out: /' "$out"
    FAIL=$((FAIL + 1))
    return 1
  fi

  printf 'ok - %s\n' "$label"
  PASS=$((PASS + 1))
}

printf '1..12\n'
run_case 'request shape: endpoint/model/knobs/system and generated control execution'
run_invalid_case 'invalid: endpoint must be http(s) URL' 'HVM_GEMMA_ENDPOINT=bad endpoint'
run_invalid_case 'invalid: model must be non-empty non-whitespace' "HVM_GEMMA_MODEL=bad model"
run_invalid_case 'invalid: model must not be whitespace-only' "HVM_GEMMA_MODEL=\"   \""
run_invalid_case 'invalid: num_ctx below minimum' 'HVM_GEMMA_NUM_CTX=32'
run_invalid_case 'invalid: num_predict below minimum' 'HVM_GEMMA_NUM_PREDICT=0'
run_invalid_case 'invalid: temperature out of range' 'HVM_GEMMA_TEMPERATURE=2.1'
run_invalid_case 'invalid: seed must be int' 'HVM_GEMMA_SEED=not-an-int'
run_invalid_case 'invalid: think value' 'HVM_GEMMA_THINK=yes'
run_invalid_case 'invalid: keep_alive format' 'HVM_GEMMA_KEEP_ALIVE=notaduration'
run_invalid_case 'invalid: system prompt too long' "HVM_GEMMA_SYSTEM=$LONG_SYSTEM"
run_invalid_case 'invalid: toolchain compatibility (Bend version)' "BEND_BIN=$TMP/bend-old"
run_invalid_case 'invalid: toolchain compatibility (HVM4 version)' "HVM4_BIN=$TMP/fake-hvm4-old"

printf '# pass=%d fail=%d\n' "$PASS" "$FAIL"

exit "$((FAIL != 0))"

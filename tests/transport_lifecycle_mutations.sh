#!/usr/bin/env bash
set -u

SELF=$(readlink -f -- "${BASH_SOURCE[0]}")
NAME=$(basename -- "$0")

if [[ "$NAME" != transport_lifecycle_mutations.sh ]]; then
  case "$NAME" in
    make)
      printf 'make\n' >>"$MUT_LOG"
      exit "${MAKE_EXIT:-0}"
      ;;
    curl)
      has_version_url=0
      for arg in "$@"; do
        [[ "$arg" == */api/version ]] && has_version_url=1
      done
      count=0
      [[ -f "$MUT_STATE/curl.count" ]] && read -r count <"$MUT_STATE/curl.count"
      count=$((count + 1))
      printf '%s\n' "$count" >"$MUT_STATE/curl.count"
      printf 'curl %s\n' "$count" >>"$MUT_LOG"
      case "${CURL_MODE:-ready}" in
        ready|false-positive|identity)
          if (( has_version_url )); then
            printf '{"version":"0.5.11"}\n'
          else
            printf 'ollama is running\n'
          fi
          exit 0
          ;;
        fake-root)
          printf '<!doctype html><html><body>not-ollama</body></html>\n'
          exit 0
          ;;
        wrong-identity)
          printf '{"status":"ok"}\n'
          exit 0
          ;;
        never) exit 22 ;;
        delayed)
          if (( count >= ${CURL_READY_AT:-4} )); then
            if (( has_version_url )); then
              printf '{"version":"9.9.9"}\n'
            else
              printf 'ollama is running\n'
            fi
            exit 0
          fi
          exit 22
          ;;
        hang) /usr/bin/sleep 10; exit 22 ;;
      esac
      ;;
    ollama)
      printf 'ollama %s\n' "$$" >>"$MUT_LOG"
      printf 'env OLLAMA_MODELS=%s OLLAMA_FLASH_ATTENTION=%s OLLAMA_KV_CACHE_TYPE=%s OLLAMA_NUM_PARALLEL=%s OLLAMA_MAX_LOADED_MODELS=%s HVM_GEMMA_ENDPOINT=%s\n' \
        "${OLLAMA_MODELS:-}" "${OLLAMA_FLASH_ATTENTION:-}" "${OLLAMA_KV_CACHE_TYPE:-}" "${OLLAMA_NUM_PARALLEL:-}" "${OLLAMA_MAX_LOADED_MODELS:-}" "${HVM_GEMMA_ENDPOINT:-}" >>"$MUT_LOG"
      printf '%s\n' "$$" >"$MUT_STATE/ollama.pid"
      [[ "${OLLAMA_MODE:-live}" == dead ]] && exit 23
      if [[ "${OLLAMA_MODE:-live}" == stubborn ]]; then
        trap '' TERM INT
      else
        trap 'printf "ollama-term\n" >>"$MUT_LOG"; exit 0' TERM INT
      fi
      while :; do /usr/bin/sleep 1; done
      ;;
    bend)
      printf 'bend' >>"$MUT_LOG"
      printf ' <%s>' "$@" >>"$MUT_LOG"
      printf '\n' >>"$MUT_LOG"
      printf 'HVM_GEMMA_ENDPOINT=%s\n' "${HVM_GEMMA_ENDPOINT:-}" >>"$MUT_LOG"
      printf 'prompt <%s>\n' "${HVM_GEMMA_PROMPT-__UNSET__}" >>"$MUT_LOG"
      if [[ -n "${HVM_GEMMA_PROMPT_FILE:-}" ]]; then
        printf 'prompt_file <%s>\n' "$HVM_GEMMA_PROMPT_FILE" >>"$MUT_LOG"
        if [[ -f "$HVM_GEMMA_PROMPT_FILE" ]]; then
          printf 'prompt_bytes <%s>\n' "$(wc -c <"$HVM_GEMMA_PROMPT_FILE")" >>"$MUT_LOG"
          printf 'prompt_sha256 <%s>\n' "$(sha256sum "$HVM_GEMMA_PROMPT_FILE" | awk '{print $1}')" >>"$MUT_LOG"
        fi
      fi
      if [[ "${BEND_VALIDATE_HVM:-0}" == 1 && ! -x "${2:-}" ]]; then
        printf 'bend: invalid HVM binary: %s\n' "${2:-}" >&2
        exit 66
      fi
      [[ -n "${BEND_STDOUT:-}" ]] && printf '%s\n' "$BEND_STDOUT"
      [[ -n "${BEND_STDERR:-}" ]] && printf '%s\n' "$BEND_STDERR" >&2
      exit "${BEND_EXIT:-0}"
      ;;
    jq)
      [[ "${JQ_EXIT:-0}" != 0 ]] && { printf 'jq-failed\n' >&2; exit "$JQ_EXIT"; }
      exec /usr/bin/jq "$@"
      ;;
    sleep)
      if [[ -n "${SLEEP_GATE:-}" && ! -e "$SLEEP_GATE" ]]; then
        : >"$SLEEP_GATE"
        /usr/bin/sleep 0.05
      fi
      exit 0
      ;;
    hvm) exit 0 ;;
  esac
fi

ROOT=$(cd -- "$(dirname -- "$SELF")/.." && pwd)
TMP=$(mktemp -d)
STUBS=$TMP/stubs
mkdir -p "$STUBS"
for tool in make curl ollama bend jq sleep hvm; do ln -s "$SELF" "$STUBS/$tool"; done
export MUT_STATE=$TMP/state MUT_LOG=$TMP/log
mkdir -p "$MUT_STATE"
: >"$MUT_LOG"
PASS=0
FAIL=0

reset_case() {
  : >"$MUT_LOG"
  rm -f "$MUT_STATE"/*
  unset MAKE_EXIT CURL_MODE CURL_READY_AT OLLAMA_MODE BEND_VALIDATE_HVM BEND_STDOUT BEND_STDERR BEND_EXIT JQ_EXIT SLEEP_GATE
  unset OLLAMA_READY_TIMEOUT OLLAMA_READY_MAX_ATTEMPTS OLLAMA_READY_INTERVAL OLLAMA_READY_REQUEST_TIMEOUT OLLAMA_CONNECT_TIMEOUT OLLAMA_MAX_TIME OLLAMA_SHUTDOWN_GRACE
  unset OLLAMA_MODELS OLLAMA_FLASH_ATTENTION OLLAMA_KV_CACHE_TYPE OLLAMA_NUM_PARALLEL OLLAMA_MAX_LOADED_MODELS
}

run_case() {
  local out=$TMP/out err=$TMP/err
  set +e
  PATH="$STUBS:/usr/local/bin:/usr/bin:/bin" "$ROOT/run.sh" "$@" >"$out" 2>"$err"
  STATUS=$?
  set -e
}

run_case_ms() {
  local out=$TMP/out err=$TMP/err
  local start_ns end_ns

  start_ns=$(date +%s%N)
  set +e
  PATH="$STUBS:/usr/local/bin:/usr/bin:/bin" "$ROOT/run.sh" "$@" >"$out" 2>"$err"
  STATUS=$?
  set -e
  end_ns=$(date +%s%N)
  RUN_CASE_MS=$(( (end_ns - start_ns) / 1000000 ))
}

ok() { printf 'ok %02d - %s\n' "$((PASS + FAIL + 1))" "$1"; PASS=$((PASS + 1)); }
not_ok() { printf 'not ok %02d - %s\n' "$((PASS + FAIL + 1))" "$1"; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then ok "$1"; else not_ok "$1"; fi; }

set -e
printf '1..27\n'

reset_case; export HVM_PATH=$TMP/not-executable CURL_MODE=ready
run_case pin-bypass
check 'explicit HVM_PATH is passed without shell validation' '[[ $STATUS == 0 ]] && grep -Fq "bend <--hvm-bin> <$TMP/not-executable>" "$MUT_LOG"'

reset_case; export HVM_PATH=$TMP/not-executable CURL_MODE=ready BEND_VALIDATE_HVM=1
run_case wrong-binary
check 'downstream wrong-binary failure and status propagate' '[[ $STATUS == 66 ]] && grep -Fq "invalid HVM binary" "$TMP/err"'

reset_case; export HVM_PATH=/bin/true CURL_MODE=identity
run_case already-ready
check 'ready service bypasses Ollama startup' '! grep -q "^ollama " "$MUT_LOG" && grep -q "^bend" "$MUT_LOG"'

reset_case; export HVM_PATH=/bin/true CURL_MODE=delayed CURL_READY_AT=2 OLLAMA_MODELS=/custom/models OLLAMA_FLASH_ATTENTION=0 OLLAMA_KV_CACHE_TYPE=q8_0 OLLAMA_NUM_PARALLEL=7 OLLAMA_MAX_LOADED_MODELS=3
run_case env-overrides
check 'server env overrides reach owned Ollama startup' 'grep -Fq "OLLAMA_MODELS=/custom/models" "$MUT_LOG" && grep -Fq "OLLAMA_FLASH_ATTENTION=0" "$MUT_LOG" && grep -Fq "OLLAMA_KV_CACHE_TYPE=q8_0" "$MUT_LOG" && grep -Fq "OLLAMA_NUM_PARALLEL=7" "$MUT_LOG" && grep -Fq "OLLAMA_MAX_LOADED_MODELS=3" "$MUT_LOG"'

reset_case; export HVM_PATH=/bin/true CURL_MODE=delayed CURL_READY_AT=2
run_case selected-defaults
check 'selected serving defaults reach owned Ollama startup' 'grep -Fq "OLLAMA_KV_CACHE_TYPE=q8_0" "$MUT_LOG" && grep -Fq "OLLAMA_NUM_PARALLEL=8" "$MUT_LOG" && grep -Fq "OLLAMA_MAX_LOADED_MODELS=1" "$MUT_LOG"'

reset_case; export HVM_PATH=/bin/true CURL_MODE=identity
run_case false-positive
check 'api/version identity is accepted as ready' '[[ $STATUS == 0 ]] && [[ $(cat "$MUT_STATE/curl.count") == 1 ]]'

reset_case; export HVM_PATH=/bin/true CURL_MODE=fake-root
run_case fake-root-responder
check 'fake root responder is rejected by readiness identity check' '[[ $STATUS == 1 ]] && grep -Fq "did not become ready" "$TMP/err"'

reset_case; export HVM_PATH=/bin/true CURL_MODE=delayed CURL_READY_AT=4
run_case delayed-ready
pid=$(cat "$MUT_STATE/ollama.pid"); alive=0; kill -0 "$pid" 2>/dev/null && alive=1
check 'delayed readiness starts Ollama and reaches Bend' '[[ $STATUS == 0 ]] && grep -q "^bend" "$MUT_LOG"'
(( alive == 1 )) && { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }

reset_case; export HVM_PATH=/bin/true CURL_MODE=never
run_case never-ready
check 'bounded polling reports readiness failure' '[[ $STATUS == 1 ]] && [[ $(cat "$MUT_STATE/curl.count") == 61 ]] && grep -Fq "did not become ready" "$TMP/err"'

reset_case; export HVM_PATH=/bin/true CURL_MODE=never OLLAMA_MODE=dead
run_case dead-child
check 'early Ollama death stops readiness polling immediately' '[[ $STATUS == 1 ]] && [[ $(cat "$MUT_STATE/curl.count") == 2 ]] && grep -Fq "owned Ollama exited during startup" "$TMP/err"'

reset_case; export HVM_PATH=/bin/true CURL_MODE=delayed CURL_READY_AT=2
run_case cleanup-after-exec
pid=$(cat "$MUT_STATE/ollama.pid"); alive=0; kill -0 "$pid" 2>/dev/null && alive=1
check 'owned Ollama is stopped before returning after Bend' '[[ $STATUS == 0 ]] && [[ $alive == 0 ]]'
(( alive == 1 )) && { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }

reset_case; export HVM_PATH=/bin/true CURL_MODE=delayed CURL_READY_AT=999 SLEEP_GATE=$MUT_STATE/sleep.gate
PATH="$STUBS:/usr/local/bin:/usr/bin:/bin" "$ROOT/run.sh" signal-case >"$TMP/out" 2>"$TMP/err" & runner=$!
for _ in $(seq 1 100); do [[ -e "$SLEEP_GATE" ]] && break; /usr/bin/sleep 0.01; done
for _ in $(seq 1 200); do [[ -f "$MUT_STATE/ollama.pid" ]] && break; /usr/bin/sleep 0.01; done
kill -TERM "$runner" 2>/dev/null || true
set +e; wait "$runner"; STATUS=$?; set -e
check 'TERM trap cleans child and exits with signal status' '[[ $STATUS == 143 ]] && grep -q "ollama-term" "$MUT_LOG"'

reset_case; export HVM_PATH=/bin/true CURL_MODE=never OLLAMA_READY_MAX_ATTEMPTS=10000
set +e
/usr/bin/timeout --preserve-status --signal=INT 0.2 \
  env PATH="$STUBS:/usr/local/bin:/usr/bin:/bin" "$ROOT/run.sh" signal-case >"$TMP/out" 2>"$TMP/err"
STATUS=$?
set -e
check 'INT trap cleans child and exits with signal status' '[[ $STATUS == 130 ]] && grep -q "ollama-term" "$MUT_LOG"'

reset_case; export HVM_PATH=/bin/true CURL_MODE=delayed OLLAMA_MODE=stubborn OLLAMA_READY_MAX_ATTEMPTS=1 OLLAMA_SHUTDOWN_GRACE=0.5
run_case_ms stubborn-child
pid=$(cat "$MUT_STATE/ollama.pid" 2>/dev/null || true); alive=0; [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && alive=1
check 'stubborn child is killed when grace expires' '[[ $STATUS == 1 ]] && [[ $alive == 0 ]] && ! grep -q "ollama-term" "$MUT_LOG"'
check 'stubborn child cleanup is bounded by shutdown grace' '(( RUN_CASE_MS >= 300 )) && (( RUN_CASE_MS <= 3500 ))'

reset_case; export HVM_PATH=/bin/true CURL_MODE=ready BEND_EXIT=7
run_case exit-seven
check 'Bend exit status propagates through exec' '[[ $STATUS == 7 ]]'

reset_case; export HVM_PATH=/bin/true CURL_MODE=ready BEND_STDOUT=OUT_SENTINEL BEND_STDERR=ERR_SENTINEL
run_case streams
check 'Bend stdout and stderr remain separated' 'grep -Fxq OUT_SENTINEL "$TMP/out" && grep -Fxq ERR_SENTINEL "$TMP/err" && ! grep -q ERR_SENTINEL "$TMP/out"'

reset_case; export HVM_PATH=/bin/true CURL_MODE=ready BEND_STDOUT='HVM_GEMMA_ERROR: model unavailable'
run_case bridge-error
check 'bridge error text becomes nonzero launcher status' '[[ $STATUS == 1 ]] && grep -Fxq "HVM_GEMMA_ERROR: model unavailable" "$TMP/out"'

reset_case; export HVM_PATH=/bin/true CURL_MODE=identity OLLAMA_ENDPOINT=http://127.0.0.1:11434
run_case endpoint-parity
check 'bridge endpoint export matches readiness endpoint' '[[ $STATUS == 0 ]] && grep -Fq "HVM_GEMMA_ENDPOINT=http://127.0.0.1:11434" "$MUT_LOG"'

reset_case; export HVM_PATH=/bin/true CURL_MODE=identity OLLAMA_ENDPOINT=http://ignored.example:11434 HVM_GEMMA_ENDPOINT=http://127.0.0.1:11434
run_case endpoint-override
check 'bridge-specific endpoint takes precedence for readiness and generation' '[[ $STATUS == 0 ]] && grep -Fq "HVM_GEMMA_ENDPOINT=http://127.0.0.1:11434" "$MUT_LOG" && ! grep -Fq "http://ignored.example:11434" "$MUT_LOG"'

reset_case; export HVM_PATH=/bin/true CURL_MODE=ready MAKE_EXIT=2
run_case build-failure
check 'build failure stops transport before readiness and Bend' '[[ $STATUS == 2 ]] && ! grep -q "^curl\|^bend" "$MUT_LOG"'

reset_case; export HVM_PATH=/bin/true CURL_MODE=wrong-identity
run_case wrong-identity
check 'readiness rejects non-Ollama identity responses' '[[ $STATUS == 1 ]] && grep -Fq "did not become ready" "$TMP/err"'

reset_case; export HVM_PATH=/bin/true CURL_MODE=ready
prompt_chunk=$(printf 'x%.0s' $(seq 1 1024))
long_prompt_args=()
for _ in $(seq 1 140); do long_prompt_args+=("$prompt_chunk"); done
long_prompt=$(IFS=' '; printf '%s' "${long_prompt_args[*]}")
long_prompt_bytes=${#long_prompt}
long_prompt_hash=$(printf '%s' "$long_prompt" | sha256sum | awk '{print $1}')
run_case "${long_prompt_args[@]}"
prompt_path=$(awk -F '[<>]' '/^prompt_file </ { print $2; exit }' "$MUT_LOG")
check '>128 KiB prompts use an exact, ephemeral file payload' '[[ $STATUS == 0 ]] && (( long_prompt_bytes > 128 * 1024 )) && grep -Fq "prompt <__UNSET__>" "$MUT_LOG" && grep -Fq "prompt_bytes <'"$long_prompt_bytes"'>" "$MUT_LOG" && grep -Fq "prompt_sha256 <'"$long_prompt_hash"'>" "$MUT_LOG" && [[ -n "$prompt_path" && ! -e "$prompt_path" ]]'

reset_case; export HVM_PATH=/bin/true CURL_MODE=ready
multi_prompt=$'quote " and line\nbreak'
multi_prompt_hash=$(printf '%s' "$multi_prompt" | sha256sum | awk '{print $1}')
run_case 'quote " and' $'line\nbreak'
check 'multi-argument prompt reaches the bridge byte-for-byte' 'grep -Fq "prompt_bytes <'"${#multi_prompt}"'>" "$MUT_LOG" && grep -Fq "prompt_sha256 <'"$multi_prompt_hash"'>" "$MUT_LOG"'

reset_case; export HVM_PATH=/bin/true CURL_MODE=ready
run_case ''
check 'explicit empty prompt argument remains explicit' 'grep -Fq "prompt_file <" "$MUT_LOG" && grep -Fq "prompt_bytes <0>" "$MUT_LOG"'

reset_case; unset HVM_PATH; export CARGO_HOME=$TMP/empty-cargo CURL_MODE=ready
mkdir -p "$CARGO_HOME"
run_case fallback-hvm
check 'PATH hvm fallback is selected when registry pin is absent' '[[ $STATUS == 0 ]] && grep -Fq "<$STUBS/hvm>" "$MUT_LOG"'

reset_case; export HVM_PATH=/bin/true CURL_MODE=hang OLLAMA_READY_TIMEOUT=1 OLLAMA_READY_REQUEST_TIMEOUT=0.05 OLLAMA_READY_MAX_ATTEMPTS=2
set +e
PATH="$STUBS:/usr/local/bin:/usr/bin:/bin" "$ROOT/run.sh" hang-case >"$TMP/out" 2>"$TMP/err"
STATUS=$?
set -e
check 'hung readiness curls are bounded by timeout and fail fast' '[[ $STATUS == 1 ]] && grep -Fq "did not become ready" "$TMP/err" && [[ $(cat "$MUT_STATE/curl.count") -le 3 ]]'

printf '# pass=%d fail=%d\n' "$PASS" "$FAIL"
rm -rf -- "$TMP"
exit "$((FAIL != 0))"

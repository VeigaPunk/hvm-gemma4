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
      count=0
      [[ -f "$MUT_STATE/curl.count" ]] && read -r count <"$MUT_STATE/curl.count"
      count=$((count + 1))
      printf '%s\n' "$count" >"$MUT_STATE/curl.count"
      printf 'curl %s\n' "$count" >>"$MUT_LOG"
      case "${CURL_MODE:-ready}" in
        ready|false-positive) exit 0 ;;
        never) exit 22 ;;
        delayed) (( count >= ${CURL_READY_AT:-4} )) && exit 0 || exit 22 ;;
        hang) /usr/bin/sleep 10; exit 22 ;;
      esac
      ;;
    ollama)
      printf 'ollama %s\n' "$$" >>"$MUT_LOG"
      printf '%s\n' "$$" >"$MUT_STATE/ollama.pid"
      [[ "${OLLAMA_MODE:-live}" == dead ]] && exit 23
      trap 'printf "ollama-term\n" >>"$MUT_LOG"; exit 0' TERM INT
      while :; do /usr/bin/sleep 1; done
      ;;
    bend)
      printf 'bend' >>"$MUT_LOG"
      printf ' <%s>' "$@" >>"$MUT_LOG"
      printf '\n' >>"$MUT_LOG"
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
}

run_case() {
  local out=$TMP/out err=$TMP/err
  set +e
  PATH="$STUBS:/usr/local/bin:/usr/bin:/bin" "$ROOT/run.sh" "$@" >"$out" 2>"$err"
  STATUS=$?
  set -e
}

ok() { printf 'ok %02d - %s\n' "$((PASS + FAIL + 1))" "$1"; PASS=$((PASS + 1)); }
not_ok() { printf 'not ok %02d - %s\n' "$((PASS + FAIL + 1))" "$1"; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then ok "$1"; else not_ok "$1"; fi; }

set -e
printf '1..16\n'

reset_case; export HVM_PATH=$TMP/not-executable CURL_MODE=ready
run_case pin-bypass
check 'explicit HVM_PATH is passed without shell validation' '[[ $STATUS == 0 ]] && grep -Fq "bend <--hvm-bin> <$TMP/not-executable>" "$MUT_LOG"'

reset_case; export HVM_PATH=$TMP/not-executable CURL_MODE=ready BEND_VALIDATE_HVM=1
run_case wrong-binary
check 'downstream wrong-binary failure and status propagate' '[[ $STATUS == 66 ]] && grep -Fq "invalid HVM binary" "$TMP/err"'

reset_case; export HVM_PATH=/bin/true CURL_MODE=ready
run_case already-ready
check 'ready service bypasses Ollama startup' '! grep -q "^ollama " "$MUT_LOG" && grep -q "^bend" "$MUT_LOG"'

reset_case; export HVM_PATH=/bin/true CURL_MODE=false-positive
run_case false-positive
check 'any successful root response is accepted as ready' '[[ $STATUS == 0 ]] && [[ $(cat "$MUT_STATE/curl.count") == 2 ]]'

reset_case; export HVM_PATH=/bin/true CURL_MODE=delayed CURL_READY_AT=4
run_case delayed-ready
pid=$(cat "$MUT_STATE/ollama.pid"); alive=0; kill -0 "$pid" 2>/dev/null && alive=1
check 'delayed readiness starts Ollama and reaches Bend' '[[ $STATUS == 0 ]] && grep -q "^bend" "$MUT_LOG"'
# `exec bend` replaces the trapped shell; terminate the deliberately detected orphan.
(( alive == 1 )) && { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }

reset_case; export HVM_PATH=/bin/true CURL_MODE=never
run_case never-ready
check 'bounded polling reports readiness failure' '[[ $STATUS == 1 ]] && [[ $(cat "$MUT_STATE/curl.count") == 62 ]] && grep -Fq "did not become ready" "$TMP/err"'

reset_case; export HVM_PATH=/bin/true CURL_MODE=never OLLAMA_MODE=dead
run_case dead-child
check 'early Ollama death is masked until readiness exhaustion' '[[ $STATUS == 1 ]] && [[ $(cat "$MUT_STATE/curl.count") == 62 ]]'

reset_case; export HVM_PATH=/bin/true CURL_MODE=delayed CURL_READY_AT=2
run_case cleanup-after-exec
pid=$(cat "$MUT_STATE/ollama.pid"); alive=0; kill -0 "$pid" 2>/dev/null && alive=1
check 'exec bypasses EXIT cleanup and leaves owned Ollama alive' '[[ $STATUS == 0 ]] && [[ $alive == 1 ]]'
(( alive == 1 )) && { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }

reset_case; export HVM_PATH=/bin/true CURL_MODE=never SLEEP_GATE=$MUT_STATE/sleep.gate
PATH="$STUBS:/usr/local/bin:/usr/bin:/bin" "$ROOT/run.sh" signal-case >"$TMP/out" 2>"$TMP/err" & runner=$!
for _ in $(seq 1 100); do [[ -e "$SLEEP_GATE" ]] && break; /usr/bin/sleep 0.01; done
kill -TERM "$runner" 2>/dev/null || true
set +e; wait "$runner"; STATUS=$?; set -e
check 'TERM trap cleans child but does not terminate polling immediately' '[[ $STATUS == 1 ]] && grep -q "ollama-term" "$MUT_LOG" && [[ $(cat "$MUT_STATE/curl.count") == 62 ]]'

reset_case; export HVM_PATH=/bin/true CURL_MODE=ready BEND_EXIT=7
run_case exit-seven
check 'Bend exit status propagates through exec' '[[ $STATUS == 7 ]]'

reset_case; export HVM_PATH=/bin/true CURL_MODE=ready BEND_STDOUT=OUT_SENTINEL BEND_STDERR=ERR_SENTINEL
run_case streams
check 'Bend stdout and stderr remain separated' 'grep -Fxq OUT_SENTINEL "$TMP/out" && grep -Fxq ERR_SENTINEL "$TMP/err" && ! grep -q ERR_SENTINEL "$TMP/out"'

reset_case; export HVM_PATH=/bin/true CURL_MODE=ready MAKE_EXIT=2
run_case build-failure
check 'build failure stops transport before readiness and Bend' '[[ $STATUS == 2 ]] && ! grep -q "^curl\|^bend" "$MUT_LOG"'

reset_case; export HVM_PATH=/bin/true CURL_MODE=ready JQ_EXIT=9
run_case jq-failure
check 'prompt encoding failure stops before Bend' '[[ $STATUS == 9 ]] && ! grep -q "^bend" "$MUT_LOG"'

reset_case; export HVM_PATH=/bin/true CURL_MODE=ready
run_case 'quote " and' $'line\nbreak'
check 'multi-argument prompt becomes one JSON-safe Bend argument' 'grep -Fq "<\"quote \\\" and line\\nbreak\">" "$MUT_LOG"'

reset_case; unset HVM_PATH; export CARGO_HOME=$TMP/empty-cargo CURL_MODE=ready
mkdir -p "$CARGO_HOME"
run_case fallback-hvm
check 'PATH hvm fallback is selected when registry pin is absent' '[[ $STATUS == 0 ]] && grep -Fq "<$STUBS/hvm>" "$MUT_LOG"'

reset_case; export HVM_PATH=/bin/true CURL_MODE=hang
set +e
/usr/bin/timeout -k 0.1 0.2 env PATH="$STUBS:/usr/local/bin:/usr/bin:/bin" "$ROOT/run.sh" hang-case >"$TMP/out" 2>"$TMP/err"
STATUS=$?
set -e
check 'a hung readiness curl has no internal deadline' '[[ $STATUS == 124 || $STATUS == 137 ]] && ! grep -q "^bend" "$MUT_LOG"'

printf '# pass=%d fail=%d\n' "$PASS" "$FAIL"
rm -rf -- "$TMP"
exit "$((FAIL != 0))"

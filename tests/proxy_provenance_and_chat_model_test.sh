#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PORT=11449

PASS=0
FAIL=0

ok() { printf 'ok %02d - %s\n' "$((PASS + FAIL + 1))" "$1"; PASS=$((PASS + 1)); }
not_ok() { printf 'not ok %02d - %s\n' "$((PASS + FAIL + 1))" "$1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
TRACE=$TMP/proxy-provenance-check.log
rm -f "$TRACE"
trap 'rm -rf -- "$TMP"' EXIT INT TERM HUP

cat >"$TMP/check-ok.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "check-ok" >>"$HVM4_PROVENANCE_TRACE"
echo "OK model provenance verified"
EOF
cat >"$TMP/check-fail.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "check-fail" >>"$HVM4_PROVENANCE_TRACE"
echo "HVM4_PROVENANCE_ERROR: forced-fail" >&2
exit 1
EOF
chmod +x "$TMP/check-ok.sh" "$TMP/check-fail.sh"

# Fail-closed guard: startup should fail when provenance check returns non-zero.
set +e
TRACE_FAIL=$TMP/fail.log
env HVM4_PROVENANCE_CHECK_SCRIPT="$TMP/check-fail.sh" \
  HVM4_PROVENANCE_TRACE="$TRACE" \
  XBREED_HVM_PORT=$PORT \
  bash "$ROOT/proxy/run-proxy.sh" >"$TRACE_FAIL" 2>&1
status=$?
set -e
if [[ $status -ne 0 && -f "$TRACE" ]]; then
  ok 'run-proxy fails closed when provenance check fails'
else
  not_ok 'run-proxy fails closed when provenance check fails'
fi

# Smoke check: valid check script runs before serving and invalid chat model is rejected as 400.
set +e
env HVM4_PROVENANCE_CHECK_SCRIPT="$TMP/check-ok.sh" \
  HVM4_PROVENANCE_TRACE="$TRACE" \
  XBREED_HVM_PORT=$PORT \
  HVM_GEMMA_MODEL=gemma4-hvm:a4b-q4-k-m \
  bash "$ROOT/proxy/run-proxy.sh" >"$TMP/proxy.out" 2>"$TMP/proxy.err" &
PROXY_PID=$!
set -e

ready=0
for _ in $(seq 1 80); do
  if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    ready=1
    break
  fi
  /usr/bin/sleep 0.05
done

if (( ready == 1 )); then
  CHAT_CODE=$(
    curl -sS -o "$TMP/chat.json" -w '%{http_code}' \
      -X POST "http://127.0.0.1:$PORT/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -H 'Authorization: Bearer xbreed-hvm' \
      -d '{"model":"not-a-model","messages":[{"role":"user","content":"ping"}]}'
  )
  if [[ "$CHAT_CODE" == "400" ]] && jq -e '.error.type == "invalid_request_error"' "$TMP/chat.json" >/dev/null 2>&1; then
    ok 'chat completions rejects invalid model with 400'
  else
    not_ok 'chat completions rejects invalid model with 400'
  fi
else
  not_ok 'proxy became ready for runtime model validation check'
fi

kill "$PROXY_PID" 2>/dev/null || true
wait "$PROXY_PID" 2>/dev/null || true

if grep -Fq 'check-ok' "$TRACE" 2>/dev/null; then
  ok 'provenance check executed before serving in startup path'
else
  not_ok 'provenance check executed before serving in startup path'
fi

printf '# pass=%d fail=%d\n' "$PASS" "$FAIL"
exit "$((FAIL != 0))"

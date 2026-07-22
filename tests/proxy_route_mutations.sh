#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE=$ROOT/proxy/src/server.ts
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT INT TERM HUP

PASS=0
FAIL=0

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

move_timeout_clear_before_wait() {
  local file=$1
  replace_once \
    $'  const [stdout, stderr, code] = await Promise.all([\n    new Response(proc.stdout).text(),\n    new Response(proc.stderr).text(),\n    proc.exited,\n  ]);\n  clearTimeout(timer);' \
    $'  clearTimeout(timer);\n  const [stdout, stderr, code] = await Promise.all([\n    new Response(proc.stdout).text(),\n    new Response(proc.stderr).text(),\n    proc.exited,\n  ]);' \
    "$file"
}

compile_mutant() {
  local id=$1 category=$2 description=$3
  local work=$TMP/$id
  mkdir -p "$work"
  cp -- "$SOURCE" "$work/server.ts"
  shift 3

  if ! "$@" "$work/server.ts"; then
    printf 'not ok %02d - %s/%s (mutation did not land exactly once)\n' \
      "$((PASS + FAIL + 1))" "$category" "$description"
    FAIL=$((FAIL + 1))
    return
  fi

  if cmp -s -- "$SOURCE" "$work/server.ts"; then
    printf 'not ok %02d - %s/%s (source unchanged)\n' \
      "$((PASS + FAIL + 1))" "$category" "$description"
    FAIL=$((FAIL + 1))
    return
  fi

  if bun build "$work/server.ts" --target=bun --outfile="$work/server.js" \
      >"$work/build.out" 2>&1; then
    printf 'ok %02d - %s/%s [SURVIVED compile oracle]\n' \
      "$((PASS + FAIL + 1))" "$category" "$description"
    PASS=$((PASS + 1))
  else
    printf 'not ok %02d - %s/%s [KILLED by compiler]\n' \
      "$((PASS + FAIL + 1))" "$category" "$description"
    sed 's/^/# /' "$work/build.out"
    FAIL=$((FAIL + 1))
  fi
}

printf '1..16\n'

compile_mutant R01 direct-ollama-bypass 'spawn Ollama instead of the HVM entrypoint' \
  replace_once \
  ': Bun.spawn([GEMMA_BIN, prompt], { env, stdout: "pipe", stderr: "pipe" });' \
  ': Bun.spawn(["ollama", "run", model, prompt], { env, stdout: "pipe", stderr: "pipe" });'

compile_mutant R02 wrong-model 'replace the pinned default model' \
  replace_once \
  'process.env.HVM_GEMMA_MODEL ?? "gemma4-hvm:a4b-q4-k-m"' \
  'process.env.HVM_GEMMA_MODEL ?? "gemma4:26b"'

compile_mutant R03 wrong-model 'resolve HVM aliases to the wrong model' \
  replace_once \
  '  ["gemma4:26b-hvm", CANONICAL_MODEL],' \
  '  ["gemma4:26b-hvm", "gemma4:26b"],'

compile_mutant R04 proxy-auth 'allow non-loopback startup without an API key' \
  delete_once \
  $'if (!LOOPBACK_HOST && !BEARER) {\n  throw new Error("XBREED_HVM_API_KEY is required when binding outside loopback");\n}\n'

compile_mutant R05 proxy-auth 'allow anonymous requests whenever no key is set' \
  replace_once \
  'if (!BEARER) return LOOPBACK_HOST && !h;' \
  'if (!BEARER) return true;'

compile_mutant R06 proxy-auth 'accept a hard-coded fallback bearer' \
  replace_once \
  'return token.length > 0 && token === BEARER;' \
  'return token.length > 0 && (token === BEARER || token === "ollama");'

compile_mutant R07 sentinel-errors 'treat sentinel output as successful text' \
  delete_once \
  $'  if (text.startsWith("HVM_GEMMA_ERROR:")) {\n    throw new Error(text);\n  }\n'

compile_mutant R08 sentinel-errors 'detect only an exact empty sentinel' \
  replace_once \
  'if (text.startsWith("HVM_GEMMA_ERROR:")) {' \
  'if (text === "HVM_GEMMA_ERROR:") {'

compile_mutant R09 prompt-corruption 'drop Responses API instructions' \
  delete_once \
  $'      if (body.instructions?.trim()) {\n        prompt = `# System\\n${body.instructions.trim()}\\n\\n${prompt}`;\n      }\n'

compile_mutant R10 prompt-corruption 'coerce every message role to user' \
  replace_once \
  'const role = (m.role ?? "user").toLowerCase();' \
  'const role = "user";'

compile_mutant R11 timeout 'inflate the route timeout by another factor of 1000' \
  replace_once \
  '  ) * 1000;' \
  '  ) * 1000 * 1000;'

compile_mutant R12 timeout 'interpret timeout seconds as milliseconds' \
  replace_once \
  '  ) * 1000;' \
  '  );'

compile_mutant R13 cancellation 'leave the child alive when the timeout fires' \
  replace_once \
  '      proc.kill("SIGTERM");' \
  '      void proc.pid;'

compile_mutant R14 cancellation 'cancel the timeout before waiting for the child' \
  move_timeout_clear_before_wait

compile_mutant R15 stats-stripping 'return raw HVM stdout including stats' \
  replace_once \
  'const text = stripHvmStats(stdout);' \
  'const text = stdout.trimEnd();'

compile_mutant R16 response-schema 'label a Responses API object as chat completion' \
  replace_once \
  '    object: "response",' \
  '    object: "chat.completion",'

printf '# generated=%d failed=%d\n' "$PASS" "$FAIL"
exit "$((FAIL != 0))"

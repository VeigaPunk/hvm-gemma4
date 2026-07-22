#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE=$ROOT/hvm_gemma.c
HVM_ROOT=${HVM_ROOT:-$(find "${CARGO_HOME:-$HOME/.cargo}/registry/src" -type d -name hvm-2.0.22 2>/dev/null | head -1)}

if [[ -z "$HVM_ROOT" ]]; then
  echo 'Bail out! HVM 2.0.22 headers not found' >&2
  exit 2
fi

TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT INT TERM HUP

PASS=0
FAIL=0

DEFAULT_MODEL=gemma4-hvm:official-q4
DEFAULT_ENDPOINT=http://127.0.0.1:11434
DEFAULT_KEEP_ALIVE=10m
DEFAULT_SYSTEM='Follow the requested output format exactly. Do not add markdown fences, explanations, or commentary.'

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

build_harness() {
  local work=$1
  cat >"$work/harness.c" <<'EOF'
#include "hvm.h"
#include <curl/curl.h>
#include <json-c/json.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#undef curl_easy_init
#undef curl_easy_strerror
#undef curl_easy_setopt
#undef curl_easy_perform
#undef curl_easy_cleanup
#undef curl_slist_append
#undef curl_slist_free_all

extern Port gemma_generate(Net *net, Book *book, Port arg);

typedef struct {
  struct curl_slist *headers;
  size_t (*write_fn)(void *, size_t, size_t, void *);
  void *write_data;
  const char *url;
  const char *postfields;
} CurlCtx;

static void write_text_file(const char *path, const char *text) {
  if (path == NULL || text == NULL) return;
  FILE *fh = fopen(path, "wb");
  if (fh == NULL) return;
  fputs(text, fh);
  fputc('\n', fh);
  fclose(fh);
}

static char *dup_cstr(const char *text) {
  size_t len = strlen(text);
  char *copy = malloc(len + 1);
  if (copy == NULL) {
    abort();
  }
  memcpy(copy, text, len + 1);
  return copy;
}

void *curl_easy_init(void) {
  return calloc(1, sizeof(CurlCtx));
}

const char *curl_easy_strerror(CURLcode code) {
  (void)code;
  return "stub";
}

CURLcode curl_easy_setopt(void *curl, CURLoption option, ...) {
  CurlCtx *ctx = curl;
  va_list ap;
  va_start(ap, option);
  switch (option) {
    case CURLOPT_URL:
      ctx->url = va_arg(ap, const char *);
      break;
    case CURLOPT_HTTPHEADER:
      ctx->headers = va_arg(ap, struct curl_slist *);
      break;
    case CURLOPT_POSTFIELDS:
      ctx->postfields = va_arg(ap, const char *);
      break;
    case CURLOPT_WRITEFUNCTION:
      ctx->write_fn = va_arg(ap, size_t (*)(void *, size_t, size_t, void *));
      break;
    case CURLOPT_WRITEDATA:
      ctx->write_data = va_arg(ap, void *);
      break;
    case CURLOPT_TIMEOUT:
      (void)va_arg(ap, long);
      break;
    default:
      (void)va_arg(ap, void *);
      break;
  }
  va_end(ap);
  return CURLE_OK;
}

CURLcode curl_easy_perform(void *curl) {
  CurlCtx *ctx = curl;
  const char *body_file = getenv("BODY_FILE");
  if (body_file != NULL && ctx->postfields != NULL) {
    FILE *fh = fopen(body_file, "wb");
    if (fh == NULL) {
      return CURLE_WRITE_ERROR;
    }
    fputs(ctx->postfields, fh);
    fclose(fh);
  }
  write_text_file(getenv("URL_FILE"), ctx->url);
  if (ctx->write_fn != NULL) {
    const char *payload = "{\"response\":\"pong\"}";
    ctx->write_fn((void *)payload, 1, strlen(payload), ctx->write_data);
  }
  return CURLE_OK;
}

void curl_easy_cleanup(void *curl) {
  free(curl);
}

struct curl_slist *curl_slist_append(struct curl_slist *list, const char *value) {
  (void)value;
  return list;
}

void curl_slist_free_all(struct curl_slist *list) {
  (void)list;
}

Str readback_str(Net *net, Book *book, Port port) {
  (void)net;
  (void)book;
  (void)port;
  Str out = {
    .len = 7,
    .buf = dup_cstr("prompt!"),
  };
  return out;
}

Port inject_bytes(Net *net, Bytes *bytes) {
  (void)net;
  fwrite(bytes->buf, 1, bytes->len, stderr);
  return 0;
}

int main(void) {
  return (int)gemma_generate((Net *)0x1, (Book *)0x2, 0);
}
EOF
  cc -O2 -fPIC -Wall -Wextra -I"$HVM_ROOT/src" \
    $(pkg-config --cflags json-c) \
    "$work/hvm_gemma.c" "$work/harness.c" \
    $(pkg-config --libs json-c) \
    -o "$work/harness"
}

assert_body_exact() {
  local body_file=$1
  local model=${2:-$DEFAULT_MODEL}
  local keep_alive=${3:-$DEFAULT_KEEP_ALIVE}
  local num_ctx=${4:-2048}
  local num_predict=${5:-256}
  local temperature=${6:-0}
  local seed=${7:-42}
  local think=${8:-false}
  local system_prompt=${9:-$DEFAULT_SYSTEM}
  jq -e --arg model "$model" \
      --arg keep_alive "$keep_alive" \
      --arg system_prompt "$system_prompt" \
      --argjson num_ctx "$num_ctx" \
      --argjson num_predict "$num_predict" \
      --argjson temperature "$temperature" \
      --argjson seed "$seed" \
      --argjson think "$think" '
    .model == $model and
    .prompt == "prompt!" and
    .system == $system_prompt and
    .stream == false and
    .think == $think and
    .keep_alive == $keep_alive and
    (.options | type == "object") and
    (.options | keys == ["num_ctx","num_predict","seed","temperature"]) and
    .options.num_ctx == $num_ctx and
    (((.options.temperature - $temperature) | abs) < 1e-12) and
    .options.seed == $seed and
    .options.num_predict == $num_predict and
    (keys == ["keep_alive","model","options","prompt","stream","system","think"])
  ' "$body_file" >/dev/null
}

assert_url_exact() {
  local url_file=$1
  local endpoint=${2:-$DEFAULT_ENDPOINT}
  local expected="${endpoint}/api/generate"
  grep -Fxq "$expected" "$url_file"
}

record_body() {
  local body_file=$1
  local label=$2
  if ! assert_body_exact "$body_file"; then
    printf 'not ok - %s (body mismatch)\n' "$label"
    sed 's/^/# body: /' "$body_file"
    FAIL=$((FAIL + 1))
    return 1
  fi
  printf 'ok - %s\n' "$label"
  PASS=$((PASS + 1))
}

expect_kill() {
  local body_file=$1
  local label=$2
  if assert_body_exact "$body_file"; then
    printf 'not ok - %s (mutant survived exact-body oracle)\n' "$label"
    sed 's/^/# body: /' "$body_file"
    FAIL=$((FAIL + 1))
    return 1
  fi
  printf 'ok - %s [killed by exact-body oracle]\n' "$label"
  PASS=$((PASS + 1))
}

run_case() {
  local id=$1 description=$2
  local work=$TMP/$id
  mkdir -p "$work"
  cp -- "$SOURCE" "$work/hvm_gemma.c"
  shift 2
  "$@" "$work/hvm_gemma.c"
  if cmp -s -- "$SOURCE" "$work/hvm_gemma.c"; then
    printf 'not ok - %s (mutation did not land)\n' "$description"
    FAIL=$((FAIL + 1))
    return
  fi

  build_harness "$work"

  local body_file=$work/body.json
  local url_file=$work/url.txt
  : >"$body_file"
  : >"$url_file"

  local out=$work/out err=$work/err
  set +e
  BODY_FILE="$body_file" URL_FILE="$url_file" "$work/harness" >"$out" 2>"$err"
  local status=$?
  set -e

  if [[ $status != 0 ]]; then
    printf 'not ok - %s (runtime status %s)\n' "$description" "$status"
    sed 's/^/# /' "$err"
    FAIL=$((FAIL + 1))
    return
  fi

  if ! assert_url_exact "$url_file"; then
    printf 'not ok - %s (url mismatch)\n' "$description"
    sed 's/^/# url: /' "$url_file"
    FAIL=$((FAIL + 1))
    return 1
  fi
  expect_kill "$body_file" "$description"
}

run_equivalent_case() {
  local id=$1 description=$2
  local work=$TMP/$id
  mkdir -p "$work"
  cp -- "$SOURCE" "$work/hvm_gemma.c"
  shift 2
  "$@" "$work/hvm_gemma.c"
  build_harness "$work"

  local body_file=$work/body.json
  local url_file=$work/url.txt
  BODY_FILE="$body_file" URL_FILE="$url_file" "$work/harness" >/dev/null 2>&1
  if ! assert_url_exact "$url_file"; then
    printf 'not ok - %s (url mismatch)\n' "$description"
    FAIL=$((FAIL + 1))
    return
  fi
  if assert_body_exact "$body_file"; then
    printf 'ok - %s [equivalent request]\n' "$description"
    PASS=$((PASS + 1))
  else
    printf 'not ok - %s (equivalent mutant changed request)\n' "$description"
    FAIL=$((FAIL + 1))
  fi
}

run_env_case() {
  local id=$1 description=$2
  local work=$TMP/$id
  mkdir -p "$work"
  cp -- "$SOURCE" "$work/hvm_gemma.c"
  build_harness "$work"

  local body_file=$work/body.json
  local url_file=$work/url.txt
  : >"$body_file"
  : >"$url_file"
  local out=$work/out err=$work/err
  shift 2
  local model=$DEFAULT_MODEL endpoint=$DEFAULT_ENDPOINT keep_alive=$DEFAULT_KEEP_ALIVE
  local num_ctx=2048 num_predict=256 temperature=0 seed=42 think=false
  set +e
  BODY_FILE="$body_file" URL_FILE="$url_file" "$@" "$work/harness" >"$out" 2>"$err"
  local status=$?
  set -e
  if [[ $status != 0 ]]; then
    printf 'not ok - %s (runtime status %s)\n' "$description" "$status"
    sed 's/^/# /' "$err"
    FAIL=$((FAIL + 1))
    return
  fi

  case "$id" in
    E01)
      model=custom-model
      endpoint=http://ollama.local:9999
      ;;
    E02)
      num_ctx=4096
      num_predict=512
      temperature=0.8
      seed=7
      think=true
      keep_alive=30m
      ;;
    E03)
      endpoint=http://base.example:9999
      ;;
  esac

  if ! assert_body_exact "$body_file" "$model" "$keep_alive" "$num_ctx" "$num_predict" "$temperature" "$seed" "$think"; then
    printf 'not ok - %s (env override body mismatch)\n' "$description"
    sed 's/^/# body: /' "$body_file"
    FAIL=$((FAIL + 1))
    return
  fi
  if ! assert_url_exact "$url_file" "$endpoint"; then
    printf 'not ok - %s (env override url mismatch)\n' "$description"
    sed 's/^/# url: /' "$url_file"
    FAIL=$((FAIL + 1))
    return
  fi
  printf 'ok - %s [env override]\n' "$description"
  PASS=$((PASS + 1))
}

run_invalid_env_case() {
  local id=$1 description=$2
  local work=$TMP/$id
  mkdir -p "$work"
  cp -- "$SOURCE" "$work/hvm_gemma.c"
  build_harness "$work"
  local out=$work/out err=$work/err
  shift 2
  set +e
  "$@" "$work/harness" >"$out" 2>"$err"
  local status=$?
  set -e
  if [[ $status != 0 ]]; then
    printf '# %s: runtime status %s\n' "$description" "$status"
    sed 's/^/# /' "$err"
    return 1
  fi

  if grep -Fq 'HVM_GEMMA_ERROR: invalid generation environment' "$err"; then
    return 0
  else
    printf '# %s: missing guardrail error\n' "$description"
    return 1
  fi
}

run_invalid_env_group() {
  local failures=0
  run_invalid_env_case E04 'invalid env: model contains whitespace' env \
    HVM_GEMMA_MODEL='bad model' || failures=$((failures + 1))
  run_invalid_env_case E05 'invalid env: endpoint malformed scheme' env \
    HVM_GEMMA_ENDPOINT=ftp://ollama.local:11434 || failures=$((failures + 1))
  run_invalid_env_case E06 'invalid env: keep_alive malformed' env \
    HVM_GEMMA_KEEP_ALIVE=not-a-duration || failures=$((failures + 1))
  run_invalid_env_case E07 'invalid env: temperature out of range' env \
    HVM_GEMMA_TEMPERATURE=2.1 || failures=$((failures + 1))
  run_invalid_env_case E08 'invalid env: boolean spelling rejected' env \
    HVM_GEMMA_THINK=yes || failures=$((failures + 1))
  run_invalid_env_case E09 'invalid env: timeout out of range' env \
    HVM_GEMMA_HTTP_TIMEOUT=0 || failures=$((failures + 1))

  if (( failures == 0 )); then
    printf 'ok - invalid generation environments rejected [6 subcases]\n'
    PASS=$((PASS + 1))
  else
    printf 'not ok - invalid generation environments rejected [%d/6 failed]\n' "$failures"
    FAIL=$((FAIL + 1))
  fi
}

printf '1..21\n'

baseline=$TMP/baseline
mkdir -p "$baseline"
cp -- "$SOURCE" "$baseline/hvm_gemma.c"
build_harness "$baseline"
BODY_FILE="$baseline/body.json" URL_FILE="$baseline/url.txt" "$baseline/harness" >/dev/null 2>&1
record_body "$baseline/body.json" 'baseline exact-body control'
assert_url_exact "$baseline/url.txt"

run_case M01 'boundary: num_ctx zero' \
  replace_once 'env_int("HVM_GEMMA_NUM_CTX", 2048,' 'env_int("HVM_GEMMA_NUM_CTX", 0,'
run_case M02 'boundary: num_ctx INT_MAX' \
  replace_once 'env_int("HVM_GEMMA_NUM_CTX", 2048,' 'env_int("HVM_GEMMA_NUM_CTX", 2147483647,'
run_case M03 'boundary: num_predict zero' \
  replace_once 'env_int("HVM_GEMMA_NUM_PREDICT", 256,' 'env_int("HVM_GEMMA_NUM_PREDICT", 0,'
run_case M04 'boundary: num_predict fill-context sentinel' \
  replace_once 'env_int("HVM_GEMMA_NUM_PREDICT", 256,' 'env_int("HVM_GEMMA_NUM_PREDICT", -2,'

run_case M05 'wrong default: stochastic temperature' \
  replace_once 'env_double("HVM_GEMMA_TEMPERATURE", 0.0,' 'env_double("HVM_GEMMA_TEMPERATURE", 0.8,'
run_case M06 'wrong default: seed zero' \
  replace_once 'env_int("HVM_GEMMA_SEED", 42,' 'env_int("HVM_GEMMA_SEED", 0,'
run_case M07 'wrong default: doubled context' \
  replace_once 'env_int("HVM_GEMMA_NUM_CTX", 2048,' 'env_int("HVM_GEMMA_NUM_CTX", 4096,'

run_case M08 'precedence: later temperature wins' \
  replace_once \
    '  json_object_object_add(options, "seed", json_object_new_int(seed));' \
    $'  json_object_object_add(options, "temperature", json_object_new_double(0.8));\n  json_object_object_add(options, "seed", json_object_new_int(seed));'
run_equivalent_case M09 'precedence: earlier temperature loses' \
  replace_once \
    '  json_object_object_add(options, "temperature", json_object_new_double(temperature));' \
    $'  json_object_object_add(options, "temperature", json_object_new_double(0.8));\n  json_object_object_add(options, "temperature", json_object_new_double(temperature));'
run_case M10 'precedence: request options replaced after attachment' \
  replace_once \
    '  json_object_object_add(request, "options", options);' \
    $'  json_object_object_add(request, "options", options);\n  json_object_object_add(request, "options", json_object_new_object());'

run_case M11 'dropped option: num_ctx' \
  delete_once $'  json_object_object_add(options, "num_ctx", json_object_new_int(num_ctx));\n'
run_case M12 'dropped option: temperature' \
  delete_once $'  json_object_object_add(options, "temperature", json_object_new_double(temperature));\n'
run_case M13 'dropped option: seed' \
  delete_once $'  json_object_object_add(options, "seed", json_object_new_int(seed));\n'
run_case M14 'dropped option: num_predict' \
  delete_once $'  json_object_object_add(options, "num_predict", json_object_new_int(num_predict));\n'

run_case M15 'escaping/type: options serialized as a JSON string' \
  replace_once \
    'json_object_object_add(request, "options", options);' \
    'json_object_object_add(request, "options", json_object_new_string(json_object_to_json_string(options)));'
run_case M16 'escaping/key: quote-backslash key mismatch' \
  replace_once '"temperature", json_object_new_double' '"temperature\"", json_object_new_double'


run_env_case E01 'env override: model and endpoint' env \
  HVM_GEMMA_MODEL=custom-model \
  HVM_GEMMA_ENDPOINT=http://ollama.local:9999
run_env_case E02 'env override: generation knobs' env \
  HVM_GEMMA_NUM_CTX=4096 \
  HVM_GEMMA_NUM_PREDICT=512 \
  HVM_GEMMA_TEMPERATURE=0.8 \
  HVM_GEMMA_SEED=7 \
  HVM_GEMMA_THINK=true \
  HVM_GEMMA_KEEP_ALIVE=30m
run_env_case E03 'env override: base URL parity' env \
  HVM_GEMMA_BASE_URL=http://base.example:9999/

run_invalid_env_group

printf '# pass=%d fail=%d\n' "$PASS" "$FAIL"
exit "$((FAIL != 0))"

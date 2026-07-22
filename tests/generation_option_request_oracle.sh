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
  (void)bytes;
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
  jq -e '
    .model == "gemma4:26b" and
    .prompt == "prompt!" and
    .stream == false and
    .think == false and
    .keep_alive == "10m" and
    (.options | type == "object") and
    (.options | keys == ["num_ctx","num_predict","seed","temperature"]) and
    .options.num_ctx == 2048 and
    .options.temperature == 0 and
    .options.seed == 42 and
    .options.num_predict == 256 and
    (keys == ["keep_alive","model","options","prompt","stream","think"])
  ' "$body_file" >/dev/null
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
  : >"$body_file"

  local out=$work/out err=$work/err
  set +e
  BODY_FILE="$body_file" "$work/harness" >"$out" 2>"$err"
  local status=$?
  set -e

  if [[ $status != 0 ]]; then
    printf 'not ok - %s (runtime status %s)\n' "$description" "$status"
    sed 's/^/# /' "$err"
    FAIL=$((FAIL + 1))
    return
  fi

  expect_kill "$body_file" "$description"
}

printf '1..17\n'

baseline=$TMP/baseline
mkdir -p "$baseline"
cp -- "$SOURCE" "$baseline/hvm_gemma.c"
build_harness "$baseline"
BODY_FILE="$baseline/body.json" "$baseline/harness" >/dev/null 2>&1
record_body "$baseline/body.json" 'baseline exact-body control'

run_case M01 'boundary: num_ctx zero' \
  replace_once 'json_object_new_int(2048)' 'json_object_new_int(0)'
run_case M02 'boundary: num_ctx INT_MAX' \
  replace_once 'json_object_new_int(2048)' 'json_object_new_int(2147483647)'
run_case M03 'boundary: num_predict zero' \
  replace_once 'json_object_new_int(256)' 'json_object_new_int(0)'
run_case M04 'boundary: num_predict fill-context sentinel' \
  replace_once 'json_object_new_int(256)' 'json_object_new_int(-2)'

run_case M05 'wrong default: stochastic temperature' \
  replace_once 'json_object_new_double(0.0)' 'json_object_new_double(0.8)'
run_case M06 'wrong default: seed zero' \
  replace_once 'json_object_new_int(42)' 'json_object_new_int(0)'
run_case M07 'wrong default: doubled context' \
  replace_once 'json_object_new_int(2048)' 'json_object_new_int(4096)'

run_case M08 'precedence: later temperature wins' \
  replace_once \
    '  json_object_object_add(options, "seed", json_object_new_int(42));' \
    $'  json_object_object_add(options, "temperature", json_object_new_double(0.8));\n  json_object_object_add(options, "seed", json_object_new_int(42));'
run_case M09 'precedence: earlier temperature loses' \
  replace_once \
    '  json_object_object_add(options, "temperature", json_object_new_double(0.0));' \
    $'  json_object_object_add(options, "temperature", json_object_new_double(0.8));\n  json_object_object_add(options, "temperature", json_object_new_double(0.0));'
run_case M10 'precedence: request options replaced after attachment' \
  replace_once \
    '  json_object_object_add(request, "options", options);' \
    $'  json_object_object_add(request, "options", options);\n  json_object_object_add(request, "options", json_object_new_object());'

run_case M11 'dropped option: num_ctx' \
  delete_once $'  json_object_object_add(options, "num_ctx", json_object_new_int(2048));\n'
run_case M12 'dropped option: temperature' \
  delete_once $'  json_object_object_add(options, "temperature", json_object_new_double(0.0));\n'
run_case M13 'dropped option: seed' \
  delete_once $'  json_object_object_add(options, "seed", json_object_new_int(42));\n'
run_case M14 'dropped option: num_predict' \
  delete_once $'  json_object_object_add(options, "num_predict", json_object_new_int(256));\n'

run_case M15 'escaping/type: options serialized as a JSON string' \
  replace_once \
    'json_object_object_add(request, "options", options);' \
    'json_object_object_add(request, "options", json_object_new_string(json_object_to_json_string(options)));'
run_case M16 'escaping/key: quote-backslash key mismatch' \
  replace_once '"temperature", json_object_new_double' '"temperature\"", json_object_new_double'

printf '# pass=%d fail=%d\n' "$PASS" "$FAIL"
exit "$((FAIL != 0))"

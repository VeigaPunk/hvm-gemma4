#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE=$ROOT/hvm_gemma.c
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT INT TERM HUP

HVM_ROOT=${HVM_ROOT:-$(find "${CARGO_HOME:-$HOME/.cargo}/registry/src" -type d -name hvm-2.0.22 2>/dev/null | head -1)}
if [[ -z "$HVM_ROOT" ]]; then
  echo 'Bail out! HVM 2.0.22 headers not found' >&2
  exit 2
fi

PASS=0
FAIL=0

compile_mutant() {
  local id=$1 description=$2
  local work=$TMP/$id
  mkdir -p "$work"
  cp -- "$SOURCE" "$work/hvm_gemma.c"
  shift 2
  "$@" "$work/hvm_gemma.c"

  if cmp -s -- "$SOURCE" "$work/hvm_gemma.c"; then
    printf 'not ok %02d - %s (mutation did not land)\n' "$((PASS + FAIL + 1))" "$description"
    FAIL=$((FAIL + 1))
    return
  fi

  if cc -O2 -fPIC -Wall -Wextra -I"$HVM_ROOT/src" \
      $(pkg-config --cflags libcurl json-c) -shared \
      -Wl,--unresolved-symbols=ignore-all -o "$work/libmutant.so" \
      "$work/hvm_gemma.c" $(pkg-config --libs libcurl json-c) \
      >"$work/build.out" 2>&1; then
    printf 'ok %02d - %s [SURVIVED compile oracle]\n' "$((PASS + FAIL + 1))" "$description"
    PASS=$((PASS + 1))
  else
    printf 'not ok %02d - %s [KILLED by compiler]\n' "$((PASS + FAIL + 1))" "$description"
    sed 's/^/# /' "$work/build.out"
    FAIL=$((FAIL + 1))
  fi
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

printf '1..18\n'

compile_mutant M01 'boundary: num_ctx zero' \
  replace_once 'json_object_new_int(2048)' 'json_object_new_int(0)'
compile_mutant M02 'boundary: num_ctx INT_MAX' \
  replace_once 'json_object_new_int(2048)' 'json_object_new_int(2147483647)'
compile_mutant M03 'boundary: num_predict zero' \
  replace_once 'json_object_new_int(256)' 'json_object_new_int(0)'
compile_mutant M04 'boundary: num_predict fill-context sentinel' \
  replace_once 'json_object_new_int(256)' 'json_object_new_int(-2)'

compile_mutant M05 'wrong default: stochastic temperature' \
  replace_once 'json_object_new_double(0.0)' 'json_object_new_double(0.8)'
compile_mutant M06 'wrong default: seed zero' \
  replace_once 'json_object_new_int(42)' 'json_object_new_int(0)'
compile_mutant M07 'wrong default: doubled context' \
  replace_once 'json_object_new_int(2048)' 'json_object_new_int(4096)'

compile_mutant M08 'precedence: later temperature wins' \
  replace_once \
    '  json_object_object_add(options, "seed", json_object_new_int(42));' \
    $'  json_object_object_add(options, "temperature", json_object_new_double(0.8));\n  json_object_object_add(options, "seed", json_object_new_int(42));'
compile_mutant M09 'precedence: earlier temperature loses' \
  replace_once \
    '  json_object_object_add(options, "temperature", json_object_new_double(0.0));' \
    $'  json_object_object_add(options, "temperature", json_object_new_double(0.8));\n  json_object_object_add(options, "temperature", json_object_new_double(0.0));'
compile_mutant M10 'precedence: request options replaced after attachment' \
  replace_once \
    '  json_object_object_add(request, "options", options);' \
    $'  json_object_object_add(request, "options", options);\n  json_object_object_add(request, "options", json_object_new_object());'

compile_mutant M11 'dropped option: num_ctx' \
  delete_once $'  json_object_object_add(options, "num_ctx", json_object_new_int(2048));\n'
compile_mutant M12 'dropped option: temperature' \
  delete_once $'  json_object_object_add(options, "temperature", json_object_new_double(0.0));\n'
compile_mutant M13 'dropped option: seed' \
  delete_once $'  json_object_object_add(options, "seed", json_object_new_int(42));\n'
compile_mutant M14 'dropped option: num_predict' \
  delete_once $'  json_object_object_add(options, "num_predict", json_object_new_int(256));\n'

compile_mutant M15 'escaping/type: options serialized as a JSON string' \
  replace_once \
    'json_object_object_add(request, "options", options);' \
    'json_object_object_add(request, "options", json_object_new_string(json_object_to_json_string(options)));'
compile_mutant M16 'escaping/key: quote-backslash key mismatch' \
  replace_once '"temperature", json_object_new_double' '"temperature\"", json_object_new_double'

compile_mutant M17 'ownership/error: release attached options before serialization' \
  replace_once \
    '  json_object_object_add(request, "options", options);' \
    $'  json_object_object_add(request, "options", options);\n  json_object_put(options);'
compile_mutant M18 'return/error: curl-init failure bypasses cleanup' \
  replace_once \
    $'    result = inject_text(net, "HVM_GEMMA_ERROR: curl initialization failed");\n    goto cleanup_json;' \
    $'    return inject_text(net, "HVM_GEMMA_ERROR: curl initialization failed");'

printf '# survived=%d killed=%d\n' "$PASS" "$FAIL"
exit "$((FAIL != 0))"

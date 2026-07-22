#!/usr/bin/env bash
# Thin entrypoint: HVM4 mailbox substrate lives in the xbreed plugin tree
# (BEND2 keep classifier → HVM4 IR → decision vector).
set -euo pipefail

PLUGIN=${XBREED_PLUGIN_ROOT:-/home/arara/.grok/installed-plugins/xbrd-gdsp-fknpft-16b26082}
SCRIPT=$PLUGIN/scripts/mailbox-hvm4.sh

[[ -x "$SCRIPT" ]] || {
  echo "HVM4_MAILBOX_ERROR: substrate missing: $SCRIPT" >&2
  exit 1
}

exec "$SCRIPT" "$@"

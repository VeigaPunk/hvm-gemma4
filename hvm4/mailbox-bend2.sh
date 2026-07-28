#!/usr/bin/env bash
# Deprecated entrypoint. Mailbox I/O is native:
#   xbreed team mailbox write|drain|compact
# Keep dialect SSoT: ./mailbox.bend
# Do not add helper CLIs.
echo "HVM4_MAILBOX: use xbreed team mailbox write|drain|compact (see mailbox.bend)" >&2
exit 2

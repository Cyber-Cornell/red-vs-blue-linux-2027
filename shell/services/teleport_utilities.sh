#!/bin/sh
set -u
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
exec sh "$SCRIPT_DIR/teleport.sh" "$@"

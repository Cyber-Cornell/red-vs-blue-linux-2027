#!/bin/sh
set -u
case "${1:---audit}" in
  --audit|--plan) ;;
  --help|-h) printf 'Usage: %s [--audit|--plan]\n' "$0"; exit 0 ;;
  *) printf '%s\n' 'Automatic fstab mutation is refused. Review mount dependencies before changing policy.' >&2; exit 1 ;;
esac
[ "$#" -le 1 ] || exit 1
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
exec sh "$SCRIPT_DIR/tools/mount_audit.sh"

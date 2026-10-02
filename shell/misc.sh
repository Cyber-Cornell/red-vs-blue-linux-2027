#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/lib/portable.sh"
for option in "$@"; do
  case "$option" in
    --audit|--plan) : ;;
    --help|-h) printf 'Usage: %s --audit | --plan\nReports updatedb exclusions without changing indexing policy.\n' "$0"; exit 0 ;;
    *) die "Unsupported option: $option; indexing policy requires manual review" ;;
  esac
done
if [ -r /etc/updatedb.conf ]; then
  sed -n '1,200p' /etc/updatedb.conf
else
  log_info 'No readable updatedb configuration'
fi
log_info 'Preserve exclusions for virtual, remote, and sensitive filesystems'

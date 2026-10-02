#!/bin/sh
set -u
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
. "$SCRIPT_DIR/../lib/portable.sh"
case "${1:-}" in
  -h|--help) printf 'Usage: %s\nRead-only init state, with process fallback when no supported manager is live.\n' "$0"; exit 0 ;;
  '') ;;
  *) die "Unknown argument: $1" ;;
esac
if [ -d /run/systemd/system ] && have_cmd systemctl; then
  systemctl list-units --type=service --all --no-legend --plain --no-pager
elif have_cmd rc-status; then
  rc-status -a
else
  log_warn 'No supported live init manager; showing processes and init-file metadata only'
  printf '%s\n' '=== PROCESS FALLBACK (NOT SERVICE HEALTH) ==='
  ps -e -o pid,comm || exit 1
  printf '\n%s\n' '=== INIT FILE METADATA (NOT EXECUTED) ==='
  if [ -d /etc/init.d ]; then ls -l /etc/init.d; fi
  exit 0
fi

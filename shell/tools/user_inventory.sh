#!/bin/sh
set -u
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
. "$SCRIPT_DIR/../lib/portable.sh"
case "${1:-}" in
  -h|--help) printf 'Usage: %s\nAccount inventory; shell policy alone does not establish login access.\n' "$0"; exit 0 ;;
  '') ;;
  *) die "Unknown argument: $1" ;;
esac
if have_cmd getent; then
  ACCOUNTS=$(getent passwd) || die 'Cannot enumerate account database'
else
  ACCOUNTS=$(cat /etc/passwd) || die 'Cannot read local accounts'
  log_warn 'getent absent; only local /etc/passwd accounts are included'
fi
printf 'username\tuid\tgid\tshell_policy\tshell\tgroups\n'
printf '%s\n' "$ACCOUNTS" | LC_ALL=C sort |
  while IFS=: read -r user pass uid gid gecos home shell; do
    [ -n "$user" ] || continue
    case "$shell" in
      */nologin|*/false|*/shutdown|*/halt|*/sync|/dev/null) policy=noninteractive ;;
      '') policy=default-shell ;;
      *) policy=interactive-shell ;;
    esac
    groups=$(id -Gn "$user" 2>/dev/null || printf UNKNOWN)
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$user" "$uid" "$gid" "$policy" "$shell" "$groups"
  done
printf '%s\n' '[INFO] Password locks, PAM, SSH policy and account expiry are separate access controls.' >&2

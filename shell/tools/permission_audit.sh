#!/bin/sh
# Read-only permission inventory; findings need an operator's review.
set -u
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/../lib/portable.sh"
ROOT=/
MAX_LINES=${CCDC_PERMISSION_MAX_LINES:-2000}
SECONDS_LIMIT=${CCDC_PERMISSION_TIMEOUT:-60}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) shift; [ "$#" -gt 0 ] || die '--root requires a directory'; ROOT=$1 ;;
    --help|-h) printf 'Usage: %s [--root DIR]\nCCDC_PERMISSION_MAX_LINES=2000 CCDC_PERMISSION_TIMEOUT=60\n' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done
case "$MAX_LINES:$SECONDS_LIMIT" in *[!0-9:]*|:*|*:) die 'Limits must be positive integers' ;; esac
[ "$MAX_LINES" -gt 0 ] && [ "$MAX_LINES" -le 100000 ] || die 'Line limit must be 1..100000'
[ "$SECONDS_LIMIT" -gt 0 ] && [ "$SECONDS_LIMIT" -le 600 ] || die 'Timeout must be 1..600 seconds'
[ -d "$ROOT" ] || die "Not a directory: $ROOT"
ROOT=$(CDPATH= cd -P "$ROOT" && pwd)
have_cmd timeout || die 'timeout is required for bounded inventory'
umask 077
WORK=$(mktemp -d) || die 'Cannot create inventory workspace'
trap 'rm -f "$WORK/result" "$WORK/errors"; rmdir "$WORK"' 0
trap 'exit 1' HUP INT TERM
RESULT=0
printf '%s\n' '--- reviewed path policy (missing paths are not created) ---'
while read -r policy_mode policy_owner policy_group policy_path; do
  [ -n "$policy_mode" ] || continue
  if [ "$policy_group" = shadow ] && ! getent group shadow >/dev/null 2>&1; then policy_group=root; fi
  check_path="${ROOT%/}$policy_path"
  if [ -L "$check_path" ]; then
    printf '[REFUSE] symlink %s\n' "$check_path"
    continue
  fi
  if [ ! -e "$check_path" ]; then printf '[ABSENT] %s\n' "$check_path"; continue; fi
  expected="$policy_owner:$policy_group:${policy_mode#0}"
  actual=$(stat -c '%U:%G:%a' "$check_path") || { RESULT=1; continue; }
  if [ "$actual" != "$expected" ]; then
    printf '[DRIFT] %s expected=%s actual=%s\n' "$check_path" "$expected" "$actual"
  else
    printf '[OK] %s %s\n' "$check_path" "$actual"
  fi
done <"$SCRIPT_DIR/../configs/permissions.conf"
scan() {
  printf '\n--- %s ---\n' "$1"
  shift
  (ulimit -f 20480; timeout "$SECONDS_LIMIT" "$@") >"$WORK/result" 2>"$WORK/errors"
  _scan_status=$?
  head -n "$MAX_LINES" "$WORK/result"
  if [ "$(wc -l <"$WORK/result")" -gt "$MAX_LINES" ]; then
    printf '[TRUNCATED] More than %s results\n' "$MAX_LINES"
  fi
  if [ "$_scan_status" -ne 0 ]; then
    printf '[INCOMPLETE] Scan exited %s; inaccessible paths or time limit\n' "$_scan_status"
    head -n 20 "$WORK/errors"
    RESULT=1
  fi
}
scan 'SUID and SGID regular files' find "$ROOT" -xdev -type f \( -perm -4000 -o -perm -2000 \) -exec ls -ld {} \;
scan 'World-writable regular files' find "$ROOT" -xdev -type f -perm -0002 -exec ls -ld {} \;
scan 'World-writable directories without sticky bit' find "$ROOT" -xdev -type d -perm -0002 ! -perm -1000 -exec ls -ld {} \;
if find "$WORK" -nouser -print >/dev/null 2>&1; then
scan 'Files without a known owner or group' find "$ROOT" -xdev \( -nouser -o -nogroup \) -exec ls -ld {} \;
else
  printf '[UNAVAILABLE] Owner/group lookup requires find with -nouser/-nogroup support\n'
fi
for directory in /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly /etc/systemd/system /etc/init.d /etc/conf.d; do
  [ -d "$ROOT$directory" ] || continue
  scan "Unexpected owner or writable service/cron definitions: $directory" find "$ROOT$directory" -xdev -type f \( ! -user root -o ! -group root -o -perm -0020 -o -perm -0002 \) -exec ls -ld {} \;
done
if [ -d "$ROOT/etc/ssh" ]; then
  scan 'SSH private keys or server configs with unexpected owner/mode' find "$ROOT/etc/ssh" -xdev -type f \( -name 'ssh_host_*_key' -o -name sshd_config -o -path '*/sshd_config.d/*.conf' \) \( ! -user root -o ! -group root -o ! -perm 0600 \) -exec ls -ld {} \;
fi
if [ -d "$ROOT/etc/sudoers.d" ]; then
  scan 'Sudoers fragments with unexpected owner/mode' find "$ROOT/etc/sudoers.d" -xdev -type f \( ! -user root -o ! -group root -o ! -perm 0440 \) -exec ls -ld {} \;
fi
if have_cmd getcap; then
  scan 'File capabilities (same filesystem)' find "$ROOT" -xdev -type f -exec getcap {} +
fi
exit "$RESULT"

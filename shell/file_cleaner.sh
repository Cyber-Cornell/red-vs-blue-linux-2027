#!/bin/sh
set -u
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd) || exit 1
. "$SCRIPT_DIR/lib/portable.sh"
MODE=plan
YES=0
FILE=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --plan) MODE=plan ;;
    --apply) MODE=apply ;;
    --yes) YES=1 ;;
    --file) shift; [ "$#" -gt 0 ] || die '--file requires an absolute path'; FILE=$1 ;;
    --help|-h) printf 'Usage: %s [--plan | --apply --yes] --file /absolute/reviewed/file\n' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done
case "$FILE" in /*) ;; *) die 'Supply one absolute --file path' ;; esac
case "$FILE" in *'/../'*|*'/./'*|*/..|*/.) die 'Dot path components are not allowed' ;; esac
[ -f "$FILE" ] && [ ! -L "$FILE" ] || die 'Target must be an existing regular file, not a symlink'
PARENT=$(CDPATH= cd -P "$(dirname "$FILE")" && pwd) || die 'Cannot resolve parent'
[ "$PARENT/$(basename "$FILE")" = "$FILE" ] || die 'Use a canonical path without symlink ancestors'
case "$FILE" in /proc/*|/sys/*|/dev/*|/etc/passwd|/etc/shadow|/etc/group|/etc/gshadow|/etc/fstab|/etc/resolv.conf|/etc/ssh/*|*/.ssh/*) die 'Protected system or SSH path; use dedicated administrative tools' ;; esac
printf 'Quarantine exactly: %s\n' "$FILE"
ls -ld "$FILE" || exit 1
sha256_file "$FILE" || die 'Cannot record source digest'
IDENTITY=$(stat -c '%d:%i:%s:%Y:%Z' "$FILE") || die 'Cannot record file identity'
[ "$MODE" = apply ] || exit 0
[ "$YES" -eq 1 ] || die 'Apply requires --yes'
require_root
SIZE=$(wc -c <"$FILE") || die 'Cannot measure target'
[ "$SIZE" -le 67108864 ] || die 'Target exceeds 64 MiB quarantine limit; use reviewed offline evidence storage'
mkdir -p /var/backups || die 'Cannot create backup parent'
FREE_KB=$(df -Pk /var/backups | awk 'NR==2 {print $4}')
case "$FREE_KB" in ''|*[!0-9]*) die 'Cannot determine free backup space' ;; esac
[ "$FREE_KB" -gt $((SIZE / 1024 + 10240)) ] || die 'Insufficient backup space (10 MiB reserve required)'
umask 077
DEST=$(mktemp -d /var/backups/ccdc-quarantine.XXXXXX) || die 'Cannot create quarantine'
printf '%s\n' "$FILE" >"$DEST/original-path.txt" || exit 1
cp -p "$FILE" "$DEST/content" || die 'Cannot copy target; original retained'
cmp "$FILE" "$DEST/content" || die 'Copy verification failed; original retained'
sha256_file "$DEST/content" >"$DEST/sha256.txt" || die 'Cannot record quarantine digest; original retained'
[ ! -L "$FILE" ] && [ "$(stat -c '%d:%i:%s:%Y:%Z' "$FILE")" = "$IDENTITY" ] || die 'Target changed during quarantine; original retained'
rm -- "$FILE" || die "Quarantine copied but original removal failed; inspect $DEST"
printf 'Quarantine: %s\n' "$DEST"
printf '%s\n' 'Restore the content file after reviewing original-path.txt; do not execute paths as shell commands.'

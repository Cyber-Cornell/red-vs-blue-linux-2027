#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/../lib/portable.sh"
TARGET=''
FLAG=''
ACTION=''
MODE=plan
YES=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --path|--flag) option=$1; shift; [ "$#" -gt 0 ] || die "$option requires a value"; case "$option" in --path) TARGET=$1 ;; --flag) FLAG=$1 ;; esac ;;
    --clear) ACTION=- ;;
    --set) ACTION=+ ;;
    --plan) MODE=plan ;;
    --apply) MODE=apply ;;
    --yes) YES=1 ;;
    --help|-h) printf 'Usage: %s --path ABS_FILE --flag i|a --clear|--set [--plan | --apply --yes]\nOne regular file only. Symlinks, paths crossing non-root mounts and wildcards are refused.\n' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done
case "$FLAG" in i|a) ;; *) die '--flag must be i or a' ;; esac
case "$ACTION" in +|-) ;; *) die '--clear or --set is required' ;; esac
case "$TARGET" in /*) ;; *) die 'An absolute file path is required' ;; esac
case "$TARGET" in *[!A-Za-z0-9_./+@:-]*|*/../*|*/./*|*//*) die 'Path must be literal and unambiguous, without whitespace or wildcards' ;; esac
have_cmd lsattr && have_cmd chattr && have_cmd readlink && have_cmd timeout || die 'lsattr, chattr, readlink and timeout are required'
[ -f "$TARGET" ] && [ ! -L "$TARGET" ] || die 'An existing regular non-symlink file is required'
[ "$(readlink -f "$TARGET")" = "$TARGET" ] || die 'Symlink ancestors or noncanonical path refused'
if ! awk -v path="$TARGET" '$5!="/" && (path==$5 || index(path,$5 "/")==1) {found=1} END {exit found}' /proc/self/mountinfo; then
  die 'Path crosses a mount boundary; review that filesystem manually'
fi
ATTRIBUTE_OUTPUT=$(timeout 5 lsattr -d "$TARGET") || die 'Cannot read current attributes'
BEFORE=$(printf '%s\n' "$ATTRIBUTE_OUTPUT" | awk 'NR==1 {print $1}')
case "$BEFORE" in ''|*[!A-Za-z-]*) die 'Cannot interpret current attributes' ;; esac
IDENTITY=$(stat -c '%d:%i' "$TARGET")
printf 'path=%s\nidentity=%s\ncurrent=%s\nrequested=%s%s\n' "$TARGET" "$IDENTITY" "$BEFORE" "$ACTION" "$FLAG"
if [ "$MODE" = plan ]; then exit 0; fi
[ "$YES" -eq 1 ] || die 'Apply requires --yes'
require_root
case "$BEFORE" in *"$FLAG"*) BEFORE_ACTION=+ ;; *) BEFORE_ACTION=- ;; esac
if [ "$ACTION" = "$BEFORE_ACTION" ]; then log_ok 'Requested attribute state already present'; exit 0; fi
umask 077
mkdir -p /var/backups
BACKUP=$(mktemp -d /var/backups/ccdc-attributes.XXXXXX)
printf '%s\n' "$TARGET" >"$BACKUP/path"
printf '%s\n' "$IDENTITY" >"$BACKUP/identity"
printf '%s\n' "$BEFORE_ACTION$FLAG" >"$BACKUP/restore-mode"
printf '%s\n' "$BEFORE" >"$BACKUP/attributes-before"
cat >"$BACKUP/restore.sh" <<'EOF'
#!/bin/sh
set -eu
BACKUP=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
IFS= read -r TARGET <"$BACKUP/path"
IFS= read -r IDENTITY <"$BACKUP/identity"
IFS= read -r RESTORE_MODE <"$BACKUP/restore-mode"
case "$RESTORE_MODE" in +i|-i|+a|-a) ;; *) exit 1 ;; esac
[ "$(id -u)" -eq 0 ]
[ ! -L "$TARGET" ] && [ "$(readlink -f "$TARGET")" = "$TARGET" ]
[ "$(stat -c '%d:%i' "$TARGET")" = "$IDENTITY" ]
awk -v path="$TARGET" '$5!="/" && (path==$5 || index(path,$5 "/")==1) {found=1} END {exit found}' /proc/self/mountinfo
timeout 5 chattr "$RESTORE_MODE" "$TARGET"
ATTRIBUTE_OUTPUT=$(timeout 5 lsattr -d "$TARGET")
ATTRIBUTES=$(printf '%s\n' "$ATTRIBUTE_OUTPUT" | awk 'NR==1 {print $1}')
case "$ATTRIBUTES" in ''|*[!A-Za-z-]*) exit 1 ;; esac
FLAG=${RESTORE_MODE#?}
case "$RESTORE_MODE:$ATTRIBUTES" in +*:*) case "$ATTRIBUTES" in *"$FLAG"*) ;; *) exit 1 ;; esac ;; -*:*) case "$ATTRIBUTES" in *"$FLAG"*) exit 1 ;; esac ;; esac
printf 'Restored %s on %s\n' "$RESTORE_MODE" "$TARGET"
EOF
chmod 700 "$BACKUP/restore.sh"
on_exit() {
  result=$?
  trap - 0
  if [ "$result" -ne 0 ]; then sh "$BACKUP/restore.sh" || log_error "Attribute rollback incomplete: $BACKUP/restore.sh"; fi
  exit "$result"
}
trap on_exit 0
trap 'exit 1' HUP INT TERM
[ "$(stat -c '%d:%i' "$TARGET")" = "$IDENTITY" ] || die 'Target identity changed'
timeout 5 chattr "$ACTION$FLAG" "$TARGET"
ATTRIBUTE_OUTPUT=$(timeout 5 lsattr -d "$TARGET") || die 'Cannot verify changed attributes'
AFTER=$(printf '%s\n' "$ATTRIBUTE_OUTPUT" | awk 'NR==1 {print $1}')
case "$AFTER" in ''|*[!A-Za-z-]*) die 'Cannot interpret verification attributes' ;; esac
printf '%s\n' "$AFTER" >"$BACKUP/attributes-after"
case "$ACTION:$AFTER" in +*:*) case "$AFTER" in *"$FLAG"*) ;; *) die 'Attribute verification failed' ;; esac ;; -*:*) case "$AFTER" in *"$FLAG"*) die 'Attribute verification failed' ;; esac ;; esac
log_ok "Verified $ACTION$FLAG on $TARGET; rollback: $BACKUP/restore.sh"

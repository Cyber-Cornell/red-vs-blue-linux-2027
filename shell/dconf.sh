#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/lib/portable.sh"
MODE=audit
YES=0
for option in "$@"; do
  case "$option" in
    --audit) MODE=audit ;;
    --plan) MODE=plan ;;
    --apply) MODE=apply ;;
    --yes) YES=1 ;;
    --help|-h) printf 'Usage: %s --audit | --plan | --apply --yes\nInstalls GNOME automount and recent-history defaults; preserves user databases.\n' "$0"; exit 0 ;;
    *) die "Unknown option: $option" ;;
  esac
done
PROFILE=/etc/dconf/profile/user
POLICY=/etc/dconf/db/local.d/01-ccdc-security
LOCKS=/etc/dconf/db/local.d/locks/01-ccdc-locks
policy() {
  printf '%s\n' '[org/gnome/desktop/media-handling]' 'automount=false' 'automount-open=false' '' '[org/gnome/desktop/privacy]' 'remember-recent-files=false'
}
if [ "$MODE" = plan ]; then policy; exit 0; fi
if [ "$MODE" = audit ]; then
  for file in "$PROFILE" "$POLICY" "$LOCKS"; do
    if [ -f "$file" ]; then printf '\n--- %s ---\n' "$file"; cat "$file"; fi
  done
  exit 0
fi
[ "$YES" -eq 1 ] || die 'Apply requires --yes'
require_root
have_cmd dconf || die 'dconf is unavailable; this stage requires a GNOME host'
for file in "$PROFILE" "$POLICY" "$LOCKS"; do
  [ ! -L "$file" ] || die "Refusing symlink: $file"
done
if [ -f "$PROFILE" ] && ! grep -qx 'system-db:local' "$PROFILE"; then
  die 'Existing dconf profile does not include system-db:local; review its hierarchy first'
fi
umask 077
mkdir -p /var/backups /etc/dconf/profile /etc/dconf/db/local.d/locks
BACKUP=$(mktemp -d /var/backups/ccdc-dconf.XXXXXX)
for file in "$PROFILE" "$POLICY" "$LOCKS"; do
  if [ -f "$file" ]; then cp -p "$file" "$BACKUP/$(basename "$file")"; fi
done
cat >"$BACKUP/restore.sh" <<'EOF'
#!/bin/sh
set -eu
BACKUP=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
for file in /etc/dconf/profile/user /etc/dconf/db/local.d/01-ccdc-security /etc/dconf/db/local.d/locks/01-ccdc-locks; do
  [ ! -L "$file" ] || exit 1
  if [ -f "$BACKUP/$(basename "$file")" ]; then cp -p "$BACKUP/$(basename "$file")" "$file"; else rm -f "$file"; fi
done
dconf update
EOF
chmod 700 "$BACKUP/restore.sh"
on_exit() {
  result=$?
  trap - 0
  if [ "$result" -ne 0 ]; then sh "$BACKUP/restore.sh" || log_error "Rollback incomplete: $BACKUP/restore.sh"; fi
  exit "$result"
}
trap on_exit 0
trap 'exit 1' HUP INT TERM
if [ ! -f "$PROFILE" ]; then printf 'user-db:user\nsystem-db:local\n' >"$PROFILE"; fi
policy >"$POLICY"
printf '%s\n' '/org/gnome/desktop/media-handling/automount' '/org/gnome/desktop/media-handling/automount-open' '/org/gnome/desktop/privacy/remember-recent-files' >"$LOCKS"
chmod 644 "$PROFILE" "$POLICY" "$LOCKS"
dconf update
log_ok "Desktop policy compiled; users must log out and back in. Rollback: $BACKUP/restore.sh"

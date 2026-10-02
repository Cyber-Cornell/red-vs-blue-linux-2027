#!/bin/sh
# Install a bounded journald drop-in without replacing distribution defaults.

set -eu

SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
# shellcheck source=lib/portable.sh
. "$SCRIPT_DIR/lib/portable.sh"

MODE=audit
YES=0
SOURCE="$SCRIPT_DIR/configs/journald.conf"
DROPIN_DIR=/etc/systemd/journald.conf.d
DROPIN="$DROPIN_DIR/90-ccdc.conf"

usage() { printf 'Usage: %s --audit | --plan | --apply --yes\n' "$0"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --audit) MODE=audit ;;
    --plan) MODE=plan ;;
    --apply) MODE=apply ;;
    --yes) YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

require_root
[ "$MODE" != plan ] || { cat "$SOURCE"; exit 0; }
if ! have_cmd systemctl || [ ! -d /run/systemd/system ]; then
  log_warn 'systemd is not active; journald stage is not applicable'
  exit 0
fi

audit_journal() {
  systemctl status systemd-journald --no-pager 2>/dev/null || true
  journalctl --disk-usage 2>/dev/null || true
  if have_cmd systemd-analyze; then
    systemd-analyze cat-config systemd/journald.conf 2>/dev/null || true
  else
    cat /etc/systemd/journald.conf "$DROPIN_DIR"/*.conf 2>/dev/null || true
  fi
}

case "$MODE" in
  audit) audit_journal; exit 0 ;;
  plan) cat "$SOURCE"; exit 0 ;;
esac

[ "$YES" -eq 1 ] || die 'Apply requires --yes'
[ -s "$SOURCE" ] || die "Missing $SOURCE"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null || date '+%Y%m%d_%H%M%S')
umask 077
mkdir -p /var/backups "$DROPIN_DIR" /var/log/journal || die 'Cannot create journald directories'
ROLLBACK_DIR=$(mktemp -d "/var/backups/ccdc-journald-$STAMP.XXXXXX") || die 'Cannot create rollback directory'
chmod 700 "$ROLLBACK_DIR"
[ ! -L "$DROPIN" ] || die 'Refusing symlinked journald drop-in'
EXISTED=0
if [ -f "$DROPIN" ]; then
  EXISTED=1
  cp -p "$DROPIN" "$ROLLBACK_DIR/90-ccdc.conf"
fi

restore_journal() {
  log_warn 'Restoring previous journald drop-in'
  if [ "$EXISTED" -eq 1 ]; then
    cp -p "$ROLLBACK_DIR/90-ccdc.conf" "$DROPIN"
  else
    rm -f "$DROPIN"
  fi
  systemctl restart systemd-journald 2>/dev/null || true
}
on_exit() {
  _result=$?
  trap - 0
  if [ "$_result" -ne 0 ]; then restore_journal; fi
  exit "$_result"
}
trap on_exit 0
trap 'exit 1' HUP INT TERM
cp -p "$SOURCE" "$DROPIN"
chown root:root "$DROPIN"
chmod 644 "$DROPIN"
systemd-tmpfiles --create --prefix /var/log/journal 2>/dev/null || true

if have_cmd systemd-analyze && ! systemd-analyze cat-config systemd/journald.conf >/dev/null; then
  die 'Merged journald configuration could not be read; previous state restored'
fi
if ! systemctl restart systemd-journald; then
  die 'systemd-journald restart failed; previous state restored'
fi
if ! systemctl is-active --quiet systemd-journald; then
  die 'systemd-journald is not active; previous state restored'
fi

journalctl --flush 2>/dev/null || true
journalctl --disk-usage >"$ROLLBACK_DIR/applied-disk-usage.txt" 2>&1 || true
cat >"$ROLLBACK_DIR/README.txt" <<EOF
Restore the prior managed drop-in if present, or remove $DROPIN if this
directory has no 90-ccdc.conf backup. Then run:
  systemctl restart systemd-journald
EOF
chmod 600 "$ROLLBACK_DIR"/* 2>/dev/null || true
log_ok 'Bounded persistent journald policy applied'
log_info "Rollback material: $ROLLBACK_DIR"

#!/bin/sh
# Apply a reversible sysctl baseline without overwriting distribution policy.

set -eu

SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
# shellcheck source=lib/portable.sh
. "$SCRIPT_DIR/lib/portable.sh"

MODE=audit
YES=0
DISABLE_USB=0
SOURCE="$SCRIPT_DIR/configs/sysctl.conf"
TARGET=/etc/sysctl.d/99-ccdc.conf
LIMITS=/etc/security/limits.d/99-ccdc-coredumps.conf
USB_CONF=/etc/modprobe.d/99-ccdc-usb-storage.conf
WORK_DIR=''

usage() {
  cat <<EOF
Usage: $0 --audit | --plan | --apply --yes [--disable-usb-storage]

USB storage remains enabled by default because removable and virtual storage
requirements vary. The optional flag writes a modprobe policy for future loads;
it does not unload a module that is in use.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --audit) MODE=audit ;;
    --plan) MODE=plan ;;
    --apply) MODE=apply ;;
    --yes) YES=1 ;;
    --disable-usb-storage) DISABLE_USB=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

require_root
[ "$(uname -s 2>/dev/null)" = Linux ] || die 'This kernel workflow supports Linux only'
[ -s "$SOURCE" ] || die "Missing $SOURCE"

audit_kernel() {
  printf '%s\n' '--- effective requested sysctls ---'
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in ''|'#'*) continue ;; esac
    _key=$(printf '%s\n' "$_line" | awk -F= '{gsub(/[[:space:]]/, "", $1); print $1}')
    _expected=$(printf '%s\n' "$_line" | awk -F= '{sub(/^[^=]*=/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print}')
    _actual=$(sysctl -n "$_key" 2>/dev/null || printf unsupported)
    printf '%-48s expected=%-8s actual=%s\n' "$_key" "$_expected" "$_actual"
  done <"$SOURCE"
  printf '%s\n' '--- loaded security-related modules ---'
  lsmod 2>/dev/null | grep -E '(^Module|usb_storage|firewire|dccp|sctp|rds|tipc)' || true
}

case "$MODE" in
  audit) audit_kernel; exit 0 ;;
  plan) cat "$SOURCE"; [ "$DISABLE_USB" -eq 1 ] && printf '%s\n' 'install usb-storage /bin/false'; exit 0 ;;
esac

[ "$YES" -eq 1 ] || die 'Apply requires --yes'
have_cmd sysctl || die 'sysctl is not installed'

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ccdc-kernel.XXXXXX") || die 'Cannot create temporary directory'
cleanup() {
  [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ] && { rm -f "$WORK_DIR"/* 2>/dev/null || true; rmdir "$WORK_DIR" 2>/dev/null || true; }
}
trap cleanup 0
trap 'exit 1' HUP INT TERM
GENERATED="$WORK_DIR/99-ccdc.conf"
SKIPPED="$WORK_DIR/unsupported.txt"
: >"$GENERATED"
: >"$SKIPPED"

while IFS= read -r _line || [ -n "$_line" ]; do
  case "$_line" in
    ''|'#'*) printf '%s\n' "$_line" >>"$GENERATED"; continue ;;
  esac
  _key=$(printf '%s\n' "$_line" | awk -F= '{gsub(/[[:space:]]/, "", $1); print $1}')
  _proc=/proc/sys/$(printf '%s' "$_key" | tr . /)
  if [ -e "$_proc" ]; then
    printf '%s\n' "$_line" >>"$GENERATED"
  else
    printf '%s\n' "$_key" >>"$SKIPPED"
  fi
done <"$SOURCE"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null || date '+%Y%m%d_%H%M%S')
umask 077
mkdir -p /var/backups /etc/sysctl.d /etc/security/limits.d /etc/modprobe.d || die 'Cannot create policy directories'
ROLLBACK_DIR=$(mktemp -d "/var/backups/ccdc-kernel-$STAMP.XXXXXX") || die 'Cannot create rollback directory'
chmod 700 "$ROLLBACK_DIR"
for _managed in "$TARGET" "$LIMITS" "$USB_CONF"; do
  [ ! -L "$_managed" ] || die "Refusing symlink: $_managed"
done
TARGET_EXISTED=0
LIMITS_EXISTED=0
USB_EXISTED=0
if [ -f "$TARGET" ]; then TARGET_EXISTED=1; cp -p "$TARGET" "$ROLLBACK_DIR/99-ccdc.conf"; fi
if [ -f "$LIMITS" ]; then LIMITS_EXISTED=1; cp -p "$LIMITS" "$ROLLBACK_DIR/99-ccdc-coredumps.conf"; fi
if [ -f "$USB_CONF" ]; then USB_EXISTED=1; cp -p "$USB_CONF" "$ROLLBACK_DIR/99-ccdc-usb-storage.conf"; fi
cp -p "$SKIPPED" "$ROLLBACK_DIR/unsupported-sysctls.txt"
while IFS= read -r _line || [ -n "$_line" ]; do
  case "$_line" in ''|'#'*) continue ;; esac
  _key=$(printf '%s\n' "$_line" | awk -F= '{gsub(/[[:space:]]/, "", $1); print $1}')
  _old_value=$(sysctl -n "$_key") || die "Cannot capture runtime value: $_key"
  [ -n "$_old_value" ] && printf '%s = %s\n' "$_key" "$_old_value" >>"$ROLLBACK_DIR/runtime-before.conf"
done <"$GENERATED"

restore_kernel() {
  log_warn 'Restoring previous managed kernel policy'
  if [ "$TARGET_EXISTED" -eq 1 ]; then cp -p "$ROLLBACK_DIR/99-ccdc.conf" "$TARGET"; else rm -f "$TARGET"; fi
  if [ "$LIMITS_EXISTED" -eq 1 ]; then cp -p "$ROLLBACK_DIR/99-ccdc-coredumps.conf" "$LIMITS"; else rm -f "$LIMITS"; fi
  if [ "$USB_EXISTED" -eq 1 ]; then cp -p "$ROLLBACK_DIR/99-ccdc-usb-storage.conf" "$USB_CONF"; elif [ "$DISABLE_USB" -eq 1 ]; then rm -f "$USB_CONF"; fi
  if [ -s "$ROLLBACK_DIR/runtime-before.conf" ]; then
    sysctl -p "$ROLLBACK_DIR/runtime-before.conf" >"$ROLLBACK_DIR/restore.log" 2>&1 || log_error "Runtime rollback incomplete; inspect $ROLLBACK_DIR/restore.log"
  fi
}
on_exit() {
  _result=$?
  trap - 0
  if [ "$_result" -ne 0 ]; then restore_kernel; fi
  cleanup
  exit "$_result"
}
trap on_exit 0
cp -p "$GENERATED" "$TARGET"
printf '%s\n' '* hard core 0' >"$LIMITS"
chown root:root "$TARGET" "$LIMITS"
chmod 644 "$TARGET" "$LIMITS"
if [ "$DISABLE_USB" -eq 1 ]; then
  printf '%s\n' 'install usb-storage /bin/false' >"$USB_CONF"
  chown root:root "$USB_CONF"
  chmod 644 "$USB_CONF"
fi

if ! sysctl -p "$TARGET" >"$ROLLBACK_DIR/apply.log" 2>&1; then
  die 'One or more supported sysctls failed to apply; managed files restored'
fi

VERIFY_FAILURES=0
while IFS= read -r _line || [ -n "$_line" ]; do
  case "$_line" in ''|'#'*) continue ;; esac
  _key=$(printf '%s\n' "$_line" | awk -F= '{gsub(/[[:space:]]/, "", $1); print $1}')
  _expected=$(printf '%s\n' "$_line" | awk -F= '{sub(/^[^=]*=/, ""); gsub(/[[:space:]]/, ""); print}')
  _actual=$(sysctl -n "$_key" 2>/dev/null | tr -d '[:space:]')
  if [ "$_actual" != "$_expected" ]; then
    printf '%s expected=%s actual=%s\n' "$_key" "$_expected" "$_actual" >>"$ROLLBACK_DIR/verify-failures.txt"
    VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
  fi
done <"$GENERATED"

if [ "$VERIFY_FAILURES" -gt 0 ]; then
  die "$VERIFY_FAILURES sysctl value(s) failed verification; managed files restored"
fi

cat >"$ROLLBACK_DIR/README.txt" <<EOF
Restore or remove $TARGET, $LIMITS, and $USB_CONF according to the backups in
this directory. Runtime sysctls can be reloaded with "sysctl -p FILE". Module
load policy applies to future module loads and may require a reboot to reverse.
EOF
chmod 600 "$ROLLBACK_DIR"/* 2>/dev/null || true
log_ok 'Supported sysctl and core-dump policies applied and verified'
log_info "Skipped unsupported keys: $ROLLBACK_DIR/unsupported-sysctls.txt"
log_info "Rollback material: $ROLLBACK_DIR"

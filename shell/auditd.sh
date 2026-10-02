#!/bin/sh
# Install a bounded, high-signal Linux audit policy with rollback.

set -eu

SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
# shellcheck source=lib/portable.sh
. "$SCRIPT_DIR/lib/portable.sh"

MODE=audit
YES=0
SOURCE_RULES="$SCRIPT_DIR/configs/audit.rules"
SOURCE_CONF="$SCRIPT_DIR/configs/auditd.conf"
TARGET_RULES=/etc/audit/rules.d/90-ccdc.rules
TARGET_CONF=/etc/audit/auditd.conf
WORK_DIR=''
ROLLBACK_DIR=''

usage() {
  cat <<EOF
Usage: $0 --audit | --plan | --apply --yes

Rules remain mutable so failed changes can be rolled back.
EOF
}

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
[ "$(uname -s 2>/dev/null)" = Linux ] || die 'This audit workflow supports Linux only'

audit_record_summary() {
  _summary_name=$1
  shift
  printf '%s\n' "--- $_summary_name record counts (values suppressed) ---"
  if ! have_cmd ausearch || ! have_cmd timeout; then
    log_warn 'ausearch and timeout are required for bounded audit-event summaries'
    return 0
  fi
  timeout -s TERM -k 2 10 ausearch "$@" --raw 2>/dev/null |
    head -n 20000 |
    awk '
      {
        event_type="UNKNOWN"
        for (field=1; field<=NF; field++) {
          if ($field ~ /^type=[A-Z0-9_]+$/) {
            event_type=substr($field, 6)
            break
          }
        }
        count[event_type]++
        total++
      }
      END {
        for (event_type in count) printf "type=%s records=%d\n", event_type, count[event_type]
        printf "records.total=%d\n", total
      }
    '
}

audit_status() {
  if ! have_cmd auditctl; then
    log_warn 'auditctl is not installed'
    return 0
  fi
  printf '%s\n' '--- audit status ---'
  auditctl -s 2>/dev/null || true
  printf '%s\n' '--- loaded rules ---'
  auditctl -l 2>/dev/null || true
  audit_record_summary 'recent audit-configuration' --start recent -k audit_config
  audit_record_summary 'recent authentication and command' --start recent -m USER_AUTH,USER_LOGIN,USER_CMD
}

case "$MODE" in
  audit) audit_status; exit 0 ;;
  plan)
    sed -n '/^[[:space:]]*#/d; /^[[:space:]]*$/d; p' "$SOURCE_RULES"
    exit 0
    ;;
esac

[ "$YES" -eq 1 ] || die 'Apply requires --yes'
[ "${CCDC_AUDIT_IMMUTABLE:-0}" = 0 ] || die 'Immutable mode prevents rollback; finalize it manually after review'
have_cmd auditctl || die 'auditctl is not installed; install the audit package first'
[ -s "$SOURCE_RULES" ] || die "Missing $SOURCE_RULES"
[ -s "$SOURCE_CONF" ] || die "Missing $SOURCE_CONF"

ENABLED=$(auditctl -s 2>/dev/null | awk '$1 == "enabled" {print $2; exit}')
[ "${ENABLED:-0}" != 2 ] || die 'Audit rules are immutable until reboot; no changes were made'

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ccdc-audit.XXXXXX") || die 'Cannot create temporary directory'
cleanup() {
  [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ] && { rm -f "$WORK_DIR"/* 2>/dev/null || true; rmdir "$WORK_DIR" 2>/dev/null || true; }
}
trap cleanup 0
trap 'exit 1' HUP INT TERM
GENERATED="$WORK_DIR/90-ccdc.rules"
SKIPPED="$WORK_DIR/skipped-watches.txt"
: >"$GENERATED"
: >"$SKIPPED"

# auditctl rejects a watch when its path does not exist. Filter only watch lines;
# syscall rules remain unchanged. Paths in this repository contain no spaces.
while IFS= read -r _line || [ -n "$_line" ]; do
  case "$_line" in
    -w[[:space:]]*)
      _watch_path=$(printf '%s\n' "$_line" | awk '{print $2}')
      if [ -e "$_watch_path" ]; then
        printf '%s\n' "$_line" >>"$GENERATED"
      else
        printf '%s\n' "$_watch_path" >>"$SKIPPED"
      fi
      ;;
    -e[[:space:]]2) ;;
    *) printf '%s\n' "$_line" >>"$GENERATED" ;;
  esac
done <"$SOURCE_RULES"

if grep -Eq '^[[:space:]]*-e[[:space:]]+2([[:space:]]|$)' /etc/audit/rules.d/*.rules 2>/dev/null; then
  die 'Existing persistent rules request immutable mode; refusing a non-reversible load'
fi

STAMP=$(date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null || date '+%Y%m%d_%H%M%S')
umask 077
mkdir -p /var/backups /etc/audit/rules.d /var/log/audit || die 'Cannot create audit directories'
ROLLBACK_DIR=$(mktemp -d "/var/backups/ccdc-audit-$STAMP.XXXXXX") || die 'Cannot create rollback directory'
chmod 700 "$ROLLBACK_DIR"
[ ! -L "$TARGET_CONF" ] && [ ! -L "$TARGET_RULES" ] || die 'Refusing symlinked audit configuration'
if [ -f "$TARGET_CONF" ]; then cp -p "$TARGET_CONF" "$ROLLBACK_DIR/auditd.conf"; fi
if [ -f "$TARGET_RULES" ]; then cp -p "$TARGET_RULES" "$ROLLBACK_DIR/90-ccdc.rules"; fi
auditctl -l >"$ROLLBACK_DIR/loaded-rules.txt"
auditctl -s >"$ROLLBACK_DIR/status-before.txt"
{ printf '%s\n' '-D'; sed '/^No rules$/d' "$ROLLBACK_DIR/loaded-rules.txt"; awk '$1 == "enabled" {print "-e " $2} $1 == "failure" {print "-f " $2} $1 == "backlog_limit" {print "-b " $2}' "$ROLLBACK_DIR/status-before.txt"; } >"$ROLLBACK_DIR/runtime-before.rules"
cp -p "$SKIPPED" "$ROLLBACK_DIR/skipped-watches.txt"

restore_audit() {
  log_warn 'Restoring prior audit configuration'
  if [ -f "$ROLLBACK_DIR/auditd.conf" ]; then cp -p "$ROLLBACK_DIR/auditd.conf" "$TARGET_CONF"; else rm -f "$TARGET_CONF"; fi
  if [ -f "$ROLLBACK_DIR/90-ccdc.rules" ]; then
    cp -p "$ROLLBACK_DIR/90-ccdc.rules" "$TARGET_RULES"
  else
    rm -f "$TARGET_RULES"
  fi
  if have_cmd augenrules; then augenrules 2>/dev/null || true; fi
  auditctl -R "$ROLLBACK_DIR/runtime-before.rules" || log_error "Runtime rollback failed; inspect $ROLLBACK_DIR"
  service auditd restart 2>/dev/null || rc-service auditd restart 2>/dev/null || true
}
on_exit() {
  _result=$?
  trap - 0
  if [ "$_result" -ne 0 ]; then restore_audit; fi
  cleanup
  exit "$_result"
}
trap on_exit 0
cp -p "$SOURCE_CONF" "$TARGET_CONF"
cp -p "$GENERATED" "$TARGET_RULES"
chown root:root "$TARGET_CONF" "$TARGET_RULES"
chmod 640 "$TARGET_CONF" "$TARGET_RULES"

if have_cmd augenrules; then
  if ! augenrules --load; then
    die 'Audit rule load failed; previous managed configuration restored'
  fi
else
  if ! auditctl -R "$TARGET_RULES"; then
    die 'Audit rule load failed; previous managed configuration restored'
  fi
fi

if have_cmd rc-service && [ ! -d /run/systemd/system ]; then
  rc-service auditd restart || die 'auditd restart failed'
  rc-service auditd status || die 'auditd is not running'
elif have_cmd service; then
  service auditd restart || die 'auditd restart failed'
  service auditd status || die 'auditd is not running'
elif have_cmd systemctl && [ -d /run/systemd/system ]; then
  systemctl restart auditd || die 'auditd restart failed'
  systemctl is-active --quiet auditd || die 'auditd is not running'
else
  die 'No supported auditd service manager found'
fi

auditctl -s >"$ROLLBACK_DIR/applied-status.txt" 2>&1 || true
auditctl -l >"$ROLLBACK_DIR/applied-rules.txt" 2>&1 || true
awk '{for (i=1;i<NF;i++) if ($i == "-k") print $(i+1)}' "$GENERATED" | sort -u >"$WORK_DIR/expected-keys"
while IFS= read -r _key; do
  grep -Eq "(key=|-k )$_key([ ,]|$)" "$ROLLBACK_DIR/applied-rules.txt" || die "Audit key missing after load: $_key"
done <"$WORK_DIR/expected-keys"

cat >"$ROLLBACK_DIR/README.txt" <<EOF
Review the saved configuration and loaded-rules report before rollback.
Restore the saved auditd.conf and 90-ccdc.rules to their /etc/audit paths,
then run:
  auditctl -R "$ROLLBACK_DIR/runtime-before.rules"
  service auditd restart
EOF
chmod 600 "$ROLLBACK_DIR"/* 2>/dev/null || true
log_ok 'Audit policy loaded and verified'
log_info "Skipped absent watch paths: $ROLLBACK_DIR/skipped-watches.txt"
log_info "Rollback material: $ROLLBACK_DIR"

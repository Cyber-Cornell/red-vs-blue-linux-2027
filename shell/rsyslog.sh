#!/bin/sh
# Add dedicated security log streams without replacing distribution rsyslog.

set -eu

SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
# shellcheck source=lib/portable.sh
. "$SCRIPT_DIR/lib/portable.sh"

MODE=audit
YES=0
REMOTE=${CCDC_LOG_SERVER:-}
SOURCE="$SCRIPT_DIR/configs/rsyslog.conf"
DROPIN=/etc/rsyslog.d/90-ccdc.conf
LOGROTATE=/etc/logrotate.d/ccdc-security

usage() {
  cat <<EOF
Usage: $0 --audit | --plan | --apply --yes [--remote HOST[:PORT]]

--remote forwards all events over TCP to an internal out-of-band collector.
The receiver and competition rules must permit this traffic.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --audit) MODE=audit ;;
    --plan) MODE=plan ;;
    --apply) MODE=apply ;;
    --yes) YES=1 ;;
    --remote)
      shift
      [ "$#" -gt 0 ] || die '--remote requires HOST[:PORT]'
      REMOTE=$1
      ;;
    --remote=*) REMOTE=${1#*=} ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

require_root
if [ "$MODE" != plan ] && ! have_cmd rsyslogd; then
  if [ "$MODE" = audit ]; then log_warn 'rsyslog is not installed'; exit 0; fi
  die 'rsyslogd is not installed'
fi

case "$REMOTE" in *[!A-Za-z0-9._:-]*) die "Invalid remote log destination: $REMOTE" ;; esac

audit_rsyslog() {
  rsyslogd -N1 2>&1 || true
  if have_cmd systemctl && [ -d /run/systemd/system ]; then
    printf 'active=%s enabled=%s\n' "$(systemctl is-active rsyslog 2>/dev/null || printf unknown)" "$(systemctl is-enabled rsyslog 2>/dev/null || printf unknown)"
  else
    rc-service rsyslog status 2>/dev/null || service rsyslog status 2>/dev/null || true
  fi
  for _log in /var/log/ccdc-auth.log /var/log/ccdc-kernel.log /var/log/ccdc-daemon.log; do
    [ -f "$_log" ] || continue
    _lines=$(wc -l <"$_log" 2>/dev/null || printf unknown)
    _metadata=$(stat -c 'uid=%u gid=%g mode=%a size=%s mtime=%Y' "$_log" 2>/dev/null || printf metadata=unavailable)
    printf '\nlog=%s lines=%s %s values_suppressed=yes\n' "$_log" "$_lines" "$_metadata"
    sha256_file "$_log" 2>/dev/null || true
  done
}

case "$MODE" in
  audit) audit_rsyslog; exit 0 ;;
  plan)
    cat "$SOURCE"
    [ -n "$REMOTE" ] && printf '*.* @@%s;RSYSLOG_SyslogProtocol23Format\n' "$REMOTE"
    exit 0
    ;;
esac

[ "$YES" -eq 1 ] || die 'Apply requires --yes'
[ -s "$SOURCE" ] || die "Missing $SOURCE"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null || date '+%Y%m%d_%H%M%S')
umask 077
mkdir -p /var/backups /etc/rsyslog.d /etc/logrotate.d || die 'Cannot create rsyslog directories'
ROLLBACK_DIR=$(mktemp -d "/var/backups/ccdc-rsyslog-$STAMP.XXXXXX") || die 'Cannot create rollback directory'
chmod 700 "$ROLLBACK_DIR"
[ ! -L "$DROPIN" ] && [ ! -L "$LOGROTATE" ] || die 'Refusing symlinked logging configuration'
DROPIN_EXISTED=0
ROTATE_EXISTED=0
if [ -f "$DROPIN" ]; then DROPIN_EXISTED=1; cp -p "$DROPIN" "$ROLLBACK_DIR/90-ccdc.conf"; fi
if [ -f "$LOGROTATE" ]; then ROTATE_EXISTED=1; cp -p "$LOGROTATE" "$ROLLBACK_DIR/ccdc-security.logrotate"; fi
restore_rsyslog() {
  log_warn 'Restoring previous rsyslog configuration'
  if [ "$DROPIN_EXISTED" -eq 1 ]; then cp -p "$ROLLBACK_DIR/90-ccdc.conf" "$DROPIN"; else rm -f "$DROPIN"; fi
  if [ "$ROTATE_EXISTED" -eq 1 ]; then cp -p "$ROLLBACK_DIR/ccdc-security.logrotate" "$LOGROTATE"; else rm -f "$LOGROTATE"; fi
  systemctl restart rsyslog 2>/dev/null || rc-service rsyslog restart 2>/dev/null || service rsyslog restart 2>/dev/null || true
}
on_exit() {
  _result=$?
  trap - 0
  if [ "$_result" -ne 0 ]; then restore_rsyslog; fi
  exit "$_result"
}
trap on_exit 0
trap 'exit 1' HUP INT TERM

{
  cat "$SOURCE"
  if [ -n "$REMOTE" ]; then
    printf '\n# Internal out-of-band forwarding requested by the operator.\n'
    printf '*.* @@%s;RSYSLOG_SyslogProtocol23Format\n' "$REMOTE"
  fi
} >"$DROPIN"
cat >"$LOGROTATE" <<'EOF'
/var/log/ccdc-auth.log /var/log/ccdc-kernel.log /var/log/ccdc-daemon.log {
    daily
    rotate 7
    size 25M
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        /bin/systemctl kill -s HUP rsyslog.service >/dev/null 2>&1 || /usr/bin/pkill -HUP -x rsyslogd >/dev/null 2>&1 || true
    endscript
}
EOF
chown root:root "$DROPIN" "$LOGROTATE" 2>/dev/null || true
chmod 640 "$DROPIN" "$LOGROTATE"

if ! rsyslogd -N1; then
  die 'rsyslog validation failed; previous state restored'
fi
if have_cmd systemctl && [ -d /run/systemd/system ]; then
  systemctl restart rsyslog || { restore_rsyslog; die 'rsyslog restart failed; previous state restored'; }
  systemctl is-active --quiet rsyslog || { restore_rsyslog; die 'rsyslog is not active; previous state restored'; }
elif have_cmd rc-service; then
  rc-service rsyslog restart || { restore_rsyslog; die 'rsyslog restart failed; previous state restored'; }
  rc-service rsyslog status || die 'rsyslog is not running'
else
  service rsyslog restart || { restore_rsyslog; die 'rsyslog restart failed; previous state restored'; }
fi

VERIFY_EVENT="CCDC-security-logging-check-$$-$STAMP"
logger -p auth.notice -t ccdc-toolkit "$VERIFY_EVENT" || die 'Cannot emit logging verification event'
sleep 1
grep -Fq "$VERIFY_EVENT" /var/log/ccdc-auth.log || die 'Verification event did not reach the managed auth log'
cat >"$ROLLBACK_DIR/README.txt" <<EOF
Restore or remove $DROPIN and $LOGROTATE according to the backup files in this
directory, validate with "rsyslogd -N1", then restart rsyslog.
EOF
chmod 600 "$ROLLBACK_DIR"/* 2>/dev/null || true
log_ok 'Dedicated, rotated security logs are active'
[ -n "$REMOTE" ] && log_info "Forwarding all events over TCP to $REMOTE"
log_info "Rollback material: $ROLLBACK_DIR"

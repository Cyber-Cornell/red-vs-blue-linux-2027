#!/bin/sh
# Harden OpenSSH with a validated, reversible drop-in and a service reload.
# Existing authorized_keys and host keys are never replaced.

set -u

SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
# shellcheck source=lib/portable.sh
. "$SCRIPT_DIR/lib/portable.sh"

MODE=audit
YES=0
ALLOW_ROOT_LOCKOUT=0
SOURCE_CONFIG="$SCRIPT_DIR/configs/sshd_config"
SSHD_CONFIG=/etc/ssh/sshd_config
DROPIN_DIR=/etc/ssh/sshd_config.d
DROPIN="$DROPIN_DIR/00-ccdc-hardening.conf"
INCLUDE_LINE='Include /etc/ssh/sshd_config.d/*.conf'
SSHD_BIN=''
SERVICE=''
ROLLBACK_DIR=''
MAIN_BACKUP=''
DROPIN_BACKUP=''
DROPIN_EXISTED=0

usage() {
  cat <<EOF
Usage:
  $0 --audit
  $0 --plan
  $0 --apply --yes [--allow-root-lockout]

The apply workflow prepends the standard sshd_config.d include, writes a
managed hardening drop-in, validates the complete configuration, and reloads
the daemon. It preserves host keys, user keys, and existing sessions.

--allow-root-lockout bypasses the check for a viable non-root admin account.
Use it only with tested console access.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --audit) MODE=audit ;;
    --plan) MODE=plan ;;
    --apply) MODE=apply ;;
    --yes) YES=1 ;;
    --allow-root-lockout) ALLOW_ROOT_LOCKOUT=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

if [ "$MODE" = plan ]; then
  [ -s "$SOURCE_CONFIG" ] || die "Missing or empty $SOURCE_CONFIG"
  printf '%s
' 'Managed SSH directives:'
  sed -n '/^[[:space:]]*#/d; /^[[:space:]]*$/d; p' "$SOURCE_CONFIG"
  exit 0
fi
[ "$MODE" != apply ] || [ "$YES" -eq 1 ] || die 'Apply requires --yes'
require_root
[ "$(uname -s 2>/dev/null)" = Linux ] || die 'This SSH workflow supports Linux only'
[ -s "$SOURCE_CONFIG" ] || die "Missing or empty $SOURCE_CONFIG"
[ -f "$SSHD_CONFIG" ] || die "$SSHD_CONFIG does not exist"

if have_cmd sshd; then
  SSHD_BIN=$(command -v sshd)
elif [ -x /usr/sbin/sshd ]; then
  SSHD_BIN=/usr/sbin/sshd
else
  die 'OpenSSH server is not installed'
fi

if have_cmd systemctl && [ -d /run/systemd/system ]; then
  if systemctl cat ssh.service >/dev/null 2>&1; then SERVICE=ssh; else SERVICE=sshd; fi
elif have_cmd rc-service; then
  if rc-service sshd status >/dev/null 2>&1; then SERVICE=sshd; else SERVICE=ssh; fi
elif [ -x /etc/init.d/ssh ]; then
  SERVICE=ssh
else
  SERVICE=sshd
fi

validate_config() {
  "$SSHD_BIN" -t -f "$SSHD_CONFIG"
}

reload_service() {
  if have_cmd systemctl && [ -d /run/systemd/system ]; then
    systemctl reload "$SERVICE" 2>/dev/null || systemctl restart "$SERVICE"
    systemctl is-active --quiet "$SERVICE"
  elif have_cmd rc-service; then
    rc-service "$SERVICE" reload 2>/dev/null || rc-service "$SERVICE" restart
  elif [ -x "/etc/init.d/$SERVICE" ]; then
    "/etc/init.d/$SERVICE" reload 2>/dev/null || "/etc/init.d/$SERVICE" restart
  else
    _pid=$(cat /run/sshd.pid /var/run/sshd.pid 2>/dev/null | sed -n '1p')
    [ -n "$_pid" ] || return 1
    kill -HUP "$_pid"
  fi
}

summarize_auth_events() {
  awk '
    {
      total++
      value=tolower($0)
      if (value ~ /(failed|failure)/) failed++
      if (value ~ /(accepted|success)/) accepted++
      if (value ~ /invalid user/) invalid++
      if (value ~ /(disconnect|closed)/) disconnected++
    }
    END {
      printf "records.total=%d accepted_or_success=%d failed_or_failure=%d invalid_user=%d disconnected_or_closed=%d values_suppressed=yes\n", total, accepted+0, failed+0, invalid+0, disconnected+0
    }
  '
}

audit_ssh() {
  log_info "sshd binary: $SSHD_BIN"
  log_info "service name: $SERVICE"
  printf '\n--- configuration syntax ---\n'
  validate_config || return 1
  printf '\n--- effective security settings ---\n'
  "$SSHD_BIN" -T -f "$SSHD_CONFIG" 2>/dev/null |
    grep -E '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|permitemptypasswords|allowtcpforwarding|allowagentforwarding|x11forwarding|permittunnel|permituserenvironment|maxauthtries|maxsessions|maxstartups|loglevel|clientaliveinterval|clientalivecountmax|usepam)[[:space:]]' || true
  printf '\n--- configuration files ---\n'
  ls -la /etc/ssh "$DROPIN_DIR" 2>/dev/null || true
  printf '\n--- authorized_keys metadata ---\n'
  find /root /home -xdev -type f \( -name authorized_keys -o -name authorized_keys2 \) -exec ls -ld {} \; 2>/dev/null || true
  printf '\n--- service state ---\n'
  if have_cmd systemctl && [ -d /run/systemd/system ]; then
    printf 'active=%s enabled=%s\n' "$(systemctl is-active "$SERVICE" 2>/dev/null || printf unknown)" "$(systemctl is-enabled "$SERVICE" 2>/dev/null || printf unknown)"
  else
    rc-service "$SERVICE" status 2>/dev/null || service "$SERVICE" status 2>/dev/null || true
  fi
  printf '\n--- recent authentication event counts (values suppressed) ---\n'
  if have_cmd journalctl; then
    if have_cmd timeout; then
      timeout -s TERM -k 2 10 journalctl --since '24 hours ago' -u ssh -u sshd --no-pager -n 300 2>/dev/null |
        summarize_auth_events
    else
      journalctl --since '24 hours ago' -u ssh -u sshd --no-pager -n 300 2>/dev/null |
        summarize_auth_events
    fi
  else
    for _auth_log in /var/log/auth.log /var/log/secure; do
      [ -f "$_auth_log" ] && tail -n 300 "$_auth_log"
    done 2>/dev/null | summarize_auth_events
  fi
}

has_viable_admin() {
  [ -s "$SCRIPT_DIR/configs/admins.txt" ] || return 1
  while IFS= read -r _admin || [ -n "$_admin" ]; do
    _admin=$(printf '%s' "$_admin" | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$_admin" ] || continue
    _entry=$(getent passwd "$_admin" 2>/dev/null || awk -F: -v u="$_admin" '$1 == u {print; exit}' /etc/passwd)
    [ -n "$_entry" ] || continue
    _uid=$(printf '%s\n' "$_entry" | awk -F: '{print $3}')
    _home=$(printf '%s\n' "$_entry" | awk -F: '{print $6}')
    _shell=$(printf '%s\n' "$_entry" | awk -F: '{print $7}')
    [ "$_uid" -ne 0 ] || continue
    case "$_shell" in */nologin|*/false|'') continue ;; esac
    _shadow=$(awk -F: -v u="$_admin" '$1 == u {print $2; exit}' /etc/shadow 2>/dev/null)
    case "$_shadow" in ''|'!'*|'*'*) _password_ok=0 ;; *) _password_ok=1 ;; esac
    if [ -s "$_home/.ssh/authorized_keys" ] || [ "$_password_ok" -eq 1 ]; then
      return 0
    fi
  done <"$SCRIPT_DIR/configs/admins.txt"
  return 1
}

restore_previous() {
  log_warn 'Restoring previous SSH configuration'
  [ -n "$MAIN_BACKUP" ] && [ -f "$MAIN_BACKUP" ] && cp -p "$MAIN_BACKUP" "$SSHD_CONFIG"
  if [ "$DROPIN_EXISTED" -eq 1 ] && [ -f "$DROPIN_BACKUP" ]; then
    cp -p "$DROPIN_BACKUP" "$DROPIN"
  else
    rm -f "$DROPIN"
  fi
  validate_config || log_error 'Restored SSH configuration does not validate'
  reload_service || log_error 'Could not reload restored SSH configuration'
}

printf '%s\n' 'Managed SSH directives:'
sed -n '/^[[:space:]]*#/d; /^[[:space:]]*$/d; p' "$SOURCE_CONFIG"

case "$MODE" in
  audit) audit_ssh; exit $? ;;
  plan) exit 0 ;;
esac

[ "$YES" -eq 1 ] || die 'Apply requires --yes'

if [ -n "${SSH_CONNECTION:-}" ]; then
  _session_user=${SUDO_USER:-$(id -un 2>/dev/null || printf root)}
  if { [ "$_session_user" = root ] || [ "$_session_user" = unknown ]; } &&
     [ "$ALLOW_ROOT_LOCKOUT" -ne 1 ] && ! has_viable_admin; then
    die 'Remote root session detected without a viable approved non-root admin; refusing potential lockout'
  fi
fi

validate_config || die 'Current SSH configuration is already invalid; repair it before applying hardening'

STAMP=$(date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null || date '+%Y%m%d_%H%M%S')
umask 077
ROLLBACK_DIR=$(mktemp -d "/var/backups/ccdc-ssh-$STAMP.XXXXXX") || die "Cannot create SSH backup directory"
chmod 700 "$ROLLBACK_DIR"
MAIN_BACKUP="$ROLLBACK_DIR/sshd_config"
DROPIN_BACKUP="$ROLLBACK_DIR/00-ccdc-hardening.conf"
cp -p "$SSHD_CONFIG" "$MAIN_BACKUP" || die 'Cannot back up sshd_config'
if [ -f "$DROPIN" ]; then
  DROPIN_EXISTED=1
  cp -p "$DROPIN" "$DROPIN_BACKUP" || die 'Cannot back up existing CCDC drop-in'
fi

mkdir -p "$DROPIN_DIR" || die "Cannot create $DROPIN_DIR"
chmod 755 "$DROPIN_DIR"

TMP_MAIN=$(mktemp "${TMPDIR:-/tmp}/sshd-config.XXXXXX") || die 'Cannot create temporary file'
TMP_DROPIN=$(mktemp "${TMPDIR:-/tmp}/sshd-dropin.XXXXXX") || { rm -f "$TMP_MAIN"; die 'Cannot create temporary file'; }
trap 'rm -f "$TMP_MAIN" "$TMP_DROPIN"' 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# The first value for most sshd keywords wins. Put the managed include before
# distribution defaults, and remove an identical later include to avoid parsing
# the same drop-ins twice.
{
  printf '%s\n' "$INCLUDE_LINE"
  grep -F -x -v "$INCLUDE_LINE" "$SSHD_CONFIG" || true
} >"$TMP_MAIN"
{
  printf '%s\n' '# Managed by the CCDC Linux toolkit. Edit configs/sshd_config and re-apply.'
  cat "$SOURCE_CONFIG"
} >"$TMP_DROPIN"

chmod 600 "$TMP_MAIN" "$TMP_DROPIN"
chown root:root "$TMP_MAIN" "$TMP_DROPIN" 2>/dev/null || true
cp -p "$TMP_MAIN" "$SSHD_CONFIG" || { restore_previous; die 'Could not install sshd_config include'; }
cp -p "$TMP_DROPIN" "$DROPIN" || { restore_previous; die 'Could not install SSH hardening drop-in'; }
rm -f "$TMP_MAIN" "$TMP_DROPIN"
trap - 0 HUP INT TERM

if ! validate_config; then
  restore_previous
  die 'Hardened SSH configuration failed validation and was rolled back'
fi

if ! reload_service; then
  restore_previous
  die 'SSH reload failed and the previous configuration was restored'
fi

if ! validate_config; then
  restore_previous
  die 'SSH configuration failed its post-reload check and was rolled back'
fi

cat >"$ROLLBACK_DIR/README.txt" <<EOF
To restore this SSH configuration with console access:
  cp -p $MAIN_BACKUP $SSHD_CONFIG

If this run replaced an existing managed drop-in:
  cp -p $DROPIN_BACKUP $DROPIN
Otherwise remove:
  rm -f "$DROPIN"

Then run:
  $SSHD_BIN -t -f $SSHD_CONFIG
  systemctl reload $SERVICE
EOF
chmod 600 "$ROLLBACK_DIR"/* 2>/dev/null || true

log_ok 'SSH hardening validated and reloaded; existing sessions were preserved'
log_info "Rollback material: $ROLLBACK_DIR"

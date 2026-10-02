#!/bin/sh
# Review accounts and lock only names explicitly approved by an operator.
# This script deliberately does not create users, replace PAM, rewrite sudoers,
# or infer that every unlisted account is malicious.

set -u

SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
CONFIG_DIR="$SCRIPT_DIR/../configs"
# shellcheck source=../lib/portable.sh
. "$SCRIPT_DIR/../lib/portable.sh"

MODE=audit
YES=0
TERMINATE=0
ADMINS_FILE="$CONFIG_DIR/admins.txt"
USERS_FILE="$CONFIG_DIR/users.txt"
SERVICES_FILE="$CONFIG_DIR/services.txt"
LOCK_FILE="$CONFIG_DIR/lock_accounts.txt"
WORK_DIR=''

usage() {
  cat <<EOF
Usage:
  $0 [--audit]
  $0 --apply --yes [--terminate-sessions]

Review inputs:
  $ADMINS_FILE
  $USERS_FILE
  $SERVICES_FILE
  $LOCK_FILE

Audit reports accounts that need human review. Apply locks only accounts named
in lock_accounts.txt. It refuses root, UID 0, allowlisted, and active-session
accounts. --terminate-sessions makes active-session accounts eligible and kills
their processes after the lock is applied.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --audit) MODE=audit ;;
    --apply) MODE=apply ;;
    --yes) YES=1 ;;
    --terminate-sessions) TERMINATE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

[ "$MODE" != apply ] || [ "$YES" -eq 1 ] || die "Apply requires --yes"
require_root
[ "$(uname -s 2>/dev/null)" = Linux ] || die "Account workflow supports Linux only"

cleanup() {
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    rm -f "$WORK_DIR"/* 2>/dev/null || true
    rmdir "$WORK_DIR" 2>/dev/null || true
  fi
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ccdc-accounts.XXXXXX") || die 'Cannot create temporary directory'
ALLOWLIST="$WORK_DIR/allowlist"
: >"$ALLOWLIST"

valid_name() {
  case "$1" in
    ''|*[!A-Za-z0-9_.-]*|[0-9-]*) return 1 ;;
  esac
  return 0
}

read_config() {
  _config=$1
  _destination=$2
  [ -f "$_config" ] || return 0
  while IFS= read -r _name || [ -n "$_name" ]; do
    _name=$(printf '%s' "$_name" | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$_name" ] || continue
    valid_name "$_name" || die "Invalid account name in $_config: $_name"
    printf '%s\n' "$_name" >>"$_destination"
  done <"$_config"
}

read_config "$ADMINS_FILE" "$ALLOWLIST"
read_config "$USERS_FILE" "$ALLOWLIST"
read_config "$SERVICES_FILE" "$ALLOWLIST"
LC_ALL=C sort -u "$ALLOWLIST" -o "$ALLOWLIST"

is_allowed() { grep -F -x "$1" "$ALLOWLIST" >/dev/null 2>&1; }

is_interactive_shell() {
  case "$1" in
    ''|*/nologin|*/false|*/sync|*/shutdown|*/halt) return 1 ;;
  esac
  return 0
}

password_state() {
  _entry=$(awk -F: -v u="$1" '$1 == u {print $2; exit}' /etc/shadow 2>/dev/null)
  case "$_entry" in
    '') printf empty ;;
    '!'*|'*'*) printf locked ;;
    *) printf set ;;
  esac
}

has_session() {
  who 2>/dev/null | awk '{print $1}' | grep -F -x "$1" >/dev/null 2>&1
}

audit_accounts() {
  printf '%-22s %-7s %-11s %-10s %-10s %s\n' USER UID APPROVED PASSWORD LOGIN_SHELL HOME
  printf '%-22s %-7s %-11s %-10s %-10s %s\n' ---- --- -------- -------- ----------- ----

  while IFS=: read -r _user _pw _uid _gid _gecos _home _shell; do
    _approved=no
    is_allowed "$_user" && _approved=yes
    _login=no
    is_interactive_shell "$_shell" && _login=yes
    _state=$(password_state "$_user")
    printf '%-22s %-7s %-11s %-10s %-10s %s\n' "$_user" "$_uid" "$_approved" "$_state" "$_login" "$_home"

    if [ "$_uid" -eq 0 ] && [ "$_user" != root ]; then
      printf '[CRITICAL] UID 0 account other than root: %s\n' "$_user" >&2
    fi
    if [ "$_state" = empty ]; then
      printf '[CRITICAL] Empty password field: %s\n' "$_user" >&2
    fi
    if [ "$_approved" = no ] && { [ "$_uid" -ge 1000 ] 2>/dev/null || is_interactive_shell "$_shell"; }; then
      printf '[REVIEW] Unapproved interactive or human-range account: %s (uid=%s shell=%s)\n' \
        "$_user" "$_uid" "$_shell" >&2
    fi
  done </etc/passwd

  while IFS= read -r _approved_user || [ -n "$_approved_user" ]; do
    [ -n "$_approved_user" ] || continue
    id "$_approved_user" >/dev/null 2>&1 ||
      printf '[REVIEW] Approved account does not exist on this host: %s\n' "$_approved_user" >&2
  done <"$ALLOWLIST"

  log_info 'Audit only: add a reviewed name to configs/lock_accounts.txt before apply'
}

lock_account() {
  _user=$1
  _record=$(getent passwd "$_user" 2>/dev/null || awk -F: -v u="$_user" '$1 == u {print; exit}' /etc/passwd)
  [ -n "$_record" ] || { log_warn "Account does not exist: $_user"; return 0; }
  _uid=$(printf '%s\n' "$_record" | awk -F: '{print $3}')
  _shell=$(printf '%s\n' "$_record" | awk -F: '{print $7}')

  [ "$_user" != root ] || { log_error 'Refusing to lock root'; return 1; }
  [ "$_uid" -ne 0 ] || { log_error "Refusing to lock UID 0 account: $_user"; return 1; }
  if is_allowed "$_user"; then
    log_error "Refusing to lock allowlisted account: $_user"
    return 1
  fi
  if [ "$_user" = "${SUDO_USER:-}" ] || [ "$_user" = "${LOGNAME:-}" ]; then
    log_error "Refusing current operator account: $_user"
    return 1
  fi
  if has_session "$_user" && [ "$TERMINATE" -ne 1 ]; then
    log_error "Refusing active-session account $_user; review it and use --terminate-sessions if intended"
    return 1
  fi

  printf '%s\n' "$_record" >>"$LEDGER"
  if have_cmd usermod; then
    usermod -L "$_user" || return 1
    usermod -e 1 "$_user" || return 1
    if [ -x /usr/sbin/nologin ]; then
      usermod -s /usr/sbin/nologin "$_user" || return 1
    elif [ -x /sbin/nologin ]; then
      usermod -s /sbin/nologin "$_user" || return 1
    else
      usermod -s /bin/false "$_user" || return 1
    fi
  else
    passwd -l "$_user" || return 1
    log_error "usermod is unavailable; password locked but shell $_shell was not changed"
    return 1
  fi

  if [ "$TERMINATE" -eq 1 ]; then
    pkill -KILL -u "$_uid" 2>/dev/null || true
  fi
  log_ok "Locked explicitly reviewed account: $_user"
}

if [ "$MODE" = audit ]; then
  audit_accounts
  exit 0
fi

[ "$YES" -eq 1 ] || die 'Apply requires --yes'
[ -f "$LOCK_FILE" ] || die "Missing $LOCK_FILE"
LOCKS="$WORK_DIR/locks"
: >"$LOCKS"
read_config "$LOCK_FILE" "$LOCKS"
LC_ALL=C sort -u "$LOCKS" -o "$LOCKS"
[ -s "$LOCKS" ] || die 'lock_accounts.txt has no reviewed account names; nothing was changed'

STAMP=$(date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null || date '+%Y%m%d_%H%M%S')
umask 077
ROLLBACK_DIR=$(mktemp -d "/var/backups/ccdc-accounts-$STAMP.XXXXXX") || die "Cannot create account backup directory"
chmod 700 "$ROLLBACK_DIR"
cp -p /etc/passwd /etc/shadow "$ROLLBACK_DIR/" || die 'Cannot back up account databases'
LEDGER="$ROLLBACK_DIR/locked-passwd-records.txt"
: >"$LEDGER"
chmod 600 "$ROLLBACK_DIR"/*

FAILURES=0
while IFS= read -r _target || [ -n "$_target" ]; do
  lock_account "$_target" || FAILURES=$((FAILURES + 1))
done <"$LOCKS"

cat >"$ROLLBACK_DIR/README.txt" <<EOF
Account state before this run is in passwd and shadow. Compare individual
entries before restoring. For an intentionally restored account, use:
  usermod -U USER
  usermod -e '' USER
  usermod -s PREVIOUS_SHELL USER

Previous passwd records for accounts changed by the run are in:
  $LEDGER
EOF
chmod 600 "$ROLLBACK_DIR/README.txt"

log_info "Rollback material: $ROLLBACK_DIR"
[ "$FAILURES" -eq 0 ] || die "$FAILURES account(s) could not be locked safely"

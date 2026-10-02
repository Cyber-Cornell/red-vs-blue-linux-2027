#!/bin/sh
# Audit and repair permissions on a narrow set of security-sensitive paths.

set -eu

SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
# shellcheck source=lib/portable.sh
. "$SCRIPT_DIR/lib/portable.sh"

MODE=audit
YES=0
ROLLBACK_DIR=''
LEDGER=''

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

audit_permissions() {
  sh "$SCRIPT_DIR/tools/permission_audit.sh" --root /
  printf '%s\n' '--- sensitive path ownership and modes ---'
  for _path in \
    /etc/passwd /etc/passwd- /etc/group /etc/group- /etc/shadow /etc/shadow- \
    /etc/gshadow /etc/gshadow- /etc/sudoers /etc/sudoers.d /etc/ssh /etc/ssh/sshd_config \
    /etc/crontab /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly \
    /root /tmp /var/tmp /dev/shm /var/log; do
    [ -e "$_path" ] && stat -c '%A %a %U:%G %n' "$_path" 2>/dev/null || true
  done
  printf '%s\n' '--- world-writable files in system configuration and executable paths ---'
  find /etc /usr/bin /usr/sbin /bin /sbin -xdev -type f -perm -0002 -exec ls -ld {} \; 2>/dev/null | head -n 2000
  printf '%s\n' '--- SSH private keys with group/other permissions ---'
  find /etc/ssh /root /home -xdev -type f \( -name 'ssh_host_*_key' -o -name 'id_*' \) ! -name '*.pub' \
    -perm /077 -exec ls -ld {} \; 2>/dev/null | head -n 2000
  printf '%s\n' '--- authorized_keys with group/other permissions ---'
  find /root /home -xdev -type f \( -name authorized_keys -o -name authorized_keys2 \) -perm /077 \
    -exec ls -ld {} \; 2>/dev/null | head -n 2000
}

case "$MODE" in
  audit) audit_permissions; exit 0 ;;
  plan)
    cat <<'EOF'
passwd/group databases       root:root   0644
shadow/gshadow databases     root:shadow 0640 (root:root where shadow is absent)
sudoers files                root:root   0440 after visudo validation
SSH server config/private keys           0600
SSH public keys                           0644
approved user .ssh directories           0700; authorized_keys 0600
cron files/directories                    root-owned and non-world-writable
temporary directories                     1777
EOF
    exit 0
    ;;
esac

[ "$YES" -eq 1 ] || die 'Apply requires --yes'
have_cmd stat || die 'stat is required for reversible permission changes'
if have_cmd visudo && ! visudo -c >/dev/null 2>&1; then
  die 'Current sudoers configuration is invalid; refusing permission changes'
fi

STAMP=$(date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null || date '+%Y%m%d_%H%M%S')
umask 077
mkdir -p /var/backups || die 'Cannot create backup parent'
ROLLBACK_DIR=$(mktemp -d "/var/backups/ccdc-permissions-$STAMP.XXXXXX") || die 'Cannot create rollback directory'
chmod 700 "$ROLLBACK_DIR"
LEDGER="$ROLLBACK_DIR/original.tsv"
printf 'mode\tuid\tgid\tpath\n' >"$LEDGER"
cat >"$ROLLBACK_DIR/restore.sh" <<'EOF'
#!/bin/sh
set -eu
LEDGER=$(CDPATH= cd -P "$(dirname "$0")" && pwd)/original.tsv
tail -n +2 "$LEDGER" | while IFS="$(printf '\t')" read -r mode uid gid path; do
  [ ! -L "$path" ] || { printf 'Refusing symlink: %s\n' "$path" >&2; exit 1; }
  [ -e "$path" ] || continue
  chown "$uid:$gid" "$path"
  chmod "$mode" "$path"
done
EOF
chmod 700 "$ROLLBACK_DIR/restore.sh"
chmod 600 "$LEDGER"
restore_on_failure() {
  _result=$?
  trap - 0 HUP INT TERM
  if [ "$_result" -ne 0 ]; then
    sh "$ROLLBACK_DIR/restore.sh" || log_error "Rollback incomplete; inspect $LEDGER"
  fi
  exit "$_result"
}
trap restore_on_failure 0
trap 'exit 1' HUP INT TERM

record_path() {
  [ ! -L "$1" ] || die "Refusing symlink: $1"
  case "$1" in *"$(printf '\t')"*|*'
'*) die 'Cannot record a path containing tabs or newlines' ;; esac
  # Record each path once, including users present in both approval lists.
  awk -F '\t' -v path="$1" '$4 == path {found=1} END {exit !found}' "$LEDGER" && return 0
  stat -c '%a	%u	%g	%n' "$1" >>"$LEDGER"
}

secure_path() {
  _path=$1
  _owner=$2
  _group=$3
  _mode=$4
  [ ! -L "$_path" ] || die "Refusing symlink: $_path"
  [ -e "$_path" ] || return 0
  record_path "$_path"
  chown "$_owner:$_group" "$_path"
  chmod "$_mode" "$_path"
}

SHADOW_GROUP=root
getent group shadow >/dev/null 2>&1 && SHADOW_GROUP=shadow

while read -r policy_mode policy_owner policy_group policy_path; do
  [ -n "$policy_mode" ] || continue
  case "$policy_mode" in *[!0-7]*|'') die 'Invalid mode in permissions.conf' ;; esac
  case "$policy_path" in /etc/*|/tmp|/var/tmp|/dev/shm) ;; *) die "Unsupported policy path: $policy_path" ;; esac
  case "$policy_path/" in */../*|*/./*) die "Ambiguous policy path: $policy_path" ;; esac
  if [ "$policy_group" = shadow ]; then policy_group=$SHADOW_GROUP; fi
  secure_path "$policy_path" "$policy_owner" "$policy_group" "$policy_mode"
done <"$SCRIPT_DIR/configs/permissions.conf"

if [ -d /etc/sudoers.d ]; then
  find /etc/sudoers.d -xdev -type f -print 2>/dev/null | while IFS= read -r _path; do
    secure_path "$_path" root root 0440
  done
fi

if [ -d /etc/ssh ]; then
  find /etc/ssh -xdev -type f -name 'ssh_host_*_key' ! -name '*.pub' -print 2>/dev/null |
    while IFS= read -r _path; do secure_path "$_path" root root 0600; done
  find /etc/ssh -xdev -type f -name 'ssh_host_*.pub' -print 2>/dev/null |
    while IFS= read -r _path; do secure_path "$_path" root root 0644; done
  if [ -d /etc/ssh/sshd_config.d ]; then
    find /etc/ssh/sshd_config.d -xdev -type f -name '*.conf' -print | while IFS= read -r _path; do secure_path "$_path" root root 0600; done
  fi
fi

for _path in /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly; do
  [ -d "$_path" ] || continue
  find "$_path" -xdev -type f -print 2>/dev/null | while IFS= read -r _cron; do
    record_path "$_cron"
    chown root:root "$_cron"
    chmod go-w "$_cron"
  done
done

for _service_dir in /etc/systemd/system /etc/init.d /etc/conf.d; do
  [ -d "$_service_dir" ] || continue
  find "$_service_dir" -xdev -type f -print | while IFS= read -r _definition; do
    record_path "$_definition"
    chown root:root "$_definition"
    chmod go-w "$_definition"
  done
done

# Restrict SSH material only for accounts explicitly approved in the toolkit.
for _list in "$SCRIPT_DIR/configs/admins.txt" "$SCRIPT_DIR/configs/users.txt"; do
  [ -f "$_list" ] || continue
  while IFS= read -r _user || [ -n "$_user" ]; do
    _user=$(printf '%s' "$_user" | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$_user" ] || continue
    _entry=$(getent passwd "$_user" 2>/dev/null || true)
    [ -n "$_entry" ] || continue
    _account_uid=$(printf '%s\n' "$_entry" | awk -F: '{print $3}')
    _account_gid=$(printf '%s\n' "$_entry" | awk -F: '{print $4}')
    _home=$(printf '%s\n' "$_entry" | awk -F: '{print $6}')
    [ -d "$_home/.ssh" ] || continue
    secure_path "$_home/.ssh" "$_account_uid" "$_account_gid" 0700
    for _keys in "$_home/.ssh/authorized_keys" "$_home/.ssh/authorized_keys2"; do
      secure_path "$_keys" "$_account_uid" "$_account_gid" 0600
    done
  done <"$_list"
done

if have_cmd visudo && ! visudo -c; then
  die "sudoers validation failed; use $LEDGER and the pre-change snapshot to restore modes"
fi

log_ok 'Sensitive permissions normalized without recursive system ownership changes'
log_info "Rollback script: $ROLLBACK_DIR/restore.sh"

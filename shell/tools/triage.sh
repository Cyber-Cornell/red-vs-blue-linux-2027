#!/bin/sh
# Bounded, read-only Linux triage collection for a live CCDC host.
# Output may contain sensitive host data and is created mode 0700/0600.

set -u

SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
# shellcheck source=../lib/portable.sh
. "$SCRIPT_DIR/../lib/portable.sh"

OUTPUT_DIR=''
MAX_LINES=${CCDC_TRIAGE_MAX_LINES:-5000}
RECENT_DAYS=${CCDC_TRIAGE_RECENT_DAYS:-7}

usage() {
  cat <<EOF
Usage: $0 --output DIR

Environment:
  CCDC_TRIAGE_MAX_LINES=N    Per-section output bound (default: 5000)
  CCDC_TRIAGE_RECENT_DAYS=N  Recent-file lookback (default: 7)
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      shift
      [ "$#" -gt 0 ] || die '--output requires a directory'
      OUTPUT_DIR=$1
      ;;
    --output=*) OUTPUT_DIR=${1#*=} ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

require_root
[ "$(uname -s 2>/dev/null)" = Linux ] || die 'triage.sh currently supports Linux only'
[ -n "$OUTPUT_DIR" ] || die '--output is required'
case "$MAX_LINES" in ''|*[!0-9]*) die 'CCDC_TRIAGE_MAX_LINES must be numeric' ;; esac
case "$RECENT_DAYS" in ''|*[!0-9]*) die 'CCDC_TRIAGE_RECENT_DAYS must be numeric' ;; esac
[ "$MAX_LINES" -gt 0 ] && [ "$MAX_LINES" -le 100000 ] || die 'Line limit must be 1..100000'
have_cmd timeout || die 'timeout is required for bounded collection'
if [ "${CCDC_TRIAGE_RUNNING:-0}" != 1 ]; then
  export CCDC_TRIAGE_RUNNING=1
  exec timeout 300 sh "$0" --output "$OUTPUT_DIR"
fi
ulimit -f 20480 || die 'Cannot bound evidence file sizes'

umask 077
mkdir -m 700 "$OUTPUT_DIR" || die 'Output directory must not already exist; create its parent first'
chmod 700 "$OUTPUT_DIR" 2>/dev/null || true
OUTPUT_DIR=$(CDPATH= cd -P "$OUTPUT_DIR" 2>/dev/null && pwd)
[ -n "$OUTPUT_DIR" ] || die 'Cannot resolve output directory'
ALERTS="$OUTPUT_DIR/00-alerts.txt"
: >"$ALERTS"

heading() {
  printf '\n===== %s =====\n' "$1"
}

alert() {
  printf '[%s] %s\n' "$1" "$2" >>"$ALERTS"
}

log_info 'Collecting host metadata'
{
  heading 'COLLECTION'
  printf 'created_utc: %s\n' "$(utc_now)"
  printf 'collector_pid: %s\n' "$$"
  printf 'hostname: %s\n' "$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf unknown)"
  printf 'effective_user: %s\n' "$(id 2>/dev/null || true)"
  heading 'KERNEL'
  uname -a 2>/dev/null || true
  heading 'OS RELEASE'
  sed -n '1,120p' /etc/os-release 2>/dev/null || true
  heading 'UPTIME AND LOAD'
  uptime 2>/dev/null || true
  cat /proc/loadavg 2>/dev/null || true
  heading 'TIME'
  date 2>/dev/null || true
  timedatectl status 2>/dev/null || true
  heading 'FILESYSTEM SPACE'
  df -hT 2>/dev/null || df -h 2>/dev/null || true
  heading 'MOUNTS'
  findmnt 2>/dev/null || mount 2>/dev/null || true
  heading 'KERNEL COMMAND LINE'
  cat /proc/cmdline 2>/dev/null || true
} >"$OUTPUT_DIR/01-system.txt" 2>&1

log_info 'Collecting account and access state'
{
  heading 'PASSWD DATABASE'
  getent passwd 2>/dev/null || cat /etc/passwd
  heading 'GROUP DATABASE'
  getent group 2>/dev/null || cat /etc/group
  heading 'UID 0 ACCOUNTS'
  awk -F: '$3 == 0 {print $1 ":" $3 ":" $6 ":" $7}' /etc/passwd
  heading 'INTERACTIVE ACCOUNTS'
  awk -F: '$7 !~ /(nologin|false|sync|shutdown|halt)$/ {print $1 ":uid=" $3 ":home=" $6 ":shell=" $7}' /etc/passwd
  heading 'PASSWORD STATE (HASHES REDACTED)'
  awk -F: '{s="set"; if ($2 == "") s="EMPTY"; else if ($2 ~ /^[!*]/) s="locked"; print $1 ":" s}' /etc/shadow 2>/dev/null || true
  heading 'SUDO PRIVILEGE SOURCES'
  grep -RInE '^[[:space:]]*[^#].*(ALL|NOPASSWD|sudo|wheel)' /etc/sudoers /etc/sudoers.d 2>/dev/null | head -n "$MAX_LINES" || true
  heading 'AUTHORIZED KEYS METADATA AND HASHES'
  find /root /home -xdev -type f \( -name authorized_keys -o -name authorized_keys2 \) -print 2>/dev/null |
    while IFS= read -r _keyfile; do
      ls -ld "$_keyfile" 2>/dev/null
      sha256_file "$_keyfile" 2>/dev/null || true
    done
  heading 'CURRENT AND RECENT LOGINS'
  who -a 2>/dev/null || true
  w 2>/dev/null || true
  last -F -n 100 2>/dev/null || true
  lastb -F -n 100 2>/dev/null || true
} >"$OUTPUT_DIR/02-accounts.txt" 2>&1

UID0_COUNT=$(awk -F: '$3 == 0 {n++} END {print n+0}' /etc/passwd)
[ "$UID0_COUNT" -le 1 ] || alert CRITICAL "Multiple UID 0 accounts found ($UID0_COUNT)"
if awk -F: '$2 == "" {found=1} END {exit !found}' /etc/shadow 2>/dev/null; then
  alert CRITICAL 'One or more accounts have an empty password field'
fi

log_info 'Collecting network and firewall state'
{
  heading 'INTERFACES'
  ip -details address show 2>/dev/null || ifconfig -a 2>/dev/null || true
  heading 'ROUTES'
  ip route show table all 2>/dev/null || route -n 2>/dev/null || true
  ip -6 route show table all 2>/dev/null || true
  heading 'NEIGHBORS'
  ip neigh show 2>/dev/null || arp -an 2>/dev/null || true
  heading 'LISTENING SOCKETS WITH PROCESSES'
  ss -H -lntup 2>/dev/null || netstat -lntup 2>/dev/null || true
  heading 'ALL CONNECTIONS WITH PROCESSES'
  ss -H -antup 2>/dev/null | head -n "$MAX_LINES" || netstat -antup 2>/dev/null | head -n "$MAX_LINES" || true
  heading 'RESOLVER'
  cat /etc/resolv.conf 2>/dev/null || true
  resolvectl status 2>/dev/null || true
  heading 'NFTABLES'
  nft -s list ruleset 2>/dev/null || true
  heading 'IPTABLES IPV4'
  iptables-save 2>/dev/null || true
  heading 'IPTABLES IPV6'
  ip6tables-save 2>/dev/null || true
} >"$OUTPUT_DIR/03-network.txt" 2>&1

log_info 'Collecting process, service, and container state'
{
  heading 'PROCESSES'
  ps auxwww 2>/dev/null || ps -ef 2>/dev/null || true
  heading 'PROCESS TREE'
  pstree -ap 2>/dev/null || true
  heading 'DELETED PROCESS EXECUTABLES'
  for _exe in /proc/[0-9]*/exe; do
    [ -e "$_exe" ] || [ -L "$_exe" ] || continue
    _target=$(readlink "$_exe" 2>/dev/null || true)
    case "$_target" in *' (deleted)') printf '%s -> %s\n' "$_exe" "$_target" ;; esac
  done
  heading 'SYSTEMD RUNNING SERVICES'
  systemctl list-units --type=service --state=running --no-pager 2>/dev/null || true
  heading 'SYSTEMD FAILED UNITS'
  systemctl --failed --no-pager 2>/dev/null || true
  heading 'SYSV/OPENRC SERVICES'
  service --status-all 2>/dev/null || rc-status -a 2>/dev/null || true
  if have_cmd rc-status; then rc-status -a 2>/dev/null || true; fi
  if have_cmd rc-update; then rc-update show 2>/dev/null || true; fi
  heading 'DOCKER CONTAINERS'
  docker ps --no-trunc 2>/dev/null || true
  heading 'PODMAN CONTAINERS'
  podman ps --no-trunc 2>/dev/null || true
} >"$OUTPUT_DIR/04-processes-services.txt" 2>&1

if grep -q ' (deleted)$' "$OUTPUT_DIR/04-processes-services.txt" 2>/dev/null; then
  alert HIGH 'A running process has a deleted executable; inspect 04-processes-services.txt'
fi

log_info 'Collecting persistence state'
{
  heading 'LD PRELOAD'
  ls -ld /etc/ld.so.preload 2>/dev/null || true
  sed -n '1,100p' /etc/ld.so.preload 2>/dev/null || true
  heading 'SYSTEM CRON'
  ls -la /etc/cron.d /etc/cron.* /var/spool/cron /var/spool/cron/crontabs 2>/dev/null || true
  for _cron in /etc/crontab /etc/anacrontab /etc/cron.d/* /var/spool/cron/* /var/spool/cron/crontabs/*; do
    [ -f "$_cron" ] || continue
    printf '\n--- %s ---\n' "$_cron"
    sed -n '1,300p' "$_cron" 2>/dev/null || true
  done
  heading 'SYSTEMD TIMERS'
  systemctl list-timers --all --no-pager 2>/dev/null || true
  heading 'LOCAL SYSTEMD UNIT FILES'
  find /etc/systemd/system /run/systemd/system -type f -o -type l 2>/dev/null | LC_ALL=C sort | head -n "$MAX_LINES"
  heading 'INIT AND RC HOOKS'
  ls -la /etc/init.d /etc/rc.local /etc/rc*.d 2>/dev/null || true
  heading 'SHELL STARTUP HOOKS'
  find /etc/profile /etc/profile.d /etc/bash.bashrc /root /home -xdev -maxdepth 3 -type f \
    \( -name '*.sh' -o -name '.bashrc' -o -name '.profile' -o -name '.bash_profile' -o -name '.zshrc' \) \
    -print 2>/dev/null | LC_ALL=C sort | head -n "$MAX_LINES"
  heading 'AT JOBS'
  atq 2>/dev/null || true
  heading 'KERNEL MODULES'
  lsmod 2>/dev/null || true
} >"$OUTPUT_DIR/05-persistence.txt" 2>&1

if [ -s /etc/ld.so.preload ]; then
  alert CRITICAL '/etc/ld.so.preload is active'
fi

log_info 'Collecting bounded filesystem indicators'
{
  heading 'SUID AND SGID FILES'
  find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -exec ls -ld {} \; 2>/dev/null | head -n "$MAX_LINES"
  heading 'FILE CAPABILITIES'
  getcap -r / 2>/dev/null | head -n "$MAX_LINES" || true
  heading 'WORLD-WRITABLE SYSTEM FILES'
  find /etc /usr /bin /sbin -xdev -type f -perm -0002 -exec ls -ld {} \; 2>/dev/null | head -n "$MAX_LINES"
  heading 'RECENT EXECUTABLE FILES IN HIGH-RISK LOCATIONS'
  find /tmp /var/tmp /dev/shm /etc /usr/local/bin /usr/local/sbin /var/www -xdev -type f \
    -mtime "-$RECENT_DAYS" -perm /111 -exec ls -ld {} \; 2>/dev/null | head -n "$MAX_LINES"
  heading 'RECENT FILES UNDER ETC AND WEB ROOTS'
  find /etc /var/www -xdev -type f -mtime "-$RECENT_DAYS" -exec ls -ld {} \; 2>/dev/null | head -n "$MAX_LINES"
  heading 'HIDDEN REGULAR FILES IN TEMPORARY DIRECTORIES'
  find /tmp /var/tmp /dev/shm -xdev -type f -name '.*' -exec ls -ld {} \; 2>/dev/null | head -n "$MAX_LINES"
} >"$OUTPUT_DIR/06-filesystem.txt" 2>&1

if grep -q '^-' "$OUTPUT_DIR/06-filesystem.txt" 2>/dev/null; then
  : # Detailed findings require operator review; avoid claiming every match is malicious.
fi

log_info 'Collecting recent security logs'
{
  heading 'JOURNAL WARNINGS (CURRENT BOOT)'
  journalctl -b -p warning..alert --no-pager -n "$MAX_LINES" 2>/dev/null || true
  heading 'SSH AND AUTH EVENTS (LAST 24 HOURS)'
  journalctl --since '24 hours ago' --no-pager -u ssh -u sshd -t sudo -t su -n "$MAX_LINES" 2>/dev/null || true
  heading 'AUDIT EVENTS (LAST 24 HOURS)'
  ausearch --start recent 2>/dev/null | tail -n "$MAX_LINES" || true
  heading 'TRADITIONAL AUTH LOG TAILS'
  for _authlog in /var/log/auth.log /var/log/secure /var/log/messages /var/log/syslog; do
    [ -f "$_authlog" ] || continue
    printf '\n--- %s ---\n' "$_authlog"
    tail -n 1000 "$_authlog"
  done
} >"$OUTPUT_DIR/07-security-logs.txt" 2>&1

log_info 'Hashing critical executables and configuration'
{
  heading 'SHA-256 BASELINE'
  for _critical in \
    /bin/sh /bin/bash /usr/bin/sudo /usr/bin/passwd /usr/bin/ssh /usr/sbin/sshd \
    /etc/passwd /etc/group /etc/sudoers /etc/ssh/sshd_config /etc/ld.so.preload; do
    [ -f "$_critical" ] || continue
    sha256_file "$_critical" 2>/dev/null || true
  done
} >"$OUTPUT_DIR/08-critical-hashes.txt" 2>&1

if [ ! -s "$ALERTS" ]; then
  printf '[INFO] No deterministic high-confidence alerts. Review every collection file.\n' >"$ALERTS"
fi

if have_cmd sha256sum; then
  (cd "$OUTPUT_DIR" && find . -maxdepth 1 -type f ! -name manifest.sha256 -print |
    LC_ALL=C sort | while IFS= read -r _file; do sha256sum "$_file"; done) >"$OUTPUT_DIR/manifest.sha256"
elif have_cmd shasum; then
  (cd "$OUTPUT_DIR" && find . -maxdepth 1 -type f ! -name manifest.sha256 -print |
    LC_ALL=C sort | while IFS= read -r _file; do shasum -a 256 "$_file"; done) >"$OUTPUT_DIR/manifest.sha256"
else
  log_warn 'No SHA-256 tool found; evidence manifest was not created'
fi

chmod 600 "$OUTPUT_DIR"/* 2>/dev/null || true
log_ok "Triage complete: $OUTPUT_DIR"
log_info "Start with: $ALERTS"

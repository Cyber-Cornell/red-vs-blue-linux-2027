#!/bin/sh
# Create a compact pre-change snapshot for configuration rollback.

set -u

SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
# shellcheck source=../lib/portable.sh
. "$SCRIPT_DIR/../lib/portable.sh"

OUTPUT_DIR=''
MIN_FREE_KB=${CCDC_MIN_FREE_KB:-102400}

usage() {
  printf 'Usage: %s --output DIR\n' "$0"
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
[ -n "$OUTPUT_DIR" ] || die '--output is required'
case "$MIN_FREE_KB" in ''|*[!0-9]*) die 'CCDC_MIN_FREE_KB must be numeric' ;; esac
have_cmd timeout || die 'timeout is required for bounded collection'
if [ "${CCDC_SNAPSHOT_RUNNING:-0}" != 1 ]; then
  export CCDC_SNAPSHOT_RUNNING=1
  exec timeout 300 sh "$0" --output "$OUTPUT_DIR"
fi
umask 077
mkdir -m 700 "$OUTPUT_DIR" || die 'Output directory must not already exist; create its parent first'
OUTPUT_DIR=$(CDPATH= cd -P "$OUTPUT_DIR" 2>/dev/null && pwd)
[ -n "$OUTPUT_DIR" ] || die 'Cannot resolve output directory'
case "$OUTPUT_DIR/" in /etc/*|/var/spool/cron/*) die 'Output must be outside archived directories' ;; esac
ulimit -f 262144 || die 'Cannot bound snapshot file sizes'

FREE_KB=$(df -Pk "$OUTPUT_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
case "${FREE_KB:-}" in
  ''|*[!0-9]*) log_warn 'Could not determine free space' ;;
  *)
    [ "$FREE_KB" -ge "$MIN_FREE_KB" ] ||
      die "Only $((FREE_KB / 1024)) MiB free; at least $((MIN_FREE_KB / 1024)) MiB is required"
    ;;
esac

STAMP=$(date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null || date '+%Y%m%d_%H%M%S')
HOST=$(hostname 2>/dev/null || printf unknown)
ARCHIVE="$OUTPUT_DIR/${HOST}-${STAMP}-etc.tar.gz"
META="$OUTPUT_DIR/system-state.txt"

log_info 'Recording package, service, mount, and firewall state'
{
  printf 'created_utc=%s\n' "$(utc_now)"
  printf 'hostname=%s\n' "$HOST"
  printf 'kernel=%s\n' "$(uname -a 2>/dev/null || true)"
  printf '\n--- mounts ---\n'
  mount 2>/dev/null || true
  printf '\n--- block devices ---\n'
  lsblk -f 2>/dev/null || true
  printf '\n--- enabled services ---\n'
  systemctl list-unit-files --state=enabled --no-pager 2>/dev/null || true
  if have_cmd rc-status; then rc-status -a 2>/dev/null || true; fi
  if have_cmd rc-update; then rc-update show 2>/dev/null || true; fi
  printf '\n--- listening sockets ---\n'
  ss -H -lntup 2>/dev/null || netstat -lntup 2>/dev/null || true
  printf '\n--- packages ---\n'
  if have_cmd dpkg-query; then
    dpkg-query -W -f='${binary:Package}\t${Version}\n' 2>/dev/null
  elif have_cmd rpm; then
    rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null
  elif have_cmd apk; then
    apk list --installed 2>/dev/null
  elif have_cmd pacman; then
    pacman -Q 2>/dev/null
  fi
} >"$META"

if have_cmd nft; then
  nft -s list ruleset >"$OUTPUT_DIR/firewall.nft" 2>&1 || true
fi
if have_cmd iptables-save; then
  iptables-save >"$OUTPUT_DIR/firewall.v4" 2>&1 || true
fi
if have_cmd ip6tables-save; then
  ip6tables-save >"$OUTPUT_DIR/firewall.v6" 2>&1 || true
fi

set -- etc
[ -d /var/spool/cron ] && set -- "$@" var/spool/cron
[ -d /var/spool/cron/crontabs ] && set -- "$@" var/spool/cron/crontabs
[ -f /var/spool/anacron/cron.daily ] && set -- "$@" var/spool/anacron/cron.daily

log_info "Creating configuration archive: $ARCHIVE"
if ! (cd / && tar -czpf "$ARCHIVE" "$@") >"$OUTPUT_DIR/tar.log" 2>&1; then
  rm -f "$ARCHIVE"
  die "Snapshot archive failed; see $OUTPUT_DIR/tar.log"
fi
tar -tzf "$ARCHIVE" >/dev/null || die 'Snapshot archive failed integrity verification'
chmod 600 "$ARCHIVE" "$META" "$OUTPUT_DIR/tar.log" 2>/dev/null || true

cat >"$OUTPUT_DIR/RESTORE.txt" <<EOF
This directory was created before a CCDC toolkit apply run.

Inspect before restoring. To extract into a temporary review directory:
  mkdir /tmp/ccdc-restore-review
  tar -xzpf $ARCHIVE -C /tmp/ccdc-restore-review

Restore individual files with cp -a after comparing them. Do not extract the
entire archive over a live system unless console access and service recovery
have been tested.
EOF

if have_cmd sha256sum; then
  (cd "$OUTPUT_DIR" && find . -maxdepth 1 -type f ! -name manifest.sha256 -print |
    LC_ALL=C sort | while IFS= read -r _file; do sha256sum "$_file"; done) >"$OUTPUT_DIR/manifest.sha256"
elif have_cmd shasum; then
  (cd "$OUTPUT_DIR" && find . -maxdepth 1 -type f ! -name manifest.sha256 -print |
    LC_ALL=C sort | while IFS= read -r _file; do shasum -a 256 "$_file"; done) >"$OUTPUT_DIR/manifest.sha256"
else
  log_warn 'No SHA-256 tool found; snapshot manifest was not created'
fi

SIZE=$(du -h "$ARCHIVE" 2>/dev/null | awk '{print $1}')
log_ok "Snapshot complete: $ARCHIVE (${SIZE:-unknown size})"

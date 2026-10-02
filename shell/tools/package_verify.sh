#!/bin/sh
# Compare installed package files with local metadata without installing tools.
set -u
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
. "$SCRIPT_DIR/../lib/portable.sh"
MAX_SECONDS=${CCDC_PACKAGE_VERIFY_TIMEOUT:-300}
MAX_OUTPUT_KB=${CCDC_PACKAGE_VERIFY_MAX_KB:-4096}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --timeout) shift; [ "$#" -gt 0 ] || die '--timeout requires N'; MAX_SECONDS=$1 ;;
    --timeout=*) MAX_SECONDS=${1#*=} ;;
    --max-output-kb) shift; [ "$#" -gt 0 ] || die '--max-output-kb requires N'; MAX_OUTPUT_KB=$1 ;;
    --max-output-kb=*) MAX_OUTPUT_KB=${1#*=} ;;
    -h|--help)
      printf 'Usage: %s [--timeout N] [--max-output-kb N]\n' "$0"
      printf '%s\n' 'Defaults: 300 seconds and 4096 KiB. Returns the native verifier status; review output even when status is zero.'
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done
require_root
[ "$(uname -s)" = Linux ] || die 'Package verification supports Linux only'
case "$MAX_SECONDS" in ''|*[!0-9]*) die 'timeout must be numeric' ;; esac
[ "$MAX_SECONDS" -ge 10 ] && [ "$MAX_SECONDS" -le 3600 ] || die 'timeout must be 10..3600 seconds'
case "$MAX_OUTPUT_KB" in ''|*[!0-9]*) die 'max-output-kb must be numeric' ;; esac
[ "$MAX_OUTPUT_KB" -ge 64 ] && [ "$MAX_OUTPUT_KB" -le 16384 ] || die 'max-output-kb must be 64..16384'
if [ "${CCDC_PACKAGE_VERIFY_RUNNING:-0}" != 1 ]; then
  have_cmd timeout || die 'timeout is required for bounded package verification'
  umask 077
  _buffer=$(mktemp "${TMPDIR:-/tmp}/ccdc-package-verify.XXXXXX") || die 'Cannot allocate private output buffer'
  trap 'rm -f "$_buffer"' 0
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  export CCDC_PACKAGE_VERIFY_RUNNING=1
  (ulimit -f "$((MAX_OUTPUT_KB * 2))" || exit 2
   timeout -s TERM -k 5 "$MAX_SECONDS" sh "$0" --timeout "$MAX_SECONDS" --max-output-kb "$MAX_OUTPUT_KB") >"$_buffer" 2>&1
  _status=$?
  cat "$_buffer"
  rm -f "$_buffer"
  trap - 0 HUP INT TERM 2>/dev/null || true
  case "$_status" in
    124|137|143) printf '%s\n' '[WARN] Package-verification deadline reached; coverage is incomplete' >&2 ;;
    153) printf '%s\n' '[WARN] Package-verification output cap reached; coverage is incomplete' >&2 ;;
  esac
  exit "$_status"
fi
export LC_ALL=C
ID=''
ID_LIKE=''
[ ! -f /etc/os-release ] || . /etc/os-release
printf '%s\n' 'Package verification uses local metadata; it is not proof that a host is clean.'
printf '%s\n' 'Configuration drift may be legitimate. Some tools report differences with status zero.'
printf 'Whole-run bounds: %s seconds and %s KiB output.\n' "$MAX_SECONDS" "$MAX_OUTPUT_KB"
case " $ID $ID_LIKE " in
  *debian*|*ubuntu*|*devuan*|*kali*|*raspbian*|*linuxmint*|*pop*)
    if have_cmd debsums; then
      printf '%s\n' '[INFO] Running debsums -a -s -c'
      debsums -a -s -c
    elif have_cmd dpkg; then
      printf '%s\n' '[INFO] Running dpkg --verify (checks available stored checksums only)'
      dpkg --verify
    else
      log_error 'No Debian package verifier available'; exit 2
    fi
    ;;
  *rhel*|*fedora*|*centos*|*alma*|*rocky*|*amzn*|*suse*|*sles*|*' ol '*)
    have_cmd rpm || { log_error 'rpm unavailable'; exit 2; }
    printf '%s\n' '[INFO] Running rpm -Va --noscripts (verification scripts disabled)'
    rpm -Va --noscripts
    ;;
  *alpine*)
    have_cmd apk || { log_error 'apk unavailable'; exit 2; }
    printf '%s\n' '[INFO] Running apk --no-logfile audit --system'
    apk --no-logfile audit --system
    ;;
  *arch*|*manjaro*)
    have_cmd pacman || { log_error 'pacman unavailable'; exit 2; }
    printf '%s\n' '[INFO] Running pacman -Qkk (file metadata; not a complete cryptographic content check)'
    pacman -Qkk
    ;;
  *) log_error 'Unsupported distribution or missing /etc/os-release'; exit 2 ;;
esac
STATUS=$?
printf '[INFO] Native verifier exit status: %s\n' "$STATUS"
exit "$STATUS"

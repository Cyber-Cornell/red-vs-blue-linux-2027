#!/bin/sh
# Read-only, race-tolerant Linux process hunter.

set -u

SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
# shellcheck source=../lib/portable.sh
. "$SCRIPT_DIR/../lib/portable.sh"

MAX_PROCESSES=${CCDC_PROCESS_MAX_PROCESSES:-1024}
MAX_SECONDS=${CCDC_PROCESS_TIMEOUT:-60}
MAX_OUTPUT_KB=${CCDC_PROCESS_MAX_OUTPUT_KB:-4096}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --max-processes) shift; [ "$#" -gt 0 ] || die '--max-processes requires N'; MAX_PROCESSES=$1 ;;
    --max-processes=*) MAX_PROCESSES=${1#*=} ;;
    --timeout) shift; [ "$#" -gt 0 ] || die '--timeout requires N'; MAX_SECONDS=$1 ;;
    --timeout=*) MAX_SECONDS=${1#*=} ;;
    --max-output-kb) shift; [ "$#" -gt 0 ] || die '--max-output-kb requires N'; MAX_OUTPUT_KB=$1 ;;
    --max-output-kb=*) MAX_OUTPUT_KB=${1#*=} ;;
    -h|--help)
      printf 'Usage: %s [--max-processes N] [--timeout N] [--max-output-kb N]\n' "$0"
      printf '%s\n' 'Defaults: 1024 processes, 60 seconds, and 4096 KiB output.'
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done
require_root
[ "$(uname -s 2>/dev/null)" = Linux ] || die 'This process hunter supports Linux only'
case "$MAX_PROCESSES" in ''|*[!0-9]*) die 'max-processes must be numeric' ;; esac
[ "$MAX_PROCESSES" -ge 1 ] && [ "$MAX_PROCESSES" -le 32768 ] || die 'max-processes must be 1..32768'
case "$MAX_SECONDS" in ''|*[!0-9]*) die 'timeout must be numeric' ;; esac
[ "$MAX_SECONDS" -ge 1 ] && [ "$MAX_SECONDS" -le 600 ] || die 'timeout must be 1..600 seconds'
case "$MAX_OUTPUT_KB" in ''|*[!0-9]*) die 'max-output-kb must be numeric' ;; esac
[ "$MAX_OUTPUT_KB" -ge 64 ] && [ "$MAX_OUTPUT_KB" -le 16384 ] || die 'max-output-kb must be 64..16384'

if [ "${CCDC_PROCESS_AUDIT_RUNNING:-0}" != 1 ]; then
  have_cmd timeout || die 'timeout is required for a bounded process audit'
  umask 077
  _buffer=$(mktemp "${TMPDIR:-/tmp}/ccdc-process-audit.XXXXXX") || die 'Cannot allocate private output buffer'
  trap 'rm -f "$_buffer"' 0
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  export CCDC_PROCESS_AUDIT_RUNNING=1
  (ulimit -f "$((MAX_OUTPUT_KB * 2))" || exit 2
   timeout -s TERM -k 5 "$MAX_SECONDS" sh "$0" \
     --max-processes "$MAX_PROCESSES" --timeout "$MAX_SECONDS" --max-output-kb "$MAX_OUTPUT_KB") >"$_buffer" 2>&1
  _status=$?
  cat "$_buffer"
  rm -f "$_buffer"
  trap - 0 HUP INT TERM 2>/dev/null || true
  case "$_status" in
    124|137|143) printf '%s\n' '[WARN] Process-audit deadline reached; coverage is incomplete' >&2 ;;
    153) printf '%s\n' '[WARN] Process-audit output cap reached; coverage is incomplete' >&2 ;;
  esac
  exit "$_status"
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ccdc-process.XXXXXX") || die 'Cannot create temporary directory'
cleanup() { rm -f "$WORK_DIR"/* 2>/dev/null || true; rmdir "$WORK_DIR" 2>/dev/null || true; }
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' HUP TERM

PROC_PIDS="$WORK_DIR/proc-pids"
PS_PIDS="$WORK_DIR/ps-pids"

snapshot_pids() {
  for _dir in /proc/[0-9]*; do
    [ -d "$_dir" ] && printf '%s\n' "${_dir##*/}"
  done | LC_ALL=C sort -n -u | head -n "$MAX_PROCESSES" >"$PROC_PIDS"
  ps -e -o pid= >"$WORK_DIR/ps-raw" 2>/dev/null || die 'Cannot collect ps PID inventory'
  awk '{print $1}' "$WORK_DIR/ps-raw" | LC_ALL=C sort -n -u | head -n "$MAX_PROCESSES" >"$PS_PIDS"
}

snapshot_pids
printf 'Bounds: processes=%s seconds=%s output_kib=%s. Environment values and command arguments are suppressed.\n' "$MAX_PROCESSES" "$MAX_SECONDS" "$MAX_OUTPUT_KB"
printf '%s\n' '=== PROCESS INVENTORY ==='
(ps -eo user,pid,ppid,lstart,etime,stat,comm --sort=pid 2>/dev/null || ps -o user,pid,ppid,stat,comm 2>/dev/null || true) | head -n "$((MAX_PROCESSES + 1))"

printf '\n%s\n' '=== HIGH-CONFIDENCE FINDINGS ==='
FINDINGS=0
while IFS= read -r _pid; do
  _exe="/proc/$_pid/exe"
  [ -L "$_exe" ] || continue
  _target=$(readlink "$_exe" 2>/dev/null || true)
  case "$_target" in
    *' (deleted)')
      printf '[HIGH] PID %s runs a deleted executable: %s\n' "$_pid" "$_target"
      FINDINGS=$((FINDINGS + 1))
      ;;
    /tmp/*|/var/tmp/*|/dev/shm/*)
      printf '[HIGH] PID %s executes from a temporary filesystem: %s\n' "$_pid" "$_target"
      FINDINGS=$((FINDINGS + 1))
      ;;
    /var/www/*|/srv/www/*)
      printf '[HIGH] PID %s executes directly from a web root: %s\n' "$_pid" "$_target"
      FINDINGS=$((FINDINGS + 1))
      ;;
  esac
done <"$PROC_PIDS"

while IFS= read -r _pid; do
  _cwd="/proc/$_pid/cwd"
  [ -L "$_cwd" ] || continue
  _target=$(readlink "$_cwd" 2>/dev/null || true)
  case "$_target" in
    *' (deleted)')
      printf '[REVIEW] PID %s has a deleted working directory: %s\n' "$_pid" "$_target"
      FINDINGS=$((FINDINGS + 1))
      ;;
  esac
done <"$PROC_PIDS"

while IFS= read -r _pid; do
  _env="/proc/$_pid/environ"
  [ -r "$_env" ] || continue
  if tr '\000' '\n' <"$_env" 2>/dev/null | grep -q '^LD_PRELOAD='; then
    printf '[HIGH] PID %s has LD_PRELOAD in its environment (value redacted)\n' "$_pid"
    FINDINGS=$((FINDINGS + 1))
  fi
done <"$PROC_PIDS"

sleep 1
ps -e -o pid= >"$WORK_DIR/ps-second-raw" 2>/dev/null || die 'Cannot repeat ps PID inventory'
awk '{print $1}' "$WORK_DIR/ps-second-raw" >"$WORK_DIR/ps-second"
_second_proc="$WORK_DIR/proc-pids-second"
for _dir in /proc/[0-9]*; do [ -d "$_dir" ] && printf '%s\n' "${_dir##*/}"; done | LC_ALL=C sort -n -u | head -n "$MAX_PROCESSES" >"$_second_proc"
LC_ALL=C comm -23 "$PROC_PIDS" "$PS_PIDS" | while IFS= read -r _pid; do
  # Only report a PID that survived a second /proc snapshot. Short-lived process
  # races are expected and are not hidden-process evidence.
  if grep -F -x "$_pid" "$_second_proc" >/dev/null 2>&1 && ! grep -F -x "$_pid" "$WORK_DIR/ps-second" >/dev/null 2>&1; then
    _comm=$(cat "/proc/$_pid/comm" 2>/dev/null || printf unknown)
    printf '[REVIEW] Persistent PID %s (%s) exists in /proc but not ps output\n' "$_pid" "$_comm"
  fi
done

printf '\n%s\n' '=== LISTENERS AND CONNECTIONS ==='
(ss -H -lntup 2>/dev/null || netstat -lntup 2>/dev/null || true) | head -n "$MAX_PROCESSES"
printf '\n%s\n' '--- established external connections ---'
(ss -H -ntup state established 2>/dev/null || netstat -ntup 2>/dev/null | grep ESTABLISHED || true) | head -n "$MAX_PROCESSES"

printf '\n%s\n' '=== PROCESS CAPABILITIES ==='
if have_cmd getpcaps; then
  while IFS= read -r _pid; do
    _caps=$(getpcaps "$_pid" 2>/dev/null || true)
    case "$_caps" in *'=') ;; *'= '*|*'cap_'*) printf '%s\n' "$_caps" ;; esac
  done <"$PROC_PIDS"
else
  log_warn 'getpcaps is unavailable; file and process capabilities were not decoded'
fi

printf '\n%s\n' '=== PROCESS NAMESPACE DEVIATIONS FROM PID 1 ==='
while IFS= read -r _pid; do
  _pid_dir="/proc/$_pid"
  [ -d "$_pid_dir/ns" ] || continue
  [ "$_pid" = 1 ] && continue
  _pid_ns=$(readlink "$_pid_dir/ns/pid" 2>/dev/null || true)
  _net_ns=$(readlink "$_pid_dir/ns/net" 2>/dev/null || true)
  _root_pid_ns=$(readlink /proc/1/ns/pid 2>/dev/null || true)
  _root_net_ns=$(readlink /proc/1/ns/net 2>/dev/null || true)
  if [ -n "$_pid_ns" ] && { [ "$_pid_ns" != "$_root_pid_ns" ] || [ "$_net_ns" != "$_root_net_ns" ]; }; then
    _comm=$(cat "$_pid_dir/comm" 2>/dev/null || printf unknown)
    printf '[REVIEW] PID %s (%s) uses a non-host PID or network namespace\n' "$_pid" "$_comm"
  fi
done <"$PROC_PIDS"

if [ "$FINDINGS" -eq 0 ]; then
  printf '\n%s\n' '[INFO] No deterministic deleted/temp/web-root executable findings. Review listeners, ancestry, capabilities, and namespaces.'
else
  printf '\n[INFO] %s deterministic finding(s); validate each against service ownership and the timeline.\n' "$FINDINGS"
fi

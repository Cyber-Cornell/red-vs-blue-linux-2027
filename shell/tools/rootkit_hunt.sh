#!/bin/sh
set -u
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd) || exit 1
. "$SCRIPT_DIR/../lib/portable.sh"
case "${1:---audit}" in --audit) ;; --help|-h) printf 'Usage: %s [--audit]\nRead-only bounded rootkit leads; no signature verdict or remediation.\n' "$0"; exit 0 ;; *) die 'Only --audit is supported' ;; esac
[ "$#" -le 1 ] || die 'Unexpected arguments'
have_cmd timeout || die 'timeout is required for bounded collection'
if [ "${CCDC_ROOTKIT_RUNNING:-0}" != 1 ]; then
  export CCDC_ROOTKIT_RUNNING=1
  exec timeout 60 sh "$0" --audit
fi
umask 077
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ccdc-rootkit.XXXXXX") || die 'Cannot create private metadata workspace'
trap 'rm -f "$WORK"/*; rmdir "$WORK" 2>/dev/null || true' 0
trap 'exit 1' HUP INT TERM
safe_path() { printf '%s' "$1" | tr '[:cntrl:]' '?' | cut -c 1-240; }
printf '%s\n' 'Rootkit review: leads require independent verification. Live tools and /proc may both be compromised; process races and legitimate modules cause false positives.'
if timeout 3 ps -e -o pid >"$WORK/ps" 2>/dev/null; then
  awk '$1 ~ /^[0-9]+$/ {print $1}' "$WORK/ps" >"$WORK/pids"
else
  printf '%s\n' 'COVERAGE process listing unavailable'
  : >"$WORK/pids"
fi
COUNT=0
for proc in /proc/[0-9]*; do
  [ -d "$proc" ] || continue
  COUNT=$((COUNT + 1))
  [ "$COUNT" -le 256 ] || { printf '%s\n' 'COVERAGE process limit reached'; break; }
  pid=${proc##*/}
  if [ -s "$WORK/pids" ] && ! grep -qx "$pid" "$WORK/pids" && kill -0 "$pid" 2>/dev/null; then
    printf 'LEAD PROCESS_VISIBILITY_MISMATCH pid=%s evidence=%s (possible process race)\n' "$pid" "$proc"
  fi
  exe=$(readlink "$proc/exe" 2>/dev/null) || continue
  case "$exe" in
    *' (deleted)'|/memfd:*) printf 'LEAD DELETED_OR_MEMORY_EXEC pid=%s path=%s evidence=%s/exe\n' "$pid" "$(safe_path "$exe")" "$proc" ;;
  esac
done
printf '\nKERNEL METADATA:\n'
if [ -r /proc/sys/kernel/tainted ]; then
  printf 'taint='; head -c 32 /proc/sys/kernel/tainted; printf '\n'
  printf '%s\n' 'Taint alone is not a rootkit indicator (unsigned/out-of-tree modules and diagnostics can taint kernels).'
fi
if [ -r /proc/modules ]; then
  head -n 128 /proc/modules | awk '{printf "module=%s bytes=%s refcount=%s state=%s\n",$1,$2,$3,$5}'
else printf '%s\n' 'COVERAGE loaded module list unavailable'; fi
for setting in /proc/sys/kernel/modules_disabled /proc/sys/kernel/kptr_restrict /proc/sys/kernel/dmesg_restrict; do
  [ -r "$setting" ] || continue
  printf 'setting=%s value=' "$setting"; head -c 32 "$setting"; printf '\n'
done
printf '\nPRELOAD/MODULE PERSISTENCE METADATA:\n'
for file in /etc/ld.so.preload /etc/modules /etc/rc.local; do
  [ -s "$file" ] || continue
  printf 'REVIEW configured-persistence path=%s (contents suppressed)\n' "$file"
  timeout 3 sha256sum "$file" 2>/dev/null || printf '%s\n' 'COVERAGE hash unavailable'
done
for dir in /etc/modules-load.d /etc/modprobe.d; do
  [ -d "$dir" ] || continue
  timeout 3 find "$dir" -xdev -maxdepth 1 -type f 2>/dev/null | head -n 32 | while IFS= read -r path; do printf 'REVIEW module-policy path=%s\n' "$(safe_path "$path")"; done
done
printf '\nUNUSUAL DEVICE-TREE REGULAR FILES (not device nodes; review legitimate exceptions):\n'
timeout 3 find /dev -xdev -maxdepth 2 -type f 2>/dev/null | head -n 64 | while IFS= read -r path; do printf 'LEAD DEV_REGULAR_FILE path=%s\n' "$(safe_path "$path")"; done
printf '\nPACKAGE INTEGRITY COVERAGE:\n'
if have_cmd dpkg; then
  for package in coreutils procps kmod; do
    dpkg-query -W -f '${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' || continue
    rc=0
    (ulimit -f 128; timeout 10 dpkg -V "$package") >"$WORK/integrity" 2>/dev/null || rc=$?
    printf 'manager=dpkg package=%s exit=%s changed-records=%s\n' "$package" "$rc" "$(wc -l <"$WORK/integrity")"
  done
elif have_cmd rpm; then
  for package in coreutils procps-ng kmod; do
    rpm -q "$package" >/dev/null 2>&1 || continue
    rc=0
    (ulimit -f 128; timeout 10 rpm -V "$package") >"$WORK/integrity" 2>/dev/null || rc=$?
    printf 'manager=rpm package=%s exit=%s changed-records=%s\n' "$package" "$rc" "$(wc -l <"$WORK/integrity")"
  done
elif have_cmd apk; then
  rc=0
  (ulimit -f 128; timeout 10 apk --no-logfile audit --system) >"$WORK/integrity" 2>/dev/null || rc=$?
  printf 'manager=apk exit=%s changed-records=%s (configuration changes may be expected)\n' "$rc" "$(wc -l <"$WORK/integrity")"
else printf '%s\n' 'COVERAGE supported package verifier unavailable'; fi
printf '%s\n' 'Correlate with package-verify stage and offline trusted-media inspection; no findings do not prove a clean host.'
[ "$COUNT" -gt 0 ] || exit 2

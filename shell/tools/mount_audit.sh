#!/bin/sh
set -u
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/../lib/portable.sh"
FSTAB=/etc/fstab
MOUNTINFO=/proc/self/mountinfo
while [ "$#" -gt 0 ]; do
  case "$1" in
    --fstab|--mountinfo) option=$1; shift; [ "$#" -gt 0 ] || die "$option requires a file"; case "$option" in --fstab) FSTAB=$1 ;; --mountinfo) MOUNTINFO=$1 ;; esac ;;
    --help|-h) printf 'Usage: %s [--fstab FILE] [--mountinfo FILE]\nRead-only; review findings against scored services and container/storage requirements.\n' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done
have_cmd timeout || die 'timeout is required'
if [ "${CCDC_MOUNT_AUDIT_RUNNING:-0}" != 1 ]; then
  export CCDC_MOUNT_AUDIT_RUNNING=1
  exec timeout 30 sh "$0" --fstab "$FSTAB" --mountinfo "$MOUNTINFO"
fi
[ -f "$FSTAB" ] && [ -r "$MOUNTINFO" ] || die 'Readable fstab and mountinfo inputs are required'
[ "$(wc -c <"$FSTAB")" -le 1048576 ] || die 'fstab exceeds 1 MiB input limit'
umask 077
WORK=$(mktemp -d) || die 'Cannot create audit workspace'
trap 'rm -f "$WORK/mountinfo" "$WORK/native"; rmdir "$WORK"' 0
trap 'exit 1' HUP INT TERM
ulimit -f 4096 || die 'Cannot bound audit input copy'
head -n 10001 "$MOUNTINFO" >"$WORK/mountinfo" || die 'Cannot capture bounded mountinfo'
[ "$(wc -l <"$WORK/mountinfo")" -le 10000 ] || die 'mountinfo exceeds 10000-entry limit'
RESULT=0
printf '%s\n' '--- fstab identity, ownership and content ---'
if [ -L "$FSTAB" ]; then printf '[REVIEW] fstab is a symlink\n'; fi
stat -c '%u:%g mode=%a inode=%i %n' "$FSTAB" || RESULT=1
sha256_file "$FSTAB" || RESULT=1
owner=$(stat -c %u "$FSTAB")
group=$(stat -c %g "$FSTAB")
mode=$(stat -c %a "$FSTAB")
if [ "$owner:$group" != 0:0 ] || [ "$((0$mode & 0022))" -ne 0 ]; then printf '[REVIEW] fstab owner/group should be root and group/other must not write it\n'; fi
if ! awk '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
  {sub(/[[:space:]]+#.*/, ""); display=$0; gsub(/(password|passwd|pass|secret)=[^,[:space:]]+/, "credential=<redacted>", display); print "[CONFIG] " display}
  NF<4 || NF>6 {print "[INVALID] field count at line " NR; bad=1; next}
  (NF>=5 && $5 !~ /^[0-9]+$/) || (NF>=6 && $6 !~ /^[0-9]+$/) {print "[INVALID] dump/pass number at line " NR; bad=1}
  $2 != "none" && seen[$2]++ {print "[REVIEW] duplicate target " $2}
  $3 ~ /^(nfs|nfs4|cifs|smb3|9p|fuse.sshfs|ceph|glusterfs)$/ {print "[REVIEW] configured network filesystem " $2}
  $3=="overlay" || "," $4 "," ~ /,(bind|rbind),/ {print "[REVIEW] configured overlay/bind " $2}
  "," $4 "," ~ /,(user|users|owner|suid|dev|exec),/ {print "[REVIEW] permissive/user-mount options " $2}
  END {exit bad}
' "$FSTAB"; then RESULT=1; fi
if have_cmd findmnt; then
  printf '%s\n' '--- native util-linux verification (no mounts performed) ---'
  timeout 10 findmnt --verify --verbose --tab-file "$FSTAB" >"$WORK/native" 2>&1 || RESULT=1
  sed -E 's/(password|passwd|pass|secret)=[^,[:space:]]+/credential=<redacted>/g' "$WORK/native"
else
  printf '[UNAVAILABLE] findmnt; only structural fstab checks performed\n'
fi
printf '%s\n' '--- active mounts (current namespace) ---'
awk '
  FILENAME==ARGV[1] {if ($0 !~ /^[[:space:]]*#/ && NF>=4) configured[$2]=1; next}
  {
    split($0, halves, " - "); split(halves[2], fs, " ")
    if (halves[2]=="" || NF<10) {print "[INVALID] mountinfo line " FNR; bad=1; next}
    target=$5; options=$6; type=fs[1]; source=fs[2]
    print "[MOUNT] " target " type=" type " source=" source " root=" $4 " options=" options
    candidate=(type=="overlay" || type ~ /^(nfs|nfs4|cifs|smb3|9p|fuse.sshfs|ceph|glusterfs)$/ || $4!="/")
    if (candidate && !configured[target]) print "[REVIEW] unlisted overlay/network/subtree mount " target
    if ($4!="/") print "[REVIEW] subtree root may indicate bind mount or filesystem subvolume " target
    if (target ~ /^\/(tmp|var\/tmp|dev\/shm|home)(\/|$)/) {
      if ("," options "," !~ /,nosuid,/) print "[REVIEW] writable-user area lacks nosuid " target
      if ("," options "," !~ /,nodev,/) print "[REVIEW] writable-user area lacks nodev " target
      if ("," options "," !~ /,noexec,/) print "[REVIEW] writable-user area permits execution " target
    }
  }
  END {exit bad}
' "$FSTAB" "$WORK/mountinfo" || RESULT=1
printf '%s\n' 'Review is not proof of tampering: container overlays, service bind mounts, Btrfs subvolumes and network storage may be required. Compare with a trusted baseline and scored-service dependencies before editing or unmounting.'
exit "$RESULT"

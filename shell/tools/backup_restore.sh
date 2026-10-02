#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/../lib/portable.sh"
ARCHIVE=''
OUTPUT=''
EXTRACT=0
YES=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --archive|--output) option=$1; shift; [ "$#" -gt 0 ] || die "$option requires a value"; case "$option" in --archive) ARCHIVE=$1 ;; --output) OUTPUT=$1 ;; esac ;;
    --extract) EXTRACT=1 ;;
    --yes) YES=1 ;;
    --help|-h) printf 'Usage: %s --archive FILE.tar.gz [--extract --yes --output NEW_DIR]\nDefault: checksum and path preview. Extracts regular files/directories to a new review directory only.\n' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done
[ -f "$ARCHIVE" ] && [ ! -L "$ARCHIVE" ] || die 'A regular archive is required'
have_cmd timeout && have_cmd sha256sum || die 'timeout and sha256sum are required'
if [ "${CCDC_RESTORE_RUNNING:-0}" != 1 ]; then
  export CCDC_RESTORE_RUNNING=1
  if [ "$EXTRACT" -eq 1 ]; then
    [ "$YES" -eq 1 ] && [ -n "$OUTPUT" ] || die 'Extraction requires --yes and --output NEW_DIR'
    exec timeout 300 sh "$0" --archive "$ARCHIVE" --extract --yes --output "$OUTPUT"
  fi
  exec timeout 300 sh "$0" --archive "$ARCHIVE"
fi
umask 077
WORK=$(mktemp -d) || die 'Cannot create review workspace'
trap 'rm -f "$WORK/names" "$WORK/types" "$WORK/archive.tar.gz" "$WORK/warnings" "$WORK/files" "$WORK/skipped"; rmdir "$WORK"' 0
trap 'exit 1' HUP INT TERM
ulimit -f 262144 || die 'Cannot enforce file-size limit'
[ -f "$ARCHIVE.sha256" ] || die 'Missing adjacent .sha256 manifest'
EXPECTED=$(awk 'NR==1 {print $1}' "$ARCHIVE.sha256")
case "$EXPECTED" in ''|*[!a-fA-F0-9]*) die 'Malformed SHA-256 manifest' ;; esac
[ "${#EXPECTED}" -eq 64 ] || die 'Malformed SHA-256 digest'
ARCHIVE_BYTES=$(wc -c <"$ARCHIVE")
[ "$ARCHIVE_BYTES" -le 268435456 ] || die 'Compressed archive exceeds 256 MiB review limit'
WORK_FREE=$(df -Pk "$WORK" | awk 'NR==2 {print $4}')
case "$WORK_FREE" in ''|*[!0-9]*) die 'Cannot determine temporary space' ;; esac
[ "$WORK_FREE" -gt $((ARCHIVE_BYTES / 1024 + 102400)) ] || die 'Insufficient space for a private archive copy'
cp "$ARCHIVE" "$WORK/archive.tar.gz"
ARCHIVE="$WORK/archive.tar.gz"
ACTUAL=$(sha256sum "$ARCHIVE" | awk '{print $1}')
[ "$ACTUAL" = "$EXPECTED" ] || die 'Archive checksum mismatch'
tar -tzf "$ARCHIVE" >"$WORK/names" 2>"$WORK/warnings"
[ ! -s "$WORK/warnings" ] || die 'Archive listing warned about member paths; refusing restore'
tar -tvzf "$ARCHIVE" >"$WORK/types"
if [ -n "$(LC_ALL=C sort "$WORK/names" | uniq -d)" ]; then die 'Duplicate archive paths require manual review'; fi
while IFS= read -r name; do
  case "$name" in /*|-*|*\\*|*[!A-Za-z0-9_./+@:-]*) die "Unsafe or unsupported archive path: $name" ;; esac
  case "/$name/" in */../*) die "Parent traversal in archive: $name" ;; esac
  case "$name" in */./*) die "Ambiguous archive path: $name" ;; esac
done <"$WORK/names"
awk 'NR==FNR {kind[FNR]=substr($0,1,1); next} kind[FNR]=="-" {print}' "$WORK/types" "$WORK/names" >"$WORK/files"
awk 'NR==FNR {kind[FNR]=substr($0,1,1); next} kind[FNR]!="-" && kind[FNR]!="d" {print}' "$WORK/types" "$WORK/names" >"$WORK/skipped"
if [ -s "$WORK/skipped" ]; then printf '%s\n' 'Links and special files excluded from automatic extraction:'; cat "$WORK/skipped"; fi
cat "$WORK/names"
if [ "$EXTRACT" -eq 0 ]; then log_ok 'Checksum and paths verified; preview only'; exit 0; fi
mkdir -m 700 "$OUTPUT" || die 'Output must be a new directory with an existing parent'
FREE_KB=$(df -Pk "$OUTPUT" | awk 'NR==2 {print $4}')
case "$FREE_KB" in ''|*[!0-9]*) die 'Cannot determine available space' ;; esac
TOTAL_BYTES=$(awk '{if ($3 ~ /^[0-9]+$/) n+=$3; else exit 1} END {printf "%.0f\n",n}' "$WORK/types") || die 'Unsupported tar listing format'
[ "$TOTAL_BYTES" -le 268435456 ] || die 'Expanded archive exceeds 256 MiB review limit'
[ "$FREE_KB" -gt $((TOTAL_BYTES / 1024 + 102400)) ] || die 'Insufficient extraction space plus 100 MiB reserve'
[ -s "$WORK/files" ] || die 'No regular files to extract'
tar -xzf "$ARCHIVE" -C "$OUTPUT" -T "$WORK/files" --no-same-owner --no-same-permissions
find "$OUTPUT" -type f -exec chmod 600 {} \;
find "$OUTPUT" -type d -exec chmod 700 {} \;
cp "$WORK/skipped" "$OUTPUT/RESTORE-SKIPPED-LINKS.txt"
log_ok "Extracted for review: $OUTPUT; restore selected files after comparison"

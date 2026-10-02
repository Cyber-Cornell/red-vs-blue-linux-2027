#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/../lib/portable.sh"
SOURCES=''
PROFILE=''
OUTPUT=''
MAX_MB=256
if [ "${CCDC_BACKUP_RUNNING:-0}" != 1 ]; then
  have_cmd timeout || die 'timeout is required'
  export CCDC_BACKUP_RUNNING=1
  exec timeout 300 sh "$0" "$@"
fi
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source|--profile|--output|--max-mb)
      option=$1; shift; [ "$#" -gt 0 ] || die "$option requires a value"
      case "$option" in
        --source)
          case "$1" in *'
'*|*'\'*) die 'Source names cannot contain newlines or backslashes' ;; esac
          SOURCES="$SOURCES
$1" ;;
        --profile) PROFILE=$1 ;;
        --output) OUTPUT=$1 ;;
        --max-mb) MAX_MB=$1 ;;
      esac ;;
    --help|-h)
      printf 'Usage: %s [--profile configs|critical] [--source PATH ...] --output NEW_DIR [--max-mb 256]\n' "$0"
      printf '%s\n' 'configs: /etc and /usr/local/etc. critical: configs plus /var/spool/cron, /var/spool/anacron, /root/.ssh.' 'Missing preset paths are recorded; explicit sources must exist. Paths are preserved relative to /.' 'Stop databases before copying live storage; /home and database data are never selected by a preset.'
      exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done
case "$PROFILE" in ''|configs|critical) ;; *) die 'Unknown profile; use configs or critical' ;; esac
[ -n "$OUTPUT" ] && { [ -n "$PROFILE" ] || [ -n "$SOURCES" ]; } || die 'Select --profile or --source and --output NEW_DIR'
case "$MAX_MB" in ''|*[!0-9]*) die '--max-mb must be numeric' ;; esac
[ "$MAX_MB" -ge 1 ] && [ "$MAX_MB" -le 4096 ] || die '--max-mb must be 1..4096'
have_cmd sha256sum && have_cmd gzip || die 'sha256sum and gzip are required'
umask 077
WORK=$(mktemp -d) || die 'Cannot create backup workspace'
CREATED=0
SUCCESS=0
cleanup() {
  if [ "$CREATED" -eq 1 ] && [ "$SUCCESS" -eq 0 ]; then rm -f "$OUTPUT/backup.tar.gz" "$OUTPUT/backup.tar.gz.sha256"; fi
  rm -f "$WORK/sources" "$WORK/skipped"
  rmdir "$WORK"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM
: >"$WORK/sources"
: >"$WORK/skipped"
OUTPUT_PARENT=$(CDPATH= cd -P "$(dirname "$OUTPUT")" && pwd) || die 'Output parent does not exist'
OUTPUT="$OUTPUT_PARENT/$(basename "$OUTPUT")"
add_source() {
  path=$1
  required=$2
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    if [ "$required" -eq 1 ]; then die "Source does not exist: $path"; fi
    printf 'absent\t%s\n' "$path" >>"$WORK/skipped"
    return
  fi
  case "$path" in *'
'*|*'\'*) die 'Source names cannot contain newlines or backslashes' ;; esac
  if [ -d "$path" ]; then path=$(CDPATH= cd -P "$path" && pwd); else path=$(CDPATH= cd -P "$(dirname "$path")" && pwd)/$(basename "$path"); fi
  case "$path" in /|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*) die "Unsupported source: $path" ;; esac
  case "$OUTPUT/" in "$path/"*) die 'Output cannot be inside any source' ;; esac
  relative=${path#/}
  case "$relative" in -*) die 'Source paths cannot begin with an option prefix' ;; esac
  while IFS= read -r existing; do
    case "$relative/" in "$existing/"*) printf 'covered-by-selected-source\t%s\t%s\n' "$path" "$existing" >>"$WORK/skipped"; return ;; esac
    case "$existing/" in "$relative/"*) die 'Overlapping sources: select the parent before its child' ;; esac
  done <"$WORK/sources"
  if ! grep -Fxq "$relative" "$WORK/sources"; then printf '%s\n' "$relative" >>"$WORK/sources"; fi
}
if [ -n "$PROFILE" ]; then
  for path in /etc /usr/local/etc; do add_source "$path" 0; done
fi
if [ "$PROFILE" = critical ]; then
  for path in /var/spool/cron /var/spool/anacron /root/.ssh; do add_source "$path" 0; done
fi
while IFS= read -r path; do
  [ -n "$path" ] || continue
  add_source "$path" 1
done <<EOF
$SOURCES
EOF
[ -s "$WORK/sources" ] || die 'No existing source paths'
FREE_KB=$(df -Pk "$OUTPUT_PARENT" | awk 'NR==2 {print $4}')
case "$FREE_KB" in ''|*[!0-9]*) die 'Cannot determine available space' ;; esac
[ "$FREE_KB" -gt $((MAX_MB * 1024 + 102400)) ] || die 'Insufficient space for the limit plus a 100 MiB reserve'
mkdir -m 700 "$OUTPUT" || die 'Output must be a new directory with an existing parent'
CREATED=1
ulimit -f $((MAX_MB * 2048)) || die 'Cannot enforce file-size limit'
cp "$WORK/sources" "$OUTPUT/sources.txt"
cp "$WORK/skipped" "$OUTPUT/skipped-sources.tsv"
ARCHIVE="$OUTPUT/backup.tar.gz"
tar -czf "$ARCHIVE" -C / -T "$OUTPUT/sources.txt" 2>"$OUTPUT/tar.log"
gzip -t "$ARCHIVE"
tar -tzf "$ARCHIVE" >"$OUTPUT/contents.txt"
(cd "$OUTPUT" && sha256sum backup.tar.gz >backup.tar.gz.sha256)
printf 'profile=%s\ncreated=%s\nmax_mb=%s\nreserve_kb=102400\n' "$PROFILE" "$(utc_now)" "$MAX_MB" >"$OUTPUT/metadata.txt"
SUCCESS=1
log_ok "Verified backup: $ARCHIVE"

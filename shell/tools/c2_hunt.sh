#!/bin/sh
set -u
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd) || exit 1
. "$SCRIPT_DIR/../lib/portable.sh"
PID_FILTER=''
YARA_RULES=''
STRINGS=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pid|--yara-rules)
      option=$1; shift; [ "$#" -gt 0 ] || die "$option requires a value"
      case "$option" in --pid) PID_FILTER=$1 ;; *) YARA_RULES=$1 ;; esac ;;
    --no-strings) STRINGS=0 ;;
    --help|-h)
      printf 'Usage: %s [--pid PID] [--no-strings] [--yara-rules LOCAL_FILE]\n' "$0"
      printf '%s\n' 'Read-only leads, not malware verdicts. Limits: 60 seconds total, 256 processes, 16 MiB/executable, 128 persistence files, 64 KiB/file.'
      exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done
case "$PID_FILTER" in *[!0-9]*) die '--pid must be numeric' ;; esac
[ -z "$YARA_RULES" ] || [ -f "$YARA_RULES" ] || die 'YARA rules must be an existing local file'
have_cmd timeout || die 'timeout is required for bounded collection'
if [ "${CCDC_C2_RUNNING:-0}" != 1 ]; then
  export CCDC_C2_RUNNING=1
  set --
  [ -z "$PID_FILTER" ] || set -- "$@" --pid "$PID_FILTER"
  [ -z "$YARA_RULES" ] || set -- "$@" --yara-rules "$YARA_RULES"
  [ "$STRINGS" -eq 1 ] || set -- "$@" --no-strings
  exec timeout 60 sh "$0" "$@"
fi
safe_path() { printf '%s' "$1" | tr '[:cntrl:]' '?' | cut -c 1-240; }
printf '%s\n' 'C2 review: heuristic leads only. Sliver/Spellshift Realm indicators can be absent or benign; a realm basename is not a verdict.'
printf '%s\n' 'No command lines, environment values, raw strings, or network payloads are emitted.'
have_cmd strings || { printf '%s\n' 'COVERAGE strings unavailable'; STRINGS=0; }
YARA=0
if [ -n "$YARA_RULES" ]; then
  if have_cmd yara; then YARA=1; else printf '%s\n' 'COVERAGE requested YARA unavailable'; fi
fi
COUNT=0
READABLE=0
for proc in /proc/[0-9]*; do
  [ -d "$proc" ] || continue
  pid=${proc##*/}
  [ -z "$PID_FILTER" ] || [ "$pid" = "$PID_FILTER" ] || continue
  COUNT=$((COUNT + 1))
  [ "$COUNT" -le 256 ] || { printf '%s\n' 'COVERAGE process limit reached'; break; }
  exe=$(readlink "$proc/exe" 2>/dev/null) || { printf 'COVERAGE pid=%s executable unavailable\n' "$pid"; continue; }
  READABLE=$((READABLE + 1))
  labels=''
  case "$exe" in *' (deleted)') labels="${labels}DELETED_EXE," ;; esac
  case "$exe" in /tmp/*|/var/tmp/*|/dev/shm/*|/memfd:*) labels="${labels}TEMP_OR_MEMORY_EXEC," ;; esac
  if [ -r "$proc/cmdline" ]; then
    if head -c 16384 "$proc/cmdline" 2>/dev/null | tr '\000' ' ' | grep -Eiq -- '(-enc(odedcommand)?[[:space:]]|base64[[:space:]].*(-d|--decode)|frombase64string|python[^ ]*[[:space:]]+-c.*(b64decode|exec\())'; then
      labels="${labels}ENCODED_COMMAND,"
    fi
  else
    printf 'COVERAGE pid=%s command metadata unavailable\n' "$pid"
  fi
  size=$(stat -Lc %s "$proc/exe" 2>/dev/null || printf 0)
  hash=unavailable
  if [ "$size" -gt 0 ] 2>/dev/null && [ "$size" -le 16777216 ] 2>/dev/null; then
    if have_cmd sha256sum; then
      digest=$(timeout 3 sha256sum "$proc/exe" 2>/dev/null) && hash=${digest%% *}
    fi
    if [ "$STRINGS" -eq 1 ] && timeout 3 strings -a "$proc/exe" 2>/dev/null | grep -Eiq 'github.com/[Bb]ishop[Ff]ox/sliver|spellshift/realm|realm[/:].*imix|imix[/:].*realm'; then
      labels="${labels}FRAMEWORK_STRING_LEAD,"
    fi
    if [ "$YARA" -eq 1 ] && timeout 3 yara -w "$YARA_RULES" "$proc/exe" 2>/dev/null | awk 'NR==1 {hit=1} END {exit !hit}'; then
      labels="${labels}LOCAL_YARA_LEAD,"
    fi
  else
    printf 'COVERAGE pid=%s executable outside size bound\n' "$pid"
  fi
  printf 'PROCESS pid=%s exe=%s sha256=%s leads=%s evidence=%s/exe\n' "$pid" "$(safe_path "$exe")" "$hash" "${labels:-none-observed}" "$proc"
done
printf 'COVERAGE process_entries=%s readable_executables=%s (absence of leads does not establish a clean host)\n' "$COUNT" "$READABLE"
printf '\nSOCKET SUMMARY (first 128 numeric endpoint rows; process names omitted):\n'
if have_cmd ss; then
  timeout 5 ss -H -ntua 2>/dev/null | head -n 128 || true
else
  printf '%s\n' 'COVERAGE ss unavailable; kernel endpoint tables follow'
  for table in /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6; do
    [ -r "$table" ] || continue
    printf 'evidence=%s\n' "$table"
    head -n 33 "$table" | awk 'NR>1 {printf "local=%s remote=%s state=%s uid=%s inode=%s\n",$2,$3,$4,$8,$10}'
  done
fi
printf '\nPERSISTENCE REFERENCES (labels and paths only):\n'
umask 077
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ccdc-c2.XXXXXX") || die 'Cannot allocate private path list'
trap 'rm -f "$WORK/files"; rmdir "$WORK" 2>/dev/null || true' 0
trap 'exit 1' HUP INT TERM
for dir in /etc/cron.d /etc/init.d /etc/systemd/system /var/spool/cron; do
  [ -d "$dir" ] || continue
  timeout 5 find "$dir" -xdev -type f 2>/dev/null
done | head -n 128 >"$WORK/files"
while IFS= read -r file; do
  [ -r "$file" ] || continue
  if timeout 2 head -c 65536 "$file" 2>/dev/null | grep -Eiq '(/tmp/|/var/tmp/|/dev/shm/|base64|encodedcommand|github.com/[Bb]ishop[Ff]ox/sliver|spellshift/realm)'; then
    printf 'PERSISTENCE lead=TEMP_ENCODED_OR_FRAMEWORK_REFERENCE evidence=%s\n' "$(safe_path "$file")"
  fi
done <"$WORK/files"
printf '%s\n' 'Review leads against authorized tools, service owners and independent evidence; obfuscation can defeat these checks.'
[ "$READABLE" -gt 0 ] || exit 2

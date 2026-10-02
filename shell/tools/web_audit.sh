#!/bin/sh
# Read-only web-root hunter for common server-side persistence.

set -u

SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
# shellcheck source=../lib/portable.sh
. "$SCRIPT_DIR/../lib/portable.sh"

WEB_ROOT=${CCDC_WEB_ROOT:-/var/www}
RECENT_DAYS=${CCDC_WEB_RECENT_DAYS:-14}
MAX_MATCHES=${CCDC_WEB_MAX_MATCHES:-3000}
MAX_BYTES=${CCDC_WEB_MAX_FILE_BYTES:-10485760}
MAX_SECONDS=${CCDC_WEB_TIMEOUT:-60}
MAX_OUTPUT_KB=${CCDC_WEB_MAX_OUTPUT_KB:-4096}

usage() { printf 'Usage: %s [--root DIR] [--recent-days N] [--max-matches N] [--max-file-bytes N] [--timeout N] [--max-output-kb N]\n' "$0"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) shift; [ "$#" -gt 0 ] || die '--root requires a directory'; WEB_ROOT=$1 ;;
    --root=*) WEB_ROOT=${1#*=} ;;
    --recent-days) shift; [ "$#" -gt 0 ] || die '--recent-days requires N'; RECENT_DAYS=$1 ;;
    --recent-days=*) RECENT_DAYS=${1#*=} ;;
    --max-matches) shift; [ "$#" -gt 0 ] || die '--max-matches requires N'; MAX_MATCHES=$1 ;;
    --max-matches=*) MAX_MATCHES=${1#*=} ;;
    --max-file-bytes) shift; [ "$#" -gt 0 ] || die '--max-file-bytes requires N'; MAX_BYTES=$1 ;;
    --max-file-bytes=*) MAX_BYTES=${1#*=} ;;
    --timeout) shift; [ "$#" -gt 0 ] || die '--timeout requires N'; MAX_SECONDS=$1 ;;
    --timeout=*) MAX_SECONDS=${1#*=} ;;
    --max-output-kb) shift; [ "$#" -gt 0 ] || die '--max-output-kb requires N'; MAX_OUTPUT_KB=$1 ;;
    --max-output-kb=*) MAX_OUTPUT_KB=${1#*=} ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

require_root
case "$RECENT_DAYS" in ''|*[!0-9]*) die 'recent-days must be numeric' ;; esac
[ "$RECENT_DAYS" -le 3650 ] || die 'recent-days must be 0..3650'
case "$MAX_MATCHES" in ''|*[!0-9]*) die 'max-matches must be numeric' ;; esac
[ "$MAX_MATCHES" -ge 1 ] && [ "$MAX_MATCHES" -le 20000 ] || die 'max-matches must be 1..20000'
case "$MAX_BYTES" in ''|*[!0-9]*) die 'max-file-bytes must be numeric' ;; esac
[ "$MAX_BYTES" -ge 1 ] && [ "$MAX_BYTES" -le 104857600 ] || die 'max-file-bytes must be 1..104857600'
case "$MAX_SECONDS" in ''|*[!0-9]*) die 'timeout must be numeric' ;; esac
[ "$MAX_SECONDS" -ge 1 ] && [ "$MAX_SECONDS" -le 600 ] || die 'timeout must be 1..600 seconds'
case "$MAX_OUTPUT_KB" in ''|*[!0-9]*) die 'max-output-kb must be numeric' ;; esac
[ "$MAX_OUTPUT_KB" -ge 64 ] && [ "$MAX_OUTPUT_KB" -le 16384 ] || die 'max-output-kb must be 64..16384'
[ -d "$WEB_ROOT" ] || die "Web root not found: $WEB_ROOT"
WEB_ROOT=$(CDPATH= cd -P "$WEB_ROOT" 2>/dev/null && pwd)
[ -n "$WEB_ROOT" ] || die 'Cannot resolve web root'

if [ "${CCDC_WEB_AUDIT_RUNNING:-0}" != 1 ]; then
  have_cmd timeout || die 'timeout is required for a bounded web audit'
  umask 077
  _buffer=$(mktemp "${TMPDIR:-/tmp}/ccdc-web-audit.XXXXXX") || die 'Cannot allocate private output buffer'
  trap 'rm -f "$_buffer"' 0
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  export CCDC_WEB_AUDIT_RUNNING=1
  (ulimit -f "$((MAX_OUTPUT_KB * 2))" || exit 2
   timeout -s TERM -k 5 "$MAX_SECONDS" sh "$0" \
     --root "$WEB_ROOT" --recent-days "$RECENT_DAYS" --max-matches "$MAX_MATCHES" \
     --max-file-bytes "$MAX_BYTES" --timeout "$MAX_SECONDS" --max-output-kb "$MAX_OUTPUT_KB") >"$_buffer" 2>&1
  _status=$?
  cat "$_buffer"
  rm -f "$_buffer"
  trap - 0 HUP INT TERM 2>/dev/null || true
  case "$_status" in
    124|137|143) printf '%s\n' '[WARN] Web-audit deadline reached; coverage is incomplete' >&2 ;;
    153) printf '%s\n' '[WARN] Web-audit output cap reached; coverage is incomplete' >&2 ;;
  esac
  exit "$_status"
fi

heading() { printf '\n===== %s =====\n' "$1"; }
describe() {
  _severity=$1
  _reason=$2
  _file=$3
  printf '[%s] %s: %s\n' "$_severity" "$_reason" "$_file"
  ls -ld "$_file" 2>/dev/null || true
  [ -f "$_file" ] && sha256_file "$_file" 2>/dev/null || true
}

printf 'Web root: %s\n' "$WEB_ROOT"
printf 'Collection time: %s\n' "$(utc_now)"
printf 'Content checks inspect files smaller than %s bytes; whole-run bounds are %s seconds and %s KiB.\n' "$MAX_BYTES" "$MAX_SECONDS" "$MAX_OUTPUT_KB"
printf '%s\n' 'Matched source and policy values are suppressed; output limits and exclusions mean partial coverage.'

heading 'SERVER-SIDE CODE EMBEDDED IN MEDIA'
find "$WEB_ROOT" -xdev -type f -size "-${MAX_BYTES}c" \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.ico' -o -iname '*.webp' \) -print 2>/dev/null |
  while IFS= read -r _file; do
    if LC_ALL=C grep -a -E -q '<\?(php|=)|<%@|<jsp:|Runtime\.getRuntime|System\.Diagnostics\.Process' "$_file" 2>/dev/null; then
      describe CRITICAL 'server-side code marker inside media' "$_file"
    fi
  done | head -n "$MAX_MATCHES"

heading 'SUSPICIOUS EXTENSIONS AND DOUBLE EXTENSIONS'
find "$WEB_ROOT" -xdev -type f \( \
  -iname '*.php.*' -o -iname '*.phtml' -o -iname '*.phar' -o -iname '*.php[0-9]' \
  -o -iname '*.jspx' -o -iname '*.jsp.*' -o -iname '*.aspx.*' -o -iname '*.cgi' \
  -o -iname '*.pl' -o -iname '*.py' -o -iname '*.sh' \) -print 2>/dev/null | head -n "$MAX_MATCHES" |
  while IFS= read -r _file; do describe REVIEW 'unusual executable web extension' "$_file"; done

heading 'OBFUSCATION, COMMAND EXECUTION, AND DYNAMIC LOADING'
find "$WEB_ROOT" -xdev \( -type d \( -name .git -o -name node_modules -o -name vendor -o -name cache \) -prune \) -o \( -type f -size "-${MAX_BYTES}c" ! -name '*.min.js' -print \) 2>/dev/null |
  while IFS= read -r _file; do
    if grep -a -E -q \
      '(base64_decode[[:space:]]*\(|gzinflate[[:space:]]*\(|gzuncompress[[:space:]]*\(|str_rot13[[:space:]]*\(|eval[[:space:]]*\(|assert[[:space:]]*\(|shell_exec[[:space:]]*\(|passthru[[:space:]]*\(|proc_open[[:space:]]*\(|popen[[:space:]]*\(|pcntl_exec[[:space:]]*\(|Runtime\.getRuntime[[:space:]]*\(|ProcessBuilder[[:space:]]*\(|System\.Diagnostics\.Process|fromCharCode[[:space:]]*\()' \
      "$_file" 2>/dev/null; then
      describe REVIEW 'obfuscation, command execution, or dynamic-loading marker (values suppressed)' "$_file"
    fi
  done | head -n "$MAX_MATCHES"

heading 'VERY LONG SERVER-SIDE SOURCE LINES'
find "$WEB_ROOT" -xdev -type f -size "-${MAX_BYTES}c" \( -iname '*.php' -o -iname '*.phtml' -o -iname '*.jsp' -o -iname '*.jspx' -o -iname '*.asp' -o -iname '*.aspx' \) -print 2>/dev/null |
  while IFS= read -r _file; do
    awk 'length($0) > 2000 {print FILENAME ":" NR ": line length=" length($0); exit}' "$_file" 2>/dev/null
  done | head -n "$MAX_MATCHES"

heading 'EXECUTABLE CONTENT IN UPLOAD/MEDIA DIRECTORIES'
find "$WEB_ROOT" -xdev -type d \( -iname 'upload*' -o -iname 'media' -o -iname 'images' -o -iname 'files' -o -path '*/wp-content/uploads' \) -print 2>/dev/null |
  while IFS= read -r _upload; do
    find "$_upload" -xdev -type f \( -iname '*.php' -o -iname '*.phtml' -o -iname '*.phar' -o -iname '*.jsp' -o -iname '*.aspx' -o -iname '*.cgi' -o -perm -001 -o -perm -010 -o -perm -100 \) -print 2>/dev/null
  done | head -n "$MAX_MATCHES"

heading 'WORLD-WRITABLE WEB CONTENT'
find "$WEB_ROOT" -xdev \( -type f -o -type d \) -perm -0002 -exec ls -ld {} \; 2>/dev/null | head -n "$MAX_MATCHES"

heading 'HANDLER AND ACCESS OVERRIDES'
find "$WEB_ROOT" -xdev -type f \( -name '.htaccess' -o -name '.user.ini' -o -name 'web.config' \) -print 2>/dev/null |
  while IFS= read -r _override; do
    if grep -a -E -i -q 'AddHandler|SetHandler|auto_prepend_file|auto_append_file|RewriteRule|exec|shell|cmd' "$_override" 2>/dev/null; then
      describe REVIEW 'handler or access override marker (values suppressed)' "$_override"
    fi
  done | head -n "$MAX_MATCHES"

heading 'SYMLINKS LEAVING THE WEB ROOT'
find "$WEB_ROOT" -xdev -type l -print 2>/dev/null | while IFS= read -r _link; do
  _target=$(readlink -f "$_link" 2>/dev/null || true)
  case "$_target" in "$WEB_ROOT"/*) ;; *) printf '[REVIEW] %s -> %s\n' "$_link" "${_target:-broken}" ;; esac
done | head -n "$MAX_MATCHES"

heading "FILES CHANGED IN THE LAST $RECENT_DAYS DAYS"
find "$WEB_ROOT" -xdev -type f -mtime "-$RECENT_DAYS" -exec ls -ld {} \; 2>/dev/null |
  LC_ALL=C sort | head -n "$MAX_MATCHES"

heading 'CMS INTEGRITY COMMANDS AVAILABLE'
if have_cmd wp && find "$WEB_ROOT" -xdev -name wp-config.php -type f -print -quit 2>/dev/null | grep -q .; then
  printf '%s\n' '[INFO] WP-CLI detected. From each reviewed WordPress root, run as the site owner:'
  printf '%s\n' '  wp core verify-checksums'
  printf '%s\n' '  wp plugin verify-checksums --all'
fi

printf '\n%s\n' '[INFO] Heuristics intentionally favor review. Hash, inspect context, compare package/CMS provenance, and preserve evidence before quarantine.'

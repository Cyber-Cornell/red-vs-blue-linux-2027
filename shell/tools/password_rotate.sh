#!/bin/sh
set -u
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd) || exit 1
. "$SCRIPT_DIR/../lib/portable.sh"
COMMAND=${1:-help}
[ "$#" -eq 0 ] || shift
MODE=plan
YES=0
TARGET=''
KIND=''
OUTPUT=''
WORK=''
cleanup() { [ -z "$WORK" ] || rm -rf "$WORK"; }
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
generate_password() {
  _random=$(od -An -N24 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  [ "${#_random}" -eq 48 ] || return 1
  printf 'Aa1!%s\n' "$_random"
}
usage() {
  printf 'Usage: %s generate\n' "$0"
  printf '       %s rotate --user NAME|--group NAME [--plan]\n' "$0"
  printf '       %s rotate --user NAME|--group NAME --apply --yes --output /private/new-file\n' "$0"
  printf '%s\n' 'Local accounts only. Group selection includes primary and supplementary members.'
  printf '%s\n' 'Root, current operator, locked/non-login and configured service accounts are protected.'
  printf '%s\n' 'Output parent must be root-owned mode 700. Credentials are PENDING until a SUCCESS result.'
}
case "$COMMAND" in
  generate) [ "$#" -eq 0 ] || die 'generate takes no options'; generate_password || die 'CSPRNG unavailable'; exit 0 ;;
  rotate) ;;
  help|--help|-h) usage; exit 0 ;;
  *) usage >&2; exit 1 ;;
esac
while [ "$#" -gt 0 ]; do
  case "$1" in
    --user|--group)
      [ -z "$KIND" ] || die 'Select exactly one user or group'
      KIND=${1#--}
      shift; [ "$#" -gt 0 ] || die 'Missing user/group name'; TARGET=$1 ;;
    --plan) MODE=plan ;;
    --apply) MODE=apply ;;
    --yes) YES=1 ;;
    --output) shift; [ "$#" -gt 0 ] || die 'Missing output path'; OUTPUT=$1 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done
case "$TARGET" in ''|[-0-9]*|*[!A-Za-z0-9_.-]*) die 'Invalid or missing account/group name' ;; esac
umask 077
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ccdc-rotate.XXXXXX") || die 'Cannot create private work directory'
if [ "$KIND" = user ]; then
  awk -F: -v u="$TARGET" '$1==u {print $1}' /etc/passwd >"$WORK/users"
else
  GROUP=$(awk -F: -v g="$TARGET" '$1==g {print; exit}' /etc/group)
  [ -n "$GROUP" ] || die 'Local group does not exist'
  GID=$(printf '%s\n' "$GROUP" | cut -d: -f3)
  MEMBERS=$(printf '%s\n' "$GROUP" | cut -d: -f4)
  awk -F: -v gid="$GID" -v members="$MEMBERS" 'BEGIN {n=split(members,a,","); for(i=1;i<=n;i++) member[a[i]]=1} $4==gid || member[$1] {print $1}' /etc/passwd >"$WORK/users"
fi
LC_ALL=C sort -u "$WORK/users" -o "$WORK/users"
[ -s "$WORK/users" ] || die 'No local accounts selected'
SERVICES="$SCRIPT_DIR/../configs/services.txt"
[ -r "$SERVICES" ] || die 'Service-account protection list is missing'
sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//' "$SERVICES" >"$WORK/services"
PROBLEMS=0
while IFS= read -r account; do
  RECORD=$(awk -F: -v u="$account" '$1==u {print; exit}' /etc/passwd)
  UID_VALUE=$(printf '%s\n' "$RECORD" | cut -d: -f3)
  LOGIN_SHELL=$(printf '%s\n' "$RECORD" | cut -d: -f7)
  PROTECTED=0
  [ "$UID_VALUE" != 0 ] || PROTECTED=1
  [ "$account" != "${SUDO_USER:-}" ] && [ "$account" != "${LOGNAME:-}" ] || PROTECTED=1
  case "$LOGIN_SHELL" in ''|*/false|*/nologin|*/sync|*/shutdown|*/halt) PROTECTED=1 ;; esac
  grep -F -x "$account" "$WORK/services" >/dev/null 2>&1 && PROTECTED=1
  if [ -r /etc/shadow ]; then
    HASH=$(awk -F: -v u="$account" '$1==u {print $2; exit}' /etc/shadow)
    case "$HASH" in ''|'!'*|'*'*) PROTECTED=1 ;; esac
  fi
  if [ "$PROTECTED" -eq 1 ]; then
    log_error "Protected account selected: $account"
    PROBLEMS=$((PROBLEMS + 1))
  else
    printf 'Selected account: %s\n' "$account"
  fi
done <"$WORK/users"
[ "$PROBLEMS" -eq 0 ] || die 'Selection contains protected accounts; no passwords changed'
[ "$MODE" = apply ] || exit 0
[ "$YES" -eq 1 ] || die 'Apply requires --yes'
require_root
[ "$(uname -s)" = Linux ] || die 'Password rotation supports Linux only'
have_cmd chpasswd || die 'chpasswd is unavailable'
case "$OUTPUT" in /*) ;; *) die 'An absolute new --output file is required' ;; esac
PARENT=$(CDPATH= cd -P "$(dirname "$OUTPUT")" && pwd) || die 'Output parent must exist'
[ "$PARENT/$(basename "$OUTPUT")" = "$OUTPUT" ] || die 'Output path must be canonical'
[ "$(stat -c '%u:%a' "$PARENT")" = 0:700 ] || die 'Output parent must be root-owned mode 700'
[ ! -e "$OUTPUT" ] && [ ! -L "$OUTPUT" ] || die 'Output file already exists'
set -C
exec 3>"$OUTPUT" || die 'Cannot exclusively create output file'
set +C
printf 'record\tuser\tvalue\n' >&3 || die 'Cannot write output artifact'
FAILURES=0
SUCCESSES=0
while IFS= read -r account; do
  PASSWORD=$(generate_password) || die 'CSPRNG failed; inspect retained results'
  printf 'PENDING\t%s\t%s\n' "$account" "$PASSWORD" >&3 || die 'Artifact write failed before password change'
  if printf '%s:%s\n' "$account" "$PASSWORD" | chpasswd >/dev/null 2>&1; then
    printf 'RESULT\t%s\tSUCCESS\n' "$account" >&3 || die 'Password changed but result write failed; inspect pending credential'
    SUCCESSES=$((SUCCESSES + 1))
    log_ok "Password rotated: $account"
  else
    printf 'RESULT\t%s\tFAIL\n' "$account" >&3 || die 'Failed to record chpasswd failure'
    FAILURES=$((FAILURES + 1))
    log_error "Password rotation failed: $account"
  fi
  unset PASSWORD
done <"$WORK/users"
exec 3>&-
printf 'Rotation results: success=%s fail=%s; private artifact: %s\n' "$SUCCESSES" "$FAILURES" "$OUTPUT"
[ "$FAILURES" -eq 0 ]

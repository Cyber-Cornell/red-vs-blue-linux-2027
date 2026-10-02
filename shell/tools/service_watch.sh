#!/bin/sh
# Local scored-service health checks with machine-readable output.

set -u

SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
# shellcheck source=../lib/portable.sh
. "$SCRIPT_DIR/../lib/portable.sh"

CONFIG="$SCRIPT_DIR/../configs/scored_services.conf"
INTERVAL=0
OUTPUT=''

usage() {
  cat <<EOF
Usage: $0 [--config FILE] [--output FILE] [--watch SECONDS]

Without --watch, checks each configured service once. Output columns are:
timestamp, service, status, detail.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --config) shift; [ "$#" -gt 0 ] || die '--config requires a file'; CONFIG=$1 ;;
    --config=*) CONFIG=${1#*=} ;;
    --output) shift; [ "$#" -gt 0 ] || die '--output requires a file'; OUTPUT=$1 ;;
    --output=*) OUTPUT=${1#*=} ;;
    --watch) shift; [ "$#" -gt 0 ] || die '--watch requires seconds'; INTERVAL=$1 ;;
    --watch=*) INTERVAL=${1#*=} ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

case "$INTERVAL" in ''|*[!0-9]*) die '--watch must be a nonnegative integer' ;; esac
[ -f "$CONFIG" ] || die "Configuration not found: $CONFIG"
if [ -n "$OUTPUT" ]; then
  umask 077
  mkdir -p "$(dirname "$OUTPUT")" || die "Cannot create output directory"
  [ ! -L "$OUTPUT" ] || die 'Output must not be a symbolic link'
  if [ ! -s "$OUTPUT" ]; then
    printf 'timestamp_utc\tservice\tstatus\tdetail\n' >>"$OUTPUT" || die 'Cannot write output'
  fi
fi

emit() {
  _line=$(printf '%s\t%s\t%s\t%s' "$(utc_now)" "$1" "$2" "$3" | tr '\r\n' '  ')
  printf '%s\n' "$_line"
  if [ -n "$OUTPUT" ]; then
    printf '%s\n' "$_line" >>"$OUTPUT" || die 'Cannot append output'
  fi
}

valid_name() {
  case "$1" in ''|-*|*[!A-Za-z0-9_.-]*) return 1 ;; esac
}

check_tcp() {
  _target=$1
  _host=${_target%:*}
  _port=${_target##*:}
  [ -n "$_host" ] && [ -n "$_port" ] && [ "$_host" != "$_target" ] || return 2
  case "$_port" in *[!0-9]*) return 2 ;; esac
  case "$_host" in -*|*' '*|*'\t'*) return 2 ;; esac
  [ "${#_port}" -le 5 ] && [ "$_port" -ge 1 ] && [ "$_port" -le 65535 ] || return 2
  if have_cmd nc; then
    nc -z -w 3 "$_host" "$_port" >/dev/null 2>&1
  elif have_cmd bash && have_cmd timeout; then
    CCDC_CHECK_HOST=$_host CCDC_CHECK_PORT=$_port timeout 4 bash -c \
      'exec 3<>"/dev/tcp/$CCDC_CHECK_HOST/$CCDC_CHECK_PORT"' >/dev/null 2>&1
  else
    return 3
  fi
}

check_one() {
  _name=$1
  _type=$2
  _target=$3
  _expected=$4
  case "$_type" in
    tcp)
      if check_tcp "$_target"; then
        emit "$_name" PASS "tcp $_target accepted a connection"; return 0
      else
        _rc=$?
      fi
      [ "$_rc" -eq 2 ] && { emit "$_name" INVALID 'TCP target must be host:port (1-65535)'; return 1; }
      [ "$_rc" -eq 3 ] && { emit "$_name" UNKNOWN 'nc or bash+timeout is required'; return 1; }
      emit "$_name" FAIL "tcp $_target did not accept a connection"
      return 1
      ;;
    http)
      if ! have_cmd curl; then emit "$_name" UNKNOWN 'curl is required'; return 1; fi
      [ -n "$_expected" ] || _expected=200
      case "$_target" in http://*|https://*) ;; *) emit "$_name" INVALID 'HTTP target must use http:// or https://'; return 1 ;; esac
      case "$_expected" in [1-5][0-9][0-9]) ;; *) emit "$_name" INVALID 'expected HTTP status must be 100-599'; return 1 ;; esac
      if ! _code=$(curl --silent --show-error --output /dev/null --max-time 5 --write-out '%{http_code}' -- "$_target" 2>/dev/null); then
        emit "$_name" FAIL "HTTP request failed for $_target"; return 1
      fi
      if [ "$_code" = "$_expected" ]; then emit "$_name" PASS "http status $_code from $_target"; return 0; fi
      emit "$_name" FAIL "expected HTTP $_expected, got $_code from $_target"
      return 1
      ;;
    dns)
      if ! have_cmd dig; then emit "$_name" UNKNOWN 'dig is required'; return 1; fi
      _server=${_target%%:*}
      _query=${_target#*:}
      [ -n "$_server" ] && [ -n "$_query" ] && [ "$_server" != "$_target" ] || { emit "$_name" INVALID "bad dns target $_target"; return 1; }
      case "$_query" in -*|+*|@*) emit "$_name" INVALID 'invalid DNS query name'; return 1 ;; esac
      if ! _answer=$(dig +time=3 +tries=1 +short "@$_server" "$_query" 2>/dev/null); then
        emit "$_name" FAIL "DNS request failed for $_query"; return 1
      fi
      if [ -n "$_answer" ]; then
        if [ -z "$_expected" ] || [ "$_expected" = nonempty ] || printf '%s\n' "$_answer" | grep -F -x -- "$_expected" >/dev/null; then
          emit "$_name" PASS "dns $_query via $_server returned an expected answer"; return 0
        fi
        emit "$_name" FAIL "dns answer did not match $_expected"; return 1
      fi
      emit "$_name" FAIL "dns $_query via $_server returned no answer"
      return 1
      ;;
    openrc)
      valid_name "$_target" || { emit "$_name" INVALID 'invalid OpenRC service'; return 1; }
      if ! have_cmd rc-service; then emit "$_name" UNKNOWN 'rc-service is required'; return 1; fi
      case "$_expected" in ''|started) ;; *) emit "$_name" INVALID 'OpenRC expected state must be started'; return 1 ;; esac
      if rc-service "$_target" status >/dev/null 2>&1; then emit "$_name" PASS "$_target is started"; return 0; fi
      emit "$_name" FAIL "$_target is stopped, missing or status unavailable"
      return 1
      ;;
    systemd)
      valid_name "$_target" || { emit "$_name" INVALID 'invalid systemd unit'; return 1; }
      if ! have_cmd systemctl; then emit "$_name" UNKNOWN 'systemctl is required'; return 1; fi
      _state=$(systemctl is-active -- "$_target" 2>/dev/null || true)
      if [ "$_state" = "${_expected:-active}" ]; then emit "$_name" PASS "$_target is $_state"; return 0; fi
      emit "$_name" FAIL "$_target is ${_state:-unknown}"
      return 1
      ;;
    *) emit "$_name" INVALID "unknown type $_type"; return 1 ;;
  esac
}

run_checks() {
  _configured=0
  _failed=0
  while IFS='|' read -r _name _type _target _expected _extra || [ -n "${_name:-}" ]; do
    _name=$(printf '%s' "${_name:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case "$_name" in ''|'#'*) continue ;; esac
    _type=$(printf '%s' "${_type:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    _target=$(printf '%s' "${_target:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    _expected=$(printf '%s' "${_expected:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    valid_name "$_name" || { emit invalid INVALID 'service name contains unsupported characters'; _failed=$((_failed + 1)); continue; }
    [ -z "${_extra:-}" ] || { emit "$_name" INVALID 'too many fields'; _failed=$((_failed + 1)); continue; }
    _configured=$((_configured + 1))
    check_one "$_name" "$_type" "$_target" "$_expected" || _failed=$((_failed + 1))
  done <"$CONFIG"
  if [ "$_configured" -eq 0 ]; then
    log_warn "No scored services configured in $CONFIG"
    emit configuration UNKNOWN 'no valid service checks configured'
    return 1
  fi
  [ "$_failed" -eq 0 ]
}

if [ "$INTERVAL" -eq 0 ]; then
  run_checks
  exit $?
fi

while :; do
  run_checks || true
  sleep "$INTERVAL"
done

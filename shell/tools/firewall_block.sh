#!/bin/sh
set -u
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd) || exit 1
. "$SCRIPT_DIR/../lib/portable.sh"
case "${0##*/}" in firewall_unblock.sh) ACTION=unblock ;; *) ACTION=block ;; esac
MODE=plan
YES=0
ADDRESS=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --plan) MODE=plan ;;
    --apply) MODE=apply ;;
    --yes) YES=1 ;;
    --address) shift; [ "$#" -gt 0 ] || die '--address requires an IPv4 address'; ADDRESS=$1 ;;
    --help|-h)
      printf 'Usage: %s [--plan | --apply --yes] --address IPv4\n' "$0"
      printf '%s\n' 'Runtime-only, exact IPv4 INPUT rule tagged CCDC-OPERATOR-BLOCK; no persistence files are changed.'
      exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done
case "$ADDRESS" in ''|*[!0-9.]*) die 'Expected one canonical IPv4 address' ;; esac
printf '%s\n' "$ADDRESS" | awk -F. '
  NF!=4 {exit 1}
  {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || length($i)>3 || $i>255 || (length($i)>1 && substr($i,1,1)=="0")) exit 1}
' || die 'Expected one canonical IPv4 address (no hostname, CIDR or range)'
[ -n "$ADDRESS" ] || die 'Missing address'
if [ "$ACTION" = block ]; then
  case "$ADDRESS" in 0.*|127.*|255.255.255.255) die 'Refusing unspecified, loopback or broadcast address' ;; esac
  SSH_CLIENT_ADDRESS=${SSH_CONNECTION:-}
  SSH_CLIENT_ADDRESS=${SSH_CLIENT_ADDRESS%% *}
  [ "$ADDRESS" != "$SSH_CLIENT_ADDRESS" ] || die 'Refusing the current SSH client address'
fi
printf 'Plan: %s inbound IPv4 source %s using only the CCDC-OPERATOR-BLOCK tagged rule; runtime-only\n' "$ACTION" "$ADDRESS"
[ "$MODE" = apply ] || exit 0
[ "$YES" -eq 1 ] || die 'Apply requires --yes'
require_root
[ "$(uname -s)" = Linux ] || die 'Firewall helpers support Linux only'
have_cmd iptables || die 'iptables is unavailable'
iptables -w 5 -S INPUT >/dev/null || die 'Cannot inspect INPUT chain'
PRESENT=0
iptables -w 5 -C INPUT -s "$ADDRESS" -m comment --comment CCDC-OPERATOR-BLOCK -j DROP >/dev/null 2>&1 || PRESENT=$?
case "$PRESENT" in 0|1) ;; *) die 'Cannot check scoped firewall rule' ;; esac
case "$ACTION:$PRESENT" in
  block:0) log_info 'Tagged rule already exists' ;;
  block:1) iptables -w 5 -I INPUT 1 -s "$ADDRESS" -m comment --comment CCDC-OPERATOR-BLOCK -j DROP || die 'Block failed' ;;
  unblock:0) iptables -w 5 -D INPUT -s "$ADDRESS" -m comment --comment CCDC-OPERATOR-BLOCK -j DROP || die 'Unblock failed' ;;
  unblock:1) log_info 'No tagged rule exists; unrelated rules are unchanged' ;;
esac
log_ok "$ACTION completed; runtime-only"

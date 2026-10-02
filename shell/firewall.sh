#!/bin/sh
# Competition-safe inbound firewall allowlist.
# The script owns only an nftables table or dedicated iptables chains and never
# flushes distribution, Docker, Kubernetes, or service-managed rules.

set -u

SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
# shellcheck source=lib/portable.sh
. "$SCRIPT_DIR/lib/portable.sh"

MODE=audit
YES=0
BACKEND=auto
TCP_RAW=${CCDC_TCP_PORTS:-}
UDP_RAW=${CCDC_UDP_PORTS:-}
TCP_PORTS=''
UDP_PORTS=''
WORK_DIR=''

usage() {
  cat <<EOF
Usage:
  $0 --audit
  $0 --plan --tcp-ports LIST [--udp-ports LIST]
  $0 --apply --yes --tcp-ports LIST [--udp-ports LIST] [--backend auto|nft|iptables]

LIST is comma-separated and may include ranges: 22,53,80,443,8000-8100.
Rules are runtime-only so a reboot returns to the host's existing persistent
policy. Re-run after reboot only after checking scored-service requirements.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --audit) MODE=audit ;;
    --plan) MODE=plan ;;
    --apply) MODE=apply ;;
    --yes) YES=1 ;;
    --backend)
      shift
      [ "$#" -gt 0 ] || die '--backend requires auto, nft, or iptables'
      BACKEND=$1
      ;;
    --backend=*) BACKEND=${1#*=} ;;
    --tcp-ports)
      shift
      [ "$#" -gt 0 ] || die '--tcp-ports requires a list'
      TCP_RAW=$1
      ;;
    --tcp-ports=*) TCP_RAW=${1#*=} ;;
    --udp-ports)
      shift
      [ "$#" -gt 0 ] || die '--udp-ports requires a list'
      UDP_RAW=$1
      ;;
    --udp-ports=*) UDP_RAW=${1#*=} ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

case "$BACKEND" in auto|nft|iptables) ;; *) die "Invalid backend: $BACKEND" ;; esac

cleanup() {
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    rm -f "$WORK_DIR"/* 2>/dev/null || true
    rmdir "$WORK_DIR" 2>/dev/null || true
  fi
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

normalize_ports() {
  _raw=$1
  _label=$2
  _result=''
  _old_ifs=$IFS
  IFS=', '
  set -f
  # Intentional field splitting of a validated operator list.
  # shellcheck disable=SC2086
  set -- $_raw
  set +f
  IFS=$_old_ifs
  for _spec in "$@"; do
    [ -n "$_spec" ] || continue
    case "$_spec" in
      *-*)
        _start=${_spec%%-*}
        _end=${_spec#*-}
        case "$_start:$_end" in
          *[!0-9:]*|:*) die "Invalid $_label port range: $_spec" ;;
        esac
        [ -n "$_end" ] || die "Invalid $_label port range: $_spec"
        [ "$_start" -ge 1 ] 2>/dev/null && [ "$_end" -le 65535 ] 2>/dev/null && [ "$_start" -le "$_end" ] 2>/dev/null ||
          die "Invalid $_label port range: $_spec"
        ;;
      *)
        case "$_spec" in *[!0-9]*) die "Invalid $_label port: $_spec" ;; esac
        [ "$_spec" -ge 1 ] 2>/dev/null && [ "$_spec" -le 65535 ] 2>/dev/null ||
          die "Invalid $_label port: $_spec"
        ;;
    esac
    case " $_result " in *" $_spec "*) ;; *) _result="${_result}${_result:+ }$_spec" ;; esac
  done
  printf '%s\n' "$_result"
}

port_list_contains() {
  _needle=$1
  shift
  for _spec in "$@"; do
    case "$_spec" in
      *-*)
        _start=${_spec%%-*}
        _end=${_spec#*-}
        [ "$_needle" -ge "$_start" ] 2>/dev/null && [ "$_needle" -le "$_end" ] 2>/dev/null && return 0
        ;;
      *) [ "$_needle" = "$_spec" ] && return 0 ;;
    esac
  done
  return 1
}

choose_backend() {
  if [ "$BACKEND" = auto ]; then
    if have_cmd nft && nft list ruleset >/dev/null 2>&1; then
      BACKEND=nft
    elif have_cmd iptables && have_cmd iptables-save; then
      BACKEND=iptables
    else
      die 'Neither a working nftables nor iptables backend was found'
    fi
  fi
  case "$BACKEND" in
    nft) have_cmd nft || die 'nft command not found' ;;
    iptables) have_cmd iptables && have_cmd iptables-save && have_cmd iptables-restore || die 'iptables tools not found' ;;
  esac
}

audit_firewall() {
  log_info 'Listening sockets'
  ss -H -lntup 2>/dev/null || netstat -lntup 2>/dev/null || true
  if have_cmd nft; then
    log_info 'nftables ruleset'
    nft -s list ruleset 2>/dev/null || true
  fi
  if have_cmd iptables-save; then
    log_info 'iptables IPv4 ruleset'
    iptables-save 2>/dev/null || true
  fi
  if have_cmd ip6tables-save; then
    log_info 'iptables IPv6 ruleset'
    ip6tables-save 2>/dev/null || true
  fi
}

TCP_PORTS=$(normalize_ports "$TCP_RAW" TCP) || exit 1
UDP_PORTS=$(normalize_ports "$UDP_RAW" UDP) || exit 1

if [ "$MODE" = audit ]; then
  require_root
  [ "$(uname -s 2>/dev/null)" = Linux ] || die 'This firewall workflow supports Linux only'
  audit_firewall
  exit 0
fi

[ -n "$TCP_PORTS$UDP_PORTS" ] || die 'At least one TCP or UDP scored-service port is required'

if [ -n "${SSH_CONNECTION:-}" ]; then
  _old_ifs=$IFS
  IFS=' '
  # SSH_CONNECTION: client-address client-port server-address server-port
  # shellcheck disable=SC2086
  set -- $SSH_CONNECTION
  IFS=$_old_ifs
  _ssh_port=${4:-}
  if [ -n "$_ssh_port" ]; then
    # Intentional splitting of normalized numeric port specs.
    # shellcheck disable=SC2086
    port_list_contains "$_ssh_port" $TCP_PORTS ||
      die "Active SSH uses TCP $_ssh_port, which is absent from --tcp-ports"
  fi
fi

printf 'Backend: %s\n' "$BACKEND"
printf 'Allowed inbound TCP: %s\n' "${TCP_PORTS:-none}"
printf 'Allowed inbound UDP: %s\n' "${UDP_PORTS:-none}"
printf '%s\n' 'Always allowed: loopback, established/related traffic, essential ICMP, DHCP client replies'
printf '%s\n' 'All other new inbound traffic: logged at a limited rate, then dropped'

[ "$MODE" = apply ] || exit 0
[ "$YES" -eq 1 ] || die 'Apply requires --yes'
require_root
[ "$(uname -s 2>/dev/null)" = Linux ] || die 'This firewall workflow supports Linux only'
choose_backend

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ccdc-firewall.XXXXXX") || die 'Cannot create temporary directory'
STAMP=$(date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null || date '+%Y%m%d_%H%M%S')
umask 077
ROLLBACK_DIR=$(mktemp -d "/var/backups/ccdc-firewall-$STAMP.XXXXXX") || die 'Cannot create firewall backup directory'
chmod 700 "$ROLLBACK_DIR"

apply_nft() {
  nft -s list ruleset >"$ROLLBACK_DIR/nft-full.rules" || return 1
  if nft list table inet ccdc >/dev/null 2>&1; then
    nft -s list table inet ccdc >"$ROLLBACK_DIR/nft-previous-ccdc.rules" || return 1
    printf '%s\n' yes >"$ROLLBACK_DIR/had-ccdc-table"
  else
    printf '%s\n' no >"$ROLLBACK_DIR/had-ccdc-table"
  fi

  _rules="$WORK_DIR/ccdc.nft"
  {
    if [ "$(cat "$ROLLBACK_DIR/had-ccdc-table")" = yes ]; then
      printf '%s\n' 'delete table inet ccdc'
    fi
    printf '%s\n' 'table inet ccdc {'
    printf '%s\n' '  chain input {'
    printf '%s\n' '    type filter hook input priority -10; policy drop;'
    printf '%s\n' '    iifname "lo" accept'
    printf '%s\n' '    ct state established,related accept'
    printf '%s\n' '    ct state invalid drop'
    printf '%s\n' '    ip protocol icmp accept'
    printf '%s\n' '    meta l4proto ipv6-icmp accept'
    printf '%s\n' '    udp sport 67 udp dport 68 accept'
    printf '%s\n' '    udp sport 547 udp dport 546 accept'
    for _port in $TCP_PORTS; do
      printf '    tcp dport %s ct state new accept\n' "$_port"
    done
    for _port in $UDP_PORTS; do
      printf '    udp dport %s accept\n' "$_port"
    done
    printf '%s\n' '    limit rate 5/second burst 10 packets log prefix "CCDC-DROP " level warning'
    printf '%s\n' '    drop'
    printf '%s\n' '  }'
    printf '%s\n' '}'
  } >"$_rules"

  nft -c -f "$_rules" || die 'Generated nftables policy failed validation'
  if ! nft -f "$_rules"; then
    log_error 'Atomic nftables transaction failed; previous policy remains installed'
    return 1
  fi
  nft list table inet ccdc >"$ROLLBACK_DIR/nft-applied.rules"
}

iptables_add_ports() {
  _binary=$1
  _chain=$2
  _protocol=$3
  _ports=$4
  for _port in $_ports; do
    _iptables_port=$(printf '%s' "$_port" | tr '-' ':')
    "$_binary" -A "$_chain" -p "$_protocol" --dport "$_iptables_port" -m conntrack --ctstate NEW -j ACCEPT || return 1
  done
}

build_iptables_chain() {
  _binary=$1
  _chain=$2
  "$_binary" -N "$_chain" 2>/dev/null || "$_binary" -L "$_chain" >/dev/null 2>&1 || return 1
  "$_binary" -F "$_chain" || return 1
  "$_binary" -A "$_chain" -i lo -j ACCEPT || return 1
  "$_binary" -A "$_chain" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || return 1
  "$_binary" -A "$_chain" -m conntrack --ctstate INVALID -j DROP || return 1
  if [ "$_binary" = ip6tables ]; then
    "$_binary" -A "$_chain" -p ipv6-icmp -j ACCEPT || return 1
    "$_binary" -A "$_chain" -p udp --sport 547 --dport 546 -j ACCEPT || return 1
  else
    "$_binary" -A "$_chain" -p icmp -j ACCEPT || return 1
    "$_binary" -A "$_chain" -p udp --sport 67 --dport 68 -j ACCEPT || return 1
  fi
  iptables_add_ports "$_binary" "$_chain" tcp "$TCP_PORTS" || return 1
  iptables_add_ports "$_binary" "$_chain" udp "$UDP_PORTS" || return 1
  "$_binary" -A "$_chain" -m limit --limit 5/second --limit-burst 10 -j LOG --log-prefix 'CCDC-DROP ' --log-level 4 || return 1
  "$_binary" -A "$_chain" -j DROP || return 1
  "$_binary" -C INPUT -j "$_chain" 2>/dev/null || "$_binary" -I INPUT 1 -j "$_chain"
}

apply_iptables() {
  iptables-save >"$ROLLBACK_DIR/iptables.v4" || return 1
  if have_cmd ip6tables; then
    have_cmd ip6tables-save && have_cmd ip6tables-restore || return 1
    ip6tables-save >"$ROLLBACK_DIR/iptables.v6" || return 1
  fi
  if ! build_iptables_chain iptables CCDC_INPUT; then
    log_error 'IPv4 apply failed; restoring the previous ruleset'
    iptables-restore <"$ROLLBACK_DIR/iptables.v4" 2>/dev/null || true
    return 1
  fi
  if have_cmd ip6tables && have_cmd ip6tables-save; then
    if ! build_iptables_chain ip6tables CCDC_INPUT; then
      log_error 'IPv6 apply failed; restoring both previous rulesets'
      iptables-restore <"$ROLLBACK_DIR/iptables.v4" 2>/dev/null || true
      have_cmd ip6tables-restore && ip6tables-restore <"$ROLLBACK_DIR/iptables.v6" 2>/dev/null || true
      return 1
    fi
  else
    log_warn 'ip6tables is unavailable; verify IPv6 exposure separately'
  fi
  iptables-save >"$ROLLBACK_DIR/iptables-applied.v4"
}

case "$BACKEND" in
  nft) apply_nft || die 'Firewall apply failed; inspect rollback material' ;;
  iptables) apply_iptables || die 'Firewall apply failed; inspect rollback material' ;;
esac

cat >"$ROLLBACK_DIR/README.txt" <<EOF
Firewall rollback captured before the CCDC allowlist was applied.

nftables full restore (replaces the entire active ruleset):
  nft flush ruleset
  nft -f $ROLLBACK_DIR/nft-full.rules

iptables restore:
  iptables-restore < $ROLLBACK_DIR/iptables.v4
  ip6tables-restore < $ROLLBACK_DIR/iptables.v6

Use the commands that match the backend recorded by this run. Console access is
recommended before restoring or changing firewall policy.
EOF
chmod 600 "$ROLLBACK_DIR"/* 2>/dev/null || true
log_ok "Firewall applied with $BACKEND"
log_info "Rollback material: $ROLLBACK_DIR"

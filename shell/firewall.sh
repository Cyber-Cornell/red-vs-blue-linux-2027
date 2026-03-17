#!/bin/sh
# ==============================================================================
# Firewall Configuration Script
# Supports: Linux (iptables/nftables), Solaris (ipf)
# ==============================================================================

set -e

log_info() { printf "\033[0;32m[INFO]\033[0m %s\n" "$1"; }
log_warn() { printf "\033[0;33m[WARN]\033[0m %s\n" "$1"; }
log_err() { printf "\033[0;31m[ERROR]\033[0m %s\n" "$1" >&2; }

if [ "$(id -u)" -ne 0 ]; then
  log_err "This script must be run as root."
  exit 1
fi

# Detect OS and firewall system
OS_TYPE="linux"
FIREWALL_SYS="iptables"

case "$(uname -s)" in
SunOS)
  OS_TYPE="solaris"
  FIREWALL_SYS="ipf"
  ;;
Linux)
  if command -v nft >/dev/null 2>&1 && [ -f /etc/nftables.conf ]; then
    FIREWALL_SYS="nftables"
  fi
  ;;
esac

log_info "Starting firewall configuration..."
log_info "Detected: $OS_TYPE / $FIREWALL_SYS"

# ==============================================================================
# SOLARIS IP FILTER
# ==============================================================================
configure_solaris_ipf() {
  log_info "Configuring Solaris IP Filter..."

  mkdir -p /etc/ipf

  cat >/etc/ipf/ipf.conf <<'EOF'
# Solaris IP Filter Rules
pass in quick on lo0 all
pass out quick on lo0 all

block in log quick all with short
block in log quick all with opt lsrr
block in log quick all with opt ssrr

pass in quick proto tcp all flags S/SA keep state
pass out quick proto tcp all flags S/SA keep state
pass in quick proto udp all keep state
pass out quick proto udp all keep state

# Allow SSH
pass in quick proto tcp from any to any port = 22 flags S/SA keep state

# Allow HTTP/HTTPS
pass in quick proto tcp from any to any port = 80 flags S/SA keep state
pass in quick proto tcp from any to any port = 443 flags S/SA keep state

# ICMP
pass in quick proto icmp all icmp-type echo keep state
pass out quick proto icmp all keep state

# Default deny incoming
block in log all
pass out all
EOF

  chmod 644 /etc/ipf/ipf.conf

  if svcs -a 2>/dev/null | grep -q "ipfilter"; then
    svcadm enable network/ipfilter
    svcadm refresh network/ipfilter
  else
    ipf -Fa -f /etc/ipf/ipf.conf
  fi

  log_info "Solaris IP Filter configured"
}

# ==============================================================================
# LINUX IPTABLES
# ==============================================================================
configure_linux_iptables() {
  log_info "Configuring Linux iptables..."

  # Reset rules
  iptables -P INPUT ACCEPT
  iptables -P FORWARD ACCEPT
  iptables -P OUTPUT ACCEPT
  iptables -F
  iptables -X
  iptables -t nat -F
  iptables -t mangle -F

  ip6tables -P INPUT ACCEPT
  ip6tables -P FORWARD ACCEPT
  ip6tables -P OUTPUT ACCEPT
  ip6tables -F
  ip6tables -X

  # Create logging chains
  iptables -N SSH-INITIAL-LOG 2>/dev/null || iptables -F SSH-INITIAL-LOG
  iptables -N ICMP-FLOOD 2>/dev/null || iptables -F ICMP-FLOOD
  ip6tables -N SSH-INITIAL-LOG 2>/dev/null || ip6tables -F SSH-INITIAL-LOG
  ip6tables -N ICMP-FLOOD 2>/dev/null || ip6tables -F ICMP-FLOOD

  # SSH logging chain
  iptables -A SSH-INITIAL-LOG -m limit --limit 4/sec -j LOG --log-prefix "IPTables-SSH: " --log-level 5
  iptables -A SSH-INITIAL-LOG -j RETURN
  ip6tables -A SSH-INITIAL-LOG -m limit --limit 4/sec -j LOG --log-prefix "IP6Tables-SSH: " --log-level 5
  ip6tables -A SSH-INITIAL-LOG -j RETURN

  # ICMP flood protection
  iptables -A ICMP-FLOOD -m recent --set --name ICMP-FLOOD --rsource
  iptables -A ICMP-FLOOD -m recent --update --seconds 1 --hitcount 6 --name ICMP-FLOOD --rsource -j DROP
  iptables -A ICMP-FLOOD -j ACCEPT
  ip6tables -A ICMP-FLOOD -m recent --set --name ICMP-FLOOD --rsource
  ip6tables -A ICMP-FLOOD -m recent --update --seconds 1 --hitcount 6 --name ICMP-FLOOD --rsource -j DROP
  ip6tables -A ICMP-FLOOD -j ACCEPT

  # Loopback
  iptables -A INPUT -i lo -j ACCEPT
  iptables -A OUTPUT -o lo -j ACCEPT
  ip6tables -A INPUT -i lo -j ACCEPT
  ip6tables -A OUTPUT -o lo -j ACCEPT

  # Established connections
  iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

  # Drop invalid
  iptables -A INPUT -m state --state INVALID -j DROP
  ip6tables -A INPUT -m state --state INVALID -j DROP

  # SSH with rate limiting
  iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --set --name SSH
  iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 60 --hitcount 4 --name SSH -j DROP
  iptables -A INPUT -p tcp --dport 22 -m state --state NEW -j SSH-INITIAL-LOG
  iptables -A INPUT -p tcp --dport 22 -m state --state NEW -j ACCEPT
  ip6tables -A INPUT -p tcp --dport 22 -m state --state NEW -j ACCEPT

  # HTTP/HTTPS
  iptables -A INPUT -p tcp --dport 80 -m state --state NEW -j ACCEPT
  iptables -A INPUT -p tcp --dport 443 -m state --state NEW -j ACCEPT
  ip6tables -A INPUT -p tcp --dport 80 -m state --state NEW -j ACCEPT
  ip6tables -A INPUT -p tcp --dport 443 -m state --state NEW -j ACCEPT

  # ICMP
  iptables -A INPUT -p icmp --icmp-type echo-request -j ICMP-FLOOD
  ip6tables -A INPUT -p icmpv6 --icmpv6-type echo-request -j ICMP-FLOOD

  # Default policies
  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT ACCEPT
  ip6tables -P INPUT DROP
  ip6tables -P FORWARD DROP
  ip6tables -P OUTPUT ACCEPT

  # Save rules
  if [ -f /etc/debian_version ]; then
    mkdir -p /etc/iptables
    iptables-save >/etc/iptables/rules.v4
    ip6tables-save >/etc/iptables/rules.v6
  elif [ -f /etc/redhat-release ]; then
    service iptables save 2>/dev/null || iptables-save >/etc/sysconfig/iptables
  elif [ -f /etc/alpine-release ]; then
    mkdir -p /etc/iptables
    iptables-save >/etc/iptables/rules-save
    ip6tables-save >/etc/iptables/rules6-save
    rc-update add iptables default 2>/dev/null || true
    rc-update add ip6tables default 2>/dev/null || true
  fi

  log_info "Linux iptables configured"
}

# ==============================================================================
# MAIN
# ==============================================================================
case "$OS_TYPE" in
solaris)
  configure_solaris_ipf
  ;;
linux)
  configure_linux_iptables
  ;;
esac

log_info "Firewall configuration complete!"

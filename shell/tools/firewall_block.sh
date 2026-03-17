#!/bin/sh

# ==============================================================================
# Script Name: block_ip.sh
# Description: Blocks a specific IPv4 address and saves rules using
#              detected OS paths (Debian/Ubuntu vs RHEL/CentOS style).
# Usage:       sudo ./block_ip.sh <IP_ADDRESS>
# ==============================================================================

# 1. Root Privilege Check
if [ "$(id -u)" -ne 0 ]; then
  printf "Error: This script must be run as root.\n" >&2
  exit 1
fi

# 2. Input Validation
IP_ADDR="$1"

if [ -z "$IP_ADDR" ]; then
  printf "Error: No IP address provided.\n" >&2
  printf "Usage: %s <ip_address>\n" "$0" >&2
  exit 1
fi

# 3. Check if iptables exists
if ! command -v iptables >/dev/null 2>&1; then
  printf "Error: iptables command not found.\n" >&2
  exit 1
fi

# 4. Apply the Block
# We use -C to check if the rule exists to avoid duplicates
if iptables -C INPUT -s "$IP_ADDR" -j DROP 2>/dev/null; then
  printf "Info: IP %s is already blocked.\n" "$IP_ADDR"
else
  # We use -I (Insert) to put the block at the TOP of the chain.
  # This ensures the IP is blocked even if 'Allow' rules exist lower down.
  iptables -I INPUT -s "$IP_ADDR" -j DROP
  printf "Success: Blocked incoming traffic from %s.\n" "$IP_ADDR"
fi

# 5. Save the Rules (Using your requested logic)
printf "Saving rules...\n"

if [ -f "/etc/debian_version" ]; then
  # Ensure the directory exists (Prevent errors on minimal installs)
  if [ ! -d "/etc/iptables" ]; then
    mkdir -p /etc/iptables
  fi

  iptables-save >/etc/iptables/rules.v4

  # Save IPv6 as well to match your previous script's behavior
  if command -v ip6tables-save >/dev/null 2>&1; then
    ip6tables-save >/etc/iptables/rules.v6
  fi
  printf "Saved to /etc/iptables/rules.v4\n"
else
  # Logic for RHEL/CentOS and others
  # Ensure the directory exists
  if [ ! -d "/etc/sysconfig" ]; then
    mkdir -p /etc/sysconfig
  fi

  iptables-save >/etc/sysconfig/iptables

  # Save IPv6 as well to match your previous script's behavior
  if command -v ip6tables-save >/dev/null 2>&1; then
    ip6tables-save >/etc/sysconfig/iptables
  fi
  printf "Saved to /etc/sysconfig/iptables\n"
fi

exit 0

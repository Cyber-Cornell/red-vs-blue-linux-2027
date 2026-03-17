#!/bin/sh

# ==============================================================================
# Script Name: unblock_ip.sh
# Description: Removes a specific IPv4 address from the iptables DROP rule.
#              Saves changes using OS-specific paths.
# Usage:       sudo ./unblock_ip.sh <IP_ADDRESS>
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

# 4. Remove the Block (Input Chain)
# We use -C to check if the rule exists before trying to delete it
# to avoid "Bad rule (does a matching rule exist in that chain?)" errors.

if iptables -C INPUT -s "$IP_ADDR" -j DROP 2>/dev/null; then
  # -D deletes the specific rule
  iptables -D INPUT -s "$IP_ADDR" -j DROP
  printf "Success: Unblocked incoming traffic from %s.\n" "$IP_ADDR"
else
  printf "Info: IP %s was not found in the blocked list (INPUT).\n" "$IP_ADDR"
fi

# 5. Remove the Block (Output Chain - just in case it was added there too)
if iptables -C OUTPUT -d "$IP_ADDR" -j DROP 2>/dev/null; then
  iptables -D OUTPUT -d "$IP_ADDR" -j DROP
  printf "Success: Unblocked outgoing traffic to %s.\n" "$IP_ADDR"
fi

# 6. Save the Rules (Matching previous script logic)
printf "Saving rules...\n"

if [ -f "/etc/debian_version" ]; then
  # Debian / Ubuntu logic
  if [ ! -d "/etc/iptables" ]; then
    mkdir -p /etc/iptables
  fi

  iptables-save >/etc/iptables/rules.v4

  # Save IPv6 as well to keep state consistent
  if command -v ip6tables-save >/dev/null 2>&1; then
    ip6tables-save >/etc/iptables/rules.v6
  fi
  printf "Saved to /etc/iptables/rules.v4\n"

else
  # RHEL / CentOS / Alpine / Generic logic
  if [ ! -d "/etc/sysconfig" ]; then
    mkdir -p /etc/sysconfig
  fi

  iptables-save >/etc/sysconfig/iptables

  if command -v ip6tables-save >/dev/null 2>&1; then
    ip6tables-save >/etc/sysconfig/iptables
  fi
  printf "Saved to /etc/sysconfig/iptables\n"
fi

exit 0

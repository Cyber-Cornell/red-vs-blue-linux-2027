#!/bin/sh

LOG_FILE="./error_log.txt"

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root."
  exit 1
fi

echo "Starting DNS configuration..."

echo "Step 1: Setting nameservers in resolv.conf..."
# Wrap echo commands in a block.
# > overwrites /etc/resolv.conf.
# 2>> redirects any write errors to the log file.
{
  echo "nameserver 9.9.9.11"
  echo "nameserver 149.112.112.11"
  echo "nameserver 2620:fe::11"
  echo "nameserver 2620:fe::fe:11"
} >/etc/resolv.conf 2>>"$LOG_FILE"

echo "Finished DNS configuration."

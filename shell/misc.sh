#!/bin/sh

LOG_FILE="./error_log.txt"

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root."
  exit 1
fi

echo "Starting updatedb configuration..."

echo "Step 1: Clearing updatedb configuration..."
# Write an empty string/newline to the config file.
# Any errors (like permission denied) are appended to the log file.
{ echo "" >/etc/updatedb.conf; } 2>>"$LOG_FILE"

echo "Finished updatedb configuration."

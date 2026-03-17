#!/bin/sh

# Function to print usage instructions
usage() {
  echo "Usage: $0 <username>"
  echo "Generates a random secure password and assigns it to the specified user."
  exit 1
}

# 1. Check for Root Privileges
if [ "$(id -u)" -ne 0 ]; then
  echo "Error: This script must be run as root."
  exit 1
fi

# 2. Check if an argument was provided
if [ -z "$1" ]; then
  echo "Error: No username provided."
  usage
fi

# Check for help flags
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  usage
fi

USER="$1"

# 3. Check if the user actually exists on the system
# We use 'id' and silence the output. If it returns false (non-zero), user is missing.
if ! id "$USER" >/dev/null 2>&1; then
  echo "Error: User '$USER' does not exist on this system."
  exit 1
fi

# 4. Generate Password
# (Existing logic preserved)
PASS=$(dd if=/dev/urandom bs=1 count=500 2>/dev/null | tr -dc 'A-Za-z0-9!@#$%^&*' | cut -c 1-14)

# 5. Apply Password
# We wrap this in an if-statement to catch if chpasswd fails (e.g., read-only filesystem)
if echo "${USER}:${PASS}" | chpasswd; then
  echo "----------------------------------------"
  echo "SUCCESS: Password changed for user '$USER'"
  echo "NEW PASSWORD: ${PASS}"
  echo "----------------------------------------"
else
  echo "Error: Failed to update password. Check system logs."
  exit 1
fi

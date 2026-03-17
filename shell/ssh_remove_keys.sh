#!/bin/sh

LOG_FILE="./error_log.txt"

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root."
  exit 1
fi

echo "Starting SSH cleanup..."

echo "Step 1: Removing .ssh directories (Standard paths)..."
{
  for dir in /home/* /root; do
    if [ -d "$dir" ]; then
      sshdir="$dir/.ssh"
      if [ -d "$sshdir" ]; then
        rm -rf "$sshdir"
      fi
    fi
  done
} 2>>"$LOG_FILE"

echo "Step 2: Removing .ssh directories (System-wide)..."
{
  if command -v getent >/dev/null 2>&1; then
    getent passwd | cut -d: -f6 | sort -u | while read -r homedir; do
      if [ -n "$homedir" ] && [ -d "$homedir/.ssh" ]; then
        rm -rf "$homedir/.ssh"
      fi
    done
  fi
} 2>>"$LOG_FILE"

echo "Step 3: Removing SSH Host keys..."
# Redirecting errors for file deletion
rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*.pub 2>>"$LOG_FILE"

echo "Step 4: Removing known_hosts files..."
{
  rm -f /etc/ssh/ssh_known_hosts

  for dir in /home/* /root; do
    if [ -d "$dir" ]; then
      kh="$dir/.ssh/known_hosts"
      if [ -f "$kh" ]; then
        rm -f "$kh" "$kh.old"
      fi
    fi
  done
} 2>>"$LOG_FILE"

ssh-keygen -A

echo "Finished SSH cleanup."

#!/bin/sh
# Finds SUID/SGID binaries and World-Writable files

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root."
  exit 1
fi

echo "=== SUID BINARIES (High Risk) ==="
# Find files with SUID bit set owned by root
# Compare this output against GTFOBins.github.io
find / -user root -perm -4000 -print 2>/dev/null

echo "\n=== WORLD WRITABLE FILES (High Risk) ==="
# Find files that anyone can write to (excluding /proc, /sys, /dev)
find / -xdev -type f -perm -0002 -print 2>/dev/null

echo "\n=== IMMUTABLE FILES (Rootkit Indicator) ==="
# Rootkits often use 'chattr +i' to make their malware undeletable.
# Standard system files are rarely immutable.
lsattr -R / 2>/dev/null | grep "\-i\-"

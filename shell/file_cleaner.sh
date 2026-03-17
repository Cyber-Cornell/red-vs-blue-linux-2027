#!/bin/sh

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root."
  exit 1
fi

echo "Starting system file cleanup..."

echo "Step 1: Removing insecure network configuration files..."
find / -name ".rhosts" -exec rm -rf {} \;
find / -name "hosts.equiv" -exec rm -rf {} \;

echo "Step 2: Removing temporary and suspicious files..."
rm -f /usr/lib/svfs/*trash
rm -f /usr/lib/gvfs/*trash
rm -f /var/timemachine
rm -f /bin/ex1t
rm -f /var/oxygen.html

echo "Step 3: Removing access control deny files..."
rm -f /etc/at.deny
rm -f /etc/cron.deny

echo "Step 4: Removing potentially sensitive data files..."
find / -iname 'users.csv' -delete
find / -iname 'user.csv' -delete
find / -iname '*password.txt' -delete
find / -iname '*passwords.txt' -delete

echo "Finished system file cleanup."

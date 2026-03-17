#!/bin/sh

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root."
  exit 1
fi

echo "Starting fstab configuration..."

echo "Step 1: Securing temporary filesystems in fstab..."
{
  echo "tmpfs /run/shm tmpfs defaults,nodev,noexec,nosuid 0 0"
  echo "tmpfs /tmp tmpfs defaults,rw,nosuid,nodev,noexec,relatime 0 0"
  echo "tmpfs /var/tmp tmpfs defaults,nodev,noexec,nosuid 0 0"
} >>/etc/fstab

echo "Finished fstab configuration."

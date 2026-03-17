#!/bin/sh

if [ "$(id -u || true)" -ne 0 ]; then
  echo "This script must be run as root."
  exit 1
fi

# ./tools/backup_create.sh
# ./permission_fix.sh
# ./tools/users.sh
# ./tools/password_rotate.sh
# ./permission_fix.sh
# ./networking.sh
# ./firewall.sh
# ./ssh_remove_keys.sh
# ./ssh_config.sh
# ./package_manager_reset.sh
# ./package_reinstall.sh
# ./package_install.sh
# ./package_remove.sh
# ./firewall.sh
# ./kernel.sh
# ./auditd.sh
# ./rsyslog.sh
# ./journald.sh
# ./apparmor.sh
# ./fstab.sh
# ./misc.sh
# ./file_cleaner.sh
# ./dconf.sh
# ./tools/password_rotate.sh

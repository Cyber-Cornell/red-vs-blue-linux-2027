#!/bin/sh

LOGFILE="error_log.txt"

# Preserve original stdout for progress messages
exec 3>&1

# Send all stdout to /dev/null, stderr appended to log
exec 1>/dev/null
exec 2>>"$LOGFILE"

progress() {
  printf '%s\n' "$1" >&3
}

progress "Starting system permission hardening..."

if [ "$(id -u || true)" -ne 0 ]; then
  progress "ERROR: Must be run as root"
  exit 1
fi

progress "Removing immutable attributes..."
chattr -Ria /bin /etc /home /lib /opt /root /usr /var

IS_RHEL=0
[ -f /etc/redhat-release ] && IS_RHEL=1

progress "Securing login banners..."
chown root:root /etc/motd /etc/issue /etc/issue.net
chmod u-x,go-wx /etc/motd /etc/issue /etc/issue.net

progress "Securing account databases..."
chown root:root /etc/group /etc/passwd /etc/passwd- /etc/group-
chown root:shadow /etc/gshadow /etc/shadow /etc/gshadow- /etc/shadow-
chmod 644 /etc/group /etc/passwd /etc/group- /etc/passwd-
chmod o-rwx,g-wx /etc/gshadow /etc/shadow /etc/gshadow- /etc/shadow-

progress "Securing cron configuration..."
chown root:root /etc/crontab /etc/cron.hourly /etc/cron.daily /etc/cron.weekly \
  /etc/cron.monthly /etc/cron.allow /etc/at.allow
chmod og-rwx /etc/crontab /etc/cron.hourly /etc/cron.daily /etc/cron.weekly \
  /etc/cron.monthly /etc/cron.allow /etc/at.allow

progress "Securing SSH configuration..."
chown -R root:root /etc/ssh
chmod og-rwx /etc/ssh/sshd_config
find /etc/ssh -name 'ssh_host_*key' -exec chmod 600 {} \;
find /etc/ssh -name '*.pub' -exec chmod 644 {} \;

progress "Normalizing top-level directory permissions..."
for dir in /dev /etc /home /media /mnt /opt /run /srv /usr /var \
  /var/lib /var/spool /var/cache /usr/lib /usr/local; do
  [ -d "$dir" ] || continue
  chown root:root "$dir"
  chmod 755 "$dir"
done

progress "Fixing user home directory permissions..."
if [ -f /etc/passwd ]; then
  while IFS=: read -r _ _ uid gid _ home _; do
    [ "$uid" -ge 1000 ] 2>/dev/null || continue
    case "$home" in
    /home/*)
      [ -d "$home" ] || continue
      chown "$uid:$gid" "$home"
      chmod 750 "$home"

      if [ -d "$home/.ssh" ]; then
        chown "$uid:$gid" "$home/.ssh"
        chmod 700 "$home/.ssh"
        find "$home/.ssh" -type f ! -name "*.pub" -exec chmod 600 {} \;
        find "$home/.ssh" -type f -exec chown "$uid:$gid" {} \;
        [ -f "$home/.ssh/config" ] && chmod 644 "$home/.ssh/config"
        [ -f "$home/.ssh/known_hosts" ] && chmod 644 "$home/.ssh/known_hosts"
      fi
      ;;
    esac
  done </etc/passwd
fi

progress "Securing system logs..."
chown root:root /var/log
chmod 755 /var/log

if grep -q "^adm:" /etc/group; then
  for f in syslog auth.log kern.log dpkg.log mail.log user.log daemon.log; do
    [ -f "/var/log/$f" ] && chown root:adm "/var/log/$f" && chmod 640 "/var/log/$f"
  done
  chown root:adm /var/log/apache2 /var/log/nginx
  chmod 750 /var/log/apache2 /var/log/nginx
fi

chown root:utmp /var/log/wtmp 2>/dev/null || chown root:root /var/log/wtmp
chmod 664 /var/log/wtmp
chown root:utmp /var/log/btmp 2>/dev/null || chown root:root /var/log/btmp
chmod 660 /var/log/btmp

progress "Securing bootloader..."
chown root:root /boot
[ "$IS_RHEL" -eq 1 ] && chmod 700 /boot || chmod 755 /boot

for b in /boot/*; do
  [ -f "$b" ] && chown root:root "$b" && chmod 644 "$b"
done

for g in /boot/grub /boot/grub2; do
  [ -d "$g" ] || continue
  chown root:root "$g"
  [ "$IS_RHEL" -eq 1 ] && chmod 700 "$g" || chmod 755 "$g"
  find "$g" -name grub.cfg -exec chmod 600 {} \;
done

progress "Fixing kernel modules..."
find /lib/modules -type d -exec chown root:root {} \; -exec chmod 755 {} \;
find /lib/modules -type f -exec chown root:root {} \; -exec chmod 644 {} \;

progress "Securing sudo configuration..."
chown root:root /etc/sudoers /etc/sudoers.d
chmod 440 /etc/sudoers
chmod 750 /etc/sudoers.d
find /etc/sudoers.d -type f -exec chmod 440 {} \;

progress "Fixing temporary directories..."
for t in /tmp /var/tmp /dev/shm; do
  [ -d "$t" ] && chown root:root "$t" && chmod 1777 "$t"
done

progress "Final package consistency checks..."
if command -v rpm >/dev/null 2>&1; then
  rpm -a --setperms --setugids
  command -v restorecon >/dev/null 2>&1 &&
    restorecon -R /boot /etc/pam.d /lib/modules /root /etc/ssh
elif command -v apk >/dev/null 2>&1; then
  apk fix
elif command -v dpkg >/dev/null 2>&1; then
  [ -f /usr/lib/policykit-1/polkit-agent-helper-1 ] && chmod 4755 /usr/lib/policykit-1/polkit-agent-helper-1
  [ -f /usr/bin/pkexec ] && chmod 4755 /usr/bin/pkexec
  [ -f /usr/lib/sudo/sudoers.so ] && chmod 644 /usr/lib/sudo/sudoers.so
fi

progress "Finished fixing file permissions."

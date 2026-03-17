#!/bin/sh
# Universal Deep Persistence Hunter
# Compatible with: Systemd, SysVinit, OpenRC, Runit, Upstart

if [ "$(id -u)" -ne 0 ]; then
  echo "Error: Must run as root."
  exit 1
fi

echo "Scanning Persistence Vectors..."
echo "---------------------------------"

# ==============================================================================
# 1. UNIVERSAL VECTORS (Works on everything)
# ==============================================================================

# A. Dynamic Linker Hijacking (The "God Mode" of userland rootkits)
if [ -s /etc/ld.so.preload ]; then
  echo "[ALERT] /etc/ld.so.preload is ACTIVE."
  echo "        Payload: $(cat /etc/ld.so.preload)"
fi
# Check for LD_PRELOAD env var in running processes
if [ -d /proc ]; then
  # We use tr to handle null bytes safely in POSIX sh
  grep -a "LD_PRELOAD" /proc/*/environ 2>/dev/null | cut -c 1-100 | grep "LD_PRELOAD" && echo "[WARN] LD_PRELOAD found in running process environment."
fi

# B. Global Profiles (Shell Hooks)
# Checks /etc/profile.d for scripts containing suspicious network/shell commands
if [ -d /etc/profile.d ]; then
  grep -lE "curl|wget|nc |netcat|bash -i|python|perl|gcc" /etc/profile.d/* 2>/dev/null | while read -r file; do
    echo "[WARN] Suspicious commands in global shell profile: $file"
  done
fi

# C. XDG Autostart (GUI Persistence)
# Used by GNOME/KDE/XFCE regardless of distro
for dir in /etc/xdg/autostart /home/*/.config/autostart; do
  if [ -d "$dir" ]; then
    find "$dir" -name "*.desktop" -type f 2>/dev/null | while read -r file; do
      # Check if it executes a hidden file or script
      if grep -q "Exec=.*/\." "$file"; then
        echo "[WARN] Hidden file execution in XDG Autostart: $file"
      fi
    done
  fi
done

# ==============================================================================
# 2. INIT SYSTEM SPECIFIC VECTORS
# ==============================================================================

# A. CHECKING RC.LOCAL (SysVinit / OpenRC / Systemd-compat)
# Classic persistence. Malware adds lines here to run at boot.
for rc in /etc/rc.local /etc/rc.d/rc.local; do
  if [ -f "$rc" ]; then
    # Check if it has content other than comments/shebang/exit
    if grep -vE "^#|^$|^exit 0" "$rc" | grep -q .; then
      echo "[INFO] $rc contains active commands. Verify contents."
      grep -vE "^#|^$" "$rc" | head -n 3
    fi
  fi
done

# B. OPENRC (Alpine, Gentoo)
if [ -d /etc/local.d ]; then
  echo "[INFO] Scanning OpenRC local.d..."
  # OpenRC runs scripts ending in .start
  find /etc/local.d -name "*.start" -type f 2>/dev/null | while read -r file; do
    echo "[CHECK] OpenRC local script found: $file"
  done
fi

# C. SYSVINIT (Devuan, Debian-Legacy, RHEL-Legacy)
if [ -d /etc/init.d ]; then
  # Look for scripts modified in the last 7 days
  # This catches recently dropped malware posing as a service
  find /etc/init.d -mtime -7 -type f 2>/dev/null | while read -r file; do
    echo "[WARN] Recently modified SysVinit script: $file"
  done
fi

# D. SYSTEMD (Debian, Ubuntu, Arch, RHEL, etc)
if [ -d /etc/systemd/system ]; then
  # Look for Timers (Systemd's version of Cron)
  find /etc/systemd/system -name "*.timer" -type f 2>/dev/null | while read -r timer; do
    echo "[INFO] Systemd Timer found (alternative to Cron): $timer"
  done

  # Look for User-level services (often used to bypass root checks)
  find /home /root -path "*/.config/systemd/user/*" -type f 2>/dev/null | while read -r file; do
    echo "[WARN] User-level Systemd service found: $file"
  done
fi

# ==============================================================================
# 3. KERNEL & HARDWARE
# ==============================================================================

# A. Udev Rules (Hardware Triggers)
if [ -d /etc/udev/rules.d ]; then
  # Look for rules that execute scripts (RUN key)
  # Whitelist standard system paths to reduce noise
  grep "RUN" /etc/udev/rules.d/* 2>/dev/null | grep -vE "/lib/udev|/usr/bin/systemctl" && echo "[WARN] Non-standard Udev execution rule found."
fi

# B. Kernel Modules
if [ -f /proc/modules ]; then
  # Tainted check
  taint=$(cat /proc/sys/kernel/tainted 2>/dev/null)
  if [ "$taint" != "0" ] && [ "$taint" != "" ]; then
    echo "[WARN] Kernel is TAINTED (Code: $taint). Possible unsigned module/rootkit."
  fi
fi

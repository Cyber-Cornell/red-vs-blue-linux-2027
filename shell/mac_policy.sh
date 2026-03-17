#!/bin/sh

# ==============================================================================
# Mandatory Access Control (MAC) Policy Configuration
# Supports: AppArmor (Debian/Ubuntu), SELinux (RHEL/CentOS/Fedora), None (Alpine)
# ==============================================================================

set -e

log_info() { printf "[INFO] %s\n" "$1"; }
log_warn() { printf "\033[0;33m[WARN]\033[0m %s\n" "$1"; }
log_err() { printf "\033[0;31m[ERROR]\033[0m %s\n" "$1" >&2; }

if [ "$(id -u)" -ne 0 ]; then
  log_err "This script must be run as root."
  exit 1
fi

# ==============================================================================
# 1. DETECT MAC SYSTEM
# ==============================================================================
detect_mac_system() {
  MAC_SYS="none"

  # Check for SELinux
  if command -v getenforce >/dev/null 2>&1; then
    SELINUX_STATUS=$(getenforce 2>/dev/null || echo "Disabled")
    if [ "$SELINUX_STATUS" != "Disabled" ]; then
      MAC_SYS="selinux"
      log_info "Detected MAC system: SELinux ($SELINUX_STATUS)"
      return
    fi
  fi

  # Check for AppArmor
  if command -v aa-status >/dev/null 2>&1; then
    if aa-status --enabled 2>/dev/null; then
      MAC_SYS="apparmor"
      log_info "Detected MAC system: AppArmor"
      return
    fi
  fi

  # Check for AppArmor via /sys
  if [ -d /sys/kernel/security/apparmor ]; then
    MAC_SYS="apparmor"
    log_info "Detected MAC system: AppArmor (via sysfs)"
    return
  fi

  # Check for SELinux via /sys
  if [ -d /sys/fs/selinux ]; then
    MAC_SYS="selinux"
    log_info "Detected MAC system: SELinux (via sysfs)"
    return
  fi

  log_warn "No MAC system detected (AppArmor or SELinux)"
}

# ==============================================================================
# 2. CONFIGURE APPARMOR
# ==============================================================================
configure_apparmor() {
  log_info "Configuring AppArmor..."

  # Install AppArmor if not present
  if ! command -v aa-status >/dev/null 2>&1; then
    log_info "Installing AppArmor..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq
      apt-get install -y apparmor apparmor-utils
    elif command -v apk >/dev/null 2>&1; then
      apk add apparmor apparmor-utils
    fi
  fi

  # Enable AppArmor service
  if [ -d /run/systemd/system ]; then
    systemctl enable apparmor 2>/dev/null || true
    systemctl start apparmor 2>/dev/null || true
  elif command -v rc-update >/dev/null 2>&1; then
    rc-update add apparmor boot 2>/dev/null || true
    rc-service apparmor start 2>/dev/null || true
  fi

  # Load all profiles
  if [ -d /etc/apparmor.d ]; then
    log_info "Loading AppArmor profiles..."

    # Reload all profiles
    for profile in /etc/apparmor.d/*; do
      if [ -f "$profile" ] && [ "$(basename "$profile")" != "README" ]; then
        apparmor_parser -r "$profile" 2>/dev/null || true
      fi
    done
  fi

  # Set enforce mode for all profiles
  if command -v aa-enforce >/dev/null 2>&1; then
    aa-enforce /etc/apparmor.d/* 2>/dev/null || true
  fi

  # Status
  aa-status 2>/dev/null || true
}

# ==============================================================================
# 3. CONFIGURE SELINUX
# ==============================================================================
configure_selinux() {
  log_info "Configuring SELinux..."

  SELINUX_CONFIG="/etc/selinux/config"

  # Install SELinux tools if not present
  if ! command -v semanage >/dev/null 2>&1; then
    log_info "Installing SELinux tools..."
    if command -v dnf >/dev/null 2>&1; then
      dnf install -y policycoreutils-python-utils selinux-policy-targeted
    elif command -v yum >/dev/null 2>&1; then
      yum install -y policycoreutils-python selinux-policy-targeted
    fi
  fi

  # Configure SELinux mode
  if [ -f "$SELINUX_CONFIG" ]; then
    # Backup
    cp "$SELINUX_CONFIG" "${SELINUX_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"

    # Set to enforcing
    sed -i 's/^SELINUX=.*/SELINUX=enforcing/' "$SELINUX_CONFIG"
    sed -i 's/^SELINUXTYPE=.*/SELINUXTYPE=targeted/' "$SELINUX_CONFIG"
  fi

  # Enable SELinux if permissive
  CURRENT_MODE=$(getenforce 2>/dev/null || echo "Disabled")
  if [ "$CURRENT_MODE" = "Permissive" ]; then
    log_warn "SELinux is in Permissive mode. Setting to Enforcing..."
    setenforce 1 2>/dev/null || log_warn "Could not set Enforcing mode (reboot may be required)"
  elif [ "$CURRENT_MODE" = "Disabled" ]; then
    log_warn "SELinux is Disabled. Reboot required after configuration."
  fi

  # Restore default contexts
  log_info "Restoring default SELinux contexts..."
  restorecon -Rv /etc 2>/dev/null || true
  restorecon -Rv /var 2>/dev/null || true
  restorecon -Rv /home 2>/dev/null || true

  # Set common booleans for hardening
  log_info "Setting SELinux booleans..."

  # Deny ptrace (prevents debugging attacks)
  setsebool -P deny_ptrace on 2>/dev/null || true

  # Restrict user execution
  setsebool -P user_exec_content off 2>/dev/null || true

  # Disable execmem where possible
  setsebool -P allow_execmem off 2>/dev/null || true

  # Show status
  sestatus 2>/dev/null || getenforce
}

# ==============================================================================
# 4. INSTALL MAC SYSTEM IF NONE
# ==============================================================================
install_mac_system() {
  log_info "No MAC system detected. Attempting to install..."

  if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO_LIKE="${ID_LIKE:-$ID}"
  fi

  case "$DISTRO_LIKE" in
  *debian* | *ubuntu*)
    log_info "Installing AppArmor on Debian/Ubuntu..."
    apt-get update -qq
    apt-get install -y apparmor apparmor-utils apparmor-profiles
    MAC_SYS="apparmor"
    ;;
  *rhel* | *fedora* | *centos* | *rocky* | *alma*)
    log_info "Enabling SELinux on RHEL/Fedora..."
    # SELinux should already be installed, just configure
    if [ -f /etc/selinux/config ]; then
      MAC_SYS="selinux"
    else
      dnf install -y selinux-policy-targeted 2>/dev/null ||
        yum install -y selinux-policy-targeted
      MAC_SYS="selinux"
    fi
    ;;
  *alpine*)
    log_info "Installing AppArmor on Alpine..."
    apk add apparmor apparmor-utils
    MAC_SYS="apparmor"
    ;;
  *arch*)
    log_info "Installing AppArmor on Arch..."
    pacman -S --noconfirm apparmor
    MAC_SYS="apparmor"
    ;;
  *)
    log_warn "Could not determine appropriate MAC system for this distro"
    return 1
    ;;
  esac
}

# ==============================================================================
# 5. CREATE CUSTOM PROFILES
# ==============================================================================
create_custom_profiles() {
  log_info "Creating custom security profiles..."

  case "$MAC_SYS" in
  apparmor)
    create_apparmor_profiles
    ;;
  selinux)
    create_selinux_policies
    ;;
  esac
}

create_apparmor_profiles() {
  # SSH daemon profile
  cat >/etc/apparmor.d/local/usr.sbin.sshd <<'EOF'
# Local customizations for sshd
# Add any site-specific rules here
EOF

  # Nginx profile additions
  if [ -f /etc/apparmor.d/usr.sbin.nginx ]; then
    cat >/etc/apparmor.d/local/usr.sbin.nginx <<'EOF'
# Local customizations for nginx
# Add any site-specific rules here
EOF
  fi

  log_info "Custom AppArmor profiles created in /etc/apparmor.d/local/"
}

create_selinux_policies() {
  # Create custom policy module directory
  mkdir -p /root/selinux_modules

  log_info "Custom SELinux policies should be created based on audit2allow output"
  log_info "Run: audit2allow -a -M custom_policy"
}

# ==============================================================================
# 6. VERIFY CONFIGURATION
# ==============================================================================
verify_configuration() {
  log_info "Verifying MAC configuration..."

  case "$MAC_SYS" in
  apparmor)
    printf "\n=== AppArmor Status ===\n"
    aa-status 2>/dev/null || echo "Could not get status"
    ;;
  selinux)
    printf "\n=== SELinux Status ===\n"
    sestatus 2>/dev/null || getenforce
    ;;
  none)
    log_warn "No MAC system configured"
    ;;
  esac
}

# ==============================================================================
# 7. MAIN
# ==============================================================================
main() {
  log_info "Starting MAC Policy Configuration..."

  detect_mac_system

  if [ "$MAC_SYS" = "none" ]; then
    install_mac_system
  fi

  case "$MAC_SYS" in
  apparmor)
    configure_apparmor
    ;;
  selinux)
    configure_selinux
    ;;
  none)
    log_err "Could not configure MAC system"
    exit 1
    ;;
  esac

  create_custom_profiles
  verify_configuration

  log_info "MAC policy configuration complete!"
}

main "$@"

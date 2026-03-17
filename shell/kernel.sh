#!/bin/sh
# ==============================================================================
# Kernel/System Hardening Script
# Supports: Linux, Solaris/illumos
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log_info() { printf "\033[0;32m[INFO]\033[0m %s\n" "$1"; }
log_warn() { printf "\033[0;33m[WARN]\033[0m %s\n" "$1"; }
log_err() { printf "\033[0;31m[ERROR]\033[0m %s\n" "$1" >&2; }

if [ "$(id -u)" -ne 0 ]; then
  log_err "This script must be run as root."
  exit 1
fi

# Detect OS
OS_TYPE="linux"
case "$(uname -s)" in
SunOS) OS_TYPE="solaris" ;;
esac

log_info "Starting system hardening..."
log_info "Detected OS: $OS_TYPE"

# ==============================================================================
# SOLARIS HARDENING
# ==============================================================================
harden_solaris() {
  log_info "Applying Solaris hardening..."

  SYSTEM_FILE="/etc/system"

  [ -f "$SYSTEM_FILE" ] && cp "$SYSTEM_FILE" "${SYSTEM_FILE}.bak.$(date +%Y%m%d%H%M%S)"

  cat >>"$SYSTEM_FILE" <<'EOF'

* Security Hardening
set sys:coredumpsize = 0
set noexec_user_stack = 1
set noexec_user_stack_log = 1
set ip:ip_forward_directed_broadcasts = 0
set ip:ip_respond_to_echo_broadcast = 0
set ip:ip_ignore_redirect = 1
set tcp:tcp_rev_src_routes = 0
EOF

  # Disable unnecessary services
  for svc in telnet ftp rlogin rsh finger; do
    svcadm disable "network/$svc" 2>/dev/null || true
  done

  # Disable core dumps
  coreadm -d global -d process 2>/dev/null || true

  log_info "Solaris hardening complete (reboot required)"
}

# ==============================================================================
# LINUX HARDENING
# ==============================================================================
harden_linux() {
  log_info "Applying Linux hardening..."

  # Apply sysctl.conf
  if [ -f "$SCRIPT_DIR/configs/sysctl.conf" ]; then
    log_info "Using configs/sysctl.conf"
    cat "$SCRIPT_DIR/configs/sysctl.conf" >/etc/sysctl.conf
  else
    log_err "configs/sysctl.conf not found!"
    exit 1
  fi

  # Apply host.conf
  if [ -f "$SCRIPT_DIR/configs/host.conf" ]; then
    log_info "Using configs/host.conf"
    cat "$SCRIPT_DIR/configs/host.conf" >/etc/host.conf
  fi

  # Create security directories
  mkdir -p /etc/security
  mkdir -p /etc/modprobe.d

  # Disable core dumps (append, don't overwrite)
  if ! grep -q "hard core 0" /etc/security/limits.conf 2>/dev/null; then
    echo "* hard core 0" >>/etc/security/limits.conf
  fi

  # Additional limits.d file
  echo "* hard core 0" >/etc/security/limits.d/99-disable-coredumps.conf

  # Blacklist USB storage
  echo "blacklist usb-storage" >>/etc/modprobe.d/blacklist.conf
  echo "install usb-storage /bin/false" >/etc/modprobe.d/usb-storage.conf

  # Clear securetty (restrict root console login)
  echo >/etc/securetty 2>/dev/null || true

  # Restore prelinked binaries (if prelink was used)
  if command -v prelink >/dev/null 2>&1; then
    log_info "Restoring prelinked binaries..."
    prelink -ua || true
  fi

  # Reload sysctl
  log_info "Reloading sysctl settings..."
  sysctl -ep || true
  sysctl -w net.ipv4.route.flush=1 2>/dev/null || true
  sysctl -w net.ipv6.route.flush=1 2>/dev/null || true

  log_info "Linux hardening complete"
}

# ==============================================================================
# MAIN
# ==============================================================================
case "$OS_TYPE" in
solaris)
  harden_solaris
  ;;
linux)
  harden_linux
  ;;
esac

log_info "System hardening complete!"

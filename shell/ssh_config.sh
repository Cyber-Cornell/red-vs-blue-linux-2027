#!/bin/sh
# ==============================================================================
# SSH Configuration Script
# Supports: Linux (all distros), NodeOS, Solaris/illumos
# Uses configs/sshd_config and configs/authorized_keys when available
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source detection library or inline
if [ -f "$SCRIPT_DIR/lib/detect.sh" ]; then
  . "$SCRIPT_DIR/lib/detect.sh"
else
  case "$(uname -s)" in
  SunOS) OS_TYPE="solaris" ;;
  Linux)
    OS_TYPE="linux"
    if [ -f /etc/nodeos-release ] || [ -d /node_modules ]; then
      OS_FAMILY="nodeos"
    fi
    ;;
  esac

  if command -v svcadm >/dev/null 2>&1; then
    INIT_SYS="smf"
  elif [ -d /run/systemd/system ]; then
    INIT_SYS="systemd"
  elif command -v rc-service >/dev/null 2>&1; then
    INIT_SYS="openrc"
  else
    INIT_SYS="sysv"
  fi
fi

log_info() { printf "\033[0;32m[INFO]\033[0m %s\n" "$1"; }
log_warn() { printf "\033[0;33m[WARN]\033[0m %s\n" "$1"; }
log_err() { printf "\033[0;31m[ERROR]\033[0m %s\n" "$1" >&2; }

if [ "$(id -u)" -ne 0 ]; then
  log_err "This script must be run as root."
  exit 1
fi

log_info "Starting SSH configuration..."
log_info "Detected OS: $OS_TYPE, Init: $INIT_SYS"

# ==============================================================================
# DETECT SSH CONFIG PATHS
# ==============================================================================
detect_ssh_paths() {
  case "$OS_TYPE" in
  solaris)
    SSHD_CONFIG="/etc/ssh/sshd_config"
    SSH_DIR="/etc/ssh"
    SSH_SERVICE="network/ssh"
    SSH_BINARY="/usr/lib/ssh/sshd"
    SFTP_SERVER="/usr/lib/ssh/sftp-server"
    ;;
  linux)
    SSHD_CONFIG="/etc/ssh/sshd_config"
    SSH_DIR="/etc/ssh"
    if [ -f "/lib/systemd/system/ssh.service" ] || [ -f "/usr/lib/systemd/system/ssh.service" ]; then
      SSH_SERVICE="ssh"
    else
      SSH_SERVICE="sshd"
    fi
    SSH_BINARY="/usr/sbin/sshd"
    SFTP_SERVER="/usr/lib/openssh/sftp-server"
    # Alpine uses different path
    if [ -f /etc/alpine-release ]; then
      SFTP_SERVER="/usr/lib/ssh/sftp-server"
    fi
    ;;
  *)
    SSHD_CONFIG="/etc/ssh/sshd_config"
    SSH_DIR="/etc/ssh"
    SSH_SERVICE="sshd"
    ;;
  esac

  log_info "SSH config: $SSHD_CONFIG"
  log_info "SSH service: $SSH_SERVICE"
}

# ==============================================================================
# GENERATE SSH HOST KEYS
# ==============================================================================
generate_host_keys() {
  log_info "Generating SSH host keys..."

  mkdir -p "$SSH_DIR"

  case "$OS_TYPE" in
  solaris)
    if [ ! -f "$SSH_DIR/ssh_host_rsa_key" ]; then
      /usr/bin/ssh-keygen -t rsa -b 4096 -f "$SSH_DIR/ssh_host_rsa_key" -N ""
    fi
    if [ ! -f "$SSH_DIR/ssh_host_ed25519_key" ]; then
      /usr/bin/ssh-keygen -t ed25519 -f "$SSH_DIR/ssh_host_ed25519_key" -N ""
    fi
    ;;
  linux)
    if command -v ssh-keygen >/dev/null 2>&1; then
      ssh-keygen -A
    fi
    ;;
  esac
}

# ==============================================================================
# APPLY SSHD CONFIG FROM configs/sshd_config
# ==============================================================================
apply_sshd_config() {
  log_info "Applying sshd_config..."

  # Backup existing config
  if [ -f "$SSHD_CONFIG" ]; then
    cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
  fi

  # Check if custom config exists in configs directory
  if [ -f "$SCRIPT_DIR/configs/sshd_config" ]; then
    log_info "Using configs/sshd_config"
    cat "$SCRIPT_DIR/configs/sshd_config" >"$SSHD_CONFIG"
  else
    log_err "configs/sshd_config not found!"
    exit 1
  fi

  # Add OS-specific settings
  case "$OS_TYPE" in
  solaris)
    log_info "Adding Solaris-specific SSH settings..."
    # Ensure Subsystem is set correctly for Solaris
    if ! grep -q "^Subsystem" "$SSHD_CONFIG"; then
      echo "" >>"$SSHD_CONFIG"
      echo "# Solaris SFTP subsystem" >>"$SSHD_CONFIG"
      echo "Subsystem sftp $SFTP_SERVER" >>"$SSHD_CONFIG"
    fi
    ;;
  linux)
    # Add Subsystem if not present
    if ! grep -q "^Subsystem" "$SSHD_CONFIG"; then
      echo "" >>"$SSHD_CONFIG"
      echo "# SFTP subsystem" >>"$SSHD_CONFIG"
      echo "Subsystem sftp $SFTP_SERVER" >>"$SSHD_CONFIG"
    fi
    ;;
  esac

  chmod 600 "$SSHD_CONFIG"
}

# ==============================================================================
# VALIDATE CONFIG
# ==============================================================================
validate_config() {
  log_info "Validating SSH configuration..."

  if command -v sshd >/dev/null 2>&1; then
    if sshd -t -f "$SSHD_CONFIG" 2>&1; then
      log_info "SSH configuration is valid."
      return 0
    else
      log_err "SSH configuration is INVALID!"
      return 1
    fi
  elif [ -x "$SSH_BINARY" ]; then
    if "$SSH_BINARY" -t -f "$SSHD_CONFIG" 2>&1; then
      log_info "SSH configuration is valid."
      return 0
    else
      log_err "SSH configuration is INVALID!"
      return 1
    fi
  else
    log_warn "Cannot validate config - sshd not found"
    return 0
  fi
}

# ==============================================================================
# RESTART SSH SERVICE
# ==============================================================================
restart_ssh_service() {
  log_info "Restarting SSH service..."

  case "$INIT_SYS" in
  smf)
    log_info "Using Solaris SMF..."
    svcadm restart "$SSH_SERVICE" || svcadm restart svc:/network/ssh:default

    sleep 2
    if svcs -p "$SSH_SERVICE" 2>/dev/null | grep -q "online"; then
      log_info "SSH service is online (SMF)"
    else
      svcs -xv "$SSH_SERVICE"
      log_warn "SSH service may not be running properly"
    fi
    ;;
  systemd)
    systemctl unmask "$SSH_SERVICE"
    systemctl enable "$SSH_SERVICE"
    systemctl restart "$SSH_SERVICE"

    if systemctl is-active --quiet "$SSH_SERVICE"; then
      log_info "SSH service is active (systemd)"
    else
      log_warn "SSH service may not be running"
    fi
    ;;
  openrc)
    rc-update add "$SSH_SERVICE" default
    rc-service "$SSH_SERVICE" restart
    ;;
  sysv)
    if [ -x "/etc/init.d/$SSH_SERVICE" ]; then
      "/etc/init.d/$SSH_SERVICE" restart
    fi
    ;;
  nodeos)
    log_info "NodeOS: Restarting SSH manually..."
    pkill -HUP sshd || true
    if ! pgrep sshd >/dev/null; then
      /usr/sbin/sshd || sshd
    fi
    ;;
  esac
}

# ==============================================================================
# SETUP AUTHORIZED KEYS FROM configs/authorized_keys
# ==============================================================================
setup_authorized_keys() {
  _user="$1"

  if [ -z "$_user" ]; then
    return
  fi

  # Check if authorized_keys config exists
  if [ ! -f "$SCRIPT_DIR/configs/authorized_keys" ]; then
    log_warn "configs/authorized_keys not found, skipping"
    return
  fi

  # Get user home directory
  if command -v getent >/dev/null 2>&1; then
    _home=$(getent passwd "$_user" 2>/dev/null | cut -d: -f6)
  else
    _home=$(grep "^${_user}:" /etc/passwd 2>/dev/null | cut -d: -f6)
  fi

  if [ -z "$_home" ] || [ ! -d "$_home" ]; then
    log_warn "User '$_user' home directory not found"
    return
  fi

  log_info "Setting up authorized_keys for $_user..."

  mkdir -p "${_home}/.ssh"
  chmod 700 "${_home}/.ssh"

  cat "$SCRIPT_DIR/configs/authorized_keys" >"${_home}/.ssh/authorized_keys"
  chmod 600 "${_home}/.ssh/authorized_keys"

  # Set ownership
  if command -v chown >/dev/null 2>&1; then
    chown -R "${_user}" "${_home}/.ssh"
    _group=$(id -gn "$_user" 2>/dev/null || echo "$_user")
    chown -R "${_user}:${_group}" "${_home}/.ssh"
  fi
}

# ==============================================================================
# MAIN
# ==============================================================================
main() {
  detect_ssh_paths
  generate_host_keys
  apply_sshd_config

  # Setup authorized keys for admin users from configs/admins.txt
  if [ -f "$SCRIPT_DIR/configs/admins.txt" ]; then
    log_info "Setting up authorized_keys for admins from configs/admins.txt"
    while IFS= read -r admin || [ -n "$admin" ]; do
      # Skip empty lines and comments
      case "$admin" in
      '' | \#*) continue ;;
      esac
      if id "$admin" >/dev/null 2>&1; then
        setup_authorized_keys "$admin"
      else
        log_warn "Admin user '$admin' does not exist"
      fi
    done <"$SCRIPT_DIR/configs/admins.txt"
  else
    # Fallback: try common admin users
    for user in cybear admin root; do
      if id "$user" >/dev/null 2>&1; then
        setup_authorized_keys "$user"
      fi
    done
  fi

  if validate_config; then
    restart_ssh_service
  else
    log_err "Restoring backup due to invalid config..."
    if ls "${SSHD_CONFIG}.bak."* >/dev/null 2>&1; then
      cp "$(ls -t "${SSHD_CONFIG}.bak."* | head -1)" "$SSHD_CONFIG"
    fi
    exit 1
  fi

  log_info "SSH configuration complete!"
}

main "$@"

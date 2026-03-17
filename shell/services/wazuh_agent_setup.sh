#!/bin/sh

# ==============================================================================
# Wazuh Agent Installation Script
# Supports: Debian/Ubuntu, RHEL/CentOS/Fedora/Alma, Alpine, SUSE
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
# 1. GET WAZUH MANAGER IP
# ==============================================================================
get_manager_ip() {
  if [ -n "$1" ]; then
    WAZUH_MANAGER="$1"
  else
    printf "Enter Wazuh Manager IP: "
    read -r WAZUH_MANAGER
  fi

  if [ -z "$WAZUH_MANAGER" ]; then
    log_err "Wazuh Manager IP is required."
    exit 1
  fi

  WAZUH_AGENT_NAME="$(hostname)"
  export WAZUH_MANAGER
  export WAZUH_AGENT_NAME

  log_info "Manager: $WAZUH_MANAGER"
  log_info "Agent Name: $WAZUH_AGENT_NAME"
}

# ==============================================================================
# 2. DETECT DISTRO
# ==============================================================================
detect_distro() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_LIKE="${ID_LIKE:-$ID}"
    VERSION_ID="${VERSION_ID:-}"
  else
    log_err "/etc/os-release not found. System may be too old."
    exit 1
  fi
  log_info "Detected: $DISTRO_ID $VERSION_ID"
}

# ==============================================================================
# 3. INSTALL DEPENDENCIES
# ==============================================================================
install_dependencies() {
  log_info "Installing dependencies..."

  case "$DISTRO_LIKE" in
  *debian* | *ubuntu*)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y curl gnupg apt-transport-https lsb-release
    ;;
  *rhel* | *fedora* | *centos* | *alma* | *rocky*)
    if command -v dnf >/dev/null 2>&1; then
      dnf install -y curl gnupg2
    else
      yum install -y curl gnupg2
    fi
    ;;
  *alpine*)
    apk update
    apk add curl gnupg wget
    ;;
  *suse* | *sles*)
    zypper install -y curl gpg2
    ;;
  *)
    log_warn "Unknown distro, attempting generic installation..."
    ;;
  esac
}

# ==============================================================================
# 4. DEBIAN/UBUNTU INSTALLATION
# ==============================================================================
install_debian() {
  log_info "Installing Wazuh agent on Debian/Ubuntu..."

  # Import GPG key
  curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH |
    gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import
  chmod 644 /usr/share/keyrings/wazuh.gpg

  # Add repository
  echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" |
    tee /etc/apt/sources.list.d/wazuh.list

  # Install agent
  apt-get update -qq
  apt-get install -y wazuh-agent
}

# ==============================================================================
# 5. RHEL/CENTOS/FEDORA INSTALLATION
# ==============================================================================
install_rhel() {
  log_info "Installing Wazuh agent on RHEL/CentOS/Fedora..."

  # Import GPG key
  rpm --import https://packages.wazuh.com/key/GPG-KEY-WAZUH

  # Add repository
  cat >/etc/yum.repos.d/wazuh.repo <<'EOF'
[wazuh]
gpgcheck=1
gpgkey=https://packages.wazuh.com/key/GPG-KEY-WAZUH
enabled=1
name=EL-$releasever - Wazuh
baseurl=https://packages.wazuh.com/4.x/yum/
protect=1
EOF

  # Install agent
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y wazuh-agent
  else
    yum install -y wazuh-agent
  fi
}

# ==============================================================================
# 6. ALPINE INSTALLATION
# ==============================================================================
install_alpine() {
  log_info "Installing Wazuh agent on Alpine Linux..."

  # Alpine requires manual installation
  WAZUH_VERSION="4.7.2"
  ARCH=$(uname -m)

  case "$ARCH" in
  x86_64) WAZUH_ARCH="x86_64" ;;
  aarch64) WAZUH_ARCH="aarch64" ;;
  *)
    log_err "Unsupported architecture: $ARCH"
    exit 1
    ;;
  esac

  # Create directories
  mkdir -p /var/ossec

  # Download and extract
  WAZUH_URL="https://packages.wazuh.com/4.x/linux/wazuh-agent-${WAZUH_VERSION}-linux-${WAZUH_ARCH}.tar.gz"

  log_info "Downloading Wazuh agent from $WAZUH_URL..."
  cd /tmp
  wget -q "$WAZUH_URL" -O wazuh-agent.tar.gz || curl -sLO "$WAZUH_URL" -o wazuh-agent.tar.gz

  tar -xzf wazuh-agent.tar.gz -C /
  rm -f wazuh-agent.tar.gz

  # Configure agent
  if [ -f /var/ossec/etc/ossec.conf ]; then
    sed -i "s/MANAGER_IP/$WAZUH_MANAGER/g" /var/ossec/etc/ossec.conf
  fi

  # Create OpenRC init script
  cat >/etc/init.d/wazuh-agent <<'INITEOF'
#!/sbin/openrc-run

name="wazuh-agent"
description="Wazuh Agent"
command="/var/ossec/bin/wazuh-control"
command_args="start"
pidfile="/var/ossec/var/run/wazuh-agentd.pid"

depend() {
    need net
    after firewall
}

start() {
    ebegin "Starting $name"
    /var/ossec/bin/wazuh-control start
    eend $?
}

stop() {
    ebegin "Stopping $name"
    /var/ossec/bin/wazuh-control stop
    eend $?
}

status() {
    /var/ossec/bin/wazuh-control status
}
INITEOF

  chmod +x /etc/init.d/wazuh-agent
  rc-update add wazuh-agent default 2>/dev/null || true
}

# ==============================================================================
# 7. SUSE INSTALLATION
# ==============================================================================
install_suse() {
  log_info "Installing Wazuh agent on SUSE/openSUSE..."

  # Import GPG key
  rpm --import https://packages.wazuh.com/key/GPG-KEY-WAZUH

  # Add repository
  cat >/etc/zypp/repos.d/wazuh.repo <<'EOF'
[wazuh]
gpgcheck=1
gpgkey=https://packages.wazuh.com/key/GPG-KEY-WAZUH
enabled=1
name=Wazuh repository
baseurl=https://packages.wazuh.com/4.x/yum/
protect=1
EOF

  zypper --non-interactive install wazuh-agent
}

# ==============================================================================
# 8. CONFIGURE AND START AGENT
# ==============================================================================
configure_agent() {
  log_info "Configuring Wazuh agent..."

  OSSEC_CONF="/var/ossec/etc/ossec.conf"

  if [ -f "$OSSEC_CONF" ]; then
    # Update manager IP
    if grep -q "<address>" "$OSSEC_CONF"; then
      sed -i "s|<address>.*</address>|<address>$WAZUH_MANAGER</address>|g" "$OSSEC_CONF"
    fi
  fi
}

start_agent() {
  log_info "Starting Wazuh agent..."

  if [ -d /run/systemd/system ]; then
    systemctl daemon-reload
    systemctl enable wazuh-agent
    systemctl start wazuh-agent
  elif command -v rc-service >/dev/null 2>&1; then
    rc-update add wazuh-agent default 2>/dev/null || true
    rc-service wazuh-agent start
  elif [ -x /var/ossec/bin/wazuh-control ]; then
    /var/ossec/bin/wazuh-control start
  fi

  # Verify
  sleep 2
  if [ -x /var/ossec/bin/wazuh-control ]; then
    /var/ossec/bin/wazuh-control status
  fi
}

# ==============================================================================
# 9. MAIN
# ==============================================================================
main() {
  log_info "Starting Wazuh Agent Installation..."

  get_manager_ip "$1"
  detect_distro
  install_dependencies

  case "$DISTRO_LIKE" in
  *debian* | *ubuntu* | *mint* | *kali*)
    install_debian
    ;;
  *rhel* | *fedora* | *centos* | *alma* | *rocky* | *amzn*)
    install_rhel
    ;;
  *alpine*)
    install_alpine
    ;;
  *suse* | *sles*)
    install_suse
    ;;
  *)
    log_err "Unsupported distribution: $DISTRO_ID"
    exit 1
    ;;
  esac

  configure_agent
  start_agent

  log_info "Wazuh agent installation complete!"
}

main "$@"

#!/bin/sh
# ==============================================================================
# Package Installation Script
# Supports: Debian/Ubuntu, RHEL/CentOS/Fedora, Alpine, Arch, Solaris, NodeOS
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source detection library
if [ -f "$SCRIPT_DIR/lib/detect.sh" ]; then
  . "$SCRIPT_DIR/lib/detect.sh"
else
  case "$(uname -s)" in
  SunOS)
    OS_TYPE="solaris"
    if command -v pkg >/dev/null 2>&1; then
      PKG_MGR="ips"
    elif command -v pkgin >/dev/null 2>&1; then
      PKG_MGR="pkgin"
    fi
    ;;
  Linux)
    OS_TYPE="linux"
    if [ -f /etc/os-release ]; then
      . /etc/os-release
      OS_FAMILY="${ID_LIKE:-$ID}"
    fi
    if [ -d /node_modules ] || [ -f /etc/nodeos-release ]; then
      OS_FAMILY="nodeos"
      PKG_MGR="npm"
    elif command -v apt-get >/dev/null 2>&1; then
      PKG_MGR="apt"
    elif command -v dnf >/dev/null 2>&1; then
      PKG_MGR="dnf"
    elif command -v apk >/dev/null 2>&1; then
      PKG_MGR="apk"
    fi
    ;;
  esac
fi

log_info() { printf "[INFO] %s\n" "$1"; }
log_warn() { printf "\033[0;33m[WARN]\033[0m %s\n" "$1"; }
log_err() { printf "\033[0;31m[ERROR]\033[0m %s\n" "$1" >&2; }

if [ "$(id -u)" -ne 0 ]; then
  log_err "This script must be run as root."
  exit 1
fi

log_info "Starting package installation..."
log_info "Detected OS: $OS_TYPE, Package Manager: $PKG_MGR"

# ==============================================================================
# DEBIAN/UBUNTU
# ==============================================================================
install_debian() {
  log_info "Installing packages on Debian/Ubuntu..."

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq

  apt-get install -y --ignore-missing \
    auditd \
    audispd-plugins \
    apparmor \
    apparmor-utils \
    ca-certificates \
    coreutils \
    curl \
    gnupg \
    htop \
    iptables \
    iptables-persistent \
    libpam-pwquality \
    lsof \
    lynis \
    net-tools \
    nmap \
    openssh-server \
    openssl \
    rsyslog \
    rkhunter \
    sudo \
    tcpdump \
    vim \
    wget ||
    true
}

# ==============================================================================
# RHEL/CENTOS/FEDORA
# ==============================================================================
install_rhel() {
  log_info "Installing packages on RHEL/CentOS/Fedora..."

  if command -v dnf >/dev/null 2>&1; then
    PKG="dnf"
  else
    PKG="yum"
  fi

  if ! grep -q "Amazon Linux" /etc/os-release 2>/dev/null; then
    $PKG install -y epel-release || true
  fi

  $PKG makecache

  $PKG install -y --skip-broken \
    audit \
    audit-libs \
    ca-certificates \
    coreutils \
    curl \
    gnupg2 \
    htop \
    iptables \
    iptables-services \
    libpwquality \
    lsof \
    lynis \
    net-tools \
    nmap \
    openssh-server \
    openssl \
    rsyslog \
    rkhunter \
    sudo \
    tcpdump \
    vim \
    wget ||
    true
}

# ==============================================================================
# ALPINE
# ==============================================================================
install_alpine() {
  log_info "Installing packages on Alpine..."

  apk update

  apk add --no-cache \
    audit \
    ca-certificates \
    coreutils \
    curl \
    gnupg \
    htop \
    iptables \
    lsof \
    net-tools \
    nmap \
    openssh \
    openssl \
    rsyslog \
    rkhunter \
    sudo \
    tcpdump \
    vim \
    wget ||
    true
}

# ==============================================================================
# SOLARIS/ILLUMOS (IPS)
# ==============================================================================
install_solaris_ips() {
  log_info "Installing packages on Solaris/illumos (IPS)..."

  pkg refresh || true

  pkg install -q --accept \
    compress/gzip \
    developer/versioning/git \
    diagnostic/top \
    diagnostic/wireshark \
    editor/vim \
    file/gnu-coreutils \
    network/netcat \
    network/openssh \
    security/sudo \
    service/network/ntp \
    shell/bash \
    system/core-os \
    system/network \
    text/gnu-grep \
    text/gnu-sed \
    web/curl \
    web/wget ||
    true

  pkg install -q --accept \
    system/auditd \
    system/auditd/plugin-remote ||
    true
}

# ==============================================================================
# SOLARIS/ILLUMOS (pkgin - SmartOS/pkgsrc)
# ==============================================================================
install_solaris_pkgin() {
  log_info "Installing packages on SmartOS/pkgsrc..."

  pkgin -y update

  pkgin -y install \
    bash \
    coreutils \
    curl \
    git \
    gnupg2 \
    htop \
    lsof \
    nmap \
    openssh \
    rsyslog \
    sudo \
    vim \
    wget ||
    true
}

# ==============================================================================
# NODEOS (npm)
# ==============================================================================
install_nodeos() {
  log_info "Installing packages on NodeOS via npm..."

  npm install -g --quiet \
    forever \
    pm2 \
    node-firewall \
    helmet \
    express-rate-limit ||
    true

  if command -v opkg >/dev/null 2>&1; then
    log_info "opkg available, installing additional tools..."
    opkg update || true
    opkg install \
      openssh-server \
      iptables \
      curl ||
      true
  fi

  log_warn "NodeOS is minimal - many security tools are unavailable"
  log_info "Consider using Docker containers for additional security tools"
}

# ==============================================================================
# MAIN
# ==============================================================================
main() {
  case "$OS_TYPE" in
  solaris)
    case "$PKG_MGR" in
    ips)
      install_solaris_ips
      ;;
    pkgin)
      install_solaris_pkgin
      ;;
    *)
      log_err "Unknown Solaris package manager"
      exit 1
      ;;
    esac
    ;;
  linux)
    case "$PKG_MGR" in
    apt)
      install_debian
      ;;
    dnf | yum)
      install_rhel
      ;;
    apk)
      install_alpine
      ;;
    npm)
      install_nodeos
      ;;
    *)
      log_err "Unknown package manager: $PKG_MGR"
      exit 1
      ;;
    esac
    ;;
  *)
    log_err "Unsupported OS: $OS_TYPE"
    exit 1
    ;;
  esac

  log_info "Package installation complete!"
}

main "$@"

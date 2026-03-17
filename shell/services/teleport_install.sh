#!/bin/sh

# ==============================================================================
# Teleport Installation Script
# POSIX-compliant for multi-distro support
# Supports: Debian/Ubuntu, RHEL/CentOS/Fedora/Alma/Rocky, Alpine, SUSE
# ==============================================================================

set -e

# Colors (POSIX-safe)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { printf "${GREEN}[+]${NC} %s\n" "$1"; }
log_warn() { printf "${YELLOW}[*]${NC} %s\n" "$1"; }
log_err() { printf "${RED}[!]${NC} %s\n" "$1" >&2; }
log_header() { printf "${BLUE}%s${NC}\n" "$1"; }

# Check root
if [ "$(id -u)" -ne 0 ]; then
  log_err "This script must be run as root"
  printf "Try: sudo %s\n" "$0"
  exit 1
fi

log_header "========================================"
log_header "   Teleport Installation Script"
log_header "========================================"
printf "\n"

# ==============================================================================
# 1. DETECT ENVIRONMENT
# ==============================================================================
detect_environment() {
  # Detect OS
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_LIKE="${ID_LIKE:-$ID}"
    DISTRO_VERSION="${VERSION_ID:-}"
    DISTRO_CODENAME="${VERSION_CODENAME:-}"
    DISTRO_PRETTY="${PRETTY_NAME:-$ID}"
  else
    log_err "Cannot determine OS version (/etc/os-release not found)"
    exit 1
  fi

  # Detect architecture
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  TELEPORT_ARCH="amd64" ;;
    aarch64) TELEPORT_ARCH="arm64" ;;
    armv7l)  TELEPORT_ARCH="arm" ;;
    *)
      log_err "Unsupported architecture: $ARCH"
      exit 1
      ;;
  esac

  log_info "Detected: $DISTRO_PRETTY ($ARCH)"
}

# ==============================================================================
# 2. INSTALLATION METHODS
# ==============================================================================

install_debian_ubuntu() {
  log_info "Installing Teleport on Debian/Ubuntu..."

  # Install dependencies
  apt-get update -qq
  apt-get install -y curl gnupg2 ca-certificates lsb-release

  # Add Teleport repository
  curl -fsSL https://apt.releases.teleport.dev/gpg -o /usr/share/keyrings/teleport-archive-keyring.asc
  
  # Determine codename
  if [ -z "$DISTRO_CODENAME" ]; then
    DISTRO_CODENAME=$(lsb_release -cs 2>/dev/null || echo "jammy")
  fi

  echo "deb [signed-by=/usr/share/keyrings/teleport-archive-keyring.asc] https://apt.releases.teleport.dev/${DISTRO_CODENAME} ${DISTRO_CODENAME} stable/v16" | \
    tee /etc/apt/sources.list.d/teleport.list > /dev/null

  apt-get update -qq
  apt-get install -y teleport
}

install_rhel_fedora() {
  log_info "Installing Teleport on RHEL/Fedora..."

  # Determine package manager
  if command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  else
    PKG_MGR="yum"
  fi

  # Install dependencies
  $PKG_MGR install -y curl

  # Add Teleport repository
  cat > /etc/yum.repos.d/teleport.repo << 'EOF'
[teleport]
name=Teleport
baseurl=https://rpm.releases.teleport.dev/
enabled=1
gpgcheck=1
gpgkey=https://rpm.releases.teleport.dev/RPM-GPG-KEY-teleport
EOF

  $PKG_MGR install -y teleport
}

install_alpine() {
  log_info "Installing Teleport on Alpine Linux..."

  # Install dependencies
  apk add --no-cache curl tar

  # Get latest version
  TELEPORT_VERSION=$(curl -s https://api.github.com/repos/gravitational/teleport/releases/latest | \
    grep '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/' || echo "16.0.0")

  log_info "Installing Teleport version

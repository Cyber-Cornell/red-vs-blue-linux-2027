#!/bin/sh
# lib/detect.sh - POSIX platform detection

detect_os() {
  OS_TYPE="unknown"
  case "$(uname -s 2>/dev/null || echo unknown)" in
  Linux) OS_TYPE="linux" ;;
  SunOS) OS_TYPE="solaris" ;;
  esac
}

detect_distro() {
  DISTRO_ID="unknown"
  DISTRO_LIKE="unknown"
  if [ "$OS_TYPE" = "linux" ] && [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID=${ID:-unknown}
    DISTRO_LIKE=${ID_LIKE:-$DISTRO_ID}
  fi
}

detect_init() {
  INIT_SYS="unknown"
  if [ "$OS_TYPE" = "solaris" ] && command -v svcadm >/dev/null 2>&1; then
    INIT_SYS="smf"
  elif [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    INIT_SYS="systemd"
  elif command -v rc-service >/dev/null 2>&1; then
    INIT_SYS="openrc"
  elif [ -d /etc/init.d ]; then
    INIT_SYS="sysv"
  fi
}

detect_pkg_mgr() {
  PKG_MGR="unknown"
  if [ "$OS_TYPE" = "solaris" ]; then
    command -v pkg >/dev/null 2>&1 && PKG_MGR="ips"
    command -v pkgin >/dev/null 2>&1 && PKG_MGR="pkgin"
    return
  fi

  command -v apt-get >/dev/null 2>&1 && PKG_MGR="apt"
  command -v dnf >/dev/null 2>&1 && PKG_MGR="dnf"
  command -v yum >/dev/null 2>&1 && PKG_MGR="yum"
  command -v apk >/dev/null 2>&1 && PKG_MGR="apk"
  command -v pacman >/dev/null 2>&1 && PKG_MGR="pacman"
  command -v zypper >/dev/null 2>&1 && PKG_MGR="zypper"
  command -v emerge >/dev/null 2>&1 && PKG_MGR="emerge"
}

detect_firewall() {
  FIREWALL_BACKEND="none"

  if [ "$OS_TYPE" = "solaris" ]; then
    command -v ipf >/dev/null 2>&1 && FIREWALL_BACKEND="ipf"
    return
  fi

  if command -v nft >/dev/null 2>&1; then
    FIREWALL_BACKEND="nft"
    return
  fi
  if command -v iptables >/dev/null 2>&1; then
    FIREWALL_BACKEND="iptables"
    return
  fi
}

detect_all() {
  detect_os
  detect_distro
  detect_init
  detect_pkg_mgr
  detect_firewall
}

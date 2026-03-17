#!/bin/sh

if [ "$(id -u || true)" -ne 0 ]; then
  echo "Script must be run as root."
  exit 1
fi

ssh-keygen -t ed25519

if [ -f /etc/os-release ]; then
  . /etc/os-release

  ID_MATCH="${ID_LIKE:-$ID}"

  case "$ID_MATCH" in
  *debian* | *ubuntu* | *devuan* | *kali* | *raspbian* | *linuxmint* | *pop*)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1

    apt-get install -y ansible
    ;;

  *rocky* | *rhel* | *fedora* | *centos* | *alma* | *ol* | *amzn* | *cloudlinux*)
    if command -v dnf >/dev/null 2>&1; then
      PKG_MGR="dnf"
    else
      PKG_MGR="yum"
    fi

    if ! grep -q "Amazon Linux" /etc/os-release; then
      $PKG_MGR install -y epel-release >/dev/null 2>&1
    fi

    $PKG_MGR install -y ansible
    ;;

  *alpine*)
    apk update

    apk add ansible
    ;;

  *suse* | *sles*)
    zypper refresh >/dev/null 2>&1

    zypper install -y ansible
    ;;

  *arch* | *manjaro*)
    pacman -Sy >/dev/null 2>&1

    pacman -S ansible
    ;;

  *)
    echo "Distro not supported."
    exit 1
    ;;
  esac
fi

log_info() { printf "\033[0;32m[INFO]\033[0m %s\n" "$1"; }
log_err() { printf "\033[0;31m[ERROR]\033[0m %s\n" "$1" >&2; }

# List of potential service names to look for
CANDIDATES="ansible ansible-tower automation-controller awx-web"
SERVICE=""

# ------------------------------------------------------------------------------
# 1. Service Detection
# ------------------------------------------------------------------------------
log_info "Searching for Ansible-related services..."

# Check Systemd
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  INIT_SYS="systemd"
  for name in $CANDIDATES; do
    if systemctl list-unit-files "$name.service" >/dev/null 2>&1; then
      SERVICE="$name"
      break
    fi
  done

# Check OpenRC
elif command -v rc-service >/dev/null 2>&1; then
  INIT_SYS="openrc"
  for name in $CANDIDATES; do
    if [ -x "/etc/init.d/$name" ]; then
      SERVICE="$name"
      break
    fi
  done

# Check SysVinit
elif [ -d /etc/init.d ]; then
  INIT_SYS="sysv"
  for name in $CANDIDATES; do
    if [ -x "/etc/init.d/$name" ]; then
      SERVICE="$name"
      break
    fi
  done
fi

if [ -z "$SERVICE" ]; then
  log_err "No Ansible service found (checked: $CANDIDATES)."
  printf "Note: Standard Ansible is agentless and does not use a service.\n"
  printf "      If you need to allow Ansible connections, ensure 'ssh' is enabled.\n"
  exit 1
fi

log_info "Found Service: $SERVICE ($INIT_SYS)"

# ------------------------------------------------------------------------------
# 2. Enable and Start Logic
# ------------------------------------------------------------------------------

if [ "$INIT_SYS" = "systemd" ]; then
  log_info "Systemd: Enabling and Starting $SERVICE..."
  systemctl unmask "$SERVICE" >/dev/null 2>&1
  if systemctl enable "$SERVICE" >/dev/null 2>&1; then
    systemctl start "$SERVICE" >/dev/null 2>&1
    log_info "Success."
  else
    log_err "Failed to enable $SERVICE via systemctl."
    exit 1
  fi

elif [ "$INIT_SYS" = "openrc" ]; then
  log_info "OpenRC: Adding $SERVICE to default runlevel..."
  if rc-update add "$SERVICE" default >/dev/null 2>&1; then
    rc-service "$SERVICE" start >/dev/null 2>&1
    log_info "Success."
  else
    log_err "Failed to enable $SERVICE via rc-update."
    exit 1
  fi

elif [ "$INIT_SYS" = "sysv" ]; then
  log_info "SysVinit: Enabling $SERVICE..."

  if command -v update-rc.d >/dev/null 2>&1; then
    update-rc.d "$SERVICE" defaults >/dev/null 2>&1
  elif command -v chkconfig >/dev/null 2>&1; then
    chkconfig "$SERVICE" on >/dev/null 2>&1
  fi

  "/etc/init.d/$SERVICE" start >/dev/null 2>&1
  log_info "Success (Attempted)."
fi
echo "Finished installing ansible"

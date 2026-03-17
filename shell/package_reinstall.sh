#!/bin/sh

LOG_FILE="./error_log.txt"

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root."
  exit 1
fi

echo "Starting package re-installation (This will take a long time)..."

if [ -f /etc/os-release ]; then
  . /etc/os-release

  # Determine distro family
  ID_MATCH="${ID_LIKE:-$ID}"

  case "$ID_MATCH" in
  *debian* | *ubuntu* | *devuan* | *kali* | *raspbian* | *linuxmint* | *pop*)
    echo "Step 1: Detected Debian/Ubuntu family..."
    export DEBIAN_FRONTEND=noninteractive

    echo "Step 2: Updating package lists..."
    apt-get update -qq >/dev/null 2>>"$LOG_FILE"

    echo "Step 3: Reinstalling all installed packages..."
    # We pipe the package list to xargs.
    # dpkg errors go to log.
    # apt-get install output goes to null, errors to log.
    dpkg --get-selections 2>>"$LOG_FILE" | grep -v deinstall | awk '{print $1}' |
      xargs apt-get install --reinstall -y -o Dpkg::Options::="--force-confmiss" >/dev/null 2>>"$LOG_FILE"

    echo "Step 4: Upgrading system..."
    apt-get upgrade -y >/dev/null 2>>"$LOG_FILE"
    apt-get dist-upgrade -y >/dev/null 2>>"$LOG_FILE"

    echo "Step 5: Cleaning up..."
    apt-get autoremove -y >/dev/null 2>>"$LOG_FILE"
    apt-get autoclean >/dev/null 2>>"$LOG_FILE"

    echo "Step 6: Updating initramfs..."
    update-initramfs -u -k all >/dev/null 2>>"$LOG_FILE"
    ;;

  *rocky* | *rhel* | *fedora* | *centos* | *alma* | *ol* | *amzn* | *cloudlinux*)
    echo "Step 1: Detected RHEL/CentOS family..."

    if command -v dnf >/dev/null 2>&1; then
      PKG_MGR="dnf"
    else
      PKG_MGR="yum"
    fi

    echo "Step 2: Cleaning cache..."
    $PKG_MGR clean all >/dev/null 2>>"$LOG_FILE"
    $PKG_MGR makecache >/dev/null 2>>"$LOG_FILE"

    echo "Step 3: Reinstalling all packages..."
    rpm -qa --qf '%{NAME}\n' 2>>"$LOG_FILE" | xargs $PKG_MGR reinstall -y >/dev/null 2>>"$LOG_FILE"

    echo "Step 4: Upgrading system..."
    $PKG_MGR upgrade -y >/dev/null 2>>"$LOG_FILE"

    echo "Step 5: Cleaning up..."
    $PKG_MGR autoremove -y >/dev/null 2>>"$LOG_FILE"
    $PKG_MGR clean all >/dev/null 2>>"$LOG_FILE"

    echo "Step 6: Regenerating initramfs (dracut)..."
    dracut -f >/dev/null 2>>"$LOG_FILE"
    ;;

  *alpine*)
    echo "Step 1: Detected Alpine Linux..."

    echo "Step 2: Refreshing keys and indexes..."
    apk add --force-refresh alpine-keys >/dev/null 2>>"$LOG_FILE"
    apk update >/dev/null 2>>"$LOG_FILE"

    echo "Step 3: Reinstalling packages (apk fix)..."
    apk info -q 2>>"$LOG_FILE" | xargs apk fix --reinstall >/dev/null 2>>"$LOG_FILE"

    echo "Step 4: Upgrading system..."
    apk upgrade --available >/dev/null 2>>"$LOG_FILE"

    echo "Step 5: Cleaning cache..."
    apk cache clean >/dev/null 2>>"$LOG_FILE" || rm -rf /var/cache/apk/* 2>>"$LOG_FILE"

    echo "Step 6: Regenerating initfs..."
    mkinitfs >/dev/null 2>>"$LOG_FILE"
    ;;

  *)
    echo "Error: Unsupported distro."
    echo "Unsupported distro: $ID_MATCH" >>"$LOG_FILE"
    exit 1
    ;;
  esac

  echo "Finished package reinstall."
else
  echo "Error: /etc/os-release not found."
  exit 1
fi

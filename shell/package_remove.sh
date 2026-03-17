#!/bin/sh

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root."
  exit 1
fi

echo "Starting removal of insecure packages..."

if [ -f /etc/os-release ]; then
  . /etc/os-release

  # Determine distro family
  ID_MATCH="${ID_LIKE:-$ID}"

  case "$ID_MATCH" in
  *debian* | *ubuntu* | *devuan* | *kali* | *raspbian*)
    echo "Step 1: Detected Debian/Ubuntu family..."
    export DEBIAN_FRONTEND=noninteractive

    echo "Step 2: Updating package lists..."
    apt-get update -q

    echo "Step 3: Purging insecure packages..."
    apt-get purge -y \
      autofs \
      ftp \
      netcat \
      nis \
      rsh-client \
      talk \
      telnet
    ;;

  *rocky* | *rhel* | *fedora* | *centos* | *alma*)
    echo "Step 1: Detected RHEL/CentOS family..."

    if command -v dnf >/dev/null 2>&1; then
      PKG_MGR="dnf"
    else
      PKG_MGR="yum"
    fi

    echo "Step 2: Removing insecure packages..."
    $PKG_MGR remove -y \
      autofs \
      ftp \
      netcat \
      nis \
      rsh-client \
      talk \
      telnet
    ;;

  *alpine*)
    echo "Step 1: Detected Alpine Linux..."

    echo "Step 2: Updating package index..."
    apk update

    echo "Step 3: Removing insecure packages..."
    apk del \
      autofs \
      ftp \
      nis \
      rsh-client \
      talk \
      telnet
    ;;

  *)
    echo "Could not remove packages: distro not supported."
    exit 1
    ;;
  esac

  echo "Finished removing packages."
fi

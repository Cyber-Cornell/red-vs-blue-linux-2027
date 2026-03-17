#!/bin/sh

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root."
  exit 1
fi

echo "Starting package manager reset..."

if [ -f /etc/os-release ]; then
  . /etc/os-release

  # Determine distro family
  ID_MATCH="${ID_LIKE:-$ID}"

  case "$ID_MATCH" in
  *debian* | *ubuntu* | *devuan* | *kali* | *raspbian*)
    echo "Step 1: Detected Debian/Ubuntu family..."

    echo "Step 2: Unholding packages..."
    HELD=$(apt-mark showhold)

    if [ -n "$HELD" ]; then
      echo "$HELD" | xargs apt-mark unhold
    fi

    echo "Step 3: Removing preference files..."
    if [ -d /etc/apt/preferences.d ]; then
      rm -f /etc/apt/preferences.d/*
    fi

    if [ -f /etc/apt/preferences ]; then
      rm -f /etc/apt/preferences
    fi

    echo "Step 4: Cleaning configuration and cache..."
    if [ -d /etc/apt/apt.conf.d ]; then
      find /etc/apt/apt.conf.d -type f ! -name '[0-1][0-9]*' ! -name '20*' -delete
    fi

    if [ -f /etc/apt/apt.conf ]; then
      rm -f /etc/apt/apt.conf
    fi

    apt-get clean >/dev/null

    echo "Step 5: Updating package lists..."
    apt-get update
    ;;

  *centos*)
    # Specific logic for CentOS migration
    CENTOS_VERSION="${VERSION_ID%%.*}"

    if [ "$CENTOS_VERSION" -lt 8 ]; then
      echo "Error: CentOS 7 or earlier cannot be migrated to Rocky Linux."
      echo "Migration failed (See error_log.txt)."
      exit 1
    fi

    echo "Step 1: Downloading Rocky Linux migration script..."
    # -s: Silent (no progress bar), -S: Show errors
    curl -s -O https://raw.githubusercontent.com/rocky-linux/rocky-tools/main/migrate2rocky/migrate2rocky.sh

    chmod +x migrate2rocky.sh

    echo "Step 2: Running migration script (This may take a while)..."
    # -r: Install Rocky. Redirect massive output to null, errors to log.
    ./migrate2rocky.sh -r

    rm -f migrate2rocky.sh
    ;;

  *rhel* | *fedora* | *rocky* | *alma*)
    echo "Step 1: Detected RHEL/Fedora family..."

    if command -v dnf >/dev/null 2>&1; then
      PKG_MGR="dnf"
    else
      PKG_MGR="yum"
    fi

    echo "Step 2: Clearing version locks..."
    if $PKG_MGR versionlock list 2>/dev/null | grep -q .; then
      $PKG_MGR versionlock clear -y
    fi

    echo "Step 3: Resetting configuration excludes..."
    if [ -f /etc/dnf/dnf.conf ]; then
      sed -i '/^exclude=/d' /etc/dnf/dnf.conf
      sed -i '/^excludepkgs=/d' /etc/dnf/dnf.conf
    fi
    if [ -f /etc/yum.conf ]; then
      sed -i '/^exclude=/d' /etc/yum.conf
      sed -i '/^excludepkgs=/d' /etc/yum.conf
    fi

    echo "Step 4: Re-enabling repositories..."
    for repo in /etc/yum.repos.d/*.repo; do
      [ -f "$repo" ] && sed -i 's/^enabled=0/enabled=1/' "$repo"
    done

    echo "Step 5: Cleaning and updating..."
    $PKG_MGR clean all
    $PKG_MGR makecache

    $PKG_MGR update -y
    ;;

  *alpine*)
    echo "Step 1: Detected Alpine Linux..."

    echo "Step 2: Resetting world file constraints..."
    if [ -f /etc/apk/world ]; then
      sed -i 's/^!//' /etc/apk/world
    fi

    echo "Step 3: Clearing config directory..."
    if [ -d /etc/apk/conf.d ]; then
      rm -f /etc/apk/conf.d/*
    fi

    echo "Step 4: Cleaning cache..."
    apk cache clean || rm -rf /var/cache/apk/*

    echo "Step 5: Updating package index..."
    apk update
    ;;

  *)
    echo "Could not reset package manager: unsupported distro."
    exit 1
    ;;
  esac

  echo "Finished package manager reset."
fi

#!/bin/sh

# Exit immediately if a variable is used before being set (prevents "rm -rf /" accidents due to typos)
set -u

# 1. Root Privilege Check
# The script modifies system files in /etc/, so it requires root permissions.
if [ "$(id -u)" -ne 0 ]; then
  echo "Error: This script must be run as root."
  exit 1
fi

# 2. Dependency Check
# Checks if the 'dconf' binary exists. If the system is headless (no GUI)
# or doesn't use GNOME, we exit cleanly instead of trying to install things.
if ! command -v dconf; then
  echo "dconf not installed"
  exit 0
fi

# 3. Create Directory Structure
# Ensures the standard dconf configuration paths exist.
# /etc/dconf/profile stores the hierarchy config.
# /etc/dconf/db/local.d/locks stores the list of immutable keys.
mkdir -p /etc/dconf/profile
mkdir -p /etc/dconf/db/local.d/locks

# 4. Set Profile Hierarchy
# This creates the 'user' profile. It tells the system to read:
# 1. The user's individual config (user-db)
# 2. The system-wide config (system-db:local)
# Without this file, the settings we write below will be ignored.
if [ ! -f /etc/dconf/profile/user ]; then
  printf "user-db:user\nsystem-db:local\n" >/etc/dconf/profile/user
fi

# 5. Define Security Settings
# Creates a file in the 'local' database defining the specific values we want.
# - Disable USB automounting (prevents physical access attacks).
# - Clear custom keybindings (removes Red Team shells hidden in keyboard shortcuts).
# - Hide the user list on login (prevents username enumeration).
# - Disable file history recording (privacy).
cat >/etc/dconf/db/local.d/01-ccdc-security <<EOF
[org/gnome/desktop/media-handling]
automount=false
automount-open=false

[org/gnome/settings-daemon/plugins/media-keys]
custom-keybindings=['']

[org/gnome/login-screen]
disable-user-list=true

[org/gnome/desktop/privacy]
remember-recent-files=false
remember-app-usage=false
remove-old-trash-files=true
remove-old-temp-files=true
EOF

# 6. Apply Locks (Immutability)
# This lists the specific keys that users are FORBIDDEN from changing.
# Even if a user tries to change these in the Settings GUI, they will be greyed out.
cat >/etc/dconf/db/local.d/locks/01-ccdc-locks <<EOF
/org/gnome/desktop/media-handling/automount
/org/gnome/desktop/media-handling/automount-open
/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings
/org/gnome/login-screen/disable-user-list
/org/gnome/desktop/privacy/remember-recent-files
EOF

# 7. Compile Database
# Converts the text files created above into the binary 'dconf' database.
# Changes will not take effect until this command is run.
dconf update

# 8. Reset User Configurations
# Iterates through the system password file to find human users.
getent passwd | while IFS=: read -r username _ uid _ _ homedir _; do

  # Sanity check to ensure UID is a number (handles malformed lines)
  case "$uid" in
  '' | *[!0-9]*) continue ;;
  esac

  # Filter for standard users (UID 1000+) but skip system users (UID > 60000 like 'nobody')
  if [ "$uid" -ge 1000 ] && [ "$uid" -lt 60000 ]; then

    # Check if the user's home directory actually exists
    if [ -d "$homedir" ]; then
      DCONF_FILE="$homedir/.config/dconf/user"

      # If the user has a local dconf database, delete it.
      # This forces the user to inherit the new system-wide locks immediately
      # the next time they log in.
      if [ -f "$DCONF_FILE" ]; then
        echo "Wiping local dconf for: $username"
        rm -f "$DCONF_FILE"
      fi
    fi
  fi
done

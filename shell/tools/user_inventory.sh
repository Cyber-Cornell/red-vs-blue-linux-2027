#!/bin/sh

# ==============================================================================
# Script Name: user_audit_sorted.sh
# Description: Lists users, groups, and login capability.
#              Output is SORTED alphabetically by username.
#              Portable: Runs on sh, dash, ash, bash.
# Usage:       ./user_audit_sorted.sh
# ==============================================================================

# 1. Format String (Table Layout)
FMT="%-20s | %-10s | %-18s | %s\n"

# 2. Print Header
printf "%s\n" "------------------------------------------------------------------------------------------------"
printf "$FMT" "Username" "Can Login?" "Shell" "Groups"
printf "%s\n" "------------------------------------------------------------------------------------------------"

# 3. Determine User Source
if command -v getent >/dev/null 2>&1; then
  USER_CMD="getent passwd"
else
  USER_CMD="cat /etc/passwd"
fi

# 4. Process Users (Piped to sort first)
# 'sort' automatically sorts by the first field (username) because the line starts with it.
eval "$USER_CMD" | sort | while IFS=: read -r user pass uid gid gecos home shell; do

  # --- A. Determine Login Status (Based ONLY on Shell) ---
  case "$shell" in
  */nologin | */false | */shutdown | */halt | */sync | "/dev/null")
    login_status="No"
    ;;
  *)
    # Assumes if they have a valid shell, they "could" login with a password/key
    login_status="Yes"
    ;;
  esac

  # --- B. Get Groups ---
  # id -Gn: Get group names
  # tr: Replace spaces with commas for display
  # 2>/dev/null: Suppress errors if a user ID is weirdly orphaned
  groups=$(id -Gn "$user" 2>/dev/null | tr ' ' ',')

  # --- C. Print Row ---
  printf "$FMT" "$user" "$login_status" "$shell" "$groups"

done

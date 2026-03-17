#!/bin/sh

# ==============================================================================
# Script Name: list_services_sorted.sh
# Description: Detects Init system (Systemd/OpenRC/SysV), lists running services,
#              and sorts the output alphabetically.
#              Portable: Runs on sh, dash, ash, bash.
# ==============================================================================

# 1. Format Helper
FMT="%-30s | %s\n"

# 2. Print Header (Printed immediately, not sorted)
printf "%s\n" "--------------------------------------------------------------------------------"
printf "$FMT" "Service Name" "Status / Description"
printf "%s\n" "--------------------------------------------------------------------------------"

# 3. Detect, Execute, and Sort
# We group the entire logic block in { ... } and pipe it to sort at the end.
{
  # --- CHECK 1: SYSTEMD ---
  if command -v systemctl >/dev/null 2>&1 && systemctl list-units >/dev/null 2>&1; then

    systemctl list-units --type=service --state=running --no-legend --plain --no-pager |
      while read -r unit load active sub desc; do
        printf "$FMT" "$unit" "$desc"
      done

  # --- CHECK 2: OPENRC (Alpine / Gentoo) ---
  elif command -v rc-status >/dev/null 2>&1; then

    rc-status -a | awk '
            /\[ *started *\]/ {
                # $1 is usually the service name
                service = $1
                printf "%-30s | %s\n", service, "Running (OpenRC)"
            }
        '

  # --- CHECK 3: SYSVINIT (Fallback) ---
  elif [ -d /etc/init.d ]; then

    for service_script in /etc/init.d/*; do
      [ ! -x "$service_script" ] && continue
      service_name=${service_script##*/}

      # Check status (silencing output)
      if "$service_script" status >/dev/null 2>&1; then
        printf "$FMT" "$service_name" "Running (SysV)"
      fi
    done

  else
    printf "Error: Could not detect Systemd, OpenRC, or SysVinit.\n" >&2
    exit 1
  fi

} | sort

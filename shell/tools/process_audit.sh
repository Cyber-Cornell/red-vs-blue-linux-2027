#!/bin/sh

# ==============================================================================
# POSIX Process Hunter v2
# Detects: Userland Rootkits, Deleted Binaries, and PID Overmounting
# ==============================================================================

if [ "$(id -u)" -ne 0 ]; then
  echo "Error: Must run as root."
  exit 1
fi

echo "Scanning for hidden, suspicious, and masked processes..."
PS_PIDS=$(ps -e -o pid | sed 's/ //g')

for pid_dir in /proc/[0-9]*; do
  if [ ! -d "$pid_dir" ]; then continue; fi
  pid=${pid_dir##*/}

  # ---------------------------------------------------------
  # CHECK 1: Visibility (Trojaned ps/top)
  # ---------------------------------------------------------
  if ! echo "$PS_PIDS" | grep -q "^${pid}$"; then
    echo "[ALERT] HIDDEN PID: $pid (Not in 'ps' output)"
  fi

  # ---------------------------------------------------------
  # CHECK 2: Mount Masking / Empty Proc Entry
  # If /proc/pid/status is missing, the PID is likely over-mounted
  # or the process is in a weird zombie state that ps usually ignores.
  # ---------------------------------------------------------
  if [ ! -f "$pid_dir/status" ]; then
    echo "[ALERT] MASKED PID: $pid"
    echo "        /proc/$pid exists, but contains no status file."
    echo "        Likely a 'mount' attack hiding the process details."

    # Check if it is a mount point
    if mount | grep -q "$pid_dir"; then
      echo "        CONFIRMED: Filesystem mounted over $pid_dir"
    fi
    continue
  fi

  # ---------------------------------------------------------
  # CHECK 3: Deleted Binaries
  # ---------------------------------------------------------
  exe_link=$(ls -l "$pid_dir/exe" 2>/dev/null)
  if echo "$exe_link" | grep -q "(deleted)"; then
    comm=$(cat "$pid_dir/comm" 2>/dev/null)
    echo "[WARN]  Deleted Binary: PID $pid ($comm)"
    echo "        Source: $(echo "$exe_link" | sed 's/.*-> //')"
  fi
done

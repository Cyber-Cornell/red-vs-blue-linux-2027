#!/bin/sh

# ==============================================================================
# Universal Package Integrity Verifier
# Detects modified, corrupted, or trojaned system files by comparing
# current files against the package manager's internal database/checksums.
# ==============================================================================

# Ensure standard locale for consistent grep/awk matching
export LC_ALL=C

if [ "$(id -u)" -ne 0 ]; then
  echo "Error: Must run as root to read all system files."
  exit 1
fi

echo "Starting System Integrity Verification..."
echo "Note: Modified configuration files in /etc are normal."
echo "      Modified binaries in /bin, /usr/bin, /sbin are CRITICAL ALERTS."
echo "----------------------------------------------------------------"

# Detect Distro Logic
if [ -f /etc/os-release ]; then
  . /etc/os-release
  ID_MATCH="${ID_LIKE:-$ID}"
fi

# ==============================================================================
# 1. DEBIAN / UBUNTU / KALI / DEVUAN
# Preference: debsums (thorough) -> dpkg -V (built-in fallback)
# ==============================================================================
if echo "$ID_MATCH" | grep -qE "debian|ubuntu|devuan|kali|raspbian|linuxmint|pop"; then
  echo "Detected Debian-based system."

  if command -v debsums >/dev/null 2>&1; then
    echo "Running 'debsums' (checking MD5 sums of installed packages)..."
    echo "Output format: [Status] [Path]"
    echo "----------------------------------------------------------------"

    # -a: all files (including configs)
    # -s: silent (only output errors)
    # -c: report changed files to stdout
    debsums -a -s -c 2>&1

    STATUS=$?
    if [ $STATUS -eq 0 ]; then
      echo "No modified files detected by debsums."
    fi

  elif command -v dpkg >/dev/null 2>&1; then
    echo "Warning: 'debsums' not found. Falling back to 'dpkg --verify'."
    echo "Output Legend: '??5??????' implies MD5 checksum mismatch."
    echo "----------------------------------------------------------------"

    # dpkg --verify is supported on newer Debian/Ubuntu versions
    if dpkg --help | grep -q verify; then
      dpkg --verify
    else
      echo "Error: This version of dpkg is too old and debsums is missing."
      echo "       Please install debsums: apt-get install debsums"
    fi
  fi

# ==============================================================================
# 2. RHEL / CENTOS / FEDORA / SUSE / ALMA / ROCKY
# Tool: rpm
# ==============================================================================
elif echo "$ID_MATCH" | grep -qE "rhel|fedora|centos|alma|rocky|ol|amzn|suse|sles"; then
  echo "Detected RPM-based system."
  echo "Running 'rpm -Va' (Verify All)..."
  echo "This may take a few minutes."
  echo ""
  echo "Legend: S=Size, 5=Checksum (CRITICAL), T=Timestamp, c=Config file"
  echo "Look specifically for '5' on non-config files."
  echo "----------------------------------------------------------------"

  # rpm -Va checks everything.
  # We use awk to highlight lines where the checksum (5) has changed.
  rpm -Va | while read -r line; do
    # Check if the 3rd character is '5' (MD5 mismatch)
    # Output format ex: S.5....T.  c /etc/httpd/conf/httpd.conf
    echo "$line" | grep "^..5" >/dev/null
    if [ $? -eq 0 ]; then
      echo "[CHECKSUM MISMATCH] $line"
    else
      # Just print the line normally if it's a size/time mismatch
      echo "$line"
    fi
  done

# ==============================================================================
# 3. ALPINE LINUX
# Tool: apk
# ==============================================================================
elif echo "$ID_MATCH" | grep -q "alpine"; then
  echo "Detected Alpine Linux."
  echo "Running 'apk audit'..."
  echo "----------------------------------------------------------------"

  # apk audit lists modified files relative to the package signature
  apk audit

# ==============================================================================
# 4. ARCH LINUX / MANJARO
# Tool: pacman
# ==============================================================================
elif echo "$ID_MATCH" | grep -qE "arch|manjaro"; then
  echo "Detected Arch-based system."
  echo "Running 'pacman -Qkk' (Double check)..."
  echo "----------------------------------------------------------------"

  # -Qkk checks for file modifications (mtime and checksum)
  # We filter out the "0 altered files" noise
  pacman -Qkk 2>/dev/null | grep -v "0 altered files"

else
  echo "Error: Unsupported distribution family or OS release file missing."
  exit 1
fi

echo "----------------------------------------------------------------"
echo "Verification Complete."

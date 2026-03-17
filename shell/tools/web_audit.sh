#!/bin/sh

# ==============================================================================
# Deep Web Shell Hunter (Terminal Output Version)
# Detects: Obfuscation, Fake Images, Double Extensions, Signature Matches
# ==============================================================================

# CONFIGURATION
# Change this to your actual web root
WEB_ROOT="/var/www"

if [ "$(id -u)" -ne 0 ]; then
  echo "Error: Must run as root."
  exit 1
fi

if [ ! -d "$WEB_ROOT" ]; then
  echo "Error: WEB_ROOT ($WEB_ROOT) not found. Adjust the variable in the script."
  exit 1
fi

echo "Starting Deep Web Shell Scan on $WEB_ROOT..."
echo "----------------------------------------------------------------"

# ==============================================================================
# 1. IMAGE/MEDIA HEADER INJECTION (Polyglots)
# ==============================================================================
echo "[1/5] Scanning Images for Embedded Code..."
# We look for image extensions that contain the PHP opening tag
find "$WEB_ROOT" -type f \( -name "*.jpg" -o -name "*.jpeg" -o -name "*.png" -o -name "*.gif" -o -name "*.ico" \) -exec grep -l "<?php" {} + 2>/dev/null | while read -r file; do
  echo "  [CRITICAL] PHP Code found inside image: $file"
done

# ==============================================================================
# 2. DOUBLE EXTENSIONS
# ==============================================================================
echo "[2/5] Scanning for Suspicious Extensions..."
# Look for .php followed by another extension (e.g., shell.php.jpg)
find "$WEB_ROOT" -type f -name "*.php.*" ! -name "*.cached" ! -name "*.lock" 2>/dev/null | while read -r file; do
  echo "  [WARN] Double extension detected: $file"
done

# ==============================================================================
# 3. HEURISTIC & OBFUSCATION SCAN
# ==============================================================================
echo "[3/5] Scanning for Obfuscated/Malicious Code Patterns..."

# A. Base64 / Rot13 / Compression
# Attackers hide calls like: eval(base64_decode('...'))
grep -rE "base64_decode|gzinflate|gzuncompress|str_rot13|convert_uudecode" "$WEB_ROOT" | grep -vE "node_modules|vendor|.git" | cut -c 1-200 | while read -r line; do
  echo "  [OBFUSCATION] $line"
done

# B. Dangerous Execution Functions
grep -rE "shell_exec|passthru|system\(|proc_open|popen\(|pcntl_exec|eval\(|assert\(" "$WEB_ROOT" | grep -vE "node_modules|vendor|.git" | cut -c 1-200 | while read -r line; do
  echo "  [DANGEROUS FUNCS] $line"
done

# C. Backticks (Execution shorthand in PHP)
grep -r "\`" "$WEB_ROOT" | grep ".php" | grep -vE "node_modules|vendor" | cut -c 1-200 | while read -r line; do
  echo "  [BACKTICKS] $line"
done

# ==============================================================================
# 4. LONG LINE DETECTION (Weevely/Obfuscated Shells)
# ==============================================================================
echo "[4/5] Scanning for files with massive line lengths..."
# Find PHP files, use awk to check if any line exceeds 2000 characters.
find "$WEB_ROOT" -type f -name "*.php" -exec awk 'length($0) > 2000 { print FILENAME; exit }' {} + 2>/dev/null | while read -r file; do
  # Filter out common minified JS/CSS/Cache if they accidentally got named .php
  if ! echo "$file" | grep -qE "min.php|cache"; then
    echo "  [WARN] Massive single line (Potential Obfuscated Shell): $file"
  fi
done

# ==============================================================================
# 5. UPLOAD DIRECTORY AUDIT
# ==============================================================================
echo "[5/5] Auditing 'Upload' directories for Executables..."

# Find directories that look like upload folders
find "$WEB_ROOT" -type d \( -name "upload*" -o -name "image*" -o -name "media" -o -name "wp-content" \) 2>/dev/null | while read -r dir; do
  # Check if they contain .php, .pl, .py, .sh
  count=$(find "$dir" -maxdepth 2 -type f \( -name "*.php" -o -name "*.pl" -o -name "*.py" -o -name "*.sh" \) 2>/dev/null | wc -l)

  if [ "$count" -gt 0 ]; then
    echo "  [RISK] Executable scripts found in content directory: $dir ($count files)"
    # List the specific files
    find "$dir" -maxdepth 2 -type f \( -name "*.php" -o -name "*.pl" -o -name "*.py" -o -name "*.sh" \) -exec echo "    -> {}" \;
  fi
done

echo "----------------------------------------------------------------"
echo "Scan Complete."

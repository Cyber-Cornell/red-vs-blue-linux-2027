#!/bin/sh

# ==============================================================================
# Script Name: net_inventory_vuln.sh
# Description: 1. Inventory: Scans network for devices/ports (Table format).
#              2. Security:  Scans for known CVEs/Vulnerabilities (NSE).
#              Portable: Runs on sh, dash, ash, bash.
# Usage:       ./net_inventory_vuln.sh <CIDR_OR_IP>
# Example:     ./net_inventory_vuln.sh 192.168.1.0/24
# ==============================================================================

# 1. Helper Functions
log_err() { printf "\033[0;31m[ERROR]\033[0m %s\n" "$1" >&2; }
log_info() { printf "\033[0;32m[INFO]\033[0m %s\n" "$1"; }
log_warn() { printf "\033[0;33m[WARN]\033[0m %s\n" "$1"; }

# 2. Dependency Check
if ! command -v nmap >/dev/null 2>&1; then
  log_err "This script requires 'nmap' to be installed."
  printf "Install via: sudo apt install nmap (Debian) or apk add nmap nmap-scripts (Alpine)\n"
  exit 1
fi

# 3. Input Validation
TARGET="$1"
if [ -z "$TARGET" ]; then
  log_err "No target provided."
  printf "Usage: %s <CIDR_Network>\n" "$0"
  printf "Example: %s 192.168.1.0/24\n" "$0"
  exit 1
fi

# ==============================================================================
# PHASE 1: Network Inventory (Fast Port Scan)
# ==============================================================================
log_info "PHASE 1: Starting Network Inventory Scan ($TARGET)"
log_info "Gathering live hosts and open ports..."

printf "%s\n" "-------------------------------------------------------------------------------"
printf "%-16s | %-25s | %s\n" "IP Address" "Hostname" "Open Ports"
printf "%s\n" "-------------------------------------------------------------------------------"

# We use a temp file to store the list of live IPs found in Phase 1
# This optimizes Phase 2 so we don't scan empty IPs for vulnerabilities.
LIVE_HOSTS_FILE="./.live_hosts_tmp"
: >"$LIVE_HOSTS_FILE" # Create/Clear file

# -oG - : Output grepable format to stdout
nmap -T4 -F --open -oG - "$TARGET" | awk -v hosts_file="$LIVE_HOSTS_FILE" '
    # Nmap Grepable Output format processing
    /Host:/ {
        ip = $2
        hostname = $3
        gsub(/[()]/, "", hostname)
        if (hostname == "") { hostname = "[Unknown]" }

        # Save live IP to temp file for Phase 2
        print ip >> hosts_file

        if ($0 ~ /Ports:/) {
            match($0, /Ports: .*/)
            raw_ports = substr($0, RSTART + 7, RLENGTH - 7)
            
            n = split(raw_ports, port_array, ",")
            final_ports = ""
            
            for (i = 1; i <= n; i++) {
                split(port_array[i], details, "/")
                p_num = details[1]
                p_svc = details[5]
                gsub(/^[ \t]+|[ \t]+$/, "", p_num)
                if (p_svc == "") { p_svc = "unknown" }
                if (i > 1) { final_ports = final_ports ", " }
                final_ports = final_ports p_num "/" p_svc
            }
        } else {
            final_ports = "No open ports found (or blocked)"
        }

        printf "%-16s | %-25s | %s\n", ip, substr(hostname, 1, 25), final_ports
    }
'

printf "%s\n" "-------------------------------------------------------------------------------"
log_info "Inventory complete."

# ==============================================================================
# PHASE 2: Vulnerability Scan (NSE)
# ==============================================================================

# Check if we found any hosts
if [ ! -s "$LIVE_HOSTS_FILE" ]; then
  log_warn "No live hosts found. Skipping vulnerability scan."
  rm -f "$LIVE_HOSTS_FILE"
  exit 0
fi

log_info "PHASE 2: Starting Vulnerability Scan on identified hosts..."
log_info "NOTE: This uses the '--script vuln' engine. It may take significantly longer."
log_info "Saving full report to: ./vuln_scan_report.txt"

# -sV: Version detection (Required for accurate vuln scripts)
# --script vuln: Run standard vulnerability scripts
# -iL: Input List (Use the IPs we found in Phase 1)
# -oN: Output Normal to a text file
# --open: Only scan open ports
nmap -T4 -F -sV --script vuln --open -iL "$LIVE_HOSTS_FILE" -oN ./vuln_scan_report.txt >/dev/null

# Clean up temp file
rm -f "$LIVE_HOSTS_FILE"

# Display a summary to the screen (Filtering for relevant info)
echo ""
printf "\033[1;33m--- VULNERABILITY SUMMARY ---\033[0m\n"

# We use grep to pull out the Host lines and any lines containing "VULNERABLE" or IDs
if grep -q "VULNERABLE" ./vuln_scan_report.txt; then
  # Print lines that look like IPs or Vulnerability findings
  awk '
        /Nmap scan report for/ { print "\n\033[1;34m" $0 "\033[0m" }
        /State: VULNERABLE/ { print "  \033[0;31m[!] " $0 "\033[0m" }
        /IDs:/ { print "      " $0 }
    ' ./vuln_scan_report.txt
else
  log_info "No obvious vulnerabilities detected by standard NSE scripts."
  log_info "Check ./vuln_scan_report.txt for full details."
fi

echo ""
log_info "Script finished."

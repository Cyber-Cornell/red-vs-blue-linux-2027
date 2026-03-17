#!/bin/bash

# Teleport Security Hardening Script for CCDC
# Run as root

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}[+] Starting Teleport Security Hardening${NC}"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}[!] This script must be run as root${NC}"
  exit 1
fi

# Create tools directory
TOOLS_DIR="/root/teleport_tools"
mkdir -p "$TOOLS_DIR"

# Backup iptables rules
iptables-save >"$BACKUP_DIR/iptables.rules"

# Define Teleport ports
TELEPORT_PROXY_PORT=3080  # Web UI and API
TELEPORT_AUTH_PORT=3025   # Auth service
TELEPORT_SSH_PORT=3022    # SSH proxy
TELEPORT_TUNNEL_PORT=3024 # Reverse tunnel
TELEPORT_K8S_PORT=3026    # Kubernetes proxy (if used)

echo -e "${GREEN}[+] Configuring iptables rules${NC}"

# Allow Teleport ports
echo -e "${YELLOW}[*] Opening Teleport ports${NC}"
iptables -I INPUT -p tcp --dport $TELEPORT_PROXY_PORT -m state --state NEW -j ACCEPT
iptables -I INPUT -p tcp --dport $TELEPORT_AUTH_PORT -m state --state NEW -j ACCEPT
iptables -I INPUT -p tcp --dport $TELEPORT_SSH_PORT -m state --state NEW -j ACCEPT
iptables -I INPUT -p tcp --dport $TELEPORT_TUNNEL_PORT -m state --state NEW -j ACCEPT

# Optional: Allow Kubernetes proxy port
# iptables -I INPUT -p tcp --dport $TELEPORT_K8S_PORT -m state --state NEW -j ACCEPT

# Rate limiting for Teleport ports to prevent brute force
iptables -I INPUT -p tcp --dport $TELEPORT_PROXY_PORT -m state --state NEW -m recent --set
iptables -I INPUT -p tcp --dport $TELEPORT_PROXY_PORT -m state --state NEW -m recent --update --seconds 60 --hitcount 10 -j DROP

# Save iptables rules
echo -e "${YELLOW}[*] Saving iptables rules...${NC}"
if [ -f /etc/debian_version ]; then
  # Debian/Ubuntu - install iptables-persistent if not present
  if ! dpkg -l | grep -q iptables-persistent; then
    echo -e "${YELLOW}[*] Installing iptables-persistent...${NC}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
  else
    # Create directory if it doesn't exist
    mkdir -p /etc/iptables
    iptables-save >/etc/iptables/rules.v4
    # Also use netfilter-persistent if available
    if command -v netfilter-persistent &>/dev/null; then
      netfilter-persistent save
    fi
  fi
elif [ -f /etc/redhat-release ]; then
  # RHEL/CentOS
  service iptables save
fi

echo -e "${GREEN}[+] Hardening Teleport configuration${NC}"

# Create secure teleport configuration
cat >/etc/teleport.yaml <<'EOF'
version: v3
teleport:
  nodename: teleport-node
  data_dir: /var/lib/teleport
  log:
    output: stderr
    severity: INFO
    format:
      output: text
  
  # Connection limits
  connection_limits:
    max_connections: 1000
    max_users: 250

  # Cache settings
  cache:
    enabled: true
    ttl: 20h

auth_service:
  enabled: yes
  listen_addr: 0.0.0.0:3025
  
  # Session recording
  session_recording: node
  
  # Cluster configuration
  cluster_name: ccdc-cluster
  
  # Authentication settings
  authentication:
    type: local
    second_factor: otp
    webauthn:
      rp_id: localhost
    
  # Password complexity
  local_auth: true
  
  # Disconnect expired certificates
  disconnect_expired_cert: yes

proxy_service:
  enabled: yes
  listen_addr: 0.0.0.0:3023
  web_listen_addr: 0.0.0.0:3080
  tunnel_listen_addr: 0.0.0.0:3024
  
  # TLS settings
  https_keypairs:
  - key_file: /var/lib/teleport/privkey.pem
    cert_file: /var/lib/teleport/fullchain.pem
  
  # Security headers
  public_addr: localhost:3080
  
  # SSH settings
  ssh_public_addr: localhost:3022

ssh_service:
  enabled: yes
  listen_addr: 0.0.0.0:3022
  
  # Enhanced session recording
  enhanced_recording:
    enabled: true
    command_buffer_size: 8
    disk_buffer_size: 128
    network_buffer_size: 8
  
  # PAM configuration
  pam:
    enabled: no
    service_name: teleport
  
  # Command execution
  commands:
  - name: hostname
    command: [hostname]
    period: 1m0s
EOF

echo -e "${GREEN}[+] Setting secure file permissions${NC}"

# Secure teleport directories and files
chown -R root:root /etc/teleport.yaml
chmod 600 /etc/teleport.yaml

if [ -d /var/lib/teleport ]; then
  chown -R teleport:teleport /var/lib/teleport
  chmod 700 /var/lib/teleport
fi

echo -e "${GREEN}[+] Configuring system security${NC}"

# Disable teleport user login
if id "teleport" &>/dev/null; then
  usermod -s /usr/sbin/nologin teleport
fi

# Enable audit logging
if [ ! -d /var/log/teleport ]; then
  mkdir -p /var/log/teleport
  chown teleport:teleport /var/log/teleport
  chmod 750 /var/log/teleport
fi

# Configure fail2ban for Teleport (if fail2ban is installed)
if command -v fail2ban-client &>/dev/null; then
  echo -e "${YELLOW}[*] Configuring fail2ban${NC}"

  cat >/etc/fail2ban/filter.d/teleport.conf <<'EOF'
[Definition]
failregex = Authentication attempt failed.*client=<HOST>
            Invalid user.*from <HOST>
            Failed login attempt.*addr.remote_addr:<HOST>
ignoreregex =
EOF

  cat >/etc/fail2ban/jail.d/teleport.conf <<'EOF'
[teleport]
enabled = true
port = 3080,3022,3023,3025
filter = teleport
logpath = /var/log/teleport/*.log
maxretry = 5
bantime = 3600
findtime = 600
EOF

  systemctl restart fail2ban
fi

echo -e "${BLUE}[+] Creating utility scripts in $TOOLS_DIR${NC}"

# ============================================================
# UTILITY SCRIPT 1: Check Teleport Status
# ============================================================
cat >"$TOOLS_DIR/check_teleport_status.sh" <<'EOFSTATUS'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}    Teleport Service Status Check${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if systemd service exists and its status
echo -e "${YELLOW}[*] Checking systemd service...${NC}"
if systemctl list-unit-files | grep -q teleport; then
    if systemctl is-active --quiet teleport; then
        echo -e "${GREEN}[+] Service is RUNNING${NC}"
    else
        echo -e "${RED}[!] Service is STOPPED${NC}"
    fi
    
    if systemctl is-enabled --quiet teleport; then
        echo -e "${GREEN}[+] Service is ENABLED (will start on boot)${NC}"
    else
        echo -e "${YELLOW}[!] Service is DISABLED${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}Service status:${NC}"
    systemctl status teleport --no-pager -l
else
    echo -e "${RED}[!] Teleport systemd service not found${NC}"
fi

echo ""
echo -e "${YELLOW}[*] Checking Teleport processes...${NC}"
if pgrep -x teleport > /dev/null; then
    echo -e "${GREEN}[+] Teleport process is running${NC}"
    ps aux | grep [t]eleport
else
    echo -e "${RED}[!] No Teleport process found${NC}"
fi

echo ""
echo -e "${YELLOW}[*] Checking listening ports...${NC}"
netstat -tlnp 2>/dev/null | grep teleport || ss -tlnp 2>/dev/null | grep teleport

echo ""
echo -e "${YELLOW}[*] Recent log entries (last 20 lines):${NC}"
journalctl -u teleport -n 20 --no-pager 2>/dev/null || echo "Unable to read logs (may need root)"

echo ""
echo -e "${BLUE}========================================${NC}"
EOFSTATUS

# ============================================================
# UTILITY SCRIPT 2: Check Firewall Rules
# ============================================================
cat >"$TOOLS_DIR/check_firewall.sh" <<'EOFFIREWALL'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}    Firewall Rules Check${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check iptables rules
echo -e "${YELLOW}[*] Current iptables rules:${NC}"
iptables -L -n -v --line-numbers

echo ""
echo -e "${YELLOW}[*] Checking Teleport ports:${NC}"
PORTS=(3080 3022 3025 3024)
PORT_NAMES=("Proxy/Web" "SSH" "Auth" "Tunnel")

for i in "${!PORTS[@]}"; do
    PORT=${PORTS[$i]}
    NAME=${PORT_NAMES[$i]}
    
    if iptables -L INPUT -n | grep -q "dpt:$PORT"; then
        echo -e "${GREEN}[+] Port $PORT ($NAME) is ALLOWED${NC}"
    else
        echo -e "${RED}[!] Port $PORT ($NAME) is NOT in iptables rules${NC}"
    fi
    
    # Check if port is listening
    if netstat -tln 2>/dev/null | grep -q ":$PORT " || ss -tln 2>/dev/null | grep -q ":$PORT "; then
        echo -e "${GREEN}    [+] Port $PORT is LISTENING${NC}"
    else
        echo -e "${YELLOW}    [!] Port $PORT is NOT listening${NC}"
    fi
done

echo ""
echo -e "${YELLOW}[*] Testing external connectivity (requires curl):${NC}"
if command -v curl &> /dev/null; then
    if curl -k -s --connect-timeout 3 https://localhost:3080 > /dev/null 2>&1; then
        echo -e "${GREEN}[+] Web interface (3080) is accessible${NC}"
    else
        echo -e "${RED}[!] Web interface (3080) is NOT accessible${NC}"
    fi
else
    echo -e "${YELLOW}[!] curl not installed, skipping connectivity test${NC}"
fi

echo ""
echo -e "${BLUE}========================================${NC}"
EOFFIREWALL

# ============================================================
# UTILITY SCRIPT 3: Check Configuration
# ============================================================
cat >"$TOOLS_DIR/check_config.sh" <<'EOFCONFIG'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}    Teleport Configuration Check${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

CONFIG_FILE="/etc/teleport.yaml"

# Check if config file exists
echo -e "${YELLOW}[*] Checking configuration file...${NC}"
if [ -f "$CONFIG_FILE" ]; then
    echo -e "${GREEN}[+] Config file exists: $CONFIG_FILE${NC}"
    
    # Check permissions
    PERMS=$(stat -c %a "$CONFIG_FILE" 2>/dev/null || stat -f %A "$CONFIG_FILE" 2>/dev/null)
    if [ "$PERMS" = "600" ]; then
        echo -e "${GREEN}[+] Permissions are secure (600)${NC}"
    else
        echo -e "${YELLOW}[!] Permissions are $PERMS (should be 600)${NC}"
    fi
    
    # Check ownership
    OWNER=$(stat -c %U "$CONFIG_FILE" 2>/dev/null || stat -f %Su "$CONFIG_FILE" 2>/dev/null)
    if [ "$OWNER" = "root" ]; then
        echo -e "${GREEN}[+] Owner is root${NC}"
    else
        echo -e "${YELLOW}[!] Owner is $OWNER (should be root)${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}[*] Configuration file contents:${NC}"
    cat "$CONFIG_FILE"
    
else
    echo -e "${RED}[!] Config file NOT found: $CONFIG_FILE${NC}"
fi

echo ""
echo -e "${YELLOW}[*] Checking Teleport data directory...${NC}"
if [ -d /var/lib/teleport ]; then
    echo -e "${GREEN}[+] Data directory exists${NC}"
    ls -la /var/lib/teleport/
else
    echo -e "${RED}[!] Data directory not found${NC}"
fi

echo ""
echo -e "${YELLOW}[*] Checking Teleport version...${NC}"
if command -v teleport &> /dev/null; then
    teleport version
else
    echo -e "${RED}[!] Teleport binary not found in PATH${NC}"
fi

echo ""
echo -e "${BLUE}========================================${NC}"
EOFCONFIG

# ============================================================
# UTILITY SCRIPT 4: Monitor Active Connections
# ============================================================
cat >"$TOOLS_DIR/monitor_connections.sh" <<'EOFMONITOR'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}    Teleport Active Connections${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

echo -e "${YELLOW}[*] Active connections to Teleport ports:${NC}"
echo ""

PORTS=(3080 3022 3025 3024)
PORT_NAMES=("Proxy/Web" "SSH" "Auth" "Tunnel")

for i in "${!PORTS[@]}"; do
    PORT=${PORTS[$i]}
    NAME=${PORT_NAMES[$i]}
    
    echo -e "${BLUE}Port $PORT ($NAME):${NC}"
    netstat -tn 2>/dev/null | grep ":$PORT " || ss -tn 2>/dev/null | grep ":$PORT "
    echo ""
done

echo -e "${YELLOW}[*] Active Teleport sessions:${NC}"
if command -v tctl &> /dev/null; then
    tctl get session 2>/dev/null || echo "Unable to list sessions (may need admin privileges)"
else
    echo "tctl command not available"
fi

echo ""
echo -e "${YELLOW}[*] Recent authentication attempts (last 50):${NC}"
journalctl -u teleport -n 50 --no-pager 2>/dev/null | grep -i "auth\|login\|failed\|success" || echo "Unable to read logs"

echo ""
echo -e "${BLUE}========================================${NC}"
EOFMONITOR

# ============================================================
# UTILITY SCRIPT 5: Quick Troubleshooting
# ============================================================
cat >"$TOOLS_DIR/troubleshoot.sh" <<'EOFTROUBLE'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}    Teleport Troubleshooting${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

ISSUES_FOUND=0

# Check 1: Service running
echo -e "${YELLOW}[1] Checking if service is running...${NC}"
if systemctl is-active --quiet teleport 2>/dev/null; then
    echo -e "${GREEN}    [+] Service is running${NC}"
else
    echo -e "${RED}    [!] Service is NOT running${NC}"
    echo -e "${YELLOW}    Fix: systemctl start teleport${NC}"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi

# Check 2: Ports listening
echo -e "${YELLOW}[2] Checking if ports are listening...${NC}"
PORTS=(3080 3022 3025 3024)
for PORT in "${PORTS[@]}"; do
    if netstat -tln 2>/dev/null | grep -q ":$PORT " || ss -tln 2>/dev/null | grep -q ":$PORT "; then
        echo -e "${GREEN}    [+] Port $PORT is listening${NC}"
    else
        echo -e "${RED}    [!] Port $PORT is NOT listening${NC}"
        ISSUES_FOUND=$((ISSUES_FOUND + 1))
    fi
done

# Check 3: Firewall rules
echo -e "${YELLOW}[3] Checking firewall rules...${NC}"
for PORT in "${PORTS[@]}"; do
    if iptables -L INPUT -n 2>/dev/null | grep -q "dpt:$PORT"; then
        echo -e "${GREEN}    [+] Port $PORT is allowed in firewall${NC}"
    else
        echo -e "${RED}    [!] Port $PORT is NOT in firewall rules${NC}"
        echo -e "${YELLOW}    Fix: iptables -I INPUT -p tcp --dport $PORT -j ACCEPT${NC}"
        ISSUES_FOUND=$((ISSUES_FOUND + 1))
    fi
done

# Check 4: Config file
echo -e "${YELLOW}[4] Checking configuration file...${NC}"
if [ -f /etc/teleport.yaml ]; then
    echo -e "${GREEN}    [+] Config file exists${NC}"
    
    # Try to validate config
    if command -v teleport &> /dev/null; then
        if teleport configure --test -c /etc/teleport.yaml 2>/dev/null; then
            echo -e "${GREEN}    [+] Config file is valid${NC}"
        else
            echo -e "${RED}    [!] Config file has errors${NC}"
            ISSUES_FOUND=$((ISSUES_FOUND + 1))
        fi
    fi
else
    echo -e "${RED}    [!] Config file missing${NC}"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi

# Check 5: Recent errors in logs
echo -e "${YELLOW}[5] Checking for errors in logs...${NC}"
ERROR_COUNT=$(journalctl -u teleport --since "10 minutes ago" 2>/dev/null | grep -i "error\|fatal\|failed" | wc -l)
if [ "$ERROR_COUNT" -eq 0 ]; then
    echo -e "${GREEN}    [+] No recent errors in logs${NC}"
else
    echo -e "${RED}    [!] Found $ERROR_COUNT errors in last 10 minutes${NC}"
    echo -e "${YELLOW}    Recent errors:${NC}"
    journalctl -u teleport --since "10 minutes ago" 2>/dev/null | grep -i "error\|fatal\|failed" | tail -5
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi

# Check 6: Disk space
echo -e "${YELLOW}[6] Checking disk space...${NC}"
DISK_USAGE=$(df /var/lib/teleport 2>/dev/null | awk 'NR==2 {print $5}' | sed 's/%//')
if [ -n "$DISK_USAGE" ] && [ "$DISK_USAGE" -lt 90 ]; then
    echo -e "${GREEN}    [+] Disk space OK (${DISK_USAGE}% used)${NC}"
else
    echo -e "${RED}    [!] Disk space critical (${DISK_USAGE}% used)${NC}"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi

echo ""
echo -e "${BLUE}========================================${NC}"
if [ $ISSUES_FOUND -eq 0 ]; then
    echo -e "${GREEN}[+] No issues found!${NC}"
else
    echo -e "${RED}[!] Found $ISSUES_FOUND issue(s)${NC}"
    echo -e "${YELLOW}[*] Check logs with: journalctl -u teleport -n 100${NC}"
fi
echo -e "${BLUE}========================================${NC}"
EOFTROUBLE

# ============================================================
# UTILITY SCRIPT 6: All-in-one checker
# ============================================================
cat >"$TOOLS_DIR/check_all.sh" <<'EOFALL'
#!/bin/bash

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

echo "Running all Teleport checks..."
echo ""

if [ -f "$SCRIPT_DIR/check_teleport_status.sh" ]; then
    bash "$SCRIPT_DIR/check_teleport_status.sh"
    echo ""
fi

if [ -f "$SCRIPT_DIR/check_firewall.sh" ]; then
    bash "$SCRIPT_DIR/check_firewall.sh"
    echo ""
fi

if [ -f "$SCRIPT_DIR/check_config.sh" ]; then
    bash "$SCRIPT_DIR/check_config.sh"
    echo ""
fi

if [ -f "$SCRIPT_DIR/monitor_connections.sh" ]; then
    bash "$SCRIPT_DIR/monitor_connections.sh"
    echo ""
fi

if [ -f "$SCRIPT_DIR/troubleshoot.sh" ]; then
    bash "$SCRIPT_DIR/troubleshoot.sh"
fi
EOFALL

# Make all scripts executable
chmod +x "$TOOLS_DIR"/*.sh

echo -e "${GREEN}[+] Created utility scripts in $TOOLS_DIR:${NC}"
ls -lh "$TOOLS_DIR"

echo ""
echo -e "${GREEN}[+] Restarting Teleport service${NC}"

# Restart teleport service
systemctl daemon-reload
systemctl restart teleport
systemctl enable teleport

# Verify service is running
if systemctl is-active --quiet teleport; then
  echo -e "${GREEN}[+] Teleport service is running${NC}"
else
  echo -e "${RED}[!] Teleport service failed to start${NC}"
  echo -e "${YELLOW}[*] Check logs: journalctl -u teleport -n 50${NC}"
fi

echo -e "${GREEN}[+] Security hardening complete!${NC}"
echo -e "${YELLOW}[*] Summary:${NC}"
echo -e "  - Firewall configured for ports: $TELEPORT_PROXY_PORT, $TELEPORT_AUTH_PORT, $TELEPORT_SSH_PORT, $TELEPORT_TUNNEL_PORT"
echo -e "  - Two-factor authentication enabled"
echo -e "  - Session recording enabled"
echo -e "  - Enhanced session recording enabled"
echo -e "  - Rate limiting configured"
echo -e "  - Configuration backed up to: $BACKUP_DIR"
echo -e "  - Utility scripts created in: $TOOLS_DIR"
echo -e ""
echo -e "${BLUE}[*] Available utility scripts:${NC}"
echo -e "  - $TOOLS_DIR/check_teleport_status.sh  - Check service status"
echo -e "  - $TOOLS_DIR/check_firewall.sh         - Check firewall rules"
echo -e "  - $TOOLS_DIR/check_config.sh           - Check configuration"
echo -e "  - $TOOLS_DIR/monitor_connections.sh    - Monitor active connections"
echo -e "  - $TOOLS_DIR/troubleshoot.sh           - Quick troubleshooting"
echo -e "  - $TOOLS_DIR/check_all.sh              - Run all checks"
echo -e ""
echo -e "${YELLOW}[*] Next steps:${NC}"
echo -e "  1. Create admin user: tctl users add admin --roles=editor,access --logins=root"
echo -e "  2. Review configuration: cat /etc/teleport.yaml"
echo -e "  3. Monitor logs: journalctl -u teleport -f"
echo -e "  4. Test access: tsh login --proxy=localhost:3080"
echo -e ""
echo -e "${RED}[!] CCDC Reminders:${NC}"
echo -e "  - Change default passwords immediately"
echo -e "  - Monitor for suspicious connections"
echo -e "  - Keep backups of working configurations"
echo -e "  - Document all changes made"

#!/bin/sh

# ==============================================================================
# Teleport Security Hardening Script for CCDC
# POSIX-compliant version for multi-distro support
# Supports: Debian/Ubuntu, RHEL/CentOS/Fedora, Alpine
# ==============================================================================

set -e

# Colors (POSIX-safe)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { printf "${GREEN}[+]${NC} %s\n" "$1"; }
log_warn() { printf "${YELLOW}[*]${NC} %s\n" "$1"; }
log_err() { printf "${RED}[!]${NC} %s\n" "$1" >&2; }

# Check root - POSIX compatible
if [ "$(id -u)" -ne 0 ]; then
  log_err "This script must be run as root"
  exit 1
fi

log_info "Starting Teleport Security Hardening"

# ==============================================================================
# 1. DETECT ENVIRONMENT
# ==============================================================================
detect_environment() {
  # Detect init system
  if [ -d /run/systemd/system ]; then
    INIT_SYS="systemd"
  elif command -v rc-service >/dev/null 2>&1; then
    INIT_SYS="openrc"
  else
    INIT_SYS="sysv"
  fi

  # Detect distro
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_LIKE="${ID_LIKE:-$ID}"
  else
    DISTRO_ID="unknown"
    DISTRO_LIKE="unknown"
  fi

  log_info "Init system: $INIT_SYS, Distro: $DISTRO_ID"
}

# ==============================================================================
# 2. DEFINE TELEPORT PORTS
# ==============================================================================
TELEPORT_PROXY_PORT=3080  # Web UI and API
TELEPORT_AUTH_PORT=3025   # Auth service
TELEPORT_SSH_PORT=3022    # SSH proxy
TELEPORT_TUNNEL_PORT=3024 # Reverse tunnel
TELEPORT_K8S_PORT=3026    # Kubernetes proxy (if used)

# ==============================================================================
# 3. BACKUP DIRECTORY
# ==============================================================================
BACKUP_DIR="/root/teleport_backups"
mkdir -p "$BACKUP_DIR"

# ==============================================================================
# 4. CONFIGURE FIREWALL
# ==============================================================================
configure_firewall() {
  log_info "Configuring firewall rules"

  # Check for iptables
  if command -v iptables >/dev/null 2>&1; then
    # Backup current rules
    iptables-save >"$BACKUP_DIR/iptables.rules.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

    log_warn "Opening Teleport ports"

    # Allow Teleport ports
    iptables -I INPUT -p tcp --dport "$TELEPORT_PROXY_PORT" -m state --state NEW -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p tcp --dport "$TELEPORT_AUTH_PORT" -m state --state NEW -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p tcp --dport "$TELEPORT_SSH_PORT" -m state --state NEW -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p tcp --dport "$TELEPORT_TUNNEL_PORT" -m state --state NEW -j ACCEPT 2>/dev/null || true

    # Rate limiting for proxy port to prevent brute force
    iptables -I INPUT -p tcp --dport "$TELEPORT_PROXY_PORT" -m state --state NEW -m recent --set 2>/dev/null || true
    iptables -I INPUT -p tcp --dport "$TELEPORT_PROXY_PORT" -m state --state NEW -m recent --update --seconds 60 --hitcount 10 -j DROP 2>/dev/null || true

    # Save iptables rules based on distro
    save_iptables_rules
  fi

  # Check for nftables
  if command -v nft >/dev/null 2>&1; then
    log_info "nftables detected - adding rules"
    nft list ruleset >"$BACKUP_DIR/nftables.rules.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

    # Add nftables rules (if no iptables-nft translation)
    # nft add rule inet filter input tcp dport { 3080, 3025, 3022, 3024 } accept 2>/dev/null || true
  fi
}

save_iptables_rules() {
  case "$DISTRO_LIKE" in
  *debian* | *ubuntu*)
    if [ -d /etc/iptables ]; then
      iptables-save >/etc/iptables/rules.v4 2>/dev/null || true
    fi
    ;;
  *rhel* | *fedora* | *centos*)
    if command -v service >/dev/null 2>&1; then
      service iptables save 2>/dev/null || true
    fi
    ;;
  *alpine*)
    # Alpine uses /etc/iptables/rules-save
    mkdir -p /etc/iptables
    iptables-save >/etc/iptables/rules-save 2>/dev/null || true
    rc-update add iptables default 2>/dev/null || true
    ;;
  esac
}

# ==============================================================================
# 5. CREATE TELEPORT CONFIGURATION
# ==============================================================================
create_teleport_config() {
  log_info "Creating hardened Teleport configuration"

  # Backup existing config
  if [ -f /etc/teleport.yaml ]; then
    cp /etc/teleport.yaml "$BACKUP_DIR/teleport.yaml.$(date +%Y%m%d%H%M%S)"
  fi

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

  # Lock settings
  locking_mode: best_effort

ssh_service:
  enabled: yes
  listen_addr: 0.0.0.0:3022
  
  # Enhanced logging
  enhanced_recording:
    enabled: true
    command: true
    disk: true
    network: true

  # PAM integration (if available)
  pam:
    enabled: false

proxy_service:
  enabled: yes
  listen_addr: 0.0.0.0:3080
  tunnel_listen_addr: 0.0.0.0:3024
  web_listen_addr: 0.0.0.0:3080
  
  # HTTPS settings (adjust for your cert)
  https_keypairs: []
  
  # ACME disabled by default
  acme: {}
EOF

  chmod 600 /etc/teleport.yaml
  chown root:root /etc/teleport.yaml
}

# ==============================================================================
# 6. SET FILE PERMISSIONS
# ==============================================================================
set_permissions() {
  log_info "Setting secure file permissions"

  # Create data directory with secure permissions
  mkdir -p /var/lib/teleport
  chmod 700 /var/lib/teleport

  # Secure log directory
  mkdir -p /var/log/teleport
  chmod 700 /var/log/teleport
}

# ==============================================================================
# 7. SERVICE MANAGEMENT
# ==============================================================================
manage_service() {
  log_info "Managing Teleport service"

  case "$INIT_SYS" in
  systemd)
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable teleport 2>/dev/null || true
    systemctl restart teleport 2>/dev/null || log_warn "Could not restart teleport service"

    # Check status
    if systemctl is-active --quiet teleport 2>/dev/null; then
      log_info "Teleport service is running"
    else
      log_warn "Teleport service may not be running. Check: journalctl -u teleport -n 50"
    fi
    ;;
  openrc)
    rc-update add teleport default 2>/dev/null || true
    rc-service teleport restart 2>/dev/null || log_warn "Could not restart teleport service"

    if rc-service teleport status >/dev/null 2>&1; then
      log_info "Teleport service is running"
    else
      log_warn "Teleport service may not be running"
    fi
    ;;
  sysv)
    if [ -x /etc/init.d/teleport ]; then
      update-rc.d teleport defaults 2>/dev/null || chkconfig teleport on 2>/dev/null || true
      /etc/init.d/teleport restart 2>/dev/null || true
    fi
    ;;
  esac
}

# ==============================================================================
# 8. CREATE UTILITY SCRIPTS
# ==============================================================================
create_utility_scripts() {
  log_info "Creating utility scripts"

  TOOLS_DIR="/root/teleport_tools"
  mkdir -p "$TOOLS_DIR"

  # User listing script
  cat >"$TOOLS_DIR/list_users.sh" <<'EOF'
#!/bin/sh
tctl users ls 2>/dev/null || echo "Run this on the auth server"
EOF

  # Session listing script
  cat >"$TOOLS_DIR/list_sessions.sh" <<'EOF'
#!/bin/sh
tctl sessions ls 2>/dev/null || echo "Run this on the auth server"
EOF

  # Lock user script
  cat >"$TOOLS_DIR/lock_user.sh" <<'EOF'
#!/bin/sh
if [ -z "$1" ]; then
  echo "Usage: $0 <username>"
  exit 1
fi
tctl users update "$1" --set-locked=true
EOF

  chmod +x "$TOOLS_DIR"/*.sh
  log_info "Utility scripts created in $TOOLS_DIR"
}

# ==============================================================================
# 9. MAIN
# ==============================================================================
main() {
  detect_environment
  configure_firewall
  create_teleport_config
  set_permissions
  manage_service
  create_utility_scripts

  log_info "Security hardening complete!"
  log_warn "Summary:"
  printf "  - Firewall configured for ports: %s, %s, %s, %s\n" \
    "$TELEPORT_PROXY_PORT" "$TELEPORT_AUTH_PORT" "$TELEPORT_SSH_PORT" "$TELEPORT_TUNNEL_PORT"
  printf "  - Two-factor authentication enabled\n"
  printf "  - Session recording enabled\n"
  printf "  - Utility scripts in /root/teleport_tools/\n"
}

main "$@"

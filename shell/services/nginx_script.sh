#!/bin/sh

# ==============================================================================
# Nginx Security Hardening Script
# Supports: Debian/Ubuntu, RHEL/CentOS/Fedora, Alpine, Arch
# Init Systems: systemd, OpenRC, SysVinit
# ==============================================================================

set -e

LOG_FILE="./nginx_hardening.log"

log_info() { printf "[INFO] %s\n" "$1"; }
log_warn() { printf "\033[0;33m[WARN]\033[0m %s\n" "$1"; }
log_err() { printf "\033[0;31m[ERROR]\033[0m %s\n" "$1" >&2; }

if [ "$(id -u)" -ne 0 ]; then
  log_err "This script must be run as root."
  exit 1
fi

# ==============================================================================
# 1. DETECT INIT SYSTEM
# ==============================================================================
detect_init_system() {
  if [ -d /run/systemd/system ]; then
    INIT_SYS="systemd"
  elif command -v rc-service >/dev/null 2>&1; then
    INIT_SYS="openrc"
  elif [ -d /etc/init.d ]; then
    INIT_SYS="sysv"
  else
    INIT_SYS="unknown"
  fi
  log_info "Detected init system: $INIT_SYS"
}

# ==============================================================================
# 2. DETECT DISTRO AND NGINX USER
# ==============================================================================
detect_distro() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_LIKE="${ID_LIKE:-$ID}"
  else
    DISTRO_ID="unknown"
    DISTRO_LIKE="unknown"
  fi
  log_info "Detected distro: $DISTRO_ID (family: $DISTRO_LIKE)"

  # Set nginx user based on distro
  case "$DISTRO_LIKE" in
  *debian* | *ubuntu*)
    NGINX_USER="www-data"
    NGINX_GROUP="www-data"
    ;;
  *rhel* | *fedora* | *centos*)
    NGINX_USER="nginx"
    NGINX_GROUP="nginx"
    ;;
  *alpine*)
    NGINX_USER="nginx"
    NGINX_GROUP="nginx"
    ;;
  *arch*)
    NGINX_USER="http"
    NGINX_GROUP="http"
    ;;
  *suse*)
    NGINX_USER="nginx"
    NGINX_GROUP="nginx"
    ;;
  *)
    NGINX_USER="www-data"
    NGINX_GROUP="www-data"
    log_warn "Unknown distro, defaulting to www-data user"
    ;;
  esac
}

# ==============================================================================
# 3. SERVICE MANAGEMENT FUNCTIONS
# ==============================================================================
nginx_reload() {
  log_info "Reloading nginx..."
  case "$INIT_SYS" in
  systemd)
    systemctl reload nginx 2>/dev/null || systemctl restart nginx
    ;;
  openrc)
    rc-service nginx reload 2>/dev/null || rc-service nginx restart
    ;;
  sysv)
    if [ -x /etc/init.d/nginx ]; then
      /etc/init.d/nginx reload 2>/dev/null || /etc/init.d/nginx restart
    else
      nginx -s reload
    fi
    ;;
  *)
    nginx -s reload
    ;;
  esac
}

nginx_test_config() {
  log_info "Testing nginx configuration..."
  if nginx -t 2>&1; then
    log_info "Nginx configuration is valid."
    return 0
  else
    log_err "Nginx configuration test failed!"
    return 1
  fi
}

# ==============================================================================
# 4. CREATE USER IF NOT EXISTS
# ==============================================================================
ensure_nginx_user() {
  if ! id "$NGINX_USER" >/dev/null 2>&1; then
    log_info "Creating nginx user: $NGINX_USER"

    if command -v useradd >/dev/null 2>&1; then
      # Standard Linux
      groupadd -r "$NGINX_GROUP" 2>/dev/null || true
      useradd -r -g "$NGINX_GROUP" -d /var/cache/nginx -s /sbin/nologin "$NGINX_USER" 2>/dev/null || true
    elif command -v adduser >/dev/null 2>&1; then
      # Alpine/BusyBox
      addgroup -S "$NGINX_GROUP" 2>/dev/null || true
      adduser -S -G "$NGINX_GROUP" -h /var/cache/nginx -s /sbin/nologin "$NGINX_USER" 2>/dev/null || true
    fi
  fi

  # Verify user is not root
  if [ "$(id -u "$NGINX_USER" 2>/dev/null)" = "0" ]; then
    log_err "$NGINX_USER is running as root! This is a security risk."
    exit 1
  fi

  # Lock the account
  if command -v passwd >/dev/null 2>&1; then
    passwd -l "$NGINX_USER" >/dev/null 2>&1 || true
  fi
}

# ==============================================================================
# 5. CONFIGURE FIREWALL
# ==============================================================================
configure_firewall() {
  log_info "Configuring firewall for HTTP/HTTPS..."

  if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
    iptables -I OUTPUT -p tcp --sport 80 -j ACCEPT 2>/dev/null || true
    iptables -I OUTPUT -p tcp --sport 443 -j ACCEPT 2>/dev/null || true
  fi

  if command -v nft >/dev/null 2>&1; then
    # nftables support (newer systems)
    log_info "nftables detected - configure manually if needed"
  fi
}

# ==============================================================================
# 6. FIND NGINX CONFIG
# ==============================================================================
find_nginx_config() {
  for config in /etc/nginx/nginx.conf /usr/local/nginx/conf/nginx.conf /opt/nginx/conf/nginx.conf; do
    if [ -f "$config" ]; then
      NGINX_CONF="$config"
      NGINX_DIR="$(dirname "$config")"
      log_info "Found nginx config: $NGINX_CONF"
      return 0
    fi
  done
  log_err "Nginx configuration file not found!"
  exit 1
}

# ==============================================================================
# 7. HARDEN NGINX CONFIGURATION
# ==============================================================================
harden_nginx() {
  log_info "Hardening nginx configuration..."

  # Backup original config
  cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date +%Y%m%d%H%M%S)"

  # Set nginx user in config
  if grep -q "^user" "$NGINX_CONF"; then
    sed -i "s/^user.*/user $NGINX_USER;/" "$NGINX_CONF"
  else
    sed -i "1iuser $NGINX_USER;" "$NGINX_CONF"
  fi

  # Disable server_tokens
  if grep -q "server_tokens" "$NGINX_CONF"; then
    sed -i 's/server_tokens.*/server_tokens off;/' "$NGINX_CONF"
  else
    # Add to http block
    sed -i '/http.*{/a\    server_tokens off;' "$NGINX_CONF"
  fi

  # Disable core dumps
  if ! grep -q "worker_rlimit_core" "$NGINX_CONF"; then
    sed -i '1iworker_rlimit_core 0;' "$NGINX_CONF"
  fi

  # Set secure permissions
  chown -R root:root "$NGINX_DIR"
  chmod 600 "$NGINX_CONF"
  chmod -R o-w "$NGINX_DIR"
  chmod -R g-w "$NGINX_DIR"

  # Set PID file permissions if exists
  if [ -f /run/nginx.pid ]; then
    chown root:root /run/nginx.pid
    chmod 644 /run/nginx.pid
  fi
}

# ==============================================================================
# 8. ADD SECURITY HEADERS
# ==============================================================================
add_security_headers() {
  log_info "Adding security headers..."

  HEADERS_FILE="$NGINX_DIR/conf.d/security_headers.conf"
  mkdir -p "$NGINX_DIR/conf.d"

  cat >"$HEADERS_FILE" <<'EOF'
# Security Headers Configuration
# Include this file in your server blocks

# Prevent MIME type sniffing
add_header X-Content-Type-Options "nosniff" always;

# Clickjacking protection
add_header X-Frame-Options "SAMEORIGIN" always;

# XSS Protection
add_header X-XSS-Protection "1; mode=block" always;

# Referrer Policy
add_header Referrer-Policy "strict-origin-when-cross-origin" always;

# Content Security Policy (adjust as needed)
# add_header Content-Security-Policy "default-src 'self';" always;

# Permissions Policy
add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
EOF

  chmod 644 "$HEADERS_FILE"
  log_warn "Security headers file created at $HEADERS_FILE"
  log_warn "Include it in your server blocks: include conf.d/security_headers.conf;"
}

# ==============================================================================
# 9. MAIN EXECUTION
# ==============================================================================
main() {
  log_info "Starting Nginx Security Hardening..."

  detect_init_system
  detect_distro
  find_nginx_config
  ensure_nginx_user
  configure_firewall
  harden_nginx
  add_security_headers

  # Test and reload
  if nginx_test_config; then
    nginx_reload
    log_info "Nginx hardening complete!"
  else
    log_err "Configuration invalid. Restoring backup..."
    cp "${NGINX_CONF}.bak."* "$NGINX_CONF" 2>/dev/null || true
    exit 1
  fi

  # Print listening ports
  log_info "Nginx listening ports:"
  grep -ir "listen[^;]*;" "$NGINX_DIR" 2>/dev/null || true
}

main "$@"

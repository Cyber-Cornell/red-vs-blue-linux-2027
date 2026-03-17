#!/bin/sh
# ==============================================================================
# Audit Configuration Script
# Supports: Linux (auditd), Solaris (BSM audit)
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log_info() { printf "\033[0;32m[INFO]\033[0m %s\n" "$1"; }
log_warn() { printf "\033[0;33m[WARN]\033[0m %s\n" "$1"; }
log_err() { printf "\033[0;31m[ERROR]\033[0m %s\n" "$1" >&2; }

if [ "$(id -u)" -ne 0 ]; then
  log_err "This script must be run as root."
  exit 1
fi

# Detect OS
OS_TYPE="linux"
case "$(uname -s)" in
SunOS) OS_TYPE="solaris" ;;
esac

# Detect init system
if [ -d /run/systemd/system ]; then
  INIT_SYS="systemd"
elif command -v svcadm >/dev/null 2>&1; then
  INIT_SYS="smf"
elif command -v rc-service >/dev/null 2>&1; then
  INIT_SYS="openrc"
else
  INIT_SYS="sysv"
fi

log_info "Starting audit configuration..."
log_info "Detected: $OS_TYPE / $INIT_SYS"

# ==============================================================================
# SOLARIS BSM AUDIT
# ==============================================================================
configure_solaris_audit() {
  log_info "Configuring Solaris BSM Audit..."

  AUDIT_CONTROL="/etc/security/audit_control"

  [ -f "$AUDIT_CONTROL" ] && cp "$AUDIT_CONTROL" "${AUDIT_CONTROL}.bak"

  cat >"$AUDIT_CONTROL" <<'EOF'
dir:/var/audit
flags:lo,ad,ex,fm,fw,fr
minfree:20
naflags:lo,ad
plugin:name=audit_binfile.so; p_dir=/var/audit; p_fsize=4M; p_minfree=1
EOF

  chmod 640 "$AUDIT_CONTROL"
  mkdir -p /var/audit
  chmod 750 /var/audit

  if svcs -a 2>/dev/null | grep -q "auditd"; then
    svcadm enable system/auditd
    svcadm refresh system/auditd
  else
    /usr/sbin/audit -s
  fi

  log_info "Solaris BSM audit configured"
}

# ==============================================================================
# LINUX AUDITD
# ==============================================================================
configure_linux_auditd() {
  log_info "Configuring Linux auditd..."

  mkdir -p /etc/audit
  mkdir -p /etc/audit/rules.d
  mkdir -p /var/log/audit

  # Apply configs from configs directory
  if [ -f "$SCRIPT_DIR/configs/auditd.conf" ]; then
    log_info "Using configs/auditd.conf"
    cat "$SCRIPT_DIR/configs/auditd.conf" >/etc/audit/auditd.conf
  else
    log_err "configs/auditd.conf not found!"
    exit 1
  fi

  if [ -f "$SCRIPT_DIR/configs/audit.rules" ]; then
    log_info "Using configs/audit.rules"
    cat "$SCRIPT_DIR/configs/audit.rules" >/etc/audit/audit.rules
    cat "$SCRIPT_DIR/configs/audit.rules" >/etc/audit/rules.d/99-ccdc.rules
  else
    log_err "configs/audit.rules not found!"
    exit 1
  fi

  chmod 640 /etc/audit/auditd.conf
  chmod 640 /etc/audit/audit.rules
  chmod 640 /etc/audit/rules.d/99-ccdc.rules

  # Enable audit
  if command -v auditctl >/dev/null 2>&1; then
    auditctl -e 1
    augenrules --load 2>/dev/null || auditctl -R /etc/audit/audit.rules
  fi

  # Restart service
  case "$INIT_SYS" in
  systemd)
    systemctl enable auditd
    # auditd doesn't like systemctl restart
    service auditd restart 2>/dev/null || systemctl restart auditd
    ;;
  openrc)
    rc-update add auditd default
    rc-service auditd restart
    ;;
  sysv)
    [ -x /etc/init.d/auditd ] && /etc/init.d/auditd restart
    ;;
  esac

  log_info "Linux auditd configured"
}

# ==============================================================================
# MAIN
# ==============================================================================
case "$OS_TYPE" in
solaris)
  configure_solaris_audit
  ;;
linux)
  configure_linux_auditd
  ;;
esac

log_info "Audit configuration complete!"

#!/bin/sh
# ==============================================================================
# Rsyslog Configuration Script
# Supports: Linux (all distros), Solaris/illumos
# Uses configs/rsyslog.conf when available
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source detection library
if [ -f "$SCRIPT_DIR/lib/detect.sh" ]; then
  . "$SCRIPT_DIR/lib/detect.sh"
else
  case "$(uname -s)" in
  SunOS) OS_TYPE="solaris" ;;
  Linux) OS_TYPE="linux" ;;
  esac

  if [ -d /run/systemd/system ]; then
    INIT_SYS="systemd"
  elif command -v svcadm >/dev/null 2>&1; then
    INIT_SYS="smf"
  elif command -v rc-service >/dev/null 2>&1; then
    INIT_SYS="openrc"
  else
    INIT_SYS="sysv"
  fi
fi

log_info() { printf "\033[0;32m[INFO]\033[0m %s\n" "$1"; }
log_warn() { printf "\033[0;33m[WARN]\033[0m %s\n" "$1"; }
log_err() { printf "\033[0;31m[ERROR]\033[0m %s\n" "$1" >&2; }

if [ "$(id -u)" -ne 0 ]; then
  log_err "This script must be run as root."
  exit 1
fi

log_info "Starting rsyslog configuration..."
log_info "Detected OS: $OS_TYPE, Init: $INIT_SYS"

# ==============================================================================
# SOLARIS SYSLOG
# ==============================================================================
configure_solaris_syslog() {
  log_info "Configuring Solaris syslog..."

  SYSLOG_CONF="/etc/syslog.conf"

  if [ -f "$SYSLOG_CONF" ]; then
    cp "$SYSLOG_CONF" "${SYSLOG_CONF}.bak.$(date +%Y%m%d%H%M%S)"
  fi

  cat >"$SYSLOG_CONF" <<'EOF'
# Solaris syslog configuration
*.err;kern.notice;auth.notice                   /dev/sysmsg
*.err;kern.debug;daemon.notice;mail.crit        /var/adm/messages

*.alert;kern.err;daemon.err                     operator
*.alert                                         root

*.emerg                                         *

auth.info                                       /var/log/authlog
mail.debug                                      /var/log/syslog
daemon.info                                     /var/log/daemon.log

# Log all auth messages
auth.*;authpriv.*                               /var/log/auth.log
EOF

  chmod 644 "$SYSLOG_CONF"

  # Create log directories
  mkdir -p /var/log
  touch /var/log/authlog /var/log/auth.log /var/log/daemon.log

  # Restart syslog via SMF
  log_info "Restarting Solaris syslog service..."
  if svcs -a 2>/dev/null | grep -q "system-log"; then
    svcadm restart system-log || svcadm restart svc:/system/system-log:default || true
  fi

  log_info "Solaris syslog configuration complete"
}

# ==============================================================================
# LINUX RSYSLOG - Uses configs/rsyslog.conf
# ==============================================================================
configure_linux_rsyslog() {
  log_info "Configuring Linux rsyslog..."

  RSYSLOG_CONF="/etc/rsyslog.conf"

  # Check if rsyslog is installed
  if ! command -v rsyslogd >/dev/null 2>&1; then
    log_err "rsyslogd binary not found. Is rsyslog installed?"
    exit 1
  fi

  # Backup existing config
  if [ -f "$RSYSLOG_CONF" ]; then
    cp "$RSYSLOG_CONF" "${RSYSLOG_CONF}.bak.$(date +%Y%m%d%H%M%S)"
  fi

  # Apply rsyslog.conf from configs directory
  if [ -f "$SCRIPT_DIR/configs/rsyslog.conf" ]; then
    log_info "Using configs/rsyslog.conf"
    cat "$SCRIPT_DIR/configs/rsyslog.conf" >"$RSYSLOG_CONF"
  else
    log_err "configs/rsyslog.conf not found!"
    exit 1
  fi

  chmod 644 "$RSYSLOG_CONF"

  # Create necessary directories and log files
  mkdir -p /var/lib/rsyslog
  mkdir -p /var/log
  touch /var/log/auth.log /var/log/syslog /var/log/kern.log \
    /var/log/mail.log /var/log/cron.log /var/log/daemon.log /var/log/user.log
  chmod 640 /var/log/*.log

  # Restart rsyslog
  SERVICE="rsyslog"

  case "$INIT_SYS" in
  systemd)
    systemctl enable "$SERVICE"
    systemctl restart "$SERVICE"

    if systemctl is-active --quiet "$SERVICE"; then
      log_info "rsyslog service is active"
    else
      log_err "rsyslog service failed to start"
    fi
    ;;
  openrc)
    rc-update add "$SERVICE" default
    rc-service "$SERVICE" restart
    ;;
  sysv)
    if command -v update-rc.d >/dev/null 2>&1; then
      update-rc.d "$SERVICE" defaults
    elif command -v chkconfig >/dev/null 2>&1; then
      chkconfig "$SERVICE" on
    fi
    "/etc/init.d/$SERVICE" restart
    ;;
  esac

  log_info "Linux rsyslog configuration complete"
}

# ==============================================================================
# MAIN
# ==============================================================================
main() {
  case "$OS_TYPE" in
  solaris)
    configure_solaris_syslog
    ;;
  linux)
    configure_linux_rsyslog
    ;;
  *)
    log_err "Unsupported OS: $OS_TYPE"
    exit 1
    ;;
  esac

  log_info "Rsyslog configuration complete!"
}

main "$@"

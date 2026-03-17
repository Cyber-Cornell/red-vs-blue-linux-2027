#!/bin/sh
# ==============================================================================
# Journald Configuration Script
# Supports: Linux (systemd), Solaris (skipped), NodeOS (skipped)
# Uses configs/journald.conf when available
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

log_info "Starting journald configuration..."

SERVICE="systemd-journald"

# ==============================================================================
# SYSTEMD JOURNALD
# ==============================================================================
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  log_info "Detected Init System: Systemd"

  JOURNALD_CONF="/etc/systemd/journald.conf"

  # Backup existing config
  if [ -f "$JOURNALD_CONF" ]; then
    cp "$JOURNALD_CONF" "${JOURNALD_CONF}.bak.$(date +%Y%m%d%H%M%S)"
  fi

  # Apply journald.conf from configs directory
  if [ -f "$SCRIPT_DIR/configs/journald.conf" ]; then
    log_info "Using configs/journald.conf"
    cat "$SCRIPT_DIR/configs/journald.conf" >"$JOURNALD_CONF"
  else
    log_err "configs/journald.conf not found!"
    exit 1
  fi

  chmod 644 "$JOURNALD_CONF"

  # Create persistent journal directory
  mkdir -p /var/log/journal
  systemd-tmpfiles --create --prefix /var/log/journal 2>/dev/null || true

  log_info "Ensuring $SERVICE is active..."
  systemctl enable "$SERVICE" 2>/dev/null || true

  log_info "Restarting $SERVICE..."
  if systemctl restart "$SERVICE"; then
    :
  else
    log_err "Failed to restart $SERVICE."
  fi

  log_info "Flushing journal to disk..."
  if systemctl kill --kill-who=main --signal=SIGUSR1 "$SERVICE" 2>/dev/null; then
    :
  else
    journalctl --flush 2>/dev/null || true
  fi

  # Verify
  if systemctl is-active --quiet "$SERVICE"; then
    log_info "Verification: $SERVICE is active and running."
  else
    log_err "Verification: $SERVICE is NOT active."
    exit 1
  fi

# ==============================================================================
# OPENRC (Alpine / Gentoo) - No journald
# ==============================================================================
elif command -v rc-service >/dev/null 2>&1; then
  log_info "Detected Init System: OpenRC"
  log_warn "Systemd-journald is specific to Systemd."
  log_warn "OpenRC systems usually use 'rsyslog' or 'syslog-ng'."
  log_warn "Skipping journald configuration."

# ==============================================================================
# SOLARIS - No journald
# ==============================================================================
elif [ "$OS_TYPE" = "solaris" ]; then
  log_info "Detected OS: Solaris"
  log_warn "Solaris does not use systemd-journald."
  log_warn "Solaris uses syslog. Skipping journald configuration."

else
  log_err "Could not detect Systemd or OpenRC."
fi

log_info "Journald operation complete."

#!/bin/sh
# =============================================================================
# CCDC System Restore Script
# POSIX-compliant, distro-agnostic
#
# Usage:
#   restore.sh list  <archive>     Show archive contents
#   restore.sh all   <archive>     Full restore (files + databases + firewall)
#   restore.sh files <archive>     Restore filesystem only
#   restore.sh db    <archive>     Restore databases only
#   restore.sh fw    <archive>     Restore firewall rules only
# =============================================================================

set -eu

# =============================================================================
# HELPERS
# =============================================================================

log_msg() {
  printf '[RESTORE] %s\n' "$1"
}

log_err() {
  printf '[RESTORE] ERROR: %s\n' "$1" >&2
}

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
  fi
}

# =============================================================================
# DETECT DECOMPRESSOR
# =============================================================================

detect_decompressor() {
  _file="$1"
  case "$_file" in
  *.tar.zst | *.tzst)
    if command -v zstd >/dev/null 2>&1; then
      echo "zstd -dc"
    else
      log_err "zstd not found. Install it to decompress this archive."
      exit 1
    fi
    ;;
  *.tar.lz4)
    if command -v lz4 >/dev/null 2>&1; then
      echo "lz4 -dc"
    else
      log_err "lz4 not found. Install it to decompress this archive."
      exit 1
    fi
    ;;
  *.tar.xz | *.txz)
    if command -v xz >/dev/null 2>&1; then
      echo "xz -dc"
    else
      log_err "xz not found. Install it to decompress this archive."
      exit 1
    fi
    ;;
  *.tar.bz2 | *.tbz2)
    if command -v bzip2 >/dev/null 2>&1; then
      echo "bzip2 -dc"
    else
      log_err "bzip2 not found."
      exit 1
    fi
    ;;
  *.tar.gz | *.tgz)
    if command -v pigz >/dev/null 2>&1; then
      echo "pigz -dc"
    else
      echo "gzip -dc"
    fi
    ;;
  *.tar)
    echo "cat"
    ;;
  *)
    log_msg "Unknown extension, trying gzip..."
    echo "gzip -dc"
    ;;
  esac
}

# =============================================================================
# TAR FEATURE DETECTION
# =============================================================================

detect_tar_flags() {
  TAR_RESTORE=""
  _tar_help=$(tar --help 2>&1 || true)
  echo "$_tar_help" | grep -q '\-\-numeric-owner' && TAR_RESTORE="${TAR_RESTORE} --numeric-owner"
  echo "$_tar_help" | grep -q '\-\-acls' && TAR_RESTORE="${TAR_RESTORE} --acls"
  echo "$_tar_help" | grep -q '\-\-xattrs' && TAR_RESTORE="${TAR_RESTORE} --xattrs"
  echo "$_tar_help" | grep -q '\-\-selinux' && TAR_RESTORE="${TAR_RESTORE} --selinux"
}

# =============================================================================
# LIST
# =============================================================================

do_list() {
  log_msg "Listing contents of: ${ARCHIVE}"
  $DECOMPRESS "$ARCHIVE" 2>/dev/null | tar -tf - 2>/dev/null
}

# =============================================================================
# RESTORE FILES
# =============================================================================

do_restore_files() {
  log_msg "Restoring filesystem from: ${ARCHIVE}"
  log_msg "Extracting to / ..."

  # shellcheck disable=SC2086
  $DECOMPRESS "$ARCHIVE" 2>/dev/null |
    tar -xpf - -C / ${TAR_RESTORE} 2>/dev/null

  log_msg "Filesystem restore complete."

  log_msg ""
  log_msg ">>> Post-restore checklist:"
  log_msg "  - Verify /etc/passwd and /etc/shadow are correct"
  log_msg "  - Verify /etc/ssh/sshd_config is correct"
  log_msg "  - Check service configs in /etc/"
  log_msg ""
  log_msg ">>> Services that may need restart:"

  for _svc in sshd ssh nginx apache2 httpd mysql mariadb postgresql \
    named bind9 postfix dovecot vsftpd smbd nmbd docker \
    kubelet php-fpm tomcat jenkins gitea teleport splunk \
    snmpd nagios zabbix-agent; do
    if command -v systemctl >/dev/null 2>&1; then
      if systemctl list-unit-files 2>/dev/null | grep -q "^${_svc}"; then
        log_msg "    systemctl restart ${_svc}"
      fi
    elif [ -f "/etc/init.d/${_svc}" ]; then
      log_msg "    /etc/init.d/${_svc} restart"
    fi
  done
}

# =============================================================================
# RESTORE DATABASES
# =============================================================================

do_restore_db() {
  log_msg "Restoring databases from: ${ARCHIVE}"

  $DECOMPRESS "$ARCHIVE" 2>/dev/null |
    tar -xpf - -C / 'backups/db_dumps' 2>/dev/null || true

  _dump_dir="/backups/db_dumps"
  _restored=0

  if [ ! -d "$_dump_dir" ]; then
    log_err "No database dumps found in archive."
    return 1
  fi

  # --- MySQL / MariaDB ---
  for _dump in "${_dump_dir}"/mysql*.sql*; do
    [ -f "$_dump" ] || continue

    if ! command -v mysql >/dev/null 2>&1; then
      log_err "MySQL dump found but 'mysql' client not installed. Skipping."
      log_msg "  Dump saved at: ${_dump}"
      continue
    fi

    log_msg "Importing MySQL dump: ${_dump}"
    mysql -e "STOP SLAVE; SET GLOBAL read_only = OFF;" 2>/dev/null || true

    if mysql <"$_dump" 2>/dev/null; then
      log_msg "  MySQL import successful."
      _restored=$((_restored + 1))
    else
      log_err "  MySQL import failed."
      log_msg "  Dump preserved at: ${_dump}"
    fi
  done

  # --- PostgreSQL ---
  for _dump in "${_dump_dir}"/postgres*.sql*; do
    [ -f "$_dump" ] || continue

    if ! command -v psql >/dev/null 2>&1; then
      log_err "PostgreSQL dump found but 'psql' not installed. Skipping."
      log_msg "  Dump saved at: ${_dump}"
      continue
    fi

    log_msg "Importing PostgreSQL dump: ${_dump}"

    if su - postgres -c "psql" <"$_dump" 2>/dev/null; then
      log_msg "  PostgreSQL import successful."
      _restored=$((_restored + 1))
    else
      log_err "  PostgreSQL import failed."
      log_msg "  Dump preserved at: ${_dump}"
    fi
  done

  if [ "$_restored" -eq 0 ]; then
    log_msg "No databases were imported."
    log_msg "  Dump files preserved at: ${_dump_dir}/"
  else
    log_msg "Restored ${_restored} database(s)."
  fi
}

# =============================================================================
# RESTORE FIREWALL
# =============================================================================

do_restore_fw() {
  log_msg "Restoring firewall rules from: ${ARCHIVE}"

  $DECOMPRESS "$ARCHIVE" 2>/dev/null |
    tar -xpf - -C / \
      'backups/fw_iptables.rules' \
      'backups/fw_ip6tables.rules' \
      'backups/fw_nftables.rules' \
      2>/dev/null || true

  _fw_dir="/backups"
  _restored=0

  # --- nftables ---
  if [ -f "${_fw_dir}/fw_nftables.rules" ]; then
    if command -v nft >/dev/null 2>&1; then
      log_msg "Applying nftables rules..."
      if nft -f "${_fw_dir}/fw_nftables.rules" 2>/dev/null; then
        log_msg "  nftables rules applied."
        _restored=$((_restored + 1))
      else
        log_err "  nftables restore failed."
      fi
    else
      log_msg "  nftables rules found but 'nft' not installed."
      log_msg "  Rules saved at: ${_fw_dir}/fw_nftables.rules"
    fi
  fi

  # --- iptables ---
  if [ -f "${_fw_dir}/fw_iptables.rules" ]; then
    if command -v iptables-restore >/dev/null 2>&1; then
      log_msg "Applying iptables rules..."
      if iptables-restore <"${_fw_dir}/fw_iptables.rules" 2>/dev/null; then
        log_msg "  iptables rules applied."
        _restored=$((_restored + 1))
      else
        log_err "  iptables restore failed."
      fi
    else
      log_msg "  iptables rules found but 'iptables-restore' not installed."
    fi
  fi

  # --- ip6tables ---
  if [ -f "${_fw_dir}/fw_ip6tables.rules" ]; then
    if command -v ip6tables-restore >/dev/null 2>&1; then
      log_msg "Applying ip6tables rules..."
      if ip6tables-restore <"${_fw_dir}/fw_ip6tables.rules" 2>/dev/null; then
        log_msg "  ip6tables rules applied."
        _restored=$((_restored + 1))
      else
        log_err "  ip6tables restore failed."
      fi
    else
      log_msg "  ip6tables rules found but 'ip6tables-restore' not installed."
    fi
  fi

  if [ "$_restored" -eq 0 ]; then
    log_err "No firewall rules were restored."
  else
    log_msg "Restored ${_restored} firewall ruleset(s)."
  fi
}

# =============================================================================
# USAGE
# =============================================================================

usage() {
  cat <<'EOF'
CCDC System Restore Script

Usage:
    restore.sh list  <archive>     Show archive contents
    restore.sh all   <archive>     Full restore (files + databases + firewall)
    restore.sh files <archive>     Restore filesystem only
    restore.sh db    <archive>     Restore database dumps only
    restore.sh fw    <archive>     Restore firewall rules only

Examples:
    restore.sh list  /backups/web01-20250101_120000.tar.zst
    restore.sh all   /backups/web01-20250101_120000.tar.zst
    restore.sh db    /backups/db01-20250101_120000.tar.zst
    restore.sh fw    /backups/fw01-20250101_120000.tar.zst

Supported formats: .tar.zst .tar.gz .tgz .tar.lz4 .tar.xz .tar.bz2 .tar
EOF
}

# =============================================================================
# MAIN
# =============================================================================

check_root

MODE="${1:-}"
ARCHIVE="${2:-}"

if [ -z "$MODE" ] || [ -z "$ARCHIVE" ]; then
  usage
  exit 1
fi

case "$MODE" in
list | all | files | db | fw) ;;
*)
  log_err "Unknown mode: ${MODE}"
  usage
  exit 1
  ;;
esac

if [ ! -f "$ARCHIVE" ]; then
  log_err "File not found: ${ARCHIVE}"
  exit 1
fi

DECOMPRESS=$(detect_decompressor "$ARCHIVE")
detect_tar_flags

log_msg "Archive      : ${ARCHIVE}"
log_msg "Decompressor : ${DECOMPRESS}"
log_msg "Mode         : ${MODE}"
log_msg "Tar flags    : ${TAR_RESTORE:-default}"

case "$MODE" in
list) do_list ;;
files) do_restore_files ;;
db) do_restore_db ;;
fw) do_restore_fw ;;
all)
  do_restore_files
  do_restore_db
  do_restore_fw
  ;;
esac

log_msg "Restore operation '${MODE}' complete."

exit 0

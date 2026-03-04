#!/bin/sh
# =============================================================================
# CCDC System Backup Script
# POSIX-compliant, zero-config, optimized for speed and size
# Saves to /backups/
# =============================================================================

set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root."
  exit 1
fi

# =============================================================================
# CONFIGURATION
# =============================================================================

BACKUP_DIR="/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
HOSTNAME=$(hostname)
MAX_FILE_SIZE_MB=100

# =============================================================================
# DETECT ENVIRONMENT
# =============================================================================

CPUS=1
if [ -f /proc/cpuinfo ]; then
  CPUS=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
elif command -v nproc >/dev/null 2>&1; then
  CPUS=$(nproc 2>/dev/null || echo 1)
elif command -v sysctl >/dev/null 2>&1; then
  CPUS=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
fi

if command -v zstd >/dev/null 2>&1; then
  COMPRESSOR="zstd -T${CPUS} -3 --long=25"
  EXT="tar.zst"
elif command -v pigz >/dev/null 2>&1; then
  COMPRESSOR="pigz -1 -p ${CPUS}"
  EXT="tar.gz"
elif command -v lz4 >/dev/null 2>&1; then
  COMPRESSOR="lz4 -1"
  EXT="tar.lz4"
else
  COMPRESSOR="gzip -1"
  EXT="tar.gz"
fi

THROTTLE=""
if command -v ionice >/dev/null 2>&1; then
  THROTTLE="ionice -c 3"
fi
if command -v nice >/dev/null 2>&1; then
  THROTTLE="nice -n 10 ${THROTTLE}"
fi

echo "[BACKUP] Compressor : ${COMPRESSOR}"
echo "[BACKUP] CPUs       : ${CPUS}"
echo "[BACKUP] Throttle   : ${THROTTLE:-none}"

# =============================================================================
# TAR FEATURE DETECTION
# =============================================================================

TAR_EXTRA=""
_tar_help=$(tar --help 2>&1 || true)
echo "$_tar_help" | grep -q '\-\-sparse' && TAR_EXTRA="${TAR_EXTRA} --sparse"
echo "$_tar_help" | grep -q '\-\-acls' && TAR_EXTRA="${TAR_EXTRA} --acls"
echo "$_tar_help" | grep -q '\-\-xattrs' && TAR_EXTRA="${TAR_EXTRA} --xattrs"
echo "$_tar_help" | grep -q '\-\-selinux' && TAR_EXTRA="${TAR_EXTRA} --selinux"
echo "$_tar_help" | grep -q '\-\-numeric-owner' && TAR_EXTRA="${TAR_EXTRA} --numeric-owner"

# =============================================================================
# PREPARE
# =============================================================================

mkdir -p "${BACKUP_DIR}"

# =============================================================================
# FIREWALL RULES
# =============================================================================

echo "[BACKUP] Exporting firewall rules..."
if command -v iptables-save >/dev/null 2>&1; then
  iptables-save >"${BACKUP_DIR}/fw_iptables.rules" 2>/dev/null || true
fi
if command -v ip6tables-save >/dev/null 2>&1; then
  ip6tables-save >"${BACKUP_DIR}/fw_ip6tables.rules" 2>/dev/null || true
fi
if command -v nft >/dev/null 2>&1; then
  nft -s list ruleset >"${BACKUP_DIR}/fw_nftables.rules" 2>/dev/null || true
fi

# =============================================================================
# PACKAGE LIST
# =============================================================================

echo "[BACKUP] Saving package list..."
if command -v dpkg >/dev/null 2>&1; then
  dpkg --get-selections >"${BACKUP_DIR}/packages_dpkg.list" 2>/dev/null || true
elif command -v rpm >/dev/null 2>&1; then
  rpm -qa --qf '%{NAME}\n' | sort >"${BACKUP_DIR}/packages_rpm.list" 2>/dev/null || true
elif command -v pacman >/dev/null 2>&1; then
  pacman -Qqe >"${BACKUP_DIR}/packages_pacman.list" 2>/dev/null || true
elif command -v apk >/dev/null 2>&1; then
  apk list -I 2>/dev/null | cut -d' ' -f1 >"${BACKUP_DIR}/packages_apk.list" || true
fi

# =============================================================================
# CRONTABS
# =============================================================================

echo "[BACKUP] Saving crontabs..."
_cron_dir="${BACKUP_DIR}/crontabs"
mkdir -p "$_cron_dir"
crontab -l >"${_cron_dir}/root.cron" 2>/dev/null || true

if [ -d /var/spool/cron/crontabs ]; then
  cp -a /var/spool/cron/crontabs/* "$_cron_dir/" 2>/dev/null || true
elif [ -d /var/spool/cron ]; then
  for _f in /var/spool/cron/*; do
    [ -f "$_f" ] && cp "$_f" "$_cron_dir/" 2>/dev/null || true
  done
fi

# =============================================================================
# DATABASE DUMPS
# =============================================================================

echo "[BACKUP] Checking for databases..."
_dump_dir="${BACKUP_DIR}/db_dumps"
mkdir -p "$_dump_dir"

if command -v mysqldump >/dev/null 2>&1; then
  if mysqladmin ping >/dev/null 2>&1; then
    echo "[BACKUP] Dumping MySQL databases..."
    mysqldump --all-databases --single-transaction --quick \
      --routines --triggers --events 2>/dev/null \
      >"${_dump_dir}/mysql_all.sql" || true
  fi
fi

if command -v pg_dumpall >/dev/null 2>&1; then
  if su - postgres -c "psql -c 'SELECT 1'" >/dev/null 2>&1; then
    echo "[BACKUP] Dumping PostgreSQL databases..."
    su - postgres -c "pg_dumpall" 2>/dev/null \
      >"${_dump_dir}/postgres_all.sql" || true
  fi
fi

find "$_dump_dir" -maxdepth 1 -type f -empty -delete 2>/dev/null || true

# =============================================================================
# EXCLUDE LIST
# =============================================================================

EXCLUDE_FILE="${BACKUP_DIR}/.exclude.tmp"

cat >"${EXCLUDE_FILE}" <<'EXCLUDES'
proc
sys
dev
tmp
run
mnt
media
lost+found
backups/.exclude.tmp

var/tmp
var/cache
var/log
usr/share/doc
usr/share/man
usr/share/info
usr/share/locale
usr/lib/firmware
usr/lib/modules

*.log
*.log.*
*.gz
*.tar
*.tar.*
*.zip
*.7z
*.rar
*.iso
*.qcow2
*.vmdk
*.vdi
*.img
*.swp
*.tmp
*.bak
*.old
*.pyc
*.class
*.o
*.obj
core
core.*

.git
.svn
.terraform
.cache
__pycache__
node_modules
.sass-cache

.bash_history
.zsh_history
.lesshst
.viminfo
.mysql_history
.psql_history
.rediscli_history

client_body_temp
fastcgi_temp
proxy_temp
scgi_temp
uwsgi_temp
sess_*

mysql-bin.*
relay-log.*
slow-query.log
general.log
aria_log.*
*.sock
*.pid
ib_logfile*
ibdata1
undo_*

pg_wal
pg_xlog
pg_stat_tmp
pg_replslot
pg_log
postmaster.pid

var/lib/docker/overlay2
var/lib/docker/containers
var/lib/docker/image
var/lib/docker/tmp
var/lib/containerd
docker.sock
.docker

var/lib/kubelet/pods
var/lib/etcd/member/wal
var/lib/jenkins/workspace
var/lib/jenkins/builds
var/lib/jenkins/caches
var/lib/teleport/log
var/lib/teleport/proc
var/lib/influxdb
var/lib/elasticsearch/nodes
var/lib/graylog-server/journal
var/ossec/logs
var/ossec/queue/diff
var/ossec/var/run
var/spool/postfix/active
var/spool/postfix/hold
var/spool/postfix/deferred
var/spool/exim4/input
.ansible
EXCLUDES

# =============================================================================
# DISCOVER DIRECTORIES
# =============================================================================

echo "[BACKUP] Scanning for directories..."

DIRS_TO_BACKUP=""
for _d in \
  /etc \
  /opt \
  /root \
  /home \
  /srv \
  /usr/local \
  /var/www \
  /var/named \
  /var/lib/bind \
  /var/spool/cron \
  /var/spool/anacron \
  /var/lib/mysql \
  /var/lib/pgsql \
  /var/lib/postgresql \
  /var/lib/samba \
  /var/lib/jenkins \
  /var/lib/gitea \
  /var/lib/teleport \
  /var/lib/docker/swarm \
  /var/lib/docker/volumes \
  /var/ossec \
  /etc/kubernetes; do
  [ -d "$_d" ] && DIRS_TO_BACKUP="${DIRS_TO_BACKUP} ${_d}"
done

if [ -z "$DIRS_TO_BACKUP" ]; then
  echo "[BACKUP] ERROR: No directories found to back up."
  rm -f "${EXCLUDE_FILE}"
  exit 1
fi

echo "[BACKUP] Excluding files larger than ${MAX_FILE_SIZE_MB}MB..."
# shellcheck disable=SC2086
find $DIRS_TO_BACKUP -xdev -type f -size "+${MAX_FILE_SIZE_MB}M" \
  2>/dev/null >>"${EXCLUDE_FILE}" || true

# =============================================================================
# COLLECT EXTRA PATHS
# =============================================================================

EXTRA_PATHS=""
for _p in \
  "${BACKUP_DIR}/db_dumps" \
  "${BACKUP_DIR}/crontabs" \
  "${BACKUP_DIR}/fw_iptables.rules" \
  "${BACKUP_DIR}/fw_ip6tables.rules" \
  "${BACKUP_DIR}/fw_nftables.rules" \
  "${BACKUP_DIR}/packages_dpkg.list" \
  "${BACKUP_DIR}/packages_rpm.list" \
  "${BACKUP_DIR}/packages_pacman.list" \
  "${BACKUP_DIR}/packages_apk.list"; do
  [ -e "$_p" ] && EXTRA_PATHS="${EXTRA_PATHS} ${_p}"
done

# =============================================================================
# CREATE ARCHIVE
# =============================================================================

ARCHIVE_NAME="${HOSTNAME}-${TIMESTAMP}.${EXT}"
ARCHIVE_PATH="${BACKUP_DIR}/${ARCHIVE_NAME}"

echo "[BACKUP] Creating: ${ARCHIVE_NAME}"

# shellcheck disable=SC2086
$THROTTLE tar -cpf - \
  --one-file-system \
  ${TAR_EXTRA} \
  -X "${EXCLUDE_FILE}" \
  ${DIRS_TO_BACKUP} \
  ${EXTRA_PATHS} \
  2>/dev/null |
  $COMPRESSOR >"${ARCHIVE_PATH}"

# =============================================================================
# CLEANUP AND REPORT
# =============================================================================

rm -f "${EXCLUDE_FILE}"

if [ -f "${ARCHIVE_PATH}" ]; then
  _bytes=$(wc -c <"${ARCHIVE_PATH}" | tr -d ' ')
  if [ "$_bytes" -ge 1073741824 ] 2>/dev/null; then
    _size="$((_bytes / 1073741824))GB"
  elif [ "$_bytes" -ge 1048576 ] 2>/dev/null; then
    _size="$((_bytes / 1048576))MB"
  elif [ "$_bytes" -ge 1024 ] 2>/dev/null; then
    _size="$((_bytes / 1024))KB"
  else
    _size="${_bytes}B"
  fi
  echo "[BACKUP] Complete: ${ARCHIVE_PATH} (${_size})"
else
  echo "[BACKUP] ERROR: Archive was not created."
  exit 1
fi

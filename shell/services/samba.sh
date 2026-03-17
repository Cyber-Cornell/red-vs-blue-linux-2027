#!/bin/sh
# POSIX-compliant Samba hardening script for CCDC
# Requires: Samba installed
# Ubuntu paths assumed where noted
#
# HUMAN NOTE: WRITTEN WITH CHATGPT!!! I've tried to check
# what it does by running it, and it does stop and restart samba,
# but it's worth checking it a bit more...
#
# USAGE: go through /etc/samba/smb.conf and find the shares that need to
# be kept. Determine the interfaces that need to be kept (you don't have
# to, but it's good for security?). Pass these options in on command line,
# with --mission. Without that, all shares will be disabled.
# --help gives all options
#
# It also backs everything up to /root/samba-backups, and logs its own output
# to /var/log/samba-hardening. It also sets up logs in samba.
#
# --watch does really, really basic monitoring of login attempts: failed and
# anonymous/guest logins.

###############################################################################
# Defaults
###############################################################################
MODE="strict"
DRYRUN=0
WATCH=0
INTERFACES=""
ALLOW_SHARES=""
LOGFILE="/var/log/samba-hardening.log"
BACKUPDIR="/root/samba-backups"
SMBCONF="/etc/samba/smb.conf"
DATE="$(date +%Y%m%d-%H%M%S)"

###############################################################################
# Helpers
###############################################################################
log() {
    printf "%s %s\n" "$(date '+%F %T')" "$*" | tee -a "$LOGFILE"
}

run() {
    log "ACTION: $*"
    [ "$DRYRUN" -eq 1 ] && return 0
    "$@"
}

backup_file() {
    f="$1"
    [ -f "$f" ] || return
    mkdir -p "$BACKUPDIR"
    cp -a "$f" "$BACKUPDIR/$(basename "$f").$DATE"
    log "BACKUP: $f -> $BACKUPDIR"
}

die() {
    log "FATAL: $*"
    exit 1
}

###############################################################################
# Parse Arguments
###############################################################################
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRYRUN=1 ;;
        --strict) MODE="strict" ;;
        --mission) MODE="mission" ;;
        --interfaces) INTERFACES="$2"; shift ;;
        --allow-share) ALLOW_SHARES="$ALLOW_SHARES $2"; shift ;;
        --watch) WATCH=1 ;;
        --log) LOGFILE="$2"; shift ;;
        --backup) BACKUPDIR="$2"; shift ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

###############################################################################
# Preconditions
###############################################################################
[ "$(id -u)" -eq 0 ] || die "Must be run as root"
command -v smbd >/dev/null 2>&1 || die "Samba not installed"

touch "$LOGFILE" || die "Cannot write log file"

log "Starting Samba hardening (mode=$MODE, dryrun=$DRYRUN)"

###############################################################################
# Forensics Snapshot
###############################################################################
log "Collecting forensics snapshot"
smbd -V 2>&1 | tee -a "$LOGFILE"
smbstatus 2>/dev/null | tee -a "$LOGFILE"

###############################################################################
# Backup Samba State
###############################################################################
backup_file "$SMBCONF"
for f in /var/lib/samba/*.tdb; do
    backup_file "$f"
done

###############################################################################
# Replace smb.conf with hardened config
###############################################################################
log "Rebuilding smb.conf from hardened template"

TMP_CONF="/tmp/smb.conf.$$"

cat >"$TMP_CONF" <<EOF
[global]
   server role = standalone server
   security = user
   map to guest = never
   restrict anonymous = 2

   server min protocol = SMB2
   client min protocol = SMB2

   ntlm auth = no
   lanman auth = no
   client lanman auth = no
   client ntlmv2 auth = yes

   smb encrypt = required
   server signing = mandatory

   unix extensions = no
   wide links = no
   follow symlinks = no
   allow insecure wide links = no

   load printers = no
   printing = bsd
   disable spoolss = yes

   log level = 2
   log file = /var/log/samba/log.%m
   max log size = 5000

   max connections = 50

EOF

###############################################################################
# Interface Binding
###############################################################################
if [ -n "$INTERFACES" ]; then
    log "Restricting Samba to interfaces: $INTERFACES"
    echo "   interfaces = $INTERFACES" >>"$TMP_CONF"
    echo "   bind interfaces only = yes" >>"$TMP_CONF"
fi

###############################################################################
# Shares
###############################################################################
log "Disabling all shares by default"

if [ "$MODE" = "mission" ]; then
    for s in $ALLOW_SHARES; do
        log "Allowing share: $s"
        cat >>"$TMP_CONF" <<EOF

[$s]
   path = /srv/samba/$s
   browseable = no
   read only = yes
   valid users = @$s
EOF
    done
fi

###############################################################################
# Validate Configuration
###############################################################################
log "Validating smb.conf"
testparm -s "$TMP_CONF" >/dev/null 2>&1 || die "Invalid smb.conf generated"

###############################################################################
# Install Configuration
###############################################################################
run cp "$TMP_CONF" "$SMBCONF"
run chmod 600 "$SMBCONF"
run chown root:root "$SMBCONF"

###############################################################################
# Filesystem Hardening
###############################################################################
log "Hardening Samba database permissions"

for f in /var/lib/samba/*.tdb; do
    [ -f "$f" ] || continue
    run chown root:root "$f"
    run chmod 600 "$f"
done

###############################################################################
# Kill Rogue smbd Instances
###############################################################################
log "Checking for rogue smbd processes"
ps -eo pid,user,comm | grep smbd | grep -v root | while read p u c; do
    log "SUSPICIOUS: smbd running as $u (pid $p)"
    run kill -9 "$p"
done

###############################################################################
# Restart Samba
###############################################################################
log "Restarting Samba"
if command -v service >/dev/null 2>&1; then
    run service smbd restart
    run service nmbd restart
else
    run /etc/init.d/smbd restart
    run /etc/init.d/nmbd restart
fi

###############################################################################
# Post-Validation
###############################################################################
log "Post-hardening validation"
testparm -s 2>&1 | tee -a "$LOGFILE"
smbstatus 2>&1 | tee -a "$LOGFILE"

###############################################################################
# Watch Mode (Suspicious Activity)
###############################################################################
if [ "$WATCH" -eq 1 ]; then
    log "Entering WATCH mode (Ctrl+C to exit)"
    while :; do
        smbstatus | awk '
            /Anonymous|guest/ { print "SUSPICIOUS SESSION:", $0 }
            /DENIED/ { print "ACCESS DENIED:", $0 }
        '
        sleep 5
    done
fi

log "Samba hardening complete"
exit 0

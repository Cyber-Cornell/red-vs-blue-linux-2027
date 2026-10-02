#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/lib/portable.sh"
MODE=audit YES=0 BACKEND= SERVICE= INIT= TARGET= PROFILE= TYPE= HEALTH= LOGCHECK= STATE=
usage() {
    cat <<'USAGE'
Usage: mac_policy.sh [--audit | --plan]
       mac_policy.sh --apply --yes --backend apparmor|selinux --service NAME
         --init systemd|openrc --path ABS --health-check ABS --log-check ABS
         [--profile ABS | --type SELINUX_TYPE]
       mac_policy.sh --rollback PRIVATE_STATE_DIR --yes
AppArmor: add one NEW executable-attached, standalone reviewed profile and restart
one reviewed service. Existing loaded profiles are never replaced. Runtime only.
SELinux: change one existing path's type, nonrecursively; save its exact context.
Probes must be executable operator-reviewed scripts; log probe must verify fresh
service telemetry reaches its expected destination. Each probe has 20 seconds.
No installation, global mode changes, permanent labeling or policy generation.
USAGE
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --audit) MODE=audit; shift ;;
        --plan) MODE=plan; shift ;;
        --apply) MODE=apply; shift ;;
        --yes) YES=1; shift ;;
        --help|-h) usage; exit 0 ;;
        --backend|--service|--init|--path|--profile|--type|--health-check|--log-check|--rollback)
            [ "$#" -ge 2 ] || die "Missing value for $1"
            case "$1" in
                --backend) BACKEND=$2 ;; --service) SERVICE=$2 ;; --init) INIT=$2 ;;
                --path) TARGET=$2 ;; --profile) PROFILE=$2 ;; --type) TYPE=$2 ;;
                --health-check) HEALTH=$2 ;; --log-check) LOGCHECK=$2 ;;
                --rollback) MODE=rollback; STATE=$2 ;;
            esac
            shift 2 ;;
        *) die "Unknown option: $1" ;;
    esac
done
if [ "$MODE" = plan ]; then
    usage
    printf '%s\n' 'Review scored-service dependencies, executable attachment, and telemetry access on a matching disposable host.' \
        'Apply requires successful service status, health and fresh-log probes before and after the change.' \
        'Failure triggers rollback. Keep the private rollback directory until the change is accepted.'
    exit 0
fi
if [ "$MODE" = audit ]; then
    if have_cmd getenforce; then getenforce; else log_warn 'SELinux getenforce unavailable'; fi
    if have_cmd aa-status; then aa-status --enabled && log_info 'AppArmor enabled' || log_warn 'AppArmor unavailable or inaccessible'; fi
    [ ! -r /sys/kernel/security/lsm ] || cat /sys/kernel/security/lsm
    log_info 'Read-only MAC inventory; inspect denials privately (they can contain sensitive paths). Missing interfaces do not imply disabled MAC.'
    exit 0
fi
[ "$YES" = 1 ] || die 'Apply and rollback require --yes'
require_root
umask 077
# Bound each retained command/probe output to 128 KiB on Linux.
ulimit -f 128
for cmd in timeout stat; do have_cmd "$cmd" || die "Missing required utility: $cmd"; done
safe_path() {
    case "$1" in /*) ;; *) die 'Paths must be absolute' ;; esac
    case "$1" in *[!a-zA-Z0-9_./-]*|*/../*|*/..|*/./*|*//*) die 'Use a canonical path with only letters, digits, slash, dot, underscore and hyphen' ;; esac
    [ ! -L "$1" ] || die 'Symlink inputs are refused'
}
service_action() {
    case "$INIT" in
        systemd)
            case "$1" in status) timeout 20 systemctl is-active --quiet "$SERVICE" ;; restart) timeout 30 systemctl restart "$SERVICE" ;; esac ;;
        openrc) timeout 30 rc-service "$SERVICE" "$1" ;;
    esac
}
run_checks() {
    service_action status && timeout 20 "$HEALTH" && timeout 20 "$LOGCHECK"
}
bounded_checks() {
    (ulimit -f 128; run_checks) >"$STATE/$1.log" 2>&1
}
restore() {
    case "$BACKEND" in
        apparmor)
            timeout 30 apparmor_parser -K -R "$STATE/profile" || return 1
            service_action restart || return 1 ;;
        selinux)
            [ "$(stat -c '%d:%i' "$TARGET")" = "$(cat "$STATE/identity")" ] || return 1
            timeout 20 chcon -- "$(cat "$STATE/context")" "$TARGET" || return 1
            [ "$(stat -c %C "$TARGET")" = "$(cat "$STATE/context")" ] || return 1 ;;
    esac
    bounded_checks rollback-checks || return 1
    printf '%s\n' restored >"$STATE/result"
}
if [ "$MODE" = rollback ]; then
    safe_path "$STATE"
    [ -d "$STATE" ] && [ "$(stat -c '%u:%a' "$STATE")" = 0:700 ] || die 'State directory must be root-owned mode 0700'
    for field in backend service init target health logcheck; do
        [ -f "$STATE/$field" ] && [ ! -L "$STATE/$field" ] || die 'Incomplete rollback state'
    done
    BACKEND=$(cat "$STATE/backend"); SERVICE=$(cat "$STATE/service"); INIT=$(cat "$STATE/init")
    TARGET=$(cat "$STATE/target"); HEALTH=$(cat "$STATE/health"); LOGCHECK=$(cat "$STATE/logcheck")
fi
case "$BACKEND" in apparmor|selinux) ;; *) die 'Select --backend apparmor or selinux' ;; esac
case "$SERVICE" in ''|-*|*[!a-zA-Z0-9_.@-]*) die 'Invalid service name' ;; esac
case "$INIT" in systemd) have_cmd systemctl || die 'systemctl unavailable' ;; openrc) have_cmd rc-service || die 'rc-service unavailable' ;; *) die 'Select --init systemd or openrc' ;; esac
for path in "$TARGET" "$HEALTH" "$LOGCHECK"; do safe_path "$path"; done
[ -e "$TARGET" ] || die 'Reviewed target does not exist'
[ -x "$HEALTH" ] && [ -f "$HEALTH" ] && [ -x "$LOGCHECK" ] && [ -f "$LOGCHECK" ] || die 'Health and logging probes must be executable files'
for path in "$HEALTH" "$LOGCHECK"; do
    [ "$(stat -c %u "$path")" = 0 ] || die 'Probes must be root-owned'
    permissions=$(stat -c %a "$path")
    [ "$((0$permissions & 022))" -eq 0 ] || die 'Probes must not be group/world writable'
done
if [ "$MODE" = rollback ]; then
    if restore >"$STATE/rollback.log" 2>&1; then log_ok 'Rollback and service probes passed'; else die "Rollback incomplete; inspect $STATE privately"; fi
    exit 0
fi
case "$BACKEND" in
    apparmor)
        have_cmd apparmor_parser && have_cmd aa-status || die 'AppArmor utilities unavailable; no installation performed'
        aa-status --enabled >/dev/null 2>&1 || die 'AppArmor not enabled or inaccessible'
        safe_path "$PROFILE"
        [ -f "$PROFILE" ] && [ "$(wc -c <"$PROFILE")" -le 65536 ] || die 'Profile must be a regular file at most 64 KiB'
        [ -x "$TARGET" ] && [ -f "$TARGET" ] || die 'AppArmor target must be an executable file'
        grep -F -x "$TARGET {" "$PROFILE" >/dev/null || die 'Profile header must be the literal executable path followed by space and {'
        # A self-contained snapshot makes unload independent of later include edits.
        if grep -Eq '(^|[[:space:]])#?[[:space:]]*(include|alias|namespace)' "$PROFILE"; then die 'Use a standalone profile without includes, aliases or namespaces'; fi ;;
    selinux)
        have_cmd getenforce && have_cmd chcon || die 'SELinux utilities unavailable; no installation performed'
        case "$(getenforce)" in Enforcing|Permissive) ;; *) die 'SELinux not enabled' ;; esac
        case "$TYPE" in ''|*[!a-zA-Z0-9_]*) die 'Specify one reviewed SELinux type' ;; esac
        [ -f "$TARGET" ] || [ -d "$TARGET" ] || die 'SELinux target must be a regular file or directory' ;;
esac
STATE=$(mktemp -d /var/tmp/ccdc-mac.XXXXXXXX) || die 'Cannot create private rollback state'
chmod 700 "$STATE"
printf '%s\n' "$BACKEND" >"$STATE/backend"
printf '%s\n' "$SERVICE" >"$STATE/service"
printf '%s\n' "$INIT" >"$STATE/init"
printf '%s\n' "$TARGET" >"$STATE/target"
printf '%s\n' "$HEALTH" >"$STATE/health"
printf '%s\n' "$LOGCHECK" >"$STATE/logcheck"
log_info "Private rollback state: $STATE"
bounded_checks preflight || die "Service or logging preflight failed; inspect $STATE"
case "$BACKEND" in
    apparmor)
        cp "$PROFILE" "$STATE/profile"
        (ulimit -f 128; timeout 30 apparmor_parser -K -Q "$STATE/profile") >"$STATE/validate.log" 2>&1 || die "Profile validation failed; inspect $STATE"
        timeout 20 apparmor_parser -K -N "$STATE/profile" >"$STATE/names" 2>"$STATE/names.log" || die 'Cannot inspect profile names'
        [ "$(cat "$STATE/names")" = "$TARGET" ] || die 'Profile must contain exactly one executable-path-named profile, with no child profiles'
        # Add, never replace: an already-loaded name causes a refusal.
        timeout 30 apparmor_parser -K -a "$STATE/profile" >"$STATE/apply.log" 2>&1 || die "Profile add failed (existing names are refused); inspect kernel state and $STATE"
        CHANGED=1 ;;
    selinux)
        stat -c %C "$TARGET" >"$STATE/context"
        case "$(cat "$STATE/context")" in *:*:*:*) ;; *) die 'Native stat cannot read a valid SELinux context' ;; esac
        stat -c '%d:%i' "$TARGET" >"$STATE/identity"
        getenforce >"$STATE/global-mode"
        CHANGED=1 ;;
esac
rollback_on_exit() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ "$CHANGED" = 1 ]; then
        if restore >"$STATE/rollback.log" 2>&1; then log_warn 'Change failed; rollback and probes passed'; else log_error "Rollback incomplete; inspect $STATE privately"; fi
    fi
    exit "$status"
}
trap rollback_on_exit EXIT
trap 'exit 130' HUP INT TERM
case "$BACKEND" in
    apparmor) service_action restart >"$STATE/restart.log" 2>&1 || die 'Reviewed service restart failed' ;;
    selinux)
        timeout 20 chcon -t "$TYPE" -- "$TARGET" >"$STATE/apply.log" 2>&1 || die 'Single-path label change failed'
        [ "$(stat -c %C "$TARGET" | cut -d : -f 3)" = "$TYPE" ] || die 'Label verification failed'
        [ "$(getenforce)" = "$(cat "$STATE/global-mode")" ] || die 'Global mode changed externally; refusing success' ;;
esac
bounded_checks postflight || die 'Health or logging probe failed'
printf '%s\n' applied >"$STATE/result"
CHANGED=0
log_ok "MAC change and service probes passed; rollback: sh $SCRIPT_DIR/mac_policy.sh --rollback $STATE --yes"

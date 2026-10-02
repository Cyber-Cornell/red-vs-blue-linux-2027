#!/bin/sh
# CCDC Linux blue-team operator entry point.
# Read-only collection is the default workflow. State-changing stages require
# both the "apply" command and --yes so an accidental invocation cannot take a
# scored service offline.

set -u

SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
if [ -z "${SCRIPT_DIR:-}" ]; then
  printf '%s\n' '[ERROR] Cannot determine the script directory.' >&2
  exit 1
fi

# shellcheck source=lib/portable.sh
. "$SCRIPT_DIR/lib/portable.sh"

VERSION="2.0.0"
COMMAND="${1:-help}"
[ "$#" -gt 0 ] && shift

RUN_ID=$(date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null || date '+%Y%m%d_%H%M%S')
OUTPUT_DIR="${CCDC_OUTPUT_DIR:-}"
TCP_PORTS="${CCDC_TCP_PORTS:-}"
UDP_PORTS="${CCDC_UDP_PORTS:-}"
YES=0
STOP_ON_ERROR=0
NO_SNAPSHOT=0
SELECTED=""
FAILED=0
PASSED=0
SKIPPED=0
LOCK_DIR=""

usage() {
  cat <<EOF
CCDC Linux Blue Team Toolkit $VERSION

Usage:
  sudo ./setup.sh audit [--output DIR]
  sudo ./setup.sh hunt [--output DIR]
  sudo ./setup.sh backup --profile configs --output NEW_DIR [--max-mb N]
  sudo ./setup.sh backup --source PATH [--source PATH ...] --output NEW_DIR
       ./setup.sh check
       ./setup.sh list
       ./setup.sh plan [PROFILE|STAGE ...]
  sudo ./setup.sh apply PROFILE|STAGE... --yes [OPTIONS]

Read-only commands:
  audit   Fast host triage plus account, service, process, persistence,
          permission, database, Docker, and web-root review.
  hunt    The audit set plus package integrity, C2, rootkit and connection review; can take time.
  check   Validate scripts, configuration, dependencies, and operator inputs.
  plan    Show exactly what an apply run would do without changing the host.

Backup command:
  backup  Create a bounded backup using tools/backup_create.sh. Options are
          forwarded unchanged; use "setup.sh backup --help" for all options.
          This is a standalone collection command, not an apply stage.

Apply profiles:
  baseline  snapshot, kernel, auditd, rsyslog, journald
  host      baseline plus sensitive permissions and desktop policy

Apply options:
  --yes                 Required acknowledgement for state changes.
  --output DIR          Store evidence and logs in DIR.
  --tcp-ports LIST      Required for firewall; comma-separated, e.g. 22,53,80.
  --udp-ports LIST      UDP ports required by scored services.
  --stop-on-error       Stop after the first failed stage.
  --no-snapshot         Skip the automatic lightweight /etc snapshot.

Examples:
  sudo ./setup.sh audit
  sudo ./setup.sh backup --profile configs --output /var/backups/ccdc-configs
  ./setup.sh plan baseline ssh
  sudo ./setup.sh apply baseline --yes
  sudo ./setup.sh apply firewall --tcp-ports 22,80,443 --yes

Never apply a profile until the service owner has recorded the scored ports,
users, dependencies, and a console recovery path.
EOF
}

append_stage() {
  case " $SELECTED " in
    *" $1 "*) return 0 ;;
  esac
  SELECTED="${SELECTED}${SELECTED:+ }$1"
}

append_selection() {
  case "$1" in
    baseline)
      append_stage kernel
      append_stage auditd
      append_stage rsyslog
      append_stage journald
      ;;
    host)
      append_selection baseline
      append_stage permissions
      append_stage dconf
      ;;
    *) append_stage "$1" ;;
  esac
}

stage_info() {
  # Format: risk|relative script|description
  case "$1" in
    triage) printf '%s\n' 'read-only|tools/triage.sh|Collect bounded volatile state and host evidence' ;;
    user-inventory) printf '%s\n' 'read-only|tools/user_inventory.sh|List accounts, shells, and group membership' ;;
    service-inventory) printf '%s\n' 'read-only|tools/service_inventory.sh|List running services' ;;
    service-check) printf '%s\n' 'read-only|tools/service_watch.sh|Check configured scored services once' ;;
    process-hunt) printf '%s\n' 'read-only|tools/process_audit.sh|Hunt hidden and deleted processes' ;;
    persistence-hunt) printf '%s\n' 'read-only|tools/persistence_audit.sh|Inspect common persistence locations' ;;
    permission-audit) printf '%s\n' 'read-only|tools/permission_audit.sh|Review SUID, SGID, writable, and immutable files' ;;
    database-audit) printf '%s\n' 'read-only|tools/db_audit.sh|Review local database privilege and persistence risks' ;;
    observability-audit) printf '%s\n' 'read-only|tools/observability_audit.sh|Review logging and EDR coverage gaps' ;;
    docker-audit) printf '%s\n' 'read-only|tools/docker_audit.sh|Review container privilege and exposure' ;;
    web-audit) printf '%s\n' 'read-only|tools/web_audit.sh|Hunt web shells under the configured web root' ;;
    package-verify) printf '%s\n' 'read-only-slow|tools/package_verify.sh|Verify packaged files against package metadata' ;;
    c2-hunt) printf '%s\n' 'read-only|tools/c2_hunt.sh|Bounded process, socket and persistence leads for C2 review' ;;
    rootkit-hunt) printf '%s\n' 'read-only|tools/rootkit_hunt.sh|Bounded process visibility, kernel and integrity review' ;;
    connection-hunt) printf '%s\n' 'read-only|tools/connection_hunt.sh|Review local sockets, owners and reviewed listener/destination policy' ;;
    snapshot) printf '%s\n' 'low|tools/snapshot.sh|Create a compact pre-change configuration snapshot' ;;
    kernel) printf '%s\n' 'moderate|kernel.sh|Apply kernel, core-dump, and module hardening' ;;
    auditd) printf '%s\n' 'moderate|auditd.sh|Install and load audit rules' ;;
    rsyslog) printf '%s\n' 'moderate|rsyslog.sh|Harden and restart rsyslog' ;;
    journald) printf '%s\n' 'moderate|journald.sh|Harden and restart systemd-journald' ;;
    permissions) printf '%s\n' 'moderate|permission_fix.sh|Normalize sensitive file permissions' ;;
    dconf) printf '%s\n' 'moderate|dconf.sh|Apply GNOME security policy when present' ;;
    ssh) printf '%s\n' 'disruptive|ssh_config.sh|Harden SSH after validation and preserve rollback data' ;;
    accounts) printf '%s\n' 'disruptive|tools/users.sh|Lock only explicitly reviewed unauthorized accounts' ;;
    firewall) printf '%s\n' 'disruptive|firewall.sh|Apply an allowlist for declared scored-service ports' ;;
    *) return 1 ;;
  esac
}

list_stages() {
  cat <<'EOF'
Profiles:
  baseline host

Read-only stages:
  triage user-inventory service-inventory service-check process-hunt persistence-hunt
  permission-audit database-audit docker-audit web-audit package-verify c2-hunt rootkit-hunt connection-hunt observability-audit

State-changing stages:
  kernel auditd rsyslog journald permissions dconf ssh accounts firewall

Targeted standalone commands (see each --help):
  package_install.sh package_remove.sh package_reinstall.sh file_cleaner.sh
  tools/backup_create.sh tools/backup_restore.sh tools/password_rotate.sh
  tools/attribute_fix.sh tools/malware_scan.sh tools/yara_hunt.sh
  tools/linpeas_runner.sh tools/service_isolate.sh tools/opencode_install.sh
  tools/opencode_omo_plugin.sh mac_policy.sh
  setup.sh backup --help (convenience entry point for backup_create.sh)

Standalone read-only reviews:
  networking.sh fstab.sh ssh_remove_keys.sh package_manager_reset.sh
  tools/mount_audit.sh tools/attribute_audit.sh

Risk labels are shown by "plan". Destructive stages are intentionally absent
from every profile and must be named explicitly.
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes) YES=1 ;;
      --stop-on-error) STOP_ON_ERROR=1 ;;
      --no-snapshot) NO_SNAPSHOT=1 ;;
      --output)
        shift
        [ "$#" -gt 0 ] || die '--output requires a directory'
        OUTPUT_DIR=$1
        ;;
      --output=*) OUTPUT_DIR=${1#*=} ;;
      --tcp-ports)
        shift
        [ "$#" -gt 0 ] || die '--tcp-ports requires a comma-separated list'
        TCP_PORTS=$1
        ;;
      --tcp-ports=*) TCP_PORTS=${1#*=} ;;
      --udp-ports)
        shift
        [ "$#" -gt 0 ] || die '--udp-ports requires a comma-separated list'
        UDP_PORTS=$1
        ;;
      --udp-ports=*) UDP_PORTS=${1#*=} ;;
      -h|--help) usage; exit 0 ;;
      --*) die "Unknown option: $1" ;;
      *) append_selection "$1" ;;
    esac
    shift
  done
}

default_output_dir() {
  if [ "$(id -u 2>/dev/null || printf 1)" -eq 0 ] && [ -d /var/log ] && [ -w /var/log ]; then
    printf '/var/log/ccdc-blue/%s\n' "$RUN_ID"
  else
    printf '%s/reports/%s\n' "$SCRIPT_DIR" "$RUN_ID"
  fi
}

prepare_output() {
  [ -n "$OUTPUT_DIR" ] || OUTPUT_DIR=$(default_output_dir)
  case "$OUTPUT_DIR" in
    /*) ;;
    *) OUTPUT_DIR="$PWD/$OUTPUT_DIR" ;;
  esac
  umask 077

  _output_parent=${OUTPUT_DIR%/*}
  _output_name=${OUTPUT_DIR##*/}
  [ -n "$_output_parent" ] || _output_parent=/
  case "$_output_name" in
    ''|.|..|*[![:print:]]*) die 'Output directory name is empty or unsafe' ;;
  esac
  if [ ! -e "$_output_parent" ] && [ ! -L "$_output_parent" ]; then
    _output_grandparent=${_output_parent%/*}
    _output_parent_name=${_output_parent##*/}
    [ -n "$_output_grandparent" ] || _output_grandparent=/
    case "$_output_parent_name" in
      ''|.|..|*[![:print:]]*) die 'Output parent directory name is empty or unsafe' ;;
    esac
    [ -d "$_output_grandparent" ] && [ ! -L "$_output_grandparent" ] ||
      die "Output parent must have an existing real parent: $_output_parent"
    _output_grandparent=$(CDPATH= cd -P "$_output_grandparent" 2>/dev/null && pwd) ||
      die "Cannot resolve output parent: $_output_grandparent"
    _output_parent="$_output_grandparent/$_output_parent_name"
    mkdir -m 0700 "$_output_parent" || die "Cannot create private output parent: $_output_parent"
  fi
  [ -d "$_output_parent" ] && [ ! -L "$_output_parent" ] ||
    die "Output parent must be a real directory: $_output_parent"
  _output_parent=$(CDPATH= cd -P "$_output_parent" 2>/dev/null && pwd) ||
    die "Cannot resolve output parent: $_output_parent"
  OUTPUT_DIR="$_output_parent/$_output_name"
  if [ -e "$OUTPUT_DIR" ] || [ -L "$OUTPUT_DIR" ]; then
    die "Output directory must not already exist: $OUTPUT_DIR"
  fi
  mkdir -m 0700 "$OUTPUT_DIR" || die "Cannot create private output directory: $OUTPUT_DIR"
  mkdir -m 0700 "$OUTPUT_DIR/logs" || die "Cannot create private log directory: $OUTPUT_DIR/logs"
  RESULTS_FILE="$OUTPUT_DIR/results.tsv"
  printf 'stage\trisk\tstatus\tstarted_utc\tended_utc\tlog\n' >"$RESULTS_FILE"
  chmod 0600 "$RESULTS_FILE" || die 'Cannot protect results file'
}

acquire_lock() {
  _base=/tmp
  [ -d /run/lock ] && [ -w /run/lock ] && _base=/run/lock
  LOCK_DIR="$_base/ccdc-blue.lock"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" >"$LOCK_DIR/pid"
    trap 'release_lock' 0
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    return 0
  fi

  _old_pid=''
  [ -r "$LOCK_DIR/pid" ] && _old_pid=$(sed -n '1p' "$LOCK_DIR/pid" 2>/dev/null || true)
  case "$_old_pid" in
    ''|*[!0-9]*) ;;
    *) kill -0 "$_old_pid" 2>/dev/null && die "Another toolkit run is active (PID $_old_pid)" ;;
  esac
  rm -f "$LOCK_DIR/pid" 2>/dev/null || true
  rmdir "$LOCK_DIR" 2>/dev/null || die "Cannot clear stale lock: $LOCK_DIR"
  mkdir "$LOCK_DIR" || die "Cannot acquire lock: $LOCK_DIR"
  printf '%s\n' "$$" >"$LOCK_DIR/pid"
  trap 'release_lock' 0
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

release_lock() {
  if [ -n "$LOCK_DIR" ]; then
    rm -f "$LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
    LOCK_DIR=''
  fi
}

record_result() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >>"$RESULTS_FILE"
}

skip_stage() {
  _stage=$1
  _risk=$2
  _reason=$3
  _now=$(utc_now)
  log_warn "Skipping $_stage: $_reason"
  record_result "$_stage" "$_risk" 'SKIP' "$_now" "$_now" '-'
  SKIPPED=$((SKIPPED + 1))
}

stage_precondition() {
  case "$1" in
    docker-audit) have_cmd docker || return 1 ;;
    database-audit) have_cmd mysql || have_cmd mariadb || have_cmd psql || return 1 ;;
    web-audit) [ -d "${CCDC_WEB_ROOT:-/var/www}" ] || return 1 ;;
    dconf) have_cmd dconf || return 1 ;;
    journald) have_cmd systemctl && [ -d /run/systemd/system ] || return 1 ;;
    service-check)
      grep -Ev '^[[:space:]]*(#|$)' "$SCRIPT_DIR/configs/scored_services.conf" 2>/dev/null | grep -q . || return 1
      ;;
  esac
  return 0
}

execute_stage_script() {
  _stage=$1
  _path=$2
  case "$_stage" in
    triage) sh "$_path" --output "$OUTPUT_DIR/triage" ;;
    snapshot) sh "$_path" --output "$OUTPUT_DIR/snapshot" ;;
    accounts|ssh|kernel|auditd|rsyslog|journald|permissions|dconf) sh "$_path" --apply --yes ;;
    firewall)
      sh "$_path" --apply --yes --tcp-ports "$TCP_PORTS" --udp-ports "$UDP_PORTS"
      ;;
    connection-hunt) sh "$_path" --tcp-ports "$TCP_PORTS" --udp-ports "$UDP_PORTS" ;;
    web-audit) CCDC_WEB_ROOT="${CCDC_WEB_ROOT:-/var/www}" sh "$_path" ;;
    *) sh "$_path" ;;
  esac
}

run_stage() {
  _stage=$1
  _info=$(stage_info "$_stage") || die "Unknown stage: $_stage"
  _risk=${_info%%|*}
  _rest=${_info#*|}
  _rel=${_rest%%|*}
  _path="$SCRIPT_DIR/$_rel"
  _log="$OUTPUT_DIR/logs/${_stage}.log"

  if ! stage_precondition "$_stage"; then
    skip_stage "$_stage" "$_risk" 'not applicable on this host'
    return 0
  fi
  if [ ! -f "$_path" ]; then
    log_error "Missing required stage script: $_rel"
    record_result "$_stage" "$_risk" 'FAIL-MISSING' "$(utc_now)" "$(utc_now)" '-'
    FAILED=$((FAILED + 1))
    return 1
  fi
  if ! sh -n "$_path" 2>"$_log.syntax"; then
    log_error "Syntax check failed for $_stage"
    cat "$_log.syntax" >&2
    record_result "$_stage" "$_risk" 'FAIL-SYNTAX' "$(utc_now)" "$(utc_now)" "$_log.syntax"
    FAILED=$((FAILED + 1))
    return 1
  fi
  rm -f "$_log.syntax"

  _started=$(utc_now)
  log_info "Starting $_stage ($_risk); log: $_log"
  if (cd "$(dirname "$_path")" && execute_stage_script "$_stage" "$_path") >"$_log" 2>&1; then
    _ended=$(utc_now)
    record_result "$_stage" "$_risk" 'PASS' "$_started" "$_ended" "$_log"
    PASSED=$((PASSED + 1))
    log_ok "Completed $_stage"
    return 0
  else
    _status=$?
  fi

  _ended=$(utc_now)
  record_result "$_stage" "$_risk" "FAIL($_status)" "$_started" "$_ended" "$_log"
  FAILED=$((FAILED + 1))
  log_error "Stage $_stage failed with exit $_status; last log lines follow"
  tail -n 20 "$_log" >&2 2>/dev/null || true
  return "$_status"
}

run_selected() {
  for _stage in $SELECTED; do
    if ! run_stage "$_stage" && [ "$STOP_ON_ERROR" -eq 1 ]; then
      break
    fi
  done
}

print_plan() {
  [ -n "$SELECTED" ] || append_selection baseline
  printf '%-22s %-15s %s\n' 'STAGE' 'RISK' 'ACTION'
  printf '%-22s %-15s %s\n' '-----' '----' '------'
  if [ "$NO_SNAPSHOT" -eq 0 ]; then
    printf '%-22s %-15s %s\n' snapshot low 'Automatic pre-change configuration snapshot'
  fi
  for _stage in $SELECTED; do
    _info=$(stage_info "$_stage") || die "Unknown stage: $_stage"
    _risk=${_info%%|*}
    _description=${_info##*|}
    printf '%-22s %-15s %s\n' "$_stage" "$_risk" "$_description"
  done
}

check_repo() {
  _problems=0
  log_info "Toolkit version $VERSION"
  log_info "Host: $(uname -srmo 2>/dev/null || uname -a)"

  _syntax_report=$(mktemp "${TMPDIR:-/tmp}/ccdc-syntax.XXXXXX") || die 'Cannot create temporary file'
  : >"$_syntax_report"
  find "$SCRIPT_DIR" -type f -name '*.sh' -print 2>/dev/null | while IFS= read -r _script; do
    _interpreter=sh
    case "$(sed -n '1p' "$_script")" in *bash*) _interpreter=bash ;; esac
    if ! have_cmd "$_interpreter"; then
      printf '[ERROR] Missing %s for %s\n' "$_interpreter" "$_script" >>"$_syntax_report"
    else
      "$_interpreter" -n "$_script" 2>>"$_syntax_report" || printf '[ERROR] Syntax: %s\n' "$_script" >>"$_syntax_report"
    fi
  done
  if [ -s "$_syntax_report" ]; then
    cat "$_syntax_report" >&2
    _problems=$((_problems + 1))
  fi
  rm -f "$_syntax_report"

  for _required in configs/sysctl.conf configs/audit.rules configs/sshd_config configs/admins.txt; do
    if [ ! -s "$SCRIPT_DIR/$_required" ]; then
      log_error "Missing or empty: $_required"
      _problems=$((_problems + 1))
    fi
  done

  if [ ! -s "$SCRIPT_DIR/configs/services.txt" ]; then
    log_warn 'configs/services.txt is empty; account lockdown has no reviewed service-account allowlist'
  fi
  if [ -z "$TCP_PORTS" ] && [ -z "$UDP_PORTS" ]; then
    log_warn 'No CCDC_TCP_PORTS/CCDC_UDP_PORTS set; firewall apply will be refused'
  fi

  _free_kb=$(df -Pk "$SCRIPT_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
  [ -n "${_free_kb:-}" ] && log_info "Workspace free space: $((_free_kb / 1024)) MiB"

  for _cmd in awk find grep sed sort tar; do
    have_cmd "$_cmd" || { log_error "Required command missing: $_cmd"; _problems=$((_problems + 1)); }
  done
  for _cmd in sha256sum ss ip lsof ausearch journalctl; do
    have_cmd "$_cmd" || log_warn "Optional collection command missing: $_cmd"
  done

  if [ "$_problems" -gt 0 ]; then
    die "Preflight found $_problems blocking problem(s)"
  fi
  log_ok 'Preflight completed; review warnings above'
}

if [ "$COMMAND" = backup ]; then
  [ -f "$SCRIPT_DIR/tools/backup_create.sh" ] || die 'Backup tool is missing'
  exec sh "$SCRIPT_DIR/tools/backup_create.sh" "$@"
fi

parse_args "$@"

case "$COMMAND" in
  help|-h|--help) usage ;;
  version|--version) printf '%s\n' "$VERSION" ;;
  list) list_stages ;;
  check) check_repo ;;
  plan) print_plan ;;
  audit|hunt)
    require_root
    [ -z "$SELECTED" ] || die "$COMMAND does not accept apply profiles or stages"
    append_stage triage
    append_stage user-inventory
    append_stage service-inventory
    append_stage service-check
    append_stage process-hunt
    append_stage persistence-hunt
    append_stage permission-audit
    append_stage database-audit
    append_stage docker-audit
    append_stage observability-audit
    append_stage web-audit
    if [ "$COMMAND" = hunt ]; then
      append_stage package-verify
      append_stage c2-hunt
      append_stage rootkit-hunt
      append_stage connection-hunt
    fi
    prepare_output
    run_selected
    log_info "Results: $OUTPUT_DIR (pass=$PASSED fail=$FAILED skip=$SKIPPED)"
    [ "$FAILED" -eq 0 ]
    ;;
  apply)
    [ -n "$SELECTED" ] || die 'apply requires a profile or at least one stage'
    [ "$YES" -eq 1 ] || die 'State changes require --yes after reviewing "setup.sh plan ..."'
    for _stage in $SELECTED; do
      _info=$(stage_info "$_stage") || die "Unknown stage: $_stage"
      case "${_info%%|*}" in read-only*) die "Read-only stage $_stage belongs in audit/hunt" ;; esac
    done
    case " $SELECTED " in
      *' firewall '*)
        [ -n "$TCP_PORTS$UDP_PORTS" ] || die 'firewall requires --tcp-ports and/or --udp-ports'
        sh "$SCRIPT_DIR/firewall.sh" --plan --tcp-ports "$TCP_PORTS" --udp-ports "$UDP_PORTS" ||
          die 'Firewall input preflight failed; no apply stages were run'
        ;;
    esac
    require_root
    [ "$(uname -s 2>/dev/null)" = Linux ] || die "Apply supports Linux only"
    prepare_output
    acquire_lock
    if [ "$NO_SNAPSHOT" -eq 0 ]; then
      run_stage snapshot || die 'Pre-change snapshot failed; use --no-snapshot only with another verified recovery method'
    fi
    run_selected
    log_info "Results: $OUTPUT_DIR (pass=$PASSED fail=$FAILED skip=$SKIPPED)"
    [ "$FAILED" -eq 0 ]
    ;;
  *)
    log_error "Unknown command: $COMMAND"
    usage >&2
    exit 2
    ;;
esac

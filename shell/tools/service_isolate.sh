#!/bin/sh
set -u
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/../lib/portable.sh"
ACTION=plan MODE=sandbox SERVICE='' INIT='' RUNTIME=docker CONTAINER=''
VALIDATE='' HEALTH='' LOGGING='' OUTPUT='' YES=0 REVIEWED=0
usage() {
  cat <<'EOF'
Usage: service_isolate.sh [--plan|--audit|--apply --yes] --mode sandbox|container
  --service NAME --init systemd|openrc
  --validate /absolute/native-config-check --health-check /absolute/health-check
  --logging-check /absolute/logging-and-edr-check --reviewed
  [--runtime docker|podman --container PREPARED_STOPPED_CONTAINER]
  --output /absolute/NEW_PRIVATE_DIRECTORY

Default plan is read-only and does not execute operator probes. Apply requires
all three executable probes, --reviewed and a new output directory. Probes receive
pre or post (rollback receives pre), run with a 30-second timeout, and must return
zero. Their output is suppressed to avoid exposing secrets. The logging probe
must verify actual service log delivery and required EDR visibility.

--reviewed acknowledges scored ports, mounts/data, dependencies, service users,
native config, telemetry, restart effects and console recovery were reviewed.
Sandbox adds NoNewPrivileges=yes and RestrictSUIDSGID=yes to a new systemd drop-in;
OpenRC sandbox is unsupported. Container mode starts an existing stopped,
operator-prepared container after stopping the source service. It never builds,
creates, pulls, removes containers, or changes boot enablement/restart policies.
Prepare the container with reviewed isolation, explicit ports/data/logging and
restart=no. Review socket/dependency activation and reboot behavior separately.
Rollback: sh OUTPUT/rollback.sh --apply --yes (also attempted on apply failure).
EOF
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --plan|--audit) ACTION=plan ;;
    --apply) ACTION=apply ;;
    --yes) YES=1 ;;
    --reviewed) REVIEWED=1 ;;
    --mode|--service|--init|--runtime|--container|--validate|--health-check|--logging-check|--output)
      key=$1; shift; [ "$#" -gt 0 ] || die "$key requires a value"
      case "$key" in
        --mode) MODE=$1 ;; --service) SERVICE=$1 ;; --init) INIT=$1 ;;
        --runtime) RUNTIME=$1 ;; --container) CONTAINER=$1 ;;
        --validate) VALIDATE=$1 ;; --health-check) HEALTH=$1 ;;
        --logging-check) LOGGING=$1 ;; --output) OUTPUT=$1 ;;
      esac ;;
    --help|-h) usage; exit 0 ;;
    *) die 'Unknown option; see --help' ;;
  esac
  shift
done
case "$MODE" in sandbox|container) ;; *) die 'Invalid mode' ;; esac
case "$INIT" in systemd|openrc) ;; *) die 'Explicit --init systemd|openrc required' ;; esac
case "$SERVICE" in ''|-*|*[!A-Za-z0-9_.@-]*) die 'Invalid service name' ;; esac
case "$RUNTIME" in docker|podman) ;; *) die 'Invalid container runtime' ;; esac
if [ "$MODE" = sandbox ]; then
  [ "$INIT" = systemd ] || die 'Sandbox mode requires systemd; OpenRC is unsupported'
  case "$SERVICE" in *.service) ;; *) SERVICE=$SERVICE.service ;; esac
else
  case "$CONTAINER" in ''|-*|*[!A-Za-z0-9_.-]*) die 'Explicit prepared container name required' ;; esac
fi
if [ "$ACTION" = plan ]; then
  printf 'PLAN: %s service %s using %s. No changes or probes executed.\n' "$MODE" "$SERVICE" "$INIT"
  usage
  exit 0
fi
[ "$YES" = 1 ] && [ "$REVIEWED" = 1 ] || die 'Apply requires --yes and --reviewed'
require_root
[ "$(uname -s)" = Linux ] || die 'Linux required'
have_cmd timeout || die 'timeout utility required'
for probe in "$VALIDATE" "$HEALTH" "$LOGGING"; do
  case "$probe" in /*) ;; *) die 'Three absolute executable probe paths required' ;; esac
  [ -f "$probe" ] && [ -x "$probe" ] || die 'Probe missing or not executable'
done
case "$OUTPUT" in /*) ;; *) die 'A new absolute --output directory is required' ;; esac
svc() {
  if [ "$INIT" = systemd ]; then timeout 45 systemctl "$1" "$SERVICE" >/dev/null 2>&1
  else timeout 45 rc-service "$SERVICE" "$1" >/dev/null 2>&1; fi
}
active() { if [ "$INIT" = systemd ]; then svc is-active; else svc status; fi; }
probes() {
  for probe in "$VALIDATE" "$HEALTH" "$LOGGING"; do
    timeout 30 "$probe" "$1" >/dev/null 2>&1 || return 1
  done
}
active || die 'Source service must already be running'
probes pre || die 'Pre-change configuration, health or telemetry check failed'
DROPIN="/etc/systemd/system/$SERVICE.d/90-ccdc-isolation.conf"
if [ "$MODE" = sandbox ]; then
  have_cmd systemd-analyze || die 'systemd-analyze required'
  [ ! -e "$DROPIN" ] && [ ! -L "$DROPIN" ] || die 'Dedicated drop-in already exists; preserve it and review manually'
else
  have_cmd "$RUNTIME" || die 'Container runtime unavailable'
  state=$(timeout 30 "$RUNTIME" inspect --format '{{.State.Running}}|{{.HostConfig.Privileged}}|{{.HostConfig.PidMode}}|{{.HostConfig.NetworkMode}}|{{.HostConfig.RestartPolicy.Name}}|{{.HostConfig.AutoRemove}}' "$CONTAINER" 2>/dev/null) || die 'Prepared container not found'
  case "$state" in 'false|false|'*) ;; *) die 'Container must be stopped and unprivileged' ;; esac
  case "$state" in *'|host|'*|*'|true') die 'Host PID/network or auto-remove containers are unsupported' ;; esac
  case "$state" in *'|no|false'|*'||false') ;; *) die 'Container restart policy must be no' ;; esac
fi
umask 077
mkdir "$OUTPUT" || die 'Output must be a new directory with an existing parent'
chmod 700 "$OUTPUT" || die 'Cannot protect output'
LOCK=/run/ccdc-service-isolate.lock
mkdir "$LOCK" 2>/dev/null || die 'Isolation lock exists; another operation may be running'
trap 'rmdir "$LOCK" 2>/dev/null || true' 0
quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
{
  printf '#!/bin/sh\nset -eu\n'
  printf '[ "${1:-}" = --apply ] && [ "${2:-}" = --yes ] || { echo "Requires --apply --yes" >&2; exit 1; }\n'
  for key in MODE INIT SERVICE RUNTIME CONTAINER DROPIN VALIDATE HEALTH LOGGING; do
    case "$key" in MODE) value=$MODE ;; INIT) value=$INIT ;; SERVICE) value=$SERVICE ;; RUNTIME) value=$RUNTIME ;; CONTAINER) value=$CONTAINER ;; DROPIN) value=$DROPIN ;; VALIDATE) value=$VALIDATE ;; HEALTH) value=$HEALTH ;; LOGGING) value=$LOGGING ;; esac
    printf '%s=' "$key"; quote "$value"; printf '\n'
  done
  cat <<'EOF'
[ "$(id -u)" = 0 ] || exit 1
if [ "$MODE" = container ]; then
  timeout 45 "$RUNTIME" stop "$CONTAINER" >/dev/null 2>&1 || exit 1
else
  if [ -e "$DROPIN" ] || [ -L "$DROPIN" ]; then
    [ ! -L "$DROPIN" ] || exit 1
    [ "$(cat "$DROPIN")" = "$(printf '[Service]
NoNewPrivileges=yes
RestrictSUIDSGID=yes
')" ] || { echo 'Drop-in changed; manual review required' >&2; exit 1; }
    rm -f "$DROPIN"
  fi
  timeout 45 systemctl daemon-reload >/dev/null 2>&1
fi
if [ "$INIT" = systemd ]; then
  timeout 45 systemctl restart "$SERVICE" >/dev/null 2>&1
  timeout 30 systemctl is-active "$SERVICE" >/dev/null 2>&1
else
  timeout 45 rc-service "$SERVICE" restart >/dev/null 2>&1
  timeout 30 rc-service "$SERVICE" status >/dev/null 2>&1
fi
for probe in "$VALIDATE" "$HEALTH" "$LOGGING"; do
  timeout 30 "$probe" pre >/dev/null 2>&1 || exit 1
done
echo 'Rollback health and telemetry checks passed'
EOF
} >"$OUTPUT/rollback.sh" || die 'Cannot write rollback'
chmod 600 "$OUTPUT/rollback.sh" || die 'Cannot protect rollback'
sh -n "$OUTPUT/rollback.sh" || die 'Rollback syntax invalid'
changed=0
recover() {
  code=$?
  trap - 0 HUP INT TERM
  if [ "$changed" = 1 ]; then
    if sh "$OUTPUT/rollback.sh" --apply --yes >"$OUTPUT/rollback-result.txt" 2>&1; then
      log_warn 'Apply failed; rollback health and telemetry checks passed'
    else log_error "Rollback failed; use console recovery and $OUTPUT/rollback.sh"; fi
  fi
  rmdir "$LOCK" 2>/dev/null || true
  exit "$code"
}
trap recover 0
trap 'exit 1' HUP INT TERM
if [ "$MODE" = sandbox ]; then
  mkdir -p "$(dirname "$DROPIN")" || die 'Cannot create drop-in directory'
  changed=1
  (set -C; printf '[Service]\nNoNewPrivileges=yes\nRestrictSUIDSGID=yes\n' >"$DROPIN") || die 'Cannot create dedicated drop-in'
  timeout 30 systemd-analyze verify "$SERVICE" >/dev/null 2>&1 || die 'Native systemd validation failed'
  timeout 45 systemctl daemon-reload >/dev/null 2>&1 || die 'Reload failed'
  svc restart || die 'Service restart failed'
  active || die 'Service is not active'
  [ "$(timeout 30 systemctl show "$SERVICE" --property=NoNewPrivileges --value)" = yes ] || die 'NoNewPrivileges was not applied'
  [ "$(timeout 30 systemctl show "$SERVICE" --property=RestrictSUIDSGID --value)" = yes ] || die 'RestrictSUIDSGID was not applied'
else
  changed=1
  svc stop || die 'Source service stop failed'
  active && die 'Source service remains active'
  timeout 45 "$RUNTIME" start "$CONTAINER" >/dev/null 2>&1 || die 'Container start failed'
  [ "$(timeout 30 "$RUNTIME" inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = true ] || die 'Container is not running'
fi
probes post || die 'Post-change configuration, health or telemetry check failed'
printf 'PASS: native configuration, service health and logging/EDR probes\n' >"$OUTPUT/result.txt" || die 'Cannot record result'
changed=0
log_ok "Isolation applied; rollback: sh $OUTPUT/rollback.sh --apply --yes"

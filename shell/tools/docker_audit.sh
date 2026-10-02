#!/bin/sh
# Read-only Docker daemon and container security survey.

set -u

SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
# shellcheck source=../lib/portable.sh
. "$SCRIPT_DIR/../lib/portable.sh"

MAX_CONTAINERS=${CCDC_DOCKER_MAX_CONTAINERS:-128}
MAX_SECONDS=${CCDC_DOCKER_AUDIT_TIMEOUT:-60}
MAX_OUTPUT_KB=${CCDC_DOCKER_AUDIT_MAX_KB:-4096}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --max-containers) shift; [ "$#" -gt 0 ] || die '--max-containers requires N'; MAX_CONTAINERS=$1 ;;
    --max-containers=*) MAX_CONTAINERS=${1#*=} ;;
    --timeout) shift; [ "$#" -gt 0 ] || die '--timeout requires N'; MAX_SECONDS=$1 ;;
    --timeout=*) MAX_SECONDS=${1#*=} ;;
    --max-output-kb) shift; [ "$#" -gt 0 ] || die '--max-output-kb requires N'; MAX_OUTPUT_KB=$1 ;;
    --max-output-kb=*) MAX_OUTPUT_KB=${1#*=} ;;
    -h|--help)
      printf 'Usage: %s [--max-containers N] [--timeout N] [--max-output-kb N]\n' "$0"
      printf '%s\n' 'Defaults: 128 containers, 60 seconds, and 4096 KiB output.'
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done
case "$MAX_CONTAINERS" in ''|*[!0-9]*) die 'max-containers must be numeric' ;; esac
[ "$MAX_CONTAINERS" -ge 1 ] && [ "$MAX_CONTAINERS" -le 4096 ] || die 'max-containers must be 1..4096'
case "$MAX_SECONDS" in ''|*[!0-9]*) die 'timeout must be numeric' ;; esac
[ "$MAX_SECONDS" -ge 1 ] && [ "$MAX_SECONDS" -le 600 ] || die 'timeout must be 1..600 seconds'
case "$MAX_OUTPUT_KB" in ''|*[!0-9]*) die 'max-output-kb must be numeric' ;; esac
[ "$MAX_OUTPUT_KB" -ge 64 ] && [ "$MAX_OUTPUT_KB" -le 16384 ] || die 'max-output-kb must be 64..16384'

if [ "${CCDC_DOCKER_AUDIT_RUNNING:-0}" != 1 ]; then
  have_cmd timeout || die 'timeout is required for a bounded Docker audit'
  umask 077
  _buffer=$(mktemp "${TMPDIR:-/tmp}/ccdc-docker-audit.XXXXXX") || die 'Cannot allocate private output buffer'
  trap 'rm -f "$_buffer"' 0
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  export CCDC_DOCKER_AUDIT_RUNNING=1
  (ulimit -f "$((MAX_OUTPUT_KB * 2))" || exit 2
   timeout -s TERM -k 5 "$MAX_SECONDS" sh "$0" \
     --max-containers "$MAX_CONTAINERS" --timeout "$MAX_SECONDS" --max-output-kb "$MAX_OUTPUT_KB") >"$_buffer" 2>&1
  _status=$?
  cat "$_buffer"
  rm -f "$_buffer"
  trap - 0 HUP INT TERM 2>/dev/null || true
  case "$_status" in
    124|137|143) printf '%s\n' '[WARN] Docker-audit deadline reached; coverage is incomplete' >&2 ;;
    153) printf '%s\n' '[WARN] Docker-audit output cap reached; coverage is incomplete' >&2 ;;
  esac
  exit "$_status"
fi

if ! have_cmd docker; then
  log_warn 'Docker is not installed; no container coverage'
  exit 2
fi
if ! docker info >/dev/null 2>&1; then
  log_warn 'Docker daemon is unavailable or access is denied; no container coverage'
  exit 1
fi
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ccdc-docker-audit-work.XXXXXX") || die 'Cannot create private Docker-audit workspace'
cleanup() { rm -f "$WORK_DIR"/* 2>/dev/null || true; rmdir "$WORK_DIR" 2>/dev/null || true; }
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' HUP TERM

printf '%s\n' '=== DOCKER DAEMON ==='
printf 'Bounds: containers=%s seconds=%s output_kib=%s. Environment, labels, event attributes, and daemon-config values are suppressed.\n' "$MAX_CONTAINERS" "$MAX_SECONDS" "$MAX_OUTPUT_KB"
docker version --format 'client={{.Client.Version}} server={{.Server.Version}}' 2>/dev/null || true
docker info --format 'root={{.DockerRootDir}} driver={{.Driver}} cgroup={{.CgroupDriver}} security={{json .SecurityOptions}} live_restore={{.LiveRestoreEnabled}}' 2>/dev/null || true

printf '\n%s\n' '=== SOCKET AND CONFIGURATION ==='
ls -ld /var/run/docker.sock /etc/docker /etc/docker/daemon.json 2>/dev/null || true
if [ -f /etc/docker/daemon.json ]; then
  printf '%s\n' '[INFO] daemon.json values suppressed; review the protected file locally'
  sha256_file /etc/docker/daemon.json 2>/dev/null || true
fi
if ss -H -lntp 2>/dev/null | grep -E ':(2375|2376)[[:space:]]' >/dev/null; then
  printf '%s\n' '[HIGH] Docker API is listening on TCP 2375/2376; verify TLS and network restriction'
fi

printf '\n%s\n' '=== IMAGES ==='
docker image ls --digests --no-trunc 2>/dev/null | head -n "$MAX_CONTAINERS" || true

printf '\n%s\n' '=== CONTAINER INVENTORY AND RISK FLAGS ==='
docker ps -aq >"$WORK_DIR/container-ids" 2>/dev/null || die 'Cannot list containers'
IDS=$(head -n "$MAX_CONTAINERS" "$WORK_DIR/container-ids")
if [ -z "$IDS" ]; then
  printf '%s\n' '[INFO] No containers exist'
  exit 0
fi

for _id in $IDS; do
  _summary=$(docker inspect --format 'name={{.Name}} id={{.Id}} image={{.Config.Image}} user={{if .Config.User}}{{.Config.User}}{{else}}root(default){{end}} privileged={{.HostConfig.Privileged}} readonly={{.HostConfig.ReadonlyRootfs}} pid={{.HostConfig.PidMode}} network={{.HostConfig.NetworkMode}} ipc={{.HostConfig.IpcMode}} restart={{.HostConfig.RestartPolicy.Name}} security={{json .HostConfig.SecurityOpt}} cap_add={{json .HostConfig.CapAdd}}' "$_id" 2>/dev/null || true)
  printf '\n%s\n' "$_summary"
  docker port "$_id" 2>/dev/null || true

  _privileged=$(docker inspect --format '{{.HostConfig.Privileged}}' "$_id" 2>/dev/null || printf false)
  [ "$_privileged" = true ] && printf '%s\n' '  [CRITICAL] privileged container'
  _pidmode=$(docker inspect --format '{{.HostConfig.PidMode}}' "$_id" 2>/dev/null || true)
  [ "$_pidmode" = host ] && printf '%s\n' '  [HIGH] host PID namespace'
  _netmode=$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$_id" 2>/dev/null || true)
  [ "$_netmode" = host ] && printf '%s\n' '  [HIGH] host network namespace'
  _ipcmode=$(docker inspect --format '{{.HostConfig.IpcMode}}' "$_id" 2>/dev/null || true)
  [ "$_ipcmode" = host ] && printf '%s\n' '  [HIGH] host IPC namespace'

  docker inspect --format '{{range .Mounts}}{{println .Source "->" .Destination "rw=" .RW}}{{end}}' "$_id" 2>/dev/null |
    while IFS= read -r _mount; do
      [ -n "$_mount" ] || continue
      printf '  mount: %s\n' "$_mount"
      case "$_mount" in
        /var/run/docker.sock*|/run/docker.sock*) printf '%s\n' '  [CRITICAL] Docker socket mounted into container' ;;
        '/ -> '*|'/etc -> '*|'/proc -> '*|'/sys -> '*|'/dev -> '*) printf '%s\n' '  [HIGH] sensitive host path mounted into container' ;;
      esac
    done

  _caps=$(docker inspect --format '{{json .HostConfig.CapAdd}}' "$_id" 2>/dev/null || true)
  case "$_caps" in
    *SYS_ADMIN*|*SYS_MODULE*|*SYS_PTRACE*|*DAC_READ_SEARCH*|*NET_ADMIN*)
      printf '  [HIGH] powerful added capability: %s\n' "$_caps"
      ;;
  esac
  _devices=$(docker inspect --format '{{json .HostConfig.Devices}}' "$_id" 2>/dev/null || true)
  [ "$_devices" = null ] || [ "$_devices" = '[]' ] || [ -z "$_devices" ] || printf '  [REVIEW] host devices: %s\n' "$_devices"
done

printf '\n%s\n' '=== GLOBALLY PUBLISHED PORTS ==='
docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | grep -E '0\.0\.0\.0|\[::\]' || true

printf '\n%s\n' '=== RECENT EVENTS (LAST HOUR) ==='
_since=$(date -d '1 hour ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')
docker events --since "$_since" --until "$(date '+%Y-%m-%dT%H:%M:%S')" \
  --format '{{.Time}} type={{.Type}} action={{.Action}} actor={{.Actor.ID}}' 2>/dev/null |
  head -n 500 || true

printf '\n%s\n' '[INFO] Confirm business need before changing a container. This report intentionally omits environment, label, event-attribute, and daemon-configuration values.'

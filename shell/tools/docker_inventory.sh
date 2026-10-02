#!/bin/sh
set -u
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
. "$SCRIPT_DIR/../lib/portable.sh"
case "${1:-}" in
  -h|--help) printf 'Usage: %s\nRead-only container names, ports and Compose labels.\n' "$0"; exit 0 ;;
  '') ;;
  *) die "Unknown argument: $1" ;;
esac
have_cmd docker || { log_error 'Docker client unavailable; no coverage'; exit 2; }
docker info >/dev/null 2>&1 || die 'Docker daemon unavailable or access denied'
IDS=$(docker ps -q) || die 'Cannot list running containers'
printf '%s\n' '=== RUNNING CONTAINERS, PORTS AND COMPOSE LABELS ==='
STATUS=0
for container_id in $IDS; do
  docker inspect --format 'name={{.Name}} ports={{json .NetworkSettings.Ports}} compose_directory={{index .Config.Labels "com.docker.compose.project.working_dir"}} compose_files={{index .Config.Labels "com.docker.compose.project.config_files"}}' "$container_id" || STATUS=1
done
[ -n "$IDS" ] || printf '%s\n' '[INFO] No running containers'
exit "$STATUS"

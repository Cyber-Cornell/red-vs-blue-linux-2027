#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
ACTION=${1:-}
case "$ACTION" in
  check|plan|audit|hunt|apply|backup|tool) shift ;;
  *)
    printf '%s\n' 'Usage: ./ansible/run.sh check|plan|audit|hunt|apply|backup|tool -i INVENTORY [ansible-playbook options]' >&2
    exit 2 ;;
esac
command -v ansible-playbook >/dev/null 2>&1 || {
  printf '%s\n' 'ansible-playbook is required on the controller' >&2
  exit 2
}
exec ansible-playbook "$SCRIPT_DIR/playbooks/$ACTION.yml" "$@"

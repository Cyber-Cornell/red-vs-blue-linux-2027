#!/bin/sh
set -u
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
. "$SCRIPT_DIR/../lib/portable.sh"
case "${1:---audit}" in
  --plan|-h|--help)
    printf '%s\n' 'Usage: falco_harden.sh [--audit|--plan]' 'Read-only version and local-rules validation.'
    printf '%s\n' 'No apply mode: review engine compatibility, output rate limits, candidate config and rollback before changes.'
    printf '%s\n' 'This tool never changes immutable flags or restarts Falco.' 'https://falco.org/docs/reference/daemon/cli-arguments/'
    exit 0
    ;;
  --audit) ;;
  *) die 'Only --audit and --plan are supported; automatic Falco mutation is disabled' ;;
esac
[ "$#" -le 1 ] || die 'Unexpected arguments'
have_cmd falco || { log_error 'Falco unavailable; no coverage'; exit 2; }
falco --version || exit 1
[ -f /etc/falco/falco_rules.local.yaml ] || { log_error 'Local Falco rules unavailable; no rules validation'; exit 2; }
falco --validate /etc/falco/falco_rules.local.yaml

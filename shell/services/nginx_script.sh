#!/bin/sh
set -u
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
. "$SCRIPT_DIR/../lib/portable.sh"
case "${1:---audit}" in
  --plan|-h|--help)
    printf '%s\n' 'Usage: nginx_script.sh [--audit|--plan]' 'Validates the current nginx configuration and reports version without reloading.'
    printf '%s\n' 'Review server_tokens off; retain scored locations, upstreams, certificates and service identity.'
    printf '%s\n' 'No apply mode: prepare a site-specific backup/change/rollback plan, run nginx -t, then coordinate reload and scoring checks.'
    printf '%s\n' 'https://nginx.org/en/docs/switches.html'
    exit 0
    ;;
  --audit) ;;
  *) die 'Only --audit and --plan are supported; automatic nginx mutation is disabled' ;;
esac
[ "$#" -le 1 ] || die 'Unexpected arguments'
have_cmd nginx || { log_error 'nginx unavailable; no coverage'; exit 2; }
nginx -v || exit 1
nginx -t

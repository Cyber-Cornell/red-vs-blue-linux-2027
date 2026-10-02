#!/bin/sh
set -u
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
. "$SCRIPT_DIR/../lib/portable.sh"
case "${1:---audit}" in
  --plan|-h|--help)
    printf '%s\n' 'Usage: apache_script.sh [--audit|--plan]' 'Read-only Apache configuration validation, virtual hosts and modules.'
    printf '%s\n' 'Review ServerTokens Prod and ServerSignature Off; retain scored virtual hosts, handlers and service identity.'
    printf '%s\n' 'No apply mode: prepare a site-specific backup/change/rollback plan and validate with apachectl -t before reload.'
    printf '%s\n' 'https://httpd.apache.org/docs/2.4/programs/apachectl.html'
    exit 0
    ;;
  --audit) ;;
  *) die 'Only --audit and --plan are supported; automatic Apache mutation is disabled' ;;
esac
[ "$#" -le 1 ] || die 'Unexpected arguments'
if have_cmd apache2ctl; then APACHE=apache2ctl
elif have_cmd apachectl; then APACHE=apachectl
else log_error 'Apache control utility unavailable; no coverage'; exit 2
fi
STATUS=0
"$APACHE" -t || STATUS=1
"$APACHE" -S || STATUS=1
"$APACHE" -M || STATUS=1
exit "$STATUS"

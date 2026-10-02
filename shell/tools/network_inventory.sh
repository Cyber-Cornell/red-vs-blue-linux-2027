#!/bin/sh
set -u
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
. "$SCRIPT_DIR/../lib/portable.sh"
case "${1:-}" in
  -h|--help) printf 'Usage: %s\nRead-only local interfaces, routes, neighbors and listeners. No active scans.\n' "$0"; exit 0 ;;
  '') ;;
  *) die 'Remote targets and active scanning are unsupported; this tool inventories only the local host' ;;
esac
STATUS=0
printf '%s\n' '=== LOCAL INTERFACES AND ROUTES ==='
if have_cmd ip; then
  ip address show || STATUS=1
  ip route show || STATUS=1
  ip -6 route show || STATUS=1
  printf '\n%s\n' '=== NEIGHBOR CACHE (NO PROBES) ==='
  ip neigh show || STATUS=1
elif have_cmd ifconfig; then
  ifconfig -a || STATUS=1
  if have_cmd route; then route -n || STATUS=1; fi
else
  log_warn 'No interface inventory utility available'; STATUS=1
fi
printf '\n%s\n' '=== LOCAL LISTENERS ==='
if have_cmd ss; then ss -lntup || STATUS=1
elif have_cmd netstat; then netstat -lntup || STATUS=1
else log_warn 'No socket inventory utility available'; STATUS=1
fi
printf '\n%s\n' '=== LOCAL RESOLVER CONFIGURATION ==='
if [ -r /etc/resolv.conf ]; then sed -n '1,100p' /etc/resolv.conf; else STATUS=1; fi
exit "$STATUS"

#!/bin/sh
set -u
case "${1:---plan}" in
  --plan|-h|--help)
    printf '%s\n' 'Usage: teleport.sh [--plan|--audit]' 'Automatic Teleport configuration/firewall/restart changes are disabled.'
    printf '%s\n' 'Audit reports installed version and service state using a live systemd or OpenRC manager.'
    printf '%s\n' 'https://goteleport.com/docs/reference/deployment/config/'
    exit 0 ;;
  --audit) ;;
  *) printf '%s\n' 'Only --plan and --audit are supported' >&2; exit 1 ;;
esac
command -v teleport >/dev/null 2>&1 || { printf '%s\n' 'Teleport unavailable; no coverage' >&2; exit 2; }
teleport version || exit 1
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  systemctl is-active -- teleport.service
elif command -v rc-service >/dev/null 2>&1; then
  rc-service teleport status
else
  printf '%s\n' 'No supported live init manager; service state unknown' >&2
  exit 2
fi

#!/bin/sh
set -u
case "${1:---plan}" in
  --plan|-h|--help)
    printf '%s\n' 'Usage: wazuh_agent_setup.sh [--plan|--audit]' 'Agent installation and repository changes are not automated.'
    printf '%s\n' 'Review the exact package version/signature, manager identity and enrollment process. Audit only queries service state.'
    printf '%s\n' 'https://documentation.wazuh.com/current/installation-guide/wazuh-agent/index.html'
    exit 0 ;;
  --audit) ;;
  *) printf '%s\n' 'Only --plan and --audit are supported; automatic installation is disabled' >&2; exit 1 ;;
esac
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  systemctl is-active -- wazuh-agent.service
elif command -v rc-service >/dev/null 2>&1; then
  rc-service wazuh-agent status
else
  printf '%s\n' 'No supported live init manager; service state unknown' >&2
  exit 2
fi

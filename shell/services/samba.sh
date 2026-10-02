#!/bin/sh
set -u
case "${1:---plan}" in
  --plan|-h|--help)
    printf '%s\n' 'Usage: samba.sh [--plan|--audit]' 'Automatic Samba hardening is disabled; preserve shares, authentication and scored clients.'
    printf '%s\n' 'Audit validates and reports configured shares with testparm. Review the report before sharing it.'
    printf '%s\n' 'https://www.samba.org/samba/docs/current/man-html/testparm.1.html'
    exit 0 ;;
  --audit) command -v testparm >/dev/null 2>&1 || { printf '%s\n' 'testparm unavailable; no coverage' >&2; exit 2; }; testparm -s ;;
  *) printf '%s\n' 'Only --plan and --audit are supported; no configuration or process changes' >&2; exit 1 ;;
esac

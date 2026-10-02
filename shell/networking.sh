#!/bin/sh
set -u
case "${1:---audit}" in
  --audit|--plan) ;;
  --help|-h) printf 'Usage: %s [--audit|--plan]\n' "$0"; exit 0 ;;
  *) printf '%s\n' 'Resolver replacement was retired. Configure DNS through the host network manager after reviewing scored dependencies.' >&2; exit 1 ;;
esac
[ "$#" -le 1 ] || exit 1
printf '%s\n' 'Resolver configuration (read-only):'
ls -ld /etc/resolv.conf || exit 1
cat /etc/resolv.conf || exit 1
if command -v resolvectl >/dev/null 2>&1; then resolvectl status || exit 1; fi
printf '%s\n' 'Review internal DNS, search domains and resolver ownership before any change.'

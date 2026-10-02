#!/bin/sh
set -u
case "${1:---audit}" in
  --audit|--plan) ;;
  --help|-h) printf 'Usage: %s [--audit|--plan]\n' "$0"; exit 0 ;;
  *) printf '%s\n' 'Automatic policy resets and distro migration were retired. Review holds, repository trust and policy files individually.' >&2; exit 1 ;;
esac
[ "$#" -le 1 ] || exit 1
printf '%s\n' 'Package policy file metadata (read-only):'
for root in /etc/apt /etc/dnf /etc/yum.repos.d /etc/apk; do
  [ -d "$root" ] || continue
  find "$root" -xdev -type f -exec ls -ld {} \; || exit 1
done
if command -v apt-mark >/dev/null 2>&1; then
  printf '\nHeld packages:\n'
  apt-mark showhold || exit 1
fi
if [ -f /etc/apk/world ]; then printf '\nAlpine world constraints:\n'; cat /etc/apk/world || exit 1; fi

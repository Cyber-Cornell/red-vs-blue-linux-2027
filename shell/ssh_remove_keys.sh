#!/bin/sh
set -u
case "${1:---audit}" in
  --audit|--plan) ;;
  --help|-h) printf 'Usage: %s [--audit|--plan]\n' "$0"; exit 0 ;;
  *) printf '%s\n' 'Blanket SSH key deletion was retired. Review specific keys and test replacement access before revocation.' >&2; exit 1 ;;
esac
[ "$#" -le 1 ] || exit 1
printf '%s\n' 'SSH key-file metadata (read-only; no private key contents):'
for root in /etc/ssh /root /home; do
  [ -d "$root" ] || continue
  find "$root" -xdev -type f \( -name authorized_keys -o -name authorized_keys2 -o -name known_hosts -o -name 'ssh_host_*_key' -o -name 'ssh_host_*.pub' \) -exec ls -ld {} \; || exit 1
done

#!/bin/sh
set -u
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd) || exit 1
. "$SCRIPT_DIR/lib/portable.sh"
case "${0##*/}" in
  package_remove.sh) ACTION=remove ;;
  package_reinstall.sh) ACTION=reinstall ;;
  *) ACTION=install ;;
esac
MODE=plan
YES=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --plan) MODE=plan; shift ;;
    --apply) MODE=apply; shift ;;
    --yes) YES=1; shift ;;
    --help|-h)
      printf 'Usage: %s [--plan | --apply --yes] -- PACKAGE [PACKAGE ...]\n' "$0"
      printf '%s\n' 'Explicit names only. Review native preview and snapshot before apply.'
      printf '%s\n' 'Dependencies and package scripts may change services; no automatic rollback.'
      exit 0 ;;
    --) shift; break ;;
    *) die 'Use -- followed by explicit package names' ;;
  esac
done
[ "$#" -gt 0 ] || die 'At least one explicit package name is required; nothing changed'
for package in "$@"; do
  case "$package" in ''|[-.]*|*+|*-|*[!a-zA-Z0-9+_.:/-]*) die "Invalid package name: $package" ;; esac
done
[ "$(uname -s)" = Linux ] || die 'Package operations support Linux only'
FAMILY=$(sed -n 's/^ID=//p; s/^ID_LIKE=//p' /etc/os-release 2>/dev/null | tr -d "\"'" | tr '\n' ' ')
MANAGER=''
case " $FAMILY " in
  *' gentoo '*) MANAGER=emerge ;;
  *' alpine '*) MANAGER=apk ;;
  *' debian '*|*' ubuntu '*|*' kali '*) MANAGER=apt-get ;;
  *' arch '*|*' manjaro '*) MANAGER=pacman ;;
  *' suse '*|*' opensuse '*|*' opensuse-leap '*|*' opensuse-tumbleweed '*|*' sles '*) MANAGER=zypper ;;
  *' rhel '*|*' fedora '*|*' centos '*) if have_cmd dnf; then MANAGER=dnf; else MANAGER=yum; fi ;;
esac
if [ -z "$MANAGER" ]; then
  for candidate in apk apt-get dnf yum pacman zypper emerge; do
    if have_cmd "$candidate"; then MANAGER=$candidate; break; fi
  done
fi
[ -n "$MANAGER" ] && have_cmd "$MANAGER" || die 'The detected distribution has no supported package manager available'
[ "$MANAGER" != apt-get ] || MANAGER=apt
for package in "$@"; do
  if [ "$MANAGER" = emerge ]; then
    case "$package" in *.ebuild|*.tbz2|*.gpkg.tar) die 'Package archives and ebuild paths are not accepted' ;; esac
    printf '%s\n' "$package" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9+_.-]*/[A-Za-z0-9][A-Za-z0-9+_.-]*$' || die 'Gentoo requires explicit category/package names (no sets, paths, operators or slots)'
  else
    case "$package" in */*) die 'Category/package syntax is supported only for Gentoo' ;; esac
  fi
done
printf 'Action: %s; manager: %s; packages:' "$ACTION" "$MANAGER"
printf ' %s' "$@"
printf '\n'
if [ "$MODE" = apply ]; then
  [ "$YES" -eq 1 ] || die 'Apply requires --yes'
  require_root
fi
case "$MANAGER:$ACTION:$MODE" in
  emerge:install:plan) emerge --ignore-default-opts --autounmask=n --autounmask-write=n --ask=n --pretend --verbose --noreplace "$@" ;;
  emerge:install:apply) emerge --ignore-default-opts --autounmask=n --autounmask-write=n --ask=n --noreplace "$@" ;;
  emerge:reinstall:plan) emerge --ignore-default-opts --autounmask=n --autounmask-write=n --ask=n --pretend --verbose --oneshot "$@" ;;
  emerge:reinstall:apply) emerge --ignore-default-opts --autounmask=n --autounmask-write=n --ask=n --oneshot "$@" ;;
  emerge:remove:plan) emerge --ignore-default-opts --autounmask=n --autounmask-write=n --ask=n --pretend --verbose --depclean --deselect=n "$@" ;;
  emerge:remove:apply) emerge --ignore-default-opts --autounmask=n --autounmask-write=n --ask=n --depclean --deselect=n "$@" ;;
  apk:install:plan) apk --simulate add "$@" ;;
  apk:remove:plan) apk --simulate del "$@" ;;
  apk:reinstall:plan) apk --simulate fix --reinstall "$@" ;;
  apk:install:apply) apk add "$@" ;;
  apk:remove:apply) apk del "$@" ;;
  apk:reinstall:apply) apk fix --reinstall "$@" ;;
  apt:install:plan) apt-get --simulate --no-remove install "$@" ;;
  apt:remove:plan) apt-get --simulate remove "$@" ;;
  apt:reinstall:plan) apt-get --simulate --no-remove --reinstall install "$@" ;;
  apt:install:apply) apt-get --no-remove install "$@" ;;
  apt:remove:apply) apt-get remove "$@" ;;
  apt:reinstall:apply) apt-get --no-remove --reinstall install "$@" ;;
  dnf:*:plan|yum:*:plan)
    printf '%s\n' 'Native preview may return nonzero when --assumeno declines.'
    "$MANAGER" --assumeno "$ACTION" "$@" ;;
  dnf:*:apply|yum:*:apply) "$MANAGER" "$ACTION" "$@" ;;
  pacman:install:plan|pacman:reinstall:plan) pacman -S --print "$@" ;;
  pacman:remove:plan) pacman -R --print "$@" ;;
  pacman:install:apply|pacman:reinstall:apply) pacman -S "$@" ;;
  pacman:remove:apply) pacman -R "$@" ;;
  zypper:install:plan) zypper --no-refresh install --dry-run "$@" ;;
  zypper:remove:plan) zypper --no-refresh remove --dry-run "$@" ;;
  zypper:reinstall:plan) zypper --no-refresh install --dry-run --force "$@" ;;
  zypper:install:apply) zypper --no-refresh install "$@" ;;
  zypper:remove:apply) zypper --no-refresh remove "$@" ;;
  zypper:reinstall:apply) zypper --no-refresh install --force "$@" ;;
esac
status=$?
[ "$status" -eq 0 ] || { log_error "Package transaction/preview exited $status"; exit "$status"; }
log_ok "Package $MODE completed"

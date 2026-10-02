#!/bin/sh
set -u
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/../lib/portable.sh"
PATH_ARG=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --path) shift; [ "$#" -gt 0 ] || die '--path requires one path'; PATH_ARG=$1 ;;
    --help|-h) printf 'Usage: %s [--path PATH]\nLists attributes on reviewed critical paths only; never recurses.\n' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done
have_cmd lsattr && have_cmd timeout || die 'lsattr and timeout are required'
if [ -n "$PATH_ARG" ]; then
  case "$PATH_ARG" in /*) ;; *) die 'Use an absolute path' ;; esac
  set -- "$PATH_ARG"
else
  set -- /etc/fstab /etc/passwd /etc/group /etc/shadow /etc/gshadow /etc/sudoers /etc/ssh/sshd_config /etc/ld.so.preload /etc/hosts /etc/resolv.conf /etc/systemd/system /etc/init.d
fi
RESULT=0
for path do
  if [ -L "$path" ]; then printf '[REFUSE] symlink %s\n' "$path"; continue; fi
  if [ ! -e "$path" ]; then printf '[ABSENT] %s\n' "$path"; continue; fi
  if attributes=$(timeout 2 lsattr -d "$path" 2>&1); then
    printf '%s\n' "$attributes"
    flags=$(printf '%s\n' "$attributes" | awk 'NR==1 {print $1}')
    case "$flags" in *i*|*a*) printf '[REVIEW] immutable/append-only on %s; confirm intended policy before clearing\n' "$path" ;; esac
  else
    printf '[UNAVAILABLE] %s: %s\n' "$path" "$attributes"
    RESULT=1
  fi
done
exit "$RESULT"

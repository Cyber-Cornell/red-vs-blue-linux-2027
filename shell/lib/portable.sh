#!/bin/sh
# lib/portable.sh - POSIX helpers

is_tty() { [ -t 1 ]; }

log_info() {
  if is_tty; then
    printf '\033[0;32m[INFO]\033[0m %s\n' "$*"
  else
    printf '[INFO] %s\n' "$*"
  fi
}

log_warn() {
  if is_tty; then
    printf '\033[0;33m[WARN]\033[0m %s\n' "$*"
  else
    printf '[WARN] %s\n' "$*"
  fi
}

log_err() {
  if is_tty; then
    printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2
  else
    printf '[ERROR] %s\n' "$*" >&2
  fi
}

require_root() {
  if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
    log_err "This script must be run as root."
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

backup_file() {
  _f=$1
  [ -f "$_f" ] || return 0
  cp "$_f" "${_f}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
}

# portable sed-in-place: sedi 's/x/y/' file
sedi() {
  _expr=$1
  _file=$2

  [ -f "$_file" ] || return 0

  _tmp="${_file}.tmp.$$"
  sed "$_expr" "$_file" >"$_tmp" && cat "$_tmp" >"$_file"
  rm -f "$_tmp"
}

# append line if missing (exact match)
ensure_line() {
  _line=$1
  _file=$2
  [ -f "$_file" ] || : >"$_file"
  grep -F -x "$_line" "$_file" >/dev/null 2>&1 || printf '%s\n' "$_line" >>"$_file"
}

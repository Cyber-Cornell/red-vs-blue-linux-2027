#!/bin/sh
# Shared POSIX helpers. This file is sourced; do not enable shell options here.

is_tty() { [ -t 1 ]; }

_log() {
  _level=$1
  _color=$2
  shift 2
  if is_tty; then
    printf '\033[%sm[%s]\033[0m %s\n' "$_color" "$_level" "$*"
  else
    printf '[%s] %s\n' "$_level" "$*"
  fi
}

log_info() { _log INFO '0;36' "$@"; }
log_ok() { _log OK '0;32' "$@"; }
log_warn() { _log WARN '0;33' "$@" >&2; }
log_error() { _log ERROR '0;31' "$@" >&2; }
log_err() { log_error "$@"; }

die() {
  log_error "$*"
  exit 1
}

require_root() {
  if [ "$(id -u 2>/dev/null || printf 1)" -ne 0 ]; then
    die 'This command must be run as root.'
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

utc_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z'
}

backup_file() {
  _backup_source=$1
  [ -e "$_backup_source" ] || return 0
  _backup_stamp=$(date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null || date '+%Y%m%d_%H%M%S')
  _backup_target="${_backup_source}.bak.${_backup_stamp}"
  _backup_n=0
  while [ -e "$_backup_target" ]; do
    _backup_n=$((_backup_n + 1))
    _backup_target="${_backup_source}.bak.${_backup_stamp}.${_backup_n}"
  done
  cp -p "$_backup_source" "$_backup_target"
  printf '%s\n' "$_backup_target"
}

# Portable sed-in-place: sedi 's/x/y/' file
sedi() {
  _sedi_expr=$1
  _sedi_file=$2
  [ -f "$_sedi_file" ] || return 0
  _sedi_tmp="${_sedi_file}.tmp.$$"
  if sed "$_sedi_expr" "$_sedi_file" >"$_sedi_tmp"; then
    cat "$_sedi_tmp" >"$_sedi_file"
    rm -f "$_sedi_tmp"
    return 0
  fi
  rm -f "$_sedi_tmp"
  return 1
}

ensure_line() {
  _ensure_line=$1
  _ensure_file=$2
  [ -f "$_ensure_file" ] || : >"$_ensure_file"
  grep -F -x "$_ensure_line" "$_ensure_file" >/dev/null 2>&1 ||
    printf '%s\n' "$_ensure_line" >>"$_ensure_file"
}

sha256_file() {
  if have_cmd sha256sum; then
    sha256sum "$1"
  elif have_cmd shasum; then
    shasum -a 256 "$1"
  elif have_cmd openssl; then
    openssl dgst -sha256 "$1"
  else
    return 127
  fi
}

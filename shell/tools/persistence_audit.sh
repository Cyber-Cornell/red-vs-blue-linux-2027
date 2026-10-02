#!/bin/sh
# Read-only Linux persistence survey with bounded output.

set -u
umask 077

SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
# shellcheck source=../lib/portable.sh
. "$SCRIPT_DIR/../lib/portable.sh"

require_root
[ "$(uname -s 2>/dev/null)" = Linux ] || die 'This persistence hunter supports Linux only'
MAX_LINES=${CCDC_AUDIT_MAX_LINES:-5000}
case "$MAX_LINES" in ''|*[!0-9]*) die 'CCDC_AUDIT_MAX_LINES must be numeric' ;; esac
[ "$MAX_LINES" -ge 1 ] && [ "$MAX_LINES" -le 20000 ] || die 'CCDC_AUDIT_MAX_LINES must be 1..20000'
MAX_SECONDS=${CCDC_PERSISTENCE_TIMEOUT:-60}
MAX_OUTPUT_KB=${CCDC_PERSISTENCE_MAX_KB:-4096}
case "$MAX_SECONDS:$MAX_OUTPUT_KB" in *[!0-9:]*|:*|*:) die 'Persistence limits must be numeric' ;; esac
[ "$MAX_SECONDS" -ge 1 ] && [ "$MAX_SECONDS" -le 600 ] || die 'CCDC_PERSISTENCE_TIMEOUT must be 1..600'
[ "$MAX_OUTPUT_KB" -ge 64 ] && [ "$MAX_OUTPUT_KB" -le 16384 ] || die 'CCDC_PERSISTENCE_MAX_KB must be 64..16384'

heading() { printf '\n===== %s =====\n' "$1"; }
metadata_lead() {
  _lead=$1
  _path=$2
  case "$_path" in *[![:print:]]*) return 0 ;; esac
  [ "${#_path}" -le 512 ] || return 0
  _metadata=$(stat -c 'uid=%u gid=%g mode=%a size=%s mtime=%Y' "$_path" 2>/dev/null) || return 0
  printf '[REVIEW] kind=%s path=%s %s ' "$_lead" "$_path" "$_metadata"
  _bytes=$(stat -c %s "$_path" 2>/dev/null || printf 0)
  if [ "$_bytes" -le 1048576 ] 2>/dev/null && have_cmd sha256sum; then
    _digest=$(timeout 2 sha256sum "$_path" 2>/dev/null) && printf 'sha256=%s\n' "${_digest%% *}" || printf '%s\n' 'sha256=unavailable'
  else
    printf '%s\n' 'sha256=skipped-size-or-tool-limit'
  fi
}
matching_file_leads() {
  _lead=$1
  _pattern=$2
  shift 2
  grep -RIlE "$_pattern" "$@" 2>/dev/null | head -n "$MAX_LINES" |
    while IFS= read -r _match; do metadata_lead "$_lead" "$_match"; done
}
GIT_ONLY=0 GIT_ROOT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --git-hooks-only) GIT_ONLY=1; shift ;;
    --git-root)
      [ "$#" -ge 2 ] || die '--git-root requires a directory'
      GIT_ROOT=$2; shift 2 ;;
    --help|-h)
      printf '%s\n' 'Usage: persistence_audit.sh [--git-hooks-only] [--git-root ABS_DIR]'
      printf '%s\n' 'Whole-run defaults: 60 seconds and 4096 KiB output; tune with CCDC_PERSISTENCE_TIMEOUT and CCDC_PERSISTENCE_MAX_KB.'
      printf '%s\n' 'Git default roots: /root /home /srv /opt /var/www; override selects one existing subtree of these roots.'
      printf '%s\n' 'Git scope: 15 seconds, depth 8, 100 .git directories, 32 hooks each, 1 MiB per hash, 128 KiB output.'
      exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
if [ -n "$GIT_ROOT" ]; then
  [ -d "$GIT_ROOT" ] && [ ! -L "$GIT_ROOT" ] || die 'Git root must be an existing real directory'
  GIT_ROOT=$(CDPATH= cd -P "$GIT_ROOT" && pwd) || exit 1
  case "$GIT_ROOT" in /root|/root/*|/home|/home/*|/srv|/srv/*|/opt|/opt/*|/var/www|/var/www/*) ;; *) die 'Git root must be under a documented standard root' ;; esac
fi
if [ "${CCDC_PERSISTENCE_RUNNING:-0}" != 1 ]; then
  have_cmd timeout || die 'timeout is required for bounded persistence review'
  _buffer=$(mktemp "${TMPDIR:-/tmp}/ccdc-persistence.XXXXXX") || die 'Cannot allocate private output buffer'
  trap 'rm -f "$_buffer"' 0
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  set --
  [ "$GIT_ONLY" -eq 0 ] || set -- "$@" --git-hooks-only
  [ -z "$GIT_ROOT" ] || set -- "$@" --git-root "$GIT_ROOT"
  export CCDC_PERSISTENCE_RUNNING=1 CCDC_AUDIT_MAX_LINES="$MAX_LINES"
  export CCDC_PERSISTENCE_TIMEOUT="$MAX_SECONDS" CCDC_PERSISTENCE_MAX_KB="$MAX_OUTPUT_KB"
  (ulimit -f "$((MAX_OUTPUT_KB * 2))" || exit 2; timeout -s TERM -k 5 "$MAX_SECONDS" sh "$0" "$@") >"$_buffer" 2>&1
  _status=$?
  cat "$_buffer"
  rm -f "$_buffer"
  trap - 0 HUP INT TERM 2>/dev/null || true
  [ "$_status" -ne 153 ] || printf '%s\n' '[WARN] Persistence output cap reached; coverage is incomplete' >&2
  exit "$_status"
fi
git_hooks() {
  heading 'EXECUTABLE GIT HOOKS (HEURISTIC REVIEW LEADS)'
  printf '%s\n' 'Bounds: 15s, depth 8, 100 .git directories, 32 hooks/repository, 1MiB/hash, 128KiB output; no hook execution or contents.'
  printf '%s\n' 'Scope excludes bare repositories, gitdir files/worktrees, symlink hooks, custom core.hooksPath, control-character/long paths and deeper repositories.'
  have_cmd timeout && have_cmd sha256sum || { log_warn 'Git hook inventory requires timeout and sha256sum'; return; }
  if [ -n "$GIT_ROOT" ]; then set -- "$GIT_ROOT"; else set -- /root /home /srv /opt /var/www; fi
  LC_ALL=C timeout -s TERM -k 2 15 sh -c '
    find "$@" -xdev -maxdepth 8 -type d -name .git -prune -exec sh -c '\''
      for directory do
        case "$directory" in *[![:print:]]*) continue ;; esac
        [ "${#directory}" -le 512 ] && printf "%s\n" "$directory"
      done
    '\'' sh {} + 2>/dev/null | head -n 100 |
    while IFS= read -r gitdir; do
      [ -d "$gitdir/hooks" ] && [ ! -L "$gitdir/hooks" ] || continue
      find "$gitdir/hooks" -maxdepth 1 -type f ! -name "*.sample" \( -perm -0100 -o -perm -0010 -o -perm -0001 \) -exec sh -c '\''
        for hook do
          case "$hook" in *[![:print:]]*) continue ;; esac
          [ "${#hook}" -le 512 ] && printf "%s\n" "$hook"
        done
      '\'' sh {} + 2>/dev/null | head -n 32 |
      while IFS= read -r hook; do
        [ -f "$hook" ] && [ ! -L "$hook" ] || continue
        bytes=$(stat -c %s "$hook" 2>/dev/null) || continue
        case "$bytes" in ""|*[!0-9]*) continue ;; esac
        metadata=$(stat -c "uid=%u gid=%g mode=%a size=%s mtime=%Y" "$hook" 2>/dev/null) || continue
        printf "[REVIEW] hook=%s %s " "$hook" "$metadata"
        if [ "$bytes" -le 1048576 ]; then
          digest=$(timeout -s TERM -k 1 2 sha256sum "$hook" 2>/dev/null) && printf "sha256=%s\n" "${digest%% *}" || printf "sha256=unavailable\n"
        else printf "sha256=skipped-size-limit\n"; fi
      done
    done
  ' sh "$@" | head -c 131072
  printf '\n%s\n' '[INFO] Git inventory is bounded and may be partial; hashes and executable bits are review leads, not malware verdicts.'
}
if [ "$GIT_ONLY" = 1 ]; then git_hooks; exit 0; fi

heading 'DYNAMIC LINKER AND PAM'
if [ -s /etc/ld.so.preload ]; then
  printf '%s\n' '[CRITICAL] /etc/ld.so.preload is active; contents suppressed'
  metadata_lead dynamic-linker-preload /etc/ld.so.preload
else
  printf '%s\n' '[OK] /etc/ld.so.preload is absent or empty'
fi
matching_file_leads pam-execution '(^|[[:space:]])pam_exec\.so|pam_script|pam_python' /etc/pam.d /etc/pam.conf

heading 'CRON, ANACRON, AND AT'
for _cron in /etc/crontab /etc/anacrontab /etc/cron.d/* /var/spool/cron/* /var/spool/cron/crontabs/*; do
  [ -f "$_cron" ] || continue
  metadata_lead scheduled-task "$_cron"
done
printf '\n--- at queue ---\n'
atq 2>/dev/null || true

heading 'SYSTEMD SERVICES, TIMERS, AND GENERATORS'
systemctl list-timers --all --no-pager 2>/dev/null || true
printf '\n--- enabled units ---\n'
systemctl list-unit-files --state=enabled --no-pager 2>/dev/null || true
printf '\n--- local/run unit files and symlinks ---\n'
find /etc/systemd/system /run/systemd/system /usr/local/lib/systemd/system /etc/systemd/system-generators \
  \( -type f -o -type l \) -exec ls -ld {} \; 2>/dev/null |
  LC_ALL=C sort | head -n "$MAX_LINES"
printf '\n--- suspicious unit directives ---\n'
matching_file_leads suspicious-unit-directive '(^|[=[:space:]])(/tmp/|/var/tmp/|/dev/shm/|curl[[:space:]]|wget[[:space:]]|nc[[:space:]]|ncat[[:space:]]|socat[[:space:]]|bash[[:space:]]+-c)' \
  /etc/systemd/system /run/systemd/system /usr/lib/systemd/system /lib/systemd/system

heading 'USER SYSTEMD AND DESKTOP AUTOSTART'
find /root/.config/systemd /home/*/.config/systemd /etc/systemd/user /usr/local/lib/systemd/user \
  /root/.config/autostart /home/*/.config/autostart /etc/xdg/autostart /var/lib/systemd/linger \
  \( -type f -o -type l \) -exec ls -ld {} \; 2>/dev/null | head -n "$MAX_LINES"

heading 'SYSV, OPENRC, RUNIT, AND RC.LOCAL'
if have_cmd rc-status; then rc-status -a 2>&1 || log_warn 'OpenRC status unavailable'; fi
if have_cmd rc-update; then rc-update show 2>&1 || log_warn 'OpenRC runlevel inventory unavailable'; fi
ls -la /etc/init.d /etc/rc*.d /etc/local.d /etc/runit /etc/sv /etc/rc.local 2>/dev/null | head -n "$MAX_LINES" || true
for _startup in /etc/rc.local /etc/rc.d/rc.local /etc/local.d/*.start; do
  [ -f "$_startup" ] || continue
  metadata_lead startup-script "$_startup"
done

heading 'SHELL AND ENVIRONMENT STARTUP'
find /etc/profile /etc/profile.d /etc/bash.bashrc /etc/bashrc /root /home -xdev -maxdepth 3 -type f \
  \( -name '*.sh' -o -name '.profile' -o -name '.bash_profile' -o -name '.bashrc' -o -name '.zshrc' -o -name '.config.fish' \) \
  -exec ls -ld {} \; 2>/dev/null | head -n "$MAX_LINES"
matching_file_leads shell-startup-network-or-loader '(curl|wget|/dev/tcp|nc[[:space:]]|ncat|socat|base64[[:space:]]+-d|LD_PRELOAD|PROMPT_COMMAND|trap[[:space:]])' \
  /etc/profile /etc/profile.d /etc/bash.bashrc /etc/bashrc /root/.profile /root/.bashrc /home/*/.profile /home/*/.bashrc

heading 'SSH AUTHORIZATION AND DAEMON HOOKS'
for _ssh_file in /root/.ssh/authorized_keys /root/.ssh/authorized_keys2 /root/.ssh/rc /root/.ssh/environment \
  /home/*/.ssh/authorized_keys /home/*/.ssh/authorized_keys2 /home/*/.ssh/rc /home/*/.ssh/environment; do
  [ -f "$_ssh_file" ] && [ ! -L "$_ssh_file" ] || continue
  metadata_lead ssh-user-hook "$_ssh_file"
  case "$_ssh_file" in
    */authorized_keys|*/authorized_keys2)
      awk '
        /^[[:space:]]*(#|$)/ {next}
        {
          key="unknown"; options="yes"
          for (i=1; i<=NF; i++) if ($i ~ /^(ssh-|ecdsa-|sk-)/) {key=$i; if (i==1) options="no"; break}
          printf "[REVIEW] authorized-key line=%d key_type=%s options_present=%s values_suppressed=yes\n", NR, key, options
        }
      ' "$_ssh_file" | head -n "$MAX_LINES"
      ;;
  esac
done
matching_file_leads ssh-daemon-hook '^[[:space:]]*(AuthorizedKeysCommand|AuthorizedKeysFile|ForceCommand|PermitUserEnvironment|PermitRootLogin|AllowUsers|DenyUsers)' \
  /etc/ssh/sshd_config /etc/ssh/sshd_config.d

heading 'SUDOERS AND POLKIT'
matching_file_leads sudo-policy '^[[:space:]]*[^#].*(NOPASSWD|SETENV|ALL[[:space:]]*=)' /etc/sudoers /etc/sudoers.d
find /etc/polkit-1/rules.d /usr/share/polkit-1/rules.d -type f -exec ls -ld {} \; 2>/dev/null | head -n "$MAX_LINES"

heading 'KERNEL, UDEV, AND MODULE LOAD PERSISTENCE'
lsmod 2>/dev/null || true
find /etc/modules-load.d /etc/modprobe.d /etc/udev/rules.d /usr/lib/modules-load.d /usr/lib/udev/rules.d \
  -type f -exec ls -ld {} \; 2>/dev/null | head -n "$MAX_LINES"
matching_file_leads udev-or-module-hook '(RUN\+=|PROGRAM=|install[[:space:]].*(curl|wget|sh|bash|python|perl)|blacklist[[:space:]])' \
  /etc/udev/rules.d /etc/modprobe.d

heading 'CONTAINER AND PACKAGE-MANAGER PERSISTENCE'
if have_cmd docker; then
  docker ps -aq 2>/dev/null | while IFS= read -r _cid; do
    [ -n "$_cid" ] || continue
    docker inspect --format 'name={{.Name}} image={{.Config.Image}} restart={{.HostConfig.RestartPolicy.Name}} privileged={{.HostConfig.Privileged}} pid={{.HostConfig.PidMode}} network={{.HostConfig.NetworkMode}}' "$_cid" 2>/dev/null
  done
fi
find /etc/apt/apt.conf.d /etc/dnf /etc/yum /etc/pacman.d/hooks /etc/apk /etc/kernel/postinst.d \
  -type f -exec ls -ld {} \; 2>/dev/null | head -n "$MAX_LINES"

git_hooks

heading 'RECENT STARTUP AND POLICY CHANGES (7 DAYS)'
find /etc/systemd /etc/init.d /etc/cron.d /etc/profile.d /etc/pam.d /etc/sudoers.d /etc/ssh /etc/udev /etc/modprobe.d \
  -xdev -type f -mtime -7 -exec ls -ld {} \; 2>/dev/null |
  LC_ALL=C sort | head -n "$MAX_LINES"

printf '\n%s\n' '[INFO] Findings are leads. Correlate ownership, package provenance, timestamps, logs, and service purpose before containment.'

#!/bin/sh
set -eu
umask 077
usage() {
    cat <<'EOF'
Usage: opencode_install.sh (--version EXACT_V1_VERSION | --agent-only) [options]
  --apply --yes          Perform the displayed plan (nonroot Linux user only).
  --replace-agent        Back up and replace a differing ccdc-defender.md.
  --min-free-mb N        Preflight free space (default: 768 install, 8 agent-only).
  --timeout-seconds N    npm time limit, 1-3600 (default: 300).
  --help                Show usage.
Default is a local plan: no network requests or filesystem changes.
The npm package runs its official postinstall script. Space checks are not quotas.
Version must be an exact V1 version, e.g. 1.4.0; verify its availability first.
Agent-only writes the V1 prompt for an already installed OpenCode V1 CLI.
V1 is required for the current oh-my-openagent plugin; V2 is incompatible.
EOF
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
value() { [ "$#" -ge 2 ] && [ -n "$2" ] || die "Missing value for $1"; }
version= agent_only=no apply=no yes=no replace=no min_mb= seconds=300
while [ "$#" -gt 0 ]; do
    case "$1" in
        --version) value "$@"; version=$2; shift 2 ;;
        --agent-only) agent_only=yes; shift ;;
        --apply) apply=yes; shift ;;
        --yes) yes=yes; shift ;;
        --replace-agent) replace=yes; shift ;;
        --min-free-mb) value "$@"; min_mb=$2; shift 2 ;;
        --timeout-seconds) value "$@"; seconds=$2; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
if [ "$agent_only" = yes ]; then
    [ -z "$version" ] || die '--agent-only and --version are mutually exclusive'
    min_mb=${min_mb:-8}
else
    printf '%s\n' "$version" | LC_ALL=C grep -Eq '^1\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$' || die 'Supply --agent-only or an exact V1 --version (no tags/ranges)'
    min_mb=${min_mb:-768}
fi
case "$min_mb:$seconds" in *[!0-9:]*|:*|*:) die 'Space/time limits must be positive integers' ;; esac
[ "${#min_mb}" -le 6 ] && [ "$min_mb" -ge 1 ] && [ "$min_mb" -le 999999 ] || die 'Invalid --min-free-mb'
[ "${#seconds}" -le 4 ] && [ "$seconds" -ge 1 ] && [ "$seconds" -le 3600 ] || die 'Invalid --timeout-seconds'
[ "$apply" != yes ] || [ "$yes" = yes ] || die '--apply requires --yes'
case "${HOME:-}" in /*) ;; *) die 'HOME must be an absolute Linux path' ;; esac
case "$HOME" in *[![:print:]]*|*/../*|*/..|*/./*|*/.) die 'HOME contains unsupported path components' ;; esac
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
prompt=$script_dir/../configs/opencode_ccdc_defender.md
[ -f "$prompt" ] && [ ! -L "$prompt" ] || die 'Bundled defender prompt is missing or a symlink'
base=$HOME/.local/share/ccdc-opencode
agent_dir=$HOME/.config/opencode/agents
agent=$agent_dir/ccdc-defender.md
mode=plan
[ "$apply" != yes ] || mode=apply
printf 'MODE=%s\nAGENT=%s\nMIN_FREE_MB=%s\n' "$mode" "$agent" "$min_mb"
if [ "$agent_only" != yes ]; then
    printf 'PACKAGE=opencode-ai@%s\nPREFIX=%s/%s\nTIMEOUT_SECONDS=%s\n' "$version" "$base" "$version" "$seconds"
fi
[ "$apply" = yes ] || { printf 'PLAN ONLY: add --apply --yes to install.\n'; exit 0; }
[ "$(uname -s)" = Linux ] || die 'Apply is supported on Linux only'
uid=$(id -u)
[ "$uid" != 0 ] || die 'Run as the intended nonroot operator; do not use sudo'

safe_dir() {
    [ ! -L "$1" ] || die "Refusing symlink directory: $1"
    [ ! -e "$1" ] || [ -d "$1" ] || die "Not a directory: $1"
    if [ -d "$1" ]; then
        [ "$(stat -c %u "$1")" = "$uid" ] || die "Directory is not owned by this user: $1"
        mode=$(stat -c %a "$1")
        [ $((0$mode & 0022)) -eq 0 ] || die "Directory is writable by other users: $1"
    fi
}
safe_dir "$HOME"
[ -d "$HOME" ] || die 'HOME does not exist'
for directory in "$HOME/.local" "$HOME/.local/share" "$base" "$HOME/.config" "$HOME/.config/opencode" "$agent_dir"; do
    safe_dir "$directory"
done
[ ! -L "$agent" ] || die 'Refusing a symlink agent file'
if [ -e "$agent" ]; then
    [ -f "$agent" ] && [ "$(stat -c %u "$agent")" = "$uid" ] || die 'Existing agent must be an owned regular file'
    cmp -s "$prompt" "$agent" || [ "$replace" = yes ] || die 'Existing agent differs; use --replace-agent to preserve a backup and replace it'
fi
free_kb=$(df -Pk "$HOME" | awk 'END {print $4}')
case "$free_kb" in ''|*[!0-9]*) die 'Unable to determine free disk space' ;; esac
[ "$free_kb" -ge "$((min_mb * 1024))" ] || die "Insufficient free space: ${free_kb}KB; require ${min_mb}MB"
if [ "$agent_only" != yes ]; then
    command -v npm >/dev/null 2>&1 || die 'npm is required; install it using your distro package manager first'
    case "$(command -v npm)" in /mnt/[a-z]/*|*.exe|*.cmd) die 'Use native Linux npm, not a Windows npm on WSL PATH' ;; esac
    command -v timeout >/dev/null 2>&1 || die 'timeout is required to bound the install'
fi
for directory in "$HOME/.local" "$HOME/.local/share" "$base" "$HOME/.config" "$HOME/.config/opencode" "$agent_dir"; do
    [ -d "$directory" ] || mkdir -m 700 "$directory"
done
lock=$base/.install-lock
mkdir "$lock" 2>/dev/null || die "Another install is active, or stale lock needs review: $lock"
work= agent_tmp=
cleanup() {
    [ -z "$agent_tmp" ] || rm -f -- "$agent_tmp"
    case "$work" in "$base"/.work.*) rm -rf -- "$work" ;; esac
    rmdir "$lock" 2>/dev/null || :
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
if [ "$agent_only" != yes ]; then
    prefix=$base/$version
    [ ! -e "$prefix" ] && [ ! -L "$prefix" ] || die "Version directory already exists; review it before reinstalling: $prefix"
    work=$(mktemp -d "$base/.work.XXXXXXXX")
    printf 'Installing official npm package; lifecycle scripts execute as this user.\n'
    timeout "$seconds" npm install --global --prefix "$work/prefix" --cache "$work/cache" --registry https://registry.npmjs.org --no-audit --no-fund --update-notifier=false "opencode-ai@$version" || die 'npm failed/timed out; temporary package and cache removed'
    [ -x "$work/prefix/bin/opencode" ] || die 'npm returned success but no executable opencode was installed'
    installed_version=$(timeout 15 "$work/prefix/bin/opencode" --version) || die 'Installed CLI did not pass its version check'
    [ "$installed_version" = "$version" ] || die "Installed CLI version differs from requested pin: $installed_version"
    mv -- "$work/prefix" "$prefix"
fi
if [ ! -f "$agent" ] || ! cmp -s "$prompt" "$agent"; then
    if [ -f "$agent" ]; then
        backup=$(mktemp "$agent.backup.XXXXXXXX")
        cp -- "$agent" "$backup"
        chmod 600 "$backup"
        printf 'AGENT_BACKUP=%s\n' "$backup"
    fi
    agent_tmp=$(mktemp "$agent_dir/.ccdc-defender.XXXXXXXX")
    cp -- "$prompt" "$agent_tmp"
    chmod 600 "$agent_tmp"
    mv -f -- "$agent_tmp" "$agent"
    agent_tmp=
fi
printf 'Agent installed. In OpenCode select ccdc-defender as the primary agent.\n'
if [ "$agent_only" = yes ]; then
    printf 'Launch from the trusted toolkit directory: opencode --agent ccdc-defender\n'
else
    sh "$script_dir/opencode_omo_plugin.sh" --opencode-version "$version" --apply --yes || die 'OpenCode installed, but automatic OMO plugin setup failed; inspect and retry the plugin helper'
    printf 'Launch from the trusted toolkit directory with this executable:\n%s/bin/opencode --agent ccdc-defender\n' "$prefix"
fi
printf 'Use the same session for triage and reviewed administration. Connect your provider interactively; keep credentials and raw secrets out of prompts.\n'

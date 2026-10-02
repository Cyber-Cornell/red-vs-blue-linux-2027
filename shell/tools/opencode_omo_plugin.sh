#!/bin/sh
set -eu
umask 077

usage() {
  printf '%s\n' 'Usage: opencode_omo_plugin.sh --opencode-version EXACT_V1_VERSION [--apply --yes] [--min-free-mb N]'
  printf '%s\n' 'Installs the pinned oh-my-openagent OpenCode plugin, not the standalone omo binary.'
  printf '%s\n' 'Default is a plan. Apply requires a nonroot Linux user and a fresh OpenCode/OMO configuration.'
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
version= apply=no yes=no min_mb=384
while [ "$#" -gt 0 ]; do
  case "$1" in
    --opencode-version) shift; [ "$#" -gt 0 ] || die 'Missing OpenCode version'; version=$1 ;;
    --min-free-mb) shift; [ "$#" -gt 0 ] || die 'Missing free-space limit'; min_mb=$1 ;;
    --apply) apply=yes ;;
    --yes) yes=yes ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done
printf '%s\n' "$version" | LC_ALL=C grep -Eq '^1\.[0-9]+\.[0-9]+$' || die 'An exact OpenCode 1.x version is required'
case "$min_mb" in ''|*[!0-9]*) die '--min-free-mb must be numeric' ;; esac
[ "$min_mb" -ge 1 ] && [ "$min_mb" -le 4096 ] || die '--min-free-mb must be 1..4096'
[ "$apply" != yes ] || [ "$yes" = yes ] || die '--apply requires --yes'
case "${HOME:-}" in /*) ;; *) die 'HOME must be an absolute Linux path' ;; esac
script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd) || die 'Cannot resolve script location'
host_template=$script_dir/../configs/opencode_omo_host.json
free_template=$script_dir/../configs/opencode_omo_free.json
[ -s "$host_template" ] && [ -s "$free_template" ] || die 'Bundled plugin configuration is missing'
oc_bin=$HOME/.local/share/ccdc-opencode/$version/bin/opencode
bun_dir=$HOME/.local/share/ccdc-bun
bunx=$bun_dir/node_modules/.bin/bunx
oc_config=$HOME/.config/opencode/opencode.json
omo_config=$HOME/.omo/omo.jsonc
printf 'MODE=%s\nOPENCODE=%s\nPLUGIN=oh-my-openagent@5.1.9\nBUN=bun@1.4.2\nFREE_TEXT_MODEL=opencode/big-pickle\nFREE_IMAGE_MODEL=opencode/mimo-v2.6-flash-free\n' "$(if [ "$apply" = yes ]; then printf apply; else printf plan; fi)" "$oc_bin"
[ "$apply" = yes ] || exit 0
[ "$(uname -s)" = Linux ] || die 'Apply supports Linux only'
[ "$(id -u)" -ne 0 ] || die 'Run as the intended nonroot operator'
[ -x "$oc_bin" ] || die 'Pinned OpenCode executable is missing'
command -v timeout >/dev/null 2>&1 || die 'timeout is required'
[ "$(timeout 10 "$oc_bin" --version)" = "$version" ] || die 'OpenCode version does not match'
[ ! -e "$oc_config" ] && [ ! -L "$oc_config" ] || die 'Existing OpenCode config needs manual merge; no plugin changes made'
[ ! -e "$omo_config" ] && [ ! -L "$omo_config" ] || die 'Existing OMO config needs manual merge; no plugin changes made'
command -v npm >/dev/null 2>&1 || die 'Native Linux npm is required for Bun'
case "$(command -v npm)" in /mnt/[a-z]/*|*.exe|*.cmd) die 'Use native Linux npm on WSL' ;; esac
free_kb=$(df -Pk "$HOME" | awk 'END {print $4}')
case "$free_kb" in ''|*[!0-9]*) die 'Cannot determine free space' ;; esac
[ "$free_kb" -ge "$((min_mb * 1024))" ] || die "Need at least $min_mb MiB free for plugin setup"
if [ -e "$bun_dir" ] || [ -L "$bun_dir" ]; then
  [ -x "$bunx" ] || die 'Existing Bun directory is incomplete; review before retrying'
else
  mkdir -m 700 "$bun_dir"
  timeout 180 npm install --prefix "$bun_dir" --registry https://registry.npmjs.org --no-audit --no-fund bun@1.4.2 || die 'Pinned Bun installation failed'
fi
[ -x "$bunx" ] || die 'Bunx executable missing after install'
PATH="$(dirname "$oc_bin"):$(dirname "$bunx"):$PATH"
export PATH
timeout 300 "$bunx" oh-my-openagent@5.1.9 install --no-tui --platform=opencode --claude=no --openai=no --gemini=no --copilot=no --opencode-zen=no --skip-auth || die 'OMO OpenCode plugin installer failed'
[ -f "$oc_config" ] && [ -f "$omo_config" ] || die 'OMO installer did not create expected configuration'
grep -Fq 'oh-my-openagent' "$oc_config" || die 'OMO plugin registration missing'
cp "$host_template" "$oc_config"
cp "$free_template" "$omo_config"
chmod 600 "$oc_config" "$omo_config"
doctor=$(mktemp "$HOME/.config/opencode/ccdc-omo-doctor.XXXXXXXX")
trap 'rm -f "$doctor"' 0
timeout 120 "$bunx" oh-my-openagent@5.1.9 doctor --json >"$doctor" || die 'OMO doctor failed'
grep -Eq '"failed"[[:space:]]*:[[:space:]]*0' "$doctor" || die 'OMO doctor reported a failed check'
grep -Fq 'Plugin loaded: 5.1.9' "$doctor" || die 'Pinned OMO plugin was not loaded'
printf '%s\n' 'Pinned OMO OpenCode plugin loaded; all configured agent/category models use listed free IDs.'
printf '%s\n' 'Free-tier availability and rate limits can change; connect OpenCode Zen directly before model requests.'

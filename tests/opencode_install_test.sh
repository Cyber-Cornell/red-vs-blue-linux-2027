#!/bin/sh
set -eu
[ "${CCDC_OPENCODE_TEST:-}" = 1 ] && [ "$HOME" = /tmp/ccdc-home ] && [ "$(id -u)" = 1000 ] || exit 2
repo=${1:-/repo}
installer=$repo/shell/tools/opencode_install.sh
prompt=$repo/shell/configs/opencode_ccdc_defender.md
base=$HOME/.local/share/ccdc-opencode
agent=$HOME/.config/opencode/agents/ccdc-defender.md
mkdir -p /tmp/mock-bin
cat > /tmp/mock-bin/npm <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$@" > /tmp/npm-argv
[ "${MOCK_NPM_FAIL:-0}" = 0 ] || exit 19
[ "${MOCK_NPM_SLEEP:-0}" = 0 ] || sleep "$MOCK_NPM_SLEEP"
prefix=
version=
while [ "$#" -gt 0 ]; do
    case "$1" in --prefix) prefix=$2; shift 2 ;; opencode-ai@*) version=${1#opencode-ai@}; shift ;; bun@*) version=bun; shift ;; *) shift ;; esac
done
[ -n "$prefix" ]
if [ "$version" = bun ]; then
    mkdir -p "$prefix/node_modules/.bin"
    cat > "$prefix/node_modules/.bin/bunx" <<'BUNX'
#!/bin/sh
set -eu
[ "$1" = oh-my-openagent@5.1.9 ] || exit 8
case "$2" in
    install)
        mkdir -p "$HOME/.config/opencode" "$HOME/.omo"
        printf '{"plugin":["oh-my-openagent@5.1.9"]}\n' > "$HOME/.config/opencode/opencode.json"
        printf '{}\n' > "$HOME/.omo/omo.jsonc" ;;
    doctor)
        printf '{"failed":0,"details":"Plugin loaded: 5.1.9"}\n' ;;
    *) exit 9 ;;
esac
BUNX
    chmod 700 "$prefix/node_modules/.bin/bunx"
    exit 0
fi
printf '%s\n' "opencode-ai@$version" > /tmp/npm-opencode-argv
mkdir -p "$prefix/bin"
printf '#!/bin/sh\nprintf "%s\\n"\n' "${MOCK_VERSION:-$version}" > "$prefix/bin/opencode"
chmod 700 "$prefix/bin/opencode"
EOF
chmod 700 /tmp/mock-bin/npm
PATH=/tmp/mock-bin:$PATH
export PATH
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
refuse() {
    if sh "$installer" "$@" > /tmp/refusal.log 2>&1; then fail "accepted $*"; fi
    cat /tmp/refusal.log
}
sh "$installer" --version 1.4.0
[ ! -e "$HOME/.local" ] && [ ! -e /tmp/npm-argv ] || fail 'plan mutated files'
refuse --version latest
refuse --version 2.0.22
refuse --version 1.4.0 --apply
refuse --agent-only --version 1.4.0
refuse --agent-only --min-free-mb bad
refuse --agent-only --apply --yes --min-free-mb 999999
[ ! -e "$HOME/.local" ] || fail 'space refusal mutated files'
sh "$installer" --agent-only --apply --yes
cmp "$prompt" "$agent"
[ "$(stat -c %a "$agent")" = 600 ] || fail 'agent mode'
printf 'operator prompt\n' > "$agent"
refuse --agent-only --apply --yes
grep -qx 'operator prompt' "$agent" || fail 'overwrote existing prompt'
sh "$installer" --agent-only --apply --yes --replace-agent
cmp "$prompt" "$agent"
grep -l '^operator prompt$' "$agent".backup.* >/dev/null
sh "$installer" --version 1.4.0 --apply --yes --min-free-mb 1
[ -x "$base/1.4.0/bin/opencode" ] || fail 'package executable missing'
grep -qx 'opencode-ai@1.4.0' /tmp/npm-opencode-argv
grep -qx 'https://registry.npmjs.org' /tmp/npm-argv
[ -x "$HOME/.local/share/ccdc-bun/node_modules/.bin/bunx" ] || fail 'plugin bootstrap missing'
grep -Fq '"oh-my-openagent@5.1.9"' "$HOME/.config/opencode/opencode.json" || fail 'plugin not pinned'
grep -Fq 'opencode/big-pickle' "$HOME/.omo/omo.jsonc" || fail 'free model config absent'
[ ! -e "$base/.install-lock" ] || fail 'lock left behind'
refuse --version 1.4.0 --apply --yes --min-free-mb 1
MOCK_NPM_FAIL=1
export MOCK_NPM_FAIL
refuse --version 1.4.1 --apply --yes --min-free-mb 1
[ ! -e "$base/1.4.1" ] && [ ! -e "$base/.install-lock" ] || fail 'failed install retained state'
[ -z "$(find "$base" -name '.work.*')" ] || fail 'cache not cleaned'
MOCK_NPM_FAIL=0 MOCK_VERSION=0.0.0
export MOCK_NPM_FAIL MOCK_VERSION
refuse --version 1.4.2 --apply --yes --min-free-mb 1
[ ! -e "$base/1.4.2" ] || fail 'accepted incorrect CLI version'
[ -z "$(find "$base" -name '.work.*')" ] || fail 'version failure cache not cleaned'
MOCK_NPM_SLEEP=3
export MOCK_NPM_SLEEP
refuse --version 1.4.3 --apply --yes --min-free-mb 1 --timeout-seconds 1
[ ! -e "$base/1.4.3" ] && [ ! -e "$base/.install-lock" ] || fail 'timeout retained state'
[ -z "$(find "$base" -name '.work.*')" ] || fail 'timeout cache not cleaned'
chmod 777 "$HOME/.config"
refuse --agent-only --apply --yes
chmod 700 "$HOME/.config"
mv "$agent" "$agent.saved"
ln -s "$agent.saved" "$agent"
refuse --agent-only --apply --yes --replace-agent
cmp "$prompt" "$agent.saved"
printf 'PASS: plan, validation, free-space refusal, agent-only, backup, pinned install, version check, failure/timeout cleanup, directory/symlink refusal\n'

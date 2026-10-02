#!/bin/sh
set -eu
[ "${CCDC_RESIDUAL_TEST:-}" = 1 ] || exit 2
repo=${1:-/repo}
evidence=${2:-/evidence}
work=$(mktemp -d /tmp/residual.XXXXXX)
export RESIDUAL_FIXTURE=$work
mkdir "$work/bin"
export PATH="$work/bin:$PATH"
cat >"$work/bin/emerge" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$RESIDUAL_FIXTURE/emerge-last"
printf 'called\n' >>"$RESIDUAL_FIXTURE/emerge-calls"
printf 'fixture emerge operation\n'
EOF
cat >"$work/bin/df" <<'EOF'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 99999999 1 99999998 1%% /\n'
EOF
chmod +x "$work/bin/"*
for script in shell/tools/persistence_audit.sh shell/package_install.sh shell/tools/malware_scan.sh; do sh -n "$repo/$script"; done
printf 'PASS sh -n assigned scripts\n'
sh "$repo/shell/package_install.sh" -- app-antivirus/clamav >"$work/package-plan"
grep -qx -- --pretend "$work/emerge-last"
grep -qx -- --autounmask=n "$work/emerge-last"
grep -qx -- --autounmask-write=n "$work/emerge-last"
grep -qx -- --ignore-default-opts "$work/emerge-last"
cp "$work/emerge-last" "$work/package-plan-argv"
calls=$(wc -l <"$work/emerge-calls")
if sh "$repo/shell/package_install.sh" --apply -- app-antivirus/clamav >"$work/package-refused" 2>&1; then exit 1; fi
[ "$(wc -l <"$work/emerge-calls")" = "$calls" ]
sh "$repo/shell/package_install.sh" --apply --yes -- app-antivirus/clamav >"$work/package-apply"
! grep -qx -- --pretend "$work/emerge-last"
grep -qx -- --noreplace "$work/emerge-last"
cp "$work/emerge-last" "$work/package-apply-argv"
for atom in @world /tmp/package app/foo/bar app/foo:0 app/foo.ebuild app/foo.tbz2; do
  if sh "$repo/shell/package_install.sh" -- "$atom" >"$work/package-invalid" 2>&1; then exit 1; fi
done
printf 'PASS Gentoo default pretend, gated apply, explicit category/package validation\n'
sh "$repo/shell/package_remove.sh" -- app-antivirus/clamav >"$work/remove-plan"
grep -qx -- --pretend "$work/emerge-last"
grep -qx -- --depclean "$work/emerge-last"
grep -qx -- --deselect=n "$work/emerge-last"
cp "$work/emerge-last" "$work/remove-plan-argv"
sh "$repo/shell/package_reinstall.sh" -- app-antivirus/clamav >"$work/reinstall-plan"
grep -qx -- --pretend "$work/emerge-last"
grep -qx -- --oneshot "$work/emerge-last"
cp "$work/emerge-last" "$work/reinstall-plan-argv"
printf 'PASS Gentoo wrapper remove/reinstall preview adapters\n'
sh "$repo/shell/package_remove.sh" --apply --yes -- app-antivirus/clamav >"$work/remove-apply"
grep -qx -- --depclean "$work/emerge-last"
! grep -qx -- --pretend "$work/emerge-last"
cp "$work/emerge-last" "$work/remove-apply-argv"
sh "$repo/shell/package_reinstall.sh" --apply --yes -- app-antivirus/clamav >"$work/reinstall-apply"
grep -qx -- --oneshot "$work/emerge-last"
! grep -qx -- --pretend "$work/emerge-last"
cp "$work/emerge-last" "$work/reinstall-apply-argv"
printf 'PASS Gentoo wrapper remove/reinstall gated apply adapters\n'
calls=$(wc -l <"$work/emerge-calls")
sh "$repo/shell/tools/malware_scan.sh" install >"$work/clamav-plan"
[ "$(wc -l <"$work/emerge-calls")" = "$calls" ]
if sh "$repo/shell/tools/malware_scan.sh" install --apply >"$work/clamav-refused" 2>&1; then exit 1; fi
sh "$repo/shell/tools/malware_scan.sh" install --apply --yes --output "$work/clamav-output" >"$work/clamav-apply"
grep -qx app-antivirus/clamav "$work/emerge-last"
grep -qx -- --autounmask-write=n "$work/emerge-last"
! grep -E -- '--sync|--config|--update|@world' "$work/emerge-last"
cp "$work/emerge-last" "$work/clamav-apply-argv"
printf 'PASS Gentoo ClamAV inert plan, apply gate, narrow emerge invocation\n'
mkdir -p '/srv/reviewed repo/.git/hooks'
printf '#!/bin/sh\ntouch /srv/HOOK_EXECUTED\n# SECRET_FIXTURE_NOT_FOR_LOGS\n' >'/srv/reviewed repo/.git/hooks/pre-commit'
cp '/srv/reviewed repo/.git/hooks/pre-commit' '/srv/reviewed repo/.git/hooks/pre-push.sample'
printf 'not executable\n' >'/srv/reviewed repo/.git/hooks/post-commit'
truncate -s 1048577 '/srv/reviewed repo/.git/hooks/oversize'
chmod 700 '/srv/reviewed repo/.git/hooks/pre-commit' '/srv/reviewed repo/.git/hooks/pre-push.sample' '/srv/reviewed repo/.git/hooks/oversize'
ln -s pre-commit '/srv/reviewed repo/.git/hooks/link'
sh "$repo/shell/tools/persistence_audit.sh" --git-hooks-only --git-root /srv >"$work/hooks"
grep -q 'hook=/srv/reviewed repo/.git/hooks/pre-commit' "$work/hooks"
digest=$(sha256sum '/srv/reviewed repo/.git/hooks/pre-commit'); digest=${digest%% *}
grep -q "sha256=$digest" "$work/hooks"
grep -q 'sha256=skipped-size-limit' "$work/hooks"
! grep -E 'SECRET_FIXTURE|HOOK_EXECUTED|hook=.*(pre-push.sample|post-commit|/link)' "$work/hooks"
[ ! -e /srv/HOOK_EXECUTED ]
[ "$(grep -c '^\[REVIEW\]' "$work/hooks")" = 2 ]
if sh "$repo/shell/tools/persistence_audit.sh" --git-hooks-only --git-root /tmp >"$work/hooks-invalid" 2>&1; then exit 1; fi
printf 'PASS Git hooks metadata/digest, no contents/execution, samples/nonexec/symlink exclusions, hash size cap, root guard\n'
i=1
while [ "$i" -le 40 ]; do cp '/srv/reviewed repo/.git/hooks/pre-commit' "/srv/reviewed repo/.git/hooks/hook-$i"; i=$((i+1)); done
sh "$repo/shell/tools/persistence_audit.sh" --git-hooks-only --git-root /srv >"$work/hooks-cap"
[ "$(grep -c '^\[REVIEW\]' "$work/hooks-cap")" -eq 32 ]
printf 'PASS Git per-repository hook cap exactly 32\n'
mkdir -p /srv/cap-repositories
index=1
while [ "$index" -le 110 ]; do
  mkdir -p "/srv/cap-repositories/repo-$index/.git/hooks"
  cp '/srv/reviewed repo/.git/hooks/pre-commit' "/srv/cap-repositories/repo-$index/.git/hooks/pre-commit"
  index=$((index+1))
done
sh "$repo/shell/tools/persistence_audit.sh" --git-hooks-only --git-root /srv/cap-repositories >"$work/hooks-repository-cap"
[ "$(grep -c '^\[REVIEW\]' "$work/hooks-repository-cap")" -eq 100 ]
mkdir -p /srv/depth/a/b/c/d/e/f/g/h/.git/hooks
cp '/srv/reviewed repo/.git/hooks/pre-commit' /srv/depth/a/b/c/d/e/f/g/h/.git/hooks/pre-commit
sh "$repo/shell/tools/persistence_audit.sh" --git-hooks-only --git-root /srv/depth >"$work/hooks-depth"
! grep -q '^\[REVIEW\]' "$work/hooks-depth"
printf 'PASS Git repository cap exactly 100 and depth limit excludes depth9 .git\n'
mkdir -p "$evidence/fixtures"
cp -R "$work/." "$evidence/fixtures/"
printf 'ALL_RESIDUAL_ADAPTERS_PASS\n'

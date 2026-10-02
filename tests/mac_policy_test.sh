#!/bin/sh
set -eu
repo=${1:-/repo}
[ "${CCDC_MAC_TEST:-}" = 1 ] || exit 2
work=$(mktemp -d /tmp/mac-test.XXXXXX)
mkdir "$work/bin"
export MAC_FIXTURE=$work
export PATH="$work/bin:$PATH"
cat >"$work/bin/stat" <<'EOF'
#!/bin/sh
if [ "$2" = %C ]; then cat "$MAC_FIXTURE/context"; else /bin/stat "$@"; fi
EOF
cat >"$work/bin/getenforce" <<'EOF'
#!/bin/sh
printf 'Enforcing\n'
EOF
cat >"$work/bin/chcon" <<'EOF'
#!/bin/sh
printf 'chcon\n' >>"$MAC_FIXTURE/mutations"
if [ "$1" = -t ]; then printf 'system_u:object_r:%s:s0\n' "$2" >"$MAC_FIXTURE/context"; else printf '%s\n' "$2" >"$MAC_FIXTURE/context"; fi
EOF
cat >"$work/bin/systemctl" <<'EOF'
#!/bin/sh
printf 'systemctl %s\n' "$1" >>"$MAC_FIXTURE/service-calls"
EOF
cat >"$work/bin/rc-service" <<'EOF'
#!/bin/sh
printf 'openrc %s\n' "$2" >>"$MAC_FIXTURE/service-calls"
EOF
cat >"$work/bin/aa-status" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$work/bin/apparmor_parser" <<'EOF'
#!/bin/sh
case "$2" in
-Q) [ ! -f "$MAC_FIXTURE/invalid" ] ;;
-N) cat "$MAC_FIXTURE/name" ;;
-a) [ ! -f "$MAC_FIXTURE/loaded" ] || exit 1; touch "$MAC_FIXTURE/loaded"; printf 'add\n' >>"$MAC_FIXTURE/mutations" ;;
-R) rm "$MAC_FIXTURE/loaded"; printf 'remove\n' >>"$MAC_FIXTURE/mutations" ;;
*) exit 9 ;;
esac
EOF
cat >"$work/health" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$work/logcheck" <<'EOF'
#!/bin/sh
[ ! -f "$MAC_FIXTURE/fail-log" ] || [ ! -f "$MAC_FIXTURE/loaded" ] || exit 1
[ ! -f "$MAC_FIXTURE/fail-selinux" ] || ! grep -q reviewed_t "$MAC_FIXTURE/context"
EOF
chmod +x "$work/bin/"* "$work/health" "$work/logcheck"
printf 'fixture\n' >"$work/target"
printf 'system_u:object_r:old_t:s0\n' >"$work/context"
script=$repo/shell/mac_policy.sh
sh -n "$script"
sh "$script" --plan >"$work/plan"
sh "$script" --audit >"$work/audit"
[ ! -e "$work/mutations" ]
printf 'PASS audit and plan have no mutations\n'
if sh "$script" --apply >"$work/refused" 2>&1; then exit 1; fi
grep -q 'require --yes' "$work/refused"
printf 'PASS apply requires --yes\n'
apply() {
    sh "$script" --apply --yes --service reviewed --init "$1" --backend "$2" --path "$work/target" --health-check "$work/health" --log-check "$work/logcheck" "$3" "$4"
}
apply openrc selinux --type reviewed_t >"$work/selinux"
grep -q reviewed_t "$work/context"
state=$(sed -n 's/.*Private rollback state: //p' "$work/selinux")
[ "$(/bin/stat -c %a "$state")" = 700 ]
[ "$(/bin/stat -c %a "$state/context")" = 600 ]
sh "$script" --rollback "$state" --yes >"$work/selinux-rollback"
grep -qx 'system_u:object_r:old_t:s0' "$work/context"
grep -q 'openrc status' "$work/service-calls"
printf 'PASS SELinux one-path apply/exact rollback and OpenRC probes; private state 0700/0600\n'
chmod +x "$work/target"
printf '%s\n' "$work/target {" '}' >"$work/profile"
printf '%s\n' "$work/target" >"$work/name"
apply systemd apparmor --profile "$work/profile" >"$work/apparmor"
[ -f "$work/loaded" ]
state=$(sed -n 's/.*Private rollback state: //p' "$work/apparmor")
if apply systemd apparmor --profile "$work/profile" >"$work/existing" 2>&1; then exit 1; fi
[ -f "$work/loaded" ]
sh "$script" --rollback "$state" --yes >"$work/apparmor-rollback"
[ ! -e "$work/loaded" ]
grep -q 'systemctl restart' "$work/service-calls"
printf 'PASS AppArmor add, existing-profile refusal, rollback, systemd restart/status\n'
touch "$work/fail-log"
if apply openrc apparmor --profile "$work/profile" >"$work/failing-probe" 2>&1; then exit 1; fi
[ ! -e "$work/loaded" ]
grep -q 'rollback and probes passed' "$work/failing-probe"
printf 'PASS failed post-change log probe triggers unload and recovery probes\n'
printf '/different/executable\n' >"$work/name"
if apply systemd apparmor --profile "$work/profile" >"$work/multiple" 2>&1; then exit 1; fi
[ ! -e "$work/loaded" ]
printf 'PASS mismatched executable/profile rejected before mutation\n'
touch "$work/fail-selinux"
if apply systemd selinux --type reviewed_t >"$work/selinux-failing-probe" 2>&1; then exit 1; fi
grep -qx 'system_u:object_r:old_t:s0' "$work/context"
grep -q 'rollback and probes passed' "$work/selinux-failing-probe"
printf 'PASS SELinux failed telemetry probe restores exact original context\n'
printf '%s\n' "$work/target" >"$work/name"
touch "$work/invalid"
if apply systemd apparmor --profile "$work/profile" >"$work/invalid-policy" 2>&1; then exit 1; fi
[ ! -e "$work/loaded" ]
grep -q 'Profile validation failed' "$work/invalid-policy"
printf 'PASS native-parser rejection adapter prevents AppArmor mutation\n'
printf 'Evidence fixture directory: %s\n' "$work"
if [ -n "${2:-}" ]; then
    mkdir -p "$2/fixtures" "$2/states"
    cp -R "$work/." "$2/fixtures/"
    cp -R /var/tmp/ccdc-mac.* "$2/states/"
fi
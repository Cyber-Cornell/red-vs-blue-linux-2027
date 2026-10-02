#!/bin/sh
set -eu
repo=${1:-/repo}
evidence=${2:-/evidence}
work=$(mktemp -d /tmp/yara-inert.XXXXXX)
umask 077
rules=$repo/shell/configs/yara/rit_linux_hunt.yar
yara --version >"$evidence/yara-version.txt"
yarac "$rules" "$work/compiled.yarc"
strings='lobster /lib/selinux.so.3 ld.so.preload Enjoy the shell! gcry_pk_verify'
printf '\177ELF%s\n' "$strings" >"$work/positive"
printf '%s\n' "$strings" >"$work/nonelf"
printf '\177ELFlobster ld.so.preload Enjoy the shell! gcry_pk_verify\n' >"$work/missing-library"
cp "$work/positive" "$work/oversize"
truncate -s 20971520 "$work/oversize"
yara "$rules" "$work/positive" >"$work/positive-result"
grep -q '^RIT_Father_Default_LD_PRELOAD_Rootkit ' "$work/positive-result"
for fixture in nonelf missing-library oversize; do
  yara "$rules" "$work/$fixture" >"$work/$fixture-result"
  [ ! -s "$work/$fixture-result" ]
done
yara "$rules" /bin/busybox >"$work/benign-result"
[ ! -s "$work/benign-result" ]
printf 'PASS native yarac compile and five-string ELF inert positive\n'
printf 'PASS non-ELF, missing-string, size-boundary and BusyBox benign negatives\n'
printf 'No fixture was executable or executed; no malware built or run\n'
mkdir -p "$evidence/yara-fixtures"
cp "$work/positive" "$work/nonelf" "$work/missing-library" "$work/positive-result" "$evidence/yara-fixtures/"
sha256sum "$rules" >"$evidence/yara-rules.sha256"

#!/bin/sh
set -eu
umask 077

usage() {
    printf '%s\n' 'Usage: linpeas_runner.sh [--script ABSOLUTE_PATH --sha256 HEX] [--mode standard|full] [--report-dir ABSOLUTE_PATH] [--minutes 1..180] [--max-mb 1..128] [--apply --yes]'
    printf '%s\n' 'Plans or runs a SHA-256-verified upstream linPEAS release in a bounded, private report.'
    printf '%s\n' 'Full mode passes -a -e -r and may inspect credentials, attempt local account passwords, or run slow checks.'
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
script= hash= mode=standard report_dir= minutes=15 max_mb=32 apply=no yes=no
release=20261002-82d9fad1
release_hash=0b5759301e028c3209b945a2b8353e70594b1e5c3395c32dca3bb9b28237e5b3
while [ "$#" -gt 0 ]; do
    case "$1" in
        --script|--sha256|--mode|--report-dir|--minutes|--max-mb)
            key=$1; shift; [ "$#" -gt 0 ] || die "Missing value for $key"
            case "$key" in
                --script) script=$1 ;; --sha256) hash=$1 ;; --mode) mode=$1 ;;
                --report-dir) report_dir=$1 ;; --minutes) minutes=$1 ;; --max-mb) max_mb=$1 ;;
            esac ;;
        --apply) apply=yes ;; --yes) yes=yes ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
    shift
done
[ "$(uname -s)" = Linux ] || die 'Linux target required'
case "$mode" in standard|full) ;; *) die 'Mode must be standard or full' ;; esac
for value in "$minutes" "$max_mb"; do case "$value" in ''|*[!0-9]*) die 'Limits must be positive integers' ;; esac; done
[ "$minutes" -ge 1 ] && [ "$minutes" -le 180 ] || die '--minutes must be 1..180'
[ "$max_mb" -ge 1 ] && [ "$max_mb" -le 128 ] || die '--max-mb must be 1..128'
if [ -n "$script" ]; then
    case "$script" in /*) ;; *) die '--script must be absolute' ;; esac
    [ -f "$script" ] && [ ! -L "$script" ] || die 'Script must be a regular file, not a symlink'
    [ -n "$hash" ] || die '--sha256 is required with --script'
else
    [ -z "$hash" ] || die '--sha256 requires --script'
    hash=$release_hash
fi
printf '%s\n' "$hash" | LC_ALL=C grep -Eq '^[0-9a-fA-F]{64}$' || die 'Invalid SHA-256 digest'
report_dir=${report_dir:-${HOME:-/tmp}/ccdc-reports}
case "$report_dir" in /*) ;; *) die '--report-dir must be absolute' ;; esac
case "$report_dir" in *'/../'*|*'/./'*|*'/..'|*'/.'|*'//'*) die 'Report path must be normalized' ;; esac
printf 'MODE=%s\nSOURCE=%s\nSHA256=%s\nREPORT_DIR=%s\nMINUTES=%s\nMAX_MB=%s\n' "$mode" "${script:-https://github.com/peass-ng/PEASS-ng/releases/download/$release/linpeas.sh}" "$hash" "$report_dir" "$minutes" "$max_mb"
[ "$apply" = yes ] || exit 0
[ "$yes" = yes ] || die '--apply requires --yes'
for dependency in sha256sum timeout gzip mktemp df; do command -v "$dependency" >/dev/null 2>&1 || die "Missing dependency: $dependency"; done
if [ -z "$script" ]; then
    command -v curl >/dev/null 2>&1 || die 'curl is required to download the pinned release'
else
    size=$(stat -c %s "$script") || die 'Cannot stat linPEAS source'
    [ "$size" -le 8388608 ] || die 'linPEAS source exceeds 8 MiB limit'
fi
[ ! -L "$report_dir" ] || die 'Report directory is a symlink'
if [ -e "$report_dir" ]; then
    [ -d "$report_dir" ] || die 'Report path is not a directory'
    [ "$(stat -c %u "$report_dir")" = "$(id -u)" ] || die 'Report directory must be owned by the current user'
    [ "$(stat -c %a "$report_dir")" = 700 ] || die 'Report directory must have mode 0700'
else
    mkdir -m 700 -p "$report_dir" || die 'Cannot create private report directory'
fi
free_kb=$(df -Pk "$report_dir" | awk 'END {print $4}')
case "$free_kb" in ''|*[!0-9]*) die 'Cannot determine free disk space' ;; esac
[ "$free_kb" -ge "$(((max_mb * 2 + 16) * 1024))" ] || die 'Insufficient free space for bounded report and compression'
work=$(mktemp -d "$report_dir/.linpeas.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
if [ -z "$script" ]; then
    script=$work/linpeas.sh
    timeout 45 curl -fLsS --max-time 40 --max-filesize 8388608 "https://github.com/peass-ng/PEASS-ng/releases/download/$release/linpeas.sh" -o "$script" || die 'Official release download failed'
else
    cp -- "$script" "$work/linpeas.sh" || die 'Cannot stage linPEAS source privately'
    script=$work/linpeas.sh
fi
actual=$(sha256sum "$script" | awk '{print $1}')
[ "$actual" = "$(printf '%s' "$hash" | tr A-F a-f)" ] || die 'linPEAS SHA-256 mismatch; nothing executed'
raw=$work/output.txt
set +e
(
    ulimit -f "$((max_mb * 2048))" || exit 1
    if [ "$mode" = full ]; then
        timeout "${minutes}m" sh "$script" -a -e -r >"$raw" 2>&1
    else
        timeout "${minutes}m" sh "$script" >"$raw" 2>&1
    fi
)
status=$?
set -e
report_tmp=$(mktemp "$report_dir/linpeas.$(date -u +%Y%m%dT%H%M%SZ).XXXXXXXX")
gzip -9n <"$raw" >"$report_tmp" || die 'Cannot compress report'
report=$report_tmp.gz
mv -- "$report_tmp" "$report"
chmod 600 "$report"
printf 'REPORT=%s\nREPORT_SHA256=%s\nLINPEAS_EXIT=%s\n' "$report" "$(sha256sum "$report" | awk '{print $1}')" "$status"
[ "$status" -eq 0 ] || die 'linPEAS did not complete; retain and review the partial report'

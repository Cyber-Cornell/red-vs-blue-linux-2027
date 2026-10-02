#!/bin/sh
set -u
umask 077

usage() {
    printf '%s\n' 'Usage: yara_hunt.sh --root ABSOLUTE_DIR [--rules ABSOLUTE_FILE] [--output NEW_ABSOLUTE_DIR] [--max-files 1..512] [--max-file-mb 1..64] [--seconds 1..600] [--apply --yes]'
    printf '%s\n' 'Plan by default. Bundled RIT-derived Linux rules are the default; apply scans bounded regular files on one filesystem.'
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd) || die 'Cannot resolve script location'
rules=$script_dir/../configs/yara/rit_linux_hunt.yar root= output= max_files=128 max_mb=16 seconds=120 apply=no yes=no
while [ "$#" -gt 0 ]; do
    case "$1" in
        --rules|--root|--output|--max-files|--max-file-mb|--seconds)
            key=$1; shift; [ "$#" -gt 0 ] || die "Missing value for $key"
            case "$key" in
                --rules) rules=$1 ;; --root) root=$1 ;; --output) output=$1 ;;
                --max-files) max_files=$1 ;; --max-file-mb) max_mb=$1 ;; --seconds) seconds=$1 ;;
            esac ;;
        --apply) apply=yes ;; --yes) yes=yes ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
    shift
done
for path in "$rules" "$root"; do case "$path" in /*) ;; *) die 'Rules and root must be absolute paths' ;; esac; done
[ -f "$rules" ] && [ ! -L "$rules" ] && [ -r "$rules" ] || die 'Rules must be a readable regular source file, not a symlink'
[ "$(stat -c %s "$rules")" -le 1048576 ] || die 'Rules exceed 1 MiB limit'
[ -d "$root" ] && [ ! -L "$root" ] || die 'Scan root must be a real directory'
root=$(CDPATH= cd -P "$root" && pwd) || die 'Cannot resolve scan root'
case "$root" in /|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*) die 'Choose a targeted directory outside kernel and device trees' ;; esac
for limit in "$max_files" "$max_mb" "$seconds"; do case "$limit" in ''|*[!0-9]*|0*) die 'Limits must be canonical positive integers' ;; esac; done
[ "$max_files" -ge 1 ] && [ "$max_files" -le 512 ] || die '--max-files must be 1..512'
[ "$max_mb" -ge 1 ] && [ "$max_mb" -le 64 ] || die '--max-file-mb must be 1..64'
[ "$seconds" -ge 1 ] && [ "$seconds" -le 600 ] || die '--seconds must be 1..600'
printf 'MODE=%s\nRULES=%s\nROOT=%s\nMAX_FILES=%s\nMAX_FILE_MB=%s\nSECONDS=%s\n' "$(if [ "$apply" = yes ]; then printf apply; else printf plan; fi)" "$rules" "$root" "$max_files" "$max_mb" "$seconds"
[ "$apply" = yes ] || exit 0
[ "$yes" = yes ] || die '--apply requires --yes'
case "$output" in /*) ;; *) die '--output NEW_ABSOLUTE_DIR is required for apply' ;; esac
[ ! -e "$output" ] && [ ! -L "$output" ] || die 'Output path must not exist'
parent=$(CDPATH= cd -P "$(dirname "$output")" && pwd) || die 'Output parent must exist'
output=$parent/$(basename "$output")
case "$output/" in "$root/"*) die 'Output must be outside scan root' ;; esac
for cmd in yara find timeout stat sha256sum; do command -v "$cmd" >/dev/null 2>&1 || die "Missing dependency: $cmd"; done
free_kb=$(df -Pk "$parent" | awk 'END {print $4}')
case "$free_kb" in ''|*[!0-9]*) die 'Cannot determine free space' ;; esac
[ "$free_kb" -ge 8192 ] || die 'Need at least 8 MiB free for bounded report'
mkdir -m 700 "$output" || die 'Cannot create private output'
report=$output/report.txt
list=$output/candidates.txt
printf 'rules_sha256=%s\nroot=%s\n' "$(sha256sum "$rules" | awk '{print $1}')" "$root" >"$output/metadata.txt"
(
    ulimit -f 2048 || exit 2
    timeout 30 find "$root" -xdev -type f -print >"$list"
) || die 'Candidate enumeration failed or exceeded report cap'
count=$(wc -l <"$list")
[ "$count" -le "$max_files" ] || die "Found $count candidates; narrow --root or raise --max-files within limit"
status=0
deadline=$(($(date +%s) + seconds))
(
    ulimit -f 2048 || exit 2
    while IFS= read -r file || [ -n "$file" ]; do
        [ -f "$file" ] && [ ! -L "$file" ] || { printf '[SKIP] changed or unsupported path: %s\n' "$file"; continue; }
        size=$(stat -c %s "$file") || { printf '[ERROR] cannot stat: %s\n' "$file"; continue; }
        [ "$size" -le "$((max_mb * 1048576))" ] || { printf '[SKIP] file over cap: %s\n' "$file"; continue; }
        remaining=$((deadline - $(date +%s)))
        [ "$remaining" -gt 0 ] || { printf '[ERROR] total scan deadline exceeded\n'; exit 124; }
        match=$output/.match.$$
        error=$output/.error.$$
        timeout "$remaining" yara -N -a "$remaining" "$rules" "$file" >"$match" 2>"$error"
        code=$?
        if [ "$code" -ne 0 ]; then
            printf '[ERROR] yara exit %s for %s\n' "$code" "$file"
            cat "$error"
            rm -f "$match" "$error"
            exit 2
        fi
        if [ -s "$match" ]; then
            sed 's/^/[MATCH] /' "$match"
        fi
        [ ! -s "$error" ] || cat "$error"
        rm -f "$match" "$error"
    done <"$list"
) >"$report" 2>&1 || status=$?
printf 'scan_exit=%s\ncandidates=%s\n' "$status" "$count" >>"$output/metadata.txt"
(cd "$output" && sha256sum metadata.txt candidates.txt report.txt >manifest.sha256) || die 'Cannot write manifest'
printf 'REPORT=%s\nSCAN_EXIT=%s\n' "$output" "$status"
[ "$status" -eq 0 ] || exit "$status"
if grep -q '^\[MATCH\]' "$report"; then exit 1; fi
exit 0

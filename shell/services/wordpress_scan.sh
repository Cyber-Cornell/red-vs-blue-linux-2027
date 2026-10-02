#!/bin/sh
set -u
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
case "${1:-}" in
  -h|--help)
    printf 'Usage: %s [web_audit.sh options]\nRuns the local read-only web-root hunter. No downloads or package installation.\n' "$0"
    printf '%s\n' 'For approved checksum checks with an existing WP-CLI, see https://developer.wordpress.org/cli/commands/core/verify-checksums/'
    exit 0
    ;;
esac
exec sh "$SCRIPT_DIR/../tools/web_audit.sh" "$@"

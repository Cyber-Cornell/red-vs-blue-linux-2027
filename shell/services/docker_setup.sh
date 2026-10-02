#!/bin/sh
printf '%s\n' 'ERROR: This former sample application entrypoint is not a Docker host setup tool.' >&2
printf '%s\n' 'Use shell/tools/docker_audit.sh for read-only daemon/container review. Prepare application-specific ownership, mounts, entrypoint and rollback separately.' >&2
printf '%s\n' 'https://docs.docker.com/engine/security/' >&2
exit 1

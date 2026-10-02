#!/bin/sh
# The legacy installer was truncated; no supported installation workflow exists.
printf '%s\n' 'ERROR: Teleport installation is not implemented by this toolkit.' >&2
printf '%s\n' 'The previous installer was incomplete. Review your event rules and the official installation documentation before making a service-aware installation plan:' >&2
printf '%s\n' 'https://goteleport.com/docs/installation/' >&2
exit 1

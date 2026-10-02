#!/bin/sh
printf '%s\n' 'ERROR: Wazuh manager installation is not implemented by this toolkit.' >&2
printf '%s\n' 'The legacy installer invoked a missing filename and executed unreviewed remote rules. Prepare an approved, version-pinned installation and verify its published provenance before execution.' >&2
printf '%s\n' 'https://documentation.wazuh.com/current/installation-guide/wazuh-server/index.html' >&2
exit 1

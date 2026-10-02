#!/bin/sh
printf '%s\n' 'ERROR: Automatic Ansible node enrollment is disabled.' >&2
printf '%s\n' 'Review the target host identity, inventory file and authorized key before a manual enrollment. This command makes no connections or changes.' >&2
printf '%s\n' 'https://docs.ansible.com/ansible/latest/inventory_guide/intro_inventory.html' >&2
exit 1

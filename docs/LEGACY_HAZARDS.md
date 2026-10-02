# Legacy script safety review

Source reviewed on 2026-10-02. The first table records former hazards and their
current replacements. Captured committed-source excerpts are in the local-only
`.omo/evidence/service-hunting/legacy-source.txt`; these development artifacts
are not shipped. Destructive historical behavior was not executed.

| Script | Observed hazard | Operator action |
| --- | --- | --- |
| `shell/file_cleaner.sh` | Formerly searched `/` and deleted credential-like filenames | Now previews or explicitly quarantines one absolute path, with a size cap. Removed from setup apply stages. |
| `shell/ssh_remove_keys.sh` | Formerly removed user `.ssh` directories and host trust databases | Now read-only audit/plan; reset apply refused. Review individual keys and coordinate trust changes. |
| `shell/package_manager_reset.sh` | Formerly deleted package pinning/config and downloaded a distribution migration script | Now read-only audit/plan; apply refused. |
| `shell/package_reinstall.sh` | Formerly reinstalled/upgraded broadly and ran autoremove | Now requires named packages and explicit plan/apply acknowledgement. Service-specific impact still needs review. |
| `shell/services/apache_script.sh` | Formerly changed service identity, ownership, handlers and firewall | Now read-only native validation/virtual-host/module audit or plan. No apply/reload. |
| `shell/services/nginx_script.sh` | Formerly made broad configuration/permission changes | Now version plus native syntax audit or plan; no full config dump/apply/reload. |
| `shell/services/falco_harden.sh` | Formerly changed engine/config and set immutable flags | Now version/local-rule validation or plan; no mutation/restart. |
| `shell/services/wordpress_scan.sh` | Formerly installed/downloaded tools and modified site config | Now delegates to local read-only web audit; no WP-CLI execution or download. |
| `shell/services/teleport_install.sh` | Source was truncated mid-string and had no complete installation dispatcher | Now fails closed with official documentation. Installation is not implemented. |
| `shell/services/wazuh_manager_setup.sh` | Downloaded one installer filename but invoked another, then executed a third-party rules script | Now fails closed with official documentation. Installation is not implemented. |

`--yes` acknowledges a requested action; it does not make an unverified legacy
stage reversible. A configuration snapshot cannot recover deleted user data,
reconstruct removed package versions, or automatically restore SSH client trust.

## Other specialized service scripts: restricted defaults

These files now default to a plan, read-only audit, or a nonzero unavailable
message. Historical source locations below refer to the committed legacy
revision captured in local evidence, not the current short wrappers. No legacy
mutation was executed. Native deployment of these products remains unvalidated.

| Historical file/location | Former behavior | Current boundary and reference |
| --- | --- | --- |
| `ansible_setup.sh:18`, `:120` | Installed packages and enabled services | Default plan; optional local version audit. New controller playbooks are documented separately in `ansible/README.md`. [Ansible installation](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html). |
| `ansible_add_node.sh:69`, `:85` | Appended SSH keys remotely and changed inventory permissions | Fails closed; use reviewed controller inventory. [Ansible inventory](https://docs.ansible.com/ansible/latest/inventory_guide/intro_inventory.html). |
| `docker_setup.sh:32`, `:82` | Changed hard-coded application paths and ran an application | Fails closed; directs operators to `tools/docker_audit.sh`. [Docker security](https://docs.docker.com/engine/security/). |
| `samba.sh:178`, `:204` | Replaced policy and could terminate service processes | Default plan or read-only `testparm -s`. No apply. [Samba testparm](https://www.samba.org/samba/docs/current/man-html/testparm.1.html). |
| `teleport.sh:84`, `:214`, `:243` | Changed/persisted firewall policy and restarted service | Default plan; audit version and systemd/OpenRC state. No apply. [Teleport configuration](https://goteleport.com/docs/reference/deployment/config/). |
| `teleport_utilities.sh:40`, `:175` | Changed firewall/account policy and referenced generated helpers | Delegates to the read-only Teleport wrapper; no missing-helper execution. |
| `wazuh_agent_setup.sh:98`, `:166`, `:255` | Downloaded software and changed repositories/config/services | Default plan or systemd/OpenRC state audit; installation unavailable. [Wazuh agent deployment](https://documentation.wazuh.com/current/installation-guide/wazuh-agent/index.html). |

The Markdown runbooks below `services/prom_grafana/` are manual infrastructure
recipes, not validated automation or event-approved deployment plans.

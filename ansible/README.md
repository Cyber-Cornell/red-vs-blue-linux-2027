# Run the Linux toolkit with Ansible

These playbooks run from an Ansible controller against Linux targets with SSH and Python available. They copy the repository's `shell/` tree into a fresh private per-run directory below a staging parent on each target, then invoke the same scripts described in the main README. The default staging parent is `/opt/ccdc-blue`; newly created parents and run directories use mode `0700`, staged files use mode `0600`, and scripts run through `/bin/sh`. An existing real staging parent is preserved rather than having its owner, mode, or contents replaced. The per-run directory is removed after command execution. The play runs one host at a time. No role or third-party collection is required.

Copy `inventory.example.ini` to a private inventory, replace the example host, and set the connection user and privilege escalation method. Confirm scored services and maintain console access before an apply run. The example inventory points to `.invalid` and cannot affect a real machine unchanged. Use `--limit` when targeting one host.

```sh
ansible-playbook -i inventory.ini ansible/playbooks/check.yml --limit web01
ansible-playbook -i inventory.ini ansible/playbooks/plan.yml --limit web01 \
  -e '{"ccdc_plan_targets":["baseline","ssh"]}'
ansible-playbook -i inventory.ini ansible/playbooks/audit.yml --limit web01 \
  -e '{"ccdc_output_dir":"/var/log/ccdc-blue/ansible-audit-01","ccdc_fetch_results":true}'
ansible-playbook -i inventory.ini ansible/playbooks/hunt.yml --limit web01 \
  -e '{"ccdc_output_dir":"/var/log/ccdc-blue/ansible-hunt-01","ccdc_fetch_results":true}'
```

The optional `ccdc_fetch_results` copies only the small `results.tsv` status summary to `./ccdc-results` on the controller. Full logs and evidence stay on the target at `ccdc_output_dir`. Audit and hunt are read-only on the target apart from their fresh report directory and temporary toolkit run directory. `check` and `plan` also allocate temporary staging, so they need write access to `ccdc_stage_dir`; existing files there are not overwritten.

To apply a reviewed profile or stage, give an explicit target list and `ccdc_confirm_apply`. The playbook runs `setup.sh plan` first and then `setup.sh apply ... --yes`. Firewall changes require the scored TCP/UDP port list. Use a unique output directory for each run.

```sh
ansible-playbook -i inventory.ini ansible/playbooks/apply.yml --limit web01 \
  -e '{"ccdc_apply_targets":["baseline"],"ccdc_confirm_apply":true,"ccdc_output_dir":"/var/log/ccdc-blue/apply-01"}'
ansible-playbook -i inventory.ini ansible/playbooks/apply.yml --limit web01 \
  -e '{"ccdc_apply_targets":["firewall"],"ccdc_tcp_ports":"22,80,443","ccdc_udp_ports":"53","ccdc_confirm_apply":true,"ccdc_output_dir":"/var/log/ccdc-blue/firewall-01"}'
```

The backup playbook forwards the bounded backup interface. The output directory must be new, on the target, and have an existing parent. Its archive stays on the target; Ansible does not fetch backups or credentials. Set `ccdc_backup_profile` to `configs` or `critical`, or list absolute source paths. The default compressed size cap is 256 MiB. The backup script checks free space, preserves paths under `/`, verifies gzip and tar, and writes a checksum and source manifest.

```sh
ansible-playbook -i inventory.ini ansible/playbooks/backup.yml --limit web01 \
  -e '{"ccdc_backup_profile":"configs","ccdc_backup_output":"/var/backups/ccdc-configs-01","ccdc_backup_max_mb":128}'
ansible-playbook -i inventory.ini ansible/playbooks/backup.yml --limit web01 \
  -e '{"ccdc_backup_sources":["/etc/ssh","/etc/nginx"],"ccdc_backup_output":"/var/backups/ccdc-custom-01","ccdc_backup_max_mb":64}'
```

The `tool` playbook runs **any** repository script under `shell/` by relative path, including individual audit tools, password rotation, permission review/fix, service helpers and the OpenCode installer. Its `ccdc_tool` value must be a `.sh` path without `..`, and arguments are passed as a list to Ansible's `command.argv` so shell metacharacters are not interpreted. Every generic invocation requires `ccdc_confirm_tool=true`; a mutating tool also needs its own explicit script flags. Ansible suppresses generic tool stdout/stderr by default because some tools print credentials. Set `ccdc_show_tool_output=true` only for a tool known to emit no secrets. Set `ccdc_tool_changes=true` for a tool expected to change the target.

```sh
ansible-playbook -i inventory.ini ansible/playbooks/tool.yml --limit web01 \
  -e '{"ccdc_tool":"tools/c2_hunt.sh","ccdc_tool_args":["--no-strings"],"ccdc_confirm_tool":true,"ccdc_show_tool_output":true}'
ansible-playbook -i inventory.ini ansible/playbooks/tool.yml --limit web01 \
  -e '{"ccdc_tool":"tools/password_rotate.sh","ccdc_tool_args":["rotate","--group","responders","--plan"],"ccdc_confirm_tool":true,"ccdc_show_tool_output":true}'
```

Standalone scanners and optional service controls use the same generic wrapper;
they do not need a dedicated playbook or membership in a default profile:

```sh
ansible-playbook -i inventory.ini ansible/playbooks/tool.yml --limit web01 \
  -e '{"ccdc_tool":"tools/linpeas_runner.sh","ccdc_tool_args":["--mode","standard"],"ccdc_confirm_tool":true}'
ansible-playbook -i inventory.ini ansible/playbooks/tool.yml --limit web01 \
  -e '{"ccdc_tool":"tools/malware_scan.sh","ccdc_tool_args":["scan","--root","/srv/reviewed-data"],"ccdc_confirm_tool":true}'
ansible-playbook -i inventory.ini ansible/playbooks/tool.yml --limit web01 \
  -e '{"ccdc_tool":"tools/yara_hunt.sh","ccdc_tool_args":["--root","/srv/reviewed-data"],"ccdc_confirm_tool":true}'
ansible-playbook -i inventory.ini ansible/playbooks/tool.yml --limit web01 \
  -e '{"ccdc_tool":"tools/observability_audit.sh","ccdc_tool_args":["--audit"],"ccdc_confirm_tool":true,"ccdc_show_tool_output":true}'
ansible-playbook -i inventory.ini ansible/playbooks/tool.yml --limit web01 \
  -e '{"ccdc_tool":"mac_policy.sh","ccdc_tool_args":["--plan"],"ccdc_confirm_tool":true}'
ansible-playbook -i inventory.ini ansible/playbooks/tool.yml --limit web01 \
  -e '{"ccdc_tool":"tools/service_isolate.sh","ccdc_tool_args":["--plan","--mode","sandbox","--service","reviewed.service","--init","systemd"],"ccdc_confirm_tool":true}'
```

Replace all example service/data names with reviewed target values. The scanner
examples are plans. Explicit scan execution requires the tool's own apply flags
and a new target-side output directory; report files are not fetched by this
wrapper. YARA matches and ClamAV detections return nonzero, so Ansible reports a
failed command that requires private report review, not automatic quarantine.
MAC/isolation apply additionally needs pre-staged operator probes, explicit
service dependencies and the tool-specific inputs in the
[optional tool guide](../docs/OPTIONAL_TOOLS.md). The playbook stages only the
toolkit; it does not create custom probes or a service container.

For a per-user tool such as `tools/opencode_install.sh`, run without privilege escalation, set `ccdc_stage_dir` to an absolute directory the account can own, and set `ccdc_stage_owner`/`ccdc_stage_group` to that account. The installer itself remains plan-first and requires its own apply flags. `ccdc_become=false` alone is insufficient with the root-owned default stage directory.

```sh
ansible-playbook -i inventory.ini ansible/playbooks/tool.yml --limit web01 \
  -e '{"ccdc_become":false,"ccdc_stage_dir":"/home/operator/ccdc-blue","ccdc_stage_owner":"operator","ccdc_stage_group":"operator","ccdc_tool":"tools/opencode_install.sh","ccdc_tool_args":["--agent-only"],"ccdc_confirm_tool":true,"ccdc_show_tool_output":true}'
ansible-playbook -i inventory.ini ansible/playbooks/tool.yml --limit web01 \
  -e '{"ccdc_become":false,"ccdc_stage_dir":"/home/operator/ccdc-blue","ccdc_stage_owner":"operator","ccdc_stage_group":"operator","ccdc_tool":"tools/opencode_omo_plugin.sh","ccdc_tool_args":["--opencode-version","1.18.34"],"ccdc_confirm_tool":true}'
```

You can use `./ansible/run.sh ACTION -i inventory.ini ...` instead of spelling out a playbook path. The same variables can live in private Ansible inventory `host_vars` or a vars file; the playbook's defaults do not override host-specific values. `ansible-playbook --syntax-check` parses the playbooks, and `--check --diff` previews staging. In Ansible check mode the scripts are skipped because `command` cannot predict their effects. A real `check` or `plan` playbook run is needed for script preflight. The generic tool playbook provides access to legacy scripts too; read each script's `--help` and the legacy hazard guide before selecting it.

Ansible module behavior used here is documented in [command.argv](https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/command_module.html), [copy](https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/copy_module.html), [fetch](https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/fetch_module.html), and [check mode](https://docs.ansible.com/projects/ansible/latest/playbook_guide/playbooks_checkmode.html).

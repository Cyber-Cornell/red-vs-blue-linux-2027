# CCDC Linux Blue-Team Toolkit

This repository provides an offline, operator-controlled workflow for defending
Linux hosts during Collegiate Cyber Defense Competition events. It collects
evidence, checks scored services, hunts common persistence, applies reversible
host controls, and keeps high-risk changes explicit.

Hunters produce review leads, not a verdict that a host is clean. The core
workflow preserves existing configuration and requires explicit apply actions.
Legacy installers are restricted to audit/plan or fail-closed guidance: read
[the legacy hazard review](docs/LEGACY_HAZARDS.md) for replaced behaviors and
deployment limitations.

Before competition use, check the event's submission rules. The
[2026 NCCDC rules](https://www.nationalccdc.org/rules.html) require qualifying
team-written tools to be public for at least three months, declared, frozen at
submission, and approved by officials. Local deadlines and exceptions control;
this working checkout is not an approved competition release.

## Prerequisites and first 15 minutes

Copy the approved repository onto the assigned Linux host. Use a console-capable
session and retain recovery access. Run commands from the repository root.
Use POSIX `sh`; core helpers need standard Linux utilities, including `timeout`,
`find`, `stat`, `awk`, `sed`, `tar`, `gzip` and a SHA-256 tool. Root is required
for complete host evidence and apply operations. Optional tools include `curl`,
`dig`, a TCP client, Docker, database clients and native daemon validators.
`setup.sh check` reports dependencies; it never installs them.

1. Record the scored services, ports, dependencies and authorized operators.
2. Fill the reviewed config files listed below. Keep credentials elsewhere.
3. Check the toolkit and collect evidence before changing the host.
4. Start local service monitoring and watch the official scoring dashboard.
5. Make a compact backup, preview one change, then apply only after review.

```sh
sh shell/setup.sh check
sudo sh shell/setup.sh audit --output /var/log/ccdc-initial
sh shell/setup.sh plan baseline
```

Before changing accounts or network policy, fill these reviewed inputs:

- `shell/configs/admins.txt`: approved administrator accounts
- `shell/configs/users.txt`: approved human, non-admin accounts
- `shell/configs/services.txt`: approved service accounts
- `shell/configs/lock_accounts.txt`: confirmed accounts to lock
- `shell/configs/scored_services.conf`: local health checks for scored services
- `shell/configs/permissions.conf`: explicit expected owner/group/mode policy

For example, adapt these service checks to the competition packet:

```text
ssh|tcp|127.0.0.1:22|up
website|http|http://127.0.0.1/|200
dns|dns|127.0.0.1:example.internal|192.0.2.10
database|systemd|postgresql.service|active
# On OpenRC, use this instead of the systemd row:
# database|openrc|postgresql|started
```

Firewall changes require the complete scored port list:

```sh
sudo sh shell/setup.sh apply firewall \
  --tcp-ports 22,80,443,8000-8100 \
  --udp-ports 53 \
  --yes
```

The firewall refuses to omit the port used by an active SSH session. Every apply
run creates a private, size-conscious `/etc` snapshot unless `--no-snapshot` is
explicitly supplied. Individual modules also write rollback material under
`/var/backups/ccdc-*`.

## Operator workflow

`audit` runs read-only triage and focused hunters. `hunt` adds package integrity
and specialized hunting and may take substantially longer. Reports default to
`/var/log/ccdc-blue/<UTC timestamp>` and contain a SHA-256 evidence manifest.

`plan` expands profiles and labels risk without changing the host. `apply`
requires both named stages and `--yes`; destructive stages are never included
in a profile. Run one risk domain at a time and check scored services after each.
Plan output previews intent; native host validation happens when applying.

| Command | Use |
| --- | --- |
| `sh shell/setup.sh check` | Check syntax, dependencies and operator inputs |
| `sh shell/setup.sh list` | Show the current stages and profiles |
| `sudo sh shell/setup.sh audit --output /var/log/ccdc-audit-01` | Collect fast local evidence and audits |
| `sudo sh shell/setup.sh hunt --output /var/log/ccdc-hunt-01` | Add package verification and specialized hunters |
| `sh shell/setup.sh plan baseline ssh` | Preview the selected stages without applying |
| `sudo sh shell/setup.sh apply baseline --yes --stop-on-error` | Apply supported kernel/audit/logging controls with a pre-change snapshot |
| `sudo sh shell/setup.sh apply ssh --yes` | Validate and apply SSH policy separately |
| `sudo sh shell/setup.sh apply accounts --yes` | Lock only explicitly selected reviewed accounts |

`host` adds permission fixes and GNOME policy to `baseline`; GNOME and journald
are skipped where inapplicable. Firewall, SSH and accounts stay explicit.
No apply profile authorizes a package upgrade, global file deletion or a
service migration. Unavailable optional audit components are recorded as skips
or coverage gaps; failed required checks remain failures.

## Compact backups and recovery

Use a fresh output directory outside every selected source:

```sh
sudo sh shell/setup.sh backup --profile configs \
  --output /var/backups/ccdc-configs-01 --max-mb 256
sudo sh shell/setup.sh backup --profile critical \
  --source /srv/scoreboard/config --source /var/www/html/wp-config.php \
  --output /var/backups/ccdc-critical-01 --max-mb 256
sudo sh shell/tools/backup_restore.sh \
  --archive /var/backups/ccdc-configs-01/backup.tar.gz
sudo sh shell/tools/backup_restore.sh \
  --archive /var/backups/ccdc-configs-01/backup.tar.gz \
  --extract --yes --output /var/backups/ccdc-restore-review-01
```

`configs` selects `/etc` and `/usr/local/etc`; `critical` additionally selects
cron/anacron spools and `/root/.ssh`. Repeat `--source` for important files or
directories. Review `sources.txt` and `skipped-sources.tsv`. Collection has a
300-second bound, an archive cap and a 100 MiB free-space reserve, followed by
gzip/tar readback and a SHA-256 manifest. These are compressed, unencrypted
archives and may include password hashes or private keys.

Restore previews by default. Explicit extraction writes into a fresh staging
directory, restores regular files with private modes, and reports links/special
members separately in `RESTORE-SKIPPED-LINKS.txt`. It does not overwrite the live
filesystem or preserve every original mode/ownership automatically. Review
staged content and use service-specific restoration. Stop a database or use its
native dump/backup facility before copying live storage; filesystem compression
does not establish database consistency.

For the competition sequence, containment guidance, reporting fields, and the
primary sources behind the design, read
[docs/CCDC_LINUX_PLAYBOOK.md](docs/CCDC_LINUX_PLAYBOOK.md). Use
[docs/INCIDENT_REPORT_TEMPLATE.md](docs/INCIDENT_REPORT_TEMPLATE.md) for White
Team reports.

## Local audits and permission repair

```sh
# Continuous local checks after configuring scored_services.conf
sudo sh shell/tools/service_watch.sh --watch 30 --output /var/log/ccdc-services.tsv

# Focused account review; no changes
sudo sh shell/tools/users.sh --audit

# Preview SSH and firewall policy
sh shell/ssh_config.sh --plan
sh shell/firewall.sh --plan --tcp-ports 22,80,443 --udp-ports 53

# Collect a standalone evidence set
sudo sh shell/tools/triage.sh --output /var/log/ccdc-triage-01

sudo sh shell/tools/permission_audit.sh --root /
sudo sh shell/permission_fix.sh --plan
sudo sh shell/permission_fix.sh --apply --yes
sudo sh shell/tools/network_inventory.sh
```

Review `permissions.conf` before repair. The fixer applies its explicit policy
and selected SSH/cron/service-definition protections, records prior metadata,
and prints a `restore.sh` path. It does not recursively normalize application
or web content. The audit reports SUID/SGID, writable paths, ownership and
capabilities as leads; missing paths and time limits affect coverage. Network
inventory reports only local state and refuses target arguments.

Service wrappers in `shell/services/` provide audit/plan or clear unavailable
messages. They do not install software or rewrite firewall/site configuration.
Apache/nginx/Falco audits need their native validators; a missing binary is a
coverage gap. Native config tests may create runtime directories or open logs;
they do not change configuration or reload a service. The separate Ansible controller workflow is documented below;
the old `services/ansible_*` enrollment/install path is disabled.

## Credentials

Generate a password with `sh shell/tools/password_rotate.sh generate`. This
prints a secret once to stdout; keep it out of command transcripts and logs.
Preview rotation for one local account or a reviewed group:

```sh
sudo sh shell/tools/password_rotate.sh rotate --user alice
sudo sh shell/tools/password_rotate.sh rotate --group responders
sudo install -d -m 700 /root/ccdc-credentials
sudo sh shell/tools/password_rotate.sh rotate --group responders \
  --apply --yes --output /root/ccdc-credentials/rotation-001
```

Group selection includes primary and supplementary members and removes
duplicates. Protected accounts cause refusal. Each selected account receives a
distinct generated password. The new output file is mode 0600 and its parent
must be root-owned mode 0700. Deliver it once through an approved private
channel, then manage retention under the team's evidence policy. Rotation logs
omit passwords. Rotation can partially succeed: inspect each `RESULT` in the
private artifact; an interrupted `PENDING` entry has an unknown outcome. The
tool does not update application/database credentials or roll back passwords.

## C2 and persistence leads

```sh
sudo sh shell/tools/c2_hunt.sh
sudo sh shell/tools/c2_hunt.sh --pid 1234 --no-strings
sudo sh shell/tools/c2_hunt.sh --yara-rules /root/reviewed-local-rules.yar
sudo sh shell/tools/rootkit_hunt.sh --audit
sudo sh shell/tools/connection_hunt.sh --tcp-ports 22,80,443 --udp-ports 53
sudo sh shell/tools/process_audit.sh
sudo sh shell/tools/persistence_audit.sh
sudo sh shell/tools/persistence_audit.sh --git-hooks-only --git-root /srv/reviewed-repository
sudo sh shell/tools/web_audit.sh --root /var/www --max-file-bytes 10485760
```

Replace example PID/paths with reviewed local values. C2 hunting correlates
process/executable metadata, bounded static markers, sockets and persistence
leads; it does not run a C2 agent or contact a remote controller. Limits include
60 seconds, 256 processes, 16 MiB per executable and 128 persistence files at
64 KiB each. Raw command lines, environment values and extracted strings are
not emitted by that tool. The persistence audit applies a 60-second and 4-MiB
whole-run default, reports metadata/hashes for cron, startup, SSH environment
and other credential-bearing files, and suppresses authorized-key values. Tune
its bounds with `CCDC_PERSISTENCE_TIMEOUT` (1-600 seconds) and
`CCDC_PERSISTENCE_MAX_KB` (64-16384 KiB).

The process audit defaults to 1,024 processes, 60 seconds, and 4 MiB output.
The web audit defaults to 3,000 matches, 10 MiB per inspected file, 60 seconds,
and 4 MiB output. It reports file metadata and hashes for source/override
markers without printing matching values. Package verification defaults to 300
seconds and 4 MiB output. The Docker audit defaults to 128 containers, 60
seconds, and 4 MiB output and suppresses daemon configuration, environment,
label, and event-attribute values. Each command's `--help` lists its bounded
overrides. Reports still contain sensitive operational metadata such as users,
paths, hashes, sockets, and service state; retain them privately.

Sliver and Spellshift Realm markers are weak leads; obfuscation can remove them
and unrelated software can match. A `realm` name alone is not a verdict. Review
hashes, service ownership, persistence and network context before containment.
See [MITRE Sliver](https://attack.mitre.org/software/S0633/) and
[obfuscation](https://attack.mitre.org/techniques/T1027/). Absence of findings
does not prove that a host is clean.

The rootkit hunter adds bounded process-visibility comparisons, deleted/memory
executables, kernel module/taint metadata, preload/module-persistence locations,
shallow `/dev` file leads and package-integrity summaries. It supplements
signature scanners such as rkhunter; it is not a replacement for trusted offline
examination. Legitimate updates/modules and process races can produce findings,
and a compromised kernel can deceive both `/proc` and installed tools.

Connection hunting flags sockets outside the reviewed service-port list,
unreviewed public peers, unusual executable ownership and namespace changes.
Use `--allow-destinations FILE` for known numeric destination addresses; match
the exact displayed address text, without CIDR or DNS names. It uses numeric
`ss` output and a `/proc` fallback, with a 60-second/128-socket bound: up to 96
TCP/UDP rows and 32 AF_PACKET/raw-IP rows. Packet/raw ownership correlation is
explicitly partial and bounded. Missing process ownership or the fallback's
reduced correlation is a coverage gap. Public/CDN/database connections,
packet-capture tools and namespace differences can be legitimate; these are
investigation leads, not automatic block or kill decisions. It sends no probes
and does not capture packet contents.

## Optional scanners and service controls

Use the [optional tool guide](docs/OPTIONAL_TOOLS.md) for the pinned upstream
LinPEAS runner, ClamAV install/update/scan, bundled RIT-derived YARA rules,
telemetry checks, mount/attribute review, and opt-in MAC/service isolation.
Local hunters do not claim to reproduce every upstream LinPEAS check.

```sh
sh shell/tools/linpeas_runner.sh --mode standard
sh shell/tools/malware_scan.sh scan --root /srv/reviewed-data
sh shell/tools/yara_hunt.sh --root /srv/reviewed-data
sudo sh shell/tools/observability_audit.sh --audit
sudo sh shell/tools/mount_audit.sh
sudo sh shell/tools/attribute_audit.sh --path /etc/fstab
sh shell/mac_policy.sh --plan
sh shell/tools/service_isolate.sh --plan --mode sandbox \
  --service reviewed.service --init systemd
```

Scanner commands above preview execution. MAC and isolation remain explicit
standalone actions with reviewed service health/logging probes and rollback;
neither is included in `baseline` or `host`. Container migration also requires
event authorization and an already prepared stopped Docker/Podman container.
The telemetry audit checks fixed paths and loopback readiness, not delivery to
the remote collector. Review [validation gaps](docs/VALIDATION_MATRIX.md).

## Ansible controller workflow

Read [ansible/README.md](ansible/README.md) and adapt the example inventory to
your assigned hosts. The controller needs Ansible; targets need SSH, Python and
reviewed privilege escalation. These playbooks stage `shell/` privately and
invoke the same local interfaces one host at a time.

```sh
ansible-playbook -i inventory.ini ansible/playbooks/check.yml --limit web01
ansible-playbook -i inventory.ini ansible/playbooks/audit.yml --limit web01
ansible-playbook -i inventory.ini ansible/playbooks/apply.yml --limit web01 \
  -e '{"ccdc_apply_targets":["baseline"],"ccdc_confirm_apply":true}'
ansible-playbook -i inventory.ini ansible/playbooks/tool.yml --limit web01 \
  -e '{"ccdc_tool":"tools/c2_hunt.sh","ccdc_tool_args":["--no-strings"],"ccdc_confirm_tool":true,"ccdc_show_tool_output":true}'
```

The generic tool playbook hides stdout/stderr by default to protect secrets;
only opt into display for known nonsecret output. A mutating tool still needs
its own apply flags. Full reports, backups and credentials remain on targets;
optional result fetching retrieves only `results.tsv`. Ansible check mode
previews staging and skips script execution. Actual runs use a fresh private
subdirectory below `ccdc_stage_dir` and remove it after the command, so existing
operator files in the staging parent are not overwritten. Run the actual
check/plan playbook for script preflight.

## Optional OpenCode defender agent

Use this only in an environment where the event permits the selected model and
processing location. Installing a prompt does not authorize outside assistance
or cloud processing. This repository provides optional scripts; the toolkit
does not automatically install OpenCode. Run as the intended nonroot operator,
without `sudo`:

```sh
sh shell/tools/opencode_install.sh --agent-only
sh shell/tools/opencode_install.sh --agent-only --apply --yes
```

This installs `shell/configs/opencode_ccdc_defender.md` as the per-user
`~/.config/opencode/agents/ccdc-defender.md` for an existing OpenCode V1 setup.
The OMO plugin currently requires V1; do not substitute V2. For a full install,
use `--version 1.18.34` with the reviewed available
version, preview first, then add `--apply --yes`. The installer uses the official
`opencode-ai` npm package and its postinstall script. It checks free space
(512 MiB by default; 8 MiB for agent-only) and bounds npm runtime to 300 seconds;
these checks are not disk quotas. `--replace-agent` preserves a backup before
replacing a different existing prompt. See [OpenCode](https://opencode.ai/docs/)
and [custom agents](https://opencode.ai/docs/agents/). Model connectivity and
defender quality are separate from installer validation.

The separate optional OMO plugin script also previews by default:

```sh
sh shell/tools/opencode_omo_plugin.sh --opencode-version 1.18.34
# On an approved target, after reviewing the plan:
sh shell/tools/opencode_omo_plugin.sh --opencode-version 1.18.34 --apply --yes
```

It requires the matching per-user OpenCode V1 installation and fresh OpenCode
and OMO config files. Existing configs require a manual merge. It pins the
OpenCode plugin `oh-my-openagent@5.1.9` and Bun `1.4.2`, writes the bundled free-tier
model configuration, and runs plugin diagnostics. Free model availability,
rate limits and provider login can change; diagnostics are not proof that a
model request succeeds. Review the scripts and bundled JSON before use, and
keep all model processing within the event's allowed environment.

The bundled text model ID is `opencode/big-pickle`; multimodal/visual routing
uses `opencode/mimo-v2.6-flash-free`. These configured IDs and installer success
do not establish free quota or provider availability. This installs the
OpenCode plugin, not the standalone OMO binary. See the
[configuration and recovery limits](docs/OPTIONAL_TOOLS.md#optional-opencode-and-omo).

## Incident-response reporting skill

The project-local Codex skill at
`.agents/skills/incident-response-report/SKILL.md` drafts situation updates,
technical incident reports, and after-action reports from supplied evidence.
Invoke it as `$incident-response-report`. Its adaptable Markdown template keeps
observed facts, analyst assessments, unknowns, timelines, response actions, and
evidence provenance distinct; reporting does not authorize collection,
remediation, notification, or publication. The research basis and publication
status of its NIST and FIRST sources are recorded in
[incident-response-reporting.md](docs/research/incident-response-reporting.md).

## Reports and rollback

Use a fresh output directory for each collection. `results.tsv` records stage
status and log locations; inspect skipped, unknown, failed and truncated
sections. Verify evidence from its own directory with
`sha256sum -c manifest.sha256`. Keep mode-0700 report directories and mode-0600
sensitive files, and review reports before sharing.

Apply modules print their rollback directories under `/var/backups/ccdc-*`.
Read the generated `restore.sh` before running it as root, preserve console
access, and rerun local plus external scored checks afterward. A configuration
snapshot is not a full disk backup or automatic rollback for credentials.

## Compatibility and rules

| Environment | Support boundary |
| --- | --- |
| Debian/Ubuntu and relatives | POSIX core; Debian package verification and native service tools where installed |
| RHEL/Fedora/SUSE and relatives | POSIX core; RPM verification without verify-script execution; native paths still require validation |
| Alpine/OpenRC | BusyBox-compatible inventories/hunters and apk verification; explicit `openrc` service checks and rc-status inventory |
| Arch and relatives | POSIX core; pacman metadata verification; deployment not covered by an Arch integration run |
| Gentoo | Guarded explicit emerge package operations and ClamAV install routing; native Portage transactions and full-host integration remain unvalidated |
| systemd | Unit health/inventory and supported reload paths; journald is systemd-only |
| OpenRC | `rc-service` checks and `rc-status` inventory; supported modules use native init adapters; no journald |
| No live init manager/container | Process/local-state fallback; daemon state is unavailable, not healthy |
| GNOME | dconf policy only when installed; effective desktop policy requires a desktop session test |

Core orchestration and hunters target POSIX `sh` on Linux. Linux tools and
distribution layouts still vary. A passing Alpine container test does not
validate systemd, auditd, SSH login, or a host firewall. See the
[feature and validation matrix](docs/VALIDATION_MATRIX.md) for exact coverage,
official references, and untested paths. Teleport and Wazuh manager installation
are intentionally unavailable pending a reviewed installer.

Service checks return nonzero for failures, unknown coverage, invalid rows, and
an empty configuration. TCP checks only establish that a socket accepts a
connection. HTTP status and DNS answers do not replace the official scorer or
an authenticated application transaction. DNS checks may specify an exact answer
in the fourth config field. `--output` appends TSV rows with one header.

Standalone hunters write to stdout/stderr. Use a private report directory and
`umask 077` when redirecting because paths, users, hashes, and connection
metadata can be sensitive. Process, web, Docker, persistence, and package
collectors enforce their documented whole-run bounds. Database queries are read-only metadata
queries; authentication/permission errors remain visible. MySQL/MariaDB uses
local socket authentication with client defaults disabled and a 15-second query
deadline, so sites requiring configured credentials may need a reviewed manual
database audit. PostgreSQL uses the local `postgres` OS account. Set
`CCDC_PG_DATABASE` to audit each PostgreSQL application database separately.
Package verification compares against local metadata and preserves native
status; review its output even when the verifier exits zero. Auditd status emits
bounded event-type counts and suppresses raw `USER_CMD` and related record
values. SSH and rsyslog audits likewise emit authentication counts or protected
file metadata/hashes rather than raw log message values.

Scripts run without cloud services and are designed for the NCCDC restriction
on outside processing. Always review the rules for the specific regional or
national event; local variations and inject instructions take precedence.

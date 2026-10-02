# CCDC Linux Blue-Team Playbook

This toolkit is built around the scoring reality of CCDC: availability and
business tasks are roughly half the points, security is judged alongside them,
and a defensive change that breaks scoring is still your outage. The current
NCCDC rules also prohibit tools that deliberately break expected operations,
including blanket shell disabling or indiscriminate network termination.

## First 15 minutes

Before the event, publish, submit, freeze, and obtain approval for qualifying
team-written tools according to the event's deadlines. The 2026 national rules
require at least three months of public availability and official approval;
changes after submission need specific permission. Confirm local variations
before using this checkout. The national rules also restrict outside processing
and scored-service migration/containerization. Testing this toolkit in a local
container does not authorize migrating a scored service.
[NCCDC rules](https://www.nationalccdc.org/rules.html).

1. Read the local event rules and competition packet. Record scored services,
   dependencies, SLAs, and owners in a private team inventory. Put only check
   names, types, targets, and expected results in
   `shell/configs/scored_services.conf`; do not put credentials there.
2. Confirm console or hypervisor recovery before changing SSH, firewall, PAM,
   routing, storage, or mandatory access control.
3. Run `sudo ./shell/setup.sh audit`. Copy the output path into the team log and
   verify `triage/manifest.sha256` before using the evidence in a report.
4. Start `service_watch.sh --watch 30` in a team terminal after filling its
   config. A second team member should watch the official scoring dashboard.
5. Inventory accounts, active sessions, listening ports, services, scheduled
   jobs, web roots, database roles, containers, and existing security controls.
   Treat unfamiliar state as a lead, not proof of compromise.
6. Build a change order. Use `setup.sh plan ...`; assign one operator and one
   verifier; change one risk domain at a time; verify scored services after each.

## Containment sequence

Preserve volatile state before killing a process or deleting a file. Record the
PID, parent process, executable link, command line, hashes, sockets, owning
account, timestamps, and relevant logs. Precise containment is preferable to a
host-wide outage:

1. Disable or expire a confirmed unauthorized account with
   `configs/lock_accounts.txt` and the `accounts` stage. The tool refuses UID 0,
   allowlisted, and active-session users by default.
2. Block a confirmed hostile address with the narrow firewall helper, or apply
   the full firewall stage only after declaring every scored port. Preserve the
   management path and verify from another terminal.
3. Quarantine a confirmed artifact onto the same filesystem, record its SHA-256
   and metadata, and keep a recoverable copy when rules permit. Avoid immediate
   deletion; it destroys evidence and can remove a service dependency.
4. Rotate credentials in a service-aware order. Keep old and new credentials
   out of terminal history and incident reports. Update applications before
   invalidating their current database or API credential.
   Use `password_rotate.sh rotate --user NAME` or `--group NAME` to preview
   local account selection. Apply requires `--apply --yes --output NEW_FILE`
   in a root-owned mode-0700 directory; the credential artifact is mode 0600.
   Group membership includes primary and supplementary members. Review every
   per-account result, retain partial-failure evidence securely, and verify
   new access before closing existing sessions. `generate` prints a secret to
   stdout and must never be sent to a general command log.
5. Patch the exploited path or remove its exposure. A generic package upgrade
   is not a substitute for verifying that the vulnerable service restarted on
   the fixed version.

## Hardening order

The `baseline` profile takes a lightweight `/etc` snapshot, applies supported
sysctls, installs bounded audit rules, and adds bounded local logging. The
`host` profile adds narrow permission fixes and desktop policy. SSH, accounts,
firewall, package replacement, mount changes, DNS, MAC policy, and file cleanup
stay explicit because their correct values depend on the scored host.

Use these gates for every disruptive stage:

- the service owner names the required behavior and rollback trigger;
- the pre-change snapshot and module-specific rollback directory exist;
- syntax or native configuration validation passes before reload;
- existing sessions stay open until a new login succeeds;
- local and remote service checks pass immediately after the change;
- the team log records the operator, time, command, result, and evidence path.

## Threat-hunting priorities

Start with attacker behaviors that repeatedly appear in Linux intrusions:

- public-facing service exploitation and unpatched known-exploited flaws;
- web shells and recently changed executable web content;
- new, renamed, UID 0, empty-password, or unexpectedly privileged accounts;
- `authorized_keys`, sudoers, PAM, shell profiles, cron, systemd units/timers,
  init hooks, `ld.so.preload`, kernel modules, and container restart policy;
- processes with deleted executables, unusual parents, temporary-directory
  binaries, unexpected capabilities, or unexplained listeners/connections;
- transfer, tunnel, discovery, and privilege-escalation tools plus their output;
- database UDFs, dangerous extensions, triggers, superusers, and file-write
  privileges; and
- log gaps, timestamp changes, audit changes, and disabled security services.

Compare current state with package metadata and the initial triage, but expect
legitimate drift. Package verification can establish that a file changed; it
cannot decide whether the change is malicious.

Default process, persistence, web, Docker, and package collectors enforce
whole-run deadlines and output caps. Process and Docker review also cap the
number of objects. Audit-command values, web source/directive matches, Docker
daemon configuration, container environments/labels, and event attributes are
suppressed from general logs; use the reported paths and hashes for private,
authorized follow-up.

`setup.sh hunt` adds the bounded `c2_hunt.sh` and `rootkit_hunt.sh` collectors.
Use `c2_hunt.sh --pid PID` to narrow process review, `--no-strings` to omit static
markers, or `--yara-rules LOCAL_FILE` for a reviewed local ruleset. Sliver and
Spellshift Realm strings are weak leads, not attribution; `realm` also names
unrelated legitimate software. Correlate executable hashes, process ancestry,
socket ownership and persistence before containment. The rootkit hunter uses
several live-host views, which a compromised kernel may falsify. Escalate to
trusted offline examination when the evidence warrants it.
[MITRE Sliver](https://attack.mitre.org/software/S0633/),
[obfuscation](https://attack.mitre.org/techniques/T1027/),
[application-layer C2](https://attack.mitre.org/techniques/T1071/).

Use `connection_hunt.sh --tcp-ports LIST --udp-ports LIST` to compare local
listeners and peers with the reviewed scored-service ports. Optional
`--allow-destinations FILE` entries are exact numeric address strings, not DNS
or CIDR rules. Review public peers, process ownership, deleted/memory-backed
executables and network namespaces together. The hunter sends no probes;
missing PID correlation and bounded/truncated output must be recorded as gaps.
Never block a peer solely because it is public or unfamiliar.

For limited disk space, `setup.sh backup --profile configs --output NEW_DIR`
creates a compressed configuration archive; `critical` adds local cron spools
and root SSH material. Add explicit `--source PATH` values for the services you
own and choose an archive cap with `--max-mb`. The tool reserves 100 MiB free
space, verifies gzip/tar and hashes, and records missing preset sources. Keep
the resulting unencrypted archive private. Restore into a fresh review
directory before replacing live files. Stop databases or use native database
backups for consistency.

Permission audit and repair share `shell/configs/permissions.conf`. Review
expected ownership/modes, then use `permission_fix.sh --plan` and, if approved,
`--apply --yes`. The repair scope covers explicit sensitive paths and selected
service definitions; review its metadata ledger and generated restore script.
It does not infer correct permissions for arbitrary web/application data.

Treat an unavailable tool, denied query, timeout, or truncated report as a
coverage gap. `service_watch.sh` exits nonzero when no checks are configured.
Process, persistence, and web findings require investigation; their zero exit
status means collection completed, not that no findings exist. Web content
checks skip files at or above the configurable 10 MiB default cap and exclude
vendor/cache trees from the keyword pass. Local socket, HTTP, and DNS checks
must be paired with an external scoring check. Database visibility depends on
the connecting role; PostgreSQL checks cover one database per invocation.

For SHA-256-verified upstream LinPEAS, bounded ClamAV/YARA scans, RIT-derived
rule provenance, mount/attribute review and telemetry continuity, follow the
[optional tool guide](OPTIONAL_TOOLS.md). MAC and service isolation are explicit
standalone controls with reviewed health/logging probes and rollback. They are
not profile defaults; container migration needs the event's permission and a
prepared service-specific container. Ansible can invoke each through `tool.yml`.

Consult [the validation matrix](VALIDATION_MATRIX.md) before applying a module
on a new distribution. Preserve report permissions: use `umask 077`, keep logs
off public web roots, and verify the manifest from inside its report directory
with `sha256sum -c manifest.sha256`. Never attach full process/configuration
reports publicly without reviewing them for secrets.

## Incident reporting

NCCDC strongly encourages a report for each detected Red Team incident and says
it should include what occurred, source and destination addresses, timeline,
passwords cracked, access obtained, damage, affected systems, and remediation.
Use `docs/INCIDENT_REPORT_TEMPLATE.md`, cite exact evidence paths, and mark
assumptions clearly. Do not paste live passwords or reusable private keys.

## Primary references

- [NCCDC 2026 Rules](https://www.nationalccdc.org/rules.html)
- [NCCDC FAQ and scoring overview](https://www.nationalccdc.org/faq.html)
- [NIST SP 800-61 Rev. 3, Incident Response Recommendations](https://nvlpubs.nist.gov/nistpubs/specialpublications/nist.sp.800-61r3.pdf)
- [CISA: Lessons Learned from an Incident Response Engagement (AA25-266A)](https://www.cisa.gov/news-events/cybersecurity-advisories/aa25-266a)
- [CISA: Technical Approaches to Uncovering and Remediating Malicious Activity](https://www.cisa.gov/news-events/cybersecurity-advisories/aa20-245a)
- [Red Hat Enterprise Linux 9 Security Hardening](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/pdf/security_hardening/Red_Hat_Enterprise_Linux-9-Security_hardening-en-US.pdf)
- [OpenSSH `sshd_config(5)`](https://man.openbsd.org/sshd_config)
- [Linux `systemd.exec(5)` sandboxing reference](https://man7.org/linux/man-pages/man5/systemd.exec.5.html)

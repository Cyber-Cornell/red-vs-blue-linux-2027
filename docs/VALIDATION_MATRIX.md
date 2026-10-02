# Feature, reference, and validation matrix

Validated 2026-10-02. **Real** means the CLI ran against an actual local Linux
surface or inert filesystem fixture. **Adapter** means an external command was
replaced with a deterministic fixture; it proves orchestration, not that daemon
or service. **Gap** means the behavior is not validated here. No external targets
were tested. No image was pulled for validation.

The local development artifacts under `.omo/evidence/` are not part of a
published release and may contain sensitive host metadata. Their exact paths
below identify the development run, not files consumers must have. Reproduction
commands later in this document work from a normal checkout.

| Setup stage | Implemented behavior and primary reference | Observed validation and remaining gap |
| --- | --- | --- |
| `triage` | Bounded local evidence; [procfs](https://man7.org/linux/man-pages/man5/proc.5.html) | Real Alpine collection, SHA-256 manifest and existing-output refusal: `host-baseline/validate-final.log`. Host journal coverage requires a full host. |
| `user-inventory` | Accounts/groups; [getent](https://man7.org/linux/man-pages/man1/getent.1.html) | Real Alpine account table: `service-hunting/services-inventory.txt`. Shell classification is not proof of login access. |
| `service-inventory` | Init service state; [systemctl](https://www.freedesktop.org/software/systemd/man/latest/systemctl.html), [OpenRC](https://github.com/OpenRC/openrc/blob/master/user-guide.md) | Real no-init process fallback, systemd/OpenRC command adapters: `service-hunting/services-inventory.txt`, `alpine-adapters.txt`. Native full init managers untested. |
| `service-check` | TCP, HTTP status, DNS answer and unit state; [curl](https://curl.se/docs/manpage.html), [BIND dig](https://bind9.readthedocs.io/en/latest/manpages.html#dig-dns-lookup-utility) | Real Alpine TCP, TSV append and invalid/empty config: `service-hunting/alpine-real.txt`. HTTP/DNS/systemd adapters and failure cases: `alpine-adapters.txt`; live authenticated application scoring untested. |
| `process-hunt` | Bounded `/proc` executable, environment, namespace and repeated PID comparison; defaults 1,024 processes/60 seconds/4 MiB; [proc_pid_exe](https://man7.org/linux/man-pages/man5/proc_pid_exe.5.html) | Real Alpine live collection and final 16-process/20-second/64-KiB regression: `service-hunting/alpine-real.txt`, `final-delta/collectors.log`. Restricted procfs can hide evidence, and this is not a rootkit detector. |
| `persistence-hunt` | Cron, system/user units, SSH, PAM, startup and container policy with 60-second/4-MiB whole-run defaults and value suppression for sensitive files; [systemd.unit](https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html), [sshd_config](https://man.openbsd.org/sshd_config) | Real Alpine local survey: `service-hunting/alpine-real.txt`; native systemd, PAM, Docker and all persistence variants are not exhaustively tested. |
| `permission-audit` | Bounded ownership/mode inventory; [find](https://www.gnu.org/software/findutils/manual/html_mono/find.html) | Real Alpine fixture: `host-baseline/validate-final.log`. No automatic remediation of findings. |
| `database-audit` | SELECT/SHOW metadata; [MySQL secure_file_priv](https://dev.mysql.com/doc/refman/8.4/en/server-system-variables.html#sysvar_secure_file_priv), [psql](https://www.postgresql.org/docs/current/app-psql.html) | No-client real case; MySQL adapter success/failure in `service-hunting/alpine-adapters.txt`. Live MySQL/MariaDB and PostgreSQL catalog/version compatibility remain gaps. |
| `docker-audit` | Privileged containers, namespaces, mounts, capabilities and published ports; defaults 128 containers/60 seconds/4 MiB and suppresses daemon/environment/label/event-attribute values; [Engine security](https://docs.docker.com/engine/security/) | Real missing-client case and risk-flag adapters: `service-hunting/alpine-real.txt`, `alpine-adapters.txt`; final secret/bound adapter: `final-delta/collectors.log`. No live daemon inspection from inside Alpine. |
| `observability-audit` | Fixed local telemetry service/config/readiness checks; [Prometheus readiness](https://prometheus.io/docs/prometheus/latest/management_api/), [Falco CLI](https://falco.org/docs/reference/daemon/cli-arguments/) | Added to audit/hunt; default paths/ports and current namespace only. CLI syntax/help verified in `final-docs/linux-interfaces.log`. Native telemetry delivery, EDR efficacy, custom authentication and live server validation remain gaps. |
| `web-audit` | Local content markers, upload executables, hashes, overrides and metadata with source values suppressed; defaults 60 seconds/4 MiB; [PHP configuration](https://www.php.net/manual/en/configuration.file.per-user.php) | Real inert media/source fixtures and unchanged hashes: `service-hunting/alpine-real.txt`; final source/override secret suppression and bounds: `final-delta/collectors.log`. Bounded heuristics do not establish absence of web shells. |
| `package-verify` | Native package metadata verification with 300-second/4-MiB defaults; [RPM](https://rpm.org/docs/4.20.x/man/rpm.8), [dpkg](https://manpages.debian.org/unstable/dpkg/dpkg.1.en.html), [pacman](https://man.archlinux.org/man/pacman.8.en), [Alpine apk](https://wiki.alpinelinux.org/wiki/Apk) | Real `apk --no-logfile audit --system` in Alpine: `service-hunting/alpine-real.txt`; final bounded adapter: `final-delta/collectors.log`. Debian/RPM/Arch native runs remain gaps. RPM verification scripts and APK audit logging are disabled; pacman metadata is not a full content checksum test. |
| `c2-hunt` | Bounded behavioral/static leads; [Sliver](https://attack.mitre.org/software/S0633/), [obfuscation](https://attack.mitre.org/techniques/T1027/) | Real benign/synthetic/privacy fixture and hunt routing: `core-controls-legacy/c2-container.log`. No live C2 malware was executed; signature/YARA detection effectiveness not established. |
| `rootkit-hunt` | Process, kernel, preload and integrity leads; [procfs](https://man7.org/linux/man-pages/man5/proc.5.html), [kernel taint](https://docs.kernel.org/admin-guide/tainted-kernels.html) | Synthetic/privacy fixture `core-controls-legacy/rootkit-container.log`; native Alpine `rootkit-native-container.log`. Does not prove resistance to a compromised kernel or replace offline examination. |
| `connection-hunt` | TCP/UDP, AF_PACKET and raw-IP kernel metadata with bounded owner correlation; [proc_pid_net](https://man7.org/linux/man-pages/man5/proc_pid_net.5.html), [packet sockets](https://man7.org/linux/man-pages/man7/packet.7.html) | Native Alpine smoke plus adapters for packet/raw/raw6 metadata, inode ownership and the exact 128-row split: `residual-coverage/native-syntax-connections.log`, `packet.log`. No payloads or active probes. Only the current namespace is covered; packet/raw ownership is partial and legitimate tools can match. |
| `snapshot` | Compact configuration archive and hashes; [GNU tar](https://www.gnu.org/software/tar/manual/tar.html) | Real tar extraction/listing, hashes and existing-output refusal: `host-baseline/validate-final.log`. This is not full system recovery. |
| `kernel` | Managed sysctl policy; [sysctl.d](https://man7.org/linux/man-pages/man5/sysctl.d.5.html) | Real plan plus failed-load rollback adapters: `host-baseline/validate-final.log`, `rollback-final.log`. Native runtime sysctl application untested. |
| `auditd` | Managed audit rules/config plus bounded event-type summaries with raw values suppressed; [auditctl](https://man7.org/linux/man-pages/man8/auditctl.8.html), [RHEL auditing](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/security_hardening/auditing-the-system_security-hardening) | Real plan and load-failure rollback adapters: host-baseline logs; final raw-command suppression adapter: `final-delta/collectors.log`. Native kernel audit rule enforcement untested. |
| `rsyslog` | Managed bounded logging; audits report protected log metadata/hashes without message values; [rsyslog validation](https://www.rsyslog.com/doc/troubleshooting/troubleshoot.html) | Real plan and validation-failure rollback adapter: host-baseline logs; final secret-suppression adapter: `final-delta/auth-log-suppression.log`. Native rsyslog syntax/reload untested. |
| `journald` | Managed journal limits; [journald.conf](https://www.freedesktop.org/software/systemd/man/252/journald.conf.html) | Real plan and restart-failure rollback adapter: host-baseline logs. Native systemd runtime untested. |
| `permissions` | Narrow sensitive-file mode changes; [chmod](https://www.gnu.org/software/coreutils/manual/html_node/chmod-invocation.html) | Real Alpine chmod apply/restore: `host-baseline/validate-final.log`. Other distributions need file ownership review. |
| `dconf` | GNOME policy when supported; [GNOME dconf](https://help.gnome.org/admin/system-admin-guide/stable/dconf.html.en) | Compiler/rollback adapters: `host-baseline/legacy-validation-final.log`. Native desktop application/effective policy not tested in headless Alpine. |
| `ssh` | Candidate validation and rollback; audit summarizes recent authentication records without message values; [sshd_config](https://man.openbsd.org/sshd_config) | Real isolated `sshd` config validation plus apply/rollback: `core-controls/isolated-controls.log`; final auth-log secret-suppression adapter: `final-delta/auth-log-suppression.log`. Reload adapter; live login continuity untested. |
| `accounts` | Explicit reviewed account locks; [usermod](https://man7.org/linux/man-pages/man8/usermod.8.html) | Real isolated `usermod` and refusal cases: `core-controls/isolated-controls.log`. Authentication/session behavior needs a full host. |
| `firewall` | Declared ports, SSH path guard, rollback; [nft atomic replacement](https://wiki.nftables.org/wiki-nftables/index.php/Atomic_rule_replacement) | Real CLI preflight and mocked nft/iptables failures: `core-controls/verification.log`, `isolated-controls.log`. Live packet enforcement/remote scoring untested. |

All artifact paths in that table are relative to the local-only `.omo/evidence/`
directory. Review the actual command output; an exit-zero collector can still
contain findings or unsupported optional sections.

`service-check` also supports the `openrc` type with expected state `started`;
systemd and OpenRC success/failure adapter evidence is in
`service-hunting/alpine-adapters.txt`. The contract follows
[OpenRC's service interface](https://github.com/OpenRC/openrc/blob/master/user-guide.md).

## Standalone tools and removed stages

The old broad package-install/remove/reinstall, package-manager-reset,
networking, fstab, file-cleaner, ssh-keys-reset, MAC, and broad-backup stages are
not part of `setup.sh apply`. Targeted standalone replacements must be reviewed
individually; see [the legacy review](LEGACY_HAZARDS.md).

The optional MAC replacement is a standalone, narrowly scoped apply interface;
it does not restore the former broad setup stage. Service isolation likewise
stays outside apply profiles. See [optional tool contracts](OPTIONAL_TOOLS.md).

| Tool family | Primary reference | Validation boundary |
| --- | --- | --- |
| Apache audit/plan | [apachectl](https://httpd.apache.org/docs/2.4/programs/apachectl.html) | Real native `-t`, `-S`, `-M` in read-only Kali bwrap: `service-hunting/native-web-audits.txt`; changed security template parsed in `native-templates.txt`. Config hashes unchanged. No live traffic/reload test. |
| nginx audit/plan | [nginx switches](https://nginx.org/en/docs/switches.html) | Real nginx 1.30.1 `-v`/`-t` in read-only Kali bwrap with temporary runtime paths: `service-hunting/native-web-audits.txt`; changed template parsed in `native-templates.txt`. No full config dump or live traffic/reload test. |
| Falco audit/plan | [Falco daemon arguments](https://falco.org/docs/reference/daemon/cli-arguments/) | Version/local-rule checks only; no immutable flags/restarts. Missing-tool/refusal cases tested; native Falco validation remains a gap. |
| WordPress local scan | [WP-CLI core checksum command](https://developer.wordpress.org/cli/commands/core/verify-checksums/) | Delegates to local web hunter; no install, downloads, site mutation or WP-CLI execution. Remote checksums require separately approved access. |
| Teleport / Wazuh manager | [Teleport installation](https://goteleport.com/docs/installation/), [Wazuh server](https://documentation.wazuh.com/current/installation-guide/wazuh-server/index.html) | Fail closed, exit 1; installation not implemented. |
| Targeted package operations | [apt-get](https://manpages.debian.org/unstable/apt/apt-get.8.en.html) | Explicit package names/plan/apply interface; native package transaction testing remains a gap here. |
| File quarantine / backup restore | [GNU coreutils](https://www.gnu.org/software/coreutils/manual/coreutils.html), [GNU tar](https://www.gnu.org/software/tar/manual/tar.html) | Real bounded profiles, repeated sources, archive readback/extraction: `host-baseline/profile-validation-final.log`, `gnu-backup-validation.log`. Quarantine fixture: `core-controls-legacy/container.log`. Full disaster recovery remains untested. |
| Password rotation | [chpasswd](https://man7.org/linux/man-pages/man8/chpasswd.8.html), [getent](https://man7.org/linux/man-pages/man1/getent.1.html) | Real isolated Alpine `chpasswd` and user/group checks: `core-controls-legacy/password-container.log`. No full-host application credential migration or live login test. Never use plaintext reports as general logs. |
| Local network / Docker inventory | [iproute2](https://man7.org/linux/man-pages/man8/ip.8.html), [Docker inspect](https://docs.docker.com/reference/cli/docker/inspect/) | Real local network inventory/target refusal and missing-Docker case: `service-hunting/services-inventory.txt`. No active scans; live daemon inventory remains a gap. |
| Remaining service wrappers | [OpenRC](https://github.com/OpenRC/openrc/blob/master/user-guide.md) plus exact vendor links emitted by `--plan` | Default plan/audit or fail-closed, no automatic installation. Systemd/OpenRC status adapters: `service-hunting/services-inventory.txt`. Live Ansible/Samba/Teleport/Wazuh/Falco services untested. |
| Ansible controller | [command.argv](https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/command_module.html), [tempfile](https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/tempfile_module.html), [check mode](https://docs.ansible.com/projects/ansible/latest/playbook_guide/playbooks_checkmode.html) | All eight playbooks, including the final per-run staging change, passed `ansible-playbook --syntax-check` with Ansible 2.20.3. No live multi-host deployment or scoring-continuity run was performed. |
| Optional OpenCode V1 | [OpenCode](https://opencode.ai/docs/), [agents](https://opencode.ai/docs/agents/) | Temporary V1 1.18.34 installation/version and mode-0600 agent were tested, then removed: `opencode-setup/real-verification.log`; offline installer fixtures `offline-alpine.log`. V1 required for current OMO compatibility. Real model/provider behavior and competition approval are outside installer tests. |
| Optional OMO plugin script | [OpenCode plugins](https://opencode.ai/docs/plugins/) | Pinned plugin and configuration setup are separate from core tooling. Default plan and explicit nonroot apply; existing config requires manual merge. Model requests/free-tier availability need separate validation and event authorization. |

The permission policy's real known-path repair/rollback and symlink refusal are
captured in `host-baseline/permission-policy-validation-final.log`. Systemd and
OpenRC restart/status routing for host logging/audit uses adapters in
`host-baseline/init-validation-final.log`; neither log proves native daemon
enforcement. The cached Alpine image has no live systemd/OpenRC manager.

## Optional-tool interface verification

The following checks were freshly run against the current scripts on
2026-10-02. Invocation and binary observations are recorded in
`.omo/evidence/final-docs/REPORT.md`; `linux-interfaces.log` captures the actual
Linux command output. These checks validate the documented interfaces only.

| Tool | Observed scenario | Remaining boundary |
| --- | --- | --- |
| LinPEAS runner | Native `sh -n`, help and standard plan print release `20261002-82d9fad1`, pinned SHA-256, 15-minute/32-MiB defaults; report directory remains absent. | No upstream scanner execution or detection effectiveness established by this check. Local collectors are not LinPEAS parity. |
| ClamAV wrapper | Native syntax/help and targeted scan plan print 300-second/16-MiB/64-MiB bounds without creating a report. Constrained adapters exercised clean/detection/error/timeout/output-cap reports, package/update routing and active-updater refusals. | The real ClamAV engine and malware efficacy were not tested; distro package transactions have no automatic rollback. Gentoo `emerge` arguments were adapter-tested, not run on Gentoo. |
| YARA wrapper | Native YARA 4.5.7 compiled all three bundled rules and matched the inert Father positive while rejecting non-ELF, missing-string, size-boundary and BusyBox negatives: `residual-coverage/yara.log`. | These WaterShell, Goofkit and Father rules are source-derived review leads, not the unavailable archived YaraRules collection. No live malware or process-memory scan was performed. |
| Executable Git-hook survey | Constrained Alpine fixtures verified metadata/SHA-256 output, no hook execution/content leak, exclusions, 32-hook/100-repository/depth/size bounds: `residual-coverage/adapter.log`. | CaptainHook-style behavioral leads are not attribution. Custom `core.hooksPath`, worktrees and bare repositories remain outside coverage. |
| Mount and attribute tools | Native syntax/help confirms read-only mount review and single-file attribute interface. | This interface check does not mutate attributes or validate all filesystem implementations. Separate earlier fixture evidence: `host-baseline/mount-attribute-validation.log`; inspect its invocation/capabilities before reproducing. |
| Optional MAC | Native syntax/help/plan confirms explicit backend/service/path/probes and runtime-only scope. | Native AppArmor/SELinux confinement, denials and scoring continuity remain untested here. Command-adapter scenarios are recorded separately under `mac-controls/`; they are not kernel enforcement evidence. |
| Service isolation | Native syntax/help and both systemd sandbox/OpenRC Podman plans succeed without running probes. | Native init/container handoff, application traffic, EDR delivery and reboot behavior are not demonstrated by plans. Adapter scenarios are separate under `service-isolation/`. |
| OpenCode OMO plugin | Native syntax/help/plan prints pinned plugin `5.1.9`, Bun `1.4.2` and bundled model IDs; target home remains absent. | This check installs nothing. Fresh-config installation, free quota, model requests and event approval require separate validation. |

The pinned RIT source revisions were checked directly with `git rev-parse HEAD`
in the existing local source clones and matched bundled rule metadata. Only
source inspection was performed; no RIT offensive tools were built or executed.
The Father rule was added during integration with pinned revision
`51e6911b8fd922c4236666203842b4afece73f14`; its native inert-fixture matching
check passed with YARA 4.5.7. This establishes rule compilation and fixture
behavior only, not detection effectiveness against modified or live implants.
ArchWiki and Gentoo Wiki links in the optional guide were consulted but the
primary pages were access-blocked; no distro behavior claim rests on those
unavailable pages. Upstream YARA, ClamAV, Falco, Prometheus, Wazuh and Grafana
references were reachable. Promtail EOL is documented by Grafana, not inferred
from a local service name.

## Reproduce the lightweight checks

Use an already-cached Alpine image. `--pull never` makes a missing image an
error. On Linux, from the repository root:

```sh
docker run --rm --pull never --network none --memory 128m --cpus 1 \
  --pids-limit 64 --cap-drop ALL --security-opt no-new-privileges \
  --read-only --tmpfs /tmp:rw,nosuid,nodev,size=32m -v "$PWD:/repo:ro" alpine:latest sh -c '
    set -eu
    for f in /repo/shell/tools/*audit.sh /repo/shell/tools/service_watch.sh /repo/shell/tools/package_verify.sh; do
      sh -n "$f"
    done
    mkdir -p /tmp/web/uploads
    printf "inert <?php marker ?>\n" >/tmp/web/uploads/marker.jpg
    sha256sum /tmp/web/uploads/marker.jpg >/tmp/before.sha256
    sh /repo/shell/tools/web_audit.sh --root /tmp/web
    sha256sum -c /tmp/before.sha256
    sh /repo/shell/tools/process_audit.sh
    sh /repo/shell/tools/persistence_audit.sh
    package_status=0
    sh /repo/shell/tools/package_verify.sh || package_status=$?
    printf "Package verifier status: %s (review output)\n" "$package_status"
    if sh /repo/shell/tools/service_watch.sh; then exit 1; fi
  '
```

Expected: no shell syntax errors; a media-marker finding and unchanged SHA-256;
process/persistence inventories; a native Alpine package-verification status;
and UNKNOWN/nonzero for the shipped empty service configuration. This does not
exercise live databases, Docker inspection, systemd, network firewall apply,
or credential rotation. The development adapter tests explicitly label their
mocked services and must never be described as live integration tests.

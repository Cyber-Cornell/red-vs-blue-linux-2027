# Optional scanners, telemetry, and service controls

Run these commands on the reviewed Linux target from the repository root. They
are available through Ansible `playbooks/tool.yml`; optional mutations are
not implied by `baseline` or `host`. The read-only observability audit is also
included in setup audit/hunt. Examples name paths, not authorized assets.
Use private output directories outside scan roots and inspect partial reports.

## LinPEAS compatibility

`shell/tools/linpeas_runner.sh` wraps the upstream script; the local account,
permission, persistence, process and package audits do not claim LinPEAS parity.
The default command prints a plan without downloading or running the scanner:

```sh
sh shell/tools/linpeas_runner.sh --mode standard --report-dir /root/ccdc-reports
```

The pinned upstream [release 20261002-82d9fad1](https://github.com/peass-ng/PEASS-ng/releases/tag/20261002-82d9fad1)
uses SHA-256
`0b5759301e028c3209b945a2b8353e70594b1e5c3395c32dca3bb9b28237e5b3`.
Execution requires explicit `--apply --yes`. An offline copy requires both
`--script ABSOLUTE_FILE` and its reviewed `--sha256`; verification happens after
private staging and before execution. The default deadline is 15 minutes,
the raw report cap is 32 MiB, and source size is limited to 8 MiB. A compressed
mode-0600 report is retained in a mode-0700 directory, including incomplete
runs; inspect `LINPEAS_EXIT` and the report checksum. Space preflight is not a
quota. The upstream script can expose credentials in its private report and
its behavior is distinct from the local read-only collectors. Full mode adds
credential-related and slow checks and is not a routine read-only audit.

## ClamAV

```sh
sh shell/tools/malware_scan.sh install
sh shell/tools/malware_scan.sh update
sh shell/tools/malware_scan.sh scan --root /srv/reviewed-data
# Run a reviewed local scan with already installed signatures:
sudo sh shell/tools/malware_scan.sh scan --root /srv/reviewed-data \
  --output /var/log/ccdc-clam-01 --apply --yes
```

All three actions plan by default. Installation uses configured distro
repositories: apk, apt-get, dnf/yum, pacman, zypper or Gentoo emerge; unsupported managers are
refused. Gentoo uses the named `app-antivirus/clamav` atom with automatic
USE/unmask writes disabled; dependency builds can exceed the deadline and
free-space estimate. Native Gentoo package transactions remain unvalidated;
see the [Portage emerge manual](https://dev.gentoo.org/~zmedico/portage/doc/man/emerge.1.html).
It does not request a service start, but package scripts may affect
services. Updating requires an existing signature directory (default
`/var/lib/clamav`) and uses the official mirror with freshclam. An active
systemd/OpenRC updater causes refusal. Install/update require separate
`--apply --yes --output NEW_DIR`; neither has automatic rollback.

Scanning uses `clamscan` with official databases, no network access, removal,
symlink following or filesystem crossing. Defaults are 300 seconds, 16 MiB per
file and 64 MiB expanded per container, with recursion/archive member limits.
The member limit is not a global file-count limit. Free-space preflight is
128 MiB for scanning and 1024 MiB for install/update; these are not disk quotas.
Exit 0 means no detections within coverage, 1 means a detection or limit alert,
and 2 means an error; time/output limits can yield other nonzero statuses.
Inspect `report.txt`, `metadata.txt` and `manifest.sha256`, including skipped
files. See [ClamAV scanning](https://docs.clamav.net/manual/Usage/Scanning.html).

## YARA and RIT-derived baseline

```sh
sh shell/tools/yara_hunt.sh --root /srv/reviewed-data
sudo sh shell/tools/yara_hunt.sh --root /srv/reviewed-data \
  --output /var/log/ccdc-yara-01 --apply --yes
```

The default source rules are `shell/configs/yara/rit_linux_hunt.yar`; optionally
select a reviewed source file with `--rules ABSOLUTE_FILE`. YARA must already
be installed. The wrapper neither downloads rules nor scans process memory.
Default bounds are 128 candidate files on one filesystem, 16 MiB per file,
30 seconds for enumeration and 120 seconds for scanning. It refuses excessive
candidate counts rather than silently choosing the first files. Source rules
are capped at 1 MiB; private report files have output caps. Names containing
newlines are outside the line-oriented candidate-list contract. Exit 1 means
matches; other failures and skipped oversized files require report review.
Use [YARA's source-rule CLI](https://yara.readthedocs.io/en/stable/commandline.html).

These are three locally written heuristic rules derived from pinned source
strings, not the upstream RIT YaraRules collection or comprehensive RIT coverage:

| Rule | Reviewed source revision |
| --- | --- |
| WaterShell ELF markers | [56c821053d39f4ad1f6cd11d7db610de98962c54](https://github.com/RITRedteam/watershell/tree/56c821053d39f4ad1f6cd11d7db610de98962c54) |
| Goofkit ELF markers | [92cdf52d263bf9e3037be536a981e66af554ce63](https://github.com/RITRedteam/goofkit/tree/92cdf52d263bf9e3037be536a981e66af554ce63) |
| Father default preload markers | [51e6911b8fd922c4236666203842b4afece73f14](https://github.com/RITRedteam/Father/tree/51e6911b8fd922c4236666203842b4afece73f14) |

The historical `RITRedteam/YaraRules` repository/API was unavailable during
review, so no downloaded archived rule corpus is bundled or claimed validated.
The rules require ELF magic and multiple source strings; renamed, stripped,
modified or memory-only samples may evade them. Inert marker fixtures test
matching mechanics, not detection of live malware. Correlate findings with
hashes, package ownership, service dependencies and network evidence.

`persistence_audit.sh --git-hooks-only --git-root /srv/reviewed-repository`
adds CaptainHook-style executable Git-hook review. It lists metadata/hashes,
never executes hooks or prints their contents. Default search roots are
`/root`, `/home`, `/srv`, `/opt`, `/var/www`; an override selects one subtree.
Bounds are 15 seconds, depth 8, 100 `.git` directories, 32 hooks per repository,
1 MiB per hash and 128 KiB output. Bare repositories, gitdir/worktree indirection,
custom `core.hooksPath` and symlink hooks are coverage gaps. This is behavioral
coverage, not a CaptainHook signature or attribution claim. See
[Git hooks](https://git-scm.com/docs/githooks).

The complete persistence survey has a separate 60-second and 4096-KiB default
cap, controlled by `CCDC_PERSISTENCE_TIMEOUT` and
`CCDC_PERSISTENCE_MAX_KB`. It prints metadata and bounded hashes for scheduled
tasks, startup scripts, SSH environment/rc files and matched policy files. It
does not print those files' contents or authorized-key values.

## Telemetry continuity

```sh
sudo sh shell/tools/observability_audit.sh --audit
sudo sh shell/services/falco_harden.sh --audit
```

The observability audit inventories fixed service names for Falco, Prometheus,
node exporter, Wazuh agent/manager, Loki, Alloy, Promtail, auditd, rsyslog and
journald using systemd/OpenRC where available. It validates existing default
configs with available native validators and reports only results, not config
bodies or metrics. Its fixed loopback readiness checks are Prometheus
`9090/-/ready`, Loki `3100/ready` and Alloy `12345/-/ready`; custom paths, ports,
authentication and container namespaces need operator checks.

The 60-second survey checks up to 64 files of 64 KiB per forwarding family.
Forwarding markers are hints: they do not resolve all includes or prove event
delivery. Exit 1 indicates known validation failure; 2 indicates incomplete
coverage. Confirm a fresh benign event arrives at the approved remote collector
and verify queue/drop behavior before and after any control change. Never infer
an authorized collector address from an example.

Falco's wrapper only checks version/local rules; it does not lock files,
install drivers, or restart Falco. Wazuh installation remains unavailable.
The older `shell/services/prom_grafana/` runbooks are manual recipes, not tested
deployment automation. Promtail reached EOL on March 2, 2026; plan and verify an
Alloy migration while preserving ingestion. References:
[Falco CLI](https://falco.org/docs/reference/daemon/cli-arguments/),
[Prometheus readiness](https://prometheus.io/docs/prometheus/latest/management_api/),
[Wazuh logcollector](https://documentation.wazuh.com/current/user-manual/reference/daemons/wazuh-logcollector.html),
[Promtail status](https://grafana.com/docs/loki/latest/send-data/promtail/).

## Mounts and immutable attributes

```sh
sudo sh shell/tools/mount_audit.sh
sudo sh shell/tools/attribute_audit.sh --path /etc/fstab
sudo sh shell/tools/attribute_fix.sh --path /etc/fstab --flag i --clear --plan
```

Mount audit compares `/etc/fstab` with the current namespace's mountinfo and
runs `findmnt --verify` when installed; it never mounts, remounts or edits fstab.
Limits are 30 seconds, 1 MiB fstab input and 10000 active mount entries.
Container overlays, bind mounts, subvolumes and network filesystems can be
required. A missing `noexec` flag or unlisted mount is a review lead.

Attribute audit is nonrecursive. Attribute repair changes only `i` or `a` on
one existing literal regular file and requires `--apply --yes`; it rejects
symlinks, ambiguous paths and non-root mount crossings. It records device/inode
identity and the original bit, checks the result, and writes a private rollback
script under `/var/backups/ccdc-attributes.*`. Clearing immutable state is not
proof the file is safe; setting it can break updates and log rotation. Check
filesystem support and service dependencies first. References:
[findmnt](https://man7.org/linux/man-pages/man8/findmnt.8.html),
[chattr](https://man7.org/linux/man-pages/man1/chattr.1.html).

## Optional MAC and service isolation

Both tools require explicit apply confirmation and operator-written executable
probes that prove the reviewed service works and fresh logs reach the approved
destination. Probe correctness is the operator's responsibility. Test on a
matching disposable host and preserve console access before applying.

```sh
sh shell/mac_policy.sh --plan
sh shell/tools/service_isolate.sh --plan --mode sandbox \
  --service reviewed.service --init systemd
sh shell/tools/service_isolate.sh --plan --mode container \
  --service reviewed --init openrc --runtime podman --container reviewed-staged
```

`mac_policy.sh` defaults to a read-only audit. Apply needs `--apply --yes
--backend apparmor|selinux --service NAME --init systemd|openrc --path ABS
--health-check ABS_EXEC --log-check ABS_EXEC`. AppArmor also needs `--profile
ABS`: a new standalone executable-attached profile, at most 64 KiB, with no
includes/aliases/namespaces and exactly one attachment matching `--path`.
The parser validates it before a runtime load; existing profiles are refused,
and the named service is restarted. SELinux instead needs `--type TYPE` and
changes only one existing file/directory type with nonrecursive `chcon`, saving
the exact old context. Neither installs packages, changes global enforcement,
generates policy, nor makes persistent labeling rules.

MAC service status, health and fresh-log probes run before/after; probes must
be root-owned and not group/world-writable, with 20-second deadlines and
private bounded output. Apply records rollback under
`/var/tmp/ccdc-mac.*` and attempts recovery on failure. Explicit recovery uses
`sh shell/mac_policy.sh --rollback PRIVATE_STATE_DIR --yes`, followed by the
same checks. Runtime AppArmor loads and SELinux labels need separate reboot
and policy-reload planning. See [AppArmor parser](https://manpages.ubuntu.com/manpages/noble/en/man8/apparmor_parser.8.html)
and [SELinux chcon](https://www.gnu.org/software/coreutils/manual/html_node/chcon-invocation.html).

`service_isolate.sh` defaults to plan; `--audit` is also a plan. Sandbox mode
is systemd-only and creates a previously absent dedicated drop-in containing
`NoNewPrivileges=yes` and `RestrictSUIDSGID=yes`. Container mode supports
systemd/OpenRC source services and Docker/Podman, but only an existing stopped
unprivileged container with no host PID/network namespace, no auto-remove and
restart policy `no`. The tool never builds/pulls/creates containers or changes
boot enablement. Review ports, mounted data, users, dependencies, socket
activation and reboot behavior before the service handoff.

Isolation apply requires `--apply --yes --reviewed --output NEW_ABSOLUTE_DIR`
and three executable probes: `--validate`, `--health-check`, `--logging-check`.
They receive `pre` or `post`, have 30-second deadlines, and must exit zero;
output is suppressed. The logging probe must verify service delivery and EDR
visibility. The private output directory contains `rollback.sh`; run it with
`--apply --yes` to restore the prior service arrangement. Apply attempts it on
failure. A subsequently edited managed drop-in requires manual recovery.
See [systemd execution controls](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html),
[Docker security](https://docs.docker.com/engine/security/),
and [Podman inspect](https://docs.podman.io/en/latest/markdown/podman-container-inspect.1.html).

## Optional OpenCode and OMO

The target-side nonroot installers are described in the
[main README](../README.md#optional-opencode-defender-agent). Neither setup
check/audit nor development-machine validation installs these products.
`opencode_omo_plugin.sh` installs the OpenCode plugin `oh-my-openagent@5.1.9`,
not the standalone OMO binary. It requires an exact matching OpenCode V1
installation, pins Bun `1.4.2`, and refuses existing OpenCode/OMO config files.
Its minimum free-space preflight is 384 MiB. Installer/doctor timeouts do not
provide a transactional rollback for package caches or partial installation.

Bundled `opencode_omo_host.json` selects `opencode/big-pickle` and registers the
plugin. `opencode_omo_free.json` routes text agents/categories to that model
and the multimodal agent/visual category to `opencode/mimo-v2.6-flash-free`.
These are configured IDs, not a promise of continuing availability, free usage,
or successful requests. Validate account access, provider data handling and
event permission separately; see [OpenCode Zen](https://opencode.ai/docs/zen/).

## Distribution review and validation

Consult the installed distro's version-specific documentation before applying
optional controls. [ArchWiki ClamAV](https://wiki.archlinux.org/title/ClamAV),
[ArchWiki AppArmor](https://wiki.archlinux.org/title/AppArmor),
[Gentoo ClamAV](https://wiki.gentoo.org/wiki/ClamAV) and
[Gentoo SELinux](https://wiki.gentoo.org/wiki/Project:SELinux) are operator
references; their primary wiki content was access-blocked during this review,
so links do not establish distro integration validation. Read the
[validation matrix](VALIDATION_MATRIX.md) for real runs, adapters and gaps.

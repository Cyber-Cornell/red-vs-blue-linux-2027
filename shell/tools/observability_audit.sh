#!/bin/sh
set -u
case "${1:---audit}" in
  --help|-h)
    printf '%s\n' 'Usage: observability_audit.sh [--audit]' 'Read-only telemetry inventory, config checks and fixed loopback readiness.' 'No config bodies, credentials, metrics payloads, service changes or external requests.' '60-second deadline; exit 1 known check failure, 2 incomplete coverage, 0 surveyed without failures.'
    exit 0 ;;
  --audit) [ "$#" -le 1 ] || exit 2 ;;
  *) printf 'Unsupported argument\n' >&2; exit 2 ;;
esac
command -v timeout >/dev/null 2>&1 || { printf 'UNKNOWN timeout unavailable\n'; exit 2; }
if [ "${CCDC_OBSERVABILITY_WORKER:-0}" != 1 ]; then
  CCDC_OBSERVABILITY_WORKER=1; export CCDC_OBSERVABILITY_WORKER
  exec timeout -s TERM -k 5 60 sh "$0" --audit
fi
FAIL=0 UNKNOWN=0 INIT=none
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then INIT=systemd
elif command -v rc-service >/dev/null 2>&1; then INIT=openrc; fi
printf 'TELEMETRY init=%s; fixed paths/ports, current namespace, bounded coverage\n' "$INIT"
unit_state() {
  unit=$1 binary=$2 config=$3
  present=0
  command -v "$binary" >/dev/null 2>&1 && present=1
  [ ! -e "$config" ] || present=1
  case "$INIT" in
    systemd)
      loaded=$(timeout 3 systemctl show --property=LoadState --value "$unit" 2>/dev/null) || loaded=unknown
      [ "$loaded" != loaded ] || present=1 ;;
    openrc) timeout 3 rc-service --exists "$unit" >/dev/null 2>&1 && present=1 ;;
  esac
  if [ "$present" -eq 0 ]; then printf 'SERVICE %s absent-or-undetected\n' "$unit"; return; fi
  case "$INIT" in
    systemd) if timeout 3 systemctl is-active --quiet "$unit"; then state=active; else state=inactive-or-query-failed; UNKNOWN=1; fi ;;
    openrc) if timeout 3 rc-service "$unit" status >/dev/null 2>&1; then state=started; else state=stopped-or-query-failed; UNKNOWN=1; fi ;;
    *) state=unknown-no-manager; UNKNOWN=1 ;;
  esac
  printf 'SERVICE %s state=%s\n' "$unit" "$state"
}
for row in \
  'falco|falco|/etc/falco/falco.yaml' \
  'prometheus|prometheus|/etc/prometheus/prometheus.yml' \
  'node_exporter|node_exporter|/etc/conf.d/node_exporter' \
  'prometheus-node-exporter|prometheus-node-exporter|/etc/default/prometheus-node-exporter' \
  'wazuh-agent|/var/ossec/bin/wazuh-agentd|/var/ossec/etc/ossec.conf' \
  'wazuh-manager|/var/ossec/bin/wazuh-analysisd|/var/ossec/etc/ossec.conf' \
  'loki|loki|/etc/loki/config.yml' \
  'alloy|alloy|/etc/alloy/config.alloy' \
  'promtail|promtail|/etc/promtail/config.yml' \
  'auditd|auditd|/etc/audit/auditd.conf' \
  'rsyslog|rsyslogd|/etc/rsyslog.conf' \
  'systemd-journald|systemd-journald|/etc/systemd/journald.conf'; do
  unit=${row%%|*}; rest=${row#*|}; binary=${rest%%|*}; config=${rest#*|}
  unit_state "$unit" "$binary" "$config"
done
validate() {
  name=$1 file=$2; shift 2
  [ -f "$file" ] || return 0
  if [ -L "$file" ] || [ ! -r "$file" ] || [ "$(wc -c <"$file")" -gt 1048576 ]; then
    printf 'CONFIG %s UNKNOWN unreadable/symlink/over-1MiB\n' "$name"; UNKNOWN=1; return
  fi
  if ! command -v "$1" >/dev/null 2>&1; then printf 'CONFIG %s UNKNOWN validator-unavailable\n' "$name"; UNKNOWN=1; return; fi
  if timeout -s TERM -k 1 5 "$@" >/dev/null 2>&1; then
    printf 'CONFIG %s validator-accepted (does-not-prove-delivery)\n' "$name"
  else printf 'CONFIG %s FAILED-or-timeout (diagnostics suppressed; review privately)\n' "$name"; FAIL=1; fi
}
validate prometheus /etc/prometheus/prometheus.yml promtool check config /etc/prometheus/prometheus.yml
validate loki /etc/loki/config.yml loki -verify-config=true -config.file=/etc/loki/config.yml
validate alloy /etc/alloy/config.alloy alloy validate /etc/alloy/config.alloy
validate falco-local-rules /etc/falco/falco_rules.local.yaml falco --validate /etc/falco/falco_rules.local.yaml
validate rsyslog /etc/rsyslog.conf rsyslogd -N1
if [ -f /var/ossec/etc/ossec.conf ]; then
  validate wazuh-logcollector /var/ossec/etc/ossec.conf /var/ossec/bin/wazuh-logcollector -t
fi
for row in 'prometheus|9090|/-/ready' 'loki|3100|/ready' 'alloy|12345|/-/ready'; do
  name=${row%%|*}; rest=${row#*|}; port=${rest%%|*}; endpoint=${rest#*|}
  if ! command -v "$name" >/dev/null 2>&1; then continue; fi
  if ! command -v curl >/dev/null 2>&1; then printf 'HEALTH %s UNKNOWN curl-unavailable\n' "$name"; UNKNOWN=1; continue; fi
  code=$(timeout 4 curl -q --noproxy '*' --proto '=http' --connect-timeout 2 --max-time 3 --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:$port$endpoint" 2>/dev/null) || code=unreachable
  case "$code" in 200) printf 'HEALTH %s default-loopback-ready\n' "$name" ;;
    *) printf 'HEALTH %s UNKNOWN default-port-not-ready-or-custom-auth\n' "$name"; UNKNOWN=1 ;; esac
done
marker() {
  file=$1 pattern=$2
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 1
  head -c 65536 "$file" | sed '/^[[:space:]]*#/d' | grep -Eq "$pattern"
}
forward=0 journal_input=0 remote=0 count=0
for file in /etc/systemd/journald.conf /etc/systemd/journald.conf.d/*.conf; do
  [ -f "$file" ] || continue
  count=$((count + 1)); [ "$count" -le 64 ] || { UNKNOWN=1; break; }
  marker "$file" '^[[:space:]]*ForwardToSyslog[[:space:]]*=[[:space:]]*yes' && forward=1
done
count=0
for file in /etc/rsyslog.conf /etc/rsyslog.d/*.conf; do
  [ -f "$file" ] || continue
  count=$((count + 1)); [ "$count" -le 64 ] || { UNKNOWN=1; break; }
  marker "$file" 'imjournal' && journal_input=1
  marker "$file" 'omfwd|@@?[^[:space:]]' && remote=1
done
printf 'FORWARDING hints journald-to-syslog=%s rsyslog-imjournal=%s rsyslog-remote=%s\n' "$forward" "$journal_input" "$remote"
if [ "$forward" -eq 1 ] && [ "$journal_input" -eq 1 ]; then printf 'REVIEW possible duplicate journal ingestion; resolve effective config before changes\n'; fi
if [ "$remote" -eq 0 ]; then printf 'REVIEW no rsyslog remote marker; verify another approved collector/destination\n'; fi
for row in \
  '/var/ossec/etc/ossec.conf|journald|wazuh-journal-input' \
  '/etc/alloy/config.alloy|loki\.write|alloy-loki-output' \
  '/etc/falco/falco.yaml|syslog_output|falco-syslog-output-section' \
  '/etc/falco/falco.yaml|http_output|falco-http-output-section'; do
  file=${row%%|*}; rest=${row#*|}; pattern=${rest%%|*}; name=${rest#*|}
  if marker "$file" "$pattern"; then printf 'FORWARDING hint=%s present-not-validated-effective\n' "$name"; fi
done
if command -v ss >/dev/null 2>&1; then
  timeout 3 ss -H -lntun 2>/dev/null | awk 'NR<=128 {n=split($5,a,":"); p=a[n]; if(p ~ /^(3100|9090|9100|12345|1514|1515|55000)$/) print "LISTENER proto=" $1 " local=" $5} NR==129 {print "UNKNOWN listener output truncated"}'
else printf 'LISTENER UNKNOWN ss-unavailable\n'; UNKNOWN=1; fi
if command -v promtail >/dev/null 2>&1 || [ -e /etc/promtail/config.yml ]; then printf 'REVIEW Promtail is EOL; plan a validated Alloy migration, preserve ingestion\n'; fi
printf '%s\n' 'LIMITS: 64 files per forwarding family, 64KiB each; markers ignore comment-only lines but not include precedence.' 'No log delivery, event freshness, queue loss, authentication or EDR detection efficacy is established.'
[ "$FAIL" -eq 0 ] || exit 1
[ "$UNKNOWN" -eq 0 ] || exit 2

#!/bin/bash
# =======================================================================
# This script:
#   - Enables Modern eBPF 
#   - Enables structured JSON logging
#   - Enables file + stderr logging
#   - Adds safe rate limiting
#   - Hardens systemd restart behavior
#   - Locks Falco configs AFTER validation
#
#   Files you MUST have created before running:
#     - /etc/falco/falco_rules.local.yaml
#     - /etc/falco/config.d/engine-kind-modern-ebpf.yaml
# =======================================================================

set -euo pipefail

# -------------------------
# VARIABLES
# -------------------------
FALCO_DIR="/etc/falco"
FALCO_YAML="$FALCO_DIR/falco.yaml"
FALCO_RULES_LOCAL="$FALCO_DIR/falco_rules.local.yaml"
FALCO_ENGINE_CONF="$FALCO_DIR/config.d/engine-kind-modern-ebpf.yaml"
FALCO_LOG="/var/log/falco.log"

echo "[+] Starting Falco hardening..."

# -------------------------
# ROOT CHECK
# -------------------------
if [[ $EUID -ne 0 ]]; then
  echo "[-] Must be run as root."
  exit 1
fi

# -------------------------
# SANITY CHECKS
# -------------------------
command -v falco >/dev/null || { echo "[-] Falco not installed."; exit 1; }

[[ -f "$FALCO_RULES_LOCAL" ]] || {
  echo "[-] Missing $FALCO_RULES_LOCAL (YOU must create this file)."
  exit 1
}

# -------------------------
# 1. ENABLE MODERN eBPF
# -------------------------
echo "[+] Enabling Modern eBPF engine..."

mkdir -p "$FALCO_DIR/config.d"

cat <<EOF > "$FALCO_ENGINE_CONF"
engine:
  kind: modern_ebpf
EOF

# -------------------------
# 2. ENABLE LOGGING OUTPUTS
# -------------------------
echo "[+] Configuring Falco logging..."

cp "$FALCO_YAML" "$FALCO_YAML.bak.$(date +%F_%T)"

sed -i 's/^json_output:.*/json_output: true/' "$FALCO_YAML"
sed -i 's/^log_stderr:.*/log_stderr: true/' "$FALCO_YAML"
sed -i 's/^log_syslog:.*/log_syslog: true/' "$FALCO_YAML"

# Enable file output cleanly
sed -i '/^file_output:/,/^[^ ]/d' "$FALCO_YAML"

cat <<EOF >> "$FALCO_YAML"

file_output:
  enabled: true
  keep_alive: false
  filename: $FALCO_LOG
EOF

touch "$FALCO_LOG"
chmod 640 "$FALCO_LOG"
chown root:root "$FALCO_LOG"

# -------------------------
# 3. SAFE RATE LIMITING (OUTPUT ONLY) (is this needed/helpful?)
# -------------------------
echo "[+] Enabling safe rate limiting..."

sed -i '/^rate_limit:/,/^[^ ]/d' "$FALCO_YAML"

cat <<EOF >> "$FALCO_YAML"

rate_limit:
  enabled: true
  max_burst: 20
  period: 1s
EOF

# -------------------------
# 4. SYSTEMD HARDENING
# -------------------------
echo "[+] Hardening Falco systemd service..."

mkdir -p /etc/systemd/system/falco.service.d/

cat <<EOF > /etc/systemd/system/falco.service.d/override.conf
[Service]
Restart=always
RestartSec=5
StartLimitIntervalSec=0
EOF

systemctl daemon-reload

# -------------------------
# 5. VALIDATE RULES BEFORE LOCKING
# -------------------------
echo "[+] Validating Falco rules..."
falco --validate "$FALCO_RULES_LOCAL"

# -------------------------
# 6. RESTART FALCO
# -------------------------
echo "[+] Restarting Falco..."
systemctl restart falco
sleep 2

systemctl is-active --quiet falco || {
  echo "[-] Falco failed to start."
  exit 1
}

echo "[+] Falco is running."

# -------------------------
# 7. LOCK CONFIGS
# -------------------------
echo "[+] Applying immutable flags (FINAL STEP)..."

chattr +i "$FALCO_YAML"
chattr +i "$FALCO_RULES_LOCAL"
chattr +i "$FALCO_ENGINE_CONF"

echo "[+] Falco hardening complete."
echo "[+] Modern eBPF enabled, logging secured, monitoring locked."

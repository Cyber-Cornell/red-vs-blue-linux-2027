## Create Discord webhook 

- Discord channel → Edit Channel → Integrations → Webhooks → New Webhook   
- Copy the webhook URL.   
- You should store it as:   
  - an environment file (/etc/alertmanager/alertmanager.env) OR   
  - a placeholder in repo and paste during competition   
- Do not hardcode webhook URLs in GitHub.   

# Part A — Install Alertmanager (Brain Box)

## A1) Create service user

```bash
sudo useradd -r -s /bin/false alertmanager 2>/dev/null || true
```

## A2) Download Alertmanager (GitHub release)

Choose a stable version (example: 0.27.0).

```bash
cd /tmp
VER="0.27.0"
ARCH="linux-amd64"

curl -fL -o alertmanager.tar.gz \
  "https://github.com/prometheus/alertmanager/releases/download/v${VER}/alertmanager-${VER}.${ARCH}.tar.gz"

tar -xzf alertmanager.tar.gz
sudo mkdir -p /etc/alertmanager /var/lib/alertmanager
sudo cp "alertmanager-${VER}.${ARCH}/alertmanager" /usr/local/bin/
sudo cp "alertmanager-${VER}.${ARCH}/amtool" /usr/local/bin/
sudo chown -R alertmanager:alertmanager /etc/alertmanager /var/lib/alertmanager
sudo chmod 0755 /usr/local/bin/alertmanager /usr/local/bin/amtool
```

# Part B — Alertmanager Configuration

## B1) Create /etc/alertmanager/alertmanager.yml

This file routes critical alerts to Discord, groups them sensibly, and avoids spam.

```bash
sudo tee /etc/alertmanager/alertmanager.yml >/dev/null <<'EOF'
global:
  resolve_timeout: 5m

route:
  receiver: "discord-critical"
  group_by: ["alertname", "host"]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

  routes:
    - matchers:
        - severity="critical"
      receiver: "discord-critical"

    - matchers:
        - severity="warning"
      receiver: "discord-warning"

receivers:
  - name: "discord-critical"
    webhook_configs:
      - url: "DISCORD_WEBHOOK_URL_CRITICAL"
        send_resolved: true

  - name: "discord-warning"
    webhook_configs:
      - url: "DISCORD_WEBHOOK_URL_WARNING"
        send_resolved: true
EOF
```

## B2) Replace placeholders (VERY IMPORTANT)

Replace:
- `DISCORD_WEBHOOK_URL_CRITICAL`
- `DISCORD_WEBHOOK_URL_WARNING`

With real Discord webhook URLs.

📌 **Best practice for competition:**
- Use one webhook if you want simplicity
- Or two channels: #alerts-critical, #alerts-warning

⚠️ **Never commit real webhook URLs to GitHub**

## B3) Validate config

```bash
sudo amtool check-config /etc/alertmanager/alertmanager.yml
```

Must say SUCCESS.

# Part C — systemd Service

## C1) Create /etc/systemd/system/alertmanager.service

```bash
sudo tee /etc/systemd/system/alertmanager.service >/dev/null <<'EOF'
[Unit]
Description=Prometheus Alertmanager
Wants=network-online.target
After=network-online.target

[Service]
User=alertmanager
Group=alertmanager
Type=simple
ExecStart=/usr/local/bin/alertmanager \
  --config.file=/etc/alertmanager/alertmanager.yml \
  --storage.path=/var/lib/alertmanager
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
```

## C2) Enable and start

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now alertmanager
sudo systemctl status alertmanager --no-pager -l
```

# Part D — Firewall Rules (Brain Box)

Alertmanager listens on 9093 by default.

**If Prometheus and Alertmanager are on the same host:**
```bash
sudo iptables -I INPUT -p tcp -s 127.0.0.1 --dport 9093 -j ACCEPT
```

**If Prometheus connects over the network:**
```bash
sudo iptables -I INPUT -p tcp --dport 9093 -j ACCEPT
```

# Part E — Connect Prometheus to Alertmanager

## E1) Edit prometheus.yml

Add or confirm this section exists:

```yaml
alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - "127.0.0.1:9093"
```

Validate and restart:
```bash
sudo promtool check config /etc/prometheus/prometheus.yml
sudo systemctl restart prometheus
```

# Part F — Add Alert Rules (Required)

Create `/etc/prometheus/alert.rules.yml` (example minimal set):

```yaml
groups:
- name: ccdc-core
  rules:
  - alert: TargetDown
    expr: up == 0
    for: 2m
    labels:
      severity: critical
    annotations:
      summary: "Target down: {{ $labels.host }}"
```

Ensure Prometheus loads it:
```yaml
rule_files:
  - "/etc/prometheus/alert.rules.yml"
```

# Part G — Test Alerts (DO NOT SKIP)

## G1) Create a test alert

Add temporarily:

```yaml
- alert: TestAlert
  expr: vector(1)
  for: 10s
  labels:
    severity: critical
  annotations:
    summary: "Alertmanager test alert"
```

Restart Prometheus.

## G2) Confirm Discord receives alert

- Message appears within ~30 seconds
- "Resolved" message arrives when rule removed
- Then remove the test rule.

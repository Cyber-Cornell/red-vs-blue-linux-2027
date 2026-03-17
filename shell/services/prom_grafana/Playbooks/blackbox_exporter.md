# PART A — Install Blackbox Exporter (Brain Box)

## A1) Create service user

```bash
sudo useradd -r -s /bin/false blackbox_exporter 2>/dev/null || true
```

## A2) Download Blackbox Exporter binary

Choose a stable version (example: 0.25.0).

```bash
cd /tmp
VER="0.25.0"
ARCH="linux-amd64"

curl -fL -o blackbox_exporter.tar.gz \
  "https://github.com/prometheus/blackbox_exporter/releases/download/v${VER}/blackbox_exporter-${VER}.${ARCH}.tar.gz"

tar -xzf blackbox_exporter.tar.gz
sudo mkdir -p /etc/blackbox
sudo cp blackbox_exporter-${VER}.${ARCH}/blackbox_exporter /usr/local/bin/
sudo chown blackbox_exporter:blackbox_exporter /usr/local/bin/blackbox_exporter
sudo chmod 0755 /usr/local/bin/blackbox_exporter
```

# PART B — Blackbox Configuration

## B1) Create config file: /etc/blackbox/blackbox.yml

```bash
sudo tee /etc/blackbox/blackbox.yml >/dev/null <<'EOF'
modules:
  # Standard HTTP check (2xx)
  http_2xx:
    prober: http
    timeout: 10s
    http:
      method: GET
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes: []   # empty = accept any 2xx
      preferred_ip_protocol: ip4
      no_follow_redirects: false

  # HTTPS check ignoring bad/self-signed certs (common in CCDC)
  https_2xx_insecure:
    prober: http
    timeout: 10s
    http:
      method: GET
      preferred_ip_protocol: ip4
      fail_if_ssl: false
      tls_config:
        insecure_skip_verify: true

  # TCP connect check (optional)
  tcp_connect:
    prober: tcp
    timeout: 5s
EOF
```

**Permissions:**
```bash
sudo chown -R blackbox_exporter:blackbox_exporter /etc/blackbox
sudo chmod 0640 /etc/blackbox/blackbox.yml
```

# PART C — systemd Service

## C1) Create /etc/systemd/system/blackbox_exporter.service

```ini
[Unit]
Description=Prometheus Blackbox Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=blackbox_exporter
Group=blackbox_exporter
Type=simple
ExecStart=/usr/local/bin/blackbox_exporter \
  --config.file=/etc/blackbox/blackbox.yml \
  --web.listen-address=:9115
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

## C2) Enable and start

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now blackbox_exporter
sudo systemctl status blackbox_exporter --no-pager -l
```

# PART D — Firewall (Brain Box)

If Prometheus scrapes Blackbox locally (recommended):

```bash
sudo iptables -C INPUT -p tcp -s 127.0.0.1 --dport 9115 -j ACCEPT 2>/dev/null || \
sudo iptables -I INPUT -p tcp -s 127.0.0.1 --dport 9115 -j ACCEPT
```

No outbound firewall changes needed unless OUTPUT is locked down.

# PART E — Prometheus Configuration

## E1) Scrape the exporter itself (health)

Add to prometheus.yml:

```yaml
- job_name: blackbox_exporter
  static_configs:
    - targets: ["127.0.0.1:9115"]
```

## E2) WordPress HTTP probe

Add below the exporter job:

```yaml
- job_name: blackbox_http
  metrics_path: /probe
  params:
    module: [http_2xx]
  static_configs:
    - targets:
        - http://10.0.X.131/
      labels:
        host: wp01
        role: wordpress
  relabel_configs:
    - source_labels: [__address__]
      target_label: __param_target
    - source_labels: [__param_target]
      target_label: instance
    - target_label: __address__
      replacement: 127.0.0.1:9115
```

**Replace:**
- `http://10.0.X.131/` → WordPress URL
- `wp01` → your host label

## E3) Optional: Teleport HTTPS probe

```yaml
- job_name: blackbox_http
  metrics_path: /probe
  params:
    module: [https_2xx_insecure]
  static_configs:
    - targets:
        - https://10.0.X.130:443/
      labels:
        host: teleport01
        role: access-control
  relabel_configs:
    - source_labels: [__address__]
      target_label: __param_target
    - source_labels: [__param_target]
      target_label: instance
    - target_label: __address__
      replacement: 127.0.0.1:9115
```

## E4) Validate and restart Prometheus

```bash
sudo promtool check config /etc/prometheus/prometheus.yml
sudo systemctl restart prometheus
```

# PART F — Validation (DO NOT SKIP)

## F1) Check exporter health

```bash
curl http://127.0.0.1:9115/metrics | head
```

## F2) Manual probe test

```bash
curl "http://127.0.0.1:9115/probe?target=http://10.0.X.131/&module=http_2xx"
```

You should see:
```
probe_success 1
```

## F3) Prometheus UI

Status → Targets

Confirm:
- `blackbox_exporter` = UP
- `blackbox_http` (WordPress) = UP

# PART G — Alerts (must exist)

Add to alert.rules.yml:

```yaml
- alert: WordPressHttpDown
  expr: probe_success{job="blackbox_http",role="wordpress"} == 0
  for: 1m
  labels:
    severity: critical
  annotations:
    summary: "WordPress HTTP check failing"
```

**Optional latency alert:**

```yaml
- alert: WordPressHttpSlow
  expr: probe_duration_seconds{job="blackbox_http",role="wordpress"} > 2
  for: 5m
  labels:
    severity: warning
```
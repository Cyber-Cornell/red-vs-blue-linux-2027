# PART A — Install Loki (Brain Box)

## A1) Create user and directories

```bash
sudo useradd -r -s /bin/false loki 2>/dev/null || true
sudo mkdir -p /etc/loki /var/lib/loki
sudo chown -R loki:loki /etc/loki /var/lib/loki
```

## A2) Download Loki binary

```bash
cd /tmp
VER="2.9.4"
ARCH="linux-amd64"

curl -fL -o loki.zip \
  "https://github.com/grafana/loki/releases/download/v${VER}/loki-${ARCH}.zip"

unzip loki.zip
sudo mv loki-${ARCH} /usr/local/bin/loki
sudo chmod 0755 /usr/local/bin/loki
```

## A3) Loki configuration

Create `/etc/loki/loki-config.yml`:

```yaml
auth_enabled: false

server:
  http_listen_port: 3100

common:
  instance_addr: 127.0.0.1
  path_prefix: /var/lib/loki
  storage:
    filesystem:
      chunks_directory: /var/lib/loki/chunks
      rules_directory: /var/lib/loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: boltdb-shipper
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  retention_period: 168h   # 7 days
  max_query_length: 72h

chunk_store_config:
  max_look_back_period: 72h

table_manager:
  retention_deletes_enabled: true
  retention_period: 168h
```

💡 **Why this config**
- Single-node safe
- No auth complexity
- File-backed storage
- Controlled retention (no disk explosions)

## A4) systemd service (loki.service)

```ini
[Unit]
Description=Loki Log Aggregation System
After=network-online.target

[Service]
User=loki
Group=loki
ExecStart=/usr/local/bin/loki -config.file=/etc/loki/loki-config.yml
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

**Enable and start:**
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now loki
sudo systemctl status loki --no-pager
```

## A5) Firewall

```bash
sudo iptables -I INPUT -p tcp -s 127.0.0.1 --dport 3100 -j ACCEPT
```

(External access not needed — Grafana runs locally.)

# PART B — Grafana: Add Loki datasource

Grafana UI:
1. Settings → Data Sources → Add data source
2. Select **Loki**
3. URL: `http://127.0.0.1:3100`
4. Save & Test → should succeed

# PART C — Install Promtail (Linux Nodes)

## C1) Download promtail

```bash
cd /tmp
VER="2.9.4"

curl -fL -o promtail.zip \
  "https://github.com/grafana/loki/releases/download/v${VER}/promtail-linux-amd64.zip"

unzip promtail.zip
sudo mv promtail-linux-amd64 /usr/local/bin/promtail
sudo chmod 0755 /usr/local/bin/promtail
```

## C2) Promtail config (Linux)

Create `/etc/promtail/promtail.yml`:

```yaml
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /var/lib/promtail/positions.yml

clients:
  - url: http://BRAIN_IP:3100/loki/api/v1/push

scrape_configs:
  - job_name: system
    static_configs:
      - targets:
          - localhost
        labels:
          job: syslog
          host: HOSTNAME
          __path__: /var/log/*.log

  - job_name: auth
    static_configs:
      - targets:
          - localhost
        labels:
          job: auth
          host: HOSTNAME
          __path__: /var/log/auth.log
```

**Replace:**
- `BRAIN_IP` → Prometheus/Grafana IP
- `HOSTNAME` → wp01, teleport01, falco01, etc.

## C3) systemd service (promtail.service)

```ini
[Unit]
Description=Promtail Log Shipper
After=network-online.target

[Service]
ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail/promtail.yml
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

**Enable/start:**
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now promtail
```

**Firewall:**
```bash
sudo iptables -I OUTPUT -p tcp -d BRAIN_IP --dport 3100 -j ACCEPT
```

# PART D — Promtail (Windows)

## D1) Download promtail (Windows)

- https://github.com/grafana/loki/releases
- Get `promtail-windows-amd64.exe`
- Place in: `C:\Program Files\Promtail\`

## D2) Promtail Windows config

`C:\Program Files\Promtail\promtail.yml`

```yaml
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: C:\ProgramData\promtail\positions.yml

clients:
  - url: http://BRAIN_IP:3100/loki/api/v1/push

scrape_configs:
  - job_name: windows-security
    windows_events:
      use_incoming_timestamp: false
      bookmark_path: C:\ProgramData\promtail\bookmark.xml
      eventlog_name: Security
      xpath_query: "*"
    labels:
      job: windows-security
      host: HOSTNAME
```

## D3) Install as Windows service

```cmd
sc.exe create promtail binPath= "C:\Program Files\Promtail\promtail-windows-amd64.exe -config.file=C:\Program Files\Promtail\promtail.yml"
sc.exe start promtail
```

# PART E — Validation

## E1) Loki health

```bash
curl http://127.0.0.1:3100/ready
```

Should return `ready`.

## E2) Grafana → Explore

1. Select **Loki**
2. Query: `{host="wp01"}`

You should see logs.

## E3) Correlate alert → logs

1. Click alert timestamp
2. Switch to Explore
3. Filter logs by host

# PART F — What logs are worth collecting (CCDC)
## Linux
- `/var/log/auth.log`
- `/var/log/syslog`
- `/var/log/nginx/access.log`
- `/var/log/nginx/error.log`
## Windows
- Security log
- System log
## Falco
- `/var/log/falco*`
## pfSense
- Remote Syslog
# Enable SNMP
1) Log in to pfSense Web UI
2) Go to SERVICES -> SNMP
3) Check: Enable the SNMP daemon
4. SNMP version: v2c
5. Community String: Set to agreed value
6. Bind Interfaces
    - Select interface that Prometheus box can reach (LAN)
7. Allowed IPs: only add Prometheus box
8. Save/Apply

# Brain Box: Install snmp_exporter

```
sudo useradd -r -s /bin/false snmp_exporter 2>/dev/null || true
```

```
cd /tmp
wget https://github.com/prometheus/snmp_exporter/releases/download/v0.30.1/snmp_exporter-0.30.1.linux-amd64.tar.gz

tar -xzf snmp_....

sudo mkdir -p /etc/snmp_exporter
# copy the folder unzipped contents into this new directory.
sudo chown -R snmp_exporter:snmp_exporter /etc/snmp_exporter
sudo chmod 0755 /etc/snmp_exporter/snmp_exporter
```

# Config
take snmp.yml config and change the community string.

sudo chown snmp_exporter:snmp_exporter /etc/snmp_exporter/snmp.yml
sudo chmod 0640 /etc/snmp_exporter/snmp.yml

# Create systemd service
/etc/systemd/system/snmp_exporter.service

```
# Create a systemd service file at /etc/systemd/system/snmp_exporter.service

[Unit]
Description=Prometheus SNMP Exporter
After=network.target

[Service]
User=prometheus
Group=prometheus
Execstart=/etc/snmp_expoter/snmp_exporter --config.file=/etc/snmp_exporter/snmp.yml --web.listen-address=:9116
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

# Enable and Start
```
sudo systemctl daemon-reload
sudo systemctl enable --now snmp_exporter
sudo systemctl status snmp_exporter --no-pager -l
```

# Validate and restart
```
sudo promtool check config /etc/prometheus/prometheus.yml

sudo systemctl restart prometheus

curl -s http://127.0.0.1:9116/metrics | head
```
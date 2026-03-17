Do on linux nodes.
# Install
```
useradd -r -s /bin/false node_exporter

curl -LO https://github.com/prometheus/node_exporter/releases/download/v1.10.2/node_exporter-1.10.2.linux-amd64.tar.gz
tar xzf node_exporter-*.tar.gz
cp node_exporter-*/node_exporter /usr/local/bin/
chown node_exporter:node_exporter /usr/local/bin/node_exporter
```

# Systemd
Create a systemd service file at /etc/systemd/system/node_exporter.service
```
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter

[Install]
WantedBy=multi-user.target
```
- `systemctl daemon-reload`
- `systemctl enable --now node_exporter`

# Firewall
`iptables -I INPUT -p tcp --dport 9100 -j ACCEPT`
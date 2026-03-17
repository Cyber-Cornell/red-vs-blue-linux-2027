# Required Ports (iptables)

`iptables -I INPUT -p tcp --dport 9090 -j ACCEPT` # Prometheus

`iptables -I INPUT -p tcp --dport 3000 -j ACCEPT`   # Grafana

`iptables -I INPUT -p tcp --dport 9116 -j ACCEPT`  # SNMP exporter

# Verify services
`systemctl status prometheus`
`systemctl status grafana-server`
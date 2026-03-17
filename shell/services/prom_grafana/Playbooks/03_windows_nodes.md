# Download
```
Invoke-WebRequest -Uri https://github.com/prometheus-community/windows_exporter/releases/download/v0.31.3/windows_exporter-0.31.3-amd64.msi -OutFile "$env:TEMP\windows_exporter.msi"
```

# Install for AD
```
msiexec /i windows_exporter.msi ENABLED_COLLECTORS="cpu,cpu_info,logical_disk,memory,net,os,service,system,tcp,time,textfile,terminal_services,ad,dns,dfsr,smb,process" LISTEN_PORT=9182
```

# Install for Federation Server
```
msiexec /i windows_exporter.msi ENABLED_COLLECTORS="cpu,cpu_info,logical_disk,memory,net,os,service,system,tcp,time,textfile,terminal_services,adfs,iis,netframework,process" LISTEN_PORT=9182
```

# Enable Firewall
```
New-NetFirewallRule -DisplayName "windows_exporter" -Direction Inbound -Protocol TCP -LocalPort 9182 -Action Allow
```

# Verify
`Invoke-WebRequest http://127.0.0.1:9182/metrics | Select-String -First 5`
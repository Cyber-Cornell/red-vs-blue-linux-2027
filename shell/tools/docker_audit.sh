#!/bin/sh
# Docker Security Quick-Audit

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker not installed. Skipping."
  exit 0
fi

echo "Scanning Docker Configuration..."
echo "---------------------------------"

# 1. Check for Privileged Containers
# Privileged containers allow the container to do almost anything the host root can do.
echo "[1] Checking for Privileged Containers..."
docker ps --quiet --all | xargs docker inspect --format '{{.Name}}: Privileged={{.HostConfig.Privileged}}' 2>/dev/null | grep "true"
if [ $? -eq 0 ]; then
  echo "    [CRITICAL] Privileged containers found! These are trivial to break out of."
fi

# 2. Check for Mounted Docker Socket
# If /var/run/docker.sock is mounted inside a container, that container is effectively root on the host.
echo "[2] Checking for mounted Docker Sockets..."
docker ps --quiet --all | xargs docker inspect --format '{{.Name}} {{range .Mounts}} {{.Source}} {{end}}' 2>/dev/null | grep "docker.sock"
if [ $? -eq 0 ]; then
  echo "    [CRITICAL] Docker socket mounted inside container! (Root access exposed)."
fi

# 3. Check for Port Exposure
echo "[3] Checking globally exposed ports..."
docker ps --format "table {{.Names}}\t{{.Ports}}" | grep "0.0.0.0"

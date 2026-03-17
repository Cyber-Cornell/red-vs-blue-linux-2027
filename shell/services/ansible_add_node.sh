#!/bin/sh

# Stop on error
set -e

# ==============================================================================
# ADD ANSIBLE NODE
# Usage: ./add_ansible_node.sh <CLIENT_IP> [REMOTE_USER]
# ==============================================================================

INVENTORY_FILE="/etc/ansible/hosts"
DEFAULT_KEY_TYPE="ed25519" # Modern, secure default. Falls back to rsa if needed.

# 1. Input Validation
if [ -z "$1" ]; then
  echo "Usage: $0 <CLIENT_IP> [REMOTE_USER]"
  echo "Example: $0 192.168.1.50 root"
  exit 1
fi

CLIENT_IP="$1"
REMOTE_USER="${2:-root}" # Default to root if $2 is not provided

log() {
  echo "[INFO] $1"
}

error() {
  echo "[ERROR] $1"
  exit 1
}

# 2. Check/Generate SSH Keys for the Current User
# Ansible uses the current user's keys to connect.
log "Checking for existing SSH keys..."

PUB_KEY=""

# Check for ed25519 or rsa keys
if [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
  PUB_KEY="$HOME/.ssh/id_ed25519.pub"
elif [ -f "$HOME/.ssh/id_rsa.pub" ]; then
  PUB_KEY="$HOME/.ssh/id_rsa.pub"
fi

if [ -z "$PUB_KEY" ]; then
  log "No SSH key found. Generating a new $DEFAULT_KEY_TYPE key pair..."
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"

  # Generate key (no passphrase for automation purposes, or remove -N "" to prompt)
  ssh-keygen -t "$DEFAULT_KEY_TYPE" -f "$HOME/.ssh/id_$DEFAULT_KEY_TYPE" -N "" -q
  PUB_KEY="$HOME/.ssh/id_$DEFAULT_KEY_TYPE.pub"
  log "Key generated at $PUB_KEY"
else
  log "Found existing public key: $PUB_KEY"
fi

# 3. Copy SSH Key to Client
# We try ssh-copy-id first (standard), fallback to manual pipe (strictly POSIX)
log "Copying SSH key to $REMOTE_USER@$CLIENT_IP..."
log "⚠️  You will be prompted for the remote user's password."

if command -v ssh-copy-id >/dev/null 2>&1; then
  # Use standard tool
  ssh-copy-id -i "$PUB_KEY" "$REMOTE_USER@$CLIENT_IP"
else
  # Manual POSIX fallback if ssh-copy-id is missing
  cat "$PUB_KEY" | ssh "$REMOTE_USER@$CLIENT_IP" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
fi

# 4. Add IP to Ansible Inventory
# We need to handle permissions. /etc/ansible/hosts is usually root owned.

log "Adding $CLIENT_IP to $INVENTORY_FILE..."

# Check if inventory file exists, create if not
if [ ! -f "$INVENTORY_FILE" ]; then
  # Check if we have write access to parent dir
  if [ ! -w "$(dirname "$INVENTORY_FILE")" ] && [ "$(id -u)" -ne 0 ]; then
    # We need sudo to create the file
    log "Inventory file missing. Creating with sudo..."
    sudo mkdir -p "$(dirname "$INVENTORY_FILE")"
    sudo touch "$INVENTORY_FILE"
    sudo chmod 664 "$INVENTORY_FILE"
  else
    mkdir -p "$(dirname "$INVENTORY_FILE")"
    touch "$INVENTORY_FILE"
  fi
fi

# Check for duplicate IP
if grep -qF "$CLIENT_IP" "$INVENTORY_FILE"; then
  log "IP $CLIENT_IP is already in the inventory. Skipping add."
else
  # Append IP. Use sudo tee if file is not writable by current user.
  if [ -w "$INVENTORY_FILE" ]; then
    echo "$CLIENT_IP" >>"$INVENTORY_FILE"
  else
    log "Escalating privileges to write to inventory..."
    echo "$CLIENT_IP" | sudo tee -a "$INVENTORY_FILE" >/dev/null
  fi
  log "Inventory updated."
fi

# 5. Verification
log "Testing Ansible connection..."
if command -v ansible >/dev/null 2>&1; then
  ansible all -i "$CLIENT_IP," -m ping -u "$REMOTE_USER"
else
  log "Ansible command not found in PATH, skipping ping test."
  log "Node setup complete, but verify installation of Ansible binaries."
fi

echo "---------------------------------------------"
echo "Success! Node $CLIENT_IP is ready to be managed."
echo "---------------------------------------------"

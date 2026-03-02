#!/usr/bin/env bash
set -euo pipefail

: "${VAULT_ADDR:?Set VAULT_ADDR, e.g. https://xxx:8200}"
: "${ROLE_ID:?Set ROLE_ID in env}"
: "${SECRET_ID:?Set SECRET_ID in env}"

REMOVE_SECRET_ID_AFTER_READING="${REMOVE_SECRET_ID_AFTER_READING:-true}"
AGENT_LISTEN_ADDR="${AGENT_LISTEN_ADDR:-127.0.0.1:8200}"

# Detect OS
. /etc/os-release
ID_LIKE="${ID_LIKE:-}"
ID="${ID:-}"

hcp_vault_install() {
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "jq is required"; return 1; }

local latest_version
latest_version="$(
    /usr/bin/curl -fsSL --connect-timeout 5 --max-time 20 --retry 2 --retry-delay 1 \
    -- "https://checkpoint-api.hashicorp.com/v1/check/vault" \
    | /usr/bin/jq -er '.current_version'
)"

local url="https://releases.hashicorp.com/vault/${latest_version}/vault_${latest_version}_linux_amd64.zip"
local tmp_dir tmp_zip
tmp_dir="$(mktemp -d)"
tmp_zip="${tmp_dir}/vault.zip"

echo "Downloading Vault ${latest_version} from ${url}..."
/usr/bin/curl -fsSL --connect-timeout 5 --max-time 60 --retry 2 --retry-delay 1 \
    -o "$tmp_zip" -- "$url"

unzip -oq "$tmp_zip" -d "$tmp_dir"
install -m 0755 "${tmp_dir}/vault" /usr/bin/vault
rm -rf "$tmp_dir"

/usr/bin/vault version || true
}

if hcp_vault_install; then
  echo "Vault installed successfully"
else
  echo "Unsupported distro: ID=$ID ID_LIKE=$ID_LIKE" >&2
  exit 1
fi

# User + dirs
sudo useradd --system --home /etc/vault.d --shell /sbin/nologin vault 2>/dev/null || true
sudo mkdir -p /etc/vault.d /var/lib/vault-agent /run/vault-agent
sudo chown -R vault:vault /etc/vault.d /var/lib/vault-agent /run/vault-agent
sudo chmod 750 /etc/vault.d /var/lib/vault-agent

# Write AppRole materials (root writes, vault owns)
sudo install -o vault -g vault -m 600 /dev/null /etc/vault.d/role_id
sudo install -o vault -g vault -m 600 /dev/null /etc/vault.d/secret_id
printf '%s' "$ROLE_ID"   | sudo tee /etc/vault.d/role_id   >/dev/null
printf '%s' "$SECRET_ID" | sudo tee /etc/vault.d/secret_id >/dev/null
sudo chown vault:vault /etc/vault.d/role_id /etc/vault.d/secret_id
sudo chmod 600 /etc/vault.d/role_id /etc/vault.d/secret_id

# Agent config (AppRole auto-auth)
sudo tee /etc/vault.d/agent.hcl >/dev/null <<HCL
exit_after_auth = false
pid_file = "/run/vault-agent/pidfile"

vault {
  address = "${VAULT_ADDR}"
}

auto_auth {
  method "approle" {
    config = {
      role_id_file_path   = "/etc/vault.d/role_id"
      secret_id_file_path = "/etc/vault.d/secret_id"
      remove_secret_id_file_after_reading = ${REMOVE_SECRET_ID_AFTER_READING}
    }
  }

  sink "file" {
    config = {
      path = "/run/vault-agent/agent-token"
      mode = 0600
    }
  }
}

cache {
  use_auto_auth_token = true
}

listener "tcp" {
  address = "${AGENT_LISTEN_ADDR}"
  tls_disable = true
}
HCL

sudo chown vault:vault /etc/vault.d/agent.hcl
sudo chmod 640 /etc/vault.d/agent.hcl

# systemd unit
VAULT_BIN="$(command -v vault)"
sudo tee /etc/systemd/system/vault-agent.service >/dev/null <<UNIT
[Unit]
Description=HashiCorp Vault Agent (AppRole Auto-Auth)
After=network-online.target
Wants=network-online.target

[Service]
User=vault
Group=vault
ExecStart=${VAULT_BIN} agent -config=/etc/vault.d/agent.hcl
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=2
LimitNOFILE=65536
AmbientCapabilities=CAP_IPC_LOCK
CapabilityBoundingSet=CAP_IPC_LOCK
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/run/vault-agent /var/lib/vault-agent /etc/vault.d

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now vault-agent
sudo systemctl --no-pager --full status vault-agent || true

echo "OK. Agent token sink: /run/vault-agent/agent-token ; listener: http://${AGENT_LISTEN_ADDR}"
echo "NOTE: remove_secret_id_file_after_reading=${REMOVE_SECRET_ID_AFTER_READING} (secret_id may be deleted after first read)."
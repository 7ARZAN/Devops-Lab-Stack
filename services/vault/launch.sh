#!/bin/sh
set -e

log(){
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [vault-launcher] $1"
}

SECRETS_FILE="/run/secrets/vault-credentials"
PRELOAD_SCRIPT="/vault/bootstrap.sh"

if [ ! -f "$SECRETS_FILE" ]; then
    log "❌ Error: vault-credentials secret not found at $SECRETS_FILE"
    exit 1
fi

VAULT_TOKEN_ID=$(grep -E '^VAULT_TOKEN_ID=' "$SECRETS_FILE" | cut -d '=' -f2- | xargs)

if [ -z "$VAULT_TOKEN_ID" ]; then
    log "❌ Error: VAULT_TOKEN_ID not set in $SECRETS_FILE"
    exit 1
fi

chmod 400 "$SECRETS_FILE"

log "🔐 Starting Vault in dev mode with static root token..."

vault server -dev \
    -dev-root-token-id="$VAULT_TOKEN_ID" \
    -dev-listen-address=0.0.0.0:8200 &

VAULT_PID=$!

log "⏳ Waiting for Vault to be accessible..."
sleep 3

export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="$VAULT_TOKEN_ID"

log "🔑 Logging in to Vault..."
vault login "$VAULT_TOKEN_ID" > /dev/null

if [ -f "$PRELOAD_SCRIPT" ]; then
    log "📦 Found preload script. Running $PRELOAD_SCRIPT..."
    sh "$PRELOAD_SCRIPT"
else
    log "⚠️ No preload script found. Skipping secret bootstrap."
fi

log "✅ Vault is running and ready to accept requests."

wait "$VAULT_PID"

#!/bin/sh
set -e

LOG_FILE="/vault/logs/bootstrap.log"
mkdir -p /vault/logs
touch "$LOG_FILE"

log() {
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [vault-bootstrap] $1" | tee -a "$LOG_FILE"
}

check_directory_writable() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        log "❌ Error: Directory $dir does not exist"
        exit 1
    fi
    if ! touch "$dir/.test" 2>/dev/null; then
        log "❌ Error: Directory $dir is not writable"
        exit 1
    fi
    rm -f "$dir/.test"
    log "✅ Directory $dir is writable"
}

vault_retry() {
    local cmd="$1"
    local retries=3
    local delay=5
    local attempt=1
    while [ $attempt -le $retries ]; do
        log "Attempt $attempt of $retries: $cmd"
        if eval "$cmd"; then
            return 0
        fi
        log "⚠️ Command failed, retrying in $delay seconds..."
        sleep $delay
        attempt=$((attempt + 1))
    done
    log "❌ Error: Command failed after $retries attempts: $cmd"
    exit 1
}

log "📜 Reading secrets from files..."

DB_FILE="/run/secrets/database-credentials"
if [ ! -f "$DB_FILE" ]; then
    log "❌ Error: Database credentials file not found at $DB_FILE"
    exit 1
fi
if [ ! -r "$DB_FILE" ]; then
    log "❌ Error: Database credentials file at $DB_FILE is not readable"
    exit 1
fi
log "🔍 Parsing database credentials..."
PG_NAME=$(grep -E '^PG_NAME=' "$DB_FILE" | cut -d '=' -f2- | xargs)
PG_USER=$(grep -E '^PG_USER=' "$DB_FILE" | cut -d '=' -f2- | xargs)
PG_PASSWD=$(grep -E '^PG_PASSWD=' "$DB_FILE" | cut -d '=' -f2- | xargs)
PG_HOST=$(grep -E '^PG_HOST=' "$DB_FILE" | cut -d '=' -f2- | xargs)
PG_PORT=$(grep -E '^PG_PORT=' "$DB_FILE" | cut -d '=' -f2- | xargs)
[ -z "$PG_NAME" ] && { log "❌ Error: PG_NAME not set"; exit 1; }
[ -z "$PG_USER" ] && { log "❌ Error: PG_USER not set"; exit 1; }
[ -z "$PG_PASSWD" ] && { log "❌ Error: PG_PASSWD not set"; exit 1; }
[ -z "$PG_HOST" ] && { log "❌ Error: PG_HOST not set"; exit 1; }
[ -z "$PG_PORT" ] && { log "❌ Error: PG_PORT not set"; exit 1; }
log "✅ Database credentials parsed successfully"

export VAULT_ADDR="http://127.0.0.1:8200"
if [ -z "$VAULT_TOKEN" ]; then
    log "❌ Error: VAULT_TOKEN not set"
    exit 1
fi
log "✅ VAULT_TOKEN is set"

log "⏳ Checking Vault status..."
vault_retry "vault status > /dev/null 2>&1"
log "✅ Vault is ready"

log "🔧 Enabling KV secrets engine..."
vault_retry "vault secrets enable -path=secret kv-v2 || log '⚠️ KV secrets engine already enabled'"
log "✅ KV secrets engine enabled"

log "📦 Storing secrets in Vault..."
vault_retry "vault kv put secret/database \
    PG_NAME='$PG_NAME' \
    PG_USER='$PG_USER' \
    PG_PASSWD='$PG_PASSWD' \
    PG_HOST='$PG_HOST' \
    PG_PORT='$PG_PORT'" || { log "❌ Failed to store database secrets"; exit 1; }
log "✅ Database secrets stored"

vault_retry "vault kv put secret/project-config \
    SCHEMA_DIR='/etc/postgres/schemas' \
    TABLE_SCHEMA_FILE='/etc/postgres/table-schema.sql'" || { log "❌ Failed to store schema metadata"; exit 1; }
log "✅ Schema metadata stored"

log "🔐 Creating Vault policies..."
cat <<EOF > /tmp/database-policy.hcl
path "secret/data/database" {
  capabilities = ["read"]
}
path "secret/data/project-config" {
  capabilities = ["read"]
}
EOF
vault_retry "vault policy write database-policy /tmp/database-policy.hcl" || { log "❌ Failed to write database policy"; exit 1; }
log "✅ Database policy created"

log "🔑 Generating service tokens..."
DATABASE_TOKEN=$(vault_retry "vault token create -policy=database-policy -period=24h -format=json" | jq -r .auth.client_token || { log "❌ Failed to create database token"; exit 1; })
log "✅ Database token created"

log "📝 Writing tokens to files..."
check_directory_writable "/vault/tokens"
mkdir -p /vault/tokens
echo "VAULT_TOKEN=$DATABASE_TOKEN" > /vault/tokens/database-token.env || { log "❌ Failed to write database token"; exit 1; }
log "✅ Tokens written successfully"

log "✅ Vault bootstrap completed successfully"

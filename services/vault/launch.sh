#!/bin/sh
set -e

SECRETS_FILE="/run/secrets/vault-credentials"
if [ ! -f "$SECRETS_FILE" ]; then
    echo "Error: vault-credentials secret not found at $SECRETS_FILE"
    exit 1
fi

VAULT_DEV_ROOT_TOKEN_ID=$(grep -E '^VAULT_DEV_ROOT_TOKEN_ID=' "$SECRETS_FILE" | cut -d '=' -f 2-)
if [ -z "$VAULT_DEV_ROOT_TOKEN_ID" ]; then
    echo "Error: VAULT_DEV_ROOT_TOKEN_ID not found in $SECRETS_FILE"
    exit 1
fi

chmod 400 "$SECRETS_FILE"

exec vault server -dev \
    -dev-root-token-id="$VAULT_DEV_ROOT_TOKEN_ID" \
    -dev-listen-address=0.0.0.0:8200

#!/bin/sh

set -eo pipefail

VAULT_ADDR="http://127.0.0.1:8200"
TOKEN_FILE="/vault/tokens/database-token.env"

PG_BIN="/usr/bin"
DATA_DIR="/var/lib/postgresql/data"
SOCKET_DIR="/run/postgresql"
LOG_FILE="${DATA_DIR}/logfile"

log(){
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] [postgres-setup] $1" >&2
}

fetch_vault_credentials(){
    if [ ! -f "$TOKEN_FILE" ]; then
        log "[ERROR] Vault token file not found at $TOKEN_FILE"
        exit 1
    fi

    . "$TOKEN_FILE"
    if [ -z "$VAULT_TOKEN" ]; then
        log "[ERROR] VAULT_TOKEN not set in $TOKEN_FILE"
        exit 1
    fi
    export VAULT_TOKEN

    log "Fetching database credentials from Vault..."
    VAULT_RESPONSE=$(vault kv get -format=json secret/database 2>/dev/null) || {
        log "[ERROR] Failed to fetch credentials from Vault"
        exit 1
    }

    PG_NAME=$(echo "$VAULT_RESPONSE" | jq -r '.data.data.PG_NAME')
    PG_USER=$(echo "$VAULT_RESPONSE" | jq -r '.data.data.PG_USER')
    PG_PASSWD=$(echo "$VAULT_RESPONSE" | jq -r '.data.data.PG_PASSWD')
    PG_HOST=$(echo "$VAULT_RESPONSE" | jq -r '.data.data.PG_HOST')
    PG_PORT=$(echo "$VAULT_RESPONSE" | jq -r '.data.data.PG_PORT')

    : "${PG_NAME:?PG_NAME must be set}"
    : "${PG_USER:?PG_USER must be set}"
    : "${PG_PASSWD:?PG_PASSWD must be set}"
    : "${PG_HOST:?PG_HOST must be set}"
    : "${PG_PORT:?PG_PORT must be set}"

    export PG_NAME PG_USER PG_PASSWD PG_HOST PG_PORT
}

fetch_vault_metadata(){
    log "Fetching project metadata from Vault..."
    VAULT_METADATA=$(vault kv get -format=json secret/project-config 2>/dev/null) || {
        log "[WARN] Failed to fetch project metadata from Vault. Using defaults."
        TABLE_SCHEMA_FILE="/etc/postgres/table-schema.sql"
        SCHEMA_DIR="/etc/postgres/schemas"
        export TABLE_SCHEMA_FILE SCHEMA_DIR
        return 0
    }

    SCHEMA_DIR=$(echo "$VAULT_METADATA" | jq -r '.data.data.SCHEMA_DIR // "/etc/postgres/schemas"')
    TABLE_SCHEMA_FILE=$(echo "$VAULT_METADATA" | jq -r '.data.data.TABLE_SCHEMA_FILE // "/etc/postgres/table-schema.sql"')
    export SCHEMA_DIR TABLE_SCHEMA_FILE
}

initialize_db(){
    if [ -z "$(ls -A "${DATA_DIR}")" ]; then
        log "Initializing PostgreSQL database..."
        "${PG_BIN}/initdb" -U postgres -D "${DATA_DIR}" --locale=C.UTF-8 || {
            log "[ERROR] Failed to initialize database"
            exit 1
        }
    fi
}

start_postgres(){
    log "Starting PostgreSQL..."
    if ! "${PG_BIN}/pg_ctl" -D "${DATA_DIR}" -l "${LOG_FILE}" -o "-k ${SOCKET_DIR}" start; then
        log "[ERROR] Failed to start PostgreSQL. Reinitializing..."
        rm -rf "${DATA_DIR}"/*
        initialize_db
        "${PG_BIN}/pg_ctl" -D "${DATA_DIR}" -l "${LOG_FILE}" -o "-k ${SOCKET_DIR}" start || {
            log "[ERROR] Failed to start PostgreSQL after reinitialization"
            exit 1
        }
    fi
}

wait_for_postgres(){
    local retries=30
    while [ $retries -gt 0 ]; do
        if "${PG_BIN}/pg_isready" -h "${SOCKET_DIR}" > /dev/null 2>&1; then
            log "PostgreSQL is ready"
            return 0
        fi
        log "Waiting for PostgreSQL to be ready..."
        sleep 1
        retries=$((retries - 1))
    done
    log "[ERROR] PostgreSQL failed to become ready"
    exit 1
}

configure_db(){
    log "Configuring database..."
    if ! psql -h "${SOCKET_DIR}" -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${PG_NAME}'" | grep -q 1; then
        log "Creating database '${PG_NAME}' and user '${PG_USER}'..."
        psql -h "${SOCKET_DIR}" -U postgres -v ON_ERROR_STOP=1 <<-EOSQL
            BEGIN;
            CREATE DATABASE "${PG_NAME}";
            CREATE USER "${PG_USER}" WITH ENCRYPTED PASSWORD '${PG_PASSWD}';
            ALTER USER "${PG_USER}" WITH SUPERUSER CREATEDB CREATEROLE REPLICATION BYPASSRLS INHERIT LOGIN;
            ALTER ROLE "${PG_USER}" SET client_encoding = 'utf8';
            ALTER ROLE "${PG_USER}" SET default_transaction_isolation = 'read committed';
            ALTER ROLE "${PG_USER}" SET timezone = 'UTC';
            GRANT ALL PRIVILEGES ON DATABASE "${PG_NAME}" TO "${PG_USER}";
            \c "${PG_NAME}"
            GRANT ALL ON SCHEMA public TO "${PG_USER}";
            COMMIT;
EOSQL
    else
        log "Database '${PG_NAME}' already exists. Skipping creation."
    fi
}

create_tables(){
    log "Applying table schemas..."
    if [ -d "${SCHEMA_DIR}" ] && [ -n "$(ls -A "${SCHEMA_DIR}"/*.sql 2>/dev/null)" ]; then
        log "Processing schema files from ${SCHEMA_DIR}..."
        for schema_file in "${SCHEMA_DIR}"/*.sql; do
            log "Applying ${schema_file}..."
            sed "s/\${PG_USER}/${PG_USER}/g; s/\${PG_NAME}/${PG_NAME}/g" "${schema_file}" | psql -h "${SOCKET_DIR}" -U postgres -d "${PG_NAME}" -v ON_ERROR_STOP=1 || {
                log "[ERROR] Failed to apply schema ${schema_file}"
                return 1
            }
        done
    elif [ -f "${TABLE_SCHEMA_FILE}" ]; then
        log "Applying single schema from ${TABLE_SCHEMA_FILE}..."
        sed "s/\${PG_USER}/${PG_USER}/g; s/\${PG_NAME}/${PG_NAME}/g" "${TABLE_SCHEMA_FILE}" | psql -h "${SOCKET_DIR}" -U postgres -d "${PG_NAME}" -v ON_ERROR_STOP=1 || {
            log "[ERROR] Failed to apply schema ${TABLE_SCHEMA_FILE}"
            return 1
        }
    else
        log "[WARN] No table schema files found at ${SCHEMA_DIR} or ${TABLE_SCHEMA_FILE}. Skipping table creation."
    fi
}

configure_external_access(){
    log "Configuring PostgreSQL for external access..."
    {
        echo "listen_addresses = '*'"
        echo "max_connections = 100"
        echo "shared_buffers = 128MB"
        echo "log_min_messages = warning"
    } >> "${DATA_DIR}/postgresql.conf"
    echo "host all all 0.0.0.0/0 scram-sha-256" >> "${DATA_DIR}/pg_hba.conf"
}

shutdown(){
    log "Received SIGTERM. Stopping PostgreSQL..."
    "${PG_BIN}/pg_ctl" -D "${DATA_DIR}" -m fast stop
    exit 0
}

trap shutdown TERM INT

main(){
    fetch_vault_credentials
    fetch_vault_metadata
    initialize_db
    start_postgres
    wait_for_postgres
    configure_db
    create_tables
    configure_external_access
    log "Starting PostgreSQL in foreground..."
    "${PG_BIN}/postgres" -D "${DATA_DIR}" -k "${SOCKET_DIR}" &
    wait $!
}

main

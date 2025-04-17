#!/bin/sh

set -eo pipefail

if [ -f /run/secrets/database-credentials ]; then
    . /run/secrets/database-credentials
else
    echo "[ERROR] Database credentials file not found at /run/secrets/database-credentials" >&2
    exit 1
fi

: "${PG_NAME:?PG_NAME must be set}"
: "${PG_USER:?PG_USER must be set}"
: "${PG_PASSWD:?PG_PASSWD must be set}"
: "${TABLE_SCHEMA_FILE:=/etc/postgres/table-schema.sql}"

PG_BIN="/usr/bin"
DATA_DIR="/var/lib/postgresql/data"
SOCKET_DIR="/run/postgresql"
LOG_FILE="${DATA_DIR}/logfile"

log() {
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

initialize_db() {
    if [ -z "$(ls -A "${DATA_DIR}")" ]; then
        log "Initializing PostgreSQL database..."
        "${PG_BIN}/initdb" -U postgres -D "${DATA_DIR}" --locale=C.UTF-8 || {
            log "Failed to initialize database"
            exit 1
        }
    fi
}

start_postgres() {
    log "Starting PostgreSQL..."
    if ! "${PG_BIN}/pg_ctl" -D "${DATA_DIR}" -l "${LOG_FILE}" -o "-k ${SOCKET_DIR}" start; then
        log "Failed to start PostgreSQL. Reinitializing..."
        rm -rf "${DATA_DIR}"/*
        initialize_db
        "${PG_BIN}/pg_ctl" -D "${DATA_DIR}" -l "${LOG_FILE}" -o "-k ${SOCKET_DIR}" start || {
            log "Failed to start PostgreSQL after reinitialization"
            exit 1
        }
    fi
}

wait_for_postgres() {
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
    log "PostgreSQL failed to become ready"
    exit 1
}

configure_db() {
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

create_tables() {
    if [ -f "${TABLE_SCHEMA_FILE}" ]; then
        log "Applying table schema from ${TABLE_SCHEMA_FILE}..."
        psql -h "${SOCKET_DIR}" -U postgres -d "${PG_NAME}" -v ON_ERROR_STOP=1 -f "${TABLE_SCHEMA_FILE}" || {
            log "Failed to apply table schema"
            return 1
        }
    else
        log "No table schema file found at ${TABLE_SCHEMA_FILE}. Skipping table creation."
    fi
}

configure_external_access() {
    log "Configuring PostgreSQL for external access..."
    {
        echo "listen_addresses = '*'"
        echo "max_connections = 100"
        echo "shared_buffers = 128MB"
        echo "log_min_messages = warning"
    } >> "${DATA_DIR}/postgresql.conf"
    echo "host all all 0.0.0.0/0 scram-sha-256" >> "${DATA_DIR}/pg_hba.conf"
}

shutdown() {
    log "Received SIGTERM. Stopping PostgreSQL..."
    "${PG_BIN}/pg_ctl" -D "${DATA_DIR}" -m fast stop
    exit 0
}

trap shutdown TERM INT

main() {
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

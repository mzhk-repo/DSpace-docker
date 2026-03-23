#!/usr/bin/env bash

sync_db_role_password() {
    local rotation_enabled fail_on_error db_container
    local target_user target_password admin_user admin_password

    rotation_enabled="${DB_PASSWORD_ROTATION_ENABLED:-true}"
    fail_on_error="${DB_PASSWORD_ROTATION_FAIL_ON_ERROR:-true}"
    db_container="${DB_CONTAINER_NAME:-dspacedb}"

    if [ "$rotation_enabled" != "true" ]; then
        echo "⏭ DB password rotation disabled (DB_PASSWORD_ROTATION_ENABLED=false)."
        return 0
    fi

    if [ "${DRY_RUN:-false}" = "true" ]; then
        echo "[dry-run] DB role password sync enabled for container '${db_container}'."
        return 0
    fi

    if ! command -v docker >/dev/null 2>&1; then
        echo "⏭ Docker is not installed. Skipping DB role password sync."
        return 0
    fi

    if ! docker inspect "$db_container" >/dev/null 2>&1; then
        echo "⏭ DB container '$db_container' not found. Skipping DB role password sync."
        return 0
    fi

    if [ "$(docker inspect -f '{{.State.Running}}' "$db_container" 2>/dev/null)" != "true" ]; then
        echo "⏭ DB container '$db_container' is not running. Skipping DB role password sync."
        return 0
    fi

    target_user="${POSTGRES_USER:-dspace}"
    target_password="${POSTGRES_PASSWORD:-dspace}"

    admin_user="$(docker inspect "$db_container" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^POSTGRES_USER=//p' | head -n1)"
    admin_password="$(docker inspect "$db_container" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^POSTGRES_PASSWORD=//p' | head -n1)"

    if [ -z "$admin_user" ] || [ -z "$admin_password" ]; then
        if [ "$fail_on_error" = "true" ]; then
            echo "❌ Could not read DB admin credentials from container '$db_container'." >&2
            return 1
        fi
        echo "⚠️ Could not read DB admin credentials from container '$db_container'. Skipping sync."
        return 0
    fi

    echo "🔐 Syncing PostgreSQL role password for '$target_user'..."
    if ! docker exec -i "$db_container" bash -s -- "$admin_user" "$admin_password" "$target_user" "$target_password" <<'EOSQL'
set -euo pipefail

admin_user="$1"
admin_password="$2"
target_user="$3"
target_password="$4"

PGPASSWORD="$admin_password" psql -h 127.0.0.1 -U "$admin_user" -d postgres -v ON_ERROR_STOP=1 \
  -v target_user="$target_user" \
  -v target_password="$target_password" \
  -At <<'PSQL' \
  | PGPASSWORD="$admin_password" psql -h 127.0.0.1 -U "$admin_user" -d postgres -v ON_ERROR_STOP=1
SELECT format('ALTER ROLE %I WITH PASSWORD %L', :'target_user', :'target_password');
PSQL
EOSQL
    then
        if [ "$fail_on_error" = "true" ]; then
            echo "❌ Failed to sync DB role password for '$target_user'." >&2
            return 1
        fi
        echo "⚠️ Failed to sync DB role password for '$target_user'. Continuing."
        return 0
    fi

    echo "✅ DB role password synced for '$target_user'."
    return 0
}

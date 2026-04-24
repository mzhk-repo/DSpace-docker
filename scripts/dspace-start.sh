#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[dspace-start] %s\n' "$*"
}

# If db__P__password is not provided directly, use POSTGRES_PASSWORD.
if [ -z "${db__P__password:-}" ] && [ -n "${POSTGRES_PASSWORD:-}" ]; then
  export db__P__password="${POSTGRES_PASSWORD}"
fi

if [ -z "${mail__P__server__P__password:-}" ] && [ -n "${DSPACE_MAIL_PASSWORD:-}" ]; then
  export mail__P__server__P__password="${DSPACE_MAIL_PASSWORD}"
fi

if [ -z "${authentication__D__oidc__P__client__D__secret:-}" ] && [ -n "${OIDC_CLIENT_SECRET:-}" ]; then
  export authentication__D__oidc__P__client__D__secret="${OIDC_CLIENT_SECRET}"
fi

if [ -z "${google__P__analytics__P__api__D__secret:-}" ] && [ -n "${DSPACE_GA_API_SECRET:-}" ]; then
  export google__P__analytics__P__api__D__secret="${DSPACE_GA_API_SECRET}"
fi

db_port="${POSTGRES_INTERNAL_PORT:-5432}"
db_host="${DSPACE_DB_HOST:-dspacedb}"
db_wait_timeout="${DSPACE_DB_WAIT_TIMEOUT:-180}"

log "Waiting for DB (${db_host}:${db_port}, timeout=${db_wait_timeout}s)..."
SECONDS=0
until : < /dev/tcp/"$db_host"/"$db_port" 2>/dev/null; do
  if [ "$SECONDS" -ge "$db_wait_timeout" ]; then
    log "ERROR: database did not become reachable in ${db_wait_timeout}s"
    exit 1
  fi
  sleep 1
done

if [ "${DSPACE_SKIP_DB_MIGRATIONS:-false}" = "true" ]; then
  log "Skipping DB migrations (DSPACE_SKIP_DB_MIGRATIONS=true)."
else
  log "Running DB migrations..."
  /dspace/bin/dspace database migrate
  log "DB migrations completed."
fi

log "Starting DSpace REST..."
# shellcheck disable=SC2086
exec java ${JAVA_OPTS:-} -jar /dspace/webapps/server-boot.jar --dspace.dir=/dspace

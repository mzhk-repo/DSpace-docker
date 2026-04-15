#!/usr/bin/env bash
set -euo pipefail

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

echo "Waiting for DB..."
until (</dev/tcp/dspacedb/$db_port) >/dev/null 2>&1; do
  sleep 1
done

echo "Running DB migrations..."
/dspace/bin/dspace database migrate

echo "Starting DSpace REST..."
exec java ${JAVA_OPTS:-} -jar /dspace/webapps/server-boot.jar --dspace.dir=/dspace

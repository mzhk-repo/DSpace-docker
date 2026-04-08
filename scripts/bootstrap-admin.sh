#!/usr/bin/env bash
# Скрипт для створення адміністратора в DSpace 7+ через CLI
# Використовує змінні з .env для налаштування даних адміністратора

set -euo pipefail

# --- helpers ---
info() { echo "==> $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTO_RESTART="true"

usage() {
  cat <<EOF
Usage: ./scripts/bootstrap-admin.sh [options]

Options:
  --no-restart         Do not restart backend container after admin creation
  -h, --help           Show this help
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-restart)
        AUTO_RESTART="false"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown option: $1"
        ;;
    esac
  done
}

load_env_file() {
  local env_file="$1"
  [[ -f "$env_file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    line="$(echo "$line" | sed -E 's/^[[:space:]]*export[[:space:]]+//')"
    [[ "$line" == *"="* ]] || continue

    local key="${line%%=*}"
    local value="${line#*=}"

    key="$(echo "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

    value="$(echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [[ "$value" =~ ^\".*\"$ ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "$value" =~ ^'.*'$ ]]; then
      value="${value:1:${#value}-2}"
    fi

    printf -v "$key" '%s' "$value"
    export "${key?}"
  done < "$env_file"
}

restart_backend_container() {
  local service_name="dspace"
  local container_name="${DSPACE_CONTAINER_NAME:-dspace}"
  local compose_file="${ROOT_DIR}/docker-compose.yml"

  if [ "$AUTO_RESTART" != "true" ]; then
    info "Skipping backend restart (--no-restart)."
    return 0
  fi

  if [ -f "$compose_file" ] && docker compose version >/dev/null 2>&1; then
    if docker compose -f "$compose_file" restart "$service_name"; then
      info "Backend restarted via docker compose: ${service_name}"
      return 0
    fi
    info "docker compose restart failed, trying docker restart ${container_name}..."
  fi

  if docker inspect "$container_name" >/dev/null 2>&1; then
    docker restart "$container_name" >/dev/null
    info "Backend restarted via docker: ${container_name}"
    return 0
  fi

  fail "Could not find backend container/service to restart (${container_name}/${service_name})"
}

parse_args "$@"
load_env_file "${ROOT_DIR}/.env"

: "${DSPACE_CONTAINER_NAME:=dspace}"
: "${DSPACE_BOOTSTRAP_ADMIN_EMAIL:?Set DSPACE_BOOTSTRAP_ADMIN_EMAIL in .env}"
: "${DSPACE_BOOTSTRAP_ADMIN_FIRSTNAME:?Set DSPACE_BOOTSTRAP_ADMIN_FIRSTNAME in .env}"
: "${DSPACE_BOOTSTRAP_ADMIN_LASTNAME:?Set DSPACE_BOOTSTRAP_ADMIN_LASTNAME in .env}"
: "${DSPACE_BOOTSTRAP_ADMIN_PASSWORD:?Set DSPACE_BOOTSTRAP_ADMIN_PASSWORD in .env}"
: "${DSPACE_BOOTSTRAP_ADMIN_LOCALE:=en}"

EMAIL="${DSPACE_BOOTSTRAP_ADMIN_EMAIL}"
FNAME="${DSPACE_BOOTSTRAP_ADMIN_FIRSTNAME}"
LNAME="${DSPACE_BOOTSTRAP_ADMIN_LASTNAME}"
PASS="${DSPACE_BOOTSTRAP_ADMIN_PASSWORD}"
LOCALE="${DSPACE_BOOTSTRAP_ADMIN_LOCALE}"

info "Checking DSpace backend container exists & is running: ${DSPACE_CONTAINER_NAME}"
docker inspect "${DSPACE_CONTAINER_NAME}" >/dev/null 2>&1 || fail "Container '${DSPACE_CONTAINER_NAME}' not found"
RUNNING="$(docker inspect -f '{{.State.Running}}' "${DSPACE_CONTAINER_NAME}")"
[[ "${RUNNING}" == "true" ]] || fail "Container '${DSPACE_CONTAINER_NAME}' is not running"

info "Checking DSpace CLI is available in container..."
docker exec "${DSPACE_CONTAINER_NAME}" bash -lc "test -x /dspace/bin/dspace" \
  || fail "/dspace/bin/dspace not found or not executable"

info "Checking whether admin user already exists: ${EMAIL}"
if docker exec "${DSPACE_CONTAINER_NAME}" bash -lc "/dspace/bin/dspace user -L 2>/dev/null | grep -Fq '${EMAIL}'"; then
  info "Admin already exists. Nothing to do."
  exit 0
fi

info "Admin not found. Creating administrator: ${EMAIL}"

# Non-interactive create-admin (works even without a TTY)
docker exec "${DSPACE_CONTAINER_NAME}" bash -lc \
  "/dspace/bin/dspace create-administrator \
    -e '${EMAIL}' \
    -f '${FNAME}' \
    -l '${LNAME}' \
    -p '${PASS}' \
    -c '${LOCALE}'"

restart_backend_container

info "Done. Try login in"

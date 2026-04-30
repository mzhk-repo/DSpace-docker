#!/usr/bin/env bash
# Скрипт для створення адміністратора в DSpace 7+ через CLI

set -euo pipefail

# --- helpers ---
info() { echo "==> $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTO_RESTART="false"
STACK_NAME="${STACK_NAME:-dspace}"
ENV_FILE="${ORCHESTRATOR_ENV_FILE:-}"

usage() {
  cat <<EOF
Usage: ./scripts/bootstrap-admin.sh [options]

Options:
  --restart            Restart backend container after admin creation (local compose only)
  --no-restart         Do not restart backend container after admin creation
  -h, --help           Show this help
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --restart)
        AUTO_RESTART="true"
        shift
        ;;
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
  [[ -f "$env_file" ]] || fail "env file not found: $env_file"

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

resolve_env_file() {
  if [[ -n "${ORCHESTRATOR_ENV_FILE:-}" ]]; then
    [[ -f "${ORCHESTRATOR_ENV_FILE}" ]] || fail "ORCHESTRATOR_ENV_FILE not found: ${ORCHESTRATOR_ENV_FILE}"
    printf '%s' "${ORCHESTRATOR_ENV_FILE}"
    return 0
  fi

  if [[ -f "${ROOT_DIR}/.env" ]]; then
    info "WARNING: ORCHESTRATOR_ENV_FILE не передано. Fallback на локальний .env — тільки для dev." >&2
    printf '%s' "${ROOT_DIR}/.env"
    return 0
  fi

  fail "env file not found. Set ORCHESTRATOR_ENV_FILE or provide local .env for dev."
}

find_backend_container() {
  local container_name="${DSPACE_CONTAINER_NAME:-dspace}"
  local service_name="${DSPACE_SERVICE_NAME:-dspace}"
  local swarm_service_name="${STACK_NAME}_${service_name}"
  local container_id

  if docker inspect "${container_name}" >/dev/null 2>&1; then
    if [[ "$(docker inspect -f '{{.State.Running}}' "${container_name}")" == "true" ]]; then
      printf '%s' "${container_name}"
      return 0
    fi
  fi

  container_id="$(docker ps -q \
    --filter "label=com.docker.swarm.service.name=${swarm_service_name}" \
    --filter "status=running" \
    | head -n 1)"

  if [[ -n "${container_id}" ]]; then
    printf '%s' "${container_id}"
    return 0
  fi

  return 1
}

wait_for_backend_container() {
  local attempts="${DSPACE_BOOTSTRAP_WAIT_ATTEMPTS:-40}"
  local sleep_s="${DSPACE_BOOTSTRAP_WAIT_SLEEP:-5}"
  local container_ref=""
  local i

  for ((i=1; i<=attempts; i++)); do
    if container_ref="$(find_backend_container)"; then
      printf '%s' "${container_ref}"
      return 0
    fi
    info "Waiting for DSpace backend container (${i}/${attempts})..." >&2
    sleep "${sleep_s}"
  done

  return 1
}

wait_for_dspace_cli_ready() {
  local attempts="${DSPACE_BOOTSTRAP_CLI_WAIT_ATTEMPTS:-40}"
  local sleep_s="${DSPACE_BOOTSTRAP_CLI_WAIT_SLEEP:-5}"
  local container_ref=""
  local i

  for ((i=1; i<=attempts; i++)); do
    if container_ref="$(find_backend_container)"; then
      if docker exec "${container_ref}" bash -lc "/dspace/bin/dspace user -L >/dev/null 2>&1" >/dev/null 2>&1; then
        printf '%s' "${container_ref}"
        return 0
      fi
    fi
    info "Waiting for DSpace CLI/database readiness (${i}/${attempts})..." >&2
    sleep "${sleep_s}"
  done

  return 1
}

shell_quote() {
  printf "%q" "$1"
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

mark_admin_created() {
  if [[ -n "${DSPACE_ADMIN_CREATED_FLAG_FILE:-}" ]]; then
    mkdir -p "$(dirname "${DSPACE_ADMIN_CREATED_FLAG_FILE}")"
    printf 'bootstrap-admin.sh\n' >> "${DSPACE_ADMIN_CREATED_FLAG_FILE}"
  fi
}

parse_args "$@"
ENV_FILE="$(resolve_env_file)"
load_env_file "${ENV_FILE}"

: "${DSPACE_CONTAINER_NAME:=dspace}"
: "${DSPACE_SERVICE_NAME:=dspace}"
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

info "Checking DSpace backend container exists & is running"
BACKEND_CONTAINER="$(wait_for_backend_container)" \
  || fail "Running backend container not found (local=${DSPACE_CONTAINER_NAME}, swarm=${STACK_NAME}_${DSPACE_SERVICE_NAME})"
info "Using backend container: ${BACKEND_CONTAINER}"

info "Checking DSpace CLI is available in container..."
docker exec "${BACKEND_CONTAINER}" bash -lc "test -x /dspace/bin/dspace" \
  || fail "/dspace/bin/dspace not found or not executable"

info "Waiting until DSpace CLI can read users..."
BACKEND_CONTAINER="$(wait_for_dspace_cli_ready)" \
  || fail "DSpace CLI did not become ready in time"
info "Using CLI-ready backend container: ${BACKEND_CONTAINER}"

info "Checking whether admin user already exists: ${EMAIL}"
if docker exec "${BACKEND_CONTAINER}" bash -lc "/dspace/bin/dspace user -L 2>/dev/null | grep -Fq -- $(shell_quote "${EMAIL}")"; then
  info "Admin already exists. Nothing to do."
  exit 0
fi

info "Admin not found. Creating administrator: ${EMAIL}"

# Non-interactive create-admin (works even without a TTY)
docker exec "${BACKEND_CONTAINER}" bash -lc \
  "/dspace/bin/dspace create-administrator \
    -e $(shell_quote "${EMAIL}") \
    -f $(shell_quote "${FNAME}") \
    -l $(shell_quote "${LNAME}") \
    -p $(shell_quote "${PASS}") \
    -c $(shell_quote "${LOCALE}")"

mark_admin_created
restart_backend_container

info "Done."

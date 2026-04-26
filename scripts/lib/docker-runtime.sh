#!/usr/bin/env bash
# Runtime adapter для автономних DSpace-скриптів: Swarm за замовчуванням, Compose fallback для dev.

DOCKER_RUNTIME_MODE="${DOCKER_RUNTIME_MODE:-swarm}"
STACK_NAME="${STACK_NAME:-dspace}"

docker_runtime_die() {
  printf '[docker-runtime] ERROR: %s\n' "$*" >&2
  exit 1
}

docker_runtime_container_id() {
  local service="$1"
  local service_name="${STACK_NAME}_${service}"

  docker ps -q \
    --filter "label=com.docker.swarm.service.name=${service_name}" \
    --filter "status=running" \
    | head -n 1
}

docker_runtime_service_accessible() {
  local service="$1"

  case "${DOCKER_RUNTIME_MODE}" in
    compose)
      docker compose -f "${PROJECT_ROOT}/docker-compose.yml" ps "${service}" >/dev/null 2>&1
      ;;
    swarm)
      [[ -n "$(docker_runtime_container_id "${service}")" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

docker_runtime_exec() {
  local service="$1"
  shift

  case "${DOCKER_RUNTIME_MODE}" in
    compose)
      docker compose -f "${PROJECT_ROOT}/docker-compose.yml" exec -T "${service}" "$@"
      ;;
    swarm)
      local cid
      cid="$(docker_runtime_container_id "${service}")"
      [[ -n "${cid}" ]] || docker_runtime_die "running Swarm container not found: ${STACK_NAME}_${service}"
      docker exec -i "${cid}" "$@"
      ;;
    *)
      docker_runtime_die "unsupported DOCKER_RUNTIME_MODE=${DOCKER_RUNTIME_MODE}"
      ;;
  esac
}

docker_runtime_logs() {
  local service="$1"
  shift || true

  case "${DOCKER_RUNTIME_MODE}" in
    compose)
      docker compose -f "${PROJECT_ROOT}/docker-compose.yml" logs "$@" "${service}"
      ;;
    swarm)
      docker service logs "$@" "${STACK_NAME}_${service}"
      ;;
    *)
      docker_runtime_die "unsupported DOCKER_RUNTIME_MODE=${DOCKER_RUNTIME_MODE}"
      ;;
  esac
}

docker_runtime_stack_stop() {
  case "${DOCKER_RUNTIME_MODE}" in
    compose)
      docker compose -f "${PROJECT_ROOT}/docker-compose.yml" down
      ;;
    swarm)
      docker stack rm "${STACK_NAME}"
      ;;
    *)
      docker_runtime_die "unsupported DOCKER_RUNTIME_MODE=${DOCKER_RUNTIME_MODE}"
      ;;
  esac
}

docker_runtime_service_scale() {
  local service="$1"
  local replicas="$2"

  case "${DOCKER_RUNTIME_MODE}" in
    compose)
      if [[ "${replicas}" == "0" ]]; then
        docker compose -f "${PROJECT_ROOT}/docker-compose.yml" stop "${service}"
      else
        docker compose -f "${PROJECT_ROOT}/docker-compose.yml" up -d "${service}"
      fi
      ;;
    swarm)
      docker service scale "${STACK_NAME}_${service}=${replicas}" >/dev/null
      ;;
    *)
      docker_runtime_die "unsupported DOCKER_RUNTIME_MODE=${DOCKER_RUNTIME_MODE}"
      ;;
  esac
}

docker_runtime_stack_start() {
  case "${DOCKER_RUNTIME_MODE}" in
    compose)
      docker compose -f "${PROJECT_ROOT}/docker-compose.yml" up -d "$@"
      ;;
    swarm)
      local service
      if [[ "$#" -gt 0 ]]; then
        for service in "$@"; do
          docker_runtime_service_scale "${service}" 1
        done
      else
        for service in dspacedb dspacesolr dspace dspace-angular; do
          docker_runtime_service_scale "${service}" 1
        done
      fi
      ;;
    *)
      docker_runtime_die "unsupported DOCKER_RUNTIME_MODE=${DOCKER_RUNTIME_MODE}"
      ;;
  esac
}

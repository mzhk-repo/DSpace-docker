#!/usr/bin/env bash
# init-volumes.sh
# Ініціалізує директорії томів для DSpace stack та виставляє безпечні права.
# Без sudo/password: усі привілейовані дії виконуються через ефемерні docker-контейнери.
#
# Використання:
#   ./scripts/init-volumes.sh
#   ./scripts/init-volumes.sh --fix-existing
#   ./scripts/init-volumes.sh --dry-run

set -euo pipefail

FIX_EXISTING=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fix-existing)
      FIX_EXISTING=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      echo "❌ Unknown option: $1" >&2
      echo "Usage: $0 [--fix-existing] [--dry-run]" >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ORCHESTRATOR_ENV_FILE:-}"
DOCKER_IMAGE="${INIT_VOLUMES_HELPER_IMAGE:-alpine:3.20}"

if [[ -n "${ORCHESTRATOR_ENV_FILE:-}" && ! -f "${ORCHESTRATOR_ENV_FILE}" ]]; then
  echo "[init-volumes] ERROR: ORCHESTRATOR_ENV_FILE не знайдено: ${ORCHESTRATOR_ENV_FILE}" >&2
  exit 1
fi

if [[ -z "$ENV_FILE" ]]; then
  if [[ ! -f "${PROJECT_ROOT}/.env" ]]; then
    echo "[init-volumes] ERROR: env file не знайдено. Передай ORCHESTRATOR_ENV_FILE або поклади .env для локального dev." >&2
    exit 1
  fi
  ENV_FILE="${PROJECT_ROOT}/.env"
  echo "[init-volumes] WARNING: ORCHESTRATOR_ENV_FILE не передано. Fallback на локальний .env — тільки для dev." >&2
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "❌ Error: docker is required for init-volumes (ephemeral container mode)." >&2
  exit 1
fi

load_env_file() {
  local env_file="$1"
  local line key value

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue

    line="$(printf '%s' "${line}" | sed -E 's/^[[:space:]]*export[[:space:]]+//')"
    [[ "${line}" == *"="* ]] || continue

    key="${line%%=*}"
    value="${line#*=}"

    key="$(printf '%s' "${key}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

    value="$(printf '%s' "${value}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [[ "${value}" =~ ^\".*\"$ ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "${value}" =~ ^\'.*\'$ ]]; then
      value="${value:1:${#value}-2}"
    fi

    printf -v "${key}" '%s' "${value}"
    export "${key?}"
  done < "${env_file}"
}

require_env_keys() {
  local missing=()
  local key

  for key in "$@"; do
    if [[ -z "${!key:-}" ]]; then
      missing+=("${key}")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    printf '[init-volumes] ERROR: missing required variable(s) in %s: %s\n' \
      "${ENV_FILE}" "${missing[*]}" >&2
    exit 1
  fi
}

echo "🌍 Loading environment variables from ${ENV_FILE}..."
load_env_file "${ENV_FILE}"

require_env_keys \
  VOL_POSTGRESQL_PATH \
  VOL_SOLR_PATH \
  VOL_ASSETSTORE_PATH \
  VOL_EXPORTS_PATH \
  VOL_LOGS_PATH \
  BACKUP_LOCAL_DIR

VOL_PG="$VOL_POSTGRESQL_PATH"
VOL_SOLR="$VOL_SOLR_PATH"
VOL_ASSET="$VOL_ASSETSTORE_PATH"
VOL_EXPORT="$VOL_EXPORTS_PATH"
VOL_LOGS="$VOL_LOGS_PATH"
VOL_BACKUP="$BACKUP_LOCAL_DIR"

POSTGRES_UID="${POSTGRES_UID:-999}"
POSTGRES_GID="${POSTGRES_GID:-999}"
SOLR_UID="${SOLR_UID:-8983}"
SOLR_GID="${SOLR_GID:-8983}"
DSPACE_UID="${DSPACE_UID:-1000}"
DSPACE_GID="${DSPACE_GID:-1000}"
BACKUP_UID="${BACKUP_UID:-$(id -u)}"
BACKUP_GID="${BACKUP_GID:-$(id -g)}"

guard_path() {
  local path="$1"
  if [[ "$path" == "/" || "$path" == "." || "$path" == ".." ]]; then
    echo "❌ Unsafe path: $path" >&2
    exit 1
  fi
}

run_cmd() {
  if $DRY_RUN; then
    printf '[dry-run] '
    printf '%q ' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

ensure_dir() {
  local dir_path="$1"
  local parent_dir base_name

  if $DRY_RUN; then
    echo "[dry-run] mkdir -p \"$dir_path\" (or via docker fallback)"
    return 0
  fi

  if mkdir -p "$dir_path" 2>/dev/null; then
    return 0
  fi

  parent_dir="$(dirname "$dir_path")"
  base_name="$(basename "$dir_path")"
  run_cmd docker run --rm -v "$parent_dir:/host" "$DOCKER_IMAGE" sh -c "mkdir -p \"/host/$base_name\""
}

run_on_volume() {
  local volume_path="$1"
  local script="$2"
  run_cmd docker run --rm -v "$volume_path:/target" "$DOCKER_IMAGE" sh -c "$script"
}

guard_path "$VOL_PG"
guard_path "$VOL_SOLR"
guard_path "$VOL_ASSET"
guard_path "$VOL_EXPORT"
guard_path "$VOL_LOGS"
guard_path "$VOL_BACKUP"

echo "==> Creating volume directories..."
for p in "$VOL_PG" "$VOL_SOLR" "$VOL_ASSET" "$VOL_EXPORT" "$VOL_LOGS" "$VOL_BACKUP"; do
  ensure_dir "$p"
done

echo "==> Setting ownership + baseline permissions via ephemeral containers..."
echo " -> PostgreSQL PGDATA (${POSTGRES_UID}:${POSTGRES_GID})"
run_on_volume "$VOL_PG" "chown -R ${POSTGRES_UID}:${POSTGRES_GID} /target && chmod 700 /target"

echo " -> Solr (${SOLR_UID}:${SOLR_GID})"
run_on_volume "$VOL_SOLR" "chown -R ${SOLR_UID}:${SOLR_GID} /target && chmod 775 /target"

echo " -> DSpace assets/exports/logs (${DSPACE_UID}:${DSPACE_GID})"
run_on_volume "$VOL_ASSET" "chown -R ${DSPACE_UID}:${DSPACE_GID} /target && chmod 775 /target"
run_on_volume "$VOL_EXPORT" "chown -R ${DSPACE_UID}:${DSPACE_GID} /target && chmod 775 /target"
run_on_volume "$VOL_LOGS" "chown -R ${DSPACE_UID}:${DSPACE_GID} /target && chmod 775 /target"

echo " -> Backup directory (${BACKUP_UID}:${BACKUP_GID})"
run_on_volume "$VOL_BACKUP" "chown -R ${BACKUP_UID}:${BACKUP_GID} /target && chmod 750 /target"

if $FIX_EXISTING; then
  echo "==> --fix-existing enabled: normalizing permissions inside volumes."

  echo " -> PostgreSQL PGDATA modes (dirs=700, files=600)"
  run_on_volume "$VOL_PG" "find /target -type d -exec chmod 700 {} + && find /target -type f -exec chmod 600 {} +"

  echo " -> Solr modes (dirs=775, files=664)"
  run_on_volume "$VOL_SOLR" "find /target -type d -exec chmod 775 {} + && find /target -type f -exec chmod 664 {} +"

  echo " -> DSpace modes (dirs=775, files=664)"
  run_on_volume "$VOL_ASSET" "find /target -type d -exec chmod 775 {} + && find /target -type f -exec chmod 664 {} +"
  run_on_volume "$VOL_EXPORT" "find /target -type d -exec chmod 775 {} + && find /target -type f -exec chmod 664 {} +"
  run_on_volume "$VOL_LOGS" "find /target -type d -exec chmod 775 {} + && find /target -type f -exec chmod 664 {} +"

  echo " -> Backup directory modes (dirs=750, files=640)"
  run_on_volume "$VOL_BACKUP" "find /target -type d -exec chmod 750 {} + && find /target -type f -exec chmod 640 {} +"
fi

echo "==> Done! Volumes are ready."
for p in "$VOL_PG" "$VOL_SOLR" "$VOL_ASSET" "$VOL_EXPORT" "$VOL_LOGS" "$VOL_BACKUP"; do
  ls -ld "$p" 2>/dev/null || echo "   $p"
done

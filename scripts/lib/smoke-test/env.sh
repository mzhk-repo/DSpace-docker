#!/usr/bin/env bash

ENV_TMP=""

cleanup_smoke_env() {
  if [[ -n "${ENV_TMP:-}" && -f "${ENV_TMP}" ]]; then
    if command -v shred >/dev/null 2>&1; then
      shred -u "${ENV_TMP}" 2>/dev/null || rm -f "${ENV_TMP}"
    else
      rm -f "${ENV_TMP}"
    fi
  fi
}

resolve_environment() {
  local raw="${1:-${ENVIRONMENT_NAME:-${SERVER_ENV:-}}}"
  case "${raw}" in
    dev|development) printf 'dev' ;;
    prod|production) printf 'prod' ;;
    "") fail "environment is not set. Pass --env dev|prod or set ENVIRONMENT_NAME/SERVER_ENV." ;;
    *) fail "unsupported environment: ${raw}. Expected dev|development|prod|production." ;;
  esac
}

decrypt_smoke_env() {
  local enc_file="$1"

  command -v sops >/dev/null 2>&1 || fail "sops is required to decrypt ${enc_file}"
  [[ -f "${enc_file}" ]] || fail "encrypted env file not found: ${enc_file}"

  cleanup_smoke_env
  ENV_TMP="$(mktemp /dev/shm/smoke-env-XXXXXX)"
  chmod 600 "${ENV_TMP}"
  sops --decrypt --input-type dotenv --output-type dotenv "${enc_file}" > "${ENV_TMP}"
  printf '%s' "${ENV_TMP}"
}

resolve_env_file() {
  local env_arg="$1"
  local env_name enc_file

  if [[ -n "${ORCHESTRATOR_ENV_FILE:-}" && -f "${ORCHESTRATOR_ENV_FILE}" ]]; then
    printf '%s' "${ORCHESTRATOR_ENV_FILE}"
    return 0
  fi

  env_name="$(resolve_environment "${env_arg}")"
  enc_file="${SCRIPT_DIR}/../env.${env_name}.enc"
  decrypt_smoke_env "${enc_file}"
}

load_env_file() {
  local env_file="$1"
  [[ -f "$env_file" ]] || { echo "❌ .env not found: $env_file" >&2; return 1; }

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

load_env_for_environment() {
  local env_arg="$1"
  local env_file

  env_file="$(resolve_env_file "${env_arg}")"
  log "Завантаження smoke-test env: ${env_file}"
  load_env_file "${env_file}"
}

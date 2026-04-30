#!/usr/bin/env bash
# Перевіряє, що потрібний env.*.enc розшифровується та містить ключі з .env.example.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
EXAMPLE_ENV="${PROJECT_ROOT}/.env.example"
ENVIRONMENT_ARG=""
VALIDATE_ALL="false"
ENV_TMP=""

log() { printf '[verify-env] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: ./scripts/verify-env.sh [--env dev|prod] [--all]

Options:
  --env ENV       Перевірити env.ENV.enc (dev/development або prod/production)
  --all           Перевірити env.dev.enc та env.prod.enc
  --ci-mock       Backward-compatible alias для --all
  -h, --help      Показати довідку
EOF
}

cleanup() {
  if [[ -n "${ENV_TMP}" && -f "${ENV_TMP}" ]]; then
    if command -v shred >/dev/null 2>&1; then
      shred -u "${ENV_TMP}" 2>/dev/null || rm -f "${ENV_TMP}"
    else
      rm -f "${ENV_TMP}"
    fi
  fi
}
trap cleanup EXIT

resolve_environment() {
  local raw="${1:-${ENVIRONMENT_NAME:-${SERVER_ENV:-}}}"
  case "${raw}" in
    dev|development) printf 'dev' ;;
    prod|production) printf 'prod' ;;
    "") die "environment is not set. Pass --env dev|prod or set ENVIRONMENT_NAME/SERVER_ENV." ;;
    *) die "unsupported environment: ${raw}. Expected dev|development|prod|production." ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env)
        [[ $# -ge 2 ]] || die "missing value for --env"
        ENVIRONMENT_ARG="$2"
        shift 2
        ;;
      --all|--ci-mock)
        VALIDATE_ALL="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done
}

extract_keys() {
  local env_file="$1"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    line="$(printf '%s' "${line}" | sed -E 's/^[[:space:]]*export[[:space:]]+//')"
    [[ "${line}" == *"="* ]] || continue

    local key="${line%%=*}"
    key="$(printf '%s' "${key}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    printf '%s\n' "${key}"
  done < "${env_file}"
}

decrypt_env() {
  local enc_file="$1"

  command -v sops >/dev/null 2>&1 || die "sops is required to validate encrypted env files"
  [[ -f "${enc_file}" ]] || die "encrypted env file not found: ${enc_file}"

  cleanup
  ENV_TMP="$(mktemp /dev/shm/verify-env-XXXXXX)"
  chmod 600 "${ENV_TMP}"
  sops --decrypt --input-type dotenv --output-type dotenv "${enc_file}" > "${ENV_TMP}"
}

validate_env_file() {
  local env_name="$1"
  local enc_file="${PROJECT_ROOT}/env.${env_name}.enc"
  local missing_keys=0
  local env_keys_file example_keys_file

  log "Validating ${enc_file} against .env.example"
  decrypt_env "${enc_file}"

  env_keys_file="$(mktemp)"
  example_keys_file="$(mktemp)"
  trap 'rm -f "${env_keys_file:-}" "${example_keys_file:-}"; cleanup' EXIT

  extract_keys "${ENV_TMP}" | sort -u > "${env_keys_file}"
  extract_keys "${EXAMPLE_ENV}" | sort -u > "${example_keys_file}"

  while IFS= read -r key || [[ -n "${key}" ]]; do
    if ! grep -Fxq "${key}" "${env_keys_file}"; then
      log "Missing variable in env.${env_name}.enc: ${key}"
      missing_keys=$((missing_keys + 1))
    fi
  done < "${example_keys_file}"

  rm -f "${env_keys_file}" "${example_keys_file}"

  if [[ "${missing_keys}" -gt 0 ]]; then
    die "validation failed for env.${env_name}.enc: ${missing_keys} missing variable(s)"
  fi

  log "OK: env.${env_name}.enc contains all required variables"
}

main() {
  parse_args "$@"

  [[ -f "${EXAMPLE_ENV}" ]] || die ".env.example not found: ${EXAMPLE_ENV}"

  if [[ "${VALIDATE_ALL}" == "true" ]]; then
    validate_env_file "dev"
    validate_env_file "prod"
    return 0
  fi

  validate_env_file "$(resolve_environment "${ENVIRONMENT_ARG}")"
}

main "$@"

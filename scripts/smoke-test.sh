#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

LIB_DIR="$SCRIPT_DIR/lib/smoke-test"
# shellcheck disable=SC1091
source "$LIB_DIR/helpers.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/env.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/modules.sh"

DRY_RUN="false"
MODULES_RAW=""
LIST_MODULES="false"
ENVIRONMENT_ARG=""

usage() {
  cat <<EOF
Usage: ./scripts/smoke-test.sh [options]

Options:
  --env ENV            Environment для env.ENV.enc (dev/development або prod/production)
  --dry-run            Print checks without network calls
  --modules M1,M2      Run only selected modules (comma separated)
  --list-modules       Print available module names
  -h, --help           Show this help

Examples:
  ./scripts/smoke-test.sh --env dev
  ./scripts/smoke-test.sh --dry-run
  ./scripts/smoke-test.sh --modules required_checks,security_headers
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env)
        if [[ $# -lt 2 ]]; then
          echo "❌ Missing value for --env"
          exit 1
        fi
        ENVIRONMENT_ARG="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN="true"
        shift
        ;;
      --modules)
        if [[ $# -lt 2 ]]; then
          echo "❌ Missing value for --modules"
          exit 1
        fi
        MODULES_RAW="$2"
        shift 2
        ;;
      --list-modules)
        LIST_MODULES="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "❌ Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done
}

module_exists() {
  local needle="$1"
  local item
  for item in "${AVAILABLE_SMOKE_MODULES[@]}"; do
    if [ "$item" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}

normalize_modules() {
  local selected=()

  if [ -z "$MODULES_RAW" ]; then
    selected=("${AVAILABLE_SMOKE_MODULES[@]}")
    printf '%s\n' "${selected[@]}"
    return 0
  fi

  IFS=',' read -r -a requested <<< "$MODULES_RAW"
  local raw module
  for raw in "${requested[@]}"; do
    module="$(echo "$raw" | xargs)"
    if [ -z "$module" ]; then
      continue
    fi
    if ! module_exists "$module"; then
      echo "❌ Unknown module in --modules: $module" >&2
      echo "Available: $(join_by ', ' "${AVAILABLE_SMOKE_MODULES[@]}")" >&2
      exit 1
    fi
    selected+=("$module")
  done

  if [ ${#selected[@]} -eq 0 ]; then
    echo "❌ No valid modules provided in --modules" >&2
    exit 1
  fi

  printf '%s\n' "${selected[@]}"
}

main() {
  trap cleanup_smoke_env EXIT
  parse_args "$@"

  if [ "$LIST_MODULES" = "true" ]; then
    printf '%s\n' "${AVAILABLE_SMOKE_MODULES[@]}"
    exit 0
  fi

  load_env_for_environment "${ENVIRONMENT_ARG}"

  log "🚦 Smoke tests starting"
  log "   dry-run: $DRY_RUN"

  mapfile -t modules_to_run < <(normalize_modules)
  log "   modules: $(join_by ', ' "${modules_to_run[@]}")"

  local module
  for module in "${modules_to_run[@]}"; do
    run_smoke_module "$module"
  done

  log "✅ Required smoke tests passed (Sitemap is optional)."
}

main "$@"

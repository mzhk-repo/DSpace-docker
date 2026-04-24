#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
PATCH_ARGS=()

usage() {
  cat <<EOF
Usage: ./scripts/setup-configs.sh [options]

Options:
  --no-restart         Do not restart containers from patch scripts
  -h, --help           Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-restart)
      PATCH_ARGS+=(--no-restart)
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "❌ Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

echo "🚀 Starting KDV DSpace Configuration Setup..."
echo "---------------------------------------------"

# Даємо права на виконання (про всяк випадок)
chmod +x "$SCRIPT_DIR/patch-local.cfg.sh"
chmod +x "$SCRIPT_DIR/patch-config.yml.sh"
chmod +x "$SCRIPT_DIR/patch-submission-forms.sh"

# Запускаємо скрипти по черзі
"$SCRIPT_DIR/patch-local.cfg.sh" "${PATCH_ARGS[@]}"
"$SCRIPT_DIR/patch-config.yml.sh" "${PATCH_ARGS[@]}"
"$SCRIPT_DIR/patch-submission-forms.sh"

echo "---------------------------------------------"
echo "🎉 All configurations updated from env file!"

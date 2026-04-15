#!/usr/bin/env bash
set -euo pipefail

if [ -d "/run/secrets" ]; then
  for secret in /run/secrets/*; do
    [ -f "$secret" ] || continue
    export "$(basename "$secret")=$(cat "$secret")"
  done
fi

exec "$@"

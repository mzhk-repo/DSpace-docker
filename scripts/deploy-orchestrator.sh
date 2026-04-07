#!/usr/bin/env bash
set -euo pipefail

[[ -f "example.env" && ! -f ".env" ]] && cp example.env .env || true

mkdir -p dspace/config

LOCAL_CFG_PATH="dspace/config/local.cfg"

if [ -d "$LOCAL_CFG_PATH" ]; then
    backup_path="${LOCAL_CFG_PATH}.dir-backup.$(date +%Y%m%d%H%M%S)"
    echo "⚠️  Found directory at $LOCAL_CFG_PATH. Moving it to $backup_path"
    mv "$LOCAL_CFG_PATH" "$backup_path"
fi

if [ ! -e "$LOCAL_CFG_PATH" ]; then
    touch "$LOCAL_CFG_PATH"
elif [ ! -f "$LOCAL_CFG_PATH" ]; then
    echo "❌ $LOCAL_CFG_PATH exists but is not a regular file."
    exit 1
fi

[[ -f "./scripts/verify-env.sh" ]] && bash ./scripts/verify-env.sh --ci-mock
[[ -f "./scripts/patch-local.cfg.sh" ]] && bash ./scripts/patch-local.cfg.sh
[[ -f "./scripts/patch-config.yml.sh" ]] && bash ./scripts/patch-config.yml.sh
[[ -f "./scripts/init-volumes.sh" ]] && bash ./scripts/init-volumes.sh
[[ -f "./scripts/smoke-test.sh" ]] && bash ./scripts/smoke-test.sh

echo "Orchestration script completed"

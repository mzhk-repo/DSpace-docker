#!/usr/bin/env bash
set -euo pipefail

[[ -f "example.env" && ! -f ".env" ]] && cp example.env .env || true

mkdir -p dspace/config
touch dspace/config/local.cfg

[[ -f "./scripts/verify-env.sh" ]] && bash ./scripts/verify-env.sh --ci-mock || true
[[ -f "./scripts/patch-local.cfg.sh" ]] && bash ./scripts/patch-local.cfg.sh || true
[[ -f "./scripts/patch-config.yml.sh" ]] && bash ./scripts/patch-config.yml.sh || true
[[ -f "./scripts/init-volumes.sh" ]] && bash ./scripts/init-volumes.sh .env || true

echo "Orchestration script completed"

#!/bin/bash
# Скрипт для перевірки, чи всі ключі з .env.example існують у .env
# Використовується в CI/CD та вручну перед запуском.

set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
EXAMPLE_ENV="$SCRIPT_DIR/../.env.example"
ACTUAL_ENV="$SCRIPT_DIR/../.env"
CI_MOCK=false

# Якщо скрипт запускається в CI/CD середовищі без реального .env,
# ми можемо передати прапорець --ci-mock, щоб він не падав, а просто перевіряв синтаксис
if [[ "$1" == "--ci-mock" ]]; then
    echo "🧪 CI Mode: Would mock .env from .env.example, but overwrite is disabled for safety."
    if [ ! -f "$ACTUAL_ENV" ]; then
        cp "$EXAMPLE_ENV" "$ACTUAL_ENV"
        echo "✅ .env created from .env.example (did not exist before)."
    else
        echo "⚠️  .env already exists, not overwriting."
    fi
    CI_MOCK=true
fi

if [ ! -f "$EXAMPLE_ENV" ]; then
    echo "❌ Error: .env.example not found!"
    exit 1
fi

if [ ! -f "$ACTUAL_ENV" ]; then
    echo "❌ Error: .env not found! Please copy .env.example to .env and fill it."
    exit 1
fi

if [ "$CI_MOCK" != "true" ]; then
    ENV_MODE="$(stat -c '%a' "$ACTUAL_ENV" 2>/dev/null || true)"
    if [ "$ENV_MODE" != "600" ]; then
        echo "❌ Security check failed: .env permissions must be 600 (current: ${ENV_MODE:-unknown})."
        exit 1
    fi
fi

echo "🔍 Validating .env against .env.example..."
MISSING_KEYS=0

# Читаємо ключі з .env.example (ігноруємо коментарі та пусті рядки)
while IFS='=' read -r key _; do
    [[ "$key" =~ ^#.*$ ]] && continue
    [[ -z "$key" ]] && continue
    
    # Видаляємо пробіли
    key=$(echo "$key" | tr -d '[:space:]')

    # Шукаємо цей ключ у реальному .env
    if ! grep -q "^[[:space:]]*${key}[[:space:]]*=" "$ACTUAL_ENV"; then
        echo "❌ Missing variable in .env: $key"
        MISSING_KEYS=$((MISSING_KEYS + 1))
    fi
done < "$EXAMPLE_ENV"

if [ "$MISSING_KEYS" -gt 0 ]; then
    echo "🛑 Validation failed! $MISSING_KEYS variables are missing in .env."
    exit 1
else
    echo "✅ Validation passed. All required variables are present."
fi

#!/usr/bin/env bash

load_env_file() {
    local env_file="$1"

    if [ ! -f "$env_file" ]; then
        echo "❌ Error: env file not found: $env_file"
        return 1
    fi

    echo "🌍 Loading environment variables from $env_file..."
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^#.*$ ]] && continue
        [[ -z "$key" ]] && continue

        value=$(echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
        export "$key=$value"
    done < <(grep -vE '^\s*#' "$env_file" | grep -vE '^\s*$')
}

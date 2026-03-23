#!/usr/bin/env bash

log_info() {
    echo "$*"
}

run_or_print() {
    if [ "${DRY_RUN:-false}" = "true" ]; then
        log_info "[dry-run] $*"
        return 0
    fi

    "$@"
}

delete_config_key() {
    local key="$1"
    local file="$2"

    if [ "${DRY_RUN:-false}" = "true" ]; then
        log_info "[dry-run] delete key: ${key} from ${file}"
        return 0
    fi

    local tmp
    tmp=$(mktemp)
    awk -v k="$key" 'index($0, k " = ") == 1 {next} {print}' "$file" > "$tmp"
    mv "$tmp" "$file"
}

set_config() {
    local key="$1"
    local value="$2"
    local file="$3"

    if grep -Fq "$key = " "$file"; then
        delete_config_key "$key" "$file"
    fi

    if [ "${DRY_RUN:-false}" = "true" ]; then
        log_info "[dry-run] set: ${key} = ${value}"
        return 0
    fi

    echo "$key = $value" >> "$file"
    log_info "   Set: $key"
}

remove_config() {
    local key="$1"
    local file="$2"

    if grep -Fq "$key = " "$file"; then
        delete_config_key "$key" "$file"
        log_info "   REMOVED (Clean-up): $key"
    fi
}

join_by() {
    local delimiter="$1"
    shift
    local first="true"
    local item
    for item in "$@"; do
        if [ "$first" = "true" ]; then
            printf '%s' "$item"
            first="false"
        else
            printf '%s%s' "$delimiter" "$item"
        fi
    done
}

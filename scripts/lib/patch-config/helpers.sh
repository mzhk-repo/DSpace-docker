#!/usr/bin/env bash

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

ensure_target_file() {
    local target_file="$1"
    local target_dir
    target_dir="$(dirname "$target_file")"

    if [ "${DRY_RUN:-false}" = "true" ]; then
        echo "[dry-run] ensure directory exists: $target_dir"
        if [ -d "$target_file" ]; then
            local backup_path="${target_file}.dir-backup.$(date +%Y%m%d%H%M%S)"
            echo "[dry-run] would move $target_file to $backup_path"
        fi
        return 0
    fi

    mkdir -p "$target_dir"

    if [ -d "$target_file" ]; then
        local backup_path="${target_file}.dir-backup.$(date +%Y%m%d%H%M%S)"
        echo "⚠️  Found directory at $target_file. Moving it to $backup_path"
        mv "$target_file" "$backup_path"
    fi

    if [ -e "$target_file" ] && [ ! -f "$target_file" ]; then
        echo "❌ $target_file exists but is not a regular file." >&2
        exit 1
    fi
}

write_content() {
    local target_file="$1"
    local content="$2"

    if [ "${DRY_RUN:-false}" = "true" ]; then
        echo "[dry-run] would write generated config to $target_file"
        echo "[dry-run] preview (first 30 lines):"
        printf '%s\n' "$content" | sed -n '1,30p'
        return 0
    fi

    printf '%s\n' "$content" > "$target_file"
}

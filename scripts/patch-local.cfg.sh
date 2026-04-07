#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
ENV_FILE="$SCRIPT_DIR/../.env"
TARGET_FILE="dspace/config/local.cfg"

LIB_DIR="$SCRIPT_DIR/lib/patch-local"
# shellcheck disable=SC1091
source "$LIB_DIR/helpers.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/env.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/db_rotation.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/modules.sh"

DRY_RUN="false"
MODULES_RAW=""
LIST_MODULES="false"

usage() {
    cat <<EOF
Usage: ./scripts/patch-local.cfg.sh [options]

Options:
  --dry-run            Print planned changes without modifying files/DB
  --modules M1,M2      Run only selected modules (comma separated)
  --list-modules       Print available module names
  -h, --help           Show this help

Examples:
  ./scripts/patch-local.cfg.sh
  ./scripts/patch-local.cfg.sh --dry-run
  ./scripts/patch-local.cfg.sh --modules database,db_rotation
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
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
    for item in "${AVAILABLE_PATCH_MODULES[@]}"; do
        if [ "$item" = "$needle" ]; then
            return 0
        fi
    done
    return 1
}

normalize_modules() {
    local selected=()

    if [ -z "$MODULES_RAW" ]; then
        selected=("${AVAILABLE_PATCH_MODULES[@]}")
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
            echo "Available: $(join_by ', ' "${AVAILABLE_PATCH_MODULES[@]}")" >&2
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

ensure_target_file() {
    local target_file="$1"

    if [ -d "$target_file" ]; then
        local backup_path="${target_file}.dir-backup.$(date +%Y%m%d%H%M%S)"
        echo "⚠️  Found directory at $target_file. Moving it to $backup_path"
        if [ "$DRY_RUN" = "true" ]; then
            echo "[dry-run] would move $target_file to $backup_path"
            echo "[dry-run] would create missing $target_file"
            return 0
        fi
        mv "$target_file" "$backup_path"
    fi

    if [ ! -e "$target_file" ]; then
        if [ "$DRY_RUN" = "true" ]; then
            echo "[dry-run] would create missing $target_file"
        else
            touch "$target_file"
        fi
        return 0
    fi

    if [ ! -f "$target_file" ]; then
        echo "❌ $target_file exists but is not a regular file." >&2
        exit 1
    fi
}

main() {
    parse_args "$@"

    if [ "$LIST_MODULES" = "true" ]; then
        printf '%s\n' "${AVAILABLE_PATCH_MODULES[@]}"
        exit 0
    fi

    load_env_file "$ENV_FILE"
    ensure_target_file "$TARGET_FILE"

    echo "🔧 Patching Backend Configuration (MODULAR SYNC)..."
    echo "   dry-run: $DRY_RUN"

    mapfile -t modules_to_run < <(normalize_modules)
    echo "   modules: $(join_by ', ' "${modules_to_run[@]}")"

    local module
    for module in "${modules_to_run[@]}"; do
        run_patch_module "$module"
    done

    if [ "$DRY_RUN" = "true" ]; then
        echo "✅ Dry-run finished. No files or DB credentials were changed."
    else
        echo "✅ Configuration patched successfully."
    fi
}

main "$@"

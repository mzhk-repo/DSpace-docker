#!/usr/bin/env bash
# Скрипт для патчу файлу submission-forms.xml, щоб додати українську мову до списку підтримуваних мов у DSpace 7+

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

read_env_var() {
    local key="$1"
    local file="$2"

    awk -F= -v wanted="$key" '
        {
          raw_key=$1
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", raw_key)
          if (raw_key == wanted) {
            value=substr($0, index($0, "=") + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            gsub(/^"|"$/, "", value)
            gsub(/^'\''|'\''$/, "", value)
            print value
            exit
          }
        }
    ' "$file"
}

resolve_env_file() {
    local env_file="${ORCHESTRATOR_ENV_FILE:-}"

    if [[ -n "$env_file" ]]; then
        if [[ ! -f "$env_file" ]]; then
            echo "[patch-submission-forms] ERROR: ORCHESTRATOR_ENV_FILE не знайдено: $env_file" >&2
            exit 1
        fi
        printf '%s' "$env_file"
        return 0
    fi

    if [[ -f "$PROJECT_ROOT/.env" ]]; then
        echo "[patch-submission-forms] WARNING: ORCHESTRATOR_ENV_FILE не передано. Fallback на локальний .env — тільки для dev." >&2
        printf '%s' "$PROJECT_ROOT/.env"
        return 0
    fi

    echo "[patch-submission-forms] ERROR: env file не знайдено. Передай ORCHESTRATOR_ENV_FILE або поклади .env для локального dev." >&2
    exit 1
}

# --- 2. Paths ---
CONFIG_DIR="$SCRIPT_DIR/../dspace/config"
SOURCE_FILE="$CONFIG_DIR/submission-forms.xml.EXAMPLE"
TARGET_FILE="$CONFIG_DIR/submission-forms.xml"
ENV_FILE="$(resolve_env_file)"
CONTAINER_NAME="${DSPACE_CONTAINER_NAME:-$(read_env_var "DSPACE_CONTAINER_NAME" "$ENV_FILE")}"
CONTAINER_NAME="${CONTAINER_NAME:-dspace}"

mark_backend_restart_required() {
    if [[ -n "${DSPACE_BACKEND_RESTART_FLAG_FILE:-}" ]]; then
        mkdir -p "$(dirname "$DSPACE_BACKEND_RESTART_FLAG_FILE")"
        printf 'patch-submission-forms.sh\n' >> "$DSPACE_BACKEND_RESTART_FLAG_FILE"
    fi
}

echo "🔧 Patching Submission Forms (Adding Ukrainian)..."

mkdir -p "$CONFIG_DIR"
CONFIG_CHANGED="false"

# --- 3. Extract File if needed ---
if [ ! -f "$TARGET_FILE" ]; then
    echo "📥 Extracting submission-forms.xml from container..."
    # Пробуємо взяти робочий файл, або приклад
    if docker ps | grep -q "$CONTAINER_NAME"; then
         docker cp "$CONTAINER_NAME:/dspace/config/submission-forms.xml" "$TARGET_FILE" || \
        docker cp "$CONTAINER_NAME:/dspace/config/submission-forms.xml.EXAMPLE" "$TARGET_FILE" || \
        cp "$SOURCE_FILE" "$TARGET_FILE"
    elif [ -f "$SOURCE_FILE" ]; then
        cp "$SOURCE_FILE" "$TARGET_FILE"
    else
         echo "⚠️ Container not running. Cannot extract file."
         exit 1
    fi
    CONFIG_CHANGED="true"
fi

# --- 4. Patching (sed magic) ---
# Перевіряємо, чи вже є українська мова
if grep -q "<stored-value>uk</stored-value>" "$TARGET_FILE"; then
    echo "✅ Ukrainian language already present."
else
    echo "🇺🇦 Adding Ukrainian language to common_iso_languages..."
    
    # Шукаємо тег початку списку мов і вставляємо після нього блок з українською
    # Використовуємо тимчасовий файл для надійності
    sed -i '/<value-pairs value-pairs-name="common_iso_languages" dc-term="language_iso">/a \
            <pair>\n\
                <displayed-value>Ukrainian</displayed-value>\n\
                <stored-value>uk</stored-value>\n\
            </pair>' "$TARGET_FILE"
            
    echo "✅ Added Ukrainian language."
    CONFIG_CHANGED="true"
fi

if [[ "$(read_env_var DSPACE_REST_VER "$ENV_FILE")" == dspace-10.* ]]; then
    forms_result="$(python3 - "$TARGET_FILE" "$CONFIG_DIR/submission-forms-10.1-additions.xml" <<'PY'
import os
import pathlib
import tempfile
import xml.etree.ElementTree as ET
import sys

path = pathlib.Path(sys.argv[1])
content = path.read_text(encoding="utf-8")
root = ET.fromstring(content)
additions = ET.parse(sys.argv[2]).getroot()
missing = [form for form in additions.findall('form')
           if root.find(f'./form-definitions/form[@name="{form.get("name")}"]') is None]
if not missing:
    print("unchanged")
else:
    closing = "    </form-definitions>"
    if content.count(closing) != 1:
        raise SystemExit("Expected exactly one form-definitions closing tag")
    forms = ''.join('    ' + ET.tostring(form, encoding='unicode') for form in missing)
    updated = content.replace(closing, forms + closing, 1)
    ET.fromstring(updated)
    fd, temporary = tempfile.mkstemp(prefix=".submission-forms-", dir=path.parent)
    try:
        os.fchmod(fd, path.stat().st_mode & 0o7777)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(updated)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print("changed")
PY
)"
    if [[ "$forms_result" == changed ]]; then
        echo "Added missing DSpace 10 submission forms."
        CONFIG_CHANGED="true"
    fi
fi

if [[ "$CONFIG_CHANGED" == "true" ]]; then
    mark_backend_restart_required
fi

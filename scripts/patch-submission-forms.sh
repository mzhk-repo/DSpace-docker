#!/bin/bash
# Скрипт для патчу файлу submission-forms.xml, щоб додати українську мову до списку підтримуваних мов у DSpace 7+

set -e

# --- 1. Load .env ---
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
ENV_FILE="$SCRIPT_DIR/../.env"
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090,SC1091
    source "$ENV_FILE"
    set +a
fi

# --- 2. Paths ---
CONFIG_DIR="$SCRIPT_DIR/../dspace/config"
SOURCE_FILE="$CONFIG_DIR/submission-forms.xml.EXAMPLE"
TARGET_FILE="$CONFIG_DIR/submission-forms.xml"
CONTAINER_NAME=${DSPACE_CONTAINER_NAME:-dspace}

echo "🔧 Patching Submission Forms (Adding Ukrainian)..."

mkdir -p "$CONFIG_DIR"

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
fi
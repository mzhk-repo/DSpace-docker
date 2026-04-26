#!/usr/bin/env bash
# Скрипт для синхронізації користувачів з OIDC групи в DSpace
# Використовує UUID групи з env.<env>.enc та додає користувачів, які мають email з певним доменом, до цієї групи в базі даних DSpace. 
# Додай рядок, щоб запускати скрипт, наприклад, кожні 10 хвилин (або щогодини):
# crontab -e
# */10 * * * * /home/pinokew/Dspace/DSpace-docker/scripts/sync-user-groups.sh >> /var/log/dspace-sync.log 2>&1  

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
PROJECT_ROOT="$SCRIPT_DIR/.."
ENVIRONMENT_ARG="${1:-}"
DRY_RUN=false

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --env)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: Missing value for --env" >&2; exit 1; }
      ENVIRONMENT_ARG="$1"
      ;;
    --env=*)
      ENVIRONMENT_ARG="${1#--env=}"
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
    -h|--help)
    echo "Usage: $0 [--env dev|prod] [--dry-run]"
    exit 0
      ;;
    dev|development|prod|production)
      ENVIRONMENT_ARG="$1"
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

# --- Load env.<env>.enc через локальну SOPS-розшифровку ---
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/autonomous-env.sh"
load_autonomous_env "$PROJECT_ROOT" "$ENVIRONMENT_ARG"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/docker-runtime.sh"

# --- Configuration ---
GROUP_UUID="${OIDC_LOGIN_GROUP_UUID:-}"
DOMAIN_SUFFIX="${OIDC_DOMAIN:-}"

DB_USER="${POSTGRES_USER:-dspace}"
DB_NAME="${POSTGRES_DB:-dspace}"
DB_PASSWORD="${POSTGRES_PASSWORD:-dspace}"

# --- Validation ---
if [ -z "$GROUP_UUID" ] || [ -z "$DOMAIN_SUFFIX" ]; then
    echo "❌ Error: OIDC_LOGIN_GROUP_UUID or OIDC_DOMAIN is missing in env file"
    exit 1
fi

TARGET_DOMAIN="@${DOMAIN_SUFFIX}"

echo "🔄 Starting Group Sync..."
echo "   Target Group UUID: $GROUP_UUID"
echo "   Target Domain:     $TARGET_DOMAIN"

# --- SQL Logic (FIXED) ---
# Видалено колонку 'id' та 'gen_random_uuid()',
# оскільки в DSpace 7+ таблиці зв'язків не мають окремого ID.

SQL_QUERY="
INSERT INTO epersongroup2eperson (eperson_group_id, eperson_id)
SELECT 
    '$GROUP_UUID',     -- ID групи
    e.uuid             -- ID користувача
FROM eperson e
WHERE e.email LIKE '%$TARGET_DOMAIN'
  AND NOT EXISTS (
      -- Перевіряємо дублікати
      SELECT 1 FROM epersongroup2eperson link 
      WHERE link.eperson_group_id = '$GROUP_UUID' 
      AND link.eperson_id = e.uuid
  );
"

# --- Execution ---
# Використовуємо Pipe метод для передачі пароля та запиту
if [[ "$DRY_RUN" == true ]]; then
    echo "[dry-run] SQL to execute:"
    echo "$SQL_QUERY"
    exit 0
fi

echo "$SQL_QUERY" | docker_runtime_exec dspacedb env PGPASSWORD="$DB_PASSWORD" psql -U "$DB_USER" -d "$DB_NAME" -w > /tmp/sync_output.txt 2>&1

OUTPUT=$(cat /tmp/sync_output.txt)
rm /tmp/sync_output.txt

# --- Parsing Result ---
# Шукаємо рядок INSERT 0 X
INSERT_LINE=$(echo "$OUTPUT" | grep -o "INSERT 0 [0-9]*" || true)

if [ -n "$INSERT_LINE" ]; then
    COUNT=$(echo "$INSERT_LINE" | awk '{print $3}')
    echo "✅ Sync completed successfully."
    echo "   Users added: ${COUNT:-0}"
else
    echo "⚠️  Sync FAILED or SQL Error:"
    echo "---------------------------------------------------"
    echo "$OUTPUT"
    echo "---------------------------------------------------"
fi

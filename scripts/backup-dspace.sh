#!/usr/bin/env bash
set -euo pipefail

# Paths
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

# --- 1. Load env.<env>.enc через локальну SOPS-розшифровку ---
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/autonomous-env.sh"
load_autonomous_env "$PROJECT_ROOT" "$ENVIRONMENT_ARG"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/docker-runtime.sh"

# 2. Перевірка критичних змінних
# Якщо ці змінні не задані в env.<env>.enc, скрипт зупиниться
: "${VOL_ASSETSTORE_PATH:?Variable VOL_ASSETSTORE_PATH not set in env file}"
: "${BACKUP_RCLONE_REMOTE:?Variable BACKUP_RCLONE_REMOTE not set in env file}"
: "${DB_SERVICE_NAME:?Variable DB_SERVICE_NAME not set in env file}"

# 3. Налаштування шляхів
BACKUP_DIR="${PROJECT_ROOT}/${BACKUP_LOCAL_DIR:-backups}" 
DATE=$(date +%Y-%m-%d_%H-%M)
LOG_FILE="${BACKUP_DIR}/backup_log.txt"

# Створення папки бекапів
mkdir -p "$BACKUP_DIR"

# Імена файлів
SQL_DUMP="${BACKUP_DIR}/dspace_db_${DATE}.sql"
ARCHIVE_CLOUD="${BACKUP_DIR}/cloud_metadata_${DATE}.tar.gz"  # Тільки база + конфіги
ARCHIVE_LOCAL="${BACKUP_DIR}/full_local_${DATE}.tar.gz"      # Все + файли книг
ENV_ARCHIVE_FILE="env.${AUTONOMOUS_ENVIRONMENT}.enc"

# Функція для логування
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=== Starting Backup Routine ==="

# --- КРОК 1: ДАМП БАЗИ ДАНИХ ---
log "[1/5] Dumping Database from service: $DB_SERVICE_NAME..."

if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] docker_runtime_exec $DB_SERVICE_NAME pg_dump -U *** *** > $SQL_DUMP"
elif docker_runtime_exec "$DB_SERVICE_NAME" \
    pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" > "$SQL_DUMP"; then
    log "Database dumped successfully."
else
    log "ERROR: Database dump failed!"
    rm -f "$SQL_DUMP"
    exit 1
fi

# --- КРОК 2: АРХІВ ДЛЯ ХМАРИ (Metadata Only) ---
log "[2/5] Creating Cloud Archive (DB + Configs + Env)..."

# Архівуємо SQL, папку конфігів та encrypted env-файл
if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] tar cloud archive -> $ARCHIVE_CLOUD"
elif tar -czf "$ARCHIVE_CLOUD" \
    -C "$BACKUP_DIR" "$(basename "$SQL_DUMP")" \
    -C "$PROJECT_ROOT" "$ENV_ARCHIVE_FILE" \
    -C "$PROJECT_ROOT" dspace/config; then
    log "Cloud archive created: $(basename "$ARCHIVE_CLOUD")"
else
    log "ERROR: Cloud archiving failed!"
    exit 1
fi

# --- КРОК 3: ЗАВАНТАЖЕННЯ НА GOOGLE DRIVE ---
log "[3/5] Uploading to Google Drive ($BACKUP_RCLONE_REMOTE)..."

if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] rclone copy $ARCHIVE_CLOUD ${BACKUP_RCLONE_REMOTE}:${BACKUP_RCLONE_FOLDER}"
elif rclone copy "$ARCHIVE_CLOUD" "${BACKUP_RCLONE_REMOTE}:${BACKUP_RCLONE_FOLDER}"; then
    log "Upload SUCCESS."
else
    log "ERROR: Upload FAILED. Check internet or rclone config."
    # Не виходимо, бо треба зробити локальний повний бекап
fi

# --- КРОК 4: ЛОКАЛЬНИЙ ПОВНИЙ БЕКАП (З Assetstore) ---
log "[4/5] Creating Full Local Archive (incl. Assetstore)..."

# Тут ми використовуємо змінну VOL_ASSETSTORE_PATH з env.<env>.enc
if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] tar full local archive incl. assetstore -> $ARCHIVE_LOCAL"
elif [ -d "$VOL_ASSETSTORE_PATH" ]; then
    # dirname/basename магія потрібна, щоб tar не зберігав повний абсолютний шлях (/home/user/...)
    tar -czf "$ARCHIVE_LOCAL" \
        -C "$BACKUP_DIR" "$(basename "$SQL_DUMP")" \
        -C "$PROJECT_ROOT" "$ENV_ARCHIVE_FILE" \
        -C "$PROJECT_ROOT" dspace/config \
        -C "$(dirname "$VOL_ASSETSTORE_PATH")" "$(basename "$VOL_ASSETSTORE_PATH")"
    
    log "Full Local archive created: $(basename "$ARCHIVE_LOCAL")"
else
    log "WARNING: Assetstore path ($VOL_ASSETSTORE_PATH) not found! Skipping assetstore backup."
fi

# --- КРОК 5: ОЧИЩЕННЯ ---
log "[5/5] Cleanup..."

# Видаляємо "сирий" SQL (він вже в архівах)
if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] rm -f $SQL_DUMP"
else
    rm -f "$SQL_DUMP"
fi

# Видаляємо "хмарний" архів з диска (щоб не дублювати місце, бо у нас є повний)
if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] rm -f $ARCHIVE_CLOUD"
else
    rm -f "$ARCHIVE_CLOUD"
fi

# Видаляємо старі локальні архіви (старше N днів з .env)
RETENTION=${BACKUP_RETENTION_DAYS:-7}
if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] find $BACKUP_DIR -name full_local_*.tar.gz -mtime +$RETENTION -exec rm"
else
    find "$BACKUP_DIR" -name "full_local_*.tar.gz" -mtime +"$RETENTION" -exec rm {} \;
fi
log "Old backups (older than $RETENTION days) removed."

log "=== Backup Finished ==="

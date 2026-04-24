#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 🚑 KDV DSpace DISASTER RECOVERY Script — restore-backup.sh
# ==============================================================================
# ⚠️  УВАГА / DANGER
# Цей скрипт:
#   1) ЗУПИНИТЬ DSpace stack
#   2) ВИДАЛИТЬ поточні дані PostgreSQL
#   3) ВИДАЛИТЬ поточні Solr cores (щоб змусити переіндексацію)
#   4) (Опційно) ВИДАЛИТЬ поточний Assetstore і відновить його з бекапу (якщо є в архіві)
#   5) ВІДНОВИТЬ БД з .sql дампу
#   6) ЗАПУСТИТЬ stack і запустить переіндексацію
#
# ❗ Це руйнівна операція. Використовуй ТІЛЬКИ для DR-тестів або аварійного відновлення.
# ============================================================================== 

# ----------------------------
# 0) Helpers
# ----------------------------
log() { echo "[$(date '+%F %T')] $*"; }
err() { echo "[$(date '+%F %T')] ❌ $*" >&2; }

die() { err "$*"; exit 1; }

# Keep terminal output readable: suppress routine stdout but keep stderr for errors.
run_quiet() { "$@" >/dev/null; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

# ----------------------------
# 1) Paths
# ----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

ENVIRONMENT_ARG=""
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: sudo $0 [--env dev|prod] <path_to_backup_file.tar.gz>"
  echo "Example: sudo $0 --env prod /srv/backups/dspace_full_2026-02-18.tar.gz"
  exit 0
elif [[ "${1:-}" == "--env" ]]; then
  [[ $# -ge 2 ]] || die "Missing value for --env"
  ENVIRONMENT_ARG="$2"
  shift 2
elif [[ "${1:-}" =~ ^(dev|development|prod|production)$ ]]; then
  ENVIRONMENT_ARG="$1"
  shift
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: sudo $0 [--env dev|prod] <path_to_backup_file.tar.gz>"
  echo "Example: sudo $0 --env prod /srv/backups/dspace_full_2026-02-18.tar.gz"
  exit 1
fi

# --- 1. Load env.<env>.enc через локальну SOPS-розшифровку ---
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/autonomous-env.sh"
load_autonomous_env "$PROJECT_ROOT" "$ENVIRONMENT_ARG"

# ----------------------------
# 3) Args & preflight checks
# ----------------------------

BACKUP_FILE_RAW="$1"
if [[ "$BACKUP_FILE_RAW" = /* ]]; then
  BACKUP_FILE="$BACKUP_FILE_RAW"
else
  BACKUP_FILE="$(pwd)/$BACKUP_FILE_RAW"
fi

[[ -f "$BACKUP_FILE" ]] || die "Backup file not found: $BACKUP_FILE"

require_cmd tar
require_cmd find
require_cmd docker
require_cmd sudo

# ВАЖЛИВО: нижче — критичні шляхи з SSOT
: "${VOL_POSTGRESQL_PATH:?VOL_POSTGRESQL_PATH is required in env file}"
: "${VOL_SOLR_PATH:?VOL_SOLR_PATH is required in env file}"
: "${VOL_ASSETSTORE_PATH:?VOL_ASSETSTORE_PATH is required in env file}"

# Твій compose файл
COMPOSE_FILE="$PROJECT_ROOT/docker-compose.yml"
[[ -f "$COMPOSE_FILE" ]] || die "docker-compose.yml not found at: $COMPOSE_FILE"

TEMP_DIR="/tmp/kdv_restore_run_$(date +%s)"

# ----------------------------
# 4) BIG WARNING + manual confirmation
# ----------------------------
cat <<EOF
=======================================================
⚠️  WARNING: DSpace DISASTER RECOVERY MODE
=======================================================
Target backup archive:
  $BACKUP_FILE

This process WILL:
  1) STOP all DSpace containers
  2) DELETE current PostgreSQL data at:
     $VOL_POSTGRESQL_PATH
  3) DELETE current Solr data at:
     $VOL_SOLR_PATH
  4) DELETE current Assetstore at:
     $VOL_ASSETSTORE_PATH
     (ONLY if the backup archive contains an assetstore/ directory)
  5) RESTORE database from SQL dump in the archive
  6) RESTORE assetstore from the archive (if present)
  7) START the full stack and RE-INDEX Solr

🚫 If you are not 100% sure — press Ctrl+C now.
EOF

# Подвійне підтвердження: спочатку "YES", потім "RESTORE"
read -r -p "Type 'YES' to confirm you understand ALL DATA WILL BE DELETED: " CONFIRM1
[[ "$CONFIRM1" == "YES" ]] || die "Operation cancelled."

read -r -p "Type 'RESTORE' to start restore now: " CONFIRM2
[[ "$CONFIRM2" == "RESTORE" ]] || die "Operation cancelled."

# ----------------------------
# 5) Unpack archive and locate artifacts
# ----------------------------
log "[1/6] Unpacking backup to temp: $TEMP_DIR"
mkdir -p "$TEMP_DIR"
tar -xzf "$BACKUP_FILE" -C "$TEMP_DIR"

SQL_DUMP="$(find "$TEMP_DIR" -maxdepth 5 -type f -name "*.sql" | head -n 1 || true)"
EXTRACTED_ASSETSTORE="$(find "$TEMP_DIR" -maxdepth 5 -type d -name "assetstore" | head -n 1 || true)"

[[ -n "$SQL_DUMP" ]] || { rm -rf "$TEMP_DIR"; die "No SQL dump (*.sql) found in backup archive."; }

log "   Found SQL dump: $SQL_DUMP"
if [[ -n "$EXTRACTED_ASSETSTORE" ]]; then
  log "   Found assetstore directory in backup: $EXTRACTED_ASSETSTORE"
else
  log "   Backup has NO assetstore directory (cloud/metadata-only backup?)"
fi

# ----------------------------
# 6) Stop stack + destructive cleanup
# ----------------------------
log "[2/6] Stopping containers (docker compose down)"
run_quiet docker compose -f "$COMPOSE_FILE" down

log "   Cleaning PostgreSQL volume: $VOL_POSTGRESQL_PATH"
# safety: require non-empty and not root
[[ -n "$VOL_POSTGRESQL_PATH" && "$VOL_POSTGRESQL_PATH" != "/" ]] || die "Refusing to wipe VOL_POSTGRESQL_PATH=$VOL_POSTGRESQL_PATH"
sudo rm -rf "${VOL_POSTGRESQL_PATH:?}/"*

log "   Cleaning Solr volume (forces re-index): $VOL_SOLR_PATH"
[[ -n "$VOL_SOLR_PATH" && "$VOL_SOLR_PATH" != "/" ]] || die "Refusing to wipe VOL_SOLR_PATH=$VOL_SOLR_PATH"
sudo rm -rf "${VOL_SOLR_PATH:?}/"*

if [[ -n "$EXTRACTED_ASSETSTORE" ]]; then
  log "   Cleaning Assetstore volume: $VOL_ASSETSTORE_PATH"
  [[ -n "$VOL_ASSETSTORE_PATH" && "$VOL_ASSETSTORE_PATH" != "/" ]] || die "Refusing to wipe VOL_ASSETSTORE_PATH=$VOL_ASSETSTORE_PATH"
  sudo rm -rf "${VOL_ASSETSTORE_PATH:?}/"*
else
  log "   ⚠️  Skipping Assetstore wipe (backup has no assetstore). Current files will be kept."
fi

# ----------------------------
# 7) Restore DB
# ----------------------------
log "[3/6] Restoring Database"

# Start only DB first
log "   Starting database service (dspacedb)"
run_quiet docker compose -f "$COMPOSE_FILE" up -d dspacedb

log "   Waiting for DB to become ready (up to 60s)"
for i in {1..30}; do
  if docker compose -f "$COMPOSE_FILE" exec -T dspacedb pg_isready -U "${POSTGRES_USER:-dspace}" -d "${POSTGRES_DB:-dspace}" >/dev/null 2>&1; then
    break
  fi
  sleep 2
  if [[ $i -eq 30 ]]; then
    rm -rf "$TEMP_DIR"
    die "Database did not become ready in time."
  fi
done

# Drop + create DB (in case leftovers exist)
log "   Dropping and recreating database: ${POSTGRES_DB:-dspace}"
run_quiet docker compose -f "$COMPOSE_FILE" exec -T dspacedb dropdb -U "${POSTGRES_USER:-dspace}" "${POSTGRES_DB:-dspace}" --if-exists
# Postgres image usually auto-creates DB on first run, but after wipe we recreate explicitly
run_quiet docker compose -f "$COMPOSE_FILE" exec -T dspacedb createdb -U "${POSTGRES_USER:-dspace}" "${POSTGRES_DB:-dspace}"

log "   Importing SQL dump into database"
docker compose -f "$COMPOSE_FILE" exec -T -i dspacedb \
  psql -v ON_ERROR_STOP=1 -q -U "${POSTGRES_USER:-dspace}" "${POSTGRES_DB:-dspace}" \
  < "$SQL_DUMP" >/dev/null

# ----------------------------
# 8) Restore files (assetstore)
# ----------------------------
log "[4/6] Restoring Files"
if [[ -n "$EXTRACTED_ASSETSTORE" ]]; then
  log "   Copying Assetstore files to: $VOL_ASSETSTORE_PATH"
  # Use rsync-like semantics via cp; assetstore may contain many files
  sudo cp -a "$EXTRACTED_ASSETSTORE/." "$VOL_ASSETSTORE_PATH/"

  # Restore expected ownership for DSpace (typically 1000:1000)
  # If you use different UID/GID, you can override via .env: DSPACE_UID / DSPACE_GID
  DSPACE_UID="${DSPACE_UID:-1000}"
  DSPACE_GID="${DSPACE_GID:-1000}"
  log "   Setting ownership for assetstore to ${DSPACE_UID}:${DSPACE_GID}"
  sudo chown -R "${DSPACE_UID}:${DSPACE_GID}" "$VOL_ASSETSTORE_PATH"
else
  log "   Skipping Assetstore restore (not present in backup)."
fi

# ----------------------------
# 9) Start full stack + reindex
# ----------------------------
log "[5/6] Starting Full Stack"
run_quiet docker compose -f "$COMPOSE_FILE" up -d

log "   Waiting for DSpace Backend to start (up to 90s)"
for i in {1..30}; do
  if docker compose -f "$COMPOSE_FILE" exec -T dspace wget -qO- "http://127.0.0.1:${DSPACE_INTERNAL_PORT:-8080}${DSPACE_REST_NAMESPACE:-/server}/api/core/sites" >/dev/null 2>&1; then
    break
  fi
  sleep 3
  if [[ $i -eq 30 ]]; then
    rm -rf "$TEMP_DIR"
    die "DSpace backend did not become healthy in time."
  fi
done

log "[6/6] Re-indexing Solr (Critical Step)"
run_quiet docker compose -f "$COMPOSE_FILE" exec -T dspace /dspace/bin/dspace index-discovery -b

# ----------------------------
# 10) Cleanup
# ----------------------------
rm -rf "$TEMP_DIR"

log "======================================================="
log "✅ RESTORE COMPLETED."
log "   Note: allow a few minutes for Solr caches to warm up."
log "======================================================="

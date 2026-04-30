#!/usr/bin/env bash
set -euo pipefail

# Підключається з backup-dspace.sh.
# Очікує: BACKUP_DIR, PROJECT_ROOT, DRY_RUN, SQL_DUMP, ARCHIVE_CLOUD,
# ARCHIVE_LOCAL, ENV_ARCHIVE_FILE, VOL_ASSETSTORE_PATH, BACKUP_RCLONE_REMOTE,
# BACKUP_RCLONE_FOLDER, DB_SERVICE_NAME, POSTGRES_USER, POSTGRES_DB.

backup_metadata() {
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

    local tar_sources=(
        --directory="$BACKUP_DIR" "$(basename "$SQL_DUMP")"
        --directory="$PROJECT_ROOT" "$ENV_ARCHIVE_FILE"
        --directory="$PROJECT_ROOT" "dspace/config"
    )

    if [[ "$DRY_RUN" == true ]]; then
        log "[dry-run] tar cloud archive -> $ARCHIVE_CLOUD"
    elif tar -czf "$ARCHIVE_CLOUD" "${tar_sources[@]}"; then
        sha256sum "$ARCHIVE_CLOUD" > "${ARCHIVE_CLOUD}.sha256"
        log "Cloud archive created: $(basename "$ARCHIVE_CLOUD")"
        log "Checksum: $(cat "${ARCHIVE_CLOUD}.sha256")"
    else
        log "ERROR: Cloud archiving failed!"
        exit 1
    fi

    # --- КРОК 3: ЗАВАНТАЖЕННЯ НА GOOGLE DRIVE ---
    log "[3/5] Uploading to Google Drive ($BACKUP_RCLONE_REMOTE)..."

    local remote_folder="${BACKUP_RCLONE_REMOTE}:${BACKUP_RCLONE_FOLDER}"
    local local_archive_dir
    local archive_name
    local checksum_name
    local_archive_dir="$(dirname "$ARCHIVE_CLOUD")"
    archive_name="$(basename "$ARCHIVE_CLOUD")"
    checksum_name="${archive_name}.sha256"

    if [[ "$DRY_RUN" == true ]]; then
        log "[dry-run] rclone copy $ARCHIVE_CLOUD $remote_folder"
        log "[dry-run] rclone copy ${ARCHIVE_CLOUD}.sha256 $remote_folder"
        log "[dry-run] rclone check $local_archive_dir $remote_folder --one-way --filter '+ /$archive_name' --filter '+ /$checksum_name' --filter '- *'"
    elif rclone copy "$ARCHIVE_CLOUD" "$remote_folder" && \
        rclone copy "${ARCHIVE_CLOUD}.sha256" "$remote_folder"; then
        if rclone check "$local_archive_dir" "$remote_folder" \
            --one-way \
            --filter "+ /$archive_name" \
            --filter "+ /$checksum_name" \
            --filter "- *"; then
            log "Upload and verification SUCCESS."
        else
            log "WARNING: Upload completed but rclone check FAILED. Manual verification recommended."
        fi
    else
        log "ERROR: Upload FAILED. Check internet or rclone config."
        # Не виходимо, бо треба зробити локальний повний бекап.
    fi

    # --- КРОК 4: ЛОКАЛЬНИЙ ПОВНИЙ БЕКАП (З Assetstore) ---
    log "[4/5] Creating Full Local Archive (incl. Assetstore)..."

    if [[ "$DRY_RUN" == true ]]; then
        log "[dry-run] tar full local archive incl. assetstore -> $ARCHIVE_LOCAL"
    elif [[ -d "$VOL_ASSETSTORE_PATH" ]]; then
        local tar_full_sources=(
            --directory="$BACKUP_DIR" "$(basename "$SQL_DUMP")"
            --directory="$PROJECT_ROOT" "$ENV_ARCHIVE_FILE"
            --directory="$PROJECT_ROOT" "dspace/config"
            --directory="$(dirname "$VOL_ASSETSTORE_PATH")" "$(basename "$VOL_ASSETSTORE_PATH")"
        )

        if tar -czf "$ARCHIVE_LOCAL" "${tar_full_sources[@]}"; then
            log "Full Local archive created: $(basename "$ARCHIVE_LOCAL")"
        else
            log "ERROR: Full local archiving failed!"
            exit 1
        fi
    else
        log "WARNING: Assetstore path ($VOL_ASSETSTORE_PATH) not found! Skipping assetstore backup."
    fi
}

#!/usr/bin/env bash
set -euo pipefail

# Підключається з backup-dspace.sh.
# Очікує: BACKUP_DIR, DATE, DRY_RUN, VOL_ASSETSTORE_PATH, BACKUP_ASSETSTORE_MIRROR.

backup_assetstore() {
    log "[assetstore] Syncing Assetstore mirror..."

    local mirror_dir="${BACKUP_ASSETSTORE_MIRROR:?Variable BACKUP_ASSETSTORE_MIRROR not set in env file}"
    local deleted_dir="${BACKUP_DIR}/assetstore-deleted/${DATE}"

    if [[ "$DRY_RUN" == true ]]; then
        log "[dry-run] rsync --archive --checksum --delete --backup --backup-dir=$deleted_dir ${VOL_ASSETSTORE_PATH}/ ${mirror_dir}/"
        return 0
    fi

    if [[ ! -d "$VOL_ASSETSTORE_PATH" ]]; then
        log "WARNING: Assetstore path ($VOL_ASSETSTORE_PATH) not found! Skipping mirror."
        return 0
    fi

    mkdir -p "$mirror_dir"
    mkdir -p "$deleted_dir"

    if rsync \
        --archive \
        --checksum \
        --delete \
        --backup \
        --backup-dir="$deleted_dir" \
        "${VOL_ASSETSTORE_PATH}/" \
        "${mirror_dir}/"; then
        log "[assetstore] Mirror sync completed."
    else
        log "ERROR: Assetstore rsync failed!"
        exit 1
    fi

    if [[ -d "$deleted_dir" ]] && [[ -z "$(ls -A "$deleted_dir")" ]]; then
        rmdir "$deleted_dir"
        log "[assetstore] No files deleted this run; removed empty deleted-dir."
    else
        log "[assetstore] Deleted files archived to: $deleted_dir"
    fi
}

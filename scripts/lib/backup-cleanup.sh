#!/usr/bin/env bash
set -euo pipefail

# Підключається з backup-dspace.sh.
# Очікує: BACKUP_DIR, DRY_RUN, SQL_DUMP, ARCHIVE_CLOUD,
# BACKUP_RCLONE_REMOTE, BACKUP_RCLONE_FOLDER.

backup_cleanup() {
    log "[5/5] Cleanup..."

    local retention_full_local="${BACKUP_RETENTION_FULL_LOCAL:-${BACKUP_RETENTION_DAYS:-30}}"
    local retention_meta_local="${BACKUP_RETENTION_META_LOCAL:-30}"
    local retention_meta_cloud="${BACKUP_RETENTION_META_CLOUD:-90}"
    local retention_deleted="${BACKUP_RETENTION_DELETED:-180}"

    if [[ "$DRY_RUN" == true ]]; then
        log "[dry-run] rm -f $SQL_DUMP"
    else
        rm -f "$SQL_DUMP"
    fi

    log "[cleanup] Keeping local metadata archive: $(basename "$ARCHIVE_CLOUD")"

    log "[cleanup] Removing local full archives older than ${retention_full_local} days..."
    if [[ "$DRY_RUN" == true ]]; then
        log "[dry-run] find $BACKUP_DIR -name 'full_local_*.tar.gz' -mtime +${retention_full_local} -delete"
    else
        find "$BACKUP_DIR" \
            -name "full_local_*.tar.gz" \
            -mtime +"$retention_full_local" \
            -delete
    fi

    log "[cleanup] Removing local metadata archives older than ${retention_meta_local} days..."
    if [[ "$DRY_RUN" == true ]]; then
        log "[dry-run] find $BACKUP_DIR \\( -name 'cloud_metadata_*.tar.gz' -o -name 'cloud_metadata_*.tar.gz.sha256' \\) -mtime +${retention_meta_local} -delete"
    else
        find "$BACKUP_DIR" \
            \( -name "cloud_metadata_*.tar.gz" -o -name "cloud_metadata_*.tar.gz.sha256" \) \
            -mtime +"$retention_meta_local" \
            -delete
    fi

    local deleted_root="${BACKUP_DIR}/assetstore-deleted"
    log "[cleanup] Removing deleted-asset dirs older than ${retention_deleted} days..."
    if [[ "$DRY_RUN" == true ]]; then
        log "[dry-run] find $deleted_root -mindepth 1 -maxdepth 1 -type d -mtime +${retention_deleted} -exec rm -rf"
    elif [[ -d "$deleted_root" ]]; then
        find "$deleted_root" \
            -mindepth 1 -maxdepth 1 \
            -type d \
            -mtime +"$retention_deleted" \
            -exec rm -rf {} \;
    fi

    log "[cleanup] Removing cloud archives older than ${retention_meta_cloud} days..."
    if [[ "$DRY_RUN" == true ]]; then
        log "[dry-run] rclone delete ${BACKUP_RCLONE_REMOTE}:${BACKUP_RCLONE_FOLDER} --filter '+ cloud_metadata_*.tar.gz' --filter '+ cloud_metadata_*.tar.gz.sha256' --filter '- *' --min-age ${retention_meta_cloud}d"
    elif rclone delete \
        "${BACKUP_RCLONE_REMOTE}:${BACKUP_RCLONE_FOLDER}" \
        --filter "+ cloud_metadata_*.tar.gz" \
        --filter "+ cloud_metadata_*.tar.gz.sha256" \
        --filter "- *" \
        --min-age "${retention_meta_cloud}d"; then
        log "[cleanup] Cloud old archives removed."
    else
        log "WARNING: rclone cloud cleanup failed. Check remote access."
    fi

    log "[cleanup] Done. Retention: full-local=${retention_full_local}d | meta-local=${retention_meta_local}d | meta-cloud=${retention_meta_cloud}d | deleted-assets=${retention_deleted}d"
}

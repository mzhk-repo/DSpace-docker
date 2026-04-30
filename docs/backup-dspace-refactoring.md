# Refactoring Spec: `backup-dspace.sh`

> **Target agent:** Codex GPT 5.5  
> **Scope:** Structural refactoring only. Do **not** touch env-loading logic
> (`lib/autonomous-env.sh`, `lib/docker-runtime.sh`), logging infrastructure
> (`LOG_FILE`), or any variable/behaviour not explicitly listed below.

---

## 1. Context & Hard Constraints

| Constraint | Detail |
|---|---|
| Env loading | `source lib/autonomous-env.sh` + `load_autonomous_env` + `source lib/docker-runtime.sh` — **unchanged, untouched** |
| Logging | `LOG_FILE`, `log()` function and its call-sites — **unchanged** |
| Notifications | Handled externally by VictoriaMetrics → Grafana via `LOG_FILE` — **no changes needed** |
| Assetstore cloud backup | **Not required** — local mirror only |
| Language | Bash (`#!/usr/bin/env bash`), `set -euo pipefail` in every file |

---

## 2. New File Structure

```
scripts/
├── backup-dspace.sh          # Entry point — arg parsing + orchestration only
└── lib/
    ├── autonomous-env.sh     # EXISTING — do not modify
    ├── docker-runtime.sh     # EXISTING — do not modify
    ├── backup-metadata.sh    # NEW — Steps 1–3: dump → archive → upload
    ├── backup-assetstore.sh  # NEW — Step 4: rsync mirror + deleted-files archive
    └── backup-cleanup.sh     # NEW — Step 5: retention logic for all artifact types
```

---

## 3. Bug Fixes (apply in `backup-dspace.sh`)

### 3.1 Double initialisation of `ENVIRONMENT_ARG`

**Problem:** `ENVIRONMENT_ARG="${1:-}"` runs before the `while` loop, so passing
`--env prod` sets `ENVIRONMENT_ARG="--env"` instead of `"prod"`.

**Fix:** Remove the pre-loop assignment entirely. Declare the variable as empty
before the loop.

```bash
# BEFORE (buggy)
ENVIRONMENT_ARG="${1:-}"
DRY_RUN=false
while [[ "$#" -gt 0 ]]; do ...

# AFTER (correct)
ENVIRONMENT_ARG=""
DRY_RUN=false
while [[ "$#" -gt 0 ]]; do ...
```

---

## 4. New env variables (add to `env.<env>.enc`)

These variables extend — and do not replace — the existing ones.

```dotenv
# Retention periods (in days)
BACKUP_RETENTION_FULL_LOCAL=30      # local full_local_*.tar.gz archives
BACKUP_RETENTION_META_LOCAL=30      # local cloud_metadata_*.tar.gz archives
BACKUP_RETENTION_META_CLOUD=90      # archives on Google Drive (via rclone)
BACKUP_RETENTION_DELETED=180        # per-date dirs under assetstore-deleted/

# Assetstore local mirror (rsync destination)
BACKUP_ASSETSTORE_MIRROR=/mnt/backup-mirror/assetstore
```

Also append these variables to the end of `.env.example` as documented defaults.

> `BACKUP_RETENTION_DAYS` (existing) is **deprecated** — replaced by
> `BACKUP_RETENTION_FULL_LOCAL`. Keep the fallback in `backup-cleanup.sh`
> for backwards compatibility: `RETENTION_FULL_LOCAL="${BACKUP_RETENTION_FULL_LOCAL:-${BACKUP_RETENTION_DAYS:-30}}"`.

---

## 5. `backup-dspace.sh` — Entry Point

Responsibilities: argument parsing, env loading, prerequisite check,
`ERR` trap, orchestration.

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
PROJECT_ROOT="$SCRIPT_DIR/.."
ENVIRONMENT_ARG=""          # FIX: was "${1:-}" — see §3.1
DRY_RUN=false

# --- Argument parsing (unchanged logic, bug fixed) ---
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --env)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: Missing value for --env" >&2; exit 1; }
      ENVIRONMENT_ARG="$1" ;;
    --env=*)
      ENVIRONMENT_ARG="${1#--env=}" ;;
    --dry-run)
      DRY_RUN=true ;;
    -h|--help)
      echo "Usage: $0 [--env dev|prod] [--dry-run]"
      exit 0 ;;
    dev|development|prod|production)
      ENVIRONMENT_ARG="$1" ;;
    *)
      echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done

# --- Env loading (UNCHANGED) ---
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/autonomous-env.sh"
load_autonomous_env "$PROJECT_ROOT" "$ENVIRONMENT_ARG"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/docker-runtime.sh"

# --- Critical variable check (UNCHANGED) ---
: "${VOL_ASSETSTORE_PATH:?Variable VOL_ASSETSTORE_PATH not set in env file}"
: "${BACKUP_RCLONE_REMOTE:?Variable BACKUP_RCLONE_REMOTE not set in env file}"
: "${DB_SERVICE_NAME:?Variable DB_SERVICE_NAME not set in env file}"
: "${BACKUP_ASSETSTORE_MIRROR:?Variable BACKUP_ASSETSTORE_MIRROR not set in env file}"

# --- Path setup ---
resolve_absolute_path() {
    local raw_path="$1"
    local path="$raw_path"
    local dir
    local suffix

    if [[ "$path" != /* ]]; then
        path="${PROJECT_ROOT}/${path}"
    fi

    dir="$(dirname "$path")"
    suffix="$(basename "$path")"
    while [[ ! -d "$dir" && "$dir" != "/" ]]; do
        suffix="$(basename "$dir")/${suffix}"
        dir="$(dirname "$dir")"
    done

    if [[ "$dir" == "/" ]]; then
        printf '/%s\n' "$suffix"
    else
        printf '%s/%s\n' "$(cd "$dir" &>/dev/null && pwd -P)" "$suffix"
    fi
}

init_backup_dir() {
    local dir="$1"
    local mode="0750"
    local owner_uid
    local owner_gid

    owner_uid="$(id -u)"
    owner_gid="$(id -g)"
    if [[ "$owner_uid" == "0" && -n "${SUDO_UID:-}" ]]; then
        owner_uid="$SUDO_UID"
        owner_gid="${SUDO_GID:-$owner_gid}"
    fi

    if [[ "$(id -u)" == "0" ]]; then
        install -d -m "$mode" -o "$owner_uid" -g "$owner_gid" "$dir"
        return 0
    fi

    if install -d -m "$mode" "$dir" 2>/dev/null; then
        return 0
    fi

    if command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
        sudo -n install -d -m "$mode" -o "$owner_uid" -g "$owner_gid" "$dir"
        return 0
    fi

    printf 'ERROR: Cannot create backup directory with required permissions: %s\n' "$dir" >&2
    printf '       Run once with a user that can create it, or configure passwordless sudo for install -d.\n' >&2
    exit 1
}

BACKUP_LOCAL_DIR_RAW="${BACKUP_LOCAL_DIR:-backups}"
BACKUP_DIR="$(resolve_absolute_path "$BACKUP_LOCAL_DIR_RAW")"
DATE=$(date +%Y-%m-%d_%H-%M)
if [[ "$DRY_RUN" != true ]]; then
    init_backup_dir "$BACKUP_DIR"
    BACKUP_DIR=$(cd "$BACKUP_DIR" &>/dev/null && pwd -P)
fi
LOG_FILE="${BACKUP_DIR}/backup_log.txt"

# --- Logging function (UNCHANGED) ---
log() {
    if [[ "$DRY_RUN" == true ]]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    else
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
    fi
}

# --- Source new lib modules ---
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/backup-metadata.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/backup-assetstore.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/backup-cleanup.sh"

# --- Prerequisite check ---
check_prerequisites() {
    local missing=()
    command -v rclone  &>/dev/null || missing+=("rclone")
    command -v rsync   &>/dev/null || missing+=("rsync")
    command -v sha256sum &>/dev/null || missing+=("sha256sum")

    if [[ ${#missing[@]} -gt 0 ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            log "WARNING: Missing required tools for real run: ${missing[*]}"
        else
            log "ERROR: Missing required tools: ${missing[*]}"
            exit 1
        fi
    fi

    # Disk space: warn if less than 10 GB free in BACKUP_DIR filesystem
    local free_kb
    free_kb=$(df --output=avail "$BACKUP_DIR" | tail -1)
    if (( free_kb < 10485760 )); then   # 10 GB in KB
        log "WARNING: Less than 10 GB free on backup filesystem (${free_kb} KB available)."
    fi
}

# --- ERR trap: remove partial artifacts ---
_partial_cleanup() {
    log "ERROR: Backup aborted. Removing partial artifacts."
    [[ -n "${SQL_DUMP:-}" ]] && rm -f "$SQL_DUMP"
    [[ -n "${ARCHIVE_CLOUD:-}" ]] && rm -f "$ARCHIVE_CLOUD" "${ARCHIVE_CLOUD}.sha256"
    [[ -n "${ARCHIVE_LOCAL:-}" ]] && rm -f "$ARCHIVE_LOCAL"
}
trap '_partial_cleanup' ERR

# --- Orchestration ---
log "=== Starting Backup Routine ==="

check_prerequisites

# Export shared variables consumed by lib modules
export BACKUP_DIR DATE LOG_FILE DRY_RUN PROJECT_ROOT
export SQL_DUMP="${BACKUP_DIR}/dspace_db_${DATE}.sql"
export ARCHIVE_CLOUD="${BACKUP_DIR}/cloud_metadata_${DATE}.tar.gz"
export ARCHIVE_LOCAL="${BACKUP_DIR}/full_local_${DATE}.tar.gz"
export ENV_ARCHIVE_FILE="env.${AUTONOMOUS_ENVIRONMENT}.enc"

backup_metadata      # lib/backup-metadata.sh
backup_assetstore    # lib/backup-assetstore.sh
backup_cleanup       # lib/backup-cleanup.sh

log "=== Backup Finished ==="
```

---

## 6. `lib/backup-metadata.sh` — Steps 1–3

Responsibilities: DB dump, cloud archive (with checksum), rclone upload
(with verification), local full archive.

```bash
#!/usr/bin/env bash
# Sourced by backup-dspace.sh — do not execute directly.
# Expects: BACKUP_DIR, DATE, LOG_FILE, DRY_RUN, PROJECT_ROOT,
#          SQL_DUMP, ARCHIVE_CLOUD, ARCHIVE_LOCAL, ENV_ARCHIVE_FILE
#          and all variables from env.<env>.enc

backup_metadata() {

    # --- STEP 1: DB dump ---
    log "[1/4] Dumping Database from service: $DB_SERVICE_NAME..."

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

    # --- STEP 2: Cloud archive (DB + configs + env) ---
    log "[2/4] Creating Cloud Archive (DB + Configs + Env)..."

    # Build include list explicitly — avoids fragile multi -C chaining
    local tar_sources=(
        --directory="$BACKUP_DIR"    "$(basename "$SQL_DUMP")"
        --directory="$PROJECT_ROOT"  "$ENV_ARCHIVE_FILE"
        --directory="$PROJECT_ROOT"  "dspace/config"
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

    # --- STEP 3: Upload to Google Drive + verify ---
    log "[3/4] Uploading to Google Drive ($BACKUP_RCLONE_REMOTE)..."

    local remote_folder="${BACKUP_RCLONE_REMOTE}:${BACKUP_RCLONE_FOLDER}"
    local remote_archive="${remote_folder}/$(basename "$ARCHIVE_CLOUD")"

    if [[ "$DRY_RUN" == true ]]; then
        log "[dry-run] rclone copy $ARCHIVE_CLOUD $remote_folder"
        log "[dry-run] rclone copy ${ARCHIVE_CLOUD}.sha256 $remote_folder"
        log "[dry-run] rclone check $ARCHIVE_CLOUD $remote_archive"
    elif rclone copy "$ARCHIVE_CLOUD" "$remote_folder" && \
            rclone copy "${ARCHIVE_CLOUD}.sha256" "$remote_folder"; then
        if rclone check "$ARCHIVE_CLOUD" "$remote_archive"; then
            log "Upload and verification SUCCESS."
        else
            log "WARNING: Upload completed but rclone check FAILED. Manual verification recommended."
        fi
    else
        log "ERROR: Upload FAILED. Check internet or rclone config."
        # Non-fatal: continue to local backup
    fi

    # --- STEP 4: Full local archive (DB + configs + env + assetstore) ---
    log "[4/4] Creating Full Local Archive (incl. Assetstore)..."

    if [[ "$DRY_RUN" == true ]]; then
        log "[dry-run] tar full local archive incl. assetstore -> $ARCHIVE_LOCAL"
    elif [[ -d "$VOL_ASSETSTORE_PATH" ]]; then
        local tar_full_sources=(
            --directory="$BACKUP_DIR"                            "$(basename "$SQL_DUMP")"
            --directory="$PROJECT_ROOT"                          "$ENV_ARCHIVE_FILE"
            --directory="$PROJECT_ROOT"                          "dspace/config"
            --directory="$(dirname "$VOL_ASSETSTORE_PATH")"      "$(basename "$VOL_ASSETSTORE_PATH")"
        )
        if tar -czf "$ARCHIVE_LOCAL" "${tar_full_sources[@]}"; then
            log "Full Local archive created: $(basename "$ARCHIVE_LOCAL")"
        else
            log "ERROR: Full local archiving failed!"
            exit 1
        fi
    else
        log "WARNING: Assetstore path ($VOL_ASSETSTORE_PATH) not found! Skipping assetstore in local archive."
    fi
}
```

---

## 7. `lib/backup-assetstore.sh` — Rsync Mirror

Responsibilities: rsync local mirror of assetstore, move deleted files into
a timestamped subdirectory.

```bash
#!/usr/bin/env bash
# Sourced by backup-dspace.sh — do not execute directly.
# Expects: BACKUP_DIR, DATE, LOG_FILE, DRY_RUN,
#          VOL_ASSETSTORE_PATH, BACKUP_ASSETSTORE_MIRROR

backup_assetstore() {

    log "[assetstore] Syncing Assetstore mirror..."

    local mirror_dir="${BACKUP_ASSETSTORE_MIRROR:?Variable BACKUP_ASSETSTORE_MIRROR not set in env file}"
    local deleted_dir="${BACKUP_DIR}/assetstore-deleted/${DATE}"

    if [[ "$DRY_RUN" == true ]]; then
        log "[dry-run] rsync --delete --backup --backup-dir=$deleted_dir \
$VOL_ASSETSTORE_PATH/ $mirror_dir/"
        return 0
    fi

    if [[ ! -d "$VOL_ASSETSTORE_PATH" ]]; then
        log "WARNING: Assetstore path ($VOL_ASSETSTORE_PATH) not found! Skipping mirror."
        return 0
    fi

    mkdir -p "$mirror_dir"
    mkdir -p "$deleted_dir"

    # --delete          removes files from mirror that no longer exist in source
    # --backup          instead of deleting, moves them to --backup-dir
    # --backup-dir      timestamped directory — preserves deletion history
    # --archive         preserves permissions, timestamps, symlinks
    # --checksum        compare by content, not just mtime/size
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

    # Remove timestamped deleted-dir if nothing was actually deleted during this run
    if [[ -d "$deleted_dir" ]] && [[ -z "$(ls -A "$deleted_dir")" ]]; then
        rmdir "$deleted_dir"
        log "[assetstore] No files deleted this run — removed empty deleted-dir."
    else
        log "[assetstore] Deleted files archived to: $deleted_dir"
    fi
}
```

---

## 8. `lib/backup-cleanup.sh` — Retention

Responsibilities: remove stale local metadata archives, stale deleted-files
dirs, stale cloud archives via rclone.

```bash
#!/usr/bin/env bash
# Sourced by backup-dspace.sh — do not execute directly.
# Expects: BACKUP_DIR, LOG_FILE, DRY_RUN, SQL_DUMP, ARCHIVE_CLOUD,
#          BACKUP_RETENTION_FULL_LOCAL, BACKUP_RETENTION_META_LOCAL,
#          BACKUP_RETENTION_META_CLOUD, BACKUP_RETENTION_DELETED,
#          BACKUP_RCLONE_REMOTE, BACKUP_RCLONE_FOLDER

backup_cleanup() {

    log "[cleanup] Starting cleanup..."

    # Backwards-compatible fallback for BACKUP_RETENTION_DAYS (deprecated)
    local retention_full_local="${BACKUP_RETENTION_FULL_LOCAL:-${BACKUP_RETENTION_DAYS:-30}}"
    local retention_meta_local="${BACKUP_RETENTION_META_LOCAL:-30}"
    local retention_meta_cloud="${BACKUP_RETENTION_META_CLOUD:-90}"
    local retention_deleted="${BACKUP_RETENTION_DELETED:-180}"

    # --- Remove raw SQL dump (already in archives) ---
    if [[ "$DRY_RUN" == true ]]; then
        log "[dry-run] rm -f $SQL_DUMP"
    else
        rm -f "$SQL_DUMP"
    fi

    log "[cleanup] Keeping local metadata archive: $(basename "$ARCHIVE_CLOUD")"

    # --- Local full archives: full_local_*.tar.gz ---
    log "[cleanup] Removing local full archives older than ${retention_full_local} days..."
    if [[ "$DRY_RUN" == true ]]; then
        log "[dry-run] find $BACKUP_DIR -name 'full_local_*.tar.gz' -mtime +${retention_full_local} -delete"
    else
        find "$BACKUP_DIR" \
            -name "full_local_*.tar.gz" \
            -mtime +"$retention_full_local" \
            -delete
    fi

    # --- Local metadata archives/checksums: cloud_metadata_*.tar.gz(.sha256) ---
    log "[cleanup] Removing local metadata archives older than ${retention_meta_local} days..."
    if [[ "$DRY_RUN" == true ]]; then
        log "[dry-run] find $BACKUP_DIR \\( -name 'cloud_metadata_*.tar.gz' -o -name 'cloud_metadata_*.tar.gz.sha256' \\) -mtime +${retention_meta_local} -delete"
    else
        find "$BACKUP_DIR" \
            \( -name "cloud_metadata_*.tar.gz" -o -name "cloud_metadata_*.tar.gz.sha256" \) \
            -mtime +"$retention_meta_local" \
            -delete
    fi

    # --- Deleted assetstore dirs: assetstore-deleted/YYYY-MM-DD_HH-MM ---
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

    # --- Cloud archives/checksums: delete via rclone ---
    log "[cleanup] Removing cloud archives older than ${retention_meta_cloud} days..."
    if [[ "$DRY_RUN" == true ]]; then
        log "[dry-run] rclone delete ${BACKUP_RCLONE_REMOTE}:${BACKUP_RCLONE_FOLDER} --include 'cloud_metadata_*.tar.gz' --include 'cloud_metadata_*.tar.gz.sha256' --exclude '*' --min-age ${retention_meta_cloud}d"
    else
        if rclone delete \
            "${BACKUP_RCLONE_REMOTE}:${BACKUP_RCLONE_FOLDER}" \
            --include "cloud_metadata_*.tar.gz" \
            --include "cloud_metadata_*.tar.gz.sha256" \
            --exclude "*" \
            --min-age "${retention_meta_cloud}d"; then
            log "[cleanup] Cloud old archives removed."
        else
            log "WARNING: rclone cloud cleanup failed. Check remote access."
        fi
    fi

    log "[cleanup] Done. Retention: full-local=${retention_full_local}d | \
meta-local=${retention_meta_local}d | meta-cloud=${retention_meta_cloud}d | deleted-assets=${retention_deleted}d"
}
```

---

## 9. Implementation Checklist for Agent

Execute steps in this exact order:

- [ ] **Fix** `backup-dspace.sh`: remove `ENVIRONMENT_ARG="${1:-}"` pre-loop assignment (§3.1)
- [ ] **Rewrite** `backup-dspace.sh` orchestration block (§5) — keep all existing sections before `# --- Source new lib modules ---` untouched
- [ ] **Create** `scripts/lib/backup-metadata.sh` (§6)
- [ ] **Create** `scripts/lib/backup-assetstore.sh` (§7)
- [ ] **Create** `scripts/lib/backup-cleanup.sh` (§8)
- [ ] **Add** new env variables to `env.dev.enc` and `env.prod.enc` (§4)
- [ ] **Append** the same new env variables to the end of `.env.example`
- [ ] **Verify** `set -euo pipefail` is present at the top of every new file
- [ ] **Verify** no new file directly calls `load_autonomous_env` or `source`s env/docker libs — only `backup-dspace.sh` does this
- [ ] **Smoke-test** with `--dry-run` flag on both `dev` and `prod` environments
- [ ] **Do not** modify `lib/autonomous-env.sh` or `lib/docker-runtime.sh`

---

## 10. Retention Summary

| Artifact | Storage | Retention |
|---|---|---|
| `full_local_*.tar.gz` (DB + config + assetstore) | Local disk | **BACKUP_RETENTION_FULL_LOCAL** |
| `cloud_metadata_*.tar.gz` + `.sha256` (DB + config + env) | Local disk | **BACKUP_RETENTION_META_LOCAL** |
| `cloud_metadata_*.tar.gz` (DB + config + env) | Google Drive | **90 days** |
| `assetstore-deleted/YYYY-MM-DD/` (deleted files) | Local disk | **180 days** |
| `assetstore` mirror | Local disk | Permanent (always current) |

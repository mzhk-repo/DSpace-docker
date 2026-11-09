# Runbook: scripts (DSpace Docker)

## Env-контракти

- CI/CD decrypt flow: shared workflow розшифровує `env.dev.enc` або `env.prod.enc` у тимчасовий файл і передає шлях через `ORCHESTRATOR_ENV_FILE`.
- Autonomous flow: cron/manual скрипти читають `SERVER_ENV` (`dev|prod`) або аргумент `--env dev|prod`, розшифровують `env.<env>.enc` у `/dev/shm` і очищають tmp-файл після завершення.
- Локальний dev fallback на `.env` дозволений тільки для deploy-adjacent скриптів, коли `ORCHESTRATOR_ENV_FILE` не передано.
- Для пошти `DSPACE_MAIL_USERNAME` є логіном SMTP AUTH, а `DSPACE_MAIL_FROM` — адресою відправника. `DSPACE_MAIL_FROM` має точно відповідати sender allowlist SMTP relay; якщо не заданий, використовується `DSPACE_MAIL_USERNAME` для сумісності.
- `DSPACE_USER_FORGOT_PASSWORD=true` enables password reset for local DSpace accounts; the default is `false`. This does not change the external OIDC provider's password policy.

## Категорія 1а: validation

### `scripts/verify-env.sh`

#### Бізнес-логіка
- Перевіряє, що `env.dev.enc` / `env.prod.enc` розшифровуються через SOPS.
- Порівнює набір ключів із `.env.example`.
- Не створює і не читає plaintext `.env`.

#### Manual execution
```bash
bash scripts/verify-env.sh --env dev
bash scripts/verify-env.sh --env prod
bash scripts/verify-env.sh --all
```

### `scripts/smoke-test.sh`

#### Бізнес-логіка
- Перевіряє UI/API/OAI/security headers/CORS/sitemap.
- Для dry-run готує контекст без мережевих HTTP-викликів.
- Env бере з `ORCHESTRATOR_ENV_FILE`; якщо його немає, визначає середовище через `--env`, `ENVIRONMENT_NAME` або `SERVER_ENV` і розшифровує `env.<env>.enc`.

#### Manual execution
```bash
bash scripts/smoke-test.sh --env dev --dry-run
bash scripts/smoke-test.sh --env dev --modules context,required_checks
```

## Категорія 1б: deploy-adjacent

### `scripts/upgrade-dspace-10.1-swarm.sh`

One-time **development or production** upgrade from DSpace 9 to 10.1 with PostgreSQL 15. Run on the manager that hosts the selected stack. The operator must stop all external writers and prevent concurrent CI/CD deployments until the upgrade and checks finish. The operator reported that backups are complete; the script does not create or validate them. The recovery point must cover the database, assetstore, Solr and configuration together.

The script validates the selected environment's version contract, secret name bases, database name and user, PostgreSQL, Solr and assetstore mounts, local services, image availability, and the existing search schema against the running Solr image. It stops UI and backend, stops Solr, saves `search/conf/schema.xml.before-dspace-10.1`, installs the 10.1 schema with passwordless `sudo`, and starts Solr 10.1. It then runs `database info`, one `database migrate ignored`, another `database info`, and `index-discovery -b` in a one-shot Swarm job using the backend's existing secrets, configuration and read-only assetstore. Finally it calls the selected environment's Swarm orchestrator, which performs the deployment directly. The UI image must already be published and accessible to the registry check; the backend and Solr 10.1 images must already exist locally.

Coordinate a deployment freeze and wait until running or queued deployments finish. A push to `dev` with deployment-relevant changes can trigger a dev deploy immediately. For example, from an authenticated GitHub CLI:

```bash
gh run list --workflow main.yml --status in_progress
gh run list --workflow main.yml --status queued
```

After confirming no deployment is running or queued, publish the UI image without pushing the branch. These commands require Docker access and existing GHCR login credentials for the repository owner:

```bash
cd /opt/Dspace/DSpace-docker
ui_image="$(bash scripts/ui-image-reference.sh)"
docker build -t "$ui_image" -f ui/Dockerfile ui
docker push "$ui_image"
```

Then, on the dev manager:

```bash
cd /opt/Dspace/DSpace-docker
docker pull dspace/dspace:dspace-10.1
docker pull dspace/dspace-solr:dspace-10.1
docker manifest inspect "$(bash scripts/ui-image-reference.sh)" >/dev/null
bash scripts/upgrade-dspace-10.1-swarm.sh --env dev --maintenance-confirmed
```

`--maintenance-confirmed` asserts that the backup is verified, external writers are stopped, and no deploy is running or can start concurrently. The script does not independently verify those conditions. It requires passwordless `sudo` for the schema backup and replacement; it does not pass credentials to `sudo`. A changed schema that differs semantically from the current image causes a stop for manual review. The script supports only the existing single-replica services on the local manager and refuses a previous attempt recorded in `.orchestrator-state/<stack>.upgrade-dspace-10.1/`.

On failure or interruption it attempts to stop backend and UI. Inspect the error, marker `status`, the migration job and service logs before recovery; the job may still be running after a timeout. Do not remove the marker or repeat migration blindly. Restoring the old image alone cannot undo a database migration; coordinated restore requires a separate operator decision. Verify backend/UI health, `database info`, search, PDFs, statistics, OAI and KDV end-to-end before resuming writers and ending the deployment freeze. The production path and full recovery procedure have not been exercised against a production Swarm stack.

If the script stopped before replacing the schema and before creating the migration job, `--resume-stopped` can continue the same attempt. It requires marker status `started`, stopped UI, backend and Solr, the original schema without a schema backup, and no migration job. It refuses later or ambiguous states:

```bash
bash scripts/upgrade-dspace-10.1-swarm.sh --env dev --maintenance-confirmed --resume-stopped
```

#### Production procedure

1. On the production manager, use the actual repository path if it differs from `/opt/Dspace/DSpace-docker`. Confirm the reviewed repository revision contains this script and the DSpace 10.1 submission form additions. Check `git status --short --branch` before updating the checkout and preserve local changes. Do not publish a GitHub release or allow another deployment during the upgrade: a published `v*` release triggers the production deploy workflow independently of this script.
2. Update the encrypted production contract using SOPS, setting **only** `DSPACE_REST_VER=dspace-10.1` and `DSPACE_SOLR_VER=dspace-10.1`; retain PostgreSQL 15 and other production values. The production contract previously contained 9.x tags. This is a separate operator action: the script does not modify `env.prod.enc`. Preserve the updated encrypted contract in the reviewed release revision so later CI deployments use the same versions. Pushing a change can trigger the dev workflow; inspect the changes and its deployment gate first.

   ```bash
   cd /opt/Dspace/DSpace-docker
   sops --input-type dotenv --output-type dotenv env.prod.enc
   bash scripts/verify-env.sh --env prod
   ```

3. Stop external writers, including Integrator jobs, and arrange the deployment freeze. On the **production manager**, with the confirmed backups available and no concurrent deployment, pull the two official images and check the patched UI manifest:

   ```bash
   cd /opt/Dspace/DSpace-docker
   docker pull dspace/dspace:dspace-10.1
   docker pull dspace/dspace-solr:dspace-10.1
   docker manifest inspect "$(bash scripts/ui-image-reference.sh)" >/dev/null
   ```

   The UI image must be published for the exact checked-out revision. If the production repository lives elsewhere, `cd` to its actual path. If any preflight check fails, stop and inspect the stated mismatch; do not bypass it.

   A `TLS handshake timeout` during manifest inspection is a registry connectivity failure and does not establish that the image is missing. Check DNS and HTTPS from the production manager:

   ```bash
   getent ahosts ghcr.io | head -4
   curl -sS -o /dev/null --connect-timeout 10 --max-time 20 -w 'HTTP %{http_code}\n' https://ghcr.io/v2/
   ```

   HTTP 401 from `/v2/` confirms an HTTPS response from the registry; it does not prove that the image manifest or its blobs can be fetched. Check registry access from Docker as well. The orchestrator checks the manifest again after migration, so resolve intermittent connectivity before starting the upgrade.

4. Run the preflight first. It creates and removes temporary containers to inspect image files, but does not change services, the database, Solr data or the upgrade marker. It cannot verify the backup contents or the deployment freeze:

   ```bash
   bash scripts/upgrade-dspace-10.1-swarm.sh --env prod --maintenance-confirmed --production-confirmed --preflight-only
   ```

   After `Preflight passed for prod`, start the production upgrade. This command changes the running production stack and migrates its database:

   ```bash
   bash scripts/upgrade-dspace-10.1-swarm.sh --env prod --maintenance-confirmed --production-confirmed
   ```

   For the narrowly defined pre-migration stopped state described above, use `--resume-stopped` after the other flags. For any later state, inspect the marker and migration job; do not repeat automatically.
5. Run the production smoke test and check the acceptance scenarios before resuming writers:

   ```bash
   bash scripts/smoke-test.sh --env prod --modules context,required_checks
   docker service ls --filter name=dspace_
   ```

   Also check migration status, search and PDF access, OAI, statistics, OIDC and a controlled Integrator workflow. A `1/1` replica count alone is not acceptance. After successful checks, publish the reviewed release revision through the normal process if a release is required; publishing it runs the production workflow again. Ensure that the release contains the updated encrypted contract.

### `scripts/deploy-orchestrator-swarm.sh`

#### Бізнес-логіка
- Головний Swarm orchestrator для CI/CD.
- Порядок фаз: validation -> deploy-adjacent -> `docker compose config` -> `docker stack deploy` -> post-deploy.
- Запускає `verify-env.sh`, `smoke-test.sh --dry-run`, `init-volumes.sh`, `setup-configs.sh --no-restart`, `bootstrap-admin.sh --no-restart`.
- Якщо backend config змінився або admin створений вперше, виконує `docker service update --force ${STACK_NAME}_dspace`.
- Якщо згенерований stack manifest не змінився, пропускає `docker stack deploy` за checksum у `.orchestrator-state/${STACK_NAME}.stack.sha256`.
- Для примусового redeploy можна передати `ORCHESTRATOR_FORCE_DEPLOY=true`.

#### Manual execution
```bash
ENV_TMP="$(mktemp /dev/shm/dspace-env-XXXXXX)"
chmod 600 "${ENV_TMP}"
sops --decrypt --input-type dotenv --output-type dotenv env.dev.enc > "${ENV_TMP}"

ORCHESTRATOR_MODE=swarm \
ENVIRONMENT_NAME=development \
STACK_NAME=dspace \
ORCHESTRATOR_ENV_FILE="${ENV_TMP}" \
bash scripts/deploy-orchestrator-swarm.sh
```

#### Примусовий redeploy, якщо потрібно оновити live stack попри незмінний manifest:
```bash
ORCHESTRATOR_FORCE_DEPLOY=true \
ORCHESTRATOR_MODE=swarm \
ENVIRONMENT_NAME=development \
STACK_NAME=dspace \
ORCHESTRATOR_ENV_FILE="${ENV_TMP}" \
bash scripts/deploy-orchestrator-swarm.sh

shred -u "${ENV_TMP}" 2>/dev/null || rm -f "${ENV_TMP}"
```

### `scripts/init-volumes.sh`

#### Бізнес-логіка
- Створює bind-mount директорії для PostgreSQL, Solr, assetstore, exports, logs та `BACKUP_LOCAL_DIR`.
- Виставляє ownership/permissions через ephemeral Docker container.
- Для `BACKUP_LOCAL_DIR` виставляє ownership на `BACKUP_UID:BACKUP_GID` з fallback на поточного користувача, який запускає `init-volumes.sh`.
- Ідемпотентний: `mkdir -p`, повторне застосування permissions без дублювання.

#### Manual execution
```bash
ENV_TMP="$(mktemp /dev/shm/dspace-env-XXXXXX)"
chmod 600 "${ENV_TMP}"
sops --decrypt --input-type dotenv --output-type dotenv env.dev.enc > "${ENV_TMP}"
ORCHESTRATOR_ENV_FILE="${ENV_TMP}" bash scripts/init-volumes.sh --dry-run
shred -u "${ENV_TMP}" 2>/dev/null || rm -f "${ENV_TMP}"
```

### `scripts/setup-configs.sh`

#### Бізнес-логіка
- Wrapper для `patch-local.cfg.sh`, `patch-config.yml.sh`, `patch-submission-forms.sh`.
- У CI запускається з `--no-restart`, щоб restart контролював orchestrator.

#### Manual execution
```bash
ORCHESTRATOR_ENV_FILE=/dev/shm/dspace-env bash scripts/setup-configs.sh --no-restart
```

### `scripts/patch-local.cfg.sh`

#### Бізнес-логіка
- Модульно синхронізує `dspace/config/local.cfg`.
- Якщо backend config змінився або виконувався `db_rotation`, може поставити restart flag для orchestrator.

#### Manual execution
```bash
ORCHESTRATOR_ENV_FILE=/dev/shm/dspace-env bash scripts/patch-local.cfg.sh --dry-run --no-restart
ORCHESTRATOR_ENV_FILE=/dev/shm/dspace-env bash scripts/patch-local.cfg.sh --list-modules
```

### `scripts/patch-config.yml.sh`

#### Бізнес-логіка
- Модульно генерує `ui-config/config.yml` для Angular UI.
- Підтримує `--dry-run`, `--modules`, `--no-restart`.

#### Manual execution
```bash
ORCHESTRATOR_ENV_FILE=/dev/shm/dspace-env bash scripts/patch-config.yml.sh --dry-run --no-restart
ORCHESTRATOR_ENV_FILE=/dev/shm/dspace-env bash scripts/patch-config.yml.sh --list-modules
```

### `scripts/patch-submission-forms.sh`

#### Бізнес-логіка
- Забезпечує `dspace/config/submission-forms.xml`.
- Додає українську мову до `common_iso_languages`, якщо її ще немає.
- For `DSPACE_REST_VER=dspace-10.*`, adds missing `owner` and `datasetStep` forms from the versioned DSpace 10.1 additions file, preserving existing forms. A backend restart is required to load a changed bind-mounted file.
- Ставить backend restart flag, якщо файл створено або змінено.

#### Manual execution
```bash
ORCHESTRATOR_ENV_FILE=/dev/shm/dspace-env bash scripts/patch-submission-forms.sh
```

### `scripts/bootstrap-admin.sh`

#### Бізнес-логіка
- Post-deploy hook для створення DSpace admin.
- Swarm-aware: знаходить running task контейнер сервісу `${STACK_NAME}_dspace`.
- Ідемпотентний: якщо admin email уже існує, завершується без змін.
- Ставить admin-created flag тільки після фактичного створення нового admin.

#### Manual execution
```bash
ORCHESTRATOR_ENV_FILE=/dev/shm/dspace-env STACK_NAME=dspace bash scripts/bootstrap-admin.sh --no-restart
```

## Категорія 2: autonomous

### `scripts/lib/autonomous-env.sh`

#### Бізнес-логіка
- Спільний helper для cron/manual скриптів.
- Визначає env через `SERVER_ENV` або `--env dev|prod`.
- Розшифровує `env.<env>.enc` у `/dev/shm`, завантажує dotenv без shell-виконання значень і очищає tmp-файл.

#### Manual execution
```bash
bash -lc 'source scripts/lib/autonomous-env.sh; load_autonomous_env "$PWD" dev; echo "$DSPACE_HOSTNAME"'
```

### `scripts/backup-dspace.sh`

#### Бізнес-логіка
- Створює SQL dump, metadata cloud archive з checksum та full local archive з assetstore.
- Архівує encrypted `env.<env>.enc`, а не plaintext `.env`.
- Завантажує cloud archive/checksum через `rclone` і перевіряє upload через `rclone check`.
- Синхронізує локальне дзеркало assetstore через `rsync`, зберігаючи видалені файли в `assetstore-deleted/${DATE}`.
- Зберігає metadata archives/checksums локально в `BACKUP_LOCAL_DIR` і чистить `full_local_*`, локальні `cloud_metadata_*` та `assetstore-deleted/*` за окремими retention-змінними.
- Публікує textfile metrics `dspace_backup_*` у `NODE_EXPORTER_TEXTFILE_DIR`; `--dry-run` не оновлює freshness-метрики.
- Очікує, що `BACKUP_LOCAL_DIR` підготовлено через `scripts/init-volumes.sh`; backup-скрипт має fallback-ініціалізацію, але cron-сценарій не повинен залежати від passwordless sudo.

#### Manual execution
```bash
bash scripts/backup-dspace.sh --env dev --dry-run
bash scripts/backup-dspace.sh --env prod --dry-run
SERVER_ENV=dev bash scripts/backup-dspace.sh
SERVER_ENV=prod bash scripts/backup-dspace.sh
```

### `scripts/test-restore.sh`

#### Бізнес-логіка
- Smoke restore: бере найновіший `cloud_metadata_*.tar.gz` або `full_local_*.tar.gz` з `BACKUP_LOCAL_DIR`, якщо archive path не передано.
- Розпаковує SQL dump у тимчасовий каталог і імпортує його в тимчасовий PostgreSQL container.
- Перевіряє, що після імпорту є таблиці, і публікує textfile metrics `dspace_restore_smoke_*`.
- `--dry-run` не запускає контейнер і не оновлює freshness-метрики.

#### Manual execution
```bash
SERVER_ENV=prod bash scripts/test-restore.sh
bash scripts/test-restore.sh --env prod /data/backup/dspace/cloud_metadata_YYYY-MM-DD_HH-MM.tar.gz
bash scripts/test-restore.sh --env prod --dry-run
```

### `scripts/cleanup-assetstore-orphans.sh`

#### Бізнес-логіка
- Запускає штатний DSpace CLI cleanup: `/dspace/bin/dspace cleanup --verbose`.
- Видаляє orphan/deleted bitstreams з assetstore через DSpace storage layer, без власного SQL або ручного filesystem-cleanup.
- Swarm-aware: виконує команду в сервісі `dspace` через `scripts/lib/docker-runtime.sh`.
- `--dry-run` тільки показує команду, не змінюючи assetstore.

#### Manual execution
```bash
bash scripts/cleanup-assetstore-orphans.sh --env dev --dry-run
bash scripts/cleanup-assetstore-orphans.sh --env prod --dry-run
SERVER_ENV=prod bash scripts/cleanup-assetstore-orphans.sh
```

### `scripts/generate-item-thumbnail.sh`

#### Бізнес-логіка
- Генерує thumbnail першої сторінки PDF для одного item або для всіх items через штатний `PDFBox JPEG Thumbnail` media filter.
- Item передається як handle або UUID; результат зберігається у стандартному bundle `THUMBNAIL`.
- Без `--yes` скрипт вимагає інтерактивне підтвердження. Наявні generated thumbnails не перегенеровуються, бо filter запускається без `-f`.
- Режим `--all` не потребує `--yes` і призначений для unattended запуску з systemd timer. Якщо нових кандидатів немає, запуск завершується успішно.
- `--dry-run` тільки показує команду та не звертається до DSpace runtime.

#### Manual execution
```bash
bash scripts/generate-item-thumbnail.sh --env dev --item 123456789/42 --dry-run
bash scripts/generate-item-thumbnail.sh --env dev --item 123456789/42
bash scripts/generate-item-thumbnail.sh --env prod --item 00000000-0000-4000-8000-000000000000 --yes
bash scripts/generate-item-thumbnail.sh --env prod --all
```

### `scripts/restore-backup.sh`

#### Бізнес-логіка
- Disaster recovery restore: зупиняє stack, очищає PostgreSQL/Solr/assetstore, відновлює DB/files і запускає reindex.
- Руйнівний сценарій із подвійним ручним підтвердженням.
- Міняє тільки env-loading контракт; restore-логіка лишається окремо контрольованою.

#### Manual execution
```bash
bash scripts/restore-backup.sh --help
sudo SERVER_ENV=prod bash scripts/restore-backup.sh /srv/backups/full_local_YYYY-MM-DD_HH-MM.tar.gz
sudo bash scripts/restore-backup.sh --env prod /srv/backups/full_local_YYYY-MM-DD_HH-MM.tar.gz
```

### `scripts/run-maintenance.sh`

#### Бізнес-логіка
- Запускає DSpace maintenance: `filter-media`, `index-discovery`, `oai import`.
- Після maintenance розмонтовує GoogleDrive/SMB, завершує `rclone` і виконує `sudo poweroff`.
- Призначений для cron/manual сценаріїв.

#### Manual execution
```bash
SERVER_ENV=dev bash scripts/run-maintenance.sh
bash scripts/run-maintenance.sh --env prod
```

### `scripts/sync-user-groups.sh`

#### Бізнес-логіка
- Синхронізує користувачів із доменом `OIDC_DOMAIN` у DSpace group `OIDC_LOGIN_GROUP_UUID`.
- SQL має `NOT EXISTS`, тому повторний запуск не дублює зв'язки.

#### Manual execution
```bash
SERVER_ENV=dev bash scripts/sync-user-groups.sh
bash scripts/sync-user-groups.sh --env prod
```

## Runtime/out-of-scope

### `scripts/dspace-start.sh`

#### Бізнес-логіка
- Runtime command backend-контейнера.
- Мапить secret/env aliases, чекає DB з timeout, запускає `dspace database migrate`, потім REST API.
- Міграції DSpace ідемпотентні; за потреби можна вимкнути через `DSPACE_SKIP_DB_MIGRATIONS=true`.

#### Manual execution
```bash
docker exec -it <dspace-container> /opt/dspace/scripts/dspace-start.sh
```

### `scripts/entrypoint.sh`

#### Бізнес-логіка
- Docker ENTRYPOINT: експортує файли з `/run/secrets/*` як env-змінні та виконує команду контейнера.

#### Manual execution
```bash
docker run --rm <image> /opt/dspace/scripts/entrypoint.sh env
```

### `scripts/deploy-orchestrator.sh`

#### Бізнес-логіка
- Legacy compose orchestrator.
- Нові CI/CD інтеграції йдуть через `deploy-orchestrator-swarm.sh`.

#### Manual execution
```bash
bash scripts/deploy-orchestrator.sh
```

### `scripts/validate_sops_encrypted.py`

#### Бізнес-логіка
- Guard script для перевірки, що env-файли справді SOPS-encrypted.

#### Manual execution
```bash
python3 scripts/validate_sops_encrypted.py env.dev.enc env.prod.enc
```

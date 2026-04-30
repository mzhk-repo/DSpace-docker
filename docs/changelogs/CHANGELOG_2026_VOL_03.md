# CHANGELOG 2026 VOL 03

## Анотація тому

- Контекст: новий том після досягнення soft limit у `VOL_02`.
- Зміст: інкрементальні інфраструктурні зміни роутингу/безпеки та операційні перевірки.
- Ключові напрямки: IaC через `docker-compose.yml` + валідація compose-конфігурації.

## [2026-04-08] Traefik routing для bitstream download — окремий router redirect

### Зроблено
- Оновлено `docker-compose.yml`:
  - `dspace-api` router повернуто до чіткого API-matching лише на `PathPrefix(/server)`.
  - Прибрано middleware `dspace-bitstreams-rewrite` (rewrite для `/bitstreams/...`).
  - Додано окремий Traefik router `dspace-bitstreams` з правилом `Host(${DSPACE_HOSTNAME}) && PathPrefix(/bitstreams/)`.
  - Для `dspace-bitstreams` застосовано `service=noop@internal` + middleware `dspace-ui-bitstreams-redirect`.
  - Розширено `redirectregex` для bitstreams:
    - підтримка optional filename segment після `/download`;
    - підтримка query string;
    - редірект на `/server/api/core/bitstreams/<uuid>/content`.

### Перевірено
- `git status --short` перед змінами: зафіксовано наявні локальні зміни в робочому дереві.
- `docker compose ps` перед змінами: стек у цій сесії не запущений.
- `docker compose config` після змін: `OK` (конфіг валідний).

### Data/impact
- Зміни лише в IaC-конфігурації Traefik labels (`docker-compose.yml`).
- Змін у БД/Solr/assetstore немає.

## [2026-04-08] Swarm hotfix — bitstream download через backend rewrite (без залежності від browser refresh)

### Контекст
- У production використовується `docker stack` (Swarm), тому перевірка через `docker compose ps` не відображала реальний стан сервісів.
- Симптом: ручний refresh на `/bitstreams/.../download` працював, але перехід із UI був нестабільним у сценарії SPA-навігації.

### Зроблено
- Скориговано Traefik labels у `docker-compose.yml` під схему backend rewrite:
  - `dspace-api` router знову обробляє `PathPrefix(/server)` + `PathPrefix(/bitstreams/)`;
  - додано middleware `dspace-bitstreams-rewrite@docker`;
  - `replacepathregex` мапить `/bitstreams/<uuid>/download` (з optional filename segment) на `/server/api/core/bitstreams/<uuid>/content`.
- Прибрано окремий UI redirect-router для bitstreams, щоб уникнути залежності від top-level redirect у SPA-сценаріях.
- Застосовано зміни в live swarm:
  - згенеровано merged manifest;
  - виконано `docker stack deploy -c /tmp/dspace-stack-swarm.yml dspace`.

### Перевірено
- `docker service ls` після rollout:
  - `dspace_dspacedb` `1/1`,
  - `dspace_dspacesolr` `1/1`,
  - `dspace_dspace-angular` `1/1`,
  - `dspace_dspace` відновлено до `1/1` після оновлення.
- Live labels:
  - `dspace_dspace` містить `dspace-bitstreams-rewrite` та rule з `PathPrefix(/bitstreams/)`;
  - `dspace_dspace-angular` містить тільки `dspace-ui` router без bitstream redirect labels.
- Origin перевірка (без Cloudflare, через `127.0.0.1:8080` + `Host`):
  - `GET /bitstreams/7c627234-2fa2-4f9e-8515-01c8191eb83c/download` -> `HTTP/1.1 200 OK`.
- Traefik access log:
  - зафіксовано запит `GET /bitstreams/.../download` зі статусом `200`, обробник `dspace-api@docker` (request id `4781`).

### Data/impact
- Змін у БД/Solr/assetstore немає.
- Зміни застосовані на ingress/routing рівні (Traefik labels у Swarm).

## [2026-04-08] UI hotfix — bitstream click обходить SPA-router без залежності від Matomo

### Root cause
- У `.env` було `DSPACE_MATOMO_ENABLED=true`, тоді як `matomo.js` фактично недоступний.
- У DSpace Angular сторінка `/bitstreams/:id/download` перед `hardRedirect` проходить через Matomo-гілку; при увімкненому Matomo і недоступному tracker-flow перехід може зависати на `Now downloading...` без фактичного download request.
- Це пояснює симптом: URL змінюється, але повний перехід/завантаження не відбувається до ручного refresh.

### Зроблено
- Встановлено `.env`: `DSPACE_MATOMO_ENABLED=false` як актуальний IaC-стан для середовища без розгорнутого Matomo.
- Прибрано експериментальний frontend workaround через custom JS asset і додаткові bind mounts у `dspace-angular`.
- `ui-config/config.yml` повернуто на штатний pipeline `matomo_context,render_config`, але без Matomo headTags.

### Перевірено
- У live UI до фіксу `/bitstreams/.../download` відкривав сторінку `Now downloading ...` без фактичного redirect при client-side переході.
- У вихідному коді DSpace Angular підтверджено, що download route залежить від `isMatomoEnabled$()` і `appendVisitorId(fileLink)` перед `hardRedirect`.
- Поточний env-стан синхронізовано з фактичним станом інфраструктури: Matomo контейнер не розгорнутий, отже frontend tracker вимкнено.

### Data/impact
- Змін у БД/Solr/assetstore немає.
- Зміни обмежені frontend config/env та rollback тимчасового workaround.

## [2026-04-14] Swarm hotfix — DSpace payload secret sourcing виправлено для shell-сумісного `.env`

### Контекст
- Після переходу на `SOPS + age` DSpace у Swarm підхоплював `env.dev.enc` payload через построковий `export "$$line"` з `/run/secrets/app_env_payload`.
- Такий підхід крихкий для реального `.env` формату: quoted values, shell-коментарі та інші shell-сумісні конструкції можуть потрапляти в процес некоректно, що дає runtime-розсинхрон env і симптоми рівня `HTTP 500` на UI/API.

### Зроблено
- У `docker-compose.swarm.yml` для `dspacedb`, `dspace`, `dspace-angular` замінено построковий export payload на shell-safe sourcing:
  - `set -a`
  - `. /run/secrets/app_env_payload`
  - `set +a`
- Публічний контракт secret не змінювався: як і раніше використовується `app_env_payload` (`dspace_app_env_payload_dev_v1` за замовчуванням).

### Перевірено
- `docker compose -f docker-compose.yml -f docker-compose.swarm.yml config` має залишитися валідним після зміни wrapper.
- Зміна не торкається schema compose, тільки runtime способу імпорту env payload у контейнерах.

### Data/impact
- Змін у БД/Solr/assetstore немає.
- Очікуваний ефект: quoted/env-driven значення з `env.dev.enc` доходять до процесів DSpace/Angular/Postgres так само, як у звичайному shell `. envfile` сценарії.

## [2026-04-14] Regression fix — відкат від shell-source до безпечного dotenv-парсера в Swarm entrypoint

### Контекст
- Після hotfix із `set -a; . /run/secrets/app_env_payload; set +a` сервіси стеку `dspace` не стартували (`exit 127`).
- У логах `dspace_dspacedb`/`dspace_dspace` підтверджено помилку: `/run/secrets/app_env_payload: POST,: not found`.
- Причина: у payload є dotenv-рядки з некавычованими значеннями з пробілами після коми (наприклад `CORS_ALLOWED_METHODS=GET, POST, ...`), що ламає shell-source режим.

### Зроблено
- У `docker-compose.swarm.yml` для `dspacedb`, `dspace`, `dspace-angular` замінено shell-source на безпечний dotenv-парсер:
  - построкове читання `key=value`;
  - ігнорування порожніх рядків і коментарів;
  - trim для `key/value`;
  - зняття зовнішніх `'`/`"`;
  - `export "$key=$value"` без виконання значень як shell-команд.

### Перевірено
- Локальний тест shell-source відтворює проблему на `env.dev.enc`: `POST,: not found`.
- Після переходу на парсер `docker compose -f docker-compose.yml -f docker-compose.swarm.yml config` залишається валідним.

### Data/impact
- Змін у БД/Solr/assetstore немає.
- Відновлено сумісність зі стандартним dotenv payload (включно зі значеннями з комами/пробілами).

## [2026-04-14] Payload env simplification — `CORS_ALLOWED_METHODS` прибрано з env, wrapper повернуто до простого shell source

### Контекст
- Потрібно повернути `docker-compose.swarm.yml` до простого режиму `set -a; . /run/secrets/app_env_payload; set +a`.
- Для цього проблемні значення, що ламають shell-source, мають бути прибрані/нормалізовані в payload.

### Зроблено
- У `scripts/lib/patch-local/modules.sh` `rest.cors.allowed-methods` зафіксовано як кодовий константний рядок:
  - `GET, POST, PUT, DELETE, PATCH, OPTIONS, HEAD`.
- Із `example.env` видалено `CORS_ALLOWED_METHODS`.
- У `docker-compose.swarm.yml` для `dspacedb`, `dspace`, `dspace-angular` повернуто простий wrapper:
  - `set -a`
  - `. /run/secrets/app_env_payload`
  - `set +a`
- У `env.dev.enc` та `env.prod.enc`:
  - видалено `CORS_ALLOWED_METHODS`;
  - нормалізовано `AUTH_METHODS` (без пробілу після коми), щоб уникнути `exit 127` у shell-source.

### Перевірено
- `sops -d env.dev.enc` і `sops -d env.prod.enc` успішні.
- У розшифрованих env відсутній `CORS_ALLOWED_METHODS`.
- Тест `set -a; . <decrypted-env>; set +a` для `env.dev.enc` проходить (`SHELL_SOURCE_OK`).
- `docker compose -f docker-compose.yml -f docker-compose.swarm.yml config` -> `CONFIG_OK`.

### Data/impact
- Змін у БД/Solr/assetstore немає.
- Конфіг CORS methods тепер керується кодом patch-скрипта, а не env payload.

## [2026-04-14] Runtime rollout — DSpace переведено на `dspace_app_env_payload_dev_v2`

### Контекст
- Після локального виправлення `env.dev.enc` звичайний `docker stack deploy` не міг оновити runtime payload, бо Docker Secret `dspace_app_env_payload_dev_v1` immutable.
- Для фактичного застосування нового dotenv payload потрібен новий versioned secret name.

### Зроблено
- Створено новий Docker Secret: `dspace_app_env_payload_dev_v2` з поточного `env.dev.enc`.
- Виконано redeploy стеку `dspace` з `DSPACE_APP_ENV_PAYLOAD_SECRET_NAME=dspace_app_env_payload_dev_v2`.

### Перевірено
- `docker service ls --filter label=com.docker.stack.namespace=dspace`:
  - `dspace_dspacedb` -> `1/1`
  - `dspace_dspacesolr` -> `1/1`
  - `dspace_dspace` -> `1/1`
  - `dspace_dspace-angular` -> `1/1`
- `docker service logs --since 2m dspace_dspacedb` підтверджує `database system is ready to accept connections`.
- `docker service logs --since 2m dspace_dspace` підтверджує `Running DB migrations...`, `Done.`, `Starting DSpace REST...` і старт Spring Boot.
- Зовнішня HTTP-перевірка `https://repo.pinokew.buzz/` -> `HTTP 200`.

### Data/impact
- Новий runtime payload застосовано без зміни БД/Solr/assetstore даних.
- Старі rejected/failed task лишилися в історії Swarm як артефакт попередніх невдалих стартів, але поточні task у стані `Running`.

## [2026-04-16] Security hardening — `POSTGRES_PASSWORD` винесено з `docker inspect` у Swarm secret files

### Контекст
- У merged compose/swarm конфігурації `POSTGRES_PASSWORD` був присутній у `Config.Env` для `dspace_dspacedb` і `dspace_dspace`.
- Це робило секрет видимим через `docker inspect`.

### Зроблено
- Оновлено `docker-compose.swarm.yml`:
  - додано external secret `postgres_password` з name `${DSPACE_POSTGRES_PASSWORD_SECRET_NAME:-dspace_postgres_password_dev_v1}`;
  - для `dspacedb` увімкнено file-based pattern: `POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password`;
  - для `dspace` додано mount цього ж secret як `target: POSTGRES_PASSWORD` (підхоплення через `scripts/entrypoint.sh`);
  - у wrapper entrypoint для `dspacedb` і `dspace` додано фільтр `POSTGRES_PASSWORD=*` при імпорті `app_env_payload`, щоб уникнути повернення plaintext-пароля через payload.
- Оновлено Ansible inventory mapping:
  - `/opt/Ansible/ansible/inventories/dev/group_vars/all/swarm_sops_payloads.yml` доповнено secret `dspace_postgres_password_dev_v1` з `dotenv_key: POSTGRES_PASSWORD`.
- Застосовано `ansible-playbook ... --tags secrets -l dev-manager-01` і redeploy `docker stack deploy` для стеку `dspace`.

### Перевірено
- `docker secret ls` містить `dspace_postgres_password_dev_v1`.
- `docker service inspect dspace_dspacedb` показує `POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password` і mount secret `postgres_password`.
- `docker service inspect dspace_dspace` містить mount secret з `target: POSTGRES_PASSWORD`; у `Env` відсутній `POSTGRES_PASSWORD`.
- `docker inspect` running контейнерів `dspace_dspacedb` і `dspace_dspace` не показує plaintext `POSTGRES_PASSWORD=`.
- Після rollout сервіси стеку `dspace` у стані `1/1`.

### Data/impact
- Змін у даних БД/Solr/assetstore немає.
- Зміна стосується безпечного способу доставки DB password у runtime (`file secrets` замість `Config.Env`).

## [2026-04-24] Scripts refactor — Swarm + SOPS env flow для DSpace

### Контекст
- Репозиторій переводиться на єдиний `dev/prod` flow через `env.dev.enc` / `env.prod.enc`.
- CI/CD передає розшифрований env через `ORCHESTRATOR_ENV_FILE`, а автономні cron/manual скрипти мають визначати середовище через `SERVER_ENV` або `--env dev|prod`.

### Зроблено
- Оновлено `scripts/deploy-orchestrator-swarm.sh`:
  - додано фази `validation -> deploy-adjacent -> docker compose config -> docker stack deploy -> post-deploy`;
  - підключено `verify-env.sh`, `smoke-test.sh --dry-run`, `init-volumes.sh`, `setup-configs.sh --no-restart`, `bootstrap-admin.sh --no-restart`;
  - додано умовний restart backend через `docker service update --force ${STACK_NAME}_dspace`, якщо змінився backend config або вперше створено admin.
- Оновлено validation/deploy-adjacent скрипти:
  - `verify-env.sh` перевіряє `env.*.enc` проти `.env.example`;
  - `smoke-test.sh` вміє читати env із `ORCHESTRATOR_ENV_FILE` або `env.<env>.enc`;
  - `init-volumes.sh`, `patch-local.cfg.sh`, `patch-config.yml.sh`, `patch-submission-forms.sh` переведено на `ORCHESTRATOR_ENV_FILE` з fallback на `.env` тільки для локального dev;
  - `setup-configs.sh` отримав `--no-restart`.
- Оновлено runtime/post-deploy:
  - `bootstrap-admin.sh` став Swarm-aware, ідемпотентно завершується якщо admin уже існує, і ставить flag тільки після фактичного створення admin;
  - `dspace-start.sh` отримав bounded DB wait і зберіг ідемпотентний запуск DB migrations.
- Оновлено автономні скрипти Категорії 2:
  - додано `scripts/lib/autonomous-env.sh`;
  - `backup-dspace.sh`, `restore-backup.sh`, `run-maintenance.sh`, `sync-user-groups.sh` читають `env.<env>.enc` через SOPS-розшифровку в `/dev/shm`;
  - додано підтримку `--env dev|prod` / `SERVER_ENV`;
  - `backup-dspace.sh` архівує encrypted env-файл (`env.<env>.enc`) замість plaintext `.env`.

### Перевірено
- `bash -n` для змінених shell-скриптів — OK.
- `shellcheck` для змінених shell-скриптів — OK.
- `verify-env.sh --all` перевіряє `env.dev.enc` і `env.prod.enc`.
- `smoke-test.sh --dry-run --modules context` читає hostname з env.
- `init-volumes.sh --dry-run`, `patch-local.cfg.sh --dry-run`, `patch-config.yml.sh --dry-run` працюють з `ORCHESTRATOR_ENV_FILE`.
- `bootstrap-admin.sh --no-restart` на live-контейнері підтвердив: admin уже існує, нового користувача не створено.
- `autonomous-env.sh` успішно розшифровує `env.dev.enc` і `env.prod.enc` у `/dev/shm` та завантажує dotenv без shell-виконання значень.

### Data/impact
- Реальний `docker stack deploy`, `docker service update --force`, backup/restore/maintenance destructive flows не запускались.
- Змін у даних БД/Solr/assetstore немає.

## [2026-04-24] Scripts runbook + live Swarm deploy validation

### Зроблено
- Повністю перезаписано `docs/scripts_runbook.md` під DSpace Docker:
  - описано env-контракти `ORCHESTRATOR_ENV_FILE`, `SERVER_ENV`, `--env dev|prod`;
  - задокументовано validation, deploy-adjacent, autonomous та runtime/out-of-scope скрипти;
  - додано приклади ручного запуску для CI, cron і DR сценаріїв.
- Під час live deploy test виявлено й виправлено edge case у `scripts/bootstrap-admin.sh`:
  - Swarm rolling update може зупинити task-контейнер після того, як hook уже зберіг його id;
  - `wait_for_dspace_cli_ready` тепер на кожній спробі повторно знаходить актуальний running task контейнер сервісу `${STACK_NAME}_dspace`.
- Виправлено restart-on-change trigger у `scripts/patch-local.cfg.sh`:
  - раніше повний запуск завжди ставив backend restart flag через наявність модуля `db_rotation`;
  - тепер restart flag ставиться тільки якщо checksum `dspace/config/local.cfg` реально змінився.
- Додано manifest checksum guard у `scripts/deploy-orchestrator-swarm.sh`:
  - checksum зберігається у `.orchestrator-state/${STACK_NAME}.stack.sha256`;
  - якщо manifest не змінився, `docker stack deploy` пропускається;
  - для примусового redeploy доступний `ORCHESTRATOR_FORCE_DEPLOY=true`.

### Перевірено
- `bash -n scripts/deploy-orchestrator-swarm.sh scripts/*.sh scripts/lib/*.sh scripts/lib/patch-local/*.sh scripts/lib/patch-config/*.sh scripts/lib/smoke-test/*.sh` — OK.
- Live deploy test:
  - `ORCHESTRATOR_MODE=swarm ENVIRONMENT_NAME=development STACK_NAME=dspace ORCHESTRATOR_ENV_FILE=<decrypted env.dev.enc> bash scripts/deploy-orchestrator-swarm.sh`.
- Перший deploy-прогін:
  - `docker stack deploy` виконався;
  - post-deploy hook впав на старому stopped task id, що підтвердило rolling-update race.
- Після fix:
  - повторний deploy-прогін завершився `Swarm deploy completed`;
  - `bootstrap-admin.sh` підтвердив, що admin уже існує, нового admin не створено;
  - restart-on-change виконав `docker service update --force dspace_dspace`;
  - `dspace_dspace` converged.
- Після виправлення no-change trigger:
  - повторний `patch-local.cfg.sh --no-restart` з тим самим `env.dev.enc` не створює restart flag (`NO_FLAG`).
- Після додавання manifest checksum guard:
  - повторний повний no-change запуск `scripts/deploy-orchestrator-swarm.sh` пропустив `docker stack deploy`;
  - post-deploy `bootstrap-admin.sh` підтвердив, що admin уже існує;
  - orchestrator завершився з `Backend restart not required`;
  - backend task id не змінився (`sohfdiqlz3r41msyv94kmkvxi` залишився running).
- Runtime статус:
  - `docker service ls --filter label=com.docker.stack.namespace=dspace` -> усі сервіси `1/1`;
  - `GET https://repo.pinokew.buzz/server/api/core/sites` -> `HTTP 200`.

### Data/impact
- Виконано live redeploy стеку `dspace` і forced update backend-сервісу через config-change flag.
- Змін у БД/Solr/assetstore даних не виконувалось.

## 2026-04-26 — Category 2 autonomous scripts switched to Swarm runtime

### Контекст
- Автономні скрипти Категорії 2 мали працювати поза CI/CD через `SERVER_ENV`/SOPS і production Swarm runtime, а не напряму через compose або hardcoded container names.

### Оновлено
- `scripts/lib/docker-runtime.sh`
- `scripts/backup-dspace.sh`
- `scripts/restore-backup.sh`
- `scripts/run-maintenance.sh`
- `scripts/sync-user-groups.sh`

### Зміни
- Додано runtime helper з default `DOCKER_RUNTIME_MODE=swarm`, `STACK_NAME=dspace` і compose fallback для локального dev.
- `backup-dspace.sh` виконує DB dump через `docker_runtime_exec dspacedb`; додано `--dry-run` без dump/upload/archive.
- `restore-backup.sh` підтримує `--dry-run` без confirmation prompts і моделює Swarm scale/restore/reindex кроки без зміни даних.
- `run-maintenance.sh` виконує DSpace CLI через Swarm service `dspace`; `--dry-run` не виконує CLI, unmount, killall або poweroff.
- `sync-user-groups.sh` виконує SQL через Swarm service `dspacedb`; `--dry-run` друкує SQL без mutation.

### Перевірено
- `bash -n` і `shellcheck` для змінених DSpace скриптів — OK.
- `backup-dspace.sh --env dev --dry-run` — OK.
- `run-maintenance.sh --env dev --dry-run` — OK, poweroff не виконувався.
- `sync-user-groups.sh --env dev --dry-run` — OK, SQL mutation не виконувалась.
- `restore-backup.sh --env dev --dry-run <tmp-test-archive>` — OK, destructive кроки тільки надруковані.
- Read-only Swarm DB check: `docker_runtime_exec dspacedb pg_isready` — OK.

## 2026-04-30 — Backup refactor iteration 1: metadata module extraction

### Зроблено
- Виправлено parsing bug у `scripts/backup-dspace.sh`: `ENVIRONMENT_ARG` тепер ініціалізується порожнім значенням перед argument loop.
- Винесено metadata-частину backup flow (`DB dump -> cloud archive -> rclone upload/check -> full local archive`) у `scripts/lib/backup-metadata.sh`.
- Додано каркасні файли для наступних ітерацій:
  - `scripts/lib/backup-assetstore.sh`;
  - `scripts/lib/backup-cleanup.sh`.
- Cleanup у `backup-dspace.sh` тепер також прибирає локальний `${ARCHIVE_CLOUD}.sha256`, який створює metadata-модуль.

### Перевірено
- `bash -n scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `shellcheck scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `bash scripts/backup-dspace.sh --env dev --dry-run` — OK, реальні dump/upload/archive не виконувались.

### Data/impact
- Реальні backup/restore/destructive операції не запускались.
- `env.dev.enc` і `env.prod.enc` у цій ітерації не змінювались.

## 2026-04-30 — Backup refactor iteration 2: `.env.example` contract placeholders

### Зроблено
- У кінець `.env.example` додано блок `BACKUP REFACTORING SETTINGS` з новими змінними:
  - `BACKUP_RETENTION_META_LOCAL`;
  - `BACKUP_RETENTION_META_CLOUD`;
  - `BACKUP_RETENTION_DELETED`;
  - `BACKUP_ASSETSTORE_MIRROR`.

### Перевірено
- `tail -n 30 .env.example` підтвердив, що блок додано саме в кінець файлу.

### Data/impact
- `env.dev.enc` і `env.prod.enc` не змінювались; значення буде перенесено вручну окремо.

## 2026-04-30 — Backup refactor iteration 3: assetstore mirror module

### Зроблено
- Реалізовано `scripts/lib/backup-assetstore.sh`.
- `scripts/backup-dspace.sh` підключає assetstore-модуль і викликає `backup_assetstore` після metadata backup та перед поточним cleanup.
- Assetstore mirror використовує `rsync --archive --checksum --delete --backup` з `--backup-dir="${BACKUP_DIR}/assetstore-deleted/${DATE}"`.
- Якщо `VOL_ASSETSTORE_PATH` відсутній, mirror-крок завершується warning-ом без падіння.

### Перевірено
- `bash -n scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `shellcheck scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `bash scripts/backup-dspace.sh --env dev --dry-run` — OK, rsync/mutation кроки не виконувались.

### Data/impact
- Реальний `rsync`, backup upload або видалення файлів не виконувались.
- `env.dev.enc` містить нові backup-змінні; `env.prod.enc` у цій ітерації не змінювався.

## 2026-04-30 — Backup refactor iteration 4: cleanup module and retention split

### Зроблено
- Реалізовано `scripts/lib/backup-cleanup.sh`.
- `scripts/backup-dspace.sh` підключає cleanup-модуль і викликає `backup_cleanup` після metadata та assetstore-кроків.
- Retention розділено на:
  - `BACKUP_RETENTION_META_LOCAL` для `full_local_*.tar.gz`;
  - `BACKUP_RETENTION_META_CLOUD` для cloud metadata/checksum через `rclone delete`;
  - `BACKUP_RETENTION_DELETED` для `assetstore-deleted/*`.
- Для `BACKUP_RETENTION_META_LOCAL` збережено fallback на deprecated `BACKUP_RETENTION_DAYS`.
- Cloud cleanup обмежено include-фільтрами `cloud_metadata_*.tar.gz` і `cloud_metadata_*.tar.gz.sha256`.

### Перевірено
- `bash -n scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `shellcheck scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `bash scripts/backup-dspace.sh --env dev --dry-run` — OK; cleanup показав retention `local=30d`, `cloud=90d`, `deleted-assets=180d`.

### Data/impact
- Реальні backup/upload/rsync/delete операції не виконувались.
- `env.prod.enc` у цій ітерації не змінювався.

## 2026-04-30 — Backup refactor iteration 5: prerequisites and partial cleanup hardening

### Зроблено
- У `scripts/backup-dspace.sh` додано `check_prerequisites` перед orchestration.
- Перевіряються required tools: `rclone`, `rsync`, `sha256sum`.
- У `--dry-run` відсутні tools логуються як warning, без fail.
- Додано попередження, якщо у filesystem для `BACKUP_DIR` менше 10 GB вільного місця.
- Додано `ERR` trap із безпечним partial cleanup для `SQL_DUMP`, `ARCHIVE_CLOUD`, `${ARCHIVE_CLOUD}.sha256`, `ARCHIVE_LOCAL`.

### Перевірено
- `bash -n scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `shellcheck scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `bash scripts/backup-dspace.sh --env dev --dry-run` — OK.

### Data/impact
- Реальні backup/upload/rsync/delete операції не виконувались.

## 2026-04-30 — Backup refactor iteration 6: prod env contract validation

### Зроблено
- Після додавання backup-змінних у `env.prod.enc` увімкнено hard check для `BACKUP_ASSETSTORE_MIRROR` у `scripts/backup-dspace.sh`.
- Перевірено, що `env.dev.enc`, `env.prod.enc` і `.env.example` містять новий backup contract:
  - `BACKUP_RETENTION_META_LOCAL`;
  - `BACKUP_RETENTION_META_CLOUD`;
  - `BACKUP_RETENTION_DELETED`;
  - `BACKUP_ASSETSTORE_MIRROR`.

### Перевірено
- `bash -n scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `shellcheck scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `bash scripts/backup-dspace.sh --env dev --dry-run` — OK.
- `bash scripts/backup-dspace.sh --env prod --dry-run` — OK.

### Data/impact
- Реальні backup/upload/rsync/delete операції не виконувались.
- `env.prod.enc` був оновлений вручну поза агентом; агент лише перевірив наявність потрібних ключів і dry-run поведінку.

## 2026-04-30 — Backup refactor iteration 7: absolute `BACKUP_LOCAL_DIR`

### Зроблено
- `scripts/backup-dspace.sh` тепер нормалізує `BACKUP_LOCAL_DIR` у завжди абсолютний `BACKUP_DIR`.
- Якщо `BACKUP_LOCAL_DIR` absolute, він використовується як є; якщо relative, прив'язується до `PROJECT_ROOT`.
- У `--dry-run` скрипт більше не створює backup-dir і не пише `backup_log.txt`, щоб dry-run для absolute prod paths не вимагав прав на `/data`.
- `.env.example` оновлено: `BACKUP_LOCAL_DIR=/data/backup/dspace`.
- `docs/backup-dspace-refactoring.md` синхронізовано з новою path setup логікою.

### Перевірено
- `bash -n scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `shellcheck scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `bash scripts/backup-dspace.sh --env dev --dry-run` — OK.
- `bash scripts/backup-dspace.sh --env prod --dry-run` — OK; backup paths мають вигляд `/data/backup/dspace/...`.

### Data/impact
- Реальні backup/upload/rsync/delete операції не виконувались.
- У `/opt/Dspace/backups` виявлено наявний старий backup archive, тому каталог не очищався.

## 2026-04-30 — Scripts runbook sync після backup refactor

### Зроблено
- Оновлено секцію `scripts/backup-dspace.sh` у `docs/scripts_runbook.md`:
  - уточнено checksum/rclone check;
  - додано assetstore rsync mirror;
  - описано розділений retention;
  - оновлено manual execution приклади з `--env dev|prod --dry-run` та `SERVER_ENV`.

### Перевірено
- Переглянуто diff документації.

## 2026-04-30 — Backup directory initialization hardening

### Зроблено
- У `scripts/backup-dspace.sh` додано ідемпотентний helper `init_backup_dir`.
- Реальний запуск створює `BACKUP_DIR` з правами `0750`.
- Якщо поточний користувач не може створити системний каталог напряму, скрипт пробує `sudo -n install -d -m 0750 -o <uid> -g <gid>`.
- Для запуску через `sudo` ownership виставляється на `SUDO_UID:SUDO_GID`, щоб подальші запуски від cron-користувача могли писати в каталог.
- `docs/scripts_runbook.md` доповнено приміткою про автоматичну ініціалізацію backup-директорії.
- Примітка: наступною ітерацією основну підготовку `BACKUP_LOCAL_DIR` перенесено в `scripts/init-volumes.sh`, щоб cron backup не залежав від passwordless sudo.

### Перевірено
- `bash -n scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `shellcheck scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `bash scripts/backup-dspace.sh --env dev --dry-run` — OK.
- `bash scripts/backup-dspace.sh --env prod --dry-run` — OK.

### Data/impact
- Реальні backup/upload/rsync/delete операції не виконувались.

## 2026-04-30 — Init volumes керує `BACKUP_LOCAL_DIR`

### Зроблено
- `scripts/init-volumes.sh` тепер вимагає `BACKUP_LOCAL_DIR` разом з іншими volume path variables.
- `BACKUP_LOCAL_DIR` додано до існуючого ідемпотентного create loop через `ensure_dir`.
- Для backup-директорії додано baseline ownership/permissions:
  - owner: `BACKUP_UID:BACKUP_GID`;
  - fallback: UID/GID поточного користувача, який запускає `init-volumes.sh`;
  - mode: `750`.
- Для `--fix-existing` додано нормалізацію backup-директорії: dirs `750`, files `640`.
- `docs/scripts_runbook.md` оновлено: cron backup має покладатися на `init-volumes.sh` для підготовки `BACKUP_LOCAL_DIR`, а не на passwordless sudo в backup-скрипті.

### Перевірено
- `bash -n scripts/init-volumes.sh` — OK.
- `shellcheck scripts/init-volumes.sh` — OK.
- `ORCHESTRATOR_ENV_FILE=.env.example bash scripts/init-volumes.sh --dry-run` — OK; dry-run показав створення `/data/backup/dspace` і permissions `1000:1000`, mode `750`.

### Data/impact
- Реальні директорії/permissions не змінювались у перевірці, бо запуск був у `--dry-run`.

## 2026-04-30 — Backup rclone verification/filter fix

### Контекст
- Під час реального `bash scripts/backup-dspace.sh --env dev` upload проходив, але `rclone check` падав із `is a file not a directory`, бо remote file path передавався як rclone filesystem root.
- Cloud cleanup показував warning про одночасне використання `--include` і `--exclude`.

### Зроблено
- У `scripts/lib/backup-metadata.sh` `rclone check` переведено на перевірку local directory проти remote directory з filter-ами на конкретні archive/checksum файли:
  - `cloud_metadata_<DATE>.tar.gz`;
  - `cloud_metadata_<DATE>.tar.gz.sha256`.
- У `scripts/lib/backup-cleanup.sh` cloud cleanup переведено з `--include/--exclude` на ordered `--filter` правила.

### Перевірено
- `bash -n scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `shellcheck scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `bash scripts/backup-dspace.sh --env dev --dry-run` — OK; dry-run показав новий `rclone check <local-dir> <remote-dir> --one-way --filter ...`.

### Data/impact
- Реальні backup/upload/rsync/delete операції в цій перевірці не виконувались.

## 2026-04-30 — Local metadata archive retention

### Зроблено
- `scripts/lib/backup-cleanup.sh` більше не видаляє локальний `cloud_metadata_<DATE>.tar.gz` і `.sha256` одразу після upload.
- Локальні metadata archives/checksums тепер зберігаються в `BACKUP_LOCAL_DIR`.
- Для `cloud_metadata_*.tar.gz` і `cloud_metadata_*.tar.gz.sha256` додано cleanup за `BACKUP_RETENTION_META_LOCAL`.
- `.env.example`, `docs/scripts_runbook.md` і `docs/backup-dspace-refactoring.md` синхронізовано з новою поведінкою.

### Перевірено
- `bash -n scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `shellcheck scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `bash scripts/backup-dspace.sh --env dev --dry-run` — OK; dry-run показав `Keeping local metadata archive` і retention cleanup для `cloud_metadata_*`.

### Data/impact
- Реальні backup/upload/rsync/delete операції в цій перевірці не виконувались.

## 2026-04-30 — Split full-local and metadata-local retention

### Зроблено
- Додано окрему env-змінну `BACKUP_RETENTION_FULL_LOCAL` для локальних `full_local_*.tar.gz`.
- `BACKUP_RETENTION_META_LOCAL` тепер керує тільки локальними `cloud_metadata_*.tar.gz` і `.sha256`.
- Deprecated `BACKUP_RETENTION_DAYS` лишено fallback-ом тільки для `BACKUP_RETENTION_FULL_LOCAL`.
- Оновлено `.env.example`, `docs/scripts_runbook.md` і `docs/backup-dspace-refactoring.md`.

### Перевірено
- `bash -n scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `shellcheck scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `bash scripts/backup-dspace.sh --env dev --dry-run` — OK; summary показав `full-local=30d | meta-local=30d | meta-cloud=90d | deleted-assets=180d`.

### Data/impact
- Реальні backup/upload/rsync/delete операції в цій перевірці не виконувались.
- `env.dev.enc` і `env.prod.enc` потрібно доповнити `BACKUP_RETENTION_FULL_LOCAL`, якщо потрібне значення відмінне від fallback `BACKUP_RETENTION_DAYS`/`30`.

# DSpace-docker: Архітектура Репозиторію

Дата оновлення: 2026-03-23

## 1) Призначення репозиторію

`DSpace-docker` це operational/deploy репозиторій для core DSpace 9 runtime (UI + REST + Solr + PostgreSQL).
Ingress-шар (`Traefik`, `Cloudflare Tunnel`) винесений в окремі репозиторії.

Основні задачі:
1. Оркестрація runtime через `docker-compose.yml`.
2. Керування параметрами через `.env` (SSOT для середовища).
3. Патчинг DSpace-конфігів зі змінних середовища (`scripts/patch-*.sh`).
4. Day-2 operations: backup/restore, smoke, maintenance, sync.
5. CI/CD перевірки і деплой через GitHub Actions.

## 2) Runtime-стек (фактичний)

Сервіси у `docker-compose.yml`:
1. `dspacedb` (`postgres:15`) — primary DB.
2. `dspacesolr` (`dspace/dspace-solr:dspace-9_x`) — Solr cores для discovery/OAI/statistics.
3. `dspace` (`dspace/dspace:dspace-9_x`) — backend (REST API, міграції БД на старті).
4. `dspace-angular` (`dspace/dspace-angular:dspace-9_x-dist`) — frontend UI.

Ingress-компоненти:
- `Traefik` — окремий репозиторій `/home/pinokew/Traefik`.
- `Cloudflare Tunnel` — окремий репозиторій `/home/pinokew/cloudflare-tunnel`.

## 3) Мережева модель і трафік

Трафік:
`Користувач -> Cloudflare -> cloudflared (cf-tunnel стек) -> Traefik (окремий стек) -> dspace-angular / dspace`

Правила:
1. `dspacenet` — внутрішня мережа DSpace-стеку (`internal: true`, bridge).
  - Містить: `dspacedb`, `dspacesolr`, `dspace`, `dspace-angular`.
  - `dspacedb` і `dspacesolr` підключені **тільки** до `dspacenet` (ізольовані від зовні).
  - `dspace` і `dspace-angular` підключені до `dspacenet` + `proxy-net`.
2. `proxy-net` — спільна зовнішня мережа (bridge, `DSPACENET_SUBNET`, default `172.23.0.0/16`).
  - Створюється **Traefik-стеком**.
  - DSpace-стек підключається до неї як `external: true`.
  - `cloudflare-tunnel` підключається до неї як `external: true`.
  - Тільки `dspace` і `dspace-angular` бачать Traefik через цю мережу.
3. Публічний host-binding Traefik за замовчуванням локальний:
`127.0.0.1:${TRAEFIK_ENTRYPOINT_PORT:-8080}:80`.
4. UI/API публікуються через Traefik-роутери на `Host(${DSPACE_HOSTNAME})`.
  - `DSPACE_HOSTNAME` є обов'язковим для публічного routing; якщо змінна порожня, compose підставляє `Host(\`\`)`, що призводить до `404` на UI/API.
5. Traefik знає, через яку мережу досягати контейнерів: `--providers.docker.network=proxy-net`.
6. Traefik dashboard захищений `ipallowlist`.
7. Forwarded headers і trusted IP ranges задаються через env.

## 4) Конфігураційна модель (SSOT)

Джерела правди:
1. `.env` — runtime параметри і секрети (локально, не в git).
2. `example.env` — контракт змінних для CI і нових інсталяцій.
3. `docker-compose.yml` — зв'язки сервісів, healthchecks, labels, volumes.

Патчери конфігів:
1. `scripts/patch-local.cfg.sh` — синхронізує `dspace/config/local.cfg` (DB, Solr, OIDC, CORS, SMTP, GA4, Matomo, sitemap, security).
2. `scripts/patch-config.yml.sh` — генерує `ui-config/config.yml` для Angular, включно з `themes.headTags` для Matomo (за `DSPACE_MATOMO_ENABLED=true`).
3. `scripts/patch-submission-forms.sh` — патчить `submission-forms.xml` (мови подання).
4. `scripts/setup-configs.sh` — оркеструє пакетний запуск патчерів.

Важливо про Matomo snippet:
1. Фактична вставка tracker-коду у DSpace UI виконується генератором `scripts/lib/patch-config/modules.sh` (`matomo_context` + `render_config`).
2. `docs/snippets/dspace-tracker.js` використовується як канонічний референс-артефакт для документації, а не як runtime-input для скриптів.

Операційне правило:
сталі зміни робляться через `.env`/скрипти/compose, не через ручні правки всередині контейнерів.

## 5) Дані і персистентність

Основні host volumes задаються через `VOL_*`:
1. `VOL_POSTGRESQL_PATH` -> PostgreSQL data.
2. `VOL_SOLR_PATH` -> Solr cores/indexes.
3. `VOL_ASSETSTORE_PATH` -> DSpace assetstore (файли контенту).
4. `VOL_EXPORTS_PATH` -> DSpace exports.
5. `VOL_LOGS_PATH` -> DSpace logs + Traefik file logs (`/traefik`).

Логування:
1. Docker `json-file` rotation для контейнерних stdout/stderr (`10m`, `3` files).
2. Traefik file logs (`access.log`, `traefik.log`) ротує системний `logrotate` (див. `Traefik-logrotate.md`).

## 6) Операційні скрипти

Ключові сценарії:
1. `scripts/verify-env.sh` — валідація `.env` проти `example.env`, перевірка прав доступу (`600` поза CI-mock).
2. `scripts/patch-local.cfg.sh` — модульний патчер `local.cfg` (`--dry-run`, `--modules`, `--list-modules`) + sync пароля ролі PostgreSQL.
3. `scripts/patch-config.yml.sh` — модульний генератор `ui-config/config.yml` (`rest_context`, `matomo_context`, `render_config`).
4. `scripts/smoke-test.sh` — постдеплой health/security перевірки UI/API/OAI/headers/CORS.
5. `scripts/backup-dspace.sh` — SQL dump + cloud metadata archive + local full archive + retention.
6. `scripts/restore-backup.sh` — DR restore (руйнівний сценарій з підтвердженням).
7. `scripts/init-volumes.sh` — ініціалізація директорій і прав томів.
8. `scripts/bootstrap-admin.sh` — неінтерактивне створення першого admin-користувача.
9. `scripts/run-maintenance.sh` — регламентні задачі DSpace (`filter-media`, `index-discovery`, `oai import`).
10. `scripts/sync-user-groups.sh` — синхронізація користувачів у DSpace-групу за доменом OIDC.

## 7) CI/CD архітектура

Workflow: `.github/workflows/ci-cd.yml`

`ci-checks`:
1. Shellcheck для `scripts/**/*.sh`.
2. Compose validation + перевірка на unresolved `${...}`.
3. Env validation (`verify-env.sh --ci-mock`).
4. Dry-run патчера backend-конфігу.
5. Trivy config scan (`CRITICAL` gate).
6. Trivy image scan (`CRITICAL` gate) для всіх образів compose + контроль `expired_at` у `.trivyignore.yaml`.

`cd-deploy` (push у `main` або tag `v*.*.*`):
1. Підключення через Tailscale.
2. SSH деплой на сервер.
3. Примусова синхронізація git ref (`main` або tag).
4. `patch-local.cfg.sh`.
5. `docker compose pull` + `docker compose up -d --remove-orphans`.
6. `smoke-test.sh` і автоматична діагностика логів при фейлі.

## 8) Безпекові обмеження

1. Секрети не зберігаються в git; `.env` має бути локальним з правами `600`.
2. Публічний доступ проходить через Cloudflare/Tunnel; пряма експозиція сервісів не є дефолтом.
3. Trusted proxy ranges задаються явно (`proxies.trusted.ipranges`, Traefik trustedIPs).
4. Security headers накладаються на UI/API через Traefik middleware.
5. CI блокує деплой при неігнорованих `CRITICAL` security findings.

## 9) Архітектура backup/restore

Backup (`scripts/backup-dspace.sh`):
1. Робить SQL dump з контейнера БД.
2. Формує cloud archive: SQL + `.env` + `dspace/config`.
3. Вивантажує cloud archive через `rclone`.
4. Формує local full archive: SQL + конфіги + assetstore.
5. Виконує retention cleanup.

Restore (`scripts/restore-backup.sh`):
1. Вимагає подвійне ручне підтвердження.
2. Зупиняє стек.
3. Очищає PG/Solr/assetstore (assetstore лише якщо є в backup).
4. Відновлює SQL.
5. Підіймає стек і запускає `index-discovery -b`.

DR-процедура і DoD описані в `RunbookDR.md`.

## 10) Правила ведення змін

1. `CHANGELOG.md` це тільки індекс томів і статус активного тому.
2. Детальні записи ведуться у `CHANGELOGS/CHANGELOG_<YEAR>_VOL_<NN>.md`.
3. Ліміт тому: soft `300` рядків, hard `350` рядків.
4. Кожен суттєвий крок має бути зафіксований у активному томі.

## 11) Структура репозиторію (актуальна)

```text
DSpace-docker/
  .github/workflows/ci-cd.yml
  docker-compose.yml
  example.env
  dspace/config/
    local.cfg
    local.cfg.EXAMPLE
    submission-forms.xml
  ui-config/config.yml
  scripts/
    verify-env.sh
    patch-local.cfg.sh
    patch-config.yml.sh
    patch-submission-forms.sh
    setup-configs.sh
    smoke-test.sh
    backup-dspace.sh
    restore-backup.sh
    init-volumes.sh
    bootstrap-admin.sh
    run-maintenance.sh
    sync-user-groups.sh
  ARCHITECTURE.md
  NEW_CHAT_START_HERE.md
  CHANGELOG.md
  CHANGELOGS/
  RunbookDR.md
  Traefik-logrotate.md
  archive/ (історичні/неактивні файли, не частина runtime-пайплайну)
```

# Runbook: Оркестрація патчу конфігів DSpace

> Файл перейменовано з `docs/SCRIPTS_REFACTOR_RUNBOOK.md`.
> Останнє оновлення: 2026-04-08.

## 1. Призначення

Цей runbook описує повний операційний цикл патчу конфігів DSpace через скриптову оркестрацію:
- валідація `.env`;
- патч backend-конфігу `dspace/config/local.cfg`;
- генерація frontend-конфігу `ui-config/config.yml`;
- підготовка volume-директорій;
- smoke-перевірки доступності та безпеки.

Документ орієнтований на експлуатацію (operations), а не на історію рефакторингу.

## 2. Які скрипти входять в оркестрацію

Основний entrypoint:
- `./scripts/deploy-orchestrator.sh`

Кроки, які він запускає послідовно:
1. `./scripts/verify-env.sh --ci-mock`
2. `./scripts/patch-local.cfg.sh`
3. `./scripts/patch-config.yml.sh`
4. `./scripts/init-volumes.sh`
5. `./scripts/smoke-test.sh`

## 3. Передумови

1. У репозиторії має бути валідний `.env` (або `example.env` для первинного шаблону).
2. Docker має бути доступний для:
   - `db_rotation` у backend patch;
   - `init-volumes.sh`.
3. DNS/ingress для `DSPACE_HOSTNAME` має резолвитись коректно, інакше `smoke-test.sh` може падати на `required_checks`.
4. Рекомендовано запускати з кореня репозиторію.

## 4. Швидкий старт

Повна оркестрація:

```bash
./scripts/deploy-orchestrator.sh
```

Перевірка без змін (окремими командами):

```bash
./scripts/verify-env.sh --ci-mock
./scripts/patch-local.cfg.sh --dry-run
./scripts/patch-config.yml.sh --dry-run
./scripts/init-volumes.sh --dry-run
./scripts/smoke-test.sh --dry-run
```

## 5. Детальний pipeline (що саме робить кожен етап)

### 5.1 `verify-env.sh`

Призначення:
- звіряє, що всі ключі з `example.env` присутні в `.env`.

Важливі деталі:
- без `--ci-mock` скрипт вимагає права на `.env` рівно `600`;
- з `--ci-mock` при відсутності `.env` створює його з `example.env`.

Рекомендація для production-переддеплою:

```bash
chmod 600 .env
./scripts/verify-env.sh
```

### 5.2 `patch-local.cfg.sh` (backend)

Призначення:
- синхронізує `dspace/config/local.cfg` зі значеннями `.env` модульно.

Контракт скрипта:
- `--dry-run`
- `--modules a,b,c`
- `--list-modules`
- `--no-restart`

Поведінка після застосування змін:
- якщо `local.cfg` змінено (або виконувався модуль `db_rotation`), скрипт автоматично перезапускає backend контейнер (`dspace` або `${DSPACE_CONTAINER_NAME}`).

Підтримувані модулі:
- `cleanup`, `basic_urls`, `database`, `db_rotation`, `solr`, `proxy`, `cors`, `auth`, `oidc`, `eperson`, `upload`, `seo`, `email`, `security`, `languages`, `ga4`, `matomo`

#### Модулі backend і функціонал

| Модуль | Функціонал | Ключові `.env` змінні |
|---|---|---|
| `cleanup` | Видаляє legacy Tomcat proxy-ключі | - |
| `basic_urls` | Базові URL/назва репозиторію | `DSPACE_DIR`, `DSPACE_NAME`, `DSPACE_UI_BASEURL`, `DSPACE_REST_BASEURL`, `DSPACE_REST_SSRBASEURL` |
| `database` | JDBC URL та DB креденшіали для DSpace | `POSTGRES_INTERNAL_PORT`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` |
| `db_rotation` | Синхронізація пароля ролі PostgreSQL через контейнер | `DB_PASSWORD_ROTATION_ENABLED`, `DB_PASSWORD_ROTATION_FAIL_ON_ERROR`, `DB_CONTAINER_NAME`, `POSTGRES_USER`, `POSTGRES_PASSWORD` |
| `solr` | Адреса Solr | `SOLR_INTERNAL_PORT` |
| `proxy` | Proxy-aware режим DSpace | `DSPACENET_SUBNET` |
| `cors` | Дозволені origins/methods для REST | `DSPACE_HOSTNAME`, `DSPACE_UI_BASEURL`, `DSPACE_UI_LOCALHOST`, `CORS_ALLOWED_METHODS` |
| `auth` | Порядок/набір auth-методів | `AUTH_METHODS` |
| `oidc` | SSO/OIDC інтеграція (Microsoft Entra ID тощо) | `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`, `OIDC_AUTHORIZE_ENDPOINT`, `OIDC_TOKEN_ENDPOINT`, `OIDC_USER_INFO_ENDPOINT`, `OIDC_ISSUER`, `OIDC_REDIRECT_URL`, `OIDC_CAN_SELF_REGISTER`, `OIDC_SCOPES`, `OIDC_EMAIL_ATTR`, `OIDC_DOMAIN` |
| `eperson` | Політика request-item/helpdesk | `REQUEST_ITEM_TYPE`, `REQUEST_ITEM_HELPDESK_OVERRIDE` |
| `upload` | Ліміти завантажень та timeout сесії | `MAX_FILE_SIZE`, `MAX_REQUEST_SIZE` |
| `seo` | Sitemap cron/domain | `DSPACE_UI_BASEURL` |
| `email` | SMTP вихідна пошта та адресати | `DSPACE_MAIL_SERVER`, `DSPACE_MAIL_PORT`, `DSPACE_MAIL_USERNAME`, `DSPACE_MAIL_PASSWORD`, `DSPACE_MAIL_ADMIN`, `DSPACE_MAIL_FEEDBACK` |
| `security` | Базові policy прапори реєстрації/відновлення | (фіксовані значення в модулі) |
| `languages` | Дефолтна та підтримувані локалі backend | (фіксовані значення в модулі) |
| `ga4` | Google Analytics 4 для backend-подій | `DSPACE_GA_ID`, `DSPACE_GA_API_SECRET` |
| `matomo` | Matomo параметри в backend local.cfg | `DSPACE_MATOMO_ENABLED`, `DSPACE_MATOMO_SITE_ID`, `DSPACE_MATOMO_BASE_URL`, `DSPACE_MATOMO_JS_URL`, `DSPACE_MATOMO_TRACKER_URL` |

### 5.3 `patch-config.yml.sh` (frontend)

Призначення:
- генерує `ui-config/config.yml` для Angular UI.

Контракт скрипта:
- `--dry-run`
- `--modules a,b,c`
- `--list-modules`
- `--no-restart`

Поведінка після застосування змін:
- якщо `ui-config/config.yml` змінився, скрипт автоматично перезапускає frontend контейнер (`dspace-angular` або `${DSPACE_UI_CONTAINER_NAME}`).

Підтримувані модулі:
- `rest_context`, `matomo_context`, `render_config`

#### Модулі frontend і функціонал

| Модуль | Функціонал | Ключові `.env` змінні |
|---|---|---|
| `rest_context` | Розбір `DSPACE_REST_BASEURL` в `ssl/host/port/namespace` | `DSPACE_REST_BASEURL` |
| `matomo_context` | Генерує `themes.headTags` зі script tracker Matomo | `DSPACE_MATOMO_ENABLED`, `DSPACE_MATOMO_SITE_ID`, `DSPACE_MATOMO_BASE_URL`, `DSPACE_MATOMO_JS_URL`, `DSPACE_MATOMO_TRACKER_URL`, `DSPACE_MATOMO_SEARCH_KEYWORD_PARAM`, `DSPACE_MATOMO_SEARCH_CATEGORY_PARAM` |
| `render_config` | Рендер фінального `ui-config/config.yml` | `DSPACE_UI_BASEURL` + контекст з попередніх модулів |

### 5.4 `init-volumes.sh`

Призначення:
- створює директорії volume;
- виставляє ownership/permissions через ефемерні Docker-контейнери.

Ключові `.env` змінні:
- обов'язкові: `VOL_POSTGRESQL_PATH`, `VOL_SOLR_PATH`, `VOL_ASSETSTORE_PATH`, `VOL_EXPORTS_PATH`, `VOL_LOGS_PATH`;
- опційні UID/GID: `POSTGRES_UID`, `POSTGRES_GID`, `SOLR_UID`, `SOLR_GID`, `DSPACE_UID`, `DSPACE_GID`;
- helper image: `INIT_VOLUMES_HELPER_IMAGE`.

Опції:
- `--dry-run`
- `--fix-existing` (нормалізує права всередині існуючих директорій).

### 5.5 `smoke-test.sh`

Призначення:
- перевірка доступності UI/API/OAI;
- перевірка security headers;
- CORS safety;
- sitemap (warning-only).

Контракт скрипта:
- `--dry-run`
- `--modules a,b,c`
- `--list-modules`

Підтримувані модулі:
- `context`, `required_checks`, `security_headers`, `cors_safety`, `sitemap_optional`

Ключова `.env` змінна:
- `DSPACE_HOSTNAME`.

## 6. Робочі сценарії запуску

### 6.1 Повний деплой-патч цикл

```bash
./scripts/deploy-orchestrator.sh
```

### 6.2 Тільки backend патч (наприклад SMTP + SSO)

```bash
./scripts/patch-local.cfg.sh --modules email,auth,oidc
```

Без рестарту контейнера:

```bash
./scripts/patch-local.cfg.sh --modules email,auth,oidc --no-restart
```

### 6.3 Тільки frontend Matomo + рендер

```bash
./scripts/patch-config.yml.sh --modules matomo_context,render_config
```

Без рестарту контейнера:

```bash
./scripts/patch-config.yml.sh --modules matomo_context,render_config --no-restart
```

### 6.4 Тільки DB password rotation

```bash
./scripts/patch-local.cfg.sh --modules db_rotation
```

### 6.5 Вибіркова smoke-перевірка без sitemap

```bash
./scripts/smoke-test.sh --modules required_checks,security_headers,cors_safety
```

## 7. Troubleshooting

### 7.1 Помилка `Is a directory` для `local.cfg` або `config.yml`

Скрипти вже мають auto-recovery:
- якщо `dspace/config/local.cfg` або `ui-config/config.yml` є директорією, вона буде перенесена у backup з суфіксом `.dir-backup.<timestamp>`;
- далі створюється/використовується коректний файл.

Перевірка:

```bash
ls -la dspace/config
ls -la ui-config
```

### 7.2 `db_rotation` пропускається

Можливі причини:
- Docker відсутній;
- контейнер БД не існує/не запущений;
- `DB_PASSWORD_ROTATION_ENABLED=false`.

Діагностика:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'
./scripts/patch-local.cfg.sh --modules db_rotation --dry-run
```

### 7.3 Smoke test падає на `UI Home`/`API`

Типові причини:
- DNS/ingress ще не готовий;
- TLS/proxy не прокинуті;
- застосунок не піднявся.

Діагностика:

```bash
./scripts/smoke-test.sh --modules context,required_checks
curl -I "https://${DSPACE_HOSTNAME}/"
```

### 7.4 `verify-env` падає на permissions

Для strict-режиму:

```bash
chmod 600 .env
./scripts/verify-env.sh
```

## 8. Операційні чеклісти

### 8.1 Pre-flight

1. `git status --short`
2. `docker compose ps`
3. `test -f .env`
4. `chmod 600 .env`
5. `./scripts/verify-env.sh`

### 8.2 Post-run

1. Перевірити, що `dspace/config/local.cfg` та `ui-config/config.yml` оновлені.
2. Переконатися, що `smoke-test.sh` пройшов required checks.
3. Якщо є backup-директорії `.dir-backup.*`, зберегти або прибрати їх після рев'ю.

## 9. Мінімальний набір змінних `.env` для ключового функціоналу

### SMTP (email модуль)
- `DSPACE_MAIL_SERVER`
- `DSPACE_MAIL_PORT`
- `DSPACE_MAIL_USERNAME`
- `DSPACE_MAIL_PASSWORD`
- `DSPACE_MAIL_ADMIN`
- `DSPACE_MAIL_FEEDBACK`

### SSO/OIDC (auth + oidc модулі)
- `AUTH_METHODS`
- `OIDC_CLIENT_ID`
- `OIDC_CLIENT_SECRET`
- `OIDC_AUTHORIZE_ENDPOINT`
- `OIDC_TOKEN_ENDPOINT`
- `OIDC_USER_INFO_ENDPOINT`
- `OIDC_ISSUER`
- `OIDC_REDIRECT_URL`
- `OIDC_DOMAIN` (опційно)
- `OIDC_SCOPES`
- `OIDC_CAN_SELF_REGISTER`
- `OIDC_EMAIL_ATTR`

### Аналітика
- GA4: `DSPACE_GA_ID`, `DSPACE_GA_API_SECRET`
- Matomo: `DSPACE_MATOMO_ENABLED`, `DSPACE_MATOMO_SITE_ID`, `DSPACE_MATOMO_BASE_URL` (+ optional overrides)

---

Якщо потрібно, цей runbook можна далі розширити окремими профілями для `dev/stage/prod` з готовими командами запуску модулів під конкретні середовища.

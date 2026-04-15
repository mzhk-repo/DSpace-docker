# CHANGELOG 2026 VOL 02

## Анотація тому

- Контекст: продовження ітеративних інфраструктурних змін DSpace 9 (аналітика, безпека, операційні процедури).
- Зміст: Matomo-інтеграція для DSpace UI, CSP-узгодження, валідація DoD.
- Ключові напрямки: IaC-підхід через `.env` + patch-скрипти, безпечний rollout малими кроками.

## [2026-03-23] Stabilization — patch-скрипти, Traefik host routing, Matomo tracker

### Зроблено
- Виправлено `scripts/lib/patch-local/modules.sh`:
  - у модулі `cors` прибрано падіння на `set -u` при відсутньому `DSPACE_HOSTNAME`;
  - додано fallback: host береться з `DSPACE_UI_BASEURL`, інакше `localhost`.
- Виправлено `scripts/lib/patch-local/db_rotation.sh`:
  - SQL sync пароля ролі PostgreSQL перероблено через безпечну генерацію/виконання `ALTER ROLE`;
  - усунуто помилку `syntax error at or near ":"` під час `db_rotation`.
- Додано/зафіксовано вимогу `DSPACE_HOSTNAME` у `.env` для Traefik роутерів:
  - усунуто стан `Host(\`\`)` у labels (`dspace`, `dspace-angular`), що спричиняв `404` на UI.
- Виправлено Matomo tracking для DSpace:
  - знайдено і виправлено некоректний `DSPACE_MATOMO_SITE_ID` (`3` -> `2`);
  - перегенеровано `ui-config/config.yml` і синхронізовано `dspace/config/local.cfg` (`matomo.request.siteid=2`);
  - підтверджено успішний tracker POST (`HTTP 204`) на `https://matomo.pinokew.buzz/js/ping`.
- Уточнено документацію:
  - оновлено `docs/ARCHITECTURE.md` (routing requirement + шлях Matomo injection);
  - оновлено `README.md` (операційні вимоги й troubleshooting).

### Перевірено
- `bash -n` для `patch-local` модулів та оркестратора — OK.
- `./scripts/patch-local.cfg.sh --dry-run` — full pipeline проходить без падінь.
- `./scripts/patch-local.cfg.sh --modules database,db_rotation` — role password sync успішний (`ALTER ROLE`).
- `curl -Ik https://repo.pinokew.buzz/` — `HTTP 200` після виправлення host routing.
- Matomo logs:
  - до виправлення: `An unexpected website was found in the request: website id was set to '3'`.
  - після виправлення: запити з `idsite=2` повертають `200/204`.

### Нотатка
- `docs/snippets/dspace-tracker.js` є канонічним артефактом/референсом; фактична вставка в UI-сторінки відбувається через генерацію `ui-config/config.yml` скриптом `scripts/patch-config.yml.sh` (`matomo_context` + `render_config`).

## [2026-03-23] Безпечна ротація пароля БД через `.env` + автоматичний sync ролі PostgreSQL

### Зроблено
- Оновлено `scripts/patch-local.cfg.sh`:
  - залишено синхронізацію `db.password` у `dspace/config/local.cfg`;
  - додано автоматичну синхронізацію пароля ролі PostgreSQL у контейнері БД (`ALTER ROLE`) на базі нового `POSTGRES_PASSWORD`;
  - додано керуючі прапори:
    - `DB_PASSWORD_ROTATION_ENABLED` (default: `true`),
    - `DB_PASSWORD_ROTATION_FAIL_ON_ERROR` (default: `true`),
    - `DB_CONTAINER_NAME` (default: `dspacedb`).
- Оновлено `README.md` з описом автоматизації ротації пароля БД.
- Додано runbook `docs/DB_PASSWORD_ROTATION_RUNBOOK.md` з покроковою процедурою, валідацією та rollback.

### Перевірено
- `shell`: `bash -n scripts/patch-local.cfg.sh` — OK.
- `shellcheck`: `scripts/patch-local.cfg.sh` — без нових зауважень.
- `runtime`: підтверджено сценарій усунення `FATAL: password authentication failed for user "dspace"` через синхронізацію ролі в БД і подальший healthy-start backend.

### Нотатка
- PostgreSQL password у вже ініціалізованому volume не змінюється автоматично лише від редагування `.env`; тому sync ролі в БД є обовʼязковою частиною процедури.

## [2026-03-18] Matomo для DSpace — документація (runbook)

### Зроблено
- Створено runbook [docs/integrations/dspace.md](docs/integrations/dspace.md) з інструкцією налаштування Matomo-аналітики для DSpace 9.
- Документ містить:
  - перелік env-змінних Matomo;
  - призначення кожної змінної;
  - покрокове застосування (`patch-config.yml.sh`, recreate `dspace-angular`);
  - базову перевірку (network requests, відсутність `_pk_*` cookies, Matomo Realtime).

### Перевірено
- `services`: до змін core сервіси DSpace були `Up (healthy)`.
- `health`: крок документарний, runtime-конфіг не змінювався.
- `data`: змін у БД/Solr/assetstore немає.

### Нотатка
- Попередній том `CHANGELOG_2026_VOL_01.md` перевищив soft limit (301 рядок), тому активний том переключено на `CHANGELOG_2026_VOL_02.md`.

## [2026-03-18] Matomo для DSpace — діагностика “є 200-запити, але нема візитів”

### Симптом
- У браузері були запити до Matomo зі статусом `200`, але візити сайту `https://repo.pinokew.buzz` не відображались у Matomo.

### Причина
- DSpace UI використовує native Matomo інтеграцію через backend-властивості `matomo.*` (читаються з REST API), а не лише headTags/snippet.
- Фактичні значення на проді до виправлення були некоректні:
  - `matomo.enabled=false`
  - `matomo.request.siteid=1`
  - `matomo.tracker.url=http://localhost:8081`
- Додатково в браузерній сесії був стан знятої згоди (`mtm_consent_removed`), що блокує відправку трекінгу до Matomo.

### Зроблено
- Оновлено `scripts/patch-local.cfg.sh`:
  - додано синхронізацію `matomo.enabled`, `matomo.request.siteid`, `matomo.tracker.url` з `.env`.
  - base URL Matomo береться з `DSPACE_MATOMO_BASE_URL`, або обчислюється з `DSPACE_MATOMO_JS_URL`.
- Оновлено `example.env`: додано `DSPACE_MATOMO_BASE_URL`.
- Оновлено `scripts/patch-config.yml.sh`: виправлено порядок ініціалізації Matomo в headTags (queue `_paq` перед завантаженням `matomo.js`).
- Застосовано зміни в runtime:
  - `./scripts/patch-local.cfg.sh`
  - `docker compose up -d --force-recreate dspace dspace-angular`

### Перевірено
- `services`: `dspace` і `dspace-angular` після recreate у стані `Up (healthy)`.
- `health`: REST-властивості після виправлення:
  - `matomo.enabled=true`
  - `matomo.request.siteid=2`
  - `matomo.tracker.url=https://matomo.pinokew.buzz`
- Браузерна валідація:
  - консольна помилка Matomo про неініціалізований tracker зникла;
  - після надання cookie-consent зафіксовано `POST` на `https://matomo.pinokew.buzz/matomo.php?...idsite=2...`.
- `data`: змін у БД/Solr/assetstore немає.

### Нотатка
- За відсутності consent (або при відкликанні consent) Matomo хіти можуть не відправлятись навіть якщо `matomo.js` завантажується успішно.

## [2026-03-18] Matomo для DSpace — спрощення env-моделі до single base URL

### Зроблено
- Спрощено конфігураційну модель Matomo: `DSPACE_MATOMO_BASE_URL` тепер є основною env-змінною.
- `scripts/patch-config.yml.sh` автоматично виводить:
  - `matomo.js` як `<base>/matomo.js`;
  - tracker endpoint як `<base>/js/ping`.
- `scripts/patch-local.cfg.sh` використовує `DSPACE_MATOMO_BASE_URL` як основне джерело для `matomo.tracker.url`.
- Збережено зворотну сумісність: `DSPACE_MATOMO_JS_URL` і `DSPACE_MATOMO_TRACKER_URL` залишені як необов'язкові override-змінні для нестандартних шляхів.
- Оновлено `example.env` та `docs/integrations/dspace.md` під нову модель.

### Перевірено
- `health`: `patch-config.yml.sh` коректно генерує `g.src = 'https://matomo.pinokew.buzz/matomo.js'` і `setTrackerUrl('https://matomo.pinokew.buzz/js/ping')` при використанні лише `DSPACE_MATOMO_BASE_URL`.
- `health`: `patch-local.cfg.sh` коректно генерує `matomo.tracker.url = https://matomo.pinokew.buzz` при використанні лише `DSPACE_MATOMO_BASE_URL`.
- `services`: нових runtime-змін цим кроком не застосовувалось.
- `data`: змін у БД/Solr/assetstore немає.

## [2026-03-18] Matomo для DSpace — крок 3 (CSP для Matomo endpoint-ів)

### Зроблено
- Визначено, що canonical `Content-Security-Policy-Report-Only` задається не в `DSpace-docker`, а в окремому ingress-репозиторії `Traefik` через env `CSP_REPORT_ONLY_POLICY`.
- Неефективний локальний overlay для CSP прибрано з `DSpace-docker/docker-compose.yml`.
- У `Traefik/.env` оновлено `CSP_REPORT_ONLY_POLICY`, додано Matomo origin до:
  - `script-src`
  - `connect-src`
- У `Traefik/.env.example` оновлено приклад policy під Matomo.
- У `Traefik/README.md` додано примітку, що зовнішні інтеграції типу Matomo вносяться через `CSP_REPORT_ONLY_POLICY`.

### Перевірено
- `services`:
  - `traefik` після recreate у стані `Up (healthy)`.
  - core сервіси DSpace залишились доступними.
- `health`:
  - `https://repo.pinokew.buzz/home` → `200`.
  - `https://repo.pinokew.buzz/server/api/core/sites` → `200`.
- `headers`:
  - UI `Content-Security-Policy-Report-Only` містить `script-src 'self' https://matomo.pinokew.buzz`.
  - UI `Content-Security-Policy-Report-Only` містить `connect-src 'self' https://matomo.pinokew.buzz`.
  - API `Content-Security-Policy-Report-Only` містить ті самі дозволи.
- `browser`:
  - сторінка `https://repo.pinokew.buzz/home` відкривається після зміни CSP без видимих runtime-помилок у перевіреній сесії.
- `data`: змін у БД/Solr/assetstore немає.

### Нотатка
- Реальне місце керування CSP для DSpace зараз це Traefik-стек; майбутні зміни policy треба робити там, а не через локальні middleware overlay в `DSpace-docker`.

## [2026-03-18] Matomo для DSpace — що залишилось виконати по roadmap (цей репозиторій)

### Залишилось (по кроках)
- Крок 3.3 (Bitstream Download Tracking):
  - перевірити, що кліки по URL ` /bitstream/handle/... ` фіксуються як `Downloads` у Matomo;
  - у Matomo Admin підтвердити/уточнити Download URL patterns для DSpace bitstream-шляхів.
- Крок 4 (валідація DoD):
  - підтвердити `Site Search` події з DSpace (`query`, `filter`) у Matomo;
  - підтвердити `0` CSP violations у браузерній консолі DSpace;
  - підтвердити відсутність `_pk_*` cookies у DSpace-сесії;
  - зафіксувати результати перевірок у changelog (services/health/data + докази перевірки).

### Межі виконання
- В цьому репозиторії вже закрито інфраструктурну частину:
  - Matomo env/pipeline;
  - native Matomo config у DSpace backend;
  - CSP allowlist для Matomo origin на ingress-рівні.
- Залишкові кроки переважно валідаційні та адміністративні (Matomo UI + браузерні перевірки + документування результатів).

## [2026-03-18] Matomo для DSpace — DoD валідація (підсумок)

### Матриця результатів DoD
- `PASS` Download tracking:
  - у браузерному прогоні зафіксовано `POST` на `https://matomo.pinokew.buzz/matomo.php` з `url=https://repo.pinokew.buzz/bitstreams/.../download` і `urlref=/items/...`;
  - фінальна сторінка завантаження: `https://repo.pinokew.buzz/bitstreams/7c627234-2fa2-4f9e-8515-01c8191eb83c/download`.
- `PASS` Site search tracking:
  - зафіксовано `POST` на `matomo.php` з `url=https://repo.pinokew.buzz/search?query=library&filter=subject`.
- `FAIL` Zero CSP violations:
  - у повному інтегрованому прогоні зафіксовано `716` `Content-Security-Policy-Report-Only` violations;
  - основні джерела: `fonts.googleapis.com`, `fonts.gstatic.com`, inline style/event handlers, cloudflare/third-party скрипти.
- `PASS` No `_pk_*` cookies:
  - у валідаційній сесії `document.cookie` не містить cookie з префіксом `_pk_`;
  - наявні cookie: `orejime-anonymous`, `CORRELATION-ID`, `_ga`, `XSRF-TOKEN`, `_ga_BL4WJ9ZV8H`.

### Перевірено
- `services`: core сервіси DSpace та ingress доступні під час прогонів.
- `health`: сторінки `home`, `search`, `item`, `bitstream/download` відкриваються та генерують Matomo хіти.
- `data`: змін у БД/Solr/assetstore немає.

### Залишилось після DoD-підсумку
- Усунути або явно дозволити джерела, що створюють CSP report-only violations, і повторити DoD для досягнення критерію `0`.
- Окремо прибрати дублювання Matomo consent-ініціалізації (`setConsentGiven registered more than once`), щоб уникнути шуму в runtime-діагностиці.

## [2026-03-23] Refactor (ітерація 1) — модульна декомпозиція `scripts/patch-local.cfg.sh`

### Зроблено
- `scripts/patch-local.cfg.sh` перетворено на оркестратор модулів.
- Додано модульну структуру:
  - `scripts/lib/patch-local/helpers.sh`
  - `scripts/lib/patch-local/env.sh`
  - `scripts/lib/patch-local/db_rotation.sh`
  - `scripts/lib/patch-local/modules.sh`
- Додано керування запуском:
  - `--dry-run` (без змін файлів/БД),
  - `--modules <m1,m2>` (точковий patch),
  - `--list-modules`.
- Збережено попередню бізнес-логіку патчів (DB/Solr/Proxy/CORS/OIDC/SMTP/GA4/Matomo тощо).
- Збережено автоматичний sync пароля ролі PostgreSQL (модуль `db_rotation`).

### Перевірено
- `bash -n scripts/patch-local.cfg.sh scripts/lib/patch-local/*.sh` — OK.
- `shellcheck scripts/patch-local.cfg.sh scripts/lib/patch-local/*.sh` — OK.
- `./scripts/patch-local.cfg.sh --list-modules` — повертає реєстр модулів.
- `./scripts/patch-local.cfg.sh --dry-run --modules database,db_rotation` — dry-run працює коректно.
- `./scripts/patch-local.cfg.sh --dry-run` — full dry-run пайплайн працює.

### Нотатка
- Це інкрементальна ітерація №1 (один скрипт). Наступні скрипти рефакторимо лише після окремого підтвердження.

## [2026-03-23] Refactor (ітерація 2) — модульна декомпозиція `scripts/patch-config.yml.sh`

### Зроблено
- `scripts/patch-config.yml.sh` перетворено на оркестратор модулів.
- Додано модульну структуру:
  - `scripts/lib/patch-config/helpers.sh`
  - `scripts/lib/patch-config/env.sh`
  - `scripts/lib/patch-config/modules.sh`
- Додано керування запуском:
  - `--dry-run` (preview без змін файлів),
  - `--modules <m1,m2>` (точковий запуск),
  - `--list-modules`.
- Виділено функціональні модулі:
  - `rest_context` (парсинг REST URL),
  - `matomo_context` (генерація headTags для Matomo),
  - `render_config` (збірка `ui-config/config.yml`).

### Перевірено
- `bash -n scripts/patch-config.yml.sh scripts/lib/patch-config/*.sh` — OK.
- `shellcheck scripts/patch-config.yml.sh scripts/lib/patch-config/*.sh` — OK.
- `./scripts/patch-config.yml.sh --list-modules` — повертає модулі.
- `./scripts/patch-config.yml.sh --dry-run --modules rest_context,matomo_context,render_config` — dry-run працює.
- `./scripts/patch-config.yml.sh --dry-run --modules render_config` — модуль рендера коректно добирає залежні контексти.

### Нотатка
- Ітерація виконана без зміни публічного контракту `ui-config/config.yml`; змінено лише структуру скрипта та керованість запуску.

## [2026-03-23] Refactor (ітерація 3) — модульна декомпозиція `scripts/smoke-test.sh`

### Зроблено
- `scripts/smoke-test.sh` перетворено на оркестратор модулів.
- Додано модульну структуру:
  - `scripts/lib/smoke-test/helpers.sh`
  - `scripts/lib/smoke-test/env.sh`
  - `scripts/lib/smoke-test/modules.sh`
- Додано керування запуском:
  - `--dry-run` (без реальних HTTP/header/CORS запитів),
  - `--modules <m1,m2>` (вибірковий запуск перевірок),
  - `--list-modules`.
- Виділено функціональні модулі:
  - `context`,
  - `required_checks`,
  - `security_headers`,
  - `cors_safety`,
  - `sitemap_optional`.

### Перевірено
- `bash -n scripts/smoke-test.sh scripts/lib/smoke-test/*.sh` — OK.
- `shellcheck scripts/smoke-test.sh scripts/lib/smoke-test/*.sh` — OK.
- `./scripts/smoke-test.sh --list-modules` — повертає доступні модулі.
- `./scripts/smoke-test.sh --dry-run` — повний dry-run працює.
- `./scripts/smoke-test.sh --dry-run --modules required_checks,security_headers,cors_safety` — селективний dry-run працює.

### Нотатка
- Поведінка smoke policy збережена: required checks лишаються blocking, sitemap check лишається warning-only.

## [2026-03-23] Refactor (ітерація 4) — декомпозиція `scripts/run-maintenance.sh`

### Зроблено
- Рознесено `run-maintenance` на прості окремі скрипти без зайвого ускладнення:
  - `scripts/run-maintenance-dspace.sh` — maintenance DSpace;
  - `scripts/run-maintenance-unmount.sh` — unmount GoogleDrive/SMB + cleanup `rclone`;
  - `scripts/run-maintenance-poweroff.sh` — `sudo poweroff`.
- `scripts/run-maintenance.sh` залишено thin-оркестратором (load `.env` + послідовний виклик кроків).

### Перевірено
- `bash -n scripts/run-maintenance.sh scripts/run-maintenance-dspace.sh scripts/run-maintenance-unmount.sh scripts/run-maintenance-poweroff.sh` — OK.
- `shellcheck` для цих 4 скриптів — OK.

### Нотатка
- Семантика запуску не змінена: cron, як і раніше, викликає `scripts/run-maintenance.sh`.

# CHANGELOG 2026 VOL 02

## Анотація тому

- Контекст: продовження ітеративних інфраструктурних змін DSpace 9 (аналітика, безпека, операційні процедури).
- Зміст: Matomo-інтеграція для DSpace UI, CSP-узгодження, валідація DoD.
- Ключові напрямки: IaC-підхід через `.env` + patch-скрипти, безпечний rollout малими кроками.

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

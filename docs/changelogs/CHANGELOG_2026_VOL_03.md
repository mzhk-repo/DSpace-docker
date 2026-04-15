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

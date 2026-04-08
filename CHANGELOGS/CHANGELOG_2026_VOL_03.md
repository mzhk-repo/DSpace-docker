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

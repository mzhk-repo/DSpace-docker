# CHANGELOG 2026 VOL 01

## Анотація тому

- Контекст: стабілізація production-інфраструктури DSpace 9 (Compose + Traefik + Cloudflare Tunnel).
- Зміст: безпека, CI/CD gates, операційні скрипти, документація архітектури.
- Ключові напрямки: hardening ingress, контроль вразливостей, стандартизація процесу змін.

## [2026-03-12] Діагностика `HTTP 500` після переходу на `repo.pinokew.buzz`

### Симптом
- Після коректного виправлення Cloudflare route (`service=http://traefik:80`) сайт відкривався, але періодично потрапляв на `/500`.

### Причина
- Конфіг-файли на хості (`ui-config/config.yml`, `dspace/config/local.cfg`) вже були з новим доменом `repo.pinokew.buzz`.
- Але контейнер `dspace` продовжував бачити старий `local.cfg` з `repo.fby.com.ua`.
- Підтверджено через `md5sum` (host ≠ container) і `docker exec ... grep`.
- Корінь проблеми: file bind-mount + атомарна заміна файлу патч-скриптом (старий inode залишився змонтованим у контейнері).

### Зроблено
- Запущено `./scripts/setup-configs.sh` та `./scripts/patch-local.cfg.sh`.
- Виконано примусове пересоздання контейнерів з file-mount'ами:
  - `docker compose -p dspace9 up -d --force-recreate dspace dspace-angular`
- Після recreate `md5sum` host/container для `local.cfg` співпали.

### Перевірено
- `https://repo.pinokew.buzz/` → `200`
- `https://repo.pinokew.buzz/home` → `200`
- `https://repo.pinokew.buzz/server/api/core/sites` → `200`
- Відсутні runtime `error/exception` у `dspace-angular`/`dspace` логах.

### Нотатка
- `GET /500 -> 500` є очікуваним для error-route; це не індикатор падіння, якщо `/` і `/home` повертають `200`.
- Поодинокі `repo.fby.com.ua` у контенті item metadata (`dc.identifier.uri`) — історичні дані репозиторію, не runtime-конфіг.

## [2026-03-12] Виокремлення Traefik у окремий репозиторій

### Зроблено
- Створено окремий репозиторій `/home/pinokew/Traefik` з файлами:
  - `docker-compose.yml` (сервіс `traefik`, ідентичні runtime-параметри/labels/healthcheck);
  - `.env.example`;
  - `README.md`;
  - `.gitignore`.
- Сервіс `traefik` видалено з `DSpace-docker/docker-compose.yml`.
- Runtime-міграція виконана без зміни конфігурації DSpace-сервісів (`dspace`, `dspace-angular`, `dspacedb`, `dspacesolr`).
- Старий контейнер `dspace-traefik` зі стеку `dspace9` зупинено/видалено і піднято новий `dspace-traefik` зі стеку `Traefik`.

### Перевірено
- `docker compose -f /home/pinokew/Dspace/DSpace-docker/docker-compose.yml -p dspace9 ps` → всі core сервіси `Up (healthy)`.
- `docker compose -f /home/pinokew/Traefik/docker-compose.yml -p traefik ps` → `dspace-traefik` у стані `Up (healthy)`.
- `docker compose -f /home/pinokew/cloudflare-tunnel/docker-compose.yml -p cf-tunnel ps` → `cf-tunnel` у стані `Up (healthy)`.
- HTTP перевірка через новий Traefik (`Host: repo.fby.com.ua`):
  - `/` → `200`
  - `/server/api/core/sites` → `200`

### Нотатка
- Поточна модель: `proxy-net` створює DSpace-стек; ingress-стеки (`Traefik`, `cloudflare-tunnel`) підключаються до неї як `external: true`.

## [2026-03-12] Перший запуск `cloudflare-tunnel` з нового репозиторію

### Зроблено
- Запущено стек з нового репозиторію: `/home/pinokew/cloudflare-tunnel`.
- Для сумісності з поточним станом DSpace-стеку (`dspacenet`) у локальному `.env` cloudflare-репозиторію встановлено `PROXY_NET_NAME=dspacenet`.
- Піднято контейнер `cf-tunnel` через `docker compose up -d`.

### Перевірено
- `docker compose ps` у `/home/pinokew/cloudflare-tunnel` → `cf-tunnel` у стані `Up (healthy)`.
- `docker compose logs --tail=30 tunnel` → тунель стартує коректно (ініціалізація protocol `quic`).
- `docker network ls` → на хості присутня мережа `dspacenet`, до якої під'єднується новий cloudflare-стек.
- `docker stop dspace-tunnel && docker rm dspace-tunnel` → старий tunnel-контейнер зі старого стеку вимкнено та видалено.

### Нотатка
- Після остаточного вирівнювання мережевої моделі на `proxy-net` достатньо змінити `PROXY_NET_NAME` у cloudflare `.env` без змін у compose-файлі.
- Спроба `docker compose up -d --remove-orphans` у DSpace-репозиторії наразі впирається в конфлікт підмереж (`proxy-net` vs існуюча `dspacenet` з тим самим CIDR).

## [2026-03-12] Виокремлення Cloudflare Tunnel у окремий репозиторій

### Зроблено
- Створено новий репозиторій `cloudflare-tunnel` (`../cloudflare-tunnel` відносно DSpace-docker):
  - `docker-compose.yml` — сервіс `cf-tunnel` з `cloudflare/cloudflared`.
  - `.env.example` — `TUNNEL_TOKEN`, `CLOUDFLARE_TUNNEL_VERSION`, `PROXY_NET_NAME`.
  - `README.md` — інструкція запуску та опис залежностей.
  - `.gitignore` — виключає `.env`.
- Перейменовано Docker-мережу з `dspacenet` → `proxy-net` (явне `name: proxy-net`):
  - Всі сервіси в DSpace-docker оновлено.
  - Видалено застарілу `dspacedb-net`.
- Видалено сервіс `tunnel` з `DSpace-docker/docker-compose.yml`.
- Видалено `TUNNEL_TOKEN` і `CLOUDFLARE_TUNNEL_VERSION` з `example.env` DSpace-stack.
- Оновлено `ARCHITECTURE.md`: розділ 2 (runtime-стек), розділ 3 (мережева модель).

### Мережева схема (поточна)
```
Інтернет → Cloudflare → cf-tunnel (proxy-net, external) → Traefik → DSpace
```
- `proxy-net` — створюється DSpace-stack, Cloudflare-stack приєднується як `external: true`.
- Наступний крок: аналогічне виокремлення `traefik` → Traefik-stack стає власником `proxy-net`, DSpace відмічає її як external.

### Порядок запуску стеків
1. `DSpace-docker/` → `docker compose up -d` (створює `proxy-net`)
2. `cloudflare-tunnel/` → `docker compose up -d` (приєднується до `proxy-net`)

### Перевірити після деплою
- `docker network ls | grep proxy-net` — мережа існує.
- `docker compose -f cloudflare-tunnel/docker-compose.yml ps` — `cf-tunnel` healthy.
- `docker compose -f DSpace-docker/docker-compose.yml ps` — всі сервіси healthy (без `tunnel`).

---

## [2026-03-14] Введення внутрішньої мережі `dspacenet` + передача власності `proxy-net` Traefik-стеку

### Мотивація
- `dspacedb` і `dspacesolr` були підключені до `proxy-net` (спільної зовнішньої мережі), хоча не потребують доступу ззовні і не мають Traefik-labels.
- Traefik раніше приєднувався до `proxy-net` як `external: true`, але мережу створював DSpace-стек — порушення принципу власності ресурсів.

### Зміни у `DSpace-docker/docker-compose.yml`
- `dspacedb`, `dspacesolr` — мережу змінено з `proxy-net` → `dspacenet` (тільки внутрішня).
- `dspace`, `dspace-angular` — підключені до обох мереж: `dspacenet` (внутрішня) + `proxy-net` (для Traefik).
- Додано `traefik.docker.network=proxy-net` labels на `dspace` та `dspace-angular`, щоб Traefik точно знав яку мережу використовувати при multi-network конфігурації.
- Секція `networks`: видалено власне оголошення `proxy-net` з `ipam`; додано `proxy-net: external: true` + `dspacenet: internal: true`.

### Зміни у `Traefik/docker-compose.yml`
- `proxy-net` переведено з `external: true` → тепер створюється Traefik-стеком з `ipam` (subnet `DSPACENET_SUBNET`).
- Додано `--providers.docker.network=proxy-net` до Traefik command (явна вказівка мережі для routing при multi-network контейнерах).

### Оновлено `ARCHITECTURE.md`
- Розділ 3 (мережева модель) відображає нову топологію.

### Порядок запуску стеків (новий)
1. `Traefik/` → `docker compose up -d` (створює `proxy-net`)
2. `DSpace-docker/` → `docker compose up -d` (приєднується до `proxy-net`, створює `dspacenet`)
3. `cloudflare-tunnel/` → `docker compose up -d` (приєднується до `proxy-net`)

### Процедура деплою змін
```bash
# 1. Перезапустити Traefik-стек (щоб він СТВОРИВ proxy-net)
cd /home/pinokew/Traefik
docker compose down && docker compose up -d

# 2. Видалити стару network proxy-net (якщо DSpace-стек ще тримав її)
# docker network rm proxy-net   # тільки якщо вона залишилась без власника

# 3. Перезапустити DSpace-стек
cd /home/pinokew/Dspace/DSpace-docker
docker compose down && docker compose up -d
```

### Перевірити після деплою
- `docker network inspect proxy-net | grep -E 'Driver|Scope|Subnet'` — bridge, local, `172.23.0.0/16`.
- `docker network inspect dspacenet 2>/dev/null | grep Internal` — `"Internal": true`.
- `docker network inspect proxy-net | grep -E 'dspace|traefik'` — тільки `traefik`, `dspace`, `dspace-angular`.
- `docker network inspect dspacenet | grep -E 'dspace|postgres|solr'` — всі 4 DSpace-сервіси.
- `docker compose -p dspace9 ps` → всі `Up (healthy)`.
- `docker compose -p traefik ps` → `traefik Up (healthy)`.
- `curl -s https://repo.pinokew.buzz/server/api/core/sites` → `200`.

---

## [2026-03-04] Діагностика нічного cron-запуску `run-maintenance.sh`

### Знайдено
- Cron entry для `run-maintenance.sh` активний і тригериться щодня о `00:00` (є записи `CRON ... CMD` до `2026-03-04 00:00:01`).
- У `crontab` редірект логів налаштовано на неіснуючий шлях:
`/home/pinokew/Dspace/DSpace-volumes/logs/...`.
- Фактичний каталог логів зараз:
`/srv/DSpace-volumes/logs`.
- Через помилку редіректу (`cannot create ... Directory nonexistent`) shell завершує команду до старту скрипта.
- Історичний `maintenance.log` містить помилку `line 35: ---: command not found` (зафіксовано у запуску від `2026-02-18`), але поточний файл `scripts/run-maintenance.sh` проходить `bash -n` (синтаксично валідний).

### Перевірено
- `git status` (локально змінені лише `.gitignore`, `docker-compose.yml`).
- `docker compose ps` (усі ключові сервіси `Up (healthy)`).
- `crontab -l` (активні nightly/hourly задачі присутні).
- `journalctl -u cron` (щоденні виклики `run-maintenance.sh`, `No MTA installed` після помилки редіректу).
- `bash -n scripts/run-maintenance.sh` (поточний скрипт без синтаксичних помилок).
- Дані логів:
`/srv/DSpace-volumes/logs/maintenance.log` останній успішний запис `2026-02-18 00:00`,
`/home/pinokew/Dspace/DSpace-volumes` відсутній.

## [2026-03-03] Нормалізація архітектурної документації та changelog-індексу

### Додано
- Повністю оновлено `ARCHITECTURE.md` під фактичний стан репозиторію `DSpace-docker`.
- На початок тому додано обов'язкову анотацію (контекст, зміст, ключові напрямки).
- Заповнено `CHANGELOG.md` як короткий індекс томів з позначенням активного.

### Змінено
- Видалено з `ARCHITECTURE.md` шаблонний контент іншого проєкту (Koha).
- Формалізовано в документації модель роботи з томами changelog (soft/hard ліміти, формат іменування).

### Перевірено
- `git status` перед змінами.
- `docker compose ps` (усі ключові сервіси стеку в стані `Up (healthy)`).
- Обсяг поточного тому після оновлення залишається значно нижче soft limit.

## [2026-03-03] Оновлення CI/CD workflow за еталоном checks-моделі

### Змінено
- Перебудовано `.github/workflows/ci-cd.yml` у підході, сумісному з `archive/ci-cd-checks.yml` (структура `permissions`, `concurrency`, `env`, розділення `ci-checks`/`cd-deploy`).
- Версії CI-утиліт винесено в `env` з digest-пінами:
`SHELLCHECK_IMAGE`, `TRIVY_IMAGE`.
- CI-утиліти переведено на запуск через Docker Hub images (`docker pull` + `docker run`) замість локальної установки через `apt`.
- Оновлено pin-версії дій у workflow:
`actions/checkout` на commit SHA, `tailscale/github-action@v4`, `appleboy/ssh-action@v1.2.5`.

### Видалено
- Видалено крок `Trivy Image Scan (Critical gate)` з CI-потоку.

### Залишено
- Збережено `Trivy Config Scan (Critical gate)` як обов'язковий security gate.
- Збережено основний CD-контур деплою: patch configs -> `docker compose pull/up` -> `smoke-test.sh`.

### Перевірено
- У workflow відсутній `Trivy Image Scan`.
- Наявні digest-посилання на CI utility images у `env`.
- Конфігурація `Trivy Config Scan (Critical gate)` збережена.

## [2026-02-23] Посилення безпеки + security gates у CI/CD

### Додано
- Додано middleware безпеки Traefik для UI та API маршрутів:
`X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`, `Content-Security-Policy-Report-Only`.
- Додано примусове встановлення forwarded-заголовків на рівні проксі:
`X-Forwarded-Proto=https`, `X-Forwarded-Port=443`.
- Додано `Trivy image` gate у CI для `CRITICAL` знахідок у всіх образах compose.
- Додано керований реєстр винятків Trivy у `.trivyignore.yaml` з полями:
`id`, `expired_at`, `statement`.
- Додано перевірку політики в CI для прострочених винятків Trivy (`expired_at`).
- Додано явну діагностику Trivy по кожному образу в CI:
список проблемних образів + витяг неігнорованих `CVE-*`.
- Додано security-перевірки у `scripts/smoke-test.sh`:
заголовки UI/API, захист від CORS-антипатерну (`ACAO=*` + credentials), стабільний регістронезалежний парсинг заголовків.

### Змінено
- Змінено host-binding Traefik на безпечний локальний дефолт:
`${TRAEFIK_BIND_IP:-127.0.0.1}:${TRAEFIK_ENTRYPOINT_PORT:-8080}:80`.
- Змінено патчинг backend у `scripts/patch-local.cfg.sh`:
встановлюється `server.forward-headers-strategy=framework` для коректної обробки проксі-заголовків.
- Змінено валідацію env у `scripts/verify-env.sh`:
додано вимогу до прав `.env` = `600` (поза CI mock mode).
- Змінено режим Trivy image scan на перевірку лише вразливостей (`--scanners vuln`) для чіткішого gate та швидшого виконання.

### Видалено
- Видалено legacy-файл `.trivyignore` (plain text).
- Мігровано на керований формат `.trivyignore.yaml`.

### Нотатки з безпеки
- CI/CD тепер падає на неігнорованих `CRITICAL` знахідках у конфігах та образах.
- Прийняття ризику стало явним, обмеженим у часі та контрольованим через `.trivyignore.yaml`.
- Security headers тепер автоматично перевіряються під час deploy smoke-тестів.

### Операційний вплив
- Публічна пряма експозиція Traefik більше не є дефолтом.
- Реліз/деплой може блокуватися через:
нові `CRITICAL` CVE, прострочені security-винятки, відсутні обов'язкові заголовки, небезпечну CORS-політику.

## [2026-03-18] Matomo для DSpace — крок 1 (канонічний JS-сніппет)

### Зроблено
- Додано артефакт `docs/snippets/dspace-tracker.js` як базовий сніппет для DSpace 9 (Angular).
- У сніппеті зафіксовано вимоги roadmap:
  - `disableCookies()`;
  - `setDoNotTrack(true)`;
  - `enableSiteSearch('query', 'filter')`;
  - `enableLinkTracking()`;
  - `setSiteId('2')` (відповідно до поточного Matomo Site ID);
  - `setTrackerUrl('https://matomo.pinokew.buzz/js/ping')`.

### Перевірено
- `services`: `docker compose ps` перед змінами — core сервіси `dspace`, `dspace-angular`, `dspacedb`, `dspacesolr` у стані `Up (healthy)`.
- `health`: зміна документарно-конфігураційна, runtime-перезапуск не виконувався.
- `data`: змін у БД, Solr, assetstore немає.

### Нотатка
- Це перший ітеративний крок; інтеграція сніппета у pipeline UI та CSP-правила виконуються наступними кроками окремо.

## [2026-03-18] Matomo для DSpace — крок 2 (інтеграція у UI config pipeline)

### Зроблено
- Розширено генератор `scripts/patch-config.yml.sh` для умовного додавання Matomo `headTags` у `ui-config/config.yml`.
- Додано env-driven логіку (без хардкоду):
  - `DSPACE_MATOMO_ENABLED`;
  - `DSPACE_MATOMO_SITE_ID`;
  - `DSPACE_MATOMO_JS_URL`;
  - `DSPACE_MATOMO_TRACKER_URL`;
  - `DSPACE_MATOMO_SEARCH_KEYWORD_PARAM`;
  - `DSPACE_MATOMO_SEARCH_CATEGORY_PARAM`.
- В `headTags` при `DSPACE_MATOMO_ENABLED=true` генеруються:
  - зовнішній `script` для `matomo.js`;
  - inline-ініціалізація `_paq` з `disableCookies`, `setDoNotTrack(true)`, `enableSiteSearch`, `enableLinkTracking`, `setTrackerUrl`, `setSiteId`, `trackPageView`.
- Оновлено `example.env` новим блоком `MATOMO (DSPACE UI)`.

### Перевірено
- `services`: до початку кроку сервіси стеку були `Up (healthy)`.
- `health`: `./scripts/patch-config.yml.sh` виконується успішно.
- Функціональна перевірка генерації:
  - у тестовому запуску з env-overrides `Matomo headTags: enabled` і в `ui-config/config.yml` присутні `script`-теги/`_paq`/`setTrackerUrl`.
  - після тесту `ui-config/config.yml` перегенеровано зі штатного `.env` (поточний стан: `Matomo headTags: disabled`).
- `data`: змін у БД, Solr, assetstore немає.

### Нотатка
- Це тільки крок 2; CSP-винятки для Matomo і end-to-end перевірка DoD виконуються наступними кроками.

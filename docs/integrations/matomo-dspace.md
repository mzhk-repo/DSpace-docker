# Runbook: Matomo Analytics для DSpace 9 (Angular)

## 1) Мета

Цей runbook описує, як увімкнути Matomo-трекінг у DSpace UI через IaC-підхід:
- без ручних правок у контейнерах;
- через `.env` як SSOT;
- через генерацію `ui-config/config.yml` скриптом `scripts/patch-config.yml.sh`.

---

## 2) Передумови

1. У Matomo вже створено сайт для DSpace (Websites → Add new site).
2. Відомі параметри:
   - `Site ID`;
   - URL до `matomo.js`;
   - Tracker URL (може бути замаскований шлях, напр. `/js/ping`).
3. Репозиторій: `DSpace-docker`.

---

## 3) Які env-змінні використовуються і для чого

Додайте/оновіть змінні у `.env`:

```env
# --- MATOMO (DSPACE UI) ---
# true = вставляти Matomo headTags у ui-config/config.yml
DSPACE_MATOMO_ENABLED=true

# Site ID з Matomo Admin -> Websites
DSPACE_MATOMO_SITE_ID=2

# Єдина базова адреса Matomo
DSPACE_MATOMO_BASE_URL=https://matomo.pinokew.buzz

# Необов'язкові override-змінні, якщо треба нетипові шляхи
# DSPACE_MATOMO_JS_URL=https://matomo.pinokew.buzz/matomo.js
# DSPACE_MATOMO_TRACKER_URL=https://matomo.pinokew.buzz/js/ping

# Query parameter для пошукової фрази у DSpace
DSPACE_MATOMO_SEARCH_KEYWORD_PARAM=query

# Query parameter для фільтра/категорії пошуку у DSpace
DSPACE_MATOMO_SEARCH_CATEGORY_PARAM=filter
```

Пояснення:
- `DSPACE_MATOMO_ENABLED`: вмикає/вимикає вставку Matomo у фронтенд-конфіг.
- `DSPACE_MATOMO_SITE_ID`: ідентифікатор сайту в Matomo.
- `DSPACE_MATOMO_BASE_URL`: основна базова адреса Matomo; з неї автоматично будуються `matomo.js` і tracker endpoint.
- `DSPACE_MATOMO_JS_URL`: необов'язковий override, якщо `matomo.js` має нестандартний шлях.
- `DSPACE_MATOMO_TRACKER_URL`: необов'язковий override, якщо tracker endpoint має нестандартний шлях.
- `DSPACE_MATOMO_SEARCH_KEYWORD_PARAM`: назва URL-параметра пошукового рядка (`query` у DSpace).
- `DSPACE_MATOMO_SEARCH_CATEGORY_PARAM`: назва URL-параметра фільтра (`filter` у DSpace).

---

## 4) Який сніппет генерується

При `DSPACE_MATOMO_ENABLED=true` генератор додає до `ui-config/config.yml`:
- `script src=<DSPACE_MATOMO_BASE_URL>/matomo.js`;
- inline ініціалізацію `_paq` з методами:
  - `disableCookies`;
  - `setDoNotTrack(true)`;
  - `enableSiteSearch('<keyword>','<category>')`;
  - `enableLinkTracking`;
   - `setTrackerUrl('<DSPACE_MATOMO_BASE_URL>/js/ping')`;
  - `setSiteId('<site_id>')`;
  - `trackPageView`.

Канонічний артефакт сніппета: `docs/snippets/dspace-tracker.js`.

---

## 5) Застосування змін

1. Оновити `.env`.
2. Перегенерувати UI-конфіг:

```bash
./scripts/patch-config.yml.sh
```

3. Перезапустити UI-сервіс (або весь стек):

```bash
docker compose up -d --force-recreate dspace-angular
```

---

## 6) Швидка перевірка

1. Відкрити UI DSpace у браузері.
2. DevTools → Network:
   - є запит до `<DSPACE_MATOMO_BASE_URL>/matomo.js`;
   - є запити на tracker endpoint Matomo.
3. DevTools → Application → Cookies:
   - відсутні `_pk_*` cookies (через `disableCookies`).
4. Matomo Realtime:
   - фіксується page view.

---

## 7) Примітки для наступних кроків

- Для повної працездатності потрібен CSP-дозвіл на Matomo-домен у `script-src` і `connect-src` (окремий крок).
- Для Bitstream Downloads використовується `enableLinkTracking()` + Download URL patterns у Matomo Admin.
- Якщо `DSPACE_MATOMO_ENABLED=false`, Matomo-теги не додаються в `ui-config/config.yml`.

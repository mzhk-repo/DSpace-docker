#!/bin/bash
set -e

# --- 1. Load .env (Robust Mode) ---
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
ENV_FILE="$SCRIPT_DIR/../.env"

if [ -f "$ENV_FILE" ]; then
    echo "🌍 Loading environment variables..."
    # Читаємо файл порядково, щоб уникнути проблем з пробілами без лапок
    while IFS='=' read -r key value; do
        # Пропускаємо коментарі та порожні рядки (хоча grep їх вже відфільтрував, перестрахуємось)
        [[ "$key" =~ ^#.*$ ]] && continue
        [[ -z "$key" ]] && continue
        
        # Видаляємо можливі пробіли на початку/кінці значення
        # та прибираємо лапки, якщо вони є (щоб не було подвійних)
        value=$(echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")

        # Експортуємо змінну
        export "$key=$value"
    done < <(grep -vE '^\s*#' "$ENV_FILE" | grep -vE '^\s*$')
else
    echo "❌ Error: .env file not found."
    exit 1
fi

TARGET_FILE="dspace/config/local.cfg"

echo "🔧 Patching Backend Configuration (FULL SYNC)..."

# Видаляє рядки конфігу за точним ключем на початку рядка: "key = ..."
delete_config_key() {
    local key="$1"
    local file="$2"
    local tmp
    tmp=$(mktemp)
    awk -v k="$key" 'index($0, k " = ") == 1 {next} {print}' "$file" > "$tmp"
    mv "$tmp" "$file"
}

# Функція: видаляє ключ, якщо він є, і додає новий
set_config() {
    local key="$1"
    local value="$2"
    local file="$3"
    
    # Видаляємо старий рядок
    if grep -Fq "$key = " "$file"; then
        delete_config_key "$key" "$file"
    fi
    
    # Додаємо новий
    echo "$key = $value" >> "$file"
    echo "   Set: $key"
}

# Функція: ПОВНІСТЮ ВИДАЛЯЄ ключ
remove_config() {
    local key="$1"
    local file="$2"
    if grep -Fq "$key = " "$file"; then
        delete_config_key "$key" "$file"
        echo "   REMOVED (Clean-up): $key"
    fi
}

# --- 2. CLEANUP ---
echo "🧹 Cleaning up unstable Spring Boot configs..."
remove_config "server.tomcat.internal-proxies" "$TARGET_FILE"
remove_config "server.tomcat.remote-ip-header" "$TARGET_FILE"
remove_config "server.tomcat.protocol-header" "$TARGET_FILE"
remove_config "server.tomcat.port-header" "$TARGET_FILE"

# --- 3. BASIC URLS ---
set_config "dspace.dir" "${DSPACE_DIR:-/dspace}" "$TARGET_FILE"
set_config "dspace.name" "${DSPACE_NAME:-DSpace Repository}" "$TARGET_FILE"
set_config "dspace.ui.url" "${DSPACE_UI_BASEURL}" "$TARGET_FILE"
set_config "dspace.server.url" "${DSPACE_REST_BASEURL}" "$TARGET_FILE"
set_config "dspace.server.ssr.url" "${DSPACE_REST_SSRBASEURL:-http://dspace:8080/server}" "$TARGET_FILE"

# --- 4. DATABASE ---
DB_URL="jdbc:postgresql://dspacedb:${POSTGRES_INTERNAL_PORT:-5432}/${POSTGRES_DB:-dspace}"
set_config "db.url" "$DB_URL" "$TARGET_FILE"
set_config "db.username" "${POSTGRES_USER:-dspace}" "$TARGET_FILE"
set_config "db.password" "${POSTGRES_PASSWORD:-dspace}" "$TARGET_FILE"

# --- 5. SOLR ---
SOLR_URL="http://dspacesolr:${SOLR_INTERNAL_PORT:-8983}/solr"
set_config "solr.server" "$SOLR_URL" "$TARGET_FILE"

# --- 6. PROXY (SECURE MODE) ---
set_config "useProxies" "true" "$TARGET_FILE"
# Довіряємо тільки нашій підмережі (Docker Network), де живе Traefik
set_config "proxies.trusted.ipranges" "${DSPACENET_SUBNET:-172.23.0.0/16}" "$TARGET_FILE"
# Обробка X-Forwarded-* від reverse proxy (важливо для secure cookies/OIDC redirect URLs)
set_config "server.forward-headers-strategy" "framework" "$TARGET_FILE"

# --- 7. CORS (METHODS & ORIGINS) ---
# Додано allowed-methods
set_config "rest.cors.allowed-origins" "https://${DSPACE_HOSTNAME}, http://${DSPACE_HOSTNAME}, ${DSPACE_UI_LOCALHOST}" "$TARGET_FILE"
set_config "rest.cors.allowed-methods" "${CORS_ALLOWED_METHODS:-GET, POST, PUT, DELETE, PATCH, OPTIONS, HEAD}" "$TARGET_FILE"

# --- 8. AUTHENTICATION ---
# Додано налаштування методів аутентифікації
set_config "plugin.sequence.org.dspace.authenticate.AuthenticationMethod" "${AUTH_METHODS:-org.dspace.authenticate.OidcAuthentication, org.dspace.authenticate.PasswordAuthentication}" "$TARGET_FILE"

# --- 9. OIDC CONFIGURATION ---
set_config "authentication-oidc.client-id" "${OIDC_CLIENT_ID}" "$TARGET_FILE"
set_config "authentication-oidc.client-secret" "${OIDC_CLIENT_SECRET}" "$TARGET_FILE"
set_config "authentication-oidc.authorize-endpoint" "${OIDC_AUTHORIZE_ENDPOINT}" "$TARGET_FILE"
set_config "authentication-oidc.token-endpoint" "${OIDC_TOKEN_ENDPOINT}" "$TARGET_FILE"
set_config "authentication-oidc.user-info-endpoint" "${OIDC_USER_INFO_ENDPOINT}" "$TARGET_FILE"
set_config "authentication-oidc.issuer" "${OIDC_ISSUER}" "$TARGET_FILE"
set_config "authentication-oidc.redirect-url" "${OIDC_REDIRECT_URL}" "$TARGET_FILE"
set_config "authentication-oidc.can-self-register" "${OIDC_CAN_SELF_REGISTER:-true}" "$TARGET_FILE"
set_config "authentication-oidc.scopes" "${OIDC_SCOPES:-openid,email,profile}" "$TARGET_FILE"
set_config "authentication-oidc.user-email-attribute" "${OIDC_EMAIL_ATTR:-email}" "$TARGET_FILE"
if [ -n "$OIDC_DOMAIN" ]; then
    set_config "authentication-oidc.domain" "$OIDC_DOMAIN" "$TARGET_FILE"
fi

# --- 10. EPERSON & LOGIC ---
set_config "request.item.type" "${REQUEST_ITEM_TYPE:-logged}" "$TARGET_FILE"
set_config "request.item.helpdesk.override" "${REQUEST_ITEM_HELPDESK_OVERRIDE:-false}" "$TARGET_FILE"

# --- 11. UPLOAD ---
set_config "spring.servlet.multipart.max-file-size" "${MAX_FILE_SIZE:-512MB}" "$TARGET_FILE"
set_config "spring.servlet.multipart.max-request-size" "${MAX_REQUEST_SIZE:-512MB}" "$TARGET_FILE"
set_config "webui.content_disposition_threshold" "8589934592" "$TARGET_FILE"
set_config "server.servlet.session.timeout" "120m" "$TARGET_FILE"

# --- 12. SEO & SITEMAPS ---
# Генерувати щодня о 01:15 ночі
set_config "sitemap.cron" "0 15 1 * * ?" "$TARGET_FILE"
# Генерувати sitemaps.org (XML) та htmlmap (HTML)
set_config "sitemap.allowed-sitemaps" "sitemaps.org, htmlmap" "$TARGET_FILE"
# URL для пошуковиків (має співпадати з публічним)
set_config "sitemap.domain" "${DSPACE_UI_BASEURL}/sitemap" "$TARGET_FILE"

echo "✅ Configuration fixed. All keys synced."

# --- E-MAIL / SMTP CONFIGURATION ---

set_config "mail.server" "${DSPACE_MAIL_SERVER:-smtp.gmail.com}" "$TARGET_FILE"
set_config "mail.server.port" "${DSPACE_MAIL_PORT:-587}" "$TARGET_FILE"

set_config "mail.server.username" "${DSPACE_MAIL_USERNAME}" "$TARGET_FILE"
set_config "mail.server.password" "${DSPACE_MAIL_PASSWORD}" "$TARGET_FILE"

# Стандартні налаштування безпеки для Gmail/Office365 (TLS, Auth)
set_config "mail.extraproperties" "mail.smtp.connectiontimeout=5000, mail.smtp.timeout=5000, mail.smtp.writetimeout=5000, mail.smtp.starttls.enable=true, mail.smtp.auth=true" "$TARGET_FILE"

# Адреси відправника та адміністраторів
set_config "mail.from.address" "${DSPACE_MAIL_USERNAME}" "$TARGET_FILE"
set_config "mail.feedback.recipient" "${DSPACE_MAIL_FEEDBACK:-${DSPACE_MAIL_ADMIN}}" "$TARGET_FILE"
set_config "mail.admin" "${DSPACE_MAIL_ADMIN}" "$TARGET_FILE"
set_config "mail.alert.recipient" "${DSPACE_MAIL_ADMIN}" "$TARGET_FILE"
set_config "mail.registration.notify" "${DSPACE_MAIL_ADMIN}" "$TARGET_FILE"

# --- БЕЗПЕКА ТА ВХІД (AUTH) ---
# Вимикаємо самореєстрацію для звичайних паролів (прибирає лінк "Register")
# Тепер створити користувача з паролем може тільки адмін вручну
set_config "user.registration" "false" "$TARGET_FILE"
set_config "user.forgot-password" "false" "$TARGET_FILE"

# --- МОВНІ НАЛАШТУВАННЯ (LANGUAGES) ---
# Залишаємо тільки Українську (за замовчуванням) та Англійську
set_config "default.locale" "uk" "$TARGET_FILE"
set_config "webui.supported.locales" "uk, en" "$TARGET_FILE"

# --- GOOGLE ANALYTICS 4 CONFIGURATION ---
# Додаємо ці рядки в scripts/patch-local.cfg.sh

# 1. Основний ключ GA4.
set_config "google.analytics.key" "${DSPACE_GA_ID}" "$TARGET_FILE"

# 2. API Secret (ОБОВ'ЯЗКОВО для GA4 для трекінгу скачувань)
set_config "google.analytics.api-secret" "${DSPACE_GA_API_SECRET}" "$TARGET_FILE"

# 3. CRON розклад (кожні 5 хвилин відправляти дані про скачування)
set_config "google.analytics.cron" "0 0/5 * * * ?" "$TARGET_FILE"

# 4. Ліміт буфера
set_config "google.analytics.buffer.limit" "256" "$TARGET_FILE"

# 5. Рахуємо тільки оригінальні файли
set_config "google-analytics.bundles" "ORIGINAL" "$TARGET_FILE"

# --- MATOMO (DSPACE NATIVE FRONTEND INTEGRATION) ---
# DSpace Angular зчитує ці властивості через REST API /api/config/properties/matomo.*
# Якщо вони не задані коректно, трекер ініціалізується з дефолтами і події не потрапляють у Matomo.
set_config "matomo.enabled" "${DSPACE_MATOMO_ENABLED:-false}" "$TARGET_FILE"
set_config "matomo.request.siteid" "${DSPACE_MATOMO_SITE_ID:-1}" "$TARGET_FILE"

# Base URL Matomo (без /matomo.js і без /matomo.php). Основна змінна: DSPACE_MATOMO_BASE_URL.
# Для зворотної сумісності пробуємо вивести її з DSPACE_MATOMO_JS_URL або DSPACE_MATOMO_TRACKER_URL.
MATOMO_TRACKER_BASE_URL="${DSPACE_MATOMO_BASE_URL:-}"
if [ -z "$MATOMO_TRACKER_BASE_URL" ] && [ -n "${DSPACE_MATOMO_JS_URL:-}" ]; then
    MATOMO_TRACKER_BASE_URL="${DSPACE_MATOMO_JS_URL%/matomo.js}"
fi
if [ -z "$MATOMO_TRACKER_BASE_URL" ] && [ -n "${DSPACE_MATOMO_TRACKER_URL:-}" ]; then
    MATOMO_TRACKER_BASE_URL="${DSPACE_MATOMO_TRACKER_URL%/js/ping}"
    MATOMO_TRACKER_BASE_URL="${MATOMO_TRACKER_BASE_URL%/matomo.php}"
fi
MATOMO_TRACKER_BASE_URL="${MATOMO_TRACKER_BASE_URL%/}"
if [ -z "$MATOMO_TRACKER_BASE_URL" ]; then
    MATOMO_TRACKER_BASE_URL="http://localhost:8081"
fi
set_config "matomo.tracker.url" "$MATOMO_TRACKER_BASE_URL" "$TARGET_FILE"

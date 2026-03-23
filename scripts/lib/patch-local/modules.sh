#!/usr/bin/env bash

# shellcheck disable=SC2034
AVAILABLE_PATCH_MODULES=(
    cleanup
    basic_urls
    database
    db_rotation
    solr
    proxy
    cors
    auth
    oidc
    eperson
    upload
    seo
    email
    security
    languages
    ga4
    matomo
)

run_patch_module() {
    local module="$1"

    case "$module" in
        cleanup) module_cleanup ;;
        basic_urls) module_basic_urls ;;
        database) module_database ;;
        db_rotation) module_db_rotation ;;
        solr) module_solr ;;
        proxy) module_proxy ;;
        cors) module_cors ;;
        auth) module_auth ;;
        oidc) module_oidc ;;
        eperson) module_eperson ;;
        upload) module_upload ;;
        seo) module_seo ;;
        email) module_email ;;
        security) module_security ;;
        languages) module_languages ;;
        ga4) module_ga4 ;;
        matomo) module_matomo ;;
        *)
            echo "❌ Unknown module: $module"
            return 1
            ;;
    esac
}

module_cleanup() {
    echo "🧹 [module] cleanup"
    remove_config "server.tomcat.internal-proxies" "$TARGET_FILE"
    remove_config "server.tomcat.remote-ip-header" "$TARGET_FILE"
    remove_config "server.tomcat.protocol-header" "$TARGET_FILE"
    remove_config "server.tomcat.port-header" "$TARGET_FILE"
}

module_basic_urls() {
    echo "🔧 [module] basic_urls"
    set_config "dspace.dir" "${DSPACE_DIR:-/dspace}" "$TARGET_FILE"
    set_config "dspace.name" "${DSPACE_NAME:-DSpace Repository}" "$TARGET_FILE"
    set_config "dspace.ui.url" "${DSPACE_UI_BASEURL}" "$TARGET_FILE"
    set_config "dspace.server.url" "${DSPACE_REST_BASEURL}" "$TARGET_FILE"
    set_config "dspace.server.ssr.url" "${DSPACE_REST_SSRBASEURL:-http://dspace:8080/server}" "$TARGET_FILE"
}

module_database() {
    echo "🔧 [module] database"
    local db_url
    db_url="jdbc:postgresql://dspacedb:${POSTGRES_INTERNAL_PORT:-5432}/${POSTGRES_DB:-dspace}"
    set_config "db.url" "$db_url" "$TARGET_FILE"
    set_config "db.username" "${POSTGRES_USER:-dspace}" "$TARGET_FILE"
    set_config "db.password" "${POSTGRES_PASSWORD:-dspace}" "$TARGET_FILE"
}

module_db_rotation() {
    echo "🔧 [module] db_rotation"
    sync_db_role_password
}

module_solr() {
    echo "🔧 [module] solr"
    local solr_url
    solr_url="http://dspacesolr:${SOLR_INTERNAL_PORT:-8983}/solr"
    set_config "solr.server" "$solr_url" "$TARGET_FILE"
}

module_proxy() {
    echo "🔧 [module] proxy"
    set_config "useProxies" "true" "$TARGET_FILE"
    set_config "proxies.trusted.ipranges" "${DSPACENET_SUBNET:-172.23.0.0/16}" "$TARGET_FILE"
    set_config "server.forward-headers-strategy" "framework" "$TARGET_FILE"
}

module_cors() {
    echo "🔧 [module] cors"
    local cors_hostname ui_localhost
    cors_hostname="${DSPACE_HOSTNAME:-}"
    ui_localhost="${DSPACE_UI_LOCALHOST:-http://dspace-angular:80}"

    if [ -z "$cors_hostname" ] && [ -n "${DSPACE_UI_BASEURL:-}" ]; then
        cors_hostname="$(echo "${DSPACE_UI_BASEURL}" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://([^/:]+).*#\1#')"
    fi
    cors_hostname="${cors_hostname:-localhost}"

    set_config "rest.cors.allowed-origins" "https://${cors_hostname}, http://${cors_hostname}, ${ui_localhost}" "$TARGET_FILE"
    set_config "rest.cors.allowed-methods" "${CORS_ALLOWED_METHODS:-GET, POST, PUT, DELETE, PATCH, OPTIONS, HEAD}" "$TARGET_FILE"
}

module_auth() {
    echo "🔧 [module] auth"
    set_config "plugin.sequence.org.dspace.authenticate.AuthenticationMethod" "${AUTH_METHODS:-org.dspace.authenticate.OidcAuthentication, org.dspace.authenticate.PasswordAuthentication}" "$TARGET_FILE"
}

module_oidc() {
    echo "🔧 [module] oidc"
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

    if [ -n "${OIDC_DOMAIN:-}" ]; then
        set_config "authentication-oidc.domain" "$OIDC_DOMAIN" "$TARGET_FILE"
    fi
}

module_eperson() {
    echo "🔧 [module] eperson"
    set_config "request.item.type" "${REQUEST_ITEM_TYPE:-logged}" "$TARGET_FILE"
    set_config "request.item.helpdesk.override" "${REQUEST_ITEM_HELPDESK_OVERRIDE:-false}" "$TARGET_FILE"
}

module_upload() {
    echo "🔧 [module] upload"
    set_config "spring.servlet.multipart.max-file-size" "${MAX_FILE_SIZE:-512MB}" "$TARGET_FILE"
    set_config "spring.servlet.multipart.max-request-size" "${MAX_REQUEST_SIZE:-512MB}" "$TARGET_FILE"
    set_config "webui.content_disposition_threshold" "8589934592" "$TARGET_FILE"
    set_config "server.servlet.session.timeout" "120m" "$TARGET_FILE"
}

module_seo() {
    echo "🔧 [module] seo"
    set_config "sitemap.cron" "0 15 1 * * ?" "$TARGET_FILE"
    set_config "sitemap.allowed-sitemaps" "sitemaps.org, htmlmap" "$TARGET_FILE"
    set_config "sitemap.domain" "${DSPACE_UI_BASEURL}/sitemap" "$TARGET_FILE"
}

module_email() {
    echo "🔧 [module] email"
    set_config "mail.server" "${DSPACE_MAIL_SERVER:-smtp.gmail.com}" "$TARGET_FILE"
    set_config "mail.server.port" "${DSPACE_MAIL_PORT:-587}" "$TARGET_FILE"
    set_config "mail.server.username" "${DSPACE_MAIL_USERNAME}" "$TARGET_FILE"
    set_config "mail.server.password" "${DSPACE_MAIL_PASSWORD}" "$TARGET_FILE"
    set_config "mail.extraproperties" "mail.smtp.connectiontimeout=5000, mail.smtp.timeout=5000, mail.smtp.writetimeout=5000, mail.smtp.starttls.enable=true, mail.smtp.auth=true" "$TARGET_FILE"
    set_config "mail.from.address" "${DSPACE_MAIL_USERNAME}" "$TARGET_FILE"
    set_config "mail.feedback.recipient" "${DSPACE_MAIL_FEEDBACK:-${DSPACE_MAIL_ADMIN}}" "$TARGET_FILE"
    set_config "mail.admin" "${DSPACE_MAIL_ADMIN}" "$TARGET_FILE"
    set_config "mail.alert.recipient" "${DSPACE_MAIL_ADMIN}" "$TARGET_FILE"
    set_config "mail.registration.notify" "${DSPACE_MAIL_ADMIN}" "$TARGET_FILE"
}

module_security() {
    echo "🔧 [module] security"
    set_config "user.registration" "false" "$TARGET_FILE"
    set_config "user.forgot-password" "false" "$TARGET_FILE"
}

module_languages() {
    echo "🔧 [module] languages"
    set_config "default.locale" "uk" "$TARGET_FILE"
    set_config "webui.supported.locales" "uk, en" "$TARGET_FILE"
}

module_ga4() {
    echo "🔧 [module] ga4"
    set_config "google.analytics.key" "${DSPACE_GA_ID}" "$TARGET_FILE"
    set_config "google.analytics.api-secret" "${DSPACE_GA_API_SECRET}" "$TARGET_FILE"
    set_config "google.analytics.cron" "0 0/5 * * * ?" "$TARGET_FILE"
    set_config "google.analytics.buffer.limit" "256" "$TARGET_FILE"
    set_config "google-analytics.bundles" "ORIGINAL" "$TARGET_FILE"
}

module_matomo() {
    echo "🔧 [module] matomo"
    set_config "matomo.enabled" "${DSPACE_MATOMO_ENABLED:-false}" "$TARGET_FILE"
    set_config "matomo.request.siteid" "${DSPACE_MATOMO_SITE_ID:-1}" "$TARGET_FILE"

    local matomo_tracker_base_url
    matomo_tracker_base_url="${DSPACE_MATOMO_BASE_URL:-}"

    if [ -z "$matomo_tracker_base_url" ] && [ -n "${DSPACE_MATOMO_JS_URL:-}" ]; then
        matomo_tracker_base_url="${DSPACE_MATOMO_JS_URL%/matomo.js}"
    fi
    if [ -z "$matomo_tracker_base_url" ] && [ -n "${DSPACE_MATOMO_TRACKER_URL:-}" ]; then
        matomo_tracker_base_url="${DSPACE_MATOMO_TRACKER_URL%/js/ping}"
        matomo_tracker_base_url="${matomo_tracker_base_url%/matomo.php}"
    fi

    matomo_tracker_base_url="${matomo_tracker_base_url%/}"
    if [ -z "$matomo_tracker_base_url" ]; then
        matomo_tracker_base_url="http://localhost:8081"
    fi

    set_config "matomo.tracker.url" "$matomo_tracker_base_url" "$TARGET_FILE"
}

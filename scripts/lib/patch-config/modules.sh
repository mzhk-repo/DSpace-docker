#!/usr/bin/env bash

# shellcheck disable=SC2034
AVAILABLE_PATCH_CONFIG_MODULES=(
    rest_context
    matomo_context
    render_config
)

REST_CONTEXT_READY="false"
MATOMO_CONTEXT_READY="false"

run_patch_config_module() {
    local module="$1"

    case "$module" in
        rest_context) module_rest_context ;;
        matomo_context) module_matomo_context ;;
        render_config) module_render_config ;;
        *)
            echo "❌ Unknown module: $module"
            return 1
            ;;
    esac
}

module_rest_context() {
    local url url_no_proto host_port default_port

    echo "🔧 [module] rest_context"

    url="${DSPACE_REST_BASEURL:-http://localhost:8081/server}"

    if [[ "$url" == https* ]]; then
        REST_SSL="true"
        default_port="443"
    else
        REST_SSL="false"
        default_port="80"
    fi

    url_no_proto=$(echo "$url" | sed -E 's|^\w+://||')
    host_port=$(echo "$url_no_proto" | cut -d/ -f1)

    REST_NAMESPACE="/$(echo "$url_no_proto" | cut -d/ -f2-)"
    if [[ "$REST_NAMESPACE" == "/" ]]; then
        REST_NAMESPACE="/"
    fi

    if [[ "$host_port" == *":"* ]]; then
        REST_HOST=$(echo "$host_port" | cut -d: -f1)
        REST_PORT=$(echo "$host_port" | cut -d: -f2)
    else
        REST_HOST="$host_port"
        REST_PORT="$default_port"
    fi

    echo "   Detected REST Config: $REST_HOST:$REST_PORT (SSL: $REST_SSL)"
    REST_CONTEXT_READY="true"
}

module_matomo_context() {
    local matomo_enabled matomo_site_id matomo_base_url
    local matomo_js_url matomo_tracker_url matomo_search_keyword_param matomo_search_category_param

    echo "🔧 [module] matomo_context"

    matomo_enabled="$(echo "${DSPACE_MATOMO_ENABLED:-false}" | tr '[:upper:]' '[:lower:]')"
    MATOMO_HEAD_TAGS=""

    if [[ "$matomo_enabled" != "true" ]]; then
        echo "   Matomo headTags: disabled"
        MATOMO_CONTEXT_READY="true"
        return 0
    fi

    matomo_site_id="${DSPACE_MATOMO_SITE_ID:-}"
    matomo_base_url="${DSPACE_MATOMO_BASE_URL:-}"

    if [[ -z "$matomo_base_url" && -n "${DSPACE_MATOMO_JS_URL:-}" ]]; then
        matomo_base_url="${DSPACE_MATOMO_JS_URL%/matomo.js}"
    fi
    if [[ -z "$matomo_base_url" && -n "${DSPACE_MATOMO_TRACKER_URL:-}" ]]; then
        matomo_base_url="${DSPACE_MATOMO_TRACKER_URL%/js/ping}"
        matomo_base_url="${matomo_base_url%/matomo.php}"
    fi
    matomo_base_url="${matomo_base_url%/}"

    matomo_js_url="${DSPACE_MATOMO_JS_URL:-${matomo_base_url}/matomo.js}"
    matomo_tracker_url="${DSPACE_MATOMO_TRACKER_URL:-${matomo_base_url}/js/ping}"
    matomo_search_keyword_param="${DSPACE_MATOMO_SEARCH_KEYWORD_PARAM:-query}"
    matomo_search_category_param="${DSPACE_MATOMO_SEARCH_CATEGORY_PARAM:-filter}"

    if [[ -z "$matomo_site_id" || -z "$matomo_js_url" || -z "$matomo_tracker_url" ]]; then
        echo "⚠️  MATOMO enabled, but required vars are missing (DSPACE_MATOMO_SITE_ID and DSPACE_MATOMO_BASE_URL or explicit overrides). Skipping Matomo headTags."
        MATOMO_CONTEXT_READY="true"
        return 0
    fi

    MATOMO_HEAD_TAGS=$(cat <<EOF
      - tagName: script
        content: |
          var _paq = window._paq = window._paq || [];
          _paq.push(['disableCookies']);
          _paq.push(['setDoNotTrack', true]);
          _paq.push(['enableSiteSearch', '${matomo_search_keyword_param}', '${matomo_search_category_param}']);
          _paq.push(['enableLinkTracking']);
          _paq.push(['setTrackerUrl', '${matomo_tracker_url}']);
          _paq.push(['setSiteId', '${matomo_site_id}']);
          _paq.push(['trackPageView']);
          (function () {
            var d = document;
            var g = d.createElement('script');
            var s = d.getElementsByTagName('script')[0];
            g.async = true;
            g.src = '${matomo_js_url}';
            s.parentNode.insertBefore(g, s);
          })();
EOF
)

    echo "   Matomo headTags: enabled"
    MATOMO_CONTEXT_READY="true"
}

module_render_config() {
    local content

    echo "🔧 [module] render_config"

    if [ "$REST_CONTEXT_READY" != "true" ]; then
        module_rest_context
    fi

    if [ "$MATOMO_CONTEXT_READY" != "true" ]; then
        module_matomo_context
    fi

    content=$(cat <<EOF
ui:
  # UI (Angular) сервер слухає всередині контейнера завжди по HTTP
  ssl: false
  host: 0.0.0.0
  port: 8081
  nameSpace: /
  # Публічний URL для генерації посилань
  baseUrl: ${DSPACE_UI_BASEURL}
  useProxies: true

rest:
  # Налаштування для БРАУЗЕРА (куди стукати за даними)
  ssl: ${REST_SSL}
  host: ${REST_HOST}
  port: ${REST_PORT}
  nameSpace: ${REST_NAMESPACE}
  ssrBaseUrl: http://dspace:8080/server

themes:
  - name: dspace
    headTags:
      - tagName: link
        attributes:
          rel: icon
          href: assets/dspace/images/favicons/favicon.ico
          sizes: any
      - tagName: link
        attributes:
          rel: icon
          href: assets/dspace/images/favicons/favicon.svg
          type: image/svg+xml
      - tagName: link
        attributes:
          rel: manifest
          href: assets/dspace/images/favicons/manifest.webmanifest
${MATOMO_HEAD_TAGS}

#  Fallback language in which the UI will be rendered if the user's browser language is not an active language
fallbackLanguage: uk

# Languages. DSpace Angular holds a message catalog for each of the following languages.
# When set to active, users will be able to switch to the use of this language in the user interface.
languages:
  - code: uk
    label: Yкраї́нська
    active: true
  - code: en
    label: English
    active: true
  - code: ar
    label: العربية
    active: true
  - code: bn
    label: বাংলা
    active: true
  - code: ca
    label: Català
    active: true
  - code: cs
    label: Čeština
    active: true
  - code: de
    label: Deutsch
    active: true
  - code: el
    label: Ελληνικά
    active: true
  - code: es
    label: Español
    active: true
  - code: fa
    label: فارسی
    active: true
  - code: fi
    label: Suomi
    active: true
  - code: fr
    label: Français
    active: true
  - code: gd
    label: Gàidhlig
    active: true
  - code: gu
    label: ગુજરાતી
    active: true
  - code: hi
    label: हिंदी
    active: true
  - code: hu
    label: Magyar
    active: true
  - code: it
    label: Italiano
    active: true
  - code: kk
    label: Қазақ
    active: true
  - code: lv
    label: Latviešu
    active: true
  - code: mr
    label: मराठी
    active: true
  - code: nl
    label: Nederlands
    active: true
  - code: pl
    label: Polski
    active: true
  - code: pt-PT
    label: Português
    active: true
  - code: pt-BR
    label: Português do Brasil
    active: true
  - code: ru
    label: Русский
    active: false
  - code: sr-lat
    label: Srpski (lat)
    active: true
  - code: sr-cyr
    label: Српски
    active: true
  - code: sv
    label: Svenska
    active: true
  - code: ta
    label: தமிழ்
    active: true
  - code: tr
    label: Türkçe
    active: true
  - code: vi
    label: Tiếng Việt
    active: true
EOF
)

    write_content "$TARGET_FILE" "$content"
}

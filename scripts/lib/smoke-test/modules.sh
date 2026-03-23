#!/usr/bin/env bash

# shellcheck disable=SC2034
AVAILABLE_SMOKE_MODULES=(
  context
  required_checks
  security_headers
  cors_safety
  sitemap_optional
)

SMOKE_CONTEXT_READY="false"

run_smoke_module() {
  local module="$1"
  case "$module" in
    context) module_context ;;
    required_checks) module_required_checks ;;
    security_headers) module_security_headers ;;
    cors_safety) module_cors_safety ;;
    sitemap_optional) module_sitemap_optional ;;
    *)
      echo "❌ Unknown module: $module"
      return 1
      ;;
  esac
}

ensure_context() {
  if [ "$SMOKE_CONTEXT_READY" != "true" ]; then
    module_context
  fi
}

module_context() {
  echo "🔧 [module] context"

  HOST="${DSPACE_HOSTNAME:-repo.fby.com.ua}"
  ORIGIN="https://${HOST}"

  UI_URL="https://${HOST}/"
  API_URL="https://${HOST}/server/api/core/sites"
  OAI_URL="https://${HOST}/server/oai/request?verb=Identify"
  SITEMAP_URL1="https://${HOST}/sitemap_index.xml"
  SITEMAP_URL2="https://${HOST}/server/sitemaps/sitemap_index.xml"

  SMOKE_CONTEXT_READY="true"
  log "🚦 Smoke tests context prepared for host: ${HOST}"
}

module_required_checks() {
  ensure_context
  echo "🔧 [module] required_checks"

  require_check "UI Home" "$UI_URL" 200 "" "DSpace" 20 5
  require_check "REST API core/sites" "$API_URL" 200 "json" "" 30 3
  require_check "OAI Identify" "$OAI_URL" 200 "" "Identify" 20 5
}

module_security_headers() {
  ensure_context
  echo "🔧 [module] security_headers"

  require_header "UI nosniff" "$UI_URL" "X-Content-Type-Options" "^nosniff$"
  require_header "UI frame policy" "$UI_URL" "X-Frame-Options" "^(SAMEORIGIN|DENY)$"
  require_header "UI referrer policy" "$UI_URL" "Referrer-Policy" "^strict-origin-when-cross-origin$"
  require_header "UI CSP report-only" "$UI_URL" "Content-Security-Policy-Report-Only" ".+"

  require_header "API nosniff" "$API_URL" "X-Content-Type-Options" "^nosniff$"
  require_header "API frame policy" "$API_URL" "X-Frame-Options" "^(SAMEORIGIN|DENY)$"
  require_header "API referrer policy" "$API_URL" "Referrer-Policy" "^strict-origin-when-cross-origin$"
  require_header "API CSP report-only" "$API_URL" "Content-Security-Policy-Report-Only" ".+"
}

module_cors_safety() {
  ensure_context
  echo "🔧 [module] cors_safety"
  require_cors_safety "$API_URL" "$ORIGIN" "$HOST"
}

module_sitemap_optional() {
  ensure_context
  echo "🔧 [module] sitemap_optional"
  warn_sitemap_check "Sitemap (optional)" "$SITEMAP_URL1" "$SITEMAP_URL2"
}

#!/usr/bin/env bash

log()  { echo "[$(date '+%F %T')] $*"; }
fail() { echo "[$(date '+%F %T')] ❌ $*" >&2; exit 1; }

join_by() {
  local delimiter="$1"
  shift
  local first="true"
  local item
  for item in "$@"; do
    if [ "$first" = "true" ]; then
      printf '%s' "$item"
      first="false"
    else
      printf '%s%s' "$delimiter" "$item"
    fi
  done
}

http_check() {
  local name="$1"
  local url="$2"
  local expect_code="${3:-200}"
  local expect_ct_regex="${4:-}"
  local expect_kw="${5:-}"
  local attempts="${6:-20}"
  local sleep_s="${7:-5}"

  log "🔎 Checking: $name"
  log "    URL: $url"

  if [ "${DRY_RUN:-false}" = "true" ]; then
    log "[dry-run] would call URL with expected HTTP ${expect_code}, CT~'${expect_ct_regex}', keyword='${expect_kw}'"
    return 0
  fi

  local body_file
  body_file="$(mktemp)"

  for ((i=1; i<=attempts; i++)); do
    local out code ct ok=true
    out="$(curl -sS --max-time 12 --connect-timeout 5 -o "$body_file" -w "%{http_code} %{content_type}" "$url" || true)"

    code="${out%% *}"
    ct="${out#* }"

    [[ "$code" == "$expect_code" ]] || ok=false

    if [[ -n "$expect_ct_regex" ]]; then
      echo "$ct" | grep -Eqi "$expect_ct_regex" || ok=false
    fi

    if [[ -n "$expect_kw" ]]; then
      grep -qi "$expect_kw" "$body_file" || ok=false
    fi

    if [[ "$ok" == true ]]; then
      log "✅ OK ($name): HTTP $code, CT='$ct' (attempt $i/$attempts)"
      rm -f "$body_file"
      return 0
    fi

    log "… not ready ($name): HTTP $code, CT='$ct' (attempt $i/$attempts)"
    sleep "$sleep_s"
  done

  log "----- Response snippet ($name) -----"
  head -n 30 "$body_file" || true
  log "-----------------------------------"
  rm -f "$body_file"
  return 1
}

require_check() {
  local name="$1"; shift
  if ! http_check "$name" "$@"; then
    fail "Smoke check failed: $name"
  fi
}

warn_check() {
  local name="$1"; shift
  if ! http_check "$name" "$@"; then
    log "⚠️  WARNING: Optional check failed: $name. Not failing deploy."
  fi
  return 0
}

require_header() {
  local name="$1"
  local url="$2"
  local header_name="$3"
  local expected_regex="$4"

  log "🔎 Header check: $name"
  log "    URL: $url"
  log "    Expect: $header_name ~ $expected_regex"

  if [ "${DRY_RUN:-false}" = "true" ]; then
    log "[dry-run] would validate response header"
    return 0
  fi

  local headers actual
  headers="$(curl -sSI --max-time 12 --connect-timeout 5 "$url" || true)"
  actual="$(echo "$headers" | awk -v k="$header_name" '
    BEGIN { kl=tolower(k) ":" }
    tolower($0) ~ "^" kl {
      sub(/^[^:]*:[[:space:]]*/, "", $0)
      sub(/\r$/, "", $0)
      print
      exit
    }')"

  if [[ -z "$actual" ]]; then
    fail "Missing header '$header_name' for $name"
  fi

  if ! echo "$actual" | grep -Eqi "$expected_regex"; then
    fail "Header mismatch for $name: $header_name='$actual'"
  fi

  log "✅ Header OK ($name): $header_name='$actual'"
}

require_cors_safety() {
  local api_url="$1"
  local origin="$2"
  local host_header="$3"

  log "🔎 CORS safety check"
  log "    API URL: $api_url"
  log "    Origin: $origin"

  if [ "${DRY_RUN:-false}" = "true" ]; then
    log "[dry-run] would perform CORS preflight safety check"
    return 0
  fi

  local headers acao acc
  headers="$(curl -sS -D - -o /dev/null \
    --max-time 12 --connect-timeout 5 \
    -X OPTIONS \
    -H "Origin: $origin" \
    -H "Access-Control-Request-Method: GET" \
    -H "Host: $host_header" \
    "$api_url" || true)"

  acao="$(echo "$headers" | awk '
    tolower($0) ~ /^access-control-allow-origin:/ {
      sub(/^[^:]*:[[:space:]]*/, "", $0)
      sub(/\r$/, "", $0)
      print
      exit
    }')"
  acc="$(echo "$headers" | awk '
    tolower($0) ~ /^access-control-allow-credentials:/ {
      sub(/^[^:]*:[[:space:]]*/, "", $0)
      sub(/\r$/, "", $0)
      print
      exit
    }')"

  if [[ "$acao" == "*" ]] && echo "$acc" | grep -Eqi '^true$'; then
    fail "Insecure CORS combination detected: ACAO='*' with Allow-Credentials='true'"
  fi

  log "✅ CORS policy safe: ACAO='${acao:-<none>}', Allow-Credentials='${acc:-<none>}'"
}

warn_sitemap_check() {
  local name="$1"
  local url1="$2"
  local url2="$3"

  log "🔎 Checking: $name"
  log "    URL candidates:"
  log "      1) $url1"
  log "      2) $url2"

  if [ "${DRY_RUN:-false}" = "true" ]; then
    log "[dry-run] would check optional sitemap availability"
    return 0
  fi

  if http_check "$name" "$url1" 200 "" "sitemap" 2 3; then
    return 0
  fi

  if http_check "$name" "$url2" 200 "" "sitemap" 2 3; then
    return 0
  fi

  log "⚠️  WARNING: Sitemap is not available yet (expected after nightly generation). Not failing deploy."
  return 0
}

#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_DIR=$(mktemp -d)
export TEST_DIR
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/project/scripts/lib" "$TEST_DIR/bin" "$TEST_DIR/solr/search/conf" "$TEST_DIR/assets" "$TEST_DIR/db"
cp "$REPO/scripts/upgrade-dspace-10.1-swarm.sh" "$TEST_DIR/project/scripts/"
printf '<schema><field name="old"/></schema>\n' > "$TEST_DIR/solr/search/conf/schema.xml"
printf 'local config\n' > "$TEST_DIR/local.cfg"
cat > "$TEST_DIR/project/scripts/lib/autonomous-env.sh" <<'SH'
load_autonomous_env() {
  DSPACE_REST_VER=dspace-10.1 DSPACE_SOLR_VER=dspace-10.1 POSTGRES_VERSION=15
  VOL_SOLR_PATH="$TEST_DIR/solr" VOL_ASSETSTORE_PATH="$TEST_DIR/assets" VOL_POSTGRESQL_PATH="$TEST_DIR/db"
  DSPACE_APP_ENV_PAYLOAD_SECRET_BASE="app_${2}" DSPACE_POSTGRES_PASSWORD_SECRET_BASE="password_${2}"
  POSTGRES_USER=dspace
  [[ "$2" == prod ]] && POSTGRES_USER=produser
  AUTONOMOUS_ENV_TMP="$TEST_DIR/env"
}
cleanup_autonomous_env() { :; }
SH
printf '#!/bin/bash\necho registry/ui:test\n' > "$TEST_DIR/project/scripts/ui-image-reference.sh"
# shellcheck disable=SC2016
printf '#!/bin/bash\necho "deploy $ENVIRONMENT_NAME" >> "$TEST_DIR/actions"\n' > "$TEST_DIR/project/scripts/deploy-orchestrator-swarm.sh"
cat > "$TEST_DIR/bin/sudo" <<'SH'
#!/bin/bash
[[ "$1" == -n ]] && shift
exec "$@"
SH
cat > "$TEST_DIR/bin/docker" <<'SH'
#!/bin/bash
set -e
printf '%s\n' "$*" >> "$TEST_DIR/actions"
case "$1 $2" in
  'info --format') [[ "$*" == *ControlAvailable* ]] && echo true || echo node1 ;;
  'service inspect')
    service="$3"
    if [[ "$service" == *upgrade-dspace-101 ]]; then [[ "${TEST_JOB_EXISTS:-}" == yes ]]; exit; fi
    case "$*" in
      *Replicas*)
        case "$service" in
          *dspace-angular) flag=ui ;;
          *dspacesolr) flag=solr ;;
          *dspacedb) flag=db ;;
          *) flag=backend ;;
        esac
        [[ -e "$TEST_DIR/$flag-stopped" ]] && echo 0 || echo 1 ;;
      *ContainerSpec.Image*)
        case "$service" in *dspacesolr) echo dspace/dspace-solr:dspace-9_x ;; *dspacedb) echo postgres:15 ;; *) echo dspace/dspace:dspace-9_x ;; esac ;;
      */var/solr/data*) echo "$TEST_DIR/solr" ;;
      */dspace/config/local.cfg*) echo "$TEST_DIR/local.cfg" ;;
      */dspace/assetstore*) echo "$TEST_DIR/assets" ;;
      *'{{.Source}}'*) if [[ "${TEST_MOUNT_MISMATCH:-}" == yes ]]; then printf '%s\t/pgdata\n' "$TEST_DIR/assets"; else printf '%s\t/pgdata\n' "$TEST_DIR/db"; fi ;;
      *Networks*) echo net1 ;;
      *app_env_payload*) echo "app_${TEST_SECRETS_ENV:-${TEST_STACK_ENV:-dev}}_123" ;;
      *POSTGRES_PASSWORD*) echo "password_${TEST_SECRETS_ENV:-${TEST_STACK_ENV:-dev}}_123" ;;
      *) exit 1 ;;
    esac ;;
  'ps -q')
    case "$*" in
      *dspace_dspace-angular*) [[ -e "$TEST_DIR/ui-stopped" ]] || echo ui-container ;;
      *dspace_dspacesolr*)
        if [[ -e "$TEST_DIR/solr-stopped" && -e "$TEST_DIR/solr-delayed" ]]; then
          rm "$TEST_DIR/solr-delayed"; echo solr-container
        elif [[ ! -e "$TEST_DIR/solr-stopped" ]]; then echo solr-container; fi ;;
      *dspace_dspacedb*) echo db-container ;;
      *dspace_dspace*) [[ -e "$TEST_DIR/backend-stopped" ]] || echo backend-container ;;
    esac ;;
  'inspect solr-container') [[ "$*" == *State.Running* ]] && echo true || echo old-image ;;
  'inspect task1') [[ "${TEST_FAILURE:-}" == migration ]] && echo failed || echo complete ;;
  'inspect '*) echo true ;;
  'image inspect') : ;;
  'manifest inspect') if [[ "${TEST_FAILURE:-}" == preflight ]]; then echo 'simulated TLS handshake timeout' >&2; exit 1; fi ;;
  'create old-image'|'create dspace/dspace-solr:dspace-9_x') echo old-container ;;
  'create '*) echo new-container ;;
  'cp old-container:'*) cp "$TEST_DIR/solr/search/conf/schema.xml" "$3" ;;
  'cp new-container:'*) printf '<schema><field name="new"/></schema>\n' > "$3" ;;
  'rm old-container'|'rm new-container') : ;;
  'service scale')
    [[ "$*" == *dspace_dspace-angular=0* ]] && touch "$TEST_DIR/ui-stopped"
    [[ "$*" == *dspace_dspace=0* ]] && touch "$TEST_DIR/backend-stopped"
    [[ "$*" == *dspace_dspacesolr=0* ]] && touch "$TEST_DIR/solr-stopped"
    : ;;
  'service update') [[ "${TEST_FAILURE:-}" != solr ]] || exit 1; rm -f "$TEST_DIR/solr-stopped" ;;
  'exec solr-container') printf '%s\n' '{"initFailures":{},"status":{"search":{},"statistics":{},"authority":{},"oai":{},"qaevent":{},"suggestion":{}}}' ;;
  'exec db-container') if [[ "$*" == *POSTGRES_DB* ]]; then echo dspace; elif [[ "${TEST_STACK_ENV:-dev}" == prod ]]; then echo produser; else echo dspace; fi ;;
  'service create') : ;;
  'service ps') echo task1 ;;
  'service logs'|'service rm') : ;;
  *) echo "unexpected docker call: $*" >&2; exit 1 ;;
esac
SH
chmod +x "$TEST_DIR/bin/"*
export PATH="$TEST_DIR/bin:$PATH"
if TEST_FAILURE=preflight bash "$TEST_DIR/project/scripts/upgrade-dspace-10.1-swarm.sh" --env dev --maintenance-confirmed > /dev/null 2> "$TEST_DIR/preflight-error"; then exit 1; fi
rg -q 'simulated TLS handshake timeout' "$TEST_DIR/preflight-error"
rg -q 'Could not inspect UI image' "$TEST_DIR/preflight-error"
[[ ! -e "$TEST_DIR/backend-stopped" && ! -e "$TEST_DIR/project/.orchestrator-state" ]]
touch "$TEST_DIR/solr-delayed"
bash "$TEST_DIR/project/scripts/upgrade-dspace-10.1-swarm.sh" --env dev --maintenance-confirmed > "$TEST_DIR/output"
[[ "$(cat "$TEST_DIR/project/.orchestrator-state/dspace.upgrade-dspace-10.1/status")" == deploy-complete ]]
[[ -e "$TEST_DIR/solr/search/conf/schema.xml.before-dspace-10.1" ]]
rg -q 'name="new"' "$TEST_DIR/solr/search/conf/schema.xml"
rg -q '^deploy development$' "$TEST_DIR/actions"
if bash "$TEST_DIR/project/scripts/upgrade-dspace-10.1-swarm.sh" --env dev --maintenance-confirmed > /dev/null 2>&1; then exit 1; fi
rm -rf "$TEST_DIR/project/.orchestrator-state" "$TEST_DIR/solr/search/conf/schema.xml.before-dspace-10.1" "$TEST_DIR/ui-stopped" "$TEST_DIR/backend-stopped" "$TEST_DIR/solr-stopped"
printf '<schema><field name="old"/></schema>\n' > "$TEST_DIR/solr/search/conf/schema.xml"
: > "$TEST_DIR/actions"
if TEST_FAILURE=migration bash "$TEST_DIR/project/scripts/upgrade-dspace-10.1-swarm.sh" --env dev --maintenance-confirmed > /dev/null 2>&1; then exit 1; fi
[[ "$(cat "$TEST_DIR/project/.orchestrator-state/dspace.upgrade-dspace-10.1/status")" == migration-started ]]
[[ -e "$TEST_DIR/ui-stopped" && -e "$TEST_DIR/backend-stopped" ]]
if rg -q '^deploy ' "$TEST_DIR/actions"; then exit 1; fi
rm -rf "$TEST_DIR/project/.orchestrator-state" "$TEST_DIR/solr/search/conf/schema.xml.before-dspace-10.1" "$TEST_DIR/ui-stopped" "$TEST_DIR/backend-stopped" "$TEST_DIR/solr-stopped"
printf '<schema><field name="old"/></schema>\n' > "$TEST_DIR/solr/search/conf/schema.xml"
: > "$TEST_DIR/actions"
if TEST_FAILURE=solr bash "$TEST_DIR/project/scripts/upgrade-dspace-10.1-swarm.sh" --env dev --maintenance-confirmed > /dev/null 2>&1; then exit 1; fi
[[ -e "$TEST_DIR/ui-stopped" && -e "$TEST_DIR/backend-stopped" ]]
if rg -q '^service create' "$TEST_DIR/actions"; then exit 1; fi
rm -rf "$TEST_DIR/project/.orchestrator-state" "$TEST_DIR/solr/search/conf/schema.xml.before-dspace-10.1" "$TEST_DIR/ui-stopped" "$TEST_DIR/backend-stopped" "$TEST_DIR/solr-stopped"
printf '<schema><field name="old"/></schema>\n' > "$TEST_DIR/solr/search/conf/schema.xml"
mkdir -p "$TEST_DIR/project/.orchestrator-state/dspace.upgrade-dspace-10.1"
printf 'migration-started\n' > "$TEST_DIR/project/.orchestrator-state/dspace.upgrade-dspace-10.1/status"
touch "$TEST_DIR/ui-stopped" "$TEST_DIR/backend-stopped" "$TEST_DIR/solr-stopped"
if bash "$TEST_DIR/project/scripts/upgrade-dspace-10.1-swarm.sh" --env dev --maintenance-confirmed --resume-stopped > /dev/null 2>&1; then exit 1; fi
printf 'started\n' > "$TEST_DIR/project/.orchestrator-state/dspace.upgrade-dspace-10.1/status"
bash "$TEST_DIR/project/scripts/upgrade-dspace-10.1-swarm.sh" --env dev --maintenance-confirmed --resume-stopped > /dev/null
[[ "$(cat "$TEST_DIR/project/.orchestrator-state/dspace.upgrade-dspace-10.1/status")" == deploy-complete ]]
rm -rf "$TEST_DIR/project/.orchestrator-state" "$TEST_DIR/solr/search/conf/schema.xml.before-dspace-10.1" "$TEST_DIR/ui-stopped" "$TEST_DIR/backend-stopped" "$TEST_DIR/solr-stopped"
printf '<schema><field name="old"/></schema>\n' > "$TEST_DIR/solr/search/conf/schema.xml"
: > "$TEST_DIR/actions"
if TEST_STACK_ENV=prod bash "$TEST_DIR/project/scripts/upgrade-dspace-10.1-swarm.sh" --env prod --maintenance-confirmed > /dev/null 2>&1; then exit 1; fi
[[ ! -s "$TEST_DIR/actions" ]]
if TEST_STACK_ENV=dev bash "$TEST_DIR/project/scripts/upgrade-dspace-10.1-swarm.sh" --env prod --maintenance-confirmed --production-confirmed > /dev/null 2>&1; then exit 1; fi
if rg -q '^service scale ' "$TEST_DIR/actions"; then exit 1; fi
: > "$TEST_DIR/actions"
if TEST_STACK_ENV=prod TEST_SECRETS_ENV=dev bash "$TEST_DIR/project/scripts/upgrade-dspace-10.1-swarm.sh" --env prod --maintenance-confirmed --production-confirmed > /dev/null 2>&1; then exit 1; fi
if rg -q '^service scale ' "$TEST_DIR/actions"; then exit 1; fi
: > "$TEST_DIR/actions"
if TEST_STACK_ENV=prod TEST_MOUNT_MISMATCH=yes bash "$TEST_DIR/project/scripts/upgrade-dspace-10.1-swarm.sh" --env prod --maintenance-confirmed --production-confirmed > /dev/null 2>&1; then exit 1; fi
if rg -q '^service scale ' "$TEST_DIR/actions"; then exit 1; fi
: > "$TEST_DIR/actions"
if TEST_STACK_ENV=prod TEST_JOB_EXISTS=yes bash "$TEST_DIR/project/scripts/upgrade-dspace-10.1-swarm.sh" --env prod --maintenance-confirmed --production-confirmed --preflight-only > /dev/null 2>&1; then exit 1; fi
if rg -q '^service (scale|update|create) ' "$TEST_DIR/actions"; then exit 1; fi
: > "$TEST_DIR/actions"
TEST_STACK_ENV=prod bash "$TEST_DIR/project/scripts/upgrade-dspace-10.1-swarm.sh" --env prod --maintenance-confirmed --production-confirmed --preflight-only > "$TEST_DIR/preflight"
rg -q 'Preflight passed for prod' "$TEST_DIR/preflight"
[[ ! -e "$TEST_DIR/project/.orchestrator-state/dspace.upgrade-dspace-10.1" ]]
if rg -q '^service (scale|update|create) ' "$TEST_DIR/actions"; then exit 1; fi
: > "$TEST_DIR/actions"
TEST_STACK_ENV=prod bash "$TEST_DIR/project/scripts/upgrade-dspace-10.1-swarm.sh" --env prod --maintenance-confirmed --production-confirmed > /dev/null
rg -q '^deploy production$' "$TEST_DIR/actions"
[[ "$(cat "$TEST_DIR/project/.orchestrator-state/dspace.upgrade-dspace-10.1/status")" == deploy-complete ]]
rm -rf "$TEST_DIR/project/.orchestrator-state" "$TEST_DIR/solr/search/conf/schema.xml.before-dspace-10.1" "$TEST_DIR/ui-stopped" "$TEST_DIR/backend-stopped" "$TEST_DIR/solr-stopped"
printf '<schema><field name="old"/></schema>\n' > "$TEST_DIR/solr/search/conf/schema.xml"
mkdir -p "$TEST_DIR/project/.orchestrator-state/dspace.upgrade-dspace-10.1"
printf 'started\n' > "$TEST_DIR/project/.orchestrator-state/dspace.upgrade-dspace-10.1/status"
touch "$TEST_DIR/ui-stopped" "$TEST_DIR/backend-stopped" "$TEST_DIR/solr-stopped"
TEST_STACK_ENV=prod bash "$TEST_DIR/project/scripts/upgrade-dspace-10.1-swarm.sh" --env prod --maintenance-confirmed --production-confirmed --resume-stopped > /dev/null
[[ "$(cat "$TEST_DIR/project/.orchestrator-state/dspace.upgrade-dspace-10.1/status")" == deploy-complete ]]
printf 'Mocked dev and prod preflight, confirmation, success, failure and resume: OK\n'

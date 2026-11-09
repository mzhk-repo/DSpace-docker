#!/usr/bin/env bash
# One-time DSpace 9 to 10.1 upgrade for the existing dev Swarm stack.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT_DIR="${ROOT_DIR}/scripts"
STACK_NAME="${STACK_NAME:-dspace}"

usage() {
  echo 'Usage: bash scripts/upgrade-dspace-10.1-swarm.sh --env dev --maintenance-confirmed [--resume-stopped]'
  echo 'Requires a verified coordinated backup and all external writers and deployments stopped.'
}
die() { echo "ERROR: $*" >&2; exit 1; }
if [[ $# == 1 && ( "$1" == --help || "$1" == -h ) ]]; then usage; exit 0; fi
[[ ( $# == 3 || ( $# == 4 && "$4" == --resume-stopped ) ) && "$1" == --env && "$2" == dev && "$3" == --maintenance-confirmed ]] || { usage >&2; exit 1; }
resume=false
[[ $# == 4 ]] && resume=true
[[ "$STACK_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || die 'Invalid STACK_NAME'
command -v sudo >/dev/null || die 'sudo is required for the Solr schema'
sudo -n true || die 'Passwordless sudo is required for the Solr schema'

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/autonomous-env.sh"
load_autonomous_env "$ROOT_DIR" dev
[[ "${DSPACE_REST_VER:-}" == dspace-10.1 && "${DSPACE_SOLR_VER:-}" == dspace-10.1 ]] || die 'dev image versions must both be dspace-10.1'
[[ "${POSTGRES_VERSION:-15}" == 15 ]] || die 'This upgrade requires PostgreSQL 15'
[[ "${SOLR_INTERNAL_PORT:-8983}" == 8983 ]] || die 'This upgrade expects Solr on port 8983'
backend="${STACK_NAME}_dspace"
solr="${STACK_NAME}_dspacesolr"
db="${STACK_NAME}_dspacedb"
ui="${STACK_NAME}_dspace-angular"
node_id="$(docker info --format '{{.Swarm.NodeID}}')"
[[ -n "$node_id" && "$(docker info --format '{{.Swarm.ControlAvailable}}')" == true ]] || die 'Run on the Swarm manager hosting the stack'
for service in "$backend" "$solr" "$db" "$ui"; do
  replicas="$(docker service inspect "$service" --format '{{.Spec.Mode.Replicated.Replicas}}')"
  cid="$(docker ps -q --filter "label=com.docker.swarm.service.name=$service")"
  if [[ "$resume" == true && "$service" != "$db" ]]; then
    [[ "$replicas" == 0 && -z "$cid" ]] || die "$service must be stopped before resuming"
  else
    [[ "$replicas" == 1 && -n "$cid" && "$(docker inspect "$cid" --format '{{.State.Running}}')" == true ]] || die "$service must have one running replica on this node"
  fi
done
[[ "$(docker service inspect "$backend" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}')" == *':dspace-9_x'* ]] || die 'Backend is not the expected DSpace 9 image'
[[ "$(docker service inspect "$solr" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}')" == *':dspace-9_x'* ]] || die 'Solr is not the expected DSpace 9 image'

if [[ "$resume" == true ]]; then
  old_solr_image="$(docker service inspect "$solr" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}')"
  docker image inspect "$old_solr_image" >/dev/null || die 'Existing Solr image is not available locally'
else
  solr_cid="$(docker ps -q --filter "label=com.docker.swarm.service.name=$solr")"
  old_solr_image="$(docker inspect "$solr_cid" --format '{{.Image}}')"
fi
solr_dir="$(docker service inspect "$solr" --format '{{range .Spec.TaskTemplate.ContainerSpec.Mounts}}{{if eq .Target "/var/solr/data"}}{{.Source}}{{end}}{{end}}')"
[[ -n "$solr_dir" && "$(realpath -e "$solr_dir")" == "$(realpath -e "${VOL_SOLR_PATH:?}")" ]] || die 'Solr mount does not match dev environment'
schema="${solr_dir}/search/conf/schema.xml"
[[ -f "$schema" && ! -L "$schema" && ! -L "${solr_dir}/search/conf" ]] || die 'Expected a regular search schema and directory'
[[ ! -e "${schema}.before-dspace-10.1" ]] || die 'Existing schema backup: inspect previous attempt before proceeding'

registry="${DOCKER_REGISTRY:-docker.io}"
owner="${DOCKER_OWNER:-dspace}"
backend_image="${registry}/${owner}/dspace:dspace-10.1"
solr_image="${registry}/${owner}/dspace-solr:dspace-10.1"
ui_image="$(bash "${SCRIPT_DIR}/ui-image-reference.sh")"
for img in "$backend_image" "$solr_image"; do docker image inspect "$img" >/dev/null || die "Image is not available locally: $img"; done
docker manifest inspect "$ui_image" >/dev/null || die "UI image is not available in the registry: $ui_image"
network="$(docker service inspect "$db" --format '{{range .Spec.TaskTemplate.Networks}}{{.Target}}{{end}}')"
[[ -n "$network" ]] || die 'Database network not found'
app_secret="$(docker service inspect "$backend" --format '{{range .Spec.TaskTemplate.ContainerSpec.Secrets}}{{if eq .File.Name "app_env_payload"}}{{.SecretName}}{{end}}{{end}}')"
password_secret="$(docker service inspect "$backend" --format '{{range .Spec.TaskTemplate.ContainerSpec.Secrets}}{{if eq .File.Name "POSTGRES_PASSWORD"}}{{.SecretName}}{{end}}{{end}}')"
[[ -n "$app_secret" && -n "$password_secret" ]] || die 'Backend Swarm secrets not found'

work="$(mktemp -d)"
mutating=false
completed=false
cleanup() {
  if [[ "$mutating" == true && "$completed" == false ]]; then
    echo 'Upgrade failed or was interrupted; stopping backend and UI.' >&2
    docker service scale --detach=false "${ui}=0" "${backend}=0" >&2 || echo 'ERROR: could not stop backend and UI; stop them manually' >&2
  fi
  rm -rf "$work"
  cleanup_autonomous_env
}
trap cleanup EXIT
trap 'exit 130' INT TERM
extract_schema() {
  local image="$1" output="$2" id
  id="$(docker create "$image")"
  if ! docker cp "$id:/opt/solr/server/solr/configsets/search/conf/schema.xml" "$output"; then
    docker rm "$id" >/dev/null
    return 1
  fi
  docker rm "$id" >/dev/null
}
extract_schema "$old_solr_image" "$work/old.xml"
extract_schema "$solr_image" "$work/new.xml"
python3 - "$schema" "$work/old.xml" <<'PY' || die 'Existing schema differs from the current image; merge local changes manually before upgrading'
import sys
from xml.etree import ElementTree
assert ElementTree.canonicalize(from_file=sys.argv[1], strip_text=True) == ElementTree.canonicalize(from_file=sys.argv[2], strip_text=True)
PY
[[ -s "$work/new.xml" ]] || die 'Target schema is empty'

state_dir="${ROOT_DIR}/.orchestrator-state"
mkdir -p "$state_dir"
marker="${state_dir}/${STACK_NAME}.upgrade-dspace-10.1"
if [[ "$resume" == true ]]; then
  [[ -f "$marker/status" && "$(cat "$marker/status")" == started ]] || die 'Resume is only allowed before schema replacement and migration'
  if docker service inspect "${STACK_NAME}-upgrade-dspace-101" >/dev/null 2>&1; then
    die 'Migration job already exists; inspect it before recovery'
  fi
else
  mkdir "$marker" 2>/dev/null || die "Previous upgrade attempt exists: $marker; inspect before retrying"
  printf '%s\n' 'started' > "$marker/status"
fi
mutating=true
echo 'Stopping UI and backend. Do not run CI/CD or other writers during this upgrade.'
docker service scale --detach=false "${ui}=0" "${backend}=0"
wait_stopped() {
  local service="$1" i
  for ((i=0; i<90; i++)); do
    [[ -z "$(docker ps -q --filter "label=com.docker.swarm.service.name=$service")" ]] && return 0
    sleep 1
  done
  die "$service still has a running task after 90 seconds"
}
for service in "$ui" "$backend"; do
  wait_stopped "$service"
done
docker service scale --detach=false "${solr}=0"
wait_stopped "$solr"

schema_uid="$(stat -c %u "$schema")"
schema_gid="$(stat -c %g "$schema")"
schema_mode="$(stat -c %a "$schema")"
sudo -n cp -p -- "$schema" "${schema}.before-dspace-10.1"
sudo -n install -o "$schema_uid" -g "$schema_gid" -m "$schema_mode" -- "$work/new.xml" "${schema}.dspace-10.1.$$"
sudo -n mv -T -- "${schema}.dspace-10.1.$$" "$schema"
echo 'Starting Solr 10.1 with the updated search schema.'
docker service update --detach=false --image "$solr_image" --replicas 1 "$solr"
solr_cid="$(docker ps -q --filter "label=com.docker.swarm.service.name=$solr")"
[[ -n "$solr_cid" ]] || die 'Solr task did not start'
ready=false
for ((i=0; i<60; i++)); do
  if docker exec "$solr_cid" wget -qO- 'http://127.0.0.1:8983/solr/admin/cores?action=STATUS&wt=json' > "$work/cores.json" 2>/dev/null &&
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert not d.get("initFailures"); assert {"search","statistics","authority","oai","qaevent","suggestion"} <= set(d["status"])' "$work/cores.json" 2>/dev/null; then
    ready=true; break
  fi
  sleep 5
done
[[ "$ready" == true ]] || die 'Solr cores did not become ready; backend remains stopped'

job="${STACK_NAME}-upgrade-dspace-101"
docker service inspect "$job" >/dev/null 2>&1 && die "Migration job already exists: $job"
config_src="$(docker service inspect "$backend" --format '{{range .Spec.TaskTemplate.ContainerSpec.Mounts}}{{if eq .Target "/dspace/config/local.cfg"}}{{.Source}}{{end}}{{end}}')"
[[ -f "$config_src" ]] || die 'Backend local.cfg mount is unavailable'
asset_src="$(docker service inspect "$backend" --format '{{range .Spec.TaskTemplate.ContainerSpec.Mounts}}{{if eq .Target "/dspace/assetstore"}}{{.Source}}{{end}}{{end}}')"
[[ -d "$asset_src" && "$(realpath -e "$asset_src")" == "$(realpath -e "${VOL_ASSETSTORE_PATH:?}")" ]] || die 'Assetstore mount does not match dev environment'
# The job uses the same secret payload and password handling as the Swarm backend.
# shellcheck disable=SC2016
job_command='set -e; while IFS= read -r line || [ -n "$line" ]; do case "$line" in ""|\#*|POSTGRES_PASSWORD=*) continue;; *=*) export "$line";; esac; done < /run/secrets/app_env_payload; export db__P__password="$(cat /run/secrets/POSTGRES_PASSWORD)"; /dspace/bin/dspace database info; /dspace/bin/dspace database migrate ignored; /dspace/bin/dspace database info; /dspace/bin/dspace index-discovery -b'
printf '%s\n' 'migration-started' > "$marker/status"
docker service create --detach=true --name "$job" --mode replicated-job --replicas 1 --restart-condition none \
  --constraint "node.id==$node_id" --network "$network" \
  --secret "source=$app_secret,target=app_env_payload" --secret "source=$password_secret,target=POSTGRES_PASSWORD" \
  --mount "type=bind,src=$config_src,dst=/dspace/config/local.cfg,readonly" \
  --mount "type=bind,src=$asset_src,dst=/dspace/assetstore,readonly" \
  --env "db__P__url=jdbc:postgresql://dspacedb:${POSTGRES_INTERNAL_PORT:-5432}/${POSTGRES_DB:-dspace}" \
  --env "db__P__username=${POSTGRES_USER:-dspace}" \
  --env "solr__P__server=http://dspacesolr:${SOLR_INTERNAL_PORT:-8983}/solr" \
  --entrypoint /bin/bash "$backend_image" -c "$job_command" >/dev/null
state=''
for ((i=0; i<1440; i++)); do
  task="$(docker service ps -q --no-trunc "$job" | head -n 1)"
  if [[ -n "$task" ]]; then
    state="$(docker inspect "$task" --format '{{.Status.State}}')"
    case "$state" in complete|failed|rejected|orphaned) break ;; esac
  fi
  sleep 5
done
docker service logs "$job" || true
[[ "$state" == complete ]] || die "Migration job state: ${state:-unknown}; backend remains stopped; inspect job and marker before recovery"
printf '%s\n' 'migration-complete' > "$marker/status"
docker service rm "$job" >/dev/null

echo 'Migration and discovery indexing completed. Deploying the configured dev stack.'
ORCHESTRATOR_FORCE_DEPLOY=true ORCHESTRATOR_MODE=swarm ENVIRONMENT_NAME=development \
  STACK_NAME="$STACK_NAME" ORCHESTRATOR_ENV_FILE="$AUTONOMOUS_ENV_TMP" \
  bash "${SCRIPT_DIR}/deploy-orchestrator-swarm.sh"
printf '%s\n' 'deploy-complete' > "$marker/status"
completed=true
echo 'Upgrade submitted. Check service health, migration status, search and acceptance tests.'

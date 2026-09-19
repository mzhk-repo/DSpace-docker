#!/usr/bin/env bash
# Generate a missing item thumbnail from the first supported PDF page.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
ENVIRONMENT_ARG=""
ITEM_IDENTIFIER=""
PROCESS_ALL=false
DRY_RUN=false
ASSUME_YES=false

usage() {
  cat <<'EOF'
Usage: scripts/generate-item-thumbnail.sh (--item HANDLE_OR_UUID | --all) [options]

Options:
  --item HANDLE_OR_UUID  DSpace item handle or UUID (required).
  --all                  Process all items missing generated thumbnails; timer-safe.
  --env dev|prod         Select env.<env>.enc. SERVER_ENV also works.
  --dry-run              Print the DSpace command without running it.
  --yes                  Skip the interactive confirmation.
  -h, --help             Show this help.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

is_valid_identifier() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ||
    "$1" =~ ^[^[:space:]/]+/[^[:space:]/]+$ ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --item)
      [[ $# -ge 2 ]] || die "Missing value for --item"
      ITEM_IDENTIFIER="$2"
      shift 2
      ;;
    --item=*)
      ITEM_IDENTIFIER="${1#--item=}"
      shift
      ;;
    --all)
      PROCESS_ALL=true
      shift
      ;;
    --env)
      [[ $# -ge 2 ]] || die "Missing value for --env"
      ENVIRONMENT_ARG="$2"
      shift 2
      ;;
    --env=*)
      ENVIRONMENT_ARG="${1#--env=}"
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --yes)
      ASSUME_YES=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

if [[ "$PROCESS_ALL" == true ]]; then
  [[ -z "$ITEM_IDENTIFIER" ]] || die "Use either --all or --item, not both"
else
  [[ -n "$ITEM_IDENTIFIER" ]] || die "Either --item or --all is required"
  is_valid_identifier "$ITEM_IDENTIFIER" || die "Invalid item handle or UUID: $ITEM_IDENTIFIER"
fi

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/autonomous-env.sh"
load_autonomous_env "$PROJECT_ROOT" "$ENVIRONMENT_ARG"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/docker-runtime.sh"

if [[ "$PROCESS_ALL" == true ]]; then
  filter_cmd=(/dspace/bin/dspace filter-media -p "PDFBox JPEG Thumbnail")
  echo "Scope: all items missing generated thumbnails"
else
  filter_cmd=(/dspace/bin/dspace filter-media -i "$ITEM_IDENTIFIER" -p "PDFBox JPEG Thumbnail")
  echo "Item: $ITEM_IDENTIFIER"
fi

echo "Filter: PDFBox JPEG Thumbnail"
echo "Output: THUMBNAIL bundle"

if [[ "$DRY_RUN" == true ]]; then
  printf '[dry-run] docker_runtime_exec dspace'
  printf ' %q' "${filter_cmd[@]}"
  printf '\n'
  exit 0
fi

if [[ "$PROCESS_ALL" == true ]]; then
  echo "Batch mode is non-interactive and suitable for systemd timers"
elif [[ "$ASSUME_YES" != true ]]; then
  [[ -t 0 ]] || die "Interactive confirmation requires a TTY; use --yes for an explicit non-interactive run"
  read -r -p "Generate thumbnail for '$ITEM_IDENTIFIER'? Type 'yes' to continue: " confirmation
  [[ "$confirmation" == "yes" ]] || die "Operation cancelled"
fi

docker_runtime_service_accessible dspace || die "DSpace backend runtime is not accessible"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] Running DSpace media filter"
filter_output="$(docker_runtime_exec dspace "${filter_cmd[@]}" 2>&1)" || {
  printf '%s\n' "$filter_output" >&2
  die "DSpace media filter failed"
}
printf '%s\n' "$filter_output"

if [[ "$PROCESS_ALL" != true ]] && ! grep -Eq 'FILTERED:|SKIPPED:' <<<"$filter_output"; then
  die "No supported PDF was processed and no existing generated thumbnail was reported"
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] Thumbnail generation check completed"

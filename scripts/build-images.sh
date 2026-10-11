#!/usr/bin/env bash
set -euo pipefail
umask 077
# Rebuild the locally built images whose recipes changed since they were last
# built by this command. `compose up` builds only an image that is missing, so
# without this step an upgraded checkout keeps running the images of the first
# installation. setup.sh runs it before starting anything; run alone, it takes
# the operator lock.
#   --all        rebuild every image in use, changed or not
#   --no-cache   the same, without Docker's build cache (current OS packages)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() { echo 'Usage: bash scripts/build-images.sh [--all] [--no-cache]' >&2; exit 1; }
plan_args=()
build_args=()
while (($#)); do
  case "$1" in
    --all) plan_args=(--all) ;;
    --no-cache) plan_args=(--all); build_args=(--no-cache) ;;
    *) usage ;;
  esac
  shift
done
command -v node >/dev/null || { echo 'Node.js is required.' >&2; exit 1; }
# shellcheck source=scripts/operator-lock.sh
. "$ROOT/scripts/operator-lock.sh"
state="$(operator_state)"
operator_lock_or_inherited "$state"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
record="$state/config/image-recipes.sha256"

config="$(compose --profile '*' config --format json)"
plan="$(printf '%s' "$config" | node "$ROOT/scripts/image-recipes.mjs" plan "$record" "${plan_args[@]}")"
if [[ -z "$plan" ]]; then
  echo 'Images match their recipes; nothing to rebuild.'
  exit 0
fi
services=()
built=()
while IFS=$'\t' read -r service fingerprint reason; do
  [[ -n "$service" ]] || continue
  echo "Building the $service image: $reason."
  services+=("$service")
  built+=("$service=$fingerprint")
done <<< "$plan"
if ! compose --profile '*' build "${build_args[@]}" "${services[@]}"; then
  echo 'Image build failed. Nothing was started or stopped; the services keep the images they had. A build needs the network when a recipe changed.' >&2
  exit 1
fi
node "$ROOT/scripts/image-recipes.mjs" record "$record" "${built[@]}"
echo "Built ${#services[@]} image(s). Containers whose image changed are replaced at the next start."

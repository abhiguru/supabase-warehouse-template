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
#   --replace-optional
#                build nothing: replace the running optional services
#                (printing, sensors, pooler) whose image or configuration
#                changed. setup.sh and start.sh start only the core services,
#                so they run this after their own start. A running service
#                whose image does not match this checkout (missing, recipe
#                changed, or replaced by something else) is left as it is and
#                the command exits 1: start never builds, and never recreates a
#                service from an image this checkout did not build.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() { echo 'Usage: bash scripts/build-images.sh [--all | --no-cache | --replace-optional]' >&2; exit 1; }
plan_args=()
build_args=()
replace_optional=false
(($# <= 1)) || usage
case "${1:-}" in
  '') ;;
  --all) plan_args=(--all) ;;
  --no-cache) plan_args=(--all); build_args=(--no-cache) ;;
  --replace-optional) replace_optional=true ;;
  *) usage ;;
esac
command -v node >/dev/null || { echo 'Node.js is required.' >&2; exit 1; }
# shellcheck source=scripts/operator-lock.sh
. "$ROOT/scripts/operator-lock.sh"
state="$(operator_state)"
operator_lock_or_inherited "$state"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
record="$state/config/image-recipes.sha256"
config="$(compose --profile '*' config --format json)" || { echo 'Could not read the Compose configuration.' >&2; exit 1; }

if [[ "$replace_optional" == true ]]; then
  running="$(printf '%s' "$config" | node "$ROOT/scripts/image-recipes.mjs" optional)" || { echo 'Could not work out which optional services are running.' >&2; exit 1; }
  [[ -n "$running" ]] || exit 0
  # The same comparison as the build step; an image with no build record yet is
  # accepted (one built by `compose build` or `compose up` of this project).
  plan="$(printf '%s' "$config" | node "$ROOT/scripts/image-recipes.mjs" plan "$record")" || { echo 'Could not check the images of the optional services.' >&2; exit 1; }
  declare -A mismatch=()
  while IFS=$'\t' read -r service _ _ reason; do
    if [[ -n "$service" && "$reason" != 'no build record' ]]; then mismatch["$service"]="$reason"; fi
  done <<< "$plan"
  services=()
  skipped=()
  while IFS= read -r service; do
    [[ -n "$service" ]] || continue
    if [[ -n "${mismatch[$service]:-}" ]]; then skipped+=("$service"); else services+=("$service"); fi
  done <<< "$running"
  echo "Optional services that are running: ${running//$'\n'/ }. Replacing those whose image or configuration changed."
  for service in "${skipped[@]}"; do
    echo "Left $service running unchanged: the $service image does not match this checkout (${mismatch[$service]}); run \`bash scripts/build-images.sh\`." >&2
  done
  if ((${#services[@]})) && ! compose --profile '*' up -d --wait --wait-timeout 180 "${services[@]}"; then
    echo "An optional service did not start (${services[*]}). The core services are not affected; see the message above." >&2
    exit 1
  fi
  ((${#skipped[@]} == 0)) || exit 1
  exit 0
fi

plan="$(printf '%s' "$config" | node "$ROOT/scripts/image-recipes.mjs" plan "$record" "${plan_args[@]}")" || { echo 'Could not work out which images to rebuild.' >&2; exit 1; }
if [[ -z "$plan" ]]; then
  echo 'Images match their recipes; nothing to rebuild.'
  exit 0
fi
services=()
built=()
while IFS=$'\t' read -r service fingerprint image reason; do
  [[ -n "$service" ]] || continue
  echo "Building the $service image: $reason."
  services+=("$service")
  built+=("$service=$fingerprint=$image")
done <<< "$plan"
if ! compose --profile '*' build "${build_args[@]}" "${services[@]}"; then
  cat >&2 <<'MSG'
Image build failed. No service was started or stopped by this step, and nothing
of this run was recorded as built. An image that did finish building before the
failure is used the next time its service is started. A build needs the network
when a recipe changed; run this again when the cause is fixed.
MSG
  exit 1
fi
node "$ROOT/scripts/image-recipes.mjs" record "$record" "${built[@]}"
echo "Built ${#services[@]} image(s). The next start replaces the containers whose image changed."

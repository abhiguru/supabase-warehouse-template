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
#   --save       build nothing: write the images this installation uses to <state>/images (see below), for an
#                installation that was built before images were saved
#   --replace-optional
#                build nothing: replace the running optional services
#                (printing, sensors, pooler) whose image or configuration
#                changed. setup.sh and start.sh start only the core services,
#                so they run this after their own start. A running service
#                whose image does not match this checkout (missing, recipe
#                changed, or replaced by something else) is left as it is and
#                the command exits 1: start never builds, and never recreates a
#                service from an image this checkout did not build.
#
# After a successful build each image it built is also written with `docker save` to <state>/images/<service>.tar (an older
# tarball of the service is replaced), with a copy of the build record beside them. Nothing else holds the built images:
# on a new host a rebuild needs Docker Hub, Debian, npm and Chrome for Testing to answer (docs/OPERATOR_INSTALL.md, "Lost
# host"), and scripts/restore-host.sh loads these tarballs first. The folder is not part of a backup; copy it with the
# backup drive. A save that fails, or that would leave less free on the disk than the reserve (5 GiB, or the size of the newest
# backup when that is larger, so the next nightly backup still fits; WAREHOUSE_IMAGE_SAVE_RESERVE, in bytes, overrides it
# for tests), is a warning: the build itself stands, and the tarball of that service is removed (the record now names a
# newer image than the old tarball holds). Tarballs of services the record no longer names are removed too.
# The folder is signed like a backup: SHA256SUMS lists every file in it and SHA256SUMS.hmac is made with the backup key
# (config/backup.key, scripts/backup-key.sh). restore-host loads a tarball only when that signature checks out, because a
# loaded image runs on the rebuilt host with every secret and full database access.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() { echo 'Usage: bash scripts/build-images.sh [--all | --no-cache | --replace-optional | --save]' >&2; exit 1; }
plan_args=()
build_args=()
replace_optional=false
save_only=false
(($# <= 1)) || usage
case "${1:-}" in
  '') ;;
  --all) plan_args=(--all) ;;
  --no-cache) plan_args=(--all); build_args=(--no-cache) ;;
  --replace-optional) replace_optional=true ;;
  --save) save_only=true ;;
  *) usage ;;
esac
command -v node >/dev/null || { echo 'Node.js is required.' >&2; exit 1; }
# shellcheck source=scripts/operator-lock.sh
. "$ROOT/scripts/operator-lock.sh"
# shellcheck source=scripts/backup-key.sh
. "$ROOT/scripts/backup-key.sh"
state="$(operator_state)"
operator_lock_or_inherited "$state"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
record="$state/config/image-recipes.sha256"
config="$(compose --profile '*' config --format json)" || { echo 'Could not read the Compose configuration.' >&2; exit 1; }
built=()

# The space to leave free after the images are saved: 5 GiB, or the size of the newest backup when that is larger.
image_save_reserve() {
  local reserve=$((5 * 1024 ** 3)) newest size
  if [[ -n "${WAREHOUSE_IMAGE_SAVE_RESERVE:-}" ]]; then printf '%s\n' "$WAREHOUSE_IMAGE_SAVE_RESERVE"; return 0; fi
  newest="$(find "$state/backups" -maxdepth 1 -type d -name 'warehouse-????????T??????Z' 2>/dev/null | LC_ALL=C sort | tail -n 1)"
  if [[ -n "$newest" ]]; then
    size="$(du -sb -- "$newest" 2>/dev/null | cut -f1)"
    if [[ "$size" =~ ^[0-9]+$ ]] && ((size > reserve)); then reserve=$size; fi
  fi
  printf '%s\n' "$reserve"
}

# Lists every file of the folder in SHA256SUMS and signs that list with the backup key (backup_sign_dir), as a backup is signed.
# Without a usable key the signature is removed: restore-host then refuses the folder, which is safer than an unproven one.
sign_images() {
  local dir="$1" sums
  rm -f -- "$dir/SHA256SUMS" "$dir/SHA256SUMS.hmac"
  sums="$(cd "$dir" && find . -mindepth 1 -maxdepth 1 -type f -printf '%P\n' | LC_ALL=C sort | xargs -r -d '\n' sha256sum --)" \
    && printf '%s\n' "$sums" > "$dir/SHA256SUMS" && chmod 0600 -- "$dir/SHA256SUMS" \
    && backup_key_ensure "$state" && backup_key_load "$state/config/backup.key" && backup_sign_dir "$dir" "$BACKUP_KEY" \
    || { rm -f -- "$dir/SHA256SUMS" "$dir/SHA256SUMS.hmac"; echo "Warning: could not sign the saved images in $dir with the backup key, so db:restore-host will not use them. Check config/backup.key (mode 0600, owned by you) and run bash scripts/build-images.sh --save." >&2; return 0; }
}

# Written to a temporary name and renamed, so the previous tarball stays whole until the new one is complete.
save_images() {
  local dir="$state/images" entry service image size avail tmp file reserve named
  reserve="$(image_save_reserve)"
  # The services the build record names: restore-host loads only those, so a tarball of any other is not kept.
  named=" $(awk 'NF >= 2 { print $2 }' "$record" 2>/dev/null | tr '\n' ' ')"
  mkdir -p -- "$dir" && chmod 0700 -- "$dir" || { echo "Warning: could not create $dir; the built images were not saved." >&2; return 0; }
  for entry in "${built[@]}"; do
    IFS='=' read -r service _ image <<< "$entry"
    if [[ "$named" != *" $service "* ]]; then
      rm -f -- "$dir/$service.tar"
      echo "Note: the $service image was not saved: the build record has no entry for it, so db:restore-host would not use it. Build it with bash scripts/build-images.sh --all, which records it." >&2
      continue
    fi
    size="$(docker image inspect --format '{{.Size}}' "$image" 2>/dev/null || true)"
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    avail="$(df --output=avail -B1 -- "$dir" 2>/dev/null | tail -n 1 | tr -d ' ')"
    if [[ ! "$avail" =~ ^[0-9]+$ ]] || ((avail < size + reserve)); then
      rm -f -- "$dir/$service.tar"
      echo "Warning: the $service image was not saved to $dir: less than $((reserve / 1024 ** 3)) GiB would be left on the disk. The image itself is fine; free some space and run bash scripts/build-images.sh --save." >&2
      continue
    fi
    tmp="$dir/.$service.tar.$$"
    if docker save --output "$tmp" "$image" && mv -f -- "$tmp" "$dir/$service.tar"; then
      echo "Saved the $service image to $dir/$service.tar."
    else
      rm -f -- "$tmp" "$dir/$service.tar"
      echo "Warning: could not save the $service image to $dir/$service.tar. The image itself is fine." >&2
    fi
  done
  cp -- "$record" "$dir/.image-recipes.sha256.$$" && mv -f -- "$dir/.image-recipes.sha256.$$" "$dir/image-recipes.sha256" \
    || echo "Warning: could not copy the build record to $dir." >&2
  # A tarball that the record does not name is of a service that is gone (or of an older layout): nothing would load it.
  for file in "$dir"/*.tar; do
    [[ -e "$file" || -L "$file" ]] || continue
    service="$(basename -- "$file" .tar)"
    [[ "$named" == *" $service "* ]] || rm -f -- "$file"
  done
  sign_images "$dir"
}
if [[ "$save_only" == true ]]; then
  # No build: write the images this installation uses and has (the same list --all would build) to <state>/images.
  plan="$(printf '%s' "$config" | node "$ROOT/scripts/image-recipes.mjs" plan "$record" --all)" || { echo 'Could not work out which images this installation uses.' >&2; exit 1; }
  while IFS=$'\t' read -r service fingerprint image reason; do
    if [[ -n "$service" && "$reason" == requested ]]; then built+=("$service=$fingerprint=$image"); fi
  done <<< "$plan"
  ((${#built[@]})) || { echo 'No built image of this installation exists on this host; nothing to save.'; exit 0; }
  save_images
  exit 0
fi

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
  [[ -d "$state/images" ]] || echo "Tip: no copy of the built images is kept yet. bash scripts/build-images.sh --save writes one to $state/images, so a lost-host rebuild does not depend on the internet."
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

save_images
echo "Built ${#services[@]} image(s). The next start replaces the containers whose image changed."

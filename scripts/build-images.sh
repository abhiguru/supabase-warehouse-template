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
#   --from-release
#                as without an option, but an image that has to be built is first pulled from the release this checkout is
#                at, when there is one for the same recipe (setup.sh uses it). A checkout exactly at a release tag (v1.2.3)
#                fetches that release's release-images.json (https://github.com/abhiguru/supabase-warehouse-template/releases)
#                and, for each service whose recipe fingerprint equals the one in the file, pulls
#                ghcr.io/abhiguru/supabase-warehouse-template/<service>@sha256:<digest> (the image the release workflow built
#                with --no-cache, scanned with docs/CONTAINER_SECURITY.md's ledger and pushed), checks that the pulled image
#                has exactly that digest and that its label org.opencontainers.image.revision is this checkout's commit (the
#                release workflow puts it on every image it pushes), tags it <project>-<service> and records it as a build
#                would. Any other service, a download that fails, a file that does not fit this checkout, a pull that takes
#                longer than WAREHOUSE_IMAGE_PULL_TIMEOUT seconds (default 1200, 20 minutes), a host that is not x86-64 (the only platform the
#                images are built for), and a checkout that is not at a tag (main, a branch, a development copy) build here as
#                always, with one line that says why. Nothing is fetched when no image needs building.
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
# After a successful build each image it built (or pulled) is also written with `docker save` to <state>/images/<service>.tar (an
# older tarball of the service is replaced), with a copy of the build record beside them. On a new host a rebuild needs Docker Hub,
# Debian, npm and Chrome for Testing to answer (docs/OPERATOR_INSTALL.md, "Lost host"), and scripts/restore-host.sh loads these
# tarballs first. The folder is not part of a backup, but scripts/backup-usb.sh copies it to the USB drive, once for each change of
# the folder, beside the archives. A save that fails, or that would leave less free on the disk than the reserve (5 GiB, or the size of the newest
# backup when that is larger, so the next nightly backup still fits; WAREHOUSE_IMAGE_SAVE_RESERVE, in bytes, overrides it
# for tests), is a warning: the build itself stands, and the tarball of that service is removed (the record now names a
# newer image than the old tarball holds). Tarballs of services the record no longer names are removed too.
# The folder is signed like a backup: SHA256SUMS lists every file in it and SHA256SUMS.hmac is made with the backup key
# (config/backup.key, scripts/backup-key.sh). restore-host loads a tarball only when that signature checks out, because a
# loaded image runs on the rebuilt host with every secret and full database access.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() {
  printf '%s\n' 'Usage: bash scripts/build-images.sh [--all | --no-cache | --replace-optional | --save]' \
    '   or: bash scripts/build-images.sh --from-release   (what setup.sh runs: pull the images of the release this checkout is at, build the rest)' >&2
  exit 1
}
plan_args=()
build_args=()
replace_optional=false
save_only=false
from_release=false
(($# <= 1)) || usage
case "${1:-}" in
  '') ;;
  --all) plan_args=(--all) ;;
  --no-cache) plan_args=(--all); build_args=(--no-cache) ;;
  --replace-optional) replace_optional=true ;;
  --save) save_only=true ;;
  --from-release) from_release=true ;;
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

# The release this checkout is at, if it is exactly at one: the tag of a final release before a pre-release of the same commit.
release_tag() {
  local tags tag
  tags="$(git -C "$ROOT" tag --points-at HEAD --list 'v[0-9]*' 2>/dev/null)" || return 1
  tag="$(printf '%s\n' "$tags" | { grep -Ex 'v[0-9]+\.[0-9]+\.[0-9]+(\+[0-9A-Za-z.-]+)?' || true; } | LC_ALL=C sort -V | tail -n 1)"
  [[ -n "$tag" ]] || tag="$(printf '%s\n' "$tags" | { grep -Ex 'v[0-9]+\.[0-9]+\.[0-9]+-[0-9A-Za-z.-]+(\+[0-9A-Za-z.-]+)?' || true; } | LC_ALL=C sort -V | tail -n 1)"
  [[ -n "$tag" ]] || return 1
  printf '%s\n' "$tag"
}

# Fills release_ref[service] for each service of the plan that the release published with this recipe, and says in one line why
# when it cannot use the release at all.
declare -A release_ref=() release_why=()
release_tag_used=''
release_commit=''
release_file=''
trap '[[ -z "$release_file" ]] || rm -f -- "$release_file"' EXIT
select_release_images() {
  local tag commit url file selection kind service fingerprint value why arch
  local -a items=()
  tag="$(release_tag)" || { echo 'Not pulling release images: this checkout is not at a release tag, so the images are built here.'; return 0; }
  # The release images are x86-64 only (docs/OPERATOR_INSTALL.md, requirements): on another architecture a pull could succeed and the
  # container then fail to start, where a build here would have worked.
  arch="$(uname -m 2>/dev/null || true)"
  [[ "$arch" == x86_64 ]] || { echo "Not pulling the images of release $tag: they are built for x86-64 and this host is ${arch:-of an unknown architecture}, so the images are built here."; return 0; }
  command -v curl >/dev/null || { echo "Not pulling the images of release $tag: curl is not installed, so the images are built here."; return 0; }
  commit="$(git -C "$ROOT" rev-parse HEAD)" || { echo "Not pulling the images of release $tag: this checkout's commit cannot be read, so the images are built here."; return 0; }
  url="https://github.com/abhiguru/supabase-warehouse-template/releases/download/${tag//+/%2B}/release-images.json"
  file="$(mktemp "$state/config/.release-images.XXXXXX" 2>/dev/null)" || { echo "Not pulling the images of release $tag: a temporary file cannot be made in $state/config, so the images are built here."; return 0; }
  release_file="$file"
  if ! why="$(curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 --max-time 60 --max-filesize 1048576 --output "$file" "$url" 2>&1)"; then
    rm -f -- "$file"
    echo "Not pulling the images of release $tag: $url could not be fetched (${why:-curl failed}), so the images are built here."
    return 0
  fi
  while IFS=$'\t' read -r service fingerprint _ _; do
    [[ -n "$service" ]] && items+=("$service=$fingerprint")
  done <<< "$plan"
  if ! selection="$(node "$ROOT/scripts/image-recipes.mjs" release-select "$file" "$tag" "$commit" "${items[@]}" 2>&1)"; then
    rm -f -- "$file"
    echo "Not pulling the images of release $tag: $selection; the images are built here."
    return 0
  fi
  rm -f -- "$file"
  release_tag_used="$tag"; release_commit="$commit"
  while IFS=$'\t' read -r kind service value; do
    case "$kind" in
      pull) release_ref[$service]="$value" ;;
      build) release_why[$service]="$value" ;;
    esac
  done <<< "$selection"
}

# Pulls one image of the release by its digest, checks that the image on this host carries that digest and was built for this checkout's
# commit, and gives it the tag a build would. Returns 1, saying why on stderr, when the image cannot be used; the caller builds it then.
pull_release_image() {
  local service="$1" ref="$2" image="$3" out digests revision limit="${WAREHOUSE_IMAGE_PULL_TIMEOUT:-1200}" rc=0
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=1200
  # A pull that stalls would hold setup inside the downtime window of an upgrade; after the limit the image is built here instead.
  if command -v timeout >/dev/null; then out="$(timeout -k 10 "$limit" docker pull --quiet "$ref" 2>&1)" || rc=$?
  else out="$(docker pull --quiet "$ref" 2>&1)" || rc=$?; fi
  if ((rc != 0)); then
    if ((rc == 124 || rc == 137)); then echo "Warning: pulling the $service image of release $release_tag_used ($ref) took longer than $limit seconds and was stopped; it is built here." >&2
    else echo "Warning: could not pull the $service image of release $release_tag_used ($ref): ${out##*$'\n'}" >&2; fi
    return 1
  fi
  # Docker checks the digest while it pulls; the repository digests it now records are looked at as well.
  digests="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$ref" 2>/dev/null || true)"
  if ! grep -qxF -- "$ref" <<< "$digests"; then
    echo "Warning: the pulled $service image does not carry the digest ${ref##*@} that release $release_tag_used names, so it is not used." >&2
    return 1
  fi
  # The release workflow labels every image it pushes with the commit it was built from. An image of another commit (an older release's
  # image listed in a replaced file, say) or one without the label is not this release's, whatever its digest.
  revision="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$ref" 2>/dev/null || true)"
  if [[ "$revision" != "$release_commit" ]]; then
    if [[ -z "$revision" ]]; then echo "Warning: the pulled $service image has no org.opencontainers.image.revision label, so it is not known to be built from this checkout's commit ${release_commit:0:12}, and it is not used." >&2
    else echo "Warning: the pulled $service image was built from commit ${revision:0:12}, not from this checkout's commit ${release_commit:0:12}, so it is not used." >&2; fi
    return 1
  fi
  if ! docker tag "$ref" "$image"; then
    echo "Warning: could not tag the pulled $service image as $image." >&2
    return 1
  fi
}

declare -A plan_fingerprint=() plan_image=() plan_reason=()
order=()
while IFS=$'\t' read -r service fingerprint image reason; do
  [[ -n "$service" ]] || continue
  order+=("$service"); plan_fingerprint[$service]="$fingerprint"; plan_image[$service]="$image"; plan_reason[$service]="$reason"
done <<< "$plan"
if [[ "$from_release" == true ]]; then select_release_images; fi

services=()
built=()
pulled=()
for service in "${order[@]}"; do
  fingerprint="${plan_fingerprint[$service]}"; image="${plan_image[$service]}"; reason="${plan_reason[$service]}"
  if [[ -n "${release_ref[$service]:-}" ]]; then
    if pull_release_image "$service" "${release_ref[$service]}" "$image"; then
      echo "Pulled the $service image from release $release_tag_used: $reason (${release_ref[$service]})."
      pulled+=("$service"); built+=("$service=$fingerprint=$image")
      continue
    fi
    reason="$reason; the release image could not be used"
  elif [[ -n "${release_why[$service]:-}" ]]; then
    reason="$reason; not taken from release $release_tag_used: ${release_why[$service]}"
  fi
  echo "Building the $service image: $reason."
  services+=("$service")
  built+=("$service=$fingerprint=$image")
done
if ((${#services[@]})) && ! compose --profile '*' build "${build_args[@]}" "${services[@]}"; then
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
if [[ "$from_release" == true ]]; then
  echo "Pulled ${#pulled[@]} image(s) from the release (${pulled[*]:-none}) and built ${#services[@]} here (${services[*]:-none}). The next start replaces the containers whose image changed."
else
  echo "Built ${#services[@]} image(s). The next start replaces the containers whose image changed."
fi

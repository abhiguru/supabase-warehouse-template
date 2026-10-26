#!/usr/bin/env bash
# Publishes the images of a release and writes the list a facility pulls them by (release.yml, job publish-images):
#   bash scripts/publish-images.sh TAG RELEASE_IMAGES_JSON
#       after scripts/scan-images.sh has built every image with --no-cache and scanned it. For every service that has a recipe in
#       docker/docker-compose.yml (the optional ones too) it tags the image the scan built, the project's `<project>-<service>`, as
#       ghcr.io/abhiguru/supabase-warehouse-template/<service>:<tag>, adds the OCI labels org.opencontainers.image.revision (the commit)
#       and org.opencontainers.image.version (the tag) to that tag, pushes it, takes the digest the registry answers with, and writes
#       RELEASE_IMAGES_JSON: the release, its commit and, for each service, the reference by digest and the fingerprint of its recipe
#       (scripts/image-recipes.mjs). `build-images.sh --from-release` reads that file from the GitHub Release and pulls an image only when
#       the fingerprint is the one of the recipe in the facility's checkout, the digest is the one listed and the revision label is its
#       checkout's commit. What it pushes is what the scan scanned: the labels are a change of the image's configuration only, the layers
#       are checked to be the scanned ones, nothing is built here, and an image that is missing is an error, not a reason to build.
#   bash scripts/publish-images.sh --rehearsed TAG LIST_FILE
#       before anything is built: for a final release (vX.Y.Z) whose commit is the commit of the newest pre-release vX.Y.Z-rc.N, whose
#       release-images.json can be downloaded and fits this checkout, it saves that file to LIST_FILE and prints the pre-release's tag on
#       standard output (the reasons, and the decision when there is none, go to standard error). Anything else prints nothing: the images
#       are built and scanned.
#   bash scripts/publish-images.sh --retag TAG PRERELEASE LIST_FILE RELEASE_IMAGES_JSON
#       the final release re-tags the images of that pre-release (`docker buildx imagetools create --prefer-index=false`: a carbon copy
#       of the manifest, so the digest does not change) as ghcr.io/abhiguru/supabase-warehouse-template/<service>:<tag> and writes
#       RELEASE_IMAGES_JSON with the same digests and `release: TAG`. Nothing is built or scanned: the bytes are the ones that were
#       scanned and rehearsed for the pre-release. The labels stay those of the pre-release (the revision is the same commit).
# It needs WAREHOUSE_STATE_DIR (the throwaway state the scan used: its project's images are the ones pushed), a Docker that is logged
# in to ghcr.io, and a checkout of the tag; --rehearsed needs `gh` with GH_TOKEN (GITHUB_REPOSITORY names the repository). The list is
# written only after every push has succeeded. The tag of the image is the release tag with `+` (not allowed in an image tag) replaced
# by `_`.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY=ghcr.io/abhiguru/supabase-warehouse-template
die() { echo "$*" >&2; exit 1; }
info() { echo "$*" >&2; }
USAGE='Usage: bash scripts/publish-images.sh TAG RELEASE_IMAGES_JSON | --rehearsed TAG LIST_FILE | --retag TAG PRERELEASE LIST_FILE RELEASE_IMAGES_JSON'
mode=push
case "${1:-}" in
  --rehearsed) mode=rehearsed; shift; [[ $# -eq 2 ]] || die "$USAGE" ;;
  --retag) mode=retag; shift; [[ $# -eq 4 ]] || die "$USAGE" ;;
  *) [[ $# -eq 2 && -n "${2:-}" ]] || die "$USAGE" ;;
esac
tag="${1:-}"
LC_ALL=C
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]] || die "Not a release tag: $tag"
command -v node >/dev/null || die 'Node.js is required.'
commit="$(git -C "$ROOT" rev-parse HEAD)" || die 'This is not a git checkout.'
[[ "$(git -C "$ROOT" rev-parse -q --verify "refs/tags/$tag^{commit}" || true)" == "$commit" ]] ||
  die "This checkout is not at the tag $tag, so the images built from it are not the release's. Nothing was published."
image_tag="${tag//+/_}"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }

config="$(compose --profile '*' config --format json)" || die 'Could not read the Compose configuration.'
recipes="$(printf '%s' "$config" | node "$ROOT/scripts/image-recipes.mjs" fingerprints)" || die 'Could not work out the recipes of this checkout.'
[[ -n "$recipes" ]] || die 'The Compose configuration has no recipe to publish.'

# Writes OUT, the list a facility reads, from service=reference items; only after everything it names has been pushed.
write_list() {
  local out="$1" tmp
  shift
  tmp="$out.tmp-$$"
  printf '%s' "$config" | node "$ROOT/scripts/image-recipes.mjs" manifest "$tag" "$commit" "$@" > "$tmp" || { rm -f -- "$tmp"; die 'Could not write the list of images.'; }
  mv -f -- "$tmp" "$out"
  echo "Wrote $out for release $tag (commit $commit): $# image(s)."
}

# Whether FILE, the list of the pre-release RC, can be the final release's images: it is the pre-release's own list, for this commit,
# and every recipe of this checkout has an image in it with the same fingerprint. Prints the reason on standard output and returns 1
# when not; prints "<service>\t<reference>" for every recipe and returns 0 when so.
rehearsed_list() {
  local file="$1" rc="$2" selection kind service value
  local -a items=()
  while IFS=$'\t' read -r service value _; do
    [[ -n "$service" ]] && items+=("$service=$value")
  done <<< "$recipes"
  selection="$(node "$ROOT/scripts/image-recipes.mjs" release-select "$file" "$rc" "$commit" "${items[@]}" 2>&1)" || { printf '%s\n' "$selection"; return 1; }
  while IFS=$'\t' read -r kind service value; do
    [[ -n "$kind" ]] || continue
    if [[ "$kind" != pull ]]; then printf 'the list of %s has no usable image of %s (%s)\n' "$rc" "$service" "$value"; return 1; fi
    printf '%s\t%s\n' "$service" "$value"
  done <<< "$selection"
}

if [[ "$mode" == rehearsed ]]; then
  file="$2"
  [[ "$tag" =~ ^(v[0-9]+\.[0-9]+\.[0-9]+)(\+[0-9A-Za-z.-]+)?$ ]] || { info "Building and scanning the images: $tag is a pre-release, which is always built."; exit 0; }
  core="${BASH_REMATCH[1]}"
  rc="$(git -C "$ROOT" tag --list "$core-rc.*" | { grep -E "^${core//./\\.}-rc\\.[0-9]+\$" || true; } | sort -V | tail -n 1)"
  [[ -n "$rc" ]] || { info "Building and scanning the images: there is no pre-release tag $core-rc.N."; exit 0; }
  rc_commit="$(git -C "$ROOT" rev-parse -q --verify "refs/tags/$rc^{commit}" || true)"
  [[ "$rc_commit" == "$commit" ]] || { info "Building and scanning the images: the newest pre-release, $rc, is at ${rc_commit:-no commit}, and $tag is at $commit."; exit 0; }
  command -v gh >/dev/null || { info "Building and scanning the images: gh is not installed, so the list of $rc cannot be downloaded."; exit 0; }
  if ! why="$(gh release download "$rc" --repo "${GITHUB_REPOSITORY:-abhiguru/supabase-warehouse-template}" --pattern release-images.json --output "$file" --clobber 2>&1)"; then
    rm -f -- "$file"
    info "Building and scanning the images: the list of images of $rc could not be downloaded (${why##*$'\n'})."
    exit 0
  fi
  if ! problem="$(rehearsed_list "$file" "$rc")"; then
    rm -f -- "$file"
    info "Building and scanning the images: the list of images of $rc cannot be used for $tag (${problem##*$'\n'})."
    exit 0
  fi
  info "$tag is the same commit as the pre-release $rc, whose images were built, scanned and rehearsed: they are re-tagged, not built again."
  printf '%s\n' "$rc"
  exit 0
fi

if [[ "$mode" == retag ]]; then
  rc="$2"; file="$3"; out="$4"
  [[ "${tag%%+*}" != *-* ]] || die "$tag is a pre-release: only a final release re-tags the images of a pre-release. Nothing was published."
  [[ "$rc" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$ && "${rc%%-*}" == "${tag%%+*}" ]] || die "$rc is not a pre-release (vX.Y.Z-rc.N) of $tag. Nothing was published."
  [[ "$(git -C "$ROOT" rev-parse -q --verify "refs/tags/$rc^{commit}" || true)" == "$commit" ]] || die "The pre-release $rc is not at this checkout's commit. Nothing was published."
  [[ -f "$file" && ! -L "$file" ]] || die "The list of images of $rc ($file) is missing. Nothing was published."
  selection="$(rehearsed_list "$file" "$rc")" || die "The list of images of $rc cannot be used for $tag: ${selection##*$'\n'}. Nothing was published."
  references=()
  while IFS=$'\t' read -r service ref; do
    [[ -n "$service" ]] || continue
    target="$REGISTRY/$service:$image_tag"
    digest="${ref##*@}"
    # A carbon copy of the pre-release's manifest: the same digest under the new tag (without --prefer-index=false a single manifest is
    # wrapped in an index, which has a digest of its own).
    docker buildx imagetools create --prefer-index=false --tag "$target" "$ref" || die "Could not re-tag the $service image of $rc as $target. The list of images was not written."
    got="$(docker buildx imagetools inspect "$target" --format '{{.Manifest.Digest}}')" || die "Could not read back $target. The list of images was not written."
    [[ "$got" == "$digest" ]] || die "$target is $got after the re-tag, not the $digest of $rc. The list of images was not written."
    references+=("$service=$ref")
    echo "Re-tagged the $service image of $rc as $target: $ref"
  done <<< "$selection"
  echo "Nothing was built or scanned for $tag: the images are those of $rc, built and scanned for it from this commit."
  write_list "$out" "${references[@]}"
  exit 0
fi

out="$2"

# Every image first, so that a missing one stops the run before anything is pushed.
while IFS=$'\t' read -r service _ image; do
  [[ -n "$service" ]] || continue
  docker image inspect --format '{{.Id}}' "$image" >/dev/null 2>&1 ||
    die "The $service image ($image) is not on this host. scripts/scan-images.sh builds and scans every image first; run it with the same WAREHOUSE_STATE_DIR. Nothing was published."
done <<< "$recipes"

# The scanned image under its release name, with the two labels that name its commit and its release. The labels are added by a build
# that starts FROM the tagged image and has no instruction of its own, so the layers are those that were scanned; that is checked, and
# a difference stops the run before anything is pushed.
label_image() {
  local service="$1" image="$2" target="$3" scanned labelled
  docker tag "$image" "$target" || die "Could not tag the $service image as $target."
  printf 'FROM %s\n' "$target" |
    docker build --pull=false --label "org.opencontainers.image.revision=$commit" --label "org.opencontainers.image.version=$tag" --tag "$target" - > /dev/null ||
    die "Could not label the $service image ($target) with its commit and release. Nothing was published."
  scanned="$(docker image inspect --format '{{json .RootFS.Layers}}' "$image")" || die "Could not read the layers of the $service image ($image). Nothing was published."
  labelled="$(docker image inspect --format '{{json .RootFS.Layers}}' "$target")" || die "Could not read the layers of $target. Nothing was published."
  [[ -n "$scanned" && "$scanned" == "$labelled" ]] ||
    die "The labelled $service image ($target) does not have the layers of the image that was scanned ($image). Nothing was published."
}

while IFS=$'\t' read -r service _ image; do
  [[ -n "$service" ]] || continue
  label_image "$service" "$image" "$REGISTRY/$service:$image_tag"
done <<< "$recipes"

references=()
while IFS=$'\t' read -r service _ image; do
  [[ -n "$service" ]] || continue
  target="$REGISTRY/$service:$image_tag"
  pushed="$(docker push "$target" 2>&1)" || { printf '%s\n' "$pushed" >&2; die "Pushing $target failed. The list of images was not written."; }
  printf '%s\n' "$pushed"
  digest="$(printf '%s\n' "$pushed" | sed -n 's/.*digest: \(sha256:[0-9a-f]\{64\}\).*/\1/p' | tail -n 1)"
  [[ -n "$digest" ]] || die "The registry did not report a digest for $target. The list of images was not written."
  references+=("$service=$REGISTRY/$service@$digest")
  echo "Published the $service image: $REGISTRY/$service@$digest"
done <<< "$recipes"

write_list "$out" "${references[@]}"

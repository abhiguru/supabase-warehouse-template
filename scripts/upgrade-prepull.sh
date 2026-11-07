#!/usr/bin/env bash
# Pre-pull of an upgrade, run by scripts/upgrade-preflight.sh of the release an installation moves to, before the API is closed. The images
# the move needs are fetched while the facility still serves, so that the setup inside the downtime window (and the way back, which runs the
# old images again) does not depend on a registry that may be slow or unreachable at that moment:
#   - every image that release-images.json of the release lists (ghcr.io/abhiguru/supabase-warehouse-template/<service>@sha256:<digest>),
#     fetched the way scripts/build-images.sh --from-release fetches it, checked against the tag and the commit, and pulled by its digest;
#   - every image that docker/docker-compose.yml of the release names by digest (the Docker Hub images, such as PostgREST).
# Pulling is all it does: it never runs `docker tag`, because the tag <project>-<service> names the images the facility runs now (upgrade.sh
# tags them as pre-<release> next, and the way back puts them back); setup of the new release tags the pulled images itself and finds them
# on this host. Anything that is not a release tag (--ref), a host that is not x86-64 (the images are built for x86-64 only) or without
# curl is skipped with one line. A release with no release-images.json (the download answers 404) is skipped with one warning: setup pulls or builds inside the downtime, as before. A download that fails otherwise (network, 5xx), a file that does not fit the release, a pull that fails or times out, or a pulled
# image of another digest or commit refuses the upgrade: nothing has been changed yet, and the same command can be run again.
#
# From the preflight, in the environment: STATE, TO_SHA, TO_LABEL, DRY (yes for --dry-run: the file is fetched and checked, nothing is pulled).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE="$(dirname "$HERE")"
say() { printf '%s\n' "$*"; }
refuse() { printf 'Refusing: %s Nothing was changed.\n' "$*" >&2; exit 1; }

: "${STATE:?the preflight sets STATE}"
: "${TO_SHA:?the preflight sets TO_SHA}"
: "${TO_LABEL:?the preflight sets TO_LABEL}"
DRY="${DRY:-no}"
SEMVER='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
[[ "$STATE" == /* && -d "$STATE/config" ]] || refuse "STATE is not an installed operator state ('$STATE')."

skip() { say "Pre-pull of images: not done: $*"; exit 0; }
[[ "$TO_LABEL" =~ $SEMVER ]] || skip "$TO_LABEL is not a release tag, so its images are built on this host during setup."
[[ "$TO_SHA" =~ ^[0-9a-f]{40}$ ]] || refuse "the commit of $TO_LABEL is not a 40-digit SHA ('$TO_SHA'), so its images cannot be checked."
arch="$(uname -m 2>/dev/null || true)"
[[ "$arch" == x86_64 ]] || skip "the release images are built for x86-64 and this host is ${arch:-of an unknown architecture}; setup builds them here."
command -v curl >/dev/null || skip 'curl is not installed; setup builds the images here.'
command -v docker >/dev/null || refuse 'docker is not installed, so the images of the release cannot be pulled.'

# The same address and the same curl as scripts/build-images.sh (select_release_images); tests/upgrade-prepull.test.mjs compares the two.
url="https://github.com/abhiguru/supabase-warehouse-template/releases/download/${TO_LABEL//+/%2B}/release-images.json"
file="$(mktemp "$STATE/config/.release-images.XXXXXX")" || refuse "a temporary file cannot be made in $STATE/config."
trap 'rm -f -- "$file"' EXIT
err="$(mktemp "$STATE/config/.release-images-err.XXXXXX")" || refuse "a temporary file cannot be made in $STATE/config."
trap 'rm -f -- "$file" "$err"' EXIT
rc=0
code="$(curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 --max-time 60 --max-filesize 1048576 --output "$file" --write-out '%{http_code}' "$url" 2> "$err")" || rc=$?
if ((rc != 0)); then
  why="$(tr '\n' ' ' < "$err")"
  # The release published no such file (an older release, or one whose images were not published): nothing to pull ahead of time, and setup
  # pulls or builds inside the downtime as it always did. Anything else (the network, a 5xx, a timeout) refuses: the registry host is not answering.
  if [[ "$code" == 404 ]]; then
    printf 'Warning: %s answers 404 (%s): release %s has no release-images.json, so its images are not pulled ahead; setup pulls or builds them while the API is closed.\n' "$url" "${why:-not found}" "$TO_LABEL" >&2
    exit 0
  fi
  refuse "$url could not be fetched (${why:-curl failed}${code:+, HTTP $code}), so the images of $TO_LABEL cannot be pulled before the downtime. Run this command again when the network is back."
fi
# Checks the file against the release and the commit (and its recipes hash); with no service named it prints nothing.
if ! selection="$(node "$HERE/image-recipes.mjs" release-select "$file" "$TO_LABEL" "$TO_SHA" 2>&1)"; then
  refuse "$selection."
fi
refs=()
while IFS= read -r ref; do [[ -z "$ref" ]] || refs+=("$ref"); done < <(node -e '
  const manifest = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  for (const [, entry] of Object.entries(manifest.images).sort(([a], [b]) => a.localeCompare(b))) console.log(entry.ref);' "$file")
((${#refs[@]})) || refuse "release-images.json of $TO_LABEL lists no image."
hub=()
while IFS= read -r ref; do [[ -z "$ref" ]] || hub+=("$ref"); done < <(sed -n 's/^[[:space:]]*image:[[:space:]]*\([^$[:space:]]*@sha256:[0-9a-f]\{64\}\)[[:space:]]*$/\1/p' "$TREE/docker/docker-compose.yml")

# Signatures first, before anything is pulled, in --dry-run too (scripts/verify-image-signature.sh; a release without docker/images-signed is not
# checked, as before). A signature that does not check refuses the upgrade. So does a host without cosign, unless the operator passed
# --unsigned to upgrade.sh (WAREHOUSE_UNSIGNED=yes): then the images are used unverified, with a warning and a line in upgrades.log.
for ref in "${refs[@]}"; do
  sig_rc=0
  bash "$HERE/verify-image-signature.sh" "$ref" || sig_rc=$?
  case "$sig_rc" in
    0) ;;
    10) break ;;
    11)
      if [[ "${WAREHOUSE_UNSIGNED:-}" == yes ]]; then
        printf 'Warning: cosign is not installed and --unsigned was given: the images of %s are used WITHOUT checking their signatures.\n' "$TO_LABEL" >&2
        if [[ "$DRY" != yes ]]; then
          (umask 077; printf '%s %s unsigned: images of %s used without a signature check (cosign missing, --unsigned)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${FROM_LABEL:-?}" "$TO_LABEL" >> "$STATE/config/upgrades.log") 2>/dev/null ||
            printf 'Warning: could not write %s/config/upgrades.log.\n' "$STATE" >&2
        fi
        break
      fi
      refuse "cosign is not installed, so the signatures of the images of $TO_LABEL cannot be checked. Install it: git show $TO_LABEL:scripts/install-cosign.sh | bash -s -- \"$STATE\" (a pinned, checksummed download, docs/OPERATOR_INSTALL.md, \"Check the image signatures\"), then run the upgrade again; or pass --unsigned to upgrade.sh to go on without the check (it is logged)." ;;
    *) refuse "the signature of the image $ref of $TO_LABEL did not check (see above). Do not upgrade to this release until the maintainer has answered (docs/RELEASE_CHECKLIST.md, \"Image publication\")." ;;
  esac
done

if [[ "$DRY" == yes ]]; then
  say "Pre-pull of images: a real run would pull ${#refs[@]} image(s) of $TO_LABEL and ${#hub[@]} base image(s) before the API is closed (this dry run pulls nothing)."
  exit 0
fi

limit="${WAREHOUSE_IMAGE_PULL_TIMEOUT:-1200}"
[[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=1200
pull() {
  local ref="$1" rc=0 out
  if command -v timeout >/dev/null; then out="$(timeout -k 10 "$limit" docker pull --quiet "$ref" 2>&1)" || rc=$?
  else out="$(docker pull --quiet "$ref" 2>&1)" || rc=$?; fi
  if ((rc == 124 || rc == 137)); then refuse "pulling $ref took longer than $limit seconds and was stopped. Run this command again, or raise WAREHOUSE_IMAGE_PULL_TIMEOUT."; fi
  ((rc == 0)) || refuse "could not pull $ref: ${out##*$'\n'}. Run this command again when the registry answers."
  # Docker records RepoDigests as repository@sha256:..., without the tag, so a tag-and-digest reference (repo:tag@sha256:...) is compared in that form.
  # Only a tag after the last "/" is removed, so a registry port (host:5000/y:tag@sha256:...) stays.
  local name="${ref%@*}" last prefix want
  last="${name##*/}"; prefix="${name%"$last"}"
  want="$prefix${last%%:*}@${ref##*@}"
  if ! grep -qxF -- "$want" <<< "$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$ref" 2>/dev/null || true)"; then
    refuse "the pulled image does not carry the digest ${ref##*@} that was asked for ($ref)."
  fi
}
say "Pre-pull of images: pulling ${#refs[@]} image(s) of $TO_LABEL and ${#hub[@]} base image(s) while the facility still serves (nothing is tagged; setup finds them on this host)."
for ref in "${refs[@]}"; do
  pull "$ref"
  revision="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$ref" 2>/dev/null || true)"
  if [[ "$revision" != "$TO_SHA" ]]; then
    docker image rm "$ref" >/dev/null 2>&1 || true
    refuse "the pulled image $ref was built from commit ${revision:-<no revision label>}, not from the commit ${TO_SHA:0:12} of $TO_LABEL."
  fi
done
for ref in "${hub[@]}"; do pull "$ref"; done
say "Pre-pull of images: done (${#refs[@]} image(s) of $TO_LABEL, ${#hub[@]} base image(s))."

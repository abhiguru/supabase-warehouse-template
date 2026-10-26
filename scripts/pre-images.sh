#!/usr/bin/env bash
# The images of the release an installation is moved away from, kept by name so that the way back needs no build.
#
#   bash scripts/pre-images.sh name LABEL      print the tag suffix for a release label: pre-<label>
#   bash scripts/pre-images.sh tag LABEL       tag every image a container of this installation uses (running first, then the
#                                              stopped ones: an optional service that is stopped is part of the set) and that this
#                                              installation built (<project>-<service>) as <project>-<service>:pre-<label>, and
#                                              keep a copy of the build record (config/image-recipes.pre-<label>.sha256)
#   bash scripts/pre-images.sh restore LABEL   point <project>-<service> at those tagged images again and put the build record
#                                              back, so setup.sh and restore.sh of the old release find its images current
#   bash scripts/pre-images.sh prune LABEL [TAG]
#                                              remove every pre-* tag of this installation except those of pre-<label> (a tag
#                                              at a time, by its exact name; never an image prune), and the other saved records.
#                                              TAG (pre-<something>), when given, is the set to keep instead of the one this
#                                              script would name for LABEL: upgrade.sh passes the tag it recorded when it tagged,
#                                              so a later release that names tags differently cannot remove the set just made
#
# upgrade.sh runs `tag` before it checks the new release out and `prune` once setup has succeeded; the way back that
# scripts/upgrade-record.mjs prints runs `restore` after the checkout of the old commit. Without this, the old release's setup
# builds its images again from the internet, because the new release's build replaced the tags and the build record
# (docs/OPERATOR_INSTALL.md, "Rerun and upgrade"). A release keeps these four commands (and the optional TAG of `prune`) working
# for the upgrade.sh of earlier releases.
# Exit codes of `tag`: 0 at least one image was tagged, 3 there was nothing to tag (no Docker, no running image of this
# installation's own), anything else a failure. The other commands exit 0, or 1 when Docker refused something.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() { echo 'Usage: bash scripts/pre-images.sh name|tag|restore|prune LABEL [pre-TAG, for prune only]' >&2; exit 2; }
(($# == 2 || $# == 3)) || usage
command="$1"
label="$2"
[[ -n "$label" ]] || usage

# A tag may hold letters, digits, _ . - and starts with a letter or digit; a release label is a tag name or a short commit.
suffix="pre-$(printf '%s' "$label" | tr -c 'A-Za-z0-9_.-' '_' | cut -c1-100)"
if (($# == 3)); then
  [[ "$command" == prune && "$3" =~ ^pre-[A-Za-z0-9_.-]{1,100}$ ]] || usage
  suffix="$3"
fi
case "$command" in
  name) printf '%s\n' "$suffix"; exit 0 ;;
  tag|restore|prune) ;;
  *) usage ;;
esac

# shellcheck source=scripts/operator-lock.sh
. "$ROOT/scripts/operator-lock.sh"
state="$(operator_state)"
operator_lock_or_inherited "$state"
project="$(sed -n 's/^WAREHOUSE_PROJECT_NAME=//p' "$state/config/compose.env" 2>/dev/null | head -n 1)"
[[ "$project" =~ ^warehouse-[a-z0-9-]+$ ]] || { echo "Note: config/compose.env names no installation (WAREHOUSE_PROJECT_NAME), so there are no images to $command." >&2; [[ "$command" == tag ]] && exit 3; exit 0; }
command -v docker >/dev/null || { echo "Note: docker is not on PATH, so there are no images to $command." >&2; [[ "$command" == tag ]] && exit 3; exit 0; }
record="$state/config/image-recipes.sha256"
saved="$state/config/image-recipes.$suffix.sha256"

# "<repository> <tag>" of every image of this installation's own (<project>-...).
own_images() { docker image ls --format '{{.Repository}} {{.Tag}}' | awk -v p="$project-" 'index($1, p) == 1'; }

case "$command" in
  tag)
    declare -A seen=()
    tagged=0
    while read -r container; do
      [[ -n "$container" ]] || continue
      read -r image id < <(docker inspect --format '{{.Config.Image}} {{.Image}}' "$container" 2>/dev/null) || continue   # gone since the listing
      repo="${image%%:*}"
      # A pulled image (another registry, a digest) is not ours to name; only what this installation built.
      [[ "$repo" == "$project"-* && "$image" != *@* && -n "$id" && -z "${seen[$repo]:-}" ]] || continue
      seen["$repo"]=1
      docker tag "$id" "$repo:$suffix"
      tagged=$((tagged + 1))
    # The running containers first, so that where a service has a stopped container of an older image too, the image that runs is the one
    # tagged; then every container of the project, for the optional services that are stopped (their image is part of what the old
    # release's setup would otherwise build again).
    done < <(docker ps -q --filter "label=com.docker.compose.project=$project"; docker ps -aq --filter "label=com.docker.compose.project=$project")
    if ((tagged == 0)); then echo "Note: no container of $project uses an image it built; nothing was tagged $suffix." >&2; exit 3; fi
    if [[ -f "$record" && ! -L "$record" ]]; then
      cp -p -- "$record" "$saved.tmp" && mv -f -- "$saved.tmp" "$saved" || echo "Warning: could not keep a copy of the build record as $saved; the way back will rebuild the images it finds out of date." >&2
    fi
    echo "Tagged $tagged image(s) of $project as :$suffix (the way back puts them back with: bash scripts/pre-images.sh restore '$label')."
    ;;
  restore)
    restored=0
    while read -r repo tag; do
      [[ "$tag" == "$suffix" ]] || continue
      docker tag "$repo:$suffix" "$repo"
      restored=$((restored + 1))
    done < <(own_images)
    if ((restored == 0)); then
      echo "Note: no image of $project is tagged :$suffix (an upgrade by an older upgrade.sh does not tag them, or they were removed). The old release's setup builds its images again, which needs the network."
      exit 0
    fi
    if [[ -f "$saved" && ! -L "$saved" ]]; then
      cp -p -- "$saved" "$record.tmp" && mv -f -- "$record.tmp" "$record" || { echo "Warning: could not put the build record back from $saved; setup will rebuild the images." >&2; exit 1; }
    else
      echo "Note: no saved build record ($saved); the old release's setup rebuilds the images whose recipe it cannot match." >&2
    fi
    echo "Put back $restored image(s) of $project from :$suffix."
    ;;
  prune)
    failed=0
    while read -r repo tag; do
      [[ "$tag" == pre-* && "$tag" != "$suffix" ]] || continue
      docker image rm "$repo:$tag" >/dev/null || { echo "Warning: could not remove the image tag $repo:$tag; remove it by hand with: docker image rm $repo:$tag" >&2; failed=1; }
    done < <(own_images)
    for old in "$state"/config/image-recipes.pre-*.sha256; do
      [[ -e "$old" && "$old" != "$saved" ]] || continue
      rm -f -- "$old"
    done
    exit "$failed"
    ;;
esac

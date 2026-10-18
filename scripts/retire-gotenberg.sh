#!/usr/bin/env bash
# Upgrade path from the Gotenberg PDF service to pdf-renderer (docker/pdf-renderer).
#   container   remove this project's old gotenberg container, if any
#   image       remove this project's old gotenberg image, once nothing uses it
# setup.sh and start.sh run `container` before `compose up` (the service is gone from
# docker-compose.yml, so Compose would otherwise leave it running as an orphan, still
# holding its memory) and `image` after the services started. Both are safe to repeat
# and to run on a fresh install, where they find nothing. They touch only a container
# or image of this operator state's Compose project, started from this checkout.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${WAREHOUSE_STATE_DIR:-}"
PROJECT="$(sed -n 's/^WAREHOUSE_PROJECT_NAME=//p' "$STATE/config/compose.env" 2>/dev/null || true)"
[[ "$PROJECT" =~ ^warehouse-[a-z0-9-]+$ ]] || { echo 'Invalid private WAREHOUSE_PROJECT_NAME.' >&2; exit 1; }
case "${1:-}" in
  container)
    ids=$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" --filter 'label=com.docker.compose.service=gotenberg')
    for id in $ids; do
      owner=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$id")
      if [[ "$owner" != "$ROOT/docker" ]]; then
        echo "Left the gotenberg container $id: project $PROJECT belongs to another checkout." >&2
        continue
      fi
      docker rm -f "$id" >/dev/null
      echo "Removed the old gotenberg container of $PROJECT (replaced by pdf-renderer)."
    done ;;
  image)
    image="$PROJECT-gotenberg"
    if docker image inspect "$image" >/dev/null 2>&1; then
      if docker image rm "$image" >/dev/null 2>&1; then
        echo "Removed the old image $image (replaced by pdf-renderer)."
      else
        echo "Kept the old image $image: Docker would not remove it (still in use?)." >&2
      fi
    fi ;;
  *) echo 'Usage: bash scripts/retire-gotenberg.sh container|image' >&2; exit 1 ;;
esac

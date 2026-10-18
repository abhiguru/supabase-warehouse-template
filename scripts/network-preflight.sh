#!/usr/bin/env bash
# Address-pool preflight for the internal `renderer` network (docker/docker-compose.yml): before
# setup.sh or start.sh retires or starts anything, create and remove a throwaway internal network
# `<project>_netcheck`. Docker has a limited pool of private subnets; when it is used up, `compose up`
# fails on the new network only after the old Gotenberg container is already gone. Failing here
# leaves the installation exactly as it was. The network carries the label warehouse.preflight=<project>
# and is removed on every exit; a leftover one of this project (a killed earlier run) is removed first.
set -euo pipefail
STATE="${WAREHOUSE_STATE_DIR:-}"
PROJECT="$(sed -n 's/^WAREHOUSE_PROJECT_NAME=//p' "$STATE/config/compose.env" 2>/dev/null || true)"
[[ "$PROJECT" =~ ^warehouse-[a-z0-9-]+$ ]] || { echo 'Invalid private WAREHOUSE_PROJECT_NAME.' >&2; exit 1; }
name="${PROJECT}_netcheck"
if [[ "$(docker network inspect --format '{{index .Labels "warehouse.preflight"}}' "$name" 2>/dev/null || true)" == "$PROJECT" ]]; then
  docker network rm "$name" >/dev/null 2>&1 || true
fi
if ! docker network create --internal --label "warehouse.preflight=$PROJECT" "$name" >/dev/null 2>&1; then
  echo "Docker cannot create a network for $PROJECT: no free address pool, or the Docker daemon refused. The PDF renderer needs its own internal network, so nothing was changed. Free a pool (docker network prune removes only unused networks; check docker network ls), or set a larger default-address-pools in /etc/docker/daemon.json, then run this again." >&2
  exit 1
fi
docker network rm "$name" >/dev/null 2>&1 || { echo "Created the check network $name but could not remove it; remove it with: docker network rm $name" >&2; exit 1; }

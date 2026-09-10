#!/usr/bin/env bash
# Only operate on containers belonging to this checkout, never an existing Supabase.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${WAREHOUSE_PROJECT_NAME:-warehouse-template}"
if [[ ! "$PROJECT" =~ ^warehouse-[a-z0-9-]+$ ]]; then
  echo "WAREHOUSE_PROJECT_NAME must start with warehouse- (lowercase letters, digits, hyphens)." >&2
  exit 1
fi
if [[ ! -f "$ROOT/docker/.env" ]]; then
  echo "Missing docker/.env. See docs/READINESS.md before running setup." >&2
  exit 1
fi
# A project name alone is not enough if a second checkout reused it.
ids=$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")
for id in $ids; do
  owner=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$id")
  if [[ "$owner" != "$ROOT/docker" ]]; then
    echo "Refusing: project $PROJECT belongs to another checkout. Choose a unique WAREHOUSE_PROJECT_NAME." >&2
    exit 1
  fi
done
exec docker compose --project-directory "$ROOT/docker" --project-name "$PROJECT" \
  --env-file "$ROOT/docker/.env" -f "$ROOT/docker/docker-compose.yml" \
  -f "$ROOT/docker/docker-compose.override.yml" "$@"

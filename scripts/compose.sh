#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${WAREHOUSE_STATE_DIR:-}"
if [[ "$STATE" == /* ]]; then STATE="$(realpath -m "$STATE")"; fi
if [[ -z "$STATE" || "$STATE" != /* || ! -d "$STATE" || -L "$STATE" || "$STATE" == "$ROOT" || "$STATE" == "$ROOT"/* ]]; then
  echo 'Set WAREHOUSE_STATE_DIR to the absolute operator state path outside this checkout.' >&2
  exit 1
fi
STATE_REAL="$(realpath -e "$STATE")"
if [[ "$STATE_REAL" == "$ROOT" || "$STATE_REAL" == "$ROOT"/* || "$(stat -c %u "$STATE")" != "$(id -u)" || "$(stat -c %a "$STATE")" != 700 ]]; then
  echo 'Operator state must be owned by this user, mode 0700, and outside the checkout.' >&2
  exit 1
fi
ENV_FILE="$STATE/config/compose.env"
if [[ ! -f "$ENV_FILE" || -L "$ENV_FILE" || "$(stat -c %a "$ENV_FILE")" != 600 ]]; then
  echo "Missing private operator configuration: $ENV_FILE" >&2
  exit 1
fi
PROJECT="$(sed -n 's/^WAREHOUSE_PROJECT_NAME=//p' "$ENV_FILE")"
DB_PATH="$(sed -n 's/^WAREHOUSE_DB_PATH=//p' "$ENV_FILE")"
STORAGE_PATH="$(sed -n 's/^WAREHOUSE_STORAGE_PATH=//p' "$ENV_FILE")"
if [[ ! "$PROJECT" =~ ^warehouse-[a-z0-9-]+$ ]]; then
  echo 'Invalid private WAREHOUSE_PROJECT_NAME.' >&2
  exit 1
fi
if [[ "$DB_PATH" != "$STATE/data/db" || "$STORAGE_PATH" != "$STATE/data/storage" || ! -d "$DB_PATH" || ! -d "$STORAGE_PATH" || -L "$DB_PATH" || -L "$STORAGE_PATH" ]]; then
  echo 'Private database/storage paths differ from this state directory.' >&2
  exit 1
fi
ids=$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")
for id in $ids; do
  owner=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$id")
  if [[ "$owner" != "$ROOT/docker" ]]; then
    echo "Refusing: project $PROJECT belongs to another checkout." >&2
    exit 1
  fi
  service=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$id")
  case "$service" in
    db) expected="$DB_PATH"; destination='/var/lib/postgresql/data' ;;
    storage|imgproxy) expected="$STORAGE_PATH"; destination='/var/lib/storage' ;;
    *) continue ;;
  esac
  actual=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "'"$destination"'"}}{{.Source}}{{end}}{{end}}' "$id")
  if [[ "$actual" != "$expected" ]]; then
    echo "Refusing: existing $service container uses another data path." >&2
    exit 1
  fi
done
exec docker compose --project-directory "$ROOT/docker" --project-name "$PROJECT" \
  --env-file "$ENV_FILE" -f "$ROOT/docker/docker-compose.yml" \
  -f "$ROOT/docker/docker-compose.override.yml" "$@"

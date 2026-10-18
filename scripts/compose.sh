#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${WAREHOUSE_STATE_DIR:-}"
if [[ "$STATE" == /* ]]; then
  if [[ "$(realpath -m "$STATE")" != "$(realpath -ms "$STATE")" ]]; then
    echo 'Operator state path must not use a symlink.' >&2
    exit 1
  fi
  STATE="$(realpath -ms "$STATE")"
fi
if [[ -z "$STATE" || "$STATE" != /* || ! -d "$STATE" || -L "$STATE" || "$STATE" == "$ROOT" || "$STATE" == "$ROOT"/* ]]; then
  echo 'Set WAREHOUSE_STATE_DIR to the absolute operator state path outside this checkout.' >&2
  exit 1
fi
STATE_REAL="$(realpath -e "$STATE")"
if [[ "$STATE_REAL" == "$ROOT" || "$STATE_REAL" == "$ROOT"/* || "$(stat -c %u "$STATE")" != "$(id -u)" || "$(stat -c %a "$STATE")" != 700 ]]; then
  echo 'Operator state must be owned by this user, mode 0700, and outside the checkout.' >&2
  exit 1
fi
if [[ "$STATE_REAL" != "$STATE" ]]; then
  echo 'Operator state path must not use a symlink.' >&2
  exit 1
fi
ENV_FILE="$STATE/config/compose.env"
if [[ ! -d "$STATE/config" || -L "$STATE/config" || ! -f "$ENV_FILE" || -L "$ENV_FILE" || "$(stat -c %u "$ENV_FILE")" != "$(id -u)" || "$(stat -c %a "$ENV_FILE")" != 600 ]]; then
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
if [[ "$DB_PATH" != "$STATE/data/db" || "$STORAGE_PATH" != "$STATE/data/storage" || ! -d "$STATE/data" || -L "$STATE/data" || ! -d "$DB_PATH" || ! -d "$STORAGE_PATH" || -L "$DB_PATH" || -L "$STORAGE_PATH" ]]; then
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
unset_args=()
while IFS= read -r line; do
  if [[ "$line" =~ ^([A-Z][A-Z0-9_]*)= ]]; then unset_args+=(-u "${BASH_REMATCH[1]}"); fi
done < "$ENV_FILE"
# Monitoring (docs/MONITORING.md): setup.sh renders the per-installation Prometheus and Alertmanager files
# into config/monitoring and creates metrics/, the textfile directory the backup scripts write and node
# exporter reads. The two sha256 values are labels of the prometheus and alertmanager services: when a
# rendered file or the alert rules change, `compose up` sees a changed service and replaces the running
# container, which does not reload its files by itself (Prometheus runs without --web.enable-lifecycle).
export WAREHOUSE_MONITORING_PATH="$STATE/config/monitoring" WAREHOUSE_METRICS_PATH="$STATE/metrics" WAREHOUSE_ALERTMANAGER_PATH="$STATE/data/alertmanager"
config_sha256() { cat -- "$@" 2>/dev/null | sha256sum | cut -d' ' -f1; }
export WAREHOUSE_PROMETHEUS_CONFIG_SHA256="$(config_sha256 "$WAREHOUSE_MONITORING_PATH/prometheus.yml" "$ROOT/docker/alert-rules.yml")"
export WAREHOUSE_ALERTMANAGER_CONFIG_SHA256="$(config_sha256 "$WAREHOUSE_MONITORING_PATH/alertmanager/alertmanager.yml")"
# WAREHOUSE_PUBLIC_PATH: the functions service reads the optional central
# sign-in key file from the state's public directory (next to instance.json).
# imgproxy reads the private storage directory (mode 0700, owned by this user)
# and so runs as this user; see the imgproxy service in docker-compose.yml.
exec env "${unset_args[@]}" WAREHOUSE_HOST_UID="$(id -u)" WAREHOUSE_HOST_GID="$(id -g)" WAREHOUSE_PUBLIC_PATH="$STATE/public" docker compose --project-directory "$ROOT/docker" --project-name "$PROJECT" \
  --env-file "$ENV_FILE" -f "$ROOT/docker/docker-compose.yml" \
  -f "$ROOT/docker/docker-compose.override.yml" "$@"

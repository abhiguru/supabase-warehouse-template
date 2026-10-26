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
    storage) expected="$STORAGE_PATH"; destination='/var/lib/storage' ;;
    *) continue ;;
  esac
  actual=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "'"$destination"'"}}{{.Source}}{{end}}{{end}}' "$id")
  if [[ "$actual" != "$expected" ]]; then
    echo "Refusing: existing $service container uses another data path." >&2
    exit 1
  fi
  # The db container must also keep its data directory where the bind mount is (PGDATA, docker-compose.yml).
  if [[ "$service" == db ]] && ! docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$id" | grep -qx 'PGDATA=/var/lib/postgresql/data'; then
    echo "Refusing: existing db container does not use PGDATA=/var/lib/postgresql/data." >&2
    exit 1
  fi
done
unset_args=()
while IFS= read -r line; do
  if [[ "$line" =~ ^([A-Z][A-Z0-9_]*)= ]]; then unset_args+=(-u "${BASH_REMATCH[1]}"); fi
done < "$ENV_FILE"
# WAREHOUSE_PUBLIC_PATH: the functions service reads the optional central
# sign-in key file from the state's public directory (next to instance.json).
# WAREHOUSE_COMPOSE_EXTRA: one more Compose file (an absolute path), merged after the shipped one. CI uses it to give
# the default network a fixed subnet; an operator has no use for it.
extra=()
if [[ -n "${WAREHOUSE_COMPOSE_EXTRA:-}" ]]; then
  if [[ "$WAREHOUSE_COMPOSE_EXTRA" != /* || ! -f "$WAREHOUSE_COMPOSE_EXTRA" ]]; then
    echo 'WAREHOUSE_COMPOSE_EXTRA must be the absolute path of an existing file.' >&2
    exit 1
  fi
  extra=(-f "$WAREHOUSE_COMPOSE_EXTRA")
fi
# The LAN fallback (docs/OPERATOR_INSTALL.md, "LAN fallback"): COMPOSE_PROFILES=lan in compose.env starts the gateway-lan service, which
# publishes the host's own LAN address. If the host no longer has that address (the router gave it another one) Docker cannot start the
# container, and a failed start can stop `up` for the public services beside it. Only then is the profile left out of this one command
# (scripts/lan.mjs guard prints the replacement list and says why on stderr); without node, or on any error, nothing is changed.
lan_override=()
if grep -Eq '^COMPOSE_PROFILES=.*\blan\b' "$ENV_FILE" && command -v node >/dev/null 2>&1; then
  guard="$(node "$ROOT/scripts/lan.mjs" guard "$ENV_FILE" || true)"
  if [[ "$guard" == COMPOSE_PROFILES=* ]]; then lan_override=("$guard"); fi
fi
exec env "${unset_args[@]}" "${lan_override[@]}" WAREHOUSE_PUBLIC_PATH="$STATE/public" docker compose --project-directory "$ROOT/docker" --project-name "$PROJECT" \
  --env-file "$ENV_FILE" -f "$ROOT/docker/docker-compose.yml" "${extra[@]}" "$@"

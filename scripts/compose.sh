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
# COMPOSE_PROFILES is always unset first, so that config/compose.env alone decides which profile services a command sees: a shell that
# has COMPOSE_PROFILES='*' or lan in its environment must not start gateway-lan, a printing service or the pooler (the guard below
# sets it again, for one command, when it has a reason to). WAREHOUSE_MAINTENANCE is unset first for the same reason: only the marker
# below decides whether the gateways are in maintenance mode.
unset_args=(-u COMPOSE_PROFILES -u WAREHOUSE_MAINTENANCE)
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
# publishes the host's own LAN address. Two things leave the profile out of one command:
#  - WAREHOUSE_COMPOSE_WITHOUT_LAN=1, which start.sh, setup.sh and restore.sh set on the `up` that waits for the services: a fault of the
#    fallback (the port is taken, the container is unhealthy) must never stop a start, a setup, an upgrade or a restore, so that start
#    waits for the public services only and gateway-lan is started apart (scripts/lan.sh start), as a warning when it fails;
#  - the guard (scripts/lan.mjs guard): the host no longer has the address (the router gave it another one) and Docker cannot start the
#    container, and a failed start can stop `up` for the public services beside it; or the address is not private. It prints the replacement
#    list and says why on stderr; without node, or on any error, nothing is changed.
lan_override=()
if grep -Eq '^COMPOSE_PROFILES=.*\blan\b' "$ENV_FILE"; then
  if [[ "${WAREHOUSE_COMPOSE_WITHOUT_LAN:-}" == 1 ]]; then
    others="$(sed -n 's/^COMPOSE_PROFILES=//p' "$ENV_FILE" | head -n 1 | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | { grep -vx -e lan -e '' || true; } | paste -sd, -)"
    lan_override=("COMPOSE_PROFILES=$others")
  elif command -v node >/dev/null 2>&1; then
    guard="$(node "$ROOT/scripts/lan.mjs" guard "$ENV_FILE" || true)"
    if [[ "$guard" == COMPOSE_PROFILES=* ]]; then lan_override=("$guard"); fi
  fi
fi
# Maintenance mode (scripts/maintenance.sh, upgrade.sh; docker/docker-compose.yml, the gateway services): the marker config/maintenance means the
# gateways answer 503 "upgrading" to every API request. It is a marker and not a line of compose.env because it is not a setting of this
# installation: it lasts for one upgrade and is removed at the end of it. Every command gets it for as long as the file exists (it counts
# when it exists, whatever it holds: a marker nobody can read still closes the API), so that no command can recreate a gateway that is open:
# start.sh after a reboot, the setup of the next release, a restore, the checker starting a stopped gateway.
maintenance_override=()
if [[ -e "$STATE/config/maintenance" || -L "$STATE/config/maintenance" ]]; then maintenance_override=(WAREHOUSE_MAINTENANCE=upgrading); fi
exec env "${unset_args[@]}" "${lan_override[@]}" "${maintenance_override[@]}" WAREHOUSE_PUBLIC_PATH="$STATE/public" docker compose --project-directory "$ROOT/docker" --project-name "$PROJECT" \
  --env-file "$ENV_FILE" -f "$ROOT/docker/docker-compose.yml" "${extra[@]}" "$@"

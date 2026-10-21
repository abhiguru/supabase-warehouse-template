#!/usr/bin/env bash
# Shared helpers for the baseline tooling. Sourced, not run.
# Everything here touches ONLY throwaway containers named slim-tool-* and throwaway internal networks named
# slim-tool-net-*; a database container is on no network unless the caller passes a network (DB_NET).
BASELINE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# TWO images, on purpose:
#   OLD_DB_IMAGE  the image of the chain. Migrations 000..N only apply there (pg_cron, pg_net, pgjwt, the GoTrue tables come
#                 with it), so the tooling needs it to build the chain database that the baseline is dumped from and
#                 compared with. It is not the shipped image any more and no other script names it.
#   NEW_DB_IMAGE  the shipped image (postgres:17), from the single pin scripts/db-image.sh. The baseline database runs on it.
OLD_DB_IMAGE='supabase/postgres:15.8.1.135@sha256:ee680a0afebe1a5e95614fdea671c01a264e58f52de6c429c17a394f46dec2c6'
NEW_DB_IMAGE="$(bash "$BASELINE_ROOT/scripts/db-image.sh")"
DB_PASSWORD='disposable-test-database-only'

# psql inside a container, as the superuser the migrations run as.
db_psql() { local c="$1"; shift; docker exec -i -e PGPASSWORD="$DB_PASSWORD" "$c" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 "$@"; }

# The migration plan (scripts/migration-plan.mjs) of a directory that holds a migrations/ folder.
plan_of() {
  PLAN_MODULE="$BASELINE_ROOT/scripts/migration-plan.mjs" PLAN_ROOT="$1" \
    node -e "import(process.env.PLAN_MODULE).then(m => process.stdout.write(m.migrationPlan(process.env.PLAN_ROOT)))"
}

# The plan of the CHAIN (migrations 000..110): built with the migration-plan.mjs of the tag migrations-pre-baseline, which
# takes the list-refresh lock 71046 that the chain's migrations 91 to 105 need (this checkout's plan no longer has it, so
# 91 and 106 could deadlock). Without the tag (a shallow clone) this checkout's plan is used.
chain_plan_of() {
  local dir module rc f
  dir="$(mktemp -d)"
  module="$BASELINE_ROOT/scripts/migration-plan.mjs"
  if git -C "$BASELINE_ROOT" cat-file -e 'migrations-pre-baseline^{commit}' 2>/dev/null; then
    mkdir -p "$dir/scripts"
    for f in migration-plan.mjs is-main.mjs; do
      git -C "$BASELINE_ROOT" show "migrations-pre-baseline:scripts/$f" >"$dir/scripts/$f"
    done
    module="$dir/scripts/migration-plan.mjs"
  else
    echo "Warning: no tag migrations-pre-baseline here; the chain is planned with this checkout's migration-plan.mjs (no lock 71046)." >&2
  fi
  PLAN_MODULE="$module" PLAN_ROOT="$1" \
    node -e "import(process.env.PLAN_MODULE).then(m => process.stdout.write(m.migrationPlan(process.env.PLAN_ROOT)))"
  rc=$?
  rm -rf "$dir"
  return $rc
}

# The `-c` flags of a throwaway database.
#   OLD image (no bootstrap): the FROZEN flags the chain was written against (docker/docker-compose.override.yml and
#   tests/migrations.sh at f1236ae, the last commit before the switch; migration 91 creates pg_cron, which must be preloaded
#   and told its database). They do not read the checkout, so the chain still builds after the switch removed pg_cron there.
#   postgres:17 (bootstrap): the shipped flags of this checkout's docker/docker-compose.override.yml.
OLD_DB_FLAGS=(
  shared_preload_libraries=pg_stat_statements,pg_cron
  pg_stat_statements.track=all
  cron.database_name=postgres
  cron.log_statement=off
  wal_level=replica
)
shipped_flags() {
  if [[ -z "${DB_BOOTSTRAP:-}" ]]; then printf '%s\n' "${OLD_DB_FLAGS[@]}"; return; fi
  sed -n 's/^ *-c \(\(shared_preload_libraries\|wal_level\|timezone\|log_timezone\|extra_float_digits\|pg_stat_statements\.[a-z_]*\)=.*\)$/\1/p' \
    "$BASELINE_ROOT/docker/docker-compose.override.yml"
}

# Environment switches of start_db:
#   DB_COMMAND    server command for another image (default: postgres -D /etc/postgresql, the publisher image).
#   DB_BOOTSTRAP  a directory of init scripts (postgres:17 mode, design 13): mounted at /docker-entrypoint-initdb.d, the
#                 cluster is made with POSTGRES_USER=supabase_admin and the en_US.UTF-8 locale, as production does.
#   DB_NET        an existing --internal network to join (containers that must talk to each other); default: no network.
# start_db <image> <name>: starts a throwaway database and waits until it accepts connections.
start_db() {
  local image="$1" name="$2" flags=() f
  while IFS= read -r f; do flags+=(-c "$f"); done < <(shipped_flags)
  [[ " ${flags[*]} " == *shared_preload_libraries=* ]] || { echo 'No shared_preload_libraries in docker-compose.override.yml' >&2; return 1; }
  local extra=() command=(${DB_COMMAND:-postgres -D /etc/postgresql})
  if [[ -n "${DB_BOOTSTRAP:-}" ]]; then
    [[ -d "$DB_BOOTSTRAP" ]] || { echo "Bootstrap directory $DB_BOOTSTRAP does not exist" >&2; return 1; }
    extra+=(-v "$(cd "$DB_BOOTSTRAP" && pwd):/docker-entrypoint-initdb.d:ro"
            -e POSTGRES_USER=supabase_admin -e POSTGRES_DB=postgres -e POSTGRES_INITDB_ARGS=--locale=en_US.UTF-8)
    command=(postgres)
  fi
  docker run -d --rm -v /var/lib/postgresql --name "$name" --label purpose=slim-tool \
    --network "${DB_NET:-none}" --memory 1g --cpus 1 \
    --tmpfs /var/lib/postgresql/data:rw,size=768m -e PGDATA=/var/lib/postgresql/data \
    -e JWT_SECRET=isolated-test-secret-not-for-any-deployment-12345 -e JWT_EXP=3600 \
    -e AUTH_MODE=operator -e APP_ENV=production \
    -e POSTGRES_PASSWORD="$DB_PASSWORD" "${extra[@]}" \
    "$image" "${command[@]}" "${flags[@]}" >/dev/null
  local i
  for ((i = 0; i < 60; i++)); do
    # The image's temporary server answers while the init scripts still run: the bootstrap image logs the end of init.
    init_log=$(docker logs "$name" 2>&1 || true)
    if { [[ -z "${DB_BOOTSTRAP:-}" ]] || [[ "$init_log" == *'PostgreSQL init process complete; ready for start up'* ]]; } \
      && docker exec "$name" pg_isready -U supabase_admin -d postgres -h 127.0.0.1 >/dev/null 2>&1; then
      # pg_isready answers during the image's own init; wait until the real superuser can log in and init is over.
      if docker exec -e PGPASSWORD="$DB_PASSWORD" "$name" psql -X -q -U supabase_admin -d postgres -Atc 'select 1' >/dev/null 2>&1; then return 0; fi
    fi
    sleep 2
  done
  echo "Database $name did not start" >&2
  docker rm -f -v "$name" >/dev/null 2>&1 || true
  return 1
}

# A random suffix that is never empty (an empty one would make the cleanup `docker rm -f -v slim-tool-chain-` name another run's container).
new_name() {
  local suffix
  suffix=$(openssl rand -hex 4 2>/dev/null || true)
  [[ -n "$suffix" ]] || suffix=$(printf '%08x' $(( (RANDOM << 16) ^ (RANDOM << 8) ^ RANDOM ^ $$ )))
  [[ -n "$suffix" ]] || { echo 'No random suffix for a container name' >&2; return 1; }
  echo "slim-tool-$1-$suffix"
}
# The Storage containers of this run (run_storage adds to it); cleanup code removes them before it removes the network.
STORAGE_CONTAINERS=()
remove_storage_containers() {
  local c
  for c in "${STORAGE_CONTAINERS[@]}"; do docker rm -f -v "$c" >/dev/null 2>&1 || true; done
  STORAGE_CONTAINERS=()
}

# The Storage image: the pin in docker/storage/Dockerfile (the version production runs), pulled if it is missing.
storage_image() {
  local ref
  ref=$(sed -n 's/^FROM \(supabase\/storage-api:[^ ]*\).*/\1/p' "$BASELINE_ROOT/docker/storage/Dockerfile" | head -n 1)
  [[ -n "$ref" ]] || { echo 'No storage-api image in docker/storage/Dockerfile' >&2; return 1; }
  docker image inspect "$ref" >/dev/null 2>&1 || docker pull -q "$ref" >&2
  echo "$ref"
}

# create_net: makes a throwaway --internal network (no route out) and prints its name. The caller removes it.
create_net() { local n; n=$(new_name net); docker network create --internal --label purpose=slim-tool "$n" >/dev/null; echo "$n"; }

# run_storage <db-container> <network> <storage-image>: runs Storage against a database, the way setup.sh does after the
# migrations (Storage owns the storage schema), waits until its own migrations are done, then removes it. The environment is
# the one in docker/docker-compose.yml, with DB_SUPER_USER / DB_INSTALL_ROLES as in design 13 (no `postgres` role needed).
# The database must be on <network>. Storage is run on BOTH sides of a comparison, so storage.* compares like for like.
run_storage() {
  local db="$1" net="$2" image="$3" name rows i
  name=$(new_name storage) || return 1
  STORAGE_CONTAINERS+=("$name")
  db_psql "$db" -c "ALTER ROLE supabase_storage_admin PASSWORD '$DB_PASSWORD'" >/dev/null
  docker run -d --rm --name "$name" --label purpose=slim-tool --network "$net" --memory 512m --cpus 1 \
    --tmpfs /var/lib/storage:rw,size=64m \
    -e ANON_KEY=disposable-anon-key -e SERVICE_KEY=disposable-service-key -e POSTGREST_URL=http://rest:3000 \
    -e PGRST_JWT_SECRET=isolated-test-secret-not-for-any-deployment-12345 \
    -e "DATABASE_URL=postgres://supabase_storage_admin:$DB_PASSWORD@$db:5432/postgres" \
    -e FILE_SIZE_LIMIT=52428800 -e STORAGE_BACKEND=file -e FILE_STORAGE_BACKEND_PATH=/var/lib/storage \
    -e TENANT_ID=stub -e REGION=stub -e GLOBAL_S3_BUCKET=stub -e ENABLE_IMAGE_TRANSFORMATION=false \
    -e DB_SUPER_USER=supabase_storage_admin -e DB_INSTALL_ROLES=false \
    "$image" >/dev/null
  for ((i = 0; i < 90; i++)); do
    if docker logs "$name" 2>&1 | grep -q 'Started Successfully'; then
      rows=$(db_psql "$db" -At -c 'SELECT count(*) FROM storage.migrations' 2>/dev/null || echo 0)
      if ((rows > 0)); then docker rm -f -v "$name" >/dev/null 2>&1 || true; return 0; fi
    fi
    sleep 2
  done
  echo "Storage did not finish its migrations against $db" >&2
  docker logs --tail 30 "$name" >&2 || true
  docker rm -f -v "$name" >/dev/null 2>&1 || true
  return 1
}

#!/usr/bin/env bash
# Shared helpers for the baseline tooling. Sourced, not run.
# Everything here touches ONLY throwaway containers named slim-tool-* and throwaway internal networks named
# slim-tool-net-*; a database container is on no network unless the caller passes a network (DB_NET).
BASELINE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# After integration the pin of the production db image comes from scripts/db-image.sh (the new image); this is the OLD image.
DEFAULT_DB_IMAGE='supabase/postgres:15.8.1.135@sha256:ee680a0afebe1a5e95614fdea671c01a264e58f52de6c429c17a394f46dec2c6'
DB_PASSWORD='disposable-test-database-only'

# psql inside a container, as the superuser the migrations run as.
db_psql() { local c="$1"; shift; docker exec -i -e PGPASSWORD="$DB_PASSWORD" "$c" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 "$@"; }

# The migration plan (scripts/migration-plan.mjs) of a directory that holds a migrations/ folder.
plan_of() {
  PLAN_MODULE="$BASELINE_ROOT/scripts/migration-plan.mjs" PLAN_ROOT="$1" \
    node -e "import(process.env.PLAN_MODULE).then(m => process.stdout.write(m.migrationPlan(process.env.PLAN_ROOT)))"
}

# The `-c` flags of the shipped database (docker/docker-compose.override.yml), as the migration harness uses them.
# With a bootstrap (postgres:17) pg_cron is not installed: it is taken out of shared_preload_libraries and cron.* is dropped.
shipped_flags() {
  local flag
  while IFS= read -r flag; do
    flag="${flag#-c }"
    if [[ -n "${DB_BOOTSTRAP:-}" ]]; then
      case "$flag" in
        cron.*) continue ;;
        shared_preload_libraries=*) flag='shared_preload_libraries=pg_stat_statements' ;;
      esac
    fi
    printf '%s\n' "$flag"
  done < <(
    sed -n 's/^ *\(-c \(shared_preload_libraries\|wal_level\|pg_stat_statements\.[a-z_]*\|cron\.[a-z_]*\)=.*\)$/\1/p' \
      "$BASELINE_ROOT/docker/docker-compose.override.yml")
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
    --tmpfs /var/lib/postgresql/data:rw,size=768m \
    -e JWT_SECRET=isolated-test-secret-not-for-any-deployment-12345 -e JWT_EXP=3600 \
    -e AUTH_MODE=operator -e APP_ENV=production \
    -e POSTGRES_PASSWORD="$DB_PASSWORD" "${extra[@]}" \
    "$image" "${command[@]}" "${flags[@]}" >/dev/null
  local i
  for ((i = 0; i < 60; i++)); do
    if docker exec "$name" pg_isready -U supabase_admin -d postgres -h 127.0.0.1 >/dev/null 2>&1; then
      # pg_isready answers during the image's own init; wait until the real superuser can log in and init is over.
      if docker exec -e PGPASSWORD="$DB_PASSWORD" "$name" psql -X -q -U supabase_admin -d postgres -Atc 'select 1' >/dev/null 2>&1; then return 0; fi
    fi
    sleep 2
  done
  echo "Database $name did not start" >&2
  docker rm -f -v "$name" >/dev/null 2>&1 || true
  return 1
}

new_name() { echo "slim-tool-$1-$(openssl rand -hex 4)"; }

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
  name=$(new_name storage)
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

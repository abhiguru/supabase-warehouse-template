#!/usr/bin/env bash
# Tests ONLY a newly created, network-isolated, disposable database. No host ports.
#
# The database is the shipped one: the official Postgres image of scripts/db-image.sh, started as production starts it
# (POSTGRES_USER=supabase_admin, en_US.UTF-8, the `-c` flags of docker/docker-compose.yml, the init scripts
# 00-bootstrap.sql and roles.sql). The order is setup.sh's: database, migrations (the baseline, run twice), then the real
# Storage 1.80.2 (the recipe image of docker/storage) on a throwaway --internal network (DB_SUPER_USER=supabase_storage_admin, DB_INSTALL_ROLES=false), then
# scripts/configure-storage.sql, then the SQL suites. No schema fixture stands in for Storage.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# new_name, create_net, run_storage and storage_image (throwaway containers named slim-tool-*, removed by their own code).
source "$ROOT/scripts/baseline/lib.sh"
suffix=$(openssl rand -hex 6)
container="warehouse-migrations-$suffix"
net=''
rest_container=''
created=false
chain_container="warehouse-migrations-chain-$suffix"
# Temporary directories of the test (make_temp_dir): removed here, so a failed run leaves none behind.
temp_dirs=()
make_temp_dir() { REPLY=$(mktemp -d "${TMPDIR:-/tmp}/warehouse-$1.XXXXXX"); temp_dirs+=("$REPLY"); }
cleanup() {
  if ((${#temp_dirs[@]})); then rm -rf "${temp_dirs[@]}"; fi
  if [[ "$created" == true ]]; then docker rm -fv "$container" "$chain_container" >/dev/null 2>&1 || true; fi
  remove_storage_containers
  if [[ -n "$rest_container" ]]; then docker rm -fv "$rest_container" >/dev/null 2>&1 || true; fi
  if [[ -n "$net" ]]; then docker network rm "$net" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT
# The library settings the shipped database runs with (docker/docker-compose.yml): the same `-c` flags are passed here,
# so the harness tests what ships.
shipped_flags=()
while IFS= read -r flag; do
  shipped_flags+=(-c "${flag#-c }")
done < <(
  sed -n 's/^ *\(-c \(shared_preload_libraries\|wal_level\|timezone\|log_timezone\|extra_float_digits\|pg_stat_statements\.[a-z_]*\)=.*\)$/\1/p' "$ROOT/docker/docker-compose.yml")
[[ " ${shipped_flags[*]} " == *shared_preload_libraries=pg_stat_statements\ * || " ${shipped_flags[*]} " == *shared_preload_libraries=pg_stat_statements ]] || { echo 'shared_preload_libraries is not exactly pg_stat_statements in docker-compose.yml' >&2; exit 1; }
[[ " ${shipped_flags[*]} " == *wal_level=replica* ]] || { echo 'No wal_level=replica in docker-compose.yml' >&2; exit 1; }
db_image="$(bash "$ROOT/scripts/db-image.sh")"
# Random service passwords for the init script roles.sql (it needs 32 to 128 distinct characters of [A-Za-z0-9_-]).
net=$(create_net)
# start_db_container <name> [--network <net>]: a disposable database as production starts it; returns when it accepts connections.
start_db_container() {
  local name="$1" network=()
  shift
  [[ $# -eq 0 ]] || network=("$@")
  docker run -d --name "$name" --label purpose=warehouse-migration-test \
    ${network[@]+"${network[@]}"} --memory 1g --cpus 1 \
    --tmpfs /var/lib/postgresql/data:rw,size=768m -e PGDATA=/var/lib/postgresql/data \
    -e JWT_SECRET=isolated-test-secret-not-for-any-deployment-12345 -e JWT_EXP=3600 \
    -e AUTH_MODE=operator -e APP_ENV=production \
    -e POSTGRES_USER=supabase_admin -e POSTGRES_DB=postgres -e POSTGRES_PASSWORD="$(openssl rand -hex 32)" \
    -e DB_PASSWORD_AUTHENTICATOR="$(openssl rand -hex 32)" -e DB_PASSWORD_STORAGE="$(openssl rand -hex 32)" \
    -e POSTGRES_INITDB_ARGS=--locale=en_US.UTF-8 \
    -v "$ROOT/docker/volumes/db/00-bootstrap.sql:/docker-entrypoint-initdb.d/00-bootstrap.sql:ro" \
    -v "$ROOT/docker/volumes/db/roles.sql:/docker-entrypoint-initdb.d/10-roles.sql:ro" \
    "$db_image" \
    postgres "${shipped_flags[@]}" >/dev/null
  local ready=false init_log i
  for ((i=0; i<60; i++)); do
    # The image's temporary server answers while the init scripts still run: wait for the end of init, then for the real server.
    init_log=$(docker logs "$name" 2>&1 || true)
    if [[ "$init_log" == *'PostgreSQL init process complete; ready for start up'* ]] \
      && docker exec "$name" pg_isready -U supabase_admin -d postgres -h 127.0.0.1 >/dev/null 2>&1; then ready=true; break; fi
    sleep 2
  done
  [[ "$ready" == true ]] || { echo 'Test database did not start' >&2; return 1; }
}
created=true
start_db_container "$container" --network "$net"
mig_psql() { docker exec -i -e PGPASSWORD=disposable-test-database-only "$container" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 "$@"; }
# The migration plan of a directory that holds a `migrations/` folder.
plan_of() { PLAN_MODULE="$ROOT/scripts/migration-plan.mjs" PLAN_ROOT="$1" node -e "import(process.env.PLAN_MODULE).then(m => process.stdout.write(m.migrationPlan(process.env.PLAN_ROOT)))"; }

# The ledger, run twice: the first pass applies the baseline, the second must skip it.
first=$(plan_of "$ROOT" | mig_psql 2>&1) || { echo "$first" | tail -20 >&2; echo 'The first ledger pass failed.' >&2; exit 1; }
[[ "$first" == *'Applying: 00000000000000_baseline.sql'* ]] || { echo "The first ledger pass did not apply the baseline: $first" >&2; exit 1; }
second=$(plan_of "$ROOT" | mig_psql 2>&1) || { echo "$second" | tail -20 >&2; echo 'The second ledger pass failed.' >&2; exit 1; }
[[ "$second" == *'Already applied: 00000000000000_baseline.sql'* && "$second" != *'Applying:'* ]] || { echo "The second ledger pass must skip the baseline: $second" >&2; exit 1; }
# The ledger holds exactly the files of migrations/ (the baseline today, more once a migration follows it).
[[ "$(mig_psql -At -c 'SELECT string_agg(name, $$,$$ ORDER BY name) FROM warehouse_migrations.applied')" == "$(cd "$ROOT/migrations" && ls -1 *.sql | LC_ALL=C sort | paste -sd,)" ]] || { echo 'The ledger does not hold exactly the migration files.' >&2; exit 1; }
migration_count=$(ls -1 "$ROOT"/migrations/*.sql | wc -l)

# Definition files (migrations/definitions/, scripts/migration-plan.mjs): applied after the numbered files, each once per checksum.
definition_count=$(ls -1 "$ROOT"/migrations/definitions/*.sql | wc -l)
[[ "$(grep -c '^Applying definition: ' <<< "$first")" == "$definition_count" && "$first" == *'Applying definition: 00_authorize_rpc.sql'* ]] || { echo "The first pass did not apply each of the $definition_count definition files: $first" >&2; exit 1; }
[[ "$second" == *'Definition unchanged: 00_authorize_rpc.sql'* && "$second" != *'Applying definition:'* ]] || { echo "The second pass must skip every definition: $second" >&2; exit 1; }
definition_rows() { mig_psql -At -c 'SELECT string_agg(name || $$:$$ || checksum, $$,$$ ORDER BY name COLLATE "C") FROM warehouse_migrations.definitions'; }
definition_sums() { (cd "$1/migrations/definitions" && for f in *.sql; do printf '%s:%s\n' "$f" "$(sha256sum "$f" | cut -d' ' -f1)"; done | LC_ALL=C sort | paste -sd,); }
[[ "$(definition_rows)" == "$(definition_sums "$ROOT")" ]] || { echo 'The definitions table does not hold exactly the files and their checksums.' >&2; exit 1; }
# notifications_during <seconds> <command...>: how many "reload schema" notifications a listener session received while the command ran.
notifications_during() {
  local seconds="$1" out
  shift
  out=$(mktemp "${TMPDIR:-/tmp}/warehouse-listen.XXXXXX")
  printf 'LISTEN pgrst;\nSELECT pg_sleep(%s);\nSELECT 1;\n' "$seconds" | mig_psql -At > "$out" 2>&1 &
  local listener=$!
  for ((i=0; i<50; i++)); do
    [[ "$(mig_psql -At -c "SELECT count(*) FROM pg_stat_activity WHERE query LIKE 'SELECT pg_sleep($seconds)%' AND pid <> pg_backend_pid()")" == 1 ]] && break
    sleep 0.2
  done
  "$@" >/dev/null
  wait "$listener"
  grep -c 'Asynchronous notification "pgrst" with payload "reload schema"' "$out" || true
  rm -f "$out"
}
# Equivalence: the numbered files alone build one database, the numbered files plus the definitions another, and the catalogs (functions,
# bodies, owners, grants, search paths) are the same, except what tests/definitions-allowed-differences.txt names (the table that
# records the definitions, and later any definition changed on purpose). Then the facility that already ran the numbered files gets
# the definitions on its next setup and ends up with the same catalog too.
make_temp_dir chain; chainroot=$REPLY
mkdir "$chainroot/migrations"
cp "$ROOT"/migrations/*.sql "$chainroot/migrations/"
start_db_container "$chain_container" --network none
chain_psql() { docker exec -i -e PGPASSWORD=disposable-test-database-only "$chain_container" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 "$@"; }
chain_first=$(plan_of "$chainroot" | chain_psql 2>&1) || { echo "$chain_first" | tail -20 >&2; echo 'The numbered files alone did not apply.' >&2; exit 1; }
[[ "$chain_first" != *'definition'* && "$(chain_psql -At -c "SELECT to_regclass('warehouse_migrations.definitions') IS NULL")" == t ]] || { echo 'A directory without definitions built a definitions table.' >&2; exit 1; }
# The catalog dump compares grants as a set; the order of a function's ACL array is part of what some suites compare (tests/grn_rates.sql), so
# the identity, ACL text, settings, owner and body of every function are compared as they are stored, too, one line per function.
function_lines() { "$1" -At -c "SELECT n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')|' || md5(coalesce(p.proacl::text, '') || coalesce(p.proconfig::text, '') || p.prosecdef || pg_get_userbyid(p.proowner) || md5(p.prosrc)) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname IN ('public', 'warehouse_security') ORDER BY 1"; }
# schema.name of the functions an allow-list names (its ^function\| and ^acl\|function\| entries; every overload of the name).
allowed_functions() { sed -n -E 's/^[AB] \^(function|acl\\\|function)\\\|([a-z_0-9]+)\\\.([a-z_0-9]+)\\\(.*/\2.\3/p' "$1" | sort -u; }
# changed_functions <psql A> <psql B> <allow-list>: the functions whose stored text differs, without those the allow-list names.
changed_functions() {
  local skip
  skip=$(allowed_functions "$3")
  { diff <(function_lines "$1") <(function_lines "$2") || true; } | sed -n 's/^[<>] //p' \
    | awk -F'|' -v skip="$skip" 'BEGIN { n = split(skip, a, "\n"); for (i = 1; i <= n; i++) skip_name[a[i]] = 1 } { name = $1; sub(/\(.*/, "", name); if (!(name in skip_name)) print $1 }' | sort -u
}
# same_catalogs <container A> <psql A> <container B> <psql B> <allow-list>: 0 when the catalog (scripts/baseline/catalog-diff.mjs) and every function
# are the same, except what the allow-list names; otherwise the differences go to standard error.
same_catalogs() {
  local report changed
  if ! report=$(node "$ROOT/scripts/baseline/catalog-diff.mjs" "$1" "$3" --image pg17 --allow "$5" 2>&1); then echo "$report" | tail -n 40 >&2; return 1; fi
  changed=$(changed_functions "$2" "$4" "$5")
  if [[ -n "$changed" ]]; then printf 'A function differs (ACL order, settings, owner or body):\n%s\n' "$changed" >&2; return 1; fi
}
same_catalogs "$chain_container" chain_psql "$container" mig_psql "$ROOT/tests/definitions-allowed-differences.txt" || { echo 'The definitions change the catalog the numbered files build.' >&2; exit 1; }
upgrade_pass=$(plan_of "$ROOT" | chain_psql 2>&1) || { echo "$upgrade_pass" | tail -20 >&2; echo 'The definitions did not apply to a database that had the numbered files.' >&2; exit 1; }
[[ "$(grep -c '^Applying definition: ' <<< "$upgrade_pass")" == "$definition_count" && "$upgrade_pass" != *'Applying: '* ]] || { echo "The upgrade pass did not apply exactly the definitions: $upgrade_pass" >&2; exit 1; }
[[ "$(definition_rows)" == "$(chain_psql -At -c 'SELECT string_agg(name || $$:$$ || checksum, $$,$$ ORDER BY name COLLATE "C") FROM warehouse_migrations.definitions')" ]] || { echo 'The upgraded database recorded other definitions.' >&2; exit 1; }
printf '# no differences expected\n' > "$chainroot/none.txt"
same_catalogs "$chain_container" chain_psql "$container" mig_psql "$chainroot/none.txt" || { echo 'A facility that ran the numbered files differs from a new one after the definitions.' >&2; exit 1; }

# The documented way to fix a function (CONTRIBUTING.md): change its definition file and add its lines to tests/definitions-allowed-differences.txt.
# Walked here on the facility database, with save_grn.sql changed in its body and get_invoice_detail.sql given a grant. Without the lines the
# comparison refuses; the lines of one function let that function pass and the other is still named; with both it passes.
make_temp_dir fixroot; fixroot=$REPLY
mkdir "$fixroot/migrations"
cp -r "$ROOT/migrations/." "$fixroot/migrations/"
sed -i 's/^\( *\)\$function\$;$/\1-- definition fix\n\1$function$;/' "$fixroot/migrations/definitions/save_grn.sql"
printf 'GRANT EXECUTE ON FUNCTION public.get_invoice_detail(uuid) TO anon;\n' >> "$fixroot/migrations/definitions/get_invoice_detail.sql"
[[ "$(grep -c 'definition fix' "$fixroot/migrations/definitions/save_grn.sql")" == 1 ]] || { echo 'The test could not change save_grn.sql.' >&2; exit 1; }
plan_of "$fixroot" | chain_psql >/dev/null 2>&1 || { echo 'The fixed definitions did not apply.' >&2; exit 1; }
# Both databases here have the definitions table, so the entry for it is left out of the lists (an entry that matches nothing fails the run).
allow_real="$fixroot/allow-none.txt"
grep -v 'warehouse_migrations' "$ROOT/tests/definitions-allowed-differences.txt" > "$allow_real"
{ cat "$allow_real"; printf '%s\n' 'A ^function\|public\.save_grn\(' 'B ^function\|public\.save_grn\('; } > "$fixroot/allow-body.txt"
{ cat "$allow_real"; printf '%s\n' 'B ^acl\|function\|public\.get_invoice_detail\('; } > "$fixroot/allow-grant.txt"
{ cat "$allow_real"; printf '%s\n' 'A ^function\|public\.save_grn\(' 'B ^function\|public\.save_grn\(' 'B ^acl\|function\|public\.get_invoice_detail\('; } > "$fixroot/allow-both.txt"
if same_catalogs "$container" mig_psql "$chain_container" chain_psql "$allow_real" 2>/dev/null; then echo 'A fixed definition passed the comparison without its allow-list lines.' >&2; exit 1; fi
if same_catalogs "$container" mig_psql "$chain_container" chain_psql "$fixroot/allow-body.txt" 2>"$fixroot/err-body.txt"; then echo 'A grant added to a definition passed the comparison with the lines of another function.' >&2; exit 1; fi
if same_catalogs "$container" mig_psql "$chain_container" chain_psql "$fixroot/allow-grant.txt" 2>"$fixroot/err-grant.txt"; then echo 'A body fixed in a definition passed the comparison with the lines of another function.' >&2; exit 1; fi
only_body=$(changed_functions mig_psql chain_psql "$fixroot/allow-body.txt")
only_grant=$(changed_functions mig_psql chain_psql "$fixroot/allow-grant.txt")
all_changed=$(changed_functions mig_psql chain_psql "$allow_real")
[[ "$only_body" == public.get_invoice_detail\(*  && "$only_grant" == public.save_grn\(* && "$(wc -l <<< "$all_changed")" == 2 && -z "$(changed_functions mig_psql chain_psql "$fixroot/allow-both.txt")" ]] \
  || { printf 'The function comparison did not leave out exactly the functions the allow-list names.\nwith the lines of save_grn: %s\nwith the lines of the get_invoice_detail grant: %s\nwith none: %s\n' "$only_body" "$only_grant" "$all_changed" >&2; exit 1; }
same_catalogs "$container" mig_psql "$chain_container" chain_psql "$fixroot/allow-both.txt" || { echo 'A fixed definition with its allow-list lines (body and grant) did not pass the comparison.' >&2; exit 1; }
# Put back: the shipped files differ from the stored checksums, so they are applied again, and the facility equals a new install again.
plan_of "$ROOT" | chain_psql >/dev/null 2>&1 || { echo 'The shipped definitions did not apply again.' >&2; exit 1; }
same_catalogs "$chain_container" chain_psql "$container" mig_psql "$chainroot/none.txt" || { echo 'The facility differs from a new install after the fix was put back.' >&2; exit 1; }

# A numbered migration that carries the facility forward is followed by every definition, not only the changed ones: a migration that altered
# a function with a definition file leaves the file's text in the end (a new install gets the file after the numbered files too). The
# fixture migration gives get_invoice_detail a setting; a second run, with no migration, skips every file.
make_temp_dir reapply; reapply=$REPLY
mkdir "$reapply/migrations"
cp -r "$ROOT/migrations/." "$reapply/migrations/"
printf "ALTER FUNCTION public.get_invoice_detail(uuid) SET statement_timeout = '1s';\n" > "$reapply/migrations/00000000000999_definitions_reapply.sql"
settings_before=$(chain_psql -At -c "SELECT coalesce(proconfig::text, '') FROM pg_proc WHERE oid = 'public.get_invoice_detail(uuid)'::regprocedure")
reapply_pass=$(plan_of "$reapply" | chain_psql 2>&1) || { echo "$reapply_pass" | tail -20 >&2; echo 'The plan with a further migration failed.' >&2; exit 1; }
[[ "$reapply_pass" == *'Applying: 00000000000999_definitions_reapply.sql'* && "$(grep -c '^Applying definition: ' <<< "$reapply_pass")" == "$definition_count" && "$reapply_pass" != *'Definition unchanged'* ]] \
  || { echo "A run that applied a migration must apply every definition again: $reapply_pass" >&2; exit 1; }
[[ "$(chain_psql -At -c "SELECT coalesce(proconfig::text, '') FROM pg_proc WHERE oid = 'public.get_invoice_detail(uuid)'::regprocedure")" == "$settings_before" ]] || { echo 'A migration that altered a function with a definition file was not overridden by the file.' >&2; exit 1; }
reapply_second=$(plan_of "$reapply" | chain_psql 2>&1)
[[ "$reapply_second" != *'Applying definition:'* && "$(grep -c '^Definition unchanged: ' <<< "$reapply_second")" == "$definition_count" ]] || { echo "Nothing applied, yet definitions were applied again: $reapply_second" >&2; exit 1; }
chain_psql -c "DELETE FROM warehouse_migrations.applied WHERE name = '00000000000999_definitions_reapply.sql'"

# The row of a definition file that was removed goes, so the file added again is applied.
make_temp_dir removed; removed=$REPLY
mkdir "$removed/migrations"
cp -r "$ROOT/migrations/." "$removed/migrations/"
rm "$removed/migrations/definitions/get_sensor_polling_data.sql"
plan_of "$removed" | chain_psql >/dev/null 2>&1 || { echo 'The plan without one definition file failed.' >&2; exit 1; }
[[ "$(chain_psql -At -c "SELECT count(*) FROM warehouse_migrations.definitions WHERE name = 'get_sensor_polling_data.sql'")" == 0 \
  && "$(chain_psql -At -c 'SELECT count(*) FROM warehouse_migrations.definitions')" == $((definition_count - 1)) ]] || { echo 'The row of a removed definition file stayed.' >&2; exit 1; }
readd_pass=$(plan_of "$ROOT" | chain_psql 2>&1)
[[ "$readd_pass" == *'Applying definition: get_sensor_polling_data.sql'* && "$(grep -c '^Applying definition: ' <<< "$readd_pass")" == 1 && "$(definition_rows)" == "$(chain_psql -At -c 'SELECT string_agg(name || $$:$$ || checksum, $$,$$ ORDER BY name COLLATE "C") FROM warehouse_migrations.definitions')" ]] \
  || { echo "A definition file added again was not applied: $readd_pass" >&2; exit 1; }

# A definition only replaces the function a numbered migration created. A file whose function has another argument list would add a second
# function: that file is rolled back whole. A migration that drops the function the file replaces stops the plan at that file, naming it, and the
# function is not brought back.
make_temp_dir overload; overload=$REPLY
mkdir "$overload/migrations"
cp -r "$ROOT/migrations/." "$overload/migrations/"
sed -i 's/^CREATE OR REPLACE FUNCTION public.get_invoice_detail(p_invoice_id uuid)$/CREATE OR REPLACE FUNCTION public.get_invoice_detail(p_invoice_id uuid, p_extra integer DEFAULT NULL)/' "$overload/migrations/definitions/get_invoice_detail.sql"
[[ "$(grep -c 'p_extra integer' "$overload/migrations/definitions/get_invoice_detail.sql")" == 1 ]] || { echo 'The test could not change get_invoice_detail.sql.' >&2; exit 1; }
if overload_out=$(plan_of "$overload" | chain_psql 2>&1); then echo 'A definition that would add an overload was applied.' >&2; exit 1; fi
[[ "$overload_out" == *'migrations/definitions/get_invoice_detail.sql: the file would add another public.get_invoice_detail'* \
  && "$(chain_psql -At -c "SELECT count(*) FROM pg_proc WHERE proname = 'get_invoice_detail'")" == 1 \
  && "$(chain_psql -At -c "SELECT checksum FROM warehouse_migrations.definitions WHERE name = 'get_invoice_detail.sql'")" == "$(sha256sum "$ROOT/migrations/definitions/get_invoice_detail.sql" | cut -d' ' -f1)" ]] \
  || { echo "A definition with another argument list was not refused and rolled back: $overload_out" >&2; exit 1; }
make_temp_dir dropped; dropped=$REPLY
mkdir "$dropped/migrations"
cp -r "$ROOT/migrations/." "$dropped/migrations/"
printf 'DROP FUNCTION public.get_invoice_detail(uuid);\n' > "$dropped/migrations/00000000000999_drop_get_invoice_detail.sql"
if dropped_out=$(plan_of "$dropped" | chain_psql 2>&1); then echo 'A definition of a dropped function was applied.' >&2; exit 1; fi
[[ "$dropped_out" == *'migrations/definitions/get_invoice_detail.sql: public.get_invoice_detail(uuid) does not exist'* && "$dropped_out" == *'Checking definition: get_invoice_detail.sql'* \
  && "$dropped_out" != *'Applying definition: get_invoice_detail.sql'* \
  && "$(chain_psql -At -c "SELECT to_regprocedure('public.get_invoice_detail(uuid)') IS NULL")" == t ]] \
  || { echo "A definition of a dropped function was not refused by name, or brought the function back: $dropped_out" >&2; exit 1; }
docker rm -fv "$chain_container" >/dev/null
# A changed definition is applied again (its checksum row follows, and the API is told to reload); the others are skipped; putting the file
# back applies it again. A file with a statement that is not a function statement is refused before anything reaches the database.
make_temp_dir defroot; defroot=$REPLY
mkdir -p "$defroot/migrations"
cp -r "$ROOT/migrations/." "$defroot/migrations/"
sed -i 's/^\( *\)\$function\$;$/\1-- definition probe\n\1$function$;/' "$defroot/migrations/definitions/save_grn.sql"
[[ "$(grep -c 'definition probe' "$defroot/migrations/definitions/save_grn.sql")" == 1 ]] || { echo 'The test could not change save_grn.sql.' >&2; exit 1; }
before_save=$(mig_psql -At -c "SELECT checksum FROM warehouse_migrations.definitions WHERE name = 'save_grn.sql'")
changed_out=$(mktemp "${TMPDIR:-/tmp}/warehouse-changed-out.XXXXXX")
notified=$(notifications_during 8 bash -c 'PLAN_ROOT="$1" PLAN_MODULE="$2" node -e "import(process.env.PLAN_MODULE).then(m => process.stdout.write(m.migrationPlan(process.env.PLAN_ROOT)))" | docker exec -i -e PGPASSWORD=disposable-test-database-only "$3" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 > "$4" 2>&1' _ "$defroot" "$ROOT/scripts/migration-plan.mjs" "$container" "$changed_out")
changed_pass=$(cat "$changed_out"); rm -f "$changed_out"
[[ "$(grep -c '^Applying definition: ' <<< "$changed_pass")" == 1 && "$changed_pass" == *'Applying definition: save_grn.sql'* && "$changed_pass" != *'Applying: '* \
  && "$(grep -c '^Definition unchanged: ' <<< "$changed_pass")" == $((definition_count - 1)) ]] || { echo "A changed definition must be applied alone: $changed_pass" >&2; exit 1; }
[[ "$(mig_psql -At -c "SELECT checksum FROM warehouse_migrations.definitions WHERE name = 'save_grn.sql'")" == "$(sha256sum "$defroot/migrations/definitions/save_grn.sql" | cut -d' ' -f1)" \
  && "$before_save" != "$(sha256sum "$defroot/migrations/definitions/save_grn.sql" | cut -d' ' -f1)" ]] || { echo 'The checksum row did not follow the changed definition.' >&2; exit 1; }
[[ "$(mig_psql -At -c "SELECT count(*) FROM pg_proc WHERE proname = 'save_grn' AND prosrc LIKE '%definition probe%'")" == 1 ]] || { echo 'The changed definition did not change the function.' >&2; exit 1; }
[[ "$notified" == 2 ]] || { echo "A changed definition must tell the API to reload right after its COMMIT, besides the reload at the end of the plan (notifications seen: $notified)." >&2; exit 1; }
unchanged_notified=$(notifications_during 8 bash -c 'PLAN_ROOT="$1" PLAN_MODULE="$2" node -e "import(process.env.PLAN_MODULE).then(m => process.stdout.write(m.migrationPlan(process.env.PLAN_ROOT)))" | docker exec -i -e PGPASSWORD=disposable-test-database-only "$3" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 >/dev/null 2>&1' _ "$defroot" "$ROOT/scripts/migration-plan.mjs" "$container")
[[ "$unchanged_notified" == 1 ]] || { echo "A plan with nothing to apply must send only the reload at its end (notifications seen: $unchanged_notified)." >&2; exit 1; }
back_pass=$(plan_of "$ROOT" | mig_psql 2>&1) || { echo "$back_pass" | tail -20 >&2; echo 'The shipped definition did not apply after the changed one.' >&2; exit 1; }
[[ "$back_pass" == *'Applying definition: save_grn.sql'* && "$(mig_psql -At -c "SELECT count(*) FROM pg_proc WHERE prosrc LIKE '%definition probe%'")" == 0 && "$(definition_rows)" == "$(definition_sums "$ROOT")" ]] || { echo 'Putting the definition back did not restore the function and its row.' >&2; exit 1; }
printf 'CREATE TABLE public.definition_guard_probe (id int);\n' > "$defroot/migrations/definitions/zz_table.sql"
cp "$ROOT/migrations/definitions/save_grn.sql" "$defroot/migrations/definitions/save_grn.sql"
rows_before=$(definition_rows)
if refused=$( { plan_of "$defroot" | mig_psql; } 2>&1 ); then echo 'A definition file with CREATE TABLE was accepted.' >&2; exit 1; fi
[[ "$refused" == *'migrations/definitions/zz_table.sql holds more than function definitions'* ]] || { echo "The refusal of a definition with CREATE TABLE is not the expected one: $refused" >&2; exit 1; }
[[ "$(mig_psql -At -c "SELECT to_regclass('public.definition_guard_probe') IS NULL")" == t && "$(definition_rows)" == "$rows_before" ]] || { echo 'The refused definition changed the database.' >&2; exit 1; }
rm -rf "$defroot" "$chainroot"
echo "The definitions ($definition_count files) build the catalog of the numbered files, a changed one is applied alone and announced to the API, and a file with a table statement is refused first."

# A changed baseline must fail closed: a space appended to a temporary copy.
make_temp_dir changed; changed=$REPLY
mkdir "$changed/migrations"
cp "$ROOT"/migrations/*.sql "$changed/migrations/"
printf ' ' >> "$changed/migrations/00000000000000_baseline.sql"
if err=$(plan_of "$changed" | mig_psql 2>&1 >/dev/null); then echo 'A changed baseline was accepted.' >&2; exit 1; fi
[[ "$err" == *'Applied migration changed: 00000000000000_baseline.sql'* ]] || { echo "A changed baseline was refused, but not with the checksum message: $err" >&2; exit 1; }
rm -rf "$changed"

# A database that recorded a migration this release does not contain (the old chain, or a deleted file) is refused, with the
# pointer to the reload section, and nothing is changed.
mig_psql -c "INSERT INTO warehouse_migrations.applied(name, checksum) VALUES ('00000000000107_gone.sql', 'x')"
if err=$(plan_of "$ROOT" | mig_psql 2>&1 >/dev/null); then echo 'A ledger with an unknown migration was accepted.' >&2; exit 1; fi
[[ "$err" == *'recorded migrations that are not in this release (00000000000107_gone.sql)'* && "$err" == *'docs/OPERATOR_INSTALL.md, "Baseline reload"'* && "$err" == *'newer than this checkout'* ]] || { echo "The unknown-migration refusal is not the expected one: $err" >&2; exit 1; }
mig_psql -c "DELETE FROM warehouse_migrations.applied WHERE name = '00000000000107_gone.sql'"
plan_of "$ROOT" | mig_psql >/dev/null

# The refusal happens before any file runs: a checkout that holds the baseline and a further migration, against a ledger with
# an unknown name, creates nothing from that further migration.
make_temp_dir probe; probe=$REPLY
mkdir "$probe/migrations"
cp "$ROOT"/migrations/*.sql "$probe/migrations/"
printf 'CREATE TABLE public.ledger_guard_probe (id int);\n' > "$probe/migrations/00000000000999_probe.sql"
mig_psql -c "INSERT INTO warehouse_migrations.applied(name, checksum) VALUES ('00000000000107_gone.sql', 'x')"
if plan_of "$probe" | mig_psql >/dev/null 2>&1; then echo 'A ledger with an unknown migration was accepted next to a new migration.' >&2; exit 1; fi
[[ "$(mig_psql -At -c "SELECT to_regclass('public.ledger_guard_probe') IS NULL")" == t ]] || { echo 'The refusal ran a migration file before it stopped.' >&2; exit 1; }
mig_psql -c "DELETE FROM warehouse_migrations.applied WHERE name = '00000000000107_gone.sql'"
rm -rf "$probe"

# A database with application tables and an empty ledger (untracked) is refused too, and the ledger stays empty.
mig_psql -c "CREATE TABLE warehouse_migrations.applied_saved AS SELECT * FROM warehouse_migrations.applied; DELETE FROM warehouse_migrations.applied;"
if err=$(plan_of "$ROOT" | mig_psql 2>&1 >/dev/null); then echo 'An untracked database was accepted.' >&2; exit 1; fi
[[ "$err" == *'Refusing to initialize an existing, untracked warehouse database'* ]] || { echo "The untracked-database refusal is not the expected one: $err" >&2; exit 1; }
[[ "$(mig_psql -At -c 'SELECT count(*) FROM warehouse_migrations.applied')" == 0 ]] || { echo 'The untracked-database refusal wrote to the ledger.' >&2; exit 1; }
mig_psql -c "INSERT INTO warehouse_migrations.applied SELECT * FROM warehouse_migrations.applied_saved; DROP TABLE warehouse_migrations.applied_saved;"

# Lock timeout and retry (scripts/migration-plan.mjs, scripts/migrate.sh). A fixture migration that changes public.dispatch is applied
# while a second session holds ACCESS EXCLUSIVE on that table:
#  - the plan fails after about 10 s (the lock_timeout each file runs under) with the lock timeout error (55P03), the file rolls back
#    whole (no ledger row, no column), and no migration waits for ever;
#  - scripts/migrate.sh, which runs the same plan, tries again after a pause and succeeds once the lock is released.
# The ledger and the table are put back afterwards.
make_temp_dir lockprobe; lockprobe=$REPLY
mkdir "$lockprobe/migrations" "$lockprobe/state" "$lockprobe/state/config" "$lockprobe/scripts"
cp "$ROOT"/migrations/*.sql "$lockprobe/migrations/"
printf 'ALTER TABLE public.dispatch ADD COLUMN lock_probe integer;\n' > "$lockprobe/migrations/00000000000999_lock_probe.sql"
hold_dispatch() {
  # Holds the lock for $1 seconds in a background session; returns when the lock is granted.
  mig_psql -c "BEGIN; LOCK TABLE public.dispatch IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep($1); COMMIT;" >/dev/null 2>&1 &
  lock_holder=$!
  for ((i=0; i<50; i++)); do
    [[ "$(mig_psql -At -c "SELECT count(*) FROM pg_locks WHERE relation = 'public.dispatch'::regclass AND mode = 'AccessExclusiveLock' AND granted")" == 1 ]] && return 0
    sleep 0.2
  done
  echo 'The session that should hold the lock on public.dispatch never got it.' >&2; exit 1
}
release_dispatch() {
  mig_psql -At -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE query LIKE 'BEGIN; LOCK TABLE public.dispatch%' AND pid <> pg_backend_pid()" >/dev/null
  wait "$lock_holder" 2>/dev/null || true
}
hold_dispatch 60
waited_from=$SECONDS
if err=$(plan_of "$lockprobe" | mig_psql 2>&1 >/dev/null); then echo 'A migration that needs a locked table was applied.' >&2; exit 1; fi
waited=$((SECONDS - waited_from))
release_dispatch
[[ "$err" == *'canceling statement due to lock timeout'* ]] || { echo "A migration blocked by a lock failed, but not with the lock timeout: $err" >&2; exit 1; }
((waited >= 9 && waited <= 25)) || { echo "A migration blocked by a lock failed after $waited s, not after about 10 s." >&2; exit 1; }
[[ "$(mig_psql -At -c "SELECT (SELECT count(*) FROM warehouse_migrations.applied WHERE name = '00000000000999_lock_probe.sql') || ',' || (SELECT count(*) FROM information_schema.columns WHERE table_name = 'dispatch' AND column_name = 'lock_probe')")" == 0,0 ]] \
  || { echo 'A migration that timed out on a lock left a ledger row or its change behind.' >&2; exit 1; }
echo "A migration blocked by a lock failed after $waited s with the lock timeout and rolled back whole."
# migrate.sh with the same plan: a shim stands in for compose.sh and sends psql to this container.
cp "$ROOT/scripts/migrate.sh" "$ROOT/scripts/migration-plan.mjs" "$ROOT/scripts/is-main.mjs" "$ROOT/scripts/operator-lock.sh" "$lockprobe/scripts/"
cat > "$lockprobe/scripts/compose.sh" <<SHIM
#!/usr/bin/env bash
[[ "\$1 \$2 \$3 \$4" == "exec -T db psql" ]] || exit 1
shift 4
exec docker exec -i -e PGPASSWORD=disposable-test-database-only "$container" psql "\$@"
SHIM
hold_dispatch 12
retried=$(WAREHOUSE_STATE_DIR="$lockprobe/state" WAREHOUSE_MIGRATE_RETRY_SECONDS=2 bash "$lockprobe/scripts/migrate.sh" --operator 2>&1) \
  || { echo "migrate.sh did not succeed once the lock was released: $retried" >&2; exit 1; }
release_dispatch
[[ "$retried" == *'canceling statement due to lock timeout'* && "$retried" == *'attempt 1 of 3'* ]] || { echo "migrate.sh did not report the first attempt's lock timeout and the retry: $retried" >&2; exit 1; }
[[ "$(mig_psql -At -c "SELECT (SELECT count(*) FROM warehouse_migrations.applied WHERE name = '00000000000999_lock_probe.sql') || ',' || (SELECT count(*) FROM information_schema.columns WHERE table_name = 'dispatch' AND column_name = 'lock_probe')")" == 1,1 ]] \
  || { echo 'migrate.sh did not apply the migration on its second attempt.' >&2; exit 1; }
echo 'migrate.sh tried again after the lock timeout and applied the migration.'
mig_psql -c "ALTER TABLE public.dispatch DROP COLUMN lock_probe; DELETE FROM warehouse_migrations.applied WHERE name = '00000000000999_lock_probe.sql'"
rm -rf "$lockprobe"

# Storage, as setup.sh does after the migrations: the real Storage 1.80.2 builds its own tables in the schema the bootstrap made.
# The image that ships (docker/storage, a multi-stage recipe on a clean Node image), built here from the same Dockerfile, not
# the publisher's image: a native module or file the slimmed image lacks would fail Storage's start. Layers are cached.
# The image ID, not a fixed tag: two harness runs on one host (two checkouts, two CI jobs) cannot overwrite each other's image.
storage_recipe=$(docker build -q "$ROOT/docker/storage")
run_storage "$container" "$net" "$storage_recipe" >/dev/null
[[ "$(mig_psql -At -c 'SELECT count(*) > 0 FROM storage.migrations')" == t && "$(mig_psql -At -c "SELECT count(*) FROM pg_tables WHERE schemaname = 'storage' AND tablename IN ('buckets', 'objects')")" == 2 ]] || { echo 'Storage did not build its tables.' >&2; exit 1; }
# The Storage schema version this checkout declares (docker/storage/migrations-head.txt; docker-compose.yml freezes the migrator at its name)
# is the newest migration the image ships and the one it applied to this catalog.
head_id=$(sed -n 's/^id=//p' "$ROOT/docker/storage/migrations-head.txt")
head_name=$(sed -n 's/^name=//p' "$ROOT/docker/storage/migrations-head.txt")
[[ "$head_id" =~ ^[0-9]+$ && -n "$head_name" ]] || { echo 'docker/storage/migrations-head.txt has no id= and name=.' >&2; exit 1; }
image_newest=$(docker run --rm --entrypoint sh "$storage_recipe" -c 'ls /app/migrations/tenant' | sed -En 's/^0*([0-9]+)-(.*)\.sql$/\1 \2/p' | sort -n | tail -n 1)
[[ "$image_newest" == "$head_id $head_name" ]] || { echo "The newest migration file of the Storage image is '$image_newest'; docker/storage/migrations-head.txt says '$head_id $head_name'." >&2; exit 1; }
[[ "$(mig_psql -At -c 'SELECT max(id) || '"' '"' || (SELECT name FROM storage.migrations ORDER BY id DESC LIMIT 1) FROM storage.migrations')" == "$head_id $head_name" ]] || { echo "Storage applied migrations up to something other than '$head_id $head_name' (docker/storage/migrations-head.txt)." >&2; exit 1; }
# The baseline did not need Storage, and Storage did not need the baseline's help: the three API roles can use the schema.
[[ "$(mig_psql -At -c "SELECT bool_and(has_schema_privilege(r, 'storage', 'USAGE')) FROM unnest(ARRAY['anon','authenticated','service_role']) r")" == t ]] || { echo 'An API role cannot use the storage schema.' >&2; exit 1; }
# An installed facility already has the storage policies (scripts/configure-storage.sql) when the next release's migrations run; setup.sh
# on a new install migrates first. So the NEWEST migration is also applied here the way an upgrade applies it: a second database gets
# the migrations up to the one before it, the Storage tables (the schema just built by the real Storage, without data), the policies,
# and only then the newest file. A migration that changes a column the policies read fails it (a plain DROP COLUMN is refused by the
# database), and tests/storage_policy_deps.sql, run on that database too, fails when one is dropped with CASCADE.
newest=$(cd "$ROOT/migrations" && ls -1 *.sql | LC_ALL=C sort | tail -n 1)
previous=$(cd "$ROOT/migrations" && ls -1 *.sql | LC_ALL=C sort | tail -n 2 | head -n 1)
[[ "$newest" != "$previous" ]] || { echo 'The storage-policy upgrade step needs at least two migration files.' >&2; exit 1; }
plan_through() { PLAN_MODULE="$ROOT/scripts/migration-plan.mjs" PLAN_ROOT="$ROOT" PLAN_THROUGH="$1" node -e "import(process.env.PLAN_MODULE).then(m => process.stdout.write(m.migrationPlan(process.env.PLAN_ROOT, { through: process.env.PLAN_THROUGH })))"; }
# A second database of this container: the bootstrap's schemas, the migrations up to $2, and the empty Storage tables of the main database.
make_probe() {
  mig_psql -c "CREATE DATABASE $1 TEMPLATE template0" >/dev/null
  sed -n '/^-- Schemas the migrations and Storage expect to exist\./,$p' "$ROOT/docker/volumes/db/00-bootstrap.sql" | mig_psql -d "$1" >/dev/null
  plan_through "$2" | mig_psql -d "$1" >/dev/null
  mig_psql -d "$1" -c 'DROP SCHEMA storage CASCADE' >/dev/null
  docker exec -e PGPASSWORD=disposable-test-database-only "$container" pg_dump -U supabase_admin -d postgres --schema-only --no-owner -n storage | mig_psql -d "$1" >/dev/null
}
make_probe policy_probe "$previous"
probe_psql() { mig_psql -d policy_probe "$@"; }
probe_psql < "$ROOT/scripts/configure-storage.sql" >/dev/null
probe_psql -At -c "SELECT count(*) FROM pg_policy WHERE polrelid = 'storage.objects'::regclass" | grep -qv '^0$' || { echo 'The probe database has no storage policy.' >&2; exit 1; }
if ! applied_newest=$(plan_of "$ROOT" | probe_psql 2>&1); then echo "$applied_newest" | tail -n 20 >&2; echo "The newest migration ($newest) does not apply to a database that already has the storage policies." >&2; exit 1; fi
[[ "$applied_newest" == *"Applying: $newest"* && "$applied_newest" != *"Applying: $previous"* ]] || { echo "The probe database did not apply exactly the newest migration: $applied_newest" >&2; exit 1; }
probe_psql < "$ROOT/tests/storage_policy_deps.sql"
# A migration that drops a column a policy reads: refused as it is; with CASCADE the policy goes, and the dependency test names the column.
if err=$(printf 'ALTER TABLE public.goodsreceived DROP COLUMN gr_image_url;\n' | probe_psql 2>&1 >/dev/null); then echo 'A column read by a storage policy was dropped without CASCADE.' >&2; exit 1; fi
[[ "$err" == *'cannot drop column gr_image_url of table goodsreceived because other objects depend on it'* ]] || { echo "Dropping gr_image_url was refused, but not for the policy: $err" >&2; exit 1; }
if err=$( { printf 'BEGIN;\nALTER TABLE public.goodsreceived DROP COLUMN gr_image_url CASCADE;\n'; cat "$ROOT/tests/storage_policy_deps.sql"; printf 'ROLLBACK;\n'; } | probe_psql 2>&1 >/dev/null); then
  echo 'tests/storage_policy_deps.sql did not notice a column dropped with CASCADE.' >&2; exit 1
fi
[[ "$err" == *'storage policy dependency lost'* && "$err" == *'public.goodsreceived.gr_image_url'* ]] || { echo "The dependency test failed, but not with its own message: $err" >&2; exit 1; }
mig_psql -c 'DROP DATABASE policy_probe WITH (FORCE)' >/dev/null
echo "The newest migration ($newest) applies on top of the storage policies, and a dropped policy column is named by tests/storage_policy_deps.sql."

# The seeded drill's data (tests/seed/make-seed.mjs). It loads into a migrated database with the counts it promises. With the clashing
# customer names ("Seed Harbour Traders" and " seed  HARBOUR traders ") it loads only into a database before migration 117 (the unique
# customers_name_norm_key), the state of a facility on an earlier release; the plan of this release then refuses at 117 itself, names
# the file, and changes nothing (the ledger, the index and the rows are as they were).
seed_psql() { mig_psql -d "$1" "${@:2}"; }
seed_counts() { seed_psql "$1" -At -c "SELECT (SELECT count(*) FROM public.customers) || ',' || (SELECT count(*) FROM public.goodsreceived) || ',' || (SELECT count(*) FROM public.dispatch) || ',' || (SELECT count(*) FROM public.invoice) || ',' || (SELECT count(*) FROM public.orders) || ',' || (SELECT count(*) FROM public.order_items) || ',' || (SELECT count(*) FROM storage.objects) || ',' || (SELECT count(*) FROM warehouse_migrations.applied)"; }
make_probe seed_probe "$newest"
seed_psql seed_probe < "$ROOT/scripts/configure-storage.sql" >/dev/null   # the buckets the photos belong to
node "$ROOT/tests/seed/make-seed.mjs" | seed_psql seed_probe >/dev/null
[[ "$(seed_counts seed_probe)" == "8,300,200,40,3,4,6,$migration_count" ]] || { echo "The seed did not load the counts it promises (customers, receipts, dispatches, invoices, orders, order lines, photos): $(seed_counts seed_probe)" >&2; exit 1; }
if node "$ROOT/tests/seed/make-seed.mjs" --clash | seed_psql seed_probe >/dev/null 2>&1; then echo 'The clashing seed loaded into a database that has the unique customer name index.' >&2; exit 1; fi
mig_psql -c 'DROP DATABASE seed_probe WITH (FORCE)' >/dev/null
before117=$(cd "$ROOT/migrations" && ls -1 *.sql | LC_ALL=C sort | awk '/^00000000000117_/ { exit } { last = $0 } END { print last }')
[[ -n "$before117" ]] || { echo 'Migration 117 was not found.' >&2; exit 1; }
make_probe seed_clash "$before117"
seed_psql seed_clash < "$ROOT/scripts/configure-storage.sql" >/dev/null
node "$ROOT/tests/seed/make-seed.mjs" --clash | seed_psql seed_clash >/dev/null
clash_before=$(seed_counts seed_clash)
if refused=$(plan_of "$ROOT" | seed_psql seed_clash 2>&1); then echo 'A database with clashing customer names took migration 117.' >&2; exit 1; fi
[[ "$refused" == *'Applying: 00000000000117_customer_name_rule.sql'* && "$refused" == *'customers_name_norm_key'* ]] || { echo "The refusal does not name migration 117 and its index: $refused" >&2; exit 1; }
[[ "$(seed_counts seed_clash)" == "$clash_before" ]] || { echo "The refused migration changed the database: $clash_before -> $(seed_counts seed_clash)" >&2; exit 1; }
[[ "$(seed_psql seed_clash -At -c "SELECT count(*) FROM pg_indexes WHERE indexname = 'customers_name_norm_key'")" == 0 ]] || { echo 'The refused migration left its index behind.' >&2; exit 1; }
mig_psql -c 'DROP DATABASE seed_clash WITH (FORCE)' >/dev/null
echo 'The seed loads with its counts; with clashing names the plan refuses at migration 117 and changes nothing.'

# Storage 1.80.2 guards storage.objects and storage.buckets with a statement trigger that refuses every DELETE unless
# storage.allow_delete_query is 'true', also a DELETE that row-level security would leave with 0 rows. The SQL suites below delete
# as staff to prove that the policies hide the rows, so the setting is on for them (database level of this disposable database
# only); it is reset before the customer-images block, which must see the guard as it is.
mig_psql -c "ALTER DATABASE postgres SET storage.allow_delete_query = 'true'"
test_files=(
  "$ROOT/tests/baseline_roles.sql" "$ROOT/tests/baseline_owners.sql" "$ROOT/tests/security_baseline.sql" "$ROOT/tests/operator_auth.sql"
  "$ROOT/tests/invoice_duration.sql" "$ROOT/tests/core_pilot.sql"
  "$ROOT/scripts/configure-storage.sql" "$ROOT/scripts/configure-storage.sql" "$ROOT/tests/storage_policy_deps.sql"
  "$ROOT/tests/staff_grn_access.sql" "$ROOT/tests/staff_dispatch_invoice_access.sql"
  "$ROOT/tests/storage_delete_rules.sql"
  "$ROOT/tests/user_status_enrollment.sql" "$ROOT/tests/retention.sql" "$ROOT/tests/audit_log_retention.sql"
  "$ROOT/tests/order_screen.sql" "$ROOT/tests/document_number_sort.sql" "$ROOT/tests/list_search.sql"
  "$ROOT/tests/preferred_language.sql" "$ROOT/tests/dispatch_lot_ownership.sql"
  "$ROOT/tests/grn_edit_lines.sql" "$ROOT/tests/invoice_line_rules.sql"
  "$ROOT/tests/direct_write_guard.sql" "$ROOT/tests/image_path_rules.sql"
  "$ROOT/tests/refresh_reuse.sql" "$ROOT/tests/otp_abuse_limits.sql"
  "$ROOT/tests/admin_guards.sql" "$ROOT/tests/auth_and_access.sql"
  "$ROOT/tests/role_allowlist.sql" "$ROOT/tests/document_write_consistency.sql"
  "$ROOT/tests/invoice_number_per_year.sql" "$ROOT/tests/invoice_number_ceiling.sql"
  "$ROOT/tests/zero_charge_reason.sql"
  "$ROOT/tests/item_price_history.sql" "$ROOT/tests/invoice_column_grants.sql"
  "$ROOT/tests/central_login.sql" "$ROOT/tests/report_sort.sql"
  "$ROOT/tests/report_pdf_retention.sql"
  "$ROOT/tests/report_invoice_amounts.sql"
  "$ROOT/tests/report_invoice_paid.sql"
  "$ROOT/tests/report_to_date.sql" "$ROOT/tests/grn_list_end_day.sql"
  "$ROOT/tests/report_ist_day.sql" "$ROOT/tests/report_dispatch_id.sql"
  "$ROOT/tests/grn_edit_integrity.sql"
  "$ROOT/tests/stock_history_cutoff.sql"
  "$ROOT/tests/dispatch_cart_and_movements.sql"
  "$ROOT/tests/removed_objects.sql" "$ROOT/tests/dispatch_delete_trigger.sql" "$ROOT/tests/public_config.sql" "$ROOT/tests/rpc_callers_exist.sql"
  "$ROOT/tests/print_invoice_range.sql" "$ROOT/tests/print_jobs_access.sql" "$ROOT/tests/table_reads_removed.sql"
  "$ROOT/tests/dispatch_invoice_read_figures.sql"
  "$ROOT/tests/grn_image_visibility.sql"
  "$ROOT/tests/stock_summary_item_identity.sql"
  "$ROOT/tests/sensor_ingest.sql" "$ROOT/tests/sensor_limits.sql"
  "$ROOT/tests/item_rate_changes.sql" "$ROOT/tests/enrollment_approve_role.sql" "$ROOT/tests/service_accounts.sql" "$ROOT/tests/users_review.sql"
  "$ROOT/tests/backlog_80.sql" "$ROOT/tests/open_items_82.sql" "$ROOT/tests/grn_deactivated_83.sql" "$ROOT/tests/grn_move_deactivated_84.sql" "$ROOT/tests/standard_rate.sql" "$ROOT/tests/grn_rates.sql" "$ROOT/tests/grn_item_rates_88.sql" "$ROOT/tests/staff_pricing_90.sql" "$ROOT/tests/items_review.sql"
  "$ROOT/tests/invoice_list_live.sql"
  "$ROOT/tests/fingerprint_collation.sql"
  "$ROOT/tests/catalog_receipt_width.sql" "$ROOT/tests/central_refusal_no_write.sql"
  "$ROOT/tests/grn_receipt_pages_98.sql" "$ROOT/tests/customer_dispatch_items_order_99.sql"
  "$ROOT/tests/customers_review.sql" "$ROOT/tests/owner_followups.sql" "$ROOT/tests/customer_name_rule.sql" "$ROOT/tests/push_review.sql" "$ROOT/tests/grn_heavy_dispatch.sql"
  "$ROOT/tests/open_items_2026_10_20.sql"
  "$ROOT/tests/review_fixes_120.sql" "$ROOT/tests/review_decisions_121.sql" "$ROOT/tests/push_review_122.sql"
  "$ROOT/tests/duplicate_warning_124.sql" "$ROOT/tests/dispatch_sort_key_grant_125.sql"
  "$ROOT/tests/report_stock_ist_day.sql" "$ROOT/tests/report_dispatch_weight.sql" "$ROOT/tests/report_grn_weight.sql"
  "$ROOT/tests/report_grn_invoices.sql"
  "$ROOT/tests/sessions_sliding.sql" "$ROOT/tests/break_glass.sql" "$ROOT/tests/otp_source_limits.sql"
)
for test_sql in "${test_files[@]}"; do
  docker exec -i -e PGPASSWORD=disposable-test-database-only "$container" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < "$test_sql"
done
# With the storage policies in place (configure-storage.sql ran above), the plan is still a no-op: nothing in it drops or rewrites them.
third=$(plan_of "$ROOT" | mig_psql 2>&1) || { echo "$third" | tail -20 >&2; echo 'The ledger pass after the storage policies failed.' >&2; exit 1; }
[[ "$third" == *'Already applied: 00000000000000_baseline.sql'* && "$third" != *'Applying:'* ]] || { echo "The ledger pass after the storage policies must skip every file: $third" >&2; exit 1; }


# Migration 123's guard (the block between the GUARD-BEGIN and GUARD-END lines of its file) refuses while a table to be dropped holds a
# row or a column to be dropped holds a value, and names each with its count. Run here against the migrated database, in
# transactions that are rolled back: the objects are absent (passes silently), then a stand-in table with a row, then a column
# with values on a table that has rows.
guard_sql=$(sed -n '/^-- GUARD-BEGIN$/,/^-- GUARD-END$/p' "$ROOT/migrations/00000000000123_slim_round2.sql")
[[ "$guard_sql" == *'DO $guard$'* && "$guard_sql" == *'$guard$;'* ]] || { echo 'The guard block of migration 123 was not found.' >&2; exit 1; }
printf 'BEGIN;\n%s\nROLLBACK;\n' "$guard_sql" | mig_psql >/dev/null \
  || { echo 'The migration 123 guard refused an empty database.' >&2; exit 1; }
if err=$(printf 'BEGIN;\nCREATE TABLE public.auth_logs (id int);\nINSERT INTO public.auth_logs VALUES (1), (2);\n%s\nROLLBACK;\n' "$guard_sql" | mig_psql 2>&1 >/dev/null); then
  echo 'The migration 123 guard accepted a table that holds rows.' >&2; exit 1
fi
[[ "$err" == *'table public.auth_logs: 2 rows'* && "$err" == *'Nothing was changed'* ]] || { echo "The guard refusal for a table is not the expected one: $err" >&2; exit 1; }
rows_api=$(mig_psql -At -c 'SELECT count(*) FROM public.api_configurations')
[[ "$rows_api" -ge 1 ]] || { echo 'api_configurations has no row for the guard test.' >&2; exit 1; }
if err=$(printf "BEGIN;\nALTER TABLE public.api_configurations ADD COLUMN sentry_dsn text DEFAULT 'x';\n%s\nROLLBACK;\n" "$guard_sql" | mig_psql 2>&1 >/dev/null); then
  echo 'The migration 123 guard accepted a column that holds values.' >&2; exit 1
fi
[[ "$err" == *"column public.api_configurations.sentry_dsn: $rows_api non-NULL values"* ]] || { echo "The guard refusal for a column is not the expected one: $err" >&2; exit 1; }
# A column that exists but is all NULL passes.
printf 'BEGIN;\nALTER TABLE public.api_configurations ADD COLUMN sentry_dsn text;\nCREATE TABLE public.auth_logs (id int);\n%s\nROLLBACK;\n' "$guard_sql" | mig_psql >/dev/null \
  || { echo 'The migration 123 guard refused an empty table and a NULL column.' >&2; exit 1; }

mig_psql -c "ALTER DATABASE postgres RESET storage.allow_delete_query"

# The bucket customer-images (no longer created) is removed by configure-storage.sql while it is empty,
# and configure stops, deleting nothing, while it holds a file.
legacy_psql() { docker exec -i -e PGPASSWORD=disposable-test-database-only "$container" psql -X -qAt -U supabase_admin -d postgres -v ON_ERROR_STOP=1 "$@"; }
# No customer-images bucket: configure must be a no-op, not a refused DELETE.
legacy_psql < "$ROOT/scripts/configure-storage.sql" >/dev/null
legacy_psql -c "INSERT INTO storage.buckets(id,name,public) VALUES ('customer-images','customer-images',false)" >/dev/null
legacy_psql < "$ROOT/scripts/configure-storage.sql" >/dev/null
[[ "$(legacy_psql -c "SELECT count(*) FROM storage.buckets WHERE id='customer-images'")" = 0 ]] \
  || { echo 'configure-storage.sql must delete an empty customer-images bucket.' >&2; exit 1; }
[[ "$(legacy_psql -c "SELECT count(*) FROM storage.buckets WHERE id IN ('documents','grn-images','dispatch-images')")" = 3 ]] \
  || { echo 'configure-storage.sql must keep the three real buckets.' >&2; exit 1; }
legacy_psql -c "INSERT INTO storage.buckets(id,name,public) VALUES ('customer-images','customer-images',false); INSERT INTO storage.objects(bucket_id,name) VALUES ('customer-images','c1/photo.jpg')" >/dev/null
if refused=$(legacy_psql < "$ROOT/scripts/configure-storage.sql" 2>&1); then
  echo 'configure-storage.sql must refuse while customer-images holds a file.' >&2; exit 1
fi
[[ "$refused" == *'customer-images still holds files'* ]] || { echo "Wrong refusal from configure-storage.sql: $refused" >&2; exit 1; }
[[ "$(legacy_psql -c "SELECT count(*) FROM storage.buckets WHERE id='customer-images'")" = 1 \
  && "$(legacy_psql -c "SELECT count(*) FROM storage.objects WHERE bucket_id='customer-images'")" = 1 ]] \
  || { echo 'A refused configure must delete nothing.' >&2; exit 1; }
legacy_psql -c "SELECT set_config('storage.allow_delete_query','true',false); DELETE FROM storage.objects WHERE bucket_id='customer-images'; DELETE FROM storage.buckets WHERE id='customer-images'" >/dev/null


for pass in 1 2; do
  docker exec -i -e PGPASSWORD=disposable-test-database-only \
    -e SMS_PROVIDER=msg91 -e SMS_PRODUCTION_MODE=true \
    -e MSG91_AUTH_KEY=isolated-test-key -e MSG91_TEMPLATE_ID=694a8ea0cd30ae1f432f445a \
    -e MSG91_PE_ID=1101817660000088076 -e MSG91_SENDER_ID=GCSAMD \
    "$container" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < "$ROOT/scripts/configure-sms.sql"
done
sms_synced=$(docker exec -e PGPASSWORD=disposable-test-database-only "$container" \
  psql -X -qAt -U supabase_admin -d postgres -c "SELECT count(*)=1 AND bool_and(provider='msg91' AND production_mode AND msg91_auth_key='isolated-test-key' AND msg91_template_id='694a8ea0cd30ae1f432f445a' AND msg91_pe_id='1101817660000088076' AND msg91_sender_id='GCSAMD') FROM public.sms_config")
[[ "$sms_synced" = t ]] || { echo 'Private MSG91 configuration did not synchronize idempotently.' >&2; exit 1; }
# A rerun with the same values leaves the row untouched (no updated_at bump, which a trigger would apply to any UPDATE);
# a changed value is written and does bump it.
sms_run() {
  docker exec -i -e PGPASSWORD=disposable-test-database-only \
    -e SMS_PROVIDER=msg91 -e SMS_PRODUCTION_MODE=true \
    -e MSG91_AUTH_KEY="$1" -e MSG91_TEMPLATE_ID=694a8ea0cd30ae1f432f445a \
    -e MSG91_PE_ID=1101817660000088076 -e MSG91_SENDER_ID=GCSAMD \
    "$container" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < "$ROOT/scripts/configure-sms.sql"
}
sms_stamp() { docker exec -e PGPASSWORD=disposable-test-database-only "$container" psql -X -qAt -U supabase_admin -d postgres -c "SELECT updated_at::text || ' ' || msg91_auth_key FROM public.sms_config"; }
sms_before=$(sms_stamp)
sleep 1
sms_run isolated-test-key
[[ "$(sms_stamp)" = "$sms_before" ]] || { echo 'configure-sms.sql changed the row on a rerun with the same values.' >&2; exit 1; }
sms_run isolated-test-key-changed
[[ "$(sms_stamp)" != "$sms_before" && "$(sms_stamp)" == *' isolated-test-key-changed' ]] || { echo 'configure-sms.sql did not write a changed value.' >&2; exit 1; }
# configure-operator.sql: the placeholder app name is replaced once; a rerun, or a company equal to the placeholder, changes nothing.
op_psql() { docker exec -i -e PGPASSWORD=disposable-test-database-only "$container" psql -X -qAt -U supabase_admin -d postgres -v ON_ERROR_STOP=1 "$@"; }
op_stamp() { op_psql -c "SELECT string_agg(key || '=' || value || '@' || updated_at::text, ',' ORDER BY key) FROM public.system_settings WHERE key IN ('app_name','support_email')"; }
op_psql -c "UPDATE public.system_settings SET value='Warehouse Manager' WHERE key='app_name'" >/dev/null
op_psql -v company='Warehouse Manager' < "$ROOT/scripts/configure-operator.sql" >/dev/null
op_before=$(op_stamp)
sleep 1
op_psql -v company='Warehouse Manager' < "$ROOT/scripts/configure-operator.sql" >/dev/null
[[ "$(op_stamp)" = "$op_before" ]] || { echo 'configure-operator.sql changed app_name to its own value.' >&2; exit 1; }
op_psql -v company='Test Company' < "$ROOT/scripts/configure-operator.sql" >/dev/null
[[ "$(op_stamp)" == *'app_name=Test Company@'* ]] || { echo 'configure-operator.sql did not set the company name.' >&2; exit 1; }
op_after=$(op_stamp)
sleep 1
op_psql -v company='Test Company' < "$ROOT/scripts/configure-operator.sql" >/dev/null
[[ "$(op_stamp)" = "$op_after" ]] || { echo 'configure-operator.sql changed the row on a rerun.' >&2; exit 1; }
# TW-BE-003 (migration 92, scripts/configure-auth.sql): the JWT signing secret is not a database setting.
# Every role reads a database-level setting through current_setting(), so that is checked as anon in a new
# session. SET ROLE does not apply a role's own settings, so those are read from pg_db_role_setting.
jwt_sql() {
  docker exec -i -e PGPASSWORD=disposable-test-database-only "$container" psql -X -qAt -U supabase_admin -d postgres -v ON_ERROR_STOP=1
}
anon_secret_setting() { printf '%s\n' 'SET ROLE anon;' "SELECT coalesce(current_setting('app.settings.jwt_secret', true), '');" | jwt_sql; }
secret_settings_held() {
  printf '%s\n' "SELECT count(*) FROM pg_db_role_setting s, unnest(s.setconfig) AS item WHERE starts_with(lower(item), 'app.settings.jwt_secret=');" | jwt_sql
}
plant_secret_settings() {
  jwt_sql <<'SQL'
ALTER DATABASE postgres SET "app.settings.jwt_secret" TO 'fictional-test-secret';
ALTER ROLE authenticator SET "app.settings.jwt_secret" TO 'fictional-test-secret';
ALTER ROLE anon IN DATABASE postgres SET "app.settings.jwt_secret" TO 'fictional-test-secret';
ALTER ROLE ALL SET "app.settings.jwt_secret" TO 'fictional-test-secret';
SQL
  [[ "$(anon_secret_setting)" = fictional-test-secret && "$(secret_settings_held)" = 4 ]] || {
    echo 'The test could not plant the signing secret settings.' >&2; exit 1; }
}
[[ "$(anon_secret_setting)" = '' && "$(secret_settings_held)" = 0 ]] || {
  echo 'The signing secret is held as a database or role setting after the migrations.' >&2; exit 1; }
[[ "$(printf '%s\n' "SELECT count(*) FROM pg_proc WHERE prosrc LIKE '%app.settings.jwt_secret%'" | jwt_sql)" = 0 ]] || {
  echo 'A database function reads the signing secret setting.' >&2; exit 1; }
# The auth configuration below must remove it as well, in case it came back (a restored or hand-edited database).
plant_secret_settings
for pass in 1 2; do
  if [[ "$pass" = 1 ]]; then
    docker exec -i -e PGPASSWORD=disposable-test-database-only "$container" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 <<'SQL'
SELECT warehouse_security.bootstrap_first_admin('9888888899','Configuration Test');
INSERT INTO warehouse_security.auth_config(key,value) VALUES ('auth_mode','demo')
ON CONFLICT(key) DO UPDATE SET value='demo';
SQL
  fi
  docker exec -i -e PGPASSWORD=disposable-test-database-only "$container" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO warehouse_security.refresh_sessions(user_id,token_hash,expires_at)
SELECT auth_user_id,'configuration-transition-test',now()+interval '1 hour'
FROM public.user_profiles WHERE mobile='919888888899';
SQL
  for configuration in "$ROOT/scripts/configure-auth.sql"; do
    docker exec -i -e PGPASSWORD=disposable-test-database-only "$container" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < "$configuration"
  done
  expected_sessions=$((pass - 1))
  actual_sessions=$(docker exec -e PGPASSWORD=disposable-test-database-only "$container" psql -X -qAt -U supabase_admin -d postgres -c "SELECT count(*) FROM warehouse_security.refresh_sessions WHERE token_hash='configuration-transition-test'")
  [[ "$actual_sessions" = "$expected_sessions" ]] || {
    echo 'Auth transition must revoke earlier sessions and preserve operator sessions on rerun.' >&2; exit 1;
  }
done
[[ "$(anon_secret_setting)" = '' && "$(secret_settings_held)" = 0 ]] || {
  echo 'scripts/configure-auth.sql must remove the signing secret setting from the database and from every role.' >&2; exit 1; }
# Migration 126: the session and per-source limit keys are seeded once. A rerun of the configuration keeps an operator's value (unlike
# access_seconds, which setup rewrites from JWT_EXP every time) and puts back a key that was removed.
auth_value() { docker exec -e PGPASSWORD=disposable-test-database-only "$container" psql -X -qAt -U supabase_admin -d postgres -c "SELECT COALESCE((SELECT value FROM warehouse_security.auth_config WHERE key='$1'),'absent')"; }
[[ "$(auth_value session_idle_seconds)/$(auth_value session_max_seconds)/$(auth_value otp_source_hourly_sends)/$(auth_value otp_source_hourly_failures)/$(auth_value otp_trusted_source_hourly_sends)/$(auth_value otp_trusted_sources)" == '2592000/7776000/30/20/120/absent' ]] || {
  echo 'The session lifetime and per-source limit keys do not hold their defaults after the migrations and configure-auth.sql.' >&2; exit 1; }
docker exec -e PGPASSWORD=disposable-test-database-only "$container" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
  -c "UPDATE warehouse_security.auth_config SET value='86400' WHERE key='session_idle_seconds'" \
  -c "UPDATE warehouse_security.auth_config SET value='200' WHERE key='otp_source_hourly_sends'" \
  -c "DELETE FROM warehouse_security.auth_config WHERE key='otp_source_hourly_failures'"
docker exec -i -e PGPASSWORD=disposable-test-database-only "$container" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < "$ROOT/scripts/configure-auth.sql"
[[ "$(auth_value session_idle_seconds)/$(auth_value otp_source_hourly_sends)/$(auth_value otp_source_hourly_failures)" == '86400/200/20' ]] || {
  echo 'scripts/configure-auth.sql must keep an operator value of the session and limit keys and put back a removed one.' >&2; exit 1; }

# scripts/configure-central.sql: the trusted issuer is the psql variable
# setup.sh passes from compose.env; absent or empty turns central sign-in off,
# and a value that is not an https address changes nothing.
central_issuer() {
  docker exec -e PGPASSWORD=disposable-test-database-only "$container" psql -X -qAt -U supabase_admin -d postgres \
    -c "SELECT COALESCE((SELECT value FROM warehouse_security.auth_config WHERE key='central_issuer'),'off')"
}
configure_central() {
  docker exec -i -e PGPASSWORD=disposable-test-database-only "$container" \
    psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 "$@" < "$ROOT/scripts/configure-central.sql"
}
configure_central
[[ "$(central_issuer)" = off ]] || { echo 'Central sign-in must be off when no issuer is passed.' >&2; exit 1; }
for pass in 1 2; do
  configure_central -v central_issuer=https://login.association.example.test
  [[ "$(central_issuer)" = https://login.association.example.test ]] || { echo 'The trusted issuer was not stored.' >&2; exit 1; }
done
configure_central -v central_issuer=https://login.association.example.test/v2
[[ "$(central_issuer)" = https://login.association.example.test/v2 ]] || { echo 'The trusted issuer was not replaced.' >&2; exit 1; }
# central_local_code (migration 81): off unless the variable is exactly 'on'; stored only with a valid issuer;
# removed with the issuer; the stored value follows the variable on every run.
central_local_code() {
  docker exec -e PGPASSWORD=disposable-test-database-only "$container" psql -X -qAt -U supabase_admin -d postgres \
    -c "SELECT COALESCE((SELECT value FROM warehouse_security.auth_config WHERE key='central_local_code'),'off')"
}
[[ "$(central_local_code)" = off ]] || { echo 'The facility''s own code must be off by default.' >&2; exit 1; }
for pass in 1 2; do
  configure_central -v central_issuer=https://login.association.example.test/v2 -v central_local_code=on
  [[ "$(central_local_code)" = on ]] || { echo 'central_local_code=on was not stored.' >&2; exit 1; }
done
configure_central -v central_issuer=https://login.association.example.test/v2 -v central_local_code=yes
[[ "$(central_local_code)" = off ]] || { echo 'Only the exact value on may switch the facility''s own code on.' >&2; exit 1; }
configure_central -v central_issuer=https://login.association.example.test/v2 -v central_local_code=on
configure_central -v central_issuer=https://login.association.example.test/v2
[[ "$(central_local_code)" = off ]] || { echo 'A run without central_local_code must store it as off.' >&2; exit 1; }
configure_central -v central_issuer=https://login.association.example.test/v2 -v central_local_code=on
configure_central -v central_issuer= -v central_local_code=on
[[ "$(central_issuer)" = off && "$(central_local_code)" = off ]] || { echo 'Turning central sign-in off must remove the facility''s own code too.' >&2; exit 1; }
configure_central -v central_issuer=https://login.association.example.test/v2
# The value is quoted as a literal: text that would end a string is refused as an address, not run.
for refused in 'http://login.association.example.test' 'https://login.association.example.test/a b' 'login.association.example.test' \
  "https://x.example.test'); DELETE FROM warehouse_security.auth_config; --"; do
  if configure_central -v "central_issuer=$refused" >/dev/null 2>&1; then
    echo "configure-central.sql accepted the issuer '$refused'." >&2; exit 1
  fi
  [[ "$(central_issuer)" = https://login.association.example.test/v2 ]] || { echo 'A refused issuer changed the stored one.' >&2; exit 1; }
done
configure_central -v central_issuer=
[[ "$(central_issuer)" = off ]] || { echo 'An empty issuer must turn central sign-in off.' >&2; exit 1; }
# The database container needs no CENTRAL_ISSUER of its own.
if docker exec "$container" printenv CENTRAL_ISSUER >/dev/null 2>&1; then echo 'The test database must not carry CENTRAL_ISSUER.' >&2; exit 1; fi


# None of the roles of the earlier image exists (tests/baseline_roles.sql holds the exact set): a state assertion that
# configure-db-roles.sql below must not change either.
removed_roles_state="SELECT count(*) FROM pg_roles WHERE rolname IN ('postgres','dashboard_user','supabase_read_only_user','supabase_replication_admin','supabase_realtime_admin','supabase_auth_admin','supabase_functions_admin','supabase_etl_admin','warehouse_list_refresher','warehouse_monitoring')"
[[ "$(mig_psql -At -c "$removed_roles_state")" == '0' ]] || { echo 'The baseline has a role of the earlier image.' >&2; exit 1; }

# scripts/configure-db-roles.sql (TW-BE-002, migration 94): through the prelude of
# scripts/db-roles.mjs, as scripts/db-roles.sh sends it. Each login stores exactly the
# SCRAM verifier it was given (never a password); a rerun applies again; a missing or
# plaintext value changes nothing; no role of the earlier image is created or needed. Logins themselves are proven over the network by
# `npm run test:db-roles` in the operator-install job: this container has none.
roles_sql() {
  docker exec -e PGPASSWORD=disposable-test-database-only "$container" psql -X -qAt -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -c "$1"
}
apply_db_roles() {
  { cat; cat "$ROOT/scripts/configure-db-roles.sql"; } |
    docker exec -i -e PGPASSWORD=disposable-test-database-only "$container" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1
}
roles_env=$(mktemp "${TMPDIR:-/tmp}/warehouse-db-roles.XXXXXX")
{
  printf 'POSTGRES_PASSWORD=%s\n' "$(openssl rand -hex 32)"
  for name in $(node "$ROOT/scripts/db-roles.mjs" names); do
    printf '%s=%s\n' "$name" "$(openssl rand -hex 32)"
  done
} > "$roles_env"
stored_verifiers="SELECT string_agg(rolname || ' ' || rolcanlogin || ' ' || rolpassword, E'\n' ORDER BY rolname) FROM pg_authid WHERE rolname IN ('authenticator','supabase_storage_admin','pgbouncer')"
# The pooler is off by default: the bootstrap creates no pgbouncer role, schema or _supabase database, and the logins script
# neither creates nor sets one. (Turning it on is covered after the security baseline below.)
[[ "$(roles_sql "SELECT count(*) FROM pg_roles WHERE rolname = 'pgbouncer'")" == 0 \
  && "$(roles_sql "SELECT count(*) FROM pg_namespace WHERE nspname = 'pgbouncer'")" == 0 \
  && "$(roles_sql "SELECT count(*) FROM pg_database WHERE datname = '_supabase'")" == 0 ]] || {
  echo 'A new database has pooler objects (role, schema or _supabase database).' >&2; exit 1; }
for pass in 1 2; do
  prelude=$(node "$ROOT/scripts/db-roles.mjs" prelude "$roles_env")
  apply_db_roles <<< "$prelude"
  expected=$(printf '%s\n' "$prelude" | sed -n "s/^\\\\set \\([a-z_]*\\)_verifier '\\(.*\\)'$/\\1 \\2/p" |
    sed -e 's/^authenticator /authenticator true /' -e 's/^storage /supabase_storage_admin true /' \
        | LC_ALL=C sort)
  [[ "$(roles_sql "$stored_verifiers" | LC_ALL=C sort)" == "$expected" ]] || {
    echo "configure-db-roles.sql pass $pass did not store each login's own verifier with LOGIN." >&2; exit 1; }
done
grep -q "$(sed -n 's/^DB_PASSWORD_AUTHENTICATOR=//p' "$roles_env")" <<< "$(roles_sql "$stored_verifiers")" && {
  echo 'A password reached the database instead of its verifier.' >&2; exit 1; }
before_refusals=$(roles_sql "$stored_verifiers")
if apply_db_roles <<< "$(grep -v '^\\set storage_verifier' <<< "$prelude")" >/dev/null 2>&1; then
  echo 'configure-db-roles.sql ran without the storage verifier.' >&2; exit 1; fi
if apply_db_roles <<< "$(sed "s/^\\\\set storage_verifier .*/\\\\set storage_verifier 'plaintext-password-not-a-verifier'/" <<< "$prelude")" >/dev/null 2>&1; then
  echo 'configure-db-roles.sql accepted a plaintext password.' >&2; exit 1; fi
[[ "$(roles_sql "$stored_verifiers")" == "$before_refusals" ]] || { echo 'A refused configure-db-roles.sql run changed a password.' >&2; exit 1; }
apply_db_roles <<< "$prelude"
[[ "$(roles_sql "$removed_roles_state")" == '0' ]] || {
  echo 'configure-db-roles.sql created a role of the earlier image.' >&2; exit 1; }
rm -f "$roles_env"
unset prelude expected before_refusals
# The baseline holds after the logins were configured too.
docker exec -i -e PGPASSWORD=disposable-test-database-only "$container" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < "$ROOT/tests/security_baseline.sql" >/dev/null

# Turning the pooler on (scripts/pooler.sh on, through scripts/db-roles.sh apply): configure-pooler.sql creates the role, the
# schema with get_auth and the _supabase database (with _supavisor), repeats without error, and the pool user's verifier is
# then stored. Everything is removed again, so the suites that follow see the default database.
pooler_env=$(mktemp "${TMPDIR:-/tmp}/warehouse-db-roles.XXXXXX")
{
  printf 'POSTGRES_PASSWORD=%s\nPOOLER_ENABLED=true\n' "$(openssl rand -hex 32)"
  for name in $(node "$ROOT/scripts/db-roles.mjs" names) DB_PASSWORD_POOLER; do
    printf '%s=%s\n' "$name" "$(openssl rand -hex 32)"
  done
} > "$pooler_env"
for pass in 1 2; do
  docker exec -i -e PGPASSWORD=disposable-test-database-only "$container" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < "$ROOT/scripts/configure-pooler.sql"
  apply_db_roles <<< "$(node "$ROOT/scripts/db-roles.mjs" prelude "$pooler_env")"
done
[[ "$(roles_sql "SELECT rolcanlogin::text || ' ' || (rolpassword LIKE 'SCRAM-SHA-256\$%')::text || ' ' || rolsuper::text FROM pg_authid WHERE rolname = 'pgbouncer'")" == 'true true false' ]] || {
  echo 'Turning the pooler on did not give pgbouncer a SCRAM login without superuser rights.' >&2; exit 1; }
[[ "$(roles_sql "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'pgbouncer' AND p.proname = 'get_auth' AND p.prosecdef")" == 1 ]] || {
  echo 'pgbouncer.get_auth is missing or not SECURITY DEFINER.' >&2; exit 1; }
[[ "$(roles_sql "SELECT count(*) FROM pgbouncer.get_auth('supabase_admin')")" == 0 ]] || {
  echo 'pgbouncer.get_auth returned a superuser verifier.' >&2; exit 1; }
[[ "$(roles_sql "SELECT count(*) FROM pgbouncer.get_auth('authenticator')")" == 1 ]] || {
  echo 'pgbouncer.get_auth did not return a normal login.' >&2; exit 1; }
[[ "$(docker exec -e PGPASSWORD=disposable-test-database-only "$container" psql -X -qAt -U supabase_admin -d _supabase -v ON_ERROR_STOP=1 -c "SELECT nspname FROM pg_namespace WHERE nspname = '_supavisor'")" == _supavisor ]] || {
  echo 'The _supabase database has no _supavisor schema.' >&2; exit 1; }
# Off removes them (scripts/drop-pooler.sql, run by pooler.sh off and cleanup and by db-roles.sh apply while the pooler is off).
# It refuses, and changes nothing, when the schema holds something besides get_auth or _supabase holds a relation; this is
# also what leaves the default database for the suites below.
pooler_psql() { docker exec -i -e PGPASSWORD=disposable-test-database-only "$container" psql -X -q -U supabase_admin "$@" -v ON_ERROR_STOP=1; }
pooler_objects="SELECT (SELECT count(*) FROM pg_roles WHERE rolname = 'pgbouncer') || ' ' || (SELECT count(*) FROM pg_namespace WHERE nspname = 'pgbouncer') || ' ' || (SELECT count(*) FROM pg_database WHERE datname = '_supabase')"
pooler_psql -d postgres -c 'CREATE TABLE pgbouncer.stray (id int)'
if pooler_psql -d postgres < "$ROOT/scripts/drop-pooler.sql" 2>/dev/null; then
  echo 'drop-pooler.sql removed a schema that holds another table.' >&2; exit 1; fi
[[ "$(roles_sql "$pooler_objects")" == '1 1 1' ]] || { echo 'A refused pooler removal changed something.' >&2; exit 1; }
pooler_psql -d postgres -c 'DROP TABLE pgbouncer.stray'
pooler_psql -d _supabase -c 'CREATE TABLE _supavisor.tenants (id int)'
if pooler_psql -d postgres < "$ROOT/scripts/drop-pooler.sql" 2>/dev/null; then
  echo 'drop-pooler.sql removed a _supabase database that holds a table.' >&2; exit 1; fi
[[ "$(roles_sql "$pooler_objects")" == '1 1 1' ]] || { echo 'A refused pooler removal changed something.' >&2; exit 1; }
pooler_psql -d _supabase -c 'DROP TABLE _supavisor.tenants'
pooler_psql -d postgres < "$ROOT/scripts/drop-pooler.sql"
[[ "$(roles_sql "$pooler_objects")" == '0 0 0' ]] || {
  echo 'The pooler removal SQL left an object behind.' >&2; exit 1; }
pooler_psql -d postgres < "$ROOT/scripts/drop-pooler.sql"
rm -f "$pooler_env"
unset pooler_env

# scripts/sensor-ingest-key.sql (migration 74): each run prints one new key, 64 hex, once;
# only its SHA-256 is stored; record_sensor_batch takes it until it is revoked. A missing or
# ill-formed label mints nothing. The key is not echoed here.
sensor_sql() {
  docker exec -e PGPASSWORD=disposable-test-database-only "$container" psql -X -qAt -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -c "$1"
}
mint_sensor_key() {
  docker exec -i -e PGPASSWORD=disposable-test-database-only "$container" \
    psql -X -qAt -U supabase_admin -d postgres -v ON_ERROR_STOP=1 "$@" < "$ROOT/scripts/sensor-ingest-key.sql"
}
sensor_keys_before=$(sensor_sql 'SELECT count(*) FROM warehouse_security.sensor_ingest_keys')
sensor_key=$(mint_sensor_key -v label=ci)
[[ "$(printf '%s\n' "$sensor_key" | wc -l)" = 1 && "$sensor_key" =~ ^[0-9a-f]{64}$ ]] || {
  echo 'sensor-ingest-key.sql must print exactly one row: a 64-hex key.' >&2; exit 1; }
second_sensor_key=$(mint_sensor_key -v label=ci)
[[ "$second_sensor_key" =~ ^[0-9a-f]{64}$ && "$second_sensor_key" != "$sensor_key" ]] || { echo 'A second run must mint a different key.' >&2; exit 1; }
[[ "$(sensor_sql "SELECT count(*) FROM warehouse_security.sensor_ingest_keys WHERE label='ci' AND revoked_at IS NULL
    AND key_hash IN (encode(extensions.digest('$sensor_key','sha256'),'hex'), encode(extensions.digest('$second_sensor_key','sha256'),'hex'))")" = 2
   && "$(sensor_sql "SELECT count(*) FROM warehouse_security.sensor_ingest_keys WHERE key_hash IN ('$sensor_key','$second_sensor_key')")" = 0
   && "$(sensor_sql 'SELECT count(*) FROM warehouse_security.sensor_ingest_keys')" = $((sensor_keys_before + 2)) ]] || {
  echo 'sensor-ingest-key.sql must store the SHA-256 of each key under its label, never the key.' >&2; exit 1; }
[[ "$(sensor_sql "SELECT public.record_sensor_batch('$sensor_key', '{\"id\":\"ci-hub\",\"online\":true}', '[]')->>'success'")" = true ]] || {
  echo 'record_sensor_batch refused a key minted by sensor-ingest-key.sql.' >&2; exit 1; }
sensor_sql "UPDATE warehouse_security.sensor_ingest_keys SET revoked_at = now() WHERE label = 'ci' AND revoked_at IS NULL" >/dev/null
[[ "$(sensor_sql "SELECT public.record_sensor_batch('$sensor_key', '{\"id\":\"ci-hub\",\"online\":true}', '[]')->>'code'")" = invalid_key ]] || {
  echo 'record_sensor_batch accepted a revoked key.' >&2; exit 1; }
for refused in '' ' ci' 'a/b' "ci'); DELETE FROM warehouse_security.sensor_ingest_keys; --" "$(printf 'k%.0s' {1..65})"; do
  if mint_sensor_key -v "label=$refused" >/dev/null 2>&1; then echo "sensor-ingest-key.sql accepted the label '$refused'." >&2; exit 1; fi
done
if mint_sensor_key >/dev/null 2>&1; then echo 'sensor-ingest-key.sql minted a key without a label.' >&2; exit 1; fi
[[ "$(sensor_sql 'SELECT count(*) FROM warehouse_security.sensor_ingest_keys')" = $((sensor_keys_before + 2)) ]] || {
  echo 'A refused label changed the stored keys.' >&2; exit 1; }
sensor_sql "DELETE FROM warehouse_security.sensor_ingest_keys WHERE label = 'ci'; DELETE FROM public.sensor_hubs WHERE hub_id = 'ci-hub'" >/dev/null
unset sensor_key second_sensor_key

# Migrations 26 and 46: a GRN edit, a dispatch being created and a dispatch edit
# must each survive a concurrent writer of the same lot.
bash "$ROOT/tests/grn_edit_lock_order.sh" "$container"

# Migrations 41, 44 and 46: the last-administrator rule and the one-invoice-per-
# receipt rule under two users acting at the same moment.
bash "$ROOT/tests/concurrent_rules.sh" "$container"

# scripts/retention.sh: every statement it sends is one this database accepts.
bash "$ROOT/tests/retention_queries.sh" "$container"

# The ledger after a rejected, changed copy (above) still holds exactly the baseline.
[[ "$(docker exec -e PGPASSWORD=disposable-test-database-only "$container" psql -X -qAt -U supabase_admin -d postgres -c 'SELECT count(*) FROM warehouse_migrations.applied')" = "$migration_count" ]] || {
  echo 'A rejected migration run changed the ledger.' >&2; exit 1;
}

# Backup verification on real containers: this database is dumped into a signed
# backup and replayed by scripts/verify-restore.sh, once with a session attached to
# template1 and once with the disk-backed data directory.
bash "$ROOT/tests/verify-restore-drill.sh" "$container"
# The REST service (PostgREST, the image docker/docker-compose.yml pins) against this migrated database, with the settings the compose
# file gives it: tests/postgrest-contract.test.mjs asserts the status, code and message of every refusal the app keys on
# (docs/API_CONTRACT.md, "What the app may match: codes, not texts"). It runs on the test network, which has no route out; the
# host reaches it by the container's address on that network. Its own database login gets a password here, as Storage's does above.
rest_image=$(sed -n 's/^    image: \(postgrest\/postgrest:[^ ]*\)$/\1/p' "$ROOT/docker/docker-compose.yml")
[[ -n "$rest_image" ]] || { echo 'No postgrest image in docker/docker-compose.yml' >&2; exit 1; }
docker image inspect "$rest_image" >/dev/null 2>&1 || docker pull -q "$rest_image" >/dev/null
rest_password=$(openssl rand -hex 32)
rest_secret=$(openssl rand -hex 32)
mig_psql -c "ALTER ROLE authenticator PASSWORD '$rest_password'"
rest_container=$(new_name rest)
docker run -d --name "$rest_container" --label purpose=slim-tool --network "$net" --memory 512m --cpus 1 \
  -e PGRST_DB_POOL=5 -e PGRST_DB_POOL_ACQUISITION_TIMEOUT=10 -e PGRST_DB_CONFIG=true -e PGRST_DB_PREPARED_STATEMENTS=true \
  -e "PGRST_DB_URI=postgres://authenticator:$rest_password@$container:5432/postgres" -e PGRST_DB_SCHEMAS=public -e PGRST_DB_ANON_ROLE=anon \
  -e "PGRST_JWT_SECRET=$rest_secret" -e PGRST_OPENAPI_MODE=disabled -e PGRST_DB_PRE_REQUEST=public.check_session \
  "$rest_image" postgrest >/dev/null
rest_address=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}" "$rest_container")
rest_ready=false
for ((i=0; i<30; i++)); do
  if [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://$rest_address:3000/rpc/get_public_config" -X POST -H 'content-type: application/json' -d '{"p_environment":"production"}' || true)" == 200 ]]; then rest_ready=true; break; fi
  sleep 1
done
[[ "$rest_ready" == true ]] || { docker logs -t --tail 20 "$rest_container" >&2 || true; echo 'The REST service did not start for the contract test.' >&2; exit 1; }
# Nothing may be skipped: a lost variable would otherwise turn every case into a skip and the run would still be green. The TAP reporter
# is named because the summary lines checked below are its; a case or a docker exec that hangs is cut off by the timeouts.
contract_report=$(POSTGREST_CONTRACT_URL="http://$rest_address:3000" POSTGREST_CONTRACT_SECRET="$rest_secret" \
  POSTGREST_CONTRACT_DB_CONTAINER="$container" POSTGREST_CONTRACT_DB_PASSWORD=disposable-test-database-only \
  node --test --test-reporter=tap --test-timeout=60000 "$ROOT/tests/postgrest-contract.test.mjs" 2>&1) || { printf '%s\n' "$contract_report" >&2; echo 'The REST contract test failed.' >&2; exit 1; }
[[ "$contract_report" == *'# skipped 0'* && "$contract_report" == *'# fail 0'* ]] || { printf '%s\n' "$contract_report" >&2; echo 'The REST contract test skipped cases.' >&2; exit 1; }
echo "REST contract: $(sed -n 's/^# pass \([0-9]*\)$/\1/p' <<<"$contract_report") checks against the pinned PostgREST passed."
docker rm -fv "$rest_container" >/dev/null
rest_container=''
echo 'Migration reruns, checksum mismatch rejection, retention, and operator and central auth configuration passed.'

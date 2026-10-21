#!/usr/bin/env bash
# Tests ONLY a newly created, network-isolated, disposable database. No host ports.
#
# The database is the shipped one: the official Postgres image of scripts/db-image.sh, started as production starts it
# (POSTGRES_USER=supabase_admin, en_US.UTF-8, the `-c` flags of docker/docker-compose.override.yml, the init scripts
# 00-bootstrap.sql and roles.sql). The order is setup.sh's: database, migrations (the baseline, run twice), then the real
# Storage 1.80.2 on a throwaway --internal network (DB_SUPER_USER=supabase_storage_admin, DB_INSTALL_ROLES=false), then
# scripts/configure-storage.sql, then the SQL suites. No schema fixture stands in for Storage.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# new_name, create_net, run_storage and storage_image (throwaway containers named slim-tool-*, removed by their own code).
source "$ROOT/scripts/baseline/lib.sh"
suffix=$(openssl rand -hex 6)
container="warehouse-migrations-$suffix"
net=''
created=false
cleanup() {
  if [[ "$created" == true ]]; then docker rm -fv "$container" >/dev/null 2>&1 || true; fi
  remove_storage_containers
  if [[ -n "$net" ]]; then docker network rm "$net" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT
# The library settings the shipped database runs with (docker/docker-compose.override.yml): the same `-c` flags are passed here,
# so the harness tests what ships.
shipped_flags=()
while IFS= read -r flag; do
  shipped_flags+=(-c "${flag#-c }")
done < <(
  sed -n 's/^ *\(-c \(shared_preload_libraries\|wal_level\|timezone\|log_timezone\|extra_float_digits\|pg_stat_statements\.[a-z_]*\)=.*\)$/\1/p' "$ROOT/docker/docker-compose.override.yml")
[[ " ${shipped_flags[*]} " == *shared_preload_libraries=pg_stat_statements\ * || " ${shipped_flags[*]} " == *shared_preload_libraries=pg_stat_statements ]] || { echo 'shared_preload_libraries is not exactly pg_stat_statements in docker-compose.override.yml' >&2; exit 1; }
[[ " ${shipped_flags[*]} " == *wal_level=replica* ]] || { echo 'No wal_level=replica in docker-compose.override.yml' >&2; exit 1; }
db_image="$(bash "$ROOT/scripts/db-image.sh")"
# Random service passwords for the init script roles.sql (it needs 32 to 128 distinct characters of [A-Za-z0-9_-]).
net=$(create_net)
docker run -d --name "$container" --label purpose=warehouse-migration-test \
  --network "$net" --memory 1g --cpus 1 \
  --tmpfs /var/lib/postgresql/data:rw,size=768m -e PGDATA=/var/lib/postgresql/data \
  -e JWT_SECRET=isolated-test-secret-not-for-any-deployment-12345 -e JWT_EXP=3600 \
  -e AUTH_MODE=operator -e APP_ENV=production \
  -e POSTGRES_USER=supabase_admin -e POSTGRES_DB=postgres -e POSTGRES_PASSWORD="$(openssl rand -hex 32)" \
  -e DB_PASSWORD_AUTHENTICATOR="$(openssl rand -hex 32)" -e DB_PASSWORD_STORAGE="$(openssl rand -hex 32)" -e DB_PASSWORD_POOLER="$(openssl rand -hex 32)" \
  -e POSTGRES_INITDB_ARGS=--locale=en_US.UTF-8 \
  -v "$ROOT/docker/volumes/db/00-bootstrap.sql:/docker-entrypoint-initdb.d/00-bootstrap.sql:ro" \
  -v "$ROOT/docker/volumes/db/roles.sql:/docker-entrypoint-initdb.d/10-roles.sql:ro" \
  "$db_image" \
  postgres "${shipped_flags[@]}" >/dev/null
created=true
ready=false
for ((i=0; i<60; i++)); do
  # The image's temporary server answers while the init scripts still run: wait for the end of init, then for the real server.
  init_log=$(docker logs "$container" 2>&1 || true)
  if [[ "$init_log" == *'PostgreSQL init process complete; ready for start up'* ]] \
    && docker exec "$container" pg_isready -U supabase_admin -d postgres -h 127.0.0.1 >/dev/null 2>&1; then ready=true; break; fi
  sleep 2
done
[[ "$ready" == true ]] || { echo 'Test database did not start' >&2; exit 1; }
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

# A changed baseline must fail closed: a space appended to a temporary copy.
changed=$(mktemp -d "${TMPDIR:-/tmp}/warehouse-changed.XXXXXX")
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
probe=$(mktemp -d "${TMPDIR:-/tmp}/warehouse-probe.XXXXXX")
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

# Storage, as setup.sh does after the migrations: the real Storage 1.80.2 builds its own tables in the schema the bootstrap made.
run_storage "$container" "$net" "$(storage_image)" >/dev/null
[[ "$(mig_psql -At -c 'SELECT count(*) > 0 FROM storage.migrations')" == t && "$(mig_psql -At -c "SELECT count(*) FROM pg_tables WHERE schemaname = 'storage' AND tablename IN ('buckets', 'objects')")" == 2 ]] || { echo 'Storage did not build its tables.' >&2; exit 1; }
# The baseline did not need Storage, and Storage did not need the baseline's help: the three API roles can use the schema.
[[ "$(mig_psql -At -c "SELECT bool_and(has_schema_privilege(r, 'storage', 'USAGE')) FROM unnest(ARRAY['anon','authenticated','service_role']) r")" == t ]] || { echo 'An API role cannot use the storage schema.' >&2; exit 1; }
# Storage 1.80.2 guards storage.objects and storage.buckets with a statement trigger that refuses every DELETE unless
# storage.allow_delete_query is 'true', also a DELETE that row-level security would leave with 0 rows. The SQL suites below delete
# as staff to prove that the policies hide the rows, so the setting is on for them (database level of this disposable database
# only); it is reset before the customer-images block, which must see the guard as it is.
mig_psql -c "ALTER DATABASE postgres SET storage.allow_delete_query = 'true'"
test_files=(
  "$ROOT/tests/baseline_roles.sql" "$ROOT/tests/baseline_owners.sql" "$ROOT/tests/security_baseline.sql" "$ROOT/tests/operator_auth.sql"
  "$ROOT/tests/invoice_duration.sql" "$ROOT/tests/core_pilot.sql"
  "$ROOT/scripts/configure-storage.sql" "$ROOT/scripts/configure-storage.sql"
  "$ROOT/tests/staff_grn_access.sql" "$ROOT/tests/staff_dispatch_invoice_access.sql"
  "$ROOT/tests/storage_delete_rules.sql"
  "$ROOT/tests/user_status_enrollment.sql" "$ROOT/tests/retention.sql"
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
  "$ROOT/tests/legacy_functions.sql"
  "$ROOT/tests/print_invoice_range.sql"
  "$ROOT/tests/dispatch_invoice_read_figures.sql"
  "$ROOT/tests/grn_image_visibility.sql"
  "$ROOT/tests/stock_summary_item_identity.sql"
  "$ROOT/tests/sensor_ingest.sql" "$ROOT/tests/sensor_limits.sql"
  "$ROOT/tests/item_rate_changes.sql" "$ROOT/tests/enrollment_approve_role.sql" "$ROOT/tests/service_accounts.sql" "$ROOT/tests/users_review.sql"
  "$ROOT/tests/backlog_80.sql" "$ROOT/tests/open_items_82.sql" "$ROOT/tests/grn_deactivated_83.sql" "$ROOT/tests/grn_move_deactivated_84.sql" "$ROOT/tests/standard_rate.sql" "$ROOT/tests/grn_rates.sql" "$ROOT/tests/grn_item_rates_88.sql" "$ROOT/tests/staff_pricing_90.sql" "$ROOT/tests/items_review.sql"
  "$ROOT/tests/list_refresh_removed_106.sql" "$ROOT/tests/invoice_list_live.sql"
  "$ROOT/tests/realtime_removed_105.sql"
  "$ROOT/tests/unused_extensions_absent.sql" "$ROOT/tests/fingerprint_collation.sql" "$ROOT/tests/jwt_sign_108.sql"
  "$ROOT/tests/catalog_receipt_width.sql" "$ROOT/tests/central_refusal_no_write.sql"
  "$ROOT/tests/grn_receipt_pages_98.sql" "$ROOT/tests/customer_dispatch_items_order_99.sql"
  "$ROOT/tests/customers_review.sql" "$ROOT/tests/owner_followups.sql" "$ROOT/tests/customer_name_rule.sql" "$ROOT/tests/push_review.sql" "$ROOT/tests/grn_heavy_dispatch.sql"
  "$ROOT/tests/open_items_2026_10_20.sql"
  "$ROOT/tests/review_fixes_120.sql" "$ROOT/tests/review_decisions_121.sql" "$ROOT/tests/push_review_122.sql"
  "$ROOT/tests/report_stock_ist_day.sql" "$ROOT/tests/report_dispatch_weight.sql" "$ROOT/tests/report_grn_weight.sql"
  "$ROOT/tests/report_grn_invoices.sql"
)
for test_sql in "${test_files[@]}"; do
  docker exec -i -e PGPASSWORD=disposable-test-database-only "$container" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < "$test_sql"
done


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
for pass in 1 2; do
  prelude=$(node "$ROOT/scripts/db-roles.mjs" prelude "$roles_env")
  apply_db_roles <<< "$prelude"
  expected=$(printf '%s\n' "$prelude" | sed -n "s/^\\\\set \\([a-z_]*\\)_verifier '\\(.*\\)'$/\\1 \\2/p" |
    sed -e 's/^authenticator /authenticator true /' -e 's/^storage /supabase_storage_admin true /' \
        -e 's/^pooler /pgbouncer true /' | LC_ALL=C sort)
  [[ "$(roles_sql "$stored_verifiers" | LC_ALL=C sort)" == "$expected" ]] || {
    echo "configure-db-roles.sql pass $pass did not store each login's own verifier with LOGIN." >&2; exit 1; }
done
grep -q "$(sed -n 's/^DB_PASSWORD_AUTHENTICATOR=//p' "$roles_env")" <<< "$(roles_sql "$stored_verifiers")" && {
  echo 'A password reached the database instead of its verifier.' >&2; exit 1; }
before_refusals=$(roles_sql "$stored_verifiers")
if apply_db_roles <<< "$(grep -v '^\\set pooler_verifier' <<< "$prelude")" >/dev/null 2>&1; then
  echo 'configure-db-roles.sql ran without the pool user verifier.' >&2; exit 1; fi
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
echo 'Migration reruns, checksum mismatch rejection, retention, and operator and central auth configuration passed.'

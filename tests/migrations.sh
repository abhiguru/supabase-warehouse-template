#!/usr/bin/env bash
# Tests ONLY a newly created, network-isolated, disposable database. No host ports.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
suffix=$(openssl rand -hex 6)
container="warehouse-migrations-$suffix"
created=false
cleanup() {
  if [[ "$created" == true ]]; then docker rm -f "$container" >/dev/null; fi
}
trap cleanup EXIT
# The library settings the shipped database runs with (docker/docker-compose.override.yml): the same `-c` flags
# are passed here, so the harness tests what ships (the bare image would also preload the image's other libraries).
# One addition: pg_net is appended to shared_preload_libraries, only because the block "Migrations 93 and 103" below
# rebuilds a pre-103 database, which needs CREATE EXTENSION pg_net; the shipped stack does not preload it.
shipped_flags=()
while IFS= read -r flag; do
  case "$flag" in "-c shared_preload_libraries="*) flag="$flag,pg_net" ;; esac
  shipped_flags+=(-c "${flag#-c }")
done < <(
  sed -n 's/^ *\(-c \(shared_preload_libraries\|wal_level\|pg_stat_statements\.[a-z_]*\|cron\.[a-z_]*\)=.*\)$/\1/p' "$ROOT/docker/docker-compose.override.yml")
[[ " ${shipped_flags[*]} " == *shared_preload_libraries=* ]] || { echo 'No shared_preload_libraries in docker-compose.override.yml' >&2; exit 1; }
[[ " ${shipped_flags[*]} " == *wal_level=replica* ]] || { echo 'No wal_level=replica in docker-compose.override.yml' >&2; exit 1; }
docker run -d --name "$container" --label purpose=warehouse-migration-test \
  --network none --memory 1g --cpus 1 \
  --tmpfs /var/lib/postgresql/data:rw,size=768m \
  -e JWT_SECRET=isolated-test-secret-not-for-any-deployment-12345 -e JWT_EXP=3600 \
  -e AUTH_MODE=operator -e APP_ENV=production \
  -e POSTGRES_PASSWORD=disposable-test-database-only \
  supabase/postgres:15.8.1.135@sha256:ee680a0afebe1a5e95614fdea671c01a264e58f52de6c429c17a394f46dec2c6 \
  postgres -D /etc/postgresql "${shipped_flags[@]}" >/dev/null
created=true
ready=false
for ((i=0; i<60; i++)); do
  if docker exec "$container" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1; then ready=true; break; fi
  sleep 2
done
[[ "$ready" == true ]] || { echo 'Test database did not start' >&2; exit 1; }
mig_psql() { docker exec -i -e PGPASSWORD=disposable-test-database-only "$container" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 "$@"; }
# The migration plan of a directory that holds a `migrations/` folder.
plan_of() { PLAN_MODULE="$ROOT/scripts/migration-plan.mjs" PLAN_ROOT="$1" node -e "import(process.env.PLAN_MODULE).then(m => process.stdout.write(m.migrationPlan(process.env.PLAN_ROOT)))"; }

# Migration 106 moves get_invoices_list from the materialized view mv_invoice_list to the tables and removes pg_cron
# and the list refresher. So that the move can be compared, the migrations up to 105 are applied first, the answers
# of the old function are recorded on a fixed set of invoices (tests/invoice_list_parity.sql), migration 106 is
# applied, and the same file must then print the same answers.
stage105=$(mktemp -d "${TMPDIR:-/tmp}/warehouse-stage105.XXXXXX")
mkdir "$stage105/migrations"
for migration_file in "$ROOT"/migrations/*.sql; do
  migration_name=$(basename "$migration_file")
  if (( 10#${migration_name%%_*} < 106 )); then cp "$migration_file" "$stage105/migrations/"; fi
done
# Migration 105 removes what the Realtime service left behind: give it schemas, a partitioned table, a function, a
# tenant row and a second publication to remove (tests/realtime_fixture_105.sql).
mig_psql < "$ROOT/tests/realtime_fixture_105.sql"
# Migration 105 must refuse, and change nothing, while an object outside the Realtime schemas depends on one inside
# them. So the probe has something to refuse on, the migrations before 105 are applied first.
stage104=$(mktemp -d "${TMPDIR:-/tmp}/warehouse-stage104.XXXXXX")
mkdir "$stage104/migrations"
for migration_file in "$ROOT"/migrations/*.sql; do
  migration_name=$(basename "$migration_file")
  if (( 10#${migration_name%%_*} < 105 )); then cp "$migration_file" "$stage104/migrations/"; fi
done
plan_of "$stage104" | mig_psql
rm -rf "$stage104"
mig_psql -c 'CREATE VIEW public.mig105_probe AS SELECT id FROM realtime.messages'
if err=$({ echo 'BEGIN;'; cat "$ROOT/migrations/00000000000105_remove_realtime.sql"; echo 'ROLLBACK;'; } | mig_psql 2>&1 >/dev/null); then
  echo 'Migration 105 must refuse while a view outside the Realtime schemas reads realtime.messages.' >&2; exit 1; fi
[[ "$err" == *'depends on an object inside them, so they are not dropped: rule _RETURN on view mig105_probe'* ]] || { echo "Migration 105 refused, but not for the probe view; it said: $err" >&2; exit 1; }
[[ "$(mig_psql -At -c "SELECT (SELECT count(*) FROM pg_publication WHERE pubname IN ('supabase_realtime', 'supabase_realtime_messages_publication')) || ',' || (SELECT count(*) FROM pg_class WHERE oid IN ('public.orders'::regclass, 'public.sensor_latest'::regclass) AND relreplident = 'f') || ',' || (to_regnamespace('realtime') IS NOT NULL)::text || ',' || (to_regnamespace('_realtime') IS NOT NULL)::text")" == '2,2,true,true' ]] || {
  echo 'A refused migration 105 changed the database.' >&2; exit 1; }
mig_psql -c 'DROP VIEW public.mig105_probe'
for pass in 1 2; do
  echo "Migration ledger pass $pass up to 105 (second pass must skip unchanged files)"
  plan_of "$stage105" | mig_psql
done
rm -rf "$stage105"
# Migration 108 replaces pgjwt's extensions.sign by warehouse_security.jwt_sign_hs256 and drops pgjwt. While pgjwt still
# exists (the database stands at 105), the function block marked in the migration is created under another name and
# compared with extensions.sign for many payloads and secrets (tests/jwt_sign_108_before.sql); the probe is then dropped.
jwt_block=$(sed -n '/^-- BEGIN jwt_sign_hs256$/,/^-- END jwt_sign_hs256$/p' "$ROOT/migrations/00000000000108_jwt_sign_without_pgjwt.sql" \
  | sed 's/jwt_sign_hs256(p_payload/jwt_sign_hs256_probe108(p_payload/')
[[ "$jwt_block" == *'CREATE OR REPLACE FUNCTION warehouse_security.jwt_sign_hs256_probe108('* ]] || { echo 'The jwt_sign_hs256 block of migration 108 was not found.' >&2; exit 1; }
printf '%s\n' "$jwt_block" | mig_psql
jwt_notice=$(mig_psql -v fn=jwt_sign_hs256_probe108 2>&1 < "$ROOT/tests/jwt_sign_108_before.sql") || { echo "$jwt_notice" >&2; exit 1; }
grep -q '27 token pairs identical to pgjwt' <<< "$jwt_notice" || { echo "$jwt_notice" >&2; echo 'The pgjwt equality test did not report 27 identical token pairs.' >&2; exit 1; }
echo "$jwt_notice" | grep 'jwt_sign_108_before:'
mig_psql -c 'DROP FUNCTION warehouse_security.jwt_sign_hs256_probe108(json, text)'
parity_old=$(mig_psql -At < "$ROOT/tests/invoice_list_parity.sql")
[[ "$(printf '%s\n' "$parity_old" | wc -l)" -ge 150 && "$(printf '%s\n' "$parity_old" | grep -c 'sort total desc')" -ge 3 ]] || {
  echo 'The invoice list parity run before migration 106 produced too few answers.' >&2; exit 1; }
# Migration 106 must refuse, and change nothing, while the cron table holds a job that is not the list refresh.
mig_psql -At -c "SELECT cron.schedule('mig106_probe', '0 0 1 1 *', 'SELECT 1')" -c "SELECT cron.schedule('0 0 1 1 *', 'SELECT 2')" >/dev/null
if err=$({ echo 'BEGIN;'; cat "$ROOT/migrations/00000000000106_lists_read_tables.sql"; echo 'ROLLBACK;'; } | mig_psql 2>&1 >/dev/null); then
  echo 'Migration 106 must refuse while another pg_cron job exists.' >&2; exit 1; fi
[[ "$err" == *'jobs that are not the list refresh: mig106_probe (job '*'(no name) (job '* ]] || { echo "Migration 106 refused, but not for the foreign job; it said: $err" >&2; exit 1; }
[[ "$(mig_psql -At -c "SELECT count(*) FROM pg_extension WHERE extname = 'pg_cron'" -c "SELECT count(*) FROM pg_matviews WHERE matviewname = 'mv_invoice_list'")" = $'1\n1' ]] || {
  echo 'A refused migration 106 changed the database.' >&2; exit 1; }
mig_psql -At -c "SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname IS NULL OR jobname = 'mig106_probe'" >/dev/null
for pass in 1 2; do
  echo "Migration ledger pass $pass with 106 (second pass must skip unchanged files)"
  plan_of "$ROOT" | mig_psql
done
parity_new=$(mig_psql -At < "$ROOT/tests/invoice_list_parity.sql")
if [[ "$parity_new" != "$parity_old" ]]; then
  diff <(printf '%s\n' "$parity_old") <(printf '%s\n' "$parity_new") | cut -c1-300 | head -20 >&2
  echo 'get_invoices_list answers differ between the old (view) and the new (tables) function.' >&2; exit 1
fi
echo "get_invoices_list: $(printf '%s\n' "$parity_new" | wc -l) answers identical before and after migration 106."
test_files=(
  "$ROOT/tests/security_baseline.sql" "$ROOT/tests/operator_auth.sql"
  "$ROOT/tests/invoice_duration.sql" "$ROOT/tests/core_pilot.sql"
  "$ROOT/tests/storage_policy_fixture.sql"
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
  "$ROOT/tests/sensor_ingest.sql"
  "$ROOT/tests/item_rate_changes.sql" "$ROOT/tests/enrollment_approve_role.sql" "$ROOT/tests/service_accounts.sql"
  "$ROOT/tests/backlog_80.sql" "$ROOT/tests/open_items_82.sql" "$ROOT/tests/grn_deactivated_83.sql" "$ROOT/tests/grn_move_deactivated_84.sql" "$ROOT/tests/standard_rate.sql" "$ROOT/tests/grn_rates.sql" "$ROOT/tests/grn_item_rates_88.sql" "$ROOT/tests/staff_pricing_90.sql"
  "$ROOT/tests/list_refresh_removed_106.sql" "$ROOT/tests/invoice_list_live.sql"
  "$ROOT/tests/realtime_removed_105.sql"
  "$ROOT/tests/unused_extensions_absent.sql" "$ROOT/tests/fingerprint_collation.sql" "$ROOT/tests/jwt_sign_108.sql"
  "$ROOT/tests/catalog_receipt_width.sql" "$ROOT/tests/central_refusal_no_write.sql"
  "$ROOT/tests/grn_receipt_pages_98.sql" "$ROOT/tests/customer_dispatch_items_order_99.sql"
  "$ROOT/tests/grn_heavy_dispatch.sql"
  "$ROOT/tests/report_stock_ist_day.sql" "$ROOT/tests/report_dispatch_weight.sql" "$ROOT/tests/report_grn_weight.sql"
  "$ROOT/tests/report_grn_invoices.sql"
)
for test_sql in "${test_files[@]}"; do
  docker exec -i -e PGPASSWORD=disposable-test-database-only "$container" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < "$test_sql"
done

# The bucket customer-images (no longer created) is removed by configure-storage.sql while it is empty,
# and configure stops, deleting nothing, while it holds a file.
legacy_psql() { docker exec -i -e PGPASSWORD=disposable-test-database-only "$container" psql -X -qAt -U supabase_admin -d postgres -v ON_ERROR_STOP=1 "$@"; }
# The image's Storage schema is older than the Storage release in use (v1.80.2), which guards storage.buckets
# with a statement trigger that refuses every DELETE unless storage.allow_delete_query is 'true'. Create the same
# function and trigger here (function body copied from a v1.80.2 database), so a plain DELETE fails as it does live.
legacy_psql >/dev/null <<'SQL'
CREATE OR REPLACE FUNCTION storage.protect_delete() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    -- Check if storage.allow_delete_query is set to 'true'
    IF COALESCE(current_setting('storage.allow_delete_query', true), 'false') != 'true' THEN
        RAISE EXCEPTION 'Direct deletion from storage tables is not allowed. Use the Storage API instead.'
            USING HINT = 'This prevents accidental data loss from orphaned objects.',
                  ERRCODE = '42501';
    END IF;
    RETURN NULL;
END;
$function$;
DROP TRIGGER IF EXISTS protect_buckets_delete ON storage.buckets;
CREATE TRIGGER protect_buckets_delete BEFORE DELETE ON storage.buckets FOR EACH STATEMENT EXECUTE FUNCTION storage.protect_delete();
SQL
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

# Migrations 93 and 103 on an install that still holds what the template and the image used to install.
# Migration 93 (TW-BE-004) locked down pg_net; migration 103 removed pg_net, http, pg_graphql and supabase_vault,
# so the database here has none of them. Both must be harmless on such a database, and migration 103 must also
# remove them from one that still has them. The block below rebuilds the old state (pg_net with its schema
# and webhook set-up, the extension http, the role supabase_functions_admin, the three event triggers of the
# image) after all migrations, replays 93 and 103 on it, and the absence test must then pass again.
pg_net_psql() { docker exec -i -e PGPASSWORD=disposable-test-database-only "$container" psql -X -qAt -U supabase_admin -d postgres -v ON_ERROR_STOP=1 "$@"; }
unused_absent() { docker exec -i -e PGPASSWORD=disposable-test-database-only "$container" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < "$ROOT/tests/unused_extensions_absent.sql"; }
# 93 on a database without pg_net: nothing to do, and it does not bring the schema back.
no_net=$({ echo 'BEGIN;'
  cat "$ROOT/migrations/00000000000093_pg_net_least_privilege.sql"
  echo "SELECT CASE WHEN to_regnamespace('net') IS NULL THEN 'no-op' ELSE 'net came back' END;"
  echo 'ROLLBACK;'; } | pg_net_psql)
[[ "${no_net##*$'\n'}" = no-op ]] || { echo 'Migration 93 must do nothing, without failing, where the schema net does not exist.' >&2; exit 1; }
# 103 a second time, on a database that already lost everything: nothing to drop, no failure.
{ echo 'BEGIN;'; cat "$ROOT/migrations/00000000000103_drop_unused_extensions.sql"; echo 'ROLLBACK;'; } | pg_net_psql >/dev/null
# The old state, rebuilt.
pg_net_psql >/dev/null <<'SQL'
CREATE EXTENSION http SCHEMA public;
CREATE EXTENSION pg_net SCHEMA extensions;
CREATE SCHEMA graphql_public;
CREATE EXTENSION pg_graphql;
-- The wrapper outside the extension, as a restore leaves it.
CREATE OR REPLACE FUNCTION graphql_public.graphql("operationName" text DEFAULT NULL, query text DEFAULT NULL, variables jsonb DEFAULT NULL, extensions jsonb DEFAULT NULL)
  RETURNS jsonb LANGUAGE sql AS $$ SELECT graphql.resolve(query := query) $$;
CREATE EXTENSION supabase_vault;
CREATE ROLE supabase_functions_admin NOINHERIT CREATEROLE NOLOGIN;
CREATE SCHEMA supabase_functions AUTHORIZATION supabase_admin;
CREATE TABLE supabase_functions.hooks (id bigserial PRIMARY KEY, hook_table_id integer NOT NULL, hook_name text NOT NULL);
CREATE TABLE supabase_functions.migrations (version text PRIMARY KEY);
ALTER TABLE supabase_functions.hooks OWNER TO supabase_functions_admin;
CREATE FUNCTION supabase_functions.http_request() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$ BEGIN RETURN NEW; END $$;
ALTER FUNCTION supabase_functions.http_request() OWNER TO supabase_functions_admin;
GRANT USAGE ON SCHEMA supabase_functions TO supabase_functions_admin;
-- The three event triggers of the image, with its function bodies (read from the pinned image), created last so
-- that building the old state does not fire them. issue_graphql_placeholder is the one that would put a stand-in
-- graphql function back when pg_graphql is dropped, so the order of migration 103 is exercised.
CREATE OR REPLACE FUNCTION extensions.grant_pg_net_access() RETURNS event_trigger LANGUAGE plpgsql AS $function$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_event_trigger_ddl_commands() AS ev JOIN pg_extension AS ext ON ev.objid = ext.oid WHERE ext.extname = 'pg_net'
  ) THEN
    GRANT USAGE ON SCHEMA net TO supabase_functions_admin, postgres, service_role;
  END IF;
END;
$function$;
CREATE OR REPLACE FUNCTION extensions.grant_pg_graphql_access() RETURNS event_trigger LANGUAGE plpgsql AS $function$
DECLARE
    func_is_graphql_resolve bool;
BEGIN
    func_is_graphql_resolve = (
        SELECT n.proname = 'resolve'
        FROM pg_event_trigger_ddl_commands() AS ev
        LEFT JOIN pg_catalog.pg_proc AS n
        ON ev.objid = n.oid
    );
    IF func_is_graphql_resolve THEN
        DROP FUNCTION IF EXISTS graphql_public.graphql;
        create or replace function graphql_public.graphql("operationName" text default null, query text default null, variables jsonb default null, extensions jsonb default null)
            returns jsonb language sql as $$ select graphql.resolve(query := query, variables := coalesce(variables, '{}'), "operationName" := "operationName", extensions := extensions); $$;
        grant usage on schema graphql to postgres, anon, authenticated, service_role;
        grant usage on schema graphql_public to postgres with grant option;
    END IF;
END;
$function$;
CREATE OR REPLACE FUNCTION extensions.set_graphql_placeholder() RETURNS event_trigger LANGUAGE plpgsql AS $function$
    DECLARE
    graphql_is_dropped bool;
    BEGIN
    graphql_is_dropped = (
        SELECT ev.schema_name = 'graphql_public'
        FROM pg_event_trigger_dropped_objects() AS ev
        WHERE ev.schema_name = 'graphql_public'
    );
    IF graphql_is_dropped THEN
        create or replace function graphql_public.graphql("operationName" text default null, query text default null, variables jsonb default null, extensions jsonb default null)
            returns jsonb language plpgsql as $$ BEGIN RETURN jsonb_build_object('errors', jsonb_build_array(jsonb_build_object('message', 'pg_graphql extension is not enabled.'))); END; $$;
    END IF;
    END;
$function$;
CREATE EVENT TRIGGER issue_pg_net_access ON ddl_command_end WHEN TAG IN ('CREATE EXTENSION') EXECUTE FUNCTION extensions.grant_pg_net_access();
CREATE EVENT TRIGGER issue_pg_graphql_access ON ddl_command_end WHEN TAG IN ('CREATE FUNCTION') EXECUTE FUNCTION extensions.grant_pg_graphql_access();
CREATE EVENT TRIGGER issue_graphql_placeholder ON sql_drop WHEN TAG IN ('DROP EXTENSION') EXECUTE FUNCTION extensions.set_graphql_placeholder();
SQL
[[ "$(pg_net_psql -c "SELECT count(*) FROM pg_event_trigger WHERE evtname IN ('issue_pg_net_access','issue_pg_graphql_access','issue_graphql_placeholder')")" = 3 ]] || {
  echo 'The test could not rebuild the three event triggers of the image.' >&2; exit 1; }
[[ "$(pg_net_psql -c "SELECT count(*) FROM pg_extension WHERE extname IN ('http','pg_net','pg_graphql','supabase_vault')")" = 4 ]] || {
  echo 'The test could not rebuild the extensions that migration 103 removes.' >&2; exit 1; }
# Migration 103 must refuse, with the message that says why, and change nothing, while something still uses what it removes.
migration_103_refuses() {
  local expected=$1 err
  if err=$(pg_net_psql < "$ROOT/migrations/00000000000103_drop_unused_extensions.sql" 2>&1 >/dev/null); then
    echo "Migration 103 must refuse: $expected" >&2; exit 1; fi
  [[ "$err" == *"$expected"* ]] || { echo "Migration 103 refused, but not with the expected message ($expected); it said: $err" >&2; exit 1; }
  [[ "$(pg_net_psql -c "SELECT count(*) FROM pg_extension WHERE extname IN ('http','pg_net','pg_graphql','supabase_vault')")" = 4 ]] || {
    echo 'A refused migration 103 changed the database.' >&2; exit 1; }
  [[ "$(pg_net_psql -c "SELECT count(*) FROM pg_event_trigger WHERE evtname IN ('issue_pg_net_access','issue_pg_graphql_access','issue_graphql_placeholder')")" = 3 ]] || {
    echo 'A refused migration 103 dropped an event trigger.' >&2; exit 1; }
}
# A webhook trigger that still calls supabase_functions.http_request().
pg_net_psql >/dev/null -c 'CREATE TABLE public.mig103_probe (id int)' -c 'CREATE TRIGGER mig103_hook AFTER INSERT ON public.mig103_probe FOR EACH ROW EXECUTE FUNCTION supabase_functions.http_request()'
migration_103_refuses 'still calls supabase_functions.http_request()'
pg_net_psql >/dev/null -c 'DROP TABLE public.mig103_probe'
# A secret in the vault would be deleted with the extension.
pg_net_psql >/dev/null -c "INSERT INTO vault.secrets (secret, name) VALUES ('mig103', 'mig103')"
migration_103_refuses 'The vault still holds secrets'
pg_net_psql >/dev/null -c "DELETE FROM vault.secrets WHERE name = 'mig103'"
# A pg_cron job that calls net.* or http(...), whichever way it is written.
cron_made=false
if [[ "$(pg_net_psql -c "SELECT to_regprocedure('cron.schedule(text,text,text)') IS NOT NULL")" != t ]]; then
  # No pg_cron in this database: a stand-in table with the two columns the migration reads.
  pg_net_psql >/dev/null -c 'CREATE SCHEMA cron' -c 'CREATE TABLE cron.job (jobid serial PRIMARY KEY, jobname text, command text)'; cron_made=true
fi
add_cron_job() {
  if [[ "$cron_made" == true ]]; then pg_net_psql >/dev/null -c "INSERT INTO cron.job (jobname, command) VALUES ('mig103_probe', \$cron\$$1\$cron\$)"
  else pg_net_psql >/dev/null -c "SELECT cron.schedule('mig103_probe', '0 0 1 1 *', \$cron\$$1\$cron\$)"; fi
}
remove_cron_job() { pg_net_psql >/dev/null -c "DELETE FROM cron.job WHERE jobname = 'mig103_probe'"; }
for command in "SELECT net.http_post('http://example.invalid')" "select  HTTP_POST ( 'a', 'b', 'c' )" "SELECT http('x')"; do
  add_cron_job "$command"
  migration_103_refuses 'A scheduled pg_cron job still calls'
  remove_cron_job
done
# A job that calls neither does not stop it, even if a word only ends in "net." (cabinet.).
add_cron_job "SELECT 1; SELECT 'cabinet.'"
pg_net_psql < "$ROOT/migrations/00000000000093_pg_net_least_privilege.sql"
pg_net_psql < "$ROOT/migrations/00000000000103_drop_unused_extensions.sql"
unused_absent
# The unrelated job was not stopped by the refusal and is still there; the stand-in cron table, if made, goes.
[[ "$(pg_net_psql -c "SELECT count(*) FROM cron.job WHERE jobname = 'mig103_probe'")" = 1 ]] || { echo 'Migration 103 touched a cron job.' >&2; exit 1; }
remove_cron_job
if [[ "$cron_made" == true ]]; then pg_net_psql >/dev/null -c 'DROP SCHEMA cron CASCADE'; fi
# The graphql stand-in function must not have come back (issue_graphql_placeholder was dropped first).
[[ "$(pg_net_psql -c "SELECT count(*) FROM pg_proc WHERE proname = 'graphql' AND pronamespace::regnamespace::text = 'graphql_public'")" = 0 ]] || {
  echo 'The graphql placeholder came back after migration 103.' >&2; exit 1; }
# A second run, where there is nothing left to do, changes nothing.
pg_net_psql < "$ROOT/migrations/00000000000103_drop_unused_extensions.sql"
unused_absent
# A role that still owns something in another database is kept: the migration must not break, and says why.
pg_net_psql >/dev/null -c 'CREATE ROLE supabase_functions_admin NOLOGIN' -c 'CREATE DATABASE mig103_other OWNER supabase_functions_admin'
pg_net_psql < "$ROOT/migrations/00000000000103_drop_unused_extensions.sql"
[[ "$(pg_net_psql -c "SELECT count(*) FROM pg_roles WHERE rolname = 'supabase_functions_admin'")" = 1 ]] || {
  echo 'Migration 103 dropped a role that owns a database.' >&2; exit 1; }
pg_net_psql >/dev/null -c 'DROP DATABASE mig103_other' -c 'DROP ROLE supabase_functions_admin'
# A role that owns an object in this database is kept as well, with a NOTICE that says so.
pg_net_psql >/dev/null -c 'CREATE ROLE supabase_functions_admin NOLOGIN' -c 'CREATE TABLE public.mig103_owned (id int)' -c 'ALTER TABLE public.mig103_owned OWNER TO supabase_functions_admin'
notice=$(pg_net_psql < "$ROOT/migrations/00000000000103_drop_unused_extensions.sql" 2>&1 >/dev/null)
[[ "$notice" == *'supabase_functions_admin is kept: it owns 1 object(s) in this database'* ]] || {
  echo "Migration 103 must keep a role that owns an object here and say so; it said: $notice" >&2; exit 1; }
[[ "$(pg_net_psql -c "SELECT count(*) FROM pg_roles WHERE rolname = 'supabase_functions_admin'")" = 1 ]] || {
  echo 'Migration 103 dropped a role that owns a table.' >&2; exit 1; }
pg_net_psql >/dev/null -c 'DROP TABLE public.mig103_owned' -c 'DROP ROLE supabase_functions_admin'
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
# Migration 92 on a database that holds the setting at database level and for three kinds of role setting.
plant_secret_settings
jwt_sql < "$ROOT/migrations/00000000000092_jwt_secret_guc.sql"
[[ "$(anon_secret_setting)" = '' && "$(secret_settings_held)" = 0 ]] || {
  echo 'Migration 92 must remove the signing secret setting from the database and from every role.' >&2; exit 1; }
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

# Migration 107: the monitoring role does not exist; a role given back by hand (with a login, a password, a pg_monitor
# membership and a grant, as an old backup or an old install would have it) is dropped again when the migration file runs
# again (migration 94 stays as history), and running it on a database without the role changes nothing.
monitoring_state="SELECT count(*) FROM pg_roles WHERE rolname = 'warehouse_monitoring'"
[[ "$(mig_psql -At -c "$monitoring_state")" == '0' ]] || { echo 'Migration 107 left the role warehouse_monitoring.' >&2; exit 1; }
mig_psql -c "CREATE ROLE warehouse_monitoring LOGIN PASSWORD 'old-install-monitoring-password'; GRANT pg_monitor TO warehouse_monitoring; GRANT USAGE ON SCHEMA public TO warehouse_monitoring"
mig_psql < "$ROOT/migrations/00000000000107_drop_monitoring_role.sql"
[[ "$(mig_psql -At -c "$monitoring_state")" == '0' ]] || { echo 'Migration 107 did not drop the role again.' >&2; exit 1; }
mig_psql < "$ROOT/migrations/00000000000107_drop_monitoring_role.sql"
[[ "$(mig_psql -At -c "$monitoring_state")" == '0' ]] || { echo 'Migration 107 is not idempotent.' >&2; exit 1; }

# scripts/configure-db-roles.sql (TW-BE-002, migration 94): through the prelude of
# scripts/db-roles.mjs, as scripts/db-roles.sh sends it. Each login stores exactly the
# SCRAM verifier it was given (never a password); a rerun applies again; a missing or
# plaintext value changes nothing; a monitoring role brought back with a login (what a restore
# of an old install replays) is dropped again. Logins themselves are proven over the network by
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
# After a restore the image has created supabase_auth_admin with a login (a backup holds only role names and the
# ledger skips 104); configure-db-roles.sql (and migration 104) take the login and the password away.
roles_sql "ALTER ROLE supabase_auth_admin LOGIN PASSWORD 'old-install-auth-password'" >/dev/null
apply_db_roles <<< "$prelude"
[[ "$(roles_sql "SELECT rolcanlogin::text || ' ' || (rolpassword IS NULL)::text FROM pg_authid WHERE rolname = 'supabase_auth_admin'")" == 'false true' ]] || {
  echo 'configure-db-roles.sql left supabase_auth_admin able to log in.' >&2; exit 1; }
roles_sql "CREATE ROLE warehouse_monitoring LOGIN PASSWORD 'old-install-monitoring-password'; GRANT pg_monitor TO warehouse_monitoring; GRANT USAGE ON SCHEMA public TO warehouse_monitoring" >/dev/null
apply_db_roles <<< "$prelude"
[[ "$(roles_sql "$monitoring_state")" == '0' ]] || {
  echo 'configure-db-roles.sql left the role warehouse_monitoring.' >&2; exit 1; }
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

# Migration 42: its closing check stays strict for the nineteen business tables
# and lets an operator's own table in `public` through.
bash "$ROOT/tests/direct_write_guard_scope.sh" "$container"

# Migration 48: the author-name backfill of invoice_discount_history, on rows
# as an installation that had discounts before the upgrade holds them.
bash "$ROOT/tests/history_author_backfill.sh" "$container"

# scripts/retention.sh: every statement it sends is one this database accepts.
bash "$ROOT/tests/retention_queries.sh" "$container"

# Applied migration history is immutable: changing an old file must fail closed.
scratch=$(mktemp -d "${TMPDIR:-/tmp}/warehouse-mismatch.XXXXXX")
trap 'rm -rf "$scratch"; cleanup' EXIT
cp -a "$ROOT/migrations" "$ROOT/scripts" "$scratch/"
printf '\n-- deliberate checksum mismatch for test\n' >> "$scratch/migrations/00000000000001_seed_data.sql"
if node "$scratch/scripts/migration-plan.mjs" 2>/dev/null | docker exec -i -e PGPASSWORD=disposable-test-database-only "$container" \
  psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 >/dev/null 2>&1; then
  echo 'Changed applied migration was incorrectly accepted.' >&2
  exit 1
fi
migration_files=("$ROOT"/migrations/*.sql)
[[ "$(docker exec -e PGPASSWORD=disposable-test-database-only "$container" psql -X -qAt -U supabase_admin -d postgres -c 'SELECT count(*) FROM warehouse_migrations.applied')" = "${#migration_files[@]}" ]] || {
  echo 'Migration mismatch changed the ledger.' >&2; exit 1;
}

# Backup verification on real containers: this database is dumped into a signed
# backup and replayed by scripts/verify-restore.sh, once with a session attached to
# template1 and once with the disk-backed data directory.
bash "$ROOT/tests/verify-restore-drill.sh" "$container"
echo 'Migration reruns, checksum mismatch rejection, retention, and operator and central auth configuration passed.'

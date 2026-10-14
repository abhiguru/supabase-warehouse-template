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
docker run -d --name "$container" --label purpose=warehouse-migration-test \
  --network none --memory 1g --cpus 1 \
  --tmpfs /var/lib/postgresql/data:rw,size=768m \
  -e JWT_SECRET=isolated-test-secret-not-for-any-deployment-12345 -e JWT_EXP=3600 \
  -e AUTH_MODE=operator -e APP_ENV=production \
  -e POSTGRES_PASSWORD=disposable-test-database-only \
  supabase/postgres:15.8.1.135@sha256:ee680a0afebe1a5e95614fdea671c01a264e58f52de6c429c17a394f46dec2c6 >/dev/null
created=true
ready=false
for ((i=0; i<60; i++)); do
  if docker exec "$container" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1; then ready=true; break; fi
  sleep 2
done
[[ "$ready" == true ]] || { echo 'Test database did not start' >&2; exit 1; }
for pass in 1 2; do
  echo "Migration ledger pass $pass (second pass must skip unchanged files)"
  node "$ROOT/scripts/migration-plan.mjs" |
    docker exec -i -e PGPASSWORD=disposable-test-database-only "$container" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1
done
test_files=(
  "$ROOT/tests/security_baseline.sql" "$ROOT/tests/operator_auth.sql"
  "$ROOT/tests/invoice_duration.sql" "$ROOT/tests/core_pilot.sql"
  "$ROOT/tests/storage_policy_fixture.sql"
  "$ROOT/scripts/configure-storage.sql" "$ROOT/scripts/configure-storage.sql"
  "$ROOT/tests/staff_grn_access.sql" "$ROOT/tests/staff_dispatch_invoice_access.sql"
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
  "$ROOT/tests/backlog_80.sql" "$ROOT/tests/open_items_82.sql"
  "$ROOT/tests/report_stock_ist_day.sql" "$ROOT/tests/report_dispatch_weight.sql" "$ROOT/tests/report_grn_weight.sql"
  "$ROOT/tests/report_grn_invoices.sql"
)
for test_sql in "${test_files[@]}"; do
  docker exec -i -e PGPASSWORD=disposable-test-database-only "$container" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < "$test_sql"
done
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
if node "$scratch/scripts/migration-plan.mjs" | docker exec -i -e PGPASSWORD=disposable-test-database-only "$container" \
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

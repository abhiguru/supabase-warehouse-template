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
  -e POSTGRES_PASSWORD=disposable-test-database-only supabase/postgres:15.8.1.060 >/dev/null
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

# Migration 26: a GRN edit must survive a concurrent writer holding the refresh lock.
bash "$ROOT/tests/grn_edit_lock_order.sh" "$container"

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
echo 'Migration reruns, checksum mismatch rejection, retention, and operator auth configuration passed.'

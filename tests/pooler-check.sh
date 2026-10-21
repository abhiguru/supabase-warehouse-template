#!/usr/bin/env bash
# The pooler check (npm run test:pooler): starts the pooler profile and proves sessions, the transaction pool and the refusal of a
# wrong password. Sourced (tests/pooler-readiness.test.mjs), it only defines wait_for_pooler_query.

# Supavisor's HTTP health endpoint can precede its PostgreSQL listeners.
# Success still requires the real authenticated query, never health alone.
wait_for_pooler_query() {
  local port="$1" attempt result
  shift
  for ((attempt=1; attempt<=12; attempt++)); do
    if result=$("$@" 2>/dev/null) && [[ "$result" == 1 ]]; then
      return 0
    fi
    if ((attempt < 12)); then sleep 2; fi
  done
  echo "Pooler authenticated query did not become ready on port $port after 12 attempts." >&2
  return 1
}
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
# Starts the pooler profile: must not interleave with a backup, which stops supavisor.
# shellcheck source=scripts/operator-lock.sh
. "$ROOT/scripts/operator-lock.sh"
state="$(operator_state)"
operator_lock "$state"
node "$ROOT/scripts/doctor.mjs" --preflight
# `up supavisor` converges db too: a PostgreSQL 15 database must go through the baseline reload instead.
bash "$ROOT/scripts/db-version-preflight.sh"
if ! compose --profile pooler up -d --wait --wait-timeout 120 supavisor; then
  node "$ROOT/scripts/service-diagnostics.mjs"
  exit 1
fi
# Read only the non-secret tenant identifier; the password stays inside the DB container. The probe
# signs in as the pool user pgbouncer (a non-superuser: pgbouncer.get_auth never returns a superuser's
# verifier, so supabase_admin cannot sign in through the pooler).
tenant=$(node --input-type=module -e 'const {readEnv,operatorEnvPath}=await import(process.argv[1]); const tenant=readEnv(operatorEnvPath()).POOLER_TENANT_ID; if(!tenant || !/^[a-zA-Z0-9_-]+$/.test(tenant)) process.exit(1); console.log(tenant);' "$ROOT/scripts/doctor-common.mjs")
for port in 5432 6543; do
  wait_for_pooler_query "$port" compose exec -T db sh -c 'export PGCONNECT_TIMEOUT=3; PGPASSWORD="$DB_PASSWORD_POOLER" psql -X -h supavisor -p "$1" -U "$2" -d postgres -v ON_ERROR_STOP=1 -Atc "SELECT 1"' sh "$port" "pgbouncer.$tenant"
  if compose exec -T db sh -c 'export PGCONNECT_TIMEOUT=10; PGPASSWORD=warehouse-invalid-probe psql -X -h supavisor -p "$1" -U "$2" -d postgres -v ON_ERROR_STOP=1 -Atc "SELECT 1"' sh "$port" "pgbouncer.$tenant" >/dev/null 2>&1; then
    echo "Pooler accepted an invalid password on port $port" >&2; exit 1
  fi
done
echo 'Pooler session/transaction queries and invalid-password rejection passed.'

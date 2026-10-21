#!/usr/bin/env bash
# The pooler check (npm run test:pooler): turns the pooler on (bash scripts/pooler.sh on, the operator step) and proves sessions, the transaction pool and the refusal of a
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
# Turns the pooler on: must not interleave with a backup, which stops supavisor.
# shellcheck source=scripts/operator-lock.sh
. "$ROOT/scripts/operator-lock.sh"
state="$(operator_state)"
operator_lock "$state"
node "$ROOT/scripts/doctor.mjs" --preflight
# The operator step: secrets, role pgbouncer, schema pgbouncer, database _supabase, then the supavisor service (it holds the
# operator lock already, which pooler.sh inherits). Repeating it is harmless.
if ! bash "$ROOT/scripts/pooler.sh" on; then
  node "$ROOT/scripts/service-diagnostics.mjs"
  exit 1
fi
# Read the non-secret tenant identifier; the pool user's password reaches the probe on standard input only (never an
# argument or the environment of a docker command). The probe
# signs in as the pool user pgbouncer (a non-superuser: pgbouncer.get_auth never returns a superuser's
# verifier, so supabase_admin cannot sign in through the pooler).
tenant=$(node --input-type=module -e 'const {readEnv,operatorEnvPath}=await import(process.argv[1]); const tenant=readEnv(operatorEnvPath()).POOLER_TENANT_ID; if(!tenant || !/^[a-zA-Z0-9_-]+$/.test(tenant)) process.exit(1); console.log(tenant);' "$ROOT/scripts/doctor-common.mjs")
pooler_password=$(node --input-type=module -e 'const {readEnv,operatorEnvPath}=await import(process.argv[1]); const value=readEnv(operatorEnvPath()).DB_PASSWORD_POOLER; if(!value) process.exit(1); console.log(value);' "$ROOT/scripts/doctor-common.mjs")
pooler_query() {
  printf '%s\n' "$pooler_password" | compose exec -T db sh -c 'export PGCONNECT_TIMEOUT=3; IFS= read -r PGPASSWORD; export PGPASSWORD; psql -X -h supavisor -p "$1" -U "$2" -d postgres -v ON_ERROR_STOP=1 -Atc "SELECT 1"' sh "$1" "$2"
}
for port in 5432 6543; do
  wait_for_pooler_query "$port" pooler_query "$port" "pgbouncer.$tenant"
  if compose exec -T db sh -c 'export PGCONNECT_TIMEOUT=10; PGPASSWORD=warehouse-invalid-probe psql -X -h supavisor -p "$1" -U "$2" -d postgres -v ON_ERROR_STOP=1 -Atc "SELECT 1"' sh "$port" "pgbouncer.$tenant" >/dev/null 2>&1; then
    echo "Pooler accepted an invalid password on port $port" >&2; exit 1
  fi
done
echo 'Pooler session/transaction queries and invalid-password rejection passed.'

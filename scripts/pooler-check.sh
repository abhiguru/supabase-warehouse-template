#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
node "$ROOT/scripts/check-demo-config.mjs"
if ! compose --profile pooler up -d --wait --wait-timeout 120 supavisor; then
  node "$ROOT/scripts/service-diagnostics.mjs"
  exit 1
fi
# Read only the non-secret tenant identifier; the password stays inside the DB container.
tenant=$(node --input-type=module -e 'const {readEnv,root}=await import(process.argv[1]); const tenant=readEnv(`${root}/docker/.env`).POOLER_TENANT_ID; if(!tenant || !/^[a-zA-Z0-9_-]+$/.test(tenant)) process.exit(1); console.log(tenant);' "$ROOT/scripts/doctor-common.mjs")
for port in 5432 6543; do
  result=$(compose exec -T db sh -c 'export PGCONNECT_TIMEOUT=10; PGPASSWORD="$POSTGRES_PASSWORD" psql -X -h supavisor -p "$1" -U "$2" -d postgres -v ON_ERROR_STOP=1 -Atc "SELECT 1"' sh "$port" "postgres.$tenant")
  [[ "$result" == 1 ]] || { echo "Pooler query failed on port $port" >&2; exit 1; }
  if compose exec -T db sh -c 'export PGCONNECT_TIMEOUT=10; PGPASSWORD=warehouse-invalid-probe psql -X -h supavisor -p "$1" -U "$2" -d postgres -v ON_ERROR_STOP=1 -Atc "SELECT 1"' sh "$port" "postgres.$tenant" >/dev/null 2>&1; then
    echo "Pooler accepted an invalid password on port $port" >&2; exit 1
  fi
done
echo 'Pooler session/transaction queries and invalid-password rejection passed.'

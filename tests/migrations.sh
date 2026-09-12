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
  -e AUTH_MODE=demo -e APP_ENV=development \
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
for test_sql in "$ROOT/tests/security_baseline.sql" "$ROOT/tests/auth_and_access.sql"; do
  docker exec -i -e PGPASSWORD=disposable-test-database-only "$container" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < "$test_sql"
done
for pass in 1 2; do
  for configuration in "$ROOT/scripts/configure-auth.sql" "$ROOT/scripts/demo-seed.sql"; do
    docker exec -i -e PGPASSWORD=disposable-test-database-only "$container" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < "$configuration"
  done
done
echo 'Migration reruns, auth configuration, and demo seed reruns passed.'

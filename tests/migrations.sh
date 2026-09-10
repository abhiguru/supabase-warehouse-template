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
  --network none --memory 768m --cpus 1 \
  --tmpfs /var/lib/postgresql/data:rw,size=512m \
  -e POSTGRES_PASSWORD=disposable-test-database-only supabase/postgres:15.8.1.060 >/dev/null
created=true
ready=false
for ((i=0; i<60; i++)); do
  if docker exec "$container" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1; then ready=true; break; fi
  sleep 2
done
[[ "$ready" == true ]] || { echo 'Test database did not start' >&2; exit 1; }
for migration in "$ROOT"/migrations/*.sql; do
  echo "Testing $(basename "$migration")"
  docker exec -i "$container" psql -X -U postgres -d postgres --single-transaction -v ON_ERROR_STOP=1 < "$migration"
done
docker exec -i "$container" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 < "$ROOT/tests/security_baseline.sql"

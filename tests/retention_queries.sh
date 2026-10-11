#!/usr/bin/env bash
# Runs every SQL statement scripts/retention.sh sends through its query()
# helper against migrations.sh's disposable database. The script's own tests
# use a stand-in for docker, so a statement the database refuses (a wrong
# column name, a dropped function) would otherwise first show on a live stack.
set -euo pipefail
container="${1:?disposable test container name required}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PGPASSWORD=disposable-test-database-only
mapfile -t statements < <(grep -oP 'query "\K[^"]+' "$ROOT/scripts/retention.sh")
(( ${#statements[@]} >= 3 )) || { echo 'Expected the retention script to hold at least three queries.' >&2; exit 1; }
for statement in "${statements[@]}"; do
  docker exec -e PGPASSWORD "$container" psql -X -qAt -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -c "$statement" >/dev/null || {
    echo "The database refused a retention query: $statement" >&2; exit 1;
  }
done
echo "Retention queries (${#statements[@]}) are accepted by the migrated database."

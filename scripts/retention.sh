#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
query() { compose exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -c "$1"; }
case "${1:-preview}" in
  preview) apply=false ;;
  apply) apply=true ;;
  *) echo 'Usage: scripts/retention.sh [preview|apply]' >&2; exit 2 ;;
esac
. "$ROOT/scripts/operator-lock.sh"
state="$(operator_state)"
operator_lock "$state"
compose exec -T db psql -X -v ON_ERROR_STOP=1 -U supabase_admin -d postgres \
  -c "SELECT jsonb_pretty(warehouse_maintenance.run_database_retention(now(), $apply));"

# Generated PDFs older than the generated_documents policy. The database names
# them; the Storage API deletes them, because only that removes the file.
expired="$(mktemp)"
trap 'rm -f "$expired"' EXIT
days="$(query "SELECT days FROM warehouse_maintenance.retention_policy WHERE key='generated_documents'")"
query "SELECT name FROM warehouse_maintenance.expired_generated_documents(now()) AS name" > "$expired"
count="$(grep -c . "$expired" || true)"
echo "Generated documents older than $days days: $count"
if [[ "$apply" == true && "$count" -gt 0 ]]; then
  compose exec -T storage node -e "$(cat "$ROOT/scripts/remove-expired-documents.cjs")" < "$expired"
  remaining="$(query "SELECT count(*) FROM warehouse_maintenance.expired_generated_documents(now())")"
  if [[ "$remaining" != 0 ]]; then
    echo "$remaining generated documents older than $days days are still stored; run retention again." >&2
    exit 1
  fi
fi
if [[ "$apply" == true ]]; then
  echo 'Database retention applied and expired generated documents removed. Business records and stored image objects require an approved operator policy and are not deleted.'
else
  echo 'Preview only; no data changed.'
fi

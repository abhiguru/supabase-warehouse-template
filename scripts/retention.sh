#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
case "${1:-preview}" in
  preview) apply=false ;;
  apply) apply=true ;;
  *) echo 'Usage: scripts/retention.sh [preview|apply]' >&2; exit 2 ;;
esac
compose exec -T db psql -X -v ON_ERROR_STOP=1 -U supabase_admin -d postgres \
  -c "SELECT jsonb_pretty(warehouse_maintenance.run_database_retention(now(), $apply));"
if [[ "$apply" == true ]]; then
  echo 'Database retention applied. Business documents and stored image objects require an approved operator policy and are not deleted.'
else
  echo 'Preview only; no data changed.'
fi

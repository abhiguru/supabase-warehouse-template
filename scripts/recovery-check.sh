#!/usr/bin/env bash
# Restart the write/API path owned by this checkout and prove data/config survive.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
state="${WAREHOUSE_STATE_DIR:-}"
[[ "$state" == /* && -f "$state/config/compose.env" && -f "$state/public/instance.json" ]] || { echo 'Set WAREHOUSE_STATE_DIR to operator state.' >&2; exit 1; }
before_env=$(sha256sum "$state/config/compose.env" "$state/public/instance.json")
before_data=$(compose exec -T db psql -X -qAt -U supabase_admin -d postgres \
  -c "SELECT count(*)||':'||COALESCE(max(gr_no),'') FROM public.goodsreceived")

compose restart rest storage functions kong >/dev/null
healthy=false
for ((i=0; i<60; i++)); do
  if bash "$ROOT/health-check.sh" >/dev/null 2>&1; then healthy=true; break; fi
  sleep 2
done
[[ "$healthy" == true ]] || { bash "$ROOT/health-check.sh"; exit 1; }
after_env=$(sha256sum "$state/config/compose.env" "$state/public/instance.json")
after_data=$(compose exec -T db psql -X -qAt -U supabase_admin -d postgres \
  -c "SELECT count(*)||':'||COALESCE(max(gr_no),'') FROM public.goodsreceived")
[[ "$before_env" == "$after_env" ]] || { echo 'Configuration changed during restart.' >&2; exit 1; }
[[ "$before_data" == "$after_data" ]] || { echo 'Business data changed during restart.' >&2; exit 1; }
echo 'Owned service restart, health recovery, configuration preservation and data preservation passed.'

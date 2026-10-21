#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" != --operator ]]; then
  echo 'Use scripts/migrate.sh --operator (setup.sh runs it with the state directory chosen).' >&2
  exit 1
fi
# setup.sh and restore.sh run this under their own lock; run alone, it takes the lock.
# shellcheck source=scripts/operator-lock.sh
. "$ROOT/scripts/operator-lock.sh"
state="$(operator_state)"
operator_lock_or_inherited "$state"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
# All migrations share one database session and advisory lock. Changed applied files fail closed.
node "$ROOT/scripts/migration-plan.mjs" |
  compose exec -T db psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1

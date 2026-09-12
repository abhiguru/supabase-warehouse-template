#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$ROOT/scripts/check-readiness.sh" "$@"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
# All migrations share one database session and advisory lock. Changed applied files fail closed.
node "$ROOT/scripts/migration-plan.mjs" |
  compose exec -T db psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1

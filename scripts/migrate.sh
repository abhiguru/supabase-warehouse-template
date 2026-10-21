#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" != --operator ]]; then
  echo 'Use scripts/migrate.sh --operator [--through <migration file name>] (setup.sh runs it with the state directory chosen).' >&2
  exit 1
fi
shift
plan_args=()
if [[ $# -gt 0 ]]; then
  if [[ $# -ne 2 || "$1" != --through || -z "$2" ]]; then
    echo 'Usage: scripts/migrate.sh --operator [--through <migration file name>]' >&2
    exit 1
  fi
  plan_args=(--through "$2")
fi
# setup.sh and restore.sh run this under their own lock; run alone, it takes the lock.
# shellcheck source=scripts/operator-lock.sh
. "$ROOT/scripts/operator-lock.sh"
state="$(operator_state)"
operator_lock_or_inherited "$state"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
# All migrations share one database session and advisory lock. Changed applied files fail closed.
# --through stops the plan after the named file (the Baseline reload); an unknown name fails before the database is touched.
plan="$(node "$ROOT/scripts/migration-plan.mjs" ${plan_args[@]+"${plan_args[@]}"})"
printf '%s\n' "$plan" |
  compose exec -T db psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1

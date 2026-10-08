#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
node "$ROOT/scripts/load-smoke.mjs"
printf 'SELECT count(*) FROM public.feature_flags;\n' |
  compose exec -T db pgbench -n -c 10 -j 2 -T 10 -U supabase_admin -f - postgres
echo 'Read-only database load smoke passed: 10 clients for 10 seconds.'

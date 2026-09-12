#!/usr/bin/env bash
# New installations only. Existing configuration is never overwritten.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$ROOT/scripts/check-readiness.sh" "$@"
for command in docker node; do
  command -v "$command" >/dev/null || { echo "Missing prerequisite: $command" >&2; exit 1; }
done
node "$ROOT/scripts/configure.mjs" "$@"
node "$ROOT/scripts/check-demo-config.mjs"
bash "$ROOT/scripts/compose.sh" config --quiet
# Apply permissions and signing configuration before any API or Studio service starts.
bash "$ROOT/scripts/compose.sh" up -d --wait --wait-timeout 180 db
bash "$ROOT/scripts/migrate.sh" "$@"
bash "$ROOT/scripts/compose.sh" exec -T db psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < "$ROOT/scripts/configure-auth.sql"
bash "$ROOT/scripts/compose.sh" exec -T db psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < "$ROOT/scripts/demo-seed.sql"
bash "$ROOT/scripts/compose.sh" up -d --wait --wait-timeout 180
bash "$ROOT/scripts/compose.sh" exec -T db psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < "$ROOT/scripts/configure-storage.sql"
bash "$ROOT/health-check.sh"
echo 'Local demo started. Admin: 0000000001; customer: 0000000002; demo OTP: 123456. No SMS is sent.'

#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$ROOT/scripts/check-readiness.sh"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
# Each migration and its ledger row commit together. SQL errors stop setup.
compose exec -T db psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
CREATE SCHEMA IF NOT EXISTS warehouse_migrations;
REVOKE ALL ON SCHEMA warehouse_migrations FROM PUBLIC, anon, authenticated;
CREATE TABLE IF NOT EXISTS warehouse_migrations.applied (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now());
SQL
for migration in "$ROOT"/migrations/*.sql; do
  name=$(basename "$migration")
  [[ "$name" =~ ^[0-9]+_[a-z0-9_]+\.sql$ ]] || { echo "Invalid migration name" >&2; exit 1; }
  applied=$(compose exec -T db psql -X -U postgres -d postgres -At -v ON_ERROR_STOP=1 -c "SELECT count(*) FROM warehouse_migrations.applied WHERE name = '$name'")
  if [[ "$applied" == 1 ]]; then
    echo "Already applied: $name"; continue
  fi
  echo "Applying: $name"
  { printf 'BEGIN;\n'; sed -n '1,$p' "$migration"; printf '\nINSERT INTO warehouse_migrations.applied(name) VALUES (%s);\nCOMMIT;\n' "'$name'"; } |
    compose exec -T db psql -X -U postgres -d postgres -v ON_ERROR_STOP=1
done
compose exec -T db psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 -c "NOTIFY pgrst, 'reload schema';"

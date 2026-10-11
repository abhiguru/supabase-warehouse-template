#!/usr/bin/env bash
# Migration 42's closing check, run as written in the migration file, against
# migrations.sh's disposable container. It must look at the nineteen business
# tables and at nothing else:
#   1. the migrated database as it is passes;
#   2. an operator's own table in `public`, writable by `authenticated` and with
#      a FOR ALL policy, does not stop the upgrade;
#   3. a write policy added to a business table still stops it;
#   4. a write grant on a business table still stops it.
# Every case runs in a transaction that is rolled back.
# GUARD_MIGRATION names another copy of the migration to take the check from; it
# exists so the test can be shown to fail against an earlier version of the check.
set -euo pipefail
container="${1:?disposable test container name required}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
migration="${GUARD_MIGRATION:-$ROOT/migrations/00000000000042_direct_write_guard.sql}"
export PGPASSWORD=disposable-test-database-only
scratch=$(mktemp -d "${TMPDIR:-/tmp}/direct-write-scope.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

awk '/^DO \$verify\$/{inside=1} inside{print} /^END \$verify\$;/{inside=0}' "$migration" > "$scratch/verify.sql"
grep -q '^DO \$verify\$' "$scratch/verify.sql" && grep -q '^END \$verify\$;' "$scratch/verify.sql" || {
  echo "Migration 42's closing check was not found in $migration." >&2; exit 1;
}

# Runs the closing check after the given setup; prints psql's messages.
run_check() {
  { printf 'BEGIN;\n%s\n' "$1"; cat "$scratch/verify.sql"; printf '\nROLLBACK;\n'; } |
    docker exec -i -e PGPASSWORD "$container" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 2>&1
}
must_pass() {
  local label="$1" output
  if ! output=$(run_check "$2"); then
    echo "Migration 42's closing check refused: $label" >&2; echo "$output" >&2; exit 1
  fi
}
must_refuse() {
  local label="$1" expected="$3" output
  if output=$(run_check "$2"); then
    echo "Migration 42's closing check accepted: $label" >&2; exit 1
  fi
  grep -qF "$expected" <<<"$output" || {
    echo "Migration 42's closing check refused $label for another reason:" >&2; echo "$output" >&2; exit 1;
  }
}

operator_table="
CREATE TABLE public.operator_notes (id integer PRIMARY KEY, note text);
ALTER TABLE public.operator_notes ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.operator_notes TO authenticated;
CREATE POLICY operator_notes_all ON public.operator_notes FOR ALL TO authenticated USING (true) WITH CHECK (true);"

must_pass 'the migrated database as it is' ''
must_pass "an operator's own writable table in public" "$operator_table"
must_refuse 'a write policy on a business table' \
  "$operator_table
CREATE POLICY review_extra_write ON public.invoice FOR UPDATE TO authenticated USING (true);" \
  'Unexpected write policy on a business table: invoice.review_extra_write'
must_refuse 'a write grant on a business table' \
  "$operator_table
GRANT UPDATE ON public.dispatch TO authenticated;" \
  'authenticated still holds a direct write on: dispatch'

left=$(docker exec -e PGPASSWORD "$container" psql -X -qAt -U supabase_admin -d postgres \
  -c "SELECT to_regclass('public.operator_notes') IS NULL AND NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname='review_extra_write') AND NOT has_table_privilege('authenticated','public.dispatch','UPDATE')")
[[ "$left" = t ]] || { echo "Migration 42 scope test left changes behind." >&2; exit 1; }
echo "Migration 42's closing check covers the nineteen business tables only."

#!/usr/bin/env bash
# Writes the baseline migration from a database that build-chain-db.sh built.
#
#   dump-baseline.sh <container> <output.sql> --expect-last N [--removed-roles a,b,c] [--keep-header-date YYYY-MM-DD]
#                    [--expected-extensions a,b,c]
#     --expect-last  the number of the chain's last migration; the run fails unless the ledger holds 0..N with no gap
#                    (050 is the one known gap) and ends at N (a missing tweak migration is caught here).
#
# The baseline is an EXACT squash of the chain: every object the chain made, nothing dropped, nothing hardened.
# It is assembled from five parts (see the comments below), each produced by a small explicit step:
#   1 header      SET LOCAL … so no setting leaks into later files of the same psql session (design 13, M2)
#   2 extensions  CREATE EXTENSION IF NOT EXISTS for every extension of the chain database
#   3 roles       a DO block creating the roles the chain created (warehouse_*): the image's own roles are the bootstrap's
#   4 schema      pg_dump --schema-only, edited by edit-dump.mjs (event triggers, auth owners, removed roles' grants)
#   5 seed data   pg_dump --data-only of the tables that hold rows after a fresh install, then sequence positions
# Not in the baseline: the image's own schemas (extensions, storage, vault, realtime, graphql, …) and the ledger
# schema warehouse_migrations (created by migration-plan.mjs). `auth` contributes its functions only.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
here="$(dirname "${BASH_SOURCE[0]}")"
(($# >= 2)) || { sed -n '2,9p' "${BASH_SOURCE[0]}" >&2; exit 2; }
container="$1" out="$2"; shift 2
removed='' expect_last='' expected_ext='pg_stat_statements,pg_trgm,pgcrypto,uuid-ossp'
header_date=$(date -u +%F)
while (($#)); do
  case "$1" in
    --removed-roles) removed="$2"; shift 2 ;;
    --keep-header-date) header_date="$2"; shift 2 ;;
    --expect-last) expect_last="$2"; shift 2 ;;
    --expected-extensions) expected_ext="$2"; shift 2 ;;
    *) echo "Unknown option $1" >&2; exit 2 ;;
  esac
done
[[ "$expect_last" =~ ^[0-9]+$ ]] || { echo '--expect-last N is required (the number of the last migration of the chain)' >&2; exit 2; }
work=$(mktemp -d "${TMPDIR:-/tmp}/baseline-dump.XXXXXX")
trap 'rm -rf "$work"' EXIT
q() { db_psql "$container" -At "$@"; }

# Precondition 1: the ledger of the chain database holds 0..N without a gap (050 was never written), ending at --expect-last.
q -c "SELECT split_part(name, '_', 1)::bigint FROM warehouse_migrations.applied ORDER BY 1" > "$work/ledger.txt"
awk -v last="$expect_last" 'BEGIN { prev = -1 }
  { n = $1 + 0
    if (n != prev + 1 && !(prev + 2 == n && n == 51 && prev == 49)) { printf "Gap in the migration chain: %d is followed by %d\n", prev, n; bad = 1 }
    prev = n }
  END { if (prev != last) { printf "The chain ends at %d, expected --expect-last %d\n", prev, last; bad = 1 }
        exit bad }' "$work/ledger.txt" >&2 || { echo 'The chain database is not the final chain (are migrations 100-102, 109 and the others in the root?)' >&2; exit 1; }

# Precondition 2: no removed role the chain created (warehouse_*) is left at the chain end; a chain migration drops it.
if [[ -z "$removed" ]]; then removed=$(EDIT_MODULE="$(cd "$here" && pwd)/edit-dump.mjs" node -e "import(process.env.EDIT_MODULE).then(m => process.stdout.write(m.DEFAULT_REMOVED_ROLES.join(',')))"); fi
left_roles=$(q -c "SELECT string_agg(rolname, ', ') FROM pg_roles WHERE rolname LIKE 'warehouse\\_%' AND rolname = ANY(string_to_array('$removed', ','))")
[[ -z "$left_roles" ]] || { echo "Removed role(s) still exist at the chain end: $left_roles. Drop them with a chain migration (DROP OWNED BY …; DROP ROLE …); the baseline must not create them." >&2; exit 1; }
removed_sql="string_to_array('$removed', ',')"

# Schemas that belong to the image or to the runner, never dumped (auth is dumped for its functions only).
image_schemas="'auth','extensions','graphql','graphql_public','pgbouncer','realtime','_realtime','storage','vault','supabase_functions','net','cron','pgsodium','pgsodium_masks','warehouse_migrations','information_schema'"
mapfile -t schemas < <(q -c "SELECT nspname FROM pg_namespace WHERE nspname NOT IN ($image_schemas) AND nspname !~ '^pg_' ORDER BY 1")
[[ " ${schemas[*]} " == *" public "* ]] || { echo 'The database has no public schema' >&2; exit 1; }
n_flags=()
for s in "${schemas[@]}" auth; do n_flags+=(-n "$s"); done

# Part 4 input: the schema dump. -T 'auth.*' leaves out the image's tables in auth (its three/four functions stay).
docker exec -e PGPASSWORD="$DB_PASSWORD" "$container" pg_dump -U supabase_admin -d postgres --schema-only "${n_flags[@]}" -T 'auth.*' \
  --no-publications --no-subscriptions --no-security-labels --no-tablespaces > "$work/raw.sql"
node "$here/edit-dump.mjs" "$work/raw.sql" "$removed" > "$work/schema.sql"

# Part 5 input: seed tables = tables with rows in the dumped schemas (auth/storage rows belong to the image).
schema_list=$(printf "'%s'," "${schemas[@]}"); schema_list=${schema_list%,}
db_psql "$container" -At < "$here/seed-dump.sql" > "$work/seed.txt"
seed_tables=()
while IFS='|' read -r kind rel _; do
  [[ "$kind" == seed ]] || continue
  [[ " ${schemas[*]} " == *" ${rel%%.*} "* ]] && seed_tables+=("$rel")
done < "$work/seed.txt"
: > "$work/data.sql"
if ((${#seed_tables[@]})); then
  # A partitioned parent holds no rows of its own and `-t parent` dumps none: dump the leaf partitions.
  t_flags=()
  for t in "${seed_tables[@]}"; do
    # pg_partition_tree lists nothing for a table that is not partitioned: that table is its own leaf.
    while IFS= read -r leaf; do t_flags+=(-t "$leaf"); done < <(q -c "SELECT quote_ident(n.nspname) || '.' || quote_ident(c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.oid = '$t'::regclass AND c.relkind = 'r'
      UNION SELECT quote_ident(n.nspname) || '.' || quote_ident(c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relkind = 'r' AND c.oid IN (SELECT relid FROM pg_partition_tree('$t'::regclass) WHERE isleaf) ORDER BY 1")
  done
  ((${#t_flags[@]})) || { echo 'No table to dump rows from (the seed tables have no leaf)' >&2; exit 1; }
  docker exec -e PGPASSWORD="$DB_PASSWORD" "$container" pg_dump -U supabase_admin -d postgres --data-only --column-inserts --on-conflict-do-nothing --strict-names \
    "${t_flags[@]}" > "$work/data.raw"
  # Only the dump's header is filtered (SET lines, set_config, psql meta commands, up to the first INSERT); the unrestrict
  # line at the end goes too. Lines inside a multi-line string value stay as they are.
  awk 'BEGIN { head = 1 } head && /^INSERT /{ head = 0 } head && /^(SET |SELECT pg_catalog\.set_config|\\)/ { next } /^\\(un)?restrict / { next } { print }' "$work/data.raw" > "$work/data.sql"
fi
q -c "SELECT format('SELECT pg_catalog.setval(%L, %s, %s);', quote_ident(schemaname) || '.' || quote_ident(sequencename), last_value, 'true')
        FROM pg_sequences WHERE last_value IS NOT NULL AND schemaname IN ($schema_list) ORDER BY 1" > "$work/setval.sql"

# Part 2: extensions (plpgsql is built in). An extension that needs another comes after it; the set must be the expected one.
actual_ext=$(q -c "SELECT string_agg(extname, ',' ORDER BY extname COLLATE \"C\") FROM pg_extension WHERE extname <> 'plpgsql'")
expected_sorted=$(tr ',' '\n' <<< "$expected_ext" | LC_ALL=C sort | paste -sd,)
[[ "$actual_ext" == "$expected_sorted" ]] || { echo "Extensions at the chain end: $actual_ext; expected: $expected_sorted (--expected-extensions). Drop the leftovers with a chain migration." >&2; exit 1; }
q -c "SELECT format('CREATE EXTENSION IF NOT EXISTS %I WITH SCHEMA %I;', e.extname, n.nspname)
        FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname <> 'plpgsql'
        ORDER BY (SELECT count(*) FROM pg_depend d WHERE d.classid = 'pg_extension'::regclass AND d.objid = e.oid AND d.refclassid = 'pg_extension'::regclass AND d.deptype = 'e'), e.extname" > "$work/ext.sql"

# Part 3: roles the chain created (names warehouse_*, except the removed ones), with attributes, memberships and role settings.
q -c "SELECT format(\$f\$  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = %L) THEN
    CREATE ROLE %I %s;
  END IF;\$f\$, rolname, rolname,
    concat_ws(' ', CASE WHEN rolcanlogin THEN 'LOGIN' ELSE 'NOLOGIN' END, CASE WHEN rolsuper THEN 'SUPERUSER' ELSE 'NOSUPERUSER' END,
      CASE WHEN rolcreatedb THEN 'CREATEDB' ELSE 'NOCREATEDB' END, CASE WHEN rolcreaterole THEN 'CREATEROLE' ELSE 'NOCREATEROLE' END,
      CASE WHEN rolreplication THEN 'REPLICATION' ELSE 'NOREPLICATION' END, CASE WHEN rolbypassrls THEN 'BYPASSRLS' ELSE 'NOBYPASSRLS' END,
      CASE WHEN rolinherit THEN 'INHERIT' ELSE 'NOINHERIT' END))
        FROM pg_roles WHERE rolname LIKE 'warehouse\\_%' AND rolname <> ALL($removed_sql) ORDER BY rolname" > "$work/roles-create.sql"
# A membership is written when a warehouse role is the member or the granted role.
q -c "SELECT format('GRANT %I TO %I%s;', g.rolname, m.rolname, CASE WHEN a.admin_option THEN ' WITH ADMIN OPTION' ELSE '' END)
        FROM pg_auth_members a JOIN pg_roles g ON g.oid = a.roleid JOIN pg_roles m ON m.oid = a.member
       WHERE (g.rolname LIKE 'warehouse\\_%' OR m.rolname LIKE 'warehouse\\_%') AND g.rolname <> ALL($removed_sql) AND m.rolname <> ALL($removed_sql)
       ORDER BY 1" > "$work/roles-grant.sql"
# Role settings: list-valued ones (search_path) keep their stored form, every other value is a quoted literal.
q -c "SELECT format('ALTER ROLE %I SET %I TO %s;', r.rolname, split_part(c, '=', 1),
        CASE WHEN split_part(c, '=', 1) IN ('search_path', 'temp_tablespaces', 'session_preload_libraries', 'local_preload_libraries')
             THEN substr(c, position('=' in c) + 1) ELSE quote_literal(substr(c, position('=' in c) + 1)) END)
        FROM pg_roles r, unnest(r.rolconfig) c WHERE r.rolname LIKE 'warehouse\\_%' AND r.rolname <> ALL($removed_sql) ORDER BY 1" > "$work/roles-set.sql"

{
  cat <<HEADER
-- Baseline migration: the schema and seed data of migrations 000 to the last of the chain, squashed.
-- Generated $header_date by scripts/baseline/dump-baseline.sh from a database built by scripts/baseline/build-chain-db.sh.
-- The old files are in the git tag migrations-pre-baseline. NEVER edit this file: add a new migration instead.
-- Every setting below is transaction-local (SET LOCAL), so nothing leaks into the files applied after this one.
SET LOCAL statement_timeout = 0;
SET LOCAL lock_timeout = 0;
SET LOCAL idle_in_transaction_session_timeout = 0;
SET LOCAL standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', true);
SET LOCAL check_function_bodies = false;
SET LOCAL xmloption = content;
SET LOCAL client_min_messages = warning;
SET LOCAL row_security = off;

HEADER
  echo '-- Extensions'
  cat "$work/ext.sql"
  echo
  if [[ -s "$work/roles-create.sql" ]]; then
    echo '-- Roles created by the chain (the image'"'"'s own roles come from the bootstrap)'
    echo 'DO $roles$'
    echo 'BEGIN'
    cat "$work/roles-create.sql"
    echo 'END $roles$;'
    cat "$work/roles-grant.sql" "$work/roles-set.sql"
    echo
  fi
  cat "$work/schema.sql"
  if [[ -s "$work/data.sql" ]]; then
    echo
    echo '-- Seed data: the rows a fresh install holds. Triggers stay quiet while it is loaded.'
    echo 'SET LOCAL session_replication_role = replica;'
    cat "$work/data.sql"
    echo 'RESET session_replication_role;'
  fi
  if [[ -s "$work/setval.sql" ]]; then echo; echo '-- Sequence positions'; cat "$work/setval.sql"; fi
} > "$out.tmp"
# What the new image never has must not be in the baseline (design 4.7 checklist).
if bad=$(grep -nE 'pg_graphql|pg_net|pg_cron|supabase_vault|supabase_realtime|CREATE SCHEMA (graphql|realtime|vault)' "$out.tmp"); then
  echo "The baseline names things the new image does not have:" >&2; echo "$bad" | cut -c1-200 | head -10 >&2; rm -f "$out.tmp"; exit 1
fi
mv "$out.tmp" "$out"
echo "Wrote $out ($(wc -l < "$out") lines, ${#schemas[@]} schemas + auth functions, ${#seed_tables[@]} seed tables)" >&2

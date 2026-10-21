#!/usr/bin/env bash
# The optional connection pooler (Supavisor, Compose profile `pooler`). It is off by default: an installation that
# never turns it on has no pgbouncer role, no pgbouncer schema, no _supabase database and no pooler secrets.
#
#   bash scripts/pooler.sh on       Turns the pooler on: generates the pooler secrets in config/compose.env where missing
#                                   (DB_PASSWORD_POOLER, SECRET_KEY_BASE, VAULT_ENC_KEY), creates the role pgbouncer with its
#                                   password, the schema pgbouncer with get_auth and the database _supabase
#                                   (scripts/configure-pooler.sql), records POOLER_ENABLED=true and starts the supavisor
#                                   service. Safe to repeat. setup.sh and both restore paths keep these objects while it is on.
#   bash scripts/pooler.sh off      Stops and removes the supavisor container and records POOLER_ENABLED=false. The role,
#                                   the schema, the _supabase database and the secrets stay (nothing is deleted); turning
#                                   the pooler on again reuses them.
#   bash scripts/pooler.sh status   Prints on, off or unset.
#   bash scripts/pooler.sh cleanup  The one-time clean-up setup.sh runs for an installation made before the pooler had a
#                                   switch (POOLER_ENABLED absent from compose.env). See docs/OPERATOR_INSTALL.md.
#                                   - a supavisor container exists: the pooler is in use, so it is recorded as on
#                                   - none exists and _supabase holds no relation and no schema beyond _supavisor and public:
#                                     role, schema and database are removed, the three secrets leave compose.env, the switch
#                                     is recorded as off, and what was removed is printed
#                                   - none exists but _supabase holds relations or other schemas (the pooler was used):
#                                     refuses, changes nothing, exit 1 (setup.sh prints it and goes on)
# Needs a running, healthy db service. Takes the operator lock (inherited when setup.sh runs it).
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() { echo 'Usage: bash scripts/pooler.sh on | off | status | cleanup' >&2; exit 1; }
(($# == 1)) || usage
command="$1"
case "$command" in on|off|status|cleanup) ;; *) usage ;; esac
# shellcheck source=scripts/operator-lock.sh
. "$ROOT/scripts/operator-lock.sh"
state="$(operator_state)"
operator_lock_or_inherited "$state"
live="$state/config/compose.env"
staged="$live.pooler"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
switch() { node "$ROOT/scripts/db-roles.mjs" pooler-state "$live"; }
db_psql() { compose exec -T db psql -X -q -A -t -U supabase_admin -v ON_ERROR_STOP=1 "$@"; }
require_db() {
  local id
  id="$(compose ps -q db)"
  if [[ -z "$id" ]] || ! docker inspect --format '{{.State.Health.Status}}' "$id" 2>/dev/null | grep -qx healthy; then
    echo 'The database service is not running and healthy; start the instance first (bash start.sh).' >&2
    exit 1
  fi
}
trap 'rm -f "$staged"' EXIT
# Stages compose.env with the switch, then renames it over compose.env.
commit_env() {
  node "$ROOT/scripts/db-roles.mjs" pooler-stage "$live" "$staged" "$1"
  mv -f "$staged" "$live"
}
supavisor_exists() {
  local project
  project="$(sed -n 's/^WAREHOUSE_PROJECT_NAME=//p' "$live" | head -n 1)"
  [[ -n "$(docker ps -aq --filter "label=com.docker.compose.project=$project" --filter 'label=com.docker.compose.service=supavisor')" ]]
}

case "$command" in
  status) switch ;;
  on)
    compose config --quiet
    require_db
    # The database side first, from the staged values: the role must exist with the new password before the service
    # starts. A failure leaves compose.env as it was; a rerun starts again.
    node "$ROOT/scripts/db-roles.mjs" pooler-stage "$live" "$staged" on
    bash "$ROOT/scripts/db-roles.sh" apply "$staged" "$live"
    mv -f "$staged" "$live"
    if ! compose --profile pooler up -d --no-deps --wait --wait-timeout 180 supavisor; then
      node "$ROOT/scripts/service-diagnostics.mjs" || true
      echo 'The pooler objects and secrets are in place but the supavisor service did not become healthy (see above). Run bash scripts/pooler.sh on again once the cause is fixed.' >&2
      exit 1
    fi
    echo 'The pooler is on: role pgbouncer, schema pgbouncer (get_auth) and database _supabase exist, the pooler secrets are in config/compose.env, and the supavisor service is healthy.'
    echo 'Check it with: npm run test:pooler. Turn it off with: bash scripts/pooler.sh off'
    ;;
  off)
    compose config --quiet
    compose --profile pooler rm -sf supavisor >/dev/null
    commit_env off
    echo 'The pooler is off: the supavisor container is stopped and removed.'
    echo 'Nothing was deleted: the role pgbouncer, the schema pgbouncer, the _supabase database and the pooler secrets stay, and bash scripts/pooler.sh on reuses them. While it is off, setup, rotation and backups leave them alone (the password of pgbouncer is not rotated).'
    ;;
  cleanup)
    [[ "$(switch)" == unset ]] || exit 0
    require_db
    if supavisor_exists; then
      commit_env on
      echo 'Pooler: a supavisor container exists, so the pooler is in use here. Recorded POOLER_ENABLED=true; its role, database and secrets stay.'
      exit 0
    fi
    facts="$(db_psql -d postgres -c "SELECT (SELECT count(*) FROM pg_roles WHERE rolname = 'pgbouncer') || ' ' || (SELECT count(*) FROM pg_namespace WHERE nspname = 'pgbouncer') || ' ' || (SELECT count(*) FROM pg_database WHERE datname = '_supabase')")"
    read -r has_role has_schema has_database <<< "$facts"
    removed=()
    if [[ "$has_database" != 0 ]]; then
      held="$(db_psql -d _supabase -c "SELECT (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname NOT LIKE 'pg\\_%' AND n.nspname <> 'information_schema' AND c.relkind IN ('r','p','v','m','S','f')) || ' ' || COALESCE((SELECT string_agg(nspname, ',' ORDER BY nspname) FROM pg_namespace WHERE nspname NOT LIKE 'pg\\_%' AND nspname NOT IN ('information_schema','public','_supavisor')), '-')")"
      read -r relations others <<< "$held"
      if [[ "$relations" != 0 || "$others" != - ]]; then
        what="$relations relation(s)"
        [[ "$others" == - ]] || what="$what and the schema(s) $others"
        echo "Pooler clean-up refused: the database _supabase holds $what. The pooler has been used here, so nothing was changed. Keep using it with bash scripts/pooler.sh on, or remove the pooler objects by hand after a backup." >&2
        exit 1
      fi
    fi
    if [[ "$has_role" != 0 || "$has_schema" != 0 ]]; then
      db_psql -d postgres <<'SQL'
BEGIN;
DROP SCHEMA IF EXISTS pgbouncer CASCADE;
DROP ROLE IF EXISTS pgbouncer;
COMMIT;
SQL
      [[ "$has_schema" == 0 ]] || removed+=('schema pgbouncer (get_auth)')
      [[ "$has_role" == 0 ]] || removed+=('role pgbouncer')
    fi
    if [[ "$has_database" != 0 ]]; then
      db_psql -d postgres -c 'DROP DATABASE IF EXISTS _supabase WITH (FORCE)'
      removed+=('database _supabase (empty)')
    fi
    for name in DB_PASSWORD_POOLER SECRET_KEY_BASE VAULT_ENC_KEY; do
      if grep -q "^$name=" "$live"; then removed+=("$name from config/compose.env"); fi
    done
    commit_env forget
    if ((${#removed[@]})); then
      echo "Pooler is off and unused: removed $(printf '%s, ' "${removed[@]}" | sed 's/, $//'). Turn the pooler on later with bash scripts/pooler.sh on."
    else
      echo 'Pooler is off and unused: recorded POOLER_ENABLED=false (no pooler objects or secrets existed).'
    fi
    ;;
esac

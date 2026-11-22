#!/usr/bin/env bash
# The optional connection pooler (Supavisor, Compose profile `pooler`). It is off by default: an installation that
# never turns it on has no pgbouncer role, no pgbouncer schema, no _supabase database and no pooler secrets.
#
#   bash scripts/pooler.sh on       Turns the pooler on: generates the pooler secrets in config/compose.env where missing
#                                   (DB_PASSWORD_POOLER, SECRET_KEY_BASE, VAULT_ENC_KEY), creates the role pgbouncer with its
#                                   password, the schema pgbouncer with get_auth and the database _supabase
#                                   (scripts/configure-pooler.sql), records POOLER_ENABLED=true and starts the supavisor
#                                   service. Safe to repeat. setup.sh and both restore paths keep these objects while it is on.
#   bash scripts/pooler.sh off      Stops and removes the supavisor container, then removes the role pgbouncer, the schema
#                                   pgbouncer (get_auth), the _supabase database and the three secrets
#                                   (scripts/drop-pooler.sql: no CASCADE, no FORCE; it refuses and changes nothing if the
#                                   schema holds more than get_auth, or the database has connections, other schemas or
#                                   relations that are not Supavisor's own tables), and records POOLER_ENABLED=false.
#                                   Those checks run first, read-only, before the container is stopped (connections only
#                                   when supavisor is not running, as it is connected itself); a refusal there stops nothing.
#                                   If the removal still refuses after the stop (something connected meanwhile), supavisor is
#                                   started again if it was running, and the message says which state the pooler is in.
#                                   `on` recreates everything. The role, database and secrets exist only while the pooler
#                                   is on. Once the pooler has run, _supabase holds Supavisor's own tables (its tenant and
#                                   pool user, the password encrypted with VAULT_ENC_KEY, written again at every start);
#                                   they cannot be kept, because off removes VAULT_ENC_KEY and the next `on` makes a new
#                                   one that cannot read them. Plain `off` then changes nothing and points to:
#   bash scripts/pooler.sh off --drop-metadata
#                                   The same, and it also removes Supavisor's own tables with _supabase. First it saves a
#                                   0600 copy of compose.env (compose.env.pre-pooler-off-<time>) and a dump of _supabase
#                                   (_supabase.pre-pooler-off-<time>.dump) next to it and prints their paths. Safe to
#                                   repeat: with no _supabase left it saves only the compose.env copy.
#   bash scripts/pooler.sh status   Prints on, off or unset.
#   bash scripts/pooler.sh cleanup  The one-time clean-up setup.sh runs for an installation made before the pooler had a
#                                   switch (POOLER_ENABLED absent from compose.env). See docs/OPERATOR_INSTALL.md.
#                                   - a supavisor container exists: the pooler is in use, so it is recorded as on
#                                   Before it changes anything it saves a 0600 copy of compose.env next to it
#                                   (compose.env.pre-pooler-cleanup-<time>) and prints its path.
#                                   - a supavisor container exists: the pooler is in use, so it is recorded as on
#                                   - none exists and the _supabase database is missing: the switch is recorded as off, the
#                                     secrets STAY (a new cluster has no _supabase even when the pooler was used); run
#                                     `bash scripts/pooler.sh on` if it was
#                                   - none exists and _supabase holds nothing: same removal as `off`
#                                   - none exists but _supabase holds relations or other schemas (the pooler was used), or the
#                                     removal is refused: changes nothing, exit 1 (setup.sh prints it and goes on)
# Needs a running, healthy db service. Takes the operator lock (inherited when setup.sh runs it).
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() { echo 'Usage: bash scripts/pooler.sh on | off | status | cleanup (or: off --drop-metadata)' >&2; exit 1; }
command="${1:-}"
drop_metadata=no
case "$#:$command:${2:-}" in
  1:on:|1:off:|1:status:|1:cleanup:) ;;
  2:off:--drop-metadata) drop_metadata=yes ;;
  *) usage ;;
esac
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
# Removes the pooler's database objects (scripts/drop-pooler.sql); on a refusal nothing was changed. Any arguments go to
# psql (pooler off --drop-metadata passes -v drop_supavisor_metadata=on; -v check_only=on runs only the refusal checks).
drop_objects() { db_psql -d postgres "$@" < "$ROOT/scripts/drop-pooler.sql"; }
# "<role> <schema> <database>": whether the role pgbouncer, the schema pgbouncer and the database _supabase exist (1 or 0).
pooler_facts() {
  db_psql -d postgres -c "SELECT (SELECT count(*) FROM pg_roles WHERE rolname = 'pgbouncer') || ' ' || (SELECT count(*) FROM pg_namespace WHERE nspname = 'pgbouncer') || ' ' || (SELECT count(*) FROM pg_database WHERE datname = '_supabase')"
}
# How many of Supavisor's own tables _supabase holds (the list in scripts/drop-pooler.sql); call only when it exists.
supavisor_tables() {
  local count
  count="$(db_psql -d _supabase -c "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = '_supavisor' AND c.relkind = 'r' AND c.relname IN ('tenants','users','clusters','cluster_tenants','schema_migrations')")"
  read -r count _ <<< "$count"
  [[ "$count" =~ ^[0-9]+$ ]] || { echo 'Could not count the tables in _supabase; nothing was changed.' >&2; return 1; }
  echo "$count"
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
    require_db
    facts="$(pooler_facts)"
    read -r _ _ has_database <<< "$facts"
    tables=0
    if [[ "$has_database" == 1 ]]; then tables="$(supavisor_tables)"; fi
    psql_vars=()
    if [[ "$drop_metadata" == yes ]]; then psql_vars=(-v drop_supavisor_metadata=on); fi
    if [[ "$drop_metadata" == no && "$tables" != 0 ]]; then
      echo "Nothing was changed: the pooler has been used, so the _supabase database holds Supavisor's own tables ($tables: its tenant and pool user, written again at every start). Switching off removes them with the database, together with VAULT_ENC_KEY, which they cannot be read without." >&2
      echo 'To switch the pooler off, run: bash scripts/pooler.sh off --drop-metadata (it first saves a copy of compose.env and a dump of _supabase). To keep it, do nothing: it stays on.' >&2
      exit 1
    fi
    # The refusal checks of drop-pooler.sql, read-only, before anything is saved or stopped. A running supavisor is
    # connected itself, so connections are checked here only when it is not running; the removal after the stop checks
    # them again.
    supavisor_running="$(compose --profile pooler ps -q supavisor)"
    check_vars=(-v check_only=on)
    if [[ -n "$supavisor_running" ]]; then check_vars+=(-v ignore_connections=on); fi
    if ! drop_objects "${psql_vars[@]}" "${check_vars[@]}"; then
      echo 'The pooler objects were not removed and compose.env is unchanged (see above); the supavisor service was not stopped, so nothing was changed. Stop what uses the pooler, or remove what does not belong in _supabase, then run this again.' >&2
      exit 1
    fi
    if [[ "$drop_metadata" == yes ]]; then
      stamp="$(date -u +%Y%m%dT%H%M%SZ)"
      copy="$live.pre-pooler-off-$stamp"
      cp -p "$live" "$copy"
      chmod 600 "$copy"
      echo "Pooler off: saved a copy of compose.env as $copy."
      if [[ "$has_database" == 1 ]]; then
        dump="$state/config/_supabase.pre-pooler-off-$stamp.dump"
        if ! compose exec -T db pg_dump -U supabase_admin -d _supabase --format=custom > "$dump"; then
          rm -f "$dump"
          echo 'The dump of _supabase failed (see above); nothing else was changed. Run this again once the cause is fixed.' >&2
          exit 1
        fi
        chmod 600 "$dump"
        echo "Pooler off: saved a dump of _supabase ($tables of Supavisor's own tables) as $dump."
      fi
    fi
    compose --profile pooler rm -sf supavisor >/dev/null
    if ! drop_objects "${psql_vars[@]}"; then
      recorded="POOLER_ENABLED is $(switch) in compose.env, which is unchanged"
      if [[ -z "$supavisor_running" ]]; then
        echo "The removal of the pooler objects refused or failed (see above). The supavisor service was not running before and is still stopped; $recorded. Stop what uses the pooler, then run this again." >&2
      elif compose --profile pooler up -d --no-deps --wait --wait-timeout 180 supavisor; then
        echo "The removal of the pooler objects refused or failed (see above), so the supavisor service was started again: the pooler is on as before and $recorded. Stop what uses the pooler, then run this again." >&2
      else
        node "$ROOT/scripts/service-diagnostics.mjs" || true
        echo "The removal of the pooler objects refused or failed (see above), and the supavisor service did not start again: the pooler is DOWN and $recorded. Start it with: bash scripts/pooler.sh on" >&2
      fi
      exit 1
    fi
    commit_env forget
    echo 'The pooler is off: the supavisor container is removed, and the role pgbouncer, the schema pgbouncer, the _supabase database and the pooler secrets are gone. bash scripts/pooler.sh on recreates them.'
    ;;
  cleanup)
    [[ "$(switch)" == unset ]] || exit 0
    require_db
    copy="$live.pre-pooler-cleanup-$(date -u +%Y%m%dT%H%M%SZ)"
    cp -p "$live" "$copy"
    chmod 600 "$copy"
    echo "Pooler clean-up: saved a copy of compose.env as $copy (use it to roll back to an older release)."
    if supavisor_exists; then
      commit_env on
      echo 'Pooler: a supavisor container exists, so the pooler is in use here. Recorded POOLER_ENABLED=true; its role, database and secrets stay.'
      exit 0
    fi
    facts="$(pooler_facts)"
    read -r has_role has_schema has_database <<< "$facts"
    if [[ "$has_database" == 0 ]]; then
      commit_env off
      echo "Pooler: no supavisor container and no _supabase database, so it cannot be told whether the pooler was used (a new cluster has neither). Recorded POOLER_ENABLED=false and kept the pooler secrets. If this installation used the pooler, run: bash scripts/pooler.sh on (compose.env copy: $copy)"
      exit 0
    fi
    removed=()
    if ! drop_objects; then
      echo 'The pooler objects were not removed and compose.env is unchanged (see above). Stop what uses the pooler, then run this again.' >&2
      exit 1
    fi
    [[ "$has_schema" == 0 ]] || removed+=('schema pgbouncer (get_auth)')
    [[ "$has_role" == 0 ]] || removed+=('role pgbouncer')
    removed+=('database _supabase (empty)')
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

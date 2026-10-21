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
#                                   schema holds more than get_auth or the database has relations or connections), and
#                                   records POOLER_ENABLED=false. `on` recreates everything. The role, database and
#                                   secrets exist only while the pooler is on.
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
# Removes the pooler's database objects (scripts/drop-pooler.sql); on a refusal nothing was changed.
drop_objects() {
  if ! db_psql -d postgres < "$ROOT/scripts/drop-pooler.sql"; then
    echo 'The pooler objects were not removed and compose.env is unchanged (see above). Stop what uses the pooler, then run this again.' >&2
    return 1
  fi
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
    compose --profile pooler rm -sf supavisor >/dev/null
    drop_objects || exit 1
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
    facts="$(db_psql -d postgres -c "SELECT (SELECT count(*) FROM pg_roles WHERE rolname = 'pgbouncer') || ' ' || (SELECT count(*) FROM pg_namespace WHERE nspname = 'pgbouncer') || ' ' || (SELECT count(*) FROM pg_database WHERE datname = '_supabase')")"
    read -r has_role has_schema has_database <<< "$facts"
    if [[ "$has_database" == 0 ]]; then
      commit_env off
      echo "Pooler: no supavisor container and no _supabase database, so it cannot be told whether the pooler was used (a new cluster has neither). Recorded POOLER_ENABLED=false and kept the pooler secrets. If this installation used the pooler, run: bash scripts/pooler.sh on (compose.env copy: $copy)"
      exit 0
    fi
    removed=()
    drop_objects || exit 1
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

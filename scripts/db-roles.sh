#!/usr/bin/env bash
# Per-role database passwords (docs/CONTAINER_SECURITY.md, "Database passwords").
#
#   bash scripts/db-roles.sh apply [VALUES_FILE [CONNECT_FILE]] [--superuser]
#       Sets every service login's password from VALUES_FILE (default: this
#       state's config/compose.env) with scripts/configure-db-roles.sql. It
#       signs in as supabase_admin with the POSTGRES_PASSWORD of CONNECT_FILE
#       (default: VALUES_FILE). --superuser also sets the superuser password
#       (scripts/rotate-db-passwords.sh only). setup.sh and both restore paths
#       run `apply` after their migrations.
#   bash scripts/db-roles.sh check      (npm run test:db-roles)
#       Proves for each login that POSTGRES_PASSWORD is refused and its own
#       value accepted, over a network connection that PostgreSQL authenticates
#       with SCRAM (connections from 127.0.0.1 inside the database container are
#       trusted by the image, so they would prove nothing), that the monitoring
#       login has pg_monitor and no superuser rights, and that
#       supabase_functions_admin cannot log in at all.
#
# Secrets travel on standard input only, never in arguments or environment
# variables of a docker command.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
usage() { echo 'Usage: bash scripts/db-roles.sh apply [VALUES_FILE [CONNECT_FILE]] [--superuser] | check' >&2; exit 1; }
# shellcheck source=scripts/operator-lock.sh
. "$ROOT/scripts/operator-lock.sh"
state="$(operator_state)"
operator_lock_or_inherited "$state"
live="$state/config/compose.env"

command="${1:-}"
(($#)) && shift
case "$command" in
  apply)
    superuser=()
    files=()
    for arg in "$@"; do
      case "$arg" in
        --superuser) superuser=(--superuser) ;;
        /*) files+=("$arg") ;;
        *) usage ;;
      esac
    done
    ((${#files[@]} <= 2)) || usage
    values="${files[0]:-$live}"
    connect="${files[1]:-$values}"
    password="$(sed -n 's/^POSTGRES_PASSWORD=//p' "$connect" | head -n 1)"
    [[ "$password" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "No usable POSTGRES_PASSWORD in $connect." >&2; exit 1; }
    prelude="$(node "$ROOT/scripts/db-roles.mjs" prelude "$values" "${superuser[@]}")"
    # The first line is the sign-in password, read by the shell in the container;
    # psql reads the verifiers and the script from the rest of the stream.
    { printf '%s\n%s\n' "$password" "$prelude"; cat "$ROOT/scripts/configure-db-roles.sql"; } |
      compose exec -T db sh -c 'IFS= read -r pw; PGPASSWORD="$pw" exec psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1'
    ;;
  check)
    (($# == 0)) || usage
    node "$ROOT/scripts/db-roles.mjs" check-input "$live" | compose exec -T db sh -c '
      export PGCONNECT_TIMEOUT=5
      IFS= read -r superuser_password
      failed=0
      login() { PGPASSWORD="$2" psql -X -qAt -h db -U "$1" -d postgres -v ON_ERROR_STOP=1 -c "$3" 2>/dev/null; }
      remote="SELECT current_user || CASE WHEN inet_client_addr() IS NULL OR inet_client_addr() <<= inet '\''127.0.0.0/8'\'' OR inet_client_addr() = inet '\''::1'\'' THEN '\'' local'\'' ELSE '\'' remote'\'' END"
      while IFS="	" read -r role password; do
        [ -n "$role" ] || continue
        if login "$role" "$superuser_password" "SELECT 1" >/dev/null; then
          echo "FAIL $role accepts POSTGRES_PASSWORD"; failed=1
        else
          echo "ok   $role refuses POSTGRES_PASSWORD"
        fi
        answer="$(login "$role" "$password" "$remote" || true)"
        if [ "$answer" = "$role remote" ]; then
          echo "ok   $role accepts its own password (SCRAM, network connection)"
        else
          echo "FAIL $role does not accept its own password over the network (${answer:-refused})"; failed=1
        fi
        if [ "$role" = warehouse_monitoring ]; then
          rights="$(login "$role" "$password" "SELECT pg_has_role(current_user, '\''pg_monitor'\'', '\''USAGE'\'')::text || '\'' '\'' || rolsuper::text || rolcreaterole::text || rolcreatedb::text || rolreplication::text || rolbypassrls::text FROM pg_roles WHERE rolname = current_user" || true)"
          if [ "$rights" = "true falsefalsefalsefalsefalse" ]; then
            echo "ok   warehouse_monitoring has pg_monitor and no superuser, role, database, replication or RLS bypass right"
          else
            echo "FAIL warehouse_monitoring rights: ${rights:-unreadable}"; failed=1
          fi
        fi
      done
      functions_login="$(PGPASSWORD="$superuser_password" psql -X -qAt -h /var/run/postgresql -U supabase_admin -d postgres -c "SELECT rolcanlogin::text || '\'' '\'' || (rolpassword IS NULL)::text FROM pg_authid WHERE rolname = '\''supabase_functions_admin'\''" 2>/dev/null || true)"
      case "$functions_login" in
        "false true") echo "ok   supabase_functions_admin cannot log in and has no password" ;;
        "") echo "ok   supabase_functions_admin does not exist" ;;
        *) echo "FAIL supabase_functions_admin login state: $functions_login"; failed=1 ;;
      esac
      exit "$failed"'
    echo 'Every database login refuses the superuser password and accepts only its own.'
    ;;
  *) usage ;;
esac

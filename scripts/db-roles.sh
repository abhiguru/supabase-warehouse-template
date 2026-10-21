#!/usr/bin/env bash
# Per-role database passwords (docs/CONTAINER_SECURITY.md, "Database passwords").
#
#   bash scripts/db-roles.sh apply [VALUES_FILE [CONNECT_FILE]] [--superuser]
#       Sets every service login's password from VALUES_FILE (default: this
#       state's config/compose.env) with scripts/configure-db-roles.sql. It
#       signs in as supabase_admin with the POSTGRES_PASSWORD of CONNECT_FILE
#       (default: VALUES_FILE). --superuser also sets the superuser password
#       (scripts/rotate-db-passwords.sh only). setup.sh and both restore paths
#       run `apply` after their migrations. While the pooler is on (POOLER_ENABLED=true),
#       it first creates the pooler's role, schema, auth lookup and _supabase database
#       (scripts/configure-pooler.sql) and sets the pool user's password too. While it is
#       off (POOLER_ENABLED=false) it drops those objects if present (scripts/drop-pooler.sql).
#   bash scripts/db-roles.sh check      (npm run test:db-roles)
#       Proves first that POSTGRES_PASSWORD is the superuser password the
#       database has (supabase_admin signs in with it), then for each login that
#       POSTGRES_PASSWORD is refused and its own value accepted, over a network
#       connection that PostgreSQL authenticates with SCRAM (connections from
#       127.0.0.1 inside the database container are trusted by the image, so they
#       would prove nothing). The roles of the earlier image do not exist and are not checked.
#       The pooler's login pgbouncer is checked only while the pooler is on.
#   bash scripts/db-roles.sh matches FILE
#       Whether the database takes FILE's values (authenticator and supabase_admin
#       sign in with them over the same network connection): exit 0 yes, 1 no,
#       2 cannot tell (no answer from the database). scripts/rotate-db-passwords.sh
#       uses it to find which file an interrupted rotation left the database with.
#
# Secrets travel on standard input only, never in arguments or environment
# variables of a docker command.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
usage() { echo 'Usage: bash scripts/db-roles.sh apply [VALUES_FILE [CONNECT_FILE]] [--superuser] | check | matches FILE' >&2; exit 1; }
# The query of every network sign-in: who signed in, and whether the server saw a
# non-loopback client (only then did it check the password with SCRAM).
remote_query="SELECT current_user || CASE WHEN inet_client_addr() IS NULL OR inet_client_addr() <<= inet '127.0.0.0/8' OR inet_client_addr() = inet '::1' THEN ' local' ELSE ' remote' END"
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
    # While the pooler is on, its role, schema, auth lookup and metadata database must exist before its password is set.
    # With the pooler off none of them is created; if a restore or an older state left them, they are dropped
    # (scripts/drop-pooler.sql: no CASCADE, no FORCE; it refuses with a message when they are in use). Unset (an
    # installation from before the switch) leaves them for `pooler.sh cleanup`.
    pooler_state="$(node "$ROOT/scripts/db-roles.mjs" pooler-state "$values")"
    if [[ "$pooler_state" == on ]]; then
      { printf '%s\n' "$password"; cat "$ROOT/scripts/configure-pooler.sql"; } |
        compose exec -T db sh -c 'IFS= read -r pw; PGPASSWORD="$pw" exec psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1'
    elif [[ "$pooler_state" == off ]]; then
      { printf '%s\n' "$password"; cat "$ROOT/scripts/drop-pooler.sql"; } |
        compose exec -T db sh -c 'IFS= read -r pw; PGPASSWORD="$pw" exec psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1'
    fi
    # The first line is the sign-in password, read by the shell in the container;
    # psql reads the verifiers and the script from the rest of the stream.
    { printf '%s\n%s\n' "$password" "$prelude"; cat "$ROOT/scripts/configure-db-roles.sql"; } |
      compose exec -T db sh -c 'IFS= read -r pw; PGPASSWORD="$pw" exec psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1'
    ;;
  check)
    (($# == 0)) || usage
    node "$ROOT/scripts/db-roles.mjs" check-input "$live" | compose exec -T db sh -c '
      export PGCONNECT_TIMEOUT=5
      remote="$1"
      IFS= read -r superuser_password
      failed=0
      login() { PGPASSWORD="$2" psql -X -qAt -h db -U "$1" -d postgres -v ON_ERROR_STOP=1 -c "$3" 2>/dev/null; }
      # Every "refuses POSTGRES_PASSWORD" below means something only if that is the
      # superuser password the database has now.
      answer="$(login supabase_admin "$superuser_password" "$remote" || true)"
      if [ "$answer" = "supabase_admin remote" ]; then
        echo "ok   supabase_admin accepts POSTGRES_PASSWORD (SCRAM, network connection): it is the live superuser password"
      else
        echo "FAIL supabase_admin refuses POSTGRES_PASSWORD over the network (${answer:-refused}): compose.env does not hold the superuser password the database has, so no refusal below proves anything"; failed=1
      fi
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
      done
      exit "$failed"' sh "$remote_query"
    echo 'Every database login refuses the superuser password and accepts only its own.'
    ;;
  matches)
    (($# == 1)) && [[ "$1" == /* && -f "$1" ]] || usage
    superuser="$(sed -n 's/^POSTGRES_PASSWORD=//p' "$1" | head -n 1)"
    authenticator="$(sed -n 's/^DB_PASSWORD_AUTHENTICATOR=//p' "$1" | head -n 1)"
    [[ -n "$superuser" && -n "$authenticator" ]] || { echo "No POSTGRES_PASSWORD or DB_PASSWORD_AUTHENTICATOR in $1." >&2; exit 2; }
    # yes: signed in over the network; no: the password was refused; anything else: no answer.
    answer="$(printf '%s\n%s\n' "$superuser" "$authenticator" | compose exec -T db sh -c '
      export PGCONNECT_TIMEOUT=5
      remote="$1"
      IFS= read -r superuser; IFS= read -r authenticator
      verdict() {
        out="$(PGPASSWORD="$2" psql -X -qAt -h db -U "$1" -d postgres -v ON_ERROR_STOP=1 -c "$remote" 2>&1)"
        if [ "$out" = "$1 remote" ]; then echo yes
        elif printf "%s" "$out" | grep -q "password authentication failed"; then echo no
        else echo unknown; fi
      }
      a="$(verdict authenticator "$authenticator")"; s="$(verdict supabase_admin "$superuser")"
      if [ "$a" = yes ] && [ "$s" = yes ]; then echo match
      elif [ "$a" = no ] || [ "$s" = no ]; then echo "no match"
      else echo unknown; fi' sh "$remote_query" 2>/dev/null || true)"
    case "$answer" in
      match) exit 0 ;;
      'no match') exit 1 ;;
      *) exit 2 ;;
    esac
    ;;
  *) usage ;;
esac

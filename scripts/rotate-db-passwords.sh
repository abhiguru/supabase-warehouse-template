#!/usr/bin/env bash
# Rotate this installation's database passwords (docs/OPERATOR_INSTALL.md,
# "Rotating the database passwords"; docs/CONTAINER_SECURITY.md, "Database passwords").
#
#   npm run db:rotate-passwords -- --yes               every service login
#   npm run db:rotate-passwords -- --yes --superuser   also POSTGRES_PASSWORD and the Realtime key
#
# New values are staged next to compose.env and set in the database in one
# transaction (verifiers on standard input, scripts/db-roles.sh); only then is
# compose.env replaced, and the database and every running service that signs in
# to it are recreated. If one of them does not become healthy, or a login does
# not behave, the previous values go back into the database and compose.env and
# the services are recreated again. JWT signing keys are a separate command
# (rotate-keys.sh); no session is ended and no device signs in again.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
# shellcheck source=scripts/operator-lock.sh
. "$ROOT/scripts/operator-lock.sh"
usage() {
  cat >&2 <<'USAGE'
Usage: npm run db:rotate-passwords -- --yes [--superuser]
Generates a new password for every database login of the services (PostgREST,
Storage, Auth, the pooler, the Postgres exporter and Grafana), sets them in the
database, and restarts the database and the services that sign in to it
(about a minute; the API is unavailable for some seconds of it). With
--superuser, POSTGRES_PASSWORD (the
postgres and supabase_admin logins) and the Realtime encryption key change too.
Take a db:backup first. Nothing was changed. Rerun with --yes to confirm.
USAGE
  exit 1
}
confirm=false
superuser=()
for arg in "$@"; do
  case "$arg" in
    --yes) confirm=true ;;
    --superuser) superuser=(--superuser) ;;
    *) usage ;;
  esac
done
[[ "$confirm" == true ]] || usage
state="$(operator_state)"
operator_lock "$state"
compose config --quiet
db_id=$(compose ps -q db)
[[ -n "$db_id" ]] || { echo 'Database service is not running; start the instance first.' >&2; exit 1; }
docker inspect --format '{{.State.Health.Status}}' "$db_id" | grep -qx healthy || { echo 'Database service is not healthy.' >&2; exit 1; }

live="$state/config/compose.env"
staged="$state/config/compose.env.rotating-db"
previous="$state/config/compose.env.before-db-rotation"
# A rotation that stopped half-way (a power cut, a killed shell) leaves one of
# these files; which one says where the values the database has now are.
if [[ -e "$staged" ]]; then
  echo "Refusing: $staged is left from an interrupted rotation and may hold the passwords the database has now. Run: mv \"$staged\" \"$live\"; bash setup.sh --operator ... (your setup inputs); npm run test:db-roles. If test:db-roles failed before you moved it, the database still has the values of compose.env: then remove $staged instead." >&2
  exit 1
fi
if [[ -e "$previous" ]]; then
  echo "Refusing: $previous is left from an interrupted rotation. compose.env holds the passwords the database has; run bash setup.sh --operator ... (your setup inputs) so every service uses them, then npm run test:db-roles, then remove $previous." >&2
  exit 1
fi
applied=false
cleanup() {
  local status=$?
  trap - EXIT
  # Before the database step the staged values are unused and are removed. After
  # it they are the database's: the file stays, and the message says what to do.
  if [[ "$applied" == false ]]; then rm -f "$staged"
  elif [[ -e "$staged" ]]; then echo "Stopped after the database step: $staged holds the passwords the database has now. Run: mv \"$staged\" \"$live\"; bash setup.sh --operator ... (your setup inputs)." >&2
  fi
  exit "$status"
}
trap cleanup EXIT

node "$ROOT/scripts/db-roles.mjs" stage "$live" "$staged" "${superuser[@]}"
# 1. The database, in one transaction, signed in with the current superuser
#    password. A failure here changes nothing.
bash "$ROOT/scripts/db-roles.sh" apply "$staged" "$live" "${superuser[@]}"
applied=true
# 2. The file: the previous one is kept (mode 0600) until the services are healthy.
cp -p "$live" "$previous"
mv -f "$staged" "$live"

# 3. The database (its environment carries the values for its first-start init
#    script) and every running service that signs in to it. A service that was
#    stopped on purpose stays stopped; it reads the new value when it starts.
recreate=()
for service in db rest storage auth realtime meta studio supavisor postgres-exporter grafana; do
  id=$(compose --profile '*' ps -q "$service")
  if [[ -n "$id" && "$(docker inspect --format '{{.State.Running}}' "$id")" == true ]]; then recreate+=("$service"); fi
done
rollback() {
  trap - EXIT
  echo 'A service did not come back with the new database passwords; putting the previous ones back.' >&2
  # The database holds the new values now: sign in with the new superuser password.
  if bash "$ROOT/scripts/db-roles.sh" apply "$previous" "$live" "${superuser[@]}"; then
    mv -f "$previous" "$live"
    compose --profile '*' up -d --force-recreate --wait --wait-timeout 180 "${recreate[@]}" ||
      echo 'The services did not all come back either; see the messages above and run node scripts/doctor.mjs --local.' >&2
    echo 'The previous database passwords are back in place; nothing was rotated.' >&2
  else
    echo "Could not put the previous passwords back. compose.env holds the new values (they are set in the database); the previous file is $previous." >&2
  fi
  exit 1
}
if ((${#recreate[@]})) && ! compose --profile '*' up -d --force-recreate --wait --wait-timeout 180 "${recreate[@]}"; then rollback; fi
bash "$ROOT/scripts/db-roles.sh" check || rollback
node "$ROOT/scripts/doctor.mjs" --local || rollback
rm -f "$previous"
if ((${#superuser[@]})); then
  echo 'Database passwords rotated: every service login, the superuser password and the Realtime key are new.'
else
  echo 'Database passwords rotated: every service login has a new password.'
fi
echo 'Take a new backup now: older backups carry the previous values (a restore of one sets them again).'

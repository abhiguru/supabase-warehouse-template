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
Storage, Auth, the pooler and the Postgres exporter), sets them in the
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
live="$state/config/compose.env"
staged="$state/config/compose.env.rotating-db"
previous="$state/config/compose.env.before-db-rotation"
# A rotation that stopped half-way (a power cut, a killed shell, a full disk) leaves
# one or both of these files; see recover below.
leftovers=()
for file in "$staged" "$previous"; do [[ ! -e "$file" ]] || leftovers+=("$file"); done
db_id=$(compose ps -q db)
if [[ -z "$db_id" ]]; then
  if ((${#leftovers[@]})); then
    echo 'Database service is not running. An earlier rotation stopped half-way; start the database alone (bash scripts/compose.sh up -d --wait db) and run this command again: it finds out which values the database has.' >&2
  else
    echo 'Database service is not running; start the instance first.' >&2
  fi
  exit 1
fi
docker inspect --format '{{.State.Health.Status}}' "$db_id" | grep -qx healthy || { echo 'Database service is not healthy.' >&2; exit 1; }

# Which file holds the passwords the database has now is decided by the database:
# each candidate's values are tried with the network sign-in npm run test:db-roles
# uses (scripts/db-roles.sh matches). The one that matches becomes compose.env, the
# others go (the database does not have their values), and nothing is rotated.
recover() {
  local file match='' status
  echo "An earlier rotation stopped half-way and left ${leftovers[*]##*/}. Asking the database which values it has."
  for file in "$live" "${leftovers[@]}"; do
    status=0
    bash "$ROOT/scripts/db-roles.sh" matches "$file" || status=$?
    case "$status" in
      0) match="$file"; break ;;
      1) ;;
      *) echo "Refusing: the database gave no clear answer for ${file##*/}. Nothing was changed; check that it is running (bash scripts/compose.sh ps db) and run this command again." >&2; exit 1 ;;
    esac
  done
  if [[ -z "$match" ]]; then
    echo "Refusing: the database takes the values of none of compose.env and ${leftovers[*]##*/}. Nothing was changed. Keep every one of these files and see docs/OPERATOR_INSTALL.md, \"Rotating the database passwords\"." >&2
    exit 1
  fi
  if [[ "$match" == "$live" ]]; then
    echo 'The database has the values of compose.env.'
  else
    mv -f "$match" "$live"
    echo "The database has the values of ${match##*/}: it is compose.env now."
  fi
  for file in "${leftovers[@]}"; do
    if [[ "$file" != "$match" && -e "$file" ]]; then rm -f "$file"; echo "Removed ${file##*/}: the database does not have its values."; fi
  done
  echo 'Nothing was rotated. Run bash start.sh so every service uses these values, check with npm run test:db-roles, then run npm run db:rotate-passwords -- --yes again if you still want new ones.'
  exit 1
}
((${#leftovers[@]} == 0)) || recover

# false: the database was not asked; started: asked, outcome not known; true: it has the staged values.
applied=false
cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$applied" == false ]]; then rm -f "$staged"
  elif [[ -e "$staged" ]]; then
    echo "Stopped during or after the database step. $staged is kept: the database may have its values now. Run npm run db:rotate-passwords -- --yes again: it finds out which values the database has, puts that file in place and says what to run next." >&2
  fi
  exit "$status"
}
trap cleanup EXIT

node "$ROOT/scripts/db-roles.mjs" stage "$live" "$staged" "${superuser[@]}"
# 1. The database, in one transaction, signed in with the current superuser
#    password. From here on the staged file is kept unless the database is known
#    to still have the values of compose.env.
applied=started
apply_status=0
bash "$ROOT/scripts/db-roles.sh" apply "$staged" "$live" "${superuser[@]}" || apply_status=$?
if ((apply_status)); then
  match_status=0
  bash "$ROOT/scripts/db-roles.sh" matches "$live" || match_status=$?
  if ((match_status == 0)); then
    applied=false
    echo 'The database step failed and changed nothing (the database still has the values of compose.env).' >&2
  fi
  exit 1
fi
applied=true
# 2. The file: the previous one is kept (mode 0600) until the services are healthy.
cp -p "$live" "$previous"
mv -f "$staged" "$live"

# 3. The database (its environment carries the values for its first-start init
#    script) and every running service that signs in to it. A service that was
#    stopped on purpose stays stopped; it reads the new value when it starts.
recreate=()
for service in db rest storage auth realtime meta studio supavisor postgres-exporter; do
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
    echo "Could not put the previous passwords back. compose.env holds the new values and $previous the previous ones; which ones the database has is checked by the next run. Fix the cause above, then run npm run db:rotate-passwords -- --yes again: it finds out which values the database has, keeps that file as compose.env and says what to run next." >&2
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

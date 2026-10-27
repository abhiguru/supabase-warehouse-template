#!/usr/bin/env bash
# Rotate this instance's JWT secret and the anon/service keys derived from it.
# Database signing configuration, every session and pending challenge and each
# key consumer are updated together; devices sign in again.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
. "$ROOT/scripts/operator-lock.sh"
if [[ $# -ne 1 || "$1" != --yes ]]; then
  cat >&2 <<'USAGE'
Usage: bash rotate-keys.sh --yes
Generates a new JWT secret with new anon and service keys for this operator
state, updates the database signing configuration, revokes every session and
recreates the key consumers. Every device must sign in again afterwards.
Nothing was changed. Rerun with --yes to confirm.
USAGE
  exit 1
fi
state="$(operator_state)"
operator_lock "$state"
compose config --quiet
# This recreates db: a PostgreSQL 15 database must go through the baseline reload instead.
bash "$ROOT/scripts/db-version-preflight.sh"
db_id=$(compose ps -q db)
[[ -n "$db_id" ]] || { echo 'Database service is not running; start the instance first.' >&2; exit 1; }
if ! docker inspect --format '{{.State.Health.Status}}' "$db_id" | grep -qx healthy; then
  echo 'Database service is not healthy.' >&2
  exit 1
fi

# A collation fault is the database image's, not the rotation's: told here, before anything is changed, so that the check after the
# rotation cannot report a rotation that went well as failed.
node "$ROOT/scripts/doctor.mjs" --collation || { echo 'Refusing: nothing was changed. Fix what the collation check above reports first (docs/OPERATOR_INSTALL.md, "Collation changes").' >&2; exit 1; }

live="$state/config/compose.env"
staged="$state/config/compose.env.rotating"
cleanup() {
  status=$?
  trap - EXIT
  rm -f "$staged"
  exit "$status"
}
trap cleanup EXIT

node "$ROOT/scripts/rotate-keys.mjs" "$live" "$staged"
secret="$(sed -n 's/^JWT_SECRET=//p' "$staged")"
[[ "$secret" =~ ^[0-9a-f]{96}$ ]] || { echo 'Staged configuration has no valid JWT_SECRET.' >&2; exit 1; }

# The secret reaches psql only through standard input, never through arguments.
# A failure here leaves compose.env and the database unchanged.
{ printf '\\set new_secret %s\n' "$secret"; cat "$ROOT/scripts/rotate-auth.sql"; } \
  | compose exec -T db psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1
# The database now signs with the new secret. If this process dies before the
# rename below, rerunning the command stages and applies a newer secret again.
mv -f "$staged" "$live"

# Recreate only the running key consumers so an intentionally stopped optional
# service is not started. db is included so its environment matches on reruns.
recreate=()
for service in db gateway rest storage functions supavisor; do
  id=$(compose ps -q "$service")
  if [[ -n "$id" && "$(docker inspect --format '{{.State.Running}}' "$id")" == true ]]; then recreate+=("$service"); fi
done
if ((${#recreate[@]})); then
  compose --profile '*' up -d --force-recreate --wait --wait-timeout 180 "${recreate[@]}"
fi
# The LAN fallback (gateway-lan) holds the keys in its configuration, like the gateway (the map of the `apikey` header), and has to be
# recreated with them. It is a profile service, so the loop above does not name it, and it is recreated whenever a container of it
# exists, running or not (a stopped one would otherwise be started again by self-healing with the old keys, `--no-recreate`). Apart from
# the others: a fault of the fallback must not undo a rotation that has already been applied, so a failure here is a warning with the
# way to repair it. Phones that fall back to the LAN with a container that still has the old keys get the gateway's 401 on every REST
# request (the app must not end a session on a 401 from the LAN path), and doctor now sees that (scripts/lan.mjs, probeLanKeys).
lan_stale=false
if [[ -n "$(compose --profile lan ps -a -q gateway-lan 2>/dev/null || true)" ]]; then
  if ! compose --profile lan up -d --force-recreate --no-deps --wait --wait-timeout 180 gateway-lan; then
    node "$ROOT/scripts/service-diagnostics.mjs" gateway-lan || true
    lan_stale=true
  fi
fi
node "$ROOT/scripts/doctor.mjs" --local
if [[ "$lan_stale" == true ]]; then
  echo 'Warning: the LAN fallback (gateway-lan) was not recreated and still holds the OLD keys: every REST request over the LAN path is refused until it is. The rotation itself is complete. Repair: bash scripts/lan.sh on auto (or: bash scripts/compose.sh --profile lan up -d --force-recreate --no-deps gateway-lan), then node scripts/doctor.mjs --lan.' >&2
fi
echo 'Signing keys rotated: new JWT secret, anon key and service key are active.'
echo 'Every session was revoked; every device must sign in again. Update any copied anon key.'

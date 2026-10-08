#!/usr/bin/env bash
# Rotate this instance's JWT secret and the anon/service keys derived from it.
# Database signing configuration, every session and pending challenge, the
# Realtime tenant and each key consumer are updated together; devices sign in again.
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
db_id=$(compose ps -q db)
[[ -n "$db_id" ]] || { echo 'Database service is not running; start the instance first.' >&2; exit 1; }
if ! docker inspect --format '{{.State.Health.Status}}' "$db_id" | grep -qx healthy; then
  echo 'Database service is not healthy.' >&2
  exit 1
fi

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
for service in db kong rest realtime storage functions studio supavisor; do
  id=$(compose ps -q "$service")
  if [[ -n "$id" && "$(docker inspect --format '{{.State.Running}}' "$id")" == true ]]; then recreate+=("$service"); fi
done
if ((${#recreate[@]})); then
  compose --profile '*' up -d --force-recreate --wait --wait-timeout 180 "${recreate[@]}"
fi
node "$ROOT/scripts/doctor.mjs" --local
echo 'Signing keys rotated: new JWT secret, anon key and service key are active.'
echo 'Every session was revoked; every device must sign in again. Update any copied anon key.'

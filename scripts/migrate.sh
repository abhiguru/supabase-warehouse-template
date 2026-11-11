#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" != --operator ]]; then
  echo 'Use scripts/migrate.sh --operator [--through <migration file name>] (setup.sh runs it with the state directory chosen).' >&2
  exit 1
fi
shift
plan_args=()
if [[ $# -gt 0 ]]; then
  if [[ $# -ne 2 || "$1" != --through || -z "$2" ]]; then
    echo 'Usage: scripts/migrate.sh --operator [--through <migration file name>]' >&2
    exit 1
  fi
  plan_args=(--through "$2")
fi
# setup.sh and restore.sh run this under their own lock; run alone, it takes the lock.
# shellcheck source=scripts/operator-lock.sh
. "$ROOT/scripts/operator-lock.sh"
state="$(operator_state)"
operator_lock_or_inherited "$state"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
# All migrations share one database session and advisory lock. Changed applied files fail closed.
# --through stops the plan after the named file (the Baseline reload); an unknown name fails before the database is touched.
plan="$(node "$ROOT/scripts/migration-plan.mjs" ${plan_args[@]+"${plan_args[@]}"})"
# Each file of the plan runs in its own transaction with a lock_timeout of 10 s (scripts/migration-plan.mjs). A file that cannot get a
# lock in that time (a session of the running API holds the table) fails with 55P03 and rolls back whole; the plan is then run again
# after a pause, three attempts in all, and the ledger makes the files that were applied "Already applied". Any other error stops at
# once. The timeout is recognised by its SQLSTATE: psql runs with VERBOSITY=verbose, which prints "ERROR:  55P03: ..." whatever the
# language of the server's messages; the English text is only a fallback. The operator sees the messages without the code and the
# LOCATION lines that verbose adds. WAREHOUSE_MIGRATE_RETRY_SECONDS (default 5) is the pause; the tests shorten it.
pause="${WAREHOUSE_MIGRATE_RETRY_SECONDS:-5}"
[[ "$pause" =~ ^[0-9]{1,3}$ ]] || { echo 'WAREHOUSE_MIGRATE_RETRY_SECONDS must be a whole number of seconds.' >&2; exit 1; }
# The severity word is the server's, in the language of its messages (ERREUR: in French), so any word is accepted before the SQLSTATE.
lock_timeout_re='([^[:space:]:]+:  55P03: |(ERROR|FATAL):  .*canceling statement due to lock timeout)'
errors="$(mktemp "${TMPDIR:-/tmp}/warehouse-migrate.XXXXXX")"
trap 'rm -f "$errors"' EXIT
attempt=1
while :; do
  status=0
  # psql's messages are kept for the retry check AND shown as they arrive (without the code and the LOCATION lines), so that a NOTICE or an
  # error keeps its place among the "Applying:" lines of the plan on standard output. The reader of fd 3 is waited for before the check.
  : > "$errors"
  exec 3> >(tee -a "$errors" | sed -u -E '/^[^[:space:]:]+:  [A-Za-z0-9_]+, [A-Za-z0-9_.]+:[0-9]+$/d; s/^((psql:[^ ]*: )?[^[:space:]:]+:  )[0-9A-Z]{5}: /\1/' >&2)
  reader=$!
  printf '%s\n' "$plan" |
    compose exec -T db psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -v VERBOSITY=verbose 2>&3 || status=$?
  exec 3>&-
  wait "$reader" 2>/dev/null || true
  ((status != 0)) || break
  if grep -Eq "$lock_timeout_re" "$errors" && ((attempt < 3)); then
    echo "A migration waited more than 10 s for a lock and was rolled back whole (attempt $attempt of 3). Trying again in ${pause} s; the files already applied are skipped." >&2
    sleep "$pause"
    attempt=$((attempt + 1))
    continue
  fi
  if grep -Eq "$lock_timeout_re" "$errors"; then
    echo 'A migration could not get its lock in three attempts: a session keeps a table it changes in use. Nothing of that file was applied. Wait for that session to end (or stop the services that use the database), then run this command again.' >&2
  fi
  exit "$status"
done

# Migration 172: the payments capability moved from instance.json to the database ("Record payments" in the app). An installation that
# had it on keeps it on: once, after the plan, the file's flag is handed to warehouse_security.carry_payments_capability, which switches
# record_payments on (audited) only on its first call and answers 'already' on every later one, so a later choice made in the app is never
# overridden. It is here, not in setup.sh or upgrade.sh, because this is the one step that every path runs after the migrations (setup,
# the setup rerun of upgrade.sh, restore.sh), under the operator lock, with the state directory and the database at hand. A partial plan
# (--through) skips it, and so does a manifest that can not be read (nothing is marked, so the next run carries it over).
if [[ ${#plan_args[@]} -eq 0 ]]; then
  manifest="$state/public/instance.json"
  if ! payments_on="$(node -e '
    const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const c = m && m.capabilities;
    if (!c || typeof c !== "object" || Array.isArray(c)) process.exit(2);
    console.log(c.payments === true ? "true" : "false");' "$manifest" 2>/dev/null)"; then
    echo "Could not read capabilities from $manifest: the payments setting was not carried over to the database (it is tried again on the next run)." >&2
  else
    carried="$(printf 'SELECT warehouse_security.carry_payments_capability(%s);\n' "$payments_on" |
      compose exec -T db psql -X -q -t -A -U supabase_admin -d postgres -v ON_ERROR_STOP=1)"
    if [[ "$carried" == carried_on ]]; then
      echo 'Payments were on in instance.json: "Record payments" is now on in the database (the app setting on the Charging screen).'
    fi
  fi
fi

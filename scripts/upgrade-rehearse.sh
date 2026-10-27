#!/usr/bin/env bash
# The migration rehearsal of an upgrade, run by scripts/upgrade-preflight.sh of the release an installation moves to (so it
# always applies THAT release's migrations): the newest verified backup is restored into a disposable, network-isolated database
# (scripts/verify-restore.sh --keep) and the migration plan of the target release (scripts/migration-plan.mjs) is applied to it,
# file by file, as setup would apply it to the facility. A migration that fails on the facility's own data (a unique index over rows
# that already clash, a constraint that existing rows break) is found here, before the backup, the checkout or any change to the
# live database, and the refusal names the file and the database's message. The live facility is only read: its backup files.
#
# From the preflight, in the environment: STATE (the installation's state directory), TO_LABEL. Exit 0: the migrations apply, or
# there was nothing to rehearse them on (no verified backup on record yet, which is warned about). Exit 1: refused; the message says
# "Nothing was changed". The disposable container is removed on every exit.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE="$(dirname "$HERE")"
say() { printf '%s\n' "$*"; }
refuse() { printf 'Refusing: %s Nothing was changed.\n' "$*" >&2; exit 1; }

: "${STATE:?the preflight sets STATE}"
: "${TO_LABEL:?the preflight sets TO_LABEL}"
[[ "$STATE" == /* && -d "$STATE/config" ]] || refuse "STATE is not an installed operator state ('$STATE')."

# The newest backup on the verified list whose directory still holds its database dump.
backup=''
verified_list="$STATE/config/backups-verified.list"
if [[ -f "$verified_list" && ! -L "$verified_list" ]]; then
  while read -r name _; do
    [[ "$name" =~ ^warehouse-[0-9]{8}T[0-9]{6}Z$ ]] || continue
    dir="$STATE/backups/$name"
    if [[ -d "$dir" && ! -L "$dir" && -f "$dir/database.dump" && ! -L "$dir/database.dump" && -f "$dir/metadata.txt" ]]; then backup="$dir"; fi
  done < <(awk 'NF { print $1 }' "$verified_list" | LC_ALL=C sort -u)
fi
if [[ -z "$backup" ]]; then
  printf '%s\n' "Warning: the migrations were NOT rehearsed: no verified backup is on record yet, so there is no copy of your data to apply them to. The upgrade's own backup is taken next, and setup applies the migrations to the facility itself, after the checkout." >&2
  exit 0
fi
[[ -d "$TREE/migrations" && -f "$TREE/scripts/migration-plan.mjs" ]] || refuse "the preflight of $TO_LABEL did not receive its migrations (migrations/ and scripts/migration-plan.mjs), so they cannot be rehearsed."

# Which data the rehearsal sees: the backup's name is its time (UTC). Rows entered after it are not on the copy, so a migration that
# fails on them is not found here; an old backup is said so, with the date.
stamp="${backup##*/warehouse-}"
made="${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:9:2}:${stamp:11:2}:${stamp:13:2}"
age=$(( $(date -u +%s) - $(date -u -d "$made" +%s 2>/dev/null || echo 0) ))
if ((age < 0)); then age=0; fi
if ((age >= 172800)); then age_text="$((age / 86400)) days"; elif ((age >= 3600)); then age_text="$((age / 3600)) hours"; else age_text="$((age / 60)) minutes"; fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/warehouse-rehearsal.XXXXXX")"
container=''
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$container" ]]; then bash "$HERE/verify-restore.sh" --rm "$container" >/dev/null 2>&1 || echo "Could not remove the disposable database $container; remove it with: bash scripts/verify-restore.sh --rm $container" >&2; fi
  rm -rf "$scratch"
  exit "$status"
}
trap cleanup EXIT

say "Rehearsal of the migrations of $TO_LABEL: restoring $(basename "$backup") into a disposable database (the facility itself is not touched). That backup was made $made UTC, $age_text ago."
if ((age >= 172800)); then
  printf '%s\n' "Warning: this backup is $age_text old. Rows entered after $made UTC are not on the copy, so a migration that fails on them is not found by this rehearsal (it would stop setup after the checkout). To rehearse on newer data, make a backup that is verified and recorded first: bash scripts/backup.sh, then bash scripts/verify-restore.sh <the new folder under backups/>, then node scripts/watch.mjs record-verified <its name> (the nightly pass does the same), and run this command again." >&2
fi
# The signature and the chain were proved when the backup went on the verified list, and it was compared with its integrity report then;
# the rehearsal only needs the data (--restore-only), so a difference between this release's report and an older backup's cannot refuse it.
if ! WAREHOUSE_STATE_DIR="$STATE" bash "$HERE/verify-restore.sh" --keep --no-storage-tree --restore-only "$backup" > "$scratch/verify.out" 2> "$scratch/verify.err"; then
  cat "$scratch/verify.err" >&2
  # A failed verify-restore removed its own container.
  # Its last message, before the diagnostics it appends when its container failed ("Restore verification failed. Container log ...").
  last="$(awk '/^Restore verification failed\./ { exit } NF { line = $0 } END { print line }' "$scratch/verify.err")"
  last="${last%.}"
  refuse "the newest verified backup ($(basename "$backup")) could not be restored into the disposable database, so the migrations of $TO_LABEL cannot be rehearsed on a copy of your data. The restore said: ${last:-nothing on standard error (see above)}. The host may be the cause (free disk space or memory, a database image that has to be pulled while the host is offline) as well as the backup; once that is dealt with, run this command again. If the backup is at fault, make a new one that is verified and recorded: bash scripts/backup.sh, then bash scripts/verify-restore.sh <the new folder under backups/>, then node scripts/watch.mjs record-verified <its name> (a backup that is only made is not used until then; the nightly pass does the same)."
fi
container="$(sed -n 's/^Kept disposable database: \(warehouse-restore-[0-9a-f]\{12\}\) .*/\1/p' "$scratch/verify.out" | head -n 1)"
[[ -n "$container" ]] || refuse "scripts/verify-restore.sh did not name the disposable database it kept, so the rehearsal cannot go on."

plan="$(cd "$TREE" && node scripts/migration-plan.mjs)" || refuse "the migration plan of $TO_LABEL could not be built (the message is above)."
# Only the plan is timed: it is what the live database will take (the restore above is not part of the downtime).
started=$SECONDS
if ! printf '%s\n' "$plan" | docker exec -i -e PGPASSWORD=disposable-restore-only "$container" \
    psql -X -q -v ON_ERROR_STOP=1 -U supabase_admin -d warehouse_restore > "$scratch/plan.out" 2> "$scratch/plan.err"; then
  failing="$(sed -n 's/^Applying: //p' "$scratch/plan.out" | tail -n 1)"
  errors="$(grep -E '(^|: )(ERROR|FATAL):' "$scratch/plan.err" | head -n 3 || true)"
  [[ -n "$errors" ]] || errors="$(head -n 3 "$scratch/plan.err")"
  if [[ -n "$failing" ]]; then what="the migration $failing does not apply to a copy of your data"; else what="the migrations do not apply to a copy of your data (the failure came before the first file)"; fi
  printf '%s\n' "$errors" >&2
  refuse "$TO_LABEL cannot be installed on this facility: $what (the database says the above). The restored copy of $(basename "$backup") was used and thrown away; the facility is unchanged. Do not retry the same command: report this message to the maintainers of this software, who can say what to correct in the data or in the release."
fi
applied="$(grep -c '^Applying: ' "$scratch/plan.out" || true)"
say "Rehearsal of the migrations: passed ($applied to apply, $(grep -c '^Already applied: ' "$scratch/plan.out" || true) already applied) on a copy of $(basename "$backup"); applying them took $((SECONDS - started)) s."

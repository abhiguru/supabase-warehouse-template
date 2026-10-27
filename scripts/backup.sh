#!/usr/bin/env bash
# Create a private logical database, object storage and instance-configuration backup (format warehouse-backup-v6).
#
# The object storage is kept as a tree, storage/, not a tarball. Files unchanged since the previous backup are hard links to
# that backup's files (rsync --link-dest), so a night costs the database dump plus the new photos, not a second copy of every
# photo; extended attributes (the Storage service keeps content type and cache control in user.supabase.*) and modification
# times are kept. Integrity: SHA256SUMS lists storage.manifest, the sorted sha256 of every file in storage/, and the backup key
# signs SHA256SUMS. The API is stopped only for the database dump, the catalog queries, the last pass of the file copy and the
# restart; everything else (the first pass of the copy, the manifest, signing) happens with the API up.
# Invariant: nothing writes into the storage/ of an existing backup, and the live data/storage is never hard-linked to a backup.
# That is why the last pass of the copy goes into a new directory (linking what the first pass already copied) and never
# into the first pass's own: rsync would otherwise change the attributes of a file that earlier backups share in place.
# A shared file that no longer matches the checksum its backup recorded (bit rot, a read error) is not linked: it is copied
# again from the live storage, the backup says so (rot_repaired= in metadata.txt, a WARNING on standard error), and it goes on.
# A link base that fails its own signature check is not used.
# Before anything is stopped or written, a free-space check refuses the backup when the disk of the backup directory could not
# hold it (with a base: twice the new stored files; without one: the whole tree once plus 10%; plus the database dump and 256 MiB
# of working room) and still keep a reserve (WAREHOUSE_BACKUP_RESERVE_MB, 2048 by default): the refusal is the last line on
# standard error, with the numbers. A free space that cannot be read (df, then stat -f) refuses too: the guard is never off.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
state="${WAREHOUSE_STATE_DIR:-}"
[[ "$state" == /* && -f "$state/config/compose.env" && -f "$state/public/instance.json" && -d "$state/data/storage" ]] || {
  echo 'Set WAREHOUSE_STATE_DIR to the installed operator state.' >&2; exit 1;
}
compose config --quiet
# Run alone, this takes the lock; scripts/watch-daily.sh runs it under its own lock and the inherited one is used.
# shellcheck source=scripts/operator-lock.sh
. "$ROOT/scripts/operator-lock.sh"
if ! operator_lock_or_inherited "$state" 2>/dev/null; then echo 'Another operator setup, start, or backup is running for this state.' >&2; exit 1; fi
# shellcheck source=scripts/backup-key.sh
source "$ROOT/scripts/backup-key.sh"
backup_key_ensure "$state"
backup_key_load "$state/config/backup.key"
# Recorded before anything is stopped; a source archive without .git has no commit.
source_commit="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
mkdir -p "$state/backups"
destination="${1:-${WAREHOUSE_BACKUP_DIR:-$state/backups/warehouse-$timestamp}}"
if [[ "$destination" != /* || -e "$destination" || -L "$destination" || "$(realpath -m "$destination")" == "$state/data"/* ]]; then
  echo "Refusing to overwrite existing backup path: $destination" >&2
  exit 1
fi
parent="$(dirname "$destination")"
[[ -d "$parent" ]] || { echo "Backup parent does not exist: $parent" >&2; exit 1; }
if [[ "$(stat -c %d "$parent")" == "$(stat -c %d "$state/data")" ]]; then
  echo "Warning: $parent shares a filesystem with $state/data; a backup there does not survive loss of this disk. Copy it to protected off-host storage." >&2
fi
# A staging directory left by a run that was killed (power loss, SIGKILL) is not a backup. The operator lock is held, so no
# other backup is writing one; anything older than two hours is garbage. (Directories get u+rwx first, as rsync keeps their
# modes; files are never chmodded, they may be hard links shared with the base.)
while IFS= read -r -d '' leftover; do
  find "$leftover" -type d -exec chmod u+rwx {} + 2>/dev/null || true
  rm -rf -- "$leftover"
done < <(find "$parent" -mindepth 1 -maxdepth 1 -type d -name '.warehouse-backup-staging.*' -mmin +120 -print0 2>/dev/null)
stage="$(mktemp -d "$parent/.warehouse-backup-staging.XXXXXXXX")"
restart=()
# The LAN fallback (gateway-lan) is the other way in to the same API: while the backup holds the services stopped it is stopped too, and comes
# back apart from the others (lan.sh start: a fault of the fallback is a warning, never a failed backup).
lan_stopped=no
lan_back() {
  [[ "$lan_stopped" == yes ]] || return 0
  lan_stopped=no
  bash "$ROOT/scripts/lan.sh" start || echo 'Warning: the LAN fallback was not started again (message above). Run: bash scripts/lan.sh start' >&2
}
# Only the services this script stopped come back: --no-deps keeps compose from also starting what they depend
# on (restarting storage would start rest, which the operator may have stopped on purpose). They come back as they were: --no-recreate
# keeps the container, and with it a gateway in maintenance mode (scripts/maintenance.sh), which a backup never lifts.
cleanup() {
  status=$?
  trap - EXIT
  if ((${#restart[@]})); then
    if ! compose up -d --no-recreate --no-deps --wait --wait-timeout 180 "${restart[@]}"; then
      if command -v node >/dev/null 2>&1; then node "$ROOT/scripts/service-diagnostics.mjs" --unhealthy || true; else echo 'Service diagnostics skipped (node not on PATH): run node scripts/service-diagnostics.mjs --unhealthy' >&2; fi
      echo 'Backup services did not restart cleanly; run doctor and start.sh.' >&2
      status=1
    fi
  fi
  lan_back
  if [[ -d "$stage" ]]; then find "$stage" -type d -exec chmod u+rwx {} + 2>/dev/null || true; rm -rf "$stage"; fi
  [[ -z "${scratch:-}" ]] || rm -rf -- "$scratch"
  exit "$status"
}
trap cleanup EXIT

db_id=$(compose ps -q db)
[[ -n "$db_id" ]] || { echo 'Database service is not running.' >&2; exit 1; }
if ! docker inspect --format '{{.State.Health.Status}}' "$db_id" | grep -qx healthy; then
  echo 'Database service is not healthy.' >&2
  exit 1
fi

# The backup records the database image of this checkout (database_image= in metadata.txt), so the
# running server must be that release's: an install that pulled this release but still runs the earlier
# container (another PostgreSQL major) would dump the old schema under the new label that every restore accepts.
# Checked before any service is stopped.
pin="$(bash "$ROOT/scripts/db-image.sh")"
pin_major="${pin#postgres:}"; pin_major="${pin_major%%[!0-9]*}"
server="$(compose exec -T db psql -X -A -t -v ON_ERROR_STOP=1 -U supabase_admin -d postgres \
  -c "SELECT current_setting('server_version_num')::int / 10000 || '|' || (to_regrole('postgres') IS NULL)" | tr -d '[:space:]')"
if [[ "$server" != "$pin_major|true" ]]; then
  echo "Refusing: the running database reports '$server' (major version | has no role postgres), but this release runs PostgreSQL $pin_major with no role postgres. A backup of it would carry the wrong image label. This installation has not been moved to this release's database yet. From PostgreSQL $((pin_major - 1)): follow docs/OPERATOR_INSTALL.md, \"Major PostgreSQL upgrade\" (back up with the checkout that runs the old server first). From before PostgreSQL 17: back it up with the release tagged migrations-pre-baseline, then follow \"Baseline reload\"." >&2
  exit 1
fi

# The link base: the earlier backup whose files this one shares as hard links. The newest backup that the daily check
# verified (config/backups-verified.list, "name epoch" per line, written by scripts/watch.mjs prune-backups; the file may
# not exist yet) and that keeps its storage as a tree, as long as it was verified within the last two days; else the newest tree
# backup there is that passes the checks below (verified or not), else none (a full copy). The age limit is what keeps a run of
# nights whose verify fails from copying the same new photos again every night: each such backup would link from the old
# verified one and hold every photo added since, so after two days the chain goes on from the newest backup that authenticates
# (the rot check below compares every shared file with the base's signed manifest, so an unverified base is safe to link from).
# The verified list keeps its other job, pruning (it protects the newest verified backup, however old).
# A candidate is used only if it passes the signature and checksum check of its small files (database dump, manifest, ...),
# which does not read the photos: its manifest is what the checksums of the shared files are compared with below, so a damaged
# manifest must not be trusted, and one unusable backup must not stop every later night. A candidate that fails is named in a
# warning and the next one is tried. It must also sit on the filesystem of the new backup (hard links do not cross
# filesystems), and not be one that an earlier night found damaged beyond repair (config/link-base-rejected, below).
rejected_bases="$state/config/link-base-rejected"
declare -A base_checked=()
usable_base() {
  local name="$1" dir="$parent/$1" problem
  # The name comes from a directory listing or the verified list: only a backup's own name goes any further.
  [[ "$name" =~ ^warehouse-[0-9]{8}T[0-9]{6}Z$ ]] || return 1
  case "${base_checked[$name]:-}" in ok) return 0 ;; bad) return 1 ;; esac
  base_checked[$name]=bad
  [[ -d "$dir" && ! -L "$dir" && -d "$dir/storage" && ! -L "$dir/storage" \
    && -f "$dir/storage.manifest" && ! -L "$dir/storage.manifest" && -f "$dir/metadata.txt" && ! -L "$dir/metadata.txt" ]] \
    && grep -qx 'format=warehouse-backup-v6' "$dir/metadata.txt" || return 1
  if [[ -f "$rejected_bases" && ! -L "$rejected_bases" ]] && grep -qxF -- "$name" "$rejected_bases"; then
    echo "Note: $name is not used as the link base: a night found its stored files damaged and not repairable from the live storage. The files are copied in full instead." >&2
    return 1
  fi
  if [[ "$(stat -c %d -- "$dir/storage")" != "$(stat -c %d -- "$parent")" ]]; then
    echo "Warning: $name is not used as the link base: it is on another filesystem than the new backup, and hard links do not cross filesystems." >&2
    return 1
  fi
  if ! problem="$(WAREHOUSE_BACKUP_KEY_FILE="$state/config/backup.key" BACKUP_TREE=skip backup_authenticate "$dir" false 2>&1)"; then
    problem="${problem%%$'\n'*}"
    echo "Warning: $name is not used as the link base: it fails its signature and checksum check (${problem#Refusing: }). The next older backup is tried, else the stored files are copied in full. Check it: npm run db:verify-restore -- $dir" >&2
    return 1
  fi
  base_checked[$name]=ok
}
base_name=none
verified_list="$state/config/backups-verified.list"
verified_base_max_age=$((2 * 86400))
if [[ -f "$verified_list" && ! -L "$verified_list" ]]; then
  while read -r candidate; do
    if usable_base "$candidate"; then base_name="$candidate"; break; fi
  done < <(awk -v now="$(date +%s)" -v max="$verified_base_max_age" '$2 ~ /^[0-9]+$/ && now - $2 <= max { print $1 }' "$verified_list" | LC_ALL=C sort -r)
fi
if [[ "$base_name" == none ]]; then
  while read -r candidate; do
    if usable_base "$candidate"; then base_name="$candidate"; break; fi
  done < <(find "$parent" -mindepth 1 -maxdepth 1 -type d -name 'warehouse-*' -printf '%f\n' 2>/dev/null | LC_ALL=C sort -r)
fi

storage="$state/data/storage"
# What the Storage service writes is files in directories. A link or special file would be skipped by the copy
# (scripts/verify-restore.sh refuses them in a backup), and a name with a newline or backslash cannot be written in
# storage.manifest; both stop the backup here, before anything is stopped.
unsafe_entry() { find "$storage" \( \( ! -type f ! -type d \) -o -name '*\\*' -o -name $'*\n*' \) -print -quit; }
bad="$(unsafe_entry)"
if [[ -n "$bad" ]]; then
  echo "Refusing: the object storage holds a link, a special file or a name with a newline or backslash: ${bad//[^[:print:]]/?}. The Storage service writes none of these; remove it, then back up again." >&2
  exit 1
fi

scratch="$(mktemp -d)"
# Pass 1 copies into storage-pass1/; pass 2, under the stop, builds the real storage/ beside it. Both link unchanged files
# from the base, and pass 2 also from pass 1. Nothing is ever written into a file that another directory already links:
# rsync does not consult --link-dest for a destination file that exists, and for one whose size and time match but whose
# extended attributes or mode differ it sets them on the existing path, in place, which for a hard link changes the file of
# the base and of every older backup that shares it. A fresh destination cannot have that problem: a file that differs is
# created anew, a file that matches is linked.
pass1="$stage/storage-pass1"
pass1_options=(-rptX)
if [[ "$base_name" != none ]]; then pass1_options+=("--link-dest=$parent/$base_name/storage"); fi
pass2_options=("${pass1_options[@]}" "--link-dest=$pass1")
started=$SECONDS

# Free-space preflight, with the API up and before pass 1 writes anything. The disk must hold the new copy at its peak, the dump
# next to it and a little working room (compose.env, the catalog files, the manifest, signing, 256 MiB), and still keep a reserve
# beyond that, so that taking a backup never fills the disk the database lives on.
#   with a base:    need = 2 x new + dump + 256 MiB. new = what pass 1 would copy, from a dry run of the same rsync (the files linked
#                   from the base cost nothing) plus 4 KiB for each folder of the tree (folders cannot be hard links, and pass 1 and
#                   pass 2 each build them); pass 1 and the final pass each add the new files, and the final pass can find as many
#                   again as pass 1 in the worst case, which is cheap when only a few files are new.
#   without a base: need = tree + 10% + dump + 256 MiB (the whole live tree is counted once, du -sb). Pass 2 links everything pass 1
#                   copied and the Storage service never rewrites a file in place, so the peak is the tree once; the 10% is for the
#                   folders of the second tree and for what is uploaded meanwhile. The same count is used when the dry run fails
#                   (new files unknown, so the whole tree stands in for them).
#   dump:           1.5 x the larger of 64 MiB and the dump of the base; with no base, the database's own size in place of the dump
#                   (the dump is compressed, so this is generous).
# A figure that cannot be read is counted as 0 (the dump's floor of 64 MiB still applies). The free space is the exception: it is
# read with df, else with stat -f, and when neither answers the backup is refused (the guard is never silently off); when stat
# had to stand in for df, a WARNING line on standard error says so, and scripts/watch-daily.sh passes it on as backup_warning.
mib() { echo $(((${1} + 1048575) / 1048576)); }
reserve_mb="${WAREHOUSE_BACKUP_RESERVE_MB:-2048}"
[[ "$reserve_mb" =~ ^[0-9]{1,9}$ ]] || { echo "Refusing: WAREHOUSE_BACKUP_RESERVE_MB must be a whole number of MiB (it is '$reserve_mb'). Nothing was stopped." >&2; exit 1; }
delta=''
dirs=''
counted=tree
if [[ "$base_name" != none ]]; then
  rc=0
  stats="$(LC_ALL=C rsync "${pass1_options[@]}" -n --stats "$storage/" "$pass1/" 2>/dev/null)" || rc=$?
  if ((rc == 0 || rc == 24)); then
    delta="$(sed -n 's/^Total transferred file size: \([0-9][0-9,.]*\) bytes.*$/\1/p' <<<"$stats" | tr -d ',.' | tail -n 1)"
    dirs="$(sed -n 's/^Number of files: .*[(, ]dir: \([0-9][0-9,.]*\)[,)].*$/\1/p' <<<"$stats" | tr -d ',.' | tail -n 1)"
  fi
  if [[ "$delta" =~ ^[0-9]{1,15}$ ]]; then
    counted=new
    [[ "$dirs" =~ ^[0-9]{1,12}$ ]] || dirs=0
    delta=$((delta + dirs * 4096))
  fi
fi
if [[ "$counted" == tree ]]; then
  delta="$(du -sb -- "$storage" 2>/dev/null | cut -f1 || true)"
  if ! [[ "$delta" =~ ^[0-9]{1,15}$ ]]; then echo 'Warning: could not measure the stored files; the free-space check counts them as 0.' >&2; delta=0; fi
fi
dump_basis=''
if [[ "$base_name" != none && -f "$parent/$base_name/database.dump" ]]; then
  dump_basis="$(stat -c %s -- "$parent/$base_name/database.dump" 2>/dev/null || true)"
else
  dump_basis="$(compose exec -T db psql -X -A -t -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -c "SELECT pg_database_size('postgres')" 2>/dev/null | tr -d '[:space:]' || true)"
fi
[[ "$dump_basis" =~ ^[0-9]{1,15}$ ]] || dump_basis=0
dump=$(((dump_basis > 67108864 ? dump_basis : 67108864) * 3 / 2))
if [[ "$counted" == new ]]; then
  need=$((2 * delta + dump + 268435456))
  need_text="2 x $(mib "$delta") MiB of new stored files and folders + $(mib "$dump") MiB for the database dump + 256 MiB of working room"
else
  margin=$((delta / 10))
  need=$((delta + margin + dump + 268435456))
  need_text="$(mib "$delta") MiB of stored files, counted once + $(mib "$margin") MiB margin (10%) + $(mib "$dump") MiB for the database dump + 256 MiB of working room"
fi
# Free space for the user the backup runs as: df first; when it gives no number (a df without --output, an odd mount), stat -f
# (free blocks for a non-root user x block size, which is what df reports). Neither: refuse, nothing has been stopped.
avail="$(df -B1 --output=avail -- "$parent" 2>/dev/null | tail -n 1 | tr -d ' ' || true)"
space_probe=df
if ! [[ "$avail" =~ ^[0-9]{1,18}$ ]]; then
  avail=''
  space_probe='stat -f'
  fs_blocks="$(stat -f -c '%a %S' -- "$parent" 2>/dev/null || true)"
  if [[ "$fs_blocks" =~ ^([0-9]{1,12})\ ([0-9]{1,6})$ ]]; then avail=$((BASH_REMATCH[1] * BASH_REMATCH[2])); fi
fi
if [[ -z "$avail" ]]; then
  echo "Refusing: could not read the free space of $parent (df and stat -f both failed), so the backup cannot be checked to fit. Nothing was stopped. See docs/TROUBLESHOOTING.md, \"backup refused: not enough free space\"." >&2
  exit 1
fi
if [[ "$space_probe" != df ]]; then
  echo "WARNING: df gave no free space for $parent, so stat -f was used for the free-space check; find out why df fails there (docs/TROUBLESHOOTING.md, \"backup refused: not enough free space\")." >&2
fi
if ((avail < need + 10#$reserve_mb * 1048576)); then
  echo "Refusing: not enough free space in $parent: a backup needs about $(mib "$need") MiB ($need_text) plus a reserve of $((10#$reserve_mb)) MiB, but only $((avail / 1048576)) MiB are free. Nothing was stopped. See docs/TROUBLESHOOTING.md, \"backup refused: not enough free space\"." >&2
  exit 1
fi
preflight_lines="preflight_need_mb=$(mib "$need")"$'\n'"preflight_avail_mb=$((avail / 1048576))"$'\n'

# Pass 1, with the API up: most of the copy. Files the Storage service writes or removes meanwhile (rsync exit 24: a file
# vanished) are settled by pass 2 under the stop; any other failure ends the backup here, before anything is stopped.
rc=0
rsync "${pass1_options[@]}" "$storage/" "$pass1/" || rc=$?
if ((rc != 0 && rc != 24)); then
  echo "Refusing: copying the object storage failed (rsync exit $rc). Nothing was stopped." >&2
  exit 1
fi

# Stop ingress first, then all services that can write the database or object
# storage. Capture only running services so the cleanup never starts an optional
# service the operator had intentionally stopped. Ingress is both gateways: the LAN one only if it runs.
for service in gateway functions rest storage supavisor; do
  id=$(compose ps -q "$service")
  if [[ -n "$id" && "$(docker inspect --format '{{.State.Running}}' "$id")" == true ]]; then restart+=("$service"); fi
done
lan_id=$(compose --profile lan ps -q gateway-lan)
if [[ -n "$lan_id" && "$(docker inspect --format '{{.State.Running}}' "$lan_id")" == true ]]; then lan_stopped=yes; fi
stopped=$SECONDS
if [[ "$lan_stopped" == yes ]]; then compose --profile lan stop gateway-lan; fi
for service in "${restart[@]}"; do compose stop "$service"; done

echo 'Creating transaction-consistent logical database dumps.'
# Owners are kept so scripts/restore.sh can replay the dump in place with the
# original ownership; scripts/verify-restore.sh still restores it with --no-owner.
compose exec -T db pg_dump -U supabase_admin -d postgres \
  --format=custom --compress=6 > "$stage/database.dump"
# The pooler's _supabase database is not dumped: it holds only the pooler's own metadata, and the pooler writes its
# tenant again at every start (volumes/pooler/pooler.exs). Backups from before this change carry _supabase.dump;
# restore.sh and verify-restore.sh skip it.
compose exec -T db psql -X -q -v ON_ERROR_STOP=1 -U supabase_admin -d postgres \
  < "$ROOT/scripts/backup-integrity.sql" > "$stage/integrity.txt"
compose exec -T db psql -X -A -t -v ON_ERROR_STOP=1 -U supabase_admin -d postgres \
  -c "SELECT rolname FROM pg_roles WHERE rolname !~ '^pg_' ORDER BY rolname" > "$stage/roles.txt"
# Object catalog as <bucket>/<name>/<version>: every entry must exist as a path
# suffix inside the storage tree (storage.manifest). Byte order keeps the listing diffable after restore.
compose exec -T db psql -X -A -t -v ON_ERROR_STOP=1 -U supabase_admin -d postgres \
  -c "SELECT p FROM (SELECT bucket_id||'/'||name||COALESCE('/'||version,'') AS p FROM storage.objects) s ORDER BY p COLLATE \"C\"" > "$stage/storage_objects.txt"

# Pass 2, under the stop: storage/ is made equal to the live storage at the same instant as the dump and the catalog. What
# pass 1 copied and still matches is linked into it; what changed since (new, or changed attributes) is copied; what the
# service removed since is simply not there. Every failure counts, vanished files included: nothing writes any more.
if ! final="$(rsync "${pass2_options[@]}" --itemize-changes "$storage/" "$stage/storage/")"; then
  echo 'Refusing: the final pass of the object storage copy failed.' >&2
  exit 1
fi
final_copied="$(grep -Ec '^(>f|cf)' <<<"$final" || true)"
# A second, dry run of the same command must have nothing left to do. It catches a destination that drops extended
# attributes or modification times, or cannot hold hard links, which the first run would not report.
if ! leftover="$(rsync "${pass2_options[@]}" -n --delete --itemize-changes "$storage/" "$stage/storage/")" || [[ -n "$leftover" ]]; then
  echo 'First differences between the live storage and the copy:' >&2
  head -n 5 <<<"$leftover" >&2
  echo 'Refusing: the copy of the object storage is not identical to the live storage after the final pass (the backup destination may not keep extended attributes or modification times).' >&2
  exit 1
fi
bad="$(unsafe_entry)"
[[ -z "$bad" ]] || { echo "Refusing: a link or special file appeared in the object storage: ${bad//[^[:print:]]/?}." >&2; exit 1; }

# The services are only needed stopped for the dump and the final pass; everything below reads the finished stage.
if ((${#restart[@]})); then compose up -d --no-recreate --no-deps --wait --wait-timeout 180 "${restart[@]}"; restart=(); fi
lan_back
stop_seconds=$((SECONDS - stopped))

# The first pass's tree has done its job (everything pass 2 still needed from it is linked into storage/). What it holds that
# storage/ does not is what the Storage service removed in the meantime; with it gone the link count of a file in storage/ is
# the number of backups that share it.
list_files() { (cd "$1" && find . -type f -printf '%P\n') | LC_ALL=C sort; }
list_files "$pass1" > "$scratch/pass1.list"
list_files "$stage/storage" > "$scratch/present"
removed_in_final="$(LC_ALL=C comm -23 "$scratch/pass1.list" "$scratch/present" | wc -l)"
final_changes=$((final_copied + removed_in_final))
find "$pass1" -type d -exec chmod u+rwx {} +
rm -rf -- "$pass1"

cp "$state/config/compose.env" "$stage/compose.env"
cp "$state/public/instance.json" "$stage/instance.json"
chmod 600 "$stage/compose.env" "$stage/instance.json"
# The central sign-in key set (public keys only) that setup.sh --central-jwks-file copied into the
# state. compose.env keeps naming it, so db:restore-host must be able to put it back: without it the
# restored host offers central sign-in and every exchange fails. Absent for an installation that
# fetches the keys or has no central sign-in.
optional_files=()
key_file="$state/public/central-jwks.json"
if [[ -e "$key_file" || -L "$key_file" ]]; then
  [[ -f "$key_file" && ! -L "$key_file" ]] || { echo "Refusing: $key_file is not a regular file." >&2; exit 1; }
  cp "$key_file" "$stage/central-jwks.json"
  chmod 600 "$stage/central-jwks.json"
  optional_files+=(central-jwks.json)
fi
# The optional letterhead image of the document PDFs (setup.sh --letterhead-file): public/letterhead.jpg or letterhead.png.
# compose.env names it (LETTERHEAD_FILE), so a lost-host restore must be able to put it back. Absent for plain PDFs.
for letterhead in letterhead.jpg letterhead.png; do
  letterhead_file="$state/public/$letterhead"
  if [[ -e "$letterhead_file" || -L "$letterhead_file" ]]; then
    [[ -f "$letterhead_file" && ! -L "$letterhead_file" ]] || { echo "Refusing: $letterhead_file is not a regular file." >&2; exit 1; }
    cp "$letterhead_file" "$stage/$letterhead"
    chmod 600 "$stage/$letterhead"
    optional_files+=("$letterhead")
  fi
done
# The tunnel credential kept by scripts/tunnel.sh, so db:restore-host can bring the
# public address back on a new host. Only its known regular files are copied.
tunnel_files=()
if [[ -d "$state/config/tunnel" && ! -L "$state/config/tunnel" ]]; then
  mkdir -m 700 "$stage/tunnel"
  for file in config.yml credentials.json token; do
    path="$state/config/tunnel/$file"
    [[ -e "$path" || -L "$path" ]] || continue
    [[ -f "$path" && ! -L "$path" ]] || { echo "Refusing: $path is not a regular file." >&2; exit 1; }
    cp "$path" "$stage/tunnel/$file"
    tunnel_files+=("tunnel/$file")
  done
fi

# The manifest: the sha256 of every file of the tree, by path relative to storage/, in byte order. The stage is not
# written to any more and nothing else reads it yet, so this runs with the API up. A file that cannot be read is left out of
# the output (sha256sum reports it and goes on); it is dealt with below.
hash_rc=0
(cd "$stage/storage" && find . -type f -printf '%P\0' | LC_ALL=C sort -z | xargs -0 -r sha256sum --) > "$scratch/manifest.all" 2> "$scratch/hash.err" || hash_rc=$?
(cd "$stage/storage" && find . -type f -links +1 -printf '%P\n') | LC_ALL=C sort > "$scratch/linked"
: > "$scratch/damaged"
# A file shared with the base (a hard link: the same bytes, not a copy) must hash as the base's manifest says, and must be
# readable. If it does not, the shared copy changed in place since that backup was made (bit rot) or cannot be read (a disk
# error); rsync would go on linking it, and this manifest would sign the damaged bytes. The base manifest is trusted: the base
# passed its signature check above. Such files are not linked into this backup: they are copied again from the live storage
# (below). A shared file that the base manifest does not list at all is handled the same way.
if [[ "$base_name" != none && -s "$scratch/linked" ]]; then
  awk 'FILENAME == ARGV[1] { linked[$0] = 1; next }
       FILENAME == ARGV[2] { have[substr($0, 67)] = substr($0, 1, 64); next }
       { now[substr($0, 67)] = substr($0, 1, 64) }
       END { for (p in linked) if (!(p in now) || !(p in have) || now[p] != have[p]) print p }' \
    "$scratch/linked" "$parent/$base_name/storage.manifest" "$scratch/manifest.all" | LC_ALL=C sort > "$scratch/damaged"
fi
# Every other file must have been read: one that is not is a fault of the new copy itself (the backup disk).
if ((hash_rc != 0)); then
  LC_ALL=C comm -23 "$scratch/present" <(LC_ALL=C cut -b67- "$scratch/manifest.all" | LC_ALL=C sort) | LC_ALL=C comm -23 - "$scratch/damaged" > "$scratch/unreadable"
  if [[ -s "$scratch/unreadable" ]]; then
    head -n 5 "$scratch/hash.err" >&2
    first_unreadable="$(head -n 1 "$scratch/unreadable")"
    echo "Refusing: $(wc -l < "$scratch/unreadable") file(s) of the new backup could not be read back to take their checksum (a failing backup disk?), first: ${first_unreadable//[^[:print:]]/?}." >&2
    exit 1
  fi
fi
rot_repaired=0
rot_names=()
if [[ -s "$scratch/damaged" ]]; then
  rot_repaired="$(wc -l < "$scratch/damaged")"
  mapfile -t rot_names < <(head -n 100 "$scratch/damaged")
  tr '\n' '\0' < "$scratch/damaged" > "$scratch/damaged.z"
  # Unlink only: the file itself stays with the base and the older backups. Then a fresh copy from the live storage.
  while IFS= read -r path; do rm -f -- "$stage/storage/$path"; done < "$scratch/damaged"
  repair_rc=0
  rsync -ptX --from0 --files-from="$scratch/damaged.z" "$storage/" "$stage/storage/" 2> "$scratch/repair.err" || repair_rc=$?
  (cd "$stage/storage" && xargs -0 -r sha256sum -- < "$scratch/damaged.z") > "$scratch/repaired.sums" 2>/dev/null || true
  # Each fresh copy must be what the base recorded for that path (so the live file is the good one and the shared copy was
  # the damaged one), and the copy must be whole, attributes included.
  awk 'FILENAME == ARGV[1] { have[substr($0, 67)] = substr($0, 1, 64); next }
       FILENAME == ARGV[2] { got[substr($0, 67)] = substr($0, 1, 64); next }
       { if (!($0 in got)) print "unreadable\t" $0; else if (($0 in have) && have[$0] != got[$0]) print "differs\t" $0 }' \
    "$parent/$base_name/storage.manifest" "$scratch/repaired.sums" "$scratch/damaged" > "$scratch/repair.bad"
  stale="$(rsync -ptXn --from0 --files-from="$scratch/damaged.z" --itemize-changes "$storage/" "$stage/storage/" 2>/dev/null | grep -E '^(.f|[<>ch]f)' | head -n 5 || true)"
  if [[ -s "$scratch/repair.bad" || "$repair_rc" != 0 || -n "$stale" ]]; then
    echo "Files shared with $base_name no longer have the checksum recorded for them there, and the live storage does not give a good copy of them either (it is missing, unreadable, or differs from that checksum):" >&2
    { if [[ -s "$scratch/repair.bad" ]]; then cut -f2 "$scratch/repair.bad"; else cat "$scratch/damaged"; fi | head -n 10 | sed 's/^/  /' >&2; } || true
    [[ ! -s "$scratch/repair.err" ]] || head -n 3 "$scratch/repair.err" >&2
    # A live file that exists but differs from the checksum the base recorded: one of the two is damaged, and the base
    # would stop every later night in the same way. Make the next backup copy everything instead of linking from it.
    if grep -q '^differs' "$scratch/repair.bad"; then
      printf '%s\n' "$base_name" >> "$rejected_bases"
      note="The next backup copies all stored files again instead of linking them from $base_name."
    else
      note='Nothing is recorded; back up again once the live files are readable.'
    fi
    echo "Refusing: the stored files cannot be backed up as they are. Repair the files named above as docs/TROUBLESHOOTING.md describes (\"storage file fails its checksum\"). $note" >&2
    exit 1
  fi
  # The manifest without the old lines of these files, plus the lines of the fresh copies, in byte order of the path.
  awk 'FILENAME == ARGV[1] { drop[$0] = 1; next } !(substr($0, 67) in drop)' "$scratch/damaged" "$scratch/manifest.all" > "$scratch/manifest.kept"
  cat "$scratch/manifest.kept" "$scratch/repaired.sums" | LC_ALL=C sort -t ' ' -k3 > "$stage/storage.manifest"
else
  cp "$scratch/manifest.all" "$stage/storage.manifest"
fi
read -r storage_files storage_bytes storage_new_bytes < <(cd "$stage/storage" && find . -type f -printf '%s %n\n' | awk '{ f++; b += $1; if ($2 == 1) n += $1 } END { print f + 0, b + 0, n + 0 }')
rot_lines=''
for name in "${rot_names[@]}"; do rot_lines+="rot_repaired_file=$name"$'\n'; done

cat > "$stage/metadata.txt" <<EOF
format=warehouse-backup-v6
created_at_utc=$timestamp
source_commit=${source_commit:-unknown}
database_image=$pin
link_base=$base_name
storage_files=$storage_files
storage_bytes=$storage_bytes
storage_new_bytes=$storage_new_bytes
rot_repaired=$rot_repaired
${rot_lines}stop_seconds=$stop_seconds
duration_seconds=$((SECONDS - started))
${preflight_lines}consistency=write-facing services stopped during the database dump and the final pass of the storage copy
EOF
(cd "$stage" && sha256sum database.dump storage.manifest storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt "${optional_files[@]}" "${tunnel_files[@]}" > SHA256SUMS)
# The signature covers SHA256SUMS and so every file; the key itself is never copied into the backup.
backup_sign_dir "$stage" "$BACKUP_KEY"
# Never chmod inside storage/: its files are shared (hard links) with earlier backups.
find "$stage" -mindepth 1 -path "$stage/storage" -prune -o -type f -exec chmod 600 {} +
find "$stage" -mindepth 1 -path "$stage/storage" -prune -o -type d -exec chmod 700 {} +
mv "$stage" "$destination"
human() { numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "$1 bytes"; }
if [[ "$base_name" == none ]]; then linked="no earlier tree backup to link from"; else linked="linked from $base_name"; fi
echo "Object storage: $storage_files files, $(human "$storage_new_bytes") new, $linked."
echo "Services were stopped for ${stop_seconds}s ($final_changes files copied or removed in the final pass); the backup took $((SECONDS - started))s."
echo "Backup created at $destination"
echo 'Treat this directory as sensitive and test every retained backup with db:verify-restore.'
echo "It is signed with $state/config/backup.key; keep a copy of that key away from this machine and from the backup drive."
# Last on standard error, in this one shape: scripts/watch-daily.sh passes the sentence on to the daily status.
if ((rot_repaired > 0)); then
  echo "The stored files below had a damaged copy in $base_name (first $((rot_repaired < 10 ? rot_repaired : 10)) of $rot_repaired shown):" >&2
  printf '  %s\n' "${rot_names[@]:0:10}" >&2
  echo "WARNING: $rot_repaired $([[ $rot_repaired == 1 ]] && echo file || echo files) re-copied: backup $base_name has a damaged copy. This backup holds good copies from the live storage; $base_name and any older backup that shares them still hold the damaged ones. Check it: npm run db:verify-restore -- $parent/$base_name (docs/TROUBLESHOOTING.md, \"storage file fails its checksum\")." >&2
fi

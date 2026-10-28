#!/usr/bin/env bash
# Replace this instance's database and stored objects in place from a
# warehouse-backup-v5 or -v6 directory created by scripts/backup.sh on the same instance.
# Destructive by design: requires --yes, stopped services, a checkout that contains every migration the backup applied (the way
# back from an upgrade is this command after the old release is checked out) and a backup that passes
# scripts/verify-restore.sh, signature included. The replaced data directories are
# kept for rollback. Formats v5 (storage.tar.gz) and v6 (a storage/ tree) are accepted; an older
# format is refused, and so is a backup made on the earlier supabase/postgres image
# (scripts/backup-image.sh). The stored files keep their modes and, from v6 on, their extended
# attributes (the Storage service keeps content type and cache control in user.supabase.*); a v5
# backup holds none, and neither may a v6 one, so once the services run a sample of the restored
# files is looked at and, when any has no content type, the attributes are set again from the
# catalog (scripts/storage-retag.sh --if-missing).
# --allow-unsigned is only for a lost backup key; a backup whose signature file
# is missing is refused while this installation's key is available.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
# usage [0]: with 0 (an explicit --help) the text goes to standard output and the exit status is 0; otherwise it is an error.
usage() { if [[ "${1:-}" == 0 ]]; then echo 'Usage: npm run db:restore -- --yes PATH_TO_BACKUP [--restore-config] [--allow-unsigned]   (--allow-unsigned: only for when the backup key is lost)'; exit 0; fi; echo 'Usage: npm run db:restore -- --yes PATH_TO_BACKUP [--restore-config] [--allow-unsigned]   (--allow-unsigned: only for when the backup key is lost)' >&2; exit 1; }

confirm=false
restore_config=false
# --relocated is used by scripts/restore-host.sh, which built this state from the
# backup itself: compose.env may then differ only in the three state-path lines.
relocated=false
allow_unsigned=false
backup=''
while (($#)); do
  case "$1" in
    --yes) confirm=true ;;
    --restore-config) restore_config=true ;;
    --relocated) relocated=true ;;
    --allow-unsigned) allow_unsigned=true ;;
    -h|--help) usage 0 ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *) [[ -z "$backup" ]] || usage; backup="$1" ;;
  esac
  shift
done
[[ -n "$backup" ]] || usage
[[ "$relocated" != true || "$restore_config" != true ]] || usage
if [[ "$confirm" != true ]]; then
  echo 'Refusing: in-place restore replaces the database and stored objects of this instance. Pass --yes to confirm.' >&2
  exit 1
fi
[[ -d "$backup" && ! -L "$backup" ]] || { echo "Backup directory not found: $backup" >&2; exit 1; }
backup="$(realpath -e "$backup")"
# shellcheck source=scripts/backup-image.sh
source "$ROOT/scripts/backup-image.sh"
# Formats v5 and v6 are accepted. A refusal needs no trust in metadata.txt, so this comes before the signature check.
backup_check_format "$backup" || exit 1
format="$BACKUP_FORMAT"
backup_check_database_image "$backup" || exit 1

# shellcheck source=scripts/operator-lock.sh
source "$ROOT/scripts/operator-lock.sh"
state="$(operator_state)"
[[ -f "$state/config/compose.env" && -f "$state/public/instance.json" && -d "$state/data/db" && -d "$state/data/storage" ]] || {
  echo 'Set WAREHOUSE_STATE_DIR to the installed operator state.' >&2; exit 1;
}
[[ "$backup" != "$state/data"/* ]] || { echo 'Refusing: the backup must not live inside the state data directory that is being replaced.' >&2; exit 1; }
operator_lock "$state"

# 1. Nothing may hold the data directories: the operator stops the project first.
compose config --quiet
if [[ -n "$(compose --profile '*' ps -q)" ]]; then
  echo 'Refusing: operator services are running. Run bash stop.sh first, then retry the restore.' >&2
  exit 1
fi

# 2. The backup must be the one this installation wrote: checksums and the
#    signature made with the backup key are checked before any of it is read.
# shellcheck source=scripts/backup-key.sh
source "$ROOT/scripts/backup-key.sh"
[[ -n "${WAREHOUSE_BACKUP_KEY_FILE:-}" ]] || export WAREHOUSE_BACKUP_KEY_FILE="$state/config/backup.key"
# The files of a v6 storage/ tree are hashed by scripts/verify-restore.sh in step 3, before anything is moved; hashing them
# here as well would read the whole tree twice.
BACKUP_TREE=skip
backup_authenticate "$backup" "$allow_unsigned" || exit 1
backup_check_layout "$backup" || exit 1
BACKUP_TREE=check
if [[ "$format" == warehouse-backup-v5 ]]; then storage_part=storage.tar.gz; else storage_part=storage.manifest; fi
for file in database.dump "$storage_part" storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt SHA256SUMS; do
  [[ -f "$backup/$file" && ! -L "$backup/$file" ]] || { echo "Incomplete backup: missing $file" >&2; exit 1; }
done
# A backup made before the pooler became optional also holds _supabase.dump (the pooler's own metadata). It is not
# replayed: the pooler writes its tenant again when it starts, and turning it on creates the database.
if [[ -e "$backup/_supabase.dump" ]]; then
  echo 'Note: the backup contains _supabase.dump (the pooler tenant). It is skipped: the pooler recreates its tenant when it starts.'
fi
# This checkout must contain every migration the backup has applied, unchanged, before anything here is touched: restore.sh drops
# the application database below and only then runs scripts/migrate.sh, which refuses a ledger it does not know, so a checkout that
# is older than the backup (the wrong release checked out for the way back) would leave the facility without a database. The same
# check, with the same wording, as scripts/restore-host.sh makes before it builds a state.
count="$(sed -n 's/^migration_count=//p' "$backup/integrity.txt")"
fingerprint="$(sed -n 's/^migration_fingerprint=//p' "$backup/integrity.txt")"
[[ "$count" =~ ^[0-9]+$ && "$fingerprint" =~ ^[0-9a-f]{64}$ ]] || { echo 'The backup integrity report records no migration ledger.' >&2; exit 1; }
mapfile -t migrations < <(find "$ROOT/migrations" -maxdepth 1 -type f -name '*.sql' -printf '%f\n' | LC_ALL=C sort)
if ((count > ${#migrations[@]})); then
  echo "Refusing: the backup has $count migrations and this checkout only ${#migrations[@]}. Check out a release at least as new as the backup (metadata.txt source_commit=$(sed -n 's/^source_commit=//p' "$backup/metadata.txt"))." >&2
  exit 1
fi
local_fingerprint="$(for m in "${migrations[@]:0:count}"; do printf '%s:%s\n' "$m" "$(sha256sum "$ROOT/migrations/$m" | cut -d' ' -f1)"; done | head -c -1 | sha256sum | cut -d' ' -f1)"
if [[ "$local_fingerprint" != "$fingerprint" ]]; then
  echo 'Refusing: the migrations this backup applied differ from this checkout. Check out the release the backup was made with (metadata.txt source_commit), or a later one.' >&2
  exit 1
fi
# Likewise the Storage service: its image is part of this checkout, and an older one would start without complaint on a newer schema.
# shellcheck source=scripts/storage-schema.sh
source "$ROOT/scripts/storage-schema.sh"
storage_check_backup_head "$backup" || exit 1
# The identity is compared field by field (scripts/instance-identity.mjs), not the bytes: the capabilities, the supported versions and the
# display name may have changed since the backup. public/release.json and public/app-compat.json are not in a backup: setup.sh writes them.
if differing="$(node "$ROOT/scripts/instance-identity.mjs" compare "$backup/instance.json" "$state/public/instance.json")"; then :; else
  status=$?
  if ((status == 1)); then
    echo "Refusing: the backup instance.json differs from this state in its identity ($differing); in-place restore only replaces the instance that produced the backup." >&2
  else
    echo 'Refusing: the backup instance.json or the state instance.json cannot be read as an instance manifest (message above).' >&2
  fi
  exit 1
fi
# A backup taken before every database login had its own password lacks those
# lines (scripts/db-roles.mjs). This state's values are then the ones the restored
# database gets, so they are left out of the comparisons below; a value the backup
# does carry must match, as every other line must.
added_since=()
while IFS= read -r name; do
  grep -q "^$name=" "$backup/compose.env" || added_since+=("$name")
done < <(node "$ROOT/scripts/db-roles.mjs" names)
without_added() {
  if ((${#added_since[@]})); then grep -v -E "^($(IFS='|'; printf '%s' "${added_since[*]}"))=" || true; else cat; fi
}
# The pooler's switch and secrets are left out of every comparison below, on both sides: the restored database gets the
# values of this state, the pooler's tenant is not in the backup any more, and an old backup carries secrets that a
# state without the pooler no longer has.
without_pooler() { grep -v -E '^(POOLER_ENABLED|DB_PASSWORD_POOLER|SECRET_KEY_BASE|VAULT_ENC_KEY)=' || true; }
backup_env() { without_pooler < "$backup/compose.env"; }
backup_pooler="$(sed -n 's/^POOLER_ENABLED=//p' "$backup/compose.env" | head -n 1)"
state_pooler="$(sed -n 's/^POOLER_ENABLED=//p' "$state/config/compose.env" | head -n 1)"
if [[ "$restore_config" != true && "$backup_pooler" != "$state_pooler" ]]; then
  echo "Note: the pooler was '${backup_pooler:-unset}' when the backup was taken and is '${state_pooler:-unset}' in this installation. This installation's setting applies (the pooler role, schema and _supabase database are created or dropped to match it); run bash scripts/pooler.sh on or off afterwards if you want the other."
fi
if [[ "$restore_config" == true ]]; then
  for key in WAREHOUSE_PROJECT_NAME WAREHOUSE_DB_PATH WAREHOUSE_STORAGE_PATH WAREHOUSE_MANIFEST_PATH; do
    if [[ "$(sed -n "s/^$key=//p" "$backup/compose.env")" != "$(sed -n "s/^$key=//p" "$state/config/compose.env")" ]]; then
      echo "Refusing: $key in the backup configuration differs from this state; --restore-config only restores the same instance at the same path." >&2
      exit 1
    fi
  done
elif [[ "$relocated" == true ]]; then
  without_paths() { grep -v -E '^WAREHOUSE_(DB|STORAGE|MANIFEST)_PATH=' || true; }
  if ! cmp -s <(backup_env | without_paths) <(without_added < "$state/config/compose.env" | without_pooler | without_paths); then
    echo 'Refusing: config/compose.env differs from the backup copy in more than the state paths.' >&2
    exit 1
  fi
elif ! cmp -s <(backup_env) <(without_added < "$state/config/compose.env" | without_pooler); then
  echo 'Refusing: config/compose.env differs from the backup copy (keys rotated or configuration changed after it was taken). Pass --restore-config to restore the backup configuration together with its data, or use a backup taken after the change.' >&2
  exit 1
fi

# 3. The disposable restore proves checksums, archive safety, replay and integrity
#    before anything here is touched.
verify_args=()
if [[ "$allow_unsigned" == true ]]; then verify_args+=(--allow-unsigned); fi
bash "$ROOT/scripts/verify-restore.sh" "${verify_args[@]}" "$backup"

# The fresh cluster below is initialised by the db image of this checkout. `compose up` builds only an image that is
# missing, so a stale image (the previous PostgreSQL major, left from before a checkout of a new release) would start
# there and initialise the new cluster on the old server. The images whose recipe changed are rebuilt now, before
# anything is moved; if the db image is still not current afterwards, the restore stops with the data untouched.
db_image_stale() {
  local plan
  plan="$(compose --profile '*' config --format json | node "$ROOT/scripts/image-recipes.mjs" plan "$state/config/image-recipes.sha256")" \
    || { echo 'Refusing: could not check whether the db image matches this checkout. Nothing was moved.' >&2; exit 1; }
  printf '%s\n' "$plan" | cut -f1 | grep -qx db
}
if db_image_stale; then
  echo 'The db image does not match this checkout (the database version changed): rebuilding the images first (scripts/build-images.sh --from-release: the images of the release this checkout is at are pulled, the rest built here).'
  bash "$ROOT/scripts/build-images.sh" --from-release || { echo 'Refusing: the db image could not be rebuilt, so the restore would start the new cluster on the old PostgreSQL. Nothing was moved. Run bash scripts/build-images.sh --from-release, then retry.' >&2; exit 1; }
  if db_image_stale; then
    echo 'Refusing: the db image still does not match this checkout after the rebuild. Nothing was moved. Run bash scripts/build-images.sh --from-release, then retry.' >&2
    exit 1
  fi
fi

ts="$(date -u +%Y%m%dT%H%M%SZ)"
old_db="$state/data/db.pre-restore-$ts"
old_storage="$state/data/storage.pre-restore-$ts"
old_config="$state/config/compose.env.pre-restore-$ts"
for path in "$old_db" "$old_storage" "$old_config"; do
  [[ ! -e "$path" && ! -L "$path" ]] || { echo "Refusing: pre-restore path already exists: $path" >&2; exit 1; }
done
scratch="$(mktemp -d "${TMPDIR:-/tmp}/warehouse-inplace-restore.XXXXXX")"
phase='prepare'
finish() {
  status=$?
  trap - EXIT
  rm -rf "$scratch"
  if ((status != 0)) && [[ "$phase" == 'start services' ]]; then if command -v node >/dev/null 2>&1; then node "$ROOT/scripts/service-diagnostics.mjs" --unhealthy || true; else echo 'Service diagnostics skipped (node not on PATH): run node scripts/service-diagnostics.mjs --unhealthy' >&2; fi; fi
  if ((status != 0)) && [[ "$phase" != done ]]; then
    cat >&2 <<MSG
Restore failed during: $phase
MSG
    if [[ "$phase" == 'release files' ]]; then
      cat >&2 <<MSG
The database and the stored files ARE restored; only public/release.json and public/app-compat.json were not written (message above). Rerunning
bash setup.sh writes them and finishes the restore; the rollback below is needed only if you want to undo the whole restore.
Setup does not set the content type and cache control of the stored files again (the step after the services start): when setup has finished,
run npm run storage:retag -- --if-missing (npm run storage:retag sets them for every file).
MSG
    fi
    cat >&2 <<MSG
The replaced data was kept for rollback:
  $old_db
  $old_storage
MSG
    if [[ "$restore_config" == true ]]; then echo "  $old_config" >&2; fi
    cat >&2 <<MSG
Rollback: bash stop.sh
  rm -rf "$state/data/db" "$state/data/storage"   # may need sudo: files are owned by the container's postgres user
  mv "$old_db" "$state/data/db" && mv "$old_storage" "$state/data/storage"
MSG
    if [[ "$restore_config" == true ]]; then echo "  mv \"$old_config\" \"$state/config/compose.env\"" >&2; fi
    echo '  bash start.sh' >&2
  fi
  exit "$status"
}
trap finish EXIT

# The restored files are a second copy next to the replaced ones, which stay for rollback: the free space has to hold the
# stored files again (the size the backup recorded, else the size of its tarball) with a gigabyte to spare. Checked while
# nothing has been moved.
if [[ "$format" == warehouse-backup-v6 ]]; then
  tree_bytes="$(sed -n 's/^storage_bytes=//p' "$backup/metadata.txt" | head -n 1)"
else
  tree_bytes="$(stat -c %s -- "$backup/storage.tar.gz")"
fi
[[ "$tree_bytes" =~ ^[0-9]{1,15}$ ]] || { echo 'Refusing: the backup records no usable size for its stored files (storage_bytes= in metadata.txt). Nothing was moved.' >&2; exit 1; }
free_bytes="$(df -B1 --output=avail -- "$state/data" | tail -n 1 | tr -d ' ')"
if [[ "$free_bytes" =~ ^[0-9]+$ ]] && ((free_bytes < tree_bytes + 1073741824)); then
  echo "Refusing: restoring the stored files needs about $((tree_bytes / 1048576)) MiB plus 1 GiB of free space in $state/data, but only $((free_bytes / 1048576)) MiB are free. The earlier restores' kept data/storage.pre-restore-* directories hold space you can free once you have accepted them (docs/OPERATOR_INSTALL.md, \"In-place restore\"). Nothing was moved." >&2
  exit 1
fi

echo "Restoring $backup into $state (format $format, created $(sed -n 's/^created_at_utc=//p' "$backup/metadata.txt"))."
phase='move current data aside'
mv "$state/data/db" "$old_db"
mv "$state/data/storage" "$old_storage"
mkdir -m 700 "$state/data/db" "$state/data/storage"
phase='extract storage'
if [[ "$format" == warehouse-backup-v6 ]]; then
  # Safety (no links, exactly the manifest's files, every hash) was proven by verify-restore.sh. -p keeps the modes and -X the
  # extended attributes (content type, cache control), -t the modification times; the owner is the user running this restore.
  # The backup's files may be hard links shared with other backups: the restore copies, it never links the live storage.
  rsync -rptX --no-owner --no-group "$backup/storage/" "$state/data/storage/"
  # A second, dry run must find nothing to do: the copy is complete and kept every attribute.
  leftover="$(rsync -rptXn --no-owner --no-group --itemize-changes "$backup/storage/" "$state/data/storage/")"
  [[ -z "$leftover" ]] || { echo "The restored stored files differ from the backup after the copy (the disk may not keep extended attributes). First differences:" >&2; head -n 5 <<<"$leftover" >&2; exit 1; }
else
  # Archive safety (no absolute paths, no .., no links) was proven by verify-restore.sh.
  # -p keeps the archived modes so the storage container reads the files exactly as before. A v5 archive holds no extended
  # attributes (the earlier tar never saved them); --xattrs is passed so that an archive that does is restored whole, and the
  # attributes are set again from the catalog once the services run.
  tar --no-same-owner -p --xattrs --xattrs-include='user.*' -xzf "$backup/storage.tar.gz" -C "$state/data/storage"
fi
if [[ "$restore_config" == true ]]; then
  phase='restore configuration'
  cp "$state/config/compose.env" "$old_config"
  chmod 600 "$old_config"
  cp "$backup/compose.env" "$state/config/compose.env.restoring"
  chmod 600 "$state/config/compose.env.restoring"
  mv "$state/config/compose.env.restoring" "$state/config/compose.env"
  # What configure.mjs's existing-state branch does: a backup taken before every
  # database login had its own password gets them now, before the database starts.
  node "$ROOT/scripts/db-roles.mjs" add-missing "$state/config/compose.env"
  compose config --quiet
else
  # This state's own configuration stays; a login the state lacks gets its password before the database starts.
  node "$ROOT/scripts/db-roles.mjs" add-missing "$state/config/compose.env"
fi

# 4. Fresh cluster initialization from the pinned image, then logical replay with
#    the original owners. Role passwords come from compose.env through the init
#    scripts (and scripts/configure-db-roles.sql after the migrations); the backup
#    never contains them.
phase='initialize database'
compose up -d --wait --wait-timeout 180 db
db_psql() { compose exec -T db psql -X -q -v ON_ERROR_STOP=1 -U supabase_admin "$@"; }
db_restore() { compose exec -T db pg_restore -U supabase_admin --exit-on-error "$@"; }
compose cp "$backup/database.dump" db:/tmp/database.dump
phase='create missing roles'
# A role the backup names that the bootstrap did not create must exist before ownership and ACLs
# replay (the bootstrap makes the whole agreed set, so this is a safety net). Names arrive as COPY
# data, never as interpolated SQL.
{
  printf 'CREATE TEMP TABLE restore_roles (role_name name NOT NULL);\n'
  printf 'COPY restore_roles(role_name) FROM stdin;\n'
  grep -v '^$' "$backup/roles.txt" || true
  printf '\\.\n'
  cat <<'SQL'
DO $$
DECLARE missing_role name;
BEGIN
  FOR missing_role IN SELECT role_name FROM restore_roles LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = missing_role) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN', missing_role);
    END IF;
  END LOOP;
END $$;
SQL
} | db_psql -d postgres
phase='recreate application database'
# The application database is recreated from template0, the same template verify-restore.sh restores
# into, so the dump replays into an empty database. template1 is not used: a session attached to it
# right after start-up makes CREATE DATABASE fail, and template0 accepts no connections. Every
# non-extension object of the application database, including CREATE EXTENSION statements, is in
# the dump. Per-database settings are not, but none is set: the roles and their settings come from the bootstrap.
# Connected to template1 (the maintenance database of a cluster that has no _supabase before the pooler is turned on).
db_psql -d template1 -c 'DROP DATABASE postgres WITH (FORCE)' \
  -c 'CREATE DATABASE postgres OWNER supabase_admin TEMPLATE template0'
phase='restore database'
# Sections replay with the archived owners, as the storage service's own migrations require. ACLs
# are replayed last, once every object exists, exactly as verify-restore.sh does.
for section in pre-data data post-data; do
  db_restore -d postgres --no-acl --section="$section" /tmp/database.dump
done
# The ACL entries of the archive's table of contents ("ACL" and "DEFAULT ACL" in the type column; a decoy
# object merely named ACL is not one). Written to a file first, so a failing pg_restore is not hidden by a
# pipe; a dump of this version always holds ACL entries, so an empty list means a damaged archive.
acl_awk='$1 ~ /^[0-9]+;$/ && ($4 == "ACL" || ($4 == "DEFAULT" && $5 == "ACL")) { print }'
compose exec -T db sh -c 'pg_restore -l /tmp/database.dump > /tmp/restore.list && awk "$1" /tmp/restore.list > /tmp/acl.list && [ -s /tmp/acl.list ]' sh "$acl_awk" \
  || { echo 'Refusing: the database dump has no readable table of contents or lists no privileges (ACL entries).' >&2; exit 1; }
db_restore -d postgres -L /tmp/acl.list /tmp/database.dump
compose exec -T db rm -f /tmp/database.dump /tmp/acl.list /tmp/restore.list
phase='analyze'
# pg_dump 18 does not carry planner statistics (pg_dump before 18 never did): the restored tables are unanalyzed
# until autovacuum reaches them, and the first queries would plan on defaults. Analyze every database in stages
# (a quick pass first), before the services start. Runs on the loopback of the db container, as supabase_admin.
compose exec -T db vacuumdb -U supabase_admin --all --analyze-in-stages

# 5. The restored database must report exactly what the backup recorded.
phase='integrity comparison'
db_psql -d postgres < "$ROOT/scripts/backup-integrity.sql" > "$scratch/integrity.txt"
storage_integrity_align "$backup/integrity.txt" "$scratch/integrity.txt"
diff -u "$backup/integrity.txt" "$scratch/integrity.txt"

# 6. Apply migrations this checkout added after the backup (a no-op otherwise),
#    start everything and run the local doctor.
phase='migrations'
bash "$ROOT/scripts/migrate.sh" --operator
# public/release.json and public/app-compat.json describe this checkout, which after a rollback is not the release that wrote them.
phase='release files'
WAREHOUSE_STATE_DIR="$state" bash "$ROOT/scripts/release-info.sh"
# Every service login gets its password from compose.env again. While the pooler is on, this also creates its role, schema
# and _supabase database again (they are not in the backup) and sets its password.
phase='database logins'
bash "$ROOT/scripts/db-roles.sh" apply
phase='start services'
# The restore brings the stack up: the boot unit and the checker's self-healing may act again (stop.sh wrote this file).
rm -f -- "$state/config/stopped-by-operator"
# Without the LAN fallback: its faults never stop a restore (WAREHOUSE_COMPOSE_WITHOUT_LAN, scripts/compose.sh); lan.sh starts it after, as a warning.
WAREHOUSE_COMPOSE_WITHOUT_LAN=1 compose up -d --wait --wait-timeout 180
bash "$ROOT/scripts/lan.sh" start || echo 'Warning: the LAN fallback was not started (message above). The public services are up.' >&2
# Whatever the format, the restored files may carry no content type: a v5 backup holds no extended attributes, and neither
# does a v6 backup of files that had lost theirs, or a copy of one that went through a USB archive written before archives kept
# them. Such files would be served as application/octet-stream and no-cache. Look at up to 20 files; if any has none, set the
# attributes of every file again from the catalog (scripts/storage-retag.sh). The bytes are intact either way, so a failure
# here is a warning, not a failed restore (npm run storage:retag repeats it).
phase='storage metadata'
if ! bash "$ROOT/scripts/storage-retag.sh" --if-missing; then
  echo 'Warning: the storage metadata (content type, cache control) could not be checked or set again. The files are intact. Run: npm run storage:retag' >&2
fi
phase='doctor'
# --restore-config can bring back a compose.env that names a central key file (CENTRAL_JWKS_FILE) which this
# state no longer has: setup deletes public/central-jwks.json when central sign-in moves to an address or off,
# and this restore does not touch public/. Doctor then only warns, and the rerun that puts the file back is
# printed below. (restore-host sets the same variable itself for a backup that lacks the file.)
pending="${WAREHOUSE_CENTRAL_KEY_PENDING:-}"
key_rerun=false
if [[ "$restore_config" == true ]]; then
  key_name="$(sed -n 's/^CENTRAL_JWKS_FILE=//p' "$state/config/compose.env" | head -n 1)"
  if [[ -n "$key_name" && ! -e "$state/public/$key_name" && ! -L "$state/public/$key_name" ]]; then pending=yes; key_rerun=true; fi
fi
if ! WAREHOUSE_CENTRAL_KEY_PENDING="$pending" node "$ROOT/scripts/doctor.mjs" --local; then
  # A collation mismatch cannot be the cause here: the restore recreates postgres from template0 in this image, so it records this
  # image's current collation version.
  exit 1
fi
phase=done
cat <<MSG
In-place restore completed from $backup.
The replaced data was kept; remove it once the restored instance is accepted:
  $old_db
  $old_storage
MSG
if [[ "$restore_config" == true ]]; then echo "  $old_config"; fi
if [[ "$key_rerun" == true ]]; then
  issuer="$(sed -n 's/^CENTRAL_ISSUER=//p' "$state/config/compose.env" | head -n 1)"
  [[ "$issuer" =~ ^https://[A-Za-z0-9._:/-]+$ ]] || issuer='https://ISSUER'
  cat <<MSG
Central sign-in: the restored configuration reads its keys from public/$key_name, which this state does not have,
so central sign-in fails until you put the file back (doctor reports it as missing until then). Rerun setup with
your usual administrator inputs and the key set the association sent you; it keeps this identity and its data:
  bash setup.sh --operator --state-dir $state --admin-phone 91XXXXXXXXXX --admin-name 'ADMIN NAME' \\
    --central-issuer $issuer --central-jwks-file /absolute/path/to/association-jwks.json
MSG
fi
cat <<MSG
Rollback if needed: bash stop.sh, remove data/db and data/storage (sudo may be
required because PostgreSQL files belong to the container's postgres user), move
the kept directories back to data/db and data/storage, then bash start.sh.
MSG

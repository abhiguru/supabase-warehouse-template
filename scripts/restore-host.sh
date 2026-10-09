#!/usr/bin/env bash
# Rebuild a lost installation on a new host from one of its warehouse-backup-v4
# backups: the same instance identity, origin, keys, users and data, as at the
# moment of the backup. It never runs setup (which would mint a new identity):
# it creates a new state directory from the backup's own compose.env and
# instance.json, rewriting only the three state-path lines, and then hands over
# to scripts/restore.sh --relocated for the database and storage replay.
#
#   npm run db:restore-host -- --state-dir /srv/warehouse/acme --yes BACKUP
#
# BACKUP is a backup directory or a `.tar` archive written by backup-usb.sh
# (its `.tar.sha256` must sit next to it). Nothing outside the new state is
# changed; the source backup is only read.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() { echo 'Usage: npm run db:restore-host -- --state-dir ABSOLUTE_NEW_STATE --yes BACKUP_DIR_OR_TAR' >&2; exit 1; }
die() { echo "$*" >&2; exit 1; }

state='' confirm=false source=''
while (($#)); do
  case "$1" in
    --state-dir) (($# > 1)) || usage; state="$2"; shift 2 ;;
    --yes) confirm=true; shift ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *) [[ -z "$source" ]] || usage; source="$1"; shift ;;
  esac
done
[[ -n "$state" && -n "$source" ]] || usage
[[ "$confirm" == true ]] || die 'Refusing: restore-host makes this host answer as the backed-up warehouse, with its identity and keys. Make sure the original host is permanently off, then pass --yes.'
((EUID != 0)) || die 'Run restore-host as the installation user (a member of the docker group), not as root.'

# 1. The new state: an absolute, symlink-free path outside the checkout that is
#    absent or empty, under a parent that belongs to this user.
[[ "$state" =~ ^/[A-Za-z0-9._/-]+$ && "$state" != */ ]] || die "The state directory must be an absolute path of letters, digits, '.', '_', '-' and '/': $state"
[[ "$(realpath -m -- "$state")" == "$state" && "$(realpath -ms -- "$state")" == "$state" ]] || die "The state directory must be a normalised path without symlinks: $state"
checkout="$(realpath -- "$ROOT")"
[[ "$state" != "$checkout" && "$state" != "$checkout"/* ]] || die 'The state directory must be outside this checkout.'
if [[ -e "$state" || -L "$state" ]]; then
  [[ -d "$state" && ! -L "$state" && -z "$(ls -A -- "$state")" ]] || die "Refusing: $state already exists and is not empty. restore-host only creates a new installation; to restore an existing one use npm run db:restore."
fi
parent="$(dirname -- "$state")"
[[ -d "$parent" && "$(stat -c %u -- "$parent")" == "$(id -u)" ]] || die "The parent directory $parent must exist and belong to you: sudo install -d -m 0755 -o \"\$(id -un)\" -g \"\$(id -gn)\" $parent"
bash "$ROOT/scripts/check-readiness.sh" --operator
WAREHOUSE_STATE_DIR="$state" node "$ROOT/scripts/doctor.mjs" --host-preflight

# 2. The backup: an archive is checked against its .sha256 and unpacked next to
#    the new state (same filesystem, removed on any failure); a directory is read in place.
scratch=''
cleanup() { [[ -z "$scratch" ]] || rm -rf -- "$scratch"; }
trap cleanup EXIT
if [[ -f "$source" && "$source" == *.tar ]]; then
  archive="$(realpath -e -- "$source")"
  name="$(basename -- "$archive" .tar)"
  [[ "$name" =~ ^warehouse-[0-9]{8}T[0-9]{6}Z$ ]] || die "Not a backup archive name (warehouse-<utc>.tar): $archive"
  [[ -f "$archive.sha256" ]] || die "Missing checksum file $archive.sha256; refusing an unverified archive."
  (cd "$(dirname -- "$archive")" && sha256sum -c --quiet -- "$name.tar.sha256") || die "The archive does not match $name.tar.sha256; choose another backup."
  # Only regular files and directories under <name>/, no absolute paths or '..'.
  bad="$(tar -tvf "$archive" | awk -v n="$name" '{ t = substr($1, 1, 1); p = $NF } t != "-" && t != "d" { print; next } p != n && p != n "/" && index(p, n "/") != 1 { print; next } p ~ /(^|\/)\.\.(\/|$)/ { print }' | head -n 3)"
  [[ -z "$bad" ]] || die "Refusing an archive with unexpected entries: $bad"
  scratch="$(mktemp -d -- "$parent/.restore-host.XXXXXX")"
  tar --no-same-owner -xf "$archive" -C "$scratch"
  backup="$scratch/$name"
elif [[ -d "$source" && ! -L "$source" ]]; then
  backup="$(realpath -e -- "$source")"
  name="$(basename -- "$backup")"
else
  die "Backup not found (a backup directory or a warehouse-<utc>.tar): $source"
fi
[[ "$(sed -n 's/^format=//p' "$backup/metadata.txt" 2>/dev/null)" == warehouse-backup-v4 ]] || die 'Refusing: restore-host requires a warehouse-backup-v4 backup.'
for file in compose.env instance.json integrity.txt SHA256SUMS; do
  [[ -f "$backup/$file" && ! -L "$backup/$file" ]] || die "Incomplete backup: missing $file"
done
(cd "$backup" && sha256sum -c --quiet SHA256SUMS) || die 'Refusing: the backup does not match its SHA256SUMS.'
env_get() { sed -n "s/^$1=//p" "$backup/compose.env" | head -n 1; }
project="$(env_get WAREHOUSE_PROJECT_NAME)"
[[ "$project" =~ ^warehouse-[a-z0-9-]+$ ]] || die 'The backup configuration has no valid WAREHOUSE_PROJECT_NAME.'
original="$(env_get WAREHOUSE_DB_PATH)"; original="${original%/data/db}"
for key in WAREHOUSE_DB_PATH WAREHOUSE_STORAGE_PATH WAREHOUSE_MANIFEST_PATH; do
  [[ -n "$(env_get "$key")" ]] || die "The backup configuration lacks $key."
done

# 3. This checkout must contain every migration the backup has applied, unchanged.
count="$(sed -n 's/^migration_count=//p' "$backup/integrity.txt")"
fingerprint="$(sed -n 's/^migration_fingerprint=//p' "$backup/integrity.txt")"
[[ "$count" =~ ^[0-9]+$ && "$fingerprint" =~ ^[0-9a-f]{64}$ ]] || die 'The backup integrity report records no migration ledger.'
mapfile -t migrations < <(find "$ROOT/migrations" -maxdepth 1 -type f -name '*.sql' -printf '%f\n' | LC_ALL=C sort)
((count <= ${#migrations[@]})) || die "Refusing: the backup has $count migrations and this checkout only ${#migrations[@]}. Check out a release at least as new as the backup (metadata.txt source_commit=$(sed -n 's/^source_commit=//p' "$backup/metadata.txt"))."
local_fingerprint="$(for m in "${migrations[@]:0:count}"; do printf '%s:%s\n' "$m" "$(sha256sum "$ROOT/migrations/$m" | cut -d' ' -f1)"; done | head -c -1 | sha256sum | cut -d' ' -f1)"
[[ "$local_fingerprint" == "$fingerprint" ]] || die 'Refusing: the migrations this backup applied differ from this checkout. Check out the release the backup was made with (metadata.txt source_commit), or a later one.'

# 4. A new host has no trace of this installation's containers.
[[ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$project")" ]] || die "Refusing: containers of $project already exist on this host. This is not a fresh host for this installation (use npm run db:restore on the original state instead)."

# 5. Build the state beside its final path and rename it into place, as setup does.
stage="$(mktemp -d -- "$state.restoring-XXXXXX")"
trap 'cleanup; rm -rf -- "$stage"' EXIT
for dir in config public data data/db data/storage backups; do mkdir -m 0700 "$stage/$dir"; done
chmod 0700 "$stage"
if [[ -n "$scratch" ]]; then mv -- "$backup" "$stage/backups/$name"; else cp -a -- "$backup" "$stage/backups/$name"; fi
awk -v s="$state" '
  /^WAREHOUSE_DB_PATH=/ { print "WAREHOUSE_DB_PATH=" s "/data/db"; next }
  /^WAREHOUSE_STORAGE_PATH=/ { print "WAREHOUSE_STORAGE_PATH=" s "/data/storage"; next }
  /^WAREHOUSE_MANIFEST_PATH=/ { print "WAREHOUSE_MANIFEST_PATH=" s "/public/instance.json"; next }
  { print }' "$stage/backups/$name/compose.env" > "$stage/config/compose.env"
chmod 0600 "$stage/config/compose.env"
install -m 0644 -- "$stage/backups/$name/instance.json" "$stage/public/instance.json"
# The tunnel credential, when the backup carries one (scripts/tunnel.sh adopt).
tunnel=false
if [[ -d "$stage/backups/$name/tunnel" ]]; then
  mkdir -m 0700 "$stage/config/tunnel"
  for file in config.yml credentials.json token; do
    src="$stage/backups/$name/tunnel/$file"
    [[ -f "$src" && ! -L "$src" ]] || continue
    if [[ "$file" == config.yml ]]; then
      awk -v c="$state/config/tunnel/credentials.json" '/^credentials-file:/ { print "credentials-file: " c; next } { print }' "$src" > "$stage/config/tunnel/config.yml"
      chmod 0600 "$stage/config/tunnel/config.yml"
    else
      install -m 0600 -- "$src" "$stage/config/tunnel/$file"
    fi
    tunnel=true
  done
fi
[[ ! -d "$state" ]] || rmdir -- "$state"
mv -T -- "$stage" "$state"
trap cleanup EXIT

echo "Created $state from $name (instance $(sed -n 's/.*"instanceId": *"\([^"]*\)".*/\1/p' "$state/public/instance.json"), originally at $original)."
# 6. The database and storage replay is the in-place restore, unchanged.
if ! WAREHOUSE_STATE_DIR="$state" bash "$ROOT/scripts/restore.sh" --yes --relocated "$state/backups/$name"; then
  cat >&2 <<MSG
restore-host failed after creating $state. Nothing else on this host was changed.
Inspect the message above, then to start over:
  WAREHOUSE_STATE_DIR=$state bash stop.sh
  sudo rm -rf $state     # PostgreSQL files belong to the container's user
and run restore-host again.
MSG
  exit 1
fi
# The directories restore.sh set aside were created empty above.
for kept in "$state"/data/db.pre-restore-* "$state"/data/storage.pre-restore-*; do
  [[ -d "$kept" ]] && rmdir -- "$kept" 2>/dev/null || true
done
if [[ "$tunnel" == true ]]; then
  address="Bring the public address back with the tunnel credential from the backup:
       sudo bash scripts/tunnel.sh install-service --state $state
     then: node scripts/doctor.mjs"
else
  address="Bring the public address back: this backup carries no tunnel credential, so install the
     connector with your private copy (docs/OPERATOR_INSTALL.md, Cloudflare Tunnel ingress), then:
     node scripts/doctor.mjs"
fi
cat <<MSG

This host now serves the warehouse from backup $name.
Next:
  1. Keep the original host off for good: both must never run at once.
  2. $address
  3. Compare with the fingerprint taken at backup time, if you have one:
       WAREHOUSE_STATE_DIR=$state bash scripts/data-fingerprint.sh | diff FINGERPRINT_FILE -
  4. Set up the USB backup drive again: sudo bash scripts/backup-usb.sh setup --state $state --enroll /dev/sdX1
  5. If the backup drive may have been exposed: bash rotate-keys.sh --yes, rotate the MSG91 key and the
     tunnel credential, then take a new backup.
Use export WAREHOUSE_STATE_DIR=$state for every operator command on this host.
MSG

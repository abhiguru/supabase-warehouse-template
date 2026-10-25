#!/usr/bin/env bash
# Rebuild a lost installation on a new host from one of its warehouse-backup-v5
# backups: the same instance identity, origin, keys, users and data, as at the
# moment of the backup. It never runs setup (which would mint a new identity):
# it creates a new state directory from the backup's own compose.env and
# instance.json, rewriting only the three state-path lines (and adding the
# per-role database passwords a backup made before them lacks), and then hands
# over to scripts/restore.sh --relocated for the database and storage replay. A
# central sign-in key file (public/central-jwks.json), the letterhead image (public/letterhead.jpg or .png) and a tunnel credential
# in the backup are put back as well.
#
#   npm run db:restore-host -- --state-dir /srv/warehouse/acme --backup-key KEYFILE --yes [--images DIR] BACKUP
#
# --images DIR is a copy of the lost host's <state>/images folder (scripts/build-images.sh writes the images it builds
# there; it is not part of a backup). Without the option, an `images` folder next to BACKUP is used. The tarballs that its
# build record (image-recipes.sha256) names are loaded with `docker load` and the record adopted before the restore starts,
# so the db, storage, functions and PDF images are not built again (a build needs Docker Hub, Debian, npm and Chrome for Testing to answer). A tarball
# that does not load is reported and that image is built as usual. Images that are pulled, not built, are pulled as usual.
#
# BACKUP is a backup directory, or a `.tar` or encrypted `.tar.enc` archive
# written by backup-usb.sh (its `.sha256` and `.hmac` files must sit next to it;
# an archive without a `.hmac` is unpacked only with --allow-unsigned).
# KEYFILE is the operator's copy of the lost installation's config/backup.key:
# the signature is checked with it before anything in the backup is read, and an
# encrypted archive cannot be opened without it. --allow-unsigned is only for a
# lost backup key (then --backup-key is left out and nothing proves the backup
# genuine). Only backup format v5 is accepted; an older format is refused, and so is a backup made on the earlier
# supabase/postgres image (scripts/backup-image.sh). A v5 backup
# whose signature file is missing is refused while --backup-key is given. Nothing
# outside the new state is changed; the source backup is only read.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() { echo 'Usage: npm run db:restore-host -- --state-dir ABSOLUTE_NEW_STATE --backup-key KEYFILE --yes [--images DIR] BACKUP_DIR_OR_ARCHIVE   (--allow-unsigned instead of --backup-key: only for when the backup key is lost)' >&2; exit 1; }
die() { echo "$*" >&2; exit 1; }

state='' confirm=false source='' keyfile='' allow_unsigned=false images=''
while (($#)); do
  case "$1" in
    --state-dir) (($# > 1)) || usage; state="$2"; shift 2 ;;
    --backup-key) (($# > 1)) || usage; keyfile="$2"; shift 2 ;;
    --allow-unsigned) allow_unsigned=true; shift ;;
    --images) (($# > 1)) || usage; images="$2"; shift 2 ;;
    --yes) confirm=true; shift ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *) [[ -z "$source" ]] || usage; source="$1"; shift ;;
  esac
done
[[ -n "$state" && -n "$source" ]] || usage
[[ "$confirm" == true ]] || die 'Refusing: restore-host makes this host answer as the backed-up warehouse, with its identity and keys. Make sure the original host is permanently off, then pass --yes.'
((EUID != 0)) || die 'Run restore-host as the installation user (a member of the docker group), not as root.'
# shellcheck source=scripts/backup-key.sh
source "$ROOT/scripts/backup-key.sh"
unset WAREHOUSE_BACKUP_KEY_FILE WAREHOUSE_STATE_DIR
if [[ -n "$keyfile" ]]; then
  backup_key_load "$keyfile" || exit 1
  export WAREHOUSE_BACKUP_KEY_FILE="$(realpath -e -- "$keyfile")"
elif [[ "$allow_unsigned" != true ]]; then
  die 'Refusing: restore-host needs the backup key of the lost installation (--backup-key FILE, your copy of its config/backup.key) to prove the backup is genuine. --allow-unsigned is only for when the backup key is lost: the backup is then used WITHOUT proof that it is genuine.'
fi

# The saved images: --images, else an `images` folder next to the backup. A saved-images folder is recognised by the build
# record build-images.sh keeps in it (image-recipes.sha256), and only the services that record names are loaded: some other
# folder of tarballs is never fed to docker load. A folder given with --images that is not one is refused; one found next to
# the backup is ignored.
is_saved_images() { [[ -d "$1" && ! -L "$1" && -f "$1/image-recipes.sha256" && ! -L "$1/image-recipes.sha256" ]]; }
if [[ -n "$images" ]]; then
  is_saved_images "$images" || die "--images must be a copy of the lost host's <state>/images folder (a directory with image-recipes.sha256 and one <service>.tar per image): $images"
  images="$(realpath -e -- "$images")"
else
  candidate="$(dirname -- "$source")/images"
  if is_saved_images "$candidate"; then images="$(realpath -e -- "$candidate")"; fi
fi

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
# shellcheck source=scripts/require-node.sh
. "$ROOT/scripts/require-node.sh"
WAREHOUSE_STATE_DIR="$state" node "$ROOT/scripts/doctor.mjs" --host-preflight

# 2. The backup: an archive is checked against its .sha256 and unpacked next to
#    the new state (same filesystem, removed on any failure); a directory is read in place.
scratch=''
cleanup() { [[ -z "$scratch" ]] || rm -rf -- "$scratch"; }
trap cleanup EXIT
if [[ -f "$source" && ( "$source" == *.tar || "$source" == *.tar.enc ) ]]; then
  archive="$(realpath -e -- "$source")"
  file="$(basename -- "$archive")"
  name="${file%.enc}"; name="${name%.tar}"
  [[ "$name" =~ ^warehouse-[0-9]{8}T[0-9]{6}Z$ ]] || die "Not a backup archive name (warehouse-<utc>.tar or .tar.enc): $archive"
  [[ -f "$archive.sha256" ]] || die "Missing checksum file $archive.sha256; refusing an unverified archive."
  # The checksum record must be for this very archive: one record, naming the selected file,
  # holding the SHA-256 of the selected bytes. A record copied from another archive is refused.
  records="$(grep -c '' -- "$archive.sha256" || true)"
  record="$(head -n 1 -- "$archive.sha256")"
  [[ "$records" == 1 && -n "${record//[[:space:]]/}" ]] || die 'The checksum file must hold one record'
  # A copy that went through a Windows tool ends the record with CR LF. The signature covers the file
  # byte for byte, so it cannot be "fixed" here: say what is wrong instead of a name mismatch.
  [[ "$record" != *$'\r' ]] || die "The checksum file $file.sha256 has CRLF line endings; copy it again without converting it."
  [[ "$record" =~ ^([0-9a-fA-F]{64})\ [\ \*](.+)$ ]] || die "The checksum file $file.sha256 is not a '<sha256>  <name>' record."
  recorded_hash="${BASH_REMATCH[1]}"; recorded_name="${BASH_REMATCH[2]}"
  [[ "$recorded_name" == "$file" ]] || die "The checksum file names a different archive ($recorded_name)"
  actual_hash="$(sha256sum < "$archive" | cut -d' ' -f1)"
  [[ "${recorded_hash,,}" == "$actual_hash" ]] || die "The archive does not match $file.sha256; choose another backup."
  # The archive signature covers its checksum, so it is checked before the archive is opened.
  # Without one, nothing vouches for the archive until the backup inside it has been unpacked.
  if [[ -n "$BACKUP_KEY" && -e "$archive.hmac" ]]; then
    backup_check_archive "$archive" "$BACKUP_KEY" || die "Refusing: the signature of $file does not match the backup key. The archive was changed, or it belongs to another installation or an earlier key."
  elif [[ -n "$BACKUP_KEY" && "$file" == *.enc ]]; then
    die "Refusing: the encrypted archive $file has no signature file ($file.hmac); it cannot be trusted."
  elif [[ "$allow_unsigned" != true ]]; then
    die "Refusing: the archive $file has no signature file ($file.hmac), so it cannot be checked before it is unpacked. Copy the .hmac file from the drive together with the archive. An archive you packed yourself has none: for that pass --allow-unsigned as well (a signed backup inside it is still checked against the key)."
  fi
  scratch="$(mktemp -d -- "$parent/.restore-host.XXXXXX")"
  if [[ "$file" == *.enc ]]; then
    [[ -n "$BACKUP_KEY" ]] || die "An encrypted archive ($file) cannot be opened without --backup-key."
    backup_decrypt "$BACKUP_KEY" < "$archive" > "$scratch/$name.tar" || die "Could not decrypt $file with this backup key."
    archive="$scratch/$name.tar"
  fi
  # Only regular files and directories under <name>/, no absolute paths or '..'.
  bad="$(tar -tvf "$archive" | awk -v n="$name" '{ t = substr($1, 1, 1); p = $NF } t != "-" && t != "d" { print; next } p != n && p != n "/" && index(p, n "/") != 1 { print; next } p ~ /(^|\/)\.\.(\/|$)/ { print }' | head -n 3)"
  [[ -z "$bad" ]] || die "Refusing an archive with unexpected entries: $bad"
  tar --no-same-owner -xf "$archive" -C "$scratch"
  [[ "$file" != *.enc ]] || rm -f -- "$scratch/$name.tar"
  backup="$scratch/$name"
elif [[ -d "$source" && ! -L "$source" ]]; then
  backup="$(realpath -e -- "$source")"
  name="$(basename -- "$backup")"
else
  die "Backup not found (a backup directory, a warehouse-<utc>.tar or a warehouse-<utc>.tar.enc): $source"
fi
for file in metadata.txt compose.env instance.json integrity.txt SHA256SUMS; do
  [[ -f "$backup/$file" && ! -L "$backup/$file" ]] || die "Incomplete backup: missing $file"
done
# Only format v5 is accepted. A refusal needs no trust in metadata.txt, so this comes before the signature check.
format="$(sed -n 's/^format=//p' "$backup/metadata.txt" 2>/dev/null || true)"
[[ "$format" == warehouse-backup-v5 ]] || { format="${format//[^[:print:]]/?}"; die "Refusing: backup format '${format:-unknown}' is no longer supported; take a new backup with this version (only warehouse-backup-v5 is accepted)."; }
# A backup made on the earlier supabase/postgres image (or with no image line) is refused: scripts/backup-image.sh.
# shellcheck source=scripts/backup-image.sh
source "$ROOT/scripts/backup-image.sh"
backup_check_database_image "$backup" || exit 1
# Signature and checksums first: compose.env from the backup becomes this host's configuration.
backup_authenticate "$backup" "$allow_unsigned" || exit 1
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
# The restore replaces the database (data/db) and the stored files (data/storage). The project's other
# Docker volumes (the print spool, the sensor data) hold nothing a restore replaces, so they do not stop it.
kept=()
present="$(docker volume ls -q --filter "name=^${project}_")"
while IFS= read -r volume; do
  [[ -n "$volume" ]] && kept+=("$volume")
done <<<"$present"
if ((${#kept[@]})); then
  list="$(printf '%s, ' "${kept[@]}")"
  echo "Kept the Docker volumes ${list%, }: they hold no database or storage state (print spool, sensor data) and are reused as they are."
fi

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
# The rebuilt installation keeps signing with the same backup key.
if [[ -n "$BACKUP_KEY" ]]; then (umask 077; printf '%s\n' "$BACKUP_KEY" > "$stage/config/backup.key"); chmod 0600 "$stage/config/backup.key"; fi
install -m 0644 -- "$stage/backups/$name/instance.json" "$stage/public/instance.json"
# The central sign-in key set (public keys only), when the backup carries one. compose.env names it
# (CENTRAL_JWKS_FILE), so a restore that left it out would offer central sign-in that cannot work.
# A backup written before backups carried the file has none: the next steps then say how to put it back.
central_key=false central_missing=false central_issuer=''
central_src="$stage/backups/$name/central-jwks.json"
staged_env="$stage/backups/$name/compose.env"
if [[ -e "$central_src" || -L "$central_src" ]]; then
  [[ -f "$central_src" && ! -L "$central_src" ]] || die 'The backup entry central-jwks.json is not a regular file.'
  install -m 0644 -- "$central_src" "$stage/public/central-jwks.json"
  central_key=true
elif [[ -n "$(sed -n 's/^CENTRAL_JWKS_FILE=//p' "$staged_env" | head -n 1)" ]]; then
  central_missing=true
  central_issuer="$(sed -n 's/^CENTRAL_ISSUER=//p' "$staged_env" | head -n 1)"
fi
# The letterhead image of the document PDFs, when the backup carries one (setup.sh --letterhead-file). A backup
# written before backups held it has none: the PDFs are then plain, which is not a fault, unless compose.env names one.
letterhead_restored='' letterhead_missing=false
for letterhead in letterhead.jpg letterhead.png; do
  src="$stage/backups/$name/$letterhead"
  if [[ -e "$src" || -L "$src" ]]; then
    [[ -f "$src" && ! -L "$src" ]] || die "The backup entry $letterhead is not a regular file."
    install -m 0644 -- "$src" "$stage/public/$letterhead"
    letterhead_restored="$letterhead"
  fi
done
if [[ -z "$letterhead_restored" && -n "$(sed -n 's/^LETTERHEAD_FILE=//p' "$staged_env" | head -n 1)" ]]; then letterhead_missing=true; fi
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
# What configure.mjs's existing-state branch does: a backup taken before every
# database login had its own password gets them now, before the database starts.
node "$ROOT/scripts/db-roles.mjs" add-missing "$stage/config/compose.env"
[[ ! -d "$state" ]] || rmdir -- "$state"
mv -T -- "$stage" "$state"
trap cleanup EXIT
echo "Created $state from $name (instance $(sed -n 's/.*"instanceId": *"\([^"]*\)".*/\1/p' "$state/public/instance.json"), originally at $original)."
if [[ "$central_key" == true ]]; then echo 'Restored the central sign-in key file public/central-jwks.json from the backup.'; fi
if [[ -n "$letterhead_restored" ]]; then echo "Restored the letterhead image public/$letterhead_restored from the backup."; fi
# Built images saved by build-images.sh on the lost host: loaded now, and their build record adopted, so the restore below
# (which builds a missing db image, and compose up the others) does not go to the internet for them.
if [[ -n "$images" ]]; then
  loaded=0
  while read -r _ service _; do
    [[ "$service" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || continue
    tarball="$images/$service.tar"
    [[ -f "$tarball" && ! -L "$tarball" ]] || continue
    if docker load --input "$tarball" >/dev/null; then loaded=$((loaded + 1)); echo "Loaded the saved image $service.tar."
    else echo "Warning: could not load $tarball; that image is built as usual." >&2; fi
  done < "$images/image-recipes.sha256"
  if ((loaded > 0)); then
    node "$ROOT/scripts/image-recipes.mjs" adopt "$state/config/image-recipes.sha256" "$images/image-recipes.sha256" \
      || echo 'Warning: the build record of the saved images could not be adopted; the images are built as usual.' >&2
  fi
  if ((loaded == 0)); then echo "No saved image could be loaded from $images; the images are built as usual."; fi
fi
# 6. The database and storage replay is the in-place restore, unchanged.
restore_args=(--yes --relocated)
if [[ "$allow_unsigned" == true ]]; then restore_args+=(--allow-unsigned); fi
# restore.sh ends with doctor --local, which fails on a missing central key file. While the file is still
# to be put back (older backup, see the next steps) that is a warning, so the restore itself can finish.
pending=''
if [[ "$central_missing" == true ]]; then pending=yes; fi
if ! WAREHOUSE_CENTRAL_KEY_PENDING="$pending" WAREHOUSE_STATE_DIR="$state" WAREHOUSE_BACKUP_KEY_FILE="${WAREHOUSE_BACKUP_KEY_FILE:-}" bash "$ROOT/scripts/restore.sh" "${restore_args[@]}" "$state/backups/$name"; then
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
# The numbered steps; the central key file step appears only when the backup could not carry the file.
n=0
step() { n=$((n + 1)); printf '  %d. %s\n' "$n" "$1"; }
printf '\nThis host now serves the warehouse from backup %s.\nNext:\n' "$name"
step 'Keep the original host off for good: both must never run at once.'
step "$address"
if [[ "$central_missing" == true ]]; then
  # Printed from the backup's own configuration, so only a plain https address is shown.
  issuer="$central_issuer"
  [[ "$issuer" =~ ^https://[A-Za-z0-9._:/-]+$ ]] || issuer='https://ISSUER'
  step "Put the central sign-in key file back. This backup carries no central sign-in key file (it was
     written before backups held it), but the configuration still names one, so the app offers association
     sign-in that fails until you do, and node scripts/doctor.mjs fails on the missing file until then.
     Rerun setup with your usual administrator inputs and the key set the association sent you; it keeps
     this identity and its data, and rebuilds the images once:
       bash setup.sh --operator --state-dir $state --admin-phone 91XXXXXXXXXX --admin-name 'ADMIN NAME' \\
         --central-issuer $issuer --central-jwks-file /absolute/path/to/association-jwks.json"
fi
if [[ "$letterhead_missing" == true ]]; then
  step "Put the letterhead image back (optional). This backup carries no letterhead image although its configuration
     names one, so the GRN, dispatch, invoice and customer stock PDFs are plain and node scripts/doctor.mjs warns until
     you rerun setup with your usual administrator inputs and the image, or with --letterhead-file off:
       bash setup.sh --operator --state-dir $state --admin-phone 91XXXXXXXXXX --admin-name 'ADMIN NAME' \\
         --letterhead-file /absolute/path/to/letterhead.png"
fi
step "Compare with the fingerprint taken at backup time, if you have one:
     (A fingerprint recorded before the release that added orders, order lines, order revisions and
     payments lacks those four lines: the diff will show them added and not be empty; compare the rest.)
     (A fingerprint recorded before this release sorted with the database collation; its sha256 values can differ for identical data. Compare the rows= counts, and take a new fingerprint after upgrading.)
       WAREHOUSE_STATE_DIR=$state bash scripts/data-fingerprint.sh | diff FINGERPRINT_FILE -"
step "Set up the USB backup drive again: sudo bash scripts/backup-usb.sh setup --state $state --enroll /dev/sdX1"
step 'If the backup drive may have been exposed: bash rotate-keys.sh --yes, rotate the MSG91 key and the
     tunnel credential, replace the other secrets as described under "Secrets that rotate-keys does not
     change" in docs/OPERATOR_INSTALL.md, then take a new backup.'
step "Keep your copy of the backup key: this installation signs with the same key ($state/config/backup.key)."
alert_step="Alerts are local only until you run setup.sh --operator again with --alert-webhook-file (or answer its Slack
     webhook prompt on a terminal; the URL is not in a backup, skip this if the installation never had one)."
if [[ "$central_missing" == true ]]; then
  alert_step+="
     The central sign-in step above reruns setup as well: add --alert-webhook-file /absolute/path/to/webhook-url-file
     to that same command, so it is one rerun and not two."
fi
step "$alert_step"
step "Install the monitoring checker (checks every 5 minutes, Slack alerts, the daily backup and retention; it needs sudo,
     which this script never uses). It also runs without a Slack webhook:
       sudo bash scripts/watch-timer.sh install --state $state"
echo "Use export WAREHOUSE_STATE_DIR=$state for every operator command on this host."

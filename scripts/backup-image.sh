#!/usr/bin/env bash
# Sourced by scripts/restore.sh, scripts/restore-host.sh and scripts/verify-restore.sh.
# A backup (format v5 or v6) records the database image it was dumped from on a database_image= line in
# metadata.txt (scripts/backup.sh). The database runs the official PostgreSQL image of the pin in
# docker/postgres/Dockerfile (scripts/db-image.sh) with one baseline migration. A backup from the same major or
# from PostgreSQL 17 restores; one from a newer major than the pin does not (a dump cannot go back to an older server). A backup made on the earlier supabase/postgres image holds the old schema, the
# old roles and the old migration chain, so it cannot be replayed here: it restores only with the
# release tagged migrations-pre-baseline, and its data is then reloaded (docs/OPERATOR_INSTALL.md,
# "Baseline reload"). A refusal needs no trust in metadata.txt, so callers run it before the signature check.
#
# The two formats differ only in how the object storage is kept (scripts/backup.sh writes v6, restores read both):
#   warehouse-backup-v5  storage.tar.gz, one gzip tar of the whole object storage, named in SHA256SUMS.
#   warehouse-backup-v6  storage/, a tree of files (hard-linked to the previous backup where unchanged, extended
#                        attributes kept), and storage.manifest, the sorted sha256 of every file in it, named in SHA256SUMS.

# backup_check_format BACKUP_DIR: accepts warehouse-backup-v5 and warehouse-backup-v6 and sets BACKUP_FORMAT to the
# label; otherwise prints the reason on standard error and returns 1. Reads only the format= line of metadata.txt, so
# like the image check it runs before the signature check.
BACKUP_FORMAT=''
backup_check_format() {
  local metadata="$1/metadata.txt" format
  BACKUP_FORMAT=''
  [[ -f "$metadata" && ! -L "$metadata" ]] || { echo 'Incomplete backup: missing metadata.txt' >&2; return 1; }
  format="$(sed -n 's/^format=//p' "$metadata" 2>/dev/null || true)"
  if [[ "$format" != warehouse-backup-v5 && "$format" != warehouse-backup-v6 ]]; then
    format="${format//[^[:print:]]/?}"
    echo "Refusing: backup format '${format:-unknown}' is no longer supported; take a new backup with this version (only warehouse-backup-v5 and -v6 are accepted)." >&2
    return 1
  fi
  BACKUP_FORMAT="$format"
}

# backup_check_layout BACKUP_DIR: run after backup_authenticate. The label of metadata.txt must agree with the
# files the signed SHA256SUMS lists: v6 names storage.manifest and has a storage/ tree and no tarball; v5 names
# storage.tar.gz and has no manifest and no tree. A label and a list that disagree are refused, so a backup cannot
# be read as the other format. Needs BACKUP_FORMAT from backup_check_format.
backup_check_layout() {
  local dir="$1" has_manifest=false has_tarball=false
  grep -Eq '^[0-9a-f]{64}  storage\.manifest$' "$dir/SHA256SUMS" && has_manifest=true
  grep -Eq '^[0-9a-f]{64}  storage\.tar\.gz$' "$dir/SHA256SUMS" && has_tarball=true
  if [[ "$BACKUP_FORMAT" == warehouse-backup-v6 ]]; then
    if [[ "$has_manifest" != true || "$has_tarball" == true || -e "$dir/storage.tar.gz" || -L "$dir/storage.tar.gz" ]]; then
      echo 'Refusing: the backup is labelled warehouse-backup-v6, but its signed file list does not describe that layout (v6 lists storage.manifest and has a storage/ tree, and no storage.tar.gz).' >&2
      return 1
    fi
    if [[ "${BACKUP_TREE:-check}" != skip && ( ! -d "$dir/storage" || -L "$dir/storage" ) ]]; then
      echo 'Incomplete backup: missing the storage/ directory' >&2
      return 1
    fi
  elif [[ "$has_tarball" != true || "$has_manifest" == true || -e "$dir/storage.manifest" || -e "$dir/storage" || -L "$dir/storage" ]]; then
    echo 'Refusing: the backup is labelled warehouse-backup-v5, but its signed file list does not describe that layout (v5 lists storage.tar.gz and has no storage.manifest and no storage/ tree).' >&2
    return 1
  fi
}

# backup_check_database_image BACKUP_DIR: returns 0 for a backup made on the official postgres image;
# otherwise prints the reason on standard error and returns 1.
backup_check_database_image() {
  local metadata="$1/metadata.txt" lines image
  lines="$(grep -c '^database_image=' "$metadata" 2>/dev/null || true)"
  image="$(sed -n 's/^database_image=//p' "$metadata" 2>/dev/null | head -n 1)"
  image="${image//[^[:print:]]/?}"
  if [[ "$lines" == 0 || ( "$lines" == 1 && -z "$image" ) ]]; then
    echo "Refusing: the backup records no database_image= line in metadata.txt, so it was made before the move to PostgreSQL 17. Restore it with the release tagged migrations-pre-baseline, then reload the data into this version (docs/OPERATOR_INSTALL.md, \"Baseline reload\")." >&2
    return 1
  fi
  if [[ "$lines" != 1 ]]; then
    echo "Refusing: metadata.txt of the backup records $lines database_image= lines instead of one; the backup metadata is damaged." >&2
    return 1
  fi
  if [[ "$image" == supabase/postgres* ]]; then
    echo "Refusing: the backup was made on the database image '$image', which this version no longer runs. Restore it with the release tagged migrations-pre-baseline, then reload the data into this version (docs/OPERATOR_INSTALL.md, \"Baseline reload\")." >&2
    return 1
  fi
  if [[ ! "$image" =~ ^postgres:[0-9][^[:space:]]*$ ]]; then
    echo "Refusing: the backup records an unknown database image '$image' (expected the official postgres image from docker/postgres/Dockerfile)." >&2
    return 1
  fi
  # The upper bound: a backup from a newer PostgreSQL major than this checkout runs cannot be restored by it.
  local pin pin_major image_major
  pin="$(bash "$(dirname "${BASH_SOURCE[0]}")/db-image.sh")" || return 1
  pin_major="${pin#postgres:}"; pin_major="${pin_major%%[!0-9]*}"
  image_major="${image#postgres:}"; image_major="${image_major%%[!0-9]*}"
  if [[ ! "$image_major" =~ ^[0-9]{1,3}$ ]]; then
    echo "Refusing: the backup records a database image '$image' whose PostgreSQL major version cannot be read." >&2
    return 1
  fi
  if ((image_major > pin_major)); then
    echo "Refusing: the backup was made on '$image', a newer PostgreSQL major than the $pin_major this checkout runs ($pin). A dump cannot be restored on an older server. Check out the release the backup was made with, or a newer one." >&2
    return 1
  fi
  # roles.txt lists every role of the dumped server. The roles of the earlier image and the removed warehouse roles (the list of tests/baseline_roles.sql) never exist on this version, so a
  # backup that names one was dumped from the earlier schema, whatever its image label says.
  local role
  for role in postgres dashboard_user supabase_auth_admin supabase_realtime_admin supabase_functions_admin supabase_read_only_user supabase_replication_admin supabase_etl_admin warehouse_monitoring warehouse_list_refresher; do
    if grep -qx -- "$role" "$1/roles.txt" 2>/dev/null; then
      echo "Refusing: the backup lists the role '$role', which this version does not have: it was dumped from the earlier image, whatever its database_image= line says. Restore it with the release tagged migrations-pre-baseline, then reload the data into this version (docs/OPERATOR_INSTALL.md, \"Baseline reload\")." >&2
      return 1
    fi
  done
}

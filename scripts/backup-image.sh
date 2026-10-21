#!/usr/bin/env bash
# Sourced by scripts/restore.sh, scripts/restore-host.sh and scripts/verify-restore.sh.
# A backup (format v5) records the database image it was dumped from on a database_image= line in
# metadata.txt (scripts/backup.sh). The database runs the official PostgreSQL image of the pin in
# docker/postgres/Dockerfile (scripts/db-image.sh) with one baseline migration. A backup from the same major or
# from PostgreSQL 17 restores; one from a newer major than the pin does not (a dump cannot go back to an older server). A backup made on the earlier supabase/postgres image holds the old schema, the
# old roles and the old migration chain, so it cannot be replayed here: it restores only with the
# release tagged migrations-pre-baseline, and its data is then reloaded (docs/OPERATOR_INSTALL.md,
# "Baseline reload"). A refusal needs no trust in metadata.txt, so callers run it before the signature check.

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

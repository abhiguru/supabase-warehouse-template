#!/usr/bin/env bash
# Refuses to go on when the database on this host is older than PostgreSQL 17. Called by setup.sh and start.sh (which
# hold the operator lock) before the first step that builds the database image or recreates the db container, and by
# rotate-keys.sh, rotate-db-passwords.sh and pooler-check.sh, the other commands that recreate db.
# Why: this release runs the official PostgreSQL 17 image. A container recreated on the data directory of the earlier
# PostgreSQL 15 image would chown it, fail with "database files are incompatible with server" and restart in a loop; the
# old directory would be changed and the message would not say what to do. The data moves with the baseline reload
# (docs/OPERATOR_INSTALL.md, "Baseline reload"), which starts from a new PostgreSQL 17 data directory.
# Two checks, both read-only:
#   1. a running db container: SHOW server_version_num must be 170000 or more;
#   2. the data directory WAREHOUSE_DB_PATH, when it is not empty: PG_VERSION must be 17. The directory is mode 0700 and
#      owned by the database user, so it is read by a one-shot container of the pinned image (scripts/db-image.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
refuse() {
  echo "Refusing: $1 This release runs PostgreSQL 17 and cannot start on that data. No database, container or image was changed. Back the installation up with the release tagged migrations-pre-baseline, then reload the data into a new PostgreSQL 17 database: docs/OPERATOR_INSTALL.md, \"Baseline reload\"." >&2
  exit 1
}
if [[ -n "$(compose ps --status running -q db)" ]]; then
  num="$(compose exec -T db psql -X -A -t -q -U supabase_admin -d postgres -c "SELECT current_setting('server_version_num')" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ "$num" =~ ^[0-9]+$ ]] && ((num < 170000)); then
    refuse "the running database reports server_version_num $num (PostgreSQL $((num / 10000)))."
  fi
fi
db_path="$(sed -n 's/^WAREHOUSE_DB_PATH=//p' "${WAREHOUSE_STATE_DIR:?Set WAREHOUSE_STATE_DIR}/config/compose.env")"
[[ "$db_path" == /* ]] || { echo 'WAREHOUSE_DB_PATH is not set in compose.env.' >&2; exit 1; }
# The image of the one-shot container: the db image this host already built (no network needed, even after an image
# prune that left only the build cache), else the pinned upstream reference.
image="$(bash "$ROOT/scripts/db-image.sh")"
built="$(compose config --format json 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const c=JSON.parse(s);console.log(c.services.db.image||`${c.name}-db`)}catch{}})' || true)"
if [[ -n "$built" ]] && docker image inspect "$built" >/dev/null 2>&1; then image="$built"; fi
found="$(docker run --rm --network none --entrypoint sh -v "$db_path:/d:ro" "$image" -c \
  'if ! ls -A /d >/dev/null 2>&1; then echo unreadable; elif [ -z "$(ls -A /d)" ]; then echo empty; elif [ -f /d/PG_VERSION ]; then cat /d/PG_VERSION; else echo unknown; fi' | tr -d '[:space:]')" || found=unreadable
case "$found" in
  empty|unknown) ;;
  17) ;;
  unreadable) echo "Warning: could not read the data directory $db_path from a container (SELinux label, a missing image or no way to pull it); its PostgreSQL version was not checked." >&2 ;;
  *) refuse "the data directory $db_path holds a PostgreSQL ${found:-unreadable} database (PG_VERSION)." ;;
esac

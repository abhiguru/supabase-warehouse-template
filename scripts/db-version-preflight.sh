#!/usr/bin/env bash
# Refuses to go on when the database on this host is not the PostgreSQL major this checkout runs. Called by setup.sh and
# start.sh (which hold the operator lock) before the first step that builds the database image or recreates the db
# container, and by rotate-keys.sh, rotate-db-passwords.sh and tests/pooler-check.sh, the other commands that recreate db.
# Why: this release runs the official PostgreSQL image of the pin in docker/postgres/Dockerfile (scripts/db-image.sh, the
# one source of the expected major). A container recreated on the data directory of another major would chown it, fail
# with "database files are incompatible with server" and restart in a loop; the old directory would be changed and the
# message would not say what to do. From the previous major (17) the data moves with the major upgrade (docs/OPERATOR_INSTALL.md,
# "Major PostgreSQL upgrade"); from earlier than 17 with the baseline reload ("Baseline reload").
# Two checks, both read-only:
#   1. a running db container: SHOW server_version_num must be the major of the pin;
#   2. the data directory WAREHOUSE_DB_PATH, when it is not empty: PG_VERSION must be the major of the pin. The directory is
#      mode 0700 and owned by the database user, so it is read by a one-shot container of the pinned image.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
pin_image="$(bash "$ROOT/scripts/db-image.sh")"
pin_major="${pin_image#postgres:}"; pin_major="${pin_major%%[!0-9]*}"
previous_major=$((pin_major - 1))
# refuse <what> <found major>: a data directory or server of the previous major goes to the upgrade section, an earlier one to the baseline reload.
refuse() {
  local what="$1" major="$2"
  if [[ "$major" =~ ^[0-9]+$ ]] && ((major == previous_major)); then
    echo "Refusing: $what This release runs PostgreSQL $pin_major and cannot start on PostgreSQL $previous_major data. No database, container or image was changed. The data moves with a major upgrade: back up with the checkout that runs PostgreSQL $previous_major, then restore on this one (docs/OPERATOR_INSTALL.md, \"Major PostgreSQL upgrade\")." >&2
  elif [[ "$major" =~ ^[0-9]+$ ]] && ((major > pin_major)); then
    echo "Refusing: $what This release runs PostgreSQL $pin_major and cannot start on newer data. No database, container or image was changed. Check out the release that runs PostgreSQL $major or newer." >&2
  else
    echo "Refusing: $what This release runs PostgreSQL $pin_major and cannot start on that data. No database, container or image was changed. Back the installation up with the release tagged migrations-pre-baseline, then reload the data into a new PostgreSQL $pin_major database: docs/OPERATOR_INSTALL.md, \"Baseline reload\"." >&2
  fi
  exit 1
}
if [[ -n "$(compose ps --status running -q db)" ]]; then
  num="$(compose exec -T db psql -X -A -t -q -U supabase_admin -d postgres -c "SELECT current_setting('server_version_num')" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ "$num" =~ ^[0-9]+$ ]] && ((num / 10000 != pin_major)); then
    refuse "the running database reports server_version_num $num (PostgreSQL $((num / 10000)))." "$((num / 10000))"
  fi
fi
db_path="$(sed -n 's/^WAREHOUSE_DB_PATH=//p' "${WAREHOUSE_STATE_DIR:?Set WAREHOUSE_STATE_DIR}/config/compose.env")"
[[ "$db_path" == /* ]] || { echo 'WAREHOUSE_DB_PATH is not set in compose.env.' >&2; exit 1; }
# The image of the one-shot container: the db image this host already built (no network needed, even after an image
# prune that left only the build cache), else the pinned upstream reference.
image="$pin_image"
built="$(compose config --format json 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const c=JSON.parse(s);console.log(c.services.db.image||`${c.name}-db`)}catch{}})' || true)"
if [[ -n "$built" ]] && docker image inspect "$built" >/dev/null 2>&1; then image="$built"; fi
found="$(docker run --rm --network none --entrypoint sh -v "$db_path:/d:ro" "$image" -c \
  'if ! ls -A /d >/dev/null 2>&1; then echo unreadable; elif [ -z "$(ls -A /d)" ]; then echo empty; elif [ -f /d/PG_VERSION ]; then cat /d/PG_VERSION; else echo unknown; fi' | tr -d '[:space:]')" || found=unreadable
case "$found" in
  empty|unknown) ;;
  "$pin_major") ;;
  unreadable) echo "Warning: could not read the data directory $db_path from a container (SELinux label, a missing image or no way to pull it); its PostgreSQL version was not checked." >&2 ;;
  *) refuse "the data directory $db_path holds a PostgreSQL ${found:-unreadable} database (PG_VERSION)." "$found" ;;
esac

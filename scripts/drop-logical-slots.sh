#!/usr/bin/env bash
# Drops idle logical replication slots while the db service still runs with its OLD settings, and refuses if one
# is left. Called by setup.sh and start.sh (which hold the operator lock) before the first step that recreates db.
# Why: wal_level is replica from release 105 on, and PostgreSQL refuses to start ("logical replication slot ...
# exists, but wal_level < logical") while any permanent logical slot exists. Migration 105 runs after the restart,
# so it cannot clear the slot in time; this step can. If db is not running there is nothing to ask: skipped.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
psql_db() { compose exec -T db psql -X -A -t -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 "$@"; }
if [[ -z "$(compose ps --status running -q db)" ]]; then
  echo 'Database service is not running; no logical replication slots to check.'
  exit 0
fi
psql_db -c "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_type = 'logical' AND NOT active AND NOT temporary" >/dev/null
left="$(psql_db -c "SELECT slot_name FROM pg_replication_slots WHERE slot_type = 'logical' AND NOT temporary ORDER BY slot_name")"
if [[ -n "$left" ]]; then
  echo "A logical replication slot is still in use: $(echo "$left" | paste -sd, -). The database cannot start with wal_level=replica while it exists, so nothing was changed. Stop whatever uses the slot (the old Realtime container), drop it with SELECT pg_drop_replication_slot('<name>'), then run this again." >&2
  exit 1
fi

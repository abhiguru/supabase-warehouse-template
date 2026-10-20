#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${WAREHOUSE_STATE_DIR:-}" ]]; then
  echo 'Set WAREHOUSE_STATE_DIR to the installed operator state. Use ./setup.sh --operator for first installation.' >&2
  exit 1
fi
node "$ROOT/scripts/doctor.mjs" --preflight
STATE="$(realpath -m "$WAREHOUSE_STATE_DIR")"
exec 9>"$STATE/config/operator.lock"
if ! flock -n 9; then echo 'Another operator setup, start, or backup is running for this state.' >&2; exit 1; fi
# Before anything is changed: Docker must be able to allocate the subnet of the internal renderer network.
bash "$ROOT/scripts/network-preflight.sh"
# Before the db container is recreated: a PostgreSQL 15 database must go through the baseline reload.
bash "$ROOT/scripts/db-version-preflight.sh"
# --remove-orphans removes the containers of services that were removed from the Compose file (see CHANGELOG.md).
# Services of a profile (printing, sensors, pooler) are disabled services, not
# orphans, so they are kept.
# wal_level=replica refuses to start the db while a logical replication slot exists: drop idle ones (refuse if one
# is in use) while the db still runs with its old settings.
bash "$ROOT/scripts/drop-logical-slots.sh"
bash "$ROOT/scripts/compose.sh" up -d --remove-orphans --wait --wait-timeout 180
# Optional services (printing, sensors, pooler) are not part of that start.
# Replace the running ones whose image or configuration changed.
bash "$ROOT/scripts/build-images.sh" --replace-optional || echo 'Warning: a running optional service was not replaced (message above). The core services are up.' >&2
node "$ROOT/scripts/doctor.mjs" --local
# The monitoring checker runs from a systemd timer that start.sh cannot install (it needs sudo): print the command
# when the timer is missing.
WAREHOUSE_STATE_DIR="$STATE" bash "$ROOT/scripts/watch-timer.sh" hint || true

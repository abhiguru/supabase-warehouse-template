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
# Upgrade from Gotenberg: remove its old container (no longer in the Compose file) right before the start.
bash "$ROOT/scripts/retire-gotenberg.sh" container
bash "$ROOT/scripts/compose.sh" up -d --wait --wait-timeout 180
bash "$ROOT/scripts/retire-gotenberg.sh" image
# Optional services (monitoring, printing, pooler) are not part of that start.
# Replace the running ones whose image or configuration changed.
bash "$ROOT/scripts/build-images.sh" --replace-optional || echo 'Warning: a running optional service was not replaced (message above). The core services are up.' >&2
# With a Slack webhook stored the monitoring services must run, or no alert is ever sent. Never builds.
bash "$ROOT/scripts/start-monitoring.sh"
# Realtime opens its database connection on the first join; do that now (best effort, never fails the start).
node "$ROOT/scripts/realtime-warmup.mjs"
node "$ROOT/scripts/doctor.mjs" --local

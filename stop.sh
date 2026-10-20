#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$ROOT/scripts/operator-lock.sh"
state="$(operator_state)"
operator_lock "$state"
# Preserve volumes/data. The wrapper verifies ownership before stopping anything.
# Every profile (pooler, printing, sensors) stops too: a plain `down` would
# leave profile-gated containers running and the restore preflight would refuse.
# --remove-orphans also removes a container of a service the Compose file no longer has.
bash "$ROOT/scripts/compose.sh" --profile '*' down --remove-orphans
echo 'Stopped. If the monitoring checker timer is installed it keeps running and reports the stopped services as alerts (to Slack, when a webhook is stored).'
echo 'To keep it quiet for a planned stop: node scripts/watch.mjs mute <minutes>   (end early: node scripts/watch.mjs unmute).'

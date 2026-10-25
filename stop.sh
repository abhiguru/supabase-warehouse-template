#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$ROOT/scripts/operator-lock.sh"
state="$(operator_state)"
operator_lock "$state"
# Written first: if the stop is cut short, or the host reboots before the operator is done (a restore, an upgrade, a manual
# procedure), the boot unit (watch-timer.sh) and the checker's self-healing leave the stack down. start.sh removes it.
printf 'stopped by stop.sh at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$state/config/stopped-by-operator"
# Preserve volumes/data. The wrapper verifies ownership before stopping anything.
# Every profile (pooler, printing, sensors) stops too: a plain `down` would
# leave profile-gated containers running and the restore preflight would refuse.
# --remove-orphans also removes a container of a service the Compose file no longer has.
bash "$ROOT/scripts/compose.sh" --profile '*' down --remove-orphans
echo 'Stopped. A reboot leaves it stopped, and the monitoring checker does not start it again, until you run start.sh (config/stopped-by-operator).'
echo 'If the monitoring checker timer is installed it keeps running and reports the stopped services as alerts (to Slack, when a webhook is stored).'
echo 'To keep it quiet for a planned stop: node scripts/watch.mjs mute <minutes>   (end early: node scripts/watch.mjs unmute).'

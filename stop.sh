#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$ROOT/scripts/operator-lock.sh"
state="$(operator_state)"
operator_lock "$state"
# Preserve volumes/data. The wrapper verifies ownership before stopping anything.
# Every profile (monitoring, pooler, printing) stops too: a plain `down` would
# leave profile-gated containers running and the restore preflight would refuse.
# --remove-orphans also removes a container of a service the Compose file no longer
# has (the Gotenberg container of an installation upgraded to pdf-renderer).
bash "$ROOT/scripts/compose.sh" --profile '*' down --remove-orphans

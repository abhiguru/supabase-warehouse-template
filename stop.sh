#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$ROOT/scripts/operator-lock.sh"
state="$(operator_state)"
operator_lock "$state"
# Preserve volumes/data. The wrapper verifies ownership before stopping anything.
# Every profile (monitoring, pooler, printing) stops too: a plain `down` would
# leave profile-gated containers running and the restore preflight would refuse.
bash "$ROOT/scripts/compose.sh" --profile '*' down

#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${WAREHOUSE_STATE_DIR:-}" ]]; then
  echo 'Set WAREHOUSE_STATE_DIR to the installed operator state. Use ./setup.sh --operator for first installation.' >&2
  exit 1
fi
node "$ROOT/scripts/doctor.mjs" --preflight
bash "$ROOT/scripts/compose.sh" up -d --wait --wait-timeout 180
node "$ROOT/scripts/doctor.mjs" --local

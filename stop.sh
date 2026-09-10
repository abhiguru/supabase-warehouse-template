#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Preserve volumes/data. The wrapper verifies ownership before stopping anything.
bash "$ROOT/scripts/compose.sh" down

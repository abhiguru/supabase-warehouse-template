#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$ROOT/scripts/check-readiness.sh"
bash "$ROOT/scripts/compose.sh" up -d --wait --wait-timeout 180
bash "$ROOT/health-check.sh"

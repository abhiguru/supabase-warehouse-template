#!/usr/bin/env bash
# New installations only. Existing configuration is never overwritten.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$ROOT/scripts/check-readiness.sh"
for command in docker node; do
  command -v "$command" >/dev/null || { echo "Missing prerequisite: $command" >&2; exit 1; }
done
node "$ROOT/scripts/configure.mjs"
bash "$ROOT/scripts/compose.sh" config --quiet
bash "$ROOT/scripts/compose.sh" up -d --wait --wait-timeout 180
bash "$ROOT/scripts/migrate.sh"
bash "$ROOT/health-check.sh"
echo "Setup succeeded. Configuration is in docker/.env (credentials are not printed)."

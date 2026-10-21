#!/usr/bin/env bash
# The operator health check: the services, the database, the gateway (public configuration and a `get_public_config` RPC probe through Kong) and the PDF
# renderer. The checks are the ones the 5-minute checker also runs, in scripts/watch.mjs (`node scripts/watch.mjs health`);
# this file keeps the command name and, when a check fails, adds the diagnostics of the gateway, functions and REST logs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! node "$ROOT/scripts/watch.mjs" health "$@"; then
  node "$ROOT/scripts/service-diagnostics.mjs" kong functions rest
  exit 1
fi

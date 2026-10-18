#!/usr/bin/env bash
# Starts the monitoring services (Prometheus, Alertmanager and the three exporters) when this installation has a
# Slack webhook stored: without them no alert is ever sent. An installation without a webhook (setup.sh
# --alert-webhook-file off) keeps monitoring optional and this does nothing.
#   --build   build the monitoring images that are missing first (setup.sh); start.sh never builds.
# Called by setup.sh and start.sh, which hold the operator lock. A failure is a warning, never an error: the core
# services are up, and `npm run doctor` reports "monitoring is not running" while it stays down.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
state="${WAREHOUSE_STATE_DIR:-}"
[[ -n "$state" && -f "$state/config/monitoring/alertmanager/webhook-url" ]] || exit 0
services=(prometheus alertmanager postgres-exporter node-exporter cadvisor)
compose() { bash "$ROOT/scripts/compose.sh" --profile monitoring "$@"; }
if [[ "${1:-}" == --build ]]; then
  compose build "${services[@]}" || { echo 'Warning: the monitoring images did not build, so no alert will reach Slack. Run `bash scripts/build-images.sh`, then `bash start.sh`.' >&2; exit 0; }
  up_args=()
else
  up_args=(--no-build)
fi
if ! compose up -d "${up_args[@]}" --wait --wait-timeout 180 "${services[@]}"; then
  echo 'Warning: the monitoring services did not start (message above), so no alert will reach Slack. Fix the cause, then run `bash start.sh`.' >&2
fi
exit 0

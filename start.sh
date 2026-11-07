#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${WAREHOUSE_STATE_DIR:-}" ]]; then
  echo 'Set WAREHOUSE_STATE_DIR to the installed operator state. Use ./setup.sh --operator for first installation.' >&2
  exit 1
fi
node "$ROOT/scripts/doctor.mjs" --preflight
# shellcheck source=scripts/operator-lock.sh
. "$ROOT/scripts/operator-lock.sh"
STATE="$(operator_state)"
operator_lock "$STATE"
# Before anything is changed: Docker must be able to allocate the subnet of the internal renderer network.
bash "$ROOT/scripts/network-preflight.sh"
# Before the db container is recreated: a PostgreSQL 15 database must go through the baseline reload.
bash "$ROOT/scripts/db-version-preflight.sh"
# The operator wants the stack up: the boot unit and the checker's self-healing may act again (stop.sh wrote this file).
rm -f -- "$STATE/config/stopped-by-operator"
# An upgrade that stopped half way (upgrade.sh leaves config/upgrade-in-progress) is said before anything starts: this start brings up
# whatever is installed, which may be a mixture of the old and the new release.
node "$ROOT/scripts/upgrade-record.mjs" message || true
# --remove-orphans removes the containers of services that were removed from the Compose file (see CHANGELOG.md).
# Services of a profile (printing, sensors, pooler) are disabled services, not
# orphans, so they are kept.
# The LAN fallback (gateway-lan) is left out of this start (WAREHOUSE_COMPOSE_WITHOUT_LAN, scripts/compose.sh): a fault of the fallback (its port
# is taken, the container is unhealthy) must never stop a start, so this waits for the public services only, and the next line starts
# gateway-lan on its own, where a fault is a warning.
WAREHOUSE_COMPOSE_WITHOUT_LAN=1 bash "$ROOT/scripts/compose.sh" up -d --remove-orphans --wait --wait-timeout 180
bash "$ROOT/scripts/lan.sh" start || echo 'Warning: the LAN fallback was not started (message above). The public services are up.' >&2
# Optional services (printing, sensors, pooler) are not part of that start; the LAN fallback was started by lan.sh above.
# Replace the running ones whose image or configuration changed.
bash "$ROOT/scripts/build-images.sh" --replace-optional || echo 'Warning: a running optional service was not replaced (message above). The core services are up.' >&2
# The Windows print bridge (PRINT_TRANSPORT=bridge): scripts/compose.sh works out its address (the WSL2 default gateway) at every
# start. Say what it is, or that it could not be worked out; printing is not needed for the start, so this never stops it.
if grep -Eq '^PRINT_TRANSPORT=bridge[[:space:]]*$' "$STATE/config/compose.env"; then
  if grep -Eq '^PRINTBRIDGE_URL=.' "$STATE/config/compose.env"; then
    echo 'Print bridge: the address set in compose.env (PRINTBRIDGE_URL).'
  else
    bridge_url="$(bash "$ROOT/scripts/print-bridge-url.sh" "$(sed -n 's/^PRINTBRIDGE_PORT=//p' "$STATE/config/compose.env" | head -n 1)" || true)"
    if [[ -n "$bridge_url" ]]; then
      echo "Print bridge: $bridge_url (the Windows host, worked out at this start)."
      # PRINTBRIDGE_URL is fixed when the functions container is created, and the gateway can change at a Windows restart: the running
      # container must carry the address worked out now. `up -d functions` recreates it only when its configuration differs.
      functions_id="$(bash "$ROOT/scripts/compose.sh" ps -q functions 2>/dev/null | head -n 1 || true)"
      if [[ -n "$functions_id" ]]; then
        running_url="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$functions_id" 2>/dev/null | sed -n 's/^PRINTBRIDGE_URL=//p' | head -n 1 || true)"
        if [[ "$running_url" != "$bridge_url" ]]; then
          echo "Print bridge: the functions container has '${running_url:-nothing}'; recreating it with $bridge_url."
          WAREHOUSE_COMPOSE_WITHOUT_LAN=1 bash "$ROOT/scripts/compose.sh" up -d functions || echo 'Warning: the functions container could not be recreated with the new bridge address (message above); printing may fail.' >&2
        fi
      fi
    else echo 'Warning: the Windows host address for the print bridge could not be worked out (no default route); printing will fail until it can.' >&2; fi
  fi
  # Mirrored networking has no vEthernet (WSL) adapter on Windows, so the bridge cannot bind its address and the gateway is not the
  # Windows host. Said when wslinfo can tell; without it nothing is said.
  if command -v wslinfo >/dev/null 2>&1 && [[ "$(wslinfo --networking-mode 2>/dev/null || true)" == mirrored ]]; then
    echo 'Warning: WSL uses mirrored networking; the print bridge needs NAT mode (docs/PRINTING.md). Set networkingMode=nat in %UserProfile%\.wslconfig and run wsl --shutdown, or give -ListenAddress and PRINTBRIDGE_URL explicitly.' >&2
  fi
fi
node "$ROOT/scripts/doctor.mjs" --local
# The monitoring checker runs from a systemd timer that start.sh cannot install (it needs sudo): print the command
# when the timer is missing.
WAREHOUSE_STATE_DIR="$STATE" bash "$ROOT/scripts/watch-timer.sh" hint || true

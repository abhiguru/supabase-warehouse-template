#!/usr/bin/env bash
# Keeps the functions container's PRINTBRIDGE_URL equal to the Windows print bridge address (docs/PRINTING.md, "Restarts").
# PRINTBRIDGE_URL is fixed when the functions container is created, and the WSL2 default gateway (the Windows host) can change at
# a Windows restart. With PRINT_TRANSPORT=bridge and no PRINTBRIDGE_URL in compose.env, the address is worked out now
# (scripts/print-bridge-url.sh); when the running container carries another one it is recreated (`up -d functions` recreates
# only a container whose configuration differs). Nothing happens for PRINT_TRANSPORT other than bridge, or an address set in compose.env.
# Used by start.sh, by the boot unit (scripts/watch-timer.sh) and by the monitoring checker after it restarts functions.
# Printing is never needed for a start: every failure here is a message and exit 0.
# Usage: print-bridge-sync.sh [--quiet]    (--quiet: say something only when the container is recreated or a problem is found)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${WAREHOUSE_STATE_DIR:-}"
quiet=0; [[ "${1:-}" == --quiet ]] && quiet=1
say() { if ((quiet == 0)); then echo "$@"; fi; }
env_file="$STATE/config/compose.env"
[[ -n "$STATE" && -f "$env_file" ]] || exit 0
grep -Eq '^PRINT_TRANSPORT=bridge[[:space:]]*$' "$env_file" || exit 0
if grep -Eq '^PRINTBRIDGE_URL=.' "$env_file"; then
  say 'Print bridge: the address set in compose.env (PRINTBRIDGE_URL).'
else
  bridge_url="$(bash "$ROOT/scripts/print-bridge-url.sh" "$(sed -n 's/^PRINTBRIDGE_PORT=//p' "$env_file" | head -n 1)" || true)"
  if [[ -z "$bridge_url" ]]; then
    echo 'Warning: the Windows host address for the print bridge could not be worked out (no default route); printing will fail until it can.' >&2
  else
    say "Print bridge: $bridge_url (the Windows host, worked out now)."
    functions_id="$(bash "$ROOT/scripts/compose.sh" ps -q functions 2>/dev/null | head -n 1 || true)"
    if [[ -n "$functions_id" ]]; then
      running_url="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$functions_id" 2>/dev/null | sed -n 's/^PRINTBRIDGE_URL=//p' | head -n 1 || true)"
      if [[ "$running_url" != "$bridge_url" ]]; then
        echo "Print bridge: the functions container has '${running_url:-nothing}'; recreating it with $bridge_url."
        WAREHOUSE_COMPOSE_WITHOUT_LAN=1 bash "$ROOT/scripts/compose.sh" up -d --no-build --no-deps functions \
          || echo 'Warning: the functions container could not be recreated with the new bridge address (message above); printing may fail.' >&2
      fi
    fi
  fi
fi
# Mirrored networking has no vEthernet (WSL) adapter on Windows, so the bridge cannot bind its address and the gateway is not the
# Windows host. Said when wslinfo can tell; without it nothing is said.
if command -v wslinfo >/dev/null 2>&1 && [[ "$(wslinfo --networking-mode 2>/dev/null || true)" == mirrored ]]; then
  echo 'Warning: WSL uses mirrored networking; the print bridge needs NAT mode (docs/PRINTING.md). Set networkingMode=nat in %UserProfile%\.wslconfig and run wsl --shutdown, or give -ListenAddress and PRINTBRIDGE_URL explicitly.' >&2
fi
exit 0

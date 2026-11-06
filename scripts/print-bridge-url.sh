#!/usr/bin/env bash
# Prints the address of the Windows print bridge as seen from a WSL2 distro in NAT mode: the Windows host is the distro's default
# gateway (it can change at every Windows restart, so this is worked out at each start, never stored). Prints nothing when there
# is no default route. Mirrored networking is not verified (docs/PRINTING.md).
# Usage: print-bridge-url.sh [port]   (default 9631)
set -euo pipefail
port="${1:-9631}"
[[ "$port" =~ ^[0-9]{1,5}$ ]] || exit 0
gateway="$(ip -4 route show default 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit } }' || true)"
[[ "$gateway" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 0
echo "http://$gateway:$port"

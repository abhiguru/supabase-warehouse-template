#!/usr/bin/env bash
# The LAN fallback (Compose profile `lan`, service gateway-lan): a second, plain-http nginx listener on the host's own private
# address, which the app uses only when the public address fails (an internet outage). It is off by default: an installation that
# never turns it on has no gateway-lan container and publishes nothing but the loopback gateway port.
# The fallback needs no certificate, no DNS record and no port forwarding (a DHCP reservation for the host is advised). Read
# docs/OPERATOR_INSTALL.md, "LAN fallback", first: while the fallback is in use, tokens cross the Wi-Fi unencrypted.
#
#   bash scripts/lan.sh on [<address>|auto] [--cidr <range>] [--port <n>]
#                                   Turns the fallback on. <address> is the host's own private address (10.x.x.x, 172.16-31.x.x,
#                                   192.168.x.x; anything else is refused) and must be on an interface of this host; `auto`
#                                   (the default) is the private address of the default-route interface. --cidr is the
#                                   warehouse network that may connect (default: the network of that interface); --port is the
#                                   port (default 8080, or the one already set). Checks the port is free or this
#                                   installation's own, writes LAN_ENABLED, LAN_BIND_IP, LAN_HTTP_PORT, LAN_CIDR and
#                                   COMPOSE_PROFILES (lan added beside what is there) to config/compose.env, starts the
#                                   gateway-lan service, recreates the function runtime (it reads the address to offer to
#                                   phones), runs the LAN checks of doctor and prints the address for the app and a note on the host
#                                   firewall (nothing to add on an ordinary host). Safe to repeat; run it again when the router gives
#                                   the host another address. A rerun that fails puts the earlier settings back and starts the
#                                   service with them again.
#   bash scripts/lan.sh off         Turns it off: removes the service and the variables. Phones that saved the address stop
#                                   using it (they keep working over the internet).
#   bash scripts/lan.sh status      Prints the address for the app, whether the host still has it, and the container state.
#   bash scripts/lan.sh start       For start.sh, setup.sh and restore.sh, which start everything else without gateway-lan (the
#                                   fallback must never stop them): starts the service when compose.env turns the fallback on and the
#                                   host has the address. It always exits 0; a fault is a warning.
# Takes the operator lock (inherited when another operator command runs it). `on` needs the stack running (bash start.sh).
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() { echo 'Usage: bash scripts/lan.sh on [<address>|auto] [--cidr <range>] [--port <n>] | off | status | start' >&2; exit 1; }
(($# >= 1)) || usage
command="$1"
shift
case "$command" in
  on) ;;
  off|status|start) (($# == 0)) || usage ;;
  *) usage ;;
esac
# shellcheck source=scripts/operator-lock.sh
. "$ROOT/scripts/operator-lock.sh"
state="$(operator_state)"
operator_lock_or_inherited "$state"
live="$state/config/compose.env"
staged="$live.lan"
previous="$live.lan-previous"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
trap 'rm -f "$staged" "$previous"' EXIT
# "running healthy", "exited", ... or nothing when there is no such container.
container_state() { compose --profile lan ps --all --format '{{.State}} {{.Health}}' gateway-lan 2>/dev/null | head -n 1 || true; }
service_running() {
  local id
  id="$(compose ps -q "$1" 2>/dev/null || true)"
  [[ -n "$id" && "$(docker inspect --format '{{.State.Running}}' "$id" 2>/dev/null || true)" == true ]]
}

case "$command" in
  status)
    node "$ROOT/scripts/lan.mjs" status "$live" "$(container_state)"
    ;;
  on)
    service_running gateway || { echo 'The gateway service is not running; start the instance first (bash start.sh).' >&2; exit 1; }
    # The checks of the address, range and port run first and write a staged copy of compose.env; nothing is changed if they refuse.
    node "$ROOT/scripts/lan.mjs" stage "$live" "$staged" on "$@"
    cp -p "$live" "$previous"
    mv -f "$staged" "$live"
    # gateway-lan, and the function runtime, whose environment now carries the address that get-config offers to signed-in phones.
    if ! compose --profile lan up -d --no-deps --wait --wait-timeout 180 gateway-lan functions; then
      node "$ROOT/scripts/service-diagnostics.mjs" gateway-lan || true
      mv -f "$previous" "$live"
      if grep -qx 'LAN_ENABLED=true' "$live"; then
        # The fallback was on, with the settings of the file now back in place: a failed rerun (a new port, a new range) must not take a
        # working fallback away. Start it again with them (the function runtime too: the failed run gave it the new address).
        if compose --profile lan up -d --no-deps --wait --wait-timeout 180 gateway-lan functions >/dev/null 2>&1; then
          echo 'The gateway-lan service did not become healthy with the new settings (see above). The LAN fallback keeps its earlier settings: config/compose.env is as it was and the service runs with them again.' >&2
        else
          echo 'The gateway-lan service did not become healthy with the new settings (see above), and it did not start again with the earlier ones either. config/compose.env is as it was. Check: bash scripts/lan.sh status' >&2
        fi
      else
        compose --profile lan rm -sf gateway-lan >/dev/null 2>&1 || true
        compose up -d --no-deps --wait --wait-timeout 180 functions >/dev/null 2>&1 || true
        echo 'The gateway-lan service did not become healthy (see above). The LAN fallback was not turned on and config/compose.env is as it was.' >&2
      fi
      exit 1
    fi
    node "$ROOT/scripts/lan.mjs" announce "$live"
    # The same LAN checks as `doctor`: the address is on this host, the container publishes only it, and it answers as this installation.
    if ! node "$ROOT/scripts/doctor.mjs" --lan; then
      echo 'The LAN fallback is on, but a check above failed. Fix it, then run: node scripts/doctor.mjs --lan' >&2
      exit 1
    fi
    ;;
  start)
    # Called by start.sh, setup.sh and restore.sh after their `up --wait` of everything else, which leaves gateway-lan out
    # (WAREHOUSE_COMPOSE_WITHOUT_LAN, scripts/compose.sh) so that a fault of the fallback cannot stop them. Never fails.
    grep -qx 'LAN_ENABLED=true' "$live" && grep -Eq '^COMPOSE_PROFILES=.*\blan\b' "$live" || exit 0
    # The guard of compose.sh: the host no longer has the address, or it is not a private one. It says why on stderr.
    reason="$(node "$ROOT/scripts/lan.mjs" guard "$live" 2>&1 >/dev/null || true)"
    if [[ -n "$reason" ]]; then
      echo "Warning: ${reason} The public services are not affected." >&2
      exit 0
    fi
    if ! compose --profile lan up -d --no-deps --wait --wait-timeout 60 gateway-lan; then
      node "$ROOT/scripts/service-diagnostics.mjs" gateway-lan || true
      echo 'Warning: the LAN fallback (the gateway-lan service) did not start or did not become healthy (message above). The public services are not affected. Check: bash scripts/lan.sh status, then node scripts/doctor.mjs --lan' >&2
    fi
    exit 0
    ;;
  off)
    node "$ROOT/scripts/lan.mjs" stage "$live" "$staged" off
    mv -f "$staged" "$live"
    compose --profile lan rm -sf gateway-lan >/dev/null
    # The function runtime stops offering the address. Not started if the stack is stopped: it picks the change up at the next start.
    if service_running functions; then compose up -d --no-deps --wait --wait-timeout 180 functions; fi
    echo 'The LAN fallback is off: the gateway-lan service is removed and the variables are reset. Phones that saved the address stop using it and keep working over the internet.'
    ;;
esac

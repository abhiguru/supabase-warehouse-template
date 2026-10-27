#!/usr/bin/env bash
# Maintenance mode: while it is on, both gateways (gateway, and gateway-lan when it runs) answer every request for the API (/rest/v1/, /storage/v1/,
# /functions/v1/) with HTTP 503 and the body {"code":"upgrading", ...}, so the app tells the user that the server is being updated and nothing
# is written meanwhile. /health and the CORS preflight answer as always. It is the write freeze of an upgrade (docs/OPERATOR_INSTALL.md, "While it
# upgrades"): upgrade.sh turns it on before the backup and off after the setup of the new release, so that a way back to the backup loses nothing
# that a phone recorded. It is not a setting of the installation.
#
#   bash scripts/maintenance.sh on      Writes the marker config/maintenance and recreates the gateways with WAREHOUSE_MAINTENANCE=upgrading (the
#                                       API is closed from then on). Safe to repeat. A gateway container that is not running, or that cannot be
#                                       recreated, is removed (not stopped): only a Compose command can bring it back, and every one of them
#                                       reads the marker, so the API is closed or down, never open. A stack that is not running starts closed.
#   bash scripts/maintenance.sh off     Removes the marker, recreates the gateway (also one that was stopped or removed, so that a refused upgrade
#                                       does not leave the facility down) and runs the health check (scripts/watch.mjs health), because the checks
#                                       that setup and doctor ran while the API was closed could not probe it. If the gateway cannot be recreated
#                                       the gateway is removed and the marker is put back: it stays closed. A stack that stop.sh stopped (no gateway
#                                       container and config/stopped-by-operator exists) is left stopped: only the maintenance marker is removed,
#                                       nothing is created, and start.sh then starts it with the API open. Exit status 1: still closed, or not done; 2: the API is OPEN but
#                                       the health check failed (upgrade.sh records that the API is open).
#   bash scripts/maintenance.sh status  Says whether the marker exists and what each running gateway was started with.
#
# The marker is read by scripts/compose.sh for every command (WAREHOUSE_MAINTENANCE=upgrading in the environment of Compose), so a gateway that is
# recreated by anything else while it exists, the setup of the next release among them, comes back closed. `on` and `off` take the operator lock
# (inherited when upgrade.sh runs them); `status` does not, so it can be read while an upgrade runs.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() { echo 'Usage: bash scripts/maintenance.sh on | off | status' >&2; exit 1; }
(($# == 1)) || usage
command="$1"
case "$command" in on|off|status) ;; *) usage ;; esac
# shellcheck source=scripts/operator-lock.sh
. "$ROOT/scripts/operator-lock.sh"
state="$(operator_state)"
[[ "$command" == status ]] || operator_lock_or_inherited "$state"
marker="$state/config/maintenance"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
marker_exists() { [[ -e "$marker" || -L "$marker" ]]; }
# The marker is replaced whole by a rename, so a reader never sees half of it.
write_marker() {
  local tmp
  tmp="$(mktemp "$state/config/.maintenance.XXXXXX")" || return 1
  printf 'upgrading\n' > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$marker" || { rm -f -- "$tmp"; return 1; }
}
# exists SERVICE [COMPOSE OPTIONS]: there is a container of the service, running or not.
exists() { [[ -n "$(compose "${@:2}" ps -aq "$1" 2>/dev/null || true)" ]]; }
# running SERVICE [COMPOSE OPTIONS]: the container of the service exists and runs.
running() {
  local id
  id="$(compose "${@:2}" ps -q "$1" 2>/dev/null || true)"
  [[ -n "$id" && "$(docker inspect --format '{{.State.Running}}' "$id" 2>/dev/null || true)" == true ]]
}
# The WAREHOUSE_MAINTENANCE a running service was created with: upgrading, off, or nothing when there is no container.
created_with() {
  local id
  id="$(compose "${@:2}" ps -q "$1" 2>/dev/null || true)"
  [[ -n "$id" ]] || return 0
  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$id" 2>/dev/null | sed -n 's/^WAREHOUSE_MAINTENANCE=//p' | head -n 1
}
diagnose() { node "$ROOT/scripts/service-diagnostics.mjs" "$1" || true; }

case "$command" in
  on)
    write_marker || { echo "Could not write $marker, so maintenance mode was not turned on. Nothing was changed." >&2; exit 1; }
    if running gateway; then
      if ! compose up -d --no-deps --no-build --force-recreate --wait --wait-timeout 120 gateway; then
        diagnose gateway
        # The old container may still be the one that runs, with the API open: remove it. Down is closed, and with no container only a Compose
        # command can bring one back, which reads the marker. (Not `stop`: a stopped container keeps its open environment, and a restart policy
        # or a `--no-recreate` start would bring it back open.)
        compose rm -sf gateway >/dev/null 2>&1 || true
        if exists gateway; then
          echo "The gateway did not come up in maintenance mode (message above) and could not be removed, so it may still run, or start again, with the API open. Remove it: bash scripts/compose.sh rm -sf gateway" >&2
          exit 1
        fi
        echo "The gateway did not come up in maintenance mode (message above), so it was removed: the API is closed or down, never open. $marker stays. Fix the cause and run this again; 'bash scripts/maintenance.sh off' opens the API." >&2
        exit 1
      fi
    elif exists gateway; then
      # Created open and not running now (stopped, or crashed and waiting for Docker's restart): it must not start again as it is.
      compose rm -sf gateway >/dev/null 2>&1 || true
      if exists gateway; then
        echo 'The gateway container is not running and could not be removed, so it could start again with the API open. Remove it: bash scripts/compose.sh rm -sf gateway' >&2
        exit 1
      fi
      echo 'The gateway was not running: its container was removed, so that it cannot start again with the API open. It starts in maintenance mode.'
    else
      echo 'The gateway is not running: it starts in maintenance mode.'
    fi
    # The other way in: the LAN fallback. A missing container starts closed (lan.sh start goes through compose.sh); a stopped one is removed.
    if running gateway-lan --profile lan; then
      if ! compose --profile lan up -d --no-deps --no-build --force-recreate --wait --wait-timeout 60 gateway-lan; then
        diagnose gateway-lan
        compose --profile lan rm -sf gateway-lan >/dev/null 2>&1 || true
        if running gateway-lan --profile lan; then
          echo "The gateway-lan service did not come up in maintenance mode (message above) and could not be removed, so the LAN path is still open. Remove it: bash scripts/compose.sh --profile lan rm -sf gateway-lan" >&2
          exit 1
        fi
        echo "Warning: the gateway-lan service did not come up in maintenance mode (message above), so it was removed; phones on the LAN path get no answer until 'bash scripts/maintenance.sh off' starts it again. The internet path is closed as intended." >&2
      fi
    elif exists gateway-lan --profile lan; then
      compose --profile lan rm -sf gateway-lan >/dev/null 2>&1 || true
      if exists gateway-lan --profile lan; then
        echo "The gateway-lan container is not running and could not be removed, so it could start again with the LAN path open. Remove it: bash scripts/compose.sh --profile lan rm -sf gateway-lan" >&2
        exit 1
      fi
    fi
    echo "Maintenance mode is on: the API answers 503 \"upgrading\" (marker $marker). Turn it off with: bash scripts/maintenance.sh off"
    ;;
  off)
    marker_exists || echo "Maintenance mode was not on (no $marker); the gateways are recreated anyway."
    rm -f -- "$marker"
    # Created again, without the word: one that runs is replaced, and one that is stopped or was removed (by `on`, after a refused or failed upgrade)
    # comes back. Without this a facility whose upgrade was refused would stay down, and this command would be the advice that does not help.
    if ! exists gateway; then
      if [[ -e "$state/config/stopped-by-operator" || -L "$state/config/stopped-by-operator" ]]; then
        echo 'Maintenance mode is off, but the stack was stopped by stop.sh (config/stopped-by-operator) and is left stopped: no gateway was created. Run: bash start.sh'
        exit 0
      fi
      echo 'The gateway had no container (it was removed, or the stack is stopped): it is created and starts open.'
    fi
    if ! compose up -d --no-deps --no-build --force-recreate --wait --wait-timeout 120 gateway; then
      diagnose gateway
      write_marker || true
      # The new container was created without the word and may still run, or start again, open: remove it, as `on` does.
      compose rm -sf gateway >/dev/null 2>&1 || true
      echo "The gateway did not come up (message above). Maintenance mode is still on ($marker was put back): the API is closed or down, never half open. Fix the cause and run this again." >&2
      exit 1
    fi
    # A gateway-lan that exists but does not run is created again too; one that is meant to run (LAN_ENABLED) and has no container is started by
    # lan.sh start. A fault of the fallback is a warning here, as in start.sh.
    if exists gateway-lan --profile lan && ! running gateway-lan --profile lan; then
      compose --profile lan up -d --no-deps --no-build --force-recreate --wait --wait-timeout 60 gateway-lan \
        || { diagnose gateway-lan; echo 'Warning: the gateway-lan service did not start (message above). The public services are up.' >&2; }
    fi
    bash "$ROOT/scripts/lan.sh" start || echo 'Warning: the LAN fallback was not started (message above). The public services are up.' >&2
    if ! node "$ROOT/scripts/watch.mjs" health --wait 60; then
      echo "Maintenance mode is off, but the health check failed (above): the API is open and something is wrong. Close it while you look: bash scripts/maintenance.sh on" >&2
      exit 2
    fi
    echo 'Maintenance mode is off: the API answers phones again.'
    ;;
  status)
    if marker_exists; then
      echo "Maintenance mode: on ($marker exists). Every API request answers 503 \"upgrading\" until: bash scripts/maintenance.sh off"
    else
      echo 'Maintenance mode: off'
    fi
    for service in gateway gateway-lan; do
      profile=()
      [[ "$service" == gateway ]] || profile=(--profile lan)
      word="$(created_with "$service" "${profile[@]+"${profile[@]}"}")"
      [[ -z "$word" ]] || echo "  $service: started with WAREHOUSE_MAINTENANCE=$word"
    done
    ;;
esac

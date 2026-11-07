#!/usr/bin/env bash
# The printing image, without a printer: it never sends a job and never touches a device. Every container runs with --network none, and
# the queue is made on PRINTER_URI=file:/dev/null, the only device URI this check may ever use (a real URI would make CUPS try the
# printer). WH-109: the entrypoint creates the one raw queue and fails the start when it cannot, so this also checks
#   * the start is refused without an administrator password, without a device (no USB Epson, no PRINTER_URI), and for a queue name CUPS
#     cannot use;
#   * with PRINTER_URI=file:/dev/null the queue LQ1310_RAW exists, is enabled and accepting, and the image's health check passes;
#   * the same health check fails for a queue that does not exist;
#   * the shipped cupsd.conf parses, and the spool survives the entrypoint.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
# Builds the printing image of this project: one operator command at a time per state.
# shellcheck source=scripts/operator-lock.sh
. "$ROOT/scripts/operator-lock.sh"
state="$(operator_state)"
operator_lock "$state"
compose --profile printing build cups
image=$(compose --profile printing images -q cups)
# A profile need not have a running container to have a built image.
if [[ -z "$image" ]]; then
  state="${WAREHOUSE_STATE_DIR:-}"
  [[ "$state" == /* && -f "$state/config/compose.env" ]] || { echo 'Set WAREHOUSE_STATE_DIR to the installed operator state.' >&2; exit 1; }
  project=$(sed -n 's/^WAREHOUSE_PROJECT_NAME=//p' "$state/config/compose.env")
  [[ "$project" =~ ^warehouse-[a-z0-9-]+$ ]] || { echo 'Invalid owned Compose project name.' >&2; exit 1; }
  image="${project}-cups"
fi
password=isolated-disposable-test-only
queue=LQ1310_RAW
# The only device this check uses. Never replace it with a real printer URI.
device=file:/dev/null
conf="$ROOT/docker/cups/config/cupsd.conf"
[[ -f "$conf" ]] || { echo "Missing $conf" >&2; exit 1; }
run() { docker run --rm --network none --label purpose=warehouse-cups-check "$@"; }

# 1. No administrator password: refused.
if run "$image" true; then
  echo 'CUPS unexpectedly accepted a missing administrator password.' >&2
  exit 1
fi

# 2. A password but no device: with no PRINTER_URI the container looks for a USB Epson; there is none, so the start must fail and say so.
if output=$(run -e CUPS_ADMIN_PASSWORD="$password" "$image" true 2>&1); then
  echo 'CUPS unexpectedly started without a printer device.' >&2
  exit 1
fi
grep -q 'No USB Epson printer was found' <<<"$output" || { echo 'The start without a device did not say that no USB printer was found.' >&2; echo "$output" >&2; exit 1; }

# 3. A queue name CUPS cannot use is refused before anything is created.
for bad in 'a/b' 'a b' '../x'; do
  if output=$(run -e CUPS_ADMIN_PASSWORD="$password" -e PRINTER_NAME="$bad" -e PRINTER_URI="$device" "$image" true 2>&1); then
    echo "CUPS unexpectedly accepted the queue name '$bad'." >&2
    exit 1
  fi
  grep -q 'is not a valid CUPS queue name' <<<"$output" || { echo "No clear message for the queue name '$bad'." >&2; echo "$output" >&2; exit 1; }
done

# 4. The shipped configuration, the entrypoint with the null device, the queue, the health check and the spool.
run -e CUPS_ADMIN_PASSWORD="$password" -e PRINTER_NAME="$queue" -e PRINTER_URI="$device" \
  -v "$conf:/etc/cups/cupsd.conf.custom:ro" --entrypoint bash "$image" -ec '
  test ! -e /usr/sbin/ipp-usb
  cupsd -t -c /etc/cups/cupsd.conf.custom
  printf "preserved fictional spool marker" > /var/spool/cups/d-readiness
  /entrypoint.sh bash -ec '\''
    test -f /var/spool/cups/d-readiness
    cupsd
    for _ in $(seq 1 30); do lpstat -r 2>/dev/null | grep -q "is running" && break; sleep 1; done
    curl --fail --silent http://localhost:631/ >/dev/null
    # The queue exists, is enabled and accepts jobs.
    lpstat -p "$PRINTER_NAME" | grep -q "enabled"
    lpstat -a "$PRINTER_NAME" | grep -q "accepting requests"
    # The image health check (docker/cups/Dockerfile, docker-compose.yml) passes for it and fails for a queue that is not there.
    lpstat -p "$PRINTER_NAME" 2>/dev/null | head -n 1 | grep -q " enabled since"
    if lpstat -p NoSuchQueue 2>/dev/null | head -n 1 | grep -q " enabled since"; then echo "the health check passed for a missing queue" >&2; exit 1; fi
    # A disabled queue is not healthy.
    cupsdisable "$PRINTER_NAME"
    if lpstat -p "$PRINTER_NAME" 2>/dev/null | head -n 1 | grep -q " enabled since"; then echo "the health check passed for a disabled queue" >&2; exit 1; fi
  '\''
'
echo 'CUPS credential rejection, device and queue-name refusal, queue creation on the null device, health check, spool preservation and local HTTP service passed; physical printing remains unverified.'

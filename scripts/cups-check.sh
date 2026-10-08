#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
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
if docker run --rm --network none "$image" true; then
  echo 'CUPS unexpectedly accepted a missing administrator password.' >&2
  exit 1
fi
docker run --rm --network none --entrypoint bash "$image" -ec '
  test ! -e /usr/sbin/ipp-usb
  cupsd -t
  printf "preserved fictional spool marker" > /var/spool/cups/d-readiness
  export CUPS_ADMIN_PASSWORD=isolated-disposable-test-only
  /entrypoint.sh bash -ec '\''
    test -f /var/spool/cups/d-readiness
    cupsd
    curl --fail --silent http://localhost:631/ >/dev/null
  '\''
'
echo 'CUPS credential rejection, spool preservation and local HTTP service passed; physical printing remains unverified.'

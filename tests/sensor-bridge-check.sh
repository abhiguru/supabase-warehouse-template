#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
# Builds the sensor bridge image of this project (profile `sensors`) and checks
# it without hubs or a network: the configuration check accepts a complete
# fictional configuration (exit 0) and refuses an empty one (exit 78, as an
# unconfigured bridge does when started), neither prints a secret, and the
# bridge's unit tests pass with the image's Python and python-kasa.
# One operator command at a time per state.
# shellcheck source=scripts/operator-lock.sh
. "$ROOT/scripts/operator-lock.sh"
state="$(operator_state)"
operator_lock "$state"
if [[ ! -f "$ROOT/docker/sensor-bridge/Dockerfile" ]]; then
  echo 'docker/sensor-bridge/Dockerfile is absent in this checkout, so there is no sensor bridge to check.' >&2
  exit 1
fi
compose --profile sensors build sensor-bridge
image=$(compose --profile sensors images -q sensor-bridge)
# A profile need not have a running container to have a built image.
if [[ -z "$image" ]]; then
  project=$(sed -n 's/^WAREHOUSE_PROJECT_NAME=//p' "$state/config/compose.env")
  [[ "$project" =~ ^warehouse-[a-z0-9-]+$ ]] || { echo 'Invalid owned Compose project name.' >&2; exit 1; }
  image="${project}-sensor-bridge"
fi
# The same restrictions as the Compose service, and no network at all.
run() { docker run --rm --network none --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges:true "$@"; }

# Fictional values only; the check fails if either secret appears in the output.
password="$(printf 'check%.0s' 1 2 3 4 5)"
key="$(printf 'ab%.0s' $(seq 32))"   # 64 hex characters, the form of a real key
set +e
output=$(run -e SENSOR_BRIDGE_HUBS=192.0.2.10,192.0.2.11 -e TAPO_USERNAME=bridge-check@example.test \
  -e TAPO_PASSWORD="$password" -e SENSOR_INGEST_KEY="$key" -e SENSOR_BRIDGE_ID=bridge-check \
  -e SENSOR_INGEST_URL=http://kong:8000/functions/v1/ingest-sensor-readings \
  --entrypoint python "$image" -m sensor_bridge --check-config 2>&1)
status=$?
set -e
if [[ "$status" -ne 0 ]]; then
  echo "The bridge refused a complete configuration (exit $status):" >&2
  printf '%s\n' "${output//$password/[password]}" | sed "s/$key/[key]/g" >&2
  exit 1
fi
if [[ "$output" == *"$password"* || "$output" == *"$key"* ]]; then
  echo 'The configuration check printed the Tapo password or the ingest key.' >&2
  exit 1
fi
set +e
output=$(run --entrypoint python "$image" -m sensor_bridge --check-config 2>&1)
status=$?
set -e
if [[ "$status" -ne 78 ]]; then
  echo "An unconfigured bridge exited $status instead of 78 (EX_CONFIG):" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi
# The tests of this checkout, read-only, with the image's interpreter and libraries.
run -v "$ROOT/docker/sensor-bridge:/src:ro,z" -w /src -e PYTHONDONTWRITEBYTECODE=1 \
  --entrypoint python "$image" -m unittest discover -s tests -t .
echo 'Sensor bridge image, configuration check and unit tests passed; the hubs themselves remain unverified.'

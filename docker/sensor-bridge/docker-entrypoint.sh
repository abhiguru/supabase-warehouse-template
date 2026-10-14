#!/bin/sh
# Options (or nothing) go to the bridge: `docker run IMAGE --check-config`.
# Any other command runs as given: `docker run IMAGE python -m unittest discover -s tests`.
set -eu
if [ "$#" -eq 0 ] || [ "${1#-}" != "$1" ]; then
  set -- python -m sensor_bridge "$@"
fi
exec "$@"

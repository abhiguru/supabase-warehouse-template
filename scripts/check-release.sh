#!/usr/bin/env bash
set -euo pipefail
echo 'No operator release tag is approved yet. Complete VM, MSG91, native-device and restore acceptance before enabling releases.' >&2
exit 1

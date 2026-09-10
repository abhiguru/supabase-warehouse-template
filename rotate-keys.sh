#!/usr/bin/env bash
set -euo pipefail
echo "Automatic key rotation is disabled in this incomplete starter." >&2
echo "Changing only .env leaves database JWT configuration and existing sessions inconsistent." >&2
echo "No credentials were read or changed. See docs/READINESS.md." >&2
exit 1

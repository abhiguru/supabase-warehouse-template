#!/usr/bin/env bash
set -euo pipefail
# Remove this release gate only after full migration and API contract tests pass.
echo "NOT READY: the v0.1.0 backend export is incomplete. No setup changes were made." >&2
echo "See docs/READINESS.md for reproduced schema errors and the completion checklist." >&2
exit 1

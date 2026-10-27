#!/usr/bin/env bash
# Writes public/release.json and public/app-compat.json for the checkout that runs it (scripts/release-info.mjs), with the newest applied
# migration read from the database. Run by setup.sh and by restore.sh after their migrations, so the two files describe the code that is
# about to run, also after a rollback to an older checkout.
#   WAREHOUSE_STATE_DIR=/abs/state bash scripts/release-info.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
schema_head="$(bash "$ROOT/scripts/compose.sh" exec -T db psql -X -A -t -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -c 'SELECT name FROM warehouse_migrations.applied ORDER BY name COLLATE "C" DESC LIMIT 1')"
[[ -n "$schema_head" ]] || { echo 'The migration ledger is empty: no release file was written. Run bash setup.sh again.' >&2; exit 1; }
node "$ROOT/scripts/release-info.mjs" write "$schema_head"

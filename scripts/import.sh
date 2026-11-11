#!/usr/bin/env bash
# CSV import of customers, items and rates for a new facility (WH-142, part 1; docs/OPERATOR_INSTALL.md, "Import customers, items and rates").
#
#   bash scripts/import.sh [--customers customers.csv] [--items items.csv] [--rates rates.csv] [--apply]
#
# Any subset of the three files. Without --apply it is a dry run: the files are checked, the database is asked what the import would do, and
# nothing is saved. With --apply the import is saved in one transaction, only when there is no error (all or nothing), in the order
# customers, items, rates. Nothing existing is ever changed. Templates: scripts/import-templates/. Exit status 1 = at least one error.
# Takes the operator lock like any operator command (setup, backup, restore and checks hold it too: wait for them or stop them).
# Needs WAREHOUSE_STATE_DIR and a running stack (bash start.sh).
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/operator-lock.sh
. "$ROOT/scripts/operator-lock.sh"
state="$(operator_state)"
operator_lock_or_inherited "$state"
# shellcheck source=scripts/require-node.sh
. "$ROOT/scripts/require-node.sh"
node "$ROOT/scripts/import.mjs" "$@"

#!/usr/bin/env bash
# CSV import for a facility (docs/OPERATOR_INSTALL.md, "Import customers, items and rates" and "Import past years"): customers, items and
# rates (WH-142), and past years' GRNs, dispatches, invoices and payments from an old system (WH-180).
#
#   bash scripts/import.sh [--folder <dir>] [--customers customers.csv] [--items items.csv] [--rates rates.csv] [--apply]
#
# --folder takes any of customers.csv, items.csv, rates.csv, grns.csv, grn-lines.csv, dispatches.csv, dispatch-lines.csv, invoices.csv,
# invoice-lines.csv and payments.csv found in it. Without --apply it is a dry run: the files are checked, the database is asked what the
# import would do, and nothing is saved. With --apply the import is saved in one transaction, only when there is no error (all or nothing),
# and only when a backup made and verified today is on record. Nothing made in the app is ever changed. Templates: scripts/import-templates/.
# Exit status 1 = at least one error (or no backup of today), 2 = wrong usage.
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

#!/usr/bin/env bash
# CI helper for the upgrade drill (the operator-upgrade job in .github/workflows/ci.yml): proves that the API was closed (a 503
# "upgrading") DURING the backup and its verification, not only at some point of the run.
#
#   bash scripts/ci-freeze-check.sh UPGRADE_LOG PROBE_LOG
#
# UPGRADE_LOG: the output of upgrade.sh, one line per line, each with the time in milliseconds in front ("<ms> <line>").
# PROBE_LOG:   one request to the API per line, "<ms> <http status> <start of the body>".
# The window starts at the "==> Backup" line of upgrade.sh and ends at its "==> Setup" line. Exit 0 when at least one probe in the
# window was answered 503 with the body of maintenance mode; exit 1 with a line on standard error when none was, or when the window
# cannot be found (an upgrade.sh whose steps are named otherwise has to be taught to this script, not waved through).
set -euo pipefail
(($# == 2)) || { echo 'usage: ci-freeze-check.sh UPGRADE_LOG PROBE_LOG' >&2; exit 2; }
upgrade_log="$1"
probe_log="$2"
start="$(awk '$2 == "==>" && $3 == "Backup" { print $1; exit }' "$upgrade_log")"
end="$(awk '$2 == "==>" && $3 == "Setup" { print $1; exit }' "$upgrade_log")"
if [[ ! "$start" =~ ^[0-9]+$ || ! "$end" =~ ^[0-9]+$ ]]; then
  echo "the log of upgrade.sh has no \"==> Backup\" and \"==> Setup\" lines to bound the backup: the freeze during the backup cannot be proved" >&2
  exit 1
fi
count="$(awk -v start="$start" -v end="$end" '$1 + 0 >= start + 0 && $1 + 0 <= end + 0 && $2 == 503 && index($0, "\"code\":\"upgrading\"") { n++ } END { print n + 0 }' "$probe_log")"
if ((count < 1)); then
  echo "no request to the API was answered 503 \"upgrading\" between the start of the backup and the start of setup ($start to $end ms): the API was open while the backup was taken" >&2
  exit 1
fi
echo "The API answered 503 \"upgrading\" $count time(s) between the start of the backup and the start of setup."

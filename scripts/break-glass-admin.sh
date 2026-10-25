#!/usr/bin/env bash
# Break-glass sign-in for an administrator while the SMS code does not arrive (docs/OPERATOR_INSTALL.md,
# "Break-glass administrator sign-in"; docs/TROUBLESHOOTING.md, "Sign-in codes").
#
#   bash scripts/break-glass-admin.sh <the administrator's 10-digit mobile number>
#
# Asks the database (warehouse_security.break_glass_code, supabase_admin only, migration 126) for a one-time six-digit code of an
# existing, active, approved administrator and prints it once. The code works for 10 minutes and once; the administrator types it on
# the app's code screen in place of the SMS code. Making the code and using it are recorded in public.audit_log. The command takes the
# operator lock like any operator command (setup, backup, restore and checks hold it too: wait for them or stop them).
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
# shellcheck source=scripts/operator-lock.sh
. "$ROOT/scripts/operator-lock.sh"
usage() {
  echo 'Usage: bash scripts/break-glass-admin.sh <the 10-digit mobile number of an active administrator>' >&2
  echo 'Prints a one-time sign-in code for that administrator, valid for 10 minutes. Use it only when the SMS code does not arrive.' >&2
  exit 2
}
[[ $# -eq 1 ]] || usage
digits="${1//[^0-9]/}"
if [[ "$digits" =~ ^91[0-9]{10}$ ]]; then digits="${digits:2}"; fi
[[ "$digits" =~ ^[0-9]{10}$ ]] || { echo "Not a 10-digit mobile number: the number must have 10 digits (a leading 91 or +91 is allowed)." >&2; exit 2; }
state="$(operator_state)"
operator_lock "$state"
errors="$(mktemp)"
trap 'rm -f "$errors"' EXIT
# The phone number goes in as a psql variable, quoted by psql; the code is read from the one result line and is written nowhere else.
if ! line="$(compose exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -v "phone=$digits" -U supabase_admin -d postgres 2>"$errors" <<'SQL'
SELECT r->>'code' || E'\t' || regexp_replace(r->>'name', E'[\t\r\n]+', ' ', 'g')
FROM (SELECT warehouse_security.break_glass_code(:'phone') AS r) q;
SQL
)"; then
  reason="$(sed -n 's/^ERROR:  //p' "$errors" | head -n 1)"
  if [[ -n "$reason" ]]; then
    echo "Refused: $reason." >&2
  else
    echo 'The database did not answer; no code was made:' >&2
    head -n 5 "$errors" >&2
  fi
  exit 1
fi
code="${line%%$'\t'*}"
name="${line#*$'\t'}"
if [[ ! "$code" =~ ^[0-9]{6}$ ]]; then
  echo 'The database answered with something unexpected; no code is shown. Check the database log.' >&2
  exit 1
fi
cat <<EOF

  Break-glass code for $name ($digits):

      $code

This code signs in the admin $name on any phone within 10 minutes; use it only when SMS is down.
It works once. Give it only to $name, in person or by a call you trust, never in a chat group.

On the phone: open the app, enter the administrator's number, ask for the code, and type this one instead of the SMS code.
If it is not used in 10 minutes, or the app shows "Invalid or expired OTP" five times, run this command again for a new one.
Afterwards the sign-in is in the audit trail: see "Break-glass administrator sign-in" in docs/OPERATOR_INSTALL.md.

EOF

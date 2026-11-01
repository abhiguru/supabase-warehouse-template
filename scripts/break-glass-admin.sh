#!/usr/bin/env bash
# Break-glass sign-in for a facility worker (administrator, supervisor or staff; never a customer) while the association's sign-in and
# the SMS code cannot be used (docs/OPERATOR_INSTALL.md, "Break-glass administrator sign-in"; docs/CENTRAL_LOGIN.md, "When the
# association's sign-in is down"; docs/TROUBLESHOOTING.md, "Sign-in codes").
#
#   bash scripts/break-glass-admin.sh [--to-stdout] <the worker's 10-digit mobile number>
#
# Asks the database (warehouse_security.break_glass_code, supabase_admin only, migrations 126 and 132) for a one-time six-digit code of an
# existing, active, approved administrator, supervisor or staff member and prints it once. The code works for 10 minutes and once; the
# worker types it in the app under "Sign in with a code from your facility", and the session it opens lasts 24 hours. Making the code and using it are recorded in public.audit_log. The command takes the
# operator lock like any operator command (setup, backup, restore and checks hold it too: wait for them or stop them).
# The code is printed only to a terminal: through a pipe, `tee`, a redirect, a logged session wrapper or a CI job it would end up in a
# file. --to-stdout is the deliberate exception (the tests use it).
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
# shellcheck source=scripts/operator-lock.sh
. "$ROOT/scripts/operator-lock.sh"
usage() {
  echo 'Usage: bash scripts/break-glass-admin.sh [--to-stdout] <the 10-digit mobile number of an active administrator, supervisor or staff member>' >&2
  echo 'Prints a one-time sign-in code for that worker, valid for 10 minutes. Use it only when the association sign-in and the SMS code cannot be used.' >&2
  echo 'It prints to a terminal only; --to-stdout lets it print into a pipe or a file on purpose.' >&2
  exit 2
}
to_stdout=false
if [[ "${1:-}" == --to-stdout ]]; then to_stdout=true; shift; fi
[[ $# -eq 1 ]] || usage
digits="${1//[^0-9]/}"
if [[ "$digits" =~ ^91[0-9]{10}$ ]]; then digits="${digits:2}"; fi
[[ "$digits" =~ ^[0-9]{10}$ ]] || { echo "Not a 10-digit mobile number: the number must have 10 digits (a leading 91 or +91 is allowed)." >&2; exit 2; }
if [[ "$to_stdout" != true && ! -t 1 ]]; then
  echo 'Not making a code: standard output is not a terminal, so the code would be written to a file, a log or a pipe.' >&2
  echo 'Run the command in a terminal session and read the code from the screen. To send it somewhere on purpose, put --to-stdout before the number.' >&2
  exit 2
fi
state="$(operator_state)"
operator_lock "$state"
errors="$(mktemp)"
trap 'rm -f "$errors"' EXIT
# The phone number goes in as a psql variable, quoted by psql; the code is read from the one result line and is written nowhere else.
if ! line="$(compose exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -v "phone=$digits" -U supabase_admin -d postgres 2>"$errors" <<'SQL'
SELECT r->>'code' || E'\t' || regexp_replace(r->>'name', E'[\t\r\n]+', ' ', 'g') || E'\t' || (r->>'role')
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
rest="${line#*$'\t'}"
# The name comes first and the role last (the name holds no tab: the query turns tabs into spaces).
name="${rest%$'\t'*}"
role="${rest##*$'\t'}"
if [[ "$rest" != *$'\t'* ]]; then name="$rest"; role=''; fi
case "$role" in
  admin) role='administrator' ;;
  supervisor|staff) ;;
  *) role='facility worker' ;;
esac
if [[ ! "$code" =~ ^[0-9]{6}$ ]]; then
  echo 'The database answered with something unexpected; no code is shown. Check the database log.' >&2
  exit 1
fi
cat <<EOF

  Break-glass code for $name, $role ($digits):

      $code

This code signs in $name on any phone within 10 minutes; use it only when the association sign-in and SMS cannot be used.
It works once, and the session it opens lasts 24 hours. Give it only to $name, in person or by a call you trust, never in a chat group.

On the phone: open the app and, on the "Sign in" screen, tap "Sign in with a code from your facility". Choose this facility, enter
the number $digits and type the code above. (An older app build: enter the number, ask for the SMS code, and type this one instead;
an administrator's code works there too.)
If the app answers "Invalid facility code" or "Too many wrong tries", or the code is not used in 10 minutes, run this command again for a new one.
Afterwards the sign-in is in the audit trail: see "Break-glass administrator sign-in" in docs/OPERATOR_INSTALL.md.

EOF

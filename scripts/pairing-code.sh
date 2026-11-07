#!/usr/bin/env bash
# A pairing code for a person of a LOCAL-ONLY facility (WH-146; docs/OPERATOR_INSTALL.md, "Local-only facility"). It replaces the SMS code:
# the first administrator gets theirs here, every other person from an administrator in the app (Users, the person, Make sign-in code).
#
#   bash scripts/pairing-code.sh [--to-stdout] <the person's 10-digit mobile number>
#
# Asks the database (warehouse_security.make_pairing_code_for_phone, supabase_admin only, migration 170) for a code of an existing, active,
# approved person: a code and a secret, valid for 10 minutes, usable once. Prints the QR code and nothing else that could be typed: pairing is
# by QR only, so the code and the secret are never shown as text. `qrencode` must be installed (sudo apt install qrencode); without it the
# command stops BEFORE a code is made. Making the code and # using it are recorded in public.audit_log. The command takes the operator lock. It prints to a terminal only (--to-stdout is the
# deliberate exception), as break-glass-admin.sh does.
# The QR text is {"v":1,"addr":"http://<address>:<port>","instance_id":"<uuid>","code":"XXXXXXXX","secret":"<64 hex>"} (docs/API_CONTRACT.md).
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
# shellcheck source=scripts/operator-lock.sh
. "$ROOT/scripts/operator-lock.sh"
usage() {
  echo 'Usage: bash scripts/pairing-code.sh [--to-stdout] <the 10-digit mobile number of an existing, active person of this local-only facility>' >&2
  echo 'Prints a one-time pairing QR code, valid for 10 minutes. It prints to a terminal only; --to-stdout lets it print into a pipe on purpose.' >&2
  exit 2
}
to_stdout=false
if [[ "${1:-}" == --to-stdout ]]; then to_stdout=true; shift; fi
[[ $# -eq 1 ]] || usage
digits="${1//[^0-9]/}"
if [[ "$digits" =~ ^91[0-9]{10}$ ]]; then digits="${digits:2}"; fi
[[ "$digits" =~ ^[0-9]{10}$ ]] || { echo 'Not a 10-digit mobile number (a leading 91 or +91 is allowed).' >&2; exit 2; }
if [[ "$to_stdout" != true && ! -t 1 ]]; then
  echo 'Not making a code: standard output is not a terminal, so the code would be written to a file, a log or a pipe.' >&2
  echo 'Run the command in a terminal session. To send it somewhere on purpose, put --to-stdout before the number.' >&2
  exit 2
fi
state="$(operator_state)"
operator_lock "$state"
env_file="$state/config/compose.env"
[[ "$(sed -n 's/^INGRESS=//p' "$env_file" | head -n 1)" == local-only ]] || { echo 'This facility is not local-only: it signs in with SMS codes or the association sign-in, not pairing codes.' >&2; exit 1; }
lan_ip="$(sed -n 's/^LAN_BIND_IP=//p' "$env_file" | head -n 1)"
lan_port="$(sed -n 's/^LAN_HTTP_PORT=//p' "$env_file" | head -n 1)"
[[ "$(sed -n 's/^LAN_ENABLED=//p' "$env_file" | head -n 1)" == true && -n "$lan_ip" && -n "$lan_port" ]] || { echo 'The warehouse network listener is off (bash scripts/lan.sh on auto).' >&2; exit 1; }
command -v qrencode >/dev/null || { echo 'qrencode is not installed, and pairing is by QR code only (there is no code to type). Install it: sudo apt install qrencode. No code was made.' >&2; exit 1; }
errors="$(mktemp)"
trap 'rm -f "$errors"' EXIT
if ! line="$(compose exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -v "phone=$digits" -U supabase_admin -d postgres 2>"$errors" <<'SQL'
SELECT r->>'code' || E'\t' || (r->>'secret') || E'\t' || regexp_replace(r#>>'{user,name}', E'[\t\r\n]+', ' ', 'g') || E'\t' || (r#>>'{user,role}')
FROM (SELECT warehouse_security.make_pairing_code_for_phone(:'phone') AS r) q;
SQL
)"; then
  reason="$(sed -n 's/^ERROR:  //p' "$errors" | head -n 1)"
  if [[ -n "$reason" ]]; then echo "Refused: $reason." >&2; else echo 'The database did not answer; no code was made:' >&2; head -n 5 "$errors" >&2; fi
  exit 1
fi
IFS=$'\t' read -r code secret name role <<< "$line"
if [[ ! "$code" =~ ^[2-9A-HJKMNP-TV-Z]{8}$ || ! "$secret" =~ ^[0-9a-f]{64}$ ]]; then
  echo 'The database answered with something unexpected; no code is shown. Check the database log.' >&2
  exit 1
fi
instance_id="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).instanceId)' "$state/public/instance.json")"
addr="http://$lan_ip:$lan_port"
payload="$(node -e 'console.log(JSON.stringify({ v: 1, addr: process.argv[1], instance_id: process.argv[2], code: process.argv[3], secret: process.argv[4] }))' "$addr" "$instance_id" "$code" "$secret")"
printf '\n  Pairing QR for %s (%s, %s), valid for 10 minutes, usable once:\n\n' "$name" "$role" "$digits"
printf '%s' "$payload" | qrencode -t ANSIUTF8
cat <<EOF

On the phone: open the app, tap "Scan facility code" and scan this QR. The facility address in it is $addr.
Show it only to $name, in person. If the app says the code was used or has expired, run this command again for a new one.

EOF

#!/usr/bin/env bash
# Two-session proofs that a payment written at the moment an invoice is cancelled can not land on the cancelled invoice (WH-99,
# migration 172 section 3: the payment trigger locks the invoice row whatever its state). Runs only against migrations.sh's
# disposable container, after tests/numbering_lock.sh (its administrator session 919888888899, its customer and its receipt ZZ-1).
#   1. A cancel is in flight (its transaction is held open): a payment inserted meanwhile waits, and once the cancel commits it is
#      refused (WH409, "is cancelled") and no payment is stored.
#   2. A payment is in flight (held open): a cancel started meanwhile waits and, once the payment commits, answers
#      INVOICE_HAS_PAYMENTS; the invoice stays live.
#   3. The same, with the payment rolled back: the cancel then succeeds.
# After each step no payment may belong to a cancelled invoice.
set -euo pipefail
container="${1:?disposable test container name required}"
export PGPASSWORD=disposable-test-database-only
psql_exec() { docker exec -i -e PGPASSWORD "$container" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 "$@"; }

claims=$(psql_exec -At <<'SQL'
SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',s.id)::text
FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id=p.auth_user_id
WHERE p.mobile='919888888899' AND s.expires_at>now() ORDER BY s.created_at DESC LIMIT 1;
SQL
)
[[ -n "$claims" ]] || { echo 'The payment race test needs the configuration admin session.' >&2; exit 1; }
customer=$(psql_exec -At -c "SELECT id FROM public.customers WHERE name = 'Numbering Lock Customer'")
grn=$(psql_exec -At -c "SELECT id FROM public.goodsreceived WHERE gr_no = 'ZZ-1'")
[[ "$customer" =~ ^[0-9a-f-]{36}$ && "$grn" =~ ^[0-9a-f-]{36}$ ]] || { echo 'The payment race test needs the numbering lock fixture.' >&2; exit 1; }
gate=public.payment_race_gate
scratch=$(mktemp -d "${TMPDIR:-/tmp}/payment-race.XXXXXX")
open_gate() { psql_exec -At -c "INSERT INTO $gate VALUES (true)" >/dev/null; }
cleanup() {
  open_gate 2>/dev/null || true
  wait 2>/dev/null || true
  psql_exec -At -c "DROP TABLE IF EXISTS $gate" >/dev/null 2>&1 || true
  rm -rf "$scratch"
}
trap cleanup EXIT
psql_exec -At >/dev/null <<SQL
DROP TABLE IF EXISTS $gate;
CREATE TABLE $gate (open boolean);
SQL
# The SQL that holds a transaction open until this script opens the gate (it gives up after 30 seconds).
wait_for_gate_sql() {
  cat <<SQL
DO \$\$
BEGIN
  FOR i IN 1..300 LOOP
    IF EXISTS (SELECT 1 FROM $gate) THEN RETURN; END IF;
    PERFORM pg_sleep(0.1);
  END LOOP;
  RAISE EXCEPTION 'The payment race test did not open the gate within 30 seconds.';
END \$\$;
SQL
}
# A fresh live invoice (a row of its own per step), and the SQL of one payment on it.
new_invoice() { # number
  psql_exec -At -c "INSERT INTO public.invoice (inv_no, inv_fin_year, customer_id, customer_name, inv_date, gr_id, gr_no, total)
    VALUES ($1, 2026, '$customer', 'Numbering Lock Customer', '2026-05-02', '$grn', 'ZZ-1', 100) RETURNING id"
}
payment_sql() { # payment number, invoice id
  echo "INSERT INTO public.payments (payment_no, payment_date, customer_id, customer_name, amount, invoice_id, payment_mode) VALUES ('$1', now(), '$customer', 'Numbering Lock Customer', 10, '$2', 'cash');"
}
cancel_sql() { # invoice id
  echo "SELECT set_config('request.jwt.claims', :'claims', true); SET LOCAL ROLE authenticated; SELECT public.cancel_invoice('$1'::uuid, 'Payment race test', NULL)->>'reason'; RESET ROLE;"
}
# poll_lock_wait PATTERN WHAT: waits until a session whose statement matches PATTERN waits for a lock.
poll_lock_wait() {
  local i
  for ((i=0; i<150; i++)); do
    [[ "$(psql_exec -At -c "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND query ILIKE '%$1%'")" -ge 1 ]] && return 0
    sleep 0.2
  done
  echo "Expected $2 to wait for a lock." >&2; exit 1
}
poll_lock_wait_for_holder() { # waits until the holder's statement has run (its work is done, only the gate is left)
  local i
  for ((i=0; i<150; i++)); do
    [[ "$(psql_exec -At -c "SELECT count(*) FROM pg_stat_activity WHERE state = 'active' AND query ILIKE '%payment_race_gate%'")" -ge 1 ]] && return 0
    sleep 0.2
  done
  echo "Expected $1 to reach the gate." >&2; exit 1
}
none_on_cancelled() {
  [[ "$(psql_exec -At -c "SELECT count(*) FROM public.payments p JOIN public.invoice i ON i.id = p.invoice_id WHERE i.cancelled_at IS NOT NULL")" == 0 ]] \
    || { echo "A payment belongs to a cancelled invoice after: $1" >&2; exit 1; }
}

# 1. The cancel is in flight; the payment waits and is refused.
inv=$(new_invoice 990001)
psql_exec -At >/dev/null -v claims="$claims" < <(echo 'BEGIN;'; cancel_sql "$inv"; wait_for_gate_sql; echo 'COMMIT;') &
holder=$!
poll_lock_wait_for_holder 'the cancel'
set +e
payment_sql WH99-1 "$inv" | psql_exec -At > "$scratch/one" 2>&1 &
payer=$!
set -e
poll_lock_wait 'payments' 'the payment'
open_gate
wait "$holder"
set +e; wait "$payer"; payer_status=$?; set -e
[[ "$payer_status" != 0 ]] && grep -q 'is cancelled' "$scratch/one" \
  || { echo "A payment during a cancel was not refused as cancelled: $(cat "$scratch/one")" >&2; exit 1; }
[[ "$(psql_exec -At -c "SELECT cancelled_at IS NOT NULL FROM public.invoice WHERE id = '$inv'")" == t ]] || { echo 'The cancel did not commit.' >&2; exit 1; }
none_on_cancelled 'a payment during a cancel'
echo 'A payment written while a cancel was in flight waited and was refused; no payment is on the cancelled invoice.'

# 2. The payment is in flight (committed at the end); the cancel waits and is refused.
psql_exec -At -c "DELETE FROM $gate" >/dev/null
inv=$(new_invoice 990002)
psql_exec -At >/dev/null < <(echo 'BEGIN;'; payment_sql WH99-2 "$inv"; wait_for_gate_sql; echo 'COMMIT;') &
holder=$!
poll_lock_wait_for_holder 'the payment'
psql_exec -At -v claims="$claims" < <(echo 'BEGIN;'; cancel_sql "$inv"; echo 'COMMIT;') > "$scratch/two" &
canceller=$!
poll_lock_wait 'cancel_invoice' 'the cancel'
open_gate
wait "$holder"; wait "$canceller"
grep -q 'INVOICE_HAS_PAYMENTS' "$scratch/two" || { echo "A cancel during a payment was not refused: $(cat "$scratch/two")" >&2; exit 1; }
[[ "$(psql_exec -At -c "SELECT cancelled_at IS NULL FROM public.invoice WHERE id = '$inv'")" == t ]] || { echo 'The invoice was cancelled under its payment.' >&2; exit 1; }
none_on_cancelled 'a cancel during a payment'
echo 'A cancel started while a payment was in flight waited and answered INVOICE_HAS_PAYMENTS; the invoice stays live.'

# 3. The payment is rolled back; the cancel then succeeds.
psql_exec -At -c "DELETE FROM $gate" >/dev/null
inv=$(new_invoice 990003)
psql_exec -At >/dev/null < <(echo 'BEGIN;'; payment_sql WH99-3 "$inv"; wait_for_gate_sql; echo 'ROLLBACK;') &
holder=$!
poll_lock_wait_for_holder 'the payment'
psql_exec -At -v claims="$claims" < <(echo 'BEGIN;'; cancel_sql "$inv"; echo 'COMMIT;') > "$scratch/three" &
canceller=$!
poll_lock_wait 'cancel_invoice' 'the cancel'
open_gate
wait "$holder"; wait "$canceller"
[[ "$(psql_exec -At -c "SELECT cancelled_at IS NOT NULL FROM public.invoice WHERE id = '$inv'")" == t ]] \
  || { echo "The cancel did not succeed after the payment was rolled back: $(cat "$scratch/three")" >&2; exit 1; }
none_on_cancelled 'a rolled back payment'
echo 'With the payment rolled back the cancel succeeded.'

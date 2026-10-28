#!/usr/bin/env bash
# Two-session proofs that a numbering rule change shares the document lock (71040) with every save (migration 127). Runs only against
# migrations.sh's disposable container, after the configuration block seeded admin 919888888899 with a live operator session.
#   1. A rule change waits for a save that is in flight (here: a session that holds the lock), and then takes effect.
#   2. A save that starts while a rule is being changed waits for the change and is judged by the new rule, never by the old one
#      and never by half of the change: GRN ZZ-1 is refused by the letter rule, and accepted when the change to free text commits first.
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
[[ -n "$claims" ]] || { echo 'The numbering lock test needs the configuration admin session.' >&2; exit 1; }
psql_exec -At >/dev/null <<'SQL'
INSERT INTO public.customers(name,mobile) VALUES ('Numbering Lock Customer','9888888897') ON CONFLICT DO NOTHING;
INSERT INTO public.items(name,packaging) VALUES ('Numbering Lock Potatoes','Bag') ON CONFLICT DO NOTHING;
SELECT warehouse_security.apply_document_numbering('grn', '{"scheme":"free"}', NULL) AS _ \gset
SQL
gate=public.numbering_lock_gate
# The holders keep the document lock until this script opens the gate (a row in $gate), and give up after 30 seconds, so nothing here
# depends on how long a step takes: every wait below polls for the state it needs.
psql_exec -At >/dev/null <<SQL
DROP TABLE IF EXISTS $gate;
CREATE TABLE $gate (open boolean);
SQL
open_gate() { psql_exec -At -c "INSERT INTO $gate VALUES (true)" >/dev/null; }
close_gate() { psql_exec -At -c "DELETE FROM $gate" >/dev/null; }
# The SQL that waits for the gate inside the holder's transaction.
wait_for_gate_sql() {
  cat <<SQL
DO \$\$
BEGIN
  FOR i IN 1..300 LOOP
    IF EXISTS (SELECT 1 FROM $gate) THEN RETURN; END IF;
    PERFORM pg_sleep(0.1);
  END LOOP;
  RAISE EXCEPTION 'The numbering lock test did not open the gate within 30 seconds.';
END \$\$;
SQL
}
waiting() { psql_exec -At -c "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND objid = 71040 AND NOT granted"; }
granted() { psql_exec -At -c "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND objid = 71040 AND granted"; }
# poll COMMAND EXPECTED WHAT: runs COMMAND until it prints EXPECTED; fails after 30 seconds, or when the background job (pid $4) has ended.
poll() {
  local i
  for ((i=0; i<150; i++)); do
    [[ "$("$1")" == "$2" ]] && return 0
    if [[ -n "${4:-}" ]] && ! kill -0 "$4" 2>/dev/null; then break; fi
    sleep 0.2
  done
  echo "Expected $2 for $3, found $("$1")." >&2; exit 1
}
cleanup() {
  open_gate 2>/dev/null || true
  wait 2>/dev/null || true
  psql_exec -At -c "DROP TABLE IF EXISTS $gate" >/dev/null 2>&1 || true
  rm -f "${change:-}"
}
change=$(mktemp "${TMPDIR:-/tmp}/numbering-lock.XXXXXX"); trap cleanup EXIT
save_zz() {
  psql_exec -At -v claims="$claims" <<'SQL'
SELECT set_config('request.jwt.claims',:'claims',false) AS _ \gset
SET ROLE authenticated;
SELECT public.save_grn(p_gr_no=>'ZZ-1',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>(SELECT id FROM public.customers WHERE name='Numbering Lock Customer'),
  p_customer_name=>'Numbering Lock Customer',p_items=>jsonb_build_array(jsonb_build_object(
  'item_id',(SELECT id FROM public.items WHERE name='Numbering Lock Potatoes'),'item_name','Numbering Lock Potatoes','packaging','Bag','qty',10,'weight',5)))->>'reason';
SQL
}

# 1. A save holds the lock; the rule change waits for it.
close_gate
{ echo 'BEGIN;'; echo 'SELECT pg_advisory_xact_lock(71040);'; wait_for_gate_sql; echo 'COMMIT;'; } | psql_exec -At >/dev/null &
holder=$!
poll granted 1 'the save to hold the document lock' "$holder"
psql_exec -At -c "SELECT warehouse_security.apply_document_numbering('grn', '{\"scheme\":\"letters\"}', NULL)->>'changed'" > "$change" &
changer=$!
poll waiting 1 'the rule change to wait for the document lock' "$changer"
[[ ! -s "$change" ]] || { echo 'The rule change did not wait for the save that held the document lock.' >&2; exit 1; }
open_gate
wait "$holder"; wait "$changer"
[[ "$(cat "$change")" == true ]] || { echo "The rule change did not take effect after the save: $(cat "$change")" >&2; exit 1; }
echo 'A rule change waited for the save in flight and then took effect.'

# 2. The rule is being changed (free text, held until the gate opens); a save of ZZ-1 started meanwhile waits and is judged by the new rule.
close_gate
{ echo 'BEGIN;'; echo "SELECT warehouse_security.apply_document_numbering('grn', '{\"scheme\":\"free\"}', NULL);"; wait_for_gate_sql; echo 'COMMIT;'; } | psql_exec -At >/dev/null &
holder=$!
poll granted 1 'the rule change to hold the document lock' "$holder"
save_zz > "$change" &
saver=$!
poll waiting 1 'the save to wait for the rule change' "$saver"
[[ ! -s "$change" ]] || { echo 'The save did not wait for the rule change.' >&2; exit 1; }
open_gate
wait "$holder"; wait "$saver"
[[ "$(psql_exec -At -c "SELECT count(*) FROM public.goodsreceived WHERE gr_no = 'ZZ-1'")" == 1 && "$(tr -d '\n' < "$change")" == "" ]] \
  || { echo "A save that started during a rule change was not judged by the new rule: $(cat "$change")" >&2; exit 1; }
echo 'A save that started during a rule change waited for it and was judged by the new rule.'
# The rule is left as free text, as the earlier suites expect.

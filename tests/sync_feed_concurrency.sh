#!/usr/bin/env bash
# WH-297, criterion 1 with real concurrent sessions (contract ~/ws/fresh/product/tech/server-change-log-feed.md, cases 1a, 1b, 1f).
# Runs only against migrations.sh's disposable container, in the sync feed database that tests/sync_feed_changes.sql and
# tests/sync_feed_deletes_scope.sql used before it. Every session starts with tests/sync_feed_contract.sql (its marked block holds
# every feed name; this script adds none).
#   1b. A transaction held open (a customer row changed, then waiting on a gate) while another session commits a GRN: while it is
#       open, nothing after it is delivered and as_of stays at its start; once it commits, both arrive and the copy equals a fresh load.
#   1a, 1f. Four sessions save GRNs, edit one GRN again and again ("Edit GRN") and dispatch from one lot, while a phone stand-in
#       first loads during the saves and then polls; after the writers end, one more pull and the copy equals a fresh load.
# Usage: bash tests/sync_feed_concurrency.sh <container> <database> <tests/sync_feed_contract.sql>
set -euo pipefail
container="${1:?disposable test container name required}"
db="${2:?sync feed database name required}"
contract="${3:?path of tests/sync_feed_contract.sql required}"
export PGPASSWORD=disposable-test-database-only
psql_db() { docker exec -i -e PGPASSWORD "$container" psql -X -q -U supabase_admin -d "$db" -v ON_ERROR_STOP=1 "$@"; }
# A session: the contract (helpers only, the setup already ran) followed by the SQL on stdin.
session() { { cat "$contract"; cat; } | psql_db -v sf_no_setup=1 "$@"; }
gate=public.sync_feed_gate
scratch=$(mktemp -d "${TMPDIR:-/tmp}/sync-feed.XXXXXX")
pids=()
cleanup() {
  psql_db -At -c "INSERT INTO $gate VALUES ('release'), ('writers_done') ON CONFLICT DO NOTHING" >/dev/null 2>&1 || true
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  psql_db -At -c "DROP TABLE IF EXISTS $gate" >/dev/null 2>&1 || true
  rm -rf "$scratch"
}
trap cleanup EXIT
# The SQL that waits (at most 60 s) for a gate row.
wait_gate_sql() {
  cat <<SQL
DO \$\$
BEGIN
  FOR i IN 1..600 LOOP
    IF EXISTS (SELECT 1 FROM $gate WHERE name = '$1') THEN RETURN; END IF;
    PERFORM pg_sleep(0.1);
  END LOOP;
  RAISE EXCEPTION 'sync feed concurrency: the gate $1 was not opened within 60 seconds';
END \$\$;
SQL
}

# Fixture (one session, committed): the gate, a customer for the held transaction, a customer and item for the saves, a GRN to edit,
# a GRN to dispatch from, and a staff member.
{ cat "$contract"; cat <<SQL; } | psql_db >/dev/null
DROP TABLE IF EXISTS $gate;
CREATE TABLE $gate (name text PRIMARY KEY);
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status)
  VALUES (gen_random_uuid(), '919888897202', 'Sync Race Staff', 'staff', true, 'approved');
SELECT pg_temp.sf_login('9888897202');
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_customer(''Sync Race North'', ''9888897221'')')->>'success' = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_customer(''Sync Race Hold'', ''9888897222'')')->>'success' = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_item(''Sync Race Potatoes'', ''Bag'')')->>'success' = 'true', 'race fixture');
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'SRE0', (SELECT id FROM public.customers WHERE name = 'Sync Race North'),
  pg_temp.sf_lines((SELECT id FROM public.items WHERE name = 'Sync Race Potatoes'), 3, 'E'));
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'SRD0', (SELECT id FROM public.customers WHERE name = 'Sync Race North'),
  pg_temp.sf_lines((SELECT id FROM public.items WHERE name = 'Sync Race Potatoes'), 1, 'D', 1000));
SQL

# ---------------------------------------------------------------------------------------------------------------------------------
# 1b. The long transaction.
# ---------------------------------------------------------------------------------------------------------------------------------
{ echo "SET application_name = 'sync_feed_holder';"; echo 'BEGIN;'
  echo "UPDATE public.customers SET city = 'Holdtown' WHERE name = 'Sync Race Hold';"
  wait_gate_sql release; echo 'COMMIT;'; } | session -At >"$scratch/holder" 2>&1 &
holder=$!; pids+=("$holder")
session -At <<SQL || { cat "$scratch/holder" >&2; echo 'The long-transaction check failed.' >&2; exit 1; }
SELECT pg_temp.sf_phone('obs', :'sf_admin_claims'::jsonb);
SELECT pg_temp.sf_first_load('obs');
DO \$\$
BEGIN
  FOR i IN 1..300 LOOP
    PERFORM pg_stat_clear_snapshot();
    IF EXISTS (SELECT 1 FROM pg_stat_activity WHERE application_name = 'sync_feed_holder' AND backend_xid IS NOT NULL AND query LIKE '%$gate%') THEN RETURN; END IF;
    PERFORM pg_sleep(0.1);
  END LOOP;
  RAISE EXCEPTION 'sync feed concurrency: the held transaction never reached its gate';
END \$\$;
SELECT xact_start AS holder_start FROM pg_stat_activity WHERE application_name = 'sync_feed_holder' \gset
SELECT id AS hold_customer FROM public.customers WHERE name = 'Sync Race Hold' \gset
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'SRL2', (SELECT id FROM public.customers WHERE name = 'Sync Race North'),
  pg_temp.sf_lines((SELECT id FROM public.items WHERE name = 'Sync Race Potatoes'), 2, 'L')) AS grn_l2 \gset
SELECT pg_temp.sf_pull('obs');
SELECT pg_temp.sf_assert(NOT (:'grn_l2' = ANY (pg_temp.sf_held('obs', 'goodsreceived'))),
  '1b: a GRN committed after the open transaction began is not delivered while it is open (contract 7)');
SELECT pg_temp.sf_assert((SELECT abs(extract(epoch FROM as_of::timestamptz - :'holder_start'::timestamptz)) < 0.5 FROM pg_temp.sf_device WHERE phone = 'obs'),
  '1b: as_of stays at the start of the open transaction: ' || (SELECT as_of FROM pg_temp.sf_device WHERE phone = 'obs') || ' vs ' || :'holder_start');
INSERT INTO $gate VALUES ('release');
DO \$\$
BEGIN
  FOR i IN 1..300 LOOP
    PERFORM pg_stat_clear_snapshot();
    IF NOT EXISTS (SELECT 1 FROM pg_stat_activity WHERE application_name = 'sync_feed_holder' AND backend_xid IS NOT NULL) THEN RETURN; END IF;
    PERFORM pg_sleep(0.1);
  END LOOP;
  RAISE EXCEPTION 'sync feed concurrency: the held transaction did not end';
END \$\$;
SELECT pg_temp.sf_assert((SELECT city FROM public.customers WHERE name = 'Sync Race Hold') = 'Holdtown', 'premise: the held transaction committed');
SELECT pg_temp.sf_pull('obs');
SELECT pg_temp.sf_assert(:'grn_l2' = ANY (pg_temp.sf_held('obs', 'goodsreceived'))
  AND (SELECT row->>'city' FROM pg_temp.sf_copy WHERE slot = 'obs' AND e = 'customers' AND id = :'hold_customer') = 'Holdtown',
  '1b: once it committed, its change and the later GRN both arrived');
SELECT pg_temp.sf_assert(pg_temp.sf_diff('obs') = '', '1b: the copy equals a fresh load: ' || pg_temp.sf_diff('obs'));
SELECT pg_temp.sf_assert((SELECT as_of::timestamptz > :'holder_start'::timestamptz FROM pg_temp.sf_device WHERE phone = 'obs'), '1b: as_of moved on after the commit');
SQL
wait "$holder" || { cat "$scratch/holder" >&2; echo 'The held transaction failed.' >&2; exit 1; }
echo 'Sync feed: a long transaction delays the feed and loses nothing (1b).'

# ---------------------------------------------------------------------------------------------------------------------------------
# 1a, 1f. Four writers and a polling phone.
# ---------------------------------------------------------------------------------------------------------------------------------
rounds=20
writer() { # name, SQL of one round (with ROUND in place of the round number)
  local name="$1" round_sql="$2" i
  { echo "SELECT id AS north FROM public.customers WHERE name = 'Sync Race North' \\gset"
    echo "SELECT id AS potatoes FROM public.items WHERE name = 'Sync Race Potatoes' \\gset"
    echo "SELECT pg_temp.sf_login('9888897202') AS staff_claims \\gset"
    for ((i=1; i<=rounds; i++)); do echo "${round_sql//ROUND/$i}"; echo 'SELECT pg_sleep(0.05);'; done
  } | session -At >"$scratch/$name" 2>&1
}
writer w1 "SELECT pg_temp.sf_save_grn(:'staff_claims'::jsonb, 'SRW1-ROUND', :'north'::uuid, pg_temp.sf_lines(:'potatoes'::uuid, 2, 'A'));" & pids+=($!); w1=$!
writer w2 "SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'SRW2-ROUND', :'north'::uuid, pg_temp.sf_lines(:'potatoes'::uuid, 3, 'B'));" & pids+=($!); w2=$!
writer w3 "SELECT pg_temp.sf_update_grn(:'sf_admin_claims'::jsonb, (SELECT id FROM public.goodsreceived WHERE gr_no = 'SRE0'), (SELECT jsonb_agg(l || jsonb_build_object('rack', 'E' || ROUND)) FROM jsonb_array_elements(pg_temp.sf_current_lines((SELECT id FROM public.goodsreceived WHERE gr_no = 'SRE0'))) l));" & pids+=($!); w3=$!
writer w4 "SELECT pg_temp.sf_dispatch(:'staff_claims'::jsonb, 'SRX-ROUND', (SELECT t.id FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id = t.gr_id WHERE g.gr_no = 'SRD0'), 1);" & pids+=($!); w4=$!
sleep 1
{ echo "SELECT pg_temp.sf_phone('poll', :'sf_admin_claims'::jsonb);"
  echo "SELECT pg_temp.sf_first_load('poll');"
  echo "SELECT 'SELECT pg_temp.sf_pull(''poll''); SELECT pg_sleep(0.1);' FROM generate_series(1, 60) \\gexec"
  wait_gate_sql writers_done
  cat <<SQL
SELECT pg_temp.sf_pull('poll');
SELECT pg_temp.sf_assert(pg_temp.sf_diff('poll') = '', '1a: after concurrent saves, edits and dispatches the copy equals a fresh load: ' || pg_temp.sf_diff('poll'));
SELECT pg_temp.sf_assert((SELECT count(*) FROM pg_temp.sf_copy WHERE slot = 'poll' AND e = 'goodsreceived' AND row->>'gr_no' LIKE 'SRW_-%') = 2 * $rounds,
  '1a: every GRN the writers saved is in the copy');
SELECT pg_temp.sf_assert((SELECT bool_and(row->>'rack' = 'E$rounds') FROM pg_temp.sf_copy c JOIN public.goodsreceived g ON g.gr_no = 'SRE0'
    WHERE c.slot = 'poll' AND c.e = 'goodsreceived_trl' AND c.row->>'gr_id' = g.id::text), '1a: the copy has the last rack of every edited lot');
SELECT pg_temp.sf_assert((SELECT (c.row->>'stock')::int FROM pg_temp.sf_copy c JOIN public.goodsreceived g ON g.gr_no = 'SRD0'
    WHERE c.slot = 'poll' AND c.e = 'goodsreceived_trl' AND c.row->>'gr_id' = g.id::text) = 1000 - $rounds, '1a: the copy has the stock after every dispatch');
SQL
} | session -At >"$scratch/poller" 2>&1 &
poller=$!; pids+=("$poller")
for name in w1 w2 w3 w4; do
  pid=${!name}
  wait "$pid" || { cat "$scratch/$name" >&2; echo "Writer $name failed." >&2; exit 1; }
done
psql_db -At -c "INSERT INTO $gate VALUES ('writers_done')" >/dev/null
wait "$poller" || { cat "$scratch/poller" >&2; echo 'The polling phone found a missed change.' >&2; exit 1; }
echo "Sync feed: $((4 * rounds)) concurrent saves, edits and dispatches, first load during them, nothing missed (1a, 1f)."

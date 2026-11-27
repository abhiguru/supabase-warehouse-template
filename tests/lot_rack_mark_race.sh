#!/usr/bin/env bash
# Two-session proof for WH-302 B12: two set_lot_rack_and_mark calls on one lot at the same moment both succeed in some order, the later
# one's value is stored, and at most one of them names a replaced value. Contract ~/ws/fresh/product/tech/app-offline-quick-change.md,
# section 2.1 ("lot and its GRN locked FOR UPDATE") and section 6 B12. Runs only against migrations.sh's disposable container, after
# tests/numbering_lock.sh (its administrator session 919888888899 and its GRN ZZ-1 with one lot).
#   1. Call A is in flight (its transaction is held open after the call): call B, sent meanwhile, waits for the lock.
#   2. A commits: B then runs, both answers are successes, the stored rack is B's, A replaced nothing, B (which saw the rack as it was
#      before A) names A's value as replaced exactly once, and the GRN's change mark is B's.
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
[[ -n "$claims" ]] || { echo 'The lot change race test needs the configuration admin session.' >&2; exit 1; }
lot=$(psql_exec -At -c "SELECT t.id FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id = t.gr_id WHERE g.gr_no = 'ZZ-1' ORDER BY t.id LIMIT 1")
[[ "$lot" =~ ^[0-9a-f-]{36}$ ]] || { echo 'The lot change race test needs the numbering lock fixture (GRN ZZ-1).' >&2; exit 1; }
gate=public.lot_change_race_gate
scratch=$(mktemp -d "${TMPDIR:-/tmp}/lot-change-race.XXXXXX")
tag=$(openssl rand -hex 4)
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
wait_for_gate_sql() {
  cat <<SQL
DO \$\$
BEGIN
  FOR i IN 1..300 LOOP
    IF EXISTS (SELECT 1 FROM $gate) THEN RETURN; END IF;
    PERFORM pg_sleep(0.1);
  END LOOP;
  RAISE EXCEPTION 'The lot change race test did not open the gate within 30 seconds.';
END \$\$;
SQL
}
call_sql() { # new rack, rack the phone saw, request key
  echo "SELECT set_config('request.jwt.claims', :'claims', true); SET LOCAL ROLE authenticated; SELECT public.set_lot_rack_and_mark('$lot'::uuid, '{\"rack\":{\"to\":\"$1\",\"from\":$2}}'::jsonb, '$3'); RESET ROLE;"
}
poll() { # SQL that answers t when the wait is over, what it is
  local i
  for ((i=0; i<150; i++)); do
    [[ "$(psql_exec -At -c "$1")" == t ]] && return 0
    sleep 0.2
  done
  echo "Expected $2." >&2; exit 1
}

# The rack both phones saw: a known value, set by a call of its own.
base="BASE-$tag"
psql_exec -At -v claims="$claims" < <(echo 'BEGIN;'; call_sql "$base" null "lot-race-base-$tag"; echo 'COMMIT;') >/dev/null

a_rack="RACE-A-$tag"; b_rack="RACE-B-$tag"
psql_exec -At -v claims="$claims" > "$scratch/a" < <(echo 'BEGIN;'; call_sql "$a_rack" "\"$base\"" "lot-race-a-$tag"; wait_for_gate_sql; echo 'COMMIT;') &
holder=$!
poll "SELECT count(*) >= 1 FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND state = 'active' AND query ILIKE '%lot_change_race_gate%'" 'call A to reach the gate with its transaction open'
psql_exec -At -v claims="$claims" > "$scratch/b" < <(echo 'BEGIN;'; call_sql "$b_rack" "\"$base\"" "lot-race-b-$tag"; echo 'COMMIT;') &
second=$!
poll "SELECT count(*) >= 1 FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND wait_event_type = 'Lock' AND query ILIKE '%set_lot_rack_and_mark%'" 'call B to wait for the lock held by call A'
[[ "$(psql_exec -At -c "SELECT rack FROM public.goodsreceived_trl WHERE id = '$lot'")" == "$base" ]] || { echo 'Call A is not committed yet, but the rack changed.' >&2; exit 1; }
open_gate
wait "$holder"; wait "$second"

ans_a=$(grep -h '"success"' "$scratch/a" | head -1)
ans_b=$(grep -h '"success"' "$scratch/b" | head -1)
[[ -n "$ans_a" && -n "$ans_b" ]] || { echo "A call gave no answer: A=$(cat "$scratch/a") B=$(cat "$scratch/b")" >&2; exit 1; }
check=$(psql_exec -At -v a="$ans_a" -v b="$ans_b" -v lot="$lot" -v ar="$a_rack" -v br="$b_rack" <<'SQL'
SELECT (:'a'::jsonb->>'success' = 'true' AND :'b'::jsonb->>'success' = 'true'
  AND (SELECT rack FROM public.goodsreceived_trl WHERE id = :'lot'::uuid) = :'br'
  AND jsonb_array_length(:'a'::jsonb->'replaced') = 0
  AND jsonb_array_length(:'b'::jsonb->'replaced') = 1
  AND :'b'::jsonb#>>'{replaced,0,field}' = 'rack' AND :'b'::jsonb#>>'{replaced,0,newer}' = :'ar' AND :'b'::jsonb#>>'{replaced,0,sent}' = :'br'
  AND date_trunc('milliseconds', (:'b'::jsonb#>>'{grn,updated_at}')::timestamptz) = (SELECT date_trunc('milliseconds', g.updated_at)
      FROM public.goodsreceived g JOIN public.goodsreceived_trl t ON t.gr_id = g.id WHERE t.id = :'lot'::uuid))::text;
SQL
)
[[ "$check" == true ]] || { echo "Two calls at once on one lot were not serialised as expected. A: $ans_a B: $ans_b" >&2; exit 1; }
echo 'Two calls on one lot at the same moment: both succeeded, the later one is stored, one replaced value is named, the change mark is the later one.'

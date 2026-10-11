#!/usr/bin/env bash
# Two-session proofs of the document lock order. Runs only against
# migrations.sh's disposable container, after the configuration block seeded
# admin 919888888899 with a live operator session. In each case both sessions
# must succeed and both changes must persist.
#   1. Migration 26: a GRN edit must not deadlock with a concurrent writer that
#      already holds the list-refresh lock (71040) and then touches
#      goodsreceived_trl.
#   2. Migration 46: a dispatch being created must not deadlock with a GRN edit
#      of the same lot. Creation used to lock the lot row and only then wait for
#      71040, while the edit holds 71040 and then writes the lot row.
#   3. Migration 46: the same for a dispatch edit that changes only its lines.
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
[[ -n "$claims" ]] || { echo 'Lock-order test needs the configuration admin session.' >&2; exit 1; }

grn_id=$(psql_exec -At -v claims="$claims" <<'SQL'
INSERT INTO public.customers(name,mobile) VALUES ('Lock Order Customer','9888888898') ON CONFLICT DO NOTHING;
INSERT INTO public.items(name,packaging) VALUES ('Lock Order Potatoes','Bag') ON CONFLICT DO NOTHING;
SELECT set_config('request.jwt.claims',:'claims',false);
SET ROLE authenticated;
SELECT (public.save_grn(p_gr_no=>'LOCKA',p_date=>now(),p_customer_id=>(SELECT id FROM public.customers WHERE name='Lock Order Customer'),
  p_customer_name=>'Lock Order Customer',p_items=>jsonb_build_array(jsonb_build_object(
  'item_id',(SELECT id FROM public.items WHERE name='Lock Order Potatoes'),'item_name','Lock Order Potatoes','packaging','Bag','qty',10,'weight',5)),
  p_idempotency_key=>'lock-order-receipt'))->>'success';
RESET ROLE;
SELECT id FROM public.goodsreceived WHERE gr_no='LOCKA';
SQL
)
grn_id=$(printf '%s\n' "$grn_id" | tail -n1)
[[ "$grn_id" =~ ^[0-9a-f-]{36}$ ]] || { echo "Lock-order fixture receipt failed: $grn_id" >&2; exit 1; }

# Session 1: hold 71040 first (as every normal writer's statement trigger does),
# then write the item table while the edit in session 2 is in flight.
psql_exec -v grn="$grn_id" <<'SQL' &
BEGIN;
SELECT pg_advisory_xact_lock(71040);
SELECT pg_sleep(4);
UPDATE public.goodsreceived_trl SET rack=rack WHERE gr_id=:'grn'::uuid;
COMMIT;
SQL
holder=$!
sleep 1

# Session 2: the GRN edit. Before migration 26 it took the item-table lock first
# and then waited for 71040, which deadlocked against session 1.
edit=$(psql_exec -At -v claims="$claims" -v grn="$grn_id" <<'SQL'
SELECT set_config('request.jwt.claims',:'claims',false);
SET ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn'::uuid,p_note=>'lock order')->>'success';
SQL
)
wait "$holder"
edit=$(printf '%s\n' "$edit" | tail -n1)
[[ "$edit" = true ]] || { echo "GRN edit under a concurrent writer did not succeed: $edit" >&2; exit 1; }
# psql substitutes :'var' only in input read from stdin or a file, never in -c.
stored=$(psql_exec -At -v grn="$grn_id" <<'SQL'
SELECT note='lock order' FROM public.goodsreceived WHERE id=:'grn'::uuid;
SQL
)
[[ "$stored" = t ]] || { echo 'GRN edit note was not stored after the concurrent writer committed.' >&2; exit 1; }
echo 'GRN edit lock-order check passed under a concurrent item-table writer.'

# Cases 2 and 3 use a second receipt: the edit above sent no lines, which
# removes the lines of a receipt that has no dispatch.
lot_id=$(psql_exec -At -v claims="$claims" <<'SQL'
SELECT set_config('request.jwt.claims',:'claims',false);
SET ROLE authenticated;
SELECT (public.save_grn(p_gr_no=>'LOCKB',p_date=>now(),p_customer_id=>(SELECT id FROM public.customers WHERE name='Lock Order Customer'),
  p_customer_name=>'Lock Order Customer',p_items=>jsonb_build_array(jsonb_build_object(
  'item_id',(SELECT id FROM public.items WHERE name='Lock Order Potatoes'),'item_name','Lock Order Potatoes','packaging','Bag','qty',10,'weight',5)),
  p_idempotency_key=>'lock-order-receipt-b'))->>'success';
RESET ROLE;
SELECT t.id FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='LOCKB';
SQL
)
lot_id=$(printf '%s\n' "$lot_id" | tail -n1)
[[ "$lot_id" =~ ^[0-9a-f-]{36}$ ]] || { echo "Lock-order fixture lot missing: $lot_id" >&2; exit 1; }
grn_id=$(psql_exec -At <<'SQL'
SELECT id FROM public.goodsreceived WHERE gr_no='LOCKB';
SQL
)

# Case 2, session 1: a real GRN edit of the lot. It holds 71040 from the start
# of its transaction (as update_grn itself does from its first write) and
# reaches the lot row only after session 2 is in flight.
psql_exec -At -v claims="$claims" -v grn="$grn_id" -v lot="$lot_id" > "${TMPDIR:-/tmp}/lock-order-edit.$$" <<'SQL' &
BEGIN;
SELECT pg_advisory_xact_lock(71040);
SELECT pg_sleep(4);
SELECT set_config('request.jwt.claims',:'claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn'::uuid,p_note=>'edited during a dispatch',p_items=>jsonb_build_array(jsonb_build_object(
  'id',:'lot','item_id',(SELECT id FROM public.items WHERE name='Lock Order Potatoes'),'item_name','Lock Order Potatoes',
  'packaging','Bag','qty',10,'weight',5,'rack','R9')))->>'success';
COMMIT;
SQL
holder=$!
sleep 1

# Case 2, session 2: the dispatch of two bags of that lot.
created=$(psql_exec -At -v claims="$claims" -v lot="$lot_id" <<'SQL'
SELECT set_config('request.jwt.claims',:'claims',false);
SET ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','LOCKD','disp_date','2026-05-02T12:00:00Z',
  'customer_id',(SELECT id FROM public.customers WHERE name='Lock Order Customer'),'customer_name','Lock Order Customer',
  'supervisor_id',(SELECT id FROM public.user_profiles WHERE mobile='919888888899'),'supervisor_name','Configuration Test'),
  ARRAY[jsonb_build_object('gr_trl_id',:'lot','disp_qty',2)],0,'lock-order-dispatch')::text;
SQL
)
wait "$holder" || { rm -f "${TMPDIR:-/tmp}/lock-order-edit.$$"; echo 'GRN edit failed while a dispatch of the same lot was being created.' >&2; exit 1; }
edit=$(tail -n1 "${TMPDIR:-/tmp}/lock-order-edit.$$"); rm -f "${TMPDIR:-/tmp}/lock-order-edit.$$"
created=$(printf '%s\n' "$created" | tail -n1)
[[ "$edit" = true ]] || { echo "GRN edit during a dispatch of the same lot did not succeed: $edit" >&2; exit 1; }
[[ "$created" == *'"success": true'* ]] || { echo "Dispatch during a GRN edit of the same lot did not succeed: $created" >&2; exit 1; }
stored=$(psql_exec -At -v lot="$lot_id" <<'SQL'
SELECT t.rack='R9' AND t.stock=8 AND (SELECT count(*)=1 FROM public.dispatch_trl d WHERE d.gr_trl_id=t.id AND d.disp_qty=2)
FROM public.goodsreceived_trl t WHERE t.id=:'lot'::uuid;
SQL
)
[[ "$stored" = t ]] || { echo 'The GRN edit and the dispatch of the same lot were not both stored.' >&2; exit 1; }
echo 'Dispatch creation lock-order check passed under a concurrent GRN edit of the same lot.'

# Case 3, session 1: holds 71040, then writes the lot row.
psql_exec -v grn="$grn_id" <<'SQL' &
BEGIN;
SELECT pg_advisory_xact_lock(71040);
SELECT pg_sleep(4);
UPDATE public.goodsreceived_trl SET rack='R10' WHERE gr_id=:'grn'::uuid;
COMMIT;
SQL
holder=$!
sleep 1

# Case 3, session 2: the dispatch edit, lines only (no header statement that
# would take 71040 before the lot rows are locked).
edited=$(psql_exec -At -v claims="$claims" -v lot="$lot_id" <<'SQL'
SELECT set_config('request.jwt.claims',:'claims',false);
SET ROLE authenticated;
SELECT public.update_dispatch_smart((SELECT id FROM public.dispatch WHERE disp_no='LOCKD'),NULL,
  ARRAY[jsonb_build_object('gr_trl_id',:'lot','disp_qty',3)])::text;
SQL
)
wait "$holder" || { echo 'Item-table writer failed while a dispatch of the same lot was being edited.' >&2; exit 1; }
edited=$(printf '%s\n' "$edited" | tail -n1)
[[ "$edited" == *'"success": true'* ]] || { echo "Dispatch edit under a concurrent item-table writer did not succeed: $edited" >&2; exit 1; }
stored=$(psql_exec -At -v lot="$lot_id" <<'SQL'
SELECT t.rack='R10' AND t.stock=7 AND (SELECT count(*)=1 FROM public.dispatch_trl d WHERE d.gr_trl_id=t.id AND d.disp_qty=3)
FROM public.goodsreceived_trl t WHERE t.id=:'lot'::uuid;
SQL
)
[[ "$stored" = t ]] || { echo 'The dispatch edit and the item-table write were not both stored.' >&2; exit 1; }
echo 'Dispatch edit lock-order check passed under a concurrent item-table writer.'

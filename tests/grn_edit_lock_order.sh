#!/usr/bin/env bash
# Two-session proof for migration 26: a GRN edit must not deadlock with a
# concurrent writer that already holds the list-refresh lock (71040) and then
# touches goodsreceived_trl. Runs only against migrations.sh's disposable
# container, after the configuration block seeded admin 919888888899 with a
# live operator session. Both sessions must succeed and the edit must persist.
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

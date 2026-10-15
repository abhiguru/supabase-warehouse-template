#!/usr/bin/env bash
# Two-session proofs of rules that only two users acting at the same moment can
# break. Runs only against migrations.sh's disposable container. In each case
# session 1 makes its change and keeps its transaction open for a few seconds;
# session 2 starts meanwhile and must come back refused once session 1 commits.
#   1. Migration 44: two administrators deactivate each other. One call alone
#      can never reach the last-administrator rule (nobody may target the own
#      profile), so without the lock in other_active_admin_exists both would
#      see the other as still active and the warehouse would have none.
#   2. Migration 44: the same for two administrators who demote each other.
#   3. Migrations 41 and 46: two users invoice the same receipt. Both would
#      read invoiced = false and both would save.
#   4. Migration 76: two users change the same item rate from the same day.
#      The second waits for the first, then replaces its rows: exactly one
#      open row is left (no duplicate band, no unique violation).
#   5. Migration 85: an item created while the first save of the standard rate is
#      still open gets the tiers that save commits (not "no rate").
#   6. Migration 86: a GRN saved with an "everyone" rate entry waits for a rate change
#      of the same item, then sees it (RATE_PLANNED) and is not saved.
#   7. Migration 87 (BR-01): a supervisor changes a user an administrator is promoting at the same
#      moment: the supervisor waits, then is refused (the user stays an administrator).
#   8. Migration 87 (BR-02): a dispatch from a cart waits for a change of the cart line it consumes
#      and takes the new quantity (no lost update).
#   9. Migration 87 (BR-07): a retry that overlaps its first call (same user, inputs and key) waits and
#      is answered from the cache: one dispatch, one movement, stock reduced once.
#  10. Migration 87 (BR-04): the item rate writers (create, update) serialise per scope: the second
#      one sees the first one's committed row and answers BANDS_OVERLAP.
set -euo pipefail
container="${1:?disposable test container name required}"
export PGPASSWORD=disposable-test-database-only
psql_exec() { docker exec -i -e PGPASSWORD "$container" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 "$@"; }
scratch=$(mktemp -d "${TMPDIR:-/tmp}/concurrent-rules.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
# The JSON answer of the function a session called (psql also prints set_config and pg_sleep output).
answer() { grep -m1 '"success"' "$1" || true; }

# Administrators that exist already (the configuration test's) would make every
# demotion legitimate; they are set aside for the duration and restored below.
others=$(psql_exec -At <<'SQL'
SELECT COALESCE(string_agg(id::text, ','), '') FROM public.user_profiles
WHERE role='admin' AND active AND enrollment_status='approved';
SQL
)
psql_exec -v others="$others" <<'SQL'
UPDATE public.user_profiles SET active=false WHERE id::text = ANY(string_to_array(:'others', ','));
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888896','Concurrent Administrator One','admin',true,'approved'),
 (gen_random_uuid(),'919888888897','Concurrent Administrator Two','admin',true,'approved'),
 (gen_random_uuid(),'919888888894','Concurrent Staff','staff',true,'approved');
SQL
# Signs a profile in and prints "<profile id> <claims>".
sign_in() {
  psql_exec -At -v mobile="$1" <<'SQL'
SELECT warehouse_security.issue_session(auth_user_id)->>'token_type' FROM public.user_profiles WHERE mobile=:'mobile';
SELECT p.id || ' ' || jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',s.id)::text
FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id=p.auth_user_id
WHERE p.mobile=:'mobile' AND s.expires_at>now() ORDER BY s.created_at DESC LIMIT 1;
SQL
}
read -r admin_one claims_one < <(sign_in 919888888896 | tail -n1)
read -r admin_two claims_two < <(sign_in 919888888897 | tail -n1)
read -r _ claims_staff < <(sign_in 919888888894 | tail -n1)
[[ "$admin_one" =~ ^[0-9a-f-]{36}$ && "$admin_two" =~ ^[0-9a-f-]{36}$ && -n "$claims_one" && -n "$claims_two" && -n "$claims_staff" ]] ||
  { echo 'Concurrent-rule fixture accounts were not created.' >&2; exit 1; }

# Runs one statement as a signed-in user. With a hold time the transaction stays
# open that many seconds after the statement.
call_as() { # claims, statement, [seconds to hold]
  psql_exec -At -v claims="$1" -v hold="${3:-0}" <<SQL
BEGIN;
SELECT set_config('request.jwt.claims',:'claims',true);
SET LOCAL ROLE authenticated;
SELECT ($2)::text;
RESET ROLE;
SELECT pg_sleep(:'hold'::integer);
COMMIT;
SQL
}
# Two administrators call the same function on each other; exactly the second is refused.
admin_race() { # label, function call with %s for the target, expected refusal message
  local label="$1" call="$2" refusal="$3" first second state
  # shellcheck disable=SC2059
  call_as "$claims_one" "$(printf "$call" "$admin_two")" 4 > "$scratch/first" &
  local holder=$!
  sleep 1
  # shellcheck disable=SC2059
  call_as "$claims_two" "$(printf "$call" "$admin_one")" > "$scratch/second"
  wait "$holder" || { echo "$label: the first administrator's call failed." >&2; exit 1; }
  first=$(answer "$scratch/first"); second=$(answer "$scratch/second")
  [[ "$first" == *'"success": true'* ]] || { echo "$label: the first call did not succeed: $first" >&2; exit 1; }
  [[ "$second" == *'"success": false'* && "$second" == *'"error": "LAST_ADMIN"'* && "$second" == *"$refusal"* ]] ||
    { echo "$label: the second call was not refused as the last administrator: $second" >&2; exit 1; }
  state=$(psql_exec -At -v one="$admin_one" <<'SQL'
SELECT (SELECT role='admin' AND active AND enrollment_status='approved' FROM public.user_profiles WHERE id=:'one'::uuid)
  AND (SELECT count(*)=1 FROM public.user_profiles WHERE role='admin' AND active AND enrollment_status='approved');
SQL
  )
  [[ "$state" = t ]] || { echo "$label: the warehouse was left without exactly one administrator." >&2; exit 1; }
  echo "$label: of two administrators acting on each other, one was refused and one administrator remains."
}

admin_race 'Concurrent deactivation' "public.update_user_status('%s'::uuid,false)" 'The last active administrator cannot be deactivated'

# Case 2 needs the second administrator back, with a new session (deactivation ended the old one).
psql_exec <<'SQL'
UPDATE public.user_profiles SET role='admin',active=true,enrollment_status='approved' WHERE mobile='919888888897';
SQL
read -r _ claims_two < <(sign_in 919888888897 | tail -n1)
admin_race 'Concurrent demotion' "public.update_user_role('%s'::uuid,'supervisor'::public.user_role)" 'The last active administrator cannot be given another role'

# Case 3. One receipt, fully dispatched; the administrator and a staff member
# save an invoice for it under two numbers at the same moment.
psql_exec -v claims="$claims_one" > "$scratch/fixture" <<'SQL'
SELECT set_config('request.jwt.claims',:'claims',false);
SET ROLE authenticated;
SELECT public.create_customer('Concurrent Rule Customer','9888888895')->>'success';
SELECT public.create_item('Concurrent Rule Potatoes','Bag')->>'success';
SELECT public.save_grn(p_gr_no=>'CONCA',p_date=>'2026-04-01T12:00:00Z',
  p_customer_id=>(SELECT id FROM public.customers WHERE name='Concurrent Rule Customer'),p_customer_name=>'Concurrent Rule Customer',
  p_pricing_mode=>'MONTHLY',p_idempotency_key=>'concurrent-rule-receipt',
  p_items=>jsonb_build_array(jsonb_build_object('item_id',(SELECT id FROM public.items WHERE name='Concurrent Rule Potatoes'),
    'item_name','Concurrent Rule Potatoes','packaging','Bag','qty',10,'weight',10,'rack','R1')))->>'success';
SELECT public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','CONCD','disp_date','2026-05-02',
  'customer_id',(SELECT id FROM public.customers WHERE name='Concurrent Rule Customer'),'customer_name','Concurrent Rule Customer',
  'supervisor_id',(SELECT id FROM public.user_profiles WHERE mobile='919888888896'),'supervisor_name','Concurrent Administrator One'),
  ARRAY[jsonb_build_object('gr_trl_id',(SELECT t.id FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='CONCA'),
    'disp_qty',10)],0,'concurrent-rule-dispatch')->>'success';
SQL
receipt=$(psql_exec -At <<'SQL'
SELECT g.id FROM public.goodsreceived g WHERE g.gr_no='CONCA' AND g.invoiced IS NOT TRUE
  AND (SELECT count(*)=1 FROM public.dispatch_trl d WHERE d.gr_id=g.id);
SQL
)
[[ "$receipt" =~ ^[0-9a-f-]{36}$ ]] || { echo "Concurrent-invoice fixture failed: $(tr '\n' ' ' < "$scratch/fixture")" >&2; exit 1; }
invoice_call() { # invoice number
  cat <<SQL
public.save_invoice(NULL::uuid, (SELECT jsonb_build_object('inv_no',$1,'inv_fin_year',2026,'customer_id',g.customer_id,
  'customer_name','Concurrent Rule Customer','inv_date','2026-05-02T12:00:00Z','total',0,'tax_amount',0,'labour',0,'discount',0,
  'duration_mode','legacy','gr_id',g.id,'gr_no',g.gr_no) FROM public.goodsreceived g WHERE g.gr_no='CONCA'),
  ARRAY(SELECT jsonb_build_object('disp_trl_id',t.id,'grn_item_id',t.gr_trl_id,'duration',1,'charge',5,'tax',5,'labour_rate',2)
    FROM public.dispatch_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='CONCA'))
SQL
}
call_as "$claims_one" "$(invoice_call 20269901)" 4 > "$scratch/first" &
holder=$!
sleep 1
call_as "$claims_staff" "$(invoice_call 20269902)" > "$scratch/second"
wait "$holder" || { echo 'Concurrent invoice: the first save failed.' >&2; exit 1; }
first=$(answer "$scratch/first"); second=$(answer "$scratch/second")
[[ "$first" == *'"success": true'* ]] || { echo "Concurrent invoice: the first save did not succeed: $first" >&2; exit 1; }
[[ "$second" == *'"success": false'* && "$second" == *'GRN is already invoiced'* ]] ||
  { echo "Concurrent invoice: the second save was not refused as already invoiced: $second" >&2; exit 1; }
stored=$(psql_exec -At -v receipt="$receipt" <<'SQL'
SELECT (SELECT count(*)=1 AND bool_and(inv_no=20269901) FROM public.invoice WHERE gr_id=:'receipt'::uuid AND deleted_at IS NULL)
  AND (SELECT count(*)=1 FROM public.invoice_trl t JOIN public.dispatch_trl d ON d.id=t.disp_trl_id WHERE d.gr_id=:'receipt'::uuid)
  AND (SELECT invoiced FROM public.goodsreceived WHERE id=:'receipt'::uuid);
SQL
)
[[ "$stored" = t ]] || { echo 'Concurrent invoice: the receipt does not have exactly one invoice.' >&2; exit 1; }
echo 'Concurrent invoice: of two saves for one receipt, one was refused and one invoice exists.'

# Migration 76: two replace_item_rates calls for one scope and one start day.
call_as "$claims_one" "public.create_item('Concurrent Rate Item','Bag')" > "$scratch/rate-item"
rate_item=$(psql_exec -At <<'SQL'
SELECT id FROM public.items WHERE name='Concurrent Rate Item'
SQL
)
[[ "$rate_item" =~ ^[0-9a-f-]{36}$ ]] || { echo 'Concurrent rate change: the item was not created.' >&2; exit 1; }
rate_call() { # rent, replace_later (the second caller knowingly replaces the first's planned rate)
  echo "public.replace_item_rates('$rate_item'::uuid, NULL, 'monthly', CURRENT_DATE + 10, jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',$1,'labour_rate',2,'tax_percent',5)), ${2:-false})"
}
call_as "$claims_one" "$(rate_call 11)" 4 > "$scratch/rate-first" &
holder=$!
sleep 1
call_as "$claims_two" "$(rate_call 12 true)" > "$scratch/rate-second"
wait "$holder" || { echo 'Concurrent rate change: the first call failed.' >&2; exit 1; }
first=$(answer "$scratch/rate-first"); second=$(answer "$scratch/rate-second")
[[ "$first" == *'"success": true'* && "$second" == *'"success": true'* ]] ||
  { echo "Concurrent rate change: a call did not succeed: $first / $second" >&2; exit 1; }
stored=$(psql_exec -At -v item="$rate_item" <<'SQL'
SELECT count(*)=1 AND bool_and(unit_price=12 AND effective_to IS NULL) FROM public.item_storage_prices WHERE item_id=:'item'::uuid;
SQL
)
removed=$(psql_exec -At -v item="$rate_item" <<'SQL'
SELECT count(*) FROM public.item_price_history WHERE item_id=:'item'::uuid AND action='delete' AND (old_values->>'unit_price')::numeric=11;
SQL
)
[[ "$stored" = t && "$removed" = 1 ]] || { echo 'Concurrent rate change: not exactly one open row (the second call must replace the first).' >&2; exit 1; }
echo 'Concurrent rate change: two changes from one day left one open row; the second replaced the first.'

# Migration 85: an item created while the first save of the standard rate is still open must
# get the tiers that save commits, not "no rate" (create_item waits for the same lock).
standard_started=$(psql_exec -At <<'SQL'
SELECT clock_timestamp()
SQL
)
call_as "$claims_one" "public.set_standard_rate('[{\"weight_min\":0,\"weight_max\":50,\"unit_price\":7,\"labour_rate\":2,\"tax_percent\":5}]'::jsonb)" 4 > "$scratch/std-first" &
holder=$!
sleep 1
call_as "$claims_two" "public.create_item('Concurrent Standard Item','Bag')" > "$scratch/std-second"
wait "$holder" || { echo 'Concurrent standard rate: the save failed.' >&2; exit 1; }
first=$(answer "$scratch/std-first"); second=$(answer "$scratch/std-second")
[[ "$first" == *'"success": true'* ]] || { echo "Concurrent standard rate: the save did not succeed: $first" >&2; exit 1; }
[[ "$second" == *'"success": true'* && "$second" == *'"rate_source": "standard"'* ]] ||
  { echo "Concurrent standard rate: the item created during the save did not get the standard rate: $second" >&2; exit 1; }
stored=$(psql_exec -At <<'SQL'
SELECT count(*)=1 AND bool_and(unit_price=7 AND weight_min=0 AND weight_max=50 AND effective_to IS NULL)
  FROM public.item_storage_prices WHERE item_id=(SELECT id FROM public.items WHERE name='Concurrent Standard Item');
SQL
)
[[ "$stored" = t ]] || { echo 'Concurrent standard rate: the new item does not have the saved tier.' >&2; exit 1; }
echo 'Concurrent standard rate: an item created during the first save got the tiers that save committed.'
# Put the database back for the tests that follow: no tiers, none of the rows this case gave out.
psql_exec -v started="$standard_started" <<'SQL'
DELETE FROM public.standard_rate_tiers;
DELETE FROM public.item_storage_prices WHERE created_at >= :'started'::timestamptz;
SQL

# Migration 86: a GRN saved with an "everyone" rate entry takes the same lock as replace_item_rates. The
# save starts while the rate change is still open; it waits, then sees the committed change (a planned
# rate in its way, RATE_PLANNED with that day) and the GRN is not saved.
call_as "$claims_one" "public.create_item('Concurrent Grn Rate Item','Bag')" > "$scratch/grn-item"
grn_item=$(psql_exec -At <<'SQL'
SELECT id FROM public.items WHERE name='Concurrent Grn Rate Item'
SQL
)
[[ "$grn_item" =~ ^[0-9a-f-]{36}$ ]] || { echo 'Concurrent GRN rate: the item was not created.' >&2; exit 1; }
grn_rate_call() { # start offset in days, rent
  echo "public.replace_item_rates('$grn_item'::uuid, NULL, 'monthly', CURRENT_DATE + $1, jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',$2,'labour_rate',2,'tax_percent',5)), false)"
}
call_as "$claims_one" "$(grn_rate_call -20 3)" > "$scratch/grn-rate-base"
[[ "$(answer "$scratch/grn-rate-base")" == *'"success": true'* ]] || { echo "Concurrent GRN rate: the base rate was not set: $(answer "$scratch/grn-rate-base")" >&2; exit 1; }
grn_save_call() {
  cat <<SQL
public.save_grn(p_gr_no=>'CONCB',p_date=>(CURRENT_DATE - 2)::text::timestamptz + interval '12 hours',
  p_customer_id=>(SELECT id FROM public.customers WHERE name='Concurrent Rule Customer'),p_customer_name=>'Concurrent Rule Customer',
  p_pricing_mode=>'MONTHLY',
  p_items=>jsonb_build_array(jsonb_build_object('item_id','$grn_item'::uuid,'item_name','Concurrent Grn Rate Item','packaging','Bag','qty',1,'weight',10,'rack','R1')),
  p_rates=>jsonb_build_array(jsonb_build_object('scope','everyone','item_id','$grn_item'::uuid,'weight_min',0,'weight_max',100,'to',NULL,
    'unit_price',12,'labour_rate',2,'tax_percent',5)))
SQL
}
call_as "$claims_one" "$(grn_rate_call 1 11)" 4 > "$scratch/grn-first" &
holder=$!
sleep 1
call_as "$claims_staff" "$(grn_save_call)" > "$scratch/grn-second"
wait "$holder" || { echo 'Concurrent GRN rate: the rate change failed.' >&2; exit 1; }
first=$(answer "$scratch/grn-first"); second=$(answer "$scratch/grn-second")
[[ "$first" == *'"success": true'* ]] || { echo "Concurrent GRN rate: the rate change did not succeed: $first" >&2; exit 1; }
[[ "$second" == *'"success": false'* && "$second" == *'"error_code": "RATE_PLANNED"'* ]] ||
  { echo "Concurrent GRN rate: the GRN save did not see the committed change: $second" >&2; exit 1; }
stored=$(psql_exec -At -v item="$grn_item" <<'SQL'
SELECT (SELECT count(*)=0 FROM public.goodsreceived WHERE gr_no='CONCB')
  AND (SELECT count(*)=2 AND count(*) FILTER (WHERE unit_price=11 AND effective_to IS NULL)=1 FROM public.item_storage_prices WHERE item_id=:'item'::uuid);
SQL
)
[[ "$stored" = t ]] || { echo 'Concurrent GRN rate: the GRN was saved, or the rate rows are not the change alone.' >&2; exit 1; }
echo 'Concurrent GRN rate: a GRN save with a rate entry waited for the rate change, saw it and was refused as RATE_PLANNED.'

# Case 7. Migration 87 (BR-01): the supervisor (the second user, demoted by case 2) sets the staff
# member to customer while the administrator promotes the same staff member and keeps the transaction open.
staff_id=$(psql_exec -At <<'SQL'
SELECT id FROM public.user_profiles WHERE mobile='919888888894'
SQL
)
[[ "$staff_id" =~ ^[0-9a-f-]{36}$ ]] || { echo 'Concurrent role change: the staff fixture is missing.' >&2; exit 1; }
call_as "$claims_one" "public.update_user_role('$staff_id'::uuid,'admin'::public.user_role)" 4 > "$scratch/role-first" &
holder=$!
sleep 1
call_as "$claims_two" "public.update_user_role('$staff_id'::uuid,'customer'::public.user_role)" > "$scratch/role-second"
wait "$holder" || { echo 'Concurrent role change: the administrator call failed.' >&2; exit 1; }
first=$(answer "$scratch/role-first"); second=$(answer "$scratch/role-second")
[[ "$first" == *'"success": true'* ]] || { echo "Concurrent role change: the promotion did not succeed: $first" >&2; exit 1; }
[[ "$second" == *'"success": false'* && "$second" == *'Supervisors cannot modify admin users'* ]] ||
  { echo "Concurrent role change: the supervisor was not refused as acting on an administrator: $second" >&2; exit 1; }
[[ "$(psql_exec -At <<'SQL'
SELECT role FROM public.user_profiles WHERE mobile='919888888894'
SQL
)" = admin ]] || { echo 'Concurrent role change: the promoted user did not keep the administrator role.' >&2; exit 1; }
# The same for a status change: the supervisor deactivates the user the administrator is promoting.
psql_exec <<'SQL'
UPDATE public.user_profiles SET role='staff' WHERE mobile='919888888894';
SQL
call_as "$claims_one" "public.update_user_role('$staff_id'::uuid,'admin'::public.user_role)" 4 > "$scratch/role-first" &
holder=$!
sleep 1
call_as "$claims_two" "public.update_user_status('$staff_id'::uuid,false)" > "$scratch/role-second"
wait "$holder" || { echo 'Concurrent status change: the administrator call failed.' >&2; exit 1; }
second=$(answer "$scratch/role-second")
[[ "$second" == *'"success": false'* && "$second" == *'Supervisors cannot modify admin users'* ]] ||
  { echo "Concurrent status change: the supervisor was not refused as acting on an administrator: $second" >&2; exit 1; }
[[ "$(psql_exec -At <<'SQL'
SELECT role='admin' AND active FROM public.user_profiles WHERE mobile='919888888894'
SQL
)" = t ]] || { echo 'Concurrent status change: the promoted user is not an active administrator.' >&2; exit 1; }
psql_exec <<'SQL'
UPDATE public.user_profiles SET role='staff' WHERE mobile='919888888894';
SQL
echo 'Concurrent role and status change: a supervisor acting while an administrator promoted the user waited and was refused; the user stayed an administrator.'

# Case 8. Migration 87 (BR-02): the cart line asks for 10 of a lot holding 100; the administrator raises
# it to 20 (transaction held); a dispatch of 4 from that cart starts meanwhile and must take the 20.
psql_exec -v claims="$claims_one" > "$scratch/fixture87" <<'SQL'
SELECT set_config('request.jwt.claims',:'claims',false);
SET ROLE authenticated;
SELECT public.save_grn(p_gr_no=>'CONCC',p_date=>'2026-04-01T12:00:00Z',
  p_customer_id=>(SELECT id FROM public.customers WHERE name='Concurrent Rule Customer'),p_customer_name=>'Concurrent Rule Customer',
  p_pricing_mode=>'MONTHLY',p_idempotency_key=>'concurrent-rule-cart-lot',
  p_items=>jsonb_build_array(jsonb_build_object('item_id',(SELECT id FROM public.items WHERE name='Concurrent Rule Potatoes'),
    'item_name','Concurrent Rule Potatoes','packaging','Bag','qty',100,'weight',10,'rack','R2')))->>'success';
SELECT public.save_grn(p_gr_no=>'CONCD',p_date=>'2026-04-01T12:00:00Z',
  p_customer_id=>(SELECT id FROM public.customers WHERE name='Concurrent Rule Customer'),p_customer_name=>'Concurrent Rule Customer',
  p_pricing_mode=>'MONTHLY',p_idempotency_key=>'concurrent-rule-retry-lot',
  p_items=>jsonb_build_array(jsonb_build_object('item_id',(SELECT id FROM public.items WHERE name='Concurrent Rule Potatoes'),
    'item_name','Concurrent Rule Potatoes','packaging','Bag','qty',50,'weight',10,'rack','R3')))->>'success';
SELECT public.get_or_create_cart((SELECT id FROM public.customers WHERE name='Concurrent Rule Customer'))::text;
SQL
cart_lot=$(psql_exec -At <<'SQL'
SELECT t.id FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='CONCC'
SQL
)
cart_id=$(psql_exec -At <<'SQL'
SELECT id FROM public.orders WHERE customer_id=(SELECT id FROM public.customers WHERE name='Concurrent Rule Customer')
  AND status='OPEN' AND deleted_at IS NULL ORDER BY created_at LIMIT 1
SQL
)
[[ "$cart_lot" =~ ^[0-9a-f-]{36}$ && "$cart_id" =~ ^[0-9a-f-]{36}$ ]] ||
  { echo "Concurrent cart line: the fixture failed: $(tr '\n' ' ' < "$scratch/fixture87")" >&2; exit 1; }
call_as "$claims_one" "public.add_item_to_order('$cart_id'::uuid,'$cart_lot'::uuid,10)" > "$scratch/cart-add"
cart_line=$(psql_exec -At <<SQL
SELECT id FROM public.order_items WHERE order_id='$cart_id'::uuid AND grn_items_id='$cart_lot'::uuid
SQL
)
[[ "$cart_line" =~ ^[0-9a-f-]{36}$ ]] || { echo "Concurrent cart line: the cart line was not created: $(answer "$scratch/cart-add")" >&2; exit 1; }
cart_dispatch_call() { # disp_no, idempotency key, lot, quantity, source order or empty
  cat <<SQL
public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','$1','disp_date','2026-05-02','customer_id',
  (SELECT id FROM public.customers WHERE name='Concurrent Rule Customer'),'customer_name','Concurrent Rule Customer',
  'supervisor_id','$admin_one','supervisor_name','Concurrent Administrator One'$5),
  ARRAY[jsonb_build_object('gr_trl_id','$3'::uuid,'disp_qty',$4)],0,'$2')
SQL
}
call_as "$claims_one" "public.update_order_item_quantity('$cart_line'::uuid,20)" 4 > "$scratch/cart-first" &
holder=$!
sleep 1
call_as "$claims_two" "$(cart_dispatch_call CONCE concurrent-cart-key "$cart_lot" 4 ",'source_order_id','$cart_id'")" > "$scratch/cart-second"
wait "$holder" || { echo 'Concurrent cart line: the quantity change failed.' >&2; exit 1; }
first=$(answer "$scratch/cart-first"); second=$(answer "$scratch/cart-second")
[[ "$first" == *'"success": true'* && "$second" == *'"success": true'* ]] ||
  { echo "Concurrent cart line: a call did not succeed: $first / $second" >&2; exit 1; }
stored=$(psql_exec -At <<SQL
SELECT (SELECT requested_quantity=16 FROM public.order_items WHERE id='$cart_line'::uuid)
  AND (SELECT count(*)=1 AND bool_and(cart_quantity_consumed=4 AND source_order_item_id='$cart_line'::uuid) FROM public.dispatch_trl WHERE gr_trl_id='$cart_lot'::uuid)
  AND (SELECT stock=96 FROM public.goodsreceived_trl WHERE id='$cart_lot'::uuid);
SQL
)
[[ "$stored" = t ]] || { echo 'Concurrent cart line: the cart line is not 16 (20 - 4), or the dispatch did not take 4 from it, or the stock is not 96.' >&2; exit 1; }
echo 'Concurrent cart line: a dispatch from the cart waited for the quantity change and took the new 20 (16 left, stock 96).'

# Case 9. Migration 87 (BR-07): the same user sends the same dispatch with the same key twice, overlapping.
retry_lot=$(psql_exec -At <<'SQL'
SELECT t.id FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='CONCD'
SQL
)
[[ "$retry_lot" =~ ^[0-9a-f-]{36}$ ]] || { echo 'Concurrent retry: the fixture lot is missing.' >&2; exit 1; }
call_as "$claims_one" "$(cart_dispatch_call CONCF concurrent-retry-key "$retry_lot" 5 '')" 4 > "$scratch/retry-first" &
holder=$!
sleep 1
call_as "$claims_one" "$(cart_dispatch_call CONCF concurrent-retry-key "$retry_lot" 5 '')" > "$scratch/retry-second"
wait "$holder" || { echo 'Concurrent retry: the first call failed.' >&2; exit 1; }
first=$(answer "$scratch/retry-first"); second=$(answer "$scratch/retry-second")
[[ "$first" == *'"success": true'* && "$first" != *'from_cache'* ]] ||
  { echo "Concurrent retry: the first call did not create the dispatch: $first" >&2; exit 1; }
[[ "$second" == *'"success": true'* && "$second" == *'"from_cache": true'* ]] ||
  { echo "Concurrent retry: the overlapping retry was not answered from the cache: $second" >&2; exit 1; }
stored=$(psql_exec -At <<SQL
SELECT (SELECT count(*)=1 FROM public.dispatch WHERE disp_no='CONCF')
  AND (SELECT count(*)=1 FROM public.dispatch_trl WHERE gr_trl_id='$retry_lot'::uuid)
  AND (SELECT count(*)=1 FROM public.stock_movements WHERE gr_trl_id='$retry_lot'::uuid AND movement_type='dispatch')
  AND (SELECT stock=45 FROM public.goodsreceived_trl WHERE id='$retry_lot'::uuid);
SQL
)
[[ "$stored" = t ]] || { echo 'Concurrent retry: not exactly one dispatch, one line, one movement and stock 45.' >&2; exit 1; }
echo 'Concurrent retry: an overlapping retry waited, was answered from the cache; one dispatch, one movement, stock reduced once.'

# Case 10. Migration 87 (BR-04): rate writers of one scope (item, everyone, monthly) take turns.
call_as "$claims_one" "public.create_item('Concurrent Rate Writer A','Bag')" > "$scratch/rw-item"
call_as "$claims_one" "public.create_item('Concurrent Rate Writer B','Bag')" > "$scratch/rw-item"
rw_item_a=$(psql_exec -At <<'SQL'
SELECT id FROM public.items WHERE name='Concurrent Rate Writer A'
SQL
)
rw_item_b=$(psql_exec -At <<'SQL'
SELECT id FROM public.items WHERE name='Concurrent Rate Writer B'
SQL
)
[[ "$rw_item_a" =~ ^[0-9a-f-]{36}$ && "$rw_item_b" =~ ^[0-9a-f-]{36}$ ]] || { echo 'Concurrent rate writers: the items were not created.' >&2; exit 1; }
create_price_call() { # item, weight min, weight max, unit price
  echo "public.create_item_storage_price(p_item_id=>'$1'::uuid,p_price_type=>'monthly',p_unit_price=>$4,p_weight_min=>$2,p_weight_max=>$3,p_labour_rate=>2,p_effective_from=>CURRENT_DATE + 10,p_tax_percent=>5)"
}
call_as "$claims_one" "$(create_price_call "$rw_item_a" 0 100 5)" 4 > "$scratch/rw-first" &
holder=$!
sleep 1
call_as "$claims_two" "$(create_price_call "$rw_item_a" 50 150 9)" > "$scratch/rw-second"
wait "$holder" || { echo 'Concurrent rate writers: the first create failed.' >&2; exit 1; }
first=$(answer "$scratch/rw-first"); second=$(answer "$scratch/rw-second")
[[ "$first" == *'"success": true'* ]] || { echo "Concurrent rate writers: the first create did not succeed: $first" >&2; exit 1; }
[[ "$second" == *'"success": false'* && "$second" == *'BANDS_OVERLAP'* ]] ||
  { echo "Concurrent rate writers: the second create was not refused as BANDS_OVERLAP: $second" >&2; exit 1; }
[[ "$(psql_exec -At <<SQL
SELECT count(*)=1 AND bool_and(weight_min=0 AND weight_max=100 AND unit_price=5) FROM public.item_storage_prices WHERE item_id='$rw_item_a'::uuid
SQL
)" = t ]] || { echo 'Concurrent rate writers: the item does not have exactly the first row.' >&2; exit 1; }
# An update and a create of the same scope: the update widens the one row to 0..100 while a create of 50..150 waits.
call_as "$claims_one" "$(create_price_call "$rw_item_b" 0 49 5)" > "$scratch/rw-base"
rw_row=$(psql_exec -At <<SQL
SELECT id FROM public.item_storage_prices WHERE item_id='$rw_item_b'::uuid
SQL
)
[[ "$rw_row" =~ ^[0-9a-f-]{36}$ ]] || { echo "Concurrent rate writers: the base row was not created: $(answer "$scratch/rw-base")" >&2; exit 1; }
call_as "$claims_one" "public.update_item_storage_price(p_id=>'$rw_row'::uuid,p_unit_price=>5,p_weight_min=>0,p_weight_max=>100,p_labour_rate=>2,p_tax_percent=>5,p_effective_from=>CURRENT_DATE + 10)" 4 > "$scratch/rw-first"  &
holder=$!
sleep 1
call_as "$claims_two" "$(create_price_call "$rw_item_b" 50 150 9)" > "$scratch/rw-second"
wait "$holder" || { echo 'Concurrent rate writers: the update failed.' >&2; exit 1; }
first=$(answer "$scratch/rw-first"); second=$(answer "$scratch/rw-second")
[[ "$first" == *'"success": true'* ]] || { echo "Concurrent rate writers: the update did not succeed: $first" >&2; exit 1; }
[[ "$second" == *'"success": false'* && "$second" == *'BANDS_OVERLAP'* ]] ||
  { echo "Concurrent rate writers: the create after the update was not refused as BANDS_OVERLAP: $second" >&2; exit 1; }
[[ "$(psql_exec -At <<SQL
SELECT count(*)=1 AND bool_and(weight_min=0 AND weight_max=100) FROM public.item_storage_prices WHERE item_id='$rw_item_b'::uuid
SQL
)" = t ]] || { echo 'Concurrent rate writers: the item does not have exactly the widened row.' >&2; exit 1; }
echo 'Concurrent rate writers: a create and an update of one scope took turns; the later one was refused as BANDS_OVERLAP and no bands overlap.'

# The administrators set aside at the start get their place back.
psql_exec -v others="$others" <<'SQL'
UPDATE public.user_profiles SET active=true WHERE id::text = ANY(string_to_array(:'others', ','));
SQL

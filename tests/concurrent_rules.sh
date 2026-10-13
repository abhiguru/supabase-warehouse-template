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

# The administrators set aside at the start get their place back.
psql_exec -v others="$others" <<'SQL'
UPDATE public.user_profiles SET active=true WHERE id::text = ANY(string_to_array(:'others', ','));
SQL

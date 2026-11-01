-- Migration 128, section 3: the order effect of a save, told before (preview_*) and after (the answer of the save).
--   * preview_create_dispatch, preview_update_dispatch, preview_update_grn and preview_delete_grn answer the effect on the customer's
--     order lines and change nothing (lines, stock, dispatch rows, history, saved answers).
--   * The real save answers the same list (order_effects); a refused save is refused the same way by its preview, with preview:true.
--   * A GRN edit that lowers a lot below what an order line asks for lists the line as exceeds_stock; a GRN delete lists the lines it
--     removes; a GRN edit that does not touch an order line lists nothing.
--   * Access: staff may preview a dispatch and a GRN edit, not a GRN delete; a customer account none of them.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database. Every row rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.eff_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'order effects: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.eff_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM pg_temp.eff_assert(challenge->>'success'='true','ordinary challenge');
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  login := public.operator_verify_otp(phone,challenge#>>'{data,otp_code}');
  PERFORM pg_temp.eff_assert(login#>>'{data,action}'='login','ordinary login');
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id=p.auth_user_id
    WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- True when the statement is refused by the RPC guard (a raw 42501).
CREATE FUNCTION pg_temp.eff_refused(statement text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE statement;
  EXCEPTION WHEN insufficient_privilege THEN RETURN true; END;
  RETURN false;
END $$;
-- The state a preview must leave alone: the order lines, the stock of the three lots, the dispatches, the order history and the saved answers.
CREATE FUNCTION pg_temp.eff_state(cart uuid) RETURNS text LANGUAGE sql AS $$
  SELECT concat_ws('|',
    (SELECT string_agg(grn_items_item_name || '=' || requested_quantity, ',' ORDER BY grn_items_item_name) FROM public.order_items WHERE order_id = cart),
    (SELECT string_agg(item_name || '=' || stock || '/' || qty, ',' ORDER BY item_name) FROM public.goodsreceived_trl WHERE item_name LIKE 'Effects %'),
    (SELECT count(*) FROM public.dispatch),
    (SELECT count(*) FROM public.dispatch_trl),
    (SELECT count(*) FROM public.order_revisions WHERE order_id = cart),
    (SELECT count(*) FROM public.stock_movements),
    (SELECT count(*) FROM public.idempotency_keys),
    (SELECT count(*) FROM public.goodsreceived)) $$;

INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888888811','Effects Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888812','Effects Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888813','Effects Customer Reader','customer',true,'approved');
SELECT pg_temp.eff_login('9888888811') AS admin_claims \gset
SELECT pg_temp.eff_login('9888888812') AS staff_claims \gset
SELECT pg_temp.eff_login('9888888813') AS customer_claims \gset
INSERT INTO public.customers(name,mobile) VALUES ('Effects Customer A','9888888861') RETURNING id AS customer_a \gset
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active)
 SELECT id,:'customer_a'::uuid,true FROM public.user_profiles WHERE mobile='919888888813';
INSERT INTO public.items(name,packaging) VALUES ('Effects Onions','Bag') RETURNING id AS onion_item \gset
INSERT INTO public.items(name,packaging) VALUES ('Effects Garlic','Bag') RETURNING id AS garlic_item \gset
INSERT INTO public.items(name,packaging) VALUES ('Effects Rice','Bag') RETURNING id AS rice_item \gset

-- Two GRNs of one customer: Onions 20 and Garlic 30 on the first, Rice 10 on the second. The order asks for 10, 6 and 8.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_grn(p_gr_no=>'EFFA',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_a'::uuid,p_customer_name=>'Effects Customer A',
 p_items=>jsonb_build_array(
  jsonb_build_object('item_id',:'onion_item','item_name','Effects Onions','packaging','Bag','qty',20,'weight',10,'rack','R1','package_mark','X0001'),
  jsonb_build_object('item_id',:'garlic_item','item_name','Effects Garlic','packaging','Bag','qty',30,'weight',10,'rack','R2','package_mark','X0002')),
 p_idempotency_key=>'effects-grn-a') AS grn_a_answer \gset
SELECT public.save_grn(p_gr_no=>'EFFB',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_a'::uuid,p_customer_name=>'Effects Customer A',
 p_items=>jsonb_build_array(
  jsonb_build_object('item_id',:'rice_item','item_name','Effects Rice','packaging','Bag','qty',10,'weight',10,'rack','R3','package_mark','X0003')),
 p_idempotency_key=>'effects-grn-b') AS grn_b_answer \gset
RESET ROLE;
SELECT pg_temp.eff_assert(:'grn_a_answer'::jsonb->>'success'='true' AND :'grn_b_answer'::jsonb->>'success'='true','receipts: '||:'grn_a_answer'||:'grn_b_answer');
SELECT id AS grn_a FROM public.goodsreceived WHERE gr_no='EFFA' \gset
SELECT id AS grn_b FROM public.goodsreceived WHERE gr_no='EFFB' \gset
SELECT id AS lot_onion FROM public.goodsreceived_trl WHERE gr_id=:'grn_a'::uuid AND item_name='Effects Onions' \gset
SELECT id AS lot_garlic FROM public.goodsreceived_trl WHERE gr_id=:'grn_a'::uuid AND item_name='Effects Garlic' \gset
SELECT id AS lot_rice FROM public.goodsreceived_trl WHERE gr_id=:'grn_b'::uuid \gset
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'customer_a'::uuid) AS cart \gset
SELECT pg_temp.eff_assert(public.add_item_to_order(:'cart'::uuid,:'lot_onion'::uuid,10)->>'success'='true','order: Onions 10');
SELECT pg_temp.eff_assert(public.add_item_to_order(:'cart'::uuid,:'lot_garlic'::uuid,6)->>'success'='true','order: Garlic 6');
SELECT pg_temp.eff_assert(public.add_item_to_order(:'cart'::uuid,:'lot_rice'::uuid,8)->>'success'='true','order: Rice 8');
RESET ROLE;
SELECT pg_temp.eff_state(:'cart'::uuid) AS state0 \gset
SELECT pg_temp.eff_assert(:'state0' LIKE 'Effects Garlic=6,Effects Onions=10,Effects Rice=8|Effects Garlic=30/30,Effects Onions=20/20,Effects Rice=10/10|0|0|%','fixture state: '||:'state0');

SELECT jsonb_build_object('disp_no','EFFD1','disp_date','2026-05-02T12:00:00Z','customer_id',:'customer_a',
 'customer_name','Effects Customer A','supervisor_id',:'admin_profile','supervisor_name','Effects Administrator') AS header \gset

-- 1. A direct dispatch of Onions 4 and Garlic 6: the preview names the lowered line and the removed line, and changes nothing.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.preview_create_dispatch(:'header'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_onion','disp_qty',4),jsonb_build_object('gr_trl_id',:'lot_garlic','disp_qty',6)]) AS p1 \gset
RESET ROLE;
SELECT pg_temp.eff_assert(:'p1'::jsonb->>'success'='true' AND :'p1'::jsonb->>'preview'='true','the dispatch preview succeeds: '||:'p1');
SELECT pg_temp.eff_assert(jsonb_array_length(:'p1'::jsonb->'order_effects')=2
 AND :'p1'::jsonb#>>'{order_effects,0,item_name}'='Effects Garlic' AND :'p1'::jsonb#>>'{order_effects,0,change}'='removed'
 AND (:'p1'::jsonb#>>'{order_effects,0,old_quantity}')::int=6 AND (:'p1'::jsonb#>>'{order_effects,0,new_quantity}')::int=0
 AND :'p1'::jsonb#>>'{order_effects,0,removed}'='true' AND (:'p1'::jsonb#>>'{order_effects,0,order_lines_left}')::int=2
 AND :'p1'::jsonb#>>'{order_effects,0,customer_name}'='Effects Customer A' AND :'p1'::jsonb#>>'{order_effects,0,order_id}'=:'cart'
 AND :'p1'::jsonb#>>'{order_effects,0,grn_no}'='EFFA' AND :'p1'::jsonb#>>'{order_effects,0,package_mark}'='X0002'
 AND :'p1'::jsonb#>>'{order_effects,1,item_name}'='Effects Onions' AND :'p1'::jsonb#>>'{order_effects,1,change}'='reduced'
 AND (:'p1'::jsonb#>>'{order_effects,1,old_quantity}')::int=10 AND (:'p1'::jsonb#>>'{order_effects,1,new_quantity}')::int=6
 AND :'p1'::jsonb#>>'{order_effects,1,removed}'='false' AND :'p1'::jsonb#>>'{order_effects,1,grn_item_id}'=:'lot_onion',
 'the preview names Garlic removed and Onions 10 to 6: '||:'p1');
SELECT pg_temp.eff_assert(NOT (:'p1'::jsonb ? 'dispatch_id'),'a preview does not return the id of a dispatch that was not kept');
SELECT pg_temp.eff_assert(pg_temp.eff_state(:'cart'::uuid)=:'state0','the preview changed nothing: '||pg_temp.eff_state(:'cart'::uuid));

-- The real save answers the same list.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'header'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_onion','disp_qty',4),jsonb_build_object('gr_trl_id',:'lot_garlic','disp_qty',6)],false,0,'effects-d1') AS r1 \gset
RESET ROLE;
SELECT pg_temp.eff_assert(:'r1'::jsonb->>'success'='true' AND (:'r1'::jsonb->'order_effects')=(:'p1'::jsonb->'order_effects'),'the save answers the effect the preview named: '||:'r1');
SELECT pg_temp.eff_assert((SELECT string_agg(grn_items_item_name||'='||requested_quantity, ',' ORDER BY grn_items_item_name) FROM public.order_items WHERE order_id=:'cart'::uuid)
 ='Effects Onions=6,Effects Rice=8','the order after the dispatch');
SELECT id AS disp_1 FROM public.dispatch WHERE disp_no='EFFD1' \gset

-- 2. A save that would be refused is refused the same way by its preview.
SELECT pg_temp.eff_state(:'cart'::uuid) AS state1 \gset
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.preview_create_dispatch(:'header'::jsonb, ARRAY[jsonb_build_object('gr_trl_id',:'lot_onion','disp_qty',1)]) AS p_taken \gset
SELECT public.create_dispatch_with_stock_check(:'header'::jsonb, ARRAY[jsonb_build_object('gr_trl_id',:'lot_onion','disp_qty',1)],false,0,'effects-d1-again') AS r_taken \gset
SELECT public.preview_create_dispatch(:'header'::jsonb || '{"disp_no":"EFFD2"}'::jsonb, ARRAY[jsonb_build_object('gr_trl_id',:'lot_onion','disp_qty',999)]) AS p_stock \gset
SELECT public.create_dispatch_with_stock_check(:'header'::jsonb || '{"disp_no":"EFFD2"}'::jsonb, ARRAY[jsonb_build_object('gr_trl_id',:'lot_onion','disp_qty',999)],false,0,'effects-d2-stock') AS r_stock \gset
RESET ROLE;
SELECT pg_temp.eff_assert(:'r_taken'::jsonb->>'reason'='NUMBER_TAKEN' AND :'p_taken'::jsonb->>'success'='false' AND :'p_taken'::jsonb->>'preview'='true'
 AND :'p_taken'::jsonb->>'reason'=:'r_taken'::jsonb->>'reason' AND :'p_taken'::jsonb->>'error'=:'r_taken'::jsonb->>'error'
 AND :'p_taken'::jsonb->>'error_code'=:'r_taken'::jsonb->>'error_code','a taken number is refused the same way: '||:'p_taken'||:'r_taken');
SELECT pg_temp.eff_assert(:'r_stock'::jsonb->>'success'='false' AND :'p_stock'::jsonb->>'success'='false' AND :'p_stock'::jsonb->>'preview'='true'
 AND :'p_stock'::jsonb->>'error'=:'r_stock'::jsonb->>'error' AND :'p_stock'::jsonb->>'error' LIKE 'Insufficient stock%','too many bags are refused the same way: '||:'p_stock'||:'r_stock');
SELECT pg_temp.eff_assert(pg_temp.eff_state(:'cart'::uuid)=:'state1','the refused previews and saves changed nothing');

-- 3. A dispatch edit: Onions 4 -> 2, Garlic taken out. The bags go back to the order: Onions 6 -> 8, Garlic is a line again.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.preview_update_dispatch(:'disp_1'::uuid,'{"note":"effects edit"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_onion','disp_qty',2)]) AS p2 \gset
RESET ROLE;
SELECT pg_temp.eff_assert(:'p2'::jsonb->>'success'='true' AND :'p2'::jsonb->>'preview'='true'
 AND jsonb_array_length(:'p2'::jsonb->'order_effects')=2
 AND :'p2'::jsonb#>>'{order_effects,0,item_name}'='Effects Garlic' AND :'p2'::jsonb#>>'{order_effects,0,change}'='added'
 AND (:'p2'::jsonb#>>'{order_effects,0,old_quantity}')::int=0 AND (:'p2'::jsonb#>>'{order_effects,0,new_quantity}')::int=6
 AND :'p2'::jsonb#>>'{order_effects,1,item_name}'='Effects Onions' AND :'p2'::jsonb#>>'{order_effects,1,change}'='increased'
 AND (:'p2'::jsonb#>>'{order_effects,1,old_quantity}')::int=6 AND (:'p2'::jsonb#>>'{order_effects,1,new_quantity}')::int=8,
 'the dispatch edit preview names Garlic added back and Onions 6 to 8: '||:'p2');
SELECT pg_temp.eff_assert(pg_temp.eff_state(:'cart'::uuid)=:'state1','the edit preview changed nothing: '||pg_temp.eff_state(:'cart'::uuid));
-- A stale form is refused by the preview as by the save.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.preview_update_dispatch(:'disp_1'::uuid,
 jsonb_build_object('expected_updated_at',((SELECT updated_at FROM public.dispatch WHERE id=:'disp_1'::uuid) - interval '1 hour')::text),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_onion','disp_qty',2)]) AS p_stale \gset
RESET ROLE;
SELECT pg_temp.eff_assert(:'p_stale'::jsonb->>'success'='false' AND :'p_stale'::jsonb->>'reason'='STALE_RECORD' AND :'p_stale'::jsonb->>'preview'='true','a stale edit is refused by the preview: '||:'p_stale');
-- A refusal of the real save (a dispatch with no line; the real update answers it as {success:false, error}) comes back from the preview as that refusal, with preview:true; nothing changes.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.preview_update_dispatch(:'disp_1'::uuid,'{"note":"effects edit"}'::jsonb,ARRAY[]::jsonb[]) AS p_raised \gset
RESET ROLE;
SELECT pg_temp.eff_assert(:'p_raised'::jsonb->>'success'='false' AND :'p_raised'::jsonb->>'preview'='true'
 AND :'p_raised'::jsonb->>'error'='A dispatch needs at least one line' AND pg_temp.eff_state(:'cart'::uuid)=:'state1',
 'a raised refusal comes back as a preview refusal: '||:'p_raised');
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_1'::uuid,'{"note":"effects edit"}'::jsonb,ARRAY[jsonb_build_object('gr_trl_id',:'lot_onion','disp_qty',2)]) AS r2 \gset
RESET ROLE;
SELECT pg_temp.eff_assert(:'r2'::jsonb->>'success'='true' AND (:'r2'::jsonb->'order_effects')=(:'p2'::jsonb->'order_effects')
 AND (:'r2'::jsonb#>>'{order_sync,given_back}')::int=8,'the edit answers the effect the preview named, and still order_sync: '||:'r2');

-- 4. A GRN edit that lowers Rice to 5 bags while the order asks for 8: the line is named, unchanged, with what the lot holds.
SELECT pg_temp.eff_state(:'cart'::uuid) AS state2 \gset
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.preview_update_grn(p_grn_id=>:'grn_b'::uuid,
 p_items=>jsonb_build_array(jsonb_build_object('id',:'lot_rice','item_id',:'rice_item','item_name','Effects Rice','packaging','Bag','qty',5,'weight',10,'rack','R3'))) AS p3 \gset
SELECT public.preview_update_grn(p_grn_id=>:'grn_b'::uuid,
 p_items=>jsonb_build_array(jsonb_build_object('id',:'lot_rice','item_id',:'rice_item','item_name','Effects Rice','packaging','Bag','qty',20,'weight',10,'rack','R3'))) AS p3_up \gset
RESET ROLE;
SELECT pg_temp.eff_assert(:'p3'::jsonb->>'success'='true' AND :'p3'::jsonb->>'preview'='true' AND jsonb_array_length(:'p3'::jsonb->'order_effects')=1
 AND :'p3'::jsonb#>>'{order_effects,0,item_name}'='Effects Rice' AND :'p3'::jsonb#>>'{order_effects,0,change}'='exceeds_stock'
 AND (:'p3'::jsonb#>>'{order_effects,0,old_quantity}')::int=8 AND (:'p3'::jsonb#>>'{order_effects,0,new_quantity}')::int=8
 AND (:'p3'::jsonb#>>'{order_effects,0,available_stock}')::int=5 AND :'p3'::jsonb#>>'{order_effects,0,removed}'='false',
 'the GRN edit preview names the Rice line that asks for more than the lot holds: '||:'p3');
SELECT pg_temp.eff_assert(:'p3_up'::jsonb->>'success'='true' AND :'p3_up'::jsonb->'order_effects'='[]'::jsonb,'raising the quantity names no order line: '||:'p3_up');
SELECT pg_temp.eff_assert(pg_temp.eff_state(:'cart'::uuid)=:'state2','the GRN previews changed nothing: '||pg_temp.eff_state(:'cart'::uuid));
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn_b'::uuid,
 p_items=>jsonb_build_array(jsonb_build_object('id',:'lot_rice','item_id',:'rice_item','item_name','Effects Rice','packaging','Bag','qty',5,'weight',10,'rack','R3'))) AS r3 \gset
RESET ROLE;
SELECT pg_temp.eff_assert(:'r3'::jsonb->>'success'='true' AND (:'r3'::jsonb->'order_effects')=(:'p3'::jsonb->'order_effects'),'the GRN edit answers the effect the preview named: '||:'r3');
SELECT pg_temp.eff_assert((SELECT stock=5 AND qty=5 FROM public.goodsreceived_trl WHERE id=:'lot_rice'::uuid),'the GRN edit stored 5 bags');

-- 5. A GRN delete: the preview names the order lines on its lots; the save answers the same.
SELECT pg_temp.eff_state(:'cart'::uuid) AS state3 \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.preview_delete_grn(:'grn_b'::uuid) AS p4 \gset
RESET ROLE;
SELECT pg_temp.eff_assert(:'p4'::jsonb->>'success'='true' AND :'p4'::jsonb->>'preview'='true' AND jsonb_array_length(:'p4'::jsonb->'order_effects')=1
 AND :'p4'::jsonb#>>'{order_effects,0,item_name}'='Effects Rice' AND :'p4'::jsonb#>>'{order_effects,0,change}'='removed'
 AND (:'p4'::jsonb#>>'{order_effects,0,old_quantity}')::int=8 AND (:'p4'::jsonb#>>'{order_effects,0,new_quantity}')::int=0
 AND :'p4'::jsonb#>>'{order_effects,0,removed}'='true' AND (:'p4'::jsonb#>>'{order_effects,0,order_lines_left}')::int=2,
 'the GRN delete preview names the Rice line as removed: '||:'p4');
SELECT pg_temp.eff_assert(pg_temp.eff_state(:'cart'::uuid)=:'state3' AND EXISTS (SELECT 1 FROM public.goodsreceived WHERE id=:'grn_b'::uuid),'the delete preview changed nothing: '||pg_temp.eff_state(:'cart'::uuid));
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_grn_safe(:'grn_b'::uuid) AS r4 \gset
RESET ROLE;
SELECT pg_temp.eff_assert(:'r4'::jsonb->>'success'='true' AND (:'r4'::jsonb->'order_effects')=(:'p4'::jsonb->'order_effects'),'the GRN delete answers the effect the preview named: '||:'r4');
SELECT pg_temp.eff_assert(NOT EXISTS (SELECT 1 FROM public.order_items WHERE order_id=:'cart'::uuid AND grn_items_item_name='Effects Rice'),'the Rice line is gone');

-- 6. Access. Staff preview a dispatch and a GRN edit but not a GRN delete; a customer account none.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.eff_assert(pg_temp.eff_refused(format('SELECT public.preview_delete_grn(%L::uuid)',:'grn_a')),'staff: no GRN delete preview');
SELECT pg_temp.eff_assert(public.preview_update_grn(p_grn_id=>:'grn_a'::uuid)->>'preview'='true','staff: a GRN edit preview is answered');
RESET ROLE;
SELECT set_config('request.jwt.claims',:'customer_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.eff_assert(pg_temp.eff_refused(format('SELECT public.preview_delete_grn(%L::uuid)',:'grn_a')),'customer: no GRN delete preview');
SELECT pg_temp.eff_assert(pg_temp.eff_refused(format('SELECT public.preview_update_grn(p_grn_id=>%L::uuid)',:'grn_a')),'customer: no GRN edit preview');
SELECT pg_temp.eff_assert(pg_temp.eff_refused(format('SELECT public.preview_update_dispatch(%L::uuid,%L::jsonb,ARRAY[]::jsonb[])',:'disp_1','{}')),'customer: no dispatch edit preview');
SELECT pg_temp.eff_assert(pg_temp.eff_refused(format('SELECT public.preview_create_dispatch(%L::jsonb,ARRAY[]::jsonb[])',:'header')),'customer: no dispatch preview');
RESET ROLE;
SELECT pg_temp.eff_assert(NOT has_function_privilege('anon','public.preview_create_dispatch(jsonb,jsonb[])','EXECUTE')
 AND NOT has_function_privilege('authenticated','warehouse_security.order_effects(uuid[],jsonb,boolean)','EXECUTE')
 AND NOT has_function_privilege('authenticated','warehouse_security.order_lines_snapshot(uuid[])','EXECUTE'),'the previews are for sessions, the helpers for no app role');
ROLLBACK;

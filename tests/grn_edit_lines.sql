-- Migration 40: update_grn can add a line to an existing receipt. Also asserts
-- the guards of update_grn that had no test: quantity and stock of a dispatched
-- lot stay as they are, and a dispatched lot cannot be removed. Fictional data;
-- runs only in migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.edit_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'grn edit lines: %',label; END IF; END $$;
-- True when the statement raises an error whose text matches the pattern.
CREATE FUNCTION pg_temp.edit_raises(statement text, pattern text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE statement; EXCEPTION WHEN OTHERS THEN RETURN SQLERRM LIKE pattern; END;
  RETURN false;
END $$;
CREATE FUNCTION pg_temp.edit_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.edit_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.edit_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888888851','Edit Line Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888852','Edit Line Staff','staff',true,'approved');
SELECT pg_temp.edit_login('9888888851') AS admin_claims \gset
SELECT pg_temp.edit_login('9888888852') AS staff_claims \gset

-- Fixture, as the administrator: receipt EDL1 with a line of 50 bags (10 of
-- them dispatched on EDLD1) and a line of 30 bags that nothing depends on.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.edit_assert(public.create_customer('Edit Line Customer','9888888853')->>'success'='true','customer');
SELECT pg_temp.edit_assert(public.create_item('Edit Line Potatoes','Bag')->>'success'='true','catalog item');
SELECT id AS customer_id FROM public.customers WHERE name='Edit Line Customer' \gset
SELECT id AS item_id FROM public.items WHERE name='Edit Line Potatoes' \gset
SELECT pg_temp.edit_assert(public.save_grn(p_gr_no=>'EDL1',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_id'::uuid,
 p_customer_name=>'Edit Line Customer',p_pricing_mode=>'MONTHLY',p_idempotency_key=>'edit-line-1',
 p_items=>jsonb_build_array(
  jsonb_build_object('item_id',:'item_id','item_name','Edit Line Potatoes','packaging','Bag','qty',50,'weight',10,'rack','R1'),
  jsonb_build_object('item_id',:'item_id','item_name','Edit Line Potatoes','packaging','Bag','qty',30,'weight',10,'rack','R2')))->>'success'='true','receipt EDL1');
SELECT id AS grn_id FROM public.goodsreceived WHERE gr_no='EDL1' \gset
SELECT id AS lot_50 FROM public.goodsreceived_trl WHERE gr_id=:'grn_id'::uuid AND qty=50 \gset
SELECT id AS lot_30 FROM public.goodsreceived_trl WHERE gr_id=:'grn_id'::uuid AND qty=30 \gset
SELECT public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','EDLD1','disp_date','2026-05-02T12:00:00Z',
 'customer_id',:'customer_id','customer_name','Edit Line Customer','supervisor_id',:'admin_profile','supervisor_name','Edit Line Administrator'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_50','disp_qty',10)],0,'edit-line-dispatch') AS dispatched \gset
SELECT pg_temp.edit_assert(:'dispatched'::jsonb->>'success'='true','10 of 50 dispatched: ' || :'dispatched');
SELECT jsonb_build_object('id',:'lot_50','item_id',:'item_id','item_name','Edit Line Potatoes','packaging','Bag','qty',50,'weight',10,'rack','R1') AS line_50 \gset
SELECT jsonb_build_object('id',:'lot_30','item_id',:'item_id','item_name','Edit Line Potatoes','packaging','Bag','qty',30,'weight',10,'rack','R2') AS line_30 \gset
RESET ROLE;
SELECT pg_temp.edit_assert((SELECT qty=50 AND stock=40 FROM public.goodsreceived_trl WHERE id=:'lot_50'::uuid),'fixture: 40 of 50 left');

-- As staff: the two present lines sent again with a third, new line. The new
-- line is stored with its full quantity in stock and reported in item_mapping.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.edit_assert(warehouse_security.active_role()='staff','actual staff role');
SELECT public.update_grn(p_grn_id=>:'grn_id'::uuid,p_note=>'Line added',
 p_items=>jsonb_build_array(:'line_50'::jsonb,:'line_30'::jsonb,
  jsonb_build_object('item_id',:'item_id','item_name','Edit Line Potatoes','packaging','Bag','qty',25,'weight',12,'rack','R3','package_mark','NEW'))) AS added \gset
SELECT pg_temp.edit_assert(:'added'::jsonb->>'success'='true' AND :'added'::jsonb#>>'{stats,items_added}'='1'
 AND :'added'::jsonb#>>'{stats,items_updated}'='2' AND :'added'::jsonb#>>'{stats,items_deleted}'='0'
 AND :'added'::jsonb#>>'{item_mapping,0,index}'='2','staff adds a line to an existing receipt: ' || :'added');
SELECT (:'added'::jsonb#>>'{item_mapping,0,grn_trl_item_id}') AS lot_new \gset
RESET ROLE;
SELECT pg_temp.edit_assert((SELECT count(*)=3 FROM public.goodsreceived_trl WHERE gr_id=:'grn_id'::uuid),'the receipt now has three lines');
SELECT pg_temp.edit_assert((SELECT gr_id=:'grn_id'::uuid AND item_id=:'item_id'::uuid AND item_name='Edit Line Potatoes' AND packaging='Bag'
 AND qty=25 AND stock=25 AND weight=12 AND rack='R3' AND package_mark='NEW'
 FROM public.goodsreceived_trl WHERE id=:'lot_new'::uuid),'the new line is stored with all 25 bags in stock');
SELECT pg_temp.edit_assert((SELECT note='Line added' AND pricing_mode='MONTHLY' FROM public.goodsreceived WHERE id=:'grn_id'::uuid),
 'the header edit is saved with the new line and the pricing mode stays on the header');
SELECT pg_temp.edit_assert((SELECT qty=50 AND stock=40 FROM public.goodsreceived_trl WHERE id=:'lot_50'::uuid)
 AND (SELECT qty=30 AND stock=30 FROM public.goodsreceived_trl WHERE id=:'lot_30'::uuid),'the present lines keep quantity and stock');
SELECT pg_temp.edit_assert((SELECT sum(current_stock)=95 FROM public.mv_customer_stock_summary WHERE customer_id=:'customer_id'::uuid),
 'the customer stock summary counts the new line (40 + 30 + 25)');
SELECT jsonb_build_object('id',:'lot_new','item_id',:'item_id','item_name','Edit Line Potatoes','packaging','Bag','qty',25,'weight',12,'rack','R3','package_mark','NEW') AS line_new \gset

-- A dispatched lot keeps its quantity and stock: asking for 5 bags where 10
-- have left is answered with success, the lot reported in items_skipped_stock
-- and the row unchanged. The undispatched line in the same edit does change.
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn_id'::uuid,
 p_items=>jsonb_build_array(:'line_50'::jsonb || '{"qty":5,"rack":"R9"}'::jsonb,:'line_30'::jsonb || '{"qty":35}'::jsonb,:'line_new'::jsonb)) AS lowered \gset
SELECT pg_temp.edit_assert(:'lowered'::jsonb->>'success'='true' AND jsonb_array_length(:'lowered'::jsonb#>'{stats,items_skipped_stock}')=1
 AND :'lowered'::jsonb#>>'{stats,items_skipped_stock,0,grn_trl_item_id}'=:'lot_50'
 AND :'lowered'::jsonb#>>'{stats,items_skipped_stock,0,dispatched_qty}'='10'
 AND :'lowered'::jsonb#>>'{stats,items_skipped_stock,0,reason}'='Cannot update qty/stock - item has 10 units dispatched',
 'the dispatched lot is reported as skipped: ' || :'lowered');
RESET ROLE;
SELECT pg_temp.edit_assert((SELECT qty=50 AND stock=40 AND rack='R9' FROM public.goodsreceived_trl WHERE id=:'lot_50'::uuid),
 'the dispatched lot keeps quantity 50 and stock 40; its rack does change');
SELECT pg_temp.edit_assert((SELECT qty=35 AND stock=35 FROM public.goodsreceived_trl WHERE id=:'lot_30'::uuid),
 'the undispatched lot takes its new quantity as stock');

-- Raising the quantity of a dispatched lot is skipped in the same way.
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn_id'::uuid,
 p_items=>jsonb_build_array(:'line_50'::jsonb || '{"qty":500,"rack":"R9"}'::jsonb,:'line_30'::jsonb || '{"qty":35}'::jsonb,:'line_new'::jsonb)) AS raised \gset
SELECT pg_temp.edit_assert(:'raised'::jsonb->>'success'='true' AND jsonb_array_length(:'raised'::jsonb#>'{stats,items_skipped_stock}')=1,
 'a raised quantity on a dispatched lot is skipped too: ' || :'raised');
RESET ROLE;
SELECT pg_temp.edit_assert((SELECT qty=50 AND stock=40 FROM public.goodsreceived_trl WHERE id=:'lot_50'::uuid),'still 40 of 50');

-- Leaving the dispatched lot out of the list would delete it: refused, and the
-- note and the other lines of that edit roll back with it.
SET LOCAL ROLE authenticated;
SELECT pg_temp.edit_assert(pg_temp.edit_raises(format(
 'SELECT public.update_grn(p_grn_id=>%L::uuid,p_note=>''Must roll back'',p_items=>%L::jsonb)',
 :'grn_id',jsonb_build_array(:'line_30'::jsonb || '{"qty":1}'::jsonb,:'line_new'::jsonb)::text),
 'Cannot delete item "Edit Line Potatoes" - has 1 existing dispatches'),'a dispatched lot cannot be removed');
RESET ROLE;
SELECT pg_temp.edit_assert((SELECT count(*)=3 FROM public.goodsreceived_trl WHERE gr_id=:'grn_id'::uuid),'the refused removal leaves three lines');
SELECT pg_temp.edit_assert((SELECT qty=50 AND stock=40 FROM public.goodsreceived_trl WHERE id=:'lot_50'::uuid)
 AND (SELECT qty=35 AND stock=35 FROM public.goodsreceived_trl WHERE id=:'lot_30'::uuid),'the refused removal changes no quantity');
SELECT pg_temp.edit_assert((SELECT note='Line added' FROM public.goodsreceived WHERE id=:'grn_id'::uuid),'the refused removal leaves the note');
SELECT pg_temp.edit_assert((SELECT count(*)=1 AND bool_and(disp_qty=10) FROM public.dispatch_trl WHERE gr_trl_id=:'lot_50'::uuid),'the dispatch line is untouched');
SELECT pg_temp.edit_assert((SELECT bool_and(tgenabled='O') FROM pg_trigger WHERE tgrelid='public.goodsreceived_trl'::regclass AND tgname='trg_mark_stock_mvs_dirty_grn'),
 'the refused edit leaves the item triggers enabled');

-- A line nothing depends on can still be removed (the line added above).
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn_id'::uuid,
 p_items=>jsonb_build_array(:'line_50'::jsonb,:'line_30'::jsonb || '{"qty":35}'::jsonb)) AS removed \gset
SELECT pg_temp.edit_assert(:'removed'::jsonb->>'success'='true' AND :'removed'::jsonb#>>'{stats,items_deleted}'='1','an undispatched line is removed: ' || :'removed');
RESET ROLE;
SELECT pg_temp.edit_assert((SELECT count(*)=0 FROM public.goodsreceived_trl WHERE id=:'lot_new'::uuid)
 AND (SELECT count(*)=2 FROM public.goodsreceived_trl WHERE gr_id=:'grn_id'::uuid),'two lines remain');
SELECT pg_temp.edit_assert((SELECT sum(current_stock)=75 FROM public.mv_customer_stock_summary WHERE customer_id=:'customer_id'::uuid),
 'the customer stock summary follows (40 + 35)');
ROLLBACK;
\echo 'GRN edit: adding a line, dispatched-lot quantity and removal guards passed.'

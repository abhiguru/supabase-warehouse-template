-- Migration 46: the refresh lock before any row lock, idempotency keys bound to
-- their function and user, quantity, weight and blank-number rules, the
-- receipt's customer name, the order history of a deleted receipt, the strict
-- role check of dispatch deletion, literal field filters, and the removal of
-- four uncalled dispatch functions. tests/grn_edit_lock_order.sh runs the
-- two-session part. Fictional data; runs only in migrations.sh's disposable,
-- network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.dw_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'document write consistency: %',label; END IF; END $$;
-- True when the statement raises an error whose text matches the pattern.
CREATE FUNCTION pg_temp.dw_raises(statement text, pattern text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE statement; EXCEPTION WHEN OTHERS THEN RETURN SQLERRM LIKE pattern; END;
  RETURN false;
END $$;
CREATE FUNCTION pg_temp.dw_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.dw_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.dw_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;

-- 1. Lock order, by definition. Every function an API role may call that
-- writes one of the five tables with a list-refresh trigger takes the lock
-- itself; in the two that lock rows explicitly the lock comes first.
SELECT pg_temp.dw_assert(count(*)=0,'granted writers without the refresh lock: ' || COALESCE(string_agg(p.oid::regprocedure::text,', '),''))
FROM pg_proc p
WHERE p.pronamespace='public'::regnamespace AND has_function_privilege('authenticated',p.oid,'EXECUTE')
  AND p.prosrc ~* '(update|delete from|insert into)\s+(only\s+)?(public\.)?(goodsreceived|goodsreceived_trl|dispatch|dispatch_trl|customers)\M'
  AND position('pg_advisory_xact_lock(71040)' IN p.prosrc)=0;
SELECT pg_temp.dw_assert(position('pg_advisory_xact_lock(71040)' IN p.prosrc) BETWEEN 1 AND position('FOR UPDATE OF gt' IN p.prosrc)
  AND position('pg_advisory_xact_lock(71040)' IN p.prosrc) < position('FOR KEY SHARE' IN p.prosrc),
  'dispatch creation takes the refresh lock before its row locks')
FROM pg_proc p WHERE p.oid='public.create_dispatch_with_stock_check_internal(jsonb,jsonb[],boolean,text)'::regprocedure;
SELECT pg_temp.dw_assert(position('pg_advisory_xact_lock(71040)' IN p.prosrc) BETWEEN 1 AND position('FOR KEY SHARE' IN p.prosrc)
  AND position('pg_advisory_xact_lock(71040)' IN p.prosrc) < position('UPDATE dispatch SET' IN p.prosrc),
  'dispatch edit takes the refresh lock before its row locks')
FROM pg_proc p WHERE p.oid='public.update_dispatch_smart(uuid,jsonb,jsonb[])'::regprocedure;
SELECT pg_temp.dw_assert(position('pg_advisory_xact_lock(71040)' IN p.prosrc) BETWEEN 1 AND position('UPDATE orders' IN p.prosrc)
  AND position('is_admin_or_supervisor_strict()' IN p.prosrc)>0 AND position('user_accessible_customers()' IN p.prosrc)=0
  AND p.prosrc !~ 'is_admin_or_supervisor\(\)',
  'dispatch deletion takes the refresh lock first and checks for administrator or supervisor only')
FROM pg_proc p WHERE p.oid='public.delete_dispatch_with_order_cleanup(uuid,uuid)'::regprocedure;

-- 9. The uncalled functions are gone; the two granted wrappers remain.
SELECT pg_temp.dw_assert(
 to_regprocedure('public.create_dispatch_with_stock_check_2arg_internal(jsonb,jsonb[])') IS NULL
 AND to_regprocedure('public.create_dispatch_with_stock_check_internal_3param(jsonb,jsonb[],integer)') IS NULL
 AND to_regprocedure('public.create_dispatch_with_stock_check_internal_4param(jsonb,jsonb[],boolean,integer)') IS NULL
 AND to_regprocedure('public.create_dispatch_with_stock_check_internal(jsonb,jsonb[],boolean)') IS NULL,
 'uncalled dispatch functions removed');
SELECT pg_temp.dw_assert((SELECT count(*)=2 AND bool_and(has_function_privilege('authenticated',oid,'EXECUTE')) FROM pg_proc
 WHERE pronamespace='public'::regnamespace AND proname='create_dispatch_with_stock_check'),'both granted wrappers remain');
SELECT pg_temp.dw_assert(NOT has_function_privilege('authenticated','warehouse_security.is_blank_text(text)','EXECUTE')
 AND NOT has_function_privilege('authenticated','warehouse_security.like_literal(text)','EXECUTE'),'helpers are not API functions');
SELECT pg_temp.dw_assert(warehouse_security.is_blank_text(NULL) AND warehouse_security.is_blank_text('')
 AND warehouse_security.is_blank_text(E' \t\n') AND warehouse_security.is_blank_text(U&'\00A0\200B\FEFF\3000')
 AND NOT warehouse_security.is_blank_text(U&'\00A0A1\200B') AND NOT warehouse_security.is_blank_text('0'),'blank text');

INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888888601','Consistency Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888602','Consistency Staff One','staff',true,'approved'),
 (gen_random_uuid(),'919888888603','Consistency Staff Two','staff',true,'approved'),
 (gen_random_uuid(),'919888888604','Consistency Client','customer',true,'approved');
SELECT id AS staff_one_profile FROM public.user_profiles WHERE mobile='919888888602' \gset
SELECT set_config('test.dw_supervisor',:'admin_profile',true);
SELECT pg_temp.dw_login('9888888601') AS admin_claims \gset
SELECT pg_temp.dw_login('9888888602') AS staff_one_claims \gset
SELECT pg_temp.dw_login('9888888603') AS staff_two_claims \gset
SELECT pg_temp.dw_login('9888888604') AS client_claims \gset

SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.dw_assert(public.create_customer('Consistency Orchard','9888888611')->>'success'='true','customer one');
SELECT pg_temp.dw_assert(public.create_customer('Consistency Dairy','9888888612')->>'success'='true','customer two');
SELECT pg_temp.dw_assert(public.create_item('Consistency Apples','Box')->>'success'='true','catalog item');
RESET ROLE;
SELECT id AS orchard FROM public.customers WHERE name='Consistency Orchard' \gset
SELECT id AS dairy FROM public.customers WHERE name='Consistency Dairy' \gset
SELECT id AS item_id FROM public.items WHERE name='Consistency Apples' \gset
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active)
 SELECT id,:'orchard'::uuid,true FROM public.user_profiles WHERE mobile='919888888604';
SELECT jsonb_build_object('item_id',:'item_id','item_name','Consistency Apples','packaging','Box','qty',20,'weight',5) AS line \gset
CREATE FUNCTION pg_temp.dw_save(gr_no text, customer uuid, sent_name text, lines jsonb, key text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.save_grn(p_gr_no=>gr_no,p_date=>'2026-04-01T12:00:00Z',p_customer_id=>customer,p_customer_name=>sent_name,
    p_pricing_mode=>'MONTHLY',p_items=>lines,p_idempotency_key=>key) $$;

-- 3 to 5. Receipt creation, as staff one.
SELECT set_config('request.jwt.claims',:'staff_one_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.dw_assert(pg_temp.dw_save('DWC0',:'orchard','Consistency Orchard',jsonb_build_array(:'line'::jsonb || '{"qty":0}'),NULL)->>'message'
 LIKE '%Quantity must be greater than 0%','a line with quantity 0 is refused');
SELECT pg_temp.dw_assert(pg_temp.dw_save('DWC0',:'orchard','Consistency Orchard',jsonb_build_array(:'line'::jsonb || '{"weight":-1}'),NULL)->>'message'
 LIKE '%Weight cannot be negative%','a negative weight is refused');
SELECT pg_temp.dw_assert(pg_temp.dw_save('DWC0',:'orchard','Consistency Orchard',jsonb_build_array(:'line'::jsonb || '{"weight":0}'),NULL)->>'success'='true',
 'a weight of 0 (none recorded) is accepted');
SELECT pg_temp.dw_assert(bool_and(pg_temp.dw_save(blank.gr_no,:'orchard','Consistency Orchard',jsonb_build_array(:'line'::jsonb),NULL)->>'message'
 LIKE 'Missing required parameters%'),'a receipt number of invisible characters is refused')
FROM (VALUES (E'\t'),(U&'\00A0'),(U&'\200B\FEFF'),(U&' \3000 ')) AS blank(gr_no);
-- The name sent by the client is not stored; the customer record's name is.
SELECT pg_temp.dw_save('DWC1',:'orchard','Consistency Dairy',jsonb_build_array(:'line'::jsonb),'dw-grn-key') AS saved \gset
SELECT pg_temp.dw_assert(:'saved'::jsonb->>'success'='true','receipt DWC1: ' || :'saved');
RESET ROLE;
SELECT pg_temp.dw_assert((SELECT count(*)=2 FROM public.goodsreceived WHERE gr_no LIKE 'DWC%'),'refused receipts stored nothing');
SELECT pg_temp.dw_assert((SELECT customer_name='Consistency Orchard' FROM public.goodsreceived WHERE gr_no='DWC1'),'receipt carries the customer record''s name');
SELECT id AS grn_1 FROM public.goodsreceived WHERE gr_no='DWC1' \gset
SELECT id AS lot_1 FROM public.goodsreceived_trl WHERE gr_id=:'grn_1'::uuid \gset
SELECT pg_temp.dw_assert(pg_temp.dw_raises($s$INSERT INTO public.goodsreceived(gr_no,date,customer_id,customer_name) SELECT U&'\00A0\200B',now(),id,name FROM public.customers WHERE name='Consistency Orchard'$s$,
 '%goodsreceived_gr_no_not_blank%'),'the receipt table refuses a number of invisible characters');
SELECT pg_temp.dw_assert(pg_temp.dw_raises($s$INSERT INTO public.dispatch(disp_no,disp_date,customer_id,customer_name) SELECT E'\t ',now(),id,name FROM public.customers WHERE name='Consistency Orchard'$s$,
 '%dispatch_disp_no_not_blank%'),'the dispatch table refuses a number of invisible characters');

-- 2. Idempotency. Staff one's retry is answered from the key.
SELECT set_config('request.jwt.claims',:'staff_one_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.dw_assert(pg_temp.dw_save('DWC1',:'orchard','Consistency Orchard',jsonb_build_array(:'line'::jsonb),'dw-grn-key')
 @> jsonb_build_object('success',true,'idempotent',true,'data',jsonb_build_object('grn_id',:'grn_1')),'the owner''s retry is answered from the key');
-- Staff two presents the same key with another receipt: it is saved, not skipped.
SELECT set_config('request.jwt.claims',:'staff_two_claims',true);
SELECT pg_temp.dw_save('DWC2',:'dairy','Consistency Dairy',jsonb_build_array(:'line'::jsonb),'dw-grn-key') AS other \gset
SELECT pg_temp.dw_assert(:'other'::jsonb->>'success'='true' AND NOT :'other'::jsonb ? 'idempotent' AND :'other'::jsonb#>>'{data,gr_no}'='DWC2',
 'another user''s save with the same key is carried out: ' || :'other');
RESET ROLE;
SELECT id AS grn_2 FROM public.goodsreceived WHERE gr_no='DWC2' \gset
SELECT id AS lot_2 FROM public.goodsreceived_trl WHERE gr_id=:'grn_2'::uuid \gset
SELECT pg_temp.dw_assert(:'grn_2' <> :'grn_1','receipt DWC2 exists');

CREATE FUNCTION pg_temp.dw_dispatch(disp_no text, customer uuid, lot uuid, quantity numeric, key text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.create_dispatch_with_stock_check(jsonb_build_object('disp_no',disp_no,'disp_date','2026-05-02T12:00:00Z',
    'customer_id',customer,'customer_name','Consistency','supervisor_id',current_setting('test.dw_supervisor'),
    'supervisor_name','Consistency Administrator'),ARRAY[jsonb_build_object('gr_trl_id',lot,'disp_qty',quantity)],0,key) $$;
SELECT set_config('request.jwt.claims',:'staff_one_claims',true);
SET LOCAL ROLE authenticated;
-- A key that save_grn stored does not answer a dispatch.
SELECT pg_temp.dw_dispatch('DWD1',:'orchard',:'lot_1',4,'dw-grn-key') AS first \gset
SELECT pg_temp.dw_assert(:'first'::jsonb->>'success'='true' AND NOT :'first'::jsonb ? 'from_cache' AND :'first'::jsonb ? 'dispatch_id',
 'a receipt key does not answer a dispatch: ' || :'first');
SELECT pg_temp.dw_dispatch('DWD2',:'orchard',:'lot_1',3,'dw-dispatch-key') AS second \gset
SELECT pg_temp.dw_assert(:'second'::jsonb->>'success'='true' AND NOT :'second'::jsonb ? 'from_cache','dispatch DWD2: ' || :'second');
SELECT pg_temp.dw_assert(pg_temp.dw_dispatch('DWD2',:'orchard',:'lot_1',3,'dw-dispatch-key')
 @> jsonb_build_object('from_cache',true,'dispatch_id',:'second'::jsonb->>'dispatch_id'),'the owner''s dispatch retry is answered from the key');
-- Staff two presents staff one's dispatch key with another dispatch.
SELECT set_config('request.jwt.claims',:'staff_two_claims',true);
SELECT pg_temp.dw_dispatch('DWD3',:'dairy',:'lot_2',2,'dw-dispatch-key') AS third \gset
SELECT pg_temp.dw_assert(:'third'::jsonb->>'success'='true' AND NOT :'third'::jsonb ? 'from_cache'
 AND :'third'::jsonb->>'dispatch_id' <> :'second'::jsonb->>'dispatch_id','another user''s dispatch with the same key is carried out: ' || :'third');
-- The five-argument wrapper still reaches the same body.
SELECT pg_temp.dw_assert(public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','DWD4','disp_date','2026-05-02T12:00:00Z',
 'customer_id',:'dairy','customer_name','Consistency Dairy','supervisor_id',:'admin_profile','supervisor_name','Consistency Administrator'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_2','disp_qty',1)],false,0,NULL)->>'success'='true','five-argument wrapper');
RESET ROLE;
SELECT pg_temp.dw_assert((SELECT count(*)=1 AND bool_and(rpc_function='save_grn' AND created_by=:'staff_one_profile'::uuid)
 FROM public.idempotency_keys WHERE idempotency_key='dw-grn-key'),'the receipt key still belongs to its first user');
SELECT pg_temp.dw_assert((SELECT count(*)=1 AND bool_and(created_by=:'staff_one_profile'::uuid AND response->>'dispatch_id'=:'second'::jsonb->>'dispatch_id'
 AND expires_at > now()+interval '23 hours' AND expires_at <= now()+interval '24 hours')
 FROM public.idempotency_keys WHERE idempotency_key='dw-dispatch-key'),'the dispatch key keeps its owner and lasts the 24 hours it is honoured');
SELECT pg_temp.dw_assert((SELECT stock=13 FROM public.goodsreceived_trl WHERE id=:'lot_1'::uuid)
 AND (SELECT stock=17 FROM public.goodsreceived_trl WHERE id=:'lot_2'::uuid),'stock left once per dispatch: 20-4-3 and 20-2-1');

-- 4. A blank dispatch number is a validation error at creation.
SELECT set_config('request.jwt.claims',:'staff_one_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.dw_dispatch(U&'\00A0 ',:'orchard',:'lot_1',1,NULL) AS blank_dispatch \gset
SELECT pg_temp.dw_assert(:'blank_dispatch'::jsonb->>'error'='Invalid dispatch data'
 AND :'blank_dispatch'::jsonb->'validation_errors' @> '[{"field":"disp_no","error":"disp_no is required"}]',
 'blank dispatch number is a validation error: ' || :'blank_dispatch');

-- 3 and 4. Dispatch edit (DWD2: 3 boxes of lot 1).
SELECT (:'second'::jsonb->>'dispatch_id') AS dispatch_2 \gset
CREATE FUNCTION pg_temp.dw_edit(dispatch uuid, header jsonb, lines jsonb[]) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(r->>'error','saved') FROM public.update_dispatch_smart(dispatch,header,lines) AS r $$;
SELECT pg_temp.dw_assert(pg_temp.dw_edit(:'dispatch_2',NULL,ARRAY[jsonb_build_object('gr_trl_id',:'lot_1','disp_qty',0)])
 ='Dispatch quantity must be a whole number greater than 0','quantity 0 refused');
SELECT pg_temp.dw_assert(pg_temp.dw_edit(:'dispatch_2',NULL,ARRAY[jsonb_build_object('gr_trl_id',:'lot_1','disp_qty',1.5)])
 ='Dispatch quantity must be a whole number greater than 0','fractional quantity refused');
SELECT pg_temp.dw_assert(pg_temp.dw_edit(:'dispatch_2',NULL,ARRAY[jsonb_build_object('gr_trl_id',:'lot_1')])
 ='Dispatch quantity must be a whole number greater than 0','missing quantity refused');
SELECT pg_temp.dw_assert(pg_temp.dw_edit(:'dispatch_2',NULL,ARRAY[jsonb_build_object('gr_trl_id',:'lot_1','disp_qty',3),
 jsonb_build_object('gr_trl_id',gen_random_uuid(),'disp_qty',1)])='Dispatch item does not exist in inventory','unknown lot refused, not dropped');
SELECT pg_temp.dw_assert(pg_temp.dw_edit(:'dispatch_2',jsonb_build_object('disp_no',E'\t','note','blank number'),NULL)='disp_no is required','blank number refused on edit');
RESET ROLE;
SELECT pg_temp.dw_assert((SELECT disp_no='DWD2' AND note IS DISTINCT FROM 'blank number' FROM public.dispatch WHERE id=:'dispatch_2'::uuid)
 AND (SELECT count(*)=1 AND bool_and(disp_qty=3) FROM public.dispatch_trl WHERE disp_id=:'dispatch_2'::uuid)
 AND (SELECT stock=13 FROM public.goodsreceived_trl WHERE id=:'lot_1'::uuid),'refused edits changed nothing');
SELECT set_config('request.jwt.claims',:'staff_one_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.dw_assert(pg_temp.dw_edit(:'dispatch_2',jsonb_build_object('note','five now'),ARRAY[jsonb_build_object('gr_trl_id',:'lot_1','disp_qty',5)])='saved','a valid edit is saved');
RESET ROLE;
SELECT pg_temp.dw_assert((SELECT bool_and(disp_qty=5) FROM public.dispatch_trl WHERE disp_id=:'dispatch_2'::uuid)
 AND (SELECT stock=11 FROM public.goodsreceived_trl WHERE id=:'lot_1'::uuid),'the valid edit moved two more boxes');
SELECT set_config('request.jwt.claims',:'staff_one_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.dw_assert(pg_temp.dw_edit(:'dispatch_2',NULL,ARRAY[]::jsonb[])='saved','an empty list still removes every line');
RESET ROLE;
SELECT pg_temp.dw_assert((SELECT count(*)=0 FROM public.dispatch_trl WHERE disp_id=:'dispatch_2'::uuid)
 AND (SELECT stock=16 FROM public.goodsreceived_trl WHERE id=:'lot_1'::uuid),'the emptied dispatch returned its five boxes');

-- 3 to 5. Receipt edit. DWC3 has no dispatch, invoice or cart line.
SELECT set_config('request.jwt.claims',:'staff_one_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.dw_assert(pg_temp.dw_save('DWC3',:'orchard','Consistency Orchard',jsonb_build_array(:'line'::jsonb),NULL)->>'success'='true','receipt DWC3');
RESET ROLE;
SELECT id AS grn_3 FROM public.goodsreceived WHERE gr_no='DWC3' \gset
SELECT id AS lot_3 FROM public.goodsreceived_trl WHERE gr_id=:'grn_3'::uuid \gset
SELECT (:'line'::jsonb || jsonb_build_object('id',:'lot_3')) AS line_3 \gset
SELECT set_config('request.jwt.claims',:'staff_one_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.dw_assert(public.update_grn(p_grn_id=>:'grn_3'::uuid,p_gr_no=>U&'\00A0\200B')->>'message'='GRN number is required','blank number refused on receipt edit');
SELECT pg_temp.dw_assert(pg_temp.dw_raises(format($s$SELECT public.update_grn(p_grn_id=>%L::uuid,p_items=>%L::jsonb)$s$,:'grn_3',
 jsonb_build_array(:'line_3'::jsonb || '{"qty":0}')),'%Quantity must be greater than 0%'),'receipt edit refuses quantity 0');
SELECT pg_temp.dw_assert(pg_temp.dw_raises(format($s$SELECT public.update_grn(p_grn_id=>%L::uuid,p_items=>%L::jsonb)$s$,:'grn_3',
 jsonb_build_array(:'line_3'::jsonb, :'line'::jsonb || '{"weight":-5}')),'%Weight cannot be negative%'),'receipt edit refuses a negative weight on a new line');
-- Same customer, another name sent: the stored name stays.
SELECT pg_temp.dw_assert(public.update_grn(p_grn_id=>:'grn_3'::uuid,p_customer_id=>:'orchard'::uuid,p_customer_name=>'Consistency Dairy',
 p_note=>'name sent',p_items=>jsonb_build_array(:'line_3'::jsonb))->>'success'='true','edit sending another name');
RESET ROLE;
SELECT pg_temp.dw_assert((SELECT customer_name='Consistency Orchard' AND note='name sent' AND gr_no='DWC3' FROM public.goodsreceived WHERE id=:'grn_3'::uuid)
 AND (SELECT count(*)=1 AND bool_and(qty=20 AND weight=5) FROM public.goodsreceived_trl WHERE gr_id=:'grn_3'::uuid),'the sent name is not stored and refused edits changed nothing');
-- Another customer: the name follows the customer record, not the client.
SELECT set_config('request.jwt.claims',:'staff_one_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.dw_assert(public.update_grn(p_grn_id=>:'grn_3'::uuid,p_customer_id=>:'dairy'::uuid,p_customer_name=>'Consistency Orchard',
 p_items=>jsonb_build_array(:'line_3'::jsonb))->>'success'='true','edit moving the receipt to another customer');
RESET ROLE;
SELECT pg_temp.dw_assert((SELECT customer_id=:'dairy'::uuid AND customer_name='Consistency Dairy' FROM public.goodsreceived WHERE id=:'grn_3'::uuid),
 'a moved receipt takes the new customer record''s name');

-- 6. Deleting a receipt whose lot is in a cart. DWC4 belongs to the client's customer.
SELECT set_config('request.jwt.claims',:'staff_one_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.dw_assert(pg_temp.dw_save('DWC4',:'orchard','Consistency Orchard',jsonb_build_array(:'line'::jsonb || '{"package_mark":"CART"}'),NULL)->>'success'='true','receipt DWC4');
RESET ROLE;
SELECT id AS grn_4 FROM public.goodsreceived WHERE gr_no='DWC4' \gset
SELECT id AS lot_4 FROM public.goodsreceived_trl WHERE gr_id=:'grn_4'::uuid \gset
SELECT set_config('request.jwt.claims',:'client_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'orchard'::uuid) AS cart \gset
SELECT pg_temp.dw_assert(public.add_item_to_order(:'cart'::uuid,:'lot_4'::uuid,6)->>'success'='true','client puts 6 boxes of DWC4 in the cart');
SELECT pg_temp.dw_assert(public.add_item_to_order(:'cart'::uuid,:'lot_1'::uuid,2)->>'success'='true','and 2 boxes of DWC1');
RESET ROLE;
SELECT count(*) AS revisions_before FROM public.order_revisions WHERE order_id=:'cart'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_grn_safe(:'grn_4'::uuid) AS deleted \gset
SELECT pg_temp.dw_assert(:'deleted'::jsonb->>'success'='true' AND :'deleted'::jsonb#>>'{deleted_counts,order_items}'='1','receipt DWC4 deleted: ' || :'deleted');
RESET ROLE;
SELECT pg_temp.dw_assert((SELECT count(*)=1 AND bool_and(grn_items_id=:'lot_1'::uuid) FROM public.order_items WHERE order_id=:'cart'::uuid),'the cart keeps only the DWC1 line');
SELECT pg_temp.dw_assert((SELECT count(*)=:revisions_before+1 FROM public.order_revisions WHERE order_id=:'cart'::uuid)
 AND (SELECT count(*)=1 AND bool_and(changed_by=:'admin_profile'::uuid AND entry->>'action'='grn_deleted'
   AND entry->'cart_items' @> '[{"grn_no":"DWC4","package_mark":"CART","quantity":0,"item_name":"Consistency Apples"}]'
   AND entry->'cart_items' @> '[{"grn_no":"DWC1","quantity":2}]' AND jsonb_array_length(entry->'cart_items')=2)
   FROM public.order_revisions WHERE order_id=:'cart'::uuid AND action='grn_deleted'),
 'the order history records the removed line at quantity 0: ' || COALESCE((SELECT entry::text FROM public.order_revisions
   WHERE order_id=:'cart'::uuid ORDER BY id DESC LIMIT 1),'none'));
-- A receipt in no cart leaves no history entry.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.dw_assert(public.delete_grn_safe(:'grn_3'::uuid)->>'success'='true','receipt DWC3 deleted');
-- 7. An administrator still deletes a dispatch; staff are stopped by the guard.
SELECT pg_temp.dw_assert(public.delete_dispatch_with_order_cleanup(:'dispatch_2'::uuid,:'admin_profile'::uuid)->>'success'='true','administrator deletes a dispatch');
SELECT set_config('request.jwt.claims',:'staff_one_claims',true);
SELECT pg_temp.dw_assert(public.delete_dispatch_with_order_cleanup((:'first'::jsonb->>'dispatch_id')::uuid,:'staff_one_profile'::uuid)
 @> '{"success":false,"error":"Staff access required"}','staff cannot delete a dispatch');
RESET ROLE;
SELECT pg_temp.dw_assert((SELECT count(*)=1 FROM public.dispatch WHERE id=(:'first'::jsonb->>'dispatch_id')::uuid)
 AND (SELECT count(*)=0 FROM public.dispatch WHERE id=:'dispatch_2'::uuid),'the refused dispatch is still there and the deleted one is gone');
SELECT pg_temp.dw_assert((SELECT count(*)=1 FROM public.order_revisions WHERE action='grn_deleted'),'only the cart that lost a line got an entry');

-- 8. Field filters take what was typed literally. DWC5 has three lots whose
-- marks and racks differ only where a wildcard would not notice.
SELECT set_config('request.jwt.claims',:'staff_one_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.dw_assert(pg_temp.dw_save('DWC_5',:'orchard','Consistency Orchard',jsonb_build_array(
 :'line'::jsonb || '{"package_mark":"MK_50%","rack":"R7\\A"}',
 :'line'::jsonb || '{"package_mark":"MKX50Z","rack":"R7A"}',
 :'line'::jsonb || '{"package_mark":"MK-50","rack":"R8"}'),NULL)->>'success'='true','receipt DWC_5');
CREATE FUNCTION pg_temp.dw_marks(result jsonb) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(m ORDER BY m COLLATE "C"),'{}') FROM (SELECT DISTINCT x#>>'{}' AS m FROM jsonb_path_query(result,'$.**.package_mark') AS x) s WHERE m LIKE 'MK%' $$;
CREATE FUNCTION pg_temp.dw_staff(filters jsonb) RETURNS text[] LANGUAGE sql AS $$
  SELECT pg_temp.dw_marks(public.get_all_grn_items(p_filters=>filters,p_limit=>100,p_offset=>0)) $$;
SELECT pg_temp.dw_assert(pg_temp.dw_staff('{"package_mark":"mk"}')=ARRAY['MK-50','MKX50Z','MK_50%'],'staff package filter, part of the mark: ' || pg_temp.dw_staff('{"package_mark":"mk"}')::text);
SELECT pg_temp.dw_assert(pg_temp.dw_staff('{"package_mark":"MK_50"}')=ARRAY['MK_50%'],'staff package filter takes underscore literally: ' || pg_temp.dw_staff('{"package_mark":"MK_50"}')::text);
SELECT pg_temp.dw_assert(pg_temp.dw_staff('{"package_mark":"0%"}')=ARRAY['MK_50%'],'staff package filter takes percent literally');
SELECT pg_temp.dw_assert(pg_temp.dw_staff('{"package_mark":"50\\"}')='{}','staff package filter takes a trailing backslash literally');
SELECT set_config('request.jwt.claims',:'client_claims',true);
CREATE FUNCTION pg_temp.dw_mine(filters jsonb) RETURNS text[] LANGUAGE sql AS $$
  SELECT pg_temp.dw_marks(public.get_customer_grn_items(p_customer_id=>(SELECT id FROM public.customers WHERE name='Consistency Orchard'),
    p_filters=>filters,p_limit=>100,p_offset=>0)) $$;
SELECT pg_temp.dw_assert(pg_temp.dw_mine('{}')=ARRAY['MK-50','MKX50Z','MK_50%'],'client sees the three lots: ' || pg_temp.dw_mine('{}')::text);
SELECT pg_temp.dw_assert(pg_temp.dw_mine('{"package_mark":"mk_50"}')=ARRAY['MK_50%'],'client package filter takes underscore literally: ' || pg_temp.dw_mine('{"package_mark":"mk_50"}')::text);
SELECT pg_temp.dw_assert(pg_temp.dw_mine('{"package_mark":"%"}')=ARRAY['MK_50%'],'client package filter takes percent literally');
SELECT pg_temp.dw_assert(pg_temp.dw_mine('{"rack":"r7\\"}')=ARRAY['MK_50%'],'client rack filter takes a backslash literally: ' || pg_temp.dw_mine('{"rack":"r7\\"}')::text);
SELECT pg_temp.dw_assert(pg_temp.dw_mine('{"rack":"r7"}')=ARRAY['MKX50Z','MK_50%'],'client rack filter, part of the rack');
SELECT pg_temp.dw_assert(pg_temp.dw_mine('{"gr_no":"dwc_5"}')=ARRAY['MK-50','MKX50Z','MK_50%'] AND pg_temp.dw_mine('{"gr_no":"dwc%5"}')='{}'
 AND pg_temp.dw_mine('{"gr_no":"dw__5"}')='{}','client receipt-number filter is literal');
SELECT pg_temp.dw_assert(pg_temp.dw_mine('{"item_name":"apples"}')=ARRAY['MK-50','MKX50Z','MK_50%'] AND pg_temp.dw_mine('{"item_name":"consistency_apples"}')='{}'
 AND pg_temp.dw_mine('{"item_name":"%"}')='{}','client item filter is literal');
SELECT pg_temp.dw_assert(pg_temp.dw_mine('{"customer_name":"orchard"}')=ARRAY['MK-50','MKX50Z','MK_50%'] AND pg_temp.dw_mine('{"customer_name":"consistency_orchard"}')='{}',
 'client customer-name filter is literal');
RESET ROLE;
ROLLBACK;
SELECT 'document write lock order, idempotency, input rules, order history and literal filters passed' AS result;

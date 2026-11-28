-- WH-303 (contract ~/ws/fresh/product/tech/app-offline-edit-grn.md, 5.3, 5.7; Product PQ3, cases U4 and B4): the quantity of a lot on a
-- live invoice is locked, online (update_grn) and by the offline edit (apply_grn_changes): LOT_INVOICED with "qty" among the
-- fields, checked BEFORE the dispatched-quantity rule (the lot here is fully dispatched, so a lower quantity would otherwise be
-- QTY_BELOW_DISPATCHED). Nothing of the refused save is written. A quantity sent unchanged is no change and is not refused.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database; rolls back.
--
-- AGREE WITH DEVELOPMENT (WH-303): apply_grn_changes(p_grn_id, p_changes, p_request_key) and the body of contract 3.2
-- (v, grnId, loadedAt, recordedAt, lots{lotId:{qty:{from,to}}}); refusals read as update_grn's (top-level reason, fields, message).
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.qi_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'grn qty invoiced lock: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.qi_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.qi_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.qi_assert(l#>>'{data,action}'='login','login for '||phone);
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
SELECT warehouse_security.bootstrap_first_admin('9888897801','Qty Lock Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
SELECT pg_temp.qi_login('9888897801') AS admin_claims \gset

SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.qi_assert(public.create_customer('Qty Lock Customer','9888897802')->>'success'='true','customer');
SELECT pg_temp.qi_assert(public.create_item('Qty Lock Turmeric','Bag')->>'success'='true','catalog item');
SELECT id AS customer_id FROM public.customers WHERE name='Qty Lock Customer' \gset
SELECT id AS item_id FROM public.items WHERE name='Qty Lock Turmeric' \gset
SELECT pg_temp.qi_assert(public.save_grn(p_sender_name=>'Fixture Sender',p_supervisor_id=>:'admin_profile'::uuid,p_supervisor_name=>'Fixture Supervisor',p_gr_no=>'QIL1',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_id'::uuid,
 p_customer_name=>'Qty Lock Customer',p_pricing_mode=>'MONTHLY',p_idempotency_key=>'qty-lock-1',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Qty Lock Turmeric','packaging','Bag','qty',10,'weight',10,'rack','R1')))->>'success'='true','receipt QIL1');
SELECT id AS grn_id FROM public.goodsreceived WHERE gr_no='QIL1' \gset
SELECT id AS lot FROM public.goodsreceived_trl WHERE gr_id=:'grn_id'::uuid \gset
SELECT public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','QILD1','disp_date','2026-06-01T12:00:00Z',
 'customer_id',:'customer_id','customer_name','Qty Lock Customer','supervisor_id',:'admin_profile','supervisor_name','Qty Lock Administrator'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot','disp_qty',4)],0,'qty-lock-d1')->>'success' AS d1 \gset
SELECT public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','QILD2','disp_date','2026-06-01T12:00:00Z',
 'customer_id',:'customer_id','customer_name','Qty Lock Customer','supervisor_id',:'admin_profile','supervisor_name','Qty Lock Administrator'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot','disp_qty',6)],0,'qty-lock-d2')->>'success' AS d2 \gset
SELECT pg_temp.qi_assert(:'d1'='true' AND :'d2'='true','the 10 bags are dispatched in two goes');
SELECT id AS disp_line FROM public.dispatch_trl WHERE gr_trl_id=:'lot'::uuid AND disp_qty=4 \gset
SELECT public.save_invoice(NULL::uuid,jsonb_build_object('inv_no',96701,'inv_fin_year',2026,'customer_id',:'customer_id',
 'customer_name','Qty Lock Customer','inv_date','2026-06-01','total',0,'tax_amount',0,'labour',0,'discount',0,
 'duration_mode','legacy','gr_id',:'grn_id','gr_no','QIL1'),
 ARRAY[jsonb_build_object('disp_trl_id',:'disp_line','grn_item_id',:'lot','duration',1,'charge',10,'tax',0,'labour_rate',2)])->>'success' AS inv \gset
SELECT pg_temp.qi_assert(:'inv'='true','the lot is on a live invoice');
SELECT jsonb_build_object('id',:'lot','item_id',:'item_id','item_name','Qty Lock Turmeric','packaging','Bag','qty',10,'weight',10,'rack','R1') AS line \gset
SELECT updated_at AS token FROM public.goodsreceived WHERE id=:'grn_id'::uuid \gset

-- U4: online save, quantity changed on the invoiced lot.
SELECT public.update_grn(p_grn_id=>:'grn_id'::uuid,p_note=>'Must not be written',
 p_items=>jsonb_build_array(:'line'::jsonb || '{"qty":5}'::jsonb)) AS online \gset
SELECT pg_temp.qi_assert(:'online'::jsonb->>'success'='false' AND :'online'::jsonb->>'reason'='LOT_INVOICED'
 AND :'online'::jsonb->'fields' ? 'qty' AND :'online'::jsonb->>'message' LIKE '%Delete or edit the invoice first.%',
 'U4: a changed quantity on an invoiced lot is LOT_INVOICED with qty in fields, ahead of QTY_BELOW_DISPATCHED: ' || :'online');
-- the same, raised (above what has left)
SELECT public.update_grn(p_grn_id=>:'grn_id'::uuid,
 p_items=>jsonb_build_array(:'line'::jsonb || '{"qty":12}'::jsonb)) AS online_up \gset
SELECT pg_temp.qi_assert(:'online_up'::jsonb->>'reason'='LOT_INVOICED' AND :'online_up'::jsonb->'fields' ? 'qty','U4: a raised quantity is locked too: ' || :'online_up');
-- an unchanged quantity is no change: the save goes through (the note is written)
SELECT public.update_grn(p_grn_id=>:'grn_id'::uuid,p_note=>'Same quantity',p_items=>jsonb_build_array(:'line'::jsonb)) AS online_same \gset
SELECT pg_temp.qi_assert(:'online_same'::jsonb->>'success'='true','U4: the same quantity is not refused: ' || :'online_same');

-- B4: the offline edit, the same lock, and nothing of the item written.
SELECT public.apply_grn_changes(:'grn_id'::uuid,jsonb_build_object('v',1,'grnId',:'grn_id','loadedAt',:'token','recordedAt',now(),
 'header',jsonb_build_object('note',jsonb_build_object('from','Same quantity','to','Offline must roll back')),
 'lots',jsonb_build_object(:'lot',jsonb_build_object('qty',jsonb_build_object('from',10,'to',5)))),'qty-lock-offline-1') AS offline \gset
SELECT pg_temp.qi_assert(:'offline'::jsonb->>'success'='false' AND :'offline'::jsonb->>'reason'='LOT_INVOICED' AND :'offline'::jsonb->'fields' ? 'qty',
 'B4: apply_grn_changes refuses a quantity change of an invoiced lot with LOT_INVOICED and qty: ' || :'offline');
SELECT pg_temp.qi_assert(:'offline'::jsonb#>'{refused,0,path}' IS NOT NULL AND :'offline'::jsonb#>>'{refused,0,code}'='LOT_INVOICED',
 'B5: the answer lists the refused change with its path and code: ' || :'offline');
RESET ROLE;
SELECT pg_temp.qi_assert((SELECT qty=10 AND stock=0 FROM public.goodsreceived_trl WHERE id=:'lot'::uuid)
 AND (SELECT note IS DISTINCT FROM 'Offline must roll back' AND note IS DISTINCT FROM 'Must not be written' FROM public.goodsreceived WHERE id=:'grn_id'::uuid),
 'neither save wrote the quantity or the note of its refused item (all or nothing)');
ROLLBACK;
\echo 'GRN quantity of an invoiced lot is locked online and offline: passed.'

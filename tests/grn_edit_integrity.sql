-- Migration 65: update_grn edits only the lines of the receipt it is given,
-- and refuses a pricing-mode change on a receipt that has invoices (backend
-- review 2026-10-13, I1 and I3). Fictional data; runs only in migrations.sh's
-- disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.gei_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'grn edit integrity: %',label; END IF; END $$;
-- The error text of a statement, or 'no error' when it succeeds.
CREATE FUNCTION pg_temp.gei_error(statement text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE statement; EXCEPTION WHEN OTHERS THEN RETURN SQLERRM; END;
  RETURN 'no error';
END $$;
CREATE FUNCTION pg_temp.gei_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.gei_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.gei_assert(l#>>'{data,action}'='login','login for '||phone);
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
SELECT warehouse_security.bootstrap_first_admin('9888888861','Integrity Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
SELECT pg_temp.gei_login('9888888861') AS admin_claims \gset

-- Fixture: receipts GEIA and GEIB of the same customer, one line of 10 bags
-- weighing 5 each.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.gei_assert(public.create_customer('Integrity Customer','9888888862')->>'success'='true','customer');
SELECT pg_temp.gei_assert(public.create_item('Integrity Potatoes','Bag')->>'success'='true','catalog item');
SELECT id AS customer_id FROM public.customers WHERE name='Integrity Customer' \gset
SELECT id AS item_id FROM public.items WHERE name='Integrity Potatoes' \gset
SELECT pg_temp.gei_assert(public.save_grn(p_gr_no=>'GEIA',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_id'::uuid,
 p_customer_name=>'Integrity Customer',p_pricing_mode=>'MONTHLY',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Integrity Potatoes','packaging','Bag','qty',10,'weight',5)))->>'success'='true','receipt GEIA');
SELECT pg_temp.gei_assert(public.save_grn(p_gr_no=>'GEIB',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_id'::uuid,
 p_customer_name=>'Integrity Customer',p_pricing_mode=>'MONTHLY',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Integrity Potatoes','packaging','Bag','qty',10,'weight',5)))->>'success'='true','receipt GEIB');
RESET ROLE;
SELECT id AS grn_a FROM public.goodsreceived WHERE gr_no='GEIA' \gset
SELECT id AS grn_b FROM public.goodsreceived WHERE gr_no='GEIB' \gset
SELECT id AS line_a FROM public.goodsreceived_trl WHERE gr_id=:'grn_a'::uuid \gset
SELECT id AS line_b FROM public.goodsreceived_trl WHERE gr_id=:'grn_b'::uuid \gset

-- I1. A line of receipt GEIA sent in an edit of receipt GEIB (the review's
-- reproduction): before migration 65 the edit succeeded, renamed GEIA's line to
-- "Foreign Mutation" weighing 99 and deleted GEIB's own line. Now it is
-- refused, and neither receipt changes.
SET LOCAL ROLE authenticated;
SELECT pg_temp.gei_error(format('SELECT public.update_grn(p_grn_id=>%L::uuid,p_note=>%L,p_items=>%L::jsonb)',
 :'grn_b','Must roll back',jsonb_build_array(jsonb_build_object('id',:'line_a','item_id',:'item_id',
  'item_name','Foreign Mutation','packaging','Bag','qty',10,'weight',99))::text)) AS foreign_error \gset
RESET ROLE;
SELECT pg_temp.gei_assert(:'foreign_error' = format('GRN line %s is not a line of this GRN; reload the GRN and edit again',:'line_a'),
 'a line of another receipt is refused: ' || :'foreign_error');
SELECT pg_temp.gei_assert((SELECT item_name='Integrity Potatoes' AND weight=5 AND qty=10 AND stock=10 AND gr_id=:'grn_a'::uuid
 FROM public.goodsreceived_trl WHERE id=:'line_a'::uuid),'the other receipt''s line is unchanged');
SELECT pg_temp.gei_assert((SELECT count(*)=1 AND bool_and(id=:'line_b'::uuid AND qty=10 AND weight=5)
 FROM public.goodsreceived_trl WHERE gr_id=:'grn_b'::uuid),'the edited receipt keeps its own line');
SELECT pg_temp.gei_assert((SELECT note IS DISTINCT FROM 'Must roll back' FROM public.goodsreceived WHERE id=:'grn_b'::uuid),
 'the refused edit leaves the header as it was');
SELECT pg_temp.gei_assert(NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid IN ('public.goodsreceived_trl'::regclass,'public.goodsreceived'::regclass,'public.items'::regclass) AND NOT tgisinternal AND tgenabled<>'O'),
 'the refused edit leaves no trigger of the receipt, its lines or the items disabled');

-- The receipt's own line sent twice: before migration 65 both copies were
-- applied, the last one winning. Refused now.
SET LOCAL ROLE authenticated;
SELECT pg_temp.gei_error(format('SELECT public.update_grn(p_grn_id=>%L::uuid,p_items=>%L::jsonb)',:'grn_b',
 jsonb_build_array(
  jsonb_build_object('id',:'line_b','item_id',:'item_id','item_name','Integrity Potatoes','packaging','Bag','qty',10,'weight',5),
  jsonb_build_object('id',:'line_b','item_id',:'item_id','item_name','Twice Sent','packaging','Bag','qty',7,'weight',6))::text)) AS duplicate_error \gset
RESET ROLE;
SELECT pg_temp.gei_assert(:'duplicate_error' = 'A GRN line is sent more than once in this edit; reload the GRN and edit again',
 'a line sent twice is refused: ' || :'duplicate_error');
SELECT pg_temp.gei_assert((SELECT item_name='Integrity Potatoes' AND qty=10 AND weight=5 FROM public.goodsreceived_trl WHERE id=:'line_b'::uuid),
 'the line sent twice is unchanged');

-- A line id that exists nowhere: before migration 65 the edit succeeded and
-- deleted the receipt's real line. Refused now.
SELECT gen_random_uuid() AS stray_line \gset
SET LOCAL ROLE authenticated;
SELECT pg_temp.gei_error(format('SELECT public.update_grn(p_grn_id=>%L::uuid,p_items=>%L::jsonb)',:'grn_b',
 jsonb_build_array(jsonb_build_object('id',:'stray_line','item_id',:'item_id','item_name','Integrity Potatoes','packaging','Bag','qty',10,'weight',5))::text)) AS stray_error \gset
RESET ROLE;
SELECT pg_temp.gei_assert(:'stray_error' = format('GRN line %s is not a line of this GRN; reload the GRN and edit again',:'stray_line'),
 'an unknown line id is refused: ' || :'stray_error');
SELECT pg_temp.gei_assert((SELECT count(*)=1 FROM public.goodsreceived_trl WHERE id=:'line_b'::uuid),'the receipt''s line is still there');

-- The receipt's own line is edited as before.
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn_b'::uuid,p_items=>jsonb_build_array(jsonb_build_object('id',:'line_b','item_id',:'item_id',
 'item_name','Integrity Potatoes','packaging','Bag','qty',12,'weight',6))) AS own_edit \gset
RESET ROLE;
SELECT pg_temp.gei_assert(:'own_edit'::jsonb->>'success'='true' AND :'own_edit'::jsonb#>>'{stats,items_updated}'='1'
 AND :'own_edit'::jsonb#>>'{stats,items_deleted}'='0','the receipt''s own line is edited: ' || :'own_edit');
SELECT pg_temp.gei_assert((SELECT qty=12 AND stock=12 AND weight=6 FROM public.goodsreceived_trl WHERE id=:'line_b'::uuid),
 'the own line takes the new quantity and weight');

-- I3. Receipt GEIA is invoiced as MONTHLY: 4 of its 10 bags dispatched on
-- 2026-06-01, charge 10, labour 2; the legacy duration the server works out for
-- April to June is 2.5, so the total is 4 x 10 x 2.5 + 4 x 2 = 108. A change of
-- the receipt's pricing mode to ONE_TIME afterwards made the invoice's lines read
-- 40.00 while its stored total stayed 108 (the review's reproduction). Refused now.
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','GEID1','disp_date','2026-06-01T12:00:00Z',
 'customer_id',:'customer_id','customer_name','Integrity Customer','supervisor_id',:'admin_profile','supervisor_name','Integrity Administrator'),
 ARRAY[jsonb_build_object('gr_trl_id',:'line_a','disp_qty',4)],0,'gei-dispatch') AS dispatched \gset
SELECT pg_temp.gei_assert(:'dispatched'::jsonb->>'success'='true','4 of 10 dispatched: ' || :'dispatched');
-- Migration 121 D9: an invoice needs a GRN with no stock left, so the other 6 bags go out on a second dispatch that is not invoiced here.
SELECT public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','GEID1B','disp_date','2026-06-01T12:00:00Z',
 'customer_id',:'customer_id','customer_name','Integrity Customer','supervisor_id',:'admin_profile','supervisor_name','Integrity Administrator'),
 ARRAY[jsonb_build_object('gr_trl_id',:'line_a','disp_qty',6)],0,'gei-dispatch-rest') AS dispatched_rest \gset
SELECT pg_temp.gei_assert(:'dispatched_rest'::jsonb->>'success'='true','the other 6 dispatched: ' || :'dispatched_rest');
SELECT id AS disp_line FROM public.dispatch_trl WHERE gr_trl_id=:'line_a'::uuid AND disp_qty=4 \gset
SELECT public.save_invoice(NULL::uuid,jsonb_build_object('inv_no',96501,'inv_fin_year',2026,'customer_id',:'customer_id',
 'customer_name','Integrity Customer','inv_date','2026-06-01','total',0,'tax_amount',0,'labour',0,'discount',0,
 'duration_mode','legacy','gr_id',:'grn_a','gr_no','GEIA'),
 ARRAY[jsonb_build_object('disp_trl_id',:'disp_line','grn_item_id',:'line_a','duration',1,'charge',10,'tax',0,'labour_rate',2)]) AS invoiced \gset
SELECT pg_temp.gei_assert(:'invoiced'::jsonb->>'success'='true','invoice saved: ' || :'invoiced');
RESET ROLE;
SELECT id AS invoice_id, total AS invoice_total FROM public.invoice WHERE gr_id=:'grn_a'::uuid \gset
SELECT pg_temp.gei_assert(:'invoice_total'::numeric=108,'the stored total is 100 storage + 8 labour: ' || :'invoice_total');
SET LOCAL ROLE authenticated;
SELECT public.get_invoice_items_detailed(:'invoice_id'::uuid)#>>'{data,summary,total_amount}' AS lines_before \gset
SELECT pg_temp.gei_error(format('SELECT public.update_grn(p_grn_id=>%L::uuid,p_note=>%L,p_pricing_mode=>%L,p_items=>%L::jsonb)',
 :'grn_a','Must roll back','ONE_TIME',jsonb_build_array(jsonb_build_object('id',:'line_a','item_id',:'item_id',
  'item_name','Integrity Potatoes','packaging','Bag','qty',10,'weight',5))::text)) AS pricing_error \gset
SELECT public.get_invoice_items_detailed(:'invoice_id'::uuid)#>>'{data,summary,total_amount}' AS lines_after \gset
RESET ROLE;
SELECT pg_temp.gei_assert(:'pricing_error' = 'Cannot change the pricing mode of a GRN that has invoices: delete invoices first, then change the pricing mode and invoice again',
 'a pricing-mode change on an invoiced receipt is refused: ' || :'pricing_error');
SELECT pg_temp.gei_assert((SELECT pricing_mode='MONTHLY' AND note IS DISTINCT FROM 'Must roll back' FROM public.goodsreceived WHERE id=:'grn_a'::uuid),
 'the receipt stays MONTHLY');
SELECT pg_temp.gei_assert(:'lines_before'::numeric=108 AND :'lines_after'::numeric=108
 AND (SELECT total=108 FROM public.invoice WHERE id=:'invoice_id'::uuid),
 'the invoice lines and the stored total still agree at 108: ' || :'lines_before' || ' then ' || :'lines_after');

-- Sending the mode the receipt already has (the app always sends it) is an
-- ordinary edit, and so is sending no mode.
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn_a'::uuid,p_note=>'Same mode',p_pricing_mode=>'MONTHLY',
 p_items=>jsonb_build_array(jsonb_build_object('id',:'line_a','item_id',:'item_id','item_name','Integrity Potatoes','packaging','Bag','qty',10,'weight',5))) AS same_mode \gset
SELECT public.update_grn(p_grn_id=>:'grn_a'::uuid,p_note=>'No mode',
 p_items=>jsonb_build_array(jsonb_build_object('id',:'line_a','item_id',:'item_id','item_name','Integrity Potatoes','packaging','Bag','qty',10,'weight',5))) AS no_mode \gset
RESET ROLE;
SELECT pg_temp.gei_assert(:'same_mode'::jsonb->>'success'='true' AND :'no_mode'::jsonb->>'success'='true'
 AND (SELECT note='No mode' AND pricing_mode='MONTHLY' FROM public.goodsreceived WHERE id=:'grn_a'::uuid),
 'the same mode or no mode is an ordinary edit: ' || :'same_mode');

-- A receipt without invoices changes its mode freely.
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn_b'::uuid,p_pricing_mode=>'ONE_TIME',
 p_items=>jsonb_build_array(jsonb_build_object('id',:'line_b','item_id',:'item_id','item_name','Integrity Potatoes','packaging','Bag','qty',12,'weight',6))) AS free_change \gset
RESET ROLE;
SELECT pg_temp.gei_assert(:'free_change'::jsonb->>'success'='true'
 AND (SELECT pricing_mode='ONE_TIME' FROM public.goodsreceived WHERE id=:'grn_b'::uuid),'a receipt without invoices changes its mode');

-- The revision path: delete the invoice, change the mode, invoice again.
SET LOCAL ROLE authenticated;
SELECT public.delete_invoice(:'invoice_id'::uuid) AS deleted \gset
SELECT public.update_grn(p_grn_id=>:'grn_a'::uuid,p_pricing_mode=>'ONE_TIME',
 p_items=>jsonb_build_array(jsonb_build_object('id',:'line_a','item_id',:'item_id','item_name','Integrity Potatoes','packaging','Bag','qty',10,'weight',5))) AS after_delete \gset
RESET ROLE;
SELECT pg_temp.gei_assert(:'deleted'::jsonb->>'success'='true' AND :'after_delete'::jsonb->>'success'='true'
 AND (SELECT pricing_mode='ONE_TIME' FROM public.goodsreceived WHERE id=:'grn_a'::uuid),
 'after the invoice is deleted the mode can change: ' || :'after_delete');

-- The patch kept the function's owner, SECURITY DEFINER, settings and grants,
-- and the kept-image update is bound to the receipt as well.
SELECT pg_temp.gei_assert((SELECT prosecdef AND has_function_privilege('authenticated',oid,'EXECUTE')
   AND NOT has_function_privilege('anon',oid,'EXECUTE')
   AND position('WHERE id = v_image_id AND grn_id = p_grn_id;' IN pg_get_functiondef(oid)) > 0
 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='update_grn'),'update_grn keeps its definer rights and grants');
ROLLBACK;

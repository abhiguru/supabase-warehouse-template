-- Migration 146 (WH-43): delete_invoice(p_invoice_id, p_expected_updated_at DEFAULT NULL) works again beside cancel_invoice. Covers who may call it
-- (administrators and supervisors; staff and customers are refused by the guard), an unknown invoice, the version token (STALE_RECORD), the payment
-- refusal, deleting a live and a cancelled invoice (lines gone, audit rows kept, number free again), and the GRN's invoiced flag (reset unless another
-- live invoice holds the GRN). Fictional data; runs only in migrations.sh's disposable, network-disabled database; rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.d_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'invoice delete 146: %',label; END IF; END $$;
-- The single jsonb answer of a call, or {"raised": message, "state": sqlstate}.
CREATE FUNCTION pg_temp.d_call(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.d_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.d_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.d_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
CREATE FUNCTION pg_temp.d_save(no integer, grn uuid, grn_no text, customer uuid) RETURNS jsonb LANGUAGE sql AS $$
 SELECT public.save_invoice(NULL::uuid,
  jsonb_build_object('inv_fin_year',2026,'inv_no',no,'customer_id',customer,'customer_name','Delete Test North',
   'inv_date','2026-05-02T12:00:00Z','total',0,'tax_amount',0,'labour',0,'discount',0,'duration_mode','legacy','gr_id',grn,'gr_no',grn_no),
  ARRAY(SELECT jsonb_build_object('disp_trl_id',t.id,'grn_item_id',t.gr_trl_id,'duration',1,'charge',5,'tax',5,'labour_rate',2)
        FROM public.dispatch_trl t WHERE t.gr_id=grn)) $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='DLTEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9877777761','Delete Test Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919877777762','Delete Test Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919877777763','Delete Test Staff','staff',true,'approved'),
 (gen_random_uuid(),'919877777764','Delete Test Reader','customer',true,'approved');
SELECT pg_temp.d_login('9877777761') AS admin_claims \gset
SELECT pg_temp.d_login('9877777762') AS supervisor_claims \gset
SELECT pg_temp.d_login('9877777763') AS staff_claims \gset
SELECT pg_temp.d_login('9877777764') AS customer_claims \gset

-- Fixture: receipts DL1 and DL2 (20 bags each), both dispatched in full; staff invoice 31 on DL1 and invoice 32 on DL2.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.d_assert(public.create_customer('Delete Test North','9877777765')->>'success'='true','customer');
SELECT pg_temp.d_assert(public.create_item('Delete Test Garlic','Bag')->>'success'='true','item');
SELECT id AS north FROM public.customers WHERE name='Delete Test North' \gset
SELECT id AS item_id FROM public.items WHERE name='Delete Test Garlic' \gset
SELECT pg_temp.d_assert(public.assign_customer_to_user('919877777764',:'north'::uuid,'Delete test fixture'),'customer login assigned');
SELECT pg_temp.d_assert(public.replace_item_rates(:'item_id'::uuid,:'north'::uuid,'monthly','2026-01-01'::date,jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',5,'labour_rate',2,'tax_percent',5)))->>'success'='true','price');
SELECT pg_temp.d_assert(public.save_grn(p_gr_no=>n.no::varchar,p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'north'::uuid,
 p_customer_name=>'Delete Test North',p_pricing_mode=>'ONE_TIME',p_idempotency_key=>'delete-grn-'||n.no,
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Delete Test Garlic','packaging','Bag','qty',20,'weight',10,'rack','D-'||n.no)))->>'success'='true','receipt '||n.no)
FROM (VALUES ('DL1'),('DL2')) n(no);
SELECT id AS grn1 FROM public.goodsreceived WHERE gr_no='DL1' \gset
SELECT id AS grn2 FROM public.goodsreceived WHERE gr_no='DL2' \gset
SELECT pg_temp.d_assert(public.create_dispatch_with_stock_check(jsonb_build_object('customer_id',:'north','customer_name','Delete Test North',
 'supervisor_id',:'admin_profile','supervisor_name','Delete Test Administrator','disp_date','2026-05-02','disp_no','DLD'||n.k),
 ARRAY[jsonb_build_object('gr_trl_id',(SELECT t.id FROM public.goodsreceived_trl t WHERE t.gr_id=n.g::uuid),'disp_qty',20)],0,'delete-dispatch-'||n.k)->>'success'='true','dispatch DLD'||n.k)
FROM (VALUES ('1',:'grn1'),('2',:'grn2')) n(k,g);
RESET ROLE;
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.d_save(31,:'grn1'::uuid,'DL1',:'north'::uuid) AS saved1 \gset
SELECT pg_temp.d_save(32,:'grn2'::uuid,'DL2',:'north'::uuid) AS saved2 \gset
RESET ROLE;
SELECT pg_temp.d_assert(:'saved1'::jsonb->>'success'='true' AND :'saved2'::jsonb->>'success'='true','staff save invoices 31 and 32: '||:'saved1'||:'saved2');
SELECT (:'saved1'::jsonb->>'invoice_id')::uuid AS inv1 \gset
SELECT (:'saved2'::jsonb->>'invoice_id')::uuid AS inv2 \gset
SELECT pg_temp.d_assert((SELECT invoiced FROM public.goodsreceived WHERE id=:'grn1'::uuid) AND (SELECT invoiced FROM public.goodsreceived WHERE id=:'grn2'::uuid),'fixture: both receipts are invoiced');
SELECT updated_at AS token1 FROM public.invoice WHERE id=:'inv1'::uuid \gset

-- 1. Staff and a customer account are refused by the guard; nothing is deleted.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.d_call(format('SELECT public.delete_invoice(%L)',:'inv1')) AS r_staff \gset
SELECT set_config('request.jwt.claims',:'customer_claims',true);
SELECT pg_temp.d_call(format('SELECT public.delete_invoice(%L)',:'inv1')) AS r_customer \gset
RESET ROLE;
SELECT pg_temp.d_assert(:'r_staff'::jsonb->>'state'='42501' AND :'r_staff'::jsonb->>'raised'='Staff access required','staff are refused: '||:'r_staff');
SELECT pg_temp.d_assert(:'r_customer'::jsonb->>'state'='42501','a customer account is refused: '||:'r_customer');
SELECT pg_temp.d_assert(NOT has_function_privilege('anon','public.delete_invoice(uuid,timestamptz)','EXECUTE') AND NOT has_function_privilege('public','public.delete_invoice(uuid,timestamptz)','EXECUTE')
 AND has_function_privilege('authenticated','public.delete_invoice(uuid,timestamptz)','EXECUTE') AND has_function_privilege('service_role','public.delete_invoice(uuid,timestamptz)','EXECUTE')
 AND (SELECT count(*)=1 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='delete_invoice'),'grants, and one overload only');
SELECT pg_temp.d_assert(EXISTS (SELECT 1 FROM public.invoice WHERE id=:'inv1'::uuid),'a refused call deleted nothing');

-- 2. Unknown invoice; stale token; payment.
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_invoice(gen_random_uuid()) AS r_unknown \gset
SELECT public.delete_invoice(:'inv1'::uuid,:'token1'::timestamptz - interval '1 second') AS r_stale \gset
RESET ROLE;
SELECT pg_temp.d_assert(:'r_unknown'::jsonb->>'success'='false' AND :'r_unknown'::jsonb->>'error'='Invoice not found','unknown invoice: '||:'r_unknown');
SELECT pg_temp.d_assert(:'r_stale'::jsonb->>'success'='false' AND :'r_stale'::jsonb->>'reason'='STALE_RECORD' AND :'r_stale'::jsonb->>'error_code'='WH409'
 AND :'r_stale'::jsonb->>'what'='invoice' AND :'r_stale'::jsonb->>'id'=:'inv1' AND :'r_stale'::jsonb ? 'current_updated_at','a stale token is refused: '||:'r_stale');
SELECT pg_temp.d_assert(EXISTS (SELECT 1 FROM public.invoice WHERE id=:'inv1'::uuid) AND (SELECT count(*)=1 FROM public.invoice_trl WHERE invoice_id=:'inv1'::uuid)
 AND (SELECT invoiced FROM public.goodsreceived WHERE id=:'grn1'::uuid),'a refused stale call changed nothing');
INSERT INTO public.payments(payment_no,payment_date,customer_id,invoice_id,amount,payment_mode) VALUES ('DLP1','2026-05-03T00:00:00Z',:'north'::uuid,:'inv2'::uuid,10,'cash');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_invoice(:'inv2'::uuid) AS r_paid \gset
RESET ROLE;
SELECT pg_temp.d_assert(:'r_paid'::jsonb->>'success'='false' AND :'r_paid'::jsonb->>'error'='Cannot delete an invoice that has payments'
 AND EXISTS (SELECT 1 FROM public.invoice WHERE id=:'inv2'::uuid) AND (SELECT invoiced FROM public.goodsreceived WHERE id=:'grn2'::uuid),'an invoice with a payment is refused and kept: '||:'r_paid');
DELETE FROM public.payments WHERE payment_no='DLP1';

-- 3. A supervisor deletes the live invoice 31 with its version token: the invoice and its lines are gone, the receipt is invoiceable, the number is free.
SELECT pg_temp.d_assert((SELECT count(*) FROM public.audit_log WHERE table_name='invoice' AND action='DELETE')=0,'no invoice delete is audited yet');
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_invoice(:'inv1'::uuid,:'token1'::timestamptz) AS r_del1 \gset
RESET ROLE;
SELECT pg_temp.d_assert(:'r_del1'::jsonb->>'success'='true' AND :'r_del1'::jsonb->>'message'='Invoice deleted successfully' AND (:'r_del1'::jsonb->>'invoice_number')::int=31
 AND (:'r_del1'::jsonb->>'inv_fin_year')::int=2026 AND :'r_del1'::jsonb->>'invoice_id'=:'inv1' AND :'r_del1'::jsonb->>'gr_id'=:'grn1','delete answer: '||:'r_del1');
SELECT pg_temp.d_assert(NOT EXISTS (SELECT 1 FROM public.invoice WHERE id=:'inv1'::uuid) AND NOT EXISTS (SELECT 1 FROM public.invoice_trl WHERE invoice_id=:'inv1'::uuid),'the invoice and its lines are removed');
SELECT pg_temp.d_assert(NOT (SELECT invoiced FROM public.goodsreceived WHERE id=:'grn1'::uuid),'the receipt is invoiceable again');
SELECT pg_temp.d_assert((SELECT count(*)=1 FROM public.audit_log WHERE table_name='invoice' AND action='DELETE' AND old_data->>'id'=:'inv1')
 AND (SELECT count(*)=1 FROM public.audit_log WHERE table_name='invoice_trl' AND action='DELETE' AND old_data->>'invoice_id'=:'inv1'),'the audit keeps the deleted invoice and its line');
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.d_save(31,:'grn1'::uuid,'DL1',:'north'::uuid) AS saved1b \gset
RESET ROLE;
SELECT pg_temp.d_assert(:'saved1b'::jsonb->>'success'='true','the number 31 can be used again: '||:'saved1b');
SELECT (:'saved1b'::jsonb->>'invoice_id')::uuid AS inv1b \gset

-- 4. The GRN flag: a cancelled invoice is deleted while a live invoice holds the receipt (flag stays), then the live one is deleted (flag reset).
SELECT updated_at AS token1b FROM public.invoice WHERE id=:'inv1b'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.cancel_invoice(:'inv1b'::uuid,'Entered twice',:'token1b'::timestamptz) AS r_cancel \gset
RESET ROLE;
SELECT pg_temp.d_assert(:'r_cancel'::jsonb->>'success'='true' AND NOT (SELECT invoiced FROM public.goodsreceived WHERE id=:'grn1'::uuid),'invoice 31 cancelled, receipt free: '||:'r_cancel');
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.d_save(33,:'grn1'::uuid,'DL1',:'north'::uuid) AS saved3 \gset
RESET ROLE;
SELECT pg_temp.d_assert(:'saved3'::jsonb->>'success'='true' AND (SELECT invoiced FROM public.goodsreceived WHERE id=:'grn1'::uuid),'a new live invoice 33 holds the receipt: '||:'saved3');
SELECT (:'saved3'::jsonb->>'invoice_id')::uuid AS inv3 \gset
SELECT updated_at AS token1c FROM public.invoice WHERE id=:'inv1b'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_invoice(:'inv1b'::uuid,:'token1c'::timestamptz) AS r_del_cancelled \gset
RESET ROLE;
SELECT pg_temp.d_assert(:'r_del_cancelled'::jsonb->>'success'='true' AND NOT EXISTS (SELECT 1 FROM public.invoice WHERE id=:'inv1b'::uuid)
 AND (SELECT invoiced FROM public.goodsreceived WHERE id=:'grn1'::uuid),'a cancelled invoice is deleted and the live invoice keeps the flag: '||:'r_del_cancelled');
-- The kept_* copies of the cancelled line are in the audit row of its deletion (migration 143).
SELECT pg_temp.d_assert(EXISTS (SELECT 1 FROM public.audit_log WHERE table_name='invoice_trl' AND action='DELETE' AND old_data->>'invoice_id'=:'inv1b' AND old_data->>'kept_item_name'='Delete Test Garlic'),
 'the audit keeps the kept_* copy of a deleted cancelled line');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_invoice(:'inv3'::uuid) AS r_del_live \gset
RESET ROLE;
SELECT pg_temp.d_assert(:'r_del_live'::jsonb->>'success'='true' AND NOT (SELECT invoiced FROM public.goodsreceived WHERE id=:'grn1'::uuid),'the last live invoice is deleted, the flag is reset: '||:'r_del_live');
ROLLBACK;

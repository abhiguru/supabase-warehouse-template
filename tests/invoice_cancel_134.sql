-- Migration 134: an invoice is cancelled, not deleted, and the invoice records are audited. Covers cancel_invoice (roles, fields, refusals,
-- the GRN flag), delete_invoice's refusal, update_invoice / save_invoice on a cancelled invoice, the number staying taken, a cancelled invoice
-- not being live (its lines go on a new invoice), the read paths (detail, customer summary, customer activity, a customer account reading
-- it) and the audit triggers on invoice, invoice_trl, payments and dispatch_trl. Fictional data; runs only in migrations.sh's disposable,
-- network-disabled database; rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.ic_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'invoice cancel 134: %',label; END IF; END $$;
-- The single jsonb answer of a call, or {"raised": message, "state": sqlstate}.
CREATE FUNCTION pg_temp.ic_call(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.ic_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.ic_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.ic_assert(l#>>'{data,action}'='login','login for '||phone);
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
SELECT warehouse_security.bootstrap_first_admin('9877777731','Cancel Test Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919877777732','Cancel Test Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919877777733','Cancel Test Staff','staff',true,'approved'),
 (gen_random_uuid(),'919877777734','Cancel Test Reader','customer',true,'approved'),
 (gen_random_uuid(),'919877777735','Cancel Test Other Reader','customer',true,'approved');
SELECT id AS staff_profile FROM public.user_profiles WHERE mobile='919877777733' \gset
SELECT pg_temp.ic_login('9877777731') AS admin_claims \gset
SELECT pg_temp.ic_login('9877777732') AS supervisor_claims \gset
SELECT pg_temp.ic_login('9877777733') AS staff_claims \gset
SELECT pg_temp.ic_login('9877777734') AS customer_claims \gset
SELECT pg_temp.ic_login('9877777735') AS other_claims \gset


-- Fixture, as the administrator: a customer with a login, an item, and two receipts of 20 bags dispatched in full and invoiced by staff
-- (invoice 5 on CN1, invoice 7 on CN2). A second login belongs to another customer.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ic_assert(public.create_customer('Cancel Test North','9877777736')->>'success'='true'
 AND public.create_customer('Cancel Test South','9877777737')->>'success'='true','customers');
SELECT pg_temp.ic_assert(public.create_item('Cancel Test Garlic','Bag')->>'success'='true','catalog item');
SELECT id AS north FROM public.customers WHERE name='Cancel Test North' \gset
SELECT id AS south FROM public.customers WHERE name='Cancel Test South' \gset
SELECT id AS item_id FROM public.items WHERE name='Cancel Test Garlic' \gset
SELECT pg_temp.ic_assert(public.assign_customer_to_user('919877777734',:'north'::uuid,'Cancel test fixture')
 AND public.assign_customer_to_user('919877777735',:'south'::uuid,'Cancel test fixture'),'customer logins assigned');
SELECT pg_temp.ic_assert(public.replace_item_rates(:'item_id'::uuid,:'north'::uuid,'monthly','2026-01-01'::date,jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',5,'labour_rate',2,'tax_percent',5)))->>'success'='true','price');
RESET ROLE;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ic_assert(public.save_grn(p_gr_no=>'CN1',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'north'::uuid,
 p_customer_name=>'Cancel Test North',p_pricing_mode=>'ONE_TIME',p_idempotency_key=>'cancel-test-grn-1',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Cancel Test Garlic',
 'packaging','Bag','qty',20,'weight',10,'rack','RC1')))->>'success'='true','receipt CN1');
SELECT id AS grn1 FROM public.goodsreceived WHERE gr_no='CN1' \gset
SELECT pg_temp.ic_assert(public.create_dispatch_with_stock_check(jsonb_build_object('customer_id',:'north','customer_name','Cancel Test North',
 'supervisor_id',:'admin_profile','supervisor_name','Cancel Test Administrator','disp_date','2026-05-02','disp_no','CND1'),
 ARRAY[jsonb_build_object('gr_trl_id',(SELECT t.id FROM public.goodsreceived_trl t WHERE t.gr_id=:'grn1'::uuid),'disp_qty',20)],
 0,'cancel-test-dispatch-1')->>'success'='true','dispatch CND1');
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SELECT public.save_invoice(NULL::uuid,
 jsonb_build_object('inv_fin_year',2026,'inv_no',5,'customer_id',:'north','customer_name','Cancel Test North',
  'inv_date','2026-05-02T12:00:00Z','total',0,'tax_amount',0,'labour',0,'discount',0,'duration_mode','legacy',
  'gr_id',:'grn1','gr_no','CN1'),
 ARRAY(SELECT jsonb_build_object('disp_trl_id',t.id,'grn_item_id',t.gr_trl_id,'duration',1,'charge',5,'tax',5,'labour_rate',2)
       FROM public.dispatch_trl t WHERE t.gr_id=:'grn1'::uuid)) AS saved1 \gset
SELECT pg_temp.ic_assert(:'saved1'::jsonb->>'success'='true','staff save invoice 5: '||:'saved1');
SELECT (:'saved1'::jsonb->>'invoice_id') AS inv1 \gset
RESET ROLE;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ic_assert(public.save_grn(p_gr_no=>'CN2',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'north'::uuid,
 p_customer_name=>'Cancel Test North',p_pricing_mode=>'ONE_TIME',p_idempotency_key=>'cancel-test-grn-2',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Cancel Test Garlic',
 'packaging','Bag','qty',20,'weight',10,'rack','RC2')))->>'success'='true','receipt CN2');
SELECT id AS grn2 FROM public.goodsreceived WHERE gr_no='CN2' \gset
SELECT pg_temp.ic_assert(public.create_dispatch_with_stock_check(jsonb_build_object('customer_id',:'north','customer_name','Cancel Test North',
 'supervisor_id',:'admin_profile','supervisor_name','Cancel Test Administrator','disp_date','2026-05-02','disp_no','CND2'),
 ARRAY[jsonb_build_object('gr_trl_id',(SELECT t.id FROM public.goodsreceived_trl t WHERE t.gr_id=:'grn2'::uuid),'disp_qty',20)],
 0,'cancel-test-dispatch-2')->>'success'='true','dispatch CND2');
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SELECT public.save_invoice(NULL::uuid,
 jsonb_build_object('inv_fin_year',2026,'inv_no',7,'customer_id',:'north','customer_name','Cancel Test North',
  'inv_date','2026-05-02T12:00:00Z','total',0,'tax_amount',0,'labour',0,'discount',0,'duration_mode','legacy',
  'gr_id',:'grn2','gr_no','CN2'),
 ARRAY(SELECT jsonb_build_object('disp_trl_id',t.id,'grn_item_id',t.gr_trl_id,'duration',1,'charge',5,'tax',5,'labour_rate',2)
       FROM public.dispatch_trl t WHERE t.gr_id=:'grn2'::uuid)) AS saved2 \gset
SELECT pg_temp.ic_assert(:'saved2'::jsonb->>'success'='true','staff save invoice 7: '||:'saved2');
SELECT (:'saved2'::jsonb->>'invoice_id') AS inv2 \gset
RESET ROLE;

-- One transaction has one now(): the version tokens of the fixture are moved an hour back (triggers off for this statement only), so that a
-- change shows as a different token.
SET LOCAL session_replication_role = replica;
UPDATE public.invoice SET updated_at = now() - interval '1 hour';
RESET session_replication_role;
SELECT updated_at AS token1 FROM public.invoice WHERE id=:'inv1'::uuid \gset
SELECT updated_at AS token2 FROM public.invoice WHERE id=:'inv2'::uuid \gset
SELECT pg_temp.ic_assert((SELECT invoiced FROM public.goodsreceived WHERE id=:'grn1'::uuid),'fixture: CN1 is invoiced');

-- 1. Roles: staff and customers are refused, nothing changes.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ic_call(format('SELECT public.cancel_invoice(%L,%L,NULL)',:'inv1','Entered twice')) AS r_staff \gset
SELECT set_config('request.jwt.claims',:'customer_claims',true);
SELECT pg_temp.ic_call(format('SELECT public.cancel_invoice(%L,%L,NULL)',:'inv1','Entered twice')) AS r_customer \gset
SELECT pg_temp.ic_call(format('SELECT public.delete_invoice(%L)',:'inv1')) AS r_customer_delete \gset
RESET ROLE;
SELECT pg_temp.ic_assert(:'r_staff'::jsonb->>'state'='42501' AND :'r_staff'::jsonb->>'raised'='Staff access required','staff are refused cancel_invoice: '||:'r_staff');
SELECT pg_temp.ic_assert(:'r_customer'::jsonb->>'state'='42501','a customer account is refused cancel_invoice: '||:'r_customer');
SELECT pg_temp.ic_assert(:'r_customer_delete'::jsonb->>'success'='false' AND :'r_customer_delete'::jsonb->>'error' ~ '(Staff|Administrator|Customer)','a customer account is refused delete_invoice: '||:'r_customer_delete');
SELECT pg_temp.ic_assert((SELECT cancelled_at IS NULL FROM public.invoice WHERE id=:'inv1'::uuid),'a refused call cancelled nothing');
SELECT pg_temp.ic_assert(NOT has_function_privilege('anon','public.cancel_invoice(uuid,text,timestamptz)','EXECUTE')
 AND NOT has_function_privilege('public','public.cancel_invoice(uuid,text,timestamptz)','EXECUTE')
 AND has_function_privilege('authenticated','public.cancel_invoice(uuid,text,timestamptz)','EXECUTE')
 AND has_function_privilege('service_role','public.cancel_invoice(uuid,text,timestamptz)','EXECUTE'),'grants of cancel_invoice');

-- 2. Reason: trimmed, 3 to 500 characters. Refused before anything is locked or written.
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.cancel_invoice(:'inv1'::uuid,'  ab  ',NULL) AS r_short \gset
SELECT public.cancel_invoice(:'inv1'::uuid,'   ',NULL) AS r_blank \gset
SELECT public.cancel_invoice(:'inv1'::uuid,NULL,NULL) AS r_null \gset
SELECT public.cancel_invoice(:'inv1'::uuid,repeat('x',501),NULL) AS r_long \gset
SELECT public.cancel_invoice(:'inv1'::uuid,'abc',:'token1'::timestamptz - interval '1 second') AS r_min_len \gset
RESET ROLE;
SELECT pg_temp.ic_assert((SELECT bool_and(a->>'success'='false' AND a->>'reason'='CANCEL_REASON_INVALID' AND a->>'error_code'='WH409' AND (a->>'min')::int=3 AND (a->>'max')::int=500)
  FROM unnest(ARRAY[:'r_short'::jsonb,:'r_blank'::jsonb,:'r_null'::jsonb,:'r_long'::jsonb]) a),'a reason under 3 (after trimming), blank, missing or over 500 characters is refused: '||:'r_short');
SELECT pg_temp.ic_assert(:'r_min_len'::jsonb->>'reason'='STALE_RECORD','a reason of exactly 3 characters passes the reason check (the stale token then refuses): '||:'r_min_len');
SELECT pg_temp.ic_assert((SELECT cancelled_at IS NULL FROM public.invoice WHERE id=:'inv1'::uuid),'a refused reason cancelled nothing');

-- 3. Unknown invoice; stale token.
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.cancel_invoice(gen_random_uuid(),'Entered twice',NULL) AS r_unknown \gset
SELECT public.cancel_invoice(:'inv1'::uuid,'Entered twice',:'token1'::timestamptz - interval '1 second') AS r_stale \gset
RESET ROLE;
SELECT pg_temp.ic_assert(:'r_unknown'::jsonb = '{"success": false, "error": "Invoice not found"}'::jsonb,'an unknown invoice: '||:'r_unknown');
SELECT pg_temp.ic_assert(:'r_stale'::jsonb->>'success'='false' AND :'r_stale'::jsonb->>'reason'='STALE_RECORD' AND :'r_stale'::jsonb->>'error_code'='WH409'
 AND :'r_stale'::jsonb->>'what'='invoice' AND (:'r_stale'::jsonb->>'id')=:'inv1' AND :'r_stale'::jsonb ? 'current_updated_at' AND :'r_stale'::jsonb ? 'expected_updated_at',
 'a stale token is refused as update_invoice refuses it: '||:'r_stale');
SELECT pg_temp.ic_assert((SELECT cancelled_at IS NULL AND updated_at=:'token1'::timestamptz FROM public.invoice WHERE id=:'inv1'::uuid) AND (SELECT invoiced FROM public.goodsreceived WHERE id=:'grn1'::uuid),
 'a refused stale call changed nothing');

-- 4. Payments: an invoice with a payment is not cancelled.
INSERT INTO public.payments(payment_no,payment_date,customer_id,invoice_id,amount,payment_mode) VALUES ('CNP1','2026-05-03T00:00:00Z',:'north'::uuid,:'inv2'::uuid,10,'cash');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.cancel_invoice(:'inv2'::uuid,'Entered twice',NULL) AS r_paid \gset
RESET ROLE;
SELECT pg_temp.ic_assert(:'r_paid'::jsonb->>'success'='false' AND :'r_paid'::jsonb->>'reason'='INVOICE_HAS_PAYMENTS' AND (:'r_paid'::jsonb->>'payments')::int=1
 AND :'r_paid'::jsonb->>'invoice_id'=:'inv2','an invoice with payments is refused: '||:'r_paid');
SELECT pg_temp.ic_assert((SELECT cancelled_at IS NULL FROM public.invoice WHERE id=:'inv2'::uuid) AND (SELECT invoiced FROM public.goodsreceived WHERE id=:'grn2'::uuid),'the invoice with payments is untouched');

-- 5. A supervisor cancels; the fields are set; the number and the lines stay; the GRN is invoiceable again.
SELECT count(*) AS lines_before FROM public.invoice_trl WHERE invoice_id=:'inv1'::uuid \gset
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.cancel_invoice(:'inv1'::uuid,'  Entered twice  ',:'token1'::timestamptz) AS r_ok \gset
RESET ROLE;
SELECT id AS supervisor_profile FROM public.user_profiles WHERE mobile='919877777732' \gset
SELECT pg_temp.ic_assert(:'r_ok'::jsonb->>'success'='true' AND :'r_ok'::jsonb->>'cancel_reason'='Entered twice' AND :'r_ok'::jsonb->>'invoice_id'=:'inv1'
 AND (:'r_ok'::jsonb->>'invoice_number')::int=5 AND :'r_ok'::jsonb->>'cancelled_by'=:'supervisor_profile' AND :'r_ok'::jsonb ? 'updated_at' AND :'r_ok'::jsonb ? 'cancelled_at','supervisor cancel answer: '||:'r_ok');
SELECT pg_temp.ic_assert((SELECT cancelled_at=now() AND cancelled_by=:'supervisor_profile'::uuid AND cancel_reason='Entered twice' AND deleted_at IS NULL AND inv_no=5 AND inv_fin_year=2026 AND updated_at<>:'token1'::timestamptz
   FROM public.invoice WHERE id=:'inv1'::uuid),'cancelled_at, cancelled_by (the caller''s profile), cancel_reason (trimmed) are set, the number is kept');
SELECT pg_temp.ic_assert((SELECT count(*)=:lines_before AND count(*)>0 FROM public.invoice_trl WHERE invoice_id=:'inv1'::uuid),'the invoice lines are kept');
SELECT pg_temp.ic_assert(NOT (SELECT invoiced FROM public.goodsreceived WHERE id=:'grn1'::uuid),'the GRN is not invoiced any more');
SELECT updated_at AS token1b FROM public.invoice WHERE id=:'inv1'::uuid \gset

-- 6. Cancelled twice: refused, nothing changes.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.cancel_invoice(:'inv1'::uuid,'Again',:'token1b'::timestamptz) AS r_twice \gset
RESET ROLE;
SELECT pg_temp.ic_assert(:'r_twice'::jsonb->>'success'='false' AND :'r_twice'::jsonb->>'reason'='INVOICE_CANCELLED' AND :'r_twice'::jsonb->>'error_code'='WH409' AND :'r_twice'::jsonb ? 'cancelled_at',
 'cancelling twice is refused: '||:'r_twice');
SELECT pg_temp.ic_assert((SELECT cancel_reason='Entered twice' AND updated_at=:'token1b'::timestamptz FROM public.invoice WHERE id=:'inv1'::uuid),'the second call changed nothing');

-- 7. The GRN flag: another live invoice on the GRN keeps it invoiced. Invoice 9 is inserted on CN2 next to invoice 7 (the save path allows
-- one invoice per GRN); the payment on invoice 7 is removed first.
DELETE FROM public.payments WHERE payment_no='CNP1';
INSERT INTO public.invoice(inv_fin_year,inv_no,gr_id,gr_no,customer_id,customer_name,inv_date,total) SELECT 2026,9,gr_id,gr_no,customer_id,customer_name,inv_date,0 FROM public.invoice WHERE id=:'inv2'::uuid;
SELECT id AS inv_other FROM public.invoice WHERE inv_no=9 AND inv_fin_year=2026 \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.cancel_invoice(:'inv2'::uuid,'Wrong customer',NULL) AS r_two \gset
RESET ROLE;
SELECT pg_temp.ic_assert(:'r_two'::jsonb->>'success'='true' AND (SELECT invoiced FROM public.goodsreceived WHERE id=:'grn2'::uuid),'with another live invoice on the GRN, the GRN stays invoiced: '||:'r_two');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.cancel_invoice(:'inv_other'::uuid,'Wrong customer',NULL) AS r_last \gset
RESET ROLE;
SELECT pg_temp.ic_assert(:'r_last'::jsonb->>'success'='true' AND NOT (SELECT invoiced FROM public.goodsreceived WHERE id=:'grn2'::uuid),'cancelling the last live invoice clears the flag (a cancelled one is not "another live invoice"): '||:'r_last');

-- 8. Edits: a cancelled invoice is not updated or saved over; a live invoice is updated as before.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_invoice(:'inv1'::uuid,
 jsonb_build_object('inv_fin_year',2026,'inv_no',5,'customer_id',:'north','customer_name','Cancel Test North','inv_date','2026-05-02T12:00:00Z',
  'discount',0,'duration_mode','legacy','gr_id',:'grn1','gr_no','CN1','notes','after the cancel'),
 ARRAY(SELECT jsonb_build_object('disp_trl_id',t.id,'grn_item_id',t.gr_trl_id,'duration',1,'charge',5,'tax',5,'labour_rate',2)
       FROM public.dispatch_trl t WHERE t.gr_id=:'grn1'::uuid)) AS r_upd \gset
SELECT public.save_invoice(:'inv1'::uuid,
 jsonb_build_object('inv_fin_year',2026,'inv_no',6,'customer_id',:'north','customer_name','Cancel Test North','inv_date','2026-05-02T12:00:00Z',
  'discount',0,'duration_mode','legacy','gr_id',:'grn1','gr_no','CN1'),
 ARRAY(SELECT jsonb_build_object('disp_trl_id',t.id,'grn_item_id',t.gr_trl_id,'duration',1,'charge',5,'tax',5,'labour_rate',2)
       FROM public.dispatch_trl t WHERE t.gr_id=:'grn1'::uuid)) AS r_save_over \gset
RESET ROLE;
SELECT pg_temp.ic_assert(:'r_upd'::jsonb->>'success'='false' AND :'r_upd'::jsonb->>'reason'='INVOICE_CANCELLED' AND :'r_upd'::jsonb->>'error_code'='WH409' AND :'r_upd'::jsonb->>'invoice_id'=:'inv1',
 'update_invoice refuses a cancelled invoice: '||:'r_upd');
SELECT pg_temp.ic_assert(:'r_save_over'::jsonb->>'reason'='INVOICE_CANCELLED' AND :'r_save_over'::jsonb->>'success'='false','save_invoice over the id of a cancelled invoice is refused by name: '||:'r_save_over');
SELECT pg_temp.ic_assert((SELECT notes IS NULL AND cancel_reason='Entered twice' AND updated_at=:'token1b'::timestamptz FROM public.invoice WHERE id=:'inv1'::uuid),'the cancelled invoice was not edited');
-- A new invoice takes the lines of the cancelled one (number 6), then a live invoice is edited as before.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_invoice(NULL::uuid,
 jsonb_build_object('inv_fin_year',2026,'inv_no',6,'customer_id',:'north','customer_name','Cancel Test North','inv_date','2026-05-02T12:00:00Z',
  'discount',0,'duration_mode','legacy','gr_id',:'grn1','gr_no','CN1'),
 ARRAY(SELECT jsonb_build_object('disp_trl_id',t.id,'grn_item_id',t.gr_trl_id,'duration',1,'charge',5,'tax',5,'labour_rate',2)
       FROM public.dispatch_trl t WHERE t.gr_id=:'grn1'::uuid)) AS r_new \gset
RESET ROLE;
SELECT pg_temp.ic_assert(:'r_new'::jsonb->>'success'='true','the lines of a cancelled invoice go on a new invoice (number 6): '||:'r_new');
SELECT (:'r_new'::jsonb->>'invoice_id') AS inv_new \gset
SELECT pg_temp.ic_assert((SELECT invoiced FROM public.goodsreceived WHERE id=:'grn1'::uuid),'the new invoice marks the GRN invoiced again');
SELECT updated_at AS token_new FROM public.invoice WHERE id=:'inv_new'::uuid \gset
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_invoice(:'inv_new'::uuid,
 jsonb_build_object('inv_fin_year',2026,'inv_no',6,'customer_id',:'north','customer_name','Cancel Test North','inv_date','2026-05-02T12:00:00Z',
  'discount',0,'duration_mode','legacy','gr_id',:'grn1','gr_no','CN1','notes','edited','expected_updated_at',:'token_new'),
 ARRAY(SELECT jsonb_build_object('disp_trl_id',t.id,'grn_item_id',t.gr_trl_id,'duration',1,'charge',5,'tax',5,'labour_rate',2)
       FROM public.dispatch_trl t WHERE t.gr_id=:'grn1'::uuid)) AS r_edit \gset
SELECT public.update_invoice(gen_random_uuid(),jsonb_build_object('inv_fin_year',2026,'inv_no',6,'customer_id',:'north','gr_id',:'grn1','inv_date','2026-05-02T12:00:00Z'),ARRAY[]::jsonb[]) AS r_upd_unknown \gset
RESET ROLE;
SELECT pg_temp.ic_assert(:'r_edit'::jsonb->>'success'='true' AND (SELECT notes='edited' FROM public.invoice WHERE id=:'inv_new'::uuid),'a live invoice is updated as before: '||:'r_edit');
SELECT pg_temp.ic_assert(:'r_upd_unknown'::jsonb->>'error'='Invoice not found','update_invoice of an unknown id still answers "Invoice not found": '||:'r_upd_unknown');

-- 9. The number stays taken, and the next number counts the cancelled rows.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_invoice(NULL::uuid,
 jsonb_build_object('inv_fin_year',2026,'inv_no',5,'customer_id',:'north','customer_name','Cancel Test North','inv_date','2026-05-02T12:00:00Z',
  'discount',0,'duration_mode','legacy','gr_id',:'grn2','gr_no','CN2'),
 ARRAY(SELECT jsonb_build_object('disp_trl_id',t.id,'grn_item_id',t.gr_trl_id,'duration',1,'charge',5,'tax',5,'labour_rate',2)
       FROM public.dispatch_trl t WHERE t.gr_id=:'grn2'::uuid)) AS r_reuse \gset
SELECT public.get_next_invoice_number(2026) AS next_no \gset
RESET ROLE;
SELECT pg_temp.ic_assert(:'r_reuse'::jsonb->>'reason'='NUMBER_TAKEN' AND :'r_reuse'::jsonb->>'number'='5','the cancelled invoice''s number can not be reused: '||:'r_reuse');
SELECT pg_temp.ic_assert(:'next_no'::int > 9,'the next number is above the cancelled 5, 7 and 9: '||:'next_no');
SELECT pg_temp.ic_assert((SELECT count(*)=1 FROM public.invoice WHERE inv_fin_year=2026 AND inv_no=5),'exactly one row holds number 5');
-- unique_inv_no_per_year blocks it at the table too.
SELECT pg_temp.ic_assert((SELECT state FROM (SELECT pg_temp.ic_call('INSERT INTO public.invoice(inv_fin_year,inv_no,gr_id,gr_no,customer_id,inv_date) SELECT 2026,5,gr_id,gr_no,customer_id,inv_date FROM public.invoice WHERE inv_no=7 RETURNING to_jsonb(invoice)')->>'state' AS state) s)='23505','unique_inv_no_per_year refuses number 5 again');

-- 10. delete_invoice refuses and deletes nothing, for a live and for a cancelled invoice.
SELECT count(*) AS inv_rows_before FROM public.invoice \gset
SELECT count(*) AS trl_rows_before FROM public.invoice_trl \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_invoice(:'inv_new'::uuid) AS r_del_live \gset
SELECT public.delete_invoice(:'inv1'::uuid) AS r_del_cancelled \gset
RESET ROLE;
SELECT pg_temp.ic_assert(:'r_del_live'::jsonb->>'success'='false' AND :'r_del_live'::jsonb->>'reason'='INVOICE_CANCEL_ONLY' AND :'r_del_live'::jsonb->>'error_code'='WH409'
 AND :'r_del_live'::jsonb->>'invoice_id'=:'inv_new' AND :'r_del_cancelled'::jsonb->>'reason'='INVOICE_CANCEL_ONLY','delete_invoice refuses: '||:'r_del_live');
SELECT pg_temp.ic_assert((SELECT count(*)=:inv_rows_before FROM public.invoice) AND (SELECT count(*)=:trl_rows_before FROM public.invoice_trl)
 AND (SELECT invoiced FROM public.goodsreceived WHERE id=:'grn1'::uuid),'delete_invoice deleted nothing and changed no flag');
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_invoice(:'inv_new'::uuid) AS r_del_staff \gset
RESET ROLE;
SELECT pg_temp.ic_assert(:'r_del_staff'::jsonb->>'success'='false' AND :'r_del_staff'::jsonb->>'error'='Staff access required','staff are refused delete_invoice as before: '||:'r_del_staff');

-- 11. Reads. Detail: staff see who cancelled; a customer account sees the cancellation but not the name.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_invoice_detail(:'inv1'::uuid)->'invoice' AS d_staff \gset
SELECT public.get_invoice_detail(:'inv_new'::uuid)->'invoice' AS d_live \gset
SELECT set_config('request.jwt.claims',:'customer_claims',true);
SELECT public.get_invoice_detail(:'inv1'::uuid)->'invoice' AS d_customer \gset
SELECT jsonb_agg(to_jsonb(r)) AS c_rows FROM (SELECT id,cancelled_at,cancelled_by,cancel_reason FROM public.invoice WHERE customer_id=:'north'::uuid ORDER BY inv_no) r \gset
SELECT public.get_customer_invoice_summary(:'north'::uuid,'2026-01-01','2026-12-31') AS s_customer \gset
SELECT public.get_customer_activity_detail(:'north'::uuid,'2026-01-01','2026-12-31') AS a_customer \gset
SELECT set_config('request.jwt.claims',:'other_claims',true);
SELECT count(*) AS other_sees FROM public.invoice WHERE id=:'inv1'::uuid \gset
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SELECT public.get_invoices_list(50,0) AS l_staff \gset
SELECT public.get_customer_invoice_summary(NULL,'2026-01-01','2026-12-31') AS s_all \gset
SELECT public.get_customer_grn_activity(:'north'::uuid,'2026-01-01','2026-12-31') AS g_activity \gset
RESET ROLE;
SELECT pg_temp.ic_assert(:'d_staff'::jsonb->>'cancel_reason'='Entered twice' AND (:'d_staff'::jsonb->>'cancelled_at') IS NOT NULL AND :'d_staff'::jsonb->>'cancelled_by_name'='Cancel Test Supervisor'
 AND :'d_staff'::jsonb->>'cancelled_by'=:'supervisor_profile','get_invoice_detail for staff: '||:'d_staff');
SELECT pg_temp.ic_assert(:'d_live'::jsonb ? 'cancelled_at' AND :'d_live'::jsonb->'cancelled_at'='null'::jsonb AND :'d_live'::jsonb->'cancel_reason'='null'::jsonb,'a live invoice answers null cancelled_at and cancel_reason: '||:'d_live');
SELECT pg_temp.ic_assert(:'d_customer'::jsonb->>'cancel_reason'='Entered twice' AND (:'d_customer'::jsonb->>'cancelled_at') IS NOT NULL AND NOT (:'d_customer'::jsonb ? 'cancelled_by_name'),
 'a customer account sees the cancellation, not who did it: '||:'d_customer');
SELECT pg_temp.ic_assert((SELECT bool_or(r->>'id'=:'inv1' AND r->>'cancel_reason'='Entered twice' AND r->>'cancelled_at' IS NOT NULL) FROM jsonb_array_elements(:'c_rows'::jsonb) r),
 'a customer account reads the cancelled invoice from the table, with the three columns: '||:'c_rows');
SELECT pg_temp.ic_assert(:other_sees=0,'another customer''s login does not see it');
-- Invoice list: the cancelled row is there with cancelled_at.
SELECT pg_temp.ic_assert((SELECT count(*)=1 FROM jsonb_array_elements(:'l_staff'::jsonb->'data') r WHERE r->>'invoice_id'=:'inv1' AND r->>'cancelled_at' IS NOT NULL AND r->>'cancel_reason'='Entered twice')
 AND (SELECT count(*)=1 FROM jsonb_array_elements(:'l_staff'::jsonb->'data') r WHERE r->>'invoice_id'=:'inv_new' AND r->'cancelled_at'='null'::jsonb),'get_invoices_list lists the cancelled invoice with cancelled_at and the live one with null');
-- Customer summary: listed with the status cancelled, out of every sum and count (invoices 5, 7 and 9 are cancelled, 6 is live).
SELECT pg_temp.ic_assert(:'s_customer'::jsonb#>>'{data,summary,cancelled_count}'='3' AND :'s_customer'::jsonb#>>'{data,summary,total_invoices}'='1'
 AND (SELECT count(*) FROM jsonb_array_elements(:'s_customer'::jsonb#>'{data,invoices}'))=4
 AND (SELECT count(*) FROM jsonb_array_elements(:'s_customer'::jsonb#>'{data,invoices}') r WHERE r#>>'{payment_status,status}'='cancelled' AND r->>'cancelled_at' IS NOT NULL)=3
 AND (SELECT r#>>'{payment_status,status}' FROM jsonb_array_elements(:'s_customer'::jsonb#>'{data,invoices}') r WHERE r->>'invoice_id'=:'inv_new')='pending'
 AND (:'s_customer'::jsonb#>>'{data,summary,total_amount}')::numeric=(SELECT total FROM public.invoice WHERE id=:'inv_new'::uuid)
 AND (:'s_customer'::jsonb#>>'{data,summary,pending_amount}')::numeric=(SELECT total FROM public.invoice WHERE id=:'inv_new'::uuid)
 AND (:'s_customer'::jsonb#>>'{data,summary,pending_count}')='1' AND (:'s_customer'::jsonb#>>'{data,summary,paid_count}')='0'
 AND (SELECT sum((m->>'invoice_count')::int) FROM jsonb_array_elements(:'s_customer'::jsonb#>'{data,by_month}') m)=1,
 'customer summary: cancelled invoices are listed, not counted or summed: '||(:'s_customer'::jsonb#>'{data,summary}')::text);
SELECT pg_temp.ic_assert((:'s_all'::jsonb#>>'{data,summary,total_invoices}')::int>=1 AND (:'s_all'::jsonb#>>'{data,summary,cancelled_count}')::int>=3
 AND (SELECT sum((c->>'invoice_count')::int) FROM jsonb_array_elements(:'s_all'::jsonb#>'{data,by_customer}') c)=(:'s_all'::jsonb#>>'{data,summary,total_invoices}')::int,
 'all-customers summary leaves cancelled invoices out and counts them apart: '||(:'s_all'::jsonb#>'{data,summary}')::text);
SELECT pg_temp.ic_assert(position(:'inv_new' IN :'g_activity')>0 AND position(:'inv1' IN :'g_activity')=0
 AND jsonb_path_query_first(:'g_activity'::jsonb,'$.**.total_invoiced_grns') = '1'::jsonb,
 'the GRN activity counts one invoiced GRN (CN1, by its live invoice); CN2 has only cancelled invoices: '||:'g_activity');
-- Customer activity: the same.
SELECT pg_temp.ic_assert((:'a_customer'::jsonb#>>'{data,summary,cancelled_count}')::int=3
 AND (:'a_customer'::jsonb#>>'{data,summary,total_invoice_amount}')::numeric=(SELECT total FROM public.invoice WHERE id=:'inv_new'::uuid)
 AND (SELECT count(*) FROM jsonb_array_elements(:'a_customer'::jsonb#>'{data,recent_invoices}') r WHERE r->>'status'='cancelled')=3
 AND (SELECT r->>'status' FROM jsonb_array_elements(:'a_customer'::jsonb#>'{data,recent_invoices}') r WHERE r->>'invoice_id'=:'inv_new')='pending',
 'customer activity: cancelled invoices are listed with their status, out of the sums: '||(:'a_customer'::jsonb)::text);

SELECT pg_temp.ic_assert((SELECT bool_and((r->>'is_invoiced')::boolean = (r->>'grn_id'=:'grn1')) AND count(*)=2 FROM jsonb_array_elements(:'a_customer'::jsonb#>'{data,recent_grns}') r),
 'customer activity: a GRN whose invoices are all cancelled is not invoiced: '||(:'a_customer'::jsonb#>'{data,recent_grns}')::text);

-- 12. A cancelled invoice is not live for the GRN and dispatch rules: GRN CN2 (all its invoices cancelled) has no invoice for the edit form.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_grn_edit_state(:'grn2'::uuid) AS e2 \gset
SELECT public.get_grn_edit_state(:'grn1'::uuid) AS e1 \gset
SELECT public.get_grn_item_rates(:'grn1'::uuid) AS rates1 \gset
SELECT public.get_grn_item_rates(:'grn2'::uuid) AS rates2 \gset
SELECT public.get_all_customer_activity_summary('2026-01-01','2026-12-31') AS all_activity \gset
SELECT id AS disp1 FROM public.dispatch WHERE disp_no='CND1' \gset
SELECT id AS disp2 FROM public.dispatch WHERE disp_no='CND2' \gset
SELECT public.get_dispatch_details(:'disp1'::uuid)::text AS dd1 \gset
SELECT public.get_dispatch_details(:'disp2'::uuid)::text AS dd2 \gset
RESET ROLE;
SELECT pg_temp.ic_assert(COALESCE(:'e2'::jsonb#>'{data,invoice}','null'::jsonb)='null'::jsonb,'GRN edit state: no invoice on a GRN whose invoices are all cancelled: '||:'e2');
SELECT pg_temp.ic_assert(position(:'inv_new' IN :'dd1')>0 AND position(:'inv1' IN :'dd1')=0 AND position(:'inv2' IN :'dd2')=0,
 'dispatch details name the live invoice of a line and never a cancelled one: '||:'dd2');
SELECT pg_temp.ic_assert(jsonb_path_query_first(:'dd1'::jsonb,'$.**.invoices_summary.total_invoices') = '1'::jsonb
 AND jsonb_path_query_first(:'dd2'::jsonb,'$.**.invoices_summary.total_invoices') = '0'::jsonb,
 'the invoice summary of a dispatch counts live invoices only: '||:'dd1'||:'dd2');
SELECT pg_temp.ic_assert((:'e1'::jsonb#>>'{data,invoice,inv_no}')='6','GRN edit state: the live invoice is the one named: '||:'e1');

SELECT pg_temp.ic_assert(jsonb_path_query_first(:'rates1'::jsonb,'$.**.source') = '"invoice"'::jsonb AND jsonb_path_query_first(:'rates2'::jsonb,'$.**.source') IS DISTINCT FROM '"invoice"'::jsonb,
 'the stored rate of a line comes from a live invoice only, never a cancelled one: '||:'rates1'||:'rates2');
SELECT pg_temp.ic_assert((SELECT max(v::text::numeric) FROM jsonb_path_query(:'all_activity'::jsonb,'$.**.total_invoice_amount') v) = (SELECT total FROM public.invoice WHERE id=:'inv_new'::uuid),
 'the all-customers activity summary leaves cancelled invoices out of the invoice amount: '||:'all_activity');
-- The date of a dispatch whose invoices are all cancelled can change (update_dispatch_smart); one with a live invoice keeps its date.
SELECT t.id AS lot1 FROM public.goodsreceived_trl t WHERE t.gr_id=:'grn1'::uuid \gset
SELECT t.id AS lot2 FROM public.goodsreceived_trl t WHERE t.gr_id=:'grn2'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp1'::uuid,jsonb_build_object('disp_date','2026-05-03T12:00:00Z'),ARRAY[jsonb_build_object('gr_trl_id',:'lot1','disp_qty',20)]) AS ud_live \gset
SELECT public.update_dispatch_smart(:'disp2'::uuid,jsonb_build_object('disp_date','2026-05-03T12:00:00Z'),ARRAY[jsonb_build_object('gr_trl_id',:'lot2','disp_qty',20)]) AS ud_cancelled \gset
RESET ROLE;
SELECT pg_temp.ic_assert(:'ud_live'::jsonb->>'reason'='DISPATCH_INVOICED' AND :'ud_cancelled'::jsonb->>'success'='true',
 'update_dispatch_smart: the date of a dispatch with a live invoice is kept, one with only cancelled invoices can change: '||:'ud_live'||:'ud_cancelled');
-- A dispatch whose invoices are all cancelled can be deleted; one with a live invoice can not.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_dispatch_with_order_cleanup(:'disp1'::uuid,NULL) AS dd_live \gset
SELECT public.delete_dispatch_with_order_cleanup(:'disp2'::uuid,NULL) AS dd_cancelled \gset
RESET ROLE;
SELECT pg_temp.ic_assert(:'dd_live'::jsonb->>'blocking_reason'='invoices_exist' AND :'dd_cancelled'::jsonb->>'success'='true' AND NOT EXISTS (SELECT 1 FROM public.dispatch WHERE id=:'disp2'::uuid)
 AND EXISTS (SELECT 1 FROM public.dispatch WHERE id=:'disp1'::uuid),'a dispatch with a live invoice is kept, one whose invoices are cancelled is deleted: '||:'dd_live'||:'dd_cancelled');

-- 13. Audit: every insert and delete, and every update that changes more than updated_at, on the four tables; none for an updated_at-only change.
CREATE FUNCTION pg_temp.ic_audit(t text, a text) RETURNS bigint LANGUAGE sql AS $$ SELECT count(*) FROM public.audit_log WHERE table_name=t AND action=a $$;
-- Inserts happened in the fixture and by the saves (invoice, invoice_trl, dispatch_trl) and the payment above (payments).
SELECT pg_temp.ic_assert(pg_temp.ic_audit('invoice','INSERT')>=4 AND pg_temp.ic_audit('invoice_trl','INSERT')>=3 AND pg_temp.ic_audit('dispatch_trl','INSERT')>=2 AND pg_temp.ic_audit('payments','INSERT')=1,
 'inserts are audited on the four tables');
SELECT pg_temp.ic_assert(pg_temp.ic_audit('payments','DELETE')=1,'the payment deleted in section 7 is audited');
SELECT pg_temp.ic_assert((SELECT new_data->>'cancel_reason'='Entered twice' AND old_data->>'cancel_reason' IS NULL AND user_id IS NOT NULL FROM public.audit_log
   WHERE table_name='invoice' AND action='UPDATE' AND new_data->>'id'=:'inv1' AND new_data->>'cancelled_at' IS NOT NULL),'the cancellation is one audited update with the old and the new row and the user');
-- An update that changes only updated_at writes nothing; a real change writes one row; a delete writes one.
SELECT pg_temp.ic_audit('invoice','UPDATE') AS a_inv \gset
SELECT pg_temp.ic_audit('invoice_trl','UPDATE') AS a_trl \gset
SELECT pg_temp.ic_audit('payments','UPDATE') AS a_pay \gset
SELECT pg_temp.ic_audit('dispatch_trl','UPDATE') AS a_dtl \gset
INSERT INTO public.payments(payment_no,payment_date,customer_id,invoice_id,amount,payment_mode) VALUES ('CNP2','2026-05-04T00:00:00Z',:'north'::uuid,:'inv_new'::uuid,5,'cash');
UPDATE public.invoice SET updated_at = updated_at + interval '1 minute' WHERE id=:'inv_new'::uuid;
UPDATE public.invoice_trl SET id = id WHERE invoice_id=:'inv_new'::uuid;
UPDATE public.payments SET note = note WHERE payment_no='CNP2';
UPDATE public.dispatch_trl SET id = id WHERE gr_id=:'grn1'::uuid;
SELECT pg_temp.ic_assert(pg_temp.ic_audit('invoice','UPDATE')=:a_inv AND pg_temp.ic_audit('invoice_trl','UPDATE')=:a_trl AND pg_temp.ic_audit('payments','UPDATE')=:a_pay AND pg_temp.ic_audit('dispatch_trl','UPDATE')=:a_dtl,
 'an update that changes no column, or only updated_at, writes no audit row');
UPDATE public.invoice SET notes='audit probe' WHERE id=:'inv_new'::uuid;
UPDATE public.invoice_trl SET charge=charge+1 WHERE invoice_id=:'inv_new'::uuid;
UPDATE public.payments SET note='audit probe' WHERE payment_no='CNP2';
UPDATE public.dispatch_trl SET cart_quantity_consumed=COALESCE(cart_quantity_consumed,0)+1 WHERE gr_id=:'grn1'::uuid;
SELECT pg_temp.ic_assert(pg_temp.ic_audit('invoice','UPDATE')=:a_inv+1 AND pg_temp.ic_audit('invoice_trl','UPDATE')=:a_trl+1 AND pg_temp.ic_audit('payments','UPDATE')=:a_pay+1 AND pg_temp.ic_audit('dispatch_trl','UPDATE')=:a_dtl+1,
 'a real change writes one audit row on each of the four tables');
SELECT pg_temp.ic_audit('invoice_trl','DELETE') AS d_trl \gset
SELECT pg_temp.ic_audit('payments','DELETE') AS d_pay \gset
SELECT pg_temp.ic_audit('invoice','DELETE') AS d_inv \gset
SELECT pg_temp.ic_audit('dispatch_trl','DELETE') AS d_dtl \gset
DELETE FROM public.payments WHERE payment_no='CNP2';
DELETE FROM public.invoice_trl WHERE invoice_id=:'inv_other'::uuid;
DELETE FROM public.invoice WHERE id=:'inv_other'::uuid;
SELECT pg_temp.ic_assert(pg_temp.ic_audit('payments','DELETE')=:d_pay+1 AND pg_temp.ic_audit('invoice','DELETE')=:d_inv+1 AND pg_temp.ic_audit('invoice_trl','DELETE')=:d_trl,
 'deleting a payment and an invoice is audited (invoice 9 had no lines)');
DELETE FROM public.invoice_trl WHERE invoice_id=:'inv_new'::uuid;
SELECT pg_temp.ic_assert(pg_temp.ic_audit('invoice_trl','DELETE')=:d_trl+1,'deleting an invoice line is audited');
DELETE FROM public.dispatch_trl WHERE gr_id=:'grn1'::uuid;
SELECT pg_temp.ic_assert(pg_temp.ic_audit('dispatch_trl','DELETE')=:d_dtl+1,'deleting a dispatch line is audited');
-- The triggers: two per table.
SELECT pg_temp.ic_assert((SELECT count(*)=8 FROM pg_trigger WHERE NOT tgisinternal AND tgname ~ '^audit_(invoice|invoice_trl|payments|dispatch_trl)(_update)?$'),'eight audit triggers on the four tables');

-- 14. Retention policy.
SELECT pg_temp.ic_assert((SELECT days=2920 FROM warehouse_maintenance.retention_policy WHERE key='audit_log'),'audit_log is kept 2920 days');
ROLLBACK;

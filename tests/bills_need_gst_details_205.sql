-- WH-205: no bill can be made until the facility's GST details are saved with a GSTIN (migration: bills need GST details). Fictional data; runs only
-- in migrations.sh's disposable, network-disabled database.
-- "GST details saved" is the key gstSavedAt of the JSON row public.system_settings 'facility_legal' (set by set_gst_details, WH-151; read by
-- warehouse_security.gst_settings()->>'saved' and by get_gst_details, which the app's Home strip uses). A store saved as NOT registered counts as
-- having no details. The refusal is the repo's usual one: the save answers {"success": false, "reason": "GST_DETAILS_REQUIRED", ...}
-- (warehouse_security.refuse), nothing written, no raw error.
-- The three bill-making paths all end in save_invoice(NULL, header, lines): the invoice form (hand-made header and lines), the GRN's
-- create-invoice button (the form from generate_invoice_data_for_grn_with_pricing, WH-162) and goods invoiced as they leave (a dispatch made with
-- p_generate_invoice, WH-138). Bills already made stay editable and cancellable; imported bills (import_history, WH-180) are outside the rule.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.gd_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'bills need GST details: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.gd_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.gd_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.gd_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
CREATE FUNCTION pg_temp.gd_as(claims jsonb, statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',claims::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN answer := jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  EXECUTE 'RESET ROLE';
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.gd_svc(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  EXECUTE 'SET LOCAL ROLE service_role';
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN answer := jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  EXECUTE 'RESET ROLE';
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.gd_save_invoice(doc jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.save_invoice(NULL::uuid, doc - 'items', ARRAY(
    SELECT jsonb_build_object('grn_item_id', (SELECT d.gr_trl_id FROM public.dispatch_trl d WHERE d.id = (i->>'disp_trl_id')::uuid), 'duration', 1) || i
    FROM jsonb_array_elements(doc->'items') i)) $$;
CREATE FUNCTION pg_temp.gd_update_invoice(p_id uuid, doc jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.update_invoice(p_id, doc - 'items', ARRAY(
    SELECT jsonb_build_object('grn_item_id', (SELECT d.gr_trl_id FROM public.dispatch_trl d WHERE d.id = (i->>'disp_trl_id')::uuid), 'duration', 1) || i
    FROM jsonb_array_elements(doc->'items') i)) $$;

-- The state of the GST details row, written as a store would be left by each case (the keys WH-151 stores).
CREATE FUNCTION pg_temp.gd_clear_gst() RETURNS void LANGUAGE sql AS $$
  UPDATE public.system_settings SET value = (value::jsonb - 'gstSavedAt' - 'gstSavedBy')::text WHERE key = 'facility_legal' $$;
-- Saved as NOT registered: saved (gstSavedAt present), gstRegistered false, no GSTIN.
CREATE FUNCTION pg_temp.gd_set_not_registered() RETURNS void LANGUAGE sql AS $$
  UPDATE public.system_settings SET value = ((value::jsonb - 'gstin') || jsonb_build_object('gstRegistered', false, 'gstSavedAt', now()::text, 'address', '1 Demo Road, Demo City'))::text
   WHERE key = 'facility_legal' $$;
CREATE FUNCTION pg_temp.gd_saved() RETURNS boolean LANGUAGE sql AS $$ SELECT (warehouse_security.gst_settings()->>'saved')::boolean $$;
CREATE FUNCTION pg_temp.gd_refused(answer jsonb) RETURNS boolean LANGUAGE sql AS $$
  SELECT answer->>'success' = 'false' AND answer->>'reason' = 'GST_DETAILS_REQUIRED' AND answer->>'error_code' = 'WH409' AND NOT (answer ? 'raised') $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888888951','Gst Required Administrator') AS boot \gset
SELECT pg_temp.gd_login('9888888951') AS admin_claims \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE mobile = '919888888951' \gset
SELECT warehouse_security.business_date(now()) AS today \gset
SELECT warehouse_security.financial_year(:'today'::date) AS cur_fy \gset
INSERT INTO public.customers(name,mobile) VALUES ('Gst Required Customer','9888888952') RETURNING id AS cust \gset
INSERT INTO public.items(name,packaging) VALUES ('Gst Required Potato','Bag') RETURNING id AS item_id \gset
INSERT INTO public.items(name,packaging) VALUES ('Gst Required Onion','Bag') RETURNING id AS exempt_item_id \gset
UPDATE warehouse_security.charging_rule SET step_days = 15, minimum_days = 30, days_counted = 'legacy', rounding = 'up', invoice_as_goods_leave = true WHERE id;
SELECT pg_temp.gd_as(:'admin_claims'::jsonb, format($q$SELECT public.replace_item_rates(%L::uuid,NULL,'monthly','2026-01-01'::date,
  '[{"weight_min":0,"weight_max":100,"unit_price":5,"labour_rate":2,"tax_percent":5}]'::jsonb)$q$, :'item_id')) AS rates \gset
SELECT pg_temp.gd_assert(:'rates'::jsonb->>'success'='true','rates: '||:'rates');
SELECT pg_temp.gd_as(:'admin_claims'::jsonb, format($q$SELECT public.replace_item_rates(%L::uuid,NULL,'monthly','2026-01-01'::date,
  '[{"weight_min":0,"weight_max":100,"unit_price":5,"labour_rate":2,"tax_percent":0}]'::jsonb)$q$, :'exempt_item_id')) AS rates2 \gset
SELECT pg_temp.gd_assert(:'rates2'::jsonb->>'success'='true','rates 2: '||:'rates2');
SELECT pg_temp.gd_as(:'admin_claims'::jsonb, format($q$SELECT public.set_item_gst_treatment(%L::uuid,'exempt_agri')$q$, :'exempt_item_id')) AS treat \gset
SELECT pg_temp.gd_assert(:'treat'::jsonb->>'success'='true','exempt treatment: '||:'treat');

-- Four receipts, each with one dispatch of 10 bags: one per path, and one of an exempt item. GST details are never saved at this point.
SELECT pg_temp.gd_assert(NOT pg_temp.gd_saved(), 'a database that never saved GST details reads as not saved');
SELECT set_config('gd.admin_claims', :'admin_claims', true) AS s1, set_config('gd.cust', :'cust', true) AS s2, set_config('gd.admin_profile', :'admin_profile', true) AS s3,
       set_config('gd.today', :'today', true) AS s4, set_config('gd.cur_fy', :'cur_fy', true) AS s5 \gset
CREATE FUNCTION pg_temp.gd_grn(p_no text, p_item uuid, p_name text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE a jsonb; v uuid;
BEGIN
  a := pg_temp.gd_as(current_setting('gd.admin_claims')::jsonb, format($q$SELECT public.save_grn(p_gr_no=>%L,p_date=>%L::timestamptz,p_customer_id=>%L::uuid,p_customer_name=>'Gst Required Customer',
    p_pricing_mode=>'MONTHLY',p_idempotency_key=>%L,p_items=>jsonb_build_array(jsonb_build_object('item_id',%L,'item_name',%L,'packaging','Bag','qty',50,'weight',10,'rack','R1')))$q$,
    p_no, (current_setting('gd.today')::date - 60)::text || 'T12:00:00Z', current_setting('gd.cust'), 'gd-' || p_no, p_item, p_name));
  PERFORM pg_temp.gd_assert(a->>'success' = 'true', 'GRN ' || p_no || ': ' || a);
  SELECT id INTO v FROM public.goodsreceived WHERE gr_no = p_no;
  RETURN v;
END $$;
CREATE FUNCTION pg_temp.gd_dispatch(p_no text, p_grn uuid, p_generate boolean) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.gd_as(current_setting('gd.admin_claims')::jsonb, format($q$SELECT public.create_dispatch_with_stock_check(jsonb_build_object('disp_no',%L,'disp_date',%L,
    'customer_id',%L,'customer_name','x','supervisor_id',%L,'supervisor_name','x'),ARRAY[jsonb_build_object('gr_trl_id',(SELECT id FROM public.goodsreceived_trl WHERE gr_id = %L::uuid),'disp_qty',10)],%L::boolean,0,%L)$q$,
    p_no, (current_setting('gd.today')::date - 20)::text || 'T12:00:00Z', current_setting('gd.cust'), current_setting('gd.admin_profile'), p_grn, p_generate, 'gd-' || p_no)) $$;
SELECT pg_temp.gd_grn('GDA1', :'item_id'::uuid, 'Gst Required Potato') AS grn_a, pg_temp.gd_grn('GDB1', :'item_id'::uuid, 'Gst Required Potato') AS grn_b,
       pg_temp.gd_grn('GDC1', :'item_id'::uuid, 'Gst Required Potato') AS grn_c, pg_temp.gd_grn('GDE1', :'exempt_item_id'::uuid, 'Gst Required Onion') AS grn_e \gset
SELECT pg_temp.gd_dispatch('GDA1', :'grn_a'::uuid, false) AS da, pg_temp.gd_dispatch('GDB1', :'grn_b'::uuid, false) AS db, pg_temp.gd_dispatch('GDE1', :'grn_e'::uuid, false) AS de \gset
-- Goods leaving with the bill asked for (WH-138): the dispatch itself must still go through with no GST details (only the bill is refused).
SELECT pg_temp.gd_dispatch('GDC1', :'grn_c'::uuid, true) AS dc \gset
SELECT pg_temp.gd_assert(:'da'::jsonb->>'success' = 'true' AND :'db'::jsonb->>'success' = 'true' AND :'dc'::jsonb->>'success' = 'true' AND :'de'::jsonb->>'success' = 'true',
  'the dispatches: ' || :'da' || :'db' || :'dc' || :'de');
SELECT pg_temp.gd_assert((SELECT count(*) FROM public.invoice) = 0, 'a dispatch with the bill asked for writes no invoice by itself');
SELECT t.id AS line_a FROM public.dispatch_trl t JOIN public.dispatch d ON d.id = t.disp_id WHERE d.disp_no = 'GDA1' \gset
SELECT t.id AS line_b FROM public.dispatch_trl t JOIN public.dispatch d ON d.id = t.disp_id WHERE d.disp_no = 'GDB1' \gset
SELECT t.id AS line_c FROM public.dispatch_trl t JOIN public.dispatch d ON d.id = t.disp_id WHERE d.disp_no = 'GDC1' \gset
SELECT t.id AS line_e FROM public.dispatch_trl t JOIN public.dispatch d ON d.id = t.disp_id WHERE d.disp_no = 'GDE1' \gset
-- The bill document of one receipt and one dispatch line, with the number given.
CREATE FUNCTION pg_temp.gd_doc(p_no integer, p_grn uuid, p_gr_no text, p_line uuid) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('inv_fin_year', current_setting('gd.cur_fy')::int, 'gr_id', p_grn, 'gr_no', p_gr_no, 'customer_id', current_setting('gd.cust'),
    'customer_name', 'Gst Required Customer', 'inv_date', now(), 'total', 0, 'tax_amount', 0, 'discount', 0, 'duration_mode', 'legacy', 'inv_no', p_no, 'request_key', 'gd-rk-' || p_no,
    'items', jsonb_build_array(jsonb_build_object('disp_trl_id', p_line, 'charge', 7, 'tax', 5, 'labour_rate', 1))) $$;
CREATE FUNCTION pg_temp.gd_save(p_no integer, p_grn uuid, p_gr_no text, p_line uuid) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.gd_as(current_setting('gd.admin_claims')::jsonb, format($q$SELECT pg_temp.gd_save_invoice(pg_temp.gd_doc(%s, %L::uuid, %L, %L::uuid))$q$, p_no, p_grn, p_gr_no, p_line)) $$;
CREATE FUNCTION pg_temp.gd_save_gst() RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.gd_as(current_setting('gd.admin_claims')::jsonb,
    $q$SELECT public.set_gst_details('{"registered":true,"gstin":"24AAAAA0000A1Z5","address":"1 Demo Road, Demo City","legal_name":"Gst Required Cold Storage"}'::jsonb)$q$) $$;
SELECT public.suggest_document_number('invoice', :'today'::date) AS next_before \gset

-- ===== 1. no GST details: each of the three paths is refused, nothing is written, no number is used =====
-- Path 1, the invoice form.
SELECT pg_temp.gd_save(900001, :'grn_a'::uuid, 'GDA1', :'line_a'::uuid) AS form_none \gset
SELECT pg_temp.gd_assert(pg_temp.gd_refused(:'form_none'::jsonb), 'no details: the invoice form save is refused with GST_DETAILS_REQUIRED: ' || :'form_none');
-- Path 2, the GRN's create-invoice button: the form the server builds for the GRN (WH-162), saved as it is.
SELECT pg_temp.gd_as(:'admin_claims'::jsonb, format($q$SELECT public.generate_invoice_data_for_grn_with_pricing(%L::uuid)$q$, :'grn_b')) AS form_b \gset
SELECT pg_temp.gd_assert(jsonb_array_length(COALESCE(:'form_b'::jsonb->'items', '[]'::jsonb)) = 1, 'the GRN form still opens and offers its one dispatch line: ' || :'form_b');
SELECT pg_temp.gd_save(900002, :'grn_b'::uuid, 'GDB1', :'line_b'::uuid) AS grn_none \gset
SELECT pg_temp.gd_assert(pg_temp.gd_refused(:'grn_none'::jsonb), 'no details: the GRN create-invoice save is refused with GST_DETAILS_REQUIRED: ' || :'grn_none');
-- Path 3, goods invoiced as they leave: the lines of the dispatch that asked for the bill, saved as one.
SELECT pg_temp.gd_save(900003, :'grn_c'::uuid, 'GDC1', :'line_c'::uuid) AS leave_none \gset
SELECT pg_temp.gd_assert(pg_temp.gd_refused(:'leave_none'::jsonb), 'no details: the invoice of goods that left is refused with GST_DETAILS_REQUIRED: ' || :'leave_none');
-- Nothing written, no number used.
SELECT pg_temp.gd_assert((SELECT count(*) FROM public.invoice) = 0 AND (SELECT count(*) FROM public.invoice_trl) = 0, 'the refusals wrote no invoice and no line');
SELECT pg_temp.gd_assert((SELECT count(*) FROM public.invoice WHERE inv_no IN (900001, 900002, 900003)) = 0, 'no invoice number was used');
SELECT pg_temp.gd_assert(public.suggest_document_number('invoice', :'today'::date) = :'next_before'::jsonb, 'the next invoice number is unchanged');
SELECT pg_temp.gd_assert(warehouse_security.grn_invoice_state(:'grn_a'::uuid) = 'not_invoiced', 'the receipt is still not invoiced');
SELECT pg_temp.gd_assert((SELECT count(*) FROM public.idempotency_keys WHERE idempotency_key LIKE 'gd-rk-%') = 0, 'a refusal leaves no request-key row');
SELECT pg_temp.gd_assert((SELECT NOT bool_or(invoiced) FROM public.goodsreceived WHERE gr_no IN ('GDA1', 'GDB1', 'GDC1')), 'the receipts are not marked invoiced');
SELECT pg_temp.gd_save(900001, :'grn_a'::uuid, 'GDA1', :'line_a'::uuid) AS form_none2 \gset
SELECT pg_temp.gd_assert(pg_temp.gd_refused(:'form_none2'::jsonb), 'refused again with the same answer: ' || :'form_none2');
-- Details that were saved and then cleared read as not saved: the same refusal.
SELECT pg_temp.gd_save_gst() AS gst1 \gset
SELECT pg_temp.gd_assert(:'gst1'::jsonb->>'success' = 'true' AND pg_temp.gd_saved(), 'GST details saved: ' || :'gst1');
SELECT pg_temp.gd_clear_gst();
SELECT pg_temp.gd_assert(NOT pg_temp.gd_saved(), 'cleared again');
SELECT pg_temp.gd_save(900001, :'grn_a'::uuid, 'GDA1', :'line_a'::uuid) AS form_cleared \gset
SELECT pg_temp.gd_assert(pg_temp.gd_refused(:'form_cleared'::jsonb), 'cleared details: refused: ' || :'form_cleared');

-- ===== 1b. saved as NOT registered counts as no GST details (card points 6 and 7) =====
SELECT pg_temp.gd_set_not_registered();
SELECT pg_temp.gd_assert(warehouse_security.gst_settings()->>'registered' = 'false', 'the store is saved as not registered');
SELECT pg_temp.gd_as(:'admin_claims'::jsonb, 'SELECT public.can_make_bills()') AS cmb_nr \gset
SELECT pg_temp.gd_as(:'admin_claims'::jsonb, 'SELECT public.get_gst_details()') AS details_nr \gset
SELECT pg_temp.gd_assert((:'cmb_nr'::jsonb#>>'{data,allowed}') = 'false' AND (:'details_nr'::jsonb#>>'{data,bills_allowed}') = 'false', 'not registered: can_make_bills and bills_allowed say false: ' || :'cmb_nr' || left(:'details_nr', 200));
SELECT pg_temp.gd_save(900001, :'grn_a'::uuid, 'GDA1', :'line_a'::uuid) AS nr_form \gset
SELECT pg_temp.gd_assert(pg_temp.gd_refused(:'nr_form'::jsonb), 'not registered: the invoice form save is refused with GST_DETAILS_REQUIRED: ' || :'nr_form');
SELECT pg_temp.gd_save(900002, :'grn_b'::uuid, 'GDB1', :'line_b'::uuid) AS nr_grn \gset
SELECT pg_temp.gd_assert(pg_temp.gd_refused(:'nr_grn'::jsonb), 'not registered: the GRN create-invoice save is refused: ' || :'nr_grn');
SELECT pg_temp.gd_save(900003, :'grn_c'::uuid, 'GDC1', :'line_c'::uuid) AS nr_leave \gset
SELECT pg_temp.gd_assert(pg_temp.gd_refused(:'nr_leave'::jsonb), 'not registered: the invoice of goods that left is refused: ' || :'nr_leave');
SELECT pg_temp.gd_assert((SELECT count(*) FROM public.invoice) = 0, 'not registered: nothing written');
SELECT pg_temp.gd_assert(public.suggest_document_number('invoice', :'today'::date) = :'next_before'::jsonb, 'not registered: the next invoice number is unchanged');
-- Saving details with no GSTIN is refused whatever the registered choice (point 6), so a store cannot leave itself here through the screen.
SELECT pg_temp.gd_as(:'admin_claims'::jsonb, $q$SELECT public.set_gst_details('{"registered":true,"gstin":"","address":"1 Demo Road, Demo City"}'::jsonb)$q$) AS empty_gstin \gset
SELECT pg_temp.gd_assert(:'empty_gstin'::jsonb->>'state' = '22023', 'an empty GSTIN is refused: ' || :'empty_gstin');
SELECT pg_temp.gd_as(:'admin_claims'::jsonb, $q$SELECT public.set_gst_details('{"registered":false,"address":"1 Demo Road, Demo City"}'::jsonb)$q$) AS unreg_save \gset
SELECT pg_temp.gd_assert(:'unreg_save'::jsonb->>'state' = '22023' AND :'unreg_save'::jsonb->>'raised' LIKE '%GSTIN%', 'saving as not registered (no GSTIN) is refused: ' || :'unreg_save');
SELECT pg_temp.gd_assert(warehouse_security.gst_settings()->>'registered' = 'false', 'the refused saves left the stored state as it was');

-- ===== 2. once saved with a GSTIN, each path succeeds =====
SELECT pg_temp.gd_save_gst() AS gst2 \gset
SELECT pg_temp.gd_assert(:'gst2'::jsonb->>'success' = 'true' AND pg_temp.gd_saved(), 'GST details saved with a GSTIN: ' || :'gst2');
SELECT pg_temp.gd_save(900001, :'grn_a'::uuid, 'GDA1', :'line_a'::uuid) AS form_ok \gset
SELECT pg_temp.gd_assert(:'form_ok'::jsonb->>'success' = 'true', 'saved: the invoice form saves, with the number refused before: ' || :'form_ok');
SELECT pg_temp.gd_save(900002, :'grn_b'::uuid, 'GDB1', :'line_b'::uuid) AS grn_ok \gset
SELECT pg_temp.gd_assert(:'grn_ok'::jsonb->>'success' = 'true', 'saved: the GRN create-invoice save works: ' || :'grn_ok');
SELECT pg_temp.gd_save(900003, :'grn_c'::uuid, 'GDC1', :'line_c'::uuid) AS leave_ok \gset
SELECT pg_temp.gd_assert(:'leave_ok'::jsonb->>'success' = 'true', 'saved: the invoice of goods that left saves: ' || :'leave_ok');
SELECT pg_temp.gd_assert((SELECT count(*) FROM public.invoice WHERE inv_no IN (900001, 900002, 900003) AND import_batch_id IS NULL) >= 3, 'the three bills exist');
-- Bills of supply for exempt items are unchanged (point 8): a registered store still issues one for exempt storage.
SELECT pg_temp.gd_save(900005, :'grn_e'::uuid, 'GDE1', :'line_e'::uuid) AS exempt_ok \gset
SELECT pg_temp.gd_assert(:'exempt_ok'::jsonb->>'success' = 'true', 'saved: a bill for an exempt item saves: ' || :'exempt_ok');
SELECT pg_temp.gd_assert((SELECT doc_type = 'bill_of_supply' FROM public.invoice WHERE id = (:'exempt_ok'::jsonb->>'invoice_id')::uuid), 'it is a bill of supply, as before');
SELECT (:'form_ok'::jsonb->>'invoice_id')::uuid AS inv_a, (:'grn_ok'::jsonb->>'invoice_id')::uuid AS inv_b, (:'leave_ok'::jsonb->>'invoice_id')::uuid AS inv_c \gset

-- ===== 2b. the state the app reads (contract: can_make_bills, get_gst_details.bills_allowed) and the saved row =====
SELECT pg_temp.gd_assert(warehouse_security.gst_settings()->>'registered' = 'true', 'a save stores gstRegistered true');
SELECT pg_temp.gd_as(:'admin_claims'::jsonb, 'SELECT public.get_gst_details()') AS details_ok \gset
SELECT pg_temp.gd_assert((:'details_ok'::jsonb#>>'{data,bills_allowed}')::boolean IS TRUE, 'get_gst_details answers bills_allowed true: ' || left(:'details_ok', 300));
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
  (gen_random_uuid(),'919888888953','Gst Required Staff','staff',true,'approved'),
  (gen_random_uuid(),'919888888954','Gst Required Supervisor','supervisor',true,'approved'),
  (gen_random_uuid(),'919888888955','Gst Required Client','customer',true,'approved');
SELECT pg_temp.gd_login('9888888953') AS staff_claims, pg_temp.gd_login('9888888954') AS sup_claims, pg_temp.gd_login('9888888955') AS client_claims \gset
SELECT pg_temp.gd_as(:'admin_claims'::jsonb, 'SELECT public.can_make_bills()') AS cmb_admin \gset
SELECT pg_temp.gd_as(:'sup_claims'::jsonb, 'SELECT public.can_make_bills()') AS cmb_sup \gset
SELECT pg_temp.gd_as(:'staff_claims'::jsonb, 'SELECT public.can_make_bills()') AS cmb_staff \gset
SELECT pg_temp.gd_as(:'client_claims'::jsonb, 'SELECT public.can_make_bills()') AS cmb_client \gset
SELECT pg_temp.gd_assert((:'cmb_admin'::jsonb#>>'{data,allowed}') = 'true' AND (:'cmb_sup'::jsonb#>>'{data,allowed}') = 'true' AND (:'cmb_staff'::jsonb#>>'{data,allowed}') = 'true'
  AND :'cmb_admin'::jsonb->>'success' = 'true', 'saved: can_make_bills is true for administrator, supervisor and staff: ' || :'cmb_admin' || :'cmb_sup' || :'cmb_staff');
SELECT pg_temp.gd_assert(COALESCE(:'cmb_client'::jsonb->>'success', 'false') <> 'true' AND NOT (:'cmb_client'::jsonb ? 'data'), 'a customer is refused can_make_bills: ' || :'cmb_client');
-- set_gst_details refuses "not registered" and a missing GSTIN with nothing stored (contract D5).
SELECT value AS row_before FROM public.system_settings WHERE key = 'facility_legal' \gset
SELECT pg_temp.gd_as(:'admin_claims'::jsonb, $q$SELECT public.set_gst_details('{"registered":false,"gstin":"24AAAAA0000A1Z5","address":"1 Demo Road, Demo City"}'::jsonb)$q$) AS unreg_with_gstin \gset
SELECT pg_temp.gd_assert(:'unreg_with_gstin'::jsonb->>'state' = '22023' AND :'unreg_with_gstin'::jsonb->>'raised' LIKE 'Bills need a GSTIN%', 'registered:false is refused 22023 "Bills need a GSTIN...": ' || :'unreg_with_gstin');
SELECT pg_temp.gd_as(:'admin_claims'::jsonb, $q$SELECT public.set_gst_details('{"address":"1 Demo Road, Demo City"}'::jsonb)$q$) AS no_gstin \gset
SELECT pg_temp.gd_assert(:'no_gstin'::jsonb->>'state' = '22023', 'a save with no GSTIN is refused: ' || :'no_gstin');
SELECT pg_temp.gd_assert((SELECT value FROM public.system_settings WHERE key = 'facility_legal') = :'row_before', 'the refused saves stored nothing');
-- A resend (same request_key) of a bill saved before the details were cleared returns the stored answer, not the refusal.
SELECT pg_temp.gd_clear_gst();
SELECT pg_temp.gd_save(900001, :'grn_a'::uuid, 'GDA1', :'line_a'::uuid) AS resend \gset
SELECT pg_temp.gd_assert(:'resend'::jsonb->>'success' = 'true' AND :'resend'::jsonb->>'invoice_id' = :'form_ok'::jsonb->>'invoice_id', 'a resend of a saved bill returns the stored answer: ' || :'resend');
SELECT pg_temp.gd_assert((SELECT count(*) FROM public.invoice WHERE inv_no = 900001) = 1, 'the resend made no second bill');
SELECT pg_temp.gd_save_gst() AS gst3 \gset
SELECT pg_temp.gd_assert(:'gst3'::jsonb->>'success' = 'true', 'details saved again: ' || :'gst3');

-- ===== 3. a bill made before can be edited and cancelled with no GST details (never saved, cleared, or not registered) =====
SELECT pg_temp.gd_clear_gst();
SELECT pg_temp.gd_assert(NOT pg_temp.gd_saved(), 'details cleared with bills already made');
SELECT pg_temp.gd_as(:'admin_claims'::jsonb, format($q$SELECT pg_temp.gd_update_invoice(%L::uuid, pg_temp.gd_doc(900001, %L::uuid, 'GDA1', %L::uuid) || '{"notes":"edited with no GST details","request_key":"gd-rk-edit1"}'::jsonb)$q$,
  :'inv_a', :'grn_a', :'line_a')) AS edit_old \gset
SELECT pg_temp.gd_assert(:'edit_old'::jsonb->>'success' = 'true' AND NOT (:'edit_old'::jsonb ? 'raised'), 'an earlier bill is edited with no GST details: ' || :'edit_old');
SELECT pg_temp.gd_assert((SELECT notes = 'edited with no GST details' FROM public.invoice WHERE id = :'inv_a'::uuid), 'the edit was stored');
SELECT pg_temp.gd_as(:'admin_claims'::jsonb, format($q$SELECT public.cancel_invoice(%L::uuid, 'Cancelled with no GST details', NULL)$q$, :'inv_b')) AS cancel_old \gset
SELECT pg_temp.gd_assert(:'cancel_old'::jsonb->>'success' = 'true' AND NOT (:'cancel_old'::jsonb ? 'raised'), 'an earlier bill is cancelled with no GST details: ' || :'cancel_old');
SELECT pg_temp.gd_assert((SELECT cancelled_at IS NOT NULL FROM public.invoice WHERE id = :'inv_b'::uuid), 'the cancellation was stored');
-- A new bill is still refused at the same moment (the rule is for making bills, not for the old ones).
SELECT pg_temp.gd_save(900004, :'grn_b'::uuid, 'GDB1', :'line_b'::uuid) AS new_none \gset
SELECT pg_temp.gd_assert(pg_temp.gd_refused(:'new_none'::jsonb), 'a new bill is still refused with no GST details: ' || :'new_none');
-- The same on a store saved as not registered.
SELECT pg_temp.gd_set_not_registered();
SELECT pg_temp.gd_as(:'admin_claims'::jsonb, format($q$SELECT pg_temp.gd_update_invoice(%L::uuid, pg_temp.gd_doc(900001, %L::uuid, 'GDA1', %L::uuid) || '{"notes":"edited when not registered","request_key":"gd-rk-edit2"}'::jsonb)$q$,
  :'inv_a', :'grn_a', :'line_a')) AS edit_nr \gset
SELECT pg_temp.gd_assert(:'edit_nr'::jsonb->>'success' = 'true' AND NOT (:'edit_nr'::jsonb ? 'raised'), 'not registered: an earlier bill is edited: ' || :'edit_nr');
SELECT pg_temp.gd_as(:'admin_claims'::jsonb, format($q$SELECT public.cancel_invoice(%L::uuid, 'Cancelled when not registered', NULL)$q$, :'inv_c')) AS cancel_nr \gset
SELECT pg_temp.gd_assert(:'cancel_nr'::jsonb->>'success' = 'true' AND NOT (:'cancel_nr'::jsonb ? 'raised'), 'not registered: an earlier bill is cancelled: ' || :'cancel_nr');

-- ===== 4. imported bills (WH-180) are outside the rule =====
SELECT pg_temp.gd_clear_gst();
SELECT pg_temp.gd_assert(NOT pg_temp.gd_saved(), 'no GST details for the import');
INSERT INTO warehouse_import.stage_grns(line,gr_no,gr_date,customer,pricing) VALUES (2,'GDI1',:'today'::date - 90,'Gst Required Customer','MONTHLY');
INSERT INTO warehouse_import.stage_grn_lines(line,gr_no,gr_date,line_no,item,packaging,qty,weight,stock_now) VALUES (2,'GDI1',:'today'::date - 90,1,'Gst Required Potato','Bag',20,50,15);
INSERT INTO warehouse_import.stage_dispatches(line,disp_no,disp_date,customer) VALUES (2,'GDI1',:'today'::date - 70,'Gst Required Customer');
INSERT INTO warehouse_import.stage_dispatch_lines(line,disp_no,disp_date,gr_no,gr_date,grn_line,qty) VALUES (2,'GDI1',:'today'::date - 70,'GDI1',:'today'::date - 90,1,5);
INSERT INTO warehouse_import.stage_invoices(line,inv_label,inv_no,inv_prefix,inv_date,customer,gr_no,gr_date,labour,tax,total) VALUES
 (2,'OLD25',25,'OLD',:'today'::date - 65,'Gst Required Customer','GDI1',:'today'::date - 90,10.00,0.00,110.00);
INSERT INTO warehouse_import.stage_invoice_lines(line,inv_label,inv_no,inv_date,item,packaging,qty,disp_no,disp_date,grn_line,rate,labour_rate,tax_pct,storage,labour,tax_amount) VALUES
 (2,'OLD25',25,:'today'::date - 65,'Gst Required Potato','Bag',5,'GDI1',:'today'::date - 70,1,20.00,2.00,0,100.00,10.00,0.00);
SELECT pg_temp.gd_svc($q$SELECT public.import_history('{}'::jsonb, true)$q$) AS imported \gset
SELECT pg_temp.gd_assert(:'imported'::jsonb->>'success' = 'true' AND NOT (:'imported'::jsonb ? 'raised'), 'an old bill imports with no GST details: ' || left(:'imported', 600));
SELECT pg_temp.gd_assert((SELECT count(*) = 1 AND bool_and(total = 110) FROM public.invoice WHERE import_batch_id IS NOT NULL), 'the imported bill keeps its figures as issued');
SELECT pg_temp.gd_assert(NOT pg_temp.gd_saved(), 'the import did not save GST details');

-- ===== 5. one shared rule, one gate (contract: warehouse_security.bills_allowed(), called by save_invoice_internal) =====
SELECT pg_temp.gd_assert(to_regprocedure('warehouse_security.bills_allowed()') IS NOT NULL, 'warehouse_security.bills_allowed() exists');
SELECT pg_temp.gd_assert(NOT has_function_privilege('authenticated', 'warehouse_security.bills_allowed()', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'warehouse_security.bills_allowed()', 'EXECUTE'), 'bills_allowed is not granted to a client role');
SELECT pg_temp.gd_assert((SELECT count(*) FROM pg_proc WHERE prosrc LIKE '%GST_DETAILS_REQUIRED%') = 1
  AND (SELECT prosrc LIKE '%bills_allowed%' FROM pg_proc WHERE proname = 'save_invoice_internal' AND prosrc LIKE '%GST_DETAILS_REQUIRED%'), 'the refusal code lives in save_invoice_internal, which calls bills_allowed()');
-- Every function that inserts a bill calls the shared rule, apart from the imports (outside the rule) and the second document of a split save
-- (inside a save that passed the gate).
SELECT pg_temp.gd_assert((SELECT count(*) FROM pg_proc p WHERE p.prosrc ~* 'insert\s+into\s+(public\.)?invoice\s*\(' AND p.proname NOT IN ('import_history', 'import_batch', 'apply_invoice_gst')) >= 1,
  'the bill-making functions are found');
SELECT pg_temp.gd_assert(NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.prosrc ~* 'insert\s+into\s+(public\.)?invoice\s*\(' AND p.proname NOT IN ('import_history', 'import_batch', 'apply_invoice_gst')
    AND p.prosrc NOT LIKE '%bills_allowed%'),
  'every function that inserts a bill calls bills_allowed(): ' ||
  COALESCE((SELECT string_agg(p.oid::regprocedure::text, ', ') FROM pg_proc p WHERE p.prosrc ~* 'insert\s+into\s+(public\.)?invoice\s*\(' AND p.proname NOT IN ('import_history', 'import_batch', 'apply_invoice_gst')
    AND p.prosrc NOT LIKE '%bills_allowed%'), ''));
SELECT pg_temp.gd_assert(NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.proname IN ('import_history', 'import_batch', 'update_invoice', 'cancel_invoice') AND p.prosrc LIKE '%bills_allowed%'),
  'imports, edits and cancels do not call the gate');
ROLLBACK;
\echo 'Bills need GST details: three bill paths refused with no details or not registered, succeed once saved, old bills editable and cancellable, imports outside, one shared rule.'

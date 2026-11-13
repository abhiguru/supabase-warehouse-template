-- WH-190 (migrations 189, 192, 198): an invoice number is taken by its full number (prefix and number), not only its digits. The facility's
-- prefix is INV2 and the previous system's invoice is INV + 25: both read INV25 (unique_inv_label_per_year). The import's own check reports a
-- clash with an app invoice by name (not a raw unique violation), an app save of number 5 and an edit of another invoice to number 5 answer
-- NUMBER_TAKEN, and a free number still saves. An import apply takes the app saves' number lock 71040 and a dry run does not.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.nt_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'invoice number taken: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.nt_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.nt_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.nt_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
CREATE FUNCTION pg_temp.nt_as(claims jsonb, statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',claims::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN answer := jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  EXECUTE 'RESET ROLE';
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.nt_svc(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  EXECUTE 'SET LOCAL ROLE service_role';
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN answer := jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  EXECUTE 'RESET ROLE';
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.nt_save_invoice(doc jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.save_invoice(NULL::uuid, doc - 'items', ARRAY(
    SELECT jsonb_build_object('grn_item_id', (SELECT d.gr_trl_id FROM public.dispatch_trl d WHERE d.id = (i->>'disp_trl_id')::uuid), 'duration', 1) || i
    FROM jsonb_array_elements(doc->'items') i)) $$;
CREATE FUNCTION pg_temp.nt_update_invoice(p_id uuid, doc jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.update_invoice(p_id, doc - 'items', ARRAY(
    SELECT jsonb_build_object('grn_item_id', (SELECT d.gr_trl_id FROM public.dispatch_trl d WHERE d.id = (i->>'disp_trl_id')::uuid), 'duration', 1) || i
    FROM jsonb_array_elements(doc->'items') i)) $$;
-- Whether this session holds the app saves' number lock (advisory 71040).
CREATE FUNCTION pg_temp.nt_holds_lock() RETURNS boolean LANGUAGE sql AS $$
  SELECT EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid() AND classid = 0 AND objid = 71040 AND granted) $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888888941','Number Taken Administrator') AS boot \gset
SELECT pg_temp.nt_login('9888888941') AS admin_claims \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE mobile = '919888888941' \gset
SELECT warehouse_security.business_date(now()) AS today \gset
SELECT warehouse_security.financial_year(:'today'::date) AS cur_fy \gset
INSERT INTO public.customers(name,mobile) VALUES ('Number Taken Customer','9888888942') RETURNING id AS cust \gset
INSERT INTO public.items(name,packaging) VALUES ('Number Taken Potato','Bag') RETURNING id AS item_id \gset
UPDATE warehouse_security.charging_rule SET step_days = 15, minimum_days = 30, days_counted = 'legacy', rounding = 'up', invoice_as_goods_leave = true WHERE id;
SELECT pg_temp.nt_as(:'admin_claims'::jsonb, $q$SELECT public.set_record_payments(true)$q$) AS pay_on \gset
-- The facility's invoice prefix is INV2.
UPDATE warehouse_security.document_numbering SET prefix = 'INV2' WHERE document_type = 'invoice';
SELECT pg_temp.nt_assert(warehouse_security.invoice_prefix_for_year(:'cur_fy'::int) = 'INV2', 'the facility prefix is INV2: ' || warehouse_security.invoice_prefix_for_year(:'cur_fy'::int));

-- ===== the lock: an apply takes it, a dry run does not =====
SELECT pg_temp.nt_assert(NOT pg_temp.nt_holds_lock(), 'this session holds no number lock at the start');
SELECT pg_temp.nt_svc($q$SELECT public.import_history('{}'::jsonb, false)$q$) AS dry_empty \gset
SELECT pg_temp.nt_assert(:'dry_empty'::jsonb->>'success' = 'true' AND NOT pg_temp.nt_holds_lock(), 'a dry run takes no number lock: ' || :'dry_empty');

-- ===== the previous system's invoice INV + 25 =====
INSERT INTO warehouse_import.stage_grns(line,gr_no,gr_date,customer,pricing) VALUES (2,'A0001',:'today'::date - 60,'Number Taken Customer','MONTHLY');
INSERT INTO warehouse_import.stage_grn_lines(line,gr_no,gr_date,line_no,item,packaging,qty,weight,stock_now) VALUES (2,'A0001',:'today'::date - 60,1,'Number Taken Potato','Bag',20,50,15);
INSERT INTO warehouse_import.stage_dispatches(line,disp_no,disp_date,customer) VALUES (2,'I0001',:'today'::date - 10,'Number Taken Customer');
INSERT INTO warehouse_import.stage_dispatch_lines(line,disp_no,disp_date,gr_no,gr_date,grn_line,qty) VALUES (2,'I0001',:'today'::date - 10,'A0001',:'today'::date - 60,1,5);
INSERT INTO warehouse_import.stage_invoices(line,inv_label,inv_no,inv_prefix,inv_date,customer,gr_no,gr_date,labour,tax,total) VALUES
 (2,'INV25',25,'INV',:'today'::date - 5,'Number Taken Customer','A0001',:'today'::date - 60,10.00,0.00,110.00);
INSERT INTO warehouse_import.stage_invoice_lines(line,inv_label,inv_no,inv_date,item,packaging,qty,disp_no,disp_date,grn_line,rate,labour_rate,tax_pct,storage,labour,tax_amount) VALUES
 (2,'INV25',25,:'today'::date - 5,'Number Taken Potato','Bag',5,'I0001',:'today'::date - 10,1,20.00,2.00,0,100.00,10.00,0.00);
SELECT pg_temp.nt_svc($q$SELECT public.import_history('{}'::jsonb, true)$q$) AS imported \gset
SELECT pg_temp.nt_assert(:'imported'::jsonb->>'success' = 'true' AND pg_temp.nt_holds_lock(), 'an apply takes the number lock and holds it to the end of the transaction: ' || :'imported');
SELECT pg_temp.nt_assert((SELECT inv_prefix = 'INV' AND inv_no = 25 FROM public.invoice WHERE import_batch_id IS NOT NULL), 'the imported invoice is INV + 25');

-- ===== app saves =====
SELECT pg_temp.nt_as(:'admin_claims'::jsonb, format($q$SELECT public.save_grn(p_gr_no=>'A0002',p_date=>%L::timestamptz,p_customer_id=>%L::uuid,p_customer_name=>'x',p_pricing_mode=>'MONTHLY',
  p_idempotency_key=>'nt-g2',p_items=>jsonb_build_array(jsonb_build_object('item_id',%L,'item_name','Number Taken Potato','packaging','Bag','qty',30,'weight',50,'rack','R1')))$q$,
  (:'today'::date - 40)::text || 'T12:00:00Z', :'cust', :'item_id')) AS g2 \gset
SELECT pg_temp.nt_assert(:'g2'::jsonb->>'success' = 'true', 'an app GRN: ' || :'g2');
SELECT id AS g2_id FROM public.goodsreceived WHERE gr_no = 'A0002' \gset
SELECT id AS g2_lot FROM public.goodsreceived_trl WHERE gr_id = :'g2_id'::uuid \gset
CREATE FUNCTION pg_temp.nt_dispatch(p_no text, p_qty integer) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.nt_as(current_setting('nt.admin_claims')::jsonb, format($q$SELECT public.create_dispatch_with_stock_check(jsonb_build_object('disp_no',%L,'disp_date',%L,
    'customer_id',%L,'customer_name','x','supervisor_id',%L,'supervisor_name','x'),ARRAY[jsonb_build_object('gr_trl_id',%L,'disp_qty',%s)],false,0,%L)$q$,
    p_no, (warehouse_security.business_date(now()) - 2)::text || 'T12:00:00Z', current_setting('nt.cust'), current_setting('nt.admin_profile'), current_setting('nt.g2_lot'), p_qty, 'nt-' || p_no)) $$;
SELECT set_config('nt.admin_claims', :'admin_claims', true) AS s1, set_config('nt.cust', :'cust', true) AS s2, set_config('nt.admin_profile', :'admin_profile', true) AS s3,
       set_config('nt.g2_lot', :'g2_lot', true) AS s4 \gset
SELECT pg_temp.nt_dispatch('I0002', 3) AS d2, pg_temp.nt_dispatch('I0003', 3) AS d3 \gset
SELECT pg_temp.nt_assert(:'d2'::jsonb->>'success' = 'true' AND :'d3'::jsonb->>'success' = 'true', 'two app dispatches: ' || :'d2' || :'d3');
SELECT t.id AS dl2 FROM public.dispatch_trl t JOIN public.dispatch d ON d.id = t.disp_id WHERE d.disp_no = 'I0002' \gset
SELECT t.id AS dl3 FROM public.dispatch_trl t JOIN public.dispatch d ON d.id = t.disp_id WHERE d.disp_no = 'I0003' \gset
CREATE FUNCTION pg_temp.nt_doc(p_no integer, p_line uuid) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('inv_fin_year', current_setting('nt.cur_fy')::int, 'gr_id', current_setting('nt.g2_id'), 'gr_no', 'A0002', 'customer_id', current_setting('nt.cust'),
    'customer_name', 'Number Taken Customer', 'inv_date', now(), 'total', 0, 'tax_amount', 0, 'discount', 0, 'duration_mode', 'legacy', 'inv_no', p_no,
    'items', jsonb_build_array(jsonb_build_object('disp_trl_id', p_line, 'charge', 7, 'tax', 0, 'labour_rate', 1))) $$;
SELECT set_config('nt.cur_fy', :'cur_fy', true) AS s5, set_config('nt.g2_id', :'g2_id', true) AS s6 \gset
-- INV2 + 5 is INV25, which the imported invoice holds: refused by name, nothing written.
SELECT pg_temp.nt_as(:'admin_claims'::jsonb, format($q$SELECT pg_temp.nt_save_invoice(pg_temp.nt_doc(5, %L::uuid))$q$, :'dl2')) AS save5 \gset
SELECT pg_temp.nt_assert(:'save5'::jsonb->>'success' = 'false' AND :'save5'::jsonb::text LIKE '%NUMBER_TAKEN%' AND NOT (:'save5'::jsonb ? 'raised'),
  'an app save of number 5 (INV25) answers NUMBER_TAKEN, not a raw unique violation: ' || :'save5');
SELECT pg_temp.nt_assert((SELECT count(*) FROM public.invoice WHERE import_batch_id IS NULL) = 0, 'the refused save wrote nothing');
-- A free number saves; the number 25 itself is refused too (INV2 + 25 is INV225 but the digits are taken in the year).
SELECT pg_temp.nt_as(:'admin_claims'::jsonb, format($q$SELECT pg_temp.nt_save_invoice(pg_temp.nt_doc(6, %L::uuid))$q$, :'dl2')) AS save6 \gset
SELECT pg_temp.nt_assert(:'save6'::jsonb->>'success' = 'true', 'a free number saves: ' || :'save6');
SELECT pg_temp.nt_assert((SELECT inv_prefix = 'INV2' AND inv_no = 6 FROM public.invoice WHERE import_batch_id IS NULL), 'the app invoice is INV2 + 6');
SELECT (:'save6'::jsonb->>'invoice_id')::uuid AS inv6 \gset
SELECT pg_temp.nt_as(:'admin_claims'::jsonb, format($q$SELECT pg_temp.nt_save_invoice(pg_temp.nt_doc(25, %L::uuid))$q$, :'dl3')) AS save25 \gset
SELECT pg_temp.nt_assert(:'save25'::jsonb->>'success' = 'false' AND :'save25'::jsonb::text LIKE '%NUMBER_TAKEN%', 'number 25 itself is taken: ' || :'save25');
-- An edit of another invoice to number 5 is refused the same way; to a free number it saves.
SELECT pg_temp.nt_as(:'admin_claims'::jsonb, format($q$SELECT pg_temp.nt_update_invoice(%L::uuid, pg_temp.nt_doc(5, %L::uuid))$q$, :'inv6', :'dl2')) AS edit5 \gset
SELECT pg_temp.nt_assert(:'edit5'::jsonb->>'success' = 'false' AND :'edit5'::jsonb::text LIKE '%NUMBER_TAKEN%' AND NOT (:'edit5'::jsonb ? 'raised'),
  'an edit to number 5 answers NUMBER_TAKEN: ' || :'edit5');
SELECT pg_temp.nt_assert((SELECT inv_no = 6 FROM public.invoice WHERE id = :'inv6'::uuid), 'the refused edit changed nothing');
SELECT pg_temp.nt_as(:'admin_claims'::jsonb, format($q$SELECT pg_temp.nt_update_invoice(%L::uuid, pg_temp.nt_doc(7, %L::uuid))$q$, :'inv6', :'dl2')) AS edit7 \gset
SELECT pg_temp.nt_assert(:'edit7'::jsonb->>'success' = 'true' AND (SELECT inv_no = 7 FROM public.invoice WHERE id = :'inv6'::uuid), 'an edit to a free number saves: ' || :'edit7');

-- ===== the import's own check: an app invoice INV2 + 5 against a later imported INV + 25 (a second import) =====
-- The app invoice INV2 + 7 now exists; a file with INV + 27 is a clash of the full number, reported by the import (nothing saved), not raised.
TRUNCATE warehouse_import.stage_grns, warehouse_import.stage_grn_lines, warehouse_import.stage_dispatches, warehouse_import.stage_dispatch_lines,
  warehouse_import.stage_invoices, warehouse_import.stage_invoice_lines, warehouse_import.stage_payments;
INSERT INTO warehouse_import.stage_grns(line,gr_no,gr_date,customer,pricing) VALUES (2,'A0003',:'today'::date - 60,'Number Taken Customer','MONTHLY');
INSERT INTO warehouse_import.stage_grn_lines(line,gr_no,gr_date,line_no,item,packaging,qty,weight,stock_now) VALUES (2,'A0003',:'today'::date - 60,1,'Number Taken Potato','Bag',20,50,15);
INSERT INTO warehouse_import.stage_dispatches(line,disp_no,disp_date,customer) VALUES (2,'I0010',:'today'::date - 10,'Number Taken Customer');
INSERT INTO warehouse_import.stage_dispatch_lines(line,disp_no,disp_date,gr_no,gr_date,grn_line,qty) VALUES (2,'I0010',:'today'::date - 10,'A0003',:'today'::date - 60,1,5);
INSERT INTO warehouse_import.stage_invoices(line,inv_label,inv_no,inv_prefix,inv_date,customer,gr_no,gr_date,labour,tax,total) VALUES
 (2,'INV27',27,'INV',:'today'::date - 5,'Number Taken Customer','A0003',:'today'::date - 60,10.00,0.00,110.00);
INSERT INTO warehouse_import.stage_invoice_lines(line,inv_label,inv_no,inv_date,item,packaging,qty,disp_no,disp_date,grn_line,rate,labour_rate,tax_pct,storage,labour,tax_amount) VALUES
 (2,'INV27',27,:'today'::date - 5,'Number Taken Potato','Bag',5,'I0010',:'today'::date - 10,1,20.00,2.00,0,100.00,10.00,0.00);
SELECT pg_temp.nt_svc($q$SELECT public.import_history('{}'::jsonb, true)$q$) AS clash \gset
SELECT pg_temp.nt_assert(:'clash'::jsonb->>'success' = 'false' AND NOT (:'clash'::jsonb ? 'raised') AND :'clash'::jsonb::text LIKE '%is used by an invoice made in the app%'
  AND :'clash'::jsonb::text LIKE '%INV27%', 'the import reports INV + 27 against the app invoice INV2 + 7 by name: ' || left(:'clash', 700));
SELECT pg_temp.nt_assert((SELECT count(*) FROM public.invoice WHERE import_batch_id IS NOT NULL) = 1, 'the refused import saved nothing');
ROLLBACK;
\echo 'Invoice number taken: the full number (prefix and number) is checked by saves, edits and the import; an apply takes the number lock, a dry run does not.'

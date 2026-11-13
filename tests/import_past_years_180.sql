-- WH-180: the import of past years (migrations 189 to 192). Marks and number uniqueness (189), imported documents are read-only (190),
-- they read as issued (191), the import itself (192), and rates on an imported GRN. Fictional data; runs only in migrations.sh's
-- disposable, network-disabled database. The files are staged the way scripts/import.mjs stages them (warehouse_import.stage_*), and
-- public.import_history is called as the service role, as scripts/import.sh does.
--
-- The fixture (the shape of scripts/import-templates): customer Import Demo Traders; GRN A0001 of 2023-05-05 (100 bags, 30 left) and another
-- GRN of the same number A0001 of 2024-05-06 (10 bags, 5 left); dispatches I0001 (60 bags) and I0002 (10 bags) of 2023-06-14 and
-- 2023-07-01 from the first, and I0004 (5 bags, 2024-07-01) from the second, which is on no invoice; invoice GC/125 of 2023-06-20 for I0001
-- (storage 4,130.00 + labour 120.00 = 4,250.00, where the rates would give far less) and GC/310 of 2023-07-05 for I0002 (520.00);
-- payment IMP-R1 of 3,250.00 on GC/125. The numbers follow the facility's numbering (A####, I####): the import does not check them, the app does.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.ip_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'import of past years: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.ip_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.ip_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.ip_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
-- The jsonb answer of a statement run as the signed-in caller, or {"raised": message, "state": sqlstate}.
CREATE FUNCTION pg_temp.ip_as(claims jsonb, statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',claims::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN answer := jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  EXECUTE 'RESET ROLE';
  RETURN answer;
END $$;
-- The same as the service role (the operator's key).
CREATE FUNCTION pg_temp.ip_svc(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  EXECUTE 'SET LOCAL ROLE service_role';
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN answer := jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  EXECUTE 'RESET ROLE';
  RETURN answer;
END $$;
-- Whether a statement raises this SQLSTATE (run as the database owner, so the guard's trigger is what answers).
CREATE FUNCTION pg_temp.ip_raises(statement text, expected text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE statement;
  EXCEPTION WHEN OTHERS THEN IF SQLSTATE ~ ('^(' || expected || ')$') THEN RETURN true; END IF; RAISE EXCEPTION 'expected SQLSTATE %, got % (%) for: %', expected, SQLSTATE, SQLERRM, left(statement, 120); END;
  RETURN false;
END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888888901','Import Demo Administrator') AS boot \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888902','Import Demo Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888903','Import Demo Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919888888904','Import Demo Customer User','customer',true,'approved');
SELECT pg_temp.ip_login('9888888901') AS admin_claims \gset
SELECT pg_temp.ip_login('9888888902') AS staff_claims \gset
SELECT pg_temp.ip_login('9888888903') AS supervisor_claims \gset
SELECT pg_temp.ip_login('9888888904') AS customer_claims \gset
SELECT set_config('ip.admin_claims', :'admin_claims', true) AS c1, set_config('ip.supervisor_claims', :'supervisor_claims', true) AS c2,
       set_config('ip.staff_claims', :'staff_claims', true) AS c3, set_config('ip.customer_claims', :'customer_claims', true) AS c4 \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE mobile = '919888888901' \gset
INSERT INTO public.customers(name,mobile) VALUES ('Import Demo Traders','9888888911') RETURNING id AS trader \gset
INSERT INTO public.customers(name,mobile) VALUES ('Import Demo Other','9888888912') RETURNING id AS other \gset
INSERT INTO public.items(name,packaging) VALUES ('Import Demo Potato','Bag') RETURNING id AS item_id \gset
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active)
 SELECT id,:'trader'::uuid,true FROM public.user_profiles WHERE mobile='919888888904';
-- The app's rates for the item (an imported invoice must not follow them).
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.replace_item_rates(%L::uuid,NULL,'monthly',(current_date - 700),
  '[{"weight_min":0,"weight_max":100,"unit_price":5,"labour_rate":1,"tax_percent":0}]'::jsonb)$q$, :'item_id')) AS rates \gset
SELECT pg_temp.ip_assert(:'rates'::jsonb->>'success'='true','general rates: '||:'rates');
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, $q$SELECT public.set_record_payments(true)$q$) AS pay_on \gset
SELECT pg_temp.ip_assert(:'pay_on'::jsonb->>'success'='true','record payments on');
-- The facility's charging rule as a fresh install has it, Invoice as goods leave on (earlier suites of the shared test database may leave another).
UPDATE warehouse_security.charging_rule SET step_days = 15, minimum_days = 30, days_counted = 'legacy', rounding = 'up', invoice_as_goods_leave = true WHERE id;

-- ===== the files, staged =====
INSERT INTO warehouse_import.stage_grns(line,gr_no,gr_date,customer,pricing) VALUES
 (2,'A0001','2023-05-05','Import Demo Traders','MONTHLY'),
 (3,'A0001','2024-05-06','Import Demo Traders','MONTHLY');
INSERT INTO warehouse_import.stage_grn_lines(line,gr_no,gr_date,line_no,item,packaging,qty,weight,rack,mark,stock_now) VALUES
 (2,'A0001','2023-05-05',1,'Import Demo Potato','Bag',100,50,'A1','ET',30),
 (3,'A0001','2024-05-06',1,'Import Demo Potato','Bag',10,50,'A2','ET',5);
INSERT INTO warehouse_import.stage_dispatches(line,disp_no,disp_date,customer) VALUES
 (2,'I0001','2023-06-14','Import Demo Traders'),
 (3,'I0002','2023-07-01','Import Demo Traders'),
 (4,'I0004','2024-07-01','Import Demo Traders');
INSERT INTO warehouse_import.stage_dispatch_lines(line,disp_no,disp_date,gr_no,gr_date,grn_line,qty) VALUES
 (2,'I0001','2023-06-14','A0001','2023-05-05',1,60),
 (3,'I0002','2023-07-01','A0001','2023-05-05',1,10),
 (4,'I0004','2024-07-01','A0001','2024-05-06',1,5);
INSERT INTO warehouse_import.stage_invoices(line,inv_label,inv_no,inv_prefix,inv_date,customer,gr_no,gr_date,labour,tax,total) VALUES
 (2,'GC/125',125,'GC/','2023-06-20','Import Demo Traders','A0001','2023-05-05',120.00,0.00,4250.00),
 (3,'GC/310',310,'GC/','2023-07-05','Import Demo Traders','A0001','2023-05-05',20.00,0.00,520.00);
INSERT INTO warehouse_import.stage_invoice_lines(line,inv_label,inv_no,inv_date,item,packaging,qty,disp_no,disp_date,grn_line,months,rate,labour_rate,tax_pct,storage,labour,tax_amount) VALUES
 (2,'GC/125',125,'2023-06-20','Import Demo Potato','Bag',60,'I0001','2023-06-14',1,1.5,45.00,2.00,0,4130.00,120.00,0.00),
 (3,'GC/310',310,'2023-07-05','Import Demo Potato','Bag',10,'I0002','2023-07-01',1,1,50.00,2.00,0,500.00,20.00,0.00);
INSERT INTO warehouse_import.stage_payments(line,receipt,pay_date,customer,inv_label,inv_no,inv_date,amount,mode) VALUES
 (2,'IMP-R1','2023-06-30','Import Demo Traders','GC/125',125,'2023-06-20',3250.00,'Cash');

-- ===== 1. the call is the operator's only =====
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, $q$SELECT public.import_history('{}'::jsonb, false)$q$) AS as_admin \gset
SELECT pg_temp.ip_assert(:'as_admin'::jsonb ? 'raised', 'an administrator is refused import_history: ' || :'as_admin');
SELECT pg_temp.ip_assert(:'as_admin'::jsonb->>'state' = '42501', 'the refusal is insufficient_privilege: ' || :'as_admin');
SELECT pg_temp.ip_as(:'staff_claims'::jsonb, $q$SELECT public.import_history('{}'::jsonb, false)$q$) AS as_staff \gset
SELECT pg_temp.ip_assert(:'as_staff'::jsonb ? 'raised', 'staff are refused import_history');
SELECT pg_temp.ip_assert(NOT has_function_privilege('anon', 'public.import_history(jsonb, boolean)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.import_history(jsonb, boolean)', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.import_history(jsonb, boolean)', 'EXECUTE'), 'import_history is granted to the service role only');
-- The new tables and the staging tables give no access to the app's roles (or to the service role).
SELECT pg_temp.ip_assert(NOT EXISTS (
  SELECT 1 FROM unnest(ARRAY['warehouse_security.import_batches','warehouse_security.imported_documents','warehouse_security.imported_grn_lines',
    'warehouse_import.stage_grns','warehouse_import.stage_grn_lines','warehouse_import.stage_dispatches','warehouse_import.stage_dispatch_lines',
    'warehouse_import.stage_invoices','warehouse_import.stage_invoice_lines','warehouse_import.stage_payments']) t
  CROSS JOIN unnest(ARRAY['anon','authenticated','service_role']) r
  CROSS JOIN unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE']) p
  WHERE has_table_privilege(r, t, p)), 'no role of the app can read or write the import tables');
SELECT pg_temp.ip_assert((SELECT bool_and(relrowsecurity) FROM pg_class WHERE oid IN ('warehouse_security.import_batches'::regclass,
  'warehouse_security.imported_documents'::regclass, 'warehouse_security.imported_grn_lines'::regclass)), 'row security is on for the import records');
SELECT pg_temp.ip_assert(NOT has_column_privilege('anon', 'public.invoice', 'import_batch_id', 'SELECT')
  AND has_column_privilege('authenticated', 'public.invoice', 'import_batch_id', 'SELECT'), 'the mark on invoice is readable by signed-in users only');

-- ===== 2. a dry run saves nothing =====
SELECT pg_temp.ip_svc($q$SELECT public.import_history('{}'::jsonb, false)$q$) AS dry \gset
SELECT pg_temp.ip_assert(:'dry'::jsonb->>'success' = 'true' AND :'dry'::jsonb->>'applied' = 'false', 'the dry run is clean: ' || :'dry');
SELECT pg_temp.ip_assert((:'dry'::jsonb#>>'{files,grns,add}')::int = 2 AND (:'dry'::jsonb#>>'{files,invoices,add}')::int = 2
  AND (:'dry'::jsonb#>>'{files,payments,add}')::int = 1, 'the dry run counts what it would add: ' || :'dry');
SELECT pg_temp.ip_assert((SELECT count(*) FROM public.goodsreceived WHERE import_batch_id IS NOT NULL) = 0
  AND (SELECT count(*) FROM public.invoice WHERE import_batch_id IS NOT NULL) = 0
  AND (SELECT count(*) FROM warehouse_security.import_batches) = 0, 'a dry run wrote nothing');

-- ===== 3. the import =====
SELECT pg_temp.ip_svc($q$SELECT public.import_history('{}'::jsonb, true)$q$) AS applied \gset
SELECT pg_temp.ip_assert(:'applied'::jsonb->>'success' = 'true' AND :'applied'::jsonb->>'applied' = 'true', 'the import applies: ' || :'applied');
SELECT pg_temp.ip_assert((SELECT count(*) FROM public.goodsreceived WHERE import_batch_id IS NOT NULL) = 2
  AND (SELECT count(*) FROM public.dispatch WHERE import_batch_id IS NOT NULL) = 3
  AND (SELECT count(*) FROM public.invoice WHERE import_batch_id IS NOT NULL) = 2
  AND (SELECT count(*) FROM public.payments WHERE import_batch_id IS NOT NULL) = 1
  AND (SELECT count(*) FROM warehouse_security.import_batches WHERE applied_at IS NOT NULL) = 1
  AND (SELECT count(*) FROM warehouse_security.imported_documents) = 8, 'two GRNs, three dispatches, two invoices, one payment, marked and recorded');
-- Two imported GRNs with the same number on different dates are accepted (and read apart).
SELECT pg_temp.ip_assert((SELECT count(*) FROM public.goodsreceived WHERE gr_no = 'A0001') = 2, 'A0001 twice, on two dates');
SELECT id AS grn1 FROM public.goodsreceived WHERE gr_no = 'A0001' AND import_batch_id IS NOT NULL ORDER BY date LIMIT 1 \gset
SELECT id AS grn2 FROM public.goodsreceived WHERE gr_no = 'A0001' AND import_batch_id IS NOT NULL ORDER BY date DESC LIMIT 1 \gset
SELECT id AS disp1 FROM public.dispatch WHERE disp_no = 'I0001' \gset
SELECT id AS disp2 FROM public.dispatch WHERE disp_no = 'I0002' \gset
SELECT id AS disp4 FROM public.dispatch WHERE disp_no = 'I0004' \gset
SELECT id AS inv125 FROM public.invoice WHERE inv_no = 125 AND inv_fin_year = 2023 \gset
SELECT id AS inv310 FROM public.invoice WHERE inv_no = 310 AND inv_fin_year = 2023 \gset
SELECT id AS pay1 FROM public.payments WHERE import_batch_id IS NOT NULL \gset
SELECT id AS lot1 FROM public.goodsreceived_trl WHERE gr_id = :'grn1'::uuid \gset
SELECT pg_temp.ip_assert((SELECT stock FROM public.goodsreceived_trl WHERE id = :'lot1'::uuid) = 30
  AND (SELECT stock FROM public.goodsreceived_trl WHERE gr_id = :'grn2'::uuid) = 5, 'stock is received less dispatched');
SELECT pg_temp.ip_assert((SELECT inv_prefix FROM public.invoice WHERE id = :'inv125'::uuid) = 'GC/'
  AND (SELECT total FROM public.invoice WHERE id = :'inv125'::uuid) = 4250.00, 'an imported invoice keeps its prefix and its total');
SELECT pg_temp.ip_assert((SELECT created_by FROM public.goodsreceived WHERE id = :'grn1'::uuid) = (SELECT id FROM public.user_profiles WHERE auth_user_id = '00000000-0000-4000-8000-696d706f7274'),
  'the documents are made by the Import actor');
-- Run again: everything is "already there", nothing is added.
SELECT pg_temp.ip_svc($q$SELECT public.import_history('{}'::jsonb, true)$q$) AS again \gset
SELECT pg_temp.ip_assert(:'again'::jsonb->>'success' = 'true' AND (:'again'::jsonb#>>'{files,grns,add}')::int = 0
  AND (:'again'::jsonb#>>'{files,grns,skip}')::int = 2 AND (:'again'::jsonb#>>'{files,invoices,skip}')::int = 2
  AND (:'again'::jsonb#>>'{files,payments,skip}')::int = 1, 'a second run reports everything as already there: ' || :'again');
SELECT pg_temp.ip_assert((SELECT count(*) FROM public.goodsreceived WHERE import_batch_id IS NOT NULL) = 2
  AND (SELECT count(*) FROM public.payments WHERE import_batch_id IS NOT NULL) = 1, 'a second run added no row');
-- The same file with one figure changed is refused, nothing saved.
UPDATE warehouse_import.stage_invoices SET total = 4251.00 WHERE inv_no = 125;
SELECT pg_temp.ip_svc($q$SELECT public.import_history('{}'::jsonb, true)$q$) AS changed \gset
SELECT pg_temp.ip_assert(:'changed'::jsonb->>'success' = 'false' AND :'changed'::jsonb->>'applied' = 'false', 'a changed document is an error: ' || :'changed');
SELECT pg_temp.ip_assert((SELECT total FROM public.invoice WHERE id = :'inv125'::uuid) = 4250.00, 'the stored invoice is as imported');
UPDATE warehouse_import.stage_invoices SET total = 4250.00 WHERE inv_no = 125;

-- ===== 4. migration 189: numbers =====
-- The same number and date again is refused by the index; an app GRN cannot take an imported number.
CREATE TEMP TABLE ip_copy ON COMMIT DROP AS SELECT * FROM public.goodsreceived WHERE id = :'grn1'::uuid;
UPDATE ip_copy SET id = gen_random_uuid();
SELECT set_config('warehouse.import', 'on', true);
SELECT pg_temp.ip_assert(pg_temp.ip_raises('INSERT INTO public.goodsreceived SELECT * FROM ip_copy', '23505'), 'the same imported number on the same date is refused');
UPDATE ip_copy SET date = date + interval '1 year';
SAVEPOINT sp_other_year;
INSERT INTO public.goodsreceived SELECT * FROM ip_copy;
SELECT pg_temp.ip_assert((SELECT count(*) FROM public.goodsreceived WHERE gr_no = 'A0001') = 3, 'the same number on another date is accepted');
ROLLBACK TO SAVEPOINT sp_other_year;
UPDATE ip_copy SET date = NULL;
SELECT pg_temp.ip_assert(pg_temp.ip_raises('INSERT INTO public.goodsreceived SELECT * FROM ip_copy', '23502|23514'), 'an imported GRN with no date is refused');
UPDATE ip_copy SET date = (SELECT date FROM public.goodsreceived WHERE id = :'grn1'::uuid), import_batch_id = NULL;
SELECT set_config('warehouse.import', '', true);
-- An app GRN with a number an imported GRN holds is refused by save_grn (and an app duplicate of an app number too).
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.save_grn(p_gr_no=>'A0001',p_date=>now(),p_customer_id=>%L::uuid,p_customer_name=>'Import Demo Traders',
  p_pricing_mode=>'MONTHLY',p_idempotency_key=>'ip-dup-imported',p_items=>jsonb_build_array(jsonb_build_object('item_id',%L,'item_name','Import Demo Potato','packaging','Bag','qty',5,'weight',50,'rack','X1')))$q$,
  :'trader', :'item_id')) AS dup_imported \gset
SELECT pg_temp.ip_assert(:'dup_imported'::jsonb->>'success' IS DISTINCT FROM 'true', 'save_grn refuses a number an imported GRN holds: ' || :'dup_imported');
SELECT pg_temp.ip_assert((SELECT count(*) FROM public.goodsreceived WHERE gr_no = 'A0001' AND import_batch_id IS NULL) = 0, 'no app GRN took the imported number');
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.save_grn(p_gr_no=>'A0002',p_date=>now(),p_customer_id=>%L::uuid,p_customer_name=>'Import Demo Traders',
  p_pricing_mode=>'MONTHLY',p_idempotency_key=>'ip-app-1',p_items=>jsonb_build_array(jsonb_build_object('item_id',%L,'item_name','Import Demo Potato','packaging','Bag','qty',20,'weight',50,'rack','X1')))$q$,
  :'trader', :'item_id')) AS app1 \gset
SELECT pg_temp.ip_assert(:'app1'::jsonb->>'success' = 'true', 'an app GRN is saved: ' || :'app1');
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.save_grn(p_gr_no=>'A0002',p_date=>now(),p_customer_id=>%L::uuid,p_customer_name=>'Import Demo Traders',
  p_pricing_mode=>'MONTHLY',p_idempotency_key=>'ip-app-2',p_items=>jsonb_build_array(jsonb_build_object('item_id',%L,'item_name','Import Demo Potato','packaging','Bag','qty',21,'weight',50,'rack','X1')))$q$,
  :'trader', :'item_id')) AS app_dup \gset
SELECT pg_temp.ip_assert(:'app_dup'::jsonb->>'success' IS DISTINCT FROM 'true', 'an app duplicate number is refused: ' || :'app_dup');
-- A dispatch number held by an imported dispatch is refused for the app.
SELECT id AS app_lot FROM public.goodsreceived_trl WHERE gr_id = (SELECT id FROM public.goodsreceived WHERE gr_no = 'A0002') \gset
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','I0001','disp_date',now(),
  'customer_id',%L,'customer_name','Import Demo Traders','supervisor_id',%L,'supervisor_name','Import Demo Administrator'),
  ARRAY[jsonb_build_object('gr_trl_id',%L,'disp_qty',1)],false,0,'ip-dup-disp')$q$, :'trader', :'admin_profile', :'app_lot')) AS dup_disp \gset
SELECT pg_temp.ip_assert(:'dup_disp'::jsonb->>'success' IS DISTINCT FROM 'true', 'create_dispatch refuses a number an imported dispatch holds: ' || :'dup_disp');
SELECT pg_temp.ip_assert((SELECT count(*) FROM public.dispatch WHERE disp_no = 'I0001') = 1 AND (SELECT stock FROM public.goodsreceived_trl WHERE id = :'app_lot'::uuid) = 20,
  'the refused dispatch took no stock');
-- The invoice prefix of a year ignores imported invoices, and the next number follows the highest imported one.
SELECT pg_temp.ip_assert(warehouse_security.invoice_prefix_for_year(2023) = COALESCE((SELECT n.prefix FROM warehouse_security.document_numbering n WHERE n.document_type = 'invoice'), ''),
  'invoice_prefix_for_year ignores imported rows: ' || warehouse_security.invoice_prefix_for_year(2023));
SELECT warehouse_security.document_number_suggestion('invoice', DATE '2023-08-01', 2023) AS suggestion \gset
SELECT pg_temp.ip_assert(:'suggestion'::jsonb->>'number' = '311', 'after imported invoices up to 310 the next is 311: ' || :'suggestion');
SELECT warehouse_security.document_number_suggestion('grn', DATE '2023-08-01', NULL) AS grn_suggestion \gset
SELECT pg_temp.ip_assert(:'grn_suggestion'::jsonb->>'number' IS DISTINCT FROM 'A0001', 'the GRN suggestion is not a number an imported GRN holds');

-- ===== 5. migration 190: imported documents are read-only =====
-- (a) the table guard: every direct change is refused, even for the database owner and the service role.
SELECT pg_temp.ip_assert(pg_temp.ip_raises(format($q$UPDATE public.goodsreceived SET note = 'x' WHERE id = %L$q$, :'grn1'), 'WH423'), 'UPDATE of an imported GRN is refused');
SELECT pg_temp.ip_assert(pg_temp.ip_raises(format($q$DELETE FROM public.goodsreceived WHERE id = %L$q$, :'grn1'), 'WH423'), 'DELETE of an imported GRN is refused');
SELECT pg_temp.ip_assert(pg_temp.ip_raises(format($q$UPDATE public.goodsreceived SET deleted_at = now() WHERE id = %L$q$, :'grn1'), 'WH423'), 'a soft delete of an imported GRN is refused');
SELECT pg_temp.ip_assert(pg_temp.ip_raises(format($q$UPDATE public.goodsreceived SET import_batch_id = NULL WHERE id = %L$q$, :'grn1'), 'WH423'), 'clearing the mark is refused');
SELECT id AS app_grn FROM public.goodsreceived WHERE gr_no = 'A0002' \gset
SELECT pg_temp.ip_assert(pg_temp.ip_raises(format($q$UPDATE public.goodsreceived SET import_batch_id = (SELECT id FROM warehouse_security.import_batches LIMIT 1) WHERE id = %L$q$, :'app_grn'), 'WH423'),
  'setting the mark on an app GRN is refused outside the import');
SELECT pg_temp.ip_assert(pg_temp.ip_raises(format($q$UPDATE public.goodsreceived_trl SET qty = qty + 1 WHERE id = %L$q$, :'lot1'), 'WH423'), 'UPDATE of an imported GRN line is refused');
SELECT pg_temp.ip_assert(pg_temp.ip_raises(format($q$DELETE FROM public.goodsreceived_trl WHERE id = %L$q$, :'lot1'), 'WH423'), 'DELETE of an imported GRN line is refused');
SELECT pg_temp.ip_assert(pg_temp.ip_raises(format($q$INSERT INTO public.goodsreceived_trl(gr_id,item_id,item_name,packaging,qty,stock,weight) VALUES (%L,%L,'Import Demo Potato','Bag',1,1,50)$q$, :'grn1', :'item_id'), 'WH423'),
  'a line cannot be added to an imported GRN');
SELECT pg_temp.ip_assert(pg_temp.ip_raises(format($q$UPDATE public.dispatch SET registration = 'X' WHERE id = %L$q$, :'disp1'), 'WH423'), 'UPDATE of an imported dispatch is refused');
SELECT pg_temp.ip_assert(pg_temp.ip_raises(format($q$DELETE FROM public.dispatch WHERE id = %L$q$, :'disp1'), 'WH423'), 'DELETE of an imported dispatch is refused');
SELECT pg_temp.ip_assert(pg_temp.ip_raises(format($q$UPDATE public.dispatch_trl SET disp_qty = 1 WHERE disp_id = %L$q$, :'disp1'), 'WH423'), 'UPDATE of an imported dispatch line is refused');
SELECT pg_temp.ip_assert(pg_temp.ip_raises(format($q$DELETE FROM public.dispatch_trl WHERE disp_id = %L$q$, :'disp1'), 'WH423'), 'DELETE of an imported dispatch line is refused');
SELECT pg_temp.ip_assert(pg_temp.ip_raises(format($q$UPDATE public.invoice SET total = 1 WHERE id = %L$q$, :'inv125'), 'WH423'), 'UPDATE of an imported invoice is refused');
SELECT pg_temp.ip_assert(pg_temp.ip_raises(format($q$UPDATE public.invoice SET cancelled_at = now() WHERE id = %L$q$, :'inv125'), 'WH423'), 'a cancel of an imported invoice is refused');
SELECT pg_temp.ip_assert(pg_temp.ip_raises(format($q$DELETE FROM public.invoice WHERE id = %L$q$, :'inv125'), 'WH423'), 'DELETE of an imported invoice is refused');
SELECT pg_temp.ip_assert(pg_temp.ip_raises(format($q$UPDATE public.invoice_trl SET charge = 1 WHERE invoice_id = %L$q$, :'inv125'), 'WH423'), 'UPDATE of an imported invoice line is refused');
SELECT pg_temp.ip_assert(pg_temp.ip_raises(format($q$DELETE FROM public.invoice_trl WHERE invoice_id = %L$q$, :'inv125'), 'WH423'), 'DELETE of an imported invoice line is refused');
SELECT pg_temp.ip_assert(pg_temp.ip_raises(format($q$UPDATE public.payments SET amount = 1 WHERE id = %L$q$, :'pay1'), 'WH423'), 'UPDATE of an imported payment is refused');
SELECT pg_temp.ip_assert(pg_temp.ip_raises(format($q$DELETE FROM public.payments WHERE id = %L$q$, :'pay1'), 'WH423'), 'DELETE of an imported payment is refused');
-- The same as the service role (the operator's key): the table grants differ, the guard answers the same where a write is allowed at all.
SELECT pg_temp.ip_svc(format($q$SELECT to_jsonb(count(*)) FROM (SELECT 1 FROM public.goodsreceived WHERE id = %L) x$q$, :'grn1')) AS svc_read \gset
-- The refusal's text and hint.
DO $$
DECLARE v_hint text; v_raised boolean := false;
BEGIN
  BEGIN
    UPDATE public.goodsreceived SET note = 'x' WHERE import_batch_id IS NOT NULL;
  EXCEPTION WHEN SQLSTATE 'WH423' THEN
    v_raised := true;
    IF SQLERRM <> 'This GRN was imported from the previous system and can''t be changed.' THEN RAISE EXCEPTION 'import of past years: guard text: %', SQLERRM; END IF;
    GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT;
    IF v_hint <> 'IMPORTED_READ_ONLY' THEN RAISE EXCEPTION 'import of past years: guard hint: %', v_hint; END IF;
  END;
  IF NOT v_raised THEN RAISE EXCEPTION 'import of past years: the guard did not refuse'; END IF;
END $$;
-- Exceptions the app needs: a GRN's invoiced flag and out_of_stock, and a line's stock, may change.
SAVEPOINT sp_flags;
UPDATE public.goodsreceived SET invoiced = true, out_of_stock = true WHERE id = :'grn1'::uuid;
UPDATE public.goodsreceived_trl SET stock = stock WHERE id = :'lot1'::uuid;
ROLLBACK TO SAVEPOINT sp_flags;
-- Only the import may set or clear the mark: with warehouse.import on it can (the import's own bypass).
SAVEPOINT sp_bypass;
SELECT set_config('warehouse.import', 'on', true);
UPDATE public.goodsreceived SET note = 'bypass' WHERE id = :'grn2'::uuid;
SELECT pg_temp.ip_assert((SELECT note FROM public.goodsreceived WHERE id = :'grn2'::uuid) = 'bypass', 'the import setting lets the import write');
ROLLBACK TO SAVEPOINT sp_bypass;
SELECT pg_temp.ip_assert(current_setting('warehouse.import', true) IS DISTINCT FROM 'on', 'the bypass is transaction-local and gone after the rollback');
-- A photo is not added to an imported GRN.
SELECT pg_temp.ip_assert(pg_temp.ip_raises(format($q$INSERT INTO public.grn_images(grn_id, image_type, storage_path) VALUES (%L, 'grn', 'x/y.jpg')$q$, :'grn1'), 'WH423'), 'a photo cannot be added to an imported GRN');

-- (b) the RPCs answer before anything is written: every role, every function.
CREATE TEMP TABLE ip_calls(label text, statement text, document text) ON COMMIT DROP;
INSERT INTO ip_calls VALUES
 ('delete_grn_safe',                    format($q$SELECT public.delete_grn_safe(%L::uuid)$q$, :'grn1'), 'grn'),
 ('delete_dispatch_with_order_cleanup', format($q$SELECT public.delete_dispatch_with_order_cleanup(%L::uuid, NULL)$q$, :'disp1'), 'dispatch'),
 ('update_dispatch_smart',              format($q$SELECT public.update_dispatch_smart(%L::uuid, '{"registration":"X"}'::jsonb, ARRAY[]::jsonb[])$q$, :'disp1'), 'dispatch'),
 ('update_invoice',                     format($q$SELECT public.update_invoice(%L::uuid, '{"inv_name":"X"}'::jsonb, ARRAY[]::jsonb[])$q$, :'inv125'), 'invoice'),
 ('cancel_invoice',                     format($q$SELECT public.cancel_invoice(%L::uuid, 'testing', NULL)$q$, :'inv125'), 'invoice'),
 ('delete_invoice',                     format($q$SELECT public.delete_invoice(%L::uuid, NULL)$q$, :'inv125'), 'invoice'),
 ('delete_invoice_pair',                format($q$SELECT public.delete_invoice_pair(%L::uuid, NULL, NULL)$q$, :'inv125'), 'invoice'),
 ('update_payment',                     format($q$SELECT public.update_payment(%L::uuid, DATE '2023-06-30', 1, 'cash', NULL, NULL, NULL)$q$, :'pay1'), 'payment'),
 ('delete_payment',                     format($q$SELECT public.delete_payment(%L::uuid, NULL, NULL)$q$, :'pay1'), 'payment'),
 ('update_grn (quantity)',              format($q$SELECT public.update_grn(p_grn_id=>%L::uuid, p_items=>jsonb_build_array(jsonb_build_object('id',%L,'item_id',%L,'item_name','Import Demo Potato','packaging','Bag','qty',99,'weight',50,'rack','A1')))$q$, :'grn1', :'lot1', :'item_id'), 'grn'),
 ('update_grn (note)',                  format($q$SELECT public.update_grn(p_grn_id=>%L::uuid, p_note=>'new note', p_items=>jsonb_build_array(jsonb_build_object('id',%L,'item_id',%L,'item_name','Import Demo Potato','packaging','Bag','qty',100,'weight',50,'rack','A1')))$q$, :'grn1', :'lot1', :'item_id'), 'grn');
SELECT pg_temp.ip_assert((SELECT count(*) FROM ip_calls) = 11, 'the call list is complete');
DO $$
DECLARE c record; r text; a jsonb; claims jsonb;
BEGIN
  FOREACH r IN ARRAY ARRAY['admin','supervisor','staff','customer'] LOOP
    claims := current_setting('ip.' || r || '_claims')::jsonb;
    FOR c IN SELECT * FROM ip_calls LOOP
      a := pg_temp.ip_as(claims, c.statement);
      -- Refused one way or another: success false, or the gate raised. Never success true.
      IF a->>'success' = 'true' THEN RAISE EXCEPTION 'import of past years: % as % succeeded: %', c.label, r, a; END IF;
      -- Those the gate lets through (administrators and supervisors) are refused with the imported-document answer.
      IF r IN ('admin') AND NOT (a->>'reason' = 'IMPORTED_READ_ONLY' AND a->>'error_code' = 'WH409' AND a->>'document' = c.document) THEN
        RAISE EXCEPTION 'import of past years: % as % is not the imported answer: %', c.label, r, a;
      END IF;
    END LOOP;
  END LOOP;
END $$;

-- ===== 6. rates on an imported GRN (Product, 2026-11-12) =====
CREATE FUNCTION pg_temp.ip_items(p_grn uuid) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_agg(jsonb_build_object('id',t.id,'item_id',t.item_id,'item_name',t.item_name,'packaging',t.packaging,'qty',t.qty,
           'weight',t.weight,'rack',t.rack,'package_mark',t.package_mark) ORDER BY t.id)
  FROM public.goodsreceived_trl t WHERE t.gr_id = p_grn $$;
SELECT jsonb_build_array(jsonb_build_object('scope','grn','item_id',:'item_id','weight_min',0,'weight_max',100,'unit_price',7,'labour_rate',1,'tax_percent',0)) AS own_rates \gset
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.update_grn(p_grn_id=>%L::uuid,p_items=>%L::jsonb,p_rates=>%L::jsonb)$q$,
  :'grn1', pg_temp.ip_items(:'grn1'::uuid), :'own_rates')) AS rates_admin \gset
SELECT pg_temp.ip_assert(:'rates_admin'::jsonb->>'success' = 'true', 'an administrator sets rates on an imported GRN: ' || :'rates_admin');
SELECT pg_temp.ip_assert((SELECT count(*) FROM public.grn_rates WHERE gr_id = :'grn1'::uuid AND unit_price = 7) = 1, 'the GRN has its own rate');
SELECT updated_by AS sup_by0 FROM public.goodsreceived WHERE id = :'grn2'::uuid \gset
SELECT pg_temp.ip_as(:'supervisor_claims'::jsonb, format($q$SELECT public.update_grn(p_grn_id=>%L::uuid,p_items=>%L::jsonb,p_rates=>%L::jsonb)$q$,
  :'grn2', pg_temp.ip_items(:'grn2'::uuid), :'own_rates')) AS rates_sup \gset
SELECT pg_temp.ip_assert(:'rates_sup'::jsonb->>'success' = 'true', 'a supervisor sets rates on an imported GRN: ' || :'rates_sup');
SELECT pg_temp.ip_assert((SELECT updated_by FROM public.goodsreceived WHERE id = :'grn2'::uuid) = (SELECT id FROM public.user_profiles WHERE mobile = '919888888903') AND :'sup_by0' IS DISTINCT FROM (SELECT id::text FROM public.user_profiles WHERE mobile = '919888888903'), 'the rates save set updated_by to the supervisor (was: ' || :'sup_by0' || ')');
SELECT pg_temp.ip_as(:'staff_claims'::jsonb, format($q$SELECT public.update_grn(p_grn_id=>%L::uuid,p_items=>%L::jsonb,p_rates=>%L::jsonb)$q$,
  :'grn1', pg_temp.ip_items(:'grn1'::uuid), :'own_rates')) AS rates_staff \gset
SELECT pg_temp.ip_assert(:'rates_staff'::jsonb->>'success' = 'false' AND :'rates_staff'::jsonb->>'error_code' = 'RATES_MANAGER_ONLY', 'staff get RATES_MANAGER_ONLY: ' || :'rates_staff');
-- WH-190: a rates-only save is an edit: it sets updated_at and updated_by and answers the new token (grn.updated_at); a second save holding the
-- older token is STALE_RECORD.
-- (One transaction: now() does not move here, so the token value itself cannot be seen to change; updated_by, which the save sets, and the returned token can.)
SELECT updated_at AS tok0, updated_by AS by0 FROM public.goodsreceived WHERE id = :'grn1'::uuid \gset
SELECT jsonb_build_array(jsonb_build_object('scope','grn','item_id',:'item_id','weight_min',0,'weight_max',100,'unit_price',8,'labour_rate',1,'tax_percent',0)) AS own_rates8 \gset
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.update_grn(p_grn_id=>%L::uuid,p_items=>%L::jsonb,p_rates=>%L::jsonb,p_expected_updated_at=>%L::timestamptz)$q$,
  :'grn1', pg_temp.ip_items(:'grn1'::uuid), :'own_rates8', :'tok0')) AS tok_save1 \gset
SELECT updated_at AS tok1, updated_by AS tok1_by FROM public.goodsreceived WHERE id = :'grn1'::uuid \gset
SELECT pg_temp.ip_assert(:'tok_save1'::jsonb->>'success' = 'true' AND :'tok1_by'::uuid = :'admin_profile'::uuid
  AND (:'tok_save1'::jsonb#>>'{grn,updated_at}')::timestamptz = :'tok1'::timestamptz, 'a rates save sets updated_by and returns the token the table holds: ' || :'tok_save1');
SELECT jsonb_build_array(jsonb_build_object('scope','grn','item_id',:'item_id','weight_min',0,'weight_max',100,'unit_price',9,'labour_rate',1,'tax_percent',0)) AS own_rates9 \gset
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.update_grn(p_grn_id=>%L::uuid,p_items=>%L::jsonb,p_rates=>%L::jsonb,p_expected_updated_at=>%L::timestamptz)$q$,
  :'grn1', pg_temp.ip_items(:'grn1'::uuid), :'own_rates9', (:'tok0'::timestamptz - interval '1 hour')::text)) AS tok_stale \gset
SELECT pg_temp.ip_assert(:'tok_stale'::jsonb->>'success' = 'false' AND :'tok_stale'::jsonb::text LIKE '%STALE_RECORD%'
  AND (SELECT unit_price FROM public.grn_rates WHERE gr_id = :'grn1'::uuid) = 8, 'a second save with the older token is STALE_RECORD and wrote nothing: ' || :'tok_stale');
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.update_grn(p_grn_id=>%L::uuid,p_items=>%L::jsonb,p_rates=>%L::jsonb,p_expected_updated_at=>%L::timestamptz)$q$,
  :'grn1', pg_temp.ip_items(:'grn1'::uuid), :'own_rates9', :'tok1')) AS tok_save2 \gset
SELECT pg_temp.ip_assert(:'tok_save2'::jsonb->>'success' = 'true' AND (SELECT unit_price FROM public.grn_rates WHERE gr_id = :'grn1'::uuid) = 9, 'a save with the new token works: ' || :'tok_save2');
-- Anything but the rates is refused: a quantity, a date, a missing line, and no rates at all.
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.update_grn(p_grn_id=>%L::uuid,p_items=>%L::jsonb,p_rates=>%L::jsonb)$q$,
  :'grn1', (SELECT jsonb_agg(i || '{"qty":99}'::jsonb) FROM jsonb_array_elements(pg_temp.ip_items(:'grn1'::uuid)) i), :'own_rates')) AS rates_qty \gset
SELECT pg_temp.ip_assert(:'rates_qty'::jsonb->>'reason' = 'IMPORTED_READ_ONLY', 'a quantity change with the rates is refused: ' || :'rates_qty');
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.update_grn(p_grn_id=>%L::uuid,p_date=>'2023-05-06T12:00:00Z',p_items=>%L::jsonb,p_rates=>%L::jsonb)$q$,
  :'grn1', pg_temp.ip_items(:'grn1'::uuid), :'own_rates')) AS rates_date \gset
SELECT pg_temp.ip_assert(:'rates_date'::jsonb->>'reason' = 'IMPORTED_READ_ONLY', 'a date change with the rates is refused: ' || :'rates_date');
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.update_grn(p_grn_id=>%L::uuid,p_items=>'[]'::jsonb,p_rates=>%L::jsonb)$q$, :'grn1', :'own_rates')) AS rates_lines \gset
SELECT pg_temp.ip_assert(:'rates_lines'::jsonb->>'reason' = 'IMPORTED_READ_ONLY', 'a save with the lines missing is refused: ' || :'rates_lines');
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.update_grn(p_grn_id=>%L::uuid,p_note=>'changed',p_items=>%L::jsonb)$q$, :'grn1', pg_temp.ip_items(:'grn1'::uuid))) AS no_rates \gset
SELECT pg_temp.ip_assert(:'no_rates'::jsonb->>'reason' = 'IMPORTED_READ_ONLY', 'a save without rates is refused: ' || :'no_rates');
SELECT pg_temp.ip_assert((SELECT qty FROM public.goodsreceived_trl WHERE id = :'lot1'::uuid) = 100 AND (SELECT note FROM public.goodsreceived WHERE id = :'grn1'::uuid) IS NULL
  AND warehouse_security.business_date((SELECT date FROM public.goodsreceived WHERE id = :'grn1'::uuid)) = DATE '2023-05-05', 'nothing but the rate was written');


-- ===== 7. migration 191: imported documents read as issued =====
-- Invoice GC/125 is 4,250.00 although the rates (now including the GRN's own 7.00 a bag) would give far less; it reads 4,250.00 everywhere.
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, $q$SELECT public.get_invoices_list(p_limit=>50)$q$) AS inv_list \gset
SELECT pg_temp.ip_assert((SELECT (e->>'total')::numeric = 4250.00 AND (e->>'imported')::boolean AND (e->>'due_amount')::numeric = 1000.00 AND (e->>'paid_amount')::numeric = 3250.00
  FROM jsonb_array_elements(:'inv_list'::jsonb->'data') e WHERE e->>'invoice_id' = :'inv125'), 'the list reads GC/125 as issued, imported, with its payment: ' || :'inv_list');
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.get_invoice_detail(%L::uuid)$q$, :'inv125')) AS inv_detail \gset
SELECT pg_temp.ip_assert((:'inv_detail'::jsonb#>>'{invoice,total}')::numeric = 4250.00 AND (:'inv_detail'::jsonb#>>'{invoice,imported}')::boolean
  AND (:'inv_detail'::jsonb#>>'{items,0,storage_amount}')::numeric = 4130.00, 'the detail reads GC/125 as issued: ' || :'inv_detail');
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.get_invoice_items_detailed(%L::uuid)$q$, :'inv125')) AS inv_items \gset
SELECT pg_temp.ip_assert((SELECT sum((e->>'total_amount')::numeric) FROM jsonb_array_elements(:'inv_items'::jsonb#>'{data,items}') e) = 4250.00
  AND (SELECT sum((e->>'tax_amount')::numeric) FROM jsonb_array_elements(:'inv_items'::jsonb#>'{data,items}') e) = 0, 'the items read GC/125 as issued: ' || :'inv_items');
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.get_invoice_data(%L::uuid)$q$, :'inv125')) AS inv_data \gset
SELECT pg_temp.ip_assert(:'inv_data'::jsonb::text LIKE '%4130.00%' AND :'inv_data'::jsonb::text LIKE '%"imported": true%', 'the invoice data carries the issued storage amount and the mark: ' || :'inv_data');
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.get_dispatch_details(%L::uuid)$q$, :'disp1')) AS disp_detail \gset
SELECT pg_temp.ip_assert((:'disp_detail'::jsonb#>>'{data,dispatch,statistics,total_invoice_amount}')::numeric = 4250.00
  AND (:'disp_detail'::jsonb#>>'{data,dispatch,imported}')::boolean, 'the dispatch reads its invoice as issued: ' || :'disp_detail');
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.get_customer_statement(%L::uuid)$q$, :'trader')) AS stmt \gset
SELECT pg_temp.ip_assert((SELECT (e->>'total')::numeric = 4250.00 AND (e->>'due_amount')::numeric = 1000.00 AND (e->>'imported')::boolean
  FROM jsonb_array_elements(:'stmt'::jsonb->'invoices') e WHERE e->>'id' = :'inv125'), 'the statement reads GC/125 as issued: ' || :'stmt');
-- The mark on the other lists and details.
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.get_grn_details(%L::uuid)$q$, :'grn1')) AS grn_detail \gset
SELECT pg_temp.ip_assert((:'grn_detail'::jsonb#>>'{data,grn,imported}')::boolean OR (:'grn_detail'::jsonb#>>'{grn,imported}')::boolean, 'get_grn_details says imported: ' || :'grn_detail');
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, $q$SELECT public.get_all_grn_items(NULL, NULL, NULL, NULL, NULL, 50, 0)$q$) AS grn_items \gset
SELECT pg_temp.ip_assert(EXISTS (SELECT 1 FROM jsonb_array_elements(:'grn_items'::jsonb->'data') e WHERE (e->>'imported')::boolean), 'get_all_grn_items marks imported GRNs: ' || left(:'grn_items', 400));
SELECT pg_temp.ip_assert(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(:'grn_items'::jsonb->'data') e WHERE e->>'gr_no' = 'A0002' AND (e->>'imported')::boolean), 'an app GRN is not marked imported');

-- ===== 8. what the app may still do with imported documents (criterion 8) =====
CREATE FUNCTION pg_temp.ip_save_invoice(doc jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.save_invoice(NULL::uuid, doc - 'items', ARRAY(
    SELECT jsonb_build_object('grn_item_id', (SELECT d.gr_trl_id FROM public.dispatch_trl d WHERE d.id = (i->>'disp_trl_id')::uuid), 'duration', 1) || i
    FROM jsonb_array_elements(doc->'items') i)) $$;
SELECT id AS lot2 FROM public.goodsreceived_trl WHERE gr_id = :'grn2'::uuid \gset
-- A dispatch made in the app from an imported GRN's stock; its edit and delete put the stock back.
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','I0005','disp_date',now(),
  'customer_id',%L,'customer_name','Import Demo Traders','supervisor_id',%L,'supervisor_name','Import Demo Administrator'),
  ARRAY[jsonb_build_object('gr_trl_id',%L,'disp_qty',2)],false,0,'ip-app-disp')$q$, :'trader', :'admin_profile', :'lot2')) AS app_disp \gset
SELECT pg_temp.ip_assert(:'app_disp'::jsonb->>'success' = 'true', 'an app dispatch from an imported GRN is allowed: ' || :'app_disp');
SELECT pg_temp.ip_assert((SELECT stock FROM public.goodsreceived_trl WHERE id = :'lot2'::uuid) = 3, 'it took 2 bags of the imported lot (5 to 3)');
SELECT id AS app_disp_id FROM public.dispatch WHERE disp_no = 'I0005' \gset
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.delete_dispatch_with_order_cleanup(%L::uuid, NULL)$q$, :'app_disp_id')) AS app_disp_del \gset
SELECT pg_temp.ip_assert(:'app_disp_del'::jsonb->>'success' = 'true' AND (SELECT stock FROM public.goodsreceived_trl WHERE id = :'lot2'::uuid) = 5,
  'deleting that app dispatch puts the stock back: ' || :'app_disp_del');
-- An app invoice over an imported dispatch that was never billed (I0004), its cancel, and the imported documents unchanged.
SELECT d.id AS d4_line FROM public.dispatch_trl d WHERE d.disp_id = :'disp4'::uuid \gset
SELECT warehouse_security.financial_year(warehouse_security.business_date(now())) AS cur_fy \gset
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT pg_temp.ip_save_invoice(jsonb_build_object('inv_fin_year', %s,
  'gr_id', %L, 'gr_no', 'A0001', 'customer_id', %L, 'customer_name', 'Import Demo Traders', 'inv_date', now(), 'total', 0, 'tax_amount', 0, 'discount', 0,
  'duration_mode', 'legacy', 'inv_no', 1, 'items', jsonb_build_array(jsonb_build_object('disp_trl_id', %L, 'charge', 7, 'tax', 0, 'labour_rate', 1))))$q$,
  :'cur_fy', :'grn2', :'trader', :'d4_line')) AS app_inv \gset
SELECT pg_temp.ip_assert(:'app_inv'::jsonb->>'success' = 'true', 'an app invoice over an imported dispatch is allowed: ' || :'app_inv');
SELECT (:'app_inv'::jsonb->>'invoice_id')::uuid AS app_inv_id \gset
SELECT pg_temp.ip_assert((SELECT import_batch_id IS NULL FROM public.invoice WHERE id = :'app_inv_id'::uuid), 'the new invoice is an app invoice');
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.cancel_invoice(%L::uuid, 'test cancel', NULL)$q$, :'app_inv_id')) AS app_inv_cancel \gset
SELECT pg_temp.ip_assert(:'app_inv_cancel'::jsonb->>'success' = 'true', 'the app invoice can be cancelled: ' || :'app_inv_cancel');
-- An app payment on an imported invoice, and its edit and delete.
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.record_payment(%L::uuid, CURRENT_DATE, 100, 'cash')$q$, :'inv125')) AS app_pay \gset
SELECT pg_temp.ip_assert(:'app_pay'::jsonb->>'success' = 'true', 'an app payment on an imported invoice is allowed: ' || :'app_pay');
SELECT id AS app_pay_id, updated_at AS app_pay_at FROM public.payments WHERE invoice_id = :'inv125'::uuid AND import_batch_id IS NULL \gset
-- Migration 195: a payment says whether it was imported; the amounts do not change.
SELECT pg_temp.ip_assert((:'app_pay'::jsonb#>>'{payment,imported}')::boolean IS FALSE AND (:'app_pay'::jsonb#>>'{payment,amount}')::numeric = 100, 'record_payment answers imported false for an app payment: ' || :'app_pay');
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.get_invoice_detail(%L::uuid)$q$, :'inv125')) AS pay_detail \gset
SELECT pg_temp.ip_assert((SELECT count(*) FROM jsonb_array_elements(:'pay_detail'::jsonb#>'{invoice,payments}') p) = 2
  AND (SELECT (p->>'imported')::boolean AND (p->>'amount')::numeric = 3250.00 FROM jsonb_array_elements(:'pay_detail'::jsonb#>'{invoice,payments}') p WHERE p->>'id' = :'pay1')
  AND (SELECT NOT (p->>'imported')::boolean AND (p->>'amount')::numeric = 100.00 FROM jsonb_array_elements(:'pay_detail'::jsonb#>'{invoice,payments}') p WHERE p->>'id' = :'app_pay_id'),
  'the invoice detail lists the imported payment as imported and the app payment on the same invoice as not: ' || :'pay_detail');
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.update_payment(%L::uuid, CURRENT_DATE, 150, 'upi', %L::timestamptz)$q$, :'app_pay_id', :'app_pay_at')) AS app_pay_up \gset
SELECT pg_temp.ip_assert(:'app_pay_up'::jsonb->>'success' = 'true' AND (SELECT amount FROM public.payments WHERE id = :'app_pay_id'::uuid) = 150, 'the app payment can be edited: ' || :'app_pay_up');
SELECT pg_temp.ip_assert((:'app_pay_up'::jsonb#>>'{payment,imported}')::boolean IS FALSE AND (:'app_pay_up'::jsonb#>>'{payment,amount}')::numeric = 150
  AND (:'app_pay_up'::jsonb#>>'{previous,imported}')::boolean IS FALSE AND (:'app_pay_up'::jsonb#>>'{previous,amount}')::numeric = 100, 'update_payment answers imported false, amounts unchanged: ' || :'app_pay_up');
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.delete_payment(%L::uuid, NULL)$q$, :'app_pay_id')) AS app_pay_del \gset
SELECT pg_temp.ip_assert(:'app_pay_del'::jsonb->>'success' = 'true', 'the app payment can be deleted: ' || :'app_pay_del');
SELECT pg_temp.ip_assert((:'app_pay_del'::jsonb#>>'{deleted,imported}')::boolean IS FALSE AND (:'app_pay_del'::jsonb#>>'{deleted,amount}')::numeric = 150, 'delete_payment answers imported false: ' || :'app_pay_del');
-- Nothing imported changed through any of it.
SELECT pg_temp.ip_assert((SELECT total FROM public.invoice WHERE id = :'inv125'::uuid) = 4250.00
  AND (SELECT amount FROM public.payments WHERE id = :'pay1'::uuid) = 3250.00
  AND (SELECT count(*) FROM public.dispatch_trl WHERE disp_id IN (:'disp1'::uuid, :'disp2'::uuid, :'disp4'::uuid)) = 3
  AND (SELECT qty FROM public.goodsreceived_trl WHERE id = :'lot2'::uuid) = 10, 'the imported documents are as imported');

-- ===== 9. dispatches taken as billed (spec answer 4, criterion 20), and the note that is left =====
-- GRN A0901: dispatches I0901 (day D) and I0911 (D + 15); the imported invoice GC/901 is dated D and its line names no dispatch.
--   I0901 is taken as billed by GC/901; I0911 (dated after the invoice) is never billed.
-- GRN A0902: invoice GC/902 names its dispatch I0902; I0905 (same day, unnamed) has no unnamed invoice line to be taken by, so the note stays.
-- GRN A0903: a dispatch and no imported invoice: nothing. GRN A0904: its dispatch is imported now, its invoice in a later run.
SELECT warehouse_security.business_date(now()) AS today_ip \gset
SELECT warehouse_security.financial_year(warehouse_security.business_date(now())) AS cur_fy \gset
TRUNCATE warehouse_import.stage_grns, warehouse_import.stage_grn_lines, warehouse_import.stage_dispatches, warehouse_import.stage_dispatch_lines,
  warehouse_import.stage_invoices, warehouse_import.stage_invoice_lines, warehouse_import.stage_payments;
INSERT INTO warehouse_import.stage_grns(line,gr_no,gr_date,customer,pricing) VALUES
 (2,'A0901',:'today_ip'::date - 400,'Import Demo Traders','MONTHLY'), (3,'A0902',:'today_ip'::date - 400,'Import Demo Traders','MONTHLY'),
 (4,'A0903',:'today_ip'::date - 400,'Import Demo Traders','MONTHLY'), (5,'A0904',:'today_ip'::date - 400,'Import Demo Traders','MONTHLY');
INSERT INTO warehouse_import.stage_grn_lines(line,gr_no,gr_date,line_no,item,packaging,qty,weight,stock_now) VALUES
 (2,'A0901',:'today_ip'::date - 400,1,'Import Demo Potato','Bag',20,50,10), (3,'A0902',:'today_ip'::date - 400,1,'Import Demo Potato','Bag',20,50,10),
 (4,'A0903',:'today_ip'::date - 400,1,'Import Demo Potato','Bag',20,50,15), (5,'A0904',:'today_ip'::date - 400,1,'Import Demo Potato','Bag',20,50,15);
INSERT INTO warehouse_import.stage_dispatches(line,disp_no,disp_date,customer) VALUES
 (2,'I0901',:'today_ip'::date - 300,'Import Demo Traders'), (3,'I0911',:'today_ip'::date - 285,'Import Demo Traders'),
 (4,'I0902',:'today_ip'::date - 300,'Import Demo Traders'), (5,'I0905',:'today_ip'::date - 300,'Import Demo Traders'),
 (6,'I0903',:'today_ip'::date - 300,'Import Demo Traders'), (7,'I0904',:'today_ip'::date - 200,'Import Demo Traders');
INSERT INTO warehouse_import.stage_dispatch_lines(line,disp_no,disp_date,gr_no,gr_date,grn_line,qty) VALUES
 (2,'I0901',:'today_ip'::date - 300,'A0901',:'today_ip'::date - 400,1,5), (3,'I0911',:'today_ip'::date - 285,'A0901',:'today_ip'::date - 400,1,5),
 (4,'I0902',:'today_ip'::date - 300,'A0902',:'today_ip'::date - 400,1,5), (5,'I0905',:'today_ip'::date - 300,'A0902',:'today_ip'::date - 400,1,5),
 (6,'I0903',:'today_ip'::date - 300,'A0903',:'today_ip'::date - 400,1,5), (7,'I0904',:'today_ip'::date - 200,'A0904',:'today_ip'::date - 400,1,5);
INSERT INTO warehouse_import.stage_invoices(line,inv_label,inv_no,inv_prefix,inv_date,customer,gr_no,gr_date,labour,tax,total) VALUES
 (2,'GC/901',901,'GC/',:'today_ip'::date - 300,'Import Demo Traders','A0901',:'today_ip'::date - 400,10.00,0.00,110.00),
 (3,'GC/902',902,'GC/',:'today_ip'::date - 300,'Import Demo Traders','A0902',:'today_ip'::date - 400,10.00,0.00,110.00);
INSERT INTO warehouse_import.stage_invoice_lines(line,inv_label,inv_no,inv_date,item,packaging,qty,disp_no,disp_date,grn_line,rate,labour_rate,tax_pct,storage,labour,tax_amount) VALUES
 (2,'GC/901',901,:'today_ip'::date - 300,'Import Demo Potato','Bag',5,NULL,NULL,NULL,20.00,2.00,0,100.00,10.00,0.00),
 (3,'GC/902',902,:'today_ip'::date - 300,'Import Demo Potato','Bag',5,'I0902',:'today_ip'::date - 300,1,20.00,2.00,0,100.00,10.00,0.00);
CREATE FUNCTION pg_temp.ip_notes(p_report jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(string_agg((p->>'file') || ':' || (p->>'line') || ':' || left(p->>'reason', 24), ' | ' ORDER BY p->>'file', (p->>'line')::int), '')
    FROM jsonb_array_elements(p_report->'problems') p
   WHERE p->>'kind' = 'note' AND p->>'reason' LIKE '%on no invoice, but its GRN has%' $$;
-- The taken-as-billed list of a report as "I0901>GC/901@date,...".
CREATE FUNCTION pg_temp.ip_taken(p_report jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(string_agg((d->>'disp_no') || '>' || (d->>'invoice') || '@' || (d->>'disp_date'), ',' ORDER BY d->>'disp_no'), '')
    FROM jsonb_array_elements(COALESCE(p_report#>'{totals,taken_as_billed}', '[]'::jsonb)) c, jsonb_array_elements(c->'dispatches') d $$;
-- Grants on the link table: nothing for the app roles or the service role.
SELECT pg_temp.ip_assert(to_regclass('public.imported_billed_dispatches') IS NOT NULL
  AND (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.imported_billed_dispatches'::regclass)
  AND NOT EXISTS (SELECT 1 FROM unnest(ARRAY['anon','authenticated','service_role']) r CROSS JOIN unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE']) p
                   WHERE has_table_privilege(r, 'public.imported_billed_dispatches', p)), 'no role of the app can read or write imported_billed_dispatches');
-- Dry run first, then the apply: the same list, the same counts, and the dry run saved no link.
SELECT pg_temp.ip_svc($q$SELECT public.import_history('{}'::jsonb, false)$q$) AS t_dry \gset
SELECT pg_temp.ip_assert(:'t_dry'::jsonb->>'success' = 'true' AND (SELECT count(*) FROM public.imported_billed_dispatches) = 0, 'the dry run is clean and saves no link: ' || :'t_dry');
SELECT pg_temp.ip_svc($q$SELECT public.import_history('{}'::jsonb, true)$q$) AS t_run1 \gset
SELECT pg_temp.ip_assert(:'t_run1'::jsonb->>'success' = 'true', 'the run applies: ' || :'t_run1');
SELECT pg_temp.ip_assert(pg_temp.ip_taken(:'t_dry'::jsonb) = pg_temp.ip_taken(:'t_run1'::jsonb)
  AND (:'t_dry'::jsonb#>'{totals,uninvoiced_dispatches}') = (:'t_run1'::jsonb#>'{totals,uninvoiced_dispatches}')
  AND pg_temp.ip_notes(:'t_dry'::jsonb) = pg_temp.ip_notes(:'t_run1'::jsonb), 'the dry run reports what the apply does: ' || pg_temp.ip_taken(:'t_dry'::jsonb));
-- The report: I0901 taken as billed by GC/901, dated D; nothing else.
SELECT pg_temp.ip_assert(pg_temp.ip_taken(:'t_run1'::jsonb) = 'I0901>GC/901@' || (:'today_ip'::date - 300), 'the taken-as-billed list: ' || pg_temp.ip_taken(:'t_run1'::jsonb));
SELECT pg_temp.ip_assert((SELECT count(*) FROM public.imported_billed_dispatches) = 1
  AND (SELECT d.disp_no FROM public.imported_billed_dispatches b JOIN public.dispatch_trl dt ON dt.id = b.disp_trl_id JOIN public.dispatch d ON d.id = dt.disp_id) = 'I0901'
  AND (SELECT i.inv_no FROM public.imported_billed_dispatches b JOIN public.invoice i ON i.id = b.invoice_id) = 901, 'exactly one link: I0901 to GC/901');
-- The never-billed list holds I0004 (section 1), I0911, I0905, I0903 and I0904 (I0902 is on GC/902), not I0901.
SELECT pg_temp.ip_assert((SELECT (c->>'dispatches')::int FROM jsonb_array_elements(:'t_run1'::jsonb#>'{totals,uninvoiced_dispatches}') c WHERE c->>'customer' = 'Import Demo Traders') = 5,
  'five dispatches are never billed (I0004 of the first fixture, I0911, I0905, I0903, I0904): ' || (:'t_run1'::jsonb#>>'{totals,uninvoiced_dispatches}'));
-- The notes: I0905 (its GRN's invoice names its dispatches) still gets "the app bills it"; I0901 does not; I0911 is dated after its GRN's invoice; I0903 and I0904 have no invoice.
SELECT pg_temp.ip_assert(pg_temp.ip_notes(:'t_run1'::jsonb) LIKE 'dispatch-lines:5:%' AND pg_temp.ip_notes(:'t_run1'::jsonb) NOT LIKE '%|%',
  'exactly one note, for I0905 on dispatch-lines line 5: ' || pg_temp.ip_notes(:'t_run1'::jsonb));
-- A dispatch named by another invoice is not linked (I0902), nor are the others.
SELECT pg_temp.ip_assert(NOT EXISTS (SELECT 1 FROM public.imported_billed_dispatches b JOIN public.dispatch_trl dt ON dt.id = b.disp_trl_id JOIN public.dispatch d ON d.id = dt.disp_id
  WHERE d.disp_no IN ('I0902', 'I0905', 'I0903', 'I0904', 'I0911')), 'no other dispatch is linked');

-- Criterion 20, A0901: I0901 is not in Customer dues as not invoiced, is not offered by the invoice form, cannot be claimed by a save;
-- I0911 is in dues, is in the form, and can be invoiced.
SELECT id AS g901 FROM public.goodsreceived WHERE gr_no = 'A0901' \gset
SELECT t.id AS d901_line FROM public.dispatch_trl t JOIN public.dispatch d ON d.id = t.disp_id WHERE d.disp_no = 'I0901' \gset
SELECT t.id AS d911_line FROM public.dispatch_trl t JOIN public.dispatch d ON d.id = t.disp_id WHERE d.disp_no = 'I0911' \gset
SELECT n.left_bags AS dues_left_bags, n.left_amount > 0 AS dues_left_priced FROM warehouse_security.not_invoiced_grns(:'trader'::uuid, :'today_ip'::date) n WHERE n.gr_id = :'g901'::uuid \gset
SELECT pg_temp.ip_assert(:'dues_left_bags'::int = 5 AND :'dues_left_priced'::boolean, 'dues counts I0911 only (5 bags), not I0901: ' || :'dues_left_bags');
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.get_customer_statement(%L::uuid)$q$, :'trader')) AS t_stmt \gset
SELECT pg_temp.ip_assert((SELECT (e->>'bags')::int = 5 FROM jsonb_array_elements(:'t_stmt'::jsonb->'left') e WHERE e->>'gr_no' = 'A0901'), 'the statement shows 5 bags not invoiced for A0901: ' || (:'t_stmt'::jsonb->>'left'));
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true) AS t_claims \gset
SELECT public.build_invoice_form_lines(:'g901'::uuid, NULL) AS t_form \gset
SELECT pg_temp.ip_assert(:'t_form'::jsonb::text LIKE '%' || :'d911_line' || '%' AND :'t_form'::jsonb::text NOT LIKE '%' || :'d901_line' || '%',
  'the form offers I0911 and not I0901: ' || left(:'t_form', 600));
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT pg_temp.ip_save_invoice(jsonb_build_object('inv_fin_year', %s, 'gr_id', %L, 'gr_no', 'A0901', 'customer_id', %L,
  'customer_name', 'Import Demo Traders', 'inv_date', now(), 'total', 0, 'tax_amount', 0, 'discount', 0, 'duration_mode', 'legacy', 'inv_no', 2,
  'items', jsonb_build_array(jsonb_build_object('disp_trl_id', %L, 'charge', 7, 'tax', 0, 'labour_rate', 1))))$q$, :'cur_fy', :'g901', :'trader', :'d901_line')) AS t_claim \gset
SELECT pg_temp.ip_assert(:'t_claim'::jsonb->>'success' = 'false' AND :'t_claim'::jsonb::text LIKE '%DISPATCH_LINE_INVOICED%', 'a save claiming I0901 is refused: ' || :'t_claim');
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT pg_temp.ip_save_invoice(jsonb_build_object('inv_fin_year', %s, 'gr_id', %L, 'gr_no', 'A0901', 'customer_id', %L,
  'customer_name', 'Import Demo Traders', 'inv_date', now(), 'total', 0, 'tax_amount', 0, 'discount', 0, 'duration_mode', 'legacy', 'inv_no', 2,
  'items', jsonb_build_array(jsonb_build_object('disp_trl_id', %L, 'charge', 7, 'tax', 0, 'labour_rate', 1))))$q$, :'cur_fy', :'g901', :'trader', :'d911_line')) AS t_ok \gset
SELECT pg_temp.ip_assert(:'t_ok'::jsonb->>'success' = 'true', 'I0911 can be invoiced: ' || :'t_ok');
-- That app invoice is cancelled again so the facts below are those of the import.
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.cancel_invoice(%L::uuid, 'test', NULL)$q$, :'t_ok'::jsonb->>'invoice_id')) AS t_cancel \gset

-- A re-run adds no second link and no second note; then an app-made dispatch on the same GRN (the next run must not link it).
SELECT pg_temp.ip_svc($q$SELECT public.import_history('{}'::jsonb, true)$q$) AS t_run1b \gset
SELECT pg_temp.ip_assert(:'t_run1b'::jsonb->>'success' = 'true' AND (SELECT count(*) FROM public.imported_billed_dispatches) = 1
  AND pg_temp.ip_taken(:'t_run1b'::jsonb) = pg_temp.ip_taken(:'t_run1'::jsonb) AND pg_temp.ip_notes(:'t_run1b'::jsonb) = '',
  'a re-run adds no second link and no second note: ' || left(:'t_run1b', 900));
-- An app-made dispatch from the imported GRN A0901 (dated before the invoice): the later runs below must not link it. (After the re-run:
-- it changes the lot's stock, which the files' "Stock now" would then contradict.)
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','I0950','disp_date',%L,
  'customer_id',%L,'customer_name','Import Demo Traders','supervisor_id',%L,'supervisor_name','Import Demo Administrator'),
  ARRAY[jsonb_build_object('gr_trl_id',(SELECT t.id FROM public.goodsreceived_trl t WHERE t.gr_id = %L),'disp_qty',1)],false,0,'ip-app-d950')$q$,
  (:'today_ip'::date - 299)::text || 'T12:00:00Z', :'trader', :'admin_profile', :'g901')) AS t_appd \gset
SELECT pg_temp.ip_assert(:'t_appd'::jsonb->>'success' = 'true', 'an app dispatch from A0901: ' || :'t_appd');

-- An earlier run's dispatch is linked when its invoice arrives (A0904's I0904, dated D+100; the invoice GC/904 is dated D+150, no dispatch named).
TRUNCATE warehouse_import.stage_grns, warehouse_import.stage_grn_lines, warehouse_import.stage_dispatches, warehouse_import.stage_dispatch_lines,
  warehouse_import.stage_invoices, warehouse_import.stage_invoice_lines, warehouse_import.stage_payments;
INSERT INTO warehouse_import.stage_invoices(line,inv_label,inv_no,inv_prefix,inv_date,customer,gr_no,gr_date,labour,tax,total) VALUES
 (2,'GC/904',904,'GC/',:'today_ip'::date - 150,'Import Demo Traders','A0904',:'today_ip'::date - 400,10.00,0.00,110.00);
INSERT INTO warehouse_import.stage_invoice_lines(line,inv_label,inv_no,inv_date,item,packaging,qty,disp_no,disp_date,grn_line,rate,labour_rate,tax_pct,storage,labour,tax_amount) VALUES
 (2,'GC/904',904,:'today_ip'::date - 150,'Import Demo Potato','Bag',5,NULL,NULL,NULL,20.00,2.00,0,100.00,10.00,0.00);
SELECT pg_temp.ip_svc($q$SELECT public.import_history('{}'::jsonb, true)$q$) AS t_run2 \gset
SELECT pg_temp.ip_assert(:'t_run2'::jsonb->>'success' = 'true' AND pg_temp.ip_taken(:'t_run2'::jsonb) LIKE '%I0904>GC/904@%' AND pg_temp.ip_taken(:'t_run2'::jsonb) LIKE '%I0901>GC/901@%'
  AND (SELECT count(*) FROM public.imported_billed_dispatches) = 2 AND pg_temp.ip_notes(:'t_run2'::jsonb) = '',
  'the later invoice takes the earlier run''s dispatch as billed, once, and the older link stays: ' || pg_temp.ip_taken(:'t_run2'::jsonb));
SELECT pg_temp.ip_svc($q$SELECT public.import_history('{}'::jsonb, true)$q$) AS t_run2b \gset
SELECT pg_temp.ip_assert((SELECT count(*) FROM public.imported_billed_dispatches) = 2 AND pg_temp.ip_taken(:'t_run2b'::jsonb) = pg_temp.ip_taken(:'t_run2'::jsonb)
  AND NOT EXISTS (SELECT 1 FROM public.imported_billed_dispatches b JOIN public.dispatch_trl dt ON dt.id = b.disp_trl_id JOIN public.dispatch d ON d.id = dt.disp_id WHERE d.import_batch_id IS NULL), 'a repeat of the later run adds no link, and the app-made dispatch is never linked');
-- Nothing saved moves: the taken dispatches are still on no invoice line.
SELECT pg_temp.ip_assert((SELECT count(*) FROM public.invoice_trl it JOIN public.dispatch_trl dt ON dt.id = it.disp_trl_id JOIN public.dispatch d ON d.id = dt.disp_id WHERE d.disp_no IN ('I0901','I0904')) = 0,
  'a dispatch taken as billed gets no invoice line');
-- An imported invoice with NO lines at all names no dispatch either: it also takes its GRN's earlier imported dispatches as billed.
-- GRN A0905: dispatches I0906 (before GC/905) and I0907 (after it); GC/905 has no rows in invoice-lines. GRN A0906 (another customer): I0908.
TRUNCATE warehouse_import.stage_grns, warehouse_import.stage_grn_lines, warehouse_import.stage_dispatches, warehouse_import.stage_dispatch_lines,
  warehouse_import.stage_invoices, warehouse_import.stage_invoice_lines, warehouse_import.stage_payments;
INSERT INTO warehouse_import.stage_grns(line,gr_no,gr_date,customer,pricing) VALUES
 (2,'A0905',:'today_ip'::date - 400,'Import Demo Traders','MONTHLY'), (3,'A0906',:'today_ip'::date - 400,'Import Demo Other','MONTHLY');
INSERT INTO warehouse_import.stage_grn_lines(line,gr_no,gr_date,line_no,item,packaging,qty,weight,stock_now) VALUES
 (2,'A0905',:'today_ip'::date - 400,1,'Import Demo Potato','Bag',20,50,10), (3,'A0906',:'today_ip'::date - 400,1,'Import Demo Potato','Bag',20,50,15);
INSERT INTO warehouse_import.stage_dispatches(line,disp_no,disp_date,customer) VALUES
 (2,'I0906',:'today_ip'::date - 250,'Import Demo Traders'), (3,'I0907',:'today_ip'::date - 100,'Import Demo Traders'), (4,'I0908',:'today_ip'::date - 250,'Import Demo Other');
INSERT INTO warehouse_import.stage_dispatch_lines(line,disp_no,disp_date,gr_no,gr_date,grn_line,qty) VALUES
 (2,'I0906',:'today_ip'::date - 250,'A0905',:'today_ip'::date - 400,1,5), (3,'I0907',:'today_ip'::date - 100,'A0905',:'today_ip'::date - 400,1,5),
 (4,'I0908',:'today_ip'::date - 250,'A0906',:'today_ip'::date - 400,1,5);
INSERT INTO warehouse_import.stage_invoices(line,inv_label,inv_no,inv_prefix,inv_date,customer,gr_no,gr_date,labour,tax,total) VALUES
 (2,'GC/905',905,'GC/',:'today_ip'::date - 200,'Import Demo Traders','A0905',:'today_ip'::date - 400,10.00,0.00,110.00);
SELECT pg_temp.ip_svc($q$SELECT public.import_history('{}'::jsonb, false)$q$) AS nl_dry \gset
SELECT pg_temp.ip_svc($q$SELECT public.import_history('{}'::jsonb, true)$q$) AS nl_run \gset
SELECT pg_temp.ip_assert(:'nl_run'::jsonb->>'success' = 'true' AND pg_temp.ip_taken(:'nl_dry'::jsonb) = pg_temp.ip_taken(:'nl_run'::jsonb), 'the run with a no-lines invoice applies, dry run = apply: ' || left(:'nl_run', 600));
SELECT pg_temp.ip_assert(pg_temp.ip_taken(:'nl_run'::jsonb) LIKE '%I0906>GC/905@%' AND pg_temp.ip_taken(:'nl_run'::jsonb) NOT LIKE '%I0907%' AND pg_temp.ip_taken(:'nl_run'::jsonb) NOT LIKE '%I0908%'
  AND (SELECT count(*) FROM public.imported_billed_dispatches) = 3, 'I0906 is taken as billed by GC/905; I0907 (later) and I0908 (another GRN, no invoice) are not: ' || pg_temp.ip_taken(:'nl_run'::jsonb));
SELECT pg_temp.ip_assert(pg_temp.ip_notes(:'nl_run'::jsonb) = '', 'no "the app bills it" note for the no-lines case: ' || pg_temp.ip_notes(:'nl_run'::jsonb));
SELECT id AS g905 FROM public.goodsreceived WHERE gr_no = 'A0905' \gset
SELECT t.id AS d906_line FROM public.dispatch_trl t JOIN public.dispatch d ON d.id = t.disp_id WHERE d.disp_no = 'I0906' \gset
SELECT t.id AS d907_line FROM public.dispatch_trl t JOIN public.dispatch d ON d.id = t.disp_id WHERE d.disp_no = 'I0907' \gset
SELECT n.left_bags AS nl_left_bags FROM warehouse_security.not_invoiced_grns(:'trader'::uuid, :'today_ip'::date) n WHERE n.gr_id = :'g905'::uuid \gset
SELECT pg_temp.ip_assert(:'nl_left_bags'::int = 5, 'dues counts I0907 only (5 bags), not I0906: ' || :'nl_left_bags');
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true) AS nl_claims \gset
SELECT public.build_invoice_form_lines(:'g905'::uuid, NULL) AS nl_form \gset
SELECT pg_temp.ip_assert(:'nl_form'::jsonb::text LIKE '%' || :'d907_line' || '%' AND :'nl_form'::jsonb::text NOT LIKE '%' || :'d906_line' || '%', 'the form offers I0907 and not I0906: ' || left(:'nl_form', 500));
SELECT pg_temp.ip_svc($q$SELECT public.import_history('{}'::jsonb, true)$q$) AS nl_again \gset
SELECT pg_temp.ip_assert((SELECT count(*) FROM public.imported_billed_dispatches) = 3 AND pg_temp.ip_notes(:'nl_again'::jsonb) = '', 'a repeat adds no link');

-- ===== 10. WH-191: get_dispatch_details names the invoice a dispatch line is taken as billed by (migration 196) =====
SELECT id AS dd901 FROM public.dispatch WHERE disp_no = 'I0901' \gset
SELECT id AS dd911 FROM public.dispatch WHERE disp_no = 'I0911' \gset
SELECT id AS dd902 FROM public.dispatch WHERE disp_no = 'I0902' \gset
SELECT id AS dd906 FROM public.dispatch WHERE disp_no = 'I0906' \gset
SELECT id AS dd908 FROM public.dispatch WHERE disp_no = 'I0908' \gset
SELECT id AS dd950 FROM public.dispatch WHERE disp_no = 'I0950' \gset
SELECT id AS inv901 FROM public.invoice WHERE inv_no = 901 AND import_batch_id IS NOT NULL \gset
SELECT id AS inv902 FROM public.invoice WHERE inv_no = 902 AND import_batch_id IS NOT NULL \gset
SELECT id AS inv905 FROM public.invoice WHERE inv_no = 905 AND import_batch_id IS NOT NULL \gset
-- The taken-as-billed dispatch (criterion 20's GRN): its line reads the billing invoice; per-line charge fields are null.
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.get_dispatch_details(%L::uuid)$q$, :'dd901')) AS dd_taken \gset
SELECT pg_temp.ip_assert((:'dd_taken'::jsonb#>>'{data,dispatch,items,0,invoice_details,invoice_id}') = :'inv901'
  AND (:'dd_taken'::jsonb#>>'{data,dispatch,items,0,invoice_details,invoice_no}')::int = 901
  AND (:'dd_taken'::jsonb#>>'{data,dispatch,items,0,invoice_details,invoice_label}') = 'GC/901'
  AND (:'dd_taken'::jsonb#>>'{data,dispatch,items,0,invoice_details,invoice_date}') IS NOT NULL
  AND (:'dd_taken'::jsonb#>>'{data,dispatch,items,0,invoice_details,total}')::numeric = 110.00
  AND jsonb_typeof(:'dd_taken'::jsonb#>'{data,dispatch,items,0,invoice_details,charge}') = 'null'
  AND jsonb_typeof(:'dd_taken'::jsonb#>'{data,dispatch,items,0,invoice_details,duration}') = 'null'
  AND jsonb_typeof(:'dd_taken'::jsonb#>'{data,dispatch,items,0,invoice_details,invoice_trl_id}') = 'null',
  'the taken-as-billed dispatch names GC/901 with no line figures: ' || left(:'dd_taken', 800));
SELECT pg_temp.ip_assert((:'dd_taken'::jsonb#>>'{data,dispatch,statistics,total_invoiced_items}')::int = 1, 'it counts as one invoiced item: ' || (:'dd_taken'::jsonb#>>'{data,dispatch,statistics}'));
SELECT pg_temp.ip_assert((:'dd_taken'::jsonb#>>'{data,dispatch,invoices_summary,total_invoices}')::int = 1 AND (:'dd_taken'::jsonb#>>'{data,dispatch,invoices_summary,invoice_labels,0}') = 'GC/901'
  AND (:'dd_taken'::jsonb#>>'{data,dispatch,invoices_summary,total_amount}')::numeric = 110.00, 'its invoice is in invoices_summary: ' || (:'dd_taken'::jsonb#>>'{data,dispatch,invoices_summary}'));
-- The dispatch dated after the invoice: nothing.
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.get_dispatch_details(%L::uuid)$q$, :'dd911')) AS dd_later \gset
SELECT pg_temp.ip_assert(jsonb_typeof(:'dd_later'::jsonb#>'{data,dispatch,items,0,invoice_details}') = 'null'
  AND (:'dd_later'::jsonb#>>'{data,dispatch,statistics,total_invoiced_items}')::int = 0, 'the later dispatch returns no invoice: ' || left(:'dd_later', 600));
-- A dispatch named by a live invoice line shows that invoice with its line figures, as before.
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.get_dispatch_details(%L::uuid)$q$, :'dd902')) AS dd_named \gset
SELECT pg_temp.ip_assert((:'dd_named'::jsonb#>>'{data,dispatch,items,0,invoice_details,invoice_id}') = :'inv902'
  AND (:'dd_named'::jsonb#>>'{data,dispatch,items,0,invoice_details,charge}')::numeric = 20.00
  AND (:'dd_named'::jsonb#>>'{data,dispatch,statistics,total_invoiced_items}')::int = 1, 'a dispatch named by GC/902 shows GC/902 and its line figures: ' || left(:'dd_named', 700));
-- The no-lines invoice case.
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.get_dispatch_details(%L::uuid)$q$, :'dd906')) AS dd_nolines \gset
SELECT pg_temp.ip_assert((:'dd_nolines'::jsonb#>>'{data,dispatch,items,0,invoice_details,invoice_id}') = :'inv905'
  AND (:'dd_nolines'::jsonb#>>'{data,dispatch,items,0,invoice_details,invoice_label}') = 'GC/905'
  AND (:'dd_nolines'::jsonb#>>'{data,dispatch,statistics,total_invoiced_items}')::int = 1, 'a dispatch taken by the no-lines invoice names GC/905: ' || left(:'dd_nolines', 700));
-- An app-made dispatch, invoiced in the app, reads as before: its own invoice line and figures.
SELECT t.id AS d950_line FROM public.dispatch_trl t WHERE t.disp_id = :'dd950'::uuid \gset
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT pg_temp.ip_save_invoice(jsonb_build_object('inv_fin_year', %s, 'gr_id', %L, 'gr_no', 'A0901', 'customer_id', %L,
  'customer_name', 'Import Demo Traders', 'inv_date', now(), 'total', 0, 'tax_amount', 0, 'discount', 0, 'duration_mode', 'legacy', 'inv_no', 3,
  'items', jsonb_build_array(jsonb_build_object('disp_trl_id', %L, 'charge', 7, 'tax', 0, 'labour_rate', 1))))$q$, :'cur_fy', :'g901', :'trader', :'d950_line')) AS app_inv950 \gset
SELECT pg_temp.ip_assert(:'app_inv950'::jsonb->>'success' = 'true', 'an app invoice for the app dispatch: ' || :'app_inv950');
SELECT pg_temp.ip_as(:'admin_claims'::jsonb, format($q$SELECT public.get_dispatch_details(%L::uuid)$q$, :'dd950')) AS dd_app \gset
SELECT pg_temp.ip_assert((:'dd_app'::jsonb#>>'{data,dispatch,items,0,invoice_details,invoice_id}') = (:'app_inv950'::jsonb->>'invoice_id')
  AND (:'dd_app'::jsonb#>>'{data,dispatch,items,0,invoice_details,charge}')::numeric = 7.00
  AND (:'dd_app'::jsonb#>>'{data,dispatch,statistics,total_invoiced_items}')::int = 1, 'the app-made invoiced dispatch reads as before: ' || left(:'dd_app', 700));
-- A customer account sees the same for its own customer's dispatch and nothing of another customer's.
SELECT pg_temp.ip_as(:'customer_claims'::jsonb, format($q$SELECT public.get_dispatch_details(%L::uuid)$q$, :'dd901')) AS dd_cust \gset
SELECT pg_temp.ip_assert((:'dd_cust'::jsonb#>>'{data,dispatch,items,0,invoice_details,invoice_id}') = :'inv901'
  AND (:'dd_cust'::jsonb#>>'{data,dispatch,statistics,total_invoiced_items}')::int = 1, 'a customer sees its own taken-as-billed dispatch as an administrator does: ' || left(:'dd_cust', 700));
SELECT pg_temp.ip_as(:'customer_claims'::jsonb, format($q$SELECT public.get_dispatch_details(%L::uuid)$q$, :'dd908')) AS dd_other \gset
SELECT pg_temp.ip_assert(:'dd_other'::jsonb ? 'raised' OR :'dd_other'::jsonb->>'success' = 'false' OR :'dd_other'::jsonb#>'{data,dispatch}' IS NULL OR jsonb_typeof(:'dd_other'::jsonb#>'{data,dispatch}') = 'null',
  'a customer gets nothing of another customer''s dispatch: ' || left(:'dd_other', 400));
SELECT pg_temp.ip_assert(:'dd_other'::jsonb::text NOT LIKE '%GC/%' AND :'dd_other'::jsonb::text NOT LIKE '%' || :'inv905' || '%', 'and no invoice of another customer appears');
ROLLBACK;
\echo 'Import of past years: marks, read-only, read as issued, the import itself and rates on an imported GRN passed.'

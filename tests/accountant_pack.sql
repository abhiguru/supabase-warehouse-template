-- WH-158: the accountant pack's database half (migrations 200 and 201; contract product/tech/accountant-pack.md, sections 3 and 8).
-- Written BEFORE the build (test first): it fails today because accountant_export_settings (200) and accountant_pack_read (201) do not exist
-- (public.get_accountant_ledgers, public.set_accountant_ledgers, public.get_accountant_pack, warehouse_security.accountant_packs).
-- Criteria covered: 1, 2, 4, 5, 6, 8, 9 (roles, refusals, ledgers, audit, before-GST count, imported flag) and 14 (record of packs, cancellations).
-- Fictional data. Runs only in migrations.sh's disposable, network-disabled database; everything is rolled back.
--
-- Fixture (financial year 2026-27; period A = May 2026, B = June, C = July; all documents of A, prefix SRT/ unless stated):
--   SRT/12 tax invoice, intra-state, customer N (GSTIN 24...), one line of 30 bags: taxable 217.50 (labour 1.00 x 30 = 30.00, storage 187.50), 5 %,
--          header CGST 5.50 SGST 5.50, round-off 0.50, total 229.00  -> rows storage 187.50 (4.74/4.74/9.48) and labour 30.00 (0.76/0.76/1.52)
--   SRT/13 tax invoice, inter-state (customer M, IGST): taxable 500.00 (labour 2.00 x 20 = 40.00), 18 %, IGST 90.00, total 590.00
--   SRT/14 tax invoice + SRT/15 bill of supply (a pair, linked): 14 has taxable 300.00 (labour 10.00), 5 %, discount 5.00, total 310.00;
--          15 is ONE_TIME, one exempt_agri line of 200.00, total 200.00
--   SRT/16 tax invoice, cancelled (in A)         SRT/18 invoice made before GST details (doc_type 'invoice'; tax 5.00, total 104.60)
--   GC/125 imported tax invoice (storage 400.00 as issued + labour 50.00, 5 %, total 472.50)
--   SRT/19 (X) and SRT/20 (Y): live tax invoices of A that are cancelled later in the test.   SRT/17 is never used: the gap.
-- Stock: PKG1 (customer N, 2026-04-10, 120 bags of 50 kg), PKG2 (M, 05-05, 40 x 25), PKG3 (N, 05-06, 50 x 10), PKG4 (U, 05-07, 12 x 10).
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.pk_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'accountant pack: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.pk_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.pk_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.pk_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
-- The jsonb answer of a statement run as the signed-in caller, or {"raised": message, "state": sqlstate}.
CREATE FUNCTION pg_temp.pk_as(claims jsonb, statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',claims::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN answer := jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  EXECUTE 'RESET ROLE';
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.pk_svc(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  EXECUTE 'SET LOCAL ROLE service_role';
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN answer := jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  EXECUTE 'RESET ROLE';
  RETURN answer;
END $$;
-- get_accountant_pack as a caller; each call that gets past the refusals adds one row to accountant_packs.
CREATE FUNCTION pg_temp.pk_pack(claims jsonb, p_from text, p_to text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.pk_as(claims, format('SELECT public.get_accountant_pack(%L::date, %L::date)', p_from, p_to)) $$;
CREATE FUNCTION pg_temp.pk_doc_of(pack jsonb, num text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT d FROM jsonb_array_elements(pack#>'{data,documents}') d WHERE d->>'number' = num $$;
CREATE FUNCTION pg_temp.pk_row_of(pack jsonb, num text, k text, ex boolean DEFAULT false) RETURNS jsonb LANGUAGE sql AS $$
  SELECT r FROM jsonb_array_elements(pg_temp.pk_doc_of(pack, num)->'rows') r WHERE r->>'kind' = k AND (r->>'exempt')::boolean = ex LIMIT 1 $$;
CREATE FUNCTION pg_temp.pk_canc_of(pack jsonb, num text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT c FROM jsonb_array_elements(pack#>'{data,cancellations}') c WHERE c->>'number' = num $$;
CREATE FUNCTION pg_temp.pk_pay_of(pack jsonb, no text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT p FROM jsonb_array_elements(pack#>'{data,payments}') p WHERE p->>'payment_no' = no $$;
CREATE FUNCTION pg_temp.pk_packs_count() RETURNS bigint LANGUAGE plpgsql AS $$ BEGIN RETURN (SELECT count(*) FROM warehouse_security.accountant_packs); END $$;

INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888888921','Pack Demo Administrator') AS boot \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888922','Pack Demo Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888923','Pack Demo Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919888888924','Pack Demo Customer User','customer',true,'approved');
SELECT pg_temp.pk_login('9888888921') AS admin_claims \gset
SELECT pg_temp.pk_login('9888888922') AS staff_claims \gset
SELECT pg_temp.pk_login('9888888923') AS supervisor_claims \gset
SELECT pg_temp.pk_login('9888888924') AS customer_claims \gset
SELECT set_config('pk.admin_claims', :'admin_claims', true) AS c1 \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE mobile = '919888888921' \gset
SELECT id AS supervisor_profile FROM public.user_profiles WHERE mobile = '919888888923' \gset

-- ===== the fixture =====
INSERT INTO public.customers(name,mobile,gst,state) VALUES ('Pack Demo Traders','9888888931','24BBBBB1111B1Z3','Gujarat') RETURNING id AS cust_n \gset
INSERT INTO public.customers(name,mobile,gst,state) VALUES ('Pack Demo Other State','9888888932','27CCCCC2222C1Z1','Maharashtra') RETURNING id AS cust_m \gset
INSERT INTO public.customers(name,mobile) VALUES ('Pack Demo Walkin','9888888933') RETURNING id AS cust_u \gset
INSERT INTO public.items(name,packaging) VALUES ('Pack Demo Jeera','Bag') RETURNING id AS item_id \gset
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active) SELECT id,:'cust_n'::uuid,true FROM public.user_profiles WHERE mobile='919888888924';
SELECT pg_temp.pk_as(:'admin_claims'::jsonb, format($q$SELECT public.replace_item_rates(%L::uuid,NULL,'monthly','2026-01-01'::date,
  '[{"weight_min":0,"weight_max":100,"unit_price":5,"labour_rate":1,"tax_percent":5}]'::jsonb)$q$, :'item_id')) AS rates \gset
SELECT pg_temp.pk_assert(:'rates'::jsonb->>'success'='true','rates: '||:'rates');
SELECT pg_temp.pk_as(:'admin_claims'::jsonb, $q$SELECT public.set_gst_details('{"registered":true,"gstin":"24AAAAA0000A1Z5","address":"1 Demo Road, Demo City","legal_name":"Pack Demo Cold Storage"}'::jsonb)$q$) AS gst \gset
SELECT pg_temp.pk_assert(:'gst'::jsonb->>'success'='true','GST details saved: '||:'gst');
SELECT pg_temp.pk_as(:'admin_claims'::jsonb, $q$SELECT public.set_record_payments(true)$q$) AS pay_on \gset
SELECT pg_temp.pk_assert(:'pay_on'::jsonb->>'success'='true','record payments on: '||:'pay_on');

-- A receipt through save_grn and a dispatch through create_dispatch_with_stock_check, as the administrator.
CREATE FUNCTION pg_temp.pk_grn(p_no text, p_date text, p_cust uuid, p_name text, p_qty int, p_weight int) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE r jsonb; v_id uuid;
BEGIN
  PERFORM set_config('request.jwt.claims', current_setting('pk.admin_claims'), true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  r := public.save_grn(p_gr_no=>p_no, p_date=>(p_date || 'T12:00:00Z')::timestamptz, p_customer_id=>p_cust, p_customer_name=>p_name, p_pricing_mode=>'MONTHLY',
    p_idempotency_key=>'pk-grn-' || p_no,
    p_items=>jsonb_build_array(jsonb_build_object('item_id',(SELECT id FROM public.items WHERE name='Pack Demo Jeera'),'item_name','Pack Demo Jeera',
      'packaging','Bag','qty',p_qty,'weight',p_weight,'rack','PK' || p_no)));
  EXECUTE 'RESET ROLE';
  IF r->>'success' <> 'true' THEN RAISE EXCEPTION 'save_grn % failed: %', p_no, r; END IF;
  SELECT id INTO v_id FROM public.goodsreceived WHERE gr_no = p_no;
  RETURN v_id;
END $$;
CREATE FUNCTION pg_temp.pk_disp(p_no text, p_date text, p_gr uuid, p_cust uuid, p_name text, p_qty int) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE r jsonb; v_id uuid;
BEGIN
  PERFORM set_config('request.jwt.claims', current_setting('pk.admin_claims'), true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  r := public.create_dispatch_with_stock_check(jsonb_build_object('customer_id',p_cust,'customer_name',p_name,
    'supervisor_id',(SELECT id FROM public.user_profiles WHERE mobile='919888888921'),'supervisor_name','Pack Demo Administrator','disp_date',p_date,'disp_no',p_no),
    ARRAY[jsonb_build_object('gr_trl_id',(SELECT t.id FROM public.goodsreceived_trl t WHERE t.gr_id=p_gr),'disp_qty',p_qty)], 0, 'pk-disp-' || p_no);
  EXECUTE 'RESET ROLE';
  IF r->>'success' <> 'true' THEN RAISE EXCEPTION 'dispatch % failed: %', p_no, r; END IF;
  SELECT t.id INTO v_id FROM public.dispatch_trl t JOIN public.dispatch d ON d.id = t.disp_id WHERE d.disp_no = p_no;
  RETURN v_id;
END $$;
-- An invoice and its one line, written directly (triggers off for the statement: the prefix and the imported mark are kept as given).
-- h: id, no, prefix, date, gr_id, gr_no, cust, cust_name, doc_type, pricing, labour, tax, total, discount, gstin, state, pos, head, cgst, sgst, igst, linked, batch.
-- l: disp, labour_rate, charge, tax_pct, treatment, taxable, line_tax, cgst, sgst, igst, issued_storage.
CREATE FUNCTION pg_temp.pk_inv(h jsonb, l jsonb) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_id uuid := (h->>'id')::uuid;
BEGIN
  PERFORM set_config('session_replication_role','replica',true);
  INSERT INTO public.invoice(id,inv_fin_year,inv_no,inv_prefix,gr_id,gr_no,customer_id,customer_name,inv_date,pricing_mode,labour,tax_amount,total,discount,
      doc_type,linked_invoice_id,gst_supplier_gstin,gst_sac_storage,gst_sac_labour,gst_customer_gstin,gst_customer_state,gst_place_of_supply,gst_tax_head,
      cgst_amount,sgst_amount,igst_amount,import_batch_id)
  VALUES (v_id,2026,(h->>'no')::int,COALESCE(h->>'prefix','SRT/'),(h->>'gr_id')::uuid,h->>'gr_no',(h->>'cust')::uuid,h->>'cust_name',(h->>'date')::timestamptz,
      h->>'pricing',(h->>'labour')::numeric,(h->>'tax')::numeric,(h->>'total')::numeric,(h->>'discount')::numeric,
      COALESCE(h->>'doc_type','invoice'),(h->>'linked')::uuid,h->>'gstin',CASE WHEN h->>'doc_type' IS NULL THEN NULL ELSE '996721' END,
      CASE WHEN h->>'doc_type' IS NULL THEN NULL ELSE '996719' END,h->>'cgstin',h->>'state',h->>'pos',h->>'head',
      (h->>'cgst')::numeric,(h->>'sgst')::numeric,(h->>'igst')::numeric,(h->>'batch')::uuid);
  INSERT INTO public.invoice_trl(invoice_id,disp_trl_id,duration,no_of_days,labour_rate,charge,tax,gst_treatment,taxable_value,line_tax,cgst_amount,sgst_amount,
      igst_amount,issued_storage_amount)
  VALUES (v_id,(l->>'disp')::uuid,1,30,(l->>'labour_rate')::numeric,(l->>'charge')::numeric,(l->>'tax_pct')::numeric,l->>'treatment',(l->>'taxable')::numeric,
      (l->>'line_tax')::numeric,(l->>'cgst')::numeric,(l->>'sgst')::numeric,(l->>'igst')::numeric,(l->>'issued_storage')::numeric);
  PERFORM set_config('session_replication_role','origin',true);
  RETURN v_id;
END $$;

SELECT pg_temp.pk_grn('PKG1','2026-04-10',:'cust_n'::uuid,'Pack Demo Traders',120,50) AS g1 \gset
SELECT pg_temp.pk_grn('PKG2','2026-05-05',:'cust_m'::uuid,'Pack Demo Other State',40,25) AS g2 \gset
SELECT pg_temp.pk_grn('PKG3','2026-05-06',:'cust_n'::uuid,'Pack Demo Traders',50,10) AS g3 \gset
SELECT pg_temp.pk_grn('PKG4','2026-05-07',:'cust_u'::uuid,'Pack Demo Walkin',12,10) AS g4 \gset
SELECT pg_temp.pk_disp('PKD1','2026-04-20',:'g1'::uuid,:'cust_n'::uuid,'Pack Demo Traders',20) AS dq1 \gset
SELECT pg_temp.pk_disp('PKD2','2026-05-10',:'g1'::uuid,:'cust_n'::uuid,'Pack Demo Traders',30) AS dq2 \gset
SELECT pg_temp.pk_disp('PKD3','2026-05-20',:'g2'::uuid,:'cust_m'::uuid,'Pack Demo Other State',20) AS dq3 \gset
SELECT pg_temp.pk_disp('PKD4','2026-05-22',:'g3'::uuid,:'cust_n'::uuid,'Pack Demo Traders',10) AS dq4 \gset
SELECT pg_temp.pk_disp('PKD5','2026-05-22',:'g3'::uuid,:'cust_n'::uuid,'Pack Demo Traders',8) AS dq5 \gset
SELECT pg_temp.pk_disp('PKD6','2026-05-25',:'g4'::uuid,:'cust_u'::uuid,'Pack Demo Walkin',12) AS dq6 \gset
SELECT pg_temp.pk_disp('PKD7','2026-05-12',:'g1'::uuid,:'cust_n'::uuid,'Pack Demo Traders',5) AS dq7 \gset
SELECT pg_temp.pk_disp('PKD8','2026-05-12',:'g1'::uuid,:'cust_n'::uuid,'Pack Demo Traders',3) AS dq8 \gset
SELECT pg_temp.pk_disp('PKD9','2026-05-20',:'g1'::uuid,:'cust_n'::uuid,'Pack Demo Traders',1) AS dq9 \gset
SELECT pg_temp.pk_disp('PKD10','2026-05-15',:'g1'::uuid,:'cust_n'::uuid,'Pack Demo Traders',1) AS dq10 \gset
INSERT INTO warehouse_security.import_batches(applied_at) VALUES (now()) RETURNING id AS batch \gset
SELECT gen_random_uuid() AS id_d3 \gset
SELECT gen_random_uuid() AS id_d3b \gset

SELECT pg_temp.pk_inv(jsonb_build_object('id',gen_random_uuid(),'no',12,'date','2026-05-15T12:00:00+05:30','gr_id',:'g1','gr_no','PKG1','cust',:'cust_n','cust_name','Pack Demo Traders',
  'doc_type','tax_invoice','pricing','MONTHLY','labour',30.00,'tax',11.00,'total',229.00,'discount',0.00,'gstin','24AAAAA0000A1Z5','cgstin','24BBBBB1111B1Z3','state','24','pos','24','head','cgst_sgst','cgst',5.50,'sgst',5.50),
  jsonb_build_object('disp',:'dq2','labour_rate',1.00,'charge',187.50,'tax_pct',5,'treatment','taxable','taxable',217.50,'line_tax',11.00,'cgst',5.50,'sgst',5.50)) AS inv_d1 \gset
SELECT pg_temp.pk_inv(jsonb_build_object('id',gen_random_uuid(),'no',13,'date','2026-05-20T12:00:00+05:30','gr_id',:'g2','gr_no','PKG2','cust',:'cust_m','cust_name','Pack Demo Other State',
  'doc_type','tax_invoice','pricing','MONTHLY','labour',40.00,'tax',90.00,'total',590.00,'discount',0.00,'gstin','24AAAAA0000A1Z5','cgstin','27CCCCC2222C1Z1','state','27','pos','27','head','igst','igst',90.00),
  jsonb_build_object('disp',:'dq3','labour_rate',2.00,'charge',460.00,'tax_pct',18,'treatment','taxable','taxable',500.00,'line_tax',90.00,'igst',90.00)) AS inv_d2 \gset
SELECT pg_temp.pk_inv(jsonb_build_object('id',:'id_d3','no',14,'date','2026-05-22T12:00:00+05:30','gr_id',:'g3','gr_no','PKG3','cust',:'cust_n','cust_name','Pack Demo Traders','linked',:'id_d3b',
  'doc_type','tax_invoice','pricing','MONTHLY','labour',10.00,'tax',15.00,'total',310.00,'discount',5.00,'gstin','24AAAAA0000A1Z5','cgstin','24BBBBB1111B1Z3','state','24','pos','24','head','cgst_sgst','cgst',7.50,'sgst',7.50),
  jsonb_build_object('disp',:'dq4','labour_rate',1.00,'charge',290.00,'tax_pct',5,'treatment','taxable','taxable',300.00,'line_tax',15.00,'cgst',7.50,'sgst',7.50)) AS inv_d3 \gset
SELECT pg_temp.pk_inv(jsonb_build_object('id',:'id_d3b','no',15,'date','2026-05-22T12:00:00+05:30','gr_id',:'g3','gr_no','PKG3','cust',:'cust_n','cust_name','Pack Demo Traders','linked',:'id_d3',
  'doc_type','bill_of_supply','pricing','ONE_TIME','labour',0.00,'tax',0.00,'total',200.00,'discount',0.00,'gstin','24AAAAA0000A1Z5','cgstin','24BBBBB1111B1Z3','state','24','pos','24'),
  jsonb_build_object('disp',:'dq5','labour_rate',0.00,'charge',200.00,'tax_pct',0,'treatment','exempt_agri','taxable',200.00,'line_tax',0.00)) AS inv_d3b \gset
SELECT pg_temp.pk_inv(jsonb_build_object('id',gen_random_uuid(),'no',16,'date','2026-05-12T12:00:00+05:30','gr_id',:'g1','gr_no','PKG1','cust',:'cust_n','cust_name','Pack Demo Traders',
  'doc_type','tax_invoice','pricing','MONTHLY','labour',0.00,'tax',5.00,'total',105.00,'discount',0.00,'gstin','24AAAAA0000A1Z5','cgstin','24BBBBB1111B1Z3','state','24','pos','24','head','cgst_sgst','cgst',2.50,'sgst',2.50),
  jsonb_build_object('disp',:'dq8','labour_rate',0.00,'charge',100.00,'tax_pct',5,'treatment','taxable','taxable',100.00,'line_tax',5.00,'cgst',2.50,'sgst',2.50)) AS inv_d7 \gset
SELECT pg_temp.pk_inv(jsonb_build_object('id',gen_random_uuid(),'no',18,'date','2026-05-25T12:00:00+05:30','gr_id',:'g4','gr_no','PKG4','cust',:'cust_u','cust_name','Pack Demo Walkin',
  'pricing','MONTHLY','labour',0.00,'tax',5.00,'total',104.60,'discount',0.00),
  jsonb_build_object('disp',:'dq6','labour_rate',0.00,'charge',100.00,'tax_pct',5)) AS inv_d4 \gset
SELECT pg_temp.pk_inv(jsonb_build_object('id',gen_random_uuid(),'no',125,'prefix','GC/','date','2026-05-12T12:00:00+05:30','gr_id',:'g1','gr_no','PKG1','cust',:'cust_n','cust_name','Pack Demo Traders',
  'doc_type','tax_invoice','pricing','MONTHLY','labour',50.00,'tax',22.50,'total',472.50,'discount',0.00,'gstin','24AAAAA0000A1Z5','cgstin','24BBBBB1111B1Z3','state','24','pos','24','head','cgst_sgst','cgst',11.25,'sgst',11.25,'batch',:'batch'),
  jsonb_build_object('disp',:'dq7','labour_rate',1.00,'charge',400.00,'tax_pct',5,'treatment','taxable','taxable',450.00,'line_tax',22.50,'cgst',11.25,'sgst',11.25,'issued_storage',400.00)) AS inv_d6 \gset
SELECT pg_temp.pk_inv(jsonb_build_object('id',gen_random_uuid(),'no',19,'date','2026-05-20T12:00:00+05:30','gr_id',:'g1','gr_no','PKG1','cust',:'cust_n','cust_name','Pack Demo Traders',
  'doc_type','tax_invoice','pricing','MONTHLY','labour',0.00,'tax',5.00,'total',105.00,'discount',0.00,'gstin','24AAAAA0000A1Z5','cgstin','24BBBBB1111B1Z3','state','24','pos','24','head','cgst_sgst','cgst',2.50,'sgst',2.50),
  jsonb_build_object('disp',:'dq9','labour_rate',0.00,'charge',100.00,'tax_pct',5,'treatment','taxable','taxable',100.00,'line_tax',5.00,'cgst',2.50,'sgst',2.50)) AS inv_x \gset
SELECT pg_temp.pk_inv(jsonb_build_object('id',gen_random_uuid(),'no',20,'date','2026-05-15T12:00:00+05:30','gr_id',:'g1','gr_no','PKG1','cust',:'cust_n','cust_name','Pack Demo Traders',
  'doc_type','tax_invoice','pricing','MONTHLY','labour',0.00,'tax',5.00,'total',105.00,'discount',0.00,'gstin','24AAAAA0000A1Z5','cgstin','24BBBBB1111B1Z3','state','24','pos','24','head','cgst_sgst','cgst',2.50,'sgst',2.50),
  jsonb_build_object('disp',:'dq10','labour_rate',0.00,'charge',100.00,'tax_pct',5,'treatment','taxable','taxable',100.00,'line_tax',5.00,'cgst',2.50,'sgst',2.50)) AS inv_y \gset

-- Payments (Record payments is on). The imported one carries the mark; the older row has no paid_on (India date of payment_date: 2026-05-23, and 2026-06-01).
INSERT INTO public.payments(payment_no,payment_date,paid_on,customer_id,invoice_id,amount,payment_mode) VALUES
 ('APP-41','2026-05-20T12:00:00+05:30','2026-05-20',:'cust_n'::uuid,:'inv_d1'::uuid,229.00,'upi'),
 ('APP-42','2026-05-21T12:00:00+05:30','2026-05-21',:'cust_n'::uuid,:'inv_d1'::uuid,200000.00,'cash'),
 ('APP-43','2026-05-21T12:00:00+05:30','2026-05-21',:'cust_n'::uuid,:'inv_d1'::uuid,199999.00,'cash');
INSERT INTO public.payments(payment_no,payment_date,customer_id,invoice_id,amount,payment_mode,bank,cheque_no) VALUES
 ('OLD-7','2026-05-22T20:00:00Z',:'cust_n'::uuid,:'inv_d1'::uuid,500.00,'cheque','Demo Bank','CHQ123');
INSERT INTO public.payments(payment_no,payment_date,customer_id,invoice_id,amount,payment_mode) VALUES
 ('OLD-8','2026-05-31T19:00:00Z',:'cust_n'::uuid,:'inv_d1'::uuid,10.00,'cash');
INSERT INTO public.payments(payment_no,payment_date,paid_on,customer_id,customer_name,amount,payment_mode) VALUES
 ('APP-44','2026-05-24T12:00:00+05:30','2026-05-24',:'cust_n'::uuid,'Pack Demo Traders',40.00,'bank_transfer');
INSERT INTO public.payments(payment_no,payment_date,paid_on,customer_id,invoice_id,amount,payment_mode,online_ref) VALUES
 ('APP-45','2026-05-24T12:00:00+05:30','2026-05-24',:'cust_n'::uuid,:'inv_d1'::uuid,60.00,'upi','UTR9');
INSERT INTO public.payments(payment_no,payment_date,paid_on,customer_name,amount,payment_mode) VALUES
 ('APP-46','2026-05-25T12:00:00+05:30','2026-05-25','Walk-in Payer',15.00,'cash');
SELECT set_config('session_replication_role','replica',true) AS x \gset
INSERT INTO public.payments(payment_no,payment_date,paid_on,customer_id,invoice_id,amount,payment_mode,import_batch_id) VALUES
 ('IMP-R1','2026-05-26T12:00:00+05:30','2026-05-26',:'cust_n'::uuid,:'inv_d6'::uuid,100.00,'cash',:'batch'::uuid);
SELECT set_config('session_replication_role','origin',true) AS x \gset
SELECT warehouse_security.business_date(now()) AS today \gset
SELECT make_date(CASE WHEN extract(month FROM :'today'::date) >= 4 THEN extract(year FROM :'today'::date)::int ELSE extract(year FROM :'today'::date)::int - 1 END, 4, 1) AS fy_start \gset
INSERT INTO public.payments(payment_no,payment_date,paid_on,customer_id,amount,payment_mode) VALUES ('APP-99',now(),:'today'::date,:'cust_n'::uuid,5.00,'cash');

-- The cancelled document SRT/16 (cancelled on 2026-05-18), by the real function.
SELECT pg_temp.pk_as(:'admin_claims'::jsonb, format($q$SELECT public.cancel_invoice(%L::uuid,'Entered twice',NULL)$q$, :'inv_d7')) AS c7 \gset
SELECT pg_temp.pk_assert(:'c7'::jsonb->>'success'='true','SRT/16 cancelled: '||:'c7');
SET LOCAL session_replication_role = replica;
UPDATE public.invoice SET cancelled_at = '2026-05-18T11:00:00+05:30' WHERE id = :'inv_d7'::uuid;
RESET session_replication_role;

-- ===== migration 200: the ledger names (criterion 9; contract section 3) =====
SELECT pg_temp.pk_assert((SELECT value::text FROM public.system_settings WHERE key = 'accountant_export') IN ('{}', '"{}"'), 'migration 200 seeds the system_settings row accountant_export as {}');
SELECT pg_temp.pk_as(:'admin_claims'::jsonb, $q$SELECT public.get_accountant_ledgers()$q$) AS led0 \gset
SELECT pg_temp.pk_assert(:'led0'::jsonb->>'success'='true' AND (:'led0'::jsonb#>>'{data,saved}')='false', 'get_accountant_ledgers answers saved=false at first: '||:'led0');
SELECT pg_temp.pk_assert(:'led0'::jsonb#>'{data,ledgers}' = :'led0'::jsonb#>'{data,defaults}', 'the ledgers are the defaults before any save');
SELECT pg_temp.pk_assert(:'led0'::jsonb#>'{data,defaults}' = '{"storage_taxable":"Cold Storage Rent","storage_exempt":"Cold Storage Rent (Exempt)","labour":"Labour Charges","cgst":"CGST","sgst":"SGST","igst":"IGST","discount":"Discount Allowed","round_off":"Round Off","receipt_cash":"Cash","receipt_upi":"Bank","receipt_bank_transfer":"Bank","receipt_cheque":"Bank","receipt_other":"Bank"}'::jsonb,
  'the 13 keys and defaults: '||(:'led0'::jsonb#>>'{data,defaults}'));
-- Refusals store nothing.
SELECT :'led0'::jsonb#>'{data,defaults}' AS defaults_json \gset
SELECT pg_temp.pk_as(:'admin_claims'::jsonb, format($q$SELECT public.set_accountant_ledgers(%L::jsonb - 'igst')$q$, :'defaults_json')) AS r_missing \gset
SELECT pg_temp.pk_as(:'admin_claims'::jsonb, format($q$SELECT public.set_accountant_ledgers(%L::jsonb || '{"extra":"x"}'::jsonb)$q$, :'defaults_json')) AS r_extra \gset
SELECT pg_temp.pk_as(:'admin_claims'::jsonb, format($q$SELECT public.set_accountant_ledgers(%L::jsonb || '{"labour":"   "}'::jsonb)$q$, :'defaults_json')) AS r_blank \gset
SELECT pg_temp.pk_as(:'admin_claims'::jsonb, format($q$SELECT public.set_accountant_ledgers(%L::jsonb || jsonb_build_object('labour', repeat('x', 61)))$q$, :'defaults_json')) AS r_long \gset
SELECT pg_temp.pk_as(:'admin_claims'::jsonb, format($q$SELECT public.set_accountant_ledgers(%L::jsonb || jsonb_build_object('labour', 'Bad' || chr(7) || 'Name'))$q$, :'defaults_json')) AS r_control \gset
SELECT pg_temp.pk_assert(:'r_missing'::jsonb->>'success'='false' AND :'r_missing'::jsonb->>'reason'='LEDGER_KEYS' AND :'r_missing'::jsonb->>'error_code'='WH409'
  AND :'r_missing'::jsonb->>'error'='Send all 13 ledger names and nothing else.', 'a missing key: '||:'r_missing');
SELECT pg_temp.pk_assert(:'r_extra'::jsonb->>'reason'='LEDGER_KEYS' AND :'r_extra'::jsonb->>'error'='Send all 13 ledger names and nothing else.', 'an extra key: '||:'r_extra');
SELECT pg_temp.pk_assert(:'r_blank'::jsonb->>'success'='false' AND :'r_blank'::jsonb->>'reason'='LEDGER_NAME_REQUIRED' AND :'r_blank'::jsonb->>'error_code'='WH409'
  AND :'r_blank'::jsonb->>'error'='Enter a ledger name.' AND :'r_blank'::jsonb->>'field'='labour', 'a blank name (after trimming): '||:'r_blank');
SELECT pg_temp.pk_assert(:'r_long'::jsonb->>'success'='false' AND :'r_long'::jsonb->>'reason'='LEDGER_NAME_TOO_LONG' AND :'r_long'::jsonb->>'error_code'='WH409'
  AND :'r_long'::jsonb->>'error'='A ledger name has at most 60 characters.' AND :'r_long'::jsonb->>'field'='labour', '61 characters: '||:'r_long');
SELECT pg_temp.pk_assert(:'r_control'::jsonb->>'success'='false', 'a control character is refused: '||:'r_control');
SELECT pg_temp.pk_as(:'admin_claims'::jsonb, format($q$SELECT public.set_accountant_ledgers(%L::jsonb || jsonb_build_object('labour', repeat('y', 60)))$q$, :'defaults_json')) AS r_sixty \gset
SELECT pg_temp.pk_assert(:'r_sixty'::jsonb->>'success'='true', '60 characters pass: '||:'r_sixty');
SELECT pg_temp.pk_assert((SELECT count(*) FROM public.audit_log WHERE table_name = 'accountant_export') = 1, 'refusals wrote no audit row, the one save wrote one');
-- A save: names trimmed, one audit row, the same values again write nothing.
SELECT pg_temp.pk_as(:'admin_claims'::jsonb, format($q$SELECT public.set_accountant_ledgers(%L::jsonb || '{"labour":"  Labour X  ","storage_taxable":"Rent X","cgst":"CGST X","sgst":"SGST X","igst":"IGST X","round_off":"Round X","discount":"Disc X","storage_exempt":"Rent Exempt X","receipt_cash":"Cash X","receipt_upi":"UPI X","receipt_bank_transfer":"Bank X","receipt_cheque":"Cheque X","receipt_other":"Other X"}'::jsonb)$q$, :'defaults_json')) AS r_save \gset
SELECT pg_temp.pk_assert(:'r_save'::jsonb->>'success'='true' AND (:'r_save'::jsonb#>>'{data,changed}')='true' AND (:'r_save'::jsonb#>>'{data,saved}')='true'
  AND (:'r_save'::jsonb#>>'{data,ledgers,labour}')='Labour X' AND (:'r_save'::jsonb#>>'{data,defaults,labour}')='Labour Charges', 'the save: '||:'r_save');
SELECT pg_temp.pk_assert((SELECT count(*) FROM public.audit_log WHERE table_name = 'accountant_export') = 2, 'a change writes one audit_log row');
SELECT :'r_save'::jsonb#>'{data,ledgers}' AS saved_json \gset
SELECT pg_temp.pk_as(:'admin_claims'::jsonb, format($q$SELECT public.set_accountant_ledgers(%L::jsonb)$q$, :'saved_json')) AS r_same \gset
SELECT pg_temp.pk_assert((:'r_same'::jsonb#>>'{data,changed}')='false' AND (SELECT count(*) FROM public.audit_log WHERE table_name = 'accountant_export') = 2, 'the same values again change nothing and write no audit row: '||:'r_same');
SELECT pg_temp.pk_as(:'admin_claims'::jsonb, $q$SELECT public.get_accountant_ledgers()$q$) AS led1 \gset
SELECT pg_temp.pk_assert(:'led1'::jsonb#>'{data,ledgers}' = :'saved_json'::jsonb AND (:'led1'::jsonb#>>'{data,saved}')='true', 'get answers the saved names');
-- Roles: administrators only for the two ledger calls; staff, customers and a supervisor raise 42501; service_role passes.
SELECT pg_temp.pk_as(:'staff_claims'::jsonb, $q$SELECT public.get_accountant_ledgers()$q$) AS l_staff \gset
SELECT pg_temp.pk_as(:'customer_claims'::jsonb, $q$SELECT public.get_accountant_ledgers()$q$) AS l_cust \gset
SELECT pg_temp.pk_as(:'supervisor_claims'::jsonb, $q$SELECT public.get_accountant_ledgers()$q$) AS l_sup \gset
SELECT pg_temp.pk_as(:'staff_claims'::jsonb, format($q$SELECT public.set_accountant_ledgers(%L::jsonb)$q$, :'saved_json')) AS s_staff \gset
SELECT pg_temp.pk_as(:'customer_claims'::jsonb, format($q$SELECT public.set_accountant_ledgers(%L::jsonb)$q$, :'saved_json')) AS s_cust \gset
SELECT pg_temp.pk_as(:'supervisor_claims'::jsonb, format($q$SELECT public.set_accountant_ledgers(%L::jsonb)$q$, :'saved_json')) AS s_sup \gset
SELECT pg_temp.pk_assert((SELECT bool_and(a->>'state' = '42501') FROM unnest(ARRAY[:'l_staff'::jsonb,:'l_cust'::jsonb,:'l_sup'::jsonb,:'s_staff'::jsonb,:'s_cust'::jsonb,:'s_sup'::jsonb]) a),
  'get/set_accountant_ledgers raise 42501 for staff, customers and supervisors');
SELECT pg_temp.pk_assert(:'l_sup'::jsonb->>'raised' = 'Administrator required' AND :'s_sup'::jsonb->>'raised' = 'Administrator required', 'the ledger calls say "Administrator required"');
SELECT pg_temp.pk_svc($q$SELECT public.get_accountant_ledgers()$q$) AS l_svc \gset
SELECT pg_temp.pk_assert(:'l_svc'::jsonb->>'success'='true', 'service_role passes: '||:'l_svc');
SELECT pg_temp.pk_assert(NOT has_function_privilege('anon','public.get_accountant_ledgers()','EXECUTE') AND has_function_privilege('authenticated','public.get_accountant_ledgers()','EXECUTE')
  AND NOT has_function_privilege('anon','public.set_accountant_ledgers(jsonb)','EXECUTE') AND has_function_privilege('authenticated','public.set_accountant_ledgers(jsonb)','EXECUTE')
  AND has_function_privilege('service_role','public.set_accountant_ledgers(jsonb)','EXECUTE'), 'grants of the ledger calls');

-- ===== migration 201: the record of packs =====
SELECT pg_temp.pk_assert(NOT EXISTS (SELECT 1 FROM unnest(ARRAY['anon','authenticated']) r CROSS JOIN unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE']) p
  WHERE has_table_privilege(r, 'warehouse_security.accountant_packs', p)), '[crit 14] anon and authenticated cannot read, insert, update, delete or truncate accountant_packs');
SELECT pg_temp.pk_assert(has_table_privilege('service_role','warehouse_security.accountant_packs','SELECT') AND NOT has_table_privilege('service_role','warehouse_security.accountant_packs','INSERT')
  AND NOT has_table_privilege('service_role','warehouse_security.accountant_packs','UPDATE') AND NOT has_table_privilege('service_role','warehouse_security.accountant_packs','DELETE'), 'service_role may only read accountant_packs');
SELECT pg_temp.pk_assert((SELECT relrowsecurity FROM pg_class WHERE oid = 'warehouse_security.accountant_packs'::regclass)
  AND NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'warehouse_security' AND tablename = 'accountant_packs'), 'row security is on with no policy');
SELECT pg_temp.pk_assert(NOT has_function_privilege('anon','public.get_accountant_pack(date,date)','EXECUTE') AND has_function_privilege('authenticated','public.get_accountant_pack(date,date)','EXECUTE')
  AND has_function_privilege('service_role','public.get_accountant_pack(date,date)','EXECUTE'), 'grants of get_accountant_pack');
SELECT pg_temp.pk_assert(pg_temp.pk_packs_count() = 0, 'no pack recorded yet');

-- [crit 9] roles on the pack: staff and customers raise 42501, no record; supervisors and administrators pass.
SELECT pg_temp.pk_pack(:'staff_claims'::jsonb,'2026-05-01','2026-05-31') AS p_staff \gset
SELECT pg_temp.pk_pack(:'customer_claims'::jsonb,'2026-05-01','2026-05-31') AS p_cust \gset
SELECT pg_temp.pk_assert(:'p_staff'::jsonb->>'state'='42501' AND :'p_cust'::jsonb->>'state'='42501', '[crit 9] staff and customers are refused get_accountant_pack: '||:'p_staff'||:'p_cust');
SELECT pg_temp.pk_assert(:'p_staff'::jsonb->>'raised'='Administrator or supervisor required', 'the refusal text is "Administrator or supervisor required"');
SELECT pg_temp.pk_assert(pg_temp.pk_packs_count() = 0, 'a refused role records nothing');
-- Refusals, in order, record nothing.
SELECT pg_temp.pk_pack(:'admin_claims'::jsonb,'2026-05-31','2026-05-01') AS r_order \gset
SELECT pg_temp.pk_pack(:'admin_claims'::jsonb,'2026-03-01','2099-12-31') AS r_future_across \gset
SELECT pg_temp.pk_as(:'admin_claims'::jsonb, $q$SELECT public.get_accountant_pack(NULL::date, '2026-05-31'::date)$q$) AS r_null \gset
SELECT pg_temp.pk_pack(:'admin_claims'::jsonb,'2026-03-01','2026-04-30') AS r_across \gset
SELECT pg_temp.pk_pack(:'admin_claims'::jsonb,'2026-02-01','2026-02-28') AS r_nothing \gset
SELECT pg_temp.pk_assert((SELECT bool_and(a->>'success'='false' AND a->>'reason'='INVALID_PERIOD' AND a->>'error_code'='WH409' AND a->>'error'='Choose a period that ends today or earlier.')
  FROM unnest(ARRAY[:'r_order'::jsonb,:'r_future_across'::jsonb,:'r_null'::jsonb]) a), '[crit 9] INVALID_PERIOD (To before From, To after today and it wins over the year check, a missing date): '||:'r_order'||:'r_future_across'||:'r_null');
SELECT pg_temp.pk_assert(:'r_across'::jsonb->>'reason'='PERIOD_ACROSS_YEARS' AND :'r_across'::jsonb->>'error_code'='WH409' AND :'r_across'::jsonb->>'error'='Choose dates inside one financial year.', '[crit 9] PERIOD_ACROSS_YEARS: '||:'r_across');
SELECT pg_temp.pk_assert(:'r_nothing'::jsonb->>'reason'='NOTHING_IN_PERIOD' AND :'r_nothing'::jsonb->>'error_code'='WH409' AND :'r_nothing'::jsonb->>'error'='No invoices or receipts in this period.', '[crit 9] NOTHING_IN_PERIOD: '||:'r_nothing');
SELECT pg_temp.pk_assert(pg_temp.pk_packs_count() = 0, '[crit 14] a refusal records no pack');

-- ===== pack A (May 2026), by a supervisor =====
SELECT pg_temp.pk_pack(:'supervisor_claims'::jsonb,'2026-05-01','2026-05-31') AS pack_a \gset
SELECT pg_temp.pk_assert(:'pack_a'::jsonb->>'success'='true', 'pack A by a supervisor: '||left(:'pack_a',400));
SELECT pg_temp.pk_assert(pg_temp.pk_packs_count() = 1 AND (SELECT period_from = '2026-05-01' AND period_to = '2026-05-31' AND made_by = :'supervisor_profile'::uuid
  AND made_by_name = 'Pack Demo Supervisor' AND made_at = (:'pack_a'::jsonb#>>'{data,made_at}')::timestamptz FROM warehouse_security.accountant_packs),
  '[crit 14] one accountant_packs row: period, made_at (the read''s), the caller and the name');
SELECT pg_temp.pk_assert(:'pack_a'::jsonb#>>'{data,made_by}' = 'Pack Demo Supervisor', 'made_by is the caller''s profile name');
SELECT pg_temp.pk_assert(:'pack_a'::jsonb#>>'{data,period,from_date}'='2026-05-01' AND :'pack_a'::jsonb#>>'{data,period,to_date}'='2026-05-31'
  AND (:'pack_a'::jsonb#>>'{data,period,fin_year}')::int = 2026 AND (:'pack_a'::jsonb#>>'{data,period,whole_month}')='true' AND (:'pack_a'::jsonb#>>'{data,record_payments}')='true', 'period block');
SELECT pg_temp.pk_assert(:'pack_a'::jsonb#>>'{data,facility,gstin}'='24AAAAA0000A1Z5' AND :'pack_a'::jsonb#>>'{data,facility,legal_name}'='Pack Demo Cold Storage'
  AND :'pack_a'::jsonb#>>'{data,facility,state_code}'='24' AND :'pack_a'::jsonb#>>'{data,facility,state_name}'='Gujarat'
  AND (:'pack_a'::jsonb#>>'{data,facility,registered}')='true' AND (:'pack_a'::jsonb#>>'{data,facility,gst_saved}')='true' AND (:'pack_a'::jsonb#>'{data,facility}') ? 'name', 'facility block');
SELECT pg_temp.pk_assert(:'pack_a'::jsonb#>'{data,ledgers}' = :'saved_json'::jsonb, 'the pack carries the ledger names in force');
SELECT pg_temp.pk_as(:'admin_claims'::jsonb, $q$SELECT public.get_accountant_pack('2026-05-01'::date,'2026-05-20'::date)$q$) AS pack_part \gset
SELECT pg_temp.pk_assert((:'pack_part'::jsonb#>>'{data,period,whole_month}')='false', 'a part of a month is not whole_month');
SELECT pg_temp.pk_assert(pg_temp.pk_packs_count() = 2, 'each call adds one row');

-- [crit 1] rows per document x rate x kind; parts add back to the stored figures.
SELECT pg_temp.pk_assert(jsonb_array_length(pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/12')->'rows') = 2, '[crit 1] SRT/12 has two rows (storage, labour)');
SELECT pg_temp.pk_assert((pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/12')#>>'{rows,0,kind}')='storage' AND (pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/12')#>>'{rows,1,kind}')='labour', 'storage first, then labour');
SELECT pg_temp.pk_assert((pg_temp.pk_row_of(:'pack_a'::jsonb,'SRT/12','storage')->>'taxable_value')::numeric = 187.50
  AND (pg_temp.pk_row_of(:'pack_a'::jsonb,'SRT/12','storage')->>'cgst')::numeric = 4.74 AND (pg_temp.pk_row_of(:'pack_a'::jsonb,'SRT/12','storage')->>'sgst')::numeric = 4.74
  AND (pg_temp.pk_row_of(:'pack_a'::jsonb,'SRT/12','storage')->>'tax')::numeric = 9.48 AND (pg_temp.pk_row_of(:'pack_a'::jsonb,'SRT/12','storage')->>'rate')::numeric = 5
  AND (pg_temp.pk_row_of(:'pack_a'::jsonb,'SRT/12','labour')->>'taxable_value')::numeric = 30.00 AND (pg_temp.pk_row_of(:'pack_a'::jsonb,'SRT/12','labour')->>'cgst')::numeric = 0.76
  AND (pg_temp.pk_row_of(:'pack_a'::jsonb,'SRT/12','labour')->>'tax')::numeric = 1.52, '[crit 1] SRT/12: the stored tax shared over the rows to the paisa (D3)');
SELECT pg_temp.pk_assert((pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/12')->>'total')::numeric = 229.00 AND (pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/12')->>'round_off')::numeric = 0.50
  AND (pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/12')->>'discount')::numeric = 0 AND pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/12')->>'doc_type' = 'tax_invoice'
  AND pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/12')->>'date' = '2026-05-15' AND pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/12')->>'status' = 'live'
  AND pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/12')->>'customer_gstin' = '24BBBBB1111B1Z3' AND pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/12')->>'customer_state' = 'Gujarat (24)'
  AND pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/12')->>'place_of_supply' = 'Gujarat (24)' AND pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/12')->>'gr_no' = 'PKG1'
  AND pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/12')->>'sac_storage' = '996721' AND pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/12')->>'sac_labour' = '996719'
  AND pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/12')->>'tax_head' = 'cgst_sgst' AND (pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/12')->>'imported')='false'
  AND (pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/12')->>'before_gst')='false' AND pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/12')->>'customer_name' = 'Pack Demo Traders', 'SRT/12 header fields');
SELECT pg_temp.pk_assert((pg_temp.pk_row_of(:'pack_a'::jsonb,'SRT/13','storage')->>'igst')::numeric = 82.80 AND (pg_temp.pk_row_of(:'pack_a'::jsonb,'SRT/13','labour')->>'igst')::numeric = 7.20
  AND (pg_temp.pk_row_of(:'pack_a'::jsonb,'SRT/13','storage')->>'taxable_value')::numeric = 460.00 AND (pg_temp.pk_row_of(:'pack_a'::jsonb,'SRT/13','labour')->>'taxable_value')::numeric = 40.00
  AND (pg_temp.pk_row_of(:'pack_a'::jsonb,'SRT/13','storage')->>'rate')::numeric = 18 AND pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/13')->>'tax_head' = 'igst'
  AND pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/13')->>'customer_state' = 'Maharashtra (27)', '[crit 1] the inter-state document: IGST rows 82.80 and 7.20');
SELECT pg_temp.pk_assert((pg_temp.pk_row_of(:'pack_a'::jsonb,'SRT/14','storage')->>'tax')::numeric = 14.50 AND (pg_temp.pk_row_of(:'pack_a'::jsonb,'SRT/14','labour')->>'tax')::numeric = 0.50
  AND (pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/14')->>'discount')::numeric = 5.00 AND (pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/14')->>'total')::numeric = 310.00
  AND (pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/14')->>'round_off')::numeric = 0 AND pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/14')->>'linked_number' = 'SRT/15'
  AND pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/15')->>'linked_number' = 'SRT/14', '[crit 1] the pair: both name each other; discount and total');
SELECT pg_temp.pk_assert(jsonb_array_length(pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/15')->'rows') = 1 AND (pg_temp.pk_row_of(:'pack_a'::jsonb,'SRT/15','storage',true)->>'exempt_value')::numeric = 200.00
  AND (pg_temp.pk_row_of(:'pack_a'::jsonb,'SRT/15','storage',true)->>'taxable_value')::numeric = 0 AND (pg_temp.pk_row_of(:'pack_a'::jsonb,'SRT/15','storage',true)->>'rate')::numeric = 0
  AND pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/15')->>'doc_type' = 'bill_of_supply' AND (pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/15')->>'total')::numeric = 200.00,
  '[crit 1] the bill of supply: one exempt storage row, exempt_value 200.00, taxable_value 0.00');
-- The sums of the live rows equal the stored figures (documents with GST details; before-GST ones are checked below).
SELECT (SELECT sum(t.taxable_value) FROM public.invoice_trl t JOIN public.invoice i ON i.id = t.invoice_id
         WHERE i.inv_date >= '2026-05-01+05:30' AND i.inv_date < '2026-06-01+05:30' AND i.deleted_at IS NULL AND i.cancelled_at IS NULL AND i.doc_type <> 'invoice') AS stored_value,
       (SELECT sum(cgst_amount) FROM public.invoice i WHERE i.inv_date >= '2026-05-01+05:30' AND i.inv_date < '2026-06-01+05:30' AND i.deleted_at IS NULL AND i.cancelled_at IS NULL AND i.doc_type <> 'invoice') AS stored_cgst,
       (SELECT sum(sgst_amount) FROM public.invoice i WHERE i.inv_date >= '2026-05-01+05:30' AND i.inv_date < '2026-06-01+05:30' AND i.deleted_at IS NULL AND i.cancelled_at IS NULL AND i.doc_type <> 'invoice') AS stored_sgst,
       (SELECT sum(igst_amount) FROM public.invoice i WHERE i.inv_date >= '2026-05-01+05:30' AND i.inv_date < '2026-06-01+05:30' AND i.deleted_at IS NULL AND i.cancelled_at IS NULL AND i.doc_type <> 'invoice') AS stored_igst \gset
SELECT pg_temp.pk_assert((SELECT sum((r->>'taxable_value')::numeric + (r->>'exempt_value')::numeric) FROM jsonb_array_elements(:'pack_a'::jsonb#>'{data,documents}') d, jsonb_array_elements(d->'rows') r
   WHERE d->>'status' = 'live' AND (d->>'before_gst')::boolean = false) = :stored_value::numeric, '[crit 1] taxable + exempt of the rows = the stored line taxable values ('||:'stored_value'||')');
SELECT pg_temp.pk_assert((SELECT sum((r->>'cgst')::numeric) FROM jsonb_array_elements(:'pack_a'::jsonb#>'{data,documents}') d, jsonb_array_elements(d->'rows') r WHERE d->>'status' = 'live' AND (d->>'before_gst')::boolean = false) = :stored_cgst::numeric
  AND (SELECT sum((r->>'sgst')::numeric) FROM jsonb_array_elements(:'pack_a'::jsonb#>'{data,documents}') d, jsonb_array_elements(d->'rows') r WHERE d->>'status' = 'live' AND (d->>'before_gst')::boolean = false) = :stored_sgst::numeric
  AND (SELECT sum((r->>'igst')::numeric) FROM jsonb_array_elements(:'pack_a'::jsonb#>'{data,documents}') d, jsonb_array_elements(d->'rows') r WHERE d->>'status' = 'live' AND (d->>'before_gst')::boolean = false) = :stored_igst::numeric,
  '[crit 1] each tax head of the rows = the stored header (CGST '||:'stored_cgst'||', SGST '||:'stored_sgst'||', IGST '||:'stored_igst'||')');
SELECT pg_temp.pk_assert(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(:'pack_a'::jsonb#>'{data,documents}') d WHERE d->>'deleted_at' IS NOT NULL), 'no deleted row is listed');

-- [crit 9] documents made before GST details: counted, tax as stored, GST heads null.
SELECT pg_temp.pk_assert((pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/18')->>'before_gst')='true' AND pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/18')->>'doc_type'='invoice'
  AND (SELECT count(*) FROM jsonb_array_elements(:'pack_a'::jsonb#>'{data,documents}') d WHERE (d->>'before_gst')::boolean) = 1, '[crit 9] SRT/18 is flagged before_gst, and it is the only one');
SELECT pg_temp.pk_assert((pg_temp.pk_row_of(:'pack_a'::jsonb,'SRT/18','storage')->>'cgst') IS NULL AND (pg_temp.pk_row_of(:'pack_a'::jsonb,'SRT/18','storage')->>'sgst') IS NULL
  AND (pg_temp.pk_row_of(:'pack_a'::jsonb,'SRT/18','storage')->>'igst') IS NULL AND (pg_temp.pk_row_of(:'pack_a'::jsonb,'SRT/18','storage')->>'tax')::numeric = 5.00
  AND (pg_temp.pk_row_of(:'pack_a'::jsonb,'SRT/18','storage')->>'taxable_value')::numeric = 100.00 AND (pg_temp.pk_row_of(:'pack_a'::jsonb,'SRT/18','storage')->>'rate')::numeric = 5
  AND (pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/18')->>'total')::numeric = 104.60 AND (pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/18')->>'round_off')::numeric = -0.40,
  '[crit 9] before-GST row: cgst/sgst/igst null, tax 5.00 as stored, taxable 100.00, round-off -0.40');

-- [crit 9] WH-180 criterion 19: the imported document is in the register, marked.
SELECT pg_temp.pk_assert((pg_temp.pk_doc_of(:'pack_a'::jsonb,'GC/125')->>'imported')='true' AND pg_temp.pk_doc_of(:'pack_a'::jsonb,'GC/125')->>'status'='live', '[crit 9] the imported GC/125 is listed, imported true');
SELECT pg_temp.pk_assert((pg_temp.pk_row_of(:'pack_a'::jsonb,'GC/125','storage')->>'taxable_value')::numeric = 400.00 AND (pg_temp.pk_row_of(:'pack_a'::jsonb,'GC/125','labour')->>'taxable_value')::numeric = 50.00,
  '[crit 9] an imported line: storage = issued_storage_amount (400.00), labour = taxable_value - storage (50.00)');

-- [crit 2] a cancelled document: listed, status cancelled, with the figures and the date; D6 (a): a cancellation entry.
SELECT pg_temp.pk_assert(pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/16')->>'status'='cancelled' AND pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/16')->>'cancelled_on'='2026-05-18'
  AND (pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/16')->>'total')::numeric = 105.00 AND jsonb_array_length(pg_temp.pk_doc_of(:'pack_a'::jsonb,'SRT/16')->'rows') = 1, '[crit 2] SRT/16 is listed as cancelled, cancelled_on 2026-05-18, with its figures');
SELECT pg_temp.pk_assert(pg_temp.pk_canc_of(:'pack_a'::jsonb,'SRT/16')->>'reason' = 'in_period' AND pg_temp.pk_canc_of(:'pack_a'::jsonb,'SRT/16')->>'id' = :'inv_d7'
  AND pg_temp.pk_canc_of(:'pack_a'::jsonb,'SRT/16')->>'date' = '2026-05-12' AND pg_temp.pk_canc_of(:'pack_a'::jsonb,'SRT/16')->>'cancelled_on' = '2026-05-18'
  AND pg_temp.pk_canc_of(:'pack_a'::jsonb,'SRT/16')->>'customer_name' = 'Pack Demo Traders' AND pg_temp.pk_canc_of(:'pack_a'::jsonb,'SRT/16')->>'doc_type' = 'tax_invoice',
  '[crit 2][crit 14] a cancelled document dated in the period has a cancellation, reason in_period, with its identity');
SELECT pg_temp.pk_assert(jsonb_array_length(:'pack_a'::jsonb#>'{data,cancellations}') = 1, 'only SRT/16 is cancelled so far');

-- [crit 4] the gap, and the issued block.
SELECT pg_temp.pk_assert((:'pack_a'::jsonb#>'{data,missing_numbers}') @> '["SRT/17"]'::jsonb AND jsonb_array_length(:'pack_a'::jsonb#>'{data,missing_numbers}') = 1,
  '[crit 4] missing_numbers names SRT/17 and nothing else: '||(:'pack_a'::jsonb#>>'{data,missing_numbers}'));
SELECT pg_temp.pk_assert((SELECT (i->>'count')::int = 7 AND (i->>'cancelled')::int = 1 FROM jsonb_array_elements(:'pack_a'::jsonb#>'{data,issued}') i WHERE i->>'doc_type'='tax_invoice')
  AND (SELECT (i->>'count')::int = 1 AND (i->>'cancelled')::int = 0 FROM jsonb_array_elements(:'pack_a'::jsonb#>'{data,issued}') i WHERE i->>'doc_type'='bill_of_supply')
  AND (SELECT (i->>'count')::int = 1 FROM jsonb_array_elements(:'pack_a'::jsonb#>'{data,issued}') i WHERE i->>'doc_type'='invoice'), '[crit 4] issued: 7 tax invoices (1 cancelled), 1 bill of supply, 1 before-GST invoice');

-- [crit 5] cash of 2,00,000 or more.
SELECT pg_temp.pk_assert((pg_temp.pk_pay_of(:'pack_a'::jsonb,'APP-42')->>'cash_large')='true' AND (pg_temp.pk_pay_of(:'pack_a'::jsonb,'APP-43')->>'cash_large')='false'
  AND (pg_temp.pk_pay_of(:'pack_a'::jsonb,'APP-42')->>'amount')::numeric = 200000.00 AND (pg_temp.pk_pay_of(:'pack_a'::jsonb,'APP-41')->>'cash_large')='false'
  AND (pg_temp.pk_pay_of(:'pack_a'::jsonb,'APP-46')->>'cash_large')='false', '[crit 5] cash 200000.00 is flagged, 199999.00 and 15.00 and a UPI payment are not');
-- Payments: the day (paid_on, else the India date of payment_date), bank and reference, the customer, imported, the invoice number.
SELECT pg_temp.pk_assert(pg_temp.pk_pay_of(:'pack_a'::jsonb,'OLD-7')->>'paid_on' = '2026-05-23' AND pg_temp.pk_pay_of(:'pack_a'::jsonb,'OLD-8') IS NULL
  AND pg_temp.pk_pay_of(:'pack_a'::jsonb,'OLD-7')->>'bank' = 'Demo Bank' AND pg_temp.pk_pay_of(:'pack_a'::jsonb,'OLD-7')->>'reference' = 'CHQ123' AND pg_temp.pk_pay_of(:'pack_a'::jsonb,'OLD-7')->>'mode' = 'cheque'
  AND pg_temp.pk_pay_of(:'pack_a'::jsonb,'APP-45')->>'reference' = 'UTR9' AND pg_temp.pk_pay_of(:'pack_a'::jsonb,'APP-41')->>'invoice_number' = 'SRT/12'
  AND pg_temp.pk_pay_of(:'pack_a'::jsonb,'APP-41')->>'paid_on' = '2026-05-20' AND pg_temp.pk_pay_of(:'pack_a'::jsonb,'APP-41')->>'bank' IS NULL AND pg_temp.pk_pay_of(:'pack_a'::jsonb,'APP-41')->>'reference' IS NULL,
  'payment day: older row dated by the India date of payment_date (2026-05-23; the one at 2026-06-01 India time is not in May); bank and reference for older rows, empty for app rows');
SELECT pg_temp.pk_assert(pg_temp.pk_pay_of(:'pack_a'::jsonb,'APP-44')->>'invoice_id' IS NULL AND pg_temp.pk_pay_of(:'pack_a'::jsonb,'APP-44')->>'customer_id' = :'cust_n'
  AND pg_temp.pk_pay_of(:'pack_a'::jsonb,'APP-44')->>'customer_name' = 'Pack Demo Traders' AND pg_temp.pk_pay_of(:'pack_a'::jsonb,'APP-46')->>'customer_id' IS NULL
  AND pg_temp.pk_pay_of(:'pack_a'::jsonb,'APP-46')->>'customer_name' = 'Walk-in Payer' AND (pg_temp.pk_pay_of(:'pack_a'::jsonb,'IMP-R1')->>'imported')='true'
  AND (pg_temp.pk_pay_of(:'pack_a'::jsonb,'APP-41')->>'imported')='false', 'payments that name no invoice, no customer id, and the imported mark');
SELECT pg_temp.pk_assert((SELECT array_agg(p->>'payment_no' ORDER BY ord) FROM jsonb_array_elements(:'pack_a'::jsonb#>'{data,payments}') WITH ORDINALITY x(p, ord)) = ARRAY['APP-41','APP-42','APP-43','OLD-7','APP-44','APP-45','APP-46','IMP-R1'],
  'payments in paid_on then payment_no order: '||(SELECT string_agg(p->>'payment_no', ',') FROM jsonb_array_elements(:'pack_a'::jsonb#>'{data,payments}') p));

-- [crit 6] stock: start + received - sent = end on every row; the exact lines of the fixture.
SELECT pg_temp.pk_assert((SELECT bool_and((s->>'start_bags')::int + (s->>'received_bags')::int - (s->>'sent_bags')::int = (s->>'end_bags')::int) FROM jsonb_array_elements(:'pack_a'::jsonb#>'{data,stock}') s)
  AND jsonb_array_length(:'pack_a'::jsonb#>'{data,stock}') = 4, '[crit 6] start + received - sent = end for all four lines');
SELECT pg_temp.pk_assert((SELECT (s->>'start_bags')::int = 100 AND (s->>'received_bags')::int = 0 AND (s->>'sent_bags')::int = 40 AND (s->>'end_bags')::int = 60
    AND s->>'customer_name' = 'Pack Demo Traders' AND s->>'item_name' = 'Pack Demo Jeera' AND s->>'packaging' = 'Bag' AND (s->>'kg_per_bag')::int = 50 AND s->>'grn_date' = '2026-04-10'
    FROM jsonb_array_elements(:'pack_a'::jsonb#>'{data,stock}') s WHERE s->>'gr_no' = 'PKG1')
  AND (SELECT (s->>'start_bags')::int = 0 AND (s->>'received_bags')::int = 40 AND (s->>'sent_bags')::int = 20 AND (s->>'end_bags')::int = 20 FROM jsonb_array_elements(:'pack_a'::jsonb#>'{data,stock}') s WHERE s->>'gr_no' = 'PKG2')
  AND (SELECT (s->>'start_bags')::int = 0 AND (s->>'received_bags')::int = 50 AND (s->>'sent_bags')::int = 18 AND (s->>'end_bags')::int = 32 FROM jsonb_array_elements(:'pack_a'::jsonb#>'{data,stock}') s WHERE s->>'gr_no' = 'PKG3')
  AND (SELECT (s->>'start_bags')::int = 0 AND (s->>'received_bags')::int = 12 AND (s->>'sent_bags')::int = 12 AND (s->>'end_bags')::int = 0 FROM jsonb_array_elements(:'pack_a'::jsonb#>'{data,stock}') s WHERE s->>'gr_no' = 'PKG4'),
  '[crit 6] PKG1 100/0/40/60 (20 bags left before May), PKG2 0/40/20/20, PKG3 0/50/18/32, PKG4 0/12/12/0');
SELECT pg_temp.pk_assert((SELECT array_agg(s->>'gr_no' ORDER BY ord) FROM jsonb_array_elements(:'pack_a'::jsonb#>'{data,stock}') WITH ORDINALITY x(s, ord)) = ARRAY['PKG2','PKG1','PKG3','PKG4'],
  'stock order: customer name, GRN date, GRN number: '||(SELECT string_agg(s->>'gr_no', ',') FROM jsonb_array_elements(:'pack_a'::jsonb#>'{data,stock}') s));
-- To = today: the end of every line equals the stock the app holds.
SELECT pg_temp.pk_pack(:'admin_claims'::jsonb, :'fy_start', :'today') AS pack_today \gset
SELECT pg_temp.pk_assert(:'pack_today'::jsonb->>'success'='true', '[crit 6] a period ending today: '||left(:'pack_today',300));
SELECT pg_temp.pk_assert((SELECT bool_and(COALESCE((SELECT sum((s->>'end_bags')::int) FROM jsonb_array_elements(:'pack_today'::jsonb#>'{data,stock}') s WHERE s->>'gr_no' = g.gr_no), 0) = t.stock)
    FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id = t.gr_id WHERE g.gr_no IN ('PKG1','PKG2','PKG3','PKG4')),
  '[crit 6] with To = today, the end of each GRN line equals goodsreceived_trl.stock');

-- ===== [crit 8] dated in A, cancelled in B: Y (SRT/20, dated 2026-05-15) is cancelled on 2026-06-10 =====
SELECT pg_temp.pk_as(:'admin_claims'::jsonb, format($q$SELECT public.cancel_invoice(%L::uuid,'Entered twice',NULL)$q$, :'inv_y')) AS cy \gset
SELECT pg_temp.pk_assert(:'cy'::jsonb->>'success'='true', 'Y cancelled: '||:'cy');
SET LOCAL session_replication_role = replica;
UPDATE public.invoice SET cancelled_at = '2026-06-10T11:00:00+05:30' WHERE id = :'inv_y'::uuid;
RESET session_replication_role;
SELECT pg_temp.pk_pack(:'admin_claims'::jsonb,'2026-06-01','2026-06-30') AS pack_b0 \gset
SELECT pg_temp.pk_assert(:'pack_b0'::jsonb->>'success'='true', '[crit 8] pack B (June) is made (a cancellation and a payment are in it): '||left(:'pack_b0',300));
SELECT pg_temp.pk_assert(pg_temp.pk_canc_of(:'pack_b0'::jsonb,'SRT/20')->>'reason' = 'cancelled_in_period' AND pg_temp.pk_canc_of(:'pack_b0'::jsonb,'SRT/20')->>'date' = '2026-05-15'
  AND pg_temp.pk_canc_of(:'pack_b0'::jsonb,'SRT/20')->>'cancelled_on' = '2026-06-10' AND pg_temp.pk_canc_of(:'pack_b0'::jsonb,'SRT/20')->>'id' IS NOT NULL,
  '[crit 8] B''s cancellations hold SRT/20 as cancelled_in_period');
SELECT pg_temp.pk_assert(pg_temp.pk_doc_of(:'pack_b0'::jsonb,'SRT/20') IS NULL AND pg_temp.pk_pay_of(:'pack_b0'::jsonb,'OLD-8')->>'paid_on' = '2026-06-01', '[crit 8] SRT/20 is not a register row of June; the older payment of 2026-06-01 (India) is');
SELECT pg_temp.pk_pack(:'admin_claims'::jsonb,'2026-05-01','2026-05-31') AS pack_a2 \gset
SELECT pg_temp.pk_assert(pg_temp.pk_doc_of(:'pack_a2'::jsonb,'SRT/20')->>'status'='cancelled' AND pg_temp.pk_doc_of(:'pack_a2'::jsonb,'SRT/20')->>'cancelled_on'='2026-06-10'
  AND pg_temp.pk_canc_of(:'pack_a2'::jsonb,'SRT/20')->>'reason'='in_period', '[crit 8] A made again lists SRT/20 as cancelled, with a cancellation (in_period)');
SELECT pg_temp.pk_assert(jsonb_array_length(:'pack_a2'::jsonb#>'{data,cancellations}') = 2, 'A made again: SRT/16 and SRT/20');

-- ===== [crit 14] pack A made; X (SRT/19, dated 2026-05-20) is cancelled after it; A again; B; B again; C =====
-- Every pack so far is moved to 2026-05-26 (before the cancel); X is cancelled on 2026-05-28.
SET LOCAL session_replication_role = replica;
UPDATE warehouse_security.accountant_packs SET made_at = '2026-05-26T10:00:00+05:30';
RESET session_replication_role;
SELECT pg_temp.pk_as(:'admin_claims'::jsonb, format($q$SELECT public.cancel_invoice(%L::uuid,'Entered twice',NULL)$q$, :'inv_x')) AS cx \gset
SELECT pg_temp.pk_assert(:'cx'::jsonb->>'success'='true', 'X cancelled: '||:'cx');
SET LOCAL session_replication_role = replica;
UPDATE public.invoice SET cancelled_at = '2026-05-28T11:00:00+05:30' WHERE id = :'inv_x'::uuid;
RESET session_replication_role;
SELECT pg_temp.pk_packs_count() AS before_a3 \gset
SELECT pg_temp.pk_pack(:'admin_claims'::jsonb,'2026-05-01','2026-05-31') AS pack_a3 \gset
SELECT pg_temp.pk_assert(pg_temp.pk_canc_of(:'pack_a3'::jsonb,'SRT/19')->>'reason' = 'in_period' AND pg_temp.pk_doc_of(:'pack_a3'::jsonb,'SRT/19')->>'status' = 'cancelled'
  AND pg_temp.pk_canc_of(:'pack_a3'::jsonb,'SRT/19')->>'cancelled_on' = '2026-05-28', '[crit 14] A made again carries the cancellation of SRT/19 (in_period)');
SELECT pg_temp.pk_assert(pg_temp.pk_packs_count() = :before_a3::bigint + 1, '[crit 14] one more record');
SELECT pg_temp.pk_pack(:'admin_claims'::jsonb,'2026-06-01','2026-06-30') AS pack_b1 \gset
SELECT pg_temp.pk_assert(pg_temp.pk_canc_of(:'pack_b1'::jsonb,'SRT/19')->>'reason' = 'exported' AND pg_temp.pk_canc_of(:'pack_b1'::jsonb,'SRT/19')->>'date' = '2026-05-20'
  AND pg_temp.pk_canc_of(:'pack_b1'::jsonb,'SRT/19')->>'cancelled_on' = '2026-05-28' AND pg_temp.pk_doc_of(:'pack_b1'::jsonb,'SRT/19') IS NULL,
  '[crit 14] pack B (the next period) carries SRT/19 as exported (a pack covering its date was made before the cancel)');
SELECT pg_temp.pk_assert(pg_temp.pk_canc_of(:'pack_b1'::jsonb,'SRT/20')->>'reason' = 'cancelled_in_period', 'SRT/20 stays cancelled_in_period in B');
SELECT pg_temp.pk_pack(:'admin_claims'::jsonb,'2026-06-01','2026-06-30') AS pack_b2 \gset
SELECT pg_temp.pk_assert(pg_temp.pk_canc_of(:'pack_b2'::jsonb,'SRT/19')->>'reason' = 'exported', '[crit 14] B made again still carries SRT/19 (its own earlier record is not a pack before its period)');
-- C: B made after the cancel carried SRT/19 already; and SRT/20.
SELECT pg_temp.pk_as(:'admin_claims'::jsonb, $q$SELECT public.record_payment((SELECT id FROM public.invoice WHERE inv_no = 12 AND inv_prefix = 'SRT/'), '2026-07-03'::date, 7, 'cash')$q$) AS pay_july \gset
SELECT pg_temp.pk_pack(:'admin_claims'::jsonb,'2026-07-01','2026-07-31') AS pack_c \gset
SELECT pg_temp.pk_assert(:'pack_c'::jsonb->>'success'='true', '[crit 14] pack C (July) is made (it has a payment): '||left(:'pack_c',300)||' / '||left(:'pay_july',300));
SELECT pg_temp.pk_assert(pg_temp.pk_canc_of(:'pack_c'::jsonb,'SRT/19') IS NULL AND pg_temp.pk_canc_of(:'pack_c'::jsonb,'SRT/20') IS NULL AND jsonb_array_length(:'pack_c'::jsonb#>'{data,cancellations}') = 0,
  '[crit 14] pack C does not carry SRT/19 or SRT/20: pack B, made after both cancels, carried them already');

-- [crit 14] the table cannot be changed, by the owner either (trigger); nothing but the function writes it.
SELECT pg_temp.pk_assert((SELECT count(*) FROM warehouse_security.accountant_packs WHERE period_from = '2026-06-01' AND period_to = '2026-06-30') = 3, 'B was recorded three times (B, B, B)');
DO $t$ BEGIN
  BEGIN UPDATE warehouse_security.accountant_packs SET made_at = now(); RAISE EXCEPTION 'update was allowed';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM = 'update was allowed' THEN RAISE; END IF; WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM warehouse_security.accountant_packs; RAISE EXCEPTION 'delete was allowed';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM = 'delete was allowed' THEN RAISE; END IF; WHEN OTHERS THEN NULL; END;
END $t$;

-- ===== Record payments off: payments is null =====
SELECT pg_temp.pk_as(:'admin_claims'::jsonb, $q$SELECT public.set_record_payments(false)$q$) AS pay_off \gset
SELECT pg_temp.pk_pack(:'admin_claims'::jsonb,'2026-05-01','2026-05-31') AS pack_off \gset
SELECT pg_temp.pk_assert(:'pack_off'::jsonb->>'success'='true' AND (:'pack_off'::jsonb#>>'{data,record_payments}')='false' AND jsonb_typeof(:'pack_off'::jsonb#>'{data,payments}')='null',
  'with Record payments off, payments is null: '||left(:'pay_off',200)||left(:'pack_off',200));

SELECT pg_temp.pk_assert(NOT has_function_privilege('anon','public.get_accountant_pack(date,date)','EXECUTE'), 'end');
ROLLBACK;
\echo 'Accountant pack: ledger names, packs read, cancellations carried, record of packs.'

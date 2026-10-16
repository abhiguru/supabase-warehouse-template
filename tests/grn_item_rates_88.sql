-- Migration 88 (2026-10-16): get_grn_item_rates, the rate each lot of a GRN is invoiced at, and its
-- guard (staff, and a customer account for the GRNs of a customer it owns).
-- Migration 89 (same day): a customer account gets the same figures with every rate that is not an
-- invoice figure as source 'customer' (its own rate) and no band edges (sections 4 and 5).
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.ir_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'grn item rates: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.ir_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.ir_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.ir_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
-- The jsonb answer of a statement run as the signed-in caller, or what it raised.
CREATE FUNCTION pg_temp.ir_as(claims jsonb, statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',claims::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN answer := jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  EXECUTE 'RESET ROLE';
  RETURN answer;
END $$;
-- The same as the anonymous role (no claims).
CREATE FUNCTION pg_temp.ir_anon(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims','',true);
  EXECUTE 'SET LOCAL ROLE anon';
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN answer := jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  EXECUTE 'RESET ROLE';
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.ir_item(p_name text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM public.items WHERE name=p_name $$;
CREATE FUNCTION pg_temp.ir_grn(p_gr_no text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM public.goodsreceived WHERE gr_no=p_gr_no $$;
CREATE FUNCTION pg_temp.ir_line(p_item text, p_qty integer, p_weight integer) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object('item_id',pg_temp.ir_item(p_item),'item_name',p_item,'packaging','Bag','qty',p_qty,'weight',p_weight,'rack','R1')) $$;
CREATE FUNCTION pg_temp.ir_save(claims jsonb, p_no text, p_day date, p_customer uuid, p_mode text, p_items jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.ir_as(claims, format($q$SELECT public.save_grn(p_gr_no=>%L,p_date=>%L::timestamptz,p_customer_id=>%L::uuid,
    p_customer_name=>'x',p_pricing_mode=>%L,p_items=>%L::jsonb)$q$, p_no, p_day::text||'T12:00:00Z', p_customer, p_mode, p_items)) $$;
-- The call under test, as a caller.
CREATE FUNCTION pg_temp.ir_get(claims jsonb, p_gr_no text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.ir_as(claims, format('SELECT public.get_grn_item_rates(%L::uuid)', pg_temp.ir_grn(p_gr_no))) $$;
-- One entry of the answer as text: "source unit/labour/tax min-max varies" (null parts as "null").
CREATE FUNCTION pg_temp.ir_row(answer jsonb, p_item text, p_weight integer) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(r->>'source','null')||' '||COALESCE(trim_scale((r->>'unit_price')::numeric)::text,'null')||'/'
         ||COALESCE(trim_scale((r->>'labour_rate')::numeric)::text,'null')||'/'||COALESCE(trim_scale((r->>'tax_percent')::numeric)::text,'null')
         ||' '||COALESCE(r->>'weight_min','null')||'-'||COALESCE(r->>'weight_max','null')||' '||(r->>'varies')
    FROM jsonb_array_elements(answer#>'{data,rates}') r WHERE r->>'item_name'=p_item AND (r->>'weight')::integer=p_weight $$;

INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9666666701','IR Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919666666702','IR Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919666666703','IR Staff','staff',true,'approved'),
 (gen_random_uuid(),'919666666704','IR Customer','customer',true,'approved'),
 (gen_random_uuid(),'919666666705','IR Other Customer','customer',true,'approved');
SELECT pg_temp.ir_login('9666666701') AS admin_claims \gset
SELECT pg_temp.ir_login('9666666702') AS supervisor_claims \gset
SELECT pg_temp.ir_login('9666666703') AS staff_claims \gset
SELECT pg_temp.ir_login('9666666704') AS customer_claims \gset
SELECT pg_temp.ir_login('9666666705') AS other_claims \gset
SELECT warehouse_security.business_date(now()) AS today \gset
SELECT (:'today'::date-100) AS d100, (:'today'::date-12) AS dm12, (:'today'::date-9) AS dm9, (:'today'::date-8) AS dm8,
       (:'today'::date-6) AS dm6 \gset

-- ---------------------------------------------------------------------------
-- 1. Fixtures
-- ---------------------------------------------------------------------------
SELECT pg_temp.ir_assert(pg_temp.ir_as(:'admin_claims'::jsonb,$q$SELECT public.create_customer('IR Orchard','9666666711')$q$)->>'success'='true','customer IR Orchard');
SELECT pg_temp.ir_assert(pg_temp.ir_as(:'admin_claims'::jsonb,$q$SELECT public.create_customer('IR Other','9666666712')$q$)->>'success'='true','customer IR Other');
SELECT id AS orchard FROM public.customers WHERE name='IR Orchard' \gset
SELECT id AS other FROM public.customers WHERE name='IR Other' \gset
SELECT pg_temp.ir_assert((SELECT public.assign_customer_to_user('919666666704',:'orchard'::uuid,'item rates fixture')),'customer login assigned to Orchard');
SELECT pg_temp.ir_assert((SELECT public.assign_customer_to_user('919666666705',:'other'::uuid,'item rates fixture')),'other login assigned to Other');
SELECT pg_temp.ir_assert(bool_and(pg_temp.ir_as(:'admin_claims'::jsonb,format($q$SELECT public.create_item(%L,'Bag')$q$,n))->>'success'='true'),'items')
 FROM unnest(ARRAY['IR Apple','IR Pear','IR Lime','IR Plum','IR Fig','IR Mango']) n;
-- Apple: default 4/1.5/5 and an Orchard rate 9/1/6 (both 0-50). Pear: default 3/1/5 (0-50). Lime: default
-- 3/1/5 for 0-10 and 4/2/5 for 11-50. Plum: no rate. Fig: default 4/1.5/5. Mango: one-time default 30/0/18.
INSERT INTO public.item_storage_prices(item_id,customer_id,price_type,unit_price,weight_min,weight_max,labour_rate,tax_percent,effective_from,effective_to,unit_price_one_time,unit_price_monthly) VALUES
 (pg_temp.ir_item('IR Apple'),NULL,'monthly',4,0,50,1.5,5,:'d100',NULL,0,4),
 (pg_temp.ir_item('IR Apple'),:'orchard'::uuid,'monthly',9,0,50,1,6,:'d100',NULL,0,9),
 (pg_temp.ir_item('IR Pear'),NULL,'monthly',3,0,50,1,5,:'d100',NULL,0,3),
 (pg_temp.ir_item('IR Lime'),NULL,'monthly',3,0,10,1,5,:'d100',NULL,0,3),
 (pg_temp.ir_item('IR Lime'),NULL,'monthly',4,11,50,2,5,:'d100',NULL,0,4),
 (pg_temp.ir_item('IR Fig'),NULL,'monthly',4,0,50,1.5,5,:'d100',NULL,0,4),
 (pg_temp.ir_item('IR Mango'),NULL,'one_time',30,0,50,0,18,:'d100',NULL,30,0);

-- GRN-A (Orchard, monthly): Pear 10 kg and Pear 30 kg (GRN-only rates, two bands that both hold 10:
-- the narrower wins), Apple (the customer's rate), Lime 8 kg and 30 kg (the item's two bands), Plum (no rate).
SELECT pg_temp.ir_save(:'staff_claims'::jsonb,'IR-A',:'dm12'::date,:'orchard'::uuid,'MONTHLY',
  jsonb_build_array(pg_temp.ir_line('IR Pear',3,10),pg_temp.ir_line('IR Pear',2,30),pg_temp.ir_line('IR Apple',3,10),
    pg_temp.ir_line('IR Lime',3,8),pg_temp.ir_line('IR Lime',3,30),pg_temp.ir_line('IR Plum',1,10))) AS save_a \gset
SELECT pg_temp.ir_assert(:'save_a'::jsonb->>'success'='true','fixture GRN-A: '||:'save_a');
INSERT INTO public.grn_rates(gr_id,item_id,price_type,weight_min,weight_max,unit_price,labour_rate,tax_percent) VALUES
 (pg_temp.ir_grn('IR-A'),pg_temp.ir_item('IR Pear'),'monthly',0,20,7,2,12),
 (pg_temp.ir_grn('IR-A'),pg_temp.ir_item('IR Pear'),'monthly',0,50,8,3,12),
 (pg_temp.ir_grn('IR-A'),pg_temp.ir_item('IR Apple'),'one_time',0,50,99,9,9);   -- wrong price type: never used by a monthly GRN
-- GRN-OT (Orchard, one-time) with Mango.
SELECT pg_temp.ir_save(:'staff_claims'::jsonb,'IR-OT',:'dm12'::date,:'orchard'::uuid,'ONE_TIME',jsonb_build_array(pg_temp.ir_line('IR Mango',2,10))) AS save_ot \gset
SELECT pg_temp.ir_assert(:'save_ot'::jsonb->>'success'='true','fixture GRN-OT: '||:'save_ot');
-- GRN-DEL: deleted.
SELECT pg_temp.ir_save(:'staff_claims'::jsonb,'IR-DEL',:'dm12'::date,:'orchard'::uuid,'MONTHLY',jsonb_build_array(pg_temp.ir_line('IR Fig',1,10))) AS save_del \gset
SELECT pg_temp.ir_assert(:'save_del'::jsonb->>'success'='true','fixture GRN-DEL: '||:'save_del');
UPDATE public.goodsreceived SET deleted_at=now() WHERE gr_no='IR-DEL';

-- ---------------------------------------------------------------------------
-- 2. The surface and the guard lists
-- ---------------------------------------------------------------------------
SELECT pg_temp.ir_assert(has_function_privilege('authenticated','public.get_grn_item_rates(uuid)','EXECUTE')
 AND has_function_privilege('service_role','public.get_grn_item_rates(uuid)','EXECUTE')
 AND NOT has_function_privilege('anon','public.get_grn_item_rates(uuid)','EXECUTE')
 AND (SELECT prosecdef AND proconfig::text LIKE '%search_path=pg_catalog, public%' FROM pg_proc WHERE oid='public.get_grn_item_rates(uuid)'::regprocedure),
 'get_grn_item_rates is security definer with a search_path and granted to authenticated and service_role only');
SELECT pg_temp.ir_assert((SELECT pg_get_functiondef(oid) LIKE '%ELSIF rpc IN (''get_grn_details'',''get_grn_item_dispatches'',''get_grn_item_rates'') THEN%'
   AND pg_get_functiondef(oid) LIKE '%''get_item_grn_rates'',%''get_grn_item_rates'',%'
  FROM pg_proc WHERE oid='warehouse_security.authorize_rpc(text,jsonb)'::regprocedure),'the guard names the new function in the staff list and the GRN branch');

-- ---------------------------------------------------------------------------
-- 3. The rates of GRN-A, as staff
-- ---------------------------------------------------------------------------
SELECT pg_temp.ir_get(:'staff_claims'::jsonb,'IR-A') AS ans_a \gset
SELECT pg_temp.ir_assert(:'ans_a'::jsonb->>'success'='true' AND :'ans_a'::jsonb#>>'{data,gr_id}'=pg_temp.ir_grn('IR-A')::text
 AND :'ans_a'::jsonb#>>'{data,grn_date}'=:'dm12' AND :'ans_a'::jsonb#>>'{data,price_type}'='monthly'
 AND :'ans_a'::jsonb#>>'{data,invoiced}'='false' AND jsonb_array_length(:'ans_a'::jsonb#>'{data,rates}')=6,'header of GRN-A: '||:'ans_a');
-- One entry per lot, in the order get_grn_details lists them (by lot id).
SELECT pg_temp.ir_assert((SELECT jsonb_agg(r->>'grn_item_id') FROM jsonb_array_elements(:'ans_a'::jsonb#>'{data,rates}') r)
  = (SELECT jsonb_agg(t.id ORDER BY t.id) FROM public.goodsreceived_trl t WHERE t.gr_id=pg_temp.ir_grn('IR-A')),'the entries follow the lot order of get_grn_details');
SELECT pg_temp.ir_assert((SELECT jsonb_agg(l->>'id') FROM jsonb_array_elements(public.get_grn_details(pg_temp.ir_grn('IR-A'))#>'{data,grn,items}') l)
  = (SELECT jsonb_agg(r->>'grn_item_id') FROM jsonb_array_elements(:'ans_a'::jsonb#>'{data,rates}') r),'the same order as the items of get_grn_details itself');
SELECT pg_temp.ir_assert(pg_temp.ir_row(:'ans_a'::jsonb,'IR Pear',10)='grn 7/2/12 0-20 false','Pear 10 kg: the narrower GRN band 0-20 wins: '||pg_temp.ir_row(:'ans_a'::jsonb,'IR Pear',10));
SELECT pg_temp.ir_assert(pg_temp.ir_row(:'ans_a'::jsonb,'IR Pear',30)='grn 8/3/12 0-50 false','Pear 30 kg: only the band 0-50 holds it: '||pg_temp.ir_row(:'ans_a'::jsonb,'IR Pear',30));
SELECT pg_temp.ir_assert(pg_temp.ir_row(:'ans_a'::jsonb,'IR Apple',10)='customer 9/1/6 0-50 false','Apple: the customer rate (the one-time GRN rate is ignored): '||pg_temp.ir_row(:'ans_a'::jsonb,'IR Apple',10));
SELECT pg_temp.ir_assert(pg_temp.ir_row(:'ans_a'::jsonb,'IR Lime',8)='item 3/1/5 0-10 false','Lime 8 kg: the item band 0-10: '||pg_temp.ir_row(:'ans_a'::jsonb,'IR Lime',8));
SELECT pg_temp.ir_assert(pg_temp.ir_row(:'ans_a'::jsonb,'IR Lime',30)='item 4/2/5 11-50 false','Lime 30 kg: the item band 11-50: '||pg_temp.ir_row(:'ans_a'::jsonb,'IR Lime',30));
SELECT pg_temp.ir_assert(pg_temp.ir_row(:'ans_a'::jsonb,'IR Plum',10)='null null/null/null null-null false','Plum: no rate at all: '||pg_temp.ir_row(:'ans_a'::jsonb,'IR Plum',10));
-- Cross-check against find_storage_price and grn_rates, lot by lot.
SELECT pg_temp.ir_assert((SELECT bool_and(
    CASE WHEN r->>'source' IN ('customer','item') THEN
      (r->>'unit_price')::numeric=f.unit_price AND (r->>'labour_rate')::numeric=f.labour_rate AND (r->>'tax_percent')::numeric=f.tax_percent
      AND (r->>'weight_min')::integer=f.weight_min AND (r->>'weight_max')::integer=f.weight_max
      AND (r->>'source'='customer')=(f.customer_id IS NOT NULL)
    WHEN r->>'source'='grn' THEN
      (r->>'unit_price')::numeric=g.unit_price AND (r->>'labour_rate')::numeric=g.labour_rate AND (r->>'tax_percent')::numeric=g.tax_percent
      AND (r->>'weight_min')::integer=g.weight_min AND (r->>'weight_max')::integer=g.weight_max
    ELSE f.id IS NULL AND g.unit_price IS NULL END)
  FROM jsonb_array_elements(:'ans_a'::jsonb#>'{data,rates}') r
  JOIN public.goodsreceived_trl t ON t.id=(r->>'grn_item_id')::uuid
  LEFT JOIN LATERAL public.find_storage_price(t.item_id,:'orchard'::uuid,t.weight,:'dm12'::date,'monthly') f ON true
  LEFT JOIN LATERAL (SELECT x.* FROM public.grn_rates x WHERE x.gr_id=t.gr_id AND x.item_id=t.item_id AND x.price_type='monthly'
      AND t.weight BETWEEN x.weight_min AND x.weight_max ORDER BY x.weight_max-x.weight_min, x.weight_min LIMIT 1) g ON true),'every figure equals find_storage_price or grn_rates for its lot');
SELECT pg_temp.ir_assert((SELECT bool_and(r->>'item_id'=t.item_id::text AND r->>'item_name'=t.item_name AND (r->>'weight')::integer=t.weight)
  FROM jsonb_array_elements(:'ans_a'::jsonb#>'{data,rates}') r JOIN public.goodsreceived_trl t ON t.id=(r->>'grn_item_id')::uuid),'item id, name and weight of each entry');
-- The one-time GRN uses the one-time price type.
SELECT pg_temp.ir_get(:'staff_claims'::jsonb,'IR-OT') AS ans_ot \gset
SELECT pg_temp.ir_assert(:'ans_ot'::jsonb#>>'{data,price_type}'='one_time' AND pg_temp.ir_row(:'ans_ot'::jsonb,'IR Mango',10)='item 30/0/18 0-50 false','one-time GRN: '||:'ans_ot');
-- Not a read of GRN-A's rates but of the GRN: get_grn_details still hides them from the customer.
SELECT pg_temp.ir_as(:'customer_claims'::jsonb,format('SELECT public.get_grn_details(%L::uuid)',pg_temp.ir_grn('IR-A'))) AS cust_details \gset
SELECT pg_temp.ir_assert(:'cust_details'::jsonb->>'success'='true' AND :'cust_details'::jsonb#>'{data,grn,rates}'='[]'::jsonb,'get_grn_details still answers grn.rates = [] to the customer');

-- ---------------------------------------------------------------------------
-- 4. An invoiced GRN
-- ---------------------------------------------------------------------------
-- IR-INV: Fig 10 kg, 10 bags, dispatched twice (dm8: 6 bags, dm9: 4 bags -- created in that order, so the
-- earlier date is the later row); Pear 10 kg, never dispatched. The invoice charges 6/1/5 for the dm8
-- line and 7/2/5 for the dm9 line: the first line by dispatch date is the dm9 one (7/2/5), and the lot varies.
SELECT pg_temp.ir_save(:'staff_claims'::jsonb,'IR-INV',:'dm12'::date,:'orchard'::uuid,'MONTHLY',
  jsonb_build_array(pg_temp.ir_line('IR Fig',10,10),pg_temp.ir_line('IR Pear',2,10))) AS save_inv \gset
SELECT pg_temp.ir_assert(:'save_inv'::jsonb->>'success'='true','fixture IR-INV: '||:'save_inv');
SELECT t.id AS fig_lot FROM public.goodsreceived_trl t WHERE t.gr_id=pg_temp.ir_grn('IR-INV') AND t.item_name='IR Fig' \gset
SELECT jsonb_build_object('customer_id',:'orchard','customer_name','IR Orchard','supervisor_id',:'admin_profile','supervisor_name','IR Administrator') AS dispatch_for \gset
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,format($q$SELECT public.create_dispatch_with_stock_check(%L::jsonb||%L::jsonb,ARRAY[%L::jsonb],0,'ir-d1')$q$,
  :'dispatch_for',jsonb_build_object('disp_no','IRD1','disp_date',:'dm8'),jsonb_build_object('gr_trl_id',:'fig_lot','disp_qty',6))) AS disp1 \gset
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,format($q$SELECT public.create_dispatch_with_stock_check(%L::jsonb||%L::jsonb,ARRAY[%L::jsonb],0,'ir-d2')$q$,
  :'dispatch_for',jsonb_build_object('disp_no','IRD2','disp_date',:'dm9'),jsonb_build_object('gr_trl_id',:'fig_lot','disp_qty',4))) AS disp2 \gset
SELECT pg_temp.ir_assert(:'disp1'::jsonb->>'success'='true' AND :'disp2'::jsonb->>'success'='true','fixture dispatches: '||:'disp1'||:'disp2');
-- Before the invoice: the item's rate, not invoiced.
SELECT pg_temp.ir_get(:'staff_claims'::jsonb,'IR-INV') AS inv_before \gset
SELECT pg_temp.ir_assert(:'inv_before'::jsonb#>>'{data,invoiced}'='false' AND pg_temp.ir_row(:'inv_before'::jsonb,'IR Fig',10)='item 4/1.5/5 0-50 false',
 'before the invoice the Fig lot shows the item rate: '||:'inv_before');
SELECT jsonb_agg(jsonb_build_object('disp_trl_id',r->>'disp_trl_id','grn_item_id',r->>'grn_item_id','duration',(r->>'duration')::numeric,
         'charge',CASE WHEN d.disp_no='IRD2' THEN 7 ELSE 6 END,'tax',5,'labour_rate',CASE WHEN d.disp_no='IRD2' THEN 2 ELSE 1 END)) AS inv_items
  FROM jsonb_array_elements(public.build_invoice_recalculation_rows(pg_temp.ir_grn('IR-INV'))->'rows') r
  JOIN public.dispatch_trl dt ON dt.id=(r->>'disp_trl_id')::uuid JOIN public.dispatch d ON d.id=dt.disp_id \gset
SELECT pg_temp.ir_as(:'admin_claims'::jsonb, format($q$SELECT public.save_invoice(%L::jsonb||jsonb_build_object('items',%L::jsonb))$q$,
  jsonb_build_object('inv_no',20269911,'inv_fin_year',2026,'customer_id',:'orchard'::uuid,'customer_name','IR Orchard',
    'inv_date',:'dm6'||'T12:00:00Z','total',0,'tax_amount',0,'labour',0,'discount',0,'duration_mode','legacy',
    'gr_id',pg_temp.ir_grn('IR-INV'),'gr_no','IR-INV'), :'inv_items')) AS inv_save \gset
SELECT pg_temp.ir_assert(:'inv_save'::jsonb->>'success'='true','fixture invoice: '||:'inv_save');
SELECT pg_temp.ir_get(:'staff_claims'::jsonb,'IR-INV') AS inv_after \gset
SELECT pg_temp.ir_assert(:'inv_after'::jsonb#>>'{data,invoiced}'='true' AND pg_temp.ir_row(:'inv_after'::jsonb,'IR Fig',10)='invoice 7/2/5 null-null true',
 'invoiced: the Fig lot shows the first invoice line by dispatch date and varies: '||pg_temp.ir_row(:'inv_after'::jsonb,'IR Fig',10));
SELECT pg_temp.ir_assert(pg_temp.ir_row(:'inv_after'::jsonb,'IR Pear',10)='item 3/1/5 0-50 false','the lot without invoice lines still shows the item rate: '||pg_temp.ir_row(:'inv_after'::jsonb,'IR Pear',10));
-- Both lines alike: not varying. (Equal figures on the second line.)
UPDATE public.invoice_trl SET charge=7, labour_rate=2, tax=5 WHERE invoice_id=(SELECT id FROM public.invoice WHERE gr_no='IR-INV');
SELECT pg_temp.ir_assert(pg_temp.ir_row(public.get_grn_item_rates(pg_temp.ir_grn('IR-INV')),'IR Fig',10)='invoice 7/2/5 null-null false','equal lines do not vary');
UPDATE public.invoice_trl SET charge=6, labour_rate=1 WHERE disp_trl_id IN (SELECT dt.id FROM public.dispatch_trl dt JOIN public.dispatch d ON d.id=dt.disp_id WHERE d.disp_no='IRD1');
SELECT pg_temp.ir_assert(pg_temp.ir_row(public.get_grn_item_rates(pg_temp.ir_grn('IR-INV')),'IR Fig',10)='invoice 7/2/5 null-null true','restored: varies again');
-- A cancelled invoice (cancel_invoice appends "[CANCELLED: ...]" to the notes) no longer counts.
UPDATE public.invoice SET notes=COALESCE(notes,'')||' [CANCELLED: test]' WHERE gr_no='IR-INV';
SELECT pg_temp.ir_assert(pg_temp.ir_row(public.get_grn_item_rates(pg_temp.ir_grn('IR-INV')),'IR Fig',10)='item 4/1.5/5 0-50 false','a cancelled invoice is skipped');
UPDATE public.invoice SET notes=replace(notes,' [CANCELLED: test]','') WHERE gr_no='IR-INV';
UPDATE public.invoice SET deleted_at=now() WHERE gr_no='IR-INV';
SELECT pg_temp.ir_assert(pg_temp.ir_row(public.get_grn_item_rates(pg_temp.ir_grn('IR-INV')),'IR Fig',10)='item 4/1.5/5 0-50 false','an invoice with deleted_at is skipped');
UPDATE public.invoice SET deleted_at=NULL WHERE gr_no='IR-INV';
SELECT pg_temp.ir_assert(pg_temp.ir_row(public.get_grn_item_rates(pg_temp.ir_grn('IR-INV')),'IR Fig',10)='invoice 7/2/5 null-null true','back to the invoice figure');
-- Migration 89: the customer keeps 'invoice' for an invoiced lot and sees the uninvoiced lot's default rate as its own.
SELECT pg_temp.ir_get(:'customer_claims'::jsonb,'IR-INV') AS inv_cust \gset
SELECT pg_temp.ir_assert(:'inv_cust'::jsonb#>>'{data,invoiced}'='true' AND pg_temp.ir_row(:'inv_cust'::jsonb,'IR Fig',10)='invoice 7/2/5 null-null true'
 AND pg_temp.ir_row(:'inv_cust'::jsonb,'IR Pear',10)='customer 3/1/5 null-null false','customer view of the invoiced GRN: '||:'inv_cust');

-- ---------------------------------------------------------------------------
-- 5. Access
-- ---------------------------------------------------------------------------
SELECT pg_temp.ir_assert(pg_temp.ir_get(:'admin_claims'::jsonb,'IR-A')->>'success'='true','administrator reads');
SELECT pg_temp.ir_assert(pg_temp.ir_get(:'supervisor_claims'::jsonb,'IR-A')->>'success'='true','supervisor reads');
SELECT pg_temp.ir_assert(pg_temp.ir_get(:'staff_claims'::jsonb,'IR-A')->>'success'='true','staff reads');
SELECT pg_temp.ir_get(:'customer_claims'::jsonb,'IR-A') AS own_a \gset
-- Migration 89: the GRN's own customer reads the same header, lots, order and figures as staff, but every
-- rate that is not an invoice figure is its own ('customer') and no entry carries band edges.
SELECT pg_temp.ir_assert(:'own_a'::jsonb->>'success'='true' AND :'own_a'::jsonb#>'{data,gr_id}'=:'ans_a'::jsonb#>'{data,gr_id}'
 AND :'own_a'::jsonb#>'{data,grn_date}'=:'ans_a'::jsonb#>'{data,grn_date}' AND :'own_a'::jsonb#>'{data,price_type}'=:'ans_a'::jsonb#>'{data,price_type}'
 AND :'own_a'::jsonb#>'{data,invoiced}'=:'ans_a'::jsonb#>'{data,invoiced}','the customer reads the same header as staff: '||:'own_a');
SELECT pg_temp.ir_assert(
  (SELECT jsonb_agg(r - 'source' - 'weight_min' - 'weight_max' ORDER BY n) FROM jsonb_array_elements(:'own_a'::jsonb#>'{data,rates}') WITH ORDINALITY e(r,n))
  = (SELECT jsonb_agg(r - 'source' - 'weight_min' - 'weight_max' ORDER BY n) FROM jsonb_array_elements(:'ans_a'::jsonb#>'{data,rates}') WITH ORDINALITY e(r,n)),
 'the customer reads the same lots, order, figures and varies as staff');
SELECT pg_temp.ir_assert(pg_temp.ir_row(:'own_a'::jsonb,'IR Pear',10)='customer 7/2/12 null-null false','customer view, Pear 10 kg: the GRN''s own rate as its own, no band: '||pg_temp.ir_row(:'own_a'::jsonb,'IR Pear',10));
SELECT pg_temp.ir_assert(pg_temp.ir_row(:'own_a'::jsonb,'IR Apple',10)='customer 9/1/6 null-null false','customer view, Apple: its customer rate, no band: '||pg_temp.ir_row(:'own_a'::jsonb,'IR Apple',10));
SELECT pg_temp.ir_assert(pg_temp.ir_row(:'own_a'::jsonb,'IR Lime',8)='customer 3/1/5 null-null false','customer view, Lime 8 kg: the default rate as its own, no band: '||pg_temp.ir_row(:'own_a'::jsonb,'IR Lime',8));
SELECT pg_temp.ir_assert(pg_temp.ir_row(:'own_a'::jsonb,'IR Lime',30)='customer 4/2/5 null-null false','customer view, Lime 30 kg: '||pg_temp.ir_row(:'own_a'::jsonb,'IR Lime',30));
SELECT pg_temp.ir_assert(pg_temp.ir_row(:'own_a'::jsonb,'IR Plum',10)='null null/null/null null-null false','customer view, Plum: still no rate: '||pg_temp.ir_row(:'own_a'::jsonb,'IR Plum',10));
SELECT pg_temp.ir_assert(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(:'own_a'::jsonb#>'{data,rates}') r
  WHERE r->>'source' IN ('item','grn') OR r->'weight_min'<>'null'::jsonb OR r->'weight_max'<>'null'::jsonb),
 'no entry of the customer''s answer names the default or GRN rate or carries a band: '||:'own_a');
-- Staff of every kind still get the source and the band.
SELECT pg_temp.ir_assert(pg_temp.ir_row(pg_temp.ir_get(:'admin_claims'::jsonb,'IR-A'),'IR Lime',8)='item 3/1/5 0-10 false'
 AND pg_temp.ir_row(pg_temp.ir_get(:'supervisor_claims'::jsonb,'IR-A'),'IR Pear',10)='grn 7/2/12 0-20 false'
 AND pg_temp.ir_row(pg_temp.ir_get(:'staff_claims'::jsonb,'IR-A'),'IR Lime',30)='item 4/2/5 11-50 false','staff views keep the source and the band');
SELECT pg_temp.ir_get(:'other_claims'::jsonb,'IR-A') AS other_a \gset
SELECT pg_temp.ir_assert(:'other_a'::jsonb->>'raised'='Customer access denied' AND :'other_a'::jsonb->>'state'='42501','another customer is refused: '||:'other_a');
SELECT pg_temp.ir_as(jsonb_build_object('role','authenticated','sub',gen_random_uuid()),format('SELECT public.get_grn_item_rates(%L::uuid)',pg_temp.ir_grn('IR-A'))) AS noprofile \gset
SELECT pg_temp.ir_assert(:'noprofile'::jsonb->>'state'='42501','a caller without a profile is refused: '||:'noprofile');
SELECT pg_temp.ir_anon(format('SELECT public.get_grn_item_rates(%L::uuid)',pg_temp.ir_grn('IR-A'))) AS anon_a \gset
SELECT pg_temp.ir_assert(:'anon_a'::jsonb->>'state'='42501','an anonymous caller is refused: '||:'anon_a');

-- ---------------------------------------------------------------------------
-- 6. Missing and deleted GRNs
-- ---------------------------------------------------------------------------
SELECT pg_temp.ir_get(:'admin_claims'::jsonb,'IR-DEL') AS del_admin \gset
SELECT pg_temp.ir_assert(:'del_admin'::jsonb='{"success":false,"error":"GRN not found","error_code":"GRN_NOT_FOUND","data":null}'::jsonb,'a deleted GRN: '||:'del_admin');
SELECT pg_temp.ir_get(:'customer_claims'::jsonb,'IR-DEL') AS del_cust \gset
SELECT pg_temp.ir_assert(:'del_cust'::jsonb->>'error_code'='GRN_NOT_FOUND','the owner of a deleted GRN gets GRN_NOT_FOUND: '||:'del_cust');
SELECT pg_temp.ir_as(:'staff_claims'::jsonb,format('SELECT public.get_grn_item_rates(%L::uuid)',gen_random_uuid())) AS unknown_staff \gset
SELECT pg_temp.ir_assert(:'unknown_staff'::jsonb->>'error_code'='GRN_NOT_FOUND' AND :'unknown_staff'::jsonb->>'success'='false' AND :'unknown_staff'::jsonb->'data'='null'::jsonb,'an unknown id: '||:'unknown_staff');
SELECT pg_temp.ir_as(:'customer_claims'::jsonb,format('SELECT public.get_grn_item_rates(%L::uuid)',gen_random_uuid())) AS unknown_cust \gset
SELECT pg_temp.ir_assert(:'unknown_cust'::jsonb->>'raised'='Customer access denied','a customer asking for an unknown id is refused by the guard: '||:'unknown_cust');

ROLLBACK;

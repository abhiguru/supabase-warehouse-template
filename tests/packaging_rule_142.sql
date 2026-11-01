-- Migration 142: the packaging rule of a stock item and of the GRN and dispatch preview rows (warehouse_security.shared_packaging). Fictional data; runs only in migrations.sh's disposable, network-disabled database; rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.pr_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'packaging 142: %',label; END IF; END $$;
-- The single jsonb answer of a call, or {"raised": message, "state": sqlstate}.
CREATE FUNCTION pg_temp.pr_call(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.pr_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.pr_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.pr_assert(l#>>'{data,action}'='login','login for '||phone);
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
SELECT warehouse_security.bootstrap_first_admin('9877778841','Packaging Rule Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919877778842','Packaging Rule Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919877778843','Packaging Rule Staff','staff',true,'approved'),
 (gen_random_uuid(),'919877778844','Packaging Rule Reader','customer',true,'approved'),
 (gen_random_uuid(),'919877778845','Packaging Rule Other Reader','customer',true,'approved');
SELECT id AS staff_profile FROM public.user_profiles WHERE mobile='919877778843' \gset
SELECT pg_temp.pr_login('9877778841') AS admin_claims \gset
SELECT pg_temp.pr_login('9877778842') AS supervisor_claims \gset
SELECT pg_temp.pr_login('9877778843') AS staff_claims \gset
SELECT pg_temp.pr_login('9877778844') AS customer_claims \gset
SELECT pg_temp.pr_login('9877778845') AS other_claims \gset

SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;

CREATE FUNCTION pg_temp.pr_item(rows jsonb, name text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT e FROM jsonb_array_elements(COALESCE(rows#>'{data,top_stock_items}', rows->'top_stock_items')) e WHERE e->>'item_name'=name $$;
CREATE FUNCTION pg_temp.pr_row(rows jsonb, list text, no text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT e FROM jsonb_array_elements(COALESCE(rows#>ARRAY['data',list], rows->list)) e WHERE e->>'gr_no'=no OR e->>'dispatch_no'=no $$;

-- The rule itself, case by case (a lot with NULL packaging is the default word Bag). The helper is internal: no app role may call it.
SELECT pg_temp.pr_assert(NOT has_function_privilege('authenticated','warehouse_security.shared_packaging(text[])','EXECUTE'),'the helper is not callable by app roles');
RESET ROLE;
SELECT pg_temp.pr_assert(warehouse_security.shared_packaging(ARRAY[NULL]::text[])='Bag','all NULL reads Bag');
SELECT pg_temp.pr_assert(warehouse_security.shared_packaging(ARRAY[NULL,NULL]::text[])='Bag','two NULL lots read Bag');
SELECT pg_temp.pr_assert(warehouse_security.shared_packaging(ARRAY['   ']::text[])='Bag','blank reads Bag');
SELECT pg_temp.pr_assert(warehouse_security.shared_packaging(ARRAY['Bag','bags ']::text[])='Bag','Bag and "bags " are one word');
SELECT pg_temp.pr_assert(warehouse_security.shared_packaging(ARRAY['Bag',NULL,'']::text[])='Bag','Bag, NULL and blank are one word');
SELECT pg_temp.pr_assert(warehouse_security.shared_packaging(ARRAY['Box',NULL]::text[]) IS NULL,'Box and NULL differ');
SELECT pg_temp.pr_assert(warehouse_security.shared_packaging(ARRAY['Box','Crate']::text[]) IS NULL,'Box and Crate differ');
SELECT pg_temp.pr_assert(warehouse_security.shared_packaging(ARRAY['Crate']::text[])='Crate','a single word');
SELECT pg_temp.pr_assert(warehouse_security.shared_packaging(ARRAY['boxes','BOX']::text[])='Box','boxes and BOX are one word');
SELECT pg_temp.pr_assert(warehouse_security.shared_packaging(ARRAY[' Carton','carton']::text[])='Bag','any word but box and crate is Bag, as the app reads it');
SELECT pg_temp.pr_assert(warehouse_security.shared_packaging(ARRAY['Unit','Unit']::text[])='Bag','all Unit reads Bag');
SELECT pg_temp.pr_assert(warehouse_security.shared_packaging(ARRAY['Bag','Unit']::text[])='Bag','Bag and Unit are one word');
SELECT pg_temp.pr_assert(warehouse_security.shared_packaging(ARRAY['Unit','Units']::text[])='Bag','Unit and Units are one word');
SELECT pg_temp.pr_assert(warehouse_security.shared_packaging(ARRAY['Unit',NULL]::text[])='Bag','Unit and NULL are one word');
SELECT pg_temp.pr_assert(warehouse_security.shared_packaging(ARRAY['Sack','Bag']::text[])='Bag','Sack and Bag are one word');
SELECT pg_temp.pr_assert(warehouse_security.shared_packaging(ARRAY['Carton','Box']::text[]) IS NULL,'Carton (Bag) and Box differ');
SELECT pg_temp.pr_assert(warehouse_security.shared_packaging(ARRAY[E'Box\t','Box',chr(160)||'box'||chr(160)]::text[])='Box','tabs and no-break spaces around a word are trimmed');
SELECT pg_temp.pr_assert(warehouse_security.shared_packaging(ARRAY[E'\t',E' \n']::text[])='Bag','a lot holding only white space reads Bag');
SELECT pg_temp.pr_assert(warehouse_security.shared_packaging(ARRAY[]::text[]) IS NULL,'no lots: null');
SET LOCAL ROLE authenticated;

SELECT pg_temp.pr_assert(public.create_customer('Packaging Rule Customer','9877788846')->>'success'='true','customer');
SELECT id AS cust FROM public.customers WHERE name='Packaging Rule Customer' \gset
SELECT pg_temp.pr_assert(public.create_item(n,'Bag')->>'success'='true','catalog item '||n)
  FROM unnest(ARRAY['Rule AllNull','Rule Blank','Rule BagPlural','Rule BoxNull','Rule BoxCrate']) n;
SELECT pg_temp.pr_assert(public.replace_item_rates(i.id,:'cust'::uuid,'monthly','2026-01-01'::date,jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',5,'labour_rate',2,'tax_percent',5)))->>'success'='true','rate '||i.name)
  FROM public.items i WHERE i.name LIKE 'Rule %';
SELECT id AS i_null FROM public.items WHERE name='Rule AllNull' \gset
SELECT id AS i_blank FROM public.items WHERE name='Rule Blank' \gset
SELECT id AS i_bag FROM public.items WHERE name='Rule BagPlural' \gset
SELECT id AS i_boxnull FROM public.items WHERE name='Rule BoxNull' \gset
SELECT id AS i_boxcrate FROM public.items WHERE name='Rule BoxCrate' \gset

CREATE FUNCTION pg_temp.pr_grn(no text, lots jsonb) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_temp.pr_assert(public.save_grn(p_gr_no=>no::varchar,p_date=>(('2026-04-'||CASE WHEN right(no,1) IN ('3','7') THEN '01' ELSE (10+right(no,1)::int)::text END||'T12:00:00Z')::timestamptz),p_customer_id=>(SELECT id FROM public.customers WHERE name='Packaging Rule Customer'),
    p_customer_name=>'Packaging Rule Customer',p_pricing_mode=>'ONE_TIME',p_idempotency_key=>'pr-'||no,p_items=>lots)->>'success'='true','receipt '||no);
END $$;
CREATE FUNCTION pg_temp.pr_lot(item_id uuid, name text, packaging text, rack text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object('item_id',item_id,'item_name',name,'packaging',packaging,'qty',10,'weight',10,'rack',rack)) $$;

SELECT pg_temp.pr_grn('PR1', jsonb_build_array(pg_temp.pr_lot(:'i_null','Rule AllNull',NULL,'R1')));
SELECT pg_temp.pr_grn('PR2', jsonb_build_array(pg_temp.pr_lot(:'i_blank','Rule Blank','  ','R2')));
SELECT pg_temp.pr_grn('PR3', jsonb_build_array(pg_temp.pr_lot(:'i_bag','Rule BagPlural','Bag','R3')));
SELECT pg_temp.pr_grn('PR4', jsonb_build_array(pg_temp.pr_lot(:'i_bag','Rule BagPlural','bags','R4')));
SELECT pg_temp.pr_grn('PR5', jsonb_build_array(pg_temp.pr_lot(:'i_boxnull','Rule BoxNull','Box','R5'),pg_temp.pr_lot(:'i_boxnull','Rule BoxNull',NULL,'R6')));
SELECT pg_temp.pr_grn('PR6', jsonb_build_array(pg_temp.pr_lot(:'i_boxcrate','Rule BoxCrate','Box','R7')));
SELECT pg_temp.pr_grn('PR7', jsonb_build_array(pg_temp.pr_lot(:'i_boxcrate','Rule BoxCrate','Crate','R8')));

SELECT public.get_customer_activity_detail(:'cust'::uuid,'2026-05-01'::date,'2026-05-31'::date) AS adet \gset
SELECT pg_temp.pr_assert(pg_temp.pr_item(:'adet'::jsonb,'Rule AllNull') ? 'packaging' AND pg_temp.pr_item(:'adet'::jsonb,'Rule AllNull')->>'packaging'='Bag','item with no packaging reads Bag: '||:'adet');
SELECT pg_temp.pr_assert(pg_temp.pr_item(:'adet'::jsonb,'Rule Blank')->>'packaging'='Bag','blank packaging reads Bag');
SELECT pg_temp.pr_assert(pg_temp.pr_item(:'adet'::jsonb,'Rule BagPlural')->>'packaging'='Bag','Bag and bags are one word');
SELECT pg_temp.pr_assert(pg_temp.pr_item(:'adet'::jsonb,'Rule BoxNull') ? 'packaging' AND pg_temp.pr_item(:'adet'::jsonb,'Rule BoxNull')->'packaging'='null'::jsonb,'Box and NULL lots: null (mixed)');
SELECT pg_temp.pr_assert(pg_temp.pr_item(:'adet'::jsonb,'Rule BoxCrate') ? 'packaging' AND pg_temp.pr_item(:'adet'::jsonb,'Rule BoxCrate')->'packaging'='null'::jsonb,'Box and Crate lots: null (mixed)');

-- recent_grns[].packaging (the five latest receipts are PR1, PR2, PR4, PR5, PR6): one word for a single-lot receipt, null for a receipt whose lots differ.
SELECT pg_temp.pr_assert(pg_temp.pr_row(:'adet'::jsonb,'recent_grns','PR1')->>'packaging'='Bag','GRN row with no packaging reads Bag: '||:'adet');
SELECT pg_temp.pr_assert(pg_temp.pr_row(:'adet'::jsonb,'recent_grns','PR2')->>'packaging'='Bag','GRN row with blank packaging reads Bag');
SELECT pg_temp.pr_assert(pg_temp.pr_row(:'adet'::jsonb,'recent_grns','PR4')->>'packaging'='Bag','GRN row with a lowercase plural bags lot reads Bag');
SELECT pg_temp.pr_assert(pg_temp.pr_row(:'adet'::jsonb,'recent_grns','PR6')->>'packaging'='Box','GRN row with one Box lot reads Box');
SELECT pg_temp.pr_assert(pg_temp.pr_row(:'adet'::jsonb,'recent_grns','PR5') ? 'packaging' AND pg_temp.pr_row(:'adet'::jsonb,'recent_grns','PR5')->'packaging'='null'::jsonb,'GRN row with Box and NULL lots: null');

-- recent_dispatches[].packaging: from the receipt lots the dispatch took from.
SELECT string_agg(t.id::text, ',' ORDER BY t.rack) AS pr5_lots FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='PR5' \gset
SELECT t.id AS pr3_lot FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='PR3' \gset
SELECT public.create_dispatch_with_stock_check(jsonb_build_object('customer_id',:'cust','customer_name','Packaging Rule Customer',
 'supervisor_id',:'admin_profile','supervisor_name','Packaging Rule Administrator','disp_date','2026-05-02','disp_no','PRD1'),
 (SELECT array_agg(jsonb_build_object('gr_trl_id',x,'disp_qty',1)) FROM unnest(string_to_array(:'pr5_lots',',')::uuid[]) x),0,'pr-dispatch-1') AS d1 \gset
SELECT pg_temp.pr_assert(:'d1'::jsonb->>'success'='true','dispatch PRD1: '||:'d1');
SELECT public.create_dispatch_with_stock_check(jsonb_build_object('customer_id',:'cust','customer_name','Packaging Rule Customer',
 'supervisor_id',:'admin_profile','supervisor_name','Packaging Rule Administrator','disp_date','2026-05-03','disp_no','PRD2'),
 ARRAY[jsonb_build_object('gr_trl_id',:'pr3_lot','disp_qty',1)],0,'pr-dispatch-2') AS d2 \gset
SELECT pg_temp.pr_assert(:'d2'::jsonb->>'success'='true','dispatch PRD2: '||:'d2');
SELECT public.get_customer_activity_detail(:'cust'::uuid,'2026-05-01'::date,'2026-05-31'::date) AS adet2 \gset
SELECT pg_temp.pr_assert(pg_temp.pr_row(:'adet2'::jsonb,'recent_dispatches','PRD2')->>'packaging'='Bag','dispatch row from a Bag lot reads Bag: '||:'adet2');
SELECT pg_temp.pr_assert(pg_temp.pr_row(:'adet2'::jsonb,'recent_dispatches','PRD1') ? 'packaging' AND pg_temp.pr_row(:'adet2'::jsonb,'recent_dispatches','PRD1')->'packaging'='null'::jsonb,'dispatch row from Box and NULL lots: null');

-- summary.current_stock_packaging: the rule over every lot with stock, beyond the five rows of top_stock_items.
CREATE FUNCTION pg_temp.pr_six(cname text, words text[]) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE cid uuid; i integer; iid uuid;
BEGIN
  PERFORM pg_temp.pr_assert(public.create_customer(cname, '98777'||lpad((abs(hashtext(cname))%100000)::text,5,'0'))->>'success'='true','customer '||cname);
  SELECT id INTO cid FROM public.customers WHERE name=cname;
  FOR i IN 1 .. array_length(words,1) LOOP
    SELECT id INTO iid FROM public.items WHERE name='Rule Six '||i;
    PERFORM pg_temp.pr_assert(public.replace_item_rates(iid,cid,'monthly','2026-01-01'::date,jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',5,'labour_rate',2,'tax_percent',5)))->>'success'='true','rate '||cname||i);
    -- Stock falls with the number, so the last item is the smallest and is outside the top five.
    PERFORM pg_temp.pr_grn_for(cname, cname||i, jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('item_id',iid,'item_name','Rule Six '||i,'packaging',words[i],'qty',100-i,'weight',10,'rack','S'||i))));
  END LOOP;
  RETURN public.get_customer_activity_detail(cid,'2026-05-01'::date,'2026-05-31'::date);
END $$;
CREATE FUNCTION pg_temp.pr_grn_for(cname text, no text, lots jsonb) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_temp.pr_assert(public.save_grn(p_gr_no=>('S'||substr(md5(no),1,10))::varchar,p_date=>'2026-04-01T12:00:00Z'::timestamptz,p_customer_id=>(SELECT id FROM public.customers WHERE name=cname),
    p_customer_name=>cname::varchar,p_pricing_mode=>'ONE_TIME',p_idempotency_key=>'pr6-'||no,p_items=>lots)->>'success'='true','receipt '||no);
END $$;
SELECT pg_temp.pr_assert(public.create_item('Rule Six '||n,'Bag')->>'success'='true','catalog item six '||n) FROM generate_series(1,6) n;
SELECT pg_temp.pr_six('Six Bags Customer', ARRAY['Bag',NULL,'bags','Unit','Sack','Bag']) AS six_bag \gset
SELECT pg_temp.pr_assert(jsonb_array_length(COALESCE(:'six_bag'::jsonb#>'{data,top_stock_items}',:'six_bag'::jsonb->'top_stock_items'))=5
  AND COALESCE(:'six_bag'::jsonb#>>'{data,summary,current_stock_packaging}',:'six_bag'::jsonb#>>'{summary,current_stock_packaging}')='Bag','six items in bags: Bag: '||:'six_bag');
SELECT pg_temp.pr_six('Six Boxes Customer', ARRAY['Box','box','Boxes','Box','BOX','Box ']) AS six_box \gset
SELECT pg_temp.pr_assert(COALESCE(:'six_box'::jsonb#>>'{data,summary,current_stock_packaging}',:'six_box'::jsonb#>>'{summary,current_stock_packaging}')='Box','six items in boxes: Box: '||:'six_box');
SELECT pg_temp.pr_six('Six Mixed Customer', ARRAY['Box','Box','Box','Box','Box','Crate']) AS six_mix \gset
SELECT pg_temp.pr_assert(COALESCE(:'six_mix'::jsonb#>'{data,summary}',:'six_mix'::jsonb->'summary') ? 'current_stock_packaging'
  AND COALESCE(:'six_mix'::jsonb#>'{data,summary,current_stock_packaging}',:'six_mix'::jsonb#>'{summary,current_stock_packaging}')='null'::jsonb
  AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(:'six_mix'::jsonb#>'{data,top_stock_items}',:'six_mix'::jsonb->'top_stock_items')) e WHERE e->>'packaging'='Crate'),
  'five Box and a sixth Crate outside the top five: null: '||:'six_mix');
SELECT pg_temp.pr_assert(public.create_customer('Zero Stock Customer','9877711111')->>'success'='true','zero-stock customer');
SELECT public.get_customer_activity_detail((SELECT id FROM public.customers WHERE name='Zero Stock Customer'),'2026-05-01'::date,'2026-05-31'::date) AS zero_stock \gset
SELECT pg_temp.pr_assert(COALESCE(:'zero_stock'::jsonb#>>'{data,summary,current_stock_packaging}',:'zero_stock'::jsonb#>>'{summary,current_stock_packaging}')='Bag','zero stock reads Bag: '||:'zero_stock');
ROLLBACK;

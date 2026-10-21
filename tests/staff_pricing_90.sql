-- Migration 90 (2026-10-16, owner decision): staff accounts lose item pricing. The guard refuses
-- them (SQLSTATE 42501, 'Staff access required') on get_item_storage_prices, replace_item_rates, undo_rate_change,
-- get_standard_rate and set_standard_rate (create/update/delete_item_storage_price, find_or_create_item_storage_price and
-- get_item_grn_rates were dropped by migration 123; their names stay in the list below that must not name them); save_grn
-- and update_grn answer RATES_MANAGER_ONLY to a staff call that carries p_rates (a list or []); get_grn_details
-- answers grn.rates = [] to staff. Staff keep get_grn_item_rates (the rate each lot is invoiced at) and the
-- invoice preview; administrators and supervisors keep everything.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.sp_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'staff pricing: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.sp_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.sp_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.sp_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
-- The jsonb answer of a statement run as the signed-in caller, or what it raised.
CREATE FUNCTION pg_temp.sp_as(claims jsonb, statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',claims::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN answer := jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  EXECUTE 'RESET ROLE';
  RETURN answer;
END $$;
-- True when the caller was turned away by the guard: raised, or answered by the function's own
-- error handler, with 'Staff access required' and no success.
CREATE FUNCTION pg_temp.sp_refused(answer jsonb) RETURNS boolean LANGUAGE sql AS $$
  SELECT COALESCE(answer->>'success','false')<>'true' AND answer::text LIKE '%Staff access required%'
     AND COALESCE(answer->>'state',answer->>'error_code','42501')='42501' $$;
CREATE FUNCTION pg_temp.sp_ok(answer jsonb) RETURNS boolean LANGUAGE sql AS $$ SELECT answer->>'success'='true' $$;
CREATE FUNCTION pg_temp.sp_item(p_name text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM public.items WHERE name=p_name $$;
CREATE FUNCTION pg_temp.sp_grn(p_gr_no text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM public.goodsreceived WHERE gr_no=p_gr_no $$;
CREATE FUNCTION pg_temp.sp_line(p_item text, p_qty integer, p_weight integer) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object('item_id',pg_temp.sp_item(p_item),'item_name',p_item,'packaging','Bag','qty',p_qty,'weight',p_weight,'rack','R1')) $$;
CREATE FUNCTION pg_temp.sp_rate(p_item text, p_rent numeric) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('scope','grn','item_id',pg_temp.sp_item(p_item),'weight_min',0,'weight_max',50,'unit_price',p_rent,'labour_rate',2,'tax_percent',5) $$;
-- save_grn with or without p_rates (SQL NULL leaves the parameter out).
CREATE FUNCTION pg_temp.sp_save(claims jsonb, p_no text, p_customer uuid, p_items jsonb, p_rates jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.sp_as(claims, format($q$SELECT public.save_grn(p_gr_no=>%L,p_date=>%L::timestamptz,p_customer_id=>%L::uuid,
    p_customer_name=>'x',p_pricing_mode=>'MONTHLY',p_items=>%L::jsonb%s)$q$, p_no, (current_date-12)::text||'T12:00:00Z', p_customer, p_items,
    CASE WHEN p_rates IS NULL THEN '' ELSE format(',p_rates=>%L::jsonb',p_rates) END)) $$;
CREATE FUNCTION pg_temp.sp_lines(p_gr_no text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_agg(jsonb_build_object('id',t.id,'item_id',t.item_id,'item_name',t.item_name,'packaging',t.packaging,'qty',t.qty,
           'weight',t.weight,'rack',t.rack,'package_mark',t.package_mark) ORDER BY t.id)
  FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no=p_gr_no $$;
-- update_grn with a note, and with or without p_rates.
CREATE FUNCTION pg_temp.sp_update(claims jsonb, p_no text, p_note text, p_rates jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.sp_as(claims, format($q$SELECT public.update_grn(p_grn_id=>%L::uuid,p_note=>%L,p_items=>%L::jsonb%s)$q$,
    pg_temp.sp_grn(p_no), p_note, pg_temp.sp_lines(p_no),
    CASE WHEN p_rates IS NULL THEN '' ELSE format(',p_rates=>%L::jsonb',p_rates) END)) $$;
CREATE FUNCTION pg_temp.sp_state() RETURNS text LANGUAGE sql AS $$
  SELECT (SELECT count(*) FROM public.item_storage_prices)||'/'||(SELECT count(*) FROM public.item_price_history)||'/'
      ||(SELECT count(*) FROM public.standard_rate_tiers)||'/'||(SELECT count(*) FROM public.grn_rates)||'/'||(SELECT count(*) FROM public.goodsreceived) $$;

INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9555555501','SP Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919555555502','SP Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919555555503','SP Staff','staff',true,'approved'),
 (gen_random_uuid(),'919555555504','SP Customer','customer',true,'approved');
SELECT pg_temp.sp_login('9555555501') AS admin_claims \gset
SELECT pg_temp.sp_login('9555555502') AS supervisor_claims \gset
SELECT pg_temp.sp_login('9555555503') AS staff_claims \gset
SELECT pg_temp.sp_login('9555555504') AS customer_claims \gset
SELECT warehouse_security.business_date(now()) AS today \gset
SELECT (:'today'::date+30) AS d30, (:'today'::date-100) AS d100, (:'today'::date-12) AS dm12 \gset

-- ---------------------------------------------------------------------------
-- 1. Fixtures
-- ---------------------------------------------------------------------------
SELECT pg_temp.sp_assert(pg_temp.sp_as(:'admin_claims'::jsonb,$q$SELECT public.create_customer('SP Orchard','9555555511')$q$)->>'success'='true','customer SP Orchard');
SELECT id AS orchard FROM public.customers WHERE name='SP Orchard' \gset
SELECT pg_temp.sp_assert((SELECT public.assign_customer_to_user('919555555504',:'orchard'::uuid,'staff pricing fixture')),'customer login assigned');
SELECT pg_temp.sp_assert(bool_and(pg_temp.sp_as(:'admin_claims'::jsonb,format($q$SELECT public.create_item(%L,'Bag')$q$,n))->>'success'='true'),'items')
 FROM unnest(ARRAY['SP Apple','SP Pear','SP Lime','SP Fig']) n;
-- Apple: default 4/1.5/5 (0-50). Fig: default 3/1/5 (0-50) and a one-day-old second row is not needed.
INSERT INTO public.item_storage_prices(item_id,customer_id,price_type,unit_price,weight_min,weight_max,labour_rate,tax_percent,effective_from,effective_to,unit_price_one_time,unit_price_monthly) VALUES
 (pg_temp.sp_item('SP Apple'),NULL,'monthly',4,0,50,1.5,5,:'d100',NULL,0,4),
 (pg_temp.sp_item('SP Fig'),NULL,'monthly',3,0,50,1,5,:'d100',NULL,0,3);

-- ---------------------------------------------------------------------------
-- 2. The guard text: the removed names are gone from the staff list, the kept ones are still there
-- ---------------------------------------------------------------------------
SELECT substring(pg_get_functiondef('warehouse_security.authorize_rpc(text,jsonb)'::regprocedure)
         from 'role_name = ''staff'' AND rpc IN \((.*?)\) THEN RETURN; END IF;') AS staff_list \gset
SELECT pg_temp.sp_assert(length(:'staff_list')>1000 AND :'staff_list' LIKE '%''save_grn''%','the staff list was found: '||length(:'staff_list'));
SELECT pg_temp.sp_assert(:'staff_list' NOT LIKE '%''' || n || '''%','the staff list no longer names '||n)
 FROM unnest(ARRAY['get_item_storage_prices','create_item_storage_price','update_item_storage_price','delete_item_storage_price',
   'find_or_create_item_storage_price','replace_item_rates','undo_rate_change','get_standard_rate','set_standard_rate','get_item_grn_rates']) n;
SELECT pg_temp.sp_assert(:'staff_list' LIKE '%''' || n || '''%','the staff list still names '||n)
 FROM unnest(ARRAY['get_grn_item_rates','generate_invoice_data_for_grn_with_pricing','save_grn','update_grn','get_grn_details','save_invoice']) n;

-- ---------------------------------------------------------------------------
-- 3. Staff are refused every pricing function; nothing is written
-- ---------------------------------------------------------------------------
SELECT pg_temp.sp_save(:'supervisor_claims'::jsonb,'SP-A',:'orchard'::uuid,jsonb_build_array(pg_temp.sp_line('SP Apple',3,10),pg_temp.sp_line('SP Pear',2,10)),
  jsonb_build_array(pg_temp.sp_rate('SP Pear',7))) AS save_a \gset
SELECT pg_temp.sp_assert(pg_temp.sp_ok(:'save_a'::jsonb),'fixture GRN SP-A by a supervisor, with a rate: '||:'save_a');
SELECT pg_temp.sp_state() AS state0 \gset
SELECT pg_temp.sp_as(:'staff_claims'::jsonb,'SELECT public.get_item_storage_prices()') AS s_list \gset
SELECT pg_temp.sp_as(:'staff_claims'::jsonb,format($q$SELECT public.replace_item_rates(%L::uuid,NULL,'monthly',%L::date,
  jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',7,'labour_rate',2,'tax_percent',5)),false,'change',NULL)$q$,pg_temp.sp_item('SP Lime'),:'d30')) AS s_replace \gset
SELECT pg_temp.sp_as(:'staff_claims'::jsonb,format($q$SELECT public.undo_rate_change(%L::uuid,NULL,'monthly',%L::date)$q$,pg_temp.sp_item('SP Lime'),:'d30')) AS s_undo \gset
SELECT pg_temp.sp_as(:'staff_claims'::jsonb,'SELECT public.get_standard_rate()') AS s_get_std \gset
SELECT pg_temp.sp_as(:'staff_claims'::jsonb,$q$SELECT public.set_standard_rate(jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',50,'unit_price',3,'labour_rate',1,'tax_percent',5)))$q$) AS s_set_std \gset
SELECT pg_temp.sp_assert(pg_temp.sp_refused(:'s_list'::jsonb),'get_item_storage_prices refused for staff: '||:'s_list');
SELECT pg_temp.sp_assert(pg_temp.sp_refused(:'s_replace'::jsonb) AND :'s_replace'::jsonb->>'state'='42501','replace_item_rates refused for staff with 42501: '||:'s_replace');
SELECT pg_temp.sp_assert(pg_temp.sp_refused(:'s_undo'::jsonb) AND :'s_undo'::jsonb->>'state'='42501','undo_rate_change refused for staff with 42501: '||:'s_undo');
SELECT pg_temp.sp_assert(pg_temp.sp_refused(:'s_get_std'::jsonb) AND :'s_get_std'::jsonb->>'state'='42501','get_standard_rate refused for staff with 42501: '||:'s_get_std');
SELECT pg_temp.sp_assert(pg_temp.sp_refused(:'s_set_std'::jsonb) AND :'s_set_std'::jsonb->>'state'='42501','set_standard_rate refused for staff with 42501 (not STANDARD_RATE_MANAGER_ONLY): '||:'s_set_std');
SELECT pg_temp.sp_assert(pg_temp.sp_state()=:'state0','the refused staff calls changed nothing (prices/history/tiers/grn rates/GRNs '||:'state0'||' -> '||pg_temp.sp_state()||')');
-- A customer account is refused the same functions (unchanged since migration 76/85/86).
SELECT pg_temp.sp_as(:'customer_claims'::jsonb,'SELECT public.get_item_storage_prices()') AS c_list \gset
SELECT pg_temp.sp_assert(COALESCE(:'c_list'::jsonb->>'success','false')<>'true' AND :'c_list'::text LIKE '%42501%','a customer account is still refused: '||:'c_list');

-- ---------------------------------------------------------------------------
-- 4. Administrators and supervisors keep all of it
-- ---------------------------------------------------------------------------
SELECT pg_temp.sp_assert(pg_temp.sp_ok(pg_temp.sp_as(c,'SELECT public.get_item_storage_prices()')),'get_item_storage_prices for '||n)
 FROM (VALUES ('administrator',:'admin_claims'::jsonb),('supervisor',:'supervisor_claims'::jsonb)) v(n,c);
SELECT pg_temp.sp_as(:'supervisor_claims'::jsonb,format($q$SELECT public.replace_item_rates(%L::uuid,NULL,'monthly',%L::date,
  jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',7,'labour_rate',2,'tax_percent',5)),false,'change',NULL)$q$,pg_temp.sp_item('SP Lime'),:'d30')) AS m_replace \gset
SELECT pg_temp.sp_assert(pg_temp.sp_ok(:'m_replace'::jsonb) AND (SELECT count(*)=1 FROM public.item_storage_prices WHERE item_id=pg_temp.sp_item('SP Lime')),'a supervisor changes a rate from a date: '||:'m_replace');
SELECT pg_temp.sp_as(:'admin_claims'::jsonb,format($q$SELECT public.undo_rate_change(%L::uuid,NULL,'monthly',%L::date)$q$,pg_temp.sp_item('SP Lime'),:'d30')) AS m_undo \gset
SELECT pg_temp.sp_assert(pg_temp.sp_ok(:'m_undo'::jsonb) AND (SELECT count(*)=0 FROM public.item_storage_prices WHERE item_id=pg_temp.sp_item('SP Lime')),'an administrator undoes it: '||:'m_undo');
SELECT pg_temp.sp_as(:'supervisor_claims'::jsonb,$q$SELECT public.set_standard_rate(jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',50,'unit_price',3,'labour_rate',1,'tax_percent',5)))$q$) AS m_set_std \gset
SELECT pg_temp.sp_assert(pg_temp.sp_ok(:'m_set_std'::jsonb) AND (SELECT count(*)=1 FROM public.standard_rate_tiers),'a supervisor sets the standard rate: '||:'m_set_std');
SELECT pg_temp.sp_as(:'admin_claims'::jsonb,'SELECT public.get_standard_rate()') AS m_get_std \gset
SELECT pg_temp.sp_assert(pg_temp.sp_ok(:'m_get_std'::jsonb) AND jsonb_array_length(:'m_get_std'::jsonb#>'{data,tiers}')=1,'an administrator reads it: '||:'m_get_std');
SELECT pg_temp.sp_assert(pg_temp.sp_ok(pg_temp.sp_as(:'admin_claims'::jsonb,$q$SELECT public.set_standard_rate(jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',60,'unit_price',3,'labour_rate',1,'tax_percent',5)))$q$)),'an administrator sets it');
-- Staff are still refused once there is a standard rate, and read nothing of it.
SELECT pg_temp.sp_assert(pg_temp.sp_refused(pg_temp.sp_as(:'staff_claims'::jsonb,'SELECT public.get_standard_rate()')),'staff still refused get_standard_rate with a rate in place');

-- ---------------------------------------------------------------------------
-- 5. Direct reads: no app role reads the rate tables (migration 123); they are read through the pricing RPCs
-- ---------------------------------------------------------------------------
SELECT pg_temp.sp_assert((SELECT bool_and(pg_temp.sp_as(c.claims,format('SELECT to_jsonb(count(*)) FROM public.%I',t.tbl))->>'state'='42501')
   FROM (VALUES ('item_storage_prices'),('grn_rates'),('standard_rate_tiers')) t(tbl),
        (VALUES (:'admin_claims'::jsonb),(:'staff_claims'::jsonb)) c(claims)),
 'direct reads of the rate tables are refused for the administrator and for staff');
SELECT pg_temp.sp_assert((SELECT count(*)>0 FROM public.item_storage_prices) AND (SELECT count(*)>0 FROM public.grn_rates) AND (SELECT count(*)>0 FROM public.standard_rate_tiers),
 'the rate tables hold rows (so a refusal is not an empty table)');


-- ---------------------------------------------------------------------------
-- 6. save_grn and update_grn: p_rates is a manager's input
-- ---------------------------------------------------------------------------
SELECT pg_temp.sp_state() AS state1 \gset
SELECT pg_temp.sp_save(:'staff_claims'::jsonb,'SP-S1',:'orchard'::uuid,jsonb_build_array(pg_temp.sp_line('SP Pear',3,10)),jsonb_build_array(pg_temp.sp_rate('SP Pear',6))) AS st_save_rates \gset
SELECT pg_temp.sp_save(:'staff_claims'::jsonb,'SP-S2',:'orchard'::uuid,jsonb_build_array(pg_temp.sp_line('SP Apple',3,10)),'[]'::jsonb) AS st_save_empty \gset
SELECT pg_temp.sp_assert(:'st_save_rates'::jsonb->>'success'='false' AND :'st_save_rates'::jsonb->>'error_code'='RATES_MANAGER_ONLY'
 AND :'st_save_rates'::jsonb->>'error'='Only administrators and supervisors can set rates on a GRN','staff save_grn with a rate list: '||:'st_save_rates');
SELECT pg_temp.sp_assert(:'st_save_empty'::jsonb->>'success'='false' AND :'st_save_empty'::jsonb->>'error_code'='RATES_MANAGER_ONLY','staff save_grn with []: '||:'st_save_empty');
SELECT pg_temp.sp_assert(NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no IN ('SP-S1','SP-S2')) AND pg_temp.sp_state()=:'state1',
 'neither refused save wrote a GRN or a rate: '||:'state1'||' -> '||pg_temp.sp_state());
SELECT pg_temp.sp_update(:'staff_claims'::jsonb,'SP-A','staff must not stay',jsonb_build_array(pg_temp.sp_rate('SP Pear',9))) AS st_upd_rates \gset
SELECT pg_temp.sp_update(:'staff_claims'::jsonb,'SP-A','staff must not stay','[]'::jsonb) AS st_upd_empty \gset
SELECT pg_temp.sp_assert(:'st_upd_rates'::jsonb->>'success'='false' AND :'st_upd_rates'::jsonb->>'error_code'='RATES_MANAGER_ONLY'
 AND :'st_upd_empty'::jsonb->>'success'='false' AND :'st_upd_empty'::jsonb->>'error_code'='RATES_MANAGER_ONLY','staff update_grn with a rate list and with []: '||:'st_upd_rates'||:'st_upd_empty');
SELECT pg_temp.sp_assert((SELECT note IS DISTINCT FROM 'staff must not stay' FROM public.goodsreceived WHERE gr_no='SP-A')
 AND (SELECT count(*)=1 AND bool_and(unit_price=7) FROM public.grn_rates WHERE gr_id=pg_temp.sp_grn('SP-A')) AND pg_temp.sp_state()=:'state1','the refused updates left SP-A and its rate as they were');
-- The same calls without p_rates succeed for staff.
SELECT pg_temp.sp_save(:'staff_claims'::jsonb,'SP-S3',:'orchard'::uuid,jsonb_build_array(pg_temp.sp_line('SP Apple',3,10),pg_temp.sp_line('SP Fig',1,10)),NULL) AS st_save_plain \gset
SELECT pg_temp.sp_assert(pg_temp.sp_ok(:'st_save_plain'::jsonb) AND EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no='SP-S3'),'staff save_grn without p_rates: '||:'st_save_plain');
SELECT pg_temp.sp_update(:'staff_claims'::jsonb,'SP-S3','plain note',NULL) AS st_upd_plain \gset
SELECT pg_temp.sp_assert(pg_temp.sp_ok(:'st_upd_plain'::jsonb) AND (SELECT note='plain note' FROM public.goodsreceived WHERE gr_no='SP-S3'),'staff update_grn without p_rates: '||:'st_upd_plain');
-- A supervisor and an administrator send p_rates, on save and on update.
SELECT pg_temp.sp_save(:'supervisor_claims'::jsonb,'SP-M1',:'orchard'::uuid,jsonb_build_array(pg_temp.sp_line('SP Pear',3,10)),jsonb_build_array(pg_temp.sp_rate('SP Pear',6))) AS sup_save \gset
SELECT pg_temp.sp_save(:'admin_claims'::jsonb,'SP-M2',:'orchard'::uuid,jsonb_build_array(pg_temp.sp_line('SP Pear',3,10)),jsonb_build_array(pg_temp.sp_rate('SP Pear',6))) AS adm_save \gset
SELECT pg_temp.sp_update(:'supervisor_claims'::jsonb,'SP-M1','sup note',jsonb_build_array(pg_temp.sp_rate('SP Pear',8))) AS sup_upd \gset
SELECT pg_temp.sp_update(:'admin_claims'::jsonb,'SP-M2','adm note',jsonb_build_array(pg_temp.sp_rate('SP Pear',8))) AS adm_upd \gset
SELECT pg_temp.sp_assert(pg_temp.sp_ok(:'sup_save'::jsonb) AND pg_temp.sp_ok(:'adm_save'::jsonb) AND pg_temp.sp_ok(:'sup_upd'::jsonb) AND pg_temp.sp_ok(:'adm_upd'::jsonb)
 AND (SELECT count(*)=2 AND bool_and(unit_price=8) FROM public.grn_rates WHERE gr_id IN (pg_temp.sp_grn('SP-M1'),pg_temp.sp_grn('SP-M2'))),
 'supervisor and administrator save and update with p_rates: '||:'sup_save'||:'adm_save'||:'sup_upd'||:'adm_upd');

-- ---------------------------------------------------------------------------
-- 7. What staff still read: get_grn_details without rates, get_grn_item_rates with them
-- ---------------------------------------------------------------------------
SELECT pg_temp.sp_as(:'staff_claims'::jsonb,format('SELECT public.get_grn_details(%L::uuid)',pg_temp.sp_grn('SP-A'))) AS det_staff \gset
SELECT pg_temp.sp_as(:'supervisor_claims'::jsonb,format('SELECT public.get_grn_details(%L::uuid)',pg_temp.sp_grn('SP-A'))) AS det_sup \gset
SELECT pg_temp.sp_as(:'admin_claims'::jsonb,format('SELECT public.get_grn_details(%L::uuid)',pg_temp.sp_grn('SP-A'))) AS det_adm \gset
SELECT pg_temp.sp_assert(pg_temp.sp_ok(:'det_staff'::jsonb) AND :'det_staff'::jsonb#>'{data,grn,rates}'='[]'::jsonb
 AND jsonb_array_length(:'det_staff'::jsonb#>'{data,grn,items}')=2 AND :'det_staff'::jsonb#>>'{data,grn,gr_no}'='SP-A',
 'staff read the GRN with rates []: '||:'det_staff');
SELECT pg_temp.sp_assert(jsonb_array_length(:'det_sup'::jsonb#>'{data,grn,rates}')=1 AND (:'det_sup'::jsonb#>>'{data,grn,rates,0,unit_price}')::numeric=7
 AND jsonb_array_length(:'det_adm'::jsonb#>'{data,grn,rates}')=1,'a supervisor and an administrator read the stored rate: '||(:'det_sup'::jsonb#>>'{data,grn,rates}'));
SELECT pg_temp.sp_as(:'staff_claims'::jsonb,format('SELECT public.get_grn_item_rates(%L::uuid)',pg_temp.sp_grn('SP-A'))) AS rates_staff \gset
SELECT pg_temp.sp_assert(pg_temp.sp_ok(:'rates_staff'::jsonb) AND jsonb_array_length(:'rates_staff'::jsonb#>'{data,rates}')=2
 AND (SELECT r->>'source'='grn' AND (r->>'unit_price')::numeric=7 AND (r->>'weight_min')::int=0 AND (r->>'weight_max')::int=50
      FROM jsonb_array_elements(:'rates_staff'::jsonb#>'{data,rates}') r WHERE r->>'item_name'='SP Pear')
 AND (SELECT r->>'source'='item' AND (r->>'unit_price')::numeric=4 AND (r->>'weight_min')::int=0 AND (r->>'weight_max')::int=50
      FROM jsonb_array_elements(:'rates_staff'::jsonb#>'{data,rates}') r WHERE r->>'item_name'='SP Apple'),
 'staff still read the rate of each lot with its source and band: '||:'rates_staff');
SELECT pg_temp.sp_as(:'customer_claims'::jsonb,format('SELECT public.get_grn_item_rates(%L::uuid)',pg_temp.sp_grn('SP-A'))) AS rates_cust \gset
SELECT pg_temp.sp_assert((SELECT bool_and(r->>'source'='customer' AND r->'weight_min'='null'::jsonb) FROM jsonb_array_elements(:'rates_cust'::jsonb#>'{data,rates}') r),'the customer view of migration 89 is unchanged: '||:'rates_cust');

-- ---------------------------------------------------------------------------
-- 8. Staff still invoice: the preview of a fully dispatched GRN
-- ---------------------------------------------------------------------------
SELECT t.id AS apple_lot FROM public.goodsreceived_trl t WHERE t.gr_id=pg_temp.sp_grn('SP-A') AND t.item_name='SP Apple' \gset
SELECT jsonb_build_object('customer_id',:'orchard','customer_name','SP Orchard','supervisor_id',:'admin_profile','supervisor_name','SP Administrator') AS dispatch_for \gset
SELECT pg_temp.sp_as(:'admin_claims'::jsonb,format($q$SELECT public.create_dispatch_with_stock_check(%L::jsonb||%L::jsonb,ARRAY[%L::jsonb],0,'sp-d1')$q$,
  :'dispatch_for',jsonb_build_object('disp_no','SPD1','disp_date',:'dm12'),jsonb_build_object('gr_trl_id',:'apple_lot','disp_qty',3))) AS disp1 \gset
SELECT t.id AS pear_lot FROM public.goodsreceived_trl t WHERE t.gr_id=pg_temp.sp_grn('SP-A') AND t.item_name='SP Pear' \gset
SELECT pg_temp.sp_as(:'admin_claims'::jsonb,format($q$SELECT public.create_dispatch_with_stock_check(%L::jsonb||%L::jsonb,ARRAY[%L::jsonb],0,'sp-d2')$q$,
  :'dispatch_for',jsonb_build_object('disp_no','SPD2','disp_date',:'dm12'),jsonb_build_object('gr_trl_id',:'pear_lot','disp_qty',2))) AS disp2 \gset
SELECT pg_temp.sp_assert(pg_temp.sp_ok(:'disp1'::jsonb) AND pg_temp.sp_ok(:'disp2'::jsonb),'fixture dispatches: '||:'disp1'||:'disp2');
SELECT pg_temp.sp_as(:'staff_claims'::jsonb,format($q$SELECT public.generate_invoice_data_for_grn_with_pricing(p_gr_id=>%L::uuid,p_duration_mode=>'legacy')$q$,pg_temp.sp_grn('SP-A'))) AS preview_staff \gset
SELECT pg_temp.sp_as(:'supervisor_claims'::jsonb,format($q$SELECT public.generate_invoice_data_for_grn_with_pricing(p_gr_id=>%L::uuid,p_duration_mode=>'legacy')$q$,pg_temp.sp_grn('SP-A'))) AS preview_sup \gset
SELECT pg_temp.sp_assert(pg_temp.sp_ok(:'preview_staff'::jsonb) AND :'preview_staff'::jsonb=:'preview_sup'::jsonb,'staff still get the invoice preview, the same as a supervisor: '||:'preview_staff');

ROLLBACK;

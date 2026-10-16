-- Migration 76 (2026-10-14): replace_item_rates, the overlap check and one-day rates in
-- create/update_item_storage_price, the staff rule for rates in force, labour 0 for one-time
-- rates, search_customers by any word, and the id tie-breaker of get_item_storage_prices.
-- Migration 90 (2026-10-16): staff are refused all of it by the guard; the staff blocks below assert the
-- refusal and run the same change as a supervisor.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.rc_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'item rate changes: %',label; END IF; END $$;
-- The jsonb answer of a call, or what it raised.
CREATE FUNCTION pg_temp.rc_call(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.rc_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.rc_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.rc_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
-- The rows of a scope as text, oldest start first: "0-100@6.00/2.50/5 2026-01-01..open".
CREATE FUNCTION pg_temp.rc_rows(p_item uuid, p_customer uuid, p_type text) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(string_agg(r.weight_min||'-'||r.weight_max||'@'||r.unit_price||'/'||r.labour_rate||'/'||trim_scale(r.tax_percent)
           ||' '||r.effective_from||'..'||COALESCE(r.effective_to::text,'open'), ' | ' ORDER BY r.effective_from, r.weight_min),'(none)')
  FROM public.item_storage_prices r
  WHERE r.item_id=p_item AND r.customer_id IS NOT DISTINCT FROM p_customer AND r.price_type=p_type $$;
-- The rent find_storage_price returns for a weight on a day, or 'none'.
CREATE FUNCTION pg_temp.rc_rent(p_item uuid, p_customer uuid, p_weight integer, p_day date, p_type text DEFAULT 'monthly') RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE((SELECT f.unit_price::text FROM public.find_storage_price(p_item,p_customer,p_weight,p_day,p_type) f WHERE f.id IS NOT NULL),'none') $$;
-- A band list as jsonb text.
CREATE FUNCTION pg_temp.rc_band(wmin int, wmax int, rent numeric, labour numeric DEFAULT 2.5, tax numeric DEFAULT 5) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('weight_min',wmin,'weight_max',wmax,'unit_price',rent,'labour_rate',labour,'tax_percent',tax) $$;
CREATE FUNCTION pg_temp.rc_replace(p_item uuid, p_customer uuid, p_type text, p_day date, p_bands jsonb, p_later boolean DEFAULT false,
  p_mode text DEFAULT 'change', p_move_from date DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.rc_call(format('SELECT public.replace_item_rates(%L,%L,%L,%L,%L::jsonb,%L,%L,%L)',p_item,p_customer,p_type,p_day,p_bands,p_later,p_mode,p_move_from)) $$;
-- A row written directly (set-up only).
CREATE FUNCTION pg_temp.rc_row(p_item uuid, p_customer uuid, p_wmin int, p_wmax int, p_rent numeric, p_from date, p_to date) RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.item_storage_prices(item_id,customer_id,price_type,unit_price,weight_min,weight_max,labour_rate,tax_percent,effective_from,effective_to,unit_price_one_time,unit_price_monthly)
  VALUES (p_item,p_customer,'monthly',p_rent,p_wmin,p_wmax,2.5,5,p_from,p_to,0,p_rent) $$;
CREATE FUNCTION pg_temp.rc_hist() RETURNS integer LANGUAGE sql AS $$ SELECT count(*)::int FROM public.item_price_history $$;

INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9777777701','Rate Changes Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919777777702','Rate Changes Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919777777703','Rate Changes Staff','staff',true,'approved'),
 (gen_random_uuid(),'919777777704','Rate Changes Customer','customer',true,'approved');
SELECT id AS supervisor_profile FROM public.user_profiles WHERE mobile='919777777702' \gset
SELECT id AS staff_profile FROM public.user_profiles WHERE mobile='919777777703' \gset
SELECT pg_temp.rc_login('9777777701') AS admin_claims \gset
SELECT pg_temp.rc_login('9777777702') AS supervisor_claims \gset
SELECT pg_temp.rc_login('9777777703') AS staff_claims \gset
SELECT pg_temp.rc_login('9777777704') AS customer_claims \gset

SELECT warehouse_security.business_date(now()) AS today, warehouse_security.business_date(now())+30 AS d30, warehouse_security.business_date(now())+120 AS d120, warehouse_security.business_date(now())+29 AS d29,
       warehouse_security.business_date(now())-1 AS yesterday, warehouse_security.business_date(now())-200 AS old_start, warehouse_security.business_date(now())-201 AS old_end,
       warehouse_security.business_date(now())-1100 AS dpast, warehouse_security.business_date(now())+731 AS dfar \gset

SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_assert(public.create_customer('Rate Changes North Orchard','9777777711')->>'success'='true'
 AND public.create_customer('Rate Changes South Orchard','9777777712')->>'success'='true'
 AND public.create_customer('Rate Changes Closed Farm','9777777713')->>'success'='true','customers');
SELECT pg_temp.rc_assert(public.create_item('Rate Changes Onion','Bag')->>'success'='true'
 AND public.create_item('Rate Changes Garlic','Bag')->>'success'='true'
 AND public.create_item('Rate Changes Cumin','Bag')->>'success'='true'
 AND public.create_item('Rate Changes Retired','Bag')->>'success'='true','items');
RESET ROLE;
SELECT id AS north FROM public.customers WHERE name='Rate Changes North Orchard' \gset
SELECT id AS south FROM public.customers WHERE name='Rate Changes South Orchard' \gset
SELECT id AS closed FROM public.customers WHERE name='Rate Changes Closed Farm' \gset
SELECT id AS onion FROM public.items WHERE name='Rate Changes Onion' \gset
SELECT id AS garlic FROM public.items WHERE name='Rate Changes Garlic' \gset
SELECT id AS cumin FROM public.items WHERE name='Rate Changes Cumin' \gset
SELECT id AS retired FROM public.items WHERE name='Rate Changes Retired' \gset
UPDATE public.customers SET active=false WHERE id=:'closed'::uuid;
UPDATE public.items SET active=false WHERE id=:'retired'::uuid;
SELECT pg_temp.rc_assert(public.assign_customer_to_user('919777777704',:'north'::uuid,'Rate changes fixture'),'customer login assigned');

-- ---------------------------------------------------------------------------
-- 1. Roles
-- ---------------------------------------------------------------------------
SELECT pg_temp.rc_assert(has_function_privilege('authenticated','public.replace_item_rates(uuid,uuid,text,date,jsonb,boolean,text,date,uuid[])','EXECUTE')
 AND has_function_privilege('service_role','public.replace_item_rates(uuid,uuid,text,date,jsonb,boolean,text,date,uuid[])','EXECUTE')
 AND NOT has_function_privilege('anon','public.replace_item_rates(uuid,uuid,text,date,jsonb,boolean,text,date,uuid[])','EXECUTE')
 AND pg_get_functiondef('public.replace_item_rates(uuid,uuid,text,date,jsonb,boolean,text,date,uuid[])'::regprocedure)
   ~ 'BEGIN\s+PERFORM warehouse_security\.authorize_rpc\(''replace_item_rates''','grants and the guard call');
-- Onion starts with a default 0-100 kg rate, 6.00, since 200 days ago (by the administrator).
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_assert(public.create_item_storage_price(p_item_id=>:'onion'::uuid,p_price_type=>'monthly',p_unit_price=>6,
 p_weight_min=>0,p_weight_max=>100,p_labour_rate=>2.5,p_effective_from=>:'old_start',p_tax_percent=>5)->>'success'='true','onion default rate');
RESET ROLE;
SELECT pg_temp.rc_assert(pg_temp.rc_rows(:'onion'::uuid,NULL,'monthly')=format('0-100@6.00/2.50/5 %s..open',:'old_start'),'the rate before the tests: '||pg_temp.rc_rows(:'onion'::uuid,NULL,'monthly'));

-- Administrator and supervisor succeed (future start); staff and a customer account are refused.
SELECT set_config('request.jwt.claims',:'customer_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'onion'::uuid,NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,7))) AS customer_try \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'customer_try'::jsonb->>'state'='42501','a customer account is refused with 42501: '||:'customer_try');
SELECT pg_temp.rc_assert(pg_temp.rc_rows(:'onion'::uuid,NULL,'monthly')=format('0-100@6.00/2.50/5 %s..open',:'old_start'),'the refusal changed nothing');
-- Migration 90 (owner decision, 2026-10-16): staff are refused by the guard (42501), whatever the date.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'onion'::uuid,NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,7))) AS staff_try \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'staff_try'::jsonb->>'state'='42501' AND :'staff_try'::jsonb->>'raised'='Staff access required','a staff account is refused with 42501: '||:'staff_try');
SELECT pg_temp.rc_assert(pg_temp.rc_rows(:'onion'::uuid,NULL,'monthly')=format('0-100@6.00/2.50/5 %s..open',:'old_start'),'the staff refusal changed nothing');
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'onion'::uuid,NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,7))) AS first_change \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'first_change'::jsonb->>'success'='true','supervisor change a rate from a future date: '||:'first_change');
SELECT pg_temp.rc_assert(pg_temp.rc_rows(:'onion'::uuid,NULL,'monthly')=format('0-100@6.00/2.50/5 %s..%s | 0-100@7.00/2.50/5 %s..open',:'old_start',:'d29',:'d30'),
 'supervisor change: '||pg_temp.rc_rows(:'onion'::uuid,NULL,'monthly'));
-- The answer: ended, removed, added.
SELECT pg_temp.rc_assert(:'first_change'::jsonb#>>'{data,starts_on}'=:'d30' AND :'first_change'::jsonb#>>'{data,price_type}'='monthly'
 AND jsonb_array_length(:'first_change'::jsonb#>'{data,ended}')=1 AND (:'first_change'::jsonb#>>'{data,ended,0,effective_to}')=:'d29'
 AND (:'first_change'::jsonb#>>'{data,ended,0,effective_from}')=:'old_start'
 AND :'first_change'::jsonb#>'{data,removed}'='[]'::jsonb AND jsonb_array_length(:'first_change'::jsonb#>'{data,added}')=1
 AND (:'first_change'::jsonb#>>'{data,added,0,unit_price}')::numeric=7 AND (:'first_change'::jsonb#>>'{data,added,0,id}') IS NOT NULL
 AND :'first_change'::jsonb->>'message'='Rates saved' AND :'first_change'::jsonb#>'{data,customer_id}'='null'::jsonb,'the answer names ended, removed and added: '||:'first_change');
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'garlic'::uuid,NULL,'monthly',:'today',jsonb_build_array(pg_temp.rc_band(0,100,5))) AS sup_change \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'sup_change'::jsonb->>'success'='true','a supervisor changes a rate');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'cumin'::uuid,NULL,'monthly',:'today',jsonb_build_array(pg_temp.rc_band(0,100,4))) AS adm_change \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'adm_change'::jsonb->>'success'='true','an administrator changes a rate');

-- ---------------------------------------------------------------------------
-- 2. Change from D: the old rent before, the new rent from D
-- ---------------------------------------------------------------------------
SELECT pg_temp.rc_assert(pg_temp.rc_rent(:'onion'::uuid,NULL,50,:'d29'::date)='6.00' AND pg_temp.rc_rent(:'onion'::uuid,NULL,50,:'d30'::date)='7.00'
 AND pg_temp.rc_rent(:'onion'::uuid,NULL,50,:'today'::date)='6.00','invoices find 6.00 the day before and 7.00 from the start day');

-- ---------------------------------------------------------------------------
-- 3. Split from D2 (0-100 -> 0-40, 41-100)   4. Merge back   (admin, D2 = d120)
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'onion'::uuid,NULL,'monthly',:'d120',jsonb_build_array(pg_temp.rc_band(41,100,9.5),pg_temp.rc_band(0,40,6))) AS split \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'split'::jsonb->>'success'='true','split (bands sent out of order): '||:'split');
SELECT pg_temp.rc_assert(pg_temp.rc_rent(:'onion'::uuid,NULL,30,:'d120'::date)='6.00' AND pg_temp.rc_rent(:'onion'::uuid,NULL,50,:'d120'::date)='9.50'
 AND pg_temp.rc_rent(:'onion'::uuid,NULL,50,:'d120'::date-1)='7.00' AND pg_temp.rc_rent(:'onion'::uuid,NULL,30,:'d120'::date-1)='7.00',
 'split: 30 kg 6.00 and 50 kg 9.50 from D2, 7.00 for both before');
SELECT pg_temp.rc_assert((:'split'::jsonb#>>'{data,added,0,weight_min}')='0' AND (:'split'::jsonb#>>'{data,added,1,weight_min}')='41','added bands come back sorted by weight');
-- Merge on D3 = d120 + 60: the old narrower bands must not win.
SELECT (warehouse_security.business_date(now())+180) AS d180 \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'onion'::uuid,NULL,'monthly',:'d180',jsonb_build_array(pg_temp.rc_band(0,100,8))) AS merge \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'merge'::jsonb->>'success'='true' AND jsonb_array_length(:'merge'::jsonb#>'{data,ended}')=2,'merge ends both bands: '||:'merge');
SELECT pg_temp.rc_assert(pg_temp.rc_rent(:'onion'::uuid,NULL,30,:'d180'::date)='8.00' AND pg_temp.rc_rent(:'onion'::uuid,NULL,50,:'d180'::date)='8.00'
 AND pg_temp.rc_rent(:'onion'::uuid,NULL,30,:'d180'::date-1)='6.00','merge: the new 0-100 wins for 30 kg on the day (the old 0-40 no longer does)');

-- ---------------------------------------------------------------------------
-- 5. One-day rate: a row from D-1 ended at D-1 (relaxed check)
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'garlic'::uuid,NULL,'monthly',:'today',jsonb_build_array(pg_temp.rc_band(0,100,5.5))) AS g1 \gset
SELECT pg_temp.rc_replace(:'garlic'::uuid,NULL,'monthly',:'today'::date+1,jsonb_build_array(pg_temp.rc_band(0,100,6))) AS g2 \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'g1'::jsonb->>'success'='true' AND :'g2'::jsonb->>'success'='true','one-day rate: both calls succeed: '||:'g1'||:'g2');
SELECT pg_temp.rc_assert(pg_temp.rc_rows(:'garlic'::uuid,NULL,'monthly')=format('0-100@5.50/2.50/5 %s..%s | 0-100@6.00/2.50/5 %s..open',:'today',:'today',(:'today'::date+1)::text),
 'one-day rate row: '||pg_temp.rc_rows(:'garlic'::uuid,NULL,'monthly'));

-- ---------------------------------------------------------------------------
-- 6. The same start day twice replaces the first call's rows (history: delete, then insert)
-- ---------------------------------------------------------------------------
SELECT pg_temp.rc_hist() AS hist_before \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'cumin'::uuid,NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,11))) AS c1 \gset
SELECT pg_temp.rc_call(format('SELECT public.replace_item_rates(%L,NULL,%L,%L,%L::jsonb,false,%L,NULL,%L::uuid[])',
  :'cumin','monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,12)),'change',ARRAY[(:'c1'::jsonb#>>'{data,added,0,id}')])) AS c2 \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'c1'::jsonb->>'success'='true' AND :'c2'::jsonb->>'success'='true'
 AND jsonb_array_length(:'c2'::jsonb#>'{data,removed}')=1 AND (:'c2'::jsonb#>>'{data,removed,0,effective_from}')=:'d30'
 AND (:'c2'::jsonb#>>'{data,removed,0,id}')=(:'c1'::jsonb#>>'{data,added,0,id}'),'second call removes the first call''s row: '||:'c2');
SELECT pg_temp.rc_assert(pg_temp.rc_rows(:'cumin'::uuid,NULL,'monthly')=format('0-100@4.00/2.50/5 %s..%s | 0-100@12.00/2.50/5 %s..open',:'today',:'d29',:'d30'),
 'one open row per band after two calls: '||pg_temp.rc_rows(:'cumin'::uuid,NULL,'monthly'));
-- history since hist_before for cumin: update(end today row), insert 11, delete 11, insert 12  (the first call also ended the row once)
SELECT pg_temp.rc_assert((SELECT string_agg(h.action,',' ORDER BY h.id) FROM public.item_price_history h WHERE h.id > (SELECT max(id)-4 FROM public.item_price_history) AND h.item_id=:'cumin'::uuid)
   = 'update,insert,delete,insert','history of two calls on the same day: update, insert, delete, insert');

-- ---------------------------------------------------------------------------
-- 7. Later planned rows
-- ---------------------------------------------------------------------------
-- cumin has 12.00 from d30. A change from today must not remove it silently.
SELECT pg_temp.rc_rows(:'cumin'::uuid,NULL,'monthly') AS cumin_before, pg_temp.rc_hist() AS hist_pre \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'cumin'::uuid,NULL,'monthly',:'today',jsonb_build_array(pg_temp.rc_band(0,100,4.5))) AS later_refused \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'later_refused'::jsonb->>'error_code'='LATER_RATES_EXIST' AND :'later_refused'::jsonb->>'success'='false'
 AND jsonb_array_length(:'later_refused'::jsonb#>'{data,later}')=1 AND (:'later_refused'::jsonb#>>'{data,later,0,effective_from}')=:'d30'
 AND (:'later_refused'::jsonb#>>'{data,later,0,unit_price}')::numeric=12 AND (:'later_refused'::jsonb#>>'{data,later,0,weight_max}')='100',
 'LATER_RATES_EXIST lists the planned rate: '||:'later_refused');
SELECT pg_temp.rc_assert(pg_temp.rc_rows(:'cumin'::uuid,NULL,'monthly')=:'cumin_before' AND pg_temp.rc_hist()=:'hist_pre','nothing changed on LATER_RATES_EXIST');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'cumin'::uuid,NULL,'monthly',:'today',jsonb_build_array(pg_temp.rc_band(0,100,4.5)),true) AS later_replaced \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'later_replaced'::jsonb->>'success'='true' AND jsonb_array_length(:'later_replaced'::jsonb#>'{data,removed}')=2,
 'with p_replace_later the planned rate and the same-day row go: '||:'later_replaced');
SELECT pg_temp.rc_assert(pg_temp.rc_rows(:'cumin'::uuid,NULL,'monthly')=format('0-100@4.50/2.50/5 %s..open',:'today'),'only the new row is left: '||pg_temp.rc_rows(:'cumin'::uuid,NULL,'monthly'));

-- ---------------------------------------------------------------------------
-- 8. Stop; a customer scope falls back to the default
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'onion'::uuid,:'north'::uuid,'monthly',:'today',jsonb_build_array(pg_temp.rc_band(0,100,3))) AS north_rate \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'north_rate'::jsonb->>'success'='true' AND pg_temp.rc_rent(:'onion'::uuid,:'north'::uuid,50,:'today'::date)='3.00'
 AND pg_temp.rc_rent(:'onion'::uuid,:'south'::uuid,50,:'today'::date)='6.00','North has an own rate, South pays the default');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'onion'::uuid,:'north'::uuid,'monthly',:'d30',jsonb_build_array()) AS north_stop \gset
SELECT pg_temp.rc_replace(:'onion'::uuid,:'north'::uuid,'monthly',:'d30',jsonb_build_array()) AS north_stop_again \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'north_stop'::jsonb->>'success'='true' AND :'north_stop'::jsonb#>'{data,added}'='[]'::jsonb
 AND (:'north_stop'::jsonb#>>'{data,ended,0,effective_to}')=:'d29','stop: the row ends the day before, nothing is added: '||:'north_stop');
SELECT pg_temp.rc_assert(pg_temp.rc_rent(:'onion'::uuid,:'north'::uuid,50,:'d29'::date)='3.00' AND pg_temp.rc_rent(:'onion'::uuid,:'north'::uuid,50,:'d30'::date)='7.00',
 'after the stop the default (7.00 from d30) applies to North');
SELECT pg_temp.rc_assert(:'north_stop_again'::jsonb->>'error_code'='NOTHING_TO_STOP','stopping twice: NOTHING_TO_STOP: '||:'north_stop_again');

-- ---------------------------------------------------------------------------
-- 9. Validation
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_hist() AS hist_val, pg_temp.rc_rows(:'garlic'::uuid,NULL,'monthly') AS rows_val \gset
SELECT pg_temp.rc_replace(:'garlic'::uuid,NULL,'weekly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,1)))->>'error_code' AS e_type,
 pg_temp.rc_replace(:'garlic'::uuid,NULL,'monthly',:'dpast'::date,jsonb_build_array(pg_temp.rc_band(0,100,1)))->>'error_code' AS e_date_past,
 pg_temp.rc_replace(:'garlic'::uuid,NULL,'monthly',:'dfar'::date,jsonb_build_array(pg_temp.rc_band(0,100,1)))->>'error_code' AS e_date_far,
 pg_temp.rc_replace(:'garlic'::uuid,NULL,'monthly',NULL,jsonb_build_array(pg_temp.rc_band(0,100,1)))->>'error_code' AS e_date_null,
 pg_temp.rc_replace(gen_random_uuid(),NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,1)))->>'error_code' AS e_item,
 pg_temp.rc_replace(:'retired'::uuid,NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,1)))->>'error_code' AS e_item_inactive,
 pg_temp.rc_replace(:'garlic'::uuid,:'closed'::uuid,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,1)))->>'error_code' AS e_customer,
 pg_temp.rc_replace(:'garlic'::uuid,gen_random_uuid(),'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,1)))->>'error_code' AS e_customer_unknown,
 pg_temp.rc_replace(:'garlic'::uuid,NULL,'monthly',:'d30',(SELECT jsonb_agg(pg_temp.rc_band(i*10,i*10+9,1)) FROM generate_series(0,10) i))->>'error_code' AS e_eleven,
 pg_temp.rc_replace(:'garlic'::uuid,NULL,'monthly',:'d30','{"a":1}'::jsonb)->>'error_code' AS e_not_array,
 pg_temp.rc_replace(:'garlic'::uuid,NULL,'monthly',:'d30',NULL)->>'error_code' AS e_null_bands \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'e_type'='INVALID_PRICE_TYPE' AND :'e_date_past'='INVALID_DATE' AND :'e_date_far'='INVALID_DATE' AND :'e_date_null'='INVALID_DATE'
 AND :'e_item'='ITEM_NOT_FOUND' AND :'e_item_inactive'='ITEM_NOT_FOUND' AND :'e_customer'='CUSTOMER_NOT_FOUND' AND :'e_customer_unknown'='CUSTOMER_NOT_FOUND'
 AND :'e_eleven'='INVALID_BANDS' AND :'e_not_array'='INVALID_BANDS' AND :'e_null_bands'='INVALID_BANDS',
 format('validation codes: %s %s %s %s %s %s %s %s %s %s %s',:'e_type',:'e_date_past',:'e_date_far',:'e_date_null',:'e_item',:'e_item_inactive',:'e_customer',:'e_customer_unknown',:'e_eleven',:'e_not_array',:'e_null_bands'));
-- Bands.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'garlic'::uuid,NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,50,1),pg_temp.rc_band(40,100,1))) AS b_overlap,
 pg_temp.rc_replace(:'garlic'::uuid,NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,40,1),pg_temp.rc_band(50,100,1))) AS b_gap,
 pg_temp.rc_replace(:'garlic'::uuid,NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(10,100,1))) AS b_not_zero,
 pg_temp.rc_replace(:'garlic'::uuid,:'south'::uuid,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(10,40,1),pg_temp.rc_band(60,100,2))) AS b_customer_gap,
 pg_temp.rc_replace(:'garlic'::uuid,NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(50,40,1))) AS b_min_max,
 pg_temp.rc_replace(:'garlic'::uuid,NULL,'monthly',:'d30',jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',40.5,'unit_price',1,'labour_rate',1,'tax_percent',5))) AS b_fraction,
 pg_temp.rc_replace(:'garlic'::uuid,NULL,'monthly',:'d30',jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max','40','unit_price',1,'labour_rate',1,'tax_percent',5))) AS b_string,
 pg_temp.rc_replace(:'garlic'::uuid,NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,1,2,101))) AS b_tax,
 pg_temp.rc_replace(:'garlic'::uuid,NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,1.005))) AS b_decimals,
 pg_temp.rc_replace(:'garlic'::uuid,NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,-1))) AS b_negative,
 pg_temp.rc_replace(:'garlic'::uuid,NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,1000000))) AS b_huge,
 pg_temp.rc_replace(:'garlic'::uuid,NULL,'monthly',:'d30',jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',1,'tax_percent',5))) AS b_no_labour,
 pg_temp.rc_replace(:'garlic'::uuid,NULL,'monthly',:'d29',jsonb_build_array(pg_temp.rc_band(0,100,1),pg_temp.rc_band(101,200,2),'7'::jsonb)) AS b_not_object,
 pg_temp.rc_replace(:'garlic'::uuid,NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,1),pg_temp.rc_band(101,200,1,2,101))) AS b_third \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'b_overlap'::jsonb->>'error_code'='BANDS_OVERLAP' AND :'b_gap'::jsonb->>'error_code'='BANDS_GAP' AND (:'b_gap'::jsonb#>>'{data,expected_min}')='41'
 AND :'b_not_zero'::jsonb->>'error_code'='BANDS_GAP' AND (:'b_not_zero'::jsonb#>>'{data,expected_min}')='0'
 AND :'b_customer_gap'::jsonb->>'success'='true','overlap, default gap (expected_min 41 and 0), customer gaps allowed: '||:'b_overlap'||:'b_gap'||:'b_not_zero'||:'b_customer_gap');
SELECT pg_temp.rc_assert(:'b_min_max'::jsonb->>'error_code'='INVALID_BAND' AND :'b_fraction'::jsonb->>'error_code'='INVALID_BAND' AND :'b_string'::jsonb->>'error_code'='INVALID_BAND'
 AND :'b_tax'::jsonb->>'error_code'='INVALID_AMOUNT' AND :'b_tax'::jsonb#>>'{data,field}'='tax_percent' AND :'b_decimals'::jsonb->>'error_code'='INVALID_AMOUNT'
 AND :'b_decimals'::jsonb#>>'{data,field}'='unit_price' AND :'b_negative'::jsonb->>'error_code'='INVALID_AMOUNT' AND :'b_huge'::jsonb->>'error_code'='INVALID_AMOUNT'
 AND :'b_no_labour'::jsonb->>'error_code'='INVALID_AMOUNT' AND :'b_no_labour'::jsonb#>>'{data,field}'='labour_rate' AND :'b_not_object'::jsonb->>'error_code'='INVALID_BAND',
 'band and amount errors: '||:'b_min_max'||:'b_fraction'||:'b_string'||:'b_tax'||:'b_decimals'||:'b_negative'||:'b_huge'||:'b_no_labour'||:'b_not_object');
SELECT pg_temp.rc_assert(:'b_third'::jsonb->>'error_code'='INVALID_AMOUNT' AND (:'b_third'::jsonb#>>'{data,index}')='1','the error names the band index: '||:'b_third');
-- 10. Atomicity: the invalid third band left the default scope as it was (the customer-gap call above wrote only South's scope).
SELECT pg_temp.rc_assert(pg_temp.rc_rows(:'garlic'::uuid,NULL,'monthly')=:'rows_val','garlic default rows unchanged by every refused call');
SELECT pg_temp.rc_assert(pg_temp.rc_hist()=:'hist_val'+2,'only the accepted South call (two bands) left history, 2 inserts: '||(pg_temp.rc_hist()-:'hist_val')::text);

-- ---------------------------------------------------------------------------
-- 11. History: each ended, removed and added row has one history row with the caller and one changed_at
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'garlic'::uuid,:'south'::uuid,'monthly',:'d120',jsonb_build_array(pg_temp.rc_band(0,50,2),pg_temp.rc_band(51,100,3))) AS hist_call \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'hist_call'::jsonb->>'success'='true','history call: '||:'hist_call');
SELECT pg_temp.rc_assert((SELECT count(*)=3 AND count(DISTINCT h.changed_at)=1 AND bool_and(h.changed_by=:'supervisor_profile'::uuid AND h.changed_by_role='supervisor')
   AND count(*) FILTER (WHERE h.action='update')=1 AND count(*) FILTER (WHERE h.action='insert')=2
   FROM public.item_price_history h WHERE h.item_id=:'garlic'::uuid AND h.customer_id=:'south'::uuid AND h.id > (SELECT max(id)-3 FROM public.item_price_history)),
 'one update (ended row) and two inserts, one changed_at, the supervisor');

-- ---------------------------------------------------------------------------
-- 12. Other scopes untouched: customer rows, one-time rows, other items
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'garlic'::uuid,NULL,'one_time',:'today',jsonb_build_array(pg_temp.rc_band(0,100,40,9,0))) AS one_time \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'one_time'::jsonb->>'success'='true','one-time rate created');
-- Labour of a one-time rate is stored as 0 whatever is sent (decision 3), and is not checked.
SELECT pg_temp.rc_assert(pg_temp.rc_rows(:'garlic'::uuid,NULL,'one_time')=format('0-100@40.00/0.00/0 %s..open',:'today'),'one-time labour stored as 0: '||pg_temp.rc_rows(:'garlic'::uuid,NULL,'one_time'));
SELECT pg_temp.rc_rows(:'garlic'::uuid,NULL,'monthly') AS garlic_monthly_before, pg_temp.rc_rows(:'garlic'::uuid,:'south'::uuid,'monthly') AS south_before,
       pg_temp.rc_rows(:'onion'::uuid,:'north'::uuid,'monthly') AS north_before, pg_temp.rc_rows(:'onion'::uuid,NULL,'monthly') AS onion_before \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'garlic'::uuid,NULL,'one_time',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,45,3,0))) AS one_time2 \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'one_time2'::jsonb->>'success'='true' AND pg_temp.rc_rows(:'garlic'::uuid,NULL,'monthly')=:'garlic_monthly_before'
 AND pg_temp.rc_rows(:'garlic'::uuid,:'south'::uuid,'monthly')=:'south_before' AND pg_temp.rc_rows(:'onion'::uuid,NULL,'monthly')=:'onion_before'
 AND pg_temp.rc_rows(:'onion'::uuid,:'north'::uuid,'monthly')=:'north_before','a one-time change leaves monthly, customer and other-item rows alone');

-- ---------------------------------------------------------------------------
-- 13. Owner decisions: past dates, rates in force, one-time labour, create/update overlap, one-day
-- ---------------------------------------------------------------------------
-- 1. A start in the past is for administrators and supervisors (staff are refused every change since migration 90).
SELECT pg_temp.rc_hist() AS hist_pd, pg_temp.rc_rows(:'cumin'::uuid,NULL,'monthly') AS rows_pd \gset
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'cumin'::uuid,NULL,'monthly',:'yesterday',jsonb_build_array(pg_temp.rc_band(0,100,5))) AS staff_past,
       pg_temp.rc_replace(:'cumin'::uuid,NULL,'monthly',:'today',jsonb_build_array(pg_temp.rc_band(0,100,5))) AS staff_today \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'staff_past'::jsonb->>'state'='42501' AND :'staff_past'::jsonb->>'raised'='Staff access required'
 AND :'staff_today'::jsonb->>'state'='42501' AND pg_temp.rc_rows(:'cumin'::uuid,NULL,'monthly')=:'rows_pd',
 'staff: yesterday and today are both refused by the guard (migration 90), rows unchanged: '||:'staff_past'||:'staff_today');
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'cumin'::uuid,NULL,'monthly',:'yesterday',jsonb_build_array(pg_temp.rc_band(0,100,5)),true) AS sup_past \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'sup_past'::jsonb->>'success'='true','a supervisor may start a rate yesterday ("correct" path)');
-- 2. Staff and the price writers (migration 90: refused by the guard); a supervisor creates, edits and deletes.
SELECT id AS cumin_row FROM public.item_storage_prices WHERE item_id=:'cumin'::uuid AND customer_id IS NULL AND price_type='monthly' AND effective_from=:'yesterday'::date \gset
SELECT pg_temp.rc_hist() AS hist_st, pg_temp.rc_rows(:'cumin'::uuid,NULL,'monthly') AS rows_st, pg_temp.rc_rows(:'cumin'::uuid,:'north'::uuid,'monthly') AS rows_st_north \gset
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_call(format($q$SELECT public.update_item_storage_price(p_id=>%L::uuid,p_unit_price=>9,p_weight_min=>0,p_weight_max=>100,p_labour_rate=>2,p_tax_percent=>5,p_effective_from=>%L,p_effective_to=>NULL)$q$,:'cumin_row',:'yesterday')) AS st_update,
       pg_temp.rc_call(format($q$SELECT public.delete_item_storage_price(%L::uuid)$q$,:'cumin_row')) AS st_delete,
       pg_temp.rc_call(format($q$SELECT public.create_item_storage_price(p_item_id=>%L::uuid,p_price_type=>'monthly',p_unit_price=>9,p_weight_min=>0,p_weight_max=>100,p_labour_rate=>2,p_effective_from=>%L,p_customer_id=>%L::uuid,p_tax_percent=>5)$q$,:'cumin',:'yesterday',:'north')) AS st_create_past,
       pg_temp.rc_call(format($q$SELECT public.create_item_storage_price(p_item_id=>%L::uuid,p_price_type=>'monthly',p_unit_price=>9,p_weight_min=>0,p_weight_max=>100,p_labour_rate=>2,p_effective_from=>%L,p_customer_id=>%L::uuid,p_tax_percent=>5)$q$,:'cumin',:'d30',:'north')) AS st_create_future,
       pg_temp.rc_call(format($q$SELECT public.update_item_storage_price(%L::uuid,0,100,9,0,2,5,%L::date,NULL)$q$,:'cumin_row',:'yesterday')) AS st_legacy_update \gset
RESET ROLE;
SELECT pg_temp.rc_assert((SELECT bool_and(COALESCE(a->>'success','false')<>'true' AND a::text LIKE '%Staff access required%')
   FROM (VALUES (:'st_update'::jsonb),(:'st_delete'::jsonb),(:'st_create_past'::jsonb),(:'st_create_future'::jsonb),(:'st_legacy_update'::jsonb)) v(a))
 AND pg_temp.rc_hist()=:hist_st AND pg_temp.rc_rows(:'cumin'::uuid,NULL,'monthly')=:'rows_st' AND pg_temp.rc_rows(:'cumin'::uuid,:'north'::uuid,'monthly')=:'rows_st_north',
 'staff refused on update, delete, create (past and upcoming) and the legacy update overload; nothing changed: '||:'st_update'||:'st_delete'||:'st_create_past'||:'st_create_future'||:'st_legacy_update');
-- A supervisor creates an upcoming rate, edits and deletes it, and may move it into the past.
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_item_storage_price(p_item_id=>:'cumin'::uuid,p_price_type=>'monthly',p_unit_price=>9,p_weight_min=>0,p_weight_max=>100,p_labour_rate=>2,p_effective_from=>:'d30',p_customer_id=>:'north'::uuid,p_tax_percent=>5) AS sup_create_future \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'sup_create_future'::jsonb->>'success'='true','a supervisor may create an upcoming rate: '||:'sup_create_future');
SELECT (:'sup_create_future'::jsonb#>>'{data,id}') AS north_future \gset
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_item_storage_price(p_id=>:'north_future'::uuid,p_unit_price=>10,p_weight_min=>0,p_weight_max=>100,p_labour_rate=>2.5,p_tax_percent=>5,p_effective_from=>:'d30',p_effective_to=>NULL) AS st_upd_future,
       public.update_item_storage_price(p_id=>:'north_future'::uuid,p_unit_price=>10,p_weight_min=>0,p_weight_max=>100,p_labour_rate=>2.5,p_tax_percent=>5,p_effective_from=>:'yesterday',p_effective_to=>NULL) AS st_upd_to_past,
       public.delete_item_storage_price(:'north_future'::uuid) AS st_del_future \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'st_upd_future'::jsonb->>'success'='true' AND :'st_upd_to_past'::jsonb->>'success'='true' AND :'st_del_future'::jsonb->>'success'='true',
 'a supervisor edits an upcoming row, moves it into the past and deletes it: '||:'st_upd_future'||:'st_upd_to_past'||:'st_del_future');
-- Managers still may.
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_item_storage_price(p_id=>:'cumin_row'::uuid,p_unit_price=>9,p_weight_min=>0,p_weight_max=>100,p_labour_rate=>2,p_tax_percent=>5,p_effective_from=>:'yesterday',p_effective_to=>NULL) AS sup_update \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'sup_update'::jsonb->>'success'='true','a supervisor may update a rate in force');
-- 3. One-time labour stays 0 through create and update.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_item_storage_price(p_item_id=>:'cumin'::uuid,p_price_type=>'one_time',p_unit_price=>30,p_weight_min=>0,p_weight_max=>100,p_labour_rate=>4,p_effective_from=>:'today',p_tax_percent=>5) AS ot_create \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'ot_create'::jsonb->>'success'='true' AND pg_temp.rc_rows(:'cumin'::uuid,NULL,'one_time')=format('0-100@30.00/0.00/5 %s..open',:'today'),'create stores labour 0 for one-time: '||pg_temp.rc_rows(:'cumin'::uuid,NULL,'one_time'));
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_item_storage_price(p_id=>(:'ot_create'::jsonb#>>'{data,id}')::uuid,p_unit_price=>31,p_weight_min=>0,p_weight_max=>100,p_labour_rate=>6,p_tax_percent=>5,p_effective_from=>:'today',p_effective_to=>NULL) AS ot_update \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'ot_update'::jsonb->>'success'='true' AND pg_temp.rc_rows(:'cumin'::uuid,NULL,'one_time')=format('0-100@31.00/0.00/5 %s..open',:'today'),'update stores labour 0 for one-time: '||pg_temp.rc_rows(:'cumin'::uuid,NULL,'one_time'));
-- 13. Create and update refuse an overlap and accept a one-day rate.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_item_storage_price(p_item_id=>:'cumin'::uuid,p_price_type=>'monthly',p_unit_price=>9,p_weight_min=>50,p_weight_max=>150,p_labour_rate=>2,p_effective_from=>:'today',p_tax_percent=>5) AS overlap_create,
       public.create_item_storage_price(p_item_id=>:'cumin'::uuid,p_price_type=>'one_time',p_unit_price=>9,p_weight_min=>0,p_weight_max=>10,p_labour_rate=>2,p_effective_from=>:'today',p_tax_percent=>5) AS overlap_one_time,
       public.create_item_storage_price(p_item_id=>:'cumin'::uuid,p_price_type=>'monthly',p_unit_price=>9,p_weight_min=>101,p_weight_max=>150,p_labour_rate=>2,p_effective_from=>:'today',p_tax_percent=>5) AS no_overlap_weight,
       public.create_item_storage_price(p_item_id=>:'cumin'::uuid,p_price_type=>'monthly',p_unit_price=>9,p_weight_min=>0,p_weight_max=>100,p_labour_rate=>2,p_effective_from=>:'old_start',p_effective_to=>:'old_start',p_customer_id=>:'north'::uuid,p_tax_percent=>5) AS one_day_same \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'overlap_create'::jsonb->>'error_code'='BANDS_OVERLAP' AND :'overlap_one_time'::jsonb->>'error_code'='BANDS_OVERLAP'
 AND :'no_overlap_weight'::jsonb->>'success'='true' AND :'one_day_same'::jsonb->>'success'='true',
 'create refuses an overlap in the same price type (even one-time), accepts a different weight and a one-day rate: '||:'overlap_create'||:'overlap_one_time'||:'one_day_same');
SELECT public.create_item_storage_price(p_item_id=>:'cumin'::uuid,p_price_type=>'monthly',p_unit_price=>9,p_weight_min=>0,p_weight_max=>100,p_labour_rate=>2,p_effective_from=>:'today',p_effective_to=>:'yesterday',p_customer_id=>:'south'::uuid,p_tax_percent=>5) AS end_before_start \gset
SELECT pg_temp.rc_assert(:'end_before_start'::jsonb->>'success'='false' AND :'end_before_start'::jsonb->>'error'='effective_to must not be before effective_from','a rate that ends before it starts is refused');
-- update into an overlap is refused; an update leaving the row alone is fine.
SELECT id AS other_row FROM public.item_storage_prices WHERE item_id=:'cumin'::uuid AND customer_id IS NULL AND price_type='monthly' AND weight_min=101 \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_item_storage_price(p_id=>:'other_row'::uuid,p_unit_price=>9,p_weight_min=>90,p_weight_max=>150,p_labour_rate=>2,p_tax_percent=>5,p_effective_from=>:'today',p_effective_to=>NULL) AS overlap_update,
       public.update_item_storage_price(p_id=>:'other_row'::uuid,p_unit_price=>9.25,p_weight_min=>101,p_weight_max=>150,p_labour_rate=>2,p_tax_percent=>5,p_effective_from=>:'today',p_effective_to=>:'today') AS one_day_update \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'overlap_update'::jsonb->>'error_code'='BANDS_OVERLAP' AND :'one_day_update'::jsonb->>'success'='true','update refuses an overlap, accepts a one-day rate: '||:'overlap_update'||:'one_day_update');
-- The nine-argument legacy update still works for a manager (it never overlaps its own row).
-- Migration 87: the nine-argument overload answers BANDS_OVERLAP for a partial overlap in its own price type
-- and ignores a row of the other price type. A new item for South: monthly 0-49 and 50-100, one-time 0-49.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_item('Rate Changes Legacy Overload','Bag')->>'success' AS lg_item \gset
RESET ROLE;
SELECT id AS lgitem FROM public.items WHERE name='Rate Changes Legacy Overload' \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_item_storage_price(p_item_id=>:'lgitem'::uuid,p_price_type=>'monthly',p_unit_price=>9,p_weight_min=>0,p_weight_max=>49,p_labour_rate=>2,p_effective_from=>:'d30',p_customer_id=>:'south'::uuid,p_tax_percent=>5) AS lg_a,
       public.create_item_storage_price(p_item_id=>:'lgitem'::uuid,p_price_type=>'monthly',p_unit_price=>9,p_weight_min=>50,p_weight_max=>100,p_labour_rate=>2,p_effective_from=>:'d30',p_customer_id=>:'south'::uuid,p_tax_percent=>5) AS lg_b,
       public.create_item_storage_price(p_item_id=>:'lgitem'::uuid,p_price_type=>'one_time',p_unit_price=>9,p_weight_min=>0,p_weight_max=>49,p_labour_rate=>0,p_effective_from=>:'d30',p_customer_id=>:'south'::uuid,p_tax_percent=>5) AS lg_c \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'lg_a'::jsonb->>'success'='true' AND :'lg_b'::jsonb->>'success'='true' AND :'lg_c'::jsonb->>'success'='true','legacy overload fixture rows: '||:'lg_a'||:'lg_b'||:'lg_c');
SELECT id AS lg_row FROM public.item_storage_prices WHERE item_id=:'lgitem'::uuid AND customer_id=:'south'::uuid AND price_type='monthly' AND weight_min=0 \gset
SELECT pg_temp.rc_rows(:'lgitem'::uuid,:'south'::uuid,'monthly') AS lg_before \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_item_storage_price(:'lg_row'::uuid,0,70,0,9,2,5,:'d30'::date,NULL) AS lg_partial,
       public.update_item_storage_price(:'lg_row'::uuid,0,49,0,9.5,2,5,:'d30'::date,NULL) AS lg_other_type \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'lg_partial'::jsonb->>'error_code'='BANDS_OVERLAP' AND :'lg_partial'::jsonb->>'success'='false',
 'the legacy overload refuses a partial overlap (0-70 against 50-100): '||:'lg_partial');
SELECT pg_temp.rc_assert(:'lg_other_type'::jsonb->>'success'='true',
 'the legacy overload ignores a one-time row with the same band: '||:'lg_other_type');
SELECT pg_temp.rc_assert((SELECT weight_max=49 FROM public.item_storage_prices WHERE id=:'lg_row'::uuid)
 AND (SELECT count(*)=2 FROM public.item_storage_prices WHERE item_id=:'lgitem'::uuid AND customer_id=:'south'::uuid AND price_type='monthly'),
 'the refused overlap changed nothing; rows: '||pg_temp.rc_rows(:'lgitem'::uuid,:'south'::uuid,'monthly'));

-- ---------------------------------------------------------------------------
-- 14. search_customers: every typed word anywhere in the name; order starts-with first
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_customer('Orchard Zeta Rate Changes','9777777721') ->>'success' AS made_zeta \gset
SELECT public.create_customer('Rate Changes Zeta Orchard North','9777777722') ->>'success' AS made_zeta2 \gset
SELECT (SELECT string_agg(e->>'name',' | ' ORDER BY ord) FROM jsonb_array_elements(public.search_customers('orchard')->'data') WITH ORDINALITY x(e,ord) WHERE e->>'name' LIKE '%Rate Changes%'
          OR e->>'name' LIKE 'Orchard Zeta%') AS s_orchard,
       (SELECT string_agg(e->>'name',' | ' ORDER BY ord) FROM jsonb_array_elements(public.search_customers('zeta orchard')->'data') WITH ORDINALITY x(e,ord)) AS s_two_words,
       (SELECT string_agg(e->>'name',' | ' ORDER BY ord) FROM jsonb_array_elements(public.search_customers('ORCHARD zeta north')->'data') WITH ORDINALITY x(e,ord)) AS s_three_words,
       (SELECT string_agg(e->>'name',' | ' ORDER BY ord) FROM jsonb_array_elements(public.search_customers('97777777')->'data') WITH ORDINALITY x(e,ord)) AS s_mobile,
       jsonb_array_length(public.search_customers('orchard',2)->'data') AS s_limit,
       jsonb_array_length(public.search_customers('%')->'data') AS s_percent,
       jsonb_array_length(public.search_customers('   ')->'data') > 3 AS s_blank_all,
       jsonb_array_length(public.search_customers(NULL)->'data') > 3 AS s_null_all,
       jsonb_array_length(public.search_customers('zzzz nothing')->'data') AS s_none \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'made_zeta'='true' AND :'made_zeta2'='true','search fixtures');
SELECT pg_temp.rc_assert(:'s_orchard'='Orchard Zeta Rate Changes | Rate Changes North Orchard | Rate Changes South Orchard | Rate Changes Zeta Orchard North',
 'one word: the name that starts with it first, then the others by name: '||:'s_orchard');
SELECT pg_temp.rc_assert(:'s_two_words'='Orchard Zeta Rate Changes | Rate Changes Zeta Orchard North','two words in any order: '||:'s_two_words');
SELECT pg_temp.rc_assert(:'s_three_words'='Rate Changes Zeta Orchard North','three words, any case: '||:'s_three_words');
SELECT pg_temp.rc_assert(:'s_mobile' LIKE '%Rate Changes%' AND :'s_limit'=2 AND :'s_percent'=0 AND :'s_blank_all' AND :'s_null_all' AND :'s_none'=0,
 format('mobile prefix, limit, wildcard text is literal, blank lists all, no match is empty: %s %s %s',:'s_limit',:'s_percent',:'s_none'));

-- ---------------------------------------------------------------------------
-- 15. get_item_storage_prices: a tie-breaker on id (pages never skip or repeat)
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_item_storage_prices(jsonb_build_object('include_expired',true),'weight_min','asc',1000,0) AS all_rows \gset
SELECT (SELECT string_agg(r->>'id',',' ORDER BY ord) FROM jsonb_array_elements(public.get_item_storage_prices(jsonb_build_object('include_expired',true),'weight_min','asc',4,0)->'data') WITH ORDINALITY x(r,ord))
    || ',' || (SELECT string_agg(r->>'id',',' ORDER BY ord) FROM jsonb_array_elements(public.get_item_storage_prices(jsonb_build_object('include_expired',true),'weight_min','asc',4,4)->'data') WITH ORDINALITY x(r,ord))
    || ',' || (SELECT string_agg(r->>'id',',' ORDER BY ord) FROM jsonb_array_elements(public.get_item_storage_prices(jsonb_build_object('include_expired',true),'weight_min','asc',4,8)->'data') WITH ORDINALITY x(r,ord)) AS pages_ids,
  (SELECT string_agg(r->>'id',',' ORDER BY ord) FROM jsonb_array_elements(public.get_item_storage_prices(jsonb_build_object('include_expired',true),'weight_min','asc',12,0)->'data') WITH ORDINALITY x(r,ord)) AS one_page_ids \gset
RESET ROLE;
SELECT pg_temp.rc_assert((:'all_rows'::jsonb#>>'{pagination,total}')::int > 12 AND :'pages_ids'=:'one_page_ids','three pages of 4 equal one page of 12 (many rows share the sort key)');
SELECT pg_temp.rc_assert(pg_get_functiondef('public.get_item_storage_prices(jsonb,text,text,integer,integer)'::regprocedure) LIKE '%, isp.id ASC%','the tie-breaker is in the list function');

-- ---------------------------------------------------------------------------
-- 15b. undo_rate_change: one step back from a change that starts on a day
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_assert(public.create_item('Rate Undo A','Bag')->>'success'='true' AND public.create_item('Rate Undo B','Bag')->>'success'='true'
 AND public.create_item('Rate Undo C','Bag')->>'success'='true' AND public.create_item('Rate Undo D','Bag')->>'success'='true'
 AND public.create_item('Rate Undo E','Bag')->>'success'='true','undo items');
RESET ROLE;
SELECT id AS ua FROM public.items WHERE name='Rate Undo A' \gset
SELECT id AS ub FROM public.items WHERE name='Rate Undo B' \gset
SELECT id AS uc FROM public.items WHERE name='Rate Undo C' \gset
SELECT id AS ud FROM public.items WHERE name='Rate Undo D' \gset
SELECT id AS ue FROM public.items WHERE name='Rate Undo E' \gset
SELECT pg_temp.rc_assert(has_function_privilege('authenticated','public.undo_rate_change(uuid,uuid,text,date)','EXECUTE')
 AND has_function_privilege('service_role','public.undo_rate_change(uuid,uuid,text,date)','EXECUTE')
 AND NOT has_function_privilege('anon','public.undo_rate_change(uuid,uuid,text,date)','EXECUTE')
 AND pg_get_functiondef('public.undo_rate_change(uuid,uuid,text,date)'::regprocedure)
   ~ 'BEGIN\s+PERFORM warehouse_security\.authorize_rpc\(''undo_rate_change''','undo_rate_change: grants and the guard call');
-- Items A..E each start with 6.00 since 200 days ago.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'ua'::uuid,NULL,'monthly',:'old_start'::date,jsonb_build_array(pg_temp.rc_band(0,100,6))) AS seed_a,
       pg_temp.rc_replace(:'ub'::uuid,NULL,'monthly',:'old_start'::date,jsonb_build_array(pg_temp.rc_band(0,100,6))) AS seed_b,
       pg_temp.rc_replace(:'uc'::uuid,NULL,'monthly',:'old_start'::date,jsonb_build_array(pg_temp.rc_band(0,100,6))) AS seed_c,
       pg_temp.rc_replace(:'ud'::uuid,NULL,'monthly',:'old_start'::date,jsonb_build_array(pg_temp.rc_band(0,100,6))) AS seed_d,
       pg_temp.rc_replace(:'ue'::uuid,NULL,'monthly',:'old_start'::date,jsonb_build_array(pg_temp.rc_band(0,100,6))) AS seed_e \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'seed_a'::jsonb->>'success'='true' AND :'seed_e'::jsonb->>'success'='true','undo seeds');

-- (a) change from d30 (with a North row and a one-time row on the same day), then undo for the default monthly scope.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'ua'::uuid,NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,7))) AS ua_change,
       pg_temp.rc_replace(:'ua'::uuid,:'north'::uuid,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,3))) AS ua_north,
       pg_temp.rc_replace(:'ua'::uuid,NULL,'one_time',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,40,0,0))) AS ua_one_time \gset
RESET ROLE;
SELECT pg_temp.rc_assert(pg_temp.rc_rows(:'ua'::uuid,NULL,'monthly')=format('0-100@6.00/2.50/5 %s..%s | 0-100@7.00/2.50/5 %s..open',:'old_start',:'d29',:'d30')
 AND pg_temp.rc_rent(:'ua'::uuid,NULL,50,:'d30'::date+4)='7.00','before the undo: 7.00 from d30: '||pg_temp.rc_rows(:'ua'::uuid,NULL,'monthly'));
SELECT pg_temp.rc_rows(:'ua'::uuid,:'north'::uuid,'monthly') AS ua_north_before, pg_temp.rc_rows(:'ua'::uuid,NULL,'one_time') AS ua_ot_before,
       pg_temp.rc_rows(:'ub'::uuid,NULL,'monthly') AS ub_before \gset
-- A customer account is refused.
SELECT set_config('request.jwt.claims',:'customer_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_call(format('SELECT public.undo_rate_change(%L,NULL,%L,%L)',:'ua','monthly',:'d30')) AS undo_customer \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'undo_customer'::jsonb->>'state'='42501' AND pg_temp.rc_rent(:'ua'::uuid,NULL,50,:'d30'::date+4)='7.00','a customer account is refused with 42501: '||:'undo_customer');
-- Staff are refused (migration 90), even for a change that has not begun.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_call(format('SELECT public.undo_rate_change(%L,NULL,%L,%L)',:'ua','monthly',:'d30')) AS undo_staff \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'undo_staff'::jsonb->>'state'='42501' AND :'undo_staff'::jsonb->>'raised'='Staff access required' AND pg_temp.rc_rent(:'ua'::uuid,NULL,50,:'d30'::date+4)='7.00',
 'a staff account is refused with 42501 and nothing is undone: '||:'undo_staff');
-- A supervisor may undo a change that has not begun.
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_call(format('SELECT public.undo_rate_change(%L,NULL,%L,%L)',:'ua','monthly',:'d30')) AS undo_a \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'undo_a'::jsonb->>'success'='true' AND :'undo_a'::jsonb->>'message'='Change undone'
 AND :'undo_a'::jsonb#>>'{data,starts_on}'=:'d30' AND :'undo_a'::jsonb#>>'{data,price_type}'='monthly' AND :'undo_a'::jsonb#>'{data,customer_id}'='null'::jsonb
 AND jsonb_array_length(:'undo_a'::jsonb#>'{data,removed}')=1 AND (:'undo_a'::jsonb#>>'{data,removed,0,effective_from}')=:'d30'
 AND jsonb_array_length(:'undo_a'::jsonb#>'{data,reopened}')=1 AND (:'undo_a'::jsonb#>>'{data,reopened,0,effective_from}')=:'old_start'
 AND (:'undo_a'::jsonb#>'{data,reopened,0,effective_to}')='null'::jsonb,'(a) the answer names removed and reopened: '||:'undo_a');
SELECT pg_temp.rc_assert(pg_temp.rc_rows(:'ua'::uuid,NULL,'monthly')=format('0-100@6.00/2.50/5 %s..open',:'old_start')
 AND pg_temp.rc_rent(:'ua'::uuid,NULL,50,:'d30'::date+4)='6.00','(a) old row open again, new row gone, 6.00 on d30+4: '||pg_temp.rc_rows(:'ua'::uuid,NULL,'monthly'));
-- (f) other scopes untouched.
SELECT pg_temp.rc_assert(pg_temp.rc_rows(:'ua'::uuid,:'north'::uuid,'monthly')=:'ua_north_before' AND pg_temp.rc_rows(:'ua'::uuid,NULL,'one_time')=:'ua_ot_before'
 AND pg_temp.rc_rows(:'ub'::uuid,NULL,'monthly')=:'ub_before','(f) the North row, the one-time row and another item are untouched');
-- The customer scope undoes on its own: its row goes, nothing to reopen, the default stays.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_call(format('SELECT public.undo_rate_change(%L,%L,%L,%L)',:'ua',:'north','monthly',:'d30')) AS undo_north \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'undo_north'::jsonb->>'success'='true' AND jsonb_array_length(:'undo_north'::jsonb#>'{data,removed}')=1 AND :'undo_north'::jsonb#>'{data,reopened}'='[]'::jsonb
 AND pg_temp.rc_rows(:'ua'::uuid,:'north'::uuid,'monthly')='(none)' AND pg_temp.rc_rows(:'ua'::uuid,NULL,'one_time')=:'ua_ot_before'
 AND pg_temp.rc_rows(:'ua'::uuid,NULL,'monthly')=format('0-100@6.00/2.50/5 %s..open',:'old_start'),'(f) the customer scope alone: '||:'undo_north');

-- (b) a stop with last day L = d29, then undo(L+1).
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'ub'::uuid,NULL,'monthly',:'d30',jsonb_build_array()) AS ub_stop \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'ub_stop'::jsonb->>'success'='true' AND pg_temp.rc_rows(:'ub'::uuid,NULL,'monthly')=format('0-100@6.00/2.50/5 %s..%s',:'old_start',:'d29')
 AND pg_temp.rc_rent(:'ub'::uuid,NULL,50,:'d30'::date+4)='none','(b) before: the rate stopped, last day d29');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_call(format('SELECT public.undo_rate_change(%L,NULL,%L,%L)',:'ub','monthly',(:'d29'::date+1)::text)) AS undo_b \gset
SELECT pg_temp.rc_call(format('SELECT public.undo_rate_change(%L,NULL,%L,%L)',:'ub','monthly',(:'d29'::date+1)::text)) AS undo_b_again \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'undo_b'::jsonb->>'success'='true' AND :'undo_b'::jsonb#>'{data,removed}'='[]'::jsonb AND jsonb_array_length(:'undo_b'::jsonb#>'{data,reopened}')=1
 AND pg_temp.rc_rows(:'ub'::uuid,NULL,'monthly')=format('0-100@6.00/2.50/5 %s..open',:'old_start') AND pg_temp.rc_rent(:'ub'::uuid,NULL,50,:'d30'::date+4)='6.00',
 '(b) undo of a stop: the row is open again: '||:'undo_b'||pg_temp.rc_rows(:'ub'::uuid,NULL,'monthly'));
-- (e) nothing left to undo.
SELECT pg_temp.rc_assert(:'undo_b_again'::jsonb->>'success'='false' AND :'undo_b_again'::jsonb->>'error_code'='NOTHING_TO_UNDO'
 AND :'undo_b_again'::jsonb->>'error'='There is no change starting on that day to undo' AND pg_temp.rc_rows(:'ub'::uuid,NULL,'monthly')=format('0-100@6.00/2.50/5 %s..open',:'old_start'),
 '(e) NOTHING_TO_UNDO and nothing changed: '||:'undo_b_again');

-- (c) two planned changes (d30 and d120): undo(d30) re-opens the old row up to d119; the d120 row stays.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'uc'::uuid,NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,7))) AS uc1,
       pg_temp.rc_replace(:'uc'::uuid,NULL,'monthly',:'d120',jsonb_build_array(pg_temp.rc_band(0,100,8))) AS uc2 \gset
SELECT pg_temp.rc_call(format('SELECT public.undo_rate_change(%L,NULL,%L,%L)',:'uc','monthly',:'d30')) AS undo_c \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'undo_c'::jsonb->>'success'='true' AND (:'undo_c'::jsonb#>>'{data,reopened,0,effective_to}')=(:'d120'::date-1)::text,'(c) the old row is reopened up to the day before d120: '||:'undo_c');
SELECT pg_temp.rc_assert(pg_temp.rc_rows(:'uc'::uuid,NULL,'monthly')=format('0-100@6.00/2.50/5 %s..%s | 0-100@8.00/2.50/5 %s..open',:'old_start',(:'d120'::date-1)::text,:'d120')
 AND pg_temp.rc_rent(:'uc'::uuid,NULL,50,:'d30'::date+4)='6.00' AND pg_temp.rc_rent(:'uc'::uuid,NULL,50,:'d120'::date)='8.00','(c) rows: '||pg_temp.rc_rows(:'uc'::uuid,NULL,'monthly'));

-- (d) staff and a change that has begun: a supervisor changes from yesterday and from today; staff are refused, a supervisor succeeds.
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'ud'::uuid,NULL,'monthly',:'yesterday'::date,jsonb_build_array(pg_temp.rc_band(0,100,7))) AS ud_change,
       pg_temp.rc_replace(:'ue'::uuid,NULL,'monthly',:'today'::date,jsonb_build_array(pg_temp.rc_band(0,100,7))) AS ue_change \gset
RESET ROLE;
SELECT pg_temp.rc_rows(:'ud'::uuid,NULL,'monthly') AS ud_before, pg_temp.rc_rows(:'ue'::uuid,NULL,'monthly') AS ue_before, pg_temp.rc_hist() AS hist_ud \gset
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_call(format('SELECT public.undo_rate_change(%L,NULL,%L,%L)',:'ud','monthly',:'yesterday')) AS ud_staff,
       pg_temp.rc_call(format('SELECT public.undo_rate_change(%L,NULL,%L,%L)',:'ue','monthly',:'today')) AS ue_staff \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'ud_staff'::jsonb->>'state'='42501' AND :'ue_staff'::jsonb->>'state'='42501'
 AND pg_temp.rc_rows(:'ud'::uuid,NULL,'monthly')=:'ud_before' AND pg_temp.rc_rows(:'ue'::uuid,NULL,'monthly')=:'ue_before' AND pg_temp.rc_hist()=:'hist_ud',
 '(d) staff (migration 90): the guard refuses both, nothing changed: '||:'ud_staff'||:'ue_staff');
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_call(format('SELECT public.undo_rate_change(%L,NULL,%L,%L)',:'ud','monthly',:'yesterday')) AS ud_sup \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'ud_sup'::jsonb->>'success'='true' AND pg_temp.rc_rows(:'ud'::uuid,NULL,'monthly')=format('0-100@6.00/2.50/5 %s..open',:'old_start'),
 '(d) a supervisor undoes a change that has begun: '||:'ud_sup'||pg_temp.rc_rows(:'ud'::uuid,NULL,'monthly'));

-- Validation codes, and the history of the undo (one delete, one update).
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_call(format('SELECT public.undo_rate_change(%L,NULL,%L,%L)',:'ua','weekly',:'d30'))->>'error_code' AS u_type,
       pg_temp.rc_call(format('SELECT public.undo_rate_change(%L,NULL,%L,%L)',:'ua','monthly',:'dfar'))->>'error_code' AS u_date_far,
       pg_temp.rc_call(format('SELECT public.undo_rate_change(%L,NULL,%L,NULL)',:'ua','monthly'))->>'error_code' AS u_date_null,
       pg_temp.rc_call(format('SELECT public.undo_rate_change(%L,NULL,%L,%L)',gen_random_uuid(),'monthly',:'d30'))->>'error_code' AS u_item,
       pg_temp.rc_call(format('SELECT public.undo_rate_change(%L,%L,%L,%L)',:'ua',:'closed','monthly',:'d30'))->>'error_code' AS u_customer \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'u_type'='INVALID_PRICE_TYPE' AND :'u_date_far'='INVALID_DATE' AND :'u_date_null'='INVALID_DATE' AND :'u_item'='ITEM_NOT_FOUND' AND :'u_customer'='CUSTOMER_NOT_FOUND',
 format('undo validation codes: %s %s %s %s %s',:'u_type',:'u_date_far',:'u_date_null',:'u_item',:'u_customer'));
SELECT pg_temp.rc_assert((SELECT string_agg(h.action,',' ORDER BY h.action) FROM (SELECT * FROM public.item_price_history WHERE item_id=:'ud'::uuid ORDER BY id DESC LIMIT 2) h)='delete,update','the undo is in the price history (a delete and an update)');
-- An undo that would make rates overlap changes nothing: a stray row (written directly) covers a day the reopened row would take.
INSERT INTO public.item_storage_prices(item_id,customer_id,price_type,unit_price,weight_min,weight_max,labour_rate,tax_percent,effective_from,effective_to,unit_price_one_time,unit_price_monthly)
 VALUES (:'ue'::uuid,NULL,'monthly',1,0,10,0,0,:'old_start'::date+10,:'old_start'::date+12,0,1);
SELECT pg_temp.rc_rows(:'ue'::uuid,NULL,'monthly') AS ue_overlap_before \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_call(format('SELECT public.undo_rate_change(%L,NULL,%L,%L)',:'ue','monthly',:'today')) AS undo_overlap \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'undo_overlap'::jsonb->>'error_code'='BANDS_OVERLAP' AND :'undo_overlap'::jsonb->>'success'='false' AND pg_temp.rc_rows(:'ue'::uuid,NULL,'monthly')=:'ue_overlap_before',
 '(overlap) BANDS_OVERLAP and the removed row is back: '||:'undo_overlap'||pg_temp.rc_rows(:'ue'::uuid,NULL,'monthly'));

-- ---------------------------------------------------------------------------
-- 16. The guard refuses staff what is not listed (item pricing since migration 90)
-- ---------------------------------------------------------------------------
SELECT pg_temp.rc_assert(pg_get_functiondef('warehouse_security.authorize_rpc(text,jsonb)'::regprocedure) !~ '''(replace_item_rates|undo_rate_change|delete_item_storage_price)''','the guard no longer lists replace_item_rates, undo_rate_change or the price writers for staff (migration 90)');

-- ---------------------------------------------------------------------------
-- 15c. Code-review fixes: modes, kept stop, move, staff and rates in force, find_or_create, India-day filter
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_assert(public.create_item('Rate Mode K','Bag')->>'success'='true' AND public.create_item('Rate Mode K2','Bag')->>'success'='true'
 AND public.create_item('Rate Mode C','Bag')->>'success'='true' AND public.create_item('Rate Mode S','Bag')->>'success'='true'
 AND public.create_item('Rate Mode S2','Bag')->>'success'='true' AND public.create_item('Rate Mode P','Bag')->>'success'='true'
 AND public.create_item('Rate Mode M','Bag')->>'success'='true' AND public.create_item('Rate Mode M2','Bag')->>'success'='true'
 AND public.create_item('Rate Mode M3','Bag')->>'success'='true' AND public.create_item('Rate Mode M4','Bag')->>'success'='true'
 AND public.create_item('Rate Mode F','Bag')->>'success'='true' AND public.create_item('Rate Mode X','Bag')->>'success'='true'
 AND public.create_item('Rate Clock','Bag')->>'success'='true','mode items');
RESET ROLE;
SELECT id AS mk FROM public.items WHERE name='Rate Mode K' \gset
SELECT id AS mk2 FROM public.items WHERE name='Rate Mode K2' \gset
SELECT id AS mc FROM public.items WHERE name='Rate Mode C' \gset
SELECT id AS ms FROM public.items WHERE name='Rate Mode S' \gset
SELECT id AS ms2 FROM public.items WHERE name='Rate Mode S2' \gset
SELECT id AS mp FROM public.items WHERE name='Rate Mode P' \gset
SELECT id AS mm FROM public.items WHERE name='Rate Mode M' \gset
SELECT id AS mm2 FROM public.items WHERE name='Rate Mode M2' \gset
SELECT id AS mm3 FROM public.items WHERE name='Rate Mode M3' \gset
SELECT id AS mm4 FROM public.items WHERE name='Rate Mode M4' \gset
SELECT id AS mf FROM public.items WHERE name='Rate Mode F' \gset
SELECT id AS mx FROM public.items WHERE name='Rate Mode X' \gset
SELECT id AS clockitem FROM public.items WHERE name='Rate Clock' \gset
SELECT :'old_start'::date+100 AS a_end, :'old_start'::date+101 AS b_start, :'old_start'::date+5 AS a_mid, :'old_start'::date-10 AS before_all, :'today'::date+1 AS tomorrow \gset

-- CR-02, change mode keeps a scheduled stop (default rent 6 stops on d120; nothing later).
SELECT pg_temp.rc_row(:'mk'::uuid,NULL,0,100,6,:'old_start',:'d120');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'mk'::uuid,NULL,'monthly',:'today',jsonb_build_array(pg_temp.rc_band(0,100,7))) AS keep_change \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'keep_change'::jsonb->>'success'='true' AND :'keep_change'::jsonb#>>'{data,kept_end}'=:'d120'
 AND pg_temp.rc_rows(:'mk'::uuid,NULL,'monthly')=format('0-100@6.00/2.50/5 %s..%s | 0-100@7.00/2.50/5 %s..%s',:'old_start',:'yesterday',:'today',:'d120')
 AND pg_temp.rc_rent(:'mk'::uuid,NULL,50,:'d120'::date+1)='none','change keeps the stop: '||:'keep_change'||pg_temp.rc_rows(:'mk'::uuid,NULL,'monthly'));
-- ... but not when a rate is planned later and replaced (the stop belonged to the replaced rate).
SELECT pg_temp.rc_row(:'mk2'::uuid,NULL,0,100,6,:'old_start',:'d29');
SELECT pg_temp.rc_row(:'mk2'::uuid,NULL,0,100,8,:'d30',:'d120');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'mk2'::uuid,NULL,'monthly',:'today',jsonb_build_array(pg_temp.rc_band(0,100,7)),true) AS nokeep_change \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'nokeep_change'::jsonb->>'success'='true' AND :'nokeep_change'::jsonb#>'{data,kept_end}'='null'::jsonb
 AND pg_temp.rc_rows(:'mk2'::uuid,NULL,'monthly')=format('0-100@6.00/2.50/5 %s..%s | 0-100@7.00/2.50/5 %s..open',:'old_start',:'yesterday',:'today'),'later rate replaced: no stop kept: '||pg_temp.rc_rows(:'mk2'::uuid,NULL,'monthly'));

-- CR-03 / CR-02, correct mode: only the rows that start on D; the end is kept; later rows stay.
SELECT pg_temp.rc_row(:'mc'::uuid,NULL,0,100,10,:'old_start',:'old_start'::date+100);
SELECT pg_temp.rc_row(:'mc'::uuid,NULL,0,100,11,:'old_start'::date+101,NULL);
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'mc'::uuid,NULL,'monthly',:'old_start',jsonb_build_array(pg_temp.rc_band(0,100,12)),true,'correct') AS correct_a,
       pg_temp.rc_rows(:'mc'::uuid,NULL,'monthly') AS rows_after_a,
       pg_temp.rc_replace(:'mc'::uuid,NULL,'monthly',:'a_mid',jsonb_build_array(pg_temp.rc_band(0,100,9)),false,'correct') AS correct_mid,
       pg_temp.rc_replace(:'mc'::uuid,NULL,'monthly',:'before_all',jsonb_build_array(pg_temp.rc_band(0,100,9)),false,'correct') AS correct_none,
       pg_temp.rc_replace(:'mc'::uuid,NULL,'monthly',:'old_start',jsonb_build_array(),false,'correct') AS correct_empty,
       pg_temp.rc_replace(:'mc'::uuid,NULL,'monthly',:'b_start',jsonb_build_array(pg_temp.rc_band(0,100,11.5)),false,'correct') AS correct_b \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'correct_a'::jsonb->>'success'='true' AND :'correct_a'::jsonb#>>'{data,kept_end}'=:'a_end' AND :'correct_a'::jsonb#>'{data,ended}'='[]'::jsonb
 AND jsonb_array_length(:'correct_a'::jsonb#>'{data,removed}')=1
 AND :'rows_after_a'=format('0-100@12.00/2.50/5 %s..%s | 0-100@11.00/2.50/5 %s..open',:'old_start',:'a_end',:'b_start'),
 'correcting A keeps its end and the later rate B (no LATER_RATES_EXIST, p_replace_later ignored): '||:'correct_a'||:'rows_after_a');
SELECT pg_temp.rc_assert(:'correct_mid'::jsonb->>'error_code'='NOT_A_RATE_START' AND :'correct_none'::jsonb->>'error_code'='NOT_A_RATE_START'
 AND :'correct_empty'::jsonb->>'error_code'='INVALID_BANDS' AND :'correct_mid'::jsonb->>'success'='false',
 'a day inside a rate, a day before any rate and an empty list are refused: '||:'correct_mid'||:'correct_none'||:'correct_empty');
SELECT pg_temp.rc_assert(:'correct_b'::jsonb->>'success'='true' AND :'correct_b'::jsonb#>'{data,kept_end}'='null'::jsonb
 AND pg_temp.rc_rows(:'mc'::uuid,NULL,'monthly')=format('0-100@12.00/2.50/5 %s..%s | 0-100@11.50/2.50/5 %s..open',:'old_start',:'a_end',:'b_start'),'correcting the open-ended rate B stays open: '||pg_temp.rc_rows(:'mc'::uuid,NULL,'monthly'));
-- Correcting the stopped rate made by the change test (CR-02): the stop stays.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'mk'::uuid,NULL,'monthly',:'today',jsonb_build_array(pg_temp.rc_band(0,100,8)),false,'correct') AS correct_stopped \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'correct_stopped'::jsonb->>'success'='true' AND :'correct_stopped'::jsonb#>>'{data,kept_end}'=:'d120'
 AND pg_temp.rc_rows(:'mk'::uuid,NULL,'monthly')=format('0-100@6.00/2.50/5 %s..%s | 0-100@8.00/2.50/5 %s..%s',:'old_start',:'yesterday',:'today',:'d120'),'correct keeps the stop: '||pg_temp.rc_rows(:'mk'::uuid,NULL,'monthly'));

-- Invalid modes.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'mx'::uuid,NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,3)),false,'replace') AS bad_mode,
       pg_temp.rc_replace(:'mx'::uuid,NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,3)),false,NULL) AS null_mode,
       pg_temp.rc_replace(:'mx'::uuid,NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,3)),false,'correct',:'d120') AS move_in_correct,
       pg_temp.rc_replace(:'mx'::uuid,NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,3)),false,'change',:'d120') AS nothing_to_move \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'bad_mode'::jsonb->>'error_code'='INVALID_MODE' AND :'null_mode'::jsonb->>'error_code'='INVALID_MODE'
 AND :'move_in_correct'::jsonb->>'error_code'='INVALID_MODE' AND :'nothing_to_move'::jsonb->>'error_code'='NOTHING_TO_MOVE'
 AND pg_temp.rc_rows(:'mx'::uuid,NULL,'monthly')='(none)','invalid modes and nothing to move write nothing: '||:'bad_mode'||:'null_mode'||:'move_in_correct'||:'nothing_to_move');

-- CR-01, move a planned rate. M: 11 until d29, 12 planned from d30; move 12 to d120 with rent 13.
SELECT pg_temp.rc_row(:'mm'::uuid,NULL,0,100,11,:'old_start',:'d29');
SELECT pg_temp.rc_row(:'mm'::uuid,NULL,0,100,12,:'d30',NULL);
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'mm'::uuid,NULL,'monthly',:'d120',jsonb_build_array(pg_temp.rc_band(0,100,13)),false,'change',:'d30') AS move_later \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'move_later'::jsonb->>'success'='true' AND :'move_later'::jsonb#>>'{data,move_from}'=:'d30' AND jsonb_array_length(:'move_later'::jsonb#>'{data,reopened}')=1
 AND pg_temp.rc_rows(:'mm'::uuid,NULL,'monthly')=format('0-100@11.00/2.50/5 %s..%s | 0-100@13.00/2.50/5 %s..open',:'old_start',:'d120'::date-1,:'d120')
 AND pg_temp.rc_rent(:'mm'::uuid,NULL,50,:'d30')='11.00' AND pg_temp.rc_rent(:'mm'::uuid,NULL,50,:'d120'::date-1)='11.00' AND pg_temp.rc_rent(:'mm'::uuid,NULL,50,:'d120')='13.00',
 'moving later: nothing of 12 is left between the two days: '||:'move_later'||pg_temp.rc_rows(:'mm'::uuid,NULL,'monthly'));
-- Move earlier: 12 planned from d120, moved to d30; no LATER_RATES_EXIST about itself.
SELECT pg_temp.rc_row(:'mm2'::uuid,NULL,0,100,11,:'old_start',:'d120'::date-1);
SELECT pg_temp.rc_row(:'mm2'::uuid,NULL,0,100,12,:'d120',NULL);
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'mm2'::uuid,NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,13)),false,'change',:'d120') AS move_earlier \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'move_earlier'::jsonb->>'success'='true'
 AND pg_temp.rc_rows(:'mm2'::uuid,NULL,'monthly')=format('0-100@11.00/2.50/5 %s..%s | 0-100@13.00/2.50/5 %s..open',:'old_start',:'d29',:'d30'),'moving earlier: '||:'move_earlier'||pg_temp.rc_rows(:'mm2'::uuid,NULL,'monthly'));
-- A refusal after the undo undoes it: 12 from d30, 14 from d120; moving 12 to today meets the later 14.
SELECT pg_temp.rc_row(:'mm4'::uuid,NULL,0,100,11,:'old_start',:'d29');
SELECT pg_temp.rc_row(:'mm4'::uuid,NULL,0,100,12,:'d30',:'d120'::date-1);
SELECT pg_temp.rc_row(:'mm4'::uuid,NULL,0,100,14,:'d120',NULL);
SELECT pg_temp.rc_rows(:'mm4'::uuid,NULL,'monthly') AS mm4_before \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'mm4'::uuid,NULL,'monthly',:'today',jsonb_build_array(pg_temp.rc_band(0,100,13)),false,'change',:'d30') AS move_refused \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'move_refused'::jsonb->>'error_code'='LATER_RATES_EXIST' AND pg_temp.rc_rows(:'mm4'::uuid,NULL,'monthly')=:'mm4_before',
 'a refusal after the undo leaves the rows as they were: '||:'move_refused'||pg_temp.rc_rows(:'mm4'::uuid,NULL,'monthly'));
-- Staff are refused every move (migration 90: the guard); a supervisor moves a planned rate.
SELECT pg_temp.rc_row(:'mm3'::uuid,NULL,0,100,11,:'old_start',:'d29');
SELECT pg_temp.rc_row(:'mm3'::uuid,NULL,0,100,12,:'d30',NULL);
SELECT pg_temp.rc_rows(:'mm3'::uuid,NULL,'monthly') AS mm3_before \gset
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'mm3'::uuid,NULL,'monthly',:'today',jsonb_build_array(pg_temp.rc_band(0,100,13)),false,'change',:'d30') AS staff_move_today,
       pg_temp.rc_replace(:'mm3'::uuid,NULL,'monthly',:'d120',jsonb_build_array(pg_temp.rc_band(0,100,13)),false,'change',:'old_start') AS staff_move_begun,
       pg_temp.rc_replace(:'mm3'::uuid,NULL,'monthly',:'d120',jsonb_build_array(pg_temp.rc_band(0,100,13)),false,'change',:'d30') AS staff_move_ok \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'staff_move_today'::jsonb->>'state'='42501' AND :'staff_move_begun'::jsonb->>'state'='42501' AND :'staff_move_ok'::jsonb->>'state'='42501'
 AND pg_temp.rc_rows(:'mm3'::uuid,NULL,'monthly')=:'mm3_before',
 'staff move: all three refused by the guard, rows unchanged: '||:'staff_move_today'||:'staff_move_begun'||:'staff_move_ok'||pg_temp.rc_rows(:'mm3'::uuid,NULL,'monthly'));
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'mm3'::uuid,NULL,'monthly',:'d120',jsonb_build_array(pg_temp.rc_band(0,100,13)),false,'change',:'d30') AS sup_move_ok \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'sup_move_ok'::jsonb->>'success'='true' AND pg_temp.rc_rows(:'mm3'::uuid,NULL,'monthly')=format('0-100@11.00/2.50/5 %s..%s | 0-100@13.00/2.50/5 %s..open',:'old_start',:'d120'::date-1,:'d120'),
 'a supervisor moves a planned rate: '||:'sup_move_ok'||pg_temp.rc_rows(:'mm3'::uuid,NULL,'monthly'));

-- CR-32: staff (refused by the guard since migration 90) and a rate that began today. S: a rate started today (by an administrator).
SELECT pg_temp.rc_row(:'ms'::uuid,NULL,0,100,5,:'old_start',:'yesterday');
SELECT pg_temp.rc_row(:'ms'::uuid,NULL,0,100,6,:'today',NULL);
SELECT pg_temp.rc_rows(:'ms'::uuid,NULL,'monthly') AS ms_before \gset
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'ms'::uuid,NULL,'monthly',:'today',jsonb_build_array(pg_temp.rc_band(0,100,9))) AS staff_today_change,
       pg_temp.rc_replace(:'ms'::uuid,NULL,'monthly',:'today',jsonb_build_array(pg_temp.rc_band(0,100,9)),false,'correct') AS staff_today_correct,
       pg_temp.rc_replace(:'ms'::uuid,NULL,'monthly',:'today',jsonb_build_array()) AS staff_today_stop \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'staff_today_change'::jsonb->>'state'='42501' AND :'staff_today_correct'::jsonb->>'state'='42501'
 AND :'staff_today_stop'::jsonb->>'state'='42501' AND pg_temp.rc_rows(:'ms'::uuid,NULL,'monthly')=:'ms_before',
 'staff cannot replace or stop a rate that began today (the guard refuses them): '||:'staff_today_change'||:'staff_today_correct'||:'staff_today_stop');
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'ms'::uuid,NULL,'monthly',:'today',jsonb_build_array(pg_temp.rc_band(0,100,9)),false,'correct') AS sup_today_correct \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'sup_today_correct'::jsonb->>'success'='true' AND pg_temp.rc_rows(:'ms'::uuid,NULL,'monthly')=format('0-100@5.00/2.50/5 %s..%s | 0-100@9.00/2.50/5 %s..open',:'old_start',:'yesterday',:'today'),
 'a supervisor corrects it: '||pg_temp.rc_rows(:'ms'::uuid,NULL,'monthly'));
-- Staff are refused a change from today even when nothing started today (migration 90); a supervisor may.
SELECT pg_temp.rc_row(:'ms2'::uuid,NULL,0,100,5,:'old_start',NULL);
SELECT pg_temp.rc_rows(:'ms2'::uuid,NULL,'monthly') AS ms2_before \gset
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'ms2'::uuid,NULL,'monthly',:'today',jsonb_build_array(pg_temp.rc_band(0,100,9))) AS staff_today_refused \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'staff_today_refused'::jsonb->>'state'='42501' AND pg_temp.rc_rows(:'ms2'::uuid,NULL,'monthly')=:'ms2_before','staff change from today refused, rows unchanged: '||:'staff_today_refused');
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'ms2'::uuid,NULL,'monthly',:'today',jsonb_build_array(pg_temp.rc_band(0,100,9))) AS staff_today_ok \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'staff_today_ok'::jsonb->>'success'='true','a supervisor changes from today when no rate started today: '||:'staff_today_ok');
-- Staff are refused a correction (migration 90); a supervisor corrects a planned rate (D after today).
SELECT pg_temp.rc_row(:'mp'::uuid,NULL,0,100,6,:'old_start',:'d29');
SELECT pg_temp.rc_row(:'mp'::uuid,NULL,0,100,7,:'d30',NULL);
SELECT pg_temp.rc_rows(:'mp'::uuid,NULL,'monthly') AS mp_before \gset
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'mp'::uuid,NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,7.5)),false,'correct') AS staff_correct_plan,
       pg_temp.rc_replace(:'mp'::uuid,NULL,'monthly',:'old_start',jsonb_build_array(pg_temp.rc_band(0,100,7.5)),false,'correct') AS staff_correct_past \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'staff_correct_plan'::jsonb->>'state'='42501' AND :'staff_correct_past'::jsonb->>'state'='42501'
 AND pg_temp.rc_rows(:'mp'::uuid,NULL,'monthly')=:'mp_before','staff corrections refused, rows unchanged: '||:'staff_correct_plan'||:'staff_correct_past');
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'mp'::uuid,NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,7.5)),false,'correct') AS sup_correct_plan \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'sup_correct_plan'::jsonb->>'success'='true'
 AND pg_temp.rc_rows(:'mp'::uuid,NULL,'monthly')=format('0-100@6.00/2.50/5 %s..%s | 0-100@7.50/2.50/5 %s..open',:'old_start',:'d29',:'d30'),'a supervisor corrects a planned rate: '||pg_temp.rc_rows(:'mp'::uuid,NULL,'monthly'));

-- CR-33: find_or_create_item_storage_price is for administrators and supervisors.
SELECT pg_get_functiondef('warehouse_security.authorize_rpc(text,jsonb)'::regprocedure) NOT LIKE '%''find_or_create_item_storage_price''%' AS guard_dropped \gset
SELECT pg_temp.rc_assert(:'guard_dropped'::boolean,'the staff list no longer names find_or_create_item_storage_price');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'mf'::uuid,:'north'::uuid,'monthly',:'today',jsonb_build_array(pg_temp.rc_band(0,40,5))) AS f_seed \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'f_seed'::jsonb->>'success'='true','seed');
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_call(format('SELECT public.find_or_create_item_storage_price(%L,%L,70,''monthly'',9,1,5)',:'mf',:'north')) AS f_staff \gset
RESET ROLE;
SELECT pg_temp.rc_assert(COALESCE(:'f_staff'::jsonb->>'success','false')<>'true' AND (SELECT count(*)=1 FROM public.item_storage_prices WHERE item_id=:'mf'::uuid),'staff are refused and nothing is created: '||:'f_staff');
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.find_or_create_item_storage_price(:'mf'::uuid,:'north'::uuid,50,'monthly',9,1,5) AS f_overlap,
       public.find_or_create_item_storage_price(:'mf'::uuid,:'south'::uuid,10,'one_time',12,3,5) AS f_onetime \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'f_overlap'::jsonb->>'error_code'='BANDS_OVERLAP' AND :'f_overlap'::jsonb->>'success'='false'
 AND (SELECT count(*)=1 FROM public.item_storage_prices WHERE item_id=:'mf'::uuid AND customer_id=:'north'::uuid),'an overlapping row is refused: '||:'f_overlap');
SELECT pg_temp.rc_assert(:'f_onetime'::jsonb->>'success'='true' AND (:'f_onetime'::jsonb#>>'{data,labour_rate}')::numeric=0
 AND :'f_onetime'::jsonb#>>'{data,effective_from}'=:'today'
 AND (SELECT labour_rate=0 AND effective_from=:'today'::date FROM public.item_storage_prices WHERE id=(:'f_onetime'::jsonb#>>'{data,id}')::uuid),'a one-time row has labour 0 and starts on the India day: '||:'f_onetime');

-- CR-34: the expired filter uses the India day. The clock is emulated one day ahead of the server's day.
CREATE OR REPLACE FUNCTION warehouse_security.business_date(moment timestamptz) RETURNS date
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$ SELECT CURRENT_DATE + 1 $$;
SELECT pg_temp.rc_row(:'mx'::uuid,NULL,0,100,3,:'old_start',CURRENT_DATE);
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_item_storage_prices(jsonb_build_object('item_ids',jsonb_build_array(:'mx')),'weight_min','asc',50,0) AS expired_hidden,
       public.get_item_storage_prices(jsonb_build_object('item_ids',jsonb_build_array(:'mx'),'include_expired',true),'weight_min','asc',50,0) AS expired_shown \gset
RESET ROLE;
SELECT pg_temp.rc_assert(jsonb_array_length(:'expired_hidden'::jsonb->'data')=0 AND jsonb_array_length(:'expired_shown'::jsonb->'data')=1,
 'a rate whose last day is before the India day is hidden unless include_expired: '||:'expired_hidden'||:'expired_shown');
-- (section 17 replaces the clock again; the whole file is rolled back at the end.)

-- ---------------------------------------------------------------------------
-- 16b. Bundle review F13: a scheduled stop survives moving and undoing the planned rate
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_assert(public.create_item('Rate Stop X','Bag')->>'success'='true' AND public.create_item('Rate Stop Y','Bag')->>'success'='true'
 AND public.create_item('Rate Stale Z','Bag')->>'success'='true','F13/F30 items');
RESET ROLE;
SELECT id AS sx FROM public.items WHERE name='Rate Stop X' \gset
SELECT id AS sy FROM public.items WHERE name='Rate Stop Y' \gset
SELECT id AS sz FROM public.items WHERE name='Rate Stale Z' \gset
SELECT (:'d120'::date+100)::text AS stop_day, (:'d30'::date+10)::text AS d40 \gset
SELECT pg_temp.rc_row(:'sx'::uuid,NULL,0,100,11,:'old_start',:'stop_day');
SELECT pg_temp.rc_row(:'sy'::uuid,NULL,0,100,11,:'old_start',:'stop_day');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'sx'::uuid,NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,12))) AS sx1,
       pg_temp.rc_replace(:'sy'::uuid,NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,12))) AS sy1 \gset
RESET ROLE;
SELECT pg_temp.rc_assert(pg_temp.rc_rows(:'sx'::uuid,NULL,'monthly')=format('0-100@11.00/2.50/5 %s..%s | 0-100@12.00/2.50/5 %s..%s',:'old_start',:'d29',:'d30',:'stop_day'),
 'F13 set-up: the change keeps the stop: '||pg_temp.rc_rows(:'sx'::uuid,NULL,'monthly'));
-- (a) move the planned rate: the stop stays on the moved rate.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'sx'::uuid,NULL,'monthly',:'d40',jsonb_build_array(pg_temp.rc_band(0,100,12)),false,'change',:'d30') AS sx_move,
       pg_temp.rc_call(format('SELECT public.undo_rate_change(%L,NULL,%L,%L)',:'sy','monthly',:'d30')) AS sy_undo \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'sx_move'::jsonb->>'success'='true' AND :'sx_move'::jsonb#>>'{data,kept_end}'=:'stop_day'
 AND pg_temp.rc_rows(:'sx'::uuid,NULL,'monthly')=format('0-100@11.00/2.50/5 %s..%s | 0-100@12.00/2.50/5 %s..%s',:'old_start',(:'d40'::date-1)::text,:'d40',:'stop_day')
 AND pg_temp.rc_rent(:'sx'::uuid,NULL,50,:'stop_day'::date+1)='none','F13 (a) moved rate keeps the stop: '||:'sx_move'||pg_temp.rc_rows(:'sx'::uuid,NULL,'monthly'));
-- (b) undo the planned rate: the old rate is open again up to the stop, not without an end.
SELECT pg_temp.rc_assert(:'sy_undo'::jsonb->>'success'='true'
 AND pg_temp.rc_rows(:'sy'::uuid,NULL,'monthly')=format('0-100@11.00/2.50/5 %s..%s',:'old_start',:'stop_day')
 AND pg_temp.rc_rent(:'sy'::uuid,NULL,50,:'stop_day'::date+1)='none','F13 (b) undo reopens up to the stop: '||:'sy_undo'||pg_temp.rc_rows(:'sy'::uuid,NULL,'monthly'));

-- ---------------------------------------------------------------------------
-- 16c. Bundle review F30: a stale editor is told, not silently overwritten
-- ---------------------------------------------------------------------------
SELECT pg_temp.rc_row(:'sz'::uuid,NULL,0,100,11,:'old_start',NULL);
SELECT array_agg(id ORDER BY id) AS seen_ids FROM public.item_storage_prices WHERE item_id=:'sz'::uuid \gset
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'sz'::uuid,NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,12))) AS sz_first \gset
RESET ROLE;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_call(format('SELECT public.replace_item_rates(%L,NULL,%L,%L,%L::jsonb,false,%L,NULL,%L::uuid[])',
  :'sz','monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,13)),'change',:'seen_ids')) AS sz_stale \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'sz_first'::jsonb->>'success'='true' AND :'sz_stale'::jsonb->>'error_code'='STALE_RATES'
 AND pg_temp.rc_rows(:'sz'::uuid,NULL,'monthly')=format('0-100@11.00/2.50/5 %s..%s | 0-100@12.00/2.50/5 %s..open',:'old_start',:'d29',:'d30'),
 'F30 a stale save is refused and writes nothing: '||:'sz_stale'||pg_temp.rc_rows(:'sz'::uuid,NULL,'monthly'));
SELECT array_agg(id ORDER BY id) AS fresh_ids FROM public.item_storage_prices WHERE item_id=:'sz'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_call(format('SELECT public.replace_item_rates(%L,NULL,%L,%L,%L::jsonb,false,%L,NULL,%L::uuid[])',
  :'sz','monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,13)),'change',:'fresh_ids')) AS sz_fresh \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'sz_fresh'::jsonb->>'success'='true'
 AND pg_temp.rc_rows(:'sz'::uuid,NULL,'monthly')=format('0-100@11.00/2.50/5 %s..%s | 0-100@13.00/2.50/5 %s..open',:'old_start',:'d29',:'d30'),
 'F30 a save that saw the current rows goes through: '||:'sz_fresh'||pg_temp.rc_rows(:'sz'::uuid,NULL,'monthly'));

-- ---------------------------------------------------------------------------
-- 16d. Bundle review F11: a rate planned to start ON the start day is refused, not deleted
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_assert(public.create_item('Rate Day P','Bag')->>'success'='true','F11 item');
RESET ROLE;
SELECT id AS pp FROM public.items WHERE name='Rate Day P' \gset
SELECT pg_temp.rc_row(:'pp'::uuid,NULL,0,100,11,:'old_start',:'d29');
SELECT pg_temp.rc_row(:'pp'::uuid,NULL,0,100,12,:'d30',NULL);
SELECT pg_temp.rc_rows(:'pp'::uuid,NULL,'monthly') AS pp_before \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
-- a stop ON the planned start day, a change ON it, and a stop the day before it
SELECT pg_temp.rc_replace(:'pp'::uuid,NULL,'monthly',:'d30',jsonb_build_array()) AS pp_stop_on,
       pg_temp.rc_replace(:'pp'::uuid,NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,15))) AS pp_change_on,
       pg_temp.rc_replace(:'pp'::uuid,NULL,'monthly',:'d29',jsonb_build_array()) AS pp_stop_before \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'pp_stop_on'::jsonb->>'error_code'='LATER_RATES_EXIST' AND :'pp_change_on'::jsonb->>'error_code'='LATER_RATES_EXIST'
 AND :'pp_stop_before'::jsonb->>'error_code'='LATER_RATES_EXIST' AND :'pp_stop_on'::jsonb#>>'{data,later,0,effective_from}'=:'d30'
 AND pg_temp.rc_rows(:'pp'::uuid,NULL,'monthly')=:'pp_before','F11 planned rate is refused and kept: '||:'pp_stop_on'||pg_temp.rc_rows(:'pp'::uuid,NULL,'monthly'));
-- correct mode on the planned rate's own day still works
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'pp'::uuid,NULL,'monthly',:'d30',jsonb_build_array(pg_temp.rc_band(0,100,13)),false,'correct') AS pp_correct,
       pg_temp.rc_replace(:'pp'::uuid,NULL,'monthly',(:'d30'::date+5),jsonb_build_array(pg_temp.rc_band(0,100,14)),false,'change',:'d30') AS pp_move \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'pp_correct'::jsonb->>'success'='true' AND :'pp_move'::jsonb->>'success'='true'
 AND pg_temp.rc_rows(:'pp'::uuid,NULL,'monthly')=format('0-100@11.00/2.50/5 %s..%s | 0-100@14.00/2.50/5 %s..open',:'old_start',(:'d30'::date+4)::text,(:'d30'::date+5)::text),
 'F11 correct and move still work: '||:'pp_correct'||:'pp_move'||pg_temp.rc_rows(:'pp'::uuid,NULL,'monthly'));
-- new bands on the planned rate's day replace it when the editor listed it; a stop does not
SELECT id AS pp_planned FROM public.item_storage_prices WHERE item_id=:'pp'::uuid AND effective_from=(:'d30'::date+5) LIMIT 1 \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_call(format('SELECT public.replace_item_rates(%L,NULL,%L,%L,%L::jsonb,false,%L,NULL,%L::uuid[])',
  :'pp','monthly',(:'d30'::date+5)::text,jsonb_build_array(),'change',ARRAY[:'pp_planned'])) AS pp_stop_seen,
  pg_temp.rc_call(format('SELECT public.replace_item_rates(%L,NULL,%L,%L,%L::jsonb,false,%L,NULL,%L::uuid[])',
  :'pp','monthly',(:'d30'::date+5)::text,jsonb_build_array(pg_temp.rc_band(0,100,15)),'change',ARRAY[:'pp_planned'])) AS pp_change_seen \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'pp_stop_seen'::jsonb->>'error_code'='LATER_RATES_EXIST' AND :'pp_change_seen'::jsonb->>'success'='true'
 AND pg_temp.rc_rent(:'pp'::uuid,NULL,50,(:'d30'::date+6)::date)='15.00','F11 seen planned rate: stop refused, new bands replace: '||:'pp_stop_seen'||:'pp_change_seen');
-- with p_replace_later the planned rate is replaced
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'pp'::uuid,NULL,'monthly',(:'d30'::date+5),jsonb_build_array(pg_temp.rc_band(0,100,16)),true) AS pp_replace \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'pp_replace'::jsonb->>'success'='true' AND pg_temp.rc_rent(:'pp'::uuid,NULL,50,(:'d30'::date+6)::date)='16.00','F11 p_replace_later replaces it: '||:'pp_replace');

-- ---------------------------------------------------------------------------
-- 17. The India day, not the UTC day: 2026-04-01 00:30 India time is 2026-03-31 19:00 UTC.
-- now() cannot be frozen, so business_date is replaced for this transaction by a version that
-- reads the clock as that moment (rolled back at the end).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION warehouse_security.business_date(moment timestamptz) RETURNS date
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
  SELECT ((moment - (pg_catalog.now() - timestamptz '2026-03-31 19:00:00+00')) AT TIME ZONE 'Asia/Kolkata')::date $$;
SELECT pg_temp.rc_assert(warehouse_security.business_date(now())='2026-04-01'::date,'the emulated clock is 1 April in India: '||warehouse_security.business_date(now()));
-- Migration 90: the staff rules of the India day (a start today is allowed, yesterday is the past, a row
-- starting today is in force) are no longer reachable: the guard refuses staff before any date is read.
SELECT pg_temp.rc_rows(:'clockitem'::uuid,NULL,'monthly') AS clock_before \gset
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'clockitem'::uuid,NULL,'monthly','2026-04-01',jsonb_build_array(pg_temp.rc_band(0,100,13))) AS ist_today,
       pg_temp.rc_replace(:'clockitem'::uuid,NULL,'monthly','2026-03-31',jsonb_build_array(pg_temp.rc_band(0,100,13))) AS ist_yesterday,
       pg_temp.rc_call(format($q$SELECT public.create_item_storage_price(p_item_id=>%L::uuid,p_price_type=>'monthly',p_unit_price=>9,p_weight_min=>101,p_weight_max=>150,p_labour_rate=>2,p_effective_from=>'2026-04-01',p_customer_id=>%L::uuid,p_tax_percent=>5)$q$,:'garlic',:'north')) AS ist_create_today \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'ist_today'::jsonb->>'state'='42501' AND :'ist_yesterday'::jsonb->>'state'='42501'
 AND :'ist_create_today'::jsonb::text LIKE '%Staff access required%' AND COALESCE(:'ist_create_today'::jsonb->>'success','false')<>'true'
 AND pg_temp.rc_rows(:'clockitem'::uuid,NULL,'monthly')=:'clock_before',
 'at 00:30 India time staff are refused on 1 April and on 31 March alike: '||:'ist_today'||:'ist_yesterday'||:'ist_create_today');
-- A supervisor starts a rate on 1 April (the India day) as before.
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rc_replace(:'clockitem'::uuid,NULL,'monthly','2026-04-01',jsonb_build_array(pg_temp.rc_band(0,100,13))) AS ist_sup \gset
RESET ROLE;
SELECT pg_temp.rc_assert(:'ist_sup'::jsonb->>'success'='true' AND :'ist_sup'::jsonb#>>'{data,starts_on}'='2026-04-01','a supervisor starts a rate on 1 April: '||:'ist_sup');
ROLLBACK;

-- Migration 129, rates:
--   1. replace_item_rates, change mode: a later rate that has begun is refused (LATER_RATES_EXIST, begun = true) like a planned one,
--      unless p_replace_later; a change with nothing after it is saved.
--   2. request keys: replace_item_rates and set_standard_rate answer a resend of the same key with the first answer and write
--      nothing; a refusal and a dry run are not stored; another user or another start day is a real call; get_submission_result
--      finds the answer.
--   3. find_storage_price: an item's first default rate also covers every earlier day (a GRN dated before it is not missing a rate);
--      a later change and a customer's own rate start on their own day.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.r9_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'rate changes 129: %',label; END IF; END $$;
-- The jsonb answer of a call, or what it raised.
CREATE FUNCTION pg_temp.r9_call(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.r9_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.r9_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.r9_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
-- The rows of a scope as text, oldest start first: "0-100@6.00 2026-01-01..open".
CREATE FUNCTION pg_temp.r9_rows(p_item uuid, p_customer uuid, p_type text) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE(string_agg(r.weight_min||'-'||r.weight_max||'@'||r.unit_price
           ||' '||r.effective_from||'..'||COALESCE(r.effective_to::text,'open'), ' | ' ORDER BY r.effective_from, r.weight_min),'(none)')
  FROM public.item_storage_prices r
  WHERE r.item_id=p_item AND r.customer_id IS NOT DISTINCT FROM p_customer AND r.price_type=p_type $$;
CREATE FUNCTION pg_temp.r9_band(rent numeric) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',rent,'labour_rate',2.5,'tax_percent',5)) $$;
-- replace_item_rates by name, so the call does not depend on the position of the newer parameters.
CREATE FUNCTION pg_temp.r9_replace(p_item uuid, p_day date, p_bands jsonb, p_later boolean DEFAULT false, p_key text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.r9_call(format('SELECT public.replace_item_rates(p_item_id=>%L,p_customer_id=>NULL,p_price_type=>%L,p_starts_on=>%L,p_bands=>%L::jsonb,p_replace_later=>%L%s)',
    p_item,'monthly',p_day,p_bands,p_later,CASE WHEN p_key IS NULL THEN '' ELSE format(',p_request_key=>%L',p_key) END)) $$;
CREATE FUNCTION pg_temp.r9_rent(p_item uuid, p_weight integer, p_day date) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE((SELECT f.unit_price::text FROM public.find_storage_price(p_item,NULL,p_weight,p_day,'monthly') f WHERE f.id IS NOT NULL),'none') $$;

INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9666666601','Rate 129 Administrator') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919666666602','Rate 129 Supervisor','supervisor',true,'approved');
SELECT pg_temp.r9_login('9666666601') AS admin_claims \gset
SELECT pg_temp.r9_login('9666666602') AS supervisor_claims \gset
SELECT warehouse_security.business_date(now()) AS today, warehouse_security.business_date(now())-100 AS d_m100, warehouse_security.business_date(now())-150 AS d_m150,
       warehouse_security.business_date(now())-200 AS d_m200, warehouse_security.business_date(now())+30 AS d30 \gset

SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.r9_assert(public.create_item('Rate129 Onion','Bag')->>'success'='true'
 AND public.create_item('Rate129 Garlic','Bag')->>'success'='true','items');
RESET ROLE;
SELECT id AS onion FROM public.items WHERE name='Rate129 Onion' \gset
SELECT id AS garlic FROM public.items WHERE name='Rate129 Garlic' \gset
SELECT pg_temp.r9_assert(pg_temp.r9_rows(:'onion'::uuid,NULL,'monthly')='(none)' AND pg_temp.r9_rows(:'garlic'::uuid,NULL,'monthly')='(none)','the items start with no rate');

-- ---------------------------------------------------------------------------
-- 1. A later rate that has begun is never replaced silently
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.r9_replace(:'onion'::uuid,:'d_m200'::date,pg_temp.r9_band(6)) AS o1,
       pg_temp.r9_replace(:'onion'::uuid,:'d_m100'::date,pg_temp.r9_band(7)) AS o2 \gset
RESET ROLE;
SELECT pg_temp.r9_assert(:'o1'::jsonb->>'success'='true' AND :'o2'::jsonb->>'success'='true'
 AND pg_temp.r9_rows(:'onion'::uuid,NULL,'monthly')=format('0-100@6.00 %s..%s | 0-100@7.00 %s..open',:'d_m200',(:'d_m100'::date-1)::text,:'d_m100'),
 'set-up: 6.00 from 200 days ago, 7.00 (begun) from 100 days ago: '||pg_temp.r9_rows(:'onion'::uuid,NULL,'monthly'));
SELECT pg_temp.r9_rows(:'onion'::uuid,NULL,'monthly') AS onion_before, (SELECT count(*) FROM public.item_price_history) AS hist_before \gset
-- A change from 150 days ago has the begun 7.00 rate after it.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.r9_replace(:'onion'::uuid,:'d_m150'::date,pg_temp.r9_band(8)) AS refused,
       pg_temp.r9_replace(:'onion'::uuid,:'d_m150'::date,pg_temp.r9_band(8),NULL) AS refused_null_flag \gset
RESET ROLE;
SELECT pg_temp.r9_assert(:'refused'::jsonb->>'success'='false' AND :'refused'::jsonb->>'error_code'='LATER_RATES_EXIST'
 AND jsonb_array_length(:'refused'::jsonb#>'{data,later}')=1 AND (:'refused'::jsonb#>>'{data,later,0,effective_from}')=:'d_m100'
 AND (:'refused'::jsonb#>>'{data,later,0,unit_price}')::numeric=7 AND (:'refused'::jsonb#>>'{data,later,0,begun}')='true'
 AND :'refused_null_flag'::jsonb->>'error_code'='LATER_RATES_EXIST',
 'a later rate that has begun is refused and says it has begun: '||:'refused');
SELECT pg_temp.r9_assert(pg_temp.r9_rows(:'onion'::uuid,NULL,'monthly')=:'onion_before' AND (SELECT count(*) FROM public.item_price_history)=:'hist_before'::bigint,
 'nothing changed on the refusal');
-- A planned later rate says it has not begun.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.r9_replace(:'garlic'::uuid,:'d_m200'::date,pg_temp.r9_band(4)) AS g1,
       pg_temp.r9_replace(:'garlic'::uuid,:'d30'::date,pg_temp.r9_band(5)) AS g2,
       pg_temp.r9_replace(:'garlic'::uuid,:'today'::date,pg_temp.r9_band(4.5)) AS g_planned \gset
RESET ROLE;
SELECT pg_temp.r9_assert(:'g_planned'::jsonb->>'error_code'='LATER_RATES_EXIST' AND (:'g_planned'::jsonb#>>'{data,later,0,begun}')='false'
 AND (:'g_planned'::jsonb#>>'{data,later,0,effective_from}')=:'d30','a planned later rate is refused as before and has begun = false: '||:'g_planned');
-- The twin: with p_replace_later the begun rate is replaced.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.r9_replace(:'onion'::uuid,:'d_m150'::date,pg_temp.r9_band(8),true) AS replaced \gset
RESET ROLE;
SELECT pg_temp.r9_assert(:'replaced'::jsonb->>'success'='true' AND jsonb_array_length(:'replaced'::jsonb#>'{data,removed}')=1
 AND pg_temp.r9_rows(:'onion'::uuid,NULL,'monthly')=format('0-100@6.00 %s..%s | 0-100@8.00 %s..open',:'d_m200',(:'d_m150'::date-1)::text,:'d_m150'),
 'with p_replace_later the begun rate goes: '||:'replaced'||pg_temp.r9_rows(:'onion'::uuid,NULL,'monthly'));
-- The twin: nothing after the start day, no flag needed (a change from today on the rate that began 150 days ago).
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.r9_replace(:'onion'::uuid,:'today'::date,pg_temp.r9_band(9)) AS plain \gset
RESET ROLE;
SELECT pg_temp.r9_assert(:'plain'::jsonb->>'success'='true'
 AND pg_temp.r9_rows(:'onion'::uuid,NULL,'monthly')=format('0-100@6.00 %s..%s | 0-100@8.00 %s..%s | 0-100@9.00 %s..open',:'d_m200',(:'d_m150'::date-1)::text,:'d_m150',(:'today'::date-1)::text,:'today'),
 'a change with no later rate needs no flag: '||pg_temp.r9_rows(:'onion'::uuid,NULL,'monthly'));
-- ---------------------------------------------------------------------------
-- 2. Request keys
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_item('Rate129 Cumin','Bag')->>'success' AS cumin_made \gset
RESET ROLE;
SELECT id AS cumin FROM public.items WHERE name='Rate129 Cumin' \gset
SELECT pg_temp.r9_assert(:'cumin_made'='true' AND (SELECT count(*) FROM pg_proc WHERE proname='replace_item_rates' AND pronamespace='public'::regnamespace)=1
 AND (SELECT count(*) FROM pg_proc WHERE proname='set_standard_rate' AND pronamespace='public'::regnamespace)=1,
 'one overload of each rate function (the old signatures are gone)');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.r9_replace(:'cumin'::uuid,:'d_m200'::date,pg_temp.r9_band(3)) AS k0,
       pg_temp.r9_replace(:'cumin'::uuid,:'today'::date,pg_temp.r9_band(4),false,'r9-key-one') AS k1 \gset
RESET ROLE;
SELECT pg_temp.r9_assert(:'k0'::jsonb->>'success'='true' AND :'k1'::jsonb->>'success'='true','set-up and the first keyed save: '||:'k1');
-- Someone else changes the rate afterwards; the resend of the first save must not undo that.
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.r9_replace(:'cumin'::uuid,:'today'::date,pg_temp.r9_band(5)) AS k_other \gset
RESET ROLE;
SELECT pg_temp.r9_rows(:'cumin'::uuid,NULL,'monthly') AS cumin_k2, (SELECT count(*) FROM public.item_price_history) AS hist_k2 \gset
SELECT pg_temp.r9_assert(:'k_other'::jsonb->>'success'='true' AND :'cumin_k2' LIKE '%0-100@5.00 '||:'today'||'..open','set-up: the supervisor changed the rate to 5.00: '||:'cumin_k2');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.r9_replace(:'cumin'::uuid,:'today'::date,pg_temp.r9_band(4),false,'r9-key-one') AS k1_resend \gset
SELECT public.get_submission_result('r9-key-one') AS k1_found \gset
SELECT public.get_submission_result('r9-key-never-used') AS k_none \gset
RESET ROLE;
SELECT pg_temp.r9_assert(:'k1_resend'::jsonb=:'k1'::jsonb,'a resend of the same key returns the first answer as it was: '||:'k1_resend');
SELECT pg_temp.r9_assert(pg_temp.r9_rows(:'cumin'::uuid,NULL,'monthly')=:'cumin_k2' AND (SELECT count(*) FROM public.item_price_history)=:'hist_k2'::bigint,
 'the resend wrote nothing: '||pg_temp.r9_rows(:'cumin'::uuid,NULL,'monthly'));
SELECT pg_temp.r9_assert(:'k1_found'::jsonb->>'found'='true' AND (:'k1_found'::jsonb->'response')=:'k1'::jsonb AND :'k_none'::jsonb->>'found'='false',
 'get_submission_result finds the stored answer and nothing for an unknown key: '||:'k1_found');
-- Twins. No key: a real save. The same key for another start day: a real save. Another user's key: not replayed.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.r9_replace(:'cumin'::uuid,:'today'::date,pg_temp.r9_band(4)) AS no_key,
       pg_temp.r9_replace(:'cumin'::uuid,:'d30'::date,pg_temp.r9_band(7),false,'r9-key-one') AS key_other_day \gset
RESET ROLE;
SELECT pg_temp.r9_assert(:'no_key'::jsonb->>'success'='true' AND :'no_key'::jsonb<>:'k1'::jsonb
 AND :'key_other_day'::jsonb->>'success'='true' AND (:'key_other_day'::jsonb#>>'{data,starts_on}')=:'d30',
 'twins: no key saves, and the same key for another start day saves: '||:'no_key'||:'key_other_day');
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.r9_replace(:'cumin'::uuid,:'d30'::date,pg_temp.r9_band(8),true,'r9-key-one') AS other_user, public.get_submission_result('r9-key-one') AS other_user_found \gset
RESET ROLE;
SELECT pg_temp.r9_assert(:'other_user'::jsonb->>'success'='true' AND (:'other_user'::jsonb#>>'{data,added,0,unit_price}')::numeric=8 AND :'other_user_found'::jsonb->>'found'='false',
 'another user''s call with the key is a real call and sees no stored answer of the other user: '||:'other_user'||:'other_user_found');
-- A refusal is not stored: the same key works once the cause is gone.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.r9_replace(:'cumin'::uuid,:'today'::date,'[]'::jsonb||jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',-1,'labour_rate',2.5,'tax_percent',5)),false,'r9-key-two') AS refused,
       public.get_submission_result('r9-key-two') AS refused_found \gset
SELECT pg_temp.r9_replace(:'cumin'::uuid,:'today'::date,pg_temp.r9_band(2),true,'r9-key-two') AS retried \gset
RESET ROLE;
SELECT pg_temp.r9_assert(:'refused'::jsonb->>'success'='false' AND :'refused_found'::jsonb->>'found'='false' AND :'retried'::jsonb->>'success'='true',
 'a refusal is not stored under the key; the retry is a real save: '||:'refused'||:'retried');

-- set_standard_rate
SELECT jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',3,'labour_rate',1,'tax_percent',5)) AS std_a,
       jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',9,'labour_rate',1,'tax_percent',5)) AS std_b \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.r9_call(format('SELECT public.set_standard_rate(p_tiers=>%L::jsonb,p_request_key=>%L)',:'std_a','r9-std-one')) AS s1,
       pg_temp.r9_call(format('SELECT public.set_standard_rate(p_tiers=>%L::jsonb)',:'std_b')) AS s_other \gset
SELECT pg_temp.r9_call(format('SELECT public.set_standard_rate(p_tiers=>%L::jsonb,p_request_key=>%L)',:'std_a','r9-std-one')) AS s1_resend,
       public.get_submission_result('r9-std-one') AS s1_found,
       public.get_standard_rate() AS std_now \gset
RESET ROLE;
SELECT pg_temp.r9_assert(:'s1'::jsonb->>'success'='true' AND :'s_other'::jsonb->>'success'='true','set-up: standard rate saved with a key, then changed without: '||:'s1'||:'s_other');
SELECT pg_temp.r9_assert(:'s1_resend'::jsonb=:'s1'::jsonb AND (:'std_now'::jsonb#>>'{data,tiers,0,unit_price}')::numeric=9
 AND :'s1_found'::jsonb->>'found'='true' AND (:'s1_found'::jsonb->'response')=:'s1'::jsonb,
 'the standard rate: a resend returns the first answer, writes nothing (9.00 stays) and is found by get_submission_result: '||:'s1_resend'||:'std_now');
-- A dry run with a key is a real (counting) call and stores nothing; the same key then saves for real.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.r9_call(format('SELECT public.set_standard_rate(p_tiers=>%L::jsonb,p_dry_run=>true,p_request_key=>%L)',:'std_a','r9-std-two')) AS dry,
       pg_temp.r9_call(format('SELECT public.set_standard_rate(p_tiers=>%L::jsonb,p_request_key=>%L)',:'std_a','r9-std-two')) AS real_save \gset
RESET ROLE;
SELECT pg_temp.r9_assert(:'dry'::jsonb#>>'{data,dry_run}'='true' AND :'real_save'::jsonb#>>'{data,dry_run}'='false' AND :'real_save'::jsonb->>'success'='true',
 'a dry run stores nothing under the key: '||:'dry'||:'real_save');
-- ---------------------------------------------------------------------------
-- 3. An item's first rate also covers every earlier day
-- ---------------------------------------------------------------------------
SELECT warehouse_security.business_date(now())-300 AS d_m300, warehouse_security.business_date(now())-50 AS d_m50, warehouse_security.business_date(now())-40 AS d_m40 \gset
-- Section 2 saved a standard rate, which a new item would be priced from: clear it, so that these items start with no rate.
DELETE FROM public.standard_rate_tiers;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_item('Rate129 Fennel','Bag')->>'success' AS fennel_made, public.create_item('Rate129 Unpriced','Bag')->>'success' AS unpriced_made,
       public.create_customer('Rate129 North Orchard','9666666611')->>'success' AS north_made \gset
RESET ROLE;
SELECT id AS fennel FROM public.items WHERE name='Rate129 Fennel' \gset
SELECT id AS unpriced FROM public.items WHERE name='Rate129 Unpriced' \gset
SELECT id AS north FROM public.customers WHERE name='Rate129 North Orchard' \gset
SELECT pg_temp.r9_assert(:'fennel_made'='true' AND :'unpriced_made'='true' AND :'north_made'='true','fixture: items and a customer');
-- A GRN of the item dated 300 days ago, checked for rates ([] = check only): before the item has any rate it is RATE_MISSING.
CREATE FUNCTION pg_temp.r9_grn(p_no text, p_item uuid, p_name text, p_day date, p_customer uuid) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.r9_call(format($q$SELECT public.save_grn(p_gr_no=>%L,p_date=>%L::timestamptz,p_customer_id=>%L::uuid,p_customer_name=>'Rate129 North Orchard',
    p_pricing_mode=>'MONTHLY',p_rates=>'[]'::jsonb,p_items=>jsonb_build_array(jsonb_build_object('item_id',%L::uuid,'item_name',%L,'packaging','Bag','qty',5,'weight',10)))$q$,
    p_no,p_day::text||'T12:00:00Z',p_customer,p_item,p_name)) $$;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.r9_grn('R129A',:'fennel'::uuid,'Rate129 Fennel',:'d_m300'::date,:'north'::uuid) AS grn_before \gset
RESET ROLE;
SELECT pg_temp.r9_assert(:'grn_before'::jsonb->>'error_code'='RATE_MISSING' AND (SELECT count(*)=0 FROM public.goodsreceived WHERE gr_no='R129A'),
 'twin: an item with no rate at all still makes a GRN RATE_MISSING: '||:'grn_before');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.r9_replace(:'fennel'::uuid,:'d_m200'::date,pg_temp.r9_band(6)) AS f1,
       pg_temp.r9_replace(:'fennel'::uuid,:'d_m100'::date,pg_temp.r9_band(7)) AS f2,
       pg_temp.r9_call(format('SELECT public.replace_item_rates(p_item_id=>%L,p_customer_id=>%L,p_price_type=>%L,p_starts_on=>%L,p_bands=>%L::jsonb)',
         :'fennel',:'north','monthly',:'d_m50',jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',4,'labour_rate',1,'tax_percent',5)))) AS f_cust \gset
RESET ROLE;
SELECT pg_temp.r9_assert(:'f1'::jsonb->>'success'='true' AND :'f2'::jsonb->>'success'='true' AND :'f_cust'::jsonb->>'success'='true','fixture: 6.00 from 200 days ago, 7.00 from 100 days ago, 4.00 for North from 50 days ago: '||:'f_cust');
SELECT pg_temp.r9_assert(pg_temp.r9_rent(:'fennel'::uuid,50,:'d_m300'::date)='6.00' AND pg_temp.r9_rent(:'fennel'::uuid,50,(:'d_m200'::date-1))='6.00'
 AND pg_temp.r9_rent(:'fennel'::uuid,50,:'d_m200'::date)='6.00' AND pg_temp.r9_rent(:'fennel'::uuid,50,:'d_m150'::date)='6.00',
 'before and on its first day the first rate applies (6.00)');
SELECT pg_temp.r9_assert(pg_temp.r9_rent(:'fennel'::uuid,50,:'d_m100'::date)='7.00' AND pg_temp.r9_rent(:'fennel'::uuid,50,(:'d_m100'::date-1))='6.00'
 AND pg_temp.r9_rent(:'fennel'::uuid,50,:'today'::date)='7.00','a later change starts on its own day only (7.00 from 100 days ago, 6.00 the day before)');
SELECT pg_temp.r9_assert(pg_temp.r9_rent(:'unpriced'::uuid,50,:'d_m300'::date)='none' AND pg_temp.r9_rent(:'unpriced'::uuid,50,:'today'::date)='none',
 'twin: an item with no rate has none on any day');
SELECT pg_temp.r9_assert((SELECT f.unit_price::text FROM public.find_storage_price(:'fennel'::uuid,:'north'::uuid,50,:'d_m300'::date,'monthly') f)='6.00'
 AND (SELECT f.unit_price::text FROM public.find_storage_price(:'fennel'::uuid,:'north'::uuid,50,:'d_m40'::date,'monthly') f)='4.00'
 AND (SELECT f.unit_price::text FROM public.find_storage_price(:'fennel'::uuid,:'north'::uuid,50,:'d_m100'::date,'monthly') f)='7.00',
 'a customer''s own rate does not reach back: North gets the default before its day (6.00, 7.00) and its own 4.00 after');
SELECT pg_temp.r9_assert(NOT EXISTS (SELECT 1 FROM public.find_storage_price(:'fennel'::uuid,NULL,50,:'d_m300'::date,'one_time') f WHERE f.id IS NOT NULL),
 'twin: the monthly rate does not cover a one-time lookup');
-- The GRN of 300 days ago now needs no rate to be added, and no rate row was written for it.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.r9_grn('R129A',:'fennel'::uuid,'Rate129 Fennel',:'d_m300'::date,:'north'::uuid) AS grn_after \gset
RESET ROLE;
SELECT pg_temp.r9_assert(:'grn_after'::jsonb->>'success'='true' AND (SELECT count(*)=1 FROM public.goodsreceived WHERE gr_no='R129A')
 AND pg_temp.r9_rows(:'fennel'::uuid,NULL,'monthly')=format('0-100@6.00 %s..%s | 0-100@7.00 %s..open',:'d_m200',(:'d_m100'::date-1)::text,:'d_m100'),
 'a GRN dated before the first rate is saved with no missing rate, and the item''s rows are untouched: '||:'grn_after'||pg_temp.r9_rows(:'fennel'::uuid,NULL,'monthly'));
ROLLBACK;

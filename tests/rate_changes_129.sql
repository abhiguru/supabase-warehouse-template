-- Migration 129, rates:
--   1. replace_item_rates, change mode: a later rate that has begun is refused (LATER_RATES_EXIST, begun = true) like a planned one,
--      unless p_replace_later; a change with nothing after it is saved.
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
ROLLBACK;

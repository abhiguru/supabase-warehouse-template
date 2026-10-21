-- Migration 85 (2026-10-15): the facility's standard rate. get_standard_rate, set_standard_rate
-- (validation, roles, the backfill of active items without a default rate from their first GRN's
-- India day), create_item (standard tiers, copy from another item, rate_source, the old four
-- arguments), update_item (reactivation) and the history rows' author.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.sr_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'standard rate: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.sr_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.sr_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.sr_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
-- The jsonb answer of a statement run as the signed-in caller, or what it raised.
CREATE FUNCTION pg_temp.sr_as(claims jsonb, statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',claims::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN answer := jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  EXECUTE 'RESET ROLE';
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.sr_set(claims jsonb, tiers text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.sr_as(claims, format('SELECT public.set_standard_rate(%L::jsonb)', tiers)) $$;
-- "0-10@3.00/1.00/5 2026-03-02..open | 11-20@..." per scope, oldest start first.
CREATE FUNCTION pg_temp.sr_rows(p_item uuid, p_customer uuid, p_type text DEFAULT 'monthly') RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(string_agg(r.weight_min||'-'||r.weight_max||'@'||r.unit_price||'/'||r.labour_rate||'/'||trim_scale(r.tax_percent)
           ||' '||r.effective_from||'..'||COALESCE(r.effective_to::text,'open'), ' | ' ORDER BY r.effective_from, r.weight_min),'(none)')
  FROM public.item_storage_prices r
  WHERE r.item_id=p_item AND r.customer_id IS NOT DISTINCT FROM p_customer AND r.price_type=p_type $$;
CREATE FUNCTION pg_temp.sr_item(p_name text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM public.items WHERE name=p_name $$;
CREATE FUNCTION pg_temp.sr_unpriced() RETURNS integer LANGUAGE sql AS $$
  SELECT count(*)::int FROM public.items i WHERE i.active
   AND NOT EXISTS (SELECT 1 FROM public.item_storage_prices r WHERE r.item_id=i.id AND r.customer_id IS NULL) $$;

INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9777777801','Standard Rate Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919777777802','Standard Rate Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919777777803','Standard Rate Staff','staff',true,'approved'),
 (gen_random_uuid(),'919777777804','Standard Rate Customer','customer',true,'approved');
SELECT id AS supervisor_profile FROM public.user_profiles WHERE mobile='919777777802' \gset
SELECT pg_temp.sr_login('9777777801') AS admin_claims \gset
SELECT pg_temp.sr_login('9777777802') AS supervisor_claims \gset
SELECT pg_temp.sr_login('9777777803') AS staff_claims \gset
SELECT pg_temp.sr_login('9777777804') AS customer_claims \gset
SELECT warehouse_security.business_date(now()) AS today, warehouse_security.business_date(now())-1 AS yesterday,
       warehouse_security.business_date(now())+10 AS d10, warehouse_security.business_date(now())-100 AS d100 \gset

-- ---------------------------------------------------------------------------
-- 1. The surface
-- ---------------------------------------------------------------------------
SELECT pg_temp.sr_assert((SELECT count(*)=1 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='create_item')
 AND has_function_privilege('authenticated','public.create_item(character varying,character varying,character varying,boolean,uuid)','EXECUTE')
 AND has_function_privilege('service_role','public.create_item(character varying,character varying,character varying,boolean,uuid)','EXECUTE')
 AND NOT has_function_privilege('anon','public.create_item(character varying,character varying,character varying,boolean,uuid)','EXECUTE'),
 'create_item has one overload (five arguments) with the same grants');
SELECT pg_temp.sr_assert(bool_and(has_function_privilege('authenticated',f,'EXECUTE') AND has_function_privilege('service_role',f,'EXECUTE')
   AND NOT has_function_privilege('anon',f,'EXECUTE'))
 AND bool_and(pg_get_functiondef(f::regprocedure) ~ 'BEGIN\s+PERFORM warehouse_security\.authorize_rpc\(''(get|set)_standard_rate''')
 AND bool_and(prosecdef), 'the new functions are granted and guarded')
 FROM (SELECT 'public.get_standard_rate()'::regprocedure AS f UNION ALL SELECT 'public.set_standard_rate(jsonb,timestamptz,boolean)'::regprocedure) q
 JOIN pg_proc p ON p.oid=q.f;
SELECT pg_temp.sr_assert((SELECT relrowsecurity FROM pg_class WHERE oid='public.standard_rate_tiers'::regclass)
 AND NOT has_table_privilege('authenticated','public.standard_rate_tiers','INSERT')
 AND NOT has_table_privilege('authenticated','public.standard_rate_tiers','UPDATE')
 AND NOT has_table_privilege('authenticated','public.standard_rate_tiers','DELETE')
 AND NOT has_table_privilege('authenticated','public.standard_rate_tiers','TRUNCATE')
 AND NOT has_table_privilege('authenticated','public.standard_rate_tiers','SELECT')
 AND NOT has_table_privilege('anon','public.standard_rate_tiers','SELECT')
 AND (SELECT count(*)=0 FROM pg_policies WHERE schemaname='public' AND tablename='standard_rate_tiers'),
 'the table has row level security, no policy and no app-role privilege (migration 123)');

-- ---------------------------------------------------------------------------
-- 2. Fixtures (before any standard rate is saved)
-- ---------------------------------------------------------------------------
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,$q$SELECT public.create_customer('Standard Rate Orchard','9777777811')$q$) AS made_customer \gset
SELECT pg_temp.sr_assert(:'made_customer'::jsonb->>'success'='true','customer: '||:'made_customer');
SELECT id AS orchard FROM public.customers WHERE name='Standard Rate Orchard' \gset
-- The old four-argument call, by name and by position, still works and gives no rate.
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,$q$SELECT public.create_item(p_name=>'SR Plain',p_packaging=>'Bag')$q$) AS made_plain \gset
SELECT pg_temp.sr_assert(:'made_plain'::jsonb->>'success'='true' AND :'made_plain'::jsonb#>>'{data,rate_source}'='none'
 AND :'made_plain'::jsonb#>>'{data,name}'='SR Plain' AND :'made_plain'::jsonb#>>'{data,active}'='true','old named call: '||:'made_plain');
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('SR Grn','Bag','by position',true)$q$) AS made_grn \gset
SELECT pg_temp.sr_assert(:'made_grn'::jsonb#>>'{data,rate_source}'='none' AND :'made_grn'::jsonb#>>'{data,description}'='by position','old positional call: '||:'made_grn');
SELECT pg_temp.sr_assert((SELECT count(*)=0 FROM public.item_storage_prices WHERE item_id IN (pg_temp.sr_item('SR Plain'),pg_temp.sr_item('SR Grn'))),
 'no standard rate saved: no rows');
SELECT pg_temp.sr_assert(pg_temp.sr_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('SR Deleted Grn','Bag')$q$)->>'success'='true'
 AND pg_temp.sr_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('SR Ended','Bag')$q$)->>'success'='true'
 AND pg_temp.sr_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('SR Customer Only','Bag')$q$)->>'success'='true'
 AND pg_temp.sr_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('SR Source','Bag')$q$)->>'success'='true'
 AND pg_temp.sr_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('SR Inactive','Bag',NULL,false)$q$)->>'success'='true'
 AND pg_temp.sr_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('SR Inactive Ended','Bag',NULL,false)$q$)->>'success'='true'
 AND pg_temp.sr_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('SR Early','Bag',NULL,false)$q$)->>'success'='true','more items');
-- First GRN of SR Grn: 2026-03-01 20:00 UTC is 2026-03-02 in India; a later GRN and a deleted earlier GRN
-- must not change the start. SR Deleted Grn has only a deleted GRN: starts today.
INSERT INTO public.goodsreceived(id,gr_no,date,customer_id,customer_name,deleted_at) VALUES
 ('44440000-0000-4000-8000-000000000001','SRG1','2026-05-01 10:00+00',:'orchard'::uuid,'Standard Rate Orchard',NULL),
 ('44440000-0000-4000-8000-000000000002','SRG2','2026-03-01 20:00+00',:'orchard'::uuid,'Standard Rate Orchard',NULL),
 ('44440000-0000-4000-8000-000000000003','SRG3','2026-01-10 10:00+00',:'orchard'::uuid,'Standard Rate Orchard',now()),
 ('44440000-0000-4000-8000-000000000004','SRG4','2026-01-11 10:00+00',:'orchard'::uuid,'Standard Rate Orchard',now());
INSERT INTO public.goodsreceived_trl(id,gr_id,item_id,item_name,packaging,qty,stock,weight,rack,package_mark) VALUES
 ('55550000-0000-4000-8000-000000000001','44440000-0000-4000-8000-000000000001',pg_temp.sr_item('SR Grn'),'SR Grn','Bag',1,1,10,'R1','A'),
 ('55550000-0000-4000-8000-000000000002','44440000-0000-4000-8000-000000000002',pg_temp.sr_item('SR Grn'),'SR Grn','Bag',1,1,10,'R1','B'),
 ('55550000-0000-4000-8000-000000000003','44440000-0000-4000-8000-000000000003',pg_temp.sr_item('SR Grn'),'SR Grn','Bag',1,1,10,'R1','C'),
 ('55550000-0000-4000-8000-000000000004','44440000-0000-4000-8000-000000000004',pg_temp.sr_item('SR Deleted Grn'),'SR Deleted Grn','Bag',1,1,10,'R1','D');
-- Default rows: SR Ended ended yesterday (and nothing else); SR Inactive Ended the same;
-- SR Customer Only has a customer row only; SR Source has the rows the copy tests read.
INSERT INTO public.item_storage_prices(item_id,customer_id,price_type,unit_price,weight_min,weight_max,labour_rate,tax_percent,effective_from,effective_to,unit_price_one_time,unit_price_monthly) VALUES
 (pg_temp.sr_item('SR Ended'),NULL,'monthly',8,0,100,1,5,:'d100',:'yesterday',0,8),
 (pg_temp.sr_item('SR Inactive Ended'),NULL,'monthly',8,0,100,1,5,:'d100',:'yesterday',0,8),
 (pg_temp.sr_item('SR Customer Only'),:'orchard'::uuid,'monthly',9,0,100,1,5,:'d100',NULL,0,9),
 (pg_temp.sr_item('SR Source'),NULL,'monthly',4,0,10,1.5,5,:'d100',NULL,0,4),
 (pg_temp.sr_item('SR Source'),NULL,'monthly',5,11,50,2,12,:'d100',NULL,0,5),
 (pg_temp.sr_item('SR Source'),NULL,'one_time',30,0,50,0,18,:'d100',NULL,30,0),
 (pg_temp.sr_item('SR Source'),:'orchard'::uuid,'monthly',99,0,50,1,5,:'d100',NULL,0,99),
 (pg_temp.sr_item('SR Source'),NULL,'monthly',77,51,60,1,5,:'d100',:'yesterday',0,77),
 (pg_temp.sr_item('SR Source'),NULL,'monthly',88,0,100,1,5,:'d10',NULL,0,88);
-- Reactivating an item before any standard rate is saved gives it nothing.
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,format($q$SELECT public.update_item(%L::uuid,'SR Early','Bag',NULL,true)$q$,pg_temp.sr_item('SR Early'))) AS early_on \gset
SELECT pg_temp.sr_assert(:'early_on'::jsonb->>'success'='true' AND (SELECT active FROM public.items WHERE name='SR Early')
 AND pg_temp.sr_rows(pg_temp.sr_item('SR Early'),NULL)='(none)','reactivation without a standard rate adds nothing: '||pg_temp.sr_rows(pg_temp.sr_item('SR Early'),NULL));
SELECT pg_temp.sr_unpriced() AS unpriced_before \gset
SELECT pg_temp.sr_assert(:unpriced_before >= 4,'the fixtures leave at least four active items without a default row: '||:unpriced_before);

-- ---------------------------------------------------------------------------
-- 3. get_standard_rate before any save; roles
-- ---------------------------------------------------------------------------
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,'SELECT public.get_standard_rate()') AS got_empty \gset
SELECT pg_temp.sr_assert(:'got_empty'::jsonb->>'success'='true' AND :'got_empty'::jsonb#>'{data,tiers}'='[]'::jsonb
 AND :'got_empty'::jsonb#>'{data,updated_at}'='null'::jsonb AND :'got_empty'::jsonb#>'{data,updated_by_name}'='null'::jsonb,'never saved: '||:'got_empty');
SELECT pg_temp.sr_assert(pg_temp.sr_as(:'supervisor_claims'::jsonb,'SELECT public.get_standard_rate()')->>'success'='true','a supervisor reads it');
-- Migration 90 (owner decision, 2026-10-16): staff no longer read it (migration 85 admitted them).
SELECT pg_temp.sr_as(:'staff_claims'::jsonb,'SELECT public.get_standard_rate()') AS staff_get \gset
SELECT pg_temp.sr_assert(:'staff_get'::jsonb->>'state'='42501' AND :'staff_get'::jsonb->>'raised'='Staff access required','a staff account is refused get_standard_rate: '||:'staff_get');
SELECT pg_temp.sr_as(:'customer_claims'::jsonb,'SELECT public.get_standard_rate()') AS cust_get \gset
SELECT pg_temp.sr_assert(:'cust_get'::jsonb->>'state'='42501','a customer account is refused get_standard_rate: '||:'cust_get');
SELECT pg_temp.sr_set(:'customer_claims'::jsonb,'[{"weight_min":0,"weight_max":10,"unit_price":3,"labour_rate":1,"tax_percent":5}]') AS cust_set \gset
SELECT pg_temp.sr_assert(:'cust_set'::jsonb->>'state'='42501','a customer account is refused set_standard_rate: '||:'cust_set');
SELECT pg_temp.sr_set(:'staff_claims'::jsonb,'[{"weight_min":0,"weight_max":10,"unit_price":3,"labour_rate":1,"tax_percent":5}]') AS staff_set \gset
-- Migration 90: refused by the guard now; the body's STANDARD_RATE_MANAGER_ONLY answer is unreachable.
SELECT pg_temp.sr_assert(:'staff_set'::jsonb->>'state'='42501' AND :'staff_set'::jsonb->>'raised'='Staff access required','staff are refused set_standard_rate: '||:'staff_set');
SELECT pg_temp.sr_assert((SELECT count(*)=0 FROM public.standard_rate_tiers) AND pg_temp.sr_unpriced()=:unpriced_before,'the refusals changed nothing');

-- ---------------------------------------------------------------------------
-- 4. Validation (as the administrator): each refusal, nothing written
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.sr_refused(tiers text, code text, index_expected integer DEFAULT NULL, field_expected text DEFAULT NULL, min_expected integer DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE a jsonb := pg_temp.sr_as(current_setting('sr.admin_claims')::jsonb, format('SELECT public.set_standard_rate(%L::jsonb)', tiers));
BEGIN
  IF a->>'success' IS DISTINCT FROM 'false' OR a->>'error_code' IS DISTINCT FROM code
     OR (index_expected IS NOT NULL AND (a#>>'{data,index}')::int IS DISTINCT FROM index_expected)
     OR (field_expected IS NOT NULL AND a#>>'{data,field}' IS DISTINCT FROM field_expected)
     OR (min_expected IS NOT NULL AND (a#>>'{data,expected_min}')::int IS DISTINCT FROM min_expected)
     OR a->>'error' IS NULL THEN
    RETURN tiers||' -> '||a::text;
  END IF;
  RETURN NULL;
END $$;
SELECT set_config('sr.admin_claims',:'admin_claims',false);
SELECT pg_temp.sr_assert(bad IS NULL, 'validation: '||bad) FROM (SELECT string_agg(r, '; ') AS bad FROM (VALUES
 (pg_temp.sr_refused('{}','INVALID_BANDS')),
 (pg_temp.sr_refused('[]','INVALID_BANDS')),
 (pg_temp.sr_refused('"x"','INVALID_BANDS')),
 (pg_temp.sr_refused((SELECT jsonb_agg(jsonb_build_object('weight_min',n*10,'weight_max',n*10+9,'unit_price',1,'labour_rate',1,'tax_percent',5))::text FROM generate_series(0,10) n),'INVALID_BANDS')),
 (pg_temp.sr_refused('[1]','INVALID_BAND',0)),
 (pg_temp.sr_refused('[{"weight_max":10,"unit_price":3,"labour_rate":1,"tax_percent":5}]','INVALID_BAND',0,'weight_min')),
 (pg_temp.sr_refused('[{"weight_min":0,"weight_max":"10","unit_price":3,"labour_rate":1,"tax_percent":5}]','INVALID_BAND',0,'weight_max')),
 (pg_temp.sr_refused('[{"weight_min":0,"weight_max":10.5,"unit_price":3,"labour_rate":1,"tax_percent":5}]','INVALID_BAND',0,'weight_max')),
 (pg_temp.sr_refused('[{"weight_min":-1,"weight_max":10,"unit_price":3,"labour_rate":1,"tax_percent":5}]','INVALID_BAND',0,'weight_min')),
 (pg_temp.sr_refused('[{"weight_min":0,"weight_max":100001,"unit_price":3,"labour_rate":1,"tax_percent":5}]','INVALID_BAND',0,'weight_max')),
 (pg_temp.sr_refused('[{"weight_min":0,"weight_max":10,"unit_price":3,"labour_rate":1,"tax_percent":5},{"weight_min":20,"weight_max":11,"unit_price":3,"labour_rate":1,"tax_percent":5}]','INVALID_BAND',1)),
 (pg_temp.sr_refused('[{"weight_min":0,"weight_max":10,"labour_rate":1,"tax_percent":5}]','INVALID_AMOUNT',0,'unit_price')),
 (pg_temp.sr_refused('[{"weight_min":0,"weight_max":10,"unit_price":3,"tax_percent":5}]','INVALID_AMOUNT',0,'labour_rate')),
 (pg_temp.sr_refused('[{"weight_min":0,"weight_max":10,"unit_price":3,"labour_rate":1}]','INVALID_AMOUNT',0,'tax_percent')),
 (pg_temp.sr_refused('[{"weight_min":0,"weight_max":10,"unit_price":3.001,"labour_rate":1,"tax_percent":5}]','INVALID_AMOUNT',0,'unit_price')),
 (pg_temp.sr_refused('[{"weight_min":0,"weight_max":10,"unit_price":3,"labour_rate":1000000,"tax_percent":5}]','INVALID_AMOUNT',0,'labour_rate')),
 (pg_temp.sr_refused('[{"weight_min":0,"weight_max":10,"unit_price":-1,"labour_rate":1,"tax_percent":5}]','INVALID_AMOUNT',0,'unit_price')),
 (pg_temp.sr_refused('[{"weight_min":0,"weight_max":10,"unit_price":3,"labour_rate":1,"tax_percent":100.01}]','INVALID_AMOUNT',0,'tax_percent')),
 (pg_temp.sr_refused('[{"weight_min":0,"weight_max":10,"unit_price":3,"labour_rate":1,"tax_percent":5},{"weight_min":10,"weight_max":20,"unit_price":3,"labour_rate":1,"tax_percent":5}]','BANDS_OVERLAP',1)),
 (pg_temp.sr_refused('[{"weight_min":0,"weight_max":10,"unit_price":3,"labour_rate":1,"tax_percent":5},{"weight_min":12,"weight_max":20,"unit_price":3,"labour_rate":1,"tax_percent":5}]','BANDS_GAP',1,NULL,11)),
 (pg_temp.sr_refused('[{"weight_min":1,"weight_max":10,"unit_price":3,"labour_rate":1,"tax_percent":5}]','BANDS_GAP',0,NULL,0))
) v(r) WHERE r IS NOT NULL) q;
SELECT pg_temp.sr_assert(pg_temp.sr_as(:'admin_claims'::jsonb,'SELECT public.set_standard_rate(NULL)')->>'error_code'='INVALID_BANDS','NULL tiers');
SELECT pg_temp.sr_assert((SELECT count(*)=0 FROM public.standard_rate_tiers) AND pg_temp.sr_unpriced()=:unpriced_before
 AND (SELECT count(*)=0 FROM public.item_storage_prices WHERE item_id=pg_temp.sr_item('SR Plain')),'the refused calls wrote nothing');

-- ---------------------------------------------------------------------------
-- 5. The first save: tiers (given out of order), backfill
-- ---------------------------------------------------------------------------
SELECT pg_temp.sr_set(:'admin_claims'::jsonb,'[{"weight_min":11,"weight_max":20,"unit_price":4,"labour_rate":1.5,"tax_percent":5},{"weight_min":0,"weight_max":10,"unit_price":3,"labour_rate":1,"tax_percent":5},{"weight_min":21,"weight_max":30,"unit_price":5,"labour_rate":2,"tax_percent":5.5}]') AS save1 \gset
SELECT pg_temp.sr_assert(:'save1'::jsonb->>'success'='true' AND (:'save1'::jsonb#>>'{data,items_priced}')::int=:unpriced_before
 AND jsonb_array_length(:'save1'::jsonb#>'{data,tiers}')=3 AND :'save1'::jsonb#>>'{data,tiers,0,weight_min}'='0'
 AND :'save1'::jsonb#>>'{data,tiers,2,tax_percent}'='5.50','first save answer, items_priced = '||:unpriced_before||': '||:'save1');
SELECT pg_temp.sr_as(:'supervisor_claims'::jsonb,'SELECT public.get_standard_rate()') AS got1 \gset
SELECT pg_temp.sr_assert(:'got1'::jsonb#>'{data,tiers,0}'='{"weight_min": 0, "weight_max": 10, "unit_price": 3, "labour_rate": 1, "tax_percent": 5}'::jsonb
 AND :'got1'::jsonb#>>'{data,tiers,1,weight_min}'='11' AND :'got1'::jsonb#>>'{data,tiers,2,unit_price}'='5.00'
 AND jsonb_array_length(:'got1'::jsonb#>'{data,tiers}')=3 AND :'got1'::jsonb#>>'{data,updated_by_name}'='Standard Rate Administrator'
 AND (:'got1'::jsonb#>>'{data,updated_at}')::timestamptz > now() - interval '5 minutes','get_standard_rate returns the tiers ordered, saved by the administrator: '||:'got1');
-- Backfill: SR Grn from the India day of its first non-deleted GRN (2026-03-02, not 03-01, not the deleted 01-10, not 05-01).
SELECT pg_temp.sr_assert(pg_temp.sr_rows(pg_temp.sr_item('SR Grn'),NULL)=
 '0-10@3.00/1.00/5 2026-03-02..open | 11-20@4.00/1.50/5 2026-03-02..open | 21-30@5.00/2.00/5.5 2026-03-02..open','SR Grn starts on its first GRN India day: '||pg_temp.sr_rows(pg_temp.sr_item('SR Grn'),NULL));
SELECT pg_temp.sr_assert(pg_temp.sr_rows(pg_temp.sr_item('SR Plain'),NULL)=format('0-10@3.00/1.00/5 %1$s..open | 11-20@4.00/1.50/5 %1$s..open | 21-30@5.00/2.00/5.5 %1$s..open',:'today'),
 'an item with no GRN starts today: '||pg_temp.sr_rows(pg_temp.sr_item('SR Plain'),NULL));
SELECT pg_temp.sr_assert(pg_temp.sr_rows(pg_temp.sr_item('SR Deleted Grn'),NULL)=format('0-10@3.00/1.00/5 %1$s..open | 11-20@4.00/1.50/5 %1$s..open | 21-30@5.00/2.00/5.5 %1$s..open',:'today'),
 'an item whose only GRN is deleted starts today: '||pg_temp.sr_rows(pg_temp.sr_item('SR Deleted Grn'),NULL));
SELECT pg_temp.sr_assert(pg_temp.sr_rows(pg_temp.sr_item('SR Early'),NULL)=format('0-10@3.00/1.00/5 %1$s..open | 11-20@4.00/1.50/5 %1$s..open | 21-30@5.00/2.00/5.5 %1$s..open',:'today'),
 'an item reactivated before the save is priced by it');
SELECT pg_temp.sr_assert(pg_temp.sr_rows(pg_temp.sr_item('SR Customer Only'),NULL)=format('0-10@3.00/1.00/5 %1$s..open | 11-20@4.00/1.50/5 %1$s..open | 21-30@5.00/2.00/5.5 %1$s..open',:'today')
 AND pg_temp.sr_rows(pg_temp.sr_item('SR Customer Only'),:'orchard'::uuid)=format('0-100@9.00/1.00/5 %s..open',:'d100'),
 'an item with customer rates only gets the default tiers and keeps the customer row: '||pg_temp.sr_rows(pg_temp.sr_item('SR Customer Only'),NULL));
SELECT pg_temp.sr_assert(pg_temp.sr_rows(pg_temp.sr_item('SR Ended'),NULL)=format('0-100@8.00/1.00/5 %s..%s',:'d100',:'yesterday')
 AND pg_temp.sr_rows(pg_temp.sr_item('SR Inactive Ended'),NULL)=format('0-100@8.00/1.00/5 %s..%s',:'d100',:'yesterday'),
 'an item with only an ended default row is untouched: '||pg_temp.sr_rows(pg_temp.sr_item('SR Ended'),NULL));
SELECT pg_temp.sr_assert(pg_temp.sr_rows(pg_temp.sr_item('SR Inactive'),NULL)='(none)','an inactive item is untouched');
SELECT pg_temp.sr_assert(pg_temp.sr_unpriced()=0,'no active item is left without a default row');
-- History rows carry the caller.
SELECT pg_temp.sr_assert((SELECT count(*)=3 AND bool_and(h.changed_by=:'admin_profile'::uuid AND h.changed_by_name='Standard Rate Administrator'
    AND h.changed_by_role='admin' AND h.action='insert' AND h.item_name='SR Grn')
  FROM public.item_price_history h WHERE h.item_id=pg_temp.sr_item('SR Grn')),'the history rows of the backfill name the administrator');
SELECT pg_temp.sr_assert((SELECT bool_and(r.created_by=:'admin_profile'::uuid AND r.unit_price_one_time=0 AND r.unit_price_monthly=r.unit_price
    AND r.price_type='monthly' AND r.customer_id IS NULL) FROM public.item_storage_prices r WHERE r.item_id=pg_temp.sr_item('SR Grn')),
 'the rows are monthly default rows created by the administrator');

-- Direct access: no write, and no app role reads the table (migration 123); the rate is read through get_standard_rate.
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,$q$SELECT to_jsonb(count(*)) FROM public.standard_rate_tiers$q$) AS admin_reads \gset
SELECT pg_temp.sr_as(:'staff_claims'::jsonb,$q$SELECT to_jsonb(count(*)) FROM public.standard_rate_tiers$q$) AS staff_reads \gset
SELECT pg_temp.sr_as(:'customer_claims'::jsonb,$q$SELECT to_jsonb(count(*)) FROM public.standard_rate_tiers$q$) AS customer_reads \gset
SELECT pg_temp.sr_assert(:'admin_reads'::jsonb->>'state'='42501' AND :'staff_reads'::jsonb->>'state'='42501' AND :'customer_reads'::jsonb->>'state'='42501',
 'direct reads are refused for administrator, staff and customer: '||:'admin_reads'||'/'||:'staff_reads'||'/'||:'customer_reads');
SELECT pg_temp.sr_assert(pg_temp.sr_as(:'admin_claims'::jsonb,$q$WITH x AS (INSERT INTO public.standard_rate_tiers(weight_min,weight_max,unit_price,labour_rate,tax_percent) VALUES (500,600,1,1,1) RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$)->>'state'='42501'
 AND pg_temp.sr_as(:'admin_claims'::jsonb,$q$WITH x AS (UPDATE public.standard_rate_tiers SET unit_price=0 RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$)->>'state'='42501'
 AND pg_temp.sr_as(:'admin_claims'::jsonb,$q$WITH x AS (DELETE FROM public.standard_rate_tiers RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$)->>'state'='42501',
 'an administrator cannot insert, update or delete the table directly');

-- ---------------------------------------------------------------------------
-- 6. create_item after the save
-- ---------------------------------------------------------------------------
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('SR Standard Item','Bag')$q$) AS new_std \gset
SELECT pg_temp.sr_assert(:'new_std'::jsonb->>'success'='true' AND :'new_std'::jsonb#>>'{data,rate_source}'='standard'
 AND pg_temp.sr_rows(pg_temp.sr_item('SR Standard Item'),NULL)=format('0-10@3.00/1.00/5 %1$s..open | 11-20@4.00/1.50/5 %1$s..open | 21-30@5.00/2.00/5.5 %1$s..open',:'today'),
 'a new item gets the standard tiers from today: '||:'new_std'||' '||pg_temp.sr_rows(pg_temp.sr_item('SR Standard Item'),NULL));
SELECT pg_temp.sr_assert((SELECT count(*)=3 AND bool_and(h.changed_by=:'admin_profile'::uuid AND h.action='insert') FROM public.item_price_history h
  WHERE h.item_id=pg_temp.sr_item('SR Standard Item')),'its history rows name the administrator');
SELECT pg_temp.sr_as(:'supervisor_claims'::jsonb,$q$SELECT public.create_item('SR Four Args','Bag','d',true)$q$) AS new_four \gset
SELECT pg_temp.sr_assert(:'new_four'::jsonb#>>'{data,rate_source}'='standard' AND (SELECT count(*)=3 FROM public.item_storage_prices WHERE item_id=pg_temp.sr_item('SR Four Args')
  AND created_by=:'supervisor_profile'::uuid),'the old four-argument call gets the standard tiers, authored by the supervisor');
-- Copy: both price types, labour 0 for one-time, no customer row, no ended or upcoming row.
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,format($q$SELECT public.create_item('SR Copy','Bag',NULL,true,%L::uuid)$q$,pg_temp.sr_item('SR Source'))) AS new_copy \gset
SELECT pg_temp.sr_assert(:'new_copy'::jsonb->>'success'='true' AND :'new_copy'::jsonb#>>'{data,rate_source}'='copied','copy answer: '||:'new_copy');
SELECT pg_temp.sr_assert(pg_temp.sr_rows(pg_temp.sr_item('SR Copy'),NULL,'monthly')=format('0-10@4.00/1.50/5 %1$s..open | 11-50@5.00/2.00/12 %1$s..open',:'today')
 AND pg_temp.sr_rows(pg_temp.sr_item('SR Copy'),NULL,'one_time')=format('0-50@30.00/0.00/18 %s..open',:'today')
 AND (SELECT count(*)=0 FROM public.item_storage_prices WHERE item_id=pg_temp.sr_item('SR Copy') AND customer_id IS NOT NULL)
 AND (SELECT count(*)=3 FROM public.item_storage_prices WHERE item_id=pg_temp.sr_item('SR Copy')),
 'the copy has the in-force default rows of both types from today: '||pg_temp.sr_rows(pg_temp.sr_item('SR Copy'),NULL,'monthly')||' / '||pg_temp.sr_rows(pg_temp.sr_item('SR Copy'),NULL,'one_time'));
SELECT pg_temp.sr_assert((SELECT bool_and(CASE r.price_type WHEN 'one_time' THEN r.unit_price_one_time=r.unit_price AND r.unit_price_monthly=0 AND r.labour_rate=0
    ELSE r.unit_price_monthly=r.unit_price AND r.unit_price_one_time=0 END AND r.created_by=:'admin_profile'::uuid)
  FROM public.item_storage_prices r WHERE r.item_id=pg_temp.sr_item('SR Copy')),'the copied rows fill the price columns by type and name the author');
SELECT pg_temp.sr_assert(pg_temp.sr_rows(pg_temp.sr_item('SR Source'),NULL,'monthly') LIKE '%0-100@88.00/1.00/5 %' AND (SELECT count(*)=6 FROM public.item_storage_prices WHERE item_id=pg_temp.sr_item('SR Source')),
 'the source item is unchanged');
-- Copy falls back to the standard tiers when the source has nothing in force, or does not exist.
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,format($q$SELECT public.create_item('SR Copy From Ended','Bag',NULL,true,%L::uuid)$q$,pg_temp.sr_item('SR Ended'))) AS new_ended \gset
SELECT pg_temp.sr_assert(:'new_ended'::jsonb#>>'{data,rate_source}'='standard' AND pg_temp.sr_rows(pg_temp.sr_item('SR Copy From Ended'),NULL)=
 format('0-10@3.00/1.00/5 %1$s..open | 11-20@4.00/1.50/5 %1$s..open | 21-30@5.00/2.00/5.5 %1$s..open',:'today'),'copy from an item with no rate in force gives the standard tiers: '||:'new_ended');
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,format($q$SELECT public.create_item('SR Copy From Nobody','Bag',NULL,true,%L::uuid)$q$,gen_random_uuid())) AS new_nobody \gset
SELECT pg_temp.sr_assert(:'new_nobody'::jsonb#>>'{data,rate_source}'='standard','copy from an unknown item gives the standard tiers: '||:'new_nobody');
-- Only managers create items (unchanged).
SELECT pg_temp.sr_assert(pg_temp.sr_as(:'staff_claims'::jsonb,$q$SELECT public.create_item('SR Staff Item','Bag')$q$)->>'state'='42501','staff still cannot create items');

-- ---------------------------------------------------------------------------
-- 7. update_item: reactivation
-- ---------------------------------------------------------------------------
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,format($q$SELECT public.update_item(%L::uuid,'SR Inactive','Bag',NULL,true)$q$,pg_temp.sr_item('SR Inactive'))) AS react \gset
SELECT pg_temp.sr_assert(:'react'::jsonb->>'success'='true' AND :'react'::jsonb#>>'{data,active}'='true' AND pg_temp.sr_rows(pg_temp.sr_item('SR Inactive'),NULL)=
 format('0-10@3.00/1.00/5 %1$s..open | 11-20@4.00/1.50/5 %1$s..open | 21-30@5.00/2.00/5.5 %1$s..open',:'today'),
 'an item that turns active with no default row gets the standard tiers from today: '||pg_temp.sr_rows(pg_temp.sr_item('SR Inactive'),NULL));
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,format($q$SELECT public.update_item(%L::uuid,'SR Inactive Ended','Bag',NULL,true)$q$,pg_temp.sr_item('SR Inactive Ended'))) AS react_ended \gset
SELECT pg_temp.sr_assert(:'react_ended'::jsonb->>'success'='true' AND pg_temp.sr_rows(pg_temp.sr_item('SR Inactive Ended'),NULL)=format('0-100@8.00/1.00/5 %s..%s',:'d100',:'yesterday'),
 'an item that has any default row gets nothing when it turns active');
-- An item that stays active, or only gets a new name, is not priced again; a deactivated one stays as it is.
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,format($q$SELECT public.update_item(%L::uuid,'SR Plain Renamed','Bag',NULL,true)$q$,pg_temp.sr_item('SR Plain'))) AS rename \gset
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,format($q$SELECT public.update_item(%L::uuid,'SR Plain Renamed','Bag',NULL,false)$q$,pg_temp.sr_item('SR Plain Renamed'))) AS off \gset
SELECT pg_temp.sr_assert(:'rename'::jsonb->>'success'='true' AND :'off'::jsonb->>'success'='true'
 AND (SELECT count(*)=3 FROM public.item_storage_prices WHERE item_id=pg_temp.sr_item('SR Plain Renamed')),'renaming and deactivating add no rows');

-- ---------------------------------------------------------------------------
-- 8. The second save by a supervisor: items already priced keep their figures
-- ---------------------------------------------------------------------------
INSERT INTO public.items(name,packaging,active) VALUES ('SR Later','Bag',true);
SELECT pg_temp.sr_assert(pg_temp.sr_unpriced()=1,'one new unpriced item');
SELECT pg_temp.sr_set(:'supervisor_claims'::jsonb,'[{"weight_min":0,"weight_max":50,"unit_price":9,"labour_rate":3,"tax_percent":18}]') AS save2 \gset
SELECT pg_temp.sr_assert(:'save2'::jsonb->>'success'='true' AND (:'save2'::jsonb#>>'{data,items_priced}')::int=1 AND jsonb_array_length(:'save2'::jsonb#>'{data,tiers}')=1,
 'the second save priced only the item without a rate: '||:'save2');
SELECT pg_temp.sr_assert(pg_temp.sr_rows(pg_temp.sr_item('SR Later'),NULL)=format('0-50@9.00/3.00/18 %s..open',:'today'),'the new item got the new tiers');
SELECT pg_temp.sr_assert(pg_temp.sr_rows(pg_temp.sr_item('SR Grn'),NULL)=
 '0-10@3.00/1.00/5 2026-03-02..open | 11-20@4.00/1.50/5 2026-03-02..open | 21-30@5.00/2.00/5.5 2026-03-02..open','an item priced by the first save is unchanged');
SELECT pg_temp.sr_assert((SELECT count(*)=1 FROM public.standard_rate_tiers),'the second save replaced the tiers');
SELECT pg_temp.sr_as(:'supervisor_claims'::jsonb,'SELECT public.get_standard_rate()') AS got2 \gset
SELECT pg_temp.sr_assert(:'got2'::jsonb#>>'{data,updated_by_name}'='Standard Rate Supervisor' AND jsonb_array_length(:'got2'::jsonb#>'{data,tiers}')=1,
 'updated_by_name is the supervisor after the second save: '||:'got2');
-- A save when nothing is unpriced counts 0.
SELECT pg_temp.sr_set(:'admin_claims'::jsonb,'[{"weight_min":0,"weight_max":50,"unit_price":9,"labour_rate":3,"tax_percent":18}]') AS save3 \gset
SELECT pg_temp.sr_assert((:'save3'::jsonb#>>'{data,items_priced}')::int=0,'a save with nothing to price reports 0: '||:'save3');
-- ---------------------------------------------------------------------------
-- 9. Review fixes (B3-B8 of the 2026-10-15 review)
-- ---------------------------------------------------------------------------
-- A staff member sending bad tiers is refused as staff (the guard comes first, migration 90).
SELECT pg_temp.sr_set(:'staff_claims'::jsonb,'[]') AS staff_bad \gset
SELECT pg_temp.sr_assert(:'staff_bad'::jsonb->>'state'='42501' AND :'staff_bad'::jsonb->>'error_code' IS NULL,'staff sending no tiers are refused by the guard, not told INVALID_BANDS: '||:'staff_bad');
-- Renaming an item that is already active adds no rows, even when it has none: only turning active does.
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('SR Bare','Bag')$q$)->>'success' AS made_bare \gset
DELETE FROM public.item_storage_prices WHERE item_id=pg_temp.sr_item('SR Bare');
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,format($q$SELECT public.update_item(%L::uuid,'SR Bare Renamed','Bag',NULL,true)$q$,pg_temp.sr_item('SR Bare'))) AS bare_rename \gset
SELECT pg_temp.sr_assert(:'bare_rename'::jsonb->>'success'='true' AND pg_temp.sr_rows(pg_temp.sr_item('SR Bare Renamed'),NULL)='(none)',
 'active to active adds no rows: '||pg_temp.sr_rows(pg_temp.sr_item('SR Bare Renamed'),NULL));
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,format($q$SELECT public.update_item(%L::uuid,'SR Bare Renamed','Bag',NULL,false)$q$,pg_temp.sr_item('SR Bare Renamed'))) AS bare_off \gset
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,format($q$SELECT public.update_item(%L::uuid,'SR Bare Renamed','Bag',NULL,true)$q$,pg_temp.sr_item('SR Bare Renamed'))) AS bare_on \gset
SELECT pg_temp.sr_assert(pg_temp.sr_rows(pg_temp.sr_item('SR Bare Renamed'),NULL)=format('0-50@9.00/3.00/18 %s..open',:'today'),
 'the same item turned off and on again is priced: '||pg_temp.sr_rows(pg_temp.sr_item('SR Bare Renamed'),NULL));
-- Any default row counts, also a one-time one, an ended one is covered above, and a planned one.
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('SR One Time Only','Bag')$q$)->>'success' AS made_ot \gset
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('SR Planned Only','Bag')$q$)->>'success' AS made_pl \gset
DELETE FROM public.item_storage_prices WHERE item_id IN (pg_temp.sr_item('SR One Time Only'),pg_temp.sr_item('SR Planned Only'));
INSERT INTO public.item_storage_prices(item_id,customer_id,price_type,unit_price,weight_min,weight_max,labour_rate,tax_percent,effective_from,effective_to,unit_price_one_time,unit_price_monthly) VALUES
 (pg_temp.sr_item('SR One Time Only'),NULL,'one_time',30,0,50,0,18,:'d100',NULL,30,0),
 (pg_temp.sr_item('SR Planned Only'),NULL,'monthly',6,0,50,1,5,:'d10',NULL,0,6);
SELECT pg_temp.sr_set(:'admin_claims'::jsonb,'[{"weight_min":0,"weight_max":50,"unit_price":9,"labour_rate":3,"tax_percent":18}]') AS save4 \gset
SELECT pg_temp.sr_assert((:'save4'::jsonb#>>'{data,items_priced}')::int=0
 AND pg_temp.sr_rows(pg_temp.sr_item('SR One Time Only'),NULL,'monthly')='(none)' AND pg_temp.sr_rows(pg_temp.sr_item('SR One Time Only'),NULL,'one_time')=format('0-50@30.00/0.00/18 %s..open',:'d100')
 AND pg_temp.sr_rows(pg_temp.sr_item('SR Planned Only'),NULL)=format('0-50@6.00/1.00/5 %s..open',:'d10'),
 'a save leaves an item with only a one-time or only a planned default row alone: '||:'save4');
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,format($q$SELECT public.update_item(%L::uuid,'SR One Time Only','Bag',NULL,false)$q$,pg_temp.sr_item('SR One Time Only'))) AS ot_off \gset
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,format($q$SELECT public.update_item(%L::uuid,'SR One Time Only','Bag',NULL,true)$q$,pg_temp.sr_item('SR One Time Only'))) AS ot_on \gset
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,format($q$SELECT public.update_item(%L::uuid,'SR Planned Only','Bag',NULL,false)$q$,pg_temp.sr_item('SR Planned Only'))) AS pl_off \gset
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,format($q$SELECT public.update_item(%L::uuid,'SR Planned Only','Bag',NULL,true)$q$,pg_temp.sr_item('SR Planned Only'))) AS pl_on \gset
SELECT pg_temp.sr_assert(pg_temp.sr_rows(pg_temp.sr_item('SR One Time Only'),NULL,'monthly')='(none)' AND pg_temp.sr_rows(pg_temp.sr_item('SR Planned Only'),NULL)=format('0-50@6.00/1.00/5 %s..open',:'d10'),
 'a reactivation leaves them alone too');
-- Copy from an item whose only rate in force is a customer rate: the standard tiers.
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('SR Cust Source','Bag')$q$)->>'success' AS made_cs \gset
DELETE FROM public.item_storage_prices WHERE item_id=pg_temp.sr_item('SR Cust Source');
INSERT INTO public.item_storage_prices(item_id,customer_id,price_type,unit_price,weight_min,weight_max,labour_rate,tax_percent,effective_from,effective_to,unit_price_one_time,unit_price_monthly) VALUES
 (pg_temp.sr_item('SR Cust Source'),:'orchard'::uuid,'monthly',9,0,100,1,5,:'d100',NULL,0,9);
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,format($q$SELECT public.create_item('SR From Customer Only','Bag',NULL,true,%L::uuid)$q$,pg_temp.sr_item('SR Cust Source'))) AS from_cust \gset
SELECT pg_temp.sr_assert(:'from_cust'::jsonb#>>'{data,rate_source}'='standard' AND pg_temp.sr_rows(pg_temp.sr_item('SR From Customer Only'),NULL)=format('0-50@9.00/3.00/18 %s..open',:'today')
 AND (SELECT count(*)=0 FROM public.item_storage_prices WHERE item_id=pg_temp.sr_item('SR From Customer Only') AND customer_id IS NOT NULL),
 'copy from an item with customer rates only gives the standard tiers: '||:'from_cust');
-- B4: a source with two open rows for one band (data from before migration 76) copies the one find_storage_price
-- would use; a source whose rows overlap in different bands cannot be copied and gives the standard tiers.
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('SR Legacy Dup','Bag')$q$)->>'success' AS made_dup \gset
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('SR Legacy Nested','Bag')$q$)->>'success' AS made_nested \gset
DELETE FROM public.item_storage_prices WHERE item_id IN (pg_temp.sr_item('SR Legacy Dup'),pg_temp.sr_item('SR Legacy Nested'));
INSERT INTO public.item_storage_prices(item_id,customer_id,price_type,unit_price,weight_min,weight_max,labour_rate,tax_percent,effective_from,effective_to,unit_price_one_time,unit_price_monthly) VALUES
 (pg_temp.sr_item('SR Legacy Dup'),NULL,'monthly',4,0,50,1,5,:'today'::date-200,NULL,0,4),
 (pg_temp.sr_item('SR Legacy Dup'),NULL,'monthly',6,0,50,2,5,:'d100',NULL,0,6),
 (pg_temp.sr_item('SR Legacy Nested'),NULL,'monthly',3,0,100,1,5,:'d100',NULL,0,3),
 (pg_temp.sr_item('SR Legacy Nested'),NULL,'monthly',5,0,10,1,5,:'d100',NULL,0,5);
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,format($q$SELECT public.create_item('SR Copy Dup','Bag',NULL,true,%L::uuid)$q$,pg_temp.sr_item('SR Legacy Dup'))) AS copy_dup \gset
SELECT pg_temp.sr_assert(:'copy_dup'::jsonb->>'success'='true' AND :'copy_dup'::jsonb#>>'{data,rate_source}'='copied'
 AND pg_temp.sr_rows(pg_temp.sr_item('SR Copy Dup'),NULL)=format('0-50@6.00/2.00/5 %s..open',:'today'),
 'two open rows of one band: the later start is copied, once: '||:'copy_dup'||' '||pg_temp.sr_rows(pg_temp.sr_item('SR Copy Dup'),NULL));
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,format($q$SELECT public.create_item('SR Copy Nested','Bag',NULL,true,%L::uuid)$q$,pg_temp.sr_item('SR Legacy Nested'))) AS copy_nested \gset
SELECT pg_temp.sr_assert(:'copy_nested'::jsonb->>'success'='true' AND :'copy_nested'::jsonb#>>'{data,rate_source}'='standard'
 AND pg_temp.sr_rows(pg_temp.sr_item('SR Copy Nested'),NULL)=format('0-50@9.00/3.00/18 %s..open',:'today'),
 'overlapping bands in the source: the standard tiers, not a copy that overlaps: '||:'copy_nested');
-- B6: whole weights written with a decimal point are accepted (they used to raise 22P02).
SELECT pg_temp.sr_set(:'admin_claims'::jsonb,'[{"weight_min":0.0,"weight_max":10.0,"unit_price":3,"labour_rate":1,"tax_percent":5},{"weight_min":11,"weight_max":50.00,"unit_price":4,"labour_rate":1,"tax_percent":5}]') AS save5 \gset
SELECT pg_temp.sr_assert(:'save5'::jsonb->>'success'='true' AND (SELECT string_agg(weight_min||'-'||weight_max,',' ORDER BY weight_min)='0-10,11-50' FROM public.standard_rate_tiers),
 'weights with a decimal point: '||:'save5');
-- ---------------------------------------------------------------------------
-- 111. Pricing review migration: set_standard_rate p_expected_updated_at (STALE_STANDARD_RATE) and p_dry_run
-- ---------------------------------------------------------------------------
-- One transaction means now() never changes, so the saved rate is first aged by an hour: a save then
-- visibly moves the version.
SELECT pg_temp.sr_assert((SELECT count(*)=1 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='set_standard_rate')
 AND has_function_privilege('authenticated','public.set_standard_rate(jsonb,timestamptz,boolean)','EXECUTE')
 AND has_function_privilege('service_role','public.set_standard_rate(jsonb,timestamptz,boolean)','EXECUTE')
 AND NOT has_function_privilege('anon','public.set_standard_rate(jsonb,timestamptz,boolean)','EXECUTE'),
 'set_standard_rate has one overload (three arguments) with the baseline grants');
UPDATE public.standard_rate_tiers SET updated_at = now() - interval '1 hour';
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('SR Dry A','Bag')$q$) AS dry_a \gset
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('SR Dry B','Bag')$q$) AS dry_b \gset
DELETE FROM public.item_storage_prices WHERE item_id IN (pg_temp.sr_item('SR Dry A'),pg_temp.sr_item('SR Dry B'));
SELECT pg_temp.sr_unpriced() AS dry_n \gset
SELECT pg_temp.sr_assert(:dry_n >= 2,'two items without a default row at least: '||:dry_n);
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,'SELECT public.get_standard_rate()')#>>'{data,updated_at}' AS v1 \gset
SELECT pg_temp.sr_assert(:'v1'::timestamptz = now() - interval '1 hour','get_standard_rate returns the version: '||:'v1');
-- Dry run: counts, writes nothing.
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,$q$SELECT public.set_standard_rate('[{"weight_min":0,"weight_max":50,"unit_price":6,"labour_rate":1,"tax_percent":5}]'::jsonb,NULL,true)$q$) AS dry \gset
SELECT pg_temp.sr_assert((:'dry'::jsonb#>>'{data,dry_run}')='true' AND (:'dry'::jsonb#>>'{data,items_priced}')::int = :dry_n
 AND pg_temp.sr_rows(pg_temp.sr_item('SR Dry A'),NULL)='(none)'
 AND (SELECT count(*)=2 AND max(updated_at) = :'v1'::timestamptz AND max(unit_price) = 4 FROM public.standard_rate_tiers),
 'dry run: counts '||:dry_n||' items and changes nothing: '||:'dry');
-- A save with the version loaded: written, version moves, the dry-run count was right.
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,format($q$SELECT public.set_standard_rate('[{"weight_min":0,"weight_max":50,"unit_price":6,"labour_rate":1,"tax_percent":5}]'::jsonb,%L::timestamptz)$q$,:'v1')) AS fresh \gset
SELECT pg_temp.sr_assert(:'fresh'::jsonb->>'success'='true' AND (:'fresh'::jsonb#>>'{data,items_priced}')::int = :dry_n
 AND (:'fresh'::jsonb#>>'{data,updated_at}')::timestamptz = now() AND (:'fresh'::jsonb#>>'{data,updated_at}')::timestamptz <> :'v1'::timestamptz
 AND pg_temp.sr_rows(pg_temp.sr_item('SR Dry A'),NULL) ~ '^0-50@6\.00/1\.00/5 '
 AND (SELECT count(*)=1 AND max(unit_price)=6 FROM public.standard_rate_tiers),'save with the current version: '||:'fresh');
-- The same version again is now stale: refused, nothing written.
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,format($q$SELECT public.set_standard_rate('[{"weight_min":0,"weight_max":50,"unit_price":9,"labour_rate":1,"tax_percent":5}]'::jsonb,%L::timestamptz)$q$,:'v1')) AS stale \gset
SELECT pg_temp.sr_assert(:'stale'::jsonb->>'success'='false' AND :'stale'::jsonb->>'error_code'='STALE_STANDARD_RATE'
 AND (:'stale'::jsonb#>>'{data,updated_at}')::timestamptz = now()
 AND (SELECT count(*)=1 AND max(unit_price)=6 FROM public.standard_rate_tiers),'old version is refused, tiers unchanged: '||:'stale');
-- A dry run with the old version is refused too; no version at all (older apps) still saves.
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,format($q$SELECT public.set_standard_rate('[{"weight_min":0,"weight_max":50,"unit_price":6,"labour_rate":1,"tax_percent":5}]'::jsonb,%L::timestamptz,true)$q$,:'v1')) AS stale_dry \gset
SELECT pg_temp.sr_assert(:'stale_dry'::jsonb->>'error_code'='STALE_STANDARD_RATE','a dry run with an old version is refused: '||:'stale_dry');
SELECT pg_temp.sr_set(:'admin_claims'::jsonb,'[{"weight_min":0,"weight_max":50,"unit_price":8,"labour_rate":1,"tax_percent":5}]') AS legacy \gset
SELECT pg_temp.sr_assert(:'legacy'::jsonb->>'success'='true' AND (SELECT max(unit_price)=8 FROM public.standard_rate_tiers),'the old one-argument call still saves: '||:'legacy');
-- '-infinity' means "I loaded no tiers": it matches only an empty table. Against the saved rate it is stale.
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,$q$SELECT public.set_standard_rate('[{"weight_min":0,"weight_max":50,"unit_price":5,"labour_rate":1,"tax_percent":5}]'::jsonb,'-infinity'::timestamptz)$q$) AS inf_stale \gset
SELECT pg_temp.sr_assert(:'inf_stale'::jsonb->>'error_code'='STALE_STANDARD_RATE' AND (SELECT max(unit_price)=8 FROM public.standard_rate_tiers),
 '-infinity against a saved rate is stale and writes nothing: '||:'inf_stale');
-- An empty tier table: a real version is stale (data.updated_at null), '-infinity' saves, NULL still saves.
DELETE FROM public.standard_rate_tiers;
SELECT pg_temp.sr_assert((SELECT count(*)=0 FROM public.standard_rate_tiers),'the tier table is empty here');
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,format($q$SELECT public.set_standard_rate('[{"weight_min":0,"weight_max":50,"unit_price":5,"labour_rate":1,"tax_percent":5}]'::jsonb,%L::timestamptz)$q$,:'v1')) AS empty_stale \gset
SELECT pg_temp.sr_assert(:'empty_stale'::jsonb->>'error_code'='STALE_STANDARD_RATE' AND :'empty_stale'::jsonb#>'{data,updated_at}'='null'::jsonb
 AND (SELECT count(*)=0 FROM public.standard_rate_tiers),'a version against an empty table is stale, nothing written: '||:'empty_stale');
SELECT pg_temp.sr_as(:'admin_claims'::jsonb,$q$SELECT public.set_standard_rate('[{"weight_min":0,"weight_max":50,"unit_price":5,"labour_rate":1,"tax_percent":5}]'::jsonb,'-infinity'::timestamptz)$q$) AS inf_first \gset
SELECT pg_temp.sr_assert(:'inf_first'::jsonb->>'success'='true' AND (:'inf_first'::jsonb#>>'{data,updated_at}')::timestamptz = now()
 AND (SELECT count(*)=1 AND max(unit_price)=5 FROM public.standard_rate_tiers),'-infinity against an empty table saves: '||:'inf_first');
ROLLBACK;

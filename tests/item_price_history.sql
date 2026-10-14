-- Migration 48, owner decision 5 of 2026-10-11: staff may create, change and
-- delete item prices, and every change is recorded. Each insert, update and
-- delete of item_storage_prices, through whichever RPC, leaves one row in the
-- append-only item_price_history with the acting profile and the old and new
-- values; get_item_price_history returns it to administrators and supervisors
-- only. Fictional data; runs only in migrations.sh's disposable,
-- network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.ph_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'item price history: %',label; END IF; END $$;
-- True when the statement raises an error whose text matches the pattern.
CREATE FUNCTION pg_temp.ph_raises(statement text, pattern text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE statement; EXCEPTION WHEN OTHERS THEN RETURN SQLERRM LIKE pattern; END;
  RETURN false;
END $$;
-- The jsonb answer of a call, or what it raised.
CREATE FUNCTION pg_temp.ph_call(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RETURN answer;
END $$;
-- The history as [action, old unit price, new unit price, profile, role] per
-- row, oldest first; and the newest row.
CREATE FUNCTION pg_temp.ph_rows() RETURNS jsonb LANGUAGE sql AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_array(h.action,h.old_values->'unit_price',h.new_values->'unit_price',h.changed_by,h.changed_by_role) ORDER BY h.id),'[]'::jsonb)
  FROM public.item_price_history h $$;
CREATE FUNCTION pg_temp.ph_last() RETURNS public.item_price_history LANGUAGE sql AS $$
  SELECT h FROM public.item_price_history h ORDER BY h.id DESC LIMIT 1 $$;
CREATE FUNCTION pg_temp.ph_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.ph_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.ph_assert(l#>>'{data,action}'='login','login for '||phone);
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
SELECT warehouse_security.bootstrap_first_admin('9888888891','Price History Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888892','Price History Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919888888893','Price History Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888894','Price History Second Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888895','Price History Customer Reader','customer',true,'approved'),
 (gen_random_uuid(),'919888888896','Price History Past Supervisor','supervisor',false,'disabled');
SELECT id AS supervisor_profile FROM public.user_profiles WHERE mobile='919888888892' \gset
SELECT id AS staff_profile FROM public.user_profiles WHERE mobile='919888888893' \gset
SELECT id AS staff2_profile FROM public.user_profiles WHERE mobile='919888888894' \gset
SELECT pg_temp.ph_login('9888888891') AS admin_claims \gset
SELECT pg_temp.ph_login('9888888892') AS supervisor_claims \gset
SELECT pg_temp.ph_login('9888888893') AS staff_claims \gset
SELECT pg_temp.ph_login('9888888894') AS staff2_claims \gset
SELECT pg_temp.ph_login('9888888895') AS customer_claims \gset
SELECT jsonb_build_object('role','authenticated','sub',auth_user_id) AS former_claims
 FROM public.user_profiles WHERE mobile='919888888896' \gset

-- Two customers and two catalog items, as the administrator. The customer
-- login is assigned to the first customer.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ph_assert(public.create_customer('Price History North','9888888897')->>'success'='true'
 AND public.create_customer('Price History South','9888888898')->>'success'='true','customers');
SELECT pg_temp.ph_assert(public.create_item('Price History Chillies','Bag')->>'success'='true'
 AND public.create_item('Price History Turmeric','Bag')->>'success'='true','catalog items');
SELECT id AS north FROM public.customers WHERE name='Price History North' \gset
SELECT id AS south FROM public.customers WHERE name='Price History South' \gset
SELECT id AS chillies FROM public.items WHERE name='Price History Chillies' \gset
SELECT id AS turmeric FROM public.items WHERE name='Price History Turmeric' \gset
SELECT pg_temp.ph_assert(public.assign_customer_to_user('919888888895',:'north'::uuid,'Price history fixture'),'customer login assigned to North');
RESET ROLE;

-- The table: read by policy, written by nobody, tied to nothing.
SELECT pg_temp.ph_assert((SELECT relrowsecurity FROM pg_class WHERE oid='public.item_price_history'::regclass)
 AND NOT has_table_privilege('authenticated','public.item_price_history','INSERT,UPDATE,DELETE,TRUNCATE')
 AND NOT has_table_privilege('service_role','public.item_price_history','INSERT,UPDATE,DELETE,TRUNCATE')
 AND NOT has_table_privilege('anon','public.item_price_history','SELECT')
 AND (SELECT count(*)=0 FROM pg_constraint WHERE conrelid='public.item_price_history'::regclass AND contype='f'),
 'the history has row level security, no write grant and no foreign key');
SELECT pg_temp.ph_assert((SELECT count(*)=0 FROM public.item_price_history),'no price has changed so far');

-- ---------------------------------------------------------------------------
-- 1. One row per insert, update and delete, with the acting profile
-- ---------------------------------------------------------------------------
-- Staff create a price: Chillies for North, monthly, 5 a bag.
-- Staff change only a rate that has not started (migration 76), so the prices below start
-- in 30 days and end in 400.
SELECT (CURRENT_DATE+30) AS f, (CURRENT_DATE+400) AS t \gset
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ph_assert(warehouse_security.active_role()='staff','actual staff role');
SELECT public.create_item_storage_price(p_item_id=>:'chillies'::uuid,p_price_type=>'monthly',p_unit_price=>5,
 p_weight_min=>0,p_weight_max=>100,p_labour_rate=>2,p_effective_from=>:'f',
 p_customer_id=>:'north'::uuid,p_tax_percent=>5) AS created \gset
SELECT pg_temp.ph_assert(:'created'::jsonb->>'success'='true','staff create a price: '||:'created');
SELECT (:'created'::jsonb#>>'{data,id}') AS north_price \gset
RESET ROLE;
SELECT pg_temp.ph_assert(pg_temp.ph_rows()=jsonb_build_array(jsonb_build_array('insert',NULL,5,:'staff_profile','staff')),
 'the insert is recorded for the staff member: '||pg_temp.ph_rows()::text);
SELECT pg_temp.ph_assert(h.price_id=:'north_price'::uuid AND h.item_id=:'chillies'::uuid AND h.item_name='Price History Chillies'
 AND h.customer_id=:'north'::uuid AND h.customer_name='Price History North' AND h.changed_at=now() AND h.old_values IS NULL
 AND h.changed_by_name='Price History Staff'
 AND h.new_values @> ('{"price_type":"monthly","unit_price":5,"unit_price_monthly":5,"unit_price_one_time":0,"weight_min":0,"weight_max":100,"labour_rate":2,"tax_percent":5,"effective_from":"'||:'f'||'","effective_to":null}')::jsonb
 AND NOT h.new_values ?| ARRAY['id','item_id','customer_id','created_at','created_by'],
 'the row names the price, the item and the customer and holds the new values: '||to_jsonb(h)::text)
FROM pg_temp.ph_last() h;
-- The supervisor changes it to 8 a bag with labour 3, until the end of 2026.
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ph_assert(public.update_item_storage_price(p_id=>:'north_price'::uuid,p_unit_price=>8,p_weight_min=>0,p_weight_max=>100,
 p_labour_rate=>3,p_tax_percent=>5,p_effective_from=>:'f',p_effective_to=>:'t')->>'success'='true','the supervisor changes the price');
RESET ROLE;
SELECT pg_temp.ph_assert(pg_temp.ph_rows()->1=jsonb_build_array('update',5,8,:'supervisor_profile','supervisor') AND jsonb_array_length(pg_temp.ph_rows())=2,
 'the update is recorded for the supervisor: '||pg_temp.ph_rows()::text);
SELECT pg_temp.ph_assert(h.price_id=:'north_price'::uuid AND h.item_id=:'chillies'::uuid AND h.customer_id=:'north'::uuid
 AND h.changed_by_name='Price History Supervisor'
 AND h.old_values @> '{"unit_price":5,"labour_rate":2,"effective_to":null}'::jsonb
 AND h.new_values @> ('{"unit_price":8,"unit_price_monthly":8,"labour_rate":3,"effective_to":"'||:'t'||'","price_type":"monthly"}')::jsonb,
 'the row holds the old and the new values: '||to_jsonb(h)::text)
FROM pg_temp.ph_last() h;
-- The second staff member adds a one-time price for South (one row); adding it again is refused
-- and leaves no row. (find_or_create_item_storage_price is no longer a staff call, migration 76.)
SELECT set_config('request.jwt.claims',:'staff2_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_item_storage_price(p_item_id=>:'turmeric'::uuid,p_price_type=>'one_time',p_unit_price=>12,
 p_weight_min=>0,p_weight_max=>10,p_labour_rate=>1,p_effective_from=>:'f',p_customer_id=>:'south'::uuid,p_tax_percent=>5) AS found_first \gset
SELECT pg_temp.ph_assert(:'found_first'::jsonb->>'success'='true','the second staff member creates the price: '||:'found_first');
SELECT (:'found_first'::jsonb#>>'{data,id}') AS south_price \gset
SELECT pg_temp.ph_assert(public.create_item_storage_price(p_item_id=>:'turmeric'::uuid,p_price_type=>'one_time',p_unit_price=>12,
 p_weight_min=>0,p_weight_max=>10,p_labour_rate=>1,p_effective_from=>:'f',p_customer_id=>:'south'::uuid,p_tax_percent=>5)->>'error_code'='BANDS_OVERLAP',
 'adding it again is refused');
RESET ROLE;
SELECT pg_temp.ph_assert(pg_temp.ph_rows()->2=jsonb_build_array('insert',NULL,12,:'staff2_profile','staff') AND jsonb_array_length(pg_temp.ph_rows())=3,
 'find-or-create leaves one insert row, and none for the price it found: '||pg_temp.ph_rows()::text);
SELECT pg_temp.ph_assert(h.price_id=:'south_price'::uuid AND h.item_name='Price History Turmeric' AND h.customer_name='Price History South'
 AND h.new_values @> '{"price_type":"one_time","unit_price":12,"unit_price_one_time":12,"unit_price_monthly":0}'::jsonb,
 'its row names Turmeric and South: '||to_jsonb(h)::text)
FROM pg_temp.ph_last() h;
-- A refused write records nothing: a price that already exists, and a change
-- the function turns down.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ph_assert(public.create_item_storage_price(p_item_id=>:'chillies'::uuid,p_price_type=>'monthly',p_unit_price=>6,
  p_weight_min=>0,p_weight_max=>100,p_labour_rate=>2,p_effective_from=>:'f',p_customer_id=>:'north'::uuid,p_tax_percent=>5,
  p_effective_to=>:'t')->>'error_code'='BANDS_OVERLAP'
 AND public.update_item_storage_price(p_id=>:'north_price'::uuid,p_unit_price=>-1,p_weight_min=>0,p_weight_max=>100,
  p_labour_rate=>3,p_tax_percent=>5,p_effective_from=>:'f')->>'error'='unit_price must be >= 0'
 AND public.update_item_storage_price(p_id=>:'north_price'::uuid,p_unit_price=>9,p_weight_min=>0,p_weight_max=>100,
  p_labour_rate=>3,p_tax_percent=>500,p_effective_from=>:'f')->>'success'='false',
 'a duplicate price and two invalid changes are refused');
RESET ROLE;
SELECT pg_temp.ph_assert(jsonb_array_length(pg_temp.ph_rows())=3 AND (SELECT unit_price=8 FROM public.item_storage_prices WHERE id=:'north_price'::uuid),
 'refused writes leave no history row: '||pg_temp.ph_rows()::text);
-- The administrator deletes North's price.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ph_assert(public.delete_item_storage_price(:'north_price'::uuid)->>'success'='true','the administrator deletes the price');
RESET ROLE;
SELECT pg_temp.ph_assert(pg_temp.ph_rows()->3=jsonb_build_array('delete',8,NULL,:'admin_profile','admin') AND jsonb_array_length(pg_temp.ph_rows())=4,
 'the delete is recorded for the administrator: '||pg_temp.ph_rows()::text);
SELECT pg_temp.ph_assert(h.price_id=:'north_price'::uuid AND h.item_name='Price History Chillies' AND h.customer_name='Price History North'
 AND h.new_values IS NULL AND h.old_values @> ('{"unit_price":8,"labour_rate":3,"effective_to":"'||:'t'||'"}')::jsonb
 AND (SELECT count(*)=0 FROM public.item_storage_prices WHERE id=:'north_price'::uuid),
 'the row keeps what the deleted price was: '||to_jsonb(h)::text)
FROM pg_temp.ph_last() h;
-- A write that is not an app session's (here with the service key; the same
-- holds for an operator in the database): recorded without a profile. A
-- default price has no customer.
SELECT set_config('request.jwt.claims','{"role":"service_role"}',true);
SET LOCAL ROLE service_role;
INSERT INTO public.item_storage_prices(item_id,customer_id,price_type,unit_price,unit_price_one_time,unit_price_monthly,weight_min,weight_max,labour_rate,tax_percent,effective_from)
 VALUES (:'chillies'::uuid,NULL,'monthly',4,0,4,0,100,1,5,'2026-01-01');
RESET ROLE;
SELECT pg_temp.ph_assert(pg_temp.ph_rows()->4=jsonb_build_array('insert',NULL,4,NULL,NULL)
 AND (SELECT h.customer_id IS NULL AND h.customer_name IS NULL AND h.item_name='Price History Chillies' AND h.changed_by_name IS NULL FROM pg_temp.ph_last() h),
 'an operator''s write is recorded without a profile: '||pg_temp.ph_rows()::text);
SELECT pg_temp.ph_assert(pg_get_triggerdef(t.oid) LIKE '%AFTER INSERT OR DELETE OR UPDATE ON public.item_storage_prices FOR EACH ROW%',
 'the record is a row trigger on the table, so no write path goes around it: '||pg_get_triggerdef(t.oid))
FROM pg_trigger t WHERE t.tgrelid='public.item_storage_prices'::regclass AND t.tgname='item_price_history_record';

-- ---------------------------------------------------------------------------
-- 2. get_item_price_history: administrators and supervisors
-- ---------------------------------------------------------------------------
SELECT pg_temp.ph_assert((SELECT count(*)=1 AND bool_and(p.proargnames=ARRAY['p_customer_id','p_item_id','p_limit','p_offset']
    AND p.pronargdefaults=4 AND p.prorettype='jsonb'::regtype AND p.prosecdef AND p.proconfig::text LIKE '%search_path=%')
  FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname='get_item_price_history')
 AND has_function_privilege('authenticated','public.get_item_price_history(uuid,uuid,integer,integer)','EXECUTE')
 AND has_function_privilege('service_role','public.get_item_price_history(uuid,uuid,integer,integer)','EXECUTE')
 AND NOT has_function_privilege('anon','public.get_item_price_history(uuid,uuid,integer,integer)','EXECUTE')
 AND pg_get_functiondef('public.get_item_price_history(uuid,uuid,integer,integer)'::regprocedure)
   ~ 'BEGIN\s+PERFORM warehouse_security\.authorize_rpc\(''get_item_price_history''',
 'one signature, guarded first, with a search_path, granted to signed-in sessions only');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_item_price_history() AS everything \gset
SELECT pg_temp.ph_assert(:'everything'::jsonb->>'success'='true' AND jsonb_array_length(:'everything'::jsonb->'data')=5
 AND :'everything'::jsonb->'pagination'='{"total":5,"limit":50,"offset":0,"has_more":false}'::jsonb
 AND (SELECT jsonb_agg(r->>'action')='["insert","delete","insert","update","insert"]'::jsonb FROM jsonb_array_elements(:'everything'::jsonb->'data') r),
 'the administrator reads every change, newest first: '||:'everything');
-- One row in full: the supervisor's update.
SELECT pg_temp.ph_assert(r ?& ARRAY['id','changed_at','action','price_id','item_id','item_name','customer_id','customer_name',
   'old_values','new_values','changed_by','changed_by_name','changed_by_role']
 AND (SELECT count(*)=13 FROM jsonb_object_keys(r))
 AND r @> jsonb_build_object('action','update','price_id',:'north_price','item_id',:'chillies','item_name','Price History Chillies',
   'customer_id',:'north','customer_name','Price History North','changed_by',:'supervisor_profile',
   'changed_by_name','Price History Supervisor','changed_by_role','supervisor')
 AND (r#>>'{old_values,unit_price}')::numeric=5 AND (r#>>'{new_values,unit_price}')::numeric=8 AND (r->>'changed_at')::timestamptz=now(),
 'a row carries when, who, which price, the action and both sets of values: '||r::text)
FROM (SELECT :'everything'::jsonb#>'{data,3}' AS r) one;
SELECT pg_temp.ph_assert(:'everything'::jsonb#>'{data,0,changed_by}'='null' AND :'everything'::jsonb#>'{data,0,changed_by_name}'='null'
 AND :'everything'::jsonb#>'{data,0,customer_id}'='null' AND :'everything'::jsonb#>'{data,1,new_values}'='null'
 AND :'everything'::jsonb#>'{data,4,old_values}'='null','absent values are null, not missing');
-- Filters.
SELECT pg_temp.ph_assert((public.get_item_price_history(p_customer_id=>:'north'::uuid)#>>'{pagination,total}')::int=3
 AND (SELECT bool_and(r->>'customer_id'=:'north') FROM jsonb_array_elements(public.get_item_price_history(p_customer_id=>:'north'::uuid)->'data') r)
 AND (public.get_item_price_history(p_customer_id=>:'south'::uuid)#>>'{pagination,total}')::int=1
 AND (public.get_item_price_history(p_item_id=>:'chillies'::uuid)#>>'{pagination,total}')::int=4
 AND (public.get_item_price_history(p_item_id=>:'turmeric'::uuid)#>>'{pagination,total}')::int=1
 AND (public.get_item_price_history(:'north'::uuid,:'turmeric'::uuid)#>>'{pagination,total}')::int=0
 AND public.get_item_price_history(:'north'::uuid,:'turmeric'::uuid)->'data'='[]'::jsonb
 AND (public.get_item_price_history(gen_random_uuid())#>>'{pagination,total}')::int=0,
 'the history is filtered by customer, by item and by both');
-- Paging: two a page over five rows.
SELECT public.get_item_price_history(p_limit=>2) AS page1, public.get_item_price_history(p_limit=>2,p_offset=>2) AS page2,
       public.get_item_price_history(p_limit=>2,p_offset=>4) AS page3, public.get_item_price_history(p_limit=>2,p_offset=>6) AS page4 \gset
SELECT pg_temp.ph_assert(:'page1'::jsonb->'pagination'='{"total":5,"limit":2,"offset":0,"has_more":true}'::jsonb
 AND :'page2'::jsonb->'pagination'='{"total":5,"limit":2,"offset":2,"has_more":true}'::jsonb
 AND :'page3'::jsonb->'pagination'='{"total":5,"limit":2,"offset":4,"has_more":false}'::jsonb
 AND :'page4'::jsonb->'pagination'='{"total":5,"limit":2,"offset":6,"has_more":false}'::jsonb AND :'page4'::jsonb->'data'='[]'::jsonb
 AND (:'page1'::jsonb->'data') || (:'page2'::jsonb->'data') || (:'page3'::jsonb->'data') = :'everything'::jsonb->'data',
 'three pages of two give the five rows once each, in order: '||(:'page3'::jsonb->'pagination')::text);
-- A page is 1 to 200 rows; a missing limit is 50, a missing or negative offset 0.
SELECT pg_temp.ph_assert((public.get_item_price_history(p_limit=>0)#>>'{pagination,limit}')::int=1
 AND jsonb_array_length(public.get_item_price_history(p_limit=>0)->'data')=1
 AND (public.get_item_price_history(p_limit=>100000)#>>'{pagination,limit}')::int=200
 AND public.get_item_price_history(NULL,NULL,NULL,NULL)->'pagination'='{"total":5,"limit":50,"offset":0,"has_more":false}'::jsonb
 AND (public.get_item_price_history(p_offset=>-3)#>>'{pagination,offset}')::int=0,'limit and offset are bounded');
-- The largest offset an integer holds is an empty page, not "integer out of
-- range": the offset is capped where offset + limit still fits.
SELECT pg_temp.ph_assert(pg_temp.ph_call(statement)=jsonb_build_object('success',true,'data','[]'::jsonb,
   'pagination',jsonb_build_object('total',5,'limit',page_limit,'offset',2147483447,'has_more',false)),
 'the largest offset is an empty page: '||statement||' -> '||pg_temp.ph_call(statement)::text)
FROM (VALUES ('SELECT public.get_item_price_history(p_offset=>2147483647)',50),
  ('SELECT public.get_item_price_history(p_limit=>200,p_offset=>2147483647)',200),
  ('SELECT public.get_item_price_history(p_limit=>2147483647,p_offset=>2147483647)',200),
  ('SELECT public.get_item_price_history(p_limit=>200,p_offset=>2147483448)',200)) AS s(statement,page_limit);
SELECT pg_temp.ph_assert((public.get_item_price_history(p_limit=>200,p_offset=>2147483446)#>>'{pagination,offset}')::int=2147483446,
 'an offset below the cap is kept as sent');
-- The supervisor reads it too, through the RPC and from the table.
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SELECT pg_temp.ph_assert(warehouse_security.active_role()='supervisor' AND public.get_item_price_history()->'data'=:'everything'::jsonb->'data'
 AND (SELECT count(*)=5 FROM public.item_price_history),'the supervisor reads the same history');

-- ---------------------------------------------------------------------------
-- 3. Nobody else reads it
-- ---------------------------------------------------------------------------
-- Staff change prices but do not read the history.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SELECT pg_temp.ph_assert(warehouse_security.active_role()='staff','actual staff role');
SELECT pg_temp.ph_assert(pg_temp.ph_call(statement)=jsonb_build_object('raised','Staff access required','state','42501'),
 'staff are refused: '||statement||' -> '||pg_temp.ph_call(statement)::text)
FROM (VALUES ('SELECT public.get_item_price_history()'),
  (format('SELECT public.get_item_price_history(p_customer_id=>%L::uuid)',:'north')),
  (format('SELECT public.get_item_price_history(p_item_id=>%L::uuid,p_limit=>1)',:'chillies'))) AS s(statement);
SELECT pg_temp.ph_assert((SELECT count(*)=0 FROM public.item_price_history),'staff read no history row from the table');
-- A customer account, also with its own customer's id.
SELECT set_config('request.jwt.claims',:'customer_claims',true);
SELECT pg_temp.ph_assert(warehouse_security.active_role()='customer' AND warehouse_security.owns_customer(:'north'::uuid),'actual customer role, assigned to North');
SELECT pg_temp.ph_assert(pg_temp.ph_call(statement)=jsonb_build_object('raised','Staff access required','state','42501'),
 'a customer account is refused: '||statement||' -> '||pg_temp.ph_call(statement)::text)
FROM (VALUES ('SELECT public.get_item_price_history()'),
  (format('SELECT public.get_item_price_history(p_customer_id=>%L::uuid)',:'north'))) AS s(statement);
SELECT pg_temp.ph_assert((SELECT count(*)=0 FROM public.item_price_history),'a customer account reads no history row from the table');
SELECT set_config('request.jwt.claims',:'former_claims',true);
SELECT pg_temp.ph_assert(pg_temp.ph_call('SELECT public.get_item_price_history()')=jsonb_build_object('raised','Active account required','state','42501'),
 'a deactivated supervisor is refused');
RESET ROLE;
SET LOCAL ROLE anon;
SELECT pg_temp.ph_assert(pg_temp.ph_call('SELECT public.get_item_price_history()')->>'state'='42501'
 AND pg_temp.ph_raises('SELECT count(*) FROM public.item_price_history','permission denied%'),'no anonymous access');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- 4. Append-only, and in nobody's way
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ph_assert(pg_temp.ph_raises('UPDATE public.item_price_history SET action=''insert''','permission denied%'),'the administrator cannot rewrite it');
SELECT pg_temp.ph_assert(pg_temp.ph_raises('DELETE FROM public.item_price_history','permission denied%'),'the administrator cannot delete from it');
SELECT pg_temp.ph_assert(pg_temp.ph_raises(format('INSERT INTO public.item_price_history(price_id,action) VALUES (%L,''insert'')',:'south_price'),
 'permission denied%'),'the administrator cannot add to it by hand');
RESET ROLE;
SELECT pg_temp.ph_assert(pg_temp.ph_raises('UPDATE public.item_price_history SET action=''insert''','History table item_price_history cannot be changed'),
 'rows cannot be changed even by the database owner');
SELECT pg_temp.ph_assert(pg_temp.ph_raises('DELETE FROM public.item_price_history','History table item_price_history cannot be changed'),
 'rows cannot be deleted even by the database owner');
SELECT pg_temp.ph_assert(pg_temp.ph_raises('TRUNCATE public.item_price_history','History table item_price_history cannot be changed'),
 'the table cannot be emptied even by the database owner');
-- The history holds no reference: the remaining prices, the item and the
-- profile that appear in it can all be removed, and its rows stay as written.
SET LOCAL ROLE authenticated;
SELECT pg_temp.ph_assert(public.delete_item_storage_price(:'south_price'::uuid)->>'success'='true','the administrator deletes South''s price');
SELECT public.delete_item_safe(:'turmeric'::uuid) AS item_deleted \gset
SELECT pg_temp.ph_assert(:'item_deleted'::jsonb->>'success'='true','the item of a deleted price can be deleted: '||:'item_deleted');
RESET ROLE;
DELETE FROM public.user_profiles WHERE id=:'staff2_profile'::uuid;
SELECT pg_temp.ph_assert((SELECT count(*)=0 FROM public.items WHERE id=:'turmeric'::uuid)
 AND (SELECT count(*)=0 FROM public.user_profiles WHERE id=:'staff2_profile'::uuid)
 AND (SELECT count(*)=2 AND bool_and(h.item_name='Price History Turmeric' AND h.customer_name='Price History South')
        AND bool_or(h.action='insert' AND h.changed_by=:'staff2_profile'::uuid) AND bool_or(h.action='delete' AND h.changed_by=:'admin_profile'::uuid)
      FROM public.item_price_history h WHERE h.item_id=:'turmeric'::uuid),
 'the history outlives the price, the item and the profile');
SET LOCAL ROLE authenticated;
SELECT public.get_item_price_history(p_item_id=>:'turmeric'::uuid) AS after_removal \gset
SELECT pg_temp.ph_assert(:'after_removal'::jsonb#>>'{data,1,item_name}'='Price History Turmeric' AND :'after_removal'::jsonb#>>'{data,1,changed_by}'=:'staff2_profile'
 AND :'after_removal'::jsonb#>>'{data,1,changed_by_name}'='Price History Second Staff' AND :'after_removal'::jsonb#>>'{data,0,changed_by_name}'='Price History Administrator',
 'the RPC still names the item and the removed profile: '||:'after_removal');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- 5. The author's name is the one at the time of the change
-- ---------------------------------------------------------------------------
-- delete_user_account, which every signed-in user may call for the own
-- account, renames the profile to "Deleted User". The staff member who created
-- North's price and the supervisor who changed it delete their accounts: the
-- history still names them, with the role each had.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ph_assert(public.delete_user_account()->>'success'='true','the staff member deletes the own account');
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SELECT pg_temp.ph_assert(public.delete_user_account()->>'success'='true','the supervisor deletes the own account');
RESET ROLE;
SELECT pg_temp.ph_assert((SELECT count(*)=2 AND bool_and(name='Deleted User' AND NOT active) FROM public.user_profiles
  WHERE id IN (:'staff_profile'::uuid,:'supervisor_profile'::uuid)),'both profiles are renamed to Deleted User');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_item_price_history(p_customer_id=>:'north'::uuid) AS after_deletion \gset
SELECT pg_temp.ph_assert((SELECT jsonb_agg(jsonb_build_array(r->'action',r->'changed_by',r->'changed_by_name',r->'changed_by_role'))
   FROM jsonb_array_elements(:'after_deletion'::jsonb->'data') r)
 = jsonb_build_array(
    jsonb_build_array('delete',:'admin_profile','Price History Administrator','admin'),
    jsonb_build_array('update',:'supervisor_profile','Price History Supervisor','supervisor'),
    jsonb_build_array('insert',:'staff_profile','Price History Staff','staff')),
 'the history names its authors after they deleted their accounts: '||:'after_deletion');
RESET ROLE;
-- A row without a stored name shows the profile's present name.
INSERT INTO public.item_price_history(price_id,item_id,item_name,action,changed_by,changed_by_role)
 VALUES (gen_random_uuid(),:'chillies'::uuid,'Price History Chillies','insert',:'admin_profile'::uuid,'admin');
SET LOCAL ROLE authenticated;
SELECT pg_temp.ph_assert(public.get_item_price_history(p_limit=>1)#>>'{data,0,changed_by_name}'='Price History Administrator'
 AND (SELECT h.changed_by_name IS NULL FROM public.item_price_history h ORDER BY h.id DESC LIMIT 1),
 'without a stored name the profile''s present name is shown');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- 6. TRUNCATE of the price table is recorded too
-- ---------------------------------------------------------------------------
-- A row trigger does not fire for TRUNCATE, and the service role and the
-- database owner may truncate the table (no app role may, and PostgREST has no
-- such verb). A statement trigger writes one row: the action, how many prices
-- were removed, and the session's profile if there is one.
SELECT pg_temp.ph_assert(pg_get_triggerdef(t.oid) LIKE '%BEFORE TRUNCATE ON public.item_storage_prices FOR EACH STATEMENT%'
 AND (SELECT p.prosecdef FROM pg_proc p WHERE p.oid=t.tgfoid),
 'a statement trigger records a TRUNCATE of the price table: '||COALESCE(pg_get_triggerdef(t.oid),'no trigger item_price_history_record_truncate'))
FROM (SELECT (SELECT g.oid FROM pg_trigger g WHERE g.tgrelid='public.item_storage_prices'::regclass AND g.tgname='item_price_history_record_truncate') AS oid,
             (SELECT g.tgfoid FROM pg_trigger g WHERE g.tgrelid='public.item_storage_prices'::regclass AND g.tgname='item_price_history_record_truncate') AS tgfoid) t;
SELECT pg_temp.ph_assert(has_table_privilege('service_role','public.item_storage_prices','TRUNCATE')
 AND NOT has_table_privilege('authenticated','public.item_storage_prices','TRUNCATE')
 AND NOT has_table_privilege('anon','public.item_storage_prices','TRUNCATE'),
 'the service role may still truncate the price table; the app role and anonymous callers may not');
SELECT count(*) AS prices_before FROM public.item_storage_prices \gset
SELECT count(*) AS history_before FROM public.item_price_history \gset
SELECT pg_temp.ph_assert(:prices_before>=1,'the price table holds prices before the truncate');
-- As the table owner, outside any app session.
SELECT set_config('request.jwt.claims','{}',true);
TRUNCATE public.item_storage_prices;
SELECT pg_temp.ph_assert((SELECT count(*)=0 FROM public.item_storage_prices)
 AND (SELECT count(*)=:history_before+1 FROM public.item_price_history)
 AND h.action='truncate' AND h.price_id IS NULL AND h.item_id IS NULL AND h.item_name IS NULL AND h.customer_id IS NULL AND h.customer_name IS NULL
 AND h.old_values=jsonb_build_object('rows',:prices_before) AND h.new_values IS NULL
 AND h.changed_by IS NULL AND h.changed_by_name IS NULL AND h.changed_by_role IS NULL AND h.changed_at=now(),
 'the owner''s TRUNCATE leaves one row that says how many prices went: '||to_jsonb(h)::text)
FROM pg_temp.ph_last() h;
-- With the service key, the case of the review finding; and the author is
-- taken from the session when there is one.
INSERT INTO public.item_storage_prices(item_id,customer_id,price_type,unit_price,unit_price_one_time,unit_price_monthly,weight_min,weight_max,labour_rate,tax_percent,effective_from)
 VALUES (:'chillies'::uuid,NULL,'monthly',4,0,4,0,100,1,5,'2026-01-01'),(:'chillies'::uuid,:'north'::uuid,'monthly',6,0,6,0,100,1,5,'2026-01-01');
SELECT set_config('request.jwt.claims','{"role":"service_role"}',true);
SET LOCAL ROLE service_role;
TRUNCATE public.item_storage_prices;
RESET ROLE;
SELECT pg_temp.ph_assert(h.action='truncate' AND h.old_values='{"rows":2}'::jsonb AND h.changed_by IS NULL
 AND (SELECT count(*)=0 FROM public.item_storage_prices),
 'a TRUNCATE with the service key is recorded: '||to_jsonb(h)::text)
FROM pg_temp.ph_last() h;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
TRUNCATE public.item_storage_prices;
SELECT pg_temp.ph_assert(h.action='truncate' AND h.old_values='{"rows":0}'::jsonb AND h.changed_by=:'admin_profile'::uuid
 AND h.changed_by_name='Price History Administrator' AND h.changed_by_role='admin',
 'a TRUNCATE inside a session names the session''s profile: '||to_jsonb(h)::text)
FROM pg_temp.ph_last() h;
-- An app session cannot truncate, and a refused TRUNCATE leaves no row.
SELECT count(*) AS history_after FROM public.item_price_history \gset
SET LOCAL ROLE authenticated;
SELECT pg_temp.ph_assert(pg_temp.ph_raises('TRUNCATE public.item_storage_prices','permission denied%'),'the administrator''s app session cannot truncate the price table');
-- The RPC shows a truncate in the whole history and in every customer's and
-- item's history, since it removed all of their prices.
SELECT pg_temp.ph_assert((SELECT jsonb_agg(r->'action') FROM jsonb_array_elements(public.get_item_price_history(p_limit=>4)->'data') r)
   ='["truncate","truncate","insert","insert"]'::jsonb
 AND public.get_item_price_history(p_limit=>1)#>'{data,0}' @> jsonb_build_object('action','truncate','price_id',NULL,'item_id',NULL,'customer_id',NULL,
   'old_values','{"rows":0}'::jsonb,'new_values',NULL,'changed_by',:'admin_profile','changed_by_name','Price History Administrator','changed_by_role','admin')
 AND (SELECT count(*)=3 FROM jsonb_array_elements(public.get_item_price_history(p_customer_id=>:'south'::uuid)->'data') r WHERE r->>'action'='truncate')
 AND (public.get_item_price_history(p_customer_id=>:'south'::uuid)#>>'{pagination,total}')::int=5
 AND (SELECT count(*)=3 FROM jsonb_array_elements(public.get_item_price_history(p_item_id=>:'turmeric'::uuid)->'data') r WHERE r->>'action'='truncate')
 AND (SELECT count(*)=3 FROM jsonb_array_elements(public.get_item_price_history(:'north'::uuid,:'chillies'::uuid)->'data') r WHERE r->>'action'='truncate')
 AND (SELECT count(*)=3 FROM jsonb_array_elements(public.get_item_price_history(gen_random_uuid())->'data') r),
 'the RPC lists a truncate in the whole history and under every customer and item');
RESET ROLE;
SELECT pg_temp.ph_assert((SELECT count(*)=:history_after FROM public.item_price_history),'a refused TRUNCATE leaves no history row');
ROLLBACK;
\echo 'Item price history: one row per insert, update, delete and truncate, the stored author name, the reading RPC, role and append-only checks passed.'

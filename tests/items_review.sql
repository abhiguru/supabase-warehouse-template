-- Migration of tweak 2026-10-20: create_item / update_item error codes (DUPLICATE_NAME, NOT_FOUND,
-- INVALID_INPUT), update_item keeping `active` when p_active is not sent, get_items searching the
-- packaging text, get_item_usage. Fictional data; runs only in migrations.sh's disposable database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.ir_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'items review: %',label; END IF; END $$;
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
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9555560701','Items Review Admin') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919555560704','Items Review Staff','staff',true,'approved');
SELECT pg_temp.ir_login('9555560701') AS admin_claims \gset
SELECT pg_temp.ir_login('9555560704') AS staff_claims \gset

-- create: a duplicate name (other case, spaces around) is DUPLICATE_NAME, also for a deactivated item
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('IR Mango','25 kg crate','red')$q$) AS c1 \gset
SELECT pg_temp.ir_assert(:'c1'::jsonb->>'success'='true','first create: '||:'c1');
SELECT (:'c1'::jsonb#>>'{data,id}')::uuid AS mango \gset
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('  ir MANGO ')$q$) AS c2 \gset
SELECT pg_temp.ir_assert(:'c2'::jsonb->>'success'='false' AND :'c2'::jsonb->>'error_code'='DUPLICATE_NAME'
  AND :'c2'::jsonb->>'message'='An item with this name already exists','duplicate create: '||:'c2');
UPDATE public.items SET active=false WHERE id=:'mango'::uuid;
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('IR Mango')$q$) AS c3 \gset
SELECT pg_temp.ir_assert(:'c3'::jsonb->>'error_code'='DUPLICATE_NAME','duplicate of a deactivated item: '||:'c3');
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('   ')$q$) AS c4 \gset
SELECT pg_temp.ir_assert(:'c4'::jsonb->>'error_code'='INVALID_INPUT','blank name: '||:'c4');
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,format('SELECT public.create_item(%L)',repeat('x',81))) AS c5 \gset
SELECT pg_temp.ir_assert(:'c5'::jsonb->>'error_code'='INVALID_INPUT','name over 80: '||:'c5');
SELECT pg_temp.ir_as(:'staff_claims'::jsonb,$q$SELECT public.create_item('IR Staff Made')$q$) AS c6 \gset
SELECT pg_temp.ir_assert(:'c6'::jsonb->>'state'='42501','staff are refused by the guard: '||:'c6');

-- update: a second item cannot take the first one's name; NOT_FOUND for a missing item
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('IR Papaya','Box')$q$) AS p1 \gset
SELECT (:'p1'::jsonb#>>'{data,id}')::uuid AS papaya \gset
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,format('SELECT public.update_item(%L,%L)',:'papaya','ir mango')) AS u1 \gset
SELECT pg_temp.ir_assert(:'u1'::jsonb->>'error_code'='DUPLICATE_NAME','duplicate update: '||:'u1');
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,format('SELECT public.update_item(%L,%L)',gen_random_uuid(),'IR Anything')) AS u2 \gset
SELECT pg_temp.ir_assert(:'u2'::jsonb->>'error_code'='NOT_FOUND','missing item: '||:'u2');
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,format('SELECT public.update_item(%L,%L)',:'papaya','')) AS u3 \gset
SELECT pg_temp.ir_assert(:'u3'::jsonb->>'error_code'='INVALID_INPUT','blank name on update: '||:'u3');
-- saving the item under its own name (other case) is fine
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,format('SELECT public.update_item(%L,%L,%L)',:'papaya','IR PAPAYA','Box')) AS u4 \gset
SELECT pg_temp.ir_assert(:'u4'::jsonb->>'success'='true' AND :'u4'::jsonb#>>'{data,name}'='IR PAPAYA','own name, other case: '||:'u4');

-- p_active: not sent keeps the value (both ways); sent sets it
UPDATE public.items SET active=false WHERE id=:'papaya'::uuid;
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,format('SELECT public.update_item(%L,%L,%L)',:'papaya','IR Papaya','Crate')) AS a1 \gset
SELECT pg_temp.ir_assert(:'a1'::jsonb#>>'{data,active}'='false' AND (SELECT NOT active FROM public.items WHERE id=:'papaya'::uuid),
  'p_active not sent keeps an inactive item inactive: '||:'a1');
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,format('SELECT public.update_item(%L,%L,%L,NULL,true)',:'papaya','IR Papaya','Crate')) AS a2 \gset
SELECT pg_temp.ir_assert(:'a2'::jsonb#>>'{data,active}'='true','p_active true reactivates: '||:'a2');
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,format('SELECT public.update_item(%L,%L,%L)',:'papaya','IR Papaya','Crate')) AS a3 \gset
SELECT pg_temp.ir_assert(:'a3'::jsonb#>>'{data,active}'='true','p_active not sent keeps an active item active: '||:'a3');
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,format('SELECT public.update_item(%L,%L,%L,NULL,false)',:'papaya','IR Papaya','Crate')) AS a4 \gset
SELECT pg_temp.ir_assert(:'a4'::jsonb#>>'{data,active}'='false','p_active false deactivates: '||:'a4');
SELECT pg_temp.ir_assert((SELECT count(*)=1 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='update_item')
  AND has_function_privilege('authenticated','public.update_item(uuid,character varying,character varying,character varying,boolean)','EXECUTE')
  AND NOT has_function_privilege('anon','public.update_item(uuid,character varying,character varying,character varying,boolean)','EXECUTE'),
  'update_item has one overload with the same grants');

-- get_items: the search matches the packaging text
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,$q$SELECT public.get_items('crate',false)$q$) AS g1 \gset
SELECT pg_temp.ir_assert((SELECT array_agg(i->>'name' ORDER BY i->>'name')=ARRAY['IR Mango','IR Papaya']
  FROM jsonb_array_elements(:'g1'::jsonb#>'{data,items}') i) AND (:'g1'::jsonb#>>'{data,total_count}')='2','search by packaging: '||:'g1');
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,$q$SELECT public.get_items('red',false)$q$) AS g2 \gset
SELECT pg_temp.ir_assert((:'g2'::jsonb#>>'{data,total_count}')='1','search by description still works: '||:'g2');

-- get_item_usage
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,format('SELECT public.get_item_usage(%L)',:'papaya')) AS s1 \gset
SELECT pg_temp.ir_assert(:'s1'::jsonb->>'success'='true' AND (:'s1'::jsonb#>>'{data,grn_lines}')='0'
  AND (:'s1'::jsonb#>>'{data,in_use}')='false' AND (:'s1'::jsonb#>>'{data,can_delete}')='true','unused item: '||:'s1');
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,format('SELECT public.get_item_usage(%L)',gen_random_uuid())) AS s2 \gset
SELECT pg_temp.ir_assert(:'s2'::jsonb->>'error_code'='NOT_FOUND','usage of a missing item: '||:'s2');
SELECT pg_temp.ir_as(:'staff_claims'::jsonb,format('SELECT public.get_item_usage(%L)',:'papaya')) AS s3 \gset
SELECT pg_temp.ir_assert(:'s3'::jsonb->>'state'='42501','staff are refused: '||:'s3');

-- get_item_usage on an item in use (one GRN line, two price rows in one rate) and delete_item_safe
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,$q$SELECT public.create_customer('IR Orchard','9555560711')$q$) AS cc \gset
SELECT pg_temp.ir_assert(:'cc'::jsonb->>'success'='true','customer: '||:'cc');
SELECT id AS orchard FROM public.customers WHERE name='IR Orchard' \gset
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('IR Guava','Bag')$q$) AS gv \gset
SELECT (:'gv'::jsonb#>>'{data,id}')::uuid AS guava \gset
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,format($q$SELECT public.save_grn(p_gr_no=>'IR-1',p_date=>%L::timestamptz,p_customer_id=>%L::uuid,
  p_customer_name=>'x',p_pricing_mode=>'MONTHLY',p_items=>%L::jsonb)$q$,(current_date-3)::text||'T12:00:00Z',:'orchard',
  jsonb_build_array(jsonb_build_object('item_id',:'guava','item_name','IR Guava','packaging','Bag','qty',2,'weight',10,'rack','R1')))) AS sg \gset
SELECT pg_temp.ir_assert(:'sg'::jsonb->>'success'='true','GRN with one line of the item: '||:'sg');
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,format($q$SELECT public.create_item_storage_price(p_item_id=>%L::uuid,p_price_type=>'monthly',p_unit_price=>7,
  p_weight_min=>0,p_weight_max=>50,p_labour_rate=>1,p_effective_from=>%L,p_tax_percent=>5)$q$,:'guava',current_date::text)) AS pr1 \gset
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,format($q$SELECT public.create_item_storage_price(p_item_id=>%L::uuid,p_price_type=>'monthly',p_unit_price=>8,
  p_weight_min=>51,p_weight_max=>100,p_labour_rate=>1,p_effective_from=>%L,p_tax_percent=>5)$q$,:'guava',current_date::text)) AS pr2 \gset
SELECT pg_temp.ir_assert(:'pr1'::jsonb->>'success'='true' AND :'pr2'::jsonb->>'success'='true','two price rows: '||:'pr1'||' '||:'pr2');
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,format('SELECT public.get_item_usage(%L)',:'guava')) AS s4 \gset
SELECT pg_temp.ir_assert((:'s4'::jsonb#>>'{data,grn_lines}')='1' AND (:'s4'::jsonb#>>'{data,in_use}')='true'
  AND (:'s4'::jsonb#>>'{data,can_delete}')='false' AND (:'s4'::jsonb#>>'{data,price_rows}')='2'
  AND (:'s4'::jsonb#>>'{data,rate_count}')='1'
  AND (:'s4'::jsonb#>>'{data,grn_rates}')::int=(SELECT count(*) FROM public.grn_rates WHERE item_id=:'guava'::uuid),'item in use: '||:'s4');
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,format('SELECT public.delete_item_safe(%L)',:'guava')) AS d1 \gset
SELECT pg_temp.ir_assert(:'d1'::jsonb->>'success'='false' AND EXISTS (SELECT 1 FROM public.items WHERE id=:'guava'::uuid),'delete_item_safe refuses the item in use: '||:'d1');
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,format('SELECT public.delete_item_safe(%L)',:'papaya')) AS d2 \gset
SELECT pg_temp.ir_assert(:'d2'::jsonb->>'success'='true' AND NOT EXISTS (SELECT 1 FROM public.items WHERE id=:'papaya'::uuid),'delete_item_safe deletes the unused item: '||:'d2');

-- older data: two items that differ only in case stay editable under their own name; null p_active on create
INSERT INTO public.items(name,active) VALUES ('IR Twin',true),('ir twin',true);
SELECT id AS twin FROM public.items WHERE name='IR Twin' \gset
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,format('SELECT public.update_item(%L,%L,%L)',:'twin','IR Twin','Box')) AS t1 \gset
SELECT pg_temp.ir_assert(:'t1'::jsonb->>'success'='true','unchanged name of an older duplicate can be saved: '||:'t1');
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,format('SELECT public.update_item(%L,%L)',:'twin','IR TWIN')) AS t2 \gset
SELECT pg_temp.ir_assert(:'t2'::jsonb->>'error_code'='DUPLICATE_NAME','changing the case onto another item is refused: '||:'t2');
SELECT pg_temp.ir_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('IR Null Active','Bag',NULL,NULL)$q$) AS n1 \gset
SELECT pg_temp.ir_assert(:'n1'::jsonb#>>'{data,active}'='true','p_active NULL on create means active: '||:'n1');
ROLLBACK;

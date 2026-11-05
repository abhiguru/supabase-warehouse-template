-- Migrations 144 and 145 (WH-41, WH-42): an item is its name and its packaging word, and staff may add an item.
--   * the word rule: warehouse_security.clean_packaging / packaging_key / packaging_word (case, plurals, blank = Bag, invisible characters);
--   * the same name with another word is another item; the same name and word (any spelling of it) is DUPLICATE_NAME; the unique key refuses it too;
--   * create_item and update_item require a word; an old item with no word can still be switched off and on;
--   * the stored word has its outer spaces and invisible characters removed;
--   * staff create an active item with a name and a word and no rate, even when the facility has a standard rate; a rate source or an inactive item is
--     refused for staff; administrators still copy or give the standard rate; a customer account is refused.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database; rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.w_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'item word 144: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.w_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.w_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.w_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
CREATE FUNCTION pg_temp.w_as(claims jsonb, statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
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
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='WDTEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9877777771','Word Test Administrator') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919877777772','Word Test Staff','staff',true,'approved'),
 (gen_random_uuid(),'919877777773','Word Test Reader','customer',true,'approved');
SELECT pg_temp.w_login('9877777771') AS admin_claims \gset
SELECT pg_temp.w_login('9877777772') AS staff_claims \gset
SELECT pg_temp.w_login('9877777773') AS customer_claims \gset

-- 1. The rule, case by case. Invisible characters: no-break space, figure space, narrow no-break space, zero-width no-break space.
SELECT pg_temp.w_assert(NOT has_function_privilege('authenticated','warehouse_security.packaging_key(text)','EXECUTE')
 AND NOT has_function_privilege('authenticated','warehouse_security.packaging_word(text)','EXECUTE')
 AND NOT has_function_privilege('authenticated','warehouse_security.clean_packaging(text)','EXECUTE'),'the three helpers are internal');
SELECT pg_temp.w_assert(warehouse_security.packaging_key(NULL)='bag' AND warehouse_security.packaging_key('')='bag' AND warehouse_security.packaging_key('  ')='bag'
 AND warehouse_security.packaging_key(' Bags ')='bag' AND warehouse_security.packaging_key('BAG')='bag','Bag, bags, blank and NULL are one key');
SELECT pg_temp.w_assert(warehouse_security.packaging_key('Box')='box' AND warehouse_security.packaging_key('BOXES')='box' AND warehouse_security.packaging_key('boxs') <> 'box','Box and Boxes are one key, Boxs is not');
SELECT pg_temp.w_assert(warehouse_security.packaging_key('Crate')='crate' AND warehouse_security.packaging_key('crates')='crate','Crate and Crates are one key');
SELECT pg_temp.w_assert(warehouse_security.packaging_key('Katta')='katta' AND warehouse_security.packaging_key('Katta') <> warehouse_security.packaging_key('Kattas')
 AND warehouse_security.packaging_key('Unit') <> 'bag' AND warehouse_security.packaging_key('Trey') <> warehouse_security.packaging_key('Unit'),'any other word is its own key');
SELECT pg_temp.w_assert(warehouse_security.packaging_key(chr(160)||'Box'||chr(160))='box' AND warehouse_security.packaging_key(chr(8199)||'Box')='box'
 AND warehouse_security.packaging_key('Box'||chr(8239))='box' AND warehouse_security.packaging_key(chr(65279)||'Box')='box' AND warehouse_security.packaging_key(chr(160))='bag',
 'invisible characters at the ends never change a word (WH-9)');
SELECT pg_temp.w_assert(warehouse_security.packaging_word(' bags ')='Bag' AND warehouse_security.packaging_word(NULL)='Bag' AND warehouse_security.packaging_word('BOXES')='Box'
 AND warehouse_security.packaging_word('crates')='Crate','Bag, Box and Crate are shown in their own spelling');
SELECT pg_temp.w_assert(warehouse_security.packaging_word(chr(160)||' Katta ')='Katta' AND warehouse_security.packaging_word('trey')='trey' AND warehouse_security.packaging_word('Sack Bag')='Sack Bag',
 'any other word is shown as typed, outer spaces removed');
SELECT pg_temp.w_assert(warehouse_security.shared_packaging(ARRAY['Katta',chr(160)||'Katta'])='Katta' AND warehouse_security.shared_packaging(ARRAY['Katta','Trey']) IS NULL
 AND warehouse_security.shared_packaging(ARRAY['Box','Boxes'])='Box','shared_packaging follows the key');

-- 2. create_item: the word is required; the same name with another word is another item; the same name and word is a duplicate.
SELECT pg_temp.w_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('Word Egg','Box')$q$) AS e1 \gset
SELECT pg_temp.w_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('Word Egg','Trey')$q$) AS e2 \gset
SELECT pg_temp.w_assert(:'e1'::jsonb->>'success'='true' AND :'e2'::jsonb->>'success'='true' AND :'e1'::jsonb#>>'{data,id}' <> :'e2'::jsonb#>>'{data,id}'
 AND (SELECT count(*)=2 FROM public.items WHERE name='Word Egg'),'Word Egg + Box and Word Egg + Trey are two items: '||:'e1'||:'e2');
SELECT pg_temp.w_as(:'admin_claims'::jsonb,$q$SELECT public.create_item(' word EGG ','BOXES')$q$) AS e3 \gset
SELECT pg_temp.w_assert(:'e3'::jsonb->>'error_code'='DUPLICATE_NAME' AND :'e3'::jsonb->>'message'='An item with this name and packaging already exists','same name and word, other spelling: '||:'e3');
SELECT pg_temp.w_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('Word Egg','trey ')$q$) AS e3b \gset
SELECT pg_temp.w_assert(:'e3b'::jsonb->>'error_code'='DUPLICATE_NAME','Trey and "trey " are one word: '||:'e3b');
SELECT pg_temp.w_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('Word Egg')$q$) AS e4 \gset
SELECT pg_temp.w_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('Word Egg','   ')$q$) AS e5 \gset
SELECT pg_temp.w_as(:'admin_claims'::jsonb,format($q$SELECT public.create_item('Word Egg',%L)$q$,chr(160))) AS e6 \gset
SELECT pg_temp.w_assert(:'e4'::jsonb->>'error_code'='INVALID_INPUT' AND :'e4'::jsonb->>'message'='Packaging is required'
 AND :'e5'::jsonb->>'message'='Packaging is required' AND :'e6'::jsonb->>'message'='Packaging is required','no word, blank word and an invisible-only word are refused: '||:'e4'||:'e5'||:'e6');
SELECT pg_temp.w_as(:'admin_claims'::jsonb,format($q$SELECT public.create_item('Word Pot',%L)$q$,chr(160)||'Katta'||chr(65279))) AS p1 \gset
SELECT pg_temp.w_assert(:'p1'::jsonb->>'success'='true' AND :'p1'::jsonb#>>'{data,packaging}'='Katta' AND (SELECT packaging='Katta' FROM public.items WHERE name='Word Pot'),
 'the stored word has its outer spaces and invisible characters removed: '||:'p1');
-- The unique key (name, word key): an old item with no word is the word Bag.
INSERT INTO public.items(name,packaging) VALUES ('Word Old',NULL);
SELECT pg_temp.w_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('Word Old','Bag')$q$) AS o1 \gset
SELECT pg_temp.w_assert(:'o1'::jsonb->>'error_code'='DUPLICATE_NAME','a Bag duplicates an old item with no word: '||:'o1');
DO $$ BEGIN
  BEGIN INSERT INTO public.items(name,packaging) VALUES ('Word Old','bags'); RAISE EXCEPTION 'no unique violation';
  EXCEPTION WHEN unique_violation THEN IF NOT (SQLERRM LIKE '%items_name_packaging_key%') THEN RAISE; END IF; END;
END $$;
SELECT pg_temp.w_assert(NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='items_name_key') AND EXISTS (SELECT 1 FROM pg_indexes WHERE indexname='items_name_packaging_key'),
 'the key on the name alone is replaced by the key on name and word');

-- 3. update_item: the word is required, except for a call that only switches an old item with no word off or on.
SELECT id AS old_id FROM public.items WHERE name='Word Old' \gset
SELECT pg_temp.w_as(:'admin_claims'::jsonb,format('SELECT public.update_item(%L,%L,NULL,NULL,false)',:'old_id','Word Old')) AS u1 \gset
SELECT pg_temp.w_assert(:'u1'::jsonb->>'success'='true' AND (SELECT NOT active FROM public.items WHERE id=:'old_id'::uuid),'an old item with no word can be switched off: '||:'u1');
SELECT pg_temp.w_as(:'admin_claims'::jsonb,format('SELECT public.update_item(%L,%L,NULL,NULL,true)',:'old_id','Word Old')) AS u2 \gset
SELECT pg_temp.w_assert(:'u2'::jsonb->>'success'='true' AND (SELECT active FROM public.items WHERE id=:'old_id'::uuid),'and on again: '||:'u2');
SELECT pg_temp.w_as(:'admin_claims'::jsonb,format('SELECT public.update_item(%L,%L)',:'old_id','Word Old Renamed')) AS u3 \gset
SELECT pg_temp.w_assert(:'u3'::jsonb->>'error_code'='INVALID_INPUT' AND :'u3'::jsonb->>'message'='Packaging is required' AND (SELECT name='Word Old' FROM public.items WHERE id=:'old_id'::uuid),
 'a rename without a word is refused and changes nothing: '||:'u3');
SELECT pg_temp.w_as(:'admin_claims'::jsonb,format('SELECT public.update_item(%L,%L,%L)',:'old_id','Word Old','Sack')) AS u4 \gset
SELECT pg_temp.w_assert(:'u4'::jsonb->>'success'='true' AND :'u4'::jsonb#>>'{data,packaging}'='Sack','a save with a word works: '||:'u4');
SELECT pg_temp.w_as(:'admin_claims'::jsonb,format('SELECT public.update_item(%L,%L,%L)',:'old_id','word egg','BOX')) AS u5 \gset
SELECT pg_temp.w_assert(:'u5'::jsonb->>'error_code'='DUPLICATE_NAME' AND :'u5'::jsonb->>'message'='An item with this name and packaging already exists','update onto another item''s name and word: '||:'u5');
SELECT pg_temp.w_as(:'admin_claims'::jsonb,format('SELECT public.update_item(%L,%L,%L)',:'old_id','Word Egg','Katta')) AS u6 \gset
SELECT pg_temp.w_assert(:'u6'::jsonb->>'success'='true','the same name with a third word is allowed: '||:'u6');

-- 4. Staff add an item (migration 145): name and word only; active; no rate.
SELECT pg_temp.w_as(:'admin_claims'::jsonb,$q$SELECT public.set_standard_rate('[{"weight_min":0,"weight_max":100,"unit_price":3,"labour_rate":1,"tax_percent":5}]'::jsonb)$q$) AS std \gset
SELECT pg_temp.w_assert(:'std'::jsonb->>'success'='true','a standard rate is set: '||:'std');
SELECT pg_temp.w_as(:'admin_claims'::jsonb,$q$SELECT public.create_item('Word Admin Item','Bag')$q$) AS a1 \gset
SELECT pg_temp.w_assert(:'a1'::jsonb->>'success'='true' AND :'a1'::jsonb#>>'{data,rate_source}'='standard'
 AND EXISTS (SELECT 1 FROM public.item_storage_prices WHERE item_id=(:'a1'::jsonb#>>'{data,id}')::uuid),'an administrator''s item gets the standard rate as before: '||:'a1');
SELECT pg_temp.w_as(:'staff_claims'::jsonb,$q$SELECT public.create_item('Word Staff Item','Katta')$q$) AS s1 \gset
SELECT pg_temp.w_assert(:'s1'::jsonb->>'success'='true' AND :'s1'::jsonb#>>'{data,active}'='true' AND :'s1'::jsonb#>>'{data,packaging}'='Katta'
 AND :'s1'::jsonb#>>'{data,rate_source}'='none' AND NOT EXISTS (SELECT 1 FROM public.item_storage_prices WHERE item_id=(:'s1'::jsonb#>>'{data,id}')::uuid),
 'staff add an active item with no rate even though a standard rate exists: '||:'s1');
SELECT pg_temp.w_as(:'staff_claims'::jsonb,format($q$SELECT public.create_item('Word Staff Copy','Katta',NULL,true,%L::uuid)$q$,:'a1'::jsonb#>>'{data,id}')) AS s2 \gset
SELECT pg_temp.w_as(:'staff_claims'::jsonb,$q$SELECT public.create_item('Word Staff Inactive','Katta',NULL,false)$q$) AS s3 \gset
SELECT pg_temp.w_assert(:'s2'::jsonb->>'error_code'='PERMISSION_DENIED' AND :'s3'::jsonb->>'error_code'='PERMISSION_DENIED'
 AND NOT EXISTS (SELECT 1 FROM public.items WHERE name IN ('Word Staff Copy','Word Staff Inactive')),'staff cannot copy a rate or add an inactive item: '||:'s2'||:'s3');
SELECT pg_temp.w_as(:'staff_claims'::jsonb,$q$SELECT public.create_item('Word Staff Item','katta')$q$) AS s4 \gset
SELECT pg_temp.w_as(:'staff_claims'::jsonb,$q$SELECT public.create_item('Word Staff No Word')$q$) AS s5 \gset
SELECT pg_temp.w_assert(:'s4'::jsonb->>'error_code'='DUPLICATE_NAME' AND :'s5'::jsonb->>'message'='Packaging is required','staff get the same duplicate and word rules: '||:'s4'||:'s5');
SELECT pg_temp.w_as(:'staff_claims'::jsonb,format('SELECT public.update_item(%L,%L,%L)',:'old_id','Word Old','Sack')) AS s6 \gset
SELECT pg_temp.w_assert(:'s6'::jsonb->>'error_code'='PERMISSION_DENIED','staff still cannot update an item: '||:'s6');
SELECT pg_temp.w_as(:'customer_claims'::jsonb,$q$SELECT public.create_item('Word Customer Item','Bag')$q$) AS c1 \gset
SELECT pg_temp.w_assert(:'c1'::jsonb->>'state'='42501' AND NOT EXISTS (SELECT 1 FROM public.items WHERE name='Word Customer Item'),'a customer account is refused: '||:'c1');
ROLLBACK;

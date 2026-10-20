-- Owner follow-ups (2026-10-20): Activate refused on a shared mobile (set_customer_active, update_customer, restore_customer); customer assignments only for the Customer role. Fictional data.
-- Runs only in migrations.sh's disposable, network-disabled database. Uses the existing operator test-session lifecycle.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.of_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'owner follow-ups: %',label; END IF; END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
CREATE FUNCTION pg_temp.of_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.of_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.of_assert(l#>>'{data,action}'='login','mocked operator login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
CREATE FUNCTION pg_temp.of_call(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RETURN answer;
END $$;
SELECT warehouse_security.bootstrap_first_admin('9777700001','Followups Admin') AS admin_user \gset
SELECT pg_temp.of_login('9777700001') AS admin_claims \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919777700021','Followups Staff','staff',true,'approved'),
 (gen_random_uuid(),'919777700022','Followups Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919777700023','Followups Customer','customer',true,'approved');
-- H* hold a number; T* are the deactivated customers being switched on. T1/H1 differ in form (12-digit 91... vs 10 digits) but share a key.
INSERT INTO public.customers(name,mobile,active) VALUES
 ('OF H1','9777700011',true),('OF T1','919777700011',false),
 ('OF T4','9777700014',false),('OF T5','9777700015',false),
 ('OF H8','9777700018',true),('OF T8','9777700018',false),
 ('OF T3 nomobile',NULL,false),('OF T3b nomobile',NULL,true);
INSERT INTO public.customers(name,mobile,active,deleted_at) VALUES ('OF H2 gone','9777700012',true,now());
INSERT INTO public.customers(name,mobile,active) VALUES ('OF T2','9777700012',false);
SELECT id AS h1 FROM public.customers WHERE name='OF H1' \gset
SELECT id AS t1 FROM public.customers WHERE name='OF T1' \gset
SELECT id AS t2 FROM public.customers WHERE name='OF T2' \gset
SELECT id AS h2 FROM public.customers WHERE name='OF H2 gone' \gset
SELECT id AS t3 FROM public.customers WHERE name='OF T3 nomobile' \gset
SELECT id AS t4 FROM public.customers WHERE name='OF T4' \gset
SELECT id AS t5 FROM public.customers WHERE name='OF T5' \gset
SELECT id AS h8 FROM public.customers WHERE name='OF H8' \gset
SELECT id AS t8 FROM public.customers WHERE name='OF T8' \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;

-- 1. set_customer_active(true) refused: another active customer uses the same key (different form); T1 stays inactive.
SELECT public.set_customer_active(:'t1'::uuid,true) AS r \gset
SELECT pg_temp.of_assert(:'r'::jsonb->>'success'='false' AND :'r'::jsonb#>>'{error,code}'='DUPLICATE_MOBILE' AND :'r'::jsonb#>>'{error,field}'='mobile'
 AND :'r'::jsonb#>>'{error,details,customer_id}'=:'h1' AND :'r'::jsonb#>>'{error,details,name}'='OF H1' AND :'r'::jsonb#>>'{error,details,active}'='true'
 AND :'r'::jsonb->>'message'='OF H1 already uses this mobile number. Change one of the numbers first.',
 'Activate refused, names the other customer: '||:'r');
SELECT pg_temp.of_assert((SELECT NOT active FROM public.customers WHERE id=:'t1'::uuid),'the refused customer stays inactive');
-- 2. Same customer once the holder is deactivated: allowed.
SELECT public.set_customer_active(:'h1'::uuid,false) AS r \gset
SELECT public.set_customer_active(:'t1'::uuid,true) AS r2 \gset
SELECT pg_temp.of_assert(:'r'::jsonb->>'success'='true' AND :'r2'::jsonb->>'success'='true' AND (SELECT active FROM public.customers WHERE id=:'t1'::uuid),
 'Activate allowed when the holder is deactivated: '||:'r2');
-- 3. The other holder is deleted: allowed.
SELECT public.set_customer_active(:'t2'::uuid,true) AS r \gset
SELECT pg_temp.of_assert(:'r'::jsonb->>'success'='true' AND (SELECT active FROM public.customers WHERE id=:'t2'::uuid),'Activate allowed when the holder is deleted: '||:'r');
-- 3b. Switching on a DELETED customer whose number another active customer now has (T2 is active since test 3): refused, H2 stays deleted.
SELECT public.set_customer_active(:'h2'::uuid,true) AS r1, public.update_customer(:'h2'::uuid, p_active=>true) AS r2, public.restore_customer(:'h2'::uuid) AS r3 \gset
SELECT pg_temp.of_assert(:'r1'::jsonb#>>'{error,code}'='DUPLICATE_MOBILE' AND :'r1'::jsonb#>>'{error,details,customer_id}'=:'t2' AND :'r1'::jsonb#>>'{error,details,name}'='OF T2'
 AND :'r2'::jsonb#>>'{error,code}'='DUPLICATE_MOBILE' AND :'r2'::jsonb#>>'{error,details,name}'='OF T2'
 AND :'r3'::jsonb#>>'{error,code}'='DUPLICATE_MOBILE' AND :'r3'::jsonb#>>'{error,details,name}'='OF T2'
 AND (SELECT deleted_at IS NOT NULL FROM public.customers WHERE id=:'h2'::uuid),
 'deleted customer cannot be switched on over a shared number, stays deleted: '||:'r1'||:'r2'||:'r3');
-- 3c. Edit and Activate in one call to a number another active customer has: the Activate sentence, not the Edit one.
SELECT public.update_customer(:'t4'::uuid, p_mobile=>'9777700018', p_active=>true) AS r \gset
SELECT pg_temp.of_assert(:'r'::jsonb#>>'{error,code}'='DUPLICATE_MOBILE' AND :'r'::jsonb->>'message'='OF H8 already uses this mobile number. Change one of the numbers first.'
 AND (SELECT NOT active AND mobile='9777700014' FROM public.customers WHERE id=:'t4'::uuid),'Edit + Activate onto a taken number uses the Activate sentence: '||:'r');
SELECT public.update_customer(:'t4'::uuid, p_mobile=>'9777700018') AS r \gset
SELECT pg_temp.of_assert(:'r'::jsonb->>'message'='A customer with this mobile number already exists','Edit alone keeps the Edit sentence: '||:'r');
-- 4. No mobile: never refused, although another no-mobile customer is active.
SELECT public.set_customer_active(:'t3'::uuid,true) AS r \gset
SELECT pg_temp.of_assert(:'r'::jsonb->>'success'='true' AND (SELECT active FROM public.customers WHERE id=:'t3'::uuid),'Activate allowed for a customer without a mobile: '||:'r');
-- 5. Other answers of set_customer_active are unchanged (no code).
SELECT public.set_customer_active(gen_random_uuid(),true) AS missing, public.set_customer_active(:'t3'::uuid,true) AS again \gset
SELECT pg_temp.of_assert(:'missing'::jsonb->>'message'='Customer not found' AND :'missing'::jsonb->'error' IS NULL
 AND :'again'::jsonb->>'success'='true' AND :'again'::jsonb->>'message' LIKE '%already active',
 'unknown id and already-active answers unchanged: '||:'missing'||:'again');
-- 6. update_customer(p_active=>true): refused on a shared number, row unchanged.
SELECT public.set_customer_active(:'t1'::uuid,false) AS r0 \gset
SELECT public.set_customer_active(:'h1'::uuid,true) AS r \gset
SELECT pg_temp.of_assert(:'r'::jsonb->>'success'='true' AND (SELECT active FROM public.customers WHERE id=:'h1'::uuid) AND (SELECT NOT active FROM public.customers WHERE id=:'t1'::uuid),'set-up: H1 active again, T1 inactive: '||:'r');
SELECT public.update_customer(:'t1'::uuid, p_active=>true) AS r \gset
SELECT pg_temp.of_assert(:'r'::jsonb#>>'{error,code}'='DUPLICATE_MOBILE' AND :'r'::jsonb#>>'{error,details,customer_id}'=:'h1'
 AND :'r'::jsonb#>>'{error,details,name}'='OF H1' AND (SELECT NOT active FROM public.customers WHERE id=:'t1'::uuid),
 'update_customer Activate refused, row unchanged: '||:'r');
-- 6b. A name sent in the same call is not applied when refused.
SELECT public.update_customer(:'t1'::uuid, p_name=>'OF T1 renamed', p_active=>true) AS r \gset
SELECT pg_temp.of_assert(:'r'::jsonb#>>'{error,code}'='DUPLICATE_MOBILE' AND (SELECT name='OF T1' FROM public.customers WHERE id=:'t1'::uuid),'nothing else changed on refusal: '||:'r');
-- 6c. A new number sent with the activation is the one checked: T1 moves to a free number and activates.
SELECT public.update_customer(:'t1'::uuid, p_mobile=>'9777700019', p_active=>true) AS r \gset
SELECT pg_temp.of_assert(:'r'::jsonb->>'success'='true' AND (SELECT active AND mobile='9777700019' FROM public.customers WHERE id=:'t1'::uuid),
 'new free number with Activate allowed: '||:'r');
-- 6d. Free number activation, no clash.
SELECT public.update_customer(:'t4'::uuid, p_active=>true) AS r \gset
SELECT pg_temp.of_assert(:'r'::jsonb->>'success'='true' AND (SELECT active FROM public.customers WHERE id=:'t4'::uuid),'update_customer Activate allowed without a clash: '||:'r');
-- 7. Already active: a normal edit (even p_active=>true) is not re-checked. Two active customers share a number (rows written before the role switch).
RESET ROLE;
INSERT INTO public.customers(name,mobile,active) VALUES ('OF Twin A','9777700030',true),('OF Twin B','9777700030',true);
SELECT id AS twin_b FROM public.customers WHERE name='OF Twin B' \gset
SET LOCAL ROLE authenticated;
SELECT public.update_customer(:'twin_b'::uuid, p_city=>'Surat') AS r1, public.update_customer(:'twin_b'::uuid, p_active=>true) AS r2 \gset
SELECT pg_temp.of_assert(:'r1'::jsonb->>'success'='true' AND :'r2'::jsonb->>'success'='true' AND (SELECT city='Surat' FROM public.customers WHERE id=:'twin_b'::uuid),
 'normal edit of an active customer is not re-checked: '||:'r1'||:'r2');
-- 8. restore_customer: refused on a shared number, allowed otherwise.
SELECT public.restore_customer(:'t8'::uuid) AS r \gset
SELECT pg_temp.of_assert(:'r'::jsonb#>>'{error,code}'='DUPLICATE_MOBILE' AND :'r'::jsonb#>>'{error,details,customer_id}'=:'h8'
 AND (SELECT NOT active FROM public.customers WHERE id=:'t8'::uuid),'restore_customer refused on a shared number: '||:'r');
SELECT public.restore_customer(:'t5'::uuid) AS r \gset
SELECT pg_temp.of_assert(:'r'::jsonb->>'success'='true' AND (SELECT active FROM public.customers WHERE id=:'t5'::uuid),'restore_customer allowed without a clash: '||:'r');
-- 9. Customer assignments: refused for staff and supervisor, still work for a customer; removal from a non-customer still works.
SELECT pg_temp.of_call(format('SELECT to_jsonb(public.assign_customer_to_user(%L,%L::uuid))','919777700021',:'t4')) AS a_staff,
       pg_temp.of_call(format('SELECT to_jsonb(public.assign_customer_to_user(%L,%L::uuid))','919777700022',:'t4')) AS a_sup,
       pg_temp.of_call(format('SELECT to_jsonb(public.assign_customer_to_user(%L,%L::uuid))','919777700023',:'t4')) AS a_cust \gset
SELECT pg_temp.of_assert(:'a_staff'::jsonb->>'raised'='ROLE_NOT_CUSTOMER: Customer assignments apply only to the Customer role.'
 AND :'a_sup'::jsonb->>'raised' LIKE 'ROLE_NOT_CUSTOMER: %' AND :'a_cust'::jsonb#>>'{}'='true',
 'assign: staff and supervisor refused, customer works: '||:'a_staff'||:'a_sup'||:'a_cust');
RESET ROLE;
SELECT pg_temp.of_assert((SELECT count(*)=0 FROM public.users_customers_new WHERE user_profile_id IN (SELECT id FROM public.user_profiles WHERE mobile IN ('919777700021','919777700022')))
 AND (SELECT count(*)=1 FROM public.users_customers_new u JOIN public.user_profiles p ON p.id=u.user_profile_id WHERE p.mobile='919777700023' AND u.active),
 'no assignment row written for staff or supervisor; one active for the customer');
-- a stale assignment of a person who is no longer a customer can still be removed
UPDATE public.user_profiles SET role='staff' WHERE mobile='919777700023';
SET LOCAL ROLE authenticated;
SELECT pg_temp.of_call(format('SELECT to_jsonb(public.remove_customer_assignment(%L,%L::uuid))','919777700023',:'t4')) AS rm \gset
RESET ROLE;
SELECT pg_temp.of_assert(:'rm'::jsonb#>>'{}'='true' AND (SELECT count(*)=0 FROM public.users_customers_new u JOIN public.user_profiles p ON p.id=u.user_profile_id WHERE p.mobile='919777700023' AND u.active),
 'removal from a non-customer still works: '||:'rm');
-- 10. Items: a stored name with a trailing space is not re-checked when sent unchanged (update_item compares with TRIM of the stored name).
RESET ROLE;
INSERT INTO public.items(name,active) VALUES ('OF Garlic ',true),('of garlic',true),('OF Rice',false),('OF Wheat',false);
SELECT id AS garlic FROM public.items WHERE name='OF Garlic ' \gset
SELECT id AS rice FROM public.items WHERE name='OF Rice' \gset
SELECT id AS wheat FROM public.items WHERE name='OF Wheat' \gset
INSERT INTO public.standard_rate_tiers(weight_min,weight_max,unit_price,labour_rate,tax_percent) VALUES (0,50,10,1,0); -- the standard rate is empty on a fresh database
SET LOCAL ROLE authenticated;
SELECT public.update_item(:'garlic'::uuid,'OF Garlic') AS r \gset
SELECT pg_temp.of_assert(:'r'::jsonb->>'success'='true' AND (SELECT name='OF Garlic' FROM public.items WHERE id=:'garlic'::uuid),'unchanged name (stored with a trailing space) is not refused as a duplicate: '||:'r');
-- 11. Items: rate_source 'standard' when switching an item on gave it the standard tiers; not when it already had a default rate or stays as it is.
SELECT public.update_item(:'rice'::uuid,'OF Rice',NULL,NULL,true) AS on1 \gset
SELECT public.update_item(:'rice'::uuid,'OF Rice',NULL,NULL,false) AS off1 \gset
SELECT public.update_item(:'rice'::uuid,'OF Rice',NULL,NULL,true) AS on2 \gset
SELECT public.update_item(:'wheat'::uuid,'OF Wheat') AS keep \gset
SELECT pg_temp.of_assert(:'on1'::jsonb#>>'{data,rate_source}'='standard' AND :'on1'::jsonb#>>'{data,active}'='true'
 AND :'off1'::jsonb#>'{data,rate_source}' IS NULL AND :'on2'::jsonb#>'{data,rate_source}' IS NULL AND :'on2'::jsonb#>>'{data,active}'='true'
 AND :'keep'::jsonb#>'{data,rate_source}' IS NULL,
 'rate_source only when the standard tiers were just given: '||:'on1'||:'on2'||:'keep');
-- 12. Items: delete_item_safe of an unknown item answers error_code NOT_FOUND (message unchanged).
SELECT public.delete_item_safe(gen_random_uuid()) AS r \gset
SELECT pg_temp.of_assert(:'r'::jsonb->>'success'='false' AND :'r'::jsonb->>'error_code'='NOT_FOUND' AND :'r'::jsonb->>'message'='Item not found','delete_item_safe unknown item: '||:'r');
RESET ROLE;
ROLLBACK;
\echo 'Owner follow-ups checks passed.'

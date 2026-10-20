-- Customer name rule (2026-10-20): names that differ only in capitals or spaces are one name. Fictional data.
-- Runs only in migrations.sh's disposable, network-disabled database. Uses the existing operator test-session lifecycle.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.nr_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'customer name rule: %',label; END IF; END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
CREATE FUNCTION pg_temp.nr_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.nr_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.nr_assert(l#>>'{data,action}'='login','mocked operator login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
CREATE FUNCTION pg_temp.nr_call(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RETURN answer;
END $$;
SELECT warehouse_security.bootstrap_first_admin('9766600001','NameRule Admin') AS admin_user \gset
SELECT pg_temp.nr_login('9766600001') AS admin_claims \gset
-- Customers: Acme Foods (active), Dormant Traders (deactivated), Spacey  Stores, Other Co, Gone Goods (deleted).
INSERT INTO public.customers(name,mobile,active) VALUES
 ('Acme Foods','9766600011',true),('Dormant Traders','9766600012',false),('Spacey  Stores','9766600013',true),('Other Co','9766600014',true);
INSERT INTO public.customers(name,mobile,active,deleted_at) VALUES ('Gone Goods','9766600015',false,now());
SELECT id AS acme FROM public.customers WHERE name='Acme Foods' \gset
SELECT id AS dorm FROM public.customers WHERE name='Dormant Traders' \gset
SELECT id AS spacey FROM public.customers WHERE name='Spacey  Stores' \gset
SELECT id AS other FROM public.customers WHERE name='Other Co' \gset
SELECT id AS gone FROM public.customers WHERE name='Gone Goods' \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;

-- 1. Add refused for a different capitalisation; details name the stored "Acme Foods".
SELECT public.create_customer('ACME Foods','9766600021') AS r \gset
SELECT pg_temp.nr_assert(:'r'::jsonb->>'success'='false' AND :'r'::jsonb#>>'{error,code}'='DUPLICATE_NAME' AND :'r'::jsonb#>>'{error,field}'='name'
 AND :'r'::jsonb#>>'{error,details,customer_id}'=:'acme' AND :'r'::jsonb#>>'{error,details,name}'='Acme Foods' AND :'r'::jsonb#>>'{error,details,active}'='true'
 AND (SELECT count(*)=0 FROM public.customers WHERE mobile='9766600021'),'Add ACME Foods refused: '||:'r');
-- 2. Add refused for extra and inner spaces.
SELECT public.create_customer('  Acme   Foods ','9766600022') AS r \gset
SELECT pg_temp.nr_assert(:'r'::jsonb#>>'{error,code}'='DUPLICATE_NAME' AND :'r'::jsonb#>>'{error,details,name}'='Acme Foods'
 AND (SELECT count(*)=0 FROM public.customers WHERE mobile='9766600022'),'Add with spaces refused: '||:'r');
-- 3. Add refused when the holder is deactivated, and when it is deleted.
SELECT public.create_customer('dormant TRADERS','9766600023') AS r1, public.create_customer('GONE  goods','9766600024') AS r2 \gset
SELECT pg_temp.nr_assert(:'r1'::jsonb#>>'{error,code}'='DUPLICATE_NAME' AND :'r1'::jsonb#>>'{error,details,customer_id}'=:'dorm' AND :'r1'::jsonb#>>'{error,details,active}'='false'
 AND :'r2'::jsonb#>>'{error,code}'='DUPLICATE_NAME' AND :'r2'::jsonb#>>'{error,details,customer_id}'=:'gone','deactivated and deleted holders still refuse: '||:'r1'||:'r2');
-- 4. A genuinely new name is accepted.
SELECT public.create_customer('Acme Foods Two','9766600025') AS r \gset
SELECT pg_temp.nr_assert(:'r'::jsonb->>'success'='true','a different name is accepted: '||:'r');
-- 5. Edit of another customer to a clashing name is refused; its name is unchanged.
SELECT public.update_customer(:'other'::uuid, p_name=>' ACME   foods') AS r \gset
SELECT pg_temp.nr_assert(:'r'::jsonb#>>'{error,code}'='DUPLICATE_NAME' AND :'r'::jsonb#>>'{error,field}'='name' AND :'r'::jsonb#>>'{error,details,customer_id}'=:'acme'
 AND :'r'::jsonb#>>'{error,details,name}'='Acme Foods' AND (SELECT name='Other Co' FROM public.customers WHERE id=:'other'::uuid),'Edit onto a taken name refused: '||:'r');
-- 6. Unchanged name on Edit is accepted, also when the stored value has different spacing; the sent name is stored trimmed.
SELECT public.update_customer(:'spacey'::uuid, p_name=>'spacey stores') AS r1, public.update_customer(:'acme'::uuid, p_name=>'ACME FOODS', p_city=>'Surat') AS r2 \gset
SELECT pg_temp.nr_assert(:'r1'::jsonb->>'success'='true' AND :'r2'::jsonb->>'success'='true'
 AND (SELECT name='spacey stores' FROM public.customers WHERE id=:'spacey'::uuid) AND (SELECT name='ACME FOODS' AND city='Surat' FROM public.customers WHERE id=:'acme'::uuid),
 'own name in other capitals or spacing accepted: '||:'r1'||:'r2');
-- 7. Tab, newline and no-break space are white space for the key (same fold as the app's).
SELECT public.create_customer('Acme Foods'||chr(9), '9766600026') AS r1, public.create_customer(chr(10)||'acme'||chr(160)||'foods', '9766600027') AS r2 \gset
SELECT pg_temp.nr_assert(:'r1'::jsonb#>>'{error,code}'='DUPLICATE_NAME' AND :'r1'::jsonb#>>'{error,details,customer_id}'=:'acme'
 AND :'r2'::jsonb#>>'{error,code}'='DUPLICATE_NAME' AND :'r2'::jsonb#>>'{error,details,customer_id}'=:'acme'
 AND (SELECT count(*)=0 FROM public.customers WHERE mobile IN ('9766600026','9766600027')),'trailing tab / leading newline / no-break space are the same name: '||:'r1'||:'r2');
-- 8. Edit onto a name held by a deactivated customer and by a deleted customer is refused.
SELECT public.update_customer(:'other'::uuid, p_name=>'DORMANT  traders') AS r1, public.update_customer(:'other'::uuid, p_name=>' gone goods') AS r2 \gset
SELECT pg_temp.nr_assert(:'r1'::jsonb#>>'{error,code}'='DUPLICATE_NAME' AND :'r1'::jsonb#>>'{error,details,customer_id}'=:'dorm'
 AND :'r2'::jsonb#>>'{error,code}'='DUPLICATE_NAME' AND :'r2'::jsonb#>>'{error,details,customer_id}'=:'gone'
 AND (SELECT name='Other Co' FROM public.customers WHERE id=:'other'::uuid),'Edit onto deactivated / deleted holder refused: '||:'r1'||:'r2');
-- 9. Error order is unchanged: an invalid or taken mobile answers before the name check.
SELECT public.create_customer('ACME Foods','123') AS r1, public.create_customer('ACME Foods','9766600011') AS r2,
       public.update_customer(:'other'::uuid, p_name=>'acme foods', p_mobile=>'123') AS r3 \gset
SELECT pg_temp.nr_assert(:'r1'::jsonb#>>'{error,code}'='VALIDATION_FAILED' AND :'r1'::jsonb#>>'{error,field}'='mobile'
 AND :'r2'::jsonb#>>'{error,code}'='DUPLICATE_MOBILE'
 AND :'r3'::jsonb#>>'{error,code}'='VALIDATION_FAILED' AND :'r3'::jsonb#>>'{error,field}'='mobile','mobile answers first: '||:'r1'||:'r2'||:'r3');
-- (The unique-violation branch of the handlers, a race between two sessions, cannot be reached in one session: the pre-check answers first.)
-- 10. The unique index exists and is unique; a direct clashing insert is stopped by it.
RESET ROLE;
SELECT pg_temp.nr_assert((SELECT i.indisunique FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid WHERE c.relname='customers_name_norm_key' AND i.indrelid='public.customers'::regclass),'customers_name_norm_key exists and is unique');
SELECT pg_temp.nr_call($$INSERT INTO public.customers(name,mobile,active) VALUES ('other co','9766600099',true) RETURNING '{}'::jsonb$$) AS r \gset
SELECT pg_temp.nr_assert(:'r'::jsonb->>'state'='23505','direct clashing insert hits the unique index: '||:'r');
SELECT pg_temp.nr_assert(:'r'::jsonb->>'raised' LIKE '%customers_name_norm_key%','the raised message names customers_name_norm_key: '||:'r');
SELECT pg_temp.nr_assert(utils.customer_name_key('  Acme   FOODS ')='acme foods' AND utils.customer_name_key(chr(9)||'A'||chr(8239)||chr(65279)||chr(10)||'b ')='a b'
 AND NOT has_function_privilege('authenticated','utils.customer_name_key(text)','EXECUTE') AND NOT has_function_privilege('anon','utils.customer_name_key(text)','EXECUTE')
 AND has_function_privilege('service_role','utils.customer_name_key(text)','EXECUTE'),'key function result and grants');
-- 11. service_role writes to customers (the index function runs as the writing role).
SET LOCAL ROLE service_role;
UPDATE public.customers SET city='Surat' WHERE name='Other Co';
INSERT INTO public.customers(name,mobile,active) VALUES ('Service Role Co','9766600098',true);
SELECT pg_temp.nr_assert((SELECT count(*)=1 FROM public.customers WHERE name='Service Role Co'),'service_role can insert and update customers');
RESET ROLE;
ROLLBACK;
\echo 'Customer name rule checks passed.'

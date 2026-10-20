-- Customers review (tweak 2026-10-20): duplicate mobile/name codes, stale edit, include-inactive search. Fictional data. Runs only in migrations.sh's disposable,
-- network-disabled database. Uses the existing operator test-session lifecycle.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.cr_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'customers review: %',label; END IF; END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
CREATE FUNCTION pg_temp.cr_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.cr_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.cr_assert(l#>>'{data,action}'='login','mocked operator login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
SELECT warehouse_security.bootstrap_first_admin('9888888951','Customers Review Admin') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888952','Customers Review Staff','staff',true,'approved');
SELECT pg_temp.cr_login('9888888951') AS admin_claims \gset
SELECT pg_temp.cr_login('9888888952') AS staff_claims \gset
-- Rows written as supabase_admin before the role switch: two ACTIVE customers that already share a number,
-- one deactivated customer, one soft-deleted customer, one stored in the old 91... form.
INSERT INTO public.customers(name,mobile,active) VALUES ('CR Twin1','9888888971',true),('CR Twin2','9888888971',true),
 ('CR Old','9888888972',false),('CR Legacy','919888888973',true);
INSERT INTO public.customers(name,mobile,active,deleted_at) VALUES ('CR Gone','9888888975',false,now());
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;

SELECT public.create_customer('CR Alpha','9888888961') AS a \gset
SELECT pg_temp.cr_assert(:'a'::jsonb->>'success'='true','create Alpha');
-- same number, formatted differently, refused with the other customer named
SELECT public.create_customer('CR Beta','+91 98888 88961') AS r \gset
SELECT pg_temp.cr_assert(:'r'::jsonb#>>'{error,code}'='DUPLICATE_MOBILE' AND :'r'::jsonb#>>'{error,field}'='mobile','duplicate mobile on Add');
SELECT pg_temp.cr_assert((:'r'::jsonb#>>'{error,details,name}')='CR Alpha' AND jsonb_typeof(:'r'::jsonb#>'{error,details}')='object','details name the other customer');
SELECT public.create_customer('CR Alpha','9888888962') AS r \gset
SELECT pg_temp.cr_assert(:'r'::jsonb#>>'{error,code}'='DUPLICATE_NAME','duplicate name on Add');
SELECT public.create_customer('CR Beta','9888888962') AS b \gset
SELECT pg_temp.cr_assert(:'b'::jsonb->>'success'='true','create Beta');
SELECT id AS beta_id FROM public.customers WHERE name='CR Beta' \gset
-- Edit: another customer's number refused; own number resent is fine
SELECT public.update_customer(:'beta_id'::uuid, p_mobile=>'9888888961') AS r \gset
SELECT pg_temp.cr_assert(:'r'::jsonb#>>'{error,code}'='DUPLICATE_MOBILE','duplicate mobile on Edit');
SELECT public.update_customer(:'beta_id'::uuid, p_mobile=>'9888888962', p_city=>'Anand') AS r \gset
SELECT pg_temp.cr_assert(:'r'::jsonb->>'success'='true','own number resent is allowed');
SELECT public.update_customer(:'beta_id'::uuid, p_name=>'CR Alpha') AS r \gset
SELECT pg_temp.cr_assert(:'r'::jsonb#>>'{error,code}'='DUPLICATE_NAME','duplicate name on Edit');
-- stale check (one transaction: now() does not move, so an old timestamp stands for the stale read)
SELECT public.update_customer(:'beta_id'::uuid, p_city=>'Surat', p_expected_updated_at=>'2000-01-01'::timestamptz) AS r \gset
SELECT pg_temp.cr_assert(:'r'::jsonb#>>'{error,code}'='STALE_CUSTOMER','stale edit refused');
SELECT pg_temp.cr_assert((SELECT city FROM public.customers WHERE id=:'beta_id'::uuid)='Anand','stale edit changed nothing');
SELECT updated_at AS beta_fresh FROM public.customers WHERE id=:'beta_id'::uuid \gset
SELECT public.update_customer(:'beta_id'::uuid, p_city=>'Surat', p_expected_updated_at=>:'beta_fresh'::timestamptz) AS r \gset
SELECT pg_temp.cr_assert(:'r'::jsonb->>'success'='true','fresh expected_updated_at accepted');
-- deactivated customer: its number no longer blocks, search finds it only with p_include_inactive
SELECT public.set_customer_active(:'beta_id'::uuid,false) AS r \gset
SELECT pg_temp.cr_assert(:'r'::jsonb->>'success'='true','Beta deactivated: ' || :'r');
SELECT public.create_customer('CR Gamma','9888888962') AS g \gset
SELECT pg_temp.cr_assert(:'g'::jsonb->>'success'='true','deactivated number does not block Add');
SELECT pg_temp.cr_assert(jsonb_array_length(public.search_customers('CR Beta',20)->'data')=0,'default search hides deactivated');
SELECT pg_temp.cr_assert((SELECT bool_and(e->>'active'='false' AND e->>'deleted'='false' AND e->>'id'=:'beta_id') AND count(*)=1 FROM jsonb_array_elements(public.search_customers('CR Beta',20,true)->'data') e WHERE e->>'id'=:'beta_id'),'include_inactive finds it with active=false');
SELECT pg_temp.cr_assert(jsonb_array_length(public.search_customers('+91 98888 88961',20)->'data')=1,'formatted number search finds Alpha');

-- (all three below run as administrator)
-- pairs that already share a number stay editable: number resent with another field changed
SELECT id AS twin1 FROM public.customers WHERE name='CR Twin1' \gset
SELECT public.update_customer(:'twin1'::uuid, p_mobile=>'9888888971', p_city=>'Rajkot') AS r \gset
SELECT pg_temp.cr_assert(:'r'::jsonb->>'success'='true','twin resent shared number plus city: ' || :'r');
SELECT public.update_customer(:'twin1'::uuid, p_mobile=>'+91 98888 88971', p_city=>'Morbi') AS r \gset
SELECT pg_temp.cr_assert(:'r'::jsonb->>'success'='true','twin resent shared number in 12-digit form: ' || :'r');
-- 10 and 12 digits are one number on Edit; the stored text is kept
SELECT id AS alpha_id FROM public.customers WHERE name='CR Alpha' \gset
SELECT public.update_customer(:'alpha_id'::uuid, p_mobile=>'919888888961', p_city=>'Anand') AS r \gset
SELECT pg_temp.cr_assert(:'r'::jsonb->>'success'='true' AND (SELECT mobile FROM public.customers WHERE id=:'alpha_id'::uuid)='9888888961','12-digit form of own number accepted, stored text kept: ' || :'r');
-- trunk 0 and 12-digit forms collide with Alpha on Add; letters are refused
SELECT public.create_customer('CR Trunk','09888888961') AS r \gset
SELECT pg_temp.cr_assert(:'r'::jsonb#>>'{error,code}'='DUPLICATE_MOBILE','trunk-0 form collides with Alpha: ' || :'r');
SELECT public.create_customer('CR Letters','98888a8981') AS r \gset
SELECT pg_temp.cr_assert(:'r'::jsonb#>>'{error,code}'='VALIDATION_FAILED' AND :'r'::jsonb#>>'{error,field}'='mobile','letters refused: ' || :'r');
-- a deactivated customer's number is allowed on Edit; the DUPLICATE_NAME details are an object with active=false
SELECT public.create_customer('CR Delta','9888888974') AS d \gset
SELECT pg_temp.cr_assert(:'d'::jsonb->>'success'='true','create Delta');
SELECT id AS delta_id FROM public.customers WHERE name='CR Delta' \gset
SELECT public.update_customer(:'delta_id'::uuid, p_mobile=>'9888888972') AS r \gset
SELECT pg_temp.cr_assert(:'r'::jsonb->>'success'='true','deactivated holder does not block Edit: ' || :'r');
SELECT public.update_customer(:'delta_id'::uuid, p_name=>'CR Old') AS r \gset
SELECT pg_temp.cr_assert(:'r'::jsonb#>>'{error,code}'='DUPLICATE_NAME' AND jsonb_typeof(:'r'::jsonb#>'{error,details}')='object'
 AND :'r'::jsonb#>>'{error,details,active}'='false' AND :'r'::jsonb#>>'{error,details,name}'='CR Old','name held by a deactivated customer: ' || :'r');
-- exactly one overload each
SELECT pg_temp.cr_assert((SELECT count(*) FROM pg_proc WHERE proname='update_customer' AND pronamespace='public'::regnamespace)=1,'one update_customer');
SELECT pg_temp.cr_assert((SELECT count(*) FROM pg_proc WHERE proname='search_customers' AND pronamespace='public'::regnamespace)=1,'one search_customers');
-- an old-app-shaped call: all 15 named arguments, the mobile the stored 91... value
SELECT id AS legacy_id FROM public.customers WHERE name='CR Legacy' \gset
SELECT public.update_customer(p_customer_id=>:'legacy_id'::uuid, p_name=>'CR Legacy', p_mobile=>'919888888973', p_email=>'legacy@example.test',
 p_address=>'1 Test Road', p_city=>'Surat', p_state=>'Gujarat', p_pincode=>'395001', p_gst=>NULL, p_pan=>NULL, p_active=>true,
 p_contact_person=>'Legacy Person', p_contact_mobile=>'9888888979', p_contact_email=>NULL, p_image_urls=>ARRAY[]::text[]) AS r \gset
SELECT pg_temp.cr_assert(:'r'::jsonb->>'success'='true' AND (SELECT mobile FROM public.customers WHERE id=:'legacy_id'::uuid)='919888888973','old-app call with stored 91... number: ' || :'r');
-- digit search by 12-digit, partial and 91-prefixed forms; soft-deleted never listed even with include_inactive
SELECT pg_temp.cr_assert(jsonb_array_length(public.search_customers('9198888889',20)->'data')>=1,'partial digits with 91 prefix find Alpha');
SELECT pg_temp.cr_assert(jsonb_array_length(public.search_customers('919888888973',20)->'data')=1,'12-digit finds the 91...-stored customer');
SELECT pg_temp.cr_assert(jsonb_array_length(public.search_customers('CR Gone',20,true)->'data')=0,'soft-deleted never listed');
-- staff: include_inactive gives no deactivated rows; active rows still found (positive control)
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SELECT pg_temp.cr_assert(warehouse_security.active_role()='staff','actual staff role');
SELECT pg_temp.cr_assert(jsonb_array_length(public.search_customers('CR Beta',20,true)->'data')=0,'staff include_inactive: no deactivated rows');
SELECT pg_temp.cr_assert(jsonb_array_length(public.search_customers('CR Alpha',20,true)->'data')=1,'staff include_inactive still finds active Alpha');
RESET ROLE;
ROLLBACK;

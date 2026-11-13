-- Migration 199 (WH-140): the facility's legal settings. get_public_config carries a `legal` object for anon (and still the version, the
-- maintenance flag, record_payments and the flags); an administrator's set_facility_legal trims and stores the six values, writes one
-- audit row per change and none for the same value again, clears a value with an empty string, keeps the GST keys of the same settings row,
-- and refuses a bad email, an unknown key and a value that is not text (22023); a supervisor, staff, a customer and anon are refused (42501).
-- Runs after all migrations in migrations.sh's disposable, network-disabled database (session time zone UTC); every fixture row rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.fl_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'facility legal: %',label; END IF; END $$;
-- The text answer of a statement, or what it raised.
CREATE FUNCTION pg_temp.fl_call(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer text;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RETURN jsonb_build_object('answer', answer);
END $$;
CREATE FUNCTION pg_temp.fl_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.fl_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.fl_assert(l#>>'{data,action}'='login','login for '||phone);
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
SELECT warehouse_security.bootstrap_first_admin('9888888821','Legal Administrator') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888822','Legal Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919888888823','Legal Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888824','Legal Customer Reader','customer',true,'approved');
SELECT pg_temp.fl_login('9888888821') AS admin_claims \gset
SELECT pg_temp.fl_login('9888888822') AS supervisor_claims \gset
SELECT pg_temp.fl_login('9888888823') AS staff_claims \gset
SELECT pg_temp.fl_login('9888888824') AS customer_claims \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE mobile='919888888821' \gset
-- The row holds GST keys (migration 173) that a legal change must keep, and the company name the legal name falls back to.
UPDATE public.system_settings SET value = '{"gstRegistered":true,"gstin":"24AAAAA0000A1Z5","sacStorage":"996721"}' WHERE key = 'facility_legal';
UPDATE public.system_settings SET value = 'Fictional Cold Storage' WHERE key = 'app_name';
INSERT INTO public.api_configurations(environment, app_version, maintenance_mode, is_active) VALUES ('fl_test', '9.8.7', false, true);

-- 1. anon reads `legal` from get_public_config: six text values, the legal name falling back to the company; nothing else was lost.
SET LOCAL ROLE anon;
SELECT public.get_public_config('fl_test')::jsonb AS answer \gset
RESET ROLE;
SELECT pg_temp.fl_assert(:'answer'::jsonb#>'{legal}' = '{"legalName":"Fictional Cold Storage","city":"","state":"","grievanceName":"","grievanceEmail":"","grievancePhone":""}'::jsonb,
  'anon reads the six legal values, the name from the company: '||:'answer');
SELECT pg_temp.fl_assert(:'answer'::jsonb ?& ARRAY['app_version','maintenance_mode','feature_flags','record_payments','legal'] AND (SELECT count(*) = 5 FROM jsonb_object_keys(:'answer'::jsonb)),
  'the public config still has the version, the maintenance flag, the flags and record_payments next to legal: '||:'answer');
SELECT pg_temp.fl_assert(NOT (:'answer'::jsonb->'legal')::text ~ 'gstin|24AAAAA|sac', 'the GST details are not in the public legal object');

-- 2. An administrator's set trims, stores and writes one audit row.
SELECT count(*) AS audit_before FROM public.audit_log WHERE table_name = 'facility_legal' \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.set_facility_legal('{"legalName":"  Fictional Traders  ","city":" Ahmedabad ","state":"Gujarat","grievanceName":"A. Officer","grievanceEmail":" officer@example.test ","grievancePhone":"+91 99999 00000"}'::jsonb) AS first_set \gset
RESET ROLE;
SELECT pg_temp.fl_assert(:'first_set'::jsonb = '{"legalName":"Fictional Traders","city":"Ahmedabad","state":"Gujarat","grievanceName":"A. Officer","grievanceEmail":"officer@example.test","grievancePhone":"+91 99999 00000"}'::jsonb,
  'the values are trimmed and returned: '||:'first_set');
SELECT pg_temp.fl_assert((SELECT count(*) FROM public.audit_log WHERE table_name = 'facility_legal') = :audit_before + 1, 'one audit row for the change');
SELECT pg_temp.fl_assert((SELECT action = 'UPDATED' AND user_id = :'admin_profile'::uuid AND old_data->>'city' = '' AND new_data->>'city' = 'Ahmedabad'
    FROM public.audit_log WHERE table_name = 'facility_legal' ORDER BY created_at DESC, id DESC LIMIT 1), 'the audit row names the administrator and holds the old and new values');
SELECT pg_temp.fl_assert((SELECT value::jsonb->>'gstin' = '24AAAAA0000A1Z5' AND (value::jsonb->>'gstRegistered')::boolean AND value::jsonb->>'sacStorage' = '996721' AND value::jsonb->>'city' = 'Ahmedabad'
    FROM public.system_settings WHERE key = 'facility_legal'), 'the GST keys of the row are kept and the legal keys are stored');
SET LOCAL ROLE anon;
SELECT public.get_public_config('fl_test')::jsonb AS answer2 \gset
RESET ROLE;
SELECT pg_temp.fl_assert(:'answer2'::jsonb#>>'{legal,city}' = 'Ahmedabad' AND :'answer2'::jsonb#>>'{legal,legalName}' = 'Fictional Traders' AND :'answer2'::jsonb ? 'record_payments',
  'anon now reads the stored values and still record_payments');

-- 3. The same value again writes no audit row (also when only the spaces differ); a key not given is left alone.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.set_facility_legal('{"city":"Ahmedabad","state":" Gujarat "}'::jsonb) AS again \gset
RESET ROLE;
SELECT pg_temp.fl_assert((SELECT count(*) FROM public.audit_log WHERE table_name = 'facility_legal') = :audit_before + 1, 'the same value again writes no audit row');
SELECT pg_temp.fl_assert(:'again'::jsonb->>'grievanceEmail' = 'officer@example.test', 'a key that was not given is left alone');

-- 4. An empty string clears a value (one more audit row); clearing the legal name falls back to the company.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.set_facility_legal('{"grievancePhone":"","legalName":""}'::jsonb) AS cleared \gset
RESET ROLE;
SELECT pg_temp.fl_assert(:'cleared'::jsonb->>'grievancePhone' = '' AND :'cleared'::jsonb->>'legalName' = 'Fictional Cold Storage' AND :'cleared'::jsonb->>'city' = 'Ahmedabad', 'an empty string clears: '||:'cleared');
SELECT pg_temp.fl_assert((SELECT count(*) FROM public.audit_log WHERE table_name = 'facility_legal') = :audit_before + 2, 'the clearing writes one audit row');
SELECT pg_temp.fl_assert(NOT (SELECT value::jsonb ? 'grievancePhone' FROM public.system_settings WHERE key = 'facility_legal')
  AND (SELECT value::jsonb->>'gstin' FROM public.system_settings WHERE key = 'facility_legal') = '24AAAAA0000A1Z5', 'the cleared key is removed from the row and the GST keys stay');

-- 5. Refused with 22023, and nothing changes: a bad email, a bad phone, an unknown key, a value that is not text, a long or control-character value, not an object.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.fl_assert(NOT EXISTS (SELECT 1 FROM (VALUES
  ('bad email', $$SELECT public.set_facility_legal('{"city":"Surat","grievanceEmail":"not-an-email"}'::jsonb)$$),
  ('bad phone', $$SELECT public.set_facility_legal('{"city":"Surat","grievancePhone":"call me"}'::jsonb)$$),
  ('unknown key', $$SELECT public.set_facility_legal('{"city":"Surat","website":"x"}'::jsonb)$$),
  ('a number', $$SELECT public.set_facility_legal('{"city":"Surat","state":5}'::jsonb)$$),
  ('a boolean', $$SELECT public.set_facility_legal('{"city":"Surat","state":true}'::jsonb)$$),
  ('null', $$SELECT public.set_facility_legal('{"city":"Surat","state":null}'::jsonb)$$),
  ('121 characters', $$SELECT public.set_facility_legal(jsonb_build_object('city','Surat','state',repeat('x',121)))$$),
  ('a control character', $$SELECT public.set_facility_legal(jsonb_build_object('city','Surat','state',E'a\nb'))$$),
  ('an array', $$SELECT public.set_facility_legal('[]'::jsonb)$$),
  ('SQL null', $$SELECT public.set_facility_legal(NULL)$$)
  ) AS c(label, statement) WHERE pg_temp.fl_call(c.statement)->>'state' IS DISTINCT FROM '22023'),
  'every bad value is refused with 22023');
RESET ROLE;
SELECT pg_temp.fl_assert((SELECT value::jsonb->>'city' FROM public.system_settings WHERE key = 'facility_legal') = 'Ahmedabad'
  AND (SELECT count(*) FROM public.audit_log WHERE table_name = 'facility_legal') = :audit_before + 2, 'a refused call changes nothing, not even the valid keys beside the bad one');

-- 6. Supervisor, staff, customer and anon are refused with 42501.
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.fl_assert(pg_temp.fl_call($$SELECT public.set_facility_legal('{"city":"Surat"}'::jsonb)$$)->>'state' = '42501', 'the supervisor cannot set the legal settings');
RESET ROLE;
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.fl_assert(pg_temp.fl_call($$SELECT public.set_facility_legal('{"city":"Surat"}'::jsonb)$$)->>'state' = '42501', 'staff cannot set the legal settings');
RESET ROLE;
SELECT set_config('request.jwt.claims',:'customer_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.fl_assert(pg_temp.fl_call($$SELECT public.set_facility_legal('{"city":"Surat"}'::jsonb)$$)->>'state' = '42501', 'a customer account cannot set the legal settings');
RESET ROLE;
SET LOCAL ROLE anon;
SELECT pg_temp.fl_assert(pg_temp.fl_call($$SELECT public.set_facility_legal('{"city":"Surat"}'::jsonb)$$)->>'state' = '42501', 'anon cannot call it');
RESET ROLE;
SELECT pg_temp.fl_assert((SELECT value::jsonb->>'city' FROM public.system_settings WHERE key = 'facility_legal') = 'Ahmedabad'
  AND (SELECT count(*) FROM public.audit_log WHERE table_name = 'facility_legal') = :audit_before + 2, 'the refused callers changed nothing');
-- The helper functions are not reachable by the API roles.
SELECT pg_temp.fl_assert(NOT has_function_privilege('authenticated', 'warehouse_security.apply_facility_legal(jsonb, uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'warehouse_security.apply_facility_legal(jsonb, uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'warehouse_security.facility_legal()', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.set_facility_legal(jsonb)', 'EXECUTE'), 'only set_facility_legal is callable, and not by anon');
ROLLBACK;

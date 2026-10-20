-- Push review (migration 118): an empty-key customer name (only tabs, new lines, no-break spaces) is refused on Add and Edit;
-- delete_user_account marks the profile enrollment_status = 'disabled'. Fictional data. Rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.pr_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'push review: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.claims_for(p_user uuid) RETURNS text LANGUAGE plpgsql AS $$
DECLARE refresh text := warehouse_security.issue_session(p_user)->>'refresh_token';
BEGIN
  RETURN (SELECT jsonb_build_object('role','authenticated','sub',user_id,'session_id',id)::text
    FROM warehouse_security.refresh_sessions WHERE token_hash=encode(extensions.digest(refresh,'sha256'),'hex'));
END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
SELECT warehouse_security.bootstrap_first_admin('9766700001','PushReview Admin') AS admin_a \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919766700002','PushReview Second Admin','admin',true,'approved');
SELECT id AS profile_b, auth_user_id AS admin_b FROM public.user_profiles WHERE mobile='919766700002' \gset
SELECT pg_temp.claims_for(:'admin_a'::uuid) AS claims_a \gset
SELECT pg_temp.claims_for(:'admin_b'::uuid) AS claims_b \gset
INSERT INTO public.customers(name,mobile,active) VALUES ('Push Review Co','9766700011',true);
SELECT id AS pr_co FROM public.customers WHERE name='Push Review Co' \gset

SELECT set_config('request.jwt.claims',:'claims_a',true);
SET LOCAL ROLE authenticated;
-- 1. Add refused for a tab-only name and an NBSP-only name; nothing inserted.
SELECT public.create_customer(chr(9),'9766700021') AS r1, public.create_customer(chr(160)||chr(160),'9766700022') AS r2,
       public.create_customer(chr(10)||chr(9)||chr(160),'9766700023') AS r3 \gset
SELECT pg_temp.pr_assert(:'r1'::jsonb#>>'{error,code}'='VALIDATION_FAILED' AND :'r1'::jsonb#>>'{error,field}'='name'
 AND :'r2'::jsonb#>>'{error,code}'='VALIDATION_FAILED' AND :'r2'::jsonb#>>'{error,field}'='name'
 AND :'r3'::jsonb#>>'{error,code}'='VALIDATION_FAILED' AND :'r3'::jsonb#>>'{error,field}'='name'
 AND (SELECT count(*)=0 FROM public.customers WHERE mobile IN ('9766700021','9766700022','9766700023')),
 'whitespace-only names refused on Add: '||:'r1'||:'r2'||:'r3');
-- 2. Edit refused for the same names; the stored name is unchanged.
SELECT public.update_customer(:'pr_co'::uuid, p_name=>chr(9)) AS r1, public.update_customer(:'pr_co'::uuid, p_name=>chr(160)) AS r2 \gset
SELECT pg_temp.pr_assert(:'r1'::jsonb#>>'{error,code}'='VALIDATION_FAILED' AND :'r1'::jsonb#>>'{error,field}'='name'
 AND :'r2'::jsonb#>>'{error,code}'='VALIDATION_FAILED' AND :'r2'::jsonb#>>'{error,field}'='name'
 AND (SELECT name='Push Review Co' FROM public.customers WHERE id=:'pr_co'::uuid),'whitespace-only names refused on Edit: '||:'r1'||:'r2');
-- 3. Normal names still work; Edit without a name still works.
SELECT public.create_customer('Push Review Two','9766700024') AS r1, public.update_customer(:'pr_co'::uuid, p_name=>'Push Review Renamed') AS r2,
       public.update_customer(:'pr_co'::uuid, p_city=>'Surat') AS r3 \gset
SELECT pg_temp.pr_assert(:'r1'::jsonb->>'success'='true' AND :'r2'::jsonb->>'success'='true' AND :'r3'::jsonb->>'success'='true'
 AND (SELECT name='Push Review Renamed' AND city='Surat' FROM public.customers WHERE id=:'pr_co'::uuid),'normal Add and Edit work: '||:'r1'||:'r2'||:'r3');
-- 4. delete_user_account: the second administrator deletes the own account.
SELECT set_config('request.jwt.claims',:'claims_b',true);
SELECT public.delete_user_account() AS d \gset
RESET ROLE;
SELECT pg_temp.pr_assert(:'d'::jsonb->>'success'='true'
 AND (SELECT enrollment_status='disabled' AND deleted_at IS NOT NULL AND NOT active AND mobile LIKE 'DEL%' FROM public.user_profiles WHERE id=:'profile_b'::uuid),
 'deleted profile is disabled with deleted_at set: '||:'d'||(SELECT enrollment_status FROM public.user_profiles WHERE id=:'profile_b'::uuid));
-- 5. The other administrator is untouched.
SELECT pg_temp.pr_assert((SELECT enrollment_status='approved' AND deleted_at IS NULL AND active FROM public.user_profiles WHERE auth_user_id=:'admin_a'::uuid),'other administrator untouched');
ROLLBACK;
\echo 'Push review checks passed.'

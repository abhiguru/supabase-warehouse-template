-- Migration 44: the last active administrator cannot be deleted, deactivated
-- or demoted; the installer restores an administrator when none can sign in;
-- enrollment review refuses a caller with no active role.
-- Runs only in migrations.sh's disposable, network-disabled database; every
-- fixture row rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.admin_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'admin guards: %',label; END IF; END $$;
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
SELECT pg_temp.admin_assert(warehouse_security.installer_admin_state('919888888501')='none','a new database has no administrator');
SELECT warehouse_security.bootstrap_first_admin('9888888501','Guard Administrator') AS admin_a \gset
SELECT id AS profile_a FROM public.user_profiles WHERE auth_user_id=:'admin_a'::uuid \gset
SELECT pg_temp.admin_assert(warehouse_security.installer_admin_state('919888888501')='match'
  AND warehouse_security.installer_admin_state('919888888502')='different','the installer recognises its administrator');
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888502','Guard Second Administrator','admin',true,'approved'),
 (gen_random_uuid(),'919888888503','Guard Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919888888504','Guard Pending','customer',false,'pending');
SELECT id AS profile_b, auth_user_id AS admin_b FROM public.user_profiles WHERE mobile='919888888502' \gset
SELECT id AS profile_pending FROM public.user_profiles WHERE mobile='919888888504' \gset
SELECT pg_temp.claims_for(:'admin_a'::uuid) AS claims_a \gset
SELECT pg_temp.claims_for(:'admin_b'::uuid) AS claims_b \gset

-- With two administrators, one may delete the own account.
SELECT set_config('request.jwt.claims',:'claims_b',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_user_account() AS deleted_b \gset
RESET ROLE;
SELECT pg_temp.admin_assert(:'deleted_b'::jsonb->>'success'='true'
  AND (SELECT NOT active AND mobile LIKE 'DEL%' AND role='admin' FROM public.user_profiles WHERE id=:'profile_b'::uuid),
  'an administrator who is not the last one deletes the own account');

-- The remaining administrator cannot.
SELECT set_config('request.jwt.claims',:'claims_a',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_user_account() AS deleted_a \gset
RESET ROLE;
SELECT pg_temp.admin_assert(:'deleted_a'::jsonb->>'success'='false' AND :'deleted_a'::jsonb->>'code'='LAST_ADMIN'
  AND :'deleted_a'::jsonb->>'error' LIKE 'The only administrator cannot delete this account.%',
  'the last active administrator cannot delete the own account');
SELECT pg_temp.admin_assert((SELECT active AND mobile='919888888501' AND name='Guard Administrator' FROM public.user_profiles WHERE id=:'profile_a'::uuid)
  AND (SELECT count(*)=1 FROM warehouse_security.refresh_sessions WHERE user_id=:'admin_a'::uuid),
  'a refused deletion changes nothing and keeps the session');
SET LOCAL ROLE authenticated;
SELECT pg_temp.admin_assert(warehouse_security.active_role()='admin','the administrator is still signed in');
RESET ROLE;
-- Other roles are not affected by the rule.
SELECT set_config('request.jwt.claims',pg_temp.claims_for((SELECT auth_user_id FROM public.user_profiles WHERE mobile='919888888503')),true);
SET LOCAL ROLE authenticated;
SELECT public.delete_user_account() AS deleted_supervisor \gset
RESET ROLE;
SELECT pg_temp.admin_assert(:'deleted_supervisor'::jsonb->>'success'='true','a supervisor deletes the own account');

-- Status and role changes refuse to leave the warehouse without an administrator.
-- An administrator cannot target the own profile, so one call can only reach the
-- rule when two administrators act on each other at the same moment. That is
-- run with two sessions in tests/concurrent_rules.sh; the rule itself and its
-- presence in both functions are checked here.
SELECT pg_temp.admin_assert(NOT warehouse_security.other_active_admin_exists(:'profile_a'::uuid)
  AND warehouse_security.other_active_admin_exists(:'profile_b'::uuid)
  AND warehouse_security.other_active_admin_exists(NULL),'only an approved, active administrator counts');
SELECT pg_temp.admin_assert(pg_get_functiondef('public.update_user_status(uuid,boolean)'::regprocedure) LIKE
  '%IF NOT p_active AND v_target_role = ''admin'' AND NOT warehouse_security.other_active_admin_exists(v_target_id) THEN%LAST_ADMIN%'
  AND pg_get_functiondef('public.update_user_role(uuid,public.user_role)'::regprocedure) LIKE
  '%IF v_old_role = ''admin'' AND NOT warehouse_security.other_active_admin_exists(v_target_id) THEN%LAST_ADMIN%',
  'status and role changes carry the last-administrator rule');
-- The patched functions still work for ordinary changes.
UPDATE public.user_profiles SET role='admin',active=true,enrollment_status='approved',mobile='919888888502' WHERE id=:'profile_b'::uuid;
SELECT set_config('request.jwt.claims',:'claims_a',true);
SET LOCAL ROLE authenticated;
SELECT public.update_user_role(:'profile_b'::uuid,'supervisor') AS demoted \gset
SELECT public.update_user_status(:'profile_b'::uuid,false) AS disabled \gset
RESET ROLE;
SELECT pg_temp.admin_assert(:'demoted'::jsonb->>'success'='true' AND :'disabled'::jsonb->>'success'='true'
  AND (SELECT role='supervisor' AND NOT active FROM public.user_profiles WHERE id=:'profile_b'::uuid),
  'an administrator still demotes and deactivates another administrator: '||(:'demoted'::jsonb->>'message')||' / '||(:'disabled'::jsonb->>'message'));

-- Installer recovery.
DO $$ BEGIN
  BEGIN
    PERFORM warehouse_security.bootstrap_first_admin('9888888505','Unwanted Administrator');
    RAISE EXCEPTION 'bootstrap accepted with an active administrator';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM<>'An administrator already exists' THEN RAISE; END IF;
  END;
END $$;
-- The only administrator row is inactive (how a deleted or disabled last administrator looked before this migration).
UPDATE public.user_profiles SET active=false,enrollment_status='disabled' WHERE id=:'profile_a'::uuid;
SELECT pg_temp.admin_assert(warehouse_security.installer_admin_state('919888888501')='none'
  AND warehouse_security.installer_admin_state('919888888505')='none','an inactive administrator row does not block the installer');
SELECT warehouse_security.bootstrap_first_admin('9888888501','Ignored New Name') AS restored \gset
SELECT pg_temp.admin_assert(:'restored'::uuid=:'admin_a'::uuid
  AND (SELECT active AND enrollment_status='approved' AND role='admin' AND name='Guard Administrator' FROM public.user_profiles WHERE id=:'profile_a'::uuid),
  'the installer restores the administrator of the given phone');
UPDATE public.user_profiles SET active=false,enrollment_status='disabled',mobile='DEL000000000001' WHERE id=:'profile_a'::uuid;
SELECT warehouse_security.bootstrap_first_admin('9888888505','Replacement Administrator') AS replacement \gset
SELECT pg_temp.admin_assert((SELECT role='admin' AND active AND enrollment_status='approved' AND NOT mobile_verified
  AND name='Replacement Administrator' FROM public.user_profiles WHERE auth_user_id=:'replacement'::uuid)
  AND warehouse_security.installer_admin_state('919888888505')='match',
  'the installer creates a new administrator when the old one was deleted');

-- Enrollment review needs an active administrator session, with or without the session hook.
SELECT set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',gen_random_uuid(),'session_id',gen_random_uuid())::text,true);
SELECT set_config('warehouse_test.pending_profile',:'profile_pending',true);
SET LOCAL ROLE authenticated;
DO $$ BEGIN
  BEGIN
    PERFORM public.operator_review_enrollment(current_setting('warehouse_test.pending_profile')::uuid,'rejected');
    RAISE EXCEPTION 'review without an active role was accepted';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
SELECT pg_temp.admin_assert((SELECT enrollment_status='pending' FROM public.user_profiles WHERE id=:'profile_pending'::uuid),
  'a caller with no active role changes no enrollment');
ROLLBACK;
\echo 'Last-administrator, installer recovery and enrollment-review guard checks passed.'

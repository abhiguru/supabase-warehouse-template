-- Migration 78: service accounts (Settings UX batch, 2026-10-14).
--
-- A service account is a profile that a machine signs in with (the FAS sync), not a person.
-- user_profiles.is_service_account marks it. People manage users in Settings, and a service
-- account must not be changed there by mistake:
--   * get_users_list rows and get_user_details return is_service_account;
--   * update_user_role, update_user_status, delete_user_account, clear_user_central_identity and
--     operator_review_enrollment refuse such a profile with error_code SERVICE_ACCOUNT_READ_ONLY;
--     assign_customer_to_user and remove_customer_assignment (they return a boolean) raise an
--     exception whose message starts with SERVICE_ACCOUNT_READ_ONLY;
--   * it does not count as another administrator for the last-administrator rule
--     (warehouse_security.other_active_admin_exists);
--   * update_user_status(false) still works on a service account (cutting a connection off);
--   * get_supervisors does not list a service account;
--   * set_service_account(p_user_id, p_is_service), administrators only, marks or unmarks one.
-- The migration marks nothing: the FAS sync setup (and a dev facility) calls
-- set_service_account for its own profile.

-- Replaces one marker in a function body, failing unless it occurs exactly
-- `expected` times. Dropped at the end of this migration. Every before-text below
-- is absent from its after-text, so a second direct run fails on the count.
CREATE FUNCTION pg_temp.patch_rpc(fn regprocedure, marker text, replacement text, expected integer DEFAULT 1) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE definition text := pg_get_functiondef(fn); occurrences integer;
BEGIN
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> expected THEN
    RAISE EXCEPTION 'Expected % occurrence(s) of the marker in %, found %: %', expected, fn, occurrences, left(marker,80);
  END IF;
  EXECUTE replace(definition,marker,replacement);
END $$;

ALTER TABLE public.user_profiles ADD COLUMN is_service_account boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.user_profiles.is_service_account IS
  'A machine account (migration 78), not a person: Settings shows it read-only and role, status and deletion are refused.';

DO $patch$ BEGIN
  -- Not another administrator who can sign in.
  PERFORM pg_temp.patch_rpc('warehouse_security.other_active_admin_exists(uuid)',
  $m$AND enrollment_status='approved' AND id IS DISTINCT FROM p_profile)$m$,
  $r$AND enrollment_status='approved' AND NOT is_service_account AND id IS DISTINCT FROM p_profile)$r$);

  -- Lists.
  PERFORM pg_temp.patch_rpc('public.get_users_list(text,public.user_role[],boolean,integer,integer)',
  $m$            'active', sub.active,
$m$, $r$            'active', sub.active,
            'is_service_account', sub.is_service_account,
$r$);
  PERFORM pg_temp.patch_rpc('public.get_users_list(text,public.user_role[],boolean,integer,integer)',
  $m$        SELECT id, auth_user_id, name, display_name, mobile, role, active, created_at, updated_at
$m$, $r$        SELECT id, auth_user_id, name, display_name, mobile, role, active, is_service_account, created_at, updated_at
$r$);
  -- A unique tie-breaker, so offset paging never skips or repeats people with the same name.
  PERFORM pg_temp.patch_rpc('public.get_users_list(text,public.user_role[],boolean,integer,integer)',
  $m$        ORDER BY name ASC
        LIMIT p_limit OFFSET p_offset$m$, $r$        ORDER BY name ASC, id ASC
        LIMIT p_limit OFFSET p_offset$r$);
  PERFORM pg_temp.patch_rpc('public.get_users_list(text,public.user_role[],boolean,integer,integer)',
  $m$) ORDER BY sub.name ASC$m$, $r$) ORDER BY sub.name ASC, sub.id ASC$r$);
  PERFORM pg_temp.patch_rpc('public.get_user_details(uuid)',
  $m$        'active', up.active,
$m$, $r$        'active', up.active,
        'is_service_account', up.is_service_account,
$r$);

  -- Read-only for role, status and deletion.
  PERFORM pg_temp.patch_rpc('public.update_user_role(uuid,public.user_role)',
  $m$    -- Users cannot change their own role
$m$, $r$    -- A service account is read-only here (migration 78)
    IF EXISTS (SELECT 1 FROM user_profiles WHERE id = v_target_id AND is_service_account) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'SERVICE_ACCOUNT_READ_ONLY',
            'error_code', 'SERVICE_ACCOUNT_READ_ONLY',
            'message', 'A service account cannot be changed here'
        );
    END IF;

    -- Users cannot change their own role
$r$);
  -- Switching a service account OFF stays allowed: the facility can always cut a connection off
  -- (it disables the enrollment and deletes its refresh sessions). Only switching it on is refused.
  PERFORM pg_temp.patch_rpc('public.update_user_status(uuid,boolean)',
  $m$    -- Users cannot deactivate themselves
$m$, $r$    -- A service account is read-only here, except that it can be cut off (migration 78)
    IF p_active AND EXISTS (SELECT 1 FROM user_profiles WHERE id = v_target_id AND is_service_account) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'SERVICE_ACCOUNT_READ_ONLY',
            'error_code', 'SERVICE_ACCOUNT_READ_ONLY',
            'message', 'A service account cannot be changed here'
        );
    END IF;

    -- Users cannot deactivate themselves
$r$);
  PERFORM pg_temp.patch_rpc('public.delete_user_account()',
  $m$  IF profile_role='admin' AND NOT warehouse_security.other_active_admin_exists(profile_id) THEN
$m$, $r$  IF EXISTS (SELECT 1 FROM public.user_profiles WHERE id=profile_id AND is_service_account) THEN
    RETURN jsonb_build_object('success',false,'code','SERVICE_ACCOUNT_READ_ONLY','error_code','SERVICE_ACCOUNT_READ_ONLY',
      'error','A service account cannot be deleted','message','A service account cannot be deleted');
  END IF;
  IF profile_role='admin' AND NOT warehouse_security.other_active_admin_exists(profile_id) THEN
$r$);

  -- The other writers that change a user (customer assignment, central sign-in link, access
  -- request review) refuse a service account too.
  PERFORM pg_temp.patch_rpc('public.assign_customer_to_user(character varying,uuid,text)',
  $m$      -- Get customer name
$m$, $r$      -- A service account is read-only here (migration 78)
      IF EXISTS (SELECT 1 FROM user_profiles WHERE id = target_user_id AND is_service_account) THEN
          RAISE EXCEPTION 'SERVICE_ACCOUNT_READ_ONLY: A service account cannot be changed here';
      END IF;

      -- Get customer name
$r$);
  PERFORM pg_temp.patch_rpc('public.remove_customer_assignment(character varying,uuid)',
  $m$      -- Soft delete the assignment
$m$, $r$      -- A service account is read-only here (migration 78)
      IF EXISTS (SELECT 1 FROM user_profiles WHERE id = target_user_id AND is_service_account) THEN
          RAISE EXCEPTION 'SERVICE_ACCOUNT_READ_ONLY: A service account cannot be changed here';
      END IF;

      -- Soft delete the assignment
$r$);
  PERFORM pg_temp.patch_rpc('public.clear_user_central_identity(uuid)',
  $m$  UPDATE public.user_profiles SET central_issuer=NULL,central_subject=NULL,updated_at=now() WHERE id=p_user_id;
$m$, $r$  IF target.is_service_account THEN
    RETURN jsonb_build_object('success',false,'error','SERVICE_ACCOUNT_READ_ONLY','error_code','SERVICE_ACCOUNT_READ_ONLY',
      'message','A service account cannot be changed here');
  END IF;
  UPDATE public.user_profiles SET central_issuer=NULL,central_subject=NULL,updated_at=now() WHERE id=p_user_id;
$r$);
  PERFORM pg_temp.patch_rpc('public.operator_review_enrollment(uuid,text,uuid[],text)',
  $m$  IF p_decision NOT IN ('approved','rejected','disabled') THEN RAISE EXCEPTION 'Invalid decision' USING ERRCODE='22023'; END IF;
$m$, $r$  IF profile.is_service_account THEN
    RETURN jsonb_build_object('success',false,'code','SERVICE_ACCOUNT_READ_ONLY','error','SERVICE_ACCOUNT_READ_ONLY',
      'error_code','SERVICE_ACCOUNT_READ_ONLY','message','A service account cannot be changed here');
  END IF;
  IF p_decision NOT IN ('approved','rejected','disabled') THEN RAISE EXCEPTION 'Invalid decision' USING ERRCODE='22023'; END IF;
$r$);

  -- The supervisor picker lists people, not connections.
  PERFORM pg_temp.patch_rpc('public.get_supervisors(text)',
  $m$        WHERE role IN ('admin', 'supervisor', 'staff')
$m$, $r$        WHERE role IN ('admin', 'supervisor', 'staff') AND NOT is_service_account
$r$);

  -- The guard: marking a service account is an administrator's call.
  PERFORM pg_temp.patch_rpc('warehouse_security.authorize_rpc(text,jsonb)',
  $m$  -- Central identity (migration 49) and sensor settings (migration 74): administrators only.
  IF rpc IN ('clear_user_central_identity','update_sensor_device') THEN
$m$, $r$  -- Central identity (migration 49), sensor settings (migration 74) and service accounts
  -- (migration 78): administrators only.
  IF rpc IN ('clear_user_central_identity','update_sensor_device','set_service_account') THEN
$r$);
END $patch$;

CREATE FUNCTION public.set_service_account(p_user_id uuid, p_is_service boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
AS $function$
DECLARE
  v_caller_id uuid; v_caller_role text; v_target public.user_profiles;
BEGIN
  PERFORM warehouse_security.authorize_rpc('set_service_account', jsonb_build_object());
  SELECT id, role::text INTO v_caller_id, v_caller_role FROM public.user_profiles WHERE auth_user_id = auth.uid() AND active;
  -- The guard admits administrators and the service key; the service key has no profile.
  IF auth.jwt()->>'role' IS DISTINCT FROM 'service_role' AND v_caller_role IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Administrator required' USING ERRCODE = '42501';
  END IF;
  IF p_user_id IS NULL OR p_is_service IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_INPUT', 'error_code', 'INVALID_INPUT',
      'message', 'User and flag are required');
  END IF;
  -- Same order as update_user_status, update_user_role and delete_user_account: the last-administrator
  -- lock first, then the row.
  PERFORM pg_advisory_xact_lock(71043);
  SELECT * INTO v_target FROM public.user_profiles WHERE id = p_user_id FOR UPDATE;
  IF v_target.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND', 'error_code', 'NOT_FOUND', 'message', 'User not found');
  END IF;
  IF v_target.id = v_caller_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'SELF_EDIT_FORBIDDEN', 'error_code', 'SELF_EDIT_FORBIDDEN',
      'message', 'You cannot change your own profile type');
  END IF;
  IF v_target.is_service_account = p_is_service THEN
    RETURN jsonb_build_object('success', true, 'user_id', p_user_id, 'is_service_account', p_is_service, 'message', 'Unchanged');
  END IF;
  -- A service account is not an administrator who can sign in for the last-administrator rule.
  IF p_is_service AND v_target.role = 'admin' AND v_target.active AND v_target.enrollment_status = 'approved'
     AND NOT warehouse_security.other_active_admin_exists(v_target.id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'LAST_ADMIN', 'error_code', 'LAST_ADMIN',
      'message', 'The last active administrator cannot be marked as a service account');
  END IF;
  UPDATE public.user_profiles SET is_service_account = p_is_service, updated_at = now() WHERE id = p_user_id;
  RETURN jsonb_build_object('success', true, 'user_id', p_user_id, 'is_service_account', p_is_service,
    'message', CASE WHEN p_is_service THEN 'Marked as a service account' ELSE 'No longer a service account' END);
END;
$function$;
REVOKE ALL ON FUNCTION public.set_service_account(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_service_account(uuid, boolean) TO authenticated, service_role;

DROP FUNCTION pg_temp.patch_rpc(regprocedure, text, text, integer);
NOTIFY pgrst, 'reload schema';

-- Users screens review (tweak batch 2026-10-20): server half.
--
--  * user_profiles.deleted_at marks a deleted account (delete_user_account sets it; accounts deleted
--    before this migration are recognised by the 'DEL' + 12 hex characters mobile it wrote, and backfilled).
--  * get_users_list / get_user_details return enrollment_status ('pending', 'rejected' or null),
--    is_deleted / deleted_at, and each assigned customer's active state; deleted accounts have no
--    phone and are left out of total_count.
--  * update_user_status no longer approves a pending or rejected access request (ENROLLMENT_PENDING /
--    ENROLLMENT_REJECTED answers), refuses a deleted account (ACCOUNT_DELETED), and only an
--    administrator may cut off a service account (PERMISSION_DENIED for a supervisor).
--  * update_user_role refuses a pending or rejected request (ENROLLMENT_PENDING / ENROLLMENT_REJECTED), removes the customer assignments of a Customer given another role and returns
--    removed_customer_count; refuses a deleted account.
--  * review_enrollment_again(p_user_id): administrators put a rejected access request back to pending (role Customer again).
--  * assign_customer_to_user / remove_customer_assignment keep returning boolean; the exception message
--    now starts with a stable code ("CODE: text"), CUSTOMER_INACTIVE included.
--  * delete_user_account answers success to an account that is already deleted.
--  * warehouse_security.other_active_admin_exists leaves out deleted accounts.
-- No role is created or altered. Every function keeps its signature.

ALTER TABLE public.user_profiles ADD COLUMN deleted_at timestamp with time zone;
COMMENT ON COLUMN public.user_profiles.deleted_at IS 'When the person deleted the account (delete_user_account); NULL for a live account. A deleted profile keeps its row (history) with mobile DEL+12 hex characters, no assignments and no sessions.';

UPDATE public.user_profiles
   SET deleted_at = COALESCE(updated_at, created_at, now()), active = false, enrollment_status = 'disabled'
 WHERE deleted_at IS NULL AND mobile ~ '^DEL[0-9a-f]{12}$' AND name = 'Deleted User';

CREATE OR REPLACE FUNCTION warehouse_security.other_active_admin_exists(p_profile uuid) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(71043);
  RETURN EXISTS (SELECT 1 FROM public.user_profiles WHERE role='admin' AND active
    AND enrollment_status='approved' AND NOT is_service_account AND deleted_at IS NULL AND id IS DISTINCT FROM p_profile);
END $$;

CREATE OR REPLACE FUNCTION public.delete_user_account() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE profile_id uuid; profile_role text;
BEGIN
  -- A retry after a timed-out delete: the account is already deleted, which is what was asked.
  -- Read before the guard (a deleted account is inactive, so the guard would refuse it); it says
  -- nothing about anyone but the caller.
  IF auth.uid() IS NOT NULL AND EXISTS (SELECT 1 FROM public.user_profiles WHERE auth_user_id=auth.uid() AND deleted_at IS NOT NULL) THEN
    RETURN jsonb_build_object('success',true,'message','Account deleted','already_deleted',true);
  END IF;
  PERFORM warehouse_security.authorize_rpc('delete_user_account','{}'::jsonb);
  SELECT id, role::text INTO STRICT profile_id, profile_role FROM public.user_profiles WHERE auth_user_id=auth.uid() AND active;
  IF EXISTS (SELECT 1 FROM public.user_profiles WHERE id=profile_id AND is_service_account) THEN
    RETURN jsonb_build_object('success',false,'code','SERVICE_ACCOUNT_READ_ONLY','error_code','SERVICE_ACCOUNT_READ_ONLY',
      'error','A service account cannot be deleted','message','A service account cannot be deleted');
  END IF;
  IF profile_role='admin' AND NOT warehouse_security.other_active_admin_exists(profile_id) THEN
    RETURN jsonb_build_object('success',false,'code','LAST_ADMIN','error_code','LAST_ADMIN',
      'error','The only administrator cannot delete this account. Make another user an administrator first.',
      'message','The only administrator cannot delete this account. Make another user an administrator first.');
  END IF;
  DELETE FROM public.users_customers_new WHERE user_profile_id=profile_id;
  DELETE FROM public.user_session_activity WHERE user_id=profile_id;
  DELETE FROM warehouse_security.refresh_sessions WHERE user_id=auth.uid();
  UPDATE public.user_profiles SET name='Deleted User',display_name='Deleted User',active=false,
    mobile='DEL'||left(replace(profile_id::text,'-',''),12),mobile_verified=false,mobile_verified_at=NULL,
    central_issuer=NULL,central_subject=NULL,deleted_at=now()
    WHERE id=profile_id;
  RETURN jsonb_build_object('success',true,'message','Account deleted');
END $$;

CREATE OR REPLACE FUNCTION public.get_users_list(p_search_query text DEFAULT ''::text, p_role_filter public.user_role[] DEFAULT NULL::public.user_role[], p_active_filter boolean DEFAULT NULL::boolean, p_limit integer DEFAULT 20, p_offset integer DEFAULT 0) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_auth_uid UUID;
    v_caller_id UUID;
    v_caller_role user_role;
    v_search TEXT;
    v_total_count INTEGER;
    v_total_all INTEGER;
    v_users jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_users_list',jsonb_build_object());
    v_auth_uid := auth.uid();

    SELECT id, role INTO v_caller_id, v_caller_role
    FROM user_profiles
    WHERE auth_user_id = v_auth_uid AND active = true;

    IF v_caller_role IS NULL OR v_caller_role NOT IN ('admin', 'supervisor') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'PERMISSION_DENIED',
            'error_code', 'PERMISSION_DENIED',
            'message', 'Only administrators and supervisors can view user list'
        );
    END IF;

    IF p_limit IS NULL OR p_limit < 1 THEN
        p_limit := 20;
    ELSIF p_limit > 100 THEN
        p_limit := 100;
    END IF;

    IF p_offset IS NULL OR p_offset < 0 THEN
        p_offset := 0;
    END IF;

    v_search := TRIM(COALESCE(p_search_query, ''));

    -- total_count leaves deleted accounts out; total_with_deleted counts every row the list can return.
    -- A deleted account has no phone, so the search matches its name only.
    SELECT COUNT(*) FILTER (WHERE up.deleted_at IS NULL), COUNT(*) INTO v_total_count, v_total_all
    FROM user_profiles up
    WHERE
        (v_search = '' OR up.name ILIKE '%' || v_search || '%' OR (up.deleted_at IS NULL AND up.mobile ILIKE '%' || v_search || '%'))
        AND (p_role_filter IS NULL OR up.role = ANY(p_role_filter))
        AND (p_active_filter IS NULL OR up.active = p_active_filter)
        AND (v_caller_role = 'admin' OR up.role != 'admin');

    -- Live accounts first (by name), deleted accounts after them: total_count is then the number of rows
    -- before the first deleted one.
    SELECT jsonb_agg(
        jsonb_build_object(
            'id', sub.id,
            'auth_user_id', sub.auth_user_id,
            'name', sub.name,
            'display_name', sub.display_name,
            'mobile', CASE WHEN sub.deleted_at IS NULL THEN sub.mobile END,
            'role', sub.role,
            'active', sub.active,
            'is_service_account', sub.is_service_account,
            'enrollment_status', CASE WHEN sub.enrollment_status IN ('pending','rejected') THEN sub.enrollment_status END,
            'is_deleted', (sub.deleted_at IS NOT NULL),
            'deleted_at', sub.deleted_at,
            'created_at', sub.created_at,
            'updated_at', sub.updated_at,
            'assigned_customers_count', COALESCE(
                (SELECT COUNT(*) FROM users_customers_new uc
                 WHERE uc.user_profile_id = sub.id AND uc.active = true), 0
            )
        ) ORDER BY (sub.deleted_at IS NOT NULL) ASC, sub.name ASC, sub.id ASC
    ) INTO v_users
    FROM (
        SELECT id, auth_user_id, name, display_name, mobile, role, active, is_service_account, enrollment_status, deleted_at, created_at, updated_at
        FROM user_profiles up
        WHERE
            (v_search = '' OR up.name ILIKE '%' || v_search || '%' OR (up.deleted_at IS NULL AND up.mobile ILIKE '%' || v_search || '%'))
            AND (p_role_filter IS NULL OR up.role = ANY(p_role_filter))
            AND (p_active_filter IS NULL OR up.active = p_active_filter)
            AND (v_caller_role = 'admin' OR up.role != 'admin')
        ORDER BY (up.deleted_at IS NOT NULL) ASC, name ASC, id ASC
        LIMIT p_limit OFFSET p_offset
    ) sub;

    RETURN jsonb_build_object(
        'success', true,
        'users', COALESCE(v_users, '[]'::jsonb),
        'pagination', jsonb_build_object(
            'total_count', v_total_count,
            'total_with_deleted', v_total_all,
            'limit', p_limit,
            'offset', p_offset,
            'has_more', (p_offset + p_limit) < v_total_all
        )
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'INTERNAL_ERROR',
            'error_code', 'INTERNAL_ERROR',
            'message', 'Failed to retrieve users list: ' || SQLERRM
        );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_user_details(p_user_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_auth_uid UUID;
    v_caller_id UUID;
    v_caller_role user_role;
    v_target_user jsonb;
    v_target_role user_role;
    v_assigned_customers jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_user_details',jsonb_build_object());
    v_auth_uid := auth.uid();

    SELECT id, role INTO v_caller_id, v_caller_role
    FROM user_profiles
    WHERE auth_user_id = v_auth_uid AND active = true;

    IF v_caller_role IS NULL OR v_caller_role NOT IN ('admin', 'supervisor') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'PERMISSION_DENIED',
            'error_code', 'PERMISSION_DENIED',
            'message', 'Only administrators and supervisors can view user details'
        );
    END IF;

    IF p_user_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'INVALID_INPUT',
            'error_code', 'INVALID_INPUT',
            'message', 'User ID is required'
        );
    END IF;

    SELECT role INTO v_target_role
    FROM user_profiles
    WHERE id = p_user_id;

    IF v_target_role IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'NOT_FOUND',
            'error_code', 'NOT_FOUND',
            'message', 'User not found'
        );
    END IF;

    IF v_caller_role = 'supervisor' AND v_target_role = 'admin' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'PERMISSION_DENIED',
            'error_code', 'PERMISSION_DENIED',
            'message', 'Supervisors cannot view admin user details'
        );
    END IF;

    SELECT jsonb_build_object(
        'id', up.id,
        'auth_user_id', up.auth_user_id,
        'name', up.name,
        'display_name', up.display_name,
        'mobile', CASE WHEN up.deleted_at IS NULL THEN up.mobile END,
        'role', up.role,
        'active', up.active,
        'is_service_account', up.is_service_account,
        'enrollment_status', CASE WHEN up.enrollment_status IN ('pending','rejected') THEN up.enrollment_status END,
        'is_deleted', (up.deleted_at IS NOT NULL),
        'deleted_at', up.deleted_at,
        'created_at', up.created_at,
        'updated_at', up.updated_at,
        'mobile_verified', up.mobile_verified,
        'mobile_verified_at', up.mobile_verified_at,
        'assigned_customers_count', COALESCE(
            (SELECT COUNT(*) FROM users_customers_new uc
             WHERE uc.user_profile_id = up.id AND uc.active = true), 0
        )
    ) INTO v_target_user
    FROM user_profiles up
    WHERE up.id = p_user_id;

    -- Sorted by customer name, then id; customer_active is the business's own active state.
    SELECT jsonb_agg(
        jsonb_build_object(
            'customer_id', c.id,
            'customer_name', c.name,
            'customer_mobile', c.mobile,
            'customer_city', c.city,
            'customer_active', c.active,
            'assigned_at', uc.assigned_at,
            'assigned_by_name', (
                SELECT name FROM user_profiles WHERE id = uc.assigned_by
            )
        ) ORDER BY c.name ASC, c.id ASC
    ) INTO v_assigned_customers
    FROM users_customers_new uc
    JOIN customers c ON c.id = uc.customer_id
    WHERE uc.user_profile_id = p_user_id AND uc.active = true;

    RETURN jsonb_build_object(
        'success', true,
        'user', v_target_user,
        'assigned_customers', COALESCE(v_assigned_customers, '[]'::jsonb)
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'INTERNAL_ERROR',
            'error_code', 'INTERNAL_ERROR',
            'message', 'Failed to retrieve user details: ' || SQLERRM
        );
END;
$$;

CREATE OR REPLACE FUNCTION public.update_user_role(p_user_id uuid, p_new_role public.user_role) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_auth_uid UUID;
    v_caller_id UUID;
    v_caller_role user_role;
    v_target_id UUID;
    v_old_role user_role;
    v_deleted timestamptz;
    v_removed integer := 0;
BEGIN
  PERFORM warehouse_security.authorize_rpc('update_user_role',jsonb_build_object());
    v_auth_uid := auth.uid();

    SELECT id, role INTO v_caller_id, v_caller_role
    FROM user_profiles
    WHERE auth_user_id = v_auth_uid AND active = true;

    IF v_caller_role IS NULL OR v_caller_role NOT IN ('admin', 'supervisor') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'PERMISSION_DENIED',
            'error_code', 'PERMISSION_DENIED',
            'message', 'Only administrators and supervisors can change user roles'
        );
    END IF;

    -- One user change at a time, and the target row is read under lock (migration 87).
    PERFORM pg_advisory_xact_lock(71043);

    IF p_user_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'INVALID_INPUT',
            'error_code', 'INVALID_INPUT',
            'message', 'User ID is required'
        );
    END IF;

    IF p_new_role IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'INVALID_INPUT',
            'error_code', 'INVALID_INPUT',
            'message', 'New role is required'
        );
    END IF;

    SELECT id, role, deleted_at INTO v_target_id, v_old_role, v_deleted
    FROM user_profiles
    WHERE id = p_user_id
    FOR UPDATE;

    IF v_target_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'NOT_FOUND',
            'error_code', 'NOT_FOUND',
            'message', 'User not found'
        );
    END IF;

    IF v_deleted IS NOT NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'ACCOUNT_DELETED',
            'error_code', 'ACCOUNT_DELETED',
            'message', 'This account was deleted and cannot be changed'
        );
    END IF;

    IF EXISTS (SELECT 1 FROM user_profiles WHERE id = v_target_id AND is_service_account) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'SERVICE_ACCOUNT_READ_ONLY',
            'error_code', 'SERVICE_ACCOUNT_READ_ONLY',
            'message', 'A service account cannot be changed here'
        );
    END IF;

    IF v_caller_id = v_target_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'SELF_EDIT_FORBIDDEN',
            'error_code', 'SELF_EDIT_FORBIDDEN',
            'message', 'You cannot change your own role'
        );
    END IF;

    -- error keeps its old value for old apps; error_code is the stable code.
    IF v_caller_role = 'supervisor' AND v_old_role = 'admin' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'PERMISSION_DENIED',
            'error_code', 'CANNOT_MODIFY_ADMIN',
            'message', 'Supervisors cannot modify admin users'
        );
    END IF;

    IF v_caller_role = 'supervisor' AND p_new_role = 'admin' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'CANNOT_PROMOTE_TO_ADMIN',
            'error_code', 'CANNOT_PROMOTE_TO_ADMIN',
            'message', 'Supervisors cannot promote users to admin role'
        );
    END IF;

    IF EXISTS (SELECT 1 FROM user_profiles WHERE id = p_user_id AND enrollment_status = 'pending') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'ENROLLMENT_PENDING',
            'error_code', 'ENROLLMENT_PENDING',
            'message', 'Review the access request before changing the role'
        );
    END IF;

    IF EXISTS (SELECT 1 FROM user_profiles WHERE id = p_user_id AND enrollment_status = 'rejected') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'ENROLLMENT_REJECTED',
            'error_code', 'ENROLLMENT_REJECTED',
            'message', 'This access request was rejected; use Review again before changing the role'
        );
    END IF;

    IF v_caller_role = 'supervisor' AND EXISTS (
        SELECT 1 FROM user_profiles WHERE id = p_user_id AND enrollment_status IS DISTINCT FROM 'approved'
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'ENROLLMENT_NOT_APPROVED',
            'error_code', 'ENROLLMENT_NOT_APPROVED',
            'message', 'Only an administrator can change a user whose access is not approved'
        );
    END IF;

    IF v_old_role = p_new_role THEN
        RETURN jsonb_build_object(
            'success', true,
            'user_id', p_user_id,
            'old_role', v_old_role,
            'new_role', p_new_role,
            'removed_customer_count', 0,
            'message', 'Role unchanged'
        );
    END IF;

    IF v_old_role = 'admin' AND NOT warehouse_security.other_active_admin_exists(v_target_id) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'LAST_ADMIN',
            'error_code', 'LAST_ADMIN',
            'message', 'The last active administrator cannot be given another role'
        );
    END IF;

    UPDATE user_profiles
    SET role = p_new_role,
        updated_at = now()
    WHERE id = p_user_id;

    -- A person who stops being a Customer keeps no customer assignments (same transaction).
    IF v_old_role = 'customer' AND p_new_role <> 'customer' THEN
        WITH removed AS (
            UPDATE users_customers_new SET active = false
            WHERE user_profile_id = p_user_id AND active
            RETURNING 1
        )
        SELECT COUNT(*) INTO v_removed FROM removed;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'user_id', p_user_id,
        'old_role', v_old_role,
        'new_role', p_new_role,
        'removed_customer_count', v_removed,
        'message', 'Role updated successfully'
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'INTERNAL_ERROR',
            'error_code', 'INTERNAL_ERROR',
            'message', 'Failed to update user role: ' || SQLERRM
        );
END;
$$;

CREATE OR REPLACE FUNCTION public.update_user_status(p_user_id uuid, p_active boolean) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_auth_uid UUID;
    v_caller_id UUID;
    v_caller_role user_role;
    v_target_id UUID;
    v_target_role user_role;
    v_old_active BOOLEAN;
    v_deleted timestamptz;
    v_service boolean;
    v_enrollment text;
BEGIN
  PERFORM warehouse_security.authorize_rpc('update_user_status',jsonb_build_object());
    v_auth_uid := auth.uid();

    SELECT id, role INTO v_caller_id, v_caller_role
    FROM user_profiles
    WHERE auth_user_id = v_auth_uid AND active = true;

    IF v_caller_role IS NULL OR v_caller_role NOT IN ('admin', 'supervisor') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'PERMISSION_DENIED',
            'error_code', 'PERMISSION_DENIED',
            'message', 'Only administrators and supervisors can change user status'
        );
    END IF;

    -- One user change at a time, and the target row is read under lock (migration 87).
    PERFORM pg_advisory_xact_lock(71043);

    IF p_user_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'INVALID_INPUT',
            'error_code', 'INVALID_INPUT',
            'message', 'User ID is required'
        );
    END IF;

    IF p_active IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'INVALID_INPUT',
            'error_code', 'INVALID_INPUT',
            'message', 'Active status is required'
        );
    END IF;

    SELECT id, role, active, deleted_at, is_service_account, enrollment_status
      INTO v_target_id, v_target_role, v_old_active, v_deleted, v_service, v_enrollment
    FROM user_profiles
    WHERE id = p_user_id
    FOR UPDATE;

    IF v_target_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'NOT_FOUND',
            'error_code', 'NOT_FOUND',
            'message', 'User not found'
        );
    END IF;

    IF v_deleted IS NOT NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'ACCOUNT_DELETED',
            'error_code', 'ACCOUNT_DELETED',
            'message', 'This account was deleted and cannot be changed'
        );
    END IF;

    -- A service account is read-only here, except that an administrator can cut it off (migration 78);
    -- the FAS sync "Disconnect" is administrator only.
    IF p_active AND v_service THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'SERVICE_ACCOUNT_READ_ONLY',
            'error_code', 'SERVICE_ACCOUNT_READ_ONLY',
            'message', 'A service account cannot be changed here'
        );
    END IF;
    IF v_service AND v_caller_role <> 'admin' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'PERMISSION_DENIED',
            'error_code', 'PERMISSION_DENIED',
            'message', 'Only an administrator can disconnect a service account'
        );
    END IF;

    IF v_caller_id = v_target_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'SELF_EDIT_FORBIDDEN',
            'error_code', 'SELF_EDIT_FORBIDDEN',
            'message', 'You cannot change your own status'
        );
    END IF;

    IF v_caller_role = 'supervisor' AND v_target_role = 'admin' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'CANNOT_MODIFY_ADMIN',
            'error_code', 'CANNOT_MODIFY_ADMIN',
            'message', 'Supervisors cannot modify admin users'
        );
    END IF;

    IF v_caller_role = 'supervisor' AND v_enrollment IS DISTINCT FROM 'approved' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'ENROLLMENT_NOT_APPROVED',
            'error_code', 'ENROLLMENT_NOT_APPROVED',
            'message', 'Only an administrator can change a user whose access is not approved'
        );
    END IF;

    -- The Active switch does not approve an access request: review it (pending) or review it again (rejected).
    IF p_active AND v_enrollment = 'pending' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'ENROLLMENT_PENDING',
            'error_code', 'ENROLLMENT_PENDING',
            'message', 'This person has an open access request. Review it in Access requests.'
        );
    END IF;
    IF p_active AND v_enrollment = 'rejected' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'ENROLLMENT_REJECTED',
            'error_code', 'ENROLLMENT_REJECTED',
            'message', 'This access request was rejected. Review it again before activating the person.'
        );
    END IF;

    IF v_old_active = p_active THEN
        RETURN jsonb_build_object(
            'success', true,
            'user_id', p_user_id,
            'active', p_active,
            'message', 'Status unchanged'
        );
    END IF;

    IF NOT p_active AND v_target_role = 'admin' AND NOT warehouse_security.other_active_admin_exists(v_target_id) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'LAST_ADMIN',
            'error_code', 'LAST_ADMIN',
            'message', 'The last active administrator cannot be deactivated'
        );
    END IF;

    UPDATE user_profiles
    SET active = p_active,
        enrollment_status = CASE WHEN p_active THEN 'approved' ELSE 'disabled' END,
        updated_at = now()
    WHERE id = p_user_id;
    IF NOT p_active THEN
        DELETE FROM warehouse_security.refresh_sessions
        WHERE user_id = (SELECT auth_user_id FROM user_profiles WHERE id = p_user_id);
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'user_id', p_user_id,
        'active', p_active,
        'message', CASE WHEN p_active THEN 'User activated successfully' ELSE 'User deactivated successfully' END
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'INTERNAL_ERROR',
            'error_code', 'INTERNAL_ERROR',
            'message', 'Failed to update user status: ' || SQLERRM
        );
END;
$$;

-- Administrators put a rejected access request back to pending, so it shows in Access requests again.
-- Supervisors pass the guard (they use the Users screens) and are refused here.
CREATE FUNCTION public.review_enrollment_again(p_user_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_role text;
    v_profile public.user_profiles;
BEGIN
  PERFORM warehouse_security.authorize_rpc('review_enrollment_again',jsonb_build_object());
    v_role := warehouse_security.active_role();
    IF auth.jwt()->>'role' IS DISTINCT FROM 'service_role' AND v_role IS DISTINCT FROM 'admin' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'PERMISSION_DENIED',
            'error_code', 'PERMISSION_DENIED',
            'message', 'Only administrators can review an access request again'
        );
    END IF;

    PERFORM pg_advisory_xact_lock(71043);

    IF p_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_INPUT', 'error_code', 'INVALID_INPUT',
            'message', 'User ID is required');
    END IF;

    SELECT * INTO v_profile FROM public.user_profiles WHERE id = p_user_id FOR UPDATE;
    IF v_profile.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND', 'error_code', 'NOT_FOUND',
            'message', 'User not found');
    END IF;
    IF v_profile.deleted_at IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'ACCOUNT_DELETED', 'error_code', 'ACCOUNT_DELETED',
            'message', 'This account was deleted and cannot be changed');
    END IF;
    IF v_profile.is_service_account THEN
        RETURN jsonb_build_object('success', false, 'error', 'SERVICE_ACCOUNT_READ_ONLY', 'error_code', 'SERVICE_ACCOUNT_READ_ONLY',
            'message', 'A service account cannot be changed here');
    END IF;

    -- Already pending: nothing to do (a second tap, or another administrator was first).
    IF v_profile.enrollment_status = 'pending' THEN
        RETURN jsonb_build_object('success', true, 'user_id', p_user_id, 'enrollment_status', 'pending',
            'changed', false, 'message', 'Access request is already waiting for review');
    END IF;
    IF v_profile.enrollment_status IS DISTINCT FROM 'rejected' THEN
        RETURN jsonb_build_object('success', false, 'error', 'NOT_REJECTED', 'error_code', 'NOT_REJECTED',
            'message', 'Only a rejected access request can be reviewed again');
    END IF;

    -- Back to the request's original state: a Customer (the role is chosen on approval). Also repairs
    -- a rejected person whose role was changed before update_user_role refused rejected profiles.
    UPDATE public.user_profiles SET enrollment_status = 'pending', active = false, role = 'customer', updated_at = now()
     WHERE id = p_user_id;

    RETURN jsonb_build_object('success', true, 'user_id', p_user_id, 'enrollment_status', 'pending',
        'changed', true, 'message', 'Access request is waiting for review again');

EXCEPTION
    WHEN insufficient_privilege THEN
        RAISE;
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'error', 'INTERNAL_ERROR', 'error_code', 'INTERNAL_ERROR',
            'message', 'Failed to review the access request again: ' || SQLERRM);
END;
$$;

ALTER FUNCTION public.review_enrollment_again(p_user_id uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.review_enrollment_again(p_user_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.review_enrollment_again(p_user_id uuid) TO service_role;
GRANT ALL ON FUNCTION public.review_enrollment_again(p_user_id uuid) TO authenticated;

-- Customer assignment: still boolean answers; the exception message starts with a stable code
-- ("CODE: text"), like SERVICE_ACCOUNT_READ_ONLY already did.
CREATE OR REPLACE FUNCTION public.assign_customer_to_user(target_user_mobile character varying, target_customer_id uuid, assigner_comment text DEFAULT NULL::text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
  DECLARE
      target_user_id uuid;
      customer_name_val varchar(80);
      customer_active_val boolean;
      customer_deleted_val timestamptz;
      assigner_id uuid;
BEGIN
  PERFORM warehouse_security.authorize_rpc('assign_customer_to_user',jsonb_build_object());
      IF NOT is_admin_or_supervisor() THEN
          RAISE EXCEPTION 'PERMISSION_DENIED: Only admins and supervisors can assign customers to users' USING ERRCODE = '42501';
      END IF;

      SELECT id INTO target_user_id
      FROM user_profiles
      WHERE mobile = target_user_mobile AND active = true AND deleted_at IS NULL
      FOR SHARE;  -- waits for a concurrent role change (update_user_role holds the row FOR UPDATE)

      IF target_user_id IS NULL THEN
          RAISE EXCEPTION 'NOT_FOUND: User with mobile % not found or inactive', target_user_mobile;
      END IF;

      IF warehouse_security.active_role() = 'supervisor' THEN
          IF target_user_id = public.get_current_user_profile_id() THEN
              RAISE EXCEPTION 'SELF_EDIT_FORBIDDEN: Supervisors cannot change their own or an administrator''s customer assignments' USING ERRCODE = '42501';
          ELSIF EXISTS (SELECT 1 FROM user_profiles WHERE id = target_user_id AND role = 'admin') THEN
              RAISE EXCEPTION 'CANNOT_MODIFY_ADMIN: Supervisors cannot change their own or an administrator''s customer assignments' USING ERRCODE = '42501';
          END IF;
      END IF;

      IF EXISTS (SELECT 1 FROM user_profiles WHERE id = target_user_id AND is_service_account) THEN
          RAISE EXCEPTION 'SERVICE_ACCOUNT_READ_ONLY: A service account cannot be changed here';
      END IF;

      SELECT name, active, deleted_at INTO customer_name_val, customer_active_val, customer_deleted_val
      FROM customers
      WHERE id = target_customer_id;

      IF customer_name_val IS NULL OR customer_deleted_val IS NOT NULL THEN
          RAISE EXCEPTION 'NOT_FOUND: Customer with ID % not found', target_customer_id;
      END IF;
      IF NOT customer_active_val THEN
          RAISE EXCEPTION 'CUSTOMER_INACTIVE: Customer % is deactivated', customer_name_val;
      END IF;

      SELECT id INTO assigner_id
      FROM user_profiles
      WHERE auth_user_id = auth.uid();

      INSERT INTO users_customers_new (
          user_profile_id,
          customer_id,
          customer_name,
          assigned_by,
          active
      ) VALUES (
          target_user_id,
          target_customer_id,
          customer_name_val,
          assigner_id,
          true
      )
      ON CONFLICT (user_profile_id, customer_id)
      DO UPDATE SET
          active = true,
          assigned_at = now(),
          assigned_by = assigner_id,
          customer_name = customer_name_val;

      RETURN true;
  END;
$$;

CREATE OR REPLACE FUNCTION public.remove_customer_assignment(target_user_mobile character varying, target_customer_id uuid) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
  DECLARE
      target_user_id uuid;
BEGIN
  PERFORM warehouse_security.authorize_rpc('remove_customer_assignment',jsonb_build_object());
      IF NOT is_admin_or_supervisor() THEN
          RAISE EXCEPTION 'PERMISSION_DENIED: Only admins and supervisors can remove customer assignments' USING ERRCODE = '42501';
      END IF;

      SELECT id INTO target_user_id
      FROM user_profiles
      WHERE mobile = target_user_mobile AND active = true AND deleted_at IS NULL;

      IF target_user_id IS NULL THEN
          RAISE EXCEPTION 'NOT_FOUND: User with mobile % not found or inactive', target_user_mobile;
      END IF;

      IF warehouse_security.active_role() = 'supervisor' THEN
          IF target_user_id = public.get_current_user_profile_id() THEN
              RAISE EXCEPTION 'SELF_EDIT_FORBIDDEN: Supervisors cannot change their own or an administrator''s customer assignments' USING ERRCODE = '42501';
          ELSIF EXISTS (SELECT 1 FROM user_profiles WHERE id = target_user_id AND role = 'admin') THEN
              RAISE EXCEPTION 'CANNOT_MODIFY_ADMIN: Supervisors cannot change their own or an administrator''s customer assignments' USING ERRCODE = '42501';
          END IF;
      END IF;

      IF EXISTS (SELECT 1 FROM user_profiles WHERE id = target_user_id AND is_service_account) THEN
          RAISE EXCEPTION 'SERVICE_ACCOUNT_READ_ONLY: A service account cannot be changed here';
      END IF;

      UPDATE users_customers_new
      SET active = false
      WHERE user_profile_id = target_user_id
      AND customer_id = target_customer_id;

      RETURN true;
  END;
$$;

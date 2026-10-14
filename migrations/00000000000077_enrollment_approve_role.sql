-- Migration 77: approve an access request as staff or supervisor (Settings UX batch, 2026-10-14).
--
-- operator_review_enrollment(p_user_id, p_decision, p_customer_ids, p_role) gets a fourth
-- argument, p_role, one of 'customer' (the default, exactly as before: at least one customer
-- must be named), 'staff' or 'supervisor' (no customers: the person is given that role and no
-- customer assignment). Administrators only, as before. A call with three arguments still
-- works through the default. The answer is {success:true, data:{status, role}}; refusals of the
-- new arguments are {success:false, error, error_code, code, data} with error_code
-- INVALID_ROLE or CUSTOMERS_NOT_ALLOWED (the existing refusals are unchanged).

DROP FUNCTION public.operator_review_enrollment(uuid, text, uuid[]);

CREATE FUNCTION public.operator_review_enrollment(
  p_user_id uuid, p_decision text, p_customer_ids uuid[] DEFAULT '{}'::uuid[], p_role text DEFAULT 'customer')
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE profile public.user_profiles; assigned_customer uuid; admin_id uuid; result_role text;
BEGIN
  IF auth.jwt()->>'role' IS DISTINCT FROM 'authenticated' OR warehouse_security.active_role() IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';
  END IF;
  SELECT id INTO admin_id FROM public.user_profiles WHERE auth_user_id=auth.uid();
  SELECT * INTO profile FROM public.user_profiles WHERE id=p_user_id FOR UPDATE;
  IF profile.id IS NULL OR profile.role<>'customer' THEN RETURN jsonb_build_object('success',false,'code','unknown_user'); END IF;
  IF p_decision NOT IN ('approved','rejected','disabled') THEN RAISE EXCEPTION 'Invalid decision' USING ERRCODE='22023'; END IF;
  IF p_role IS NULL OR p_role NOT IN ('customer','staff','supervisor') THEN
    RETURN jsonb_build_object('success',false,'error','Role must be customer, staff or supervisor',
      'error_code','INVALID_ROLE','code','INVALID_ROLE','data','{}'::jsonb);
  END IF;
  -- Only a request that is still pending is approved or rejected: a decision from a stale list
  -- must not re-decide a customer another administrator already approved, rejected or disabled.
  IF p_decision IN ('approved','rejected') AND profile.enrollment_status IS DISTINCT FROM 'pending' THEN
    RETURN jsonb_build_object('success',false,'code','unknown_user');
  END IF;
  result_role := profile.role::text;
  IF p_decision='approved' THEN
    IF p_role='customer' THEN
      IF COALESCE(cardinality(p_customer_ids),0)<1 OR EXISTS (SELECT 1 FROM unnest(p_customer_ids) AS requested(id)
        WHERE NOT EXISTS (SELECT 1 FROM public.customers c WHERE c.id=requested.id)) THEN
        RAISE EXCEPTION 'At least one valid customer assignment is required' USING ERRCODE='22023';
      END IF;
    ELSIF COALESCE(cardinality(p_customer_ids),0)>0 THEN
      RETURN jsonb_build_object('success',false,'error','Staff and supervisors are not assigned to customers',
        'error_code','CUSTOMERS_NOT_ALLOWED','code','CUSTOMERS_NOT_ALLOWED','data','{}'::jsonb);
    END IF;
    UPDATE public.user_profiles SET role=p_role::public.user_role,enrollment_status='approved',active=true,updated_at=now() WHERE id=p_user_id;
    result_role := p_role;
    UPDATE public.users_customers_new SET active=false WHERE user_profile_id=p_user_id;
    IF p_role='customer' THEN
      FOREACH assigned_customer IN ARRAY p_customer_ids LOOP
        INSERT INTO public.users_customers_new(user_profile_id,customer_id,assigned_by,active)
        VALUES (p_user_id,assigned_customer,admin_id,true)
        ON CONFLICT(user_profile_id,customer_id) DO UPDATE SET active=true,assigned_by=excluded.assigned_by,assigned_at=now();
      END LOOP;
    END IF;
  ELSE
    UPDATE public.user_profiles SET enrollment_status=p_decision,active=false,updated_at=now() WHERE id=p_user_id;
    UPDATE public.users_customers_new SET active=false WHERE user_profile_id=p_user_id;
    DELETE FROM warehouse_security.refresh_sessions WHERE user_id=profile.auth_user_id;
  END IF;
  RETURN jsonb_build_object('success',true,'data',jsonb_build_object('status',p_decision,'role',result_role));
END $function$;

REVOKE EXECUTE ON FUNCTION public.operator_review_enrollment(uuid,text,uuid[],text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.operator_review_enrollment(uuid,text,uuid[],text) TO authenticated;
NOTIFY pgrst, 'reload schema';

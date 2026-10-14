-- Migration 80: backlog fixes (2026-10-14).
--
--   1. A service account is not a supervisor of a document. Migration 78 made a service account
--      "a connection, not a person" and took it out of the Supervisor picker (get_supervisors), but
--      save_grn, update_grn, create_dispatch_with_stock_check and update_dispatch_smart still
--      accepted its profile id sent directly. They now raise 'Supervisor must be a person, not a
--      service account' (P0001), with ONE exception decided by the owner: a service account may name
--      ITSELF, i.e. the profile whose auth user is auth.uid() (the FAS sync acts as its own profile and
--      names it as supervisor). The edits (update_grn, update_dispatch_smart) also let the document keep
--      the supervisor it already has. update_grn checks 'GRN not found' before this rule. The rule is one
--      helper, warehouse_security.require_person_supervisor, not granted to the app roles.
--   2. get_or_create_cart refuses a business that is deactivated (customers.active = false) or
--      deleted (deleted_at set) with 'Business is not active' (P0001): never a new order (nor the
--      DISPATCHED -> OPEN reset of an existing one), and a customer login is refused even for an
--      existing open order. An administrator, supervisor or staff member may still open the EXISTING
--      OPEN order, which is returned as before. Everything else about it is unchanged.
--   3. Two total weights that no screen shows added the per-bag weight without the bags:
--        get_grn_details       data statistics.total_weight   was SUM(weight); now the kg of the
--                              receipt's lines, SUM(weight x qty) (bags received, as migration 59
--                              counts a receipt in the GRN activity report).
--        get_stock_aging_report  summary.total_weight_kg and by_bucket[*].total_weight
--                              were SUM(weight); now SUM(weight x current_stock): the kg of the stock
--                              still in the warehouse. Each line's own weight stays the kg of one bag.
--      A line without a per-bag weight counts as 0 (SUM skips it), as before. No key name, type or
--      shape changes.
--
--   4. get_my_access_status() tells the app why a signed-in customer sees no business: 'revoked'
--      (the profile is inactive, or it has customer assignments and none is active), 'none' (an
--      active profile that never had an assignment and is not staff, supervisor or administrator)
--      or 'active' (anything else). A profile that is already inactive normally never reaches it over
--      the API (PostgREST's check_session refuses its session first); the answer for it is what a direct
--      call (or a session that is still valid) gets. It reads only the caller's own profile and assignments, like
--      get_my_language, and is granted to authenticated and service_role only.
--
-- Method: the current definitions are patched, not rewritten (pg_get_functiondef keeps the guard,
-- SECURITY DEFINER, search_path and grants, and every migration since the first schema); each
-- replaced text must occur exactly as often as stated, or the migration fails and applies nothing.

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

-- The supervisor rule of migration 80 (see above). p_supervisor is text so that an unreadable value
-- is left to the caller's own validation. p_current is the supervisor the document already has.
CREATE FUNCTION warehouse_security.require_person_supervisor(p_supervisor text, p_current uuid DEFAULT NULL) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'pg_catalog' AS $function$
BEGIN
  IF p_supervisor ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     AND EXISTS (SELECT 1 FROM public.user_profiles p
                 WHERE p.id = p_supervisor::uuid AND p.is_service_account
                   AND p.auth_user_id IS DISTINCT FROM auth.uid()
                   AND p.id IS DISTINCT FROM p_current) THEN
    RAISE EXCEPTION 'Supervisor must be a person, not a service account' USING ERRCODE = 'P0001';
  END IF;
END;
$function$;
REVOKE ALL ON FUNCTION warehouse_security.require_person_supervisor(text, uuid) FROM PUBLIC, anon, authenticated;

DO $patch$ BEGIN
  -- 1. A service account is not a supervisor (unless it names itself).
  PERFORM pg_temp.patch_rpc('public.save_grn(varchar,timestamptz,uuid,varchar,uuid,varchar,uuid,varchar,varchar,varchar,boolean,varchar,jsonb,jsonb,text,varchar)',
  $m$IF warehouse_security.is_blank_text(p_gr_no) OR p_date IS NULL OR p_customer_id IS NULL THEN$m$,
  $r$PERFORM warehouse_security.require_person_supervisor(p_supervisor_id::text);

      IF warehouse_security.is_blank_text(p_gr_no) OR p_date IS NULL OR p_customer_id IS NULL THEN$r$);
  PERFORM pg_temp.patch_rpc('public.update_grn(uuid,varchar,timestamptz,uuid,varchar,uuid,varchar,uuid,varchar,varchar,varchar,boolean,varchar,jsonb,jsonb,varchar,text)',
  $m$IF p_gr_no IS NOT NULL AND warehouse_security.is_blank_text(p_gr_no) THEN$m$,
  $r$PERFORM warehouse_security.require_person_supervisor(p_supervisor_id::text,
      (SELECT supervisor_id FROM goodsreceived WHERE id = p_grn_id));

    IF p_gr_no IS NOT NULL AND warehouse_security.is_blank_text(p_gr_no) THEN$r$);
  PERFORM pg_temp.patch_rpc('public.create_dispatch_with_stock_check(jsonb,jsonb[],integer,text)',
  $m$  PERFORM warehouse_security.authorize_rpc('create_dispatch_with_stock_check',jsonb_build_object());
$m$,
  $r$  PERFORM warehouse_security.authorize_rpc('create_dispatch_with_stock_check',jsonb_build_object());
  PERFORM warehouse_security.require_person_supervisor(p_dispatch_data->>'supervisor_id');
$r$);
  PERFORM pg_temp.patch_rpc('public.create_dispatch_with_stock_check(jsonb,jsonb[],boolean,integer,text)',
  $m$  PERFORM warehouse_security.authorize_rpc('create_dispatch_with_stock_check',jsonb_build_object());
$m$,
  $r$  PERFORM warehouse_security.authorize_rpc('create_dispatch_with_stock_check',jsonb_build_object());
  PERFORM warehouse_security.require_person_supervisor(p_dispatch_data->>'supervisor_id');
$r$);
  PERFORM pg_temp.patch_rpc('public.update_dispatch_smart(uuid,jsonb,jsonb[])',
  $m$  PERFORM warehouse_security.authorize_rpc('update_dispatch_smart',jsonb_build_object('p_dispatch_id',p_dispatch_id));
$m$,
  $r$  PERFORM warehouse_security.authorize_rpc('update_dispatch_smart',jsonb_build_object('p_dispatch_id',p_dispatch_id));
  PERFORM warehouse_security.require_person_supervisor(p_dispatch_data->>'supervisor_id',
    (SELECT supervisor_id FROM dispatch WHERE id = p_dispatch_id));
$r$);

  -- 2. An inactive or deleted business: no new order, no customer; staff may open the existing open one.
  PERFORM pg_temp.patch_rpc('public.get_or_create_cart(uuid)',
  $m$      IF NOT FOUND THEN
          RAISE EXCEPTION 'Customer not found: %', p_customer_id;
      END IF;
$m$,
  $r$      IF NOT FOUND THEN
          RAISE EXCEPTION 'Customer not found: %', p_customer_id;
      END IF;

      IF EXISTS (SELECT 1 FROM customers WHERE id = p_customer_id AND (active = false OR deleted_at IS NOT NULL))
         AND (warehouse_security.active_role() IS NULL
              OR warehouse_security.active_role() NOT IN ('admin', 'supervisor', 'staff')
              OR NOT EXISTS (SELECT 1 FROM orders WHERE customer_id = p_customer_id AND deleted_at IS NULL AND status = 'OPEN')) THEN
          RAISE EXCEPTION 'Business is not active' USING ERRCODE = 'P0001';
      END IF;
$r$);

  -- 3. Total weights are bags x kg per bag.
  PERFORM pg_temp.patch_rpc('public.get_grn_details(uuid)',
  $m$'total_weight', COALESCE(SUM(grt.weight), 0),$m$,
  $r$'total_weight', COALESCE(SUM(grt.weight::numeric * grt.qty), 0),$r$);
  PERFORM pg_temp.patch_rpc('public.get_stock_aging_report(uuid,integer[])',
  $m$SUM(weight)$m$,
  $r$SUM(weight::numeric * current_stock)$r$, 5);
END $patch$;

CREATE FUNCTION public.get_my_access_status() RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'pg_catalog' AS $function$
DECLARE
  me record;
BEGIN
  SELECT p.id, p.role, p.active INTO me FROM public.user_profiles p WHERE p.auth_user_id = auth.uid();
  IF me.id IS NULL THEN
    RETURN 'none';
  END IF;
  IF NOT me.active THEN
    RETURN 'revoked';
  END IF;
  IF me.role IN ('admin', 'supervisor', 'staff') THEN
    RETURN 'active';
  END IF;
  IF EXISTS (SELECT 1 FROM public.users_customers_new a WHERE a.user_profile_id = me.id AND a.active) THEN
    RETURN 'active';
  END IF;
  IF EXISTS (SELECT 1 FROM public.users_customers_new a WHERE a.user_profile_id = me.id) THEN
    RETURN 'revoked';
  END IF;
  RETURN 'none';
END;
$function$;
REVOKE ALL ON FUNCTION public.get_my_access_status() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_access_status() TO authenticated, service_role;

DROP FUNCTION pg_temp.patch_rpc(regprocedure, text, text, integer);
NOTIFY pgrst, 'reload schema';

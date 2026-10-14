-- Migration 80: backlog fixes (2026-10-14).
--
--   1. save_grn and update_grn refuse a service account as the supervisor. Migration 78 made a
--      service account "a connection, not a person" and took it out of the Supervisor picker
--      (get_supervisors), but both writers still accepted its profile id sent directly. They now
--      raise 'Supervisor must be a person, not a service account' (P0001). update_grn refuses it
--      only when it would CHANGE the receipt's supervisor: an edit that sends back the supervisor the
--      receipt already has (a receipt saved before migration 78, or whose profile was marked since)
--      still saves.
--   2. get_or_create_cart refuses a business that is deactivated (customers.active = false) or
--      deleted (deleted_at set) with 'Business is not active' (P0001), instead of opening an order
--      for it. Everything else about it is unchanged.
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
--      or 'active' (anything else). It reads only the caller's own profile and assignments, like
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

DO $patch$ BEGIN
  -- 1. A service account is not a supervisor.
  PERFORM pg_temp.patch_rpc('public.save_grn(varchar,timestamptz,uuid,varchar,uuid,varchar,uuid,varchar,varchar,varchar,boolean,varchar,jsonb,jsonb,text,varchar)',
  $m$IF warehouse_security.is_blank_text(p_gr_no) OR p_date IS NULL OR p_customer_id IS NULL THEN$m$,
  $r$IF p_supervisor_id IS NOT NULL
         AND EXISTS (SELECT 1 FROM user_profiles WHERE id = p_supervisor_id AND is_service_account) THEN
          RAISE EXCEPTION 'Supervisor must be a person, not a service account' USING ERRCODE = 'P0001';
      END IF;

      IF warehouse_security.is_blank_text(p_gr_no) OR p_date IS NULL OR p_customer_id IS NULL THEN$r$);
  PERFORM pg_temp.patch_rpc('public.update_grn(uuid,varchar,timestamptz,uuid,varchar,uuid,varchar,uuid,varchar,varchar,varchar,boolean,varchar,jsonb,jsonb,varchar,text)',
  $m$IF NOT EXISTS (SELECT 1 FROM goodsreceived WHERE id = p_grn_id) THEN$m$,
  $r$IF p_supervisor_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM user_profiles WHERE id = p_supervisor_id AND is_service_account)
       AND p_supervisor_id IS DISTINCT FROM (SELECT supervisor_id FROM goodsreceived WHERE id = p_grn_id) THEN
        RAISE EXCEPTION 'Supervisor must be a person, not a service account' USING ERRCODE = 'P0001';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM goodsreceived WHERE id = p_grn_id) THEN$r$);

  -- 2. No order for a deactivated or deleted business.
  PERFORM pg_temp.patch_rpc('public.get_or_create_cart(uuid)',
  $m$      IF NOT FOUND THEN
          RAISE EXCEPTION 'Customer not found: %', p_customer_id;
      END IF;
$m$,
  $r$      IF NOT FOUND THEN
          RAISE EXCEPTION 'Customer not found: %', p_customer_id;
      END IF;

      IF EXISTS (SELECT 1 FROM customers WHERE id = p_customer_id AND (active = false OR deleted_at IS NOT NULL)) THEN
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

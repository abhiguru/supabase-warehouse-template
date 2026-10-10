-- Business tables are written only through the guarded RPCs (review, 2026-10-10).
--
-- Migration 3 gave the shared `authenticated` database role INSERT, UPDATE and
-- DELETE on nineteen business tables and a FOR ALL policy for administrators and
-- supervisors. One PostgREST call (PATCH /rest/v1/invoice {"total":1}, PATCH
-- /rest/v1/goodsreceived_trl {"stock":999}, POST /rest/v1/stock_movements, a
-- two-step DELETE of dispatch_trl then dispatch) therefore went around every
-- rule the RPCs apply: the server-computed invoice totals and rate limits
-- (migrations 24 and 41), the discount reason (30 and 41), the stock checks,
-- the lot-ownership rule (39) and the dependency checks of the delete RPCs.
--
-- Owner decision: those two roles lose the direct write; reads stay. Every
-- function the `authenticated` role may execute that writes one of these tables
-- is SECURITY DEFINER and owned by the table owner, so the RPCs do not depend on
-- the caller's table privileges. service_role (Edge functions, print jobs,
-- sensor ingestion) and the database owner (Studio, operator scripts) are
-- unchanged. The column grant UPDATE(name, display_name) on user_profiles is
-- not one of the nineteen tables and stays.
DO $revoke$
DECLARE table_name text; policy_check text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY['customers','items','item_storage_prices','goodsreceived','goodsreceived_trl',
    'dispatch','dispatch_trl','invoice','invoice_trl','payments','orders','order_items','grn_images','dispatch_images',
    'stock_movements','print_jobs','sensor_devices','sensor_readings','sensor_health_events'] LOOP
    -- A table-level REVOKE also removes any column-level grant of the same kind.
    EXECUTE format('REVOKE INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER ON public.%I FROM PUBLIC, anon, authenticated', table_name);
    -- The privilege alone decides today. The policy is narrowed as well so that
    -- a later accidental table grant cannot reopen the write.
    SELECT cmd INTO policy_check FROM pg_policies
      WHERE schemaname='public' AND tablename=table_name AND policyname='starter_staff';
    IF policy_check IS DISTINCT FROM 'ALL' THEN
      RAISE EXCEPTION 'Expected the FOR ALL starter_staff policy on %, found %', table_name, COALESCE(policy_check,'none');
    END IF;
    EXECUTE format('DROP POLICY starter_staff ON public.%I', table_name);
    EXECUTE format('CREATE POLICY starter_staff ON public.%I FOR SELECT TO authenticated USING (warehouse_security.active_role() IN (''admin'',''supervisor''))', table_name);
  END LOOP;
END $revoke$;

-- The one direct write in use that had no granted RPC was an order's note
-- (PATCH /rest/v1/orders). update_order_metadata(uuid,text,text,timestamp) has
-- carried the RPC guard and written order history since migration 28 but was
-- not part of the API surface. The guard lets only administrators and
-- supervisors through, the roles that held the direct write.
REVOKE ALL ON FUNCTION public.update_order_metadata(uuid, text, text, timestamp without time zone) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_order_metadata(uuid, text, text, timestamp without time zone) TO authenticated, service_role;

-- Fail the migration rather than leave a half-closed surface. Only the nineteen
-- business tables are checked: a table an operator added to `public` is theirs
-- to grant and must not block the upgrade.
DO $verify$
DECLARE
  leftover text;
  business_tables CONSTANT text[] := ARRAY['customers','items','item_storage_prices','goodsreceived','goodsreceived_trl',
    'dispatch','dispatch_trl','invoice','invoice_trl','payments','orders','order_items','grn_images','dispatch_images',
    'stock_movements','print_jobs','sensor_devices','sensor_readings','sensor_health_events'];
BEGIN
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO leftover
  FROM pg_class c
  WHERE c.relnamespace='public'::regnamespace AND c.relkind IN ('r','p')
    AND c.relname = ANY (business_tables)
    AND (has_any_column_privilege('authenticated', c.oid, 'INSERT,UPDATE')
      OR has_table_privilege('authenticated', c.oid, 'DELETE,TRUNCATE'));
  IF leftover IS NOT NULL THEN
    RAISE EXCEPTION 'authenticated still holds a direct write on: %', leftover;
  END IF;
  SELECT string_agg(tablename || '.' || policyname, ', ' ORDER BY tablename, policyname) INTO leftover
  FROM pg_policies
  WHERE schemaname='public' AND cmd <> 'SELECT'
    AND tablename = ANY (business_tables);
  IF leftover IS NOT NULL THEN
    RAISE EXCEPTION 'Unexpected write policy on a business table: %', leftover;
  END IF;
END $verify$;

NOTIFY pgrst, 'reload schema';

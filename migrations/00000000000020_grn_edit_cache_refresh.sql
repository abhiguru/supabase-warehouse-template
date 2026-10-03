-- Normal table writes and bulk GRN edits must consume the same queue before
-- returning. Keep this helper internal; it is not an application RPC.
CREATE FUNCTION warehouse_security.refresh_dirty_lists() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE target record;
BEGIN
  PERFORM pg_advisory_xact_lock(71040);
  FOR target IN SELECT mv_name FROM public.mv_refresh_queue
    WHERE needs_refresh ORDER BY mv_name LOOP
    IF target.mv_name NOT IN ('mv_customer_stock_summary','mv_grn_daily_summary',
      'mv_dispatch_daily_summary','mv_grn_list','mv_dispatch_list','mv_orders_list','mv_invoice_list') THEN
      RAISE EXCEPTION 'Unexpected refresh target';
    END IF;
    EXECUTE format('REFRESH MATERIALIZED VIEW public.%I',target.mv_name);
    UPDATE public.mv_refresh_queue SET needs_refresh=false,last_refresh=now()
      WHERE mv_name=target.mv_name;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION warehouse_security.refresh_dirty_lists()
  FROM PUBLIC,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION warehouse_security.refresh_lists() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
  PERFORM warehouse_security.refresh_dirty_lists();
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION warehouse_security.refresh_lists()
  FROM PUBLIC,anon,authenticated,service_role;

-- Retain the imported bookkeeping and business/authorization logic. Its bulk
-- edit suppresses the item dirty trigger, so explicitly mark and flush the
-- starter queue after all edits. Refresh the seven supported lists once here:
-- GRN edits can also change the customer, date, item identity and weight.
DO $patch$
DECLARE fn regprocedure; definition text; marker text; addition text;
BEGIN
  SELECT p.oid::regprocedure INTO STRICT fn FROM pg_proc p
    WHERE p.pronamespace='public'::regnamespace AND p.proname='update_grn';
  definition := pg_get_functiondef(fn);
  marker := $before$        INSERT INTO mv_refresh_status (mv_name, is_dirty, last_marked_dirty_at)
        VALUES
            ('mv_grn_list', true, now()),
            ('mv_dispatch_list', true, now()),
            ('mv_customer_stock_summary', true, now())
        ON CONFLICT (mv_name) DO UPDATE SET
            is_dirty = true,
            last_marked_dirty_at = now();$before$;
  IF (length(definition)-length(replace(definition,marker,''))) <> length(marker) THEN
    RAISE EXCEPTION 'Expected one GRN edit refresh marker';
  END IF;
  addition := $after$

        PERFORM pg_advisory_xact_lock(71040);
        UPDATE public.mv_refresh_queue SET needs_refresh=true,last_marked_dirty=now()
          WHERE mv_name IN ('mv_customer_stock_summary','mv_grn_daily_summary',
            'mv_dispatch_daily_summary','mv_grn_list','mv_dispatch_list','mv_orders_list','mv_invoice_list');
        PERFORM warehouse_security.refresh_dirty_lists();$after$;
  EXECUTE replace(definition,marker,marker||addition);
END $patch$;
NOTIFY pgrst, 'reload schema';

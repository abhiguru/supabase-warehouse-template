-- Fresh installs previously populated the views once but never seeded the
-- queue used by the existing dirty/refresh triggers. Later writes therefore
-- left materialized lists stale. Register only the runtime allowlist, retaining
-- any existing queue entries, and reconcile each view with current rows.
DO $$
DECLARE view_name text;
BEGIN
  -- Match refresh_lists() so ordinary writes cannot race this reconciliation.
  PERFORM pg_advisory_xact_lock(71040);
  FOREACH view_name IN ARRAY ARRAY[
    'mv_customer_stock_summary','mv_grn_daily_summary','mv_dispatch_daily_summary',
    'mv_grn_list','mv_dispatch_list','mv_orders_list','mv_invoice_list'
  ] LOOP
    INSERT INTO public.mv_refresh_queue(mv_name) VALUES (view_name)
      ON CONFLICT (mv_name) DO NOTHING;
    EXECUTE format('REFRESH MATERIALIZED VIEW public.%I', view_name);
    UPDATE public.mv_refresh_queue SET needs_refresh=false,last_refresh=now()
      WHERE mv_name=view_name;
  END LOOP;
END $$;

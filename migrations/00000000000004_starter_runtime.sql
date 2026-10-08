-- Custom sessions do not depend on GoTrue's uninstalled session tables.
-- PostgREST 12 supplies a single JSON claims setting, not legacy per-claim GUCs.
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT NULLIF(auth.jwt()->>'sub','')::uuid;
$$;
CREATE OR REPLACE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$
  SELECT auth.jwt()->>'role';
$$;
CREATE FUNCTION public.check_session() RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog AS $$
BEGIN
  IF auth.jwt()->>'role' = 'authenticated' AND NOT EXISTS (
    SELECT 1 FROM warehouse_security.refresh_sessions s JOIN public.user_profiles p ON p.auth_user_id=s.user_id
    WHERE s.id::text=auth.jwt()->>'session_id' AND s.user_id=auth.uid() AND s.expires_at>now() AND p.active
  ) THEN RAISE EXCEPTION 'Session expired or revoked' USING ERRCODE='42501'; END IF;
END $$;
REVOKE EXECUTE ON FUNCTION public.check_session() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_session() TO anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION warehouse_security.active_role() RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog AS $$
  SELECT p.role::text FROM public.user_profiles p WHERE p.auth_user_id=auth.uid() AND p.active AND EXISTS (
    SELECT 1 FROM warehouse_security.refresh_sessions s WHERE s.user_id=p.auth_user_id
      AND s.id::text=auth.jwt()->>'session_id' AND s.expires_at>now()
  );
$$;

CREATE OR REPLACE FUNCTION warehouse_security.owns_customer(customer uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog AS $$
  SELECT warehouse_security.active_role() IS NOT NULL AND (
    warehouse_security.active_role() IN ('admin','supervisor') OR EXISTS (
      SELECT 1 FROM public.users_customers_new a JOIN public.user_profiles p ON p.id=a.user_profile_id
      WHERE a.customer_id=customer AND a.active AND p.active AND p.auth_user_id=auth.uid()
    )
  );
$$;

CREATE OR REPLACE FUNCTION public.delete_user_account() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE profile_id uuid;
BEGIN
  PERFORM warehouse_security.authorize_rpc('delete_user_account','{}'::jsonb);
  SELECT id INTO STRICT profile_id FROM public.user_profiles WHERE auth_user_id=auth.uid() AND active;
  DELETE FROM public.users_customers_new WHERE user_profile_id=profile_id;
  DELETE FROM public.user_session_activity WHERE user_id=profile_id;
  DELETE FROM warehouse_security.refresh_sessions WHERE user_id=auth.uid();
  UPDATE public.user_profiles SET name='Deleted User',display_name='Deleted User',active=false,
    mobile='DEL'||left(replace(profile_id::text,'-',''),12),mobile_verified=false,mobile_verified_at=NULL
    WHERE id=profile_id;
  RETURN jsonb_build_object('success',true,'message','Account deleted');
END $$;

-- pg_dump exports materialized views WITH NO DATA. Populate them before any API call.
DO $$ DECLARE r record; BEGIN
  FOR r IN SELECT matviewname FROM pg_matviews WHERE schemaname='public' ORDER BY matviewname LOOP
    EXECUTE format('REFRESH MATERIALIZED VIEW public.%I',r.matviewname);
  END LOOP;
END $$;

-- Small starter installs refresh synchronously, without copying production cron jobs.
-- Large deployments should replace this with a monitored queue worker.
CREATE FUNCTION warehouse_security.refresh_lists() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE r record;
BEGIN
  PERFORM pg_advisory_xact_lock(71040);
  FOR r IN SELECT mv_name FROM public.mv_refresh_queue WHERE needs_refresh ORDER BY mv_name LOOP
    IF r.mv_name NOT IN ('mv_customer_stock_summary','mv_grn_daily_summary','mv_dispatch_daily_summary',
      'mv_grn_list','mv_dispatch_list','mv_orders_list','mv_invoice_list') THEN
      RAISE EXCEPTION 'Unexpected refresh target';
    END IF;
    EXECUTE format('REFRESH MATERIALIZED VIEW public.%I',r.mv_name);
    UPDATE public.mv_refresh_queue SET needs_refresh=false,last_refresh=now() WHERE mv_name=r.mv_name;
  END LOOP;
  RETURN NULL;
END $$;
REVOKE EXECUTE ON FUNCTION warehouse_security.refresh_lists() FROM PUBLIC,anon,authenticated;
DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['customers','goodsreceived','goodsreceived_trl','dispatch','dispatch_trl'] LOOP
    EXECUTE format('CREATE TRIGGER zz_starter_refresh AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION warehouse_security.refresh_lists()',t);
  END LOOP;
END $$;

-- The RPC already supported a GRN filter; expose only the unambiguous newer signature.
DROP FUNCTION public.get_customer_items_for_order_selection(uuid,integer,integer,text,integer);
NOTIFY pgrst, 'reload schema';

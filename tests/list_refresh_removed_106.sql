-- Migration 106: the list refresh machinery is gone, and what stays still works.
-- Runs after all migrations in migrations.sh's disposable, network-disabled database; it writes nothing.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.lr_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'list refresh removed: %', label; END IF; END $$;

SELECT pg_temp.lr_assert(NOT EXISTS (SELECT 1 FROM pg_matviews), 'a materialized view remains: ' || coalesce((SELECT string_agg(matviewname, ', ') FROM pg_matviews), ''));
SELECT pg_temp.lr_assert(NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') AND to_regnamespace('cron') IS NULL, 'pg_cron or its schema remains');
SELECT pg_temp.lr_assert(to_regrole('warehouse_list_refresher') IS NULL, 'the refresher role remains');
SELECT pg_temp.lr_assert(NOT EXISTS (SELECT 1 FROM pg_event_trigger WHERE evtname = 'issue_pg_cron_access')
  AND to_regprocedure('extensions.grant_pg_cron_access()') IS NULL, 'the pg_cron event trigger remains');
SELECT pg_temp.lr_assert(to_regclass('public.mv_refresh_queue') IS NULL AND to_regclass('public.mv_refresh_status') IS NULL, 'a refresh table remains');
SELECT pg_temp.lr_assert(NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.relname LIKE 'mv\_%' AND c.relnamespace = 'public'::regnamespace), 'a relation named mv_* remains');
SELECT pg_temp.lr_assert((SELECT count(*) = 0 FROM unnest(ARRAY[
  'public.get_dispatch_list(timestamptz,timestamptz,jsonb,text,text,integer,integer)', 'public.get_dispatch_list_original(timestamptz,timestamptz,jsonb,text,text,integer,integer)', 'public.get_all_grn_items(uuid,uuid,boolean,text,integer,integer)',
  'public.get_list_freshness()', 'warehouse_security.list_refresh_status()', 'public.mark_customer_list_mvs_dirty()', 'public.mark_dispatch_mvs_dirty()',
  'public.mark_grn_mvs_dirty()', 'public.mark_invoice_mv_dirty()', 'public.mark_stock_mvs_dirty()', 'warehouse_security.mark_item_list_mvs_dirty()',
  'warehouse_security.mark_lists_dirty(text[])', 'warehouse_security.list_refresh_views()', 'warehouse_security.list_refresh_claim()',
  'warehouse_security.list_refresh_view(text)', 'warehouse_security.list_refresh_done(text,bigint,timestamptz,timestamptz,text)',
  'warehouse_security.list_refresh_prune_history()', 'warehouse_security.refresh_dirty_lists_worker()', 'warehouse_security.refresh_dirty_lists()',
  'warehouse_security.ensure_list_refresher()', 'public.enable_dispatch_triggers()', 'public.refresh_dirty_mvs()', 'public.refresh_stock_views()',
  'public.trigger_refresh_dispatch_list_mv()', 'public.trigger_refresh_stock_views()', 'public.refresh_auth_geographic_anomalies()']) f
  WHERE to_regprocedure(f) IS NOT NULL), 'a dropped function still exists');
SELECT pg_temp.lr_assert(NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid WHERE NOT t.tgisinternal AND p.proname ~ '^mark_.*dirty$'),
  'a trigger still marks lists');
-- What stays: the table-based overload of get_all_grn_items, the Dispatches list, and the Invoices list.
SELECT pg_temp.lr_assert(to_regprocedure('public.get_all_grn_items(timestamptz,timestamptz,jsonb,text,text,integer,integer)') IS NOT NULL
  AND (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'get_all_grn_items') = 1, 'get_all_grn_items keeps its one table-based overload');
SELECT pg_temp.lr_assert(to_regprocedure('public.get_dispatch_list_with_items(uuid,jsonb,text,text,integer,integer,boolean)') IS NOT NULL, 'the Dispatches list function exists');
SELECT pg_temp.lr_assert((SELECT count(*) = 1 AND bool_and(p.prosecdef AND has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE'))
   FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'get_invoices_list'), 'get_invoices_list: one function, SECURITY DEFINER, for signed-in callers only');
SELECT pg_temp.lr_assert(NOT (SELECT prosrc FROM pg_proc WHERE oid = 'public.get_invoices_list(integer,integer,uuid,integer,text,text,text,text,integer,integer,text,timestamptz,timestamptz,uuid[])'::regprocedure) ~* 'mv_',
  'get_invoices_list reads no mv_* relation');
SELECT pg_temp.lr_assert((SELECT bool_and(prosrc !~* 'mv_(invoice|dispatch|grn|customer|orders)_|mv_refresh|refresh_dirty|list_refresh|REFRESH\s+MATERIALIZED')
   FROM pg_proc WHERE pronamespace IN ('public'::regnamespace, 'warehouse_security'::regnamespace)), 'a function still names a dropped list');
-- update_grn keeps the document lock and the guard.
SELECT pg_temp.lr_assert((SELECT bool_and(position('pg_advisory_xact_lock(71040)' IN prosrc) > 0 AND position('authorize_rpc' IN prosrc) > 0)
   FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'update_grn'), 'update_grn keeps lock 71040 and its guard');
-- The allow-list of authorize_rpc: the two dropped names are gone, their neighbours stay.
SELECT pg_temp.lr_assert((SELECT position('''get_dispatch_list''' IN prosrc) = 0 AND position('get_list_freshness' IN prosrc) = 0
     AND position('''get_dispatch_list_with_items''' IN prosrc) > 0 AND position('''get_invoices_list''' IN prosrc) > 0
   FROM pg_proc WHERE oid = 'warehouse_security.authorize_rpc(text,jsonb)'::regprocedure), 'authorize_rpc allow-list');
SELECT pg_temp.lr_assert(EXISTS (SELECT 1 FROM warehouse_migrations.applied WHERE name = '00000000000000_baseline.sql'), 'the baseline (which holds migration 106) is recorded');
ROLLBACK;
SELECT 'list refresh machinery removed, the lists that stay are intact' AS result;

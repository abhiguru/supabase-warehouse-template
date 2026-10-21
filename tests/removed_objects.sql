-- What was removed stays removed, in one place: Realtime, the list refresh machinery, unused extensions (migrations 103 to 108), the Tally and
-- legacy functions (migrations 71 and 74, with the live invoice and payment path that the removal must not break), the pgjwt signer
-- (with a check that the internal signer's token verifies), and the dead objects of migration 123. Absence checks only, except the two
-- behaviour parts: the signer and the live path. Runs after all migrations in migrations.sh's disposable, network-disabled database;
-- every fixture row rolls back.
\set ON_ERROR_STOP on
BEGIN;

-- ===== from realtime_removed_105.sql =====
CREATE FUNCTION pg_temp.rt_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'realtime removed: %', label; END IF; END $$;

SELECT pg_temp.rt_assert(NOT EXISTS (SELECT 1 FROM pg_publication), 'a publication remains: ' || coalesce((SELECT string_agg(pubname, ', ') FROM pg_publication), ''));
SELECT pg_temp.rt_assert((SELECT count(*) = 2 AND bool_and(relreplident = 'd') FROM pg_class
  WHERE oid IN ('public.orders'::regclass, 'public.sensor_latest'::regclass)), 'orders and sensor_latest are REPLICA IDENTITY DEFAULT');
SELECT pg_temp.rt_assert(NOT EXISTS (SELECT 1 FROM pg_class WHERE relreplident = 'f' AND relnamespace = 'public'::regnamespace), 'a public table is still REPLICA IDENTITY FULL');
SELECT pg_temp.rt_assert(to_regnamespace('realtime') IS NULL AND to_regnamespace('_realtime') IS NULL, 'the schema realtime or _realtime remains');
SELECT pg_temp.rt_assert(NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name LIKE 'supabase\_realtime%' OR slot_name LIKE 'realtime%'), 'a Realtime replication slot remains');
SELECT pg_temp.rt_assert(EXISTS (SELECT 1 FROM warehouse_migrations.applied WHERE name = '00000000000000_baseline.sql'), 'the ledger does not hold the baseline');
-- The tables still work for the app: the policies and grants of migrations 14 and 74 are untouched.
SELECT pg_temp.rt_assert(EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'public.sensor_latest'::regclass AND polname = 'starter_staff'), 'the sensor_latest policy remains');

-- ===== from list_refresh_removed_106.sql =====
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

-- ===== from unused_extensions_absent.sql =====
CREATE FUNCTION pg_temp.ue_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'unused extensions: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.ue_outcome(role_name text, statement text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE answer text;
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', role_name);
  BEGIN EXECUTE statement; answer := 'ok';
  EXCEPTION WHEN OTHERS THEN answer := SQLSTATE; END;
  RESET ROLE;
  RETURN answer;
END $$;

SELECT pg_temp.ue_assert(NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname IN ('http', 'pg_net', 'pg_graphql', 'supabase_vault')),
  'an unused extension is installed: ' || coalesce((SELECT string_agg(extname, ', ') FROM pg_extension WHERE extname IN ('http', 'pg_net', 'pg_graphql', 'supabase_vault')), ''));
SELECT pg_temp.ue_assert(NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('http_post', 'http_get', 'http', 'http_put', 'http_delete', 'http_patch', 'http_head')),
  'a public.http_* function is left');
SELECT pg_temp.ue_assert(to_regprocedure('public.http_post(character varying,character varying,character varying)') IS NULL, 'public.http_post exists');
SELECT pg_temp.ue_assert(NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname IN ('net', 'graphql', 'graphql_public', 'vault', 'supabase_functions')),
  'a schema of the removed extensions exists: ' || coalesce((SELECT string_agg(nspname, ', ') FROM pg_namespace WHERE nspname IN ('net', 'graphql', 'graphql_public', 'vault', 'supabase_functions')), ''));
SELECT pg_temp.ue_assert(to_regrole('supabase_functions_admin') IS NULL, 'the role supabase_functions_admin exists');

-- The event triggers: none of the three that react to the removed extensions, and not their functions;
-- PostgREST's schema-cache triggers stay.
SELECT pg_temp.ue_assert(NOT EXISTS (SELECT 1 FROM pg_event_trigger WHERE evtname IN ('issue_graphql_placeholder', 'issue_pg_graphql_access', 'issue_pg_net_access', 'graphql_watch_ddl', 'graphql_watch_drop')),
  'an event trigger of pg_graphql or pg_net is left');
SELECT pg_temp.ue_assert(NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname IN ('set_graphql_placeholder', 'grant_pg_graphql_access', 'grant_pg_net_access')),
  'a function of those event triggers is left');
SELECT pg_temp.ue_assert((SELECT count(*) FROM pg_event_trigger WHERE evtname IN ('pgrst_ddl_watch', 'pgrst_drop_watch')) = 0, 'a PostgREST event trigger is present: the baseline strips them and the bootstrap makes none');

-- anon cannot see a graphql function, and calling one fails because the function or schema is not there (42883 or 3F000).
SELECT pg_temp.ue_assert(NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE p.proname = 'graphql' OR n.nspname LIKE 'graphql%'),
  'a graphql function or schema exists');
SELECT pg_temp.ue_assert(pg_temp.ue_outcome('anon', $q$SELECT graphql_public.graphql(query := '{ __typename }')$q$) IN ('3F000', '42883'), 'anon can reach graphql_public.graphql');
SELECT pg_temp.ue_assert(pg_temp.ue_outcome('anon', $q$SELECT graphql.resolve('{ __typename }')$q$) IN ('3F000', '42883'), 'anon can reach graphql.resolve');
SELECT pg_temp.ue_assert(pg_temp.ue_outcome('service_role', $q$SELECT public.http_post('http://hook.example.test/', '{}', 'application/json')$q$) IN ('3F000', '42883'), 'service_role can call public.http_post');
SELECT pg_temp.ue_assert(pg_temp.ue_outcome('service_role', $q$SELECT net.http_post('http://hook.example.test/')$q$) IN ('3F000', '42883'), 'service_role can reach net.http_post');

-- ===== from jwt_sign_108.sql =====
CREATE FUNCTION pg_temp.js_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'jwt sign 108: %', label; END IF; END $$;

SELECT pg_temp.js_assert(NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgjwt'), 'pgjwt is still installed');
SELECT pg_temp.js_assert(to_regprocedure('extensions.sign(json,text,text)') IS NULL AND to_regprocedure('extensions.verify(text,text,text)') IS NULL,
  'extensions.sign or extensions.verify still exists');
SELECT pg_temp.js_assert(NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.prosrc ~ '(extensions\.)?\m(verify|url_encode|url_decode|algorithm_sign|try_cast_double)\s*\(|extensions\.sign\s*\(' AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')),
  'a function still mentions pgjwt: ' || coalesce((SELECT string_agg(p.oid::regprocedure::text, ', ') FROM pg_proc p WHERE p.prosrc ~ '(extensions\.)?\m(verify|url_encode|url_decode|algorithm_sign|try_cast_double)\s*\(|extensions\.sign\s*\(' AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')), ''));
SELECT pg_temp.js_assert(to_regprocedure('warehouse_security.jwt_sign_hs256(json,text)') IS NOT NULL, 'the signer is missing');
-- no API role may execute the signer
SELECT pg_temp.js_assert(NOT has_function_privilege(r, 'warehouse_security.jwt_sign_hs256(json,text)', 'EXECUTE'), r || ' can execute the signer')
  FROM unnest(ARRAY['anon', 'authenticated', 'service_role']) AS r;
SELECT pg_temp.js_assert((SELECT proacl IS NULL OR NOT EXISTS (SELECT 1 FROM aclexplode(proacl) a WHERE a.grantee = 0)
  FROM pg_proc WHERE oid = 'warehouse_security.jwt_sign_hs256(json,text)'::regprocedure), 'PUBLIC can execute the signer');
-- sign_access_token still has its old shape and is still not callable by API roles
SELECT pg_temp.js_assert((SELECT prosecdef AND proconfig @> ARRAY['search_path=pg_catalog, public, extensions'] FROM pg_proc
  WHERE oid = 'warehouse_security.sign_access_token(uuid,uuid)'::regprocedure), 'sign_access_token lost SECURITY DEFINER or its search_path');
SELECT pg_temp.js_assert(NOT has_function_privilege(r, 'warehouse_security.sign_access_token(uuid,uuid)', 'EXECUTE'), r || ' can execute sign_access_token')
  FROM unnest(ARRAY['anon', 'authenticated', 'service_role']) AS r;
SELECT pg_temp.js_assert((SELECT prosrc FROM pg_proc WHERE oid = 'warehouse_security.sign_access_token(uuid,uuid)'::regprocedure) LIKE '%warehouse_security.jwt_sign_hs256(%'
  AND (SELECT prosrc FROM pg_proc WHERE oid = 'warehouse_security.sign_access_token(uuid,uuid)'::regprocedure) NOT LIKE '%extensions.sign%', 'sign_access_token does not call the new signer');

-- A real session: the token verifies with the secret.
INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode', 'operator'), ('demo_auth_enabled', 'false'), ('refresh_grace_seconds', '60')
 ON CONFLICT (key) DO UPDATE SET value = excluded.value;
SELECT warehouse_security.bootstrap_first_admin('9888888108', 'Signer Administrator') AS user_id \gset
SELECT warehouse_security.issue_session(:'user_id'::uuid) AS issued \gset
SELECT :'issued'::jsonb->>'access_token' AS token \gset
SELECT pg_temp.js_assert(:'token' ~ '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$', 'the access token is not three base64url parts');
SELECT split_part(:'token', '.', 1) AS h, split_part(:'token', '.', 2) AS p, split_part(:'token', '.', 3) AS sig \gset
SELECT pg_temp.js_assert(
  translate(encode(extensions.hmac(convert_to(:'h' || '.' || :'p', 'UTF8'), convert_to('isolated-test-secret-not-for-any-deployment-12345', 'UTF8'), 'sha256'), 'base64'), E'+/=\n', '-_') = :'sig',
  'the signature does not verify with the HS256 secret');
SELECT pg_temp.js_assert(convert_from(decode(translate(:'h', '-_', '+/') || repeat('=', (4 - length(:'h') % 4) % 4), 'base64'), 'UTF8') = '{"alg":"HS256","typ":"JWT"}', 'wrong header');
SELECT pg_temp.js_assert(convert_from(decode(translate(:'p', '-_', '+/') || repeat('=', (4 - length(:'p') % 4) % 4), 'base64'), 'UTF8')::jsonb ->> 'sub' = :'user_id'
  AND convert_from(decode(translate(:'p', '-_', '+/') || repeat('=', (4 - length(:'p') % 4) % 4), 'base64'), 'UTF8')::jsonb ->> 'role' = 'authenticated', 'wrong payload');
-- refresh_jwt_token (which also signs through sign_access_token) still works
SELECT :'issued'::jsonb->>'refresh_token' AS r1 \gset
SET LOCAL ROLE anon;
SELECT public.refresh_jwt_token(:'r1') AS rotated \gset
RESET ROLE;
SELECT pg_temp.js_assert(:'rotated'::jsonb->>'success' = 'true' AND :'rotated'::jsonb->>'access_token' ~ '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$', 'refresh_jwt_token no longer returns a token');

-- ===== from legacy_functions.sql =====
CREATE FUNCTION pg_temp.lf_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'legacy functions: %', label; END IF; END $$;

CREATE TEMP TABLE lf_signatures(signature text PRIMARY KEY) ON COMMIT DROP;
INSERT INTO lf_signatures(signature) VALUES
  ('acknowledge_voucher_drift(uuid,text,text)'),
  ('backfill_matched_receipts(date,integer)'),
  ('begin_tally_sync_attempt(uuid,text,text,text)'),
  ('claim_tally_sync_item(text,text)'),
  ('claim_vouchers_to_verify(text,integer,text)'),
  ('confirm_tally_sync_attempt(uuid,text,text,text)'),
  ('create_contra_voucher(date,numeric,text,text,text)'),
  ('create_manual_receipt(date,numeric,uuid,text,numeric,jsonb)'),
  ('create_manual_receipt(date,numeric,uuid,text,numeric,jsonb,text)'),
  ('delete_contra_voucher(uuid)'),
  ('delete_manual_receipt(uuid)'),
  ('enqueue_contra_voucher(uuid)'),
  ('enqueue_historical_invoices(integer,integer,integer,text)'),
  ('enqueue_historical_invoices(integer,integer,integer,text,boolean)'),
  ('enqueue_historical_receipts(text,integer,integer)'),
  ('enqueue_historical_receipts(text,integer,integer,boolean)'),
  ('enqueue_receipt_voucher(uuid)'),
  ('enqueue_tally_invoice_sync()'),
  ('get_contra_for_edit(uuid)'),
  ('get_invoice_for_tally_sync(uuid)'),
  ('get_receipt_for_edit(uuid)'),
  ('get_receipt_for_tally_sync(uuid)'),
  ('get_tally_ledger_map(uuid,character varying)'),
  ('get_tally_sync_dashboard()'),
  ('get_tally_sync_queue(text,text,integer,integer)'),
  ('guard_bank_reco_company_config_delete()'),
  ('handle_receipt_queue_dead_letter()'),
  ('pause_tally_sync(text,text)'),
  ('record_voucher_verification(uuid,text,text,jsonb,text)'),
  ('release_tally_locks(text)'),
  ('rename_tally_ledger(uuid,character varying,character varying)'),
  ('resume_tally_sync(text)'),
  ('resync_tally_receipt(uuid)'),
  ('retry_failed_receipt(uuid)'),
  ('save_tally_contra_voucher(uuid,text,text,date,text)'),
  ('save_tally_receipt_voucher(uuid,text,text,date,text)'),
  ('save_tally_voucher(uuid,character varying,character varying,character varying,date,character varying,numeric)'),
  ('set_receipt_editing(uuid,boolean)'),
  ('sync_customer_rename_to_ledger_map()'),
  ('update_contra_voucher(uuid,date,numeric,text,text,text)'),
  ('update_manual_receipt(uuid,date,numeric,uuid,text,numeric,jsonb)'),
  ('update_manual_receipt(uuid,date,numeric,uuid,text,numeric,jsonb,text)'),
  ('update_middleware_status(boolean,boolean,boolean,text,timestamp with time zone)'),
  ('update_tally_sync_status(uuid,text,text,timestamp with time zone,text,text,integer,jsonb)'),
  ('upsert_tally_ledger_map(uuid,character varying,character varying,character varying,character varying,boolean)'),
  ('cleanup_expired_idempotency_keys()'),
  ('safe_delete_invoice(uuid,boolean)'),
  ('cancel_order(uuid,text,uuid)'),
  ('check_cart_restoration_history(text,uuid)'),
  ('create_order(jsonb,jsonb,uuid)'),
  ('delete_dispatch_with_stock_restore(uuid)'),
  ('delete_dispatch_with_stock_restore(uuid,integer)'),
  ('get_invoice_details(integer,integer)'),
  ('get_order_queue(integer,integer,text,text,jsonb,boolean,text)'),
  ('get_sensor_health_dashboard()'),
  ('get_unhealthy_sensors()'),
  ('ignore_order(uuid,text)'),
  ('ignore_order(uuid,text,uuid)'),
  ('list_service_credentials()'),
  ('reactivate_order(uuid)'),
  ('reactivate_order(uuid,uuid)'),
  ('record_sensor_health_status(character varying,character varying,character varying,numeric)'),
  ('register_sensor(character varying,text,text,text)'),
  ('search_all_items_autocomplete(text,text,integer,integer,integer,numeric,numeric)'),
  ('auto_generate_invoice_for_dispatch(uuid)'),
  ('retry_auto_invoice_generation(uuid,boolean)'),
  ('get_customers_with_stock(text,timestamp with time zone,integer,integer,integer)'),
  ('generate_time_first_uuid()'),
  ('generate_order_number()'),
  ('get_tally_company()');
CREATE TEMP TABLE lf_tables(table_name text PRIMARY KEY) ON COMMIT DROP;
INSERT INTO lf_tables(table_name) VALUES
  ('tally_receipt_vouchers'), ('bank_statement_lines'), ('bank_statements'), ('tally_contra_vouchers'),
  ('tally_sync_attempts'), ('tally_sync_log'), ('tally_sync_queue'), ('tally_vouchers'), ('tally_ledger_map'),
  ('tally_drift_log'), ('tally_middleware_status'), ('bank_reco_company_config'), ('receipt_voucher_counters'),
  ('contra_voucher_counters');
CREATE TEMP TABLE lf_triggers(trigger_name text PRIMARY KEY) ON COMMIT DROP;
INSERT INTO lf_triggers(trigger_name) VALUES
  ('trg_tally_sync_on_invoice'), ('trg_sync_customer_rename_to_ledger_map'), ('tg_bank_reco_company_config_delete_guard'),
  ('trg_receipt_queue_dead_letter'), ('trigger_tally_sync_queue_updated_at'), ('trigger_tally_ledger_map_updated_at');
SELECT pg_temp.lf_assert((SELECT count(*) FROM lf_signatures) = 70 AND (SELECT count(*) FROM lf_tables) = 14
  AND (SELECT count(*) FROM lf_triggers) = 6, 'the lists hold 70 signatures, 14 tables and 6 triggers');

-- ---------------------------------------------------------------------------
-- 1. Gone
-- ---------------------------------------------------------------------------
SELECT pg_temp.lf_assert(count(*) = 0, count(*) || ' of the 70 retired signatures still exist, e.g. '
    || COALESCE(string_agg(signature, ', ' ORDER BY signature) FILTER (WHERE to_regprocedure('public.' || signature) IS NOT NULL), ''))
FROM lf_signatures WHERE to_regprocedure('public.' || signature) IS NOT NULL;
SELECT pg_temp.lf_assert(count(*) = 0, count(*) || ' of the 14 retired tables still exist: '
    || COALESCE(string_agg(table_name, ', ' ORDER BY table_name), ''))
FROM lf_tables WHERE to_regclass('public.' || table_name) IS NOT NULL;
SELECT pg_temp.lf_assert(count(*) = 0, 'retired triggers still exist: ' || COALESCE(string_agg(t.tgname || ' on ' || t.tgrelid::regclass::text, ', '), ''))
FROM pg_trigger t JOIN lf_triggers r ON r.trigger_name = t.tgname;
SELECT pg_temp.lf_assert(count(*) = 0, 'a user trigger on invoice or customers is a Tally one: ' || COALESCE(string_agg(t.tgname, ', '), ''))
FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
WHERE t.tgrelid IN ('public.invoice'::regclass, 'public.customers'::regclass) AND NOT t.tgisinternal
  AND (t.tgname ~* 'tally|ledger_map' OR p.proname ~* 'tally|ledger_map');
-- No other function by any of the retired names is left behind in public either.
SELECT pg_temp.lf_assert(count(*) = 0, 'a function by a retired name is still in public: ' || COALESCE(string_agg(p.oid::regprocedure::text, ', '), ''))
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
  AND p.proname IN (SELECT split_part(signature, '(', 1) FROM lf_signatures);

-- ---------------------------------------------------------------------------
-- 2. Nothing kept names a retired object
-- ---------------------------------------------------------------------------
SELECT pg_temp.lf_assert(count(*) = 0, 'functions still name a Tally, bank, receipt voucher or contra voucher object: '
    || COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), ''))
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname IN ('public', 'utils', 'warehouse_security', 'warehouse_maintenance')
  AND p.prosrc ~ 'tally_|bank_statement|bank_reco|receipt_voucher|contra_voucher';
SELECT pg_temp.lf_assert(count(*) = 0, 'a policy names a retired table: ' || COALESCE(string_agg(polname, ', '), ''))
FROM pg_policy
WHERE COALESCE(pg_get_expr(polqual, polrelid), '') || ' ' || COALESCE(pg_get_expr(polwithcheck, polrelid), '')
  ~ 'tally_|bank_statement|bank_reco|receipt_voucher|contra_voucher';

-- ---------------------------------------------------------------------------
-- 3. Kept
-- ---------------------------------------------------------------------------
SELECT pg_temp.lf_assert(to_regclass('public.payments') IS NOT NULL, 'payments is kept');
-- The baseline's role_based_payments_access was replaced by migration 3; these two are its policies since.
SELECT pg_temp.lf_assert(string_agg(polname, ',' ORDER BY polname) = 'starter_customer,starter_staff',
  'the payments policies starter_customer and starter_staff are kept: ' || COALESCE(string_agg(polname, ',' ORDER BY polname), 'none'))
FROM pg_policy WHERE polrelid = 'public.payments'::regclass;
SELECT pg_temp.lf_assert(to_regprocedure('public.update_updated_at_column()') IS NOT NULL
  AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgfoid = 'public.update_updated_at_column()'::regprocedure),
  'update_updated_at_column() is kept and still serves other tables');
SELECT pg_temp.lf_assert(to_regprocedure('public.get_open_invoices_for_customer(uuid,date)') IS NOT NULL, 'get_open_invoices_for_customer(uuid,date) is kept');
SELECT pg_temp.lf_assert(has_function_privilege('service_role', 'public.get_open_invoices_for_customer(uuid,date)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.get_open_invoices_for_customer(uuid,date)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.get_open_invoices_for_customer(uuid,date)', 'EXECUTE'),
  'get_open_invoices_for_customer stays the service role''s only');

-- ---------------------------------------------------------------------------
-- 4. The live path, written by the database owner
-- ---------------------------------------------------------------------------
INSERT INTO public.customers(name, mobile) VALUES ('Legacy Retire Juniper Cold', '9888887101') RETURNING id AS juniper \gset
INSERT INTO public.invoice(inv_fin_year, inv_no, gr_id, gr_no, customer_id, customer_name, inv_date, labour, tax_amount, total, discount)
VALUES (2026, 71001, gen_random_uuid(), 'LRG71', :'juniper'::uuid, 'Legacy Retire Juniper Cold', '2026-09-20T12:00:00Z', 0, 0, 12, 0)
RETURNING id AS invoice_id \gset
UPDATE public.invoice SET total = 14 WHERE id = :'invoice_id'::uuid;
UPDATE public.customers SET name = 'Legacy Retire Juniper Cold Stores' WHERE id = :'juniper'::uuid;
SELECT pg_temp.lf_assert((SELECT total FROM public.invoice WHERE id = :'invoice_id'::uuid) = 14
  AND (SELECT name FROM public.customers WHERE id = :'juniper'::uuid) = 'Legacy Retire Juniper Cold Stores',
  'the invoice total and the customer name changed');
INSERT INTO public.payments(payment_no, payment_date, customer_id, customer_name, amount, payment_mode, online_ref, invoice_id)
VALUES ('LRP-1', '2026-09-22T12:00:00Z', :'juniper'::uuid, 'Legacy Retire Juniper Cold Stores', 4, 'ONLINE', 'UTR-71', :'invoice_id'::uuid);

SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);
SET LOCAL ROLE service_role;
SELECT public.get_open_invoices_for_customer(:'juniper'::uuid) AS open_invoices \gset
RESET ROLE;
SELECT pg_temp.lf_assert((:'open_invoices'::jsonb)->>'success' = 'true'
  AND jsonb_array_length((:'open_invoices'::jsonb)->'data') = 1
  AND ((:'open_invoices'::jsonb)#>>'{data,0,total}')::numeric = 14
  AND ((:'open_invoices'::jsonb)#>>'{data,0,paid}')::numeric = 4
  AND ((:'open_invoices'::jsonb)#>>'{data,0,outstanding}')::numeric = 10,
  'one open invoice, 14 total, 4 paid, 10 outstanding: ' || :'open_invoices');

-- ---------------------------------------------------------------------------
-- 5. Migration 74: the MAC-based sensor writers
-- ---------------------------------------------------------------------------
SELECT pg_temp.lf_assert(to_regprocedure('public.record_sensor_reading(character varying,numeric,numeric,character varying,character varying)') IS NULL
  AND to_regprocedure('public.update_sensor(character varying,text,text,integer,jsonb)') IS NULL,
  'record_sensor_reading and update_sensor are gone');
SELECT pg_temp.lf_assert(count(*) = 0, 'a function by a retired sensor writer''s name is still in public: ' || COALESCE(string_agg(p.oid::regprocedure::text, ', '), ''))
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('record_sensor_reading', 'update_sensor');
SELECT pg_temp.lf_assert(to_regprocedure('public.record_sensor_batch(text,jsonb,jsonb)') IS NOT NULL
  AND to_regprocedure('public.update_sensor_device(uuid,text,text,integer,numeric,numeric,boolean)') IS NOT NULL,
  'record_sensor_batch and update_sensor_device replace them');

-- ---------------------------------------------------------------------------
-- Migration 123: the dead functions, tables, views, columns, indexes, the OTP cleanup trigger and uuid-ossp
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.ro_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'removed objects (123): %', label; END IF; END $$;
SELECT pg_temp.ro_assert(count(*) = 0, count(*) || ' dropped functions still exist: ' || string_agg(f, ', ' ORDER BY f))
FROM unnest(ARRAY[
  'auth.email()', 'auth.role()',
  'public.auto_cleanup_expired_otps()', 'public.cancel_invoice(uuid)',
  'public.cancel_invoice(uuid,text)', 'public.check_invoice_exists(integer,integer)',
  'public.check_ip_rate_limit(inet)', 'public.check_otp_rate_limit(character varying)',
  'public.check_session_validity()', 'public.check_stock_availability(uuid)',
  'public.cleanup_expired_otps()', 'public.cleanup_intrusion_events()',
  'public.cleanup_old_audit_logs()', 'public.cleanup_orphaned_grn_images(integer)',
  'public.constant_time_compare(text,text)', 'public.create_first_admin(character varying,character varying,character varying)',
  'public.create_item_storage_price(uuid,text,numeric,numeric,numeric,numeric,date,uuid,numeric,date)', 'public.deactivate_sensor(character varying,text)',
  'public.debug_auth_context()', 'public.debug_current_user_grn_access()',
  'public.debug_jwt_claims()', 'public.debug_otp_verification(character varying,character varying)',
  'public.debug_search_customer_items_for_order(text,uuid,text,integer,integer,integer,uuid,numeric,numeric)', 'public.debug_user_access(character varying)',
  'public.delete_item_storage_price(uuid)', 'public.delete_resolved_auto_invoice_errors(uuid[])',
  'public.ensure_default_pricing_for_all_items(numeric,numeric,numeric)', 'public.find_or_create_item_storage_price(uuid,uuid,numeric,text,numeric,numeric,numeric,numeric,numeric)',
  'public.find_storage_price_table(uuid,integer,date,uuid)', 'public.fix_orphaned_invoice_flags()',
  'public.generate_secure_otp()', 'public.generate_sequential_uuid()',
  'public.get_active_sessions(uuid)', 'public.get_auto_invoice_error_stats(date,date)',
  'public.get_cart_dispatches(uuid)', 'public.get_current_user_profile()',
  'public.get_customer_invoices(uuid,timestamp with time zone,timestamp with time zone,jsonb)', 'public.get_customer_stock_analysis(uuid,timestamp with time zone,jsonb)',
  'public.get_customer_stock_analysis(uuid,timestamp with time zone,jsonb,boolean)', 'public.get_customer_stock_movements(uuid,timestamp with time zone,timestamp with time zone)',
  'public.get_customer_with_priority_contact(uuid)', 'public.get_dispatch_cart_linkage_summary(uuid)',
  'public.get_financial_year_dates(integer)', 'public.get_grn_by_number(text,integer)',
  'public.get_grn_invoices(uuid)', 'public.get_grn_items(uuid)',
  'public.get_grn_items_by_id(uuid)', 'public.get_grn_summary(text,integer)',
  'public.get_invoice_form_data(uuid,text)', 'public.get_invoiceable_grns(integer,integer)',
  'public.get_item_dispatch_records(uuid,jsonb,text,text,integer,integer,boolean)', 'public.get_item_grn_rates(uuid)',
  'public.get_item_grn_records(uuid,jsonb,text,text,integer,integer)', 'public.get_item_pricing_config(uuid,uuid)',
  'public.get_item_stock_analysis(timestamp with time zone,jsonb,jsonb)', 'public.get_jwt_secret()',
  'public.get_next_invoice_number_with_year()', 'public.get_order_item_change_summary(uuid)',
  'public.get_order_list(jsonb,text,text,integer,integer)', 'public.get_order_stats(uuid)',
  'public.get_otp_stats(character varying)', 'public.get_recent_auto_invoice_errors(integer,boolean)',
  'public.get_sensor_devices(boolean)', 'public.get_sensor_latest()',
  'public.get_sensor_readings(uuid,timestamp with time zone,timestamp with time zone,integer,integer)', 'public.get_sensor_statistics(uuid,character varying)',
  'public.get_service_credentials(character varying)', 'public.get_unresolved_auto_invoice_error_count()',
  'public.get_user_profile_id(uuid)', 'public.has_role(user_role)',
  'public.is_admin()', 'public.is_admin_or_supervisor_v2()',
  'public.is_admin_supervisor_or_staff()', 'public.is_dispatch_item_invoiced(uuid)',
  'public.is_supervisor_bypass()', 'public.link_supabase_auth_user(character varying,uuid)',
  'public.log_authentication_attempt(text,uuid,boolean,text,text,jsonb)', 'public.log_auto_invoice_error(uuid,text,uuid,text,timestamp with time zone,text,text,jsonb)',
  'public.monitor_print_jobs()', 'public.recalculate_invoice_items(uuid,text)',
  'public.refresh_auth_token(text)', 'public.resolve_auto_invoice_error(uuid,text)',
  'public.resolve_auto_invoice_errors_by_grn(uuid,uuid)', 'public.restore_cart_quantities_from_dispatch(uuid)',
  'public.restore_dispatch(uuid)', 'public.restore_grn(uuid)',
  'public.restore_invoice(uuid)', 'public.safe_delete_dispatch(uuid,boolean)',
  'public.safe_delete_grn(uuid,boolean)', 'public.save_invoice(jsonb)',
  'public.search_grns(text,integer)', 'public.send_otp(character varying,character varying,text,inet,text)',
  'public.send_otp_simple(character varying,character varying)', 'public.send_otp_with_config(character varying,character varying,text,inet)',
  'public.send_otp_with_hash(character varying,character varying,text,inet)', 'public.set_msg91_mode(boolean)',
  'public.set_sms_mode(boolean)', 'public.submit_contact_form(text,text,text,text)',
  'public.update_customer_contact_with_priority(uuid)', 'public.update_grn_out_of_stock_status(uuid)',
  'public.update_item_storage_price(uuid,numeric,numeric,numeric,numeric,numeric,date,date)', 'public.update_item_storage_price(uuid,numeric,numeric,numeric,numeric,numeric,numeric,date,date)',
  'public.update_order(uuid,jsonb,jsonb,uuid)', 'public.update_order_items_batch(uuid,jsonb)',
  'public.update_order_metadata(uuid,text,text,timestamp without time zone)', 'public.update_service_credentials(character varying,jsonb)',
  'public.validate_date_range(timestamp with time zone,text,timestamp with time zone,timestamp with time zone,boolean)', 'public.validate_invoice_data_structure(jsonb)',
  'public.validate_price_configuration(uuid,integer,integer,date,uuid,date)', 'public.validate_string_length(text,text,integer,integer,boolean)',
  'public.verify_captcha(text)', 'public.verify_otp_or_register(character varying,character varying,character varying,character varying)',
  'warehouse_security.image_file_unreferenced(text,text)']) AS f
WHERE to_regprocedure(f) IS NOT NULL;
-- By name too, for the families that kept one overload: save_invoice (three arguments), get_invoiceable_grns (three), create_item_storage_price (none).
SELECT pg_temp.ro_assert(NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace
    AND proname IN ('create_item_storage_price', 'update_item_storage_price', 'delete_item_storage_price', 'find_or_create_item_storage_price', 'get_item_grn_rates'))
  AND (SELECT count(*) = 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'save_invoice')
  AND (SELECT count(*) = 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'get_invoiceable_grns'),
  'the item price helpers are gone and save_invoice and get_invoiceable_grns have one overload each');
-- What stays: the functions the other callers use.
SELECT pg_temp.ro_assert(to_regprocedure('public.create_dispatch_with_stock_check(jsonb,jsonb[],integer,text)') IS NOT NULL
  AND to_regprocedure('public.create_dispatch_with_stock_check_internal_3param(jsonb,jsonb[],integer,text)') IS NOT NULL
  AND to_regprocedure('public.upload_grn_image(uuid,character varying,text,text,integer,character varying,uuid,uuid)') IS NOT NULL
  AND to_regprocedure('warehouse_security.reset_otp_limits(text)') IS NOT NULL AND to_regprocedure('public.set_service_account(uuid,boolean)') IS NOT NULL AND to_regprocedure('public.clear_user_central_identity(uuid)') IS NOT NULL AND to_regprocedure('warehouse_maintenance.misplaced_image_paths()') IS NOT NULL,
  'fas-sync''s dispatch call, the image uploads and the operator functions are kept');
SELECT pg_temp.ro_assert(count(*) = 0, 'dropped relations still exist: ' || string_agg(r, ', ' ORDER BY r))
FROM unnest(ARRAY[
  'auth_logs', 'config_access_logs', 'intrusion_events', 'intrusion_metrics',
  'contact_submissions', 'captcha_config', 'jwt_config', 'order_number_counter',
  'secrets_vault', 'test_otp_records', 'user_session_activity', 'sensor_health_events',
  'auto_invoice_errors', 'v_jwt_secret', 'v_access_token_expiry', 'v_refresh_token_expiry',
  'foreign_key_status', 'high_cpu_analysis', 'low_stock_alerts', 'rls_policies_summary',
  'security_metrics', 'sensor_health_dashboard', 'stock_summary', 'user_customer_assignments']) AS r
WHERE to_regclass('public.' || r) IS NOT NULL;
SELECT pg_temp.ro_assert(count(*) = 0, 'dropped columns still exist: ' || string_agg(c, ', ' ORDER BY c))
FROM unnest(ARRAY[
  'api_configurations.custom_config', 'api_configurations.google_maps_key', 'api_configurations.mapbox_token',
  'api_configurations.sentry_dsn', 'sms_config.account_sid', 'sms_config.auth_token',
  'sms_config.from_phone', 'payments.bank', 'feature_flags.rollout_percentage',
  'otp_verifications.msg91_response', 'otp_verifications.otp_hash', 'sensor_devices.last_alert_at']) AS c
WHERE EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = to_regclass('public.' || split_part(c, '.', 1)) AND a.attname = split_part(c, '.', 2) AND NOT a.attisdropped);
SELECT pg_temp.ro_assert(count(*) = 0, 'dropped indexes still exist: ' || string_agg(i, ', ' ORDER BY i))
FROM unnest(ARRAY[
  'idx_idempotency_key_lookup', 'idx_api_config_env', 'idx_printer_status_name',
  'idx_dispatch_trl_disp_id', 'idx_goodsreceived_trl_gr_id', 'idx_grn_images_grn_id',
  'grn_rates_gr_id_idx', 'idx_invoice_inv_fin_year', 'idx_invoice_customer_id',
  'idx_invoice_trl_invoice_id', 'idx_invoice_trl_disp_trl_id', 'idx_order_items_order_id',
  'idx_users_customers_user_profile']) AS i
WHERE to_regclass('public.' || i) IS NOT NULL;
SELECT pg_temp.ro_assert(NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trigger_auto_cleanup_otps')
  AND (SELECT count(*) = 1 FROM warehouse_maintenance.retention_policy WHERE key = 'ephemeral_auth' AND days = 7)
  AND NOT EXISTS (SELECT 1 FROM warehouse_maintenance.retention_policy WHERE key IN ('session_activity', 'security_logs')),
  'the OTP cleanup trigger is gone and the 7-day ephemeral_auth rule is the only OTP retention rule');
SELECT pg_temp.ro_assert(NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'uuid-ossp')
  AND NOT EXISTS (SELECT 1 FROM pg_attrdef d WHERE pg_get_expr(d.adbin, d.adrelid) ~ 'uuid_generate'),
  'uuid-ossp is gone and no column default uses it');
SELECT pg_temp.ro_assert((SELECT bool_and(pg_get_expr(d.adbin, d.adrelid) = 'uuidv7()') FROM pg_attrdef d JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
    WHERE d.adrelid IN ('public.dispatch_trl'::regclass, 'public.goodsreceived_trl'::regclass, 'public.invoice_trl'::regclass) AND a.attname = 'id'),
  'the line tables that are ordered by uuid_extract_timestamp(id) get time-ordered ids');
SELECT pg_temp.ro_assert(pg_get_expr(d.adbin, d.adrelid) = 'gen_random_uuid()', 'orders.id is random: the order number is cut from the first 8 characters of it')
FROM pg_attrdef d WHERE d.adrelid = 'public.orders'::regclass AND d.adnum = (SELECT attnum FROM pg_attribute WHERE attrelid = 'public.orders'::regclass AND attname = 'id');
-- The live functions that lost a dead branch still answer the old keys.
SELECT pg_temp.ro_assert(pg_get_functiondef('public.delete_grn_safe(uuid)'::regprocedure) ~ '''auto_invoice_errors'', 0'
  AND pg_get_functiondef('public.save_invoice_internal(uuid,jsonb,jsonb[])'::regprocedure) ~ 'resolved_errors_count'
  AND pg_get_functiondef('public.generate_invoice_data_for_grn(uuid,text)'::regprocedure) !~ 'user_customers', 'delete_grn_safe keeps auto_invoice_errors (0); no function reads user_customers');
SELECT pg_temp.ro_assert((SELECT count(*) = 0 FROM pg_proc p WHERE p.pronamespace IN ('public'::regnamespace, 'warehouse_security'::regnamespace, 'warehouse_maintenance'::regnamespace)
    AND p.prosrc ~ '\m(user_session_activity|auth_logs|config_access_logs|intrusion_events|user_customers|secrets_vault|jwt_config)\M'),
  'no function body names a dropped table');
-- The trigger of S3 stays: it is not redundant (tests/dispatch_delete_trigger.sql).
SELECT pg_temp.ro_assert(EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_restore_stock_on_dispatch_delete'), 'trg_restore_stock_on_dispatch_delete is still there');
ROLLBACK;
SELECT 'removed objects stay removed; the signer and the live invoice and payment path work' AS result;

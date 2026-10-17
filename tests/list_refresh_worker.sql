-- Migration 91 (TW-BE-016, TW-BE-023): a write only marks the lists it changes; the worker
-- refreshes them after the commit. In one transaction, rolled back, so the worker's refresh runs
-- here as warehouse_security.refresh_dirty_lists() (the same claim, refresh and record steps, no
-- commits). The committed cases (CALL of the worker, the lost-refresh race, five parallel
-- dispatches, the pg_cron runner) are in tests/list_refresh_worker.sh.
-- Only in migrations.sh's disposable, network-disabled database; fictional data.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.lr_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'list refresh worker: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.lr_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  login := public.operator_verify_otp(phone,challenge#>>'{data,otp_code}');
  PERFORM pg_temp.lr_assert(login#>>'{data,action}'='login','login '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id=p.auth_user_id
    WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- Rows in which a list differs from its defining query, both ways. now() columns are left out.
CREATE FUNCTION pg_temp.lr_view_diff(view_name text) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE def text; cols text; n bigint;
BEGIN
  def := rtrim(btrim(pg_get_viewdef(('public.'||view_name)::regclass)), ';');
  SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY a.attnum) INTO cols FROM pg_attribute a
   WHERE a.attrelid = ('public.'||view_name)::regclass AND a.attnum > 0 AND NOT a.attisdropped AND a.attname <> 'last_refreshed';
  EXECUTE format('SELECT (SELECT count(*) FROM (SELECT %1$s FROM public.%2$I EXCEPT ALL SELECT %1$s FROM (%3$s) d) a)
    + (SELECT count(*) FROM (SELECT %1$s FROM (%3$s) d EXCEPT ALL SELECT %1$s FROM public.%2$I) b)', cols, view_name, def) INTO n;
  RETURN n;
END $$;
CREATE FUNCTION pg_temp.lr_seqs() RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_object_agg(mv_name, mark_seq) FROM public.mv_refresh_queue $$;
-- The lists whose mark counter moved since `before`.
CREATE FUNCTION pg_temp.lr_marked(before jsonb) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(mv_name::text ORDER BY mv_name), '{}') FROM public.mv_refresh_queue
   WHERE mark_seq > COALESCE((before->>mv_name)::bigint, 0) $$;

-- ---------------------------------------------------------------------------
-- 1. Nothing on the write path refreshes a list
-- ---------------------------------------------------------------------------
SELECT pg_temp.lr_assert(NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'zz_starter_refresh'), 'no zz_starter_refresh trigger remains');
SELECT pg_temp.lr_assert(NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
    WHERE NOT t.tgisinternal AND p.prosrc ~* 'REFRESH\s+MATERIALIZED'), 'no trigger function refreshes a materialized view');
SELECT pg_temp.lr_assert(to_regprocedure('warehouse_security.refresh_lists()') IS NULL
  AND to_regprocedure('public.trigger_refresh_grn_list_mv()') IS NULL
  AND to_regprocedure('public.trigger_refresh_invoice_list_mv()') IS NULL, 'the synchronous refresh trigger functions are gone');
SELECT pg_temp.lr_assert((SELECT count(*) = 3 FROM pg_trigger WHERE NOT tgisinternal AND tgenabled = 'O'
    AND ((tgrelid = 'public.items'::regclass AND tgname = 'trg_mark_item_list_mvs_dirty')
      OR (tgrelid IN ('public.invoice'::regclass, 'public.invoice_trl'::regclass) AND tgname = 'trg_mark_invoice_mv_dirty'))),
  'items, invoice and invoice_trl carry mark-only triggers');
SELECT pg_temp.lr_assert(position('refresh_dirty_lists' IN pg_get_functiondef(p.oid)) = 0
    AND position('mark_lists_dirty(warehouse_security.list_refresh_views())' IN pg_get_functiondef(p.oid)) > 0,
  'update_grn marks the seven lists and refreshes none')
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'update_grn';
-- Migration 87 (87:504-506): create_dispatch takes 71040 exactly once, before the idempotency lookup.
SELECT pg_temp.lr_assert((length(d) - length(replace(d, 'pg_advisory_xact_lock(71040)', ''))) / length('pg_advisory_xact_lock(71040)') = 1
    AND position('pg_advisory_xact_lock(71040)' IN d) < position('Check idempotency key first' IN d),
  'create_dispatch still takes the document lock once, before the idempotency lookup')
FROM (SELECT pg_get_functiondef('public.create_dispatch_with_stock_check_internal(jsonb,jsonb[],boolean,text)'::regprocedure) d) x;

-- ---------------------------------------------------------------------------
-- 2. The worker, its helpers and its runner
-- ---------------------------------------------------------------------------
SELECT pg_temp.lr_assert(p.prokind = 'p' AND NOT p.prosecdef AND p.proconfig IS NULL
    AND p.prosrc LIKE '%pg_try_advisory_lock(71046)%' AND p.prosrc NOT LIKE '%71040%',
  'the worker is a procedure that can commit (invoker, no SET clause), takes 71046 and never 71040')
FROM pg_proc p WHERE p.oid = 'warehouse_security.refresh_dirty_lists_worker()'::regprocedure;
SELECT pg_temp.lr_assert(NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.prosrc LIKE '%71046%'
    AND p.oid <> 'warehouse_security.refresh_dirty_lists_worker()'::regprocedure), 'no other function uses lock 71046');
SELECT pg_temp.lr_assert(bool_and(p.prosecdef AND p.proconfig @> ARRAY['search_path=pg_catalog, public'] AND p.prosrc NOT LIKE '%71040%'),
  'the worker helpers are SECURITY DEFINER with a fixed search_path and never take 71040')
FROM pg_proc p WHERE p.oid IN ('warehouse_security.list_refresh_claim()'::regprocedure, 'warehouse_security.list_refresh_view(text)'::regprocedure,
  'warehouse_security.list_refresh_done(text,bigint,timestamptz,timestamptz,text)'::regprocedure,
  'warehouse_security.list_refresh_prune_history()'::regprocedure, 'warehouse_security.refresh_dirty_lists()'::regprocedure,
  'warehouse_security.mark_lists_dirty(text[])'::regprocedure);
-- Who may run what: the runner the worker and its four helpers; no app role any of it.
SELECT pg_temp.lr_assert(bool_and(NOT has_function_privilege(r.role, f.fn, 'EXECUTE')),
  'no app role may run the worker, its helpers, the mark, the status or the in-transaction refresh')
FROM unnest(ARRAY['anon','authenticated','service_role']) r(role),
  unnest(ARRAY['warehouse_security.refresh_dirty_lists_worker()','warehouse_security.list_refresh_claim()',
    'warehouse_security.list_refresh_view(text)','warehouse_security.list_refresh_done(text,bigint,timestamptz,timestamptz,text)',
    'warehouse_security.list_refresh_prune_history()','warehouse_security.mark_lists_dirty(text[])',
    'warehouse_security.ensure_list_refresher()','warehouse_security.list_refresh_status()',
    'warehouse_security.refresh_dirty_lists()','warehouse_security.list_refresh_views()']::regprocedure[]) f(fn);
SELECT pg_temp.lr_assert(array_agg(p.oid::regprocedure::text ORDER BY p.oid::regprocedure::text) = ARRAY[
    'warehouse_security.list_refresh_claim()','warehouse_security.list_refresh_done(text,bigint,timestamp with time zone,timestamp with time zone,text)',
    'warehouse_security.list_refresh_prune_history()','warehouse_security.list_refresh_view(text)',
    'warehouse_security.refresh_dirty_lists_worker()'],
  'the runner may execute exactly the worker and its four helpers in warehouse_security: '
    || array_agg(p.oid::regprocedure::text ORDER BY p.oid::regprocedure::text)::text)
FROM pg_proc p WHERE p.pronamespace IN ('warehouse_security'::regnamespace, 'public'::regnamespace)
  AND has_function_privilege('warehouse_list_refresher', p.oid, 'EXECUTE');
SELECT pg_temp.lr_assert(a.rolcanlogin AND a.rolpassword IS NULL AND NOT a.rolsuper AND NOT a.rolinherit AND NOT a.rolcreaterole
    AND NOT a.rolcreatedb AND NOT a.rolreplication AND NOT a.rolbypassrls AND a.rolconnlimit = 3
    AND NOT EXISTS (SELECT 1 FROM pg_auth_members m WHERE m.member = a.oid)
    AND NOT has_table_privilege('warehouse_list_refresher', 'public.goodsreceived', 'SELECT')
    AND NOT has_table_privilege('warehouse_list_refresher', 'public.mv_refresh_queue', 'SELECT')
    AND NOT has_schema_privilege('warehouse_list_refresher', 'cron', 'USAGE'),
  'the runner signs in without a password (no network login), holds no role and reads no table')
FROM pg_authid a WHERE a.rolname = 'warehouse_list_refresher';
SELECT pg_temp.lr_assert((SELECT setconfig @> ARRAY['statement_timeout=120s','search_path=pg_catalog'] FROM pg_db_role_setting
    WHERE setrole = 'warehouse_list_refresher'::regrole AND setdatabase = 0), 'the runner has its own statement timeout and search path');
SELECT pg_temp.lr_assert((SELECT count(*) = 1 AND bool_and(schedule = '5 seconds' AND command = 'CALL warehouse_security.refresh_dirty_lists_worker()'
    AND username = 'warehouse_list_refresher' AND database = current_database() AND active) FROM cron.job WHERE jobname = 'warehouse-list-refresh')
  AND (SELECT count(*) = 1 AND bool_and(command = 'SELECT warehouse_security.list_refresh_prune_history()' AND username = 'warehouse_list_refresher' AND active)
    FROM cron.job WHERE jobname = 'warehouse-list-refresh-history'),
  'pg_cron runs the worker every 5 seconds and prunes its history, both as the runner');
-- ensure_list_refresher (scripts/configure-list-refresh.sql) puts back a paused job and a role that lost LOGIN.
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'warehouse-list-refresh'), active := false);
ALTER ROLE warehouse_list_refresher NOLOGIN;
SELECT pg_temp.lr_assert(NOT (warehouse_security.list_refresh_status()->>'ok')::boolean
    AND warehouse_security.list_refresh_status()->>'problems' LIKE '%paused%' AND warehouse_security.list_refresh_status()->>'problems' LIKE '%cannot log in%',
  'the status names a paused job and a runner that cannot log in: ' || (warehouse_security.list_refresh_status()->>'problems'));
SELECT warehouse_security.ensure_list_refresher();
SELECT pg_temp.lr_assert((SELECT active FROM cron.job WHERE jobname = 'warehouse-list-refresh')
    AND (SELECT rolcanlogin FROM pg_roles WHERE rolname = 'warehouse_list_refresher')
    AND (SELECT count(*) = 2 FROM cron.job WHERE jobname LIKE 'warehouse-list-refresh%'), 'ensure_list_refresher restores both');

-- ---------------------------------------------------------------------------
-- 3. Every table marks every list that reads it; the mark is unconditional
-- ---------------------------------------------------------------------------
-- A statement trigger fires for an UPDATE of no row, so each table is probed alone.
DO $$
DECLARE t text; col text; before jsonb; marked text[]; needed text[];
BEGIN
  FOREACH t IN ARRAY ARRAY['customers','goodsreceived','goodsreceived_trl','dispatch','dispatch_trl','items','invoice','invoice_trl'] LOOP
    SELECT quote_ident(attname) INTO STRICT col FROM pg_attribute WHERE attrelid = ('public.'||t)::regclass AND attnum = 1;
    before := pg_temp.lr_seqs();
    EXECUTE format('UPDATE public.%I SET %s = %s WHERE false', t, col, col);
    marked := pg_temp.lr_marked(before);
    SELECT array_agg(DISTINCT m.relname::text ORDER BY m.relname::text) INTO needed
      FROM pg_class m JOIN pg_rewrite r ON r.ev_class = m.oid JOIN pg_depend d ON d.objid = r.oid AND d.classid = 'pg_rewrite'::regclass
     WHERE m.relkind = 'm' AND m.relname = ANY (warehouse_security.list_refresh_views()) AND d.refobjid = ('public.'||t)::regclass;
    PERFORM pg_temp.lr_assert(marked @> needed, format('a change of %s alone marks every list that reads it: needs %s, marked %s', t, needed, marked));
  END LOOP;
END $$;
-- TW-BE-023, named: line tables alone reach the daily summaries.
SELECT pg_temp.lr_seqs() AS seqs \gset
UPDATE public.dispatch_trl SET id = id WHERE false;
SELECT pg_temp.lr_assert('mv_dispatch_daily_summary' = ANY (pg_temp.lr_marked(:'seqs')), 'TW-BE-023: an UPDATE of dispatch_trl alone marks mv_dispatch_daily_summary');
SELECT pg_temp.lr_seqs() AS seqs \gset
UPDATE public.goodsreceived_trl SET id = id WHERE false;
SELECT pg_temp.lr_assert('mv_grn_daily_summary' = ANY (pg_temp.lr_marked(:'seqs')), 'TW-BE-023: an UPDATE of goodsreceived_trl alone marks mv_grn_daily_summary');
-- A list that is already dirty is marked again (its counter moves) and keeps the start of its dirty period.
SELECT last_marked_dirty AS dirty_since, mark_seq AS seq FROM public.mv_refresh_queue WHERE mv_name = 'mv_dispatch_list' \gset
SELECT pg_temp.lr_assert(needs_refresh, 'mv_dispatch_list is dirty after the probes') FROM public.mv_refresh_queue WHERE mv_name = 'mv_dispatch_list';
UPDATE public.dispatch SET id = id WHERE false;
SELECT pg_temp.lr_assert(mark_seq = :'seq'::bigint + 1 AND last_marked_dirty = :'dirty_since'::timestamptz,
  'a mark of a dirty list still counts and keeps its dirty_since') FROM public.mv_refresh_queue WHERE mv_name = 'mv_dispatch_list';
SELECT warehouse_security.refresh_dirty_lists();
SELECT pg_temp.lr_assert(NOT EXISTS (SELECT 1 FROM public.mv_refresh_queue WHERE needs_refresh), 'the refresh cleans every list');

-- ---------------------------------------------------------------------------
-- 4. Staff save a GRN and dispatch from it: lists follow only after the worker's refresh
-- ---------------------------------------------------------------------------
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888888871','List Refresh Administrator');
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888872','List Refresh Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888873','List Refresh Customer','customer',true,'approved');
SELECT id AS admin_profile FROM public.user_profiles WHERE mobile = '919888888871' \gset
SELECT pg_temp.lr_login('9888888872') AS staff_claims \gset
SELECT pg_temp.lr_login('9888888873') AS customer_claims \gset
INSERT INTO public.customers(name,mobile) VALUES ('List Refresh Farms','9888888874') RETURNING id AS customer_id \gset
INSERT INTO public.items(name,packaging) VALUES ('List Refresh Onions','Bag') RETURNING id AS item_id \gset
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active)
 SELECT id,:'customer_id'::uuid,true FROM public.user_profiles WHERE mobile='919888888873';
SELECT warehouse_security.refresh_dirty_lists();
SELECT pg_temp.lr_assert(NOT EXISTS (SELECT 1 FROM public.mv_refresh_queue WHERE needs_refresh), 'clean before the documents');

SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_grn(p_gr_no=>'LRW1',p_date=>now(),p_customer_id=>:'customer_id'::uuid,p_customer_name=>'List Refresh Farms',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','List Refresh Onions','packaging','Bag','qty',20,'weight',5)),
 p_idempotency_key=>'list-refresh-worker-grn') AS grn \gset
SELECT pg_temp.lr_assert(:'grn'::jsonb->>'success' = 'true', 'staff save the GRN: ' || :'grn');
RESET ROLE;
SELECT t.id AS lot_id FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id = t.gr_id WHERE g.gr_no = 'LRW1' \gset
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','LRWD1','disp_date',now(),
  'customer_id',:'customer_id','customer_name','List Refresh Farms',
  'supervisor_id',:'admin_profile','supervisor_name','List Refresh Administrator'),
  ARRAY[jsonb_build_object('gr_trl_id',:'lot_id','disp_qty',3)],0,'list-refresh-worker-dispatch') AS dispatch \gset
SELECT pg_temp.lr_assert(:'dispatch'::jsonb->>'success' = 'true', 'staff dispatch from it: ' || :'dispatch');
-- The write answers are authoritative at once.
SELECT pg_temp.lr_assert((SELECT stock = 17 FROM public.goodsreceived_trl WHERE id = :'lot_id'::uuid), 'the stock is taken at once');
SELECT pg_temp.lr_assert((public.get_list_freshness()#>>'{success}') = 'true'
    AND (SELECT bool_and((l->>'needs_refresh')::boolean AND l->>'dirty_since' IS NOT NULL) FROM jsonb_array_elements(public.get_list_freshness()#>'{data,lists}') l
          WHERE l->>'view' IN ('mv_dispatch_list','mv_grn_list','mv_invoice_list','mv_dispatch_daily_summary','mv_grn_daily_summary','mv_customer_stock_summary'))
    AND (public.get_list_freshness()#>>'{data,bound_seconds}')::integer = 15
    AND jsonb_array_length(public.get_list_freshness()#>'{data,lists}') = 7,
  'staff see the six lists the documents changed as needing a refresh: ' || public.get_list_freshness()::text);
SELECT pg_temp.lr_assert(jsonb_array_length(public.get_dispatch_list(p_filters => '{"disp_no": "LRWD1"}')->'data') = 0,
  'before the refresh the dispatch is not in get_dispatch_list: ' || left(public.get_dispatch_list(p_filters => '{"disp_no": "LRWD1"}')::text, 300));
RESET ROLE;
SELECT pg_temp.lr_assert(NOT EXISTS (SELECT 1 FROM public.mv_dispatch_list WHERE disp_no = 'LRWD1')
    AND NOT EXISTS (SELECT 1 FROM public.mv_grn_list WHERE gr_no = 'LRW1'),
  'neither write refreshed a list (the dispatch is absent from mv_dispatch_list, the GRN from mv_grn_list)');
SELECT pg_temp.lr_assert(pg_temp.lr_view_diff('mv_dispatch_list') > 0, 'mv_dispatch_list differs from its defining query before the refresh');

SELECT warehouse_security.refresh_dirty_lists();
SELECT pg_temp.lr_assert(EXISTS (SELECT 1 FROM public.mv_dispatch_list WHERE disp_no = 'LRWD1')
    AND EXISTS (SELECT 1 FROM public.mv_grn_list WHERE gr_no = 'LRW1'), 'after the refresh the dispatch and the GRN are listed');
SELECT pg_temp.lr_assert(bool_and(pg_temp.lr_view_diff(v) = 0), 'all seven lists equal their defining queries after one refresh: '
    || string_agg(v || '=' || pg_temp.lr_view_diff(v), ', '))
FROM unnest(warehouse_security.list_refresh_views()) v;
SELECT pg_temp.lr_assert(NOT EXISTS (SELECT 1 FROM public.mv_refresh_queue WHERE needs_refresh OR last_error_code IS NOT NULL)
    AND (SELECT bool_and(last_refresh IS NOT NULL) FROM public.mv_refresh_queue WHERE mv_name = ANY (warehouse_security.list_refresh_views())),
  'the queue is clean and every list has a refresh time');
-- TW-BE-023: the day's dispatch summary counts the dispatch with its line (before migration 91 the
-- header statement refreshed it before the line existed, and the line statement did not mark it).
SELECT pg_temp.lr_assert(s.dispatch_count = 1 AND s.line_count = 1 AND s.total_qty = 3,
  'TW-BE-023: the day''s mv_dispatch_daily_summary row for the customer is 1 dispatch, 1 line, 3 bags: '
    || s.dispatch_count || '/' || s.line_count || '/' || s.total_qty)
FROM public.mv_dispatch_daily_summary s
WHERE s.customer_id = :'customer_id'::uuid AND s.dispatch_day = date_trunc('day', now());
SELECT pg_temp.lr_assert((SELECT count(*) = 1 FROM public.mv_dispatch_daily_summary WHERE customer_id = :'customer_id'::uuid),
  'the customer has one dispatch day in the summary');
-- get_list_freshness: staff after the refresh; a customer account and anon are refused.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.lr_assert(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.get_list_freshness()#>'{data,lists}') l
    WHERE (l->>'needs_refresh')::boolean OR l->>'dirty_since' IS NOT NULL OR l->>'last_refresh' IS NULL OR (l->>'refresh_failing')::boolean)
  AND (SELECT l->'rpcs' = '["get_invoices_list"]'::jsonb FROM jsonb_array_elements(public.get_list_freshness()#>'{data,lists}') l WHERE l->>'view' = 'mv_invoice_list'),
  'staff see every list current after the refresh');
SELECT pg_temp.lr_assert(jsonb_array_length(public.get_dispatch_list(p_filters => '{"disp_no": "LRWD1"}')->'data') = 1,
  'after the refresh get_dispatch_list lists the dispatch: ' || left(public.get_dispatch_list(p_filters => '{"disp_no": "LRWD1"}')::text, 300));
SELECT set_config('request.jwt.claims',:'customer_claims',true);
DO $$ BEGIN
  PERFORM public.get_list_freshness();
  RAISE EXCEPTION 'list refresh worker: a customer account read the list freshness';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
RESET ROLE;
SELECT pg_temp.lr_assert(NOT has_function_privilege('anon', 'public.get_list_freshness()', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.get_list_freshness()', 'EXECUTE'), 'get_list_freshness is granted to authenticated, not anon');
ROLLBACK;
SELECT 'list refresh worker: no refresh on the write path, every table marks its lists, the refresh brings all seven lists to their definitions' AS result;

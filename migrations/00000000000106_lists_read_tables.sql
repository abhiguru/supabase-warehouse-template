-- Migration 106: the Invoices list reads the tables, and the list-refresh machinery of migration 91 is removed.
--
-- Why, in plain English. Migration 91 kept seven copies of list data (materialized views) fresh with a
-- background job: every write marked the lists, a pg_cron job refreshed them every five seconds, and a new
-- invoice could take up to 15 s to appear in the list. Only one of the seven copies was behind an app screen
-- (mv_invoice_list, for the Invoices list and the GRN Invoices tab); the rest were read by a function no app
-- calls any more, by a legacy overload only tests call, or by nothing. The owner decided that the Invoices list
-- reads the tables directly. A write is then visible at once, and the machinery below has no job left.
--
-- What changes, in this order (every step is skipped where the object is already gone, so the migration runs on
-- a new install, on an existing one, and in the test harness):
--  1. public.get_invoices_list is rewritten with the SAME signature, owner, SECURITY DEFINER, search_path and
--     grants, and reads invoice + customers + goodsreceived. Kept exactly: the role rules (administrators,
--     supervisors and staff see customers whose deleted_at is null; every other role goes through
--     user_accessible_customers(); no signed-in user sees nothing), every filter, p_search (each word must match
--     the invoice number, the customer name, the receipt number, "year-number" or the zero-padded form), every
--     sort with its tie-breaks, total_count, total_qty, financial_year_display and the answer shape. The filtered
--     set is built once (one materialized CTE) and serves both the page and total_count. The line total
--     (total_qty) is computed only for the rows of the page, with the same inner joins the view used. One
--     addition: the order ends with the invoice id, so rows that tie on every key (the same date and number in
--     two financial years) come back in one fixed order instead of an arbitrary one.
--  2. update_grn loses its two view lines (the insert into mv_refresh_status and the mark of the seven lists),
--     by the marker patch below; its document lock 71040 and everything else stay. authorize_rpc loses
--     'get_dispatch_list' and 'get_list_freshness' from its allow-list (same patch).
--  3. Dropped functions: get_dispatch_list (the app's wrapper was deleted; the Dispatches list uses
--     get_dispatch_list_with_items), the legacy get_all_grn_items(p_catalog_id, p_grn_id, ...) overload (the
--     overload with p_date_from stays), get_list_freshness, warehouse_security.list_refresh_status; the mark
--     functions public.mark_customer_list_mvs_dirty, mark_dispatch_mvs_dirty, mark_grn_mvs_dirty,
--     mark_invoice_mv_dirty, mark_stock_mvs_dirty and warehouse_security.mark_item_list_mvs_dirty,
--     mark_lists_dirty, list_refresh_views; the worker pieces list_refresh_claim, list_refresh_view,
--     list_refresh_done, list_refresh_prune_history, refresh_dirty_lists_worker, refresh_dirty_lists,
--     ensure_list_refresher; and the older view helpers enable_dispatch_triggers, refresh_dirty_mvs,
--     refresh_stock_views, trigger_refresh_dispatch_list_mv, trigger_refresh_stock_views,
--     refresh_auth_geographic_anomalies (nothing calls them). No CASCADE is used anywhere.
--  4. Dropped triggers: every statement trigger that marked lists (nine, on customers, dispatch, dispatch_trl,
--     goodsreceived, goodsreceived_trl, invoice, invoice_trl and items), found through pg_trigger.
--  5. Dropped tables and views: mv_refresh_queue, mv_refresh_status, the seven list views mv_customer_stock_summary,
--     mv_dispatch_daily_summary, mv_dispatch_list, mv_grn_daily_summary, mv_grn_list, mv_invoice_list,
--     mv_orders_list, and auth_geographic_anomalies (never populated, no reader).
--  6. pg_cron: the extension is dropped, with the image's event trigger issue_pg_cron_access and its function;
--     that removes the two jobs warehouse-list-refresh and warehouse-list-refresh-history and the cron schema.
--     The jobs are not unscheduled one by one; dropping the extension deletes them. The migration STOPS, and
--     changes nothing, if the cron table holds any other job (named or not), because dropping the extension
--     would delete it; the operator removes it with cron.unschedule(jobid) and reruns setup. The compose file
--     keeps pg_cron in shared_preload_libraries (with cron.database_name) only because locked migration 91
--     creates the extension on a fresh install; the library stays loaded but idle until the squashed baseline
--     removes migration 91 and the preload.
--  7. The login role warehouse_list_refresher is dropped only if it owns nothing in this database and nothing in
--     other databases or the cluster refers to it (pg_shdepend, as migration 103 does for supabase_functions_admin);
--     otherwise it is kept and a NOTICE says so. Only privileges granted to it are removed (DROP OWNED BY on a role
--     that owns nothing).
--  8. The legacy public.get_dispatch_list_original (its body calls the dropped get_dispatch_list) is dropped.
--     The advisory lock 71046 is still taken by scripts/migration-plan.mjs while pg_cron is preloaded.
--  A self-check at the end fails the migration if a materialized view, the pg_cron extension, the queue
--  tables or a function that names a dropped list remain, or if get_invoices_list is missing. The refresher
--  role is not checked: by design it may be kept (step 7), as a NOLOGIN role.
--
-- Speed (throwaway database, migrations 1-106, 20,000 invoices with 3-10 lines each, 500 customers,
-- get_invoices_list as an administrator, EXPLAIN ANALYZE of the statement the function runs, bar 300 ms):
-- worst of three calls, ms. Every sort and direction (page of 20, no filter): default inv_date desc 36, the
-- others 63-83. Filters: customer 3-5, financial year 26, date range 19, number range 13, number search 22, receipt
-- search 48. Free-text search: one word 83, two words 75, year-number 86, no match 90 (the slowest case; it
-- scans all 20,000 headers). Combined filters 2. Deep page (offset 19,980) 82. No index was needed.
-- Parity with the old function: tests/migrations.sh seeds a fixed set of invoices, records the answers of the
-- old function (reading mv_invoice_list) for every sort and direction, each filter and several pages before this
-- migration, applies the migration, and requires the same answers byte for byte afterwards.

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

-- Owner, SECURITY DEFINER, options and grants of the functions replaced in place, compared again at the end.
CREATE TEMP TABLE m106_before ON COMMIT DROP AS
SELECT p.oid AS fn, p.proowner, p.prosecdef, p.proconfig, p.proacl FROM pg_proc p
WHERE p.oid IN ('warehouse_security.authorize_rpc(text,jsonb)'::regprocedure,
  'public.get_invoices_list(integer,integer,uuid,integer,text,text,text,text,integer,integer,text,timestamptz,timestamptz,uuid[])'::regprocedure)
  OR (p.pronamespace = 'public'::regnamespace AND p.proname = 'update_grn');

-- ---------------------------------------------------------------------------
-- 1. The Invoices list from the tables
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_invoices_list(
  p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_customer_id uuid DEFAULT NULL::uuid,
  p_financial_year integer DEFAULT NULL::integer, p_search_invoice_no text DEFAULT NULL::text,
  p_search_grn_no text DEFAULT NULL::text, p_sort_field text DEFAULT 'inv_date'::text,
  p_sort_direction text DEFAULT 'desc'::text, p_inv_no_from integer DEFAULT NULL::integer,
  p_inv_no_to integer DEFAULT NULL::integer, p_search text DEFAULT NULL::text,
  p_date_from timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_date_to timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_customer_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
AS $function$
DECLARE
    v_user_role text;
    v_all_customers boolean := false;
    v_accessible_customers uuid[] := ARRAY[]::uuid[];
    v_total_count integer;
    v_data jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_invoices_list',jsonb_build_object('p_customer_id',p_customer_id));
    -- Which customers the caller may see: administrators, supervisors and staff see every customer that is
    -- not deleted; other roles see the customers assigned to them; nobody signed in sees nothing.
    IF auth.uid() IS NOT NULL THEN
        SELECT role INTO v_user_role
        FROM public.user_profiles
        WHERE auth_user_id = auth.uid();

        IF v_user_role IN ('admin', 'supervisor', 'staff') THEN
            v_all_customers := true;
        ELSE
            SELECT public.user_accessible_customers() INTO v_accessible_customers;
        END IF;
    END IF;

    WITH f AS MATERIALIZED (
        -- The filtered set: once, for the page and for the count.
        SELECT i.id AS invoice_id, i.inv_no, i.inv_fin_year, i.inv_date, i.total,
               c.name AS customer_name, gr.gr_no
        FROM public.invoice i
        JOIN public.customers c ON c.id = i.customer_id
        JOIN public.goodsreceived gr ON gr.id = i.gr_id
        WHERE i.deleted_at IS NULL
            AND (CASE WHEN v_all_customers THEN c.deleted_at IS NULL ELSE c.id = ANY(v_accessible_customers) END)
            AND (p_customer_id IS NULL OR c.id = p_customer_id)
            AND (p_financial_year IS NULL OR i.inv_fin_year = p_financial_year)
            AND (p_search_invoice_no IS NULL OR p_search_invoice_no = '' OR i.inv_no::text ILIKE '%' || p_search_invoice_no || '%')
            AND (p_search_grn_no IS NULL OR p_search_grn_no = '' OR gr.gr_no ILIKE '%' || p_search_grn_no || '%')
            AND (p_inv_no_from IS NULL OR i.inv_no >= p_inv_no_from)
            AND (p_inv_no_to IS NULL OR i.inv_no <= p_inv_no_to)
            AND (p_date_from IS NULL OR i.inv_date >= p_date_from)
            AND (p_date_to IS NULL OR i.inv_date <= p_date_to)
            AND (p_customer_ids IS NULL OR cardinality(p_customer_ids) = 0 OR c.id = ANY(p_customer_ids))
            AND NOT EXISTS (SELECT 1 FROM unnest(warehouse_security.search_terms(p_search)) AS term
              WHERE NOT (i.inv_no::text ILIKE term OR COALESCE(c.name, '') ILIKE term OR COALESCE(gr.gr_no, '') ILIKE term
                OR (i.inv_fin_year::text || '-' || i.inv_no::text) ILIKE term
                OR (i.inv_fin_year::text || '-' || lpad(i.inv_no::text, GREATEST(4, LENGTH(i.inv_no::text)), '0')) ILIKE term))
    ), pg AS MATERIALIZED (
        -- The rows of the page, in the requested order; ord keeps that order for the answer.
        SELECT s.invoice_id, row_number() OVER () AS ord
        FROM (
            SELECT m.invoice_id
            FROM f m
            ORDER BY
                -- inv_date sorting with secondary sort by inv_no DESC
                CASE WHEN p_sort_field = 'inv_date' AND p_sort_direction = 'desc' THEN m.inv_date END DESC,
                CASE WHEN p_sort_field = 'inv_date' AND p_sort_direction = 'asc' THEN m.inv_date END ASC,
                CASE WHEN p_sort_field = 'inv_date' THEN m.inv_no END DESC,
                -- inv_no sorting (invoice number)
                CASE WHEN p_sort_field = 'inv_no' AND p_sort_direction = 'desc' THEN m.inv_no END DESC,
                CASE WHEN p_sort_field = 'inv_no' AND p_sort_direction = 'asc' THEN m.inv_no END ASC,
                -- invoice_number alias (same as inv_no)
                CASE WHEN p_sort_field = 'invoice_number' AND p_sort_direction = 'desc' THEN m.inv_no END DESC,
                CASE WHEN p_sort_field = 'invoice_number' AND p_sort_direction = 'asc' THEN m.inv_no END ASC,
                -- customer_name sorting with secondary sort by inv_date DESC, inv_no DESC
                CASE WHEN p_sort_field = 'customer_name' AND p_sort_direction = 'desc' THEN m.customer_name END DESC,
                CASE WHEN p_sort_field = 'customer_name' AND p_sort_direction = 'asc' THEN m.customer_name END ASC,
                CASE WHEN p_sort_field = 'customer_name' THEN m.inv_date END DESC,
                CASE WHEN p_sort_field = 'customer_name' THEN m.inv_no END DESC,
                -- grn_number / gr_no sorting
                CASE WHEN p_sort_field IN ('grn_number', 'gr_no') AND p_sort_direction = 'desc' THEN m.gr_no END DESC,
                CASE WHEN p_sort_field IN ('grn_number', 'gr_no') AND p_sort_direction = 'asc' THEN m.gr_no END ASC,
                -- total sorting
                CASE WHEN p_sort_field = 'total' AND p_sort_direction = 'desc' THEN m.total END DESC,
                CASE WHEN p_sort_field = 'total' AND p_sort_direction = 'asc' THEN m.total END ASC,
                -- financial_year sorting with secondary sort by inv_no DESC
                CASE WHEN p_sort_field = 'financial_year' AND p_sort_direction = 'desc' THEN m.inv_fin_year END DESC,
                CASE WHEN p_sort_field = 'financial_year' AND p_sort_direction = 'asc' THEN m.inv_fin_year END ASC,
                CASE WHEN p_sort_field = 'financial_year' THEN m.inv_no END DESC,
                -- Default fallback: inv_date DESC, inv_no DESC
                m.inv_date DESC,
                m.inv_no DESC,
                -- Migration 106: rows that tie on every key above keep one fixed order.
                m.invoice_id
            LIMIT p_limit OFFSET p_offset
        ) s
    )
    SELECT (SELECT count(*) FROM f)::integer,
           COALESCE((
               SELECT jsonb_agg(
                   jsonb_build_object(
                       'invoice_id', i.id,
                       'invoice_number', i.inv_no,
                       'invoice_date', i.inv_date,
                       'inv_fin_year', i.inv_fin_year,
                       'financial_year', (i.inv_fin_year || '-'::text) || (i.inv_fin_year + 1),
                       'inv_name', i.inv_name,
                       'invoice_pricing_mode', i.pricing_mode,
                       'notes', i.notes,
                       'is_auto_generated', i.is_auto_generated,
                       'total', i.total,
                       'discount', i.discount,
                       'labour', i.labour,
                       'tax_amount', i.tax_amount,
                       'one_time_charge', i.one_time_charge,
                       'created_by', i.created_by,
                       'total_qty', q.total_qty,
                       'customer', jsonb_build_object(
                           'id', c.id,
                           'name', c.name,
                           'city', c.city,
                           'address', c.address,
                           'phone', c.mobile,
                           'email', c.email,
                           'gst', c.gst,
                           'active', c.active
                       ),
                       'grn', jsonb_build_object(
                           'id', gr.id,
                           'gr_no', gr.gr_no,
                           'registration', gr.registration,
                           'date', gr.date,
                           'sender_id', gr.sender_id,
                           'sender_name', gr.sender_name,
                           'supervisor_id', gr.supervisor_id,
                           'supervisor_name', gr.supervisor_name,
                           'customer_id', gr.customer_id,
                           'customer_name', gr.customer_name
                       )
                   ) ORDER BY pg.ord)
               FROM pg
               JOIN public.invoice i ON i.id = pg.invoice_id
               JOIN public.customers c ON c.id = i.customer_id
               JOIN public.goodsreceived gr ON gr.id = i.gr_id
               -- The line total of the invoice, for the rows of the page only. The inner joins are the ones the
               -- old list view used: a line whose dispatch line or receipt line is missing does not count.
               CROSS JOIN LATERAL (
                   SELECT COALESCE(sum(dt.disp_qty), 0::bigint)::numeric AS total_qty
                   FROM public.invoice_trl it
                   JOIN public.dispatch_trl dt ON dt.id = it.disp_trl_id
                   JOIN public.goodsreceived_trl grt ON grt.id = dt.gr_trl_id
                   WHERE it.invoice_id = i.id
               ) q
           ), '[]'::jsonb)
    INTO v_total_count, v_data;

    RETURN jsonb_build_object(
        'success', true,
        'data', v_data,
        'pagination', jsonb_build_object(
            'total_count', v_total_count,
            'has_more', (p_offset + p_limit) < v_total_count
        )
    );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2. The two functions that still exist lose their lines about the lists
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE fn regprocedure;
BEGIN
  SELECT p.oid::regprocedure INTO STRICT fn FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'update_grn';
  -- The insert into mv_refresh_status (a table of migration 4 that nothing reads) and the mark of the lists.
  PERFORM pg_temp.patch_rpc(fn,
  $m$        INSERT INTO mv_refresh_status (mv_name, is_dirty, last_marked_dirty_at)
        VALUES
            ('mv_grn_list', true, now()),
            ('mv_dispatch_list', true, now()),
            ('mv_customer_stock_summary', true, now())
        ON CONFLICT (mv_name) DO UPDATE SET
            is_dirty = true,
            last_marked_dirty_at = now();

        PERFORM pg_advisory_xact_lock(71040);
        -- Migration 91: the seven lists are marked here and refreshed after the commit.
        PERFORM warehouse_security.mark_lists_dirty(warehouse_security.list_refresh_views());
$m$, $r$        PERFORM pg_advisory_xact_lock(71040);
$r$);

  PERFORM pg_temp.patch_rpc('warehouse_security.authorize_rpc(text,jsonb)',
  $m$    'get_dispatch_details','get_dispatch_list','get_dispatch_list_with_items',
$m$, $r$    'get_dispatch_details','get_dispatch_list_with_items',
$r$);
  PERFORM pg_temp.patch_rpc('warehouse_security.authorize_rpc(text,jsonb)',
  $m$    -- How current the lists are (migration 91).
    'get_list_freshness',
$m$, $r$$r$);
END $patch$;

-- ---------------------------------------------------------------------------
-- 3-7. The refresh machinery
-- ---------------------------------------------------------------------------
DO $drop$
DECLARE
  t record;
  foreign_jobs text;
BEGIN
  -- Stop first if the cron table holds a job of anyone else: dropping pg_cron would delete it silently.
  IF to_regclass('cron.job') IS NOT NULL THEN
    EXECUTE $q$SELECT string_agg(COALESCE(jobname, '(no name)') || ' (job ' || jobid || ')', ', ' ORDER BY jobid)
                FROM cron.job WHERE jobname IS DISTINCT FROM 'warehouse-list-refresh'
                  AND jobname IS DISTINCT FROM 'warehouse-list-refresh-history'$q$ INTO foreign_jobs;
    IF foreign_jobs IS NOT NULL THEN
      RAISE EXCEPTION 'The pg_cron table holds jobs that are not the list refresh: %. Dropping pg_cron would delete them; remove them first (select jobid, jobname, command from cron.job; then select cron.unschedule(<jobid>);) and rerun setup.', foreign_jobs;
    END IF;
  END IF;

  -- The statement triggers first (they call the mark functions), found by the function they call.
  FOR t IN
    SELECT tg.tgrelid::regclass AS table_name, tg.tgname
    FROM pg_trigger tg
    WHERE NOT tg.tgisinternal AND tg.tgfoid IN (
      SELECT p.oid FROM pg_proc p
      WHERE (p.pronamespace = 'public'::regnamespace AND p.proname IN ('mark_customer_list_mvs_dirty','mark_dispatch_mvs_dirty',
               'mark_grn_mvs_dirty','mark_invoice_mv_dirty','mark_stock_mvs_dirty'))
         OR (p.pronamespace = 'warehouse_security'::regnamespace AND p.proname = 'mark_item_list_mvs_dirty'))
  LOOP
    EXECUTE format('DROP TRIGGER %I ON %s', t.tgname, t.table_name);
  END LOOP;
END $drop$;

DROP FUNCTION IF EXISTS public.get_dispatch_list(timestamptz, timestamptz, jsonb, text, text, integer, integer);
DROP FUNCTION IF EXISTS public.get_dispatch_list_original(timestamptz, timestamptz, jsonb, text, text, integer, integer);
DROP FUNCTION IF EXISTS public.get_all_grn_items(uuid, uuid, boolean, text, integer, integer);
DROP FUNCTION IF EXISTS public.get_list_freshness();
DROP FUNCTION IF EXISTS warehouse_security.list_refresh_status();
DROP FUNCTION IF EXISTS public.mark_customer_list_mvs_dirty();
DROP FUNCTION IF EXISTS public.mark_dispatch_mvs_dirty();
DROP FUNCTION IF EXISTS public.mark_grn_mvs_dirty();
DROP FUNCTION IF EXISTS public.mark_invoice_mv_dirty();
DROP FUNCTION IF EXISTS public.mark_stock_mvs_dirty();
DROP FUNCTION IF EXISTS warehouse_security.mark_item_list_mvs_dirty();
DROP FUNCTION IF EXISTS warehouse_security.mark_lists_dirty(text[]);
DROP FUNCTION IF EXISTS warehouse_security.list_refresh_views();
DROP FUNCTION IF EXISTS warehouse_security.list_refresh_claim();
DROP FUNCTION IF EXISTS warehouse_security.list_refresh_view(text);
DROP FUNCTION IF EXISTS warehouse_security.list_refresh_done(text, bigint, timestamptz, timestamptz, text);
DROP FUNCTION IF EXISTS warehouse_security.list_refresh_prune_history();
DROP PROCEDURE IF EXISTS warehouse_security.refresh_dirty_lists_worker();
DROP FUNCTION IF EXISTS warehouse_security.refresh_dirty_lists();
DROP FUNCTION IF EXISTS warehouse_security.ensure_list_refresher();
DROP FUNCTION IF EXISTS public.enable_dispatch_triggers();
DROP FUNCTION IF EXISTS public.refresh_dirty_mvs();
DROP FUNCTION IF EXISTS public.refresh_stock_views();
DROP FUNCTION IF EXISTS public.trigger_refresh_dispatch_list_mv();
DROP FUNCTION IF EXISTS public.trigger_refresh_stock_views();
DROP FUNCTION IF EXISTS public.refresh_auth_geographic_anomalies();

DROP MATERIALIZED VIEW IF EXISTS public.mv_customer_stock_summary;
DROP MATERIALIZED VIEW IF EXISTS public.mv_dispatch_daily_summary;
DROP MATERIALIZED VIEW IF EXISTS public.mv_dispatch_list;
DROP MATERIALIZED VIEW IF EXISTS public.mv_grn_daily_summary;
DROP MATERIALIZED VIEW IF EXISTS public.mv_grn_list;
DROP MATERIALIZED VIEW IF EXISTS public.mv_invoice_list;
DROP MATERIALIZED VIEW IF EXISTS public.mv_orders_list;
DROP MATERIALIZED VIEW IF EXISTS public.auth_geographic_anomalies;
DROP TABLE IF EXISTS public.mv_refresh_queue;
DROP TABLE IF EXISTS public.mv_refresh_status;

-- pg_cron and the image's event trigger for it, then the runner's role.
DO $cron$
DECLARE
  current_db oid := (SELECT oid FROM pg_database WHERE datname = current_database());
  owned_here bigint;
  referenced_elsewhere bigint;
BEGIN
  DROP EVENT TRIGGER IF EXISTS issue_pg_cron_access;
  DROP FUNCTION IF EXISTS extensions.grant_pg_cron_access();
  DROP EXTENSION IF EXISTS pg_cron;

  IF to_regrole('warehouse_list_refresher') IS NOT NULL THEN
    SELECT count(*) FILTER (WHERE s.dbid = current_db AND s.deptype = 'o'),
           count(*) FILTER (WHERE s.dbid <> current_db)
      INTO owned_here, referenced_elsewhere
    FROM pg_shdepend s
    WHERE s.refclassid = 'pg_authid'::regclass AND s.refobjid = 'warehouse_list_refresher'::regrole;
    IF owned_here = 0 AND referenced_elsewhere = 0 THEN
      DROP OWNED BY warehouse_list_refresher;
      DROP ROLE warehouse_list_refresher;
    ELSE
      ALTER ROLE warehouse_list_refresher NOLOGIN;
      RAISE NOTICE 'The role warehouse_list_refresher is kept: it owns % object(s) in this database and is referenced by % object(s) in other databases or cluster-wide.', owned_here, referenced_elsewhere;
    END IF;
  END IF;
END $cron$;

-- ---------------------------------------------------------------------------
-- Checks
-- ---------------------------------------------------------------------------
DO $check$
DECLARE d text; changed text; left_over text;
BEGIN
  SELECT string_agg(b.fn::regprocedure::text, ', ') INTO changed FROM m106_before b JOIN pg_proc p ON p.oid = b.fn
   WHERE p.proowner <> b.proowner OR p.prosecdef <> b.prosecdef
      OR (p.proconfig IS DISTINCT FROM b.proconfig) OR p.proacl IS DISTINCT FROM b.proacl;
  IF changed IS NOT NULL OR (SELECT count(*) FROM m106_before) <> 3 THEN
    RAISE EXCEPTION 'Migration 106: a replaced function changed owner, options or grants: %', changed;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_matviews) THEN
    RAISE EXCEPTION 'Migration 106: a materialized view remains: %', (SELECT string_agg(matviewname, ', ') FROM pg_matviews);
  END IF;
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') OR to_regnamespace('cron') IS NOT NULL THEN
    RAISE EXCEPTION 'Migration 106: pg_cron remains';
  END IF;
  IF to_regclass('public.mv_refresh_queue') IS NOT NULL OR to_regclass('public.mv_refresh_status') IS NOT NULL THEN
    RAISE EXCEPTION 'Migration 106: a refresh table remains';
  END IF;
  IF to_regprocedure('public.get_invoices_list(integer,integer,uuid,integer,text,text,text,text,integer,integer,text,timestamptz,timestamptz,uuid[])') IS NULL THEN
    RAISE EXCEPTION 'Migration 106: get_invoices_list is missing';
  END IF;
  -- No function of the application still names a dropped list or the queue.
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO left_over FROM pg_proc p
   WHERE p.pronamespace IN ('public'::regnamespace, 'warehouse_security'::regnamespace)
     AND p.prosrc ~* 'mv_(invoice|dispatch|grn|customer|orders)_|mv_refresh|refresh_dirty|mark_lists_dirty|list_refresh|REFRESH\s+MATERIALIZED';
  IF left_over IS NOT NULL THEN
    RAISE EXCEPTION 'Migration 106: a function still names a dropped list: %', left_over;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
              WHERE NOT t.tgisinternal AND p.proname ~ '^mark_.*(dirty)$') THEN
    RAISE EXCEPTION 'Migration 106: a trigger still marks lists';
  END IF;
  -- authorize_rpc: the two dropped names are gone from the allow-list, the others are untouched.
  d := pg_get_functiondef('warehouse_security.authorize_rpc(text,jsonb)'::regprocedure);
  IF position('''get_dispatch_list''' IN d) > 0 OR position('get_list_freshness' IN d) > 0
     OR position('''get_dispatch_list_with_items''' IN d) = 0 OR position('''get_invoices_list''' IN d) = 0 THEN
    RAISE EXCEPTION 'Migration 106: the allow-list of authorize_rpc is wrong';
  END IF;
  -- Migration 87: create_dispatch still takes 71040 exactly once, before its idempotency lookup.
  d := pg_get_functiondef('public.create_dispatch_with_stock_check_internal(jsonb,jsonb[],boolean,text)'::regprocedure);
  IF (length(d) - length(replace(d, 'pg_advisory_xact_lock(71040)', ''))) / length('pg_advisory_xact_lock(71040)') <> 1 THEN
    RAISE EXCEPTION 'Migration 106: create_dispatch must take lock 71040 exactly once';
  END IF;
END $check$;

DROP FUNCTION pg_temp.patch_rpc(regprocedure, text, text, integer);
NOTIFY pgrst, 'reload schema';

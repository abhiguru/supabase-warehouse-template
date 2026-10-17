-- Migration 91: the list refresh leaves the write path (TW-BE-016 and TW-BE-023, operational review
-- of 2026-10-17; owner decision D2: bound 15 s, runner pg_cron because the pinned image preloads it).
--
-- Before: every write statement on customers, goodsreceived, goodsreceived_trl, dispatch and
-- dispatch_trl ran a full REFRESH MATERIALIZED VIEW of every dirty list inside the writer's
-- transaction, under the document lock 71040 (zz_starter_refresh, migrations 4 and 20); items
-- refreshed mv_grn_list and invoice/invoice_trl refreshed mv_invoice_list directly, and update_grn
-- refreshed all seven lists before it answered. On a populated warehouse one dispatch spent 6-7 s of
-- its 8 s statement timeout there, and with five writers at once none committed.
--
-- After: a write only marks the lists it changes; a worker refreshes them after the commit.
-- 1. The five zz_starter_refresh triggers, the items trigger trg_mv_grn_list_refresh_on_items and the
--    invoice triggers trg_mv_invoice_list_refresh_on_inv(_trl) are dropped, with the three trigger
--    functions only they used. items now marks mv_grn_list and mv_customer_stock_summary (both show
--    the item name); invoice and invoice_trl mark mv_invoice_list.
-- 2. update_grn keeps its mark of all seven lists and its 71040 lock, and no longer refreshes: the
--    one PERFORM warehouse_security.refresh_dirty_lists() of migration 20 is replaced (marker patch).
-- 3. Marking. mv_refresh_queue gets mark_seq (raised by every mark), last_error_code and
--    last_error_at. Every mark goes through warehouse_security.mark_lists_dirty(views), which:
--    - always marks: the old "AND needs_refresh = false" skipped a mark that arrived while the flag
--      was still set, so a write committed after the worker's snapshot would have been lost;
--    - locks all queue rows in name order first, so two writers never wait on each other in a cycle;
--    - keeps last_marked_dirty as the start of the current dirty period, so its age is how far behind
--      a list can be (the doctor checks it against the bound).
--    Each table marks every list whose defining query reads it (pg_depend; tests/list_refresh_worker.sql
--    proves it). In particular mark_stock_mvs_dirty also marks both daily summaries, so a change of
--    lines alone reaches them (TW-BE-023), and a receipt or customer header change reaches the stock,
--    dispatch and invoice lists.
-- 4. The worker, CALL warehouse_security.refresh_dirty_lists_worker(), commits per view. PostgreSQL
--    refuses COMMIT in a SECURITY DEFINER procedure and in one with a SET clause, so the procedure runs
--    as its caller, names every object with its schema and calls SECURITY DEFINER helpers. One run:
--    - pg_try_advisory_lock(71046), session level; another run in progress makes this one return;
--    - list_refresh_claim(): the dirty lists and their mark_seq, read FOR UPDATE so that a writer still
--      marking one has committed first; COMMIT;
--    - per list: list_refresh_view() runs REFRESH ... CONCURRENTLY (plain only when the view cannot be
--      refreshed concurrently), COMMIT; list_refresh_done() records it, COMMIT. The list is clean only
--      if no mark arrived since the claim; a later mark keeps it dirty for the next run. Nothing is
--      cleared before the refresh succeeded, so a stopped run leaves the list dirty. A failed refresh
--      keeps the list dirty and records its SQLSTATE.
--    It never takes the document lock 71040, and writers never wait for a refresh.
-- 5. The runner: pg_cron job warehouse-list-refresh, every 5 seconds, as warehouse_list_refresher: a
--    LOGIN role without a password (pg_cron connects over 127.0.0.1 inside the db container, which the
--    image's pg_hba trusts; from the network a role without a password cannot sign in) that may run the
--    worker and nothing else. Job warehouse-list-refresh-history keeps its run history to one day.
--    warehouse_security.ensure_list_refresher() creates both and the role; scripts/configure-list-refresh.sql
--    calls it after every setup and restore, because a restore re-creates roles without LOGIN.
-- 6. warehouse_security.refresh_dirty_lists() keeps its name and grants (none) and becomes the same
--    refresh in the caller's transaction, without commits and without 71040: for SQL tests, which run in
--    one transaction, and for a manual catch-up.
-- 7. public.get_list_freshness(): per list view needs_refresh, dirty_since, last_refresh, a failing
--    refresh and the RPCs it serves, for administrators, supervisors and staff (authorize_rpc).
--    Contract: a committed write reaches get_invoices_list, get_dispatch_list and the legacy
--    get_all_grn_items(p_catalog_id, ...) overload within 15 s; write answers stay authoritative.
-- 8. warehouse_security.list_refresh_status(): what health-check.sh (doctor) checks, including a session other
--    than the runner that holds 71046.
-- Migrations: scripts/migration-plan.mjs holds 71046 for the whole run, so no refresh overlaps a migration;
-- taking 71040 in a migration (migrations 19 and 68) no longer keeps refreshes away.
-- Lock 71046 was unused (71040 documents, 71041 migrations, 71042 auth configuration, 71043 users,
-- 71045 SMS configuration; 71041/71044/71049 also seed hashtextextended keys). Migration 87's check that
-- create_dispatch takes 71040 exactly once, before its idempotency lookup, is repeated at the end.

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

-- Owner, SECURITY DEFINER, options and grants of the functions this migration replaces in place,
-- compared again at the end.
CREATE TEMP TABLE m91_before ON COMMIT DROP AS
SELECT p.oid AS fn, p.proowner, p.prosecdef, p.proconfig, p.proacl FROM pg_proc p
WHERE p.oid IN ('public.mark_customer_list_mvs_dirty()'::regprocedure, 'public.mark_dispatch_mvs_dirty()'::regprocedure,
  'public.mark_grn_mvs_dirty()'::regprocedure, 'public.mark_invoice_mv_dirty()'::regprocedure,
  'public.mark_stock_mvs_dirty()'::regprocedure, 'warehouse_security.refresh_dirty_lists()'::regprocedure,
  'warehouse_security.authorize_rpc(text,jsonb)'::regprocedure)
  OR (p.pronamespace = 'public'::regnamespace AND p.proname = 'update_grn');

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ---------------------------------------------------------------------------
-- 3. The queue and the mark
-- ---------------------------------------------------------------------------
ALTER TABLE public.mv_refresh_queue
  ADD COLUMN mark_seq bigint NOT NULL DEFAULT 0,
  ADD COLUMN last_error_code text,
  ADD COLUMN last_error_at timestamptz;

-- The seven lists the worker may refresh (as in migrations 4, 19 and 20).
CREATE FUNCTION warehouse_security.list_refresh_views() RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT ARRAY['mv_customer_stock_summary','mv_dispatch_daily_summary','mv_dispatch_list',
    'mv_grn_daily_summary','mv_grn_list','mv_invoice_list','mv_orders_list']::text[] $$;

CREATE FUNCTION warehouse_security.mark_lists_dirty(p_views text[]) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  -- Every queue row, in one order, before any is changed: writers that mark different lists in
  -- different statements of one transaction never wait on each other in a cycle.
  PERFORM 1 FROM public.mv_refresh_queue ORDER BY mv_name FOR UPDATE;
  UPDATE public.mv_refresh_queue
     SET mark_seq = mark_seq + 1,
         last_marked_dirty = CASE WHEN needs_refresh AND last_marked_dirty IS NOT NULL
                                  THEN last_marked_dirty ELSE clock_timestamp() END,
         needs_refresh = true
   WHERE mv_name = ANY (p_views);
END $$;

-- The statement triggers. Each set is every list whose defining query reads the trigger's table.
CREATE OR REPLACE FUNCTION public.mark_customer_list_mvs_dirty() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
    -- customers: every list but mv_dispatch_list reads it; mv_dispatch_list stays as before.
    PERFORM warehouse_security.mark_lists_dirty(warehouse_security.list_refresh_views());
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_dispatch_mvs_dirty() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
    PERFORM warehouse_security.mark_lists_dirty(ARRAY['mv_dispatch_daily_summary','mv_dispatch_list','mv_orders_list']);
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_grn_mvs_dirty() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
    PERFORM warehouse_security.mark_lists_dirty(ARRAY['mv_customer_stock_summary','mv_dispatch_daily_summary',
        'mv_dispatch_list','mv_grn_daily_summary','mv_grn_list','mv_invoice_list']);
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_invoice_mv_dirty() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
    PERFORM warehouse_security.mark_lists_dirty(ARRAY['mv_invoice_list']);
    RETURN NULL;
END;
$$;

-- On dispatch_trl and goodsreceived_trl. TW-BE-023: both daily summaries join the line tables.
CREATE OR REPLACE FUNCTION public.mark_stock_mvs_dirty() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
    PERFORM warehouse_security.mark_lists_dirty(ARRAY['mv_customer_stock_summary','mv_dispatch_daily_summary',
        'mv_dispatch_list','mv_grn_daily_summary','mv_grn_list','mv_invoice_list']);
    RETURN NULL;
END;
$$;

CREATE FUNCTION warehouse_security.mark_item_list_mvs_dirty() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  PERFORM warehouse_security.mark_lists_dirty(ARRAY['mv_customer_stock_summary','mv_grn_list']);
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION warehouse_security.list_refresh_views() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION warehouse_security.mark_lists_dirty(text[]) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION warehouse_security.mark_item_list_mvs_dirty() FROM PUBLIC, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 1. No refresh on the write path
-- ---------------------------------------------------------------------------
DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['customers','goodsreceived','goodsreceived_trl','dispatch','dispatch_trl'] LOOP
    EXECUTE format('DROP TRIGGER zz_starter_refresh ON public.%I', t);
  END LOOP;
END $$;
DROP TRIGGER trg_mv_grn_list_refresh_on_items ON public.items;
DROP TRIGGER trg_mv_invoice_list_refresh_on_inv ON public.invoice;
DROP TRIGGER trg_mv_invoice_list_refresh_on_inv_trl ON public.invoice_trl;
DROP FUNCTION warehouse_security.refresh_lists();
DROP FUNCTION public.trigger_refresh_grn_list_mv();
DROP FUNCTION public.trigger_refresh_invoice_list_mv();
CREATE TRIGGER trg_mark_item_list_mvs_dirty AFTER INSERT OR UPDATE OR DELETE ON public.items
  FOR EACH STATEMENT EXECUTE FUNCTION warehouse_security.mark_item_list_mvs_dirty();
CREATE TRIGGER trg_mark_invoice_mv_dirty AFTER INSERT OR UPDATE OR DELETE ON public.invoice
  FOR EACH STATEMENT EXECUTE FUNCTION public.mark_invoice_mv_dirty();
CREATE TRIGGER trg_mark_invoice_mv_dirty AFTER INSERT OR UPDATE OR DELETE ON public.invoice_trl
  FOR EACH STATEMENT EXECUTE FUNCTION public.mark_invoice_mv_dirty();

-- 2. update_grn marks and returns; the worker refreshes.
DO $patch$
DECLARE fn regprocedure;
BEGIN
  SELECT p.oid::regprocedure INTO STRICT fn FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'update_grn';
  PERFORM pg_temp.patch_rpc(fn,
  $m$        UPDATE public.mv_refresh_queue SET needs_refresh=true,last_marked_dirty=now()
          WHERE mv_name IN ('mv_customer_stock_summary','mv_grn_daily_summary',
            'mv_dispatch_daily_summary','mv_grn_list','mv_dispatch_list','mv_orders_list','mv_invoice_list');
        PERFORM warehouse_security.refresh_dirty_lists();
$m$, $r$        -- Migration 91: the seven lists are marked here and refreshed after the commit.
        PERFORM warehouse_security.mark_lists_dirty(warehouse_security.list_refresh_views());
$r$);
END $patch$;

-- ---------------------------------------------------------------------------
-- 4. The worker
-- ---------------------------------------------------------------------------
-- The dirty lists and their mark counters. FOR UPDATE waits for a writer that is marking one of them,
-- so every mark counted here is committed and visible to the refresh that follows.
CREATE FUNCTION warehouse_security.list_refresh_claim() RETURNS TABLE(mv_name text, mark_seq bigint)
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT q.mv_name, q.mark_seq FROM public.mv_refresh_queue q
   WHERE q.needs_refresh AND q.mv_name = ANY (warehouse_security.list_refresh_views())
   ORDER BY q.mv_name
   FOR UPDATE OF q $$;

-- Refreshes one list. NULL on success, else the SQLSTATE (a cancelled statement is not caught).
CREATE FUNCTION warehouse_security.list_refresh_view(p_view text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  IF p_view IS NULL OR NOT p_view = ANY (warehouse_security.list_refresh_views()) THEN
    RAISE EXCEPTION 'Unexpected refresh target' USING ERRCODE = '22023';
  END IF;
  BEGIN
    BEGIN
      EXECUTE format('REFRESH MATERIALIZED VIEW CONCURRENTLY public.%I', p_view);
    EXCEPTION WHEN object_not_in_prerequisite_state OR feature_not_supported THEN
      -- No unique index, or not populated yet: refresh it whole (readers wait meanwhile).
      EXECUTE format('REFRESH MATERIALIZED VIEW public.%I', p_view);
    END;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'List refresh of % failed with SQLSTATE %', p_view, SQLSTATE;
    RETURN SQLSTATE;
  END;
  RETURN NULL;
END $$;

-- Records a refresh. p_started_at: before the refresh began, so the list holds every write committed
-- before it. p_claimed_at: after the claim, so a mark that came later was made after it.
CREATE FUNCTION warehouse_security.list_refresh_done(p_view text, p_seq bigint, p_claimed_at timestamptz,
  p_started_at timestamptz, p_error text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  IF p_error IS NULL THEN
    UPDATE public.mv_refresh_queue q
       SET last_refresh = p_started_at, last_error_code = NULL, last_error_at = NULL,
           needs_refresh = (q.mark_seq <> p_seq),
           last_marked_dirty = CASE WHEN q.mark_seq <> p_seq THEN GREATEST(q.last_marked_dirty, p_claimed_at)
                                    ELSE q.last_marked_dirty END
     WHERE q.mv_name = p_view;
  ELSE
    UPDATE public.mv_refresh_queue q SET last_error_code = p_error, last_error_at = clock_timestamp()
     WHERE q.mv_name = p_view;
  END IF;
END $$;

-- The runner's entry point. Run it as a top-level CALL (pg_cron does); it commits per list.
CREATE PROCEDURE warehouse_security.refresh_dirty_lists_worker()
LANGUAGE plpgsql AS $$
DECLARE views text[]; seqs bigint[]; claimed_at timestamptz; started_at timestamptz; failure text; i integer;
BEGIN
  IF NOT pg_catalog.pg_try_advisory_lock(71046) THEN RETURN; END IF;
  SELECT pg_catalog.array_agg(c.mv_name ORDER BY c.mv_name), pg_catalog.array_agg(c.mark_seq ORDER BY c.mv_name)
    INTO views, seqs FROM warehouse_security.list_refresh_claim() c;
  claimed_at := pg_catalog.clock_timestamp();
  COMMIT;
  FOR i IN 1 .. COALESCE(pg_catalog.array_length(views, 1), 0) LOOP
    started_at := pg_catalog.clock_timestamp();
    failure := warehouse_security.list_refresh_view(views[i]);
    COMMIT;
    PERFORM warehouse_security.list_refresh_done(views[i], seqs[i], claimed_at, started_at, failure);
    COMMIT;
  END LOOP;
  PERFORM pg_catalog.pg_advisory_unlock(71046);
END $$;

-- 6. The same refresh in the caller's transaction: no commits, no advisory lock, no 71040.
CREATE OR REPLACE FUNCTION warehouse_security.refresh_dirty_lists() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE target record; claimed_at timestamptz; started_at timestamptz;
BEGIN
  FOR target IN SELECT c.mv_name, c.mark_seq FROM warehouse_security.list_refresh_claim() c LOOP
    claimed_at := COALESCE(claimed_at, clock_timestamp());
    started_at := clock_timestamp();
    PERFORM warehouse_security.list_refresh_done(target.mv_name, target.mark_seq, claimed_at, started_at,
      warehouse_security.list_refresh_view(target.mv_name));
  END LOOP;
END $$;

-- The run history of the two jobs, kept for one day.
CREATE FUNCTION warehouse_security.list_refresh_prune_history() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE removed integer;
BEGIN
  DELETE FROM cron.job_run_details d USING cron.job j
   WHERE j.jobid = d.jobid AND j.jobname IN ('warehouse-list-refresh', 'warehouse-list-refresh-history')
     AND d.end_time < now() - interval '1 day';
  GET DIAGNOSTICS removed = ROW_COUNT;
  RETURN removed;
END $$;

REVOKE ALL ON FUNCTION warehouse_security.list_refresh_claim() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION warehouse_security.list_refresh_view(text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION warehouse_security.list_refresh_done(text,bigint,timestamptz,timestamptz,text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION warehouse_security.list_refresh_prune_history() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON PROCEDURE warehouse_security.refresh_dirty_lists_worker() FROM PUBLIC, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. The runner
-- ---------------------------------------------------------------------------
-- Run by the migration and by scripts/configure-list-refresh.sql (setup.sh, restore.sh) as the
-- superuser that applies migrations. Role attributes and settings live outside the database dump, and
-- restore.sh re-creates missing roles without LOGIN, so this puts them back every time.
CREATE FUNCTION warehouse_security.ensure_list_refresher() RETURNS void
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE job record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'warehouse_list_refresher') THEN
    CREATE ROLE warehouse_list_refresher;
  END IF;
  ALTER ROLE warehouse_list_refresher WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT
    NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 3 PASSWORD NULL;
  ALTER ROLE warehouse_list_refresher SET search_path = pg_catalog;
  ALTER ROLE warehouse_list_refresher SET statement_timeout = '120s';
  ALTER ROLE warehouse_list_refresher SET lock_timeout = '30s';
  ALTER ROLE warehouse_list_refresher SET idle_in_transaction_session_timeout = '60s';
  GRANT USAGE ON SCHEMA warehouse_security TO warehouse_list_refresher;
  GRANT EXECUTE ON PROCEDURE warehouse_security.refresh_dirty_lists_worker() TO warehouse_list_refresher;
  GRANT EXECUTE ON FUNCTION warehouse_security.list_refresh_claim(), warehouse_security.list_refresh_view(text),
    warehouse_security.list_refresh_done(text,bigint,timestamptz,timestamptz,text),
    warehouse_security.list_refresh_prune_history() TO warehouse_list_refresher;
  -- schedule_in_database keeps an existing job of the same name and user but changes only its
  -- schedule and command (pg_cron 1.6), so alter_job sets every field, a paused job included.
  FOR job IN SELECT * FROM (VALUES
      ('warehouse-list-refresh', '5 seconds', 'CALL warehouse_security.refresh_dirty_lists_worker()'),
      ('warehouse-list-refresh-history', '17 * * * *', 'SELECT warehouse_security.list_refresh_prune_history()')
    ) AS j(name, schedule, command) LOOP
    PERFORM cron.alter_job(job_id := cron.schedule_in_database(job.name, job.schedule, job.command,
        current_database(), 'warehouse_list_refresher', true),
      schedule := job.schedule, command := job.command, database := current_database(),
      username := 'warehouse_list_refresher', active := true);
  END LOOP;
  -- One job of each name: a copy left under another user (an earlier hand-made one) is removed.
  DELETE FROM cron.job WHERE jobname IN ('warehouse-list-refresh', 'warehouse-list-refresh-history')
    AND username <> 'warehouse_list_refresher';
END $$;
REVOKE ALL ON FUNCTION warehouse_security.ensure_list_refresher() FROM PUBLIC, anon, authenticated, service_role;
DO $$ BEGIN PERFORM warehouse_security.ensure_list_refresher(); END $$;

-- 8. What the doctor checks (scripts are run by the superuser; not granted to any app role).
CREATE FUNCTION warehouse_security.list_refresh_status() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE job record; last_run record; oldest numeric; failing text; holder text; problems text[] := '{}';
BEGIN
  SELECT j.jobid, j.active, j.username INTO job FROM cron.job j WHERE j.jobname = 'warehouse-list-refresh';
  IF NOT FOUND THEN
    problems := problems || 'the pg_cron job warehouse-list-refresh is missing (run setup.sh again)'::text;
  ELSIF NOT job.active OR job.username <> 'warehouse_list_refresher' THEN
    problems := problems || 'the pg_cron job warehouse-list-refresh is paused or runs as another role (run setup.sh again)'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'warehouse_list_refresher' AND rolcanlogin) THEN
    problems := problems || 'the role warehouse_list_refresher cannot log in (run setup.sh again)'::text;
  END IF;
  SELECT round(EXTRACT(EPOCH FROM clock_timestamp() - min(q.last_marked_dirty))::numeric, 1) INTO oldest
    FROM public.mv_refresh_queue q WHERE q.needs_refresh AND q.mv_name = ANY (warehouse_security.list_refresh_views());
  IF oldest > 15 THEN
    problems := problems || format('a list has waited %s s for its refresh (bound: 15 s)', oldest);
  END IF;
  SELECT string_agg(q.mv_name || ' (SQLSTATE ' || q.last_error_code || ')', ', ' ORDER BY q.mv_name) INTO failing
    FROM public.mv_refresh_queue q WHERE q.last_error_code IS NOT NULL;
  IF failing IS NOT NULL THEN
    problems := problems || ('the refresh fails for ' || failing);
  END IF;
  -- Another session holding 71046 makes every run return at once: a migration in progress, or a CALL of
  -- the worker left open in psql after an error (the procedure cannot release the lock on an error).
  SELECT string_agg(format('pid %s (user %s, application %s, %s since %s)', a.pid, a.usename,
      COALESCE(NULLIF(a.application_name, ''), '-'), a.state, to_char(a.state_change, 'YYYY-MM-DD HH24:MI:SS TZ')), ', ')
    INTO holder
    FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid
   WHERE l.locktype = 'advisory' AND l.classid = 0 AND l.objid = 71046 AND l.objsubid = 1 AND l.granted
     AND a.usename IS DISTINCT FROM 'warehouse_list_refresher';
  IF holder IS NOT NULL THEN
    problems := problems || ('the list refresh lock 71046 is held by ' || holder
      || ': no run can refresh until that session ends');
  END IF;
  IF job.jobid IS NOT NULL THEN
    SELECT d.status, d.return_message INTO last_run FROM cron.job_run_details d
     WHERE d.jobid = job.jobid AND d.status IN ('succeeded', 'failed') ORDER BY d.runid DESC LIMIT 1;
    IF last_run.status = 'failed' THEN
      problems := problems || ('the last refresh run failed: ' || left(COALESCE(last_run.return_message, ''), 200));
    END IF;
  END IF;
  RETURN jsonb_build_object('ok', cardinality(problems) = 0, 'problems', to_jsonb(problems),
    'oldest_dirty_seconds', COALESCE(oldest, 0));
END $$;
REVOKE ALL ON FUNCTION warehouse_security.list_refresh_status() FROM PUBLIC, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. The freshness RPC
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM pg_temp.patch_rpc('warehouse_security.authorize_rpc(text,jsonb)',
  $m$    -- Sensors (owner decision, 2026-10-11).
    'get_sensor_polling_data','get_sensor_history',
$m$, $r$    -- How current the lists are (migration 91).
    'get_list_freshness',
    -- Sensors (owner decision, 2026-10-11).
    'get_sensor_polling_data','get_sensor_history',
$r$);
END $patch$;

CREATE FUNCTION public.get_list_freshness() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_list_freshness', '{}'::jsonb);
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'bound_seconds', 15,
    'refresh_interval_seconds', 5,
    'checked_at', clock_timestamp(),
    'lists', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'view', q.mv_name,
        'rpcs', CASE q.mv_name
                  WHEN 'mv_grn_list' THEN '["get_all_grn_items(p_catalog_id, ...)"]'::jsonb
                  WHEN 'mv_dispatch_list' THEN '["get_dispatch_list"]'::jsonb
                  WHEN 'mv_invoice_list' THEN '["get_invoices_list"]'::jsonb
                  ELSE '[]'::jsonb END,
        'needs_refresh', q.needs_refresh,
        'dirty_since', CASE WHEN q.needs_refresh THEN q.last_marked_dirty END,
        'last_refresh', q.last_refresh,
        'refresh_failing', q.last_error_code IS NOT NULL) ORDER BY q.mv_name)
      FROM public.mv_refresh_queue q WHERE q.mv_name = ANY (warehouse_security.list_refresh_views())), '[]'::jsonb)));
END $$;
REVOKE ALL ON FUNCTION public.get_list_freshness() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_list_freshness() TO authenticated;

-- ---------------------------------------------------------------------------
-- Checks
-- ---------------------------------------------------------------------------
DO $check$
DECLARE d text; changed text;
BEGIN
  -- The functions replaced in place kept owner, SECURITY DEFINER, options and grants.
  SELECT string_agg(b.fn::regprocedure::text, ', ') INTO changed FROM m91_before b JOIN pg_proc p ON p.oid = b.fn
   WHERE p.proowner <> b.proowner OR p.prosecdef <> b.prosecdef
      OR p.proconfig IS DISTINCT FROM b.proconfig OR p.proacl IS DISTINCT FROM b.proacl;
  IF changed IS NOT NULL OR (SELECT count(*) FROM m91_before) <> 8 THEN
    RAISE EXCEPTION 'Migration 91: a replaced function changed owner, options or grants: %', changed;
  END IF;
  -- No refresh is left on the write path.
  IF EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
              WHERE NOT t.tgisinternal AND t.tgrelid IN (SELECT oid FROM pg_class WHERE relnamespace = 'public'::regnamespace)
                AND p.prosrc ~* 'REFRESH\s+MATERIALIZED') THEN
    RAISE EXCEPTION 'Migration 91: a trigger still refreshes a materialized view';
  END IF;
  SELECT pg_get_functiondef(p.oid) INTO STRICT d FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'update_grn';
  IF position('refresh_dirty_lists' IN d) > 0 OR position('warehouse_security.mark_lists_dirty(warehouse_security.list_refresh_views())' IN d) = 0 THEN
    RAISE EXCEPTION 'Migration 91: update_grn still refreshes, or no longer marks the seven lists';
  END IF;
  -- Migration 87: create_dispatch takes 71040 exactly once, before its idempotency lookup.
  d := pg_get_functiondef('public.create_dispatch_with_stock_check_internal(jsonb,jsonb[],boolean,text)'::regprocedure);
  IF (length(d) - length(replace(d, 'pg_advisory_xact_lock(71040)', ''))) / length('pg_advisory_xact_lock(71040)') <> 1
     OR position('pg_advisory_xact_lock(71040)' IN d) > position('Check idempotency key first' IN d) THEN
    RAISE EXCEPTION 'Migration 91: create_dispatch must take lock 71040 exactly once, before the idempotency lookup';
  END IF;
  -- The worker never takes the document lock.
  IF EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'warehouse_security'::regnamespace
              AND (p.proname LIKE 'list_refresh%' OR p.proname IN ('refresh_dirty_lists', 'refresh_dirty_lists_worker', 'mark_lists_dirty'))
              AND p.prosrc LIKE '%71040%') THEN
    RAISE EXCEPTION 'Migration 91: the list refresh must not take lock 71040';
  END IF;
END $check$;

-- Catch up once: lists the old triggers left behind (a customer or receipt header change) are
-- refreshed by the first worker run.
DO $$ BEGIN PERFORM warehouse_security.mark_lists_dirty(warehouse_security.list_refresh_views()); END $$;

DROP FUNCTION pg_temp.patch_rpc(regprocedure, text, text, integer);
NOTIFY pgrst, 'reload schema';

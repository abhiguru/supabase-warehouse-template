-- Migration 71: retire the Tally accounting integration and the dead legacy functions
-- (external review 2026-10-13, L1-L10; the owner retired Tally entirely the same day).
--
-- The baseline carried a Tally integration nothing in this product uses: an invoice sync queue
-- filled by a trigger on every invoice write and never read, receipt and contra vouchers, bank
-- statement reconciliation, a ledger map kept in step with customer names by a trigger on
-- customers, and the functions around them. It also carried functions that nothing calls and
-- whose bodies do not work against the final schema (L1, L2, L7-L10). All 70 were granted to the
-- service role only; no edge function, script, test, document or app screen calls any of them.
--
-- What goes: six triggers (two on the live tables invoice and customers), 70 function signatures
-- (46 Tally, 24 dead) and 14 tables. What stays: payments and its policies (the Paid and Pending
-- reports read it; after this only the service role or the database owner writes it, as was
-- already true in practice), update_updated_at_column() (other tables' triggers use it) and
-- get_open_invoices_for_customer(uuid,date).
--
-- Data: the invoice sync queue (one row per invoice, never sent, rebuildable from invoice), the
-- sync log, attempts and drift log, the middleware status and the two voucher counters are
-- discarded; a NOTICE gives their row counts. The migration REFUSES to run, naming the table,
-- when a Tally voucher, receipt or contra voucher, bank statement or line, ledger map or company
-- configuration row exists: those are accounting records, and a stopped upgrade is better than
-- losing them silently. Take and verify a backup before upgrading (setup.sh does not take one).
--
-- Every check runs before the first drop. The migration also refuses when one of the 70 is
-- granted to anon or authenticated, when a trigger other than the six named here calls one, when
-- another object depends on one, when a function outside the set (public, utils,
-- warehouse_security, warehouse_maintenance) names one or a retired table, or when a policy on a
-- kept table names a retired table. Tables are dropped RESTRICT, functions without CASCADE.
-- tests/legacy_functions.sql checks the result.
DO $drop$
DECLARE
  signatures constant text[] := ARRAY[
    -- Tally, receipt, contra and bank reconciliation (46, with get_tally_company() last below)
    'public.acknowledge_voucher_drift(uuid,text,text)',
    'public.backfill_matched_receipts(date,integer)',
    'public.begin_tally_sync_attempt(uuid,text,text,text)',
    'public.claim_tally_sync_item(text,text)',
    'public.claim_vouchers_to_verify(text,integer,text)',
    'public.confirm_tally_sync_attempt(uuid,text,text,text)',
    'public.create_contra_voucher(date,numeric,text,text,text)',
    'public.create_manual_receipt(date,numeric,uuid,text,numeric,jsonb)',
    'public.create_manual_receipt(date,numeric,uuid,text,numeric,jsonb,text)',
    'public.delete_contra_voucher(uuid)',
    'public.delete_manual_receipt(uuid)',
    'public.enqueue_contra_voucher(uuid)',
    'public.enqueue_historical_invoices(integer,integer,integer,text)',
    'public.enqueue_historical_invoices(integer,integer,integer,text,boolean)',
    'public.enqueue_historical_receipts(text,integer,integer)',
    'public.enqueue_historical_receipts(text,integer,integer,boolean)',
    'public.enqueue_receipt_voucher(uuid)',
    'public.enqueue_tally_invoice_sync()',
    'public.get_contra_for_edit(uuid)',
    'public.get_invoice_for_tally_sync(uuid)',
    'public.get_receipt_for_edit(uuid)',
    'public.get_receipt_for_tally_sync(uuid)',
    'public.get_tally_ledger_map(uuid,character varying)',
    'public.get_tally_sync_dashboard()',
    'public.get_tally_sync_queue(text,text,integer,integer)',
    'public.guard_bank_reco_company_config_delete()',
    'public.handle_receipt_queue_dead_letter()',
    'public.pause_tally_sync(text,text)',
    'public.record_voucher_verification(uuid,text,text,jsonb,text)',
    'public.release_tally_locks(text)',
    'public.rename_tally_ledger(uuid,character varying,character varying)',
    'public.resume_tally_sync(text)',
    'public.resync_tally_receipt(uuid)',
    'public.retry_failed_receipt(uuid)',
    'public.save_tally_contra_voucher(uuid,text,text,date,text)',
    'public.save_tally_receipt_voucher(uuid,text,text,date,text)',
    'public.save_tally_voucher(uuid,character varying,character varying,character varying,date,character varying,numeric)',
    'public.set_receipt_editing(uuid,boolean)',
    'public.sync_customer_rename_to_ledger_map()',
    'public.update_contra_voucher(uuid,date,numeric,text,text,text)',
    'public.update_manual_receipt(uuid,date,numeric,uuid,text,numeric,jsonb)',
    'public.update_manual_receipt(uuid,date,numeric,uuid,text,numeric,jsonb,text)',
    'public.update_middleware_status(boolean,boolean,boolean,text,timestamp with time zone)',
    'public.update_tally_sync_status(uuid,text,text,timestamp with time zone,text,text,integer,jsonb)',
    'public.upsert_tally_ledger_map(uuid,character varying,character varying,character varying,character varying,boolean)',
    -- Dead (24): L1, L2, L7 (17), L8 (2), L9, L10 and L6's generate_order_number()
    'public.cleanup_expired_idempotency_keys()',
    'public.safe_delete_invoice(uuid,boolean)',
    'public.cancel_order(uuid,text,uuid)',
    'public.check_cart_restoration_history(text,uuid)',
    'public.create_order(jsonb,jsonb,uuid)',
    'public.delete_dispatch_with_stock_restore(uuid)',
    'public.delete_dispatch_with_stock_restore(uuid,integer)',
    'public.get_invoice_details(integer,integer)',
    'public.get_order_queue(integer,integer,text,text,jsonb,boolean,text)',
    'public.get_sensor_health_dashboard()',
    'public.get_unhealthy_sensors()',
    'public.ignore_order(uuid,text)',
    'public.ignore_order(uuid,text,uuid)',
    'public.list_service_credentials()',
    'public.reactivate_order(uuid)',
    'public.reactivate_order(uuid,uuid)',
    'public.record_sensor_health_status(character varying,character varying,character varying,numeric)',
    'public.register_sensor(character varying,text,text,text)',
    'public.search_all_items_autocomplete(text,text,integer,integer,integer,numeric,numeric)',
    'public.auto_generate_invoice_for_dispatch(uuid)',
    'public.retry_auto_invoice_generation(uuid,boolean)',
    'public.get_customers_with_stock(text,timestamp with time zone,integer,integer,integer)',
    'public.generate_time_first_uuid()',
    'public.generate_order_number()',
    -- Argument defaults of eight functions above call it: dropped after them.
    'public.get_tally_company()'
  ];
  triggers constant text[][] := ARRAY[
    ['trg_tally_sync_on_invoice', 'invoice'],
    ['trg_sync_customer_rename_to_ledger_map', 'customers'],
    ['tg_bank_reco_company_config_delete_guard', 'bank_reco_company_config'],
    ['trg_receipt_queue_dead_letter', 'tally_sync_queue'],
    ['trigger_tally_sync_queue_updated_at', 'tally_sync_queue'],
    ['trigger_tally_ledger_map_updated_at', 'tally_ledger_map']];
  -- In drop order (each before the tables its foreign keys point at).
  tables constant text[] := ARRAY['tally_receipt_vouchers', 'bank_statement_lines', 'bank_statements',
    'tally_contra_vouchers', 'tally_sync_attempts', 'tally_sync_log', 'tally_sync_queue', 'tally_vouchers',
    'tally_ledger_map', 'tally_drift_log', 'tally_middleware_status', 'bank_reco_company_config',
    'receipt_voucher_counters', 'contra_voucher_counters'];
  -- Accounting records: any row stops the migration.
  kept_records constant text[] := ARRAY['bank_statements', 'bank_statement_lines', 'tally_vouchers',
    'tally_receipt_vouchers', 'tally_contra_vouchers', 'tally_ledger_map', 'bank_reco_company_config'];
  fns regprocedure[] := '{}';
  rels regclass[] := '{}';
  fn regprocedure;
  name text;
  names_re text;
  tables_re text;
  found text;
  n bigint;
  discarded text := '';
  i integer;
BEGIN
  FOREACH name IN ARRAY signatures LOOP
    fn := to_regprocedure(name);
    IF fn IS NULL THEN RAISE EXCEPTION 'Migration 71: % does not exist; this database is not the one the migration was written for', name; END IF;
    fns := fns || fn;
  END LOOP;
  FOREACH name IN ARRAY tables LOOP
    IF to_regclass('public.' || name) IS NULL THEN RAISE EXCEPTION 'Migration 71: table public.% does not exist', name; END IF;
    rels := rels || to_regclass('public.' || name);
  END LOOP;
  FOR i IN 1 .. array_length(triggers, 1) LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = triggers[i][1] AND tgrelid = ('public.' || triggers[i][2])::regclass) THEN
      RAISE EXCEPTION 'Migration 71: trigger % on public.% does not exist', triggers[i][1], triggers[i][2];
    END IF;
  END LOOP;

  -- (a) Not API: none is granted to an app role.
  SELECT string_agg(f::text, ', ') INTO found FROM unnest(fns) AS f
  WHERE has_function_privilege('anon', f, 'EXECUTE') OR has_function_privilege('authenticated', f, 'EXECUTE');
  IF found IS NOT NULL THEN RAISE EXCEPTION 'Migration 71: granted to an API role, so not dead code: %', found; END IF;

  -- (b) No trigger other than the six calls one of them, and nothing else depends on one.
  SELECT string_agg(format('%s on %s', t.tgname, t.tgrelid::regclass), ', ') INTO found
  FROM pg_trigger t
  WHERE NOT t.tgisinternal AND t.tgfoid = ANY (fns)
    AND NOT EXISTS (SELECT 1 FROM generate_subscripts(triggers, 1) AS k
                    WHERE t.tgname = triggers[k][1] AND t.tgrelid = ('public.' || triggers[k][2])::regclass);
  IF found IS NOT NULL THEN RAISE EXCEPTION 'Migration 71: another trigger calls a retired function: %', found; END IF;
  SELECT string_agg(pg_describe_object(d.classid, d.objid, d.objsubid), ', ') INTO found
  FROM pg_depend d
  WHERE d.refclassid = 'pg_proc'::regclass AND d.refobjid = ANY (fns) AND d.deptype = 'n'
    AND NOT (d.classid = 'pg_proc'::regclass AND d.objid = ANY (fns))
    AND NOT (d.classid = 'pg_trigger'::regclass AND EXISTS (
      SELECT 1 FROM pg_trigger t, generate_subscripts(triggers, 1) AS k
      WHERE t.oid = d.objid AND t.tgname = triggers[k][1] AND t.tgrelid = ('public.' || triggers[k][2])::regclass));
  IF found IS NOT NULL THEN RAISE EXCEPTION 'Migration 71: an object outside the set depends on a retired function: %', found; END IF;

  -- (c) No function outside the set names one of them.
  SELECT '\m(' || string_agg(DISTINCT p.proname, '|') || ')\M' INTO names_re FROM pg_proc p WHERE p.oid = ANY (fns);
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO found
  FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
  WHERE s.nspname IN ('public', 'utils', 'warehouse_security', 'warehouse_maintenance')
    AND NOT p.oid = ANY (fns) AND p.prosrc ~ names_re;
  IF found IS NOT NULL THEN RAISE EXCEPTION 'Migration 71: a kept function names a retired function: %', found; END IF;

  -- (d) No kept function and no policy on a kept table names a retired table.
  tables_re := '\m(' || array_to_string(tables, '|') || ')\M';
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO found
  FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
  WHERE s.nspname IN ('public', 'utils', 'warehouse_security', 'warehouse_maintenance')
    AND NOT p.oid = ANY (fns) AND p.prosrc ~ tables_re;
  IF found IS NOT NULL THEN RAISE EXCEPTION 'Migration 71: a kept function names a retired table: %', found; END IF;
  SELECT string_agg(format('%s on %s', pol.polname, pol.polrelid::regclass), ', ') INTO found
  FROM pg_policy pol
  WHERE NOT pol.polrelid = ANY (rels)
    AND (COALESCE(pg_get_expr(pol.polqual, pol.polrelid), '') || ' ' || COALESCE(pg_get_expr(pol.polwithcheck, pol.polrelid), '')) ~ tables_re;
  IF found IS NOT NULL THEN RAISE EXCEPTION 'Migration 71: a policy names a retired table: %', found; END IF;

  -- Accounting records stop the migration; the rest is counted and discarded.
  FOREACH name IN ARRAY kept_records LOOP
    EXECUTE format('SELECT count(*) FROM public.%I', name) INTO n;
    IF n > 0 THEN
      RAISE EXCEPTION 'Migration 71: public.% holds % row(s) of Tally accounting records; the migration does not discard them', name, n
        USING HINT = 'Export or remove these rows deliberately (after a verified backup), then run the upgrade again.';
    END IF;
  END LOOP;
  FOREACH name IN ARRAY tables LOOP
    CONTINUE WHEN name = ANY (kept_records);
    EXECUTE format('SELECT count(*) FROM public.%I', name) INTO n;
    discarded := discarded || format('%s%s %s', CASE WHEN discarded = '' THEN '' ELSE ', ' END, name, n);
  END LOOP;
  RAISE NOTICE 'Migration 71 discards these rows (never-sent Tally queue, logs and counters): %', discarded;

  -- 1. Triggers, by name.
  FOR i IN 1 .. array_length(triggers, 1) LOOP
    EXECUTE format('DROP TRIGGER %I ON public.%I', triggers[i][1], triggers[i][2]);
  END LOOP;
  -- 2. Functions, without CASCADE; get_tally_company() last.
  FOREACH fn IN ARRAY fns LOOP
    EXECUTE format('DROP FUNCTION %s', fn);
  END LOOP;
  -- 3. Tables, RESTRICT.
  FOREACH name IN ARRAY tables LOOP
    EXECUTE format('DROP TABLE public.%I RESTRICT', name);
  END LOOP;

  IF to_regprocedure('public.update_updated_at_column()') IS NULL THEN
    RAISE EXCEPTION 'Migration 71: update_updated_at_column() must be kept';
  END IF;
END $drop$;
NOTIFY pgrst, 'reload schema';

-- Migration 71 retires the Tally accounting integration and the dead legacy functions (L1-L10).
--
-- The baseline carried a Tally integration (an invoice sync queue fed by a trigger on invoice,
-- receipt and contra vouchers, bank statement reconciliation, a ledger map kept in step with
-- customer names by a trigger on customers) and dead functions that nothing calls and whose
-- bodies do not work against the final schema (external review 2026-10-13, L1-L10). Every one
-- was granted to the service role only; nothing in functions/, scripts/, tests/, the docs or the
-- app calls them. The owner retired Tally entirely (2026-10-13).
--
-- Four parts:
--   1. gone: the 70 signatures, the 14 tables and the six triggers (two of them on the live
--      tables invoice and customers);
--   2. no function left in public, utils, warehouse_security or warehouse_maintenance names a
--      Tally, bank statement, bank reconciliation, receipt voucher or contra voucher object;
--   3. kept: payments with its two policies, update_updated_at_column() (shared by other triggers) and
--      get_open_invoices_for_customer(uuid,date), still the service role's only;
--   4. the live path: as the database owner an invoice is written and its total changed and a
--      customer renamed (both used to fire a Tally trigger); a payment of 4 against a total of 14
--      leaves 10 outstanding, read as the service role.
-- Recorded payments stay; Paid and Pending in the reports read them (tests/report_invoice_paid.sql
-- and tests/report_invoice_amounts.sql are unchanged).
-- Part 5: migration 74 retires the two MAC-based sensor writers, record_sensor_reading and
-- update_sensor (service role only, called by nothing); public.record_sensor_batch and
-- public.update_sensor_device replace them (tests/sensor_ingest.sql).
-- Runs ONLY in migrations.sh's fresh, network-disabled database. All fixture rows roll back.
\set ON_ERROR_STOP on
BEGIN;
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
  AND to_regprocedure('public.update_sensor_device(uuid,text,text,integer)') IS NOT NULL,
  'record_sensor_batch and update_sensor_device replace them');

ROLLBACK;

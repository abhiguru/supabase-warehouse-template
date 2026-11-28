-- WH-299 backend change "sync GRN invoice state" (feed format 2), cases B1 and B3 of
-- ~/ws/fresh/product/tech/app-offline-read-from-copy.md (sections 6 and 13). tests/migrations.sh pipes
-- tests/fixtures/gst_details.sql and tests/sync_feed_contract.sql in front of this file, in the sync feed database of its own;
-- this file commits. Fictional data only.
--   B3: the feed's payload format is 2 and a copy of format 1 is told to reload everything.
--   B1: every GRN's grn_lock row carries invoice_state equal to warehouse_security.grn_invoice_state(id) after a lot's stock
--       changes, a dispatch is soft-deleted or deleted, an invoice is issued, cancelled or deleted, imported_billed_dispatches
--       changes, and charging_rule.invoice_as_goods_leave is switched (answered with a reload of grn_lock).
--
-- AGREE WITH DEVELOPMENT (WH-299): the new names are 'invoice_state' (field of a grn_lock row) and format 2; every other feed
-- name is in tests/sync_feed_contract.sql.
\set ON_ERROR_STOP on

-- The phone's invoice_state of one GRN; '(no row)' without a grn_lock row, '(no field)' when the row lacks the key.
CREATE FUNCTION pg_temp.is_state(p text, grn uuid) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT COALESCE((SELECT CASE WHEN c.row ? 'invoice_state' THEN COALESCE(c.row->>'invoice_state', '(null)') ELSE '(no field)' END
    FROM pg_temp.sf_copy c WHERE c.slot = p AND c.e = pg_temp.sf('e_grn_lock') AND c.id = grn::text), '(no row)') $$;
-- Every live GRN of the facility whose grn_lock row on the phone is missing or says something else than the server's one-GRN rule.
CREATE FUNCTION pg_temp.is_bad(p text) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT COALESCE(string_agg(format('%s phone %s server %s', t.gr_no, t.phone, t.server), '; ' ORDER BY t.gr_no), '')
  FROM (SELECT g.gr_no, pg_temp.is_state(p, g.id) AS phone, warehouse_security.grn_invoice_state(g.id) AS server
        FROM public.goodsreceived g WHERE g.deleted_at IS NULL) t
  WHERE t.phone IS DISTINCT FROM t.server $$;
-- After one pull of each staff-side phone: the GRN has the expected state, every GRN agrees with the server, and the copy equals a
-- fresh load.
CREATE FUNCTION pg_temp.is_expect(grn uuid, expected text, step text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE p text; got text; bad text;
BEGIN
  PERFORM pg_temp.sf_assert(warehouse_security.grn_invoice_state(grn) = expected,
    format('premise (%s): the server says %s, the fixture expects %s', step, warehouse_security.grn_invoice_state(grn), expected));
  FOREACH p IN ARRAY ARRAY['admin', 'supervisor', 'staff'] LOOP
    PERFORM pg_temp.sf_pull(p);
    got := pg_temp.is_state(p, grn);
    PERFORM pg_temp.sf_assert(got = expected, format('B1 %s: %s holds invoice_state %s, expected %s', step, p, got, expected));
    bad := pg_temp.is_bad(p);
    PERFORM pg_temp.sf_assert(bad = '', format('B1 %s: %s disagrees with grn_invoice_state: %s', step, p, bad));
    bad := pg_temp.sf_diff(p);
    PERFORM pg_temp.sf_assert(bad = '', format('B1 %s: the copy of %s differs from a fresh load: %s', step, p, bad));
  END LOOP;
END $$;
-- Bills the one line of a dispatch (administrator); returns the invoice id.
CREATE FUNCTION pg_temp.is_invoice(claims jsonb, bill int, disp uuid) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE d record; r jsonb;
BEGIN
  SELECT t.id AS line, t.gr_trl_id AS lot, g.id AS grn, g.gr_no, g.customer_id, g.customer_name INTO STRICT d
    FROM public.dispatch_trl t JOIN public.goodsreceived g ON g.id = t.gr_id WHERE t.disp_id = disp;
  r := pg_temp.sf_as(claims, format('SELECT public.save_invoice(NULL::uuid, %L::jsonb, ARRAY[%L::jsonb])',
    jsonb_build_object('inv_fin_year', 2026, 'inv_no', bill, 'customer_id', d.customer_id, 'customer_name', d.customer_name,
      'inv_date', '2026-06-02T12:00:00Z', 'total', 0, 'tax_amount', 0, 'labour', 0, 'discount', 0, 'duration_mode', 'legacy',
      'gr_id', d.grn, 'gr_no', d.gr_no),
    jsonb_build_object('disp_trl_id', d.line, 'grn_item_id', d.lot, 'duration', 1, 'charge', 5, 'tax', 5, 'labour_rate', 2)));
  PERFORM pg_temp.sf_assert(r->>'success' = 'true', format('fixture: invoice %s: %s', bill, left(r::text, 300)));
  RETURN (r->>'invoice_id')::uuid;
END $$;

INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888897302', 'Copy State Staff Person', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888897303', 'Copy State Supervisor', 'supervisor', true, 'approved'),
 (gen_random_uuid(), '919888897311', 'Copy State Reader', 'customer', true, 'approved');
SELECT pg_temp.sf_login('9888897302') AS staff_claims \gset
SELECT pg_temp.sf_login('9888897303') AS supervisor_claims \gset
SELECT pg_temp.sf_login('9888897311') AS reader_claims \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_customer(''Copy State East'', ''9888897321'')')->>'success' = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_item(''Copy State Ginger'', ''Bag'')')->>'success' = 'true', 'customer and item');
SELECT id AS east FROM public.customers WHERE name = 'Copy State East' \gset
SELECT id AS ginger FROM public.items WHERE name = 'Copy State Ginger' \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT to_jsonb(public.assign_customer_to_user(%L, %L::uuid, %L))', '919888897311', :'east', 'Copy state fixture'))::text = 'true',
  'the customer account is assigned');
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.replace_item_rates(%L::uuid, %L::uuid, %L, %L::date, %L::jsonb)', :'ginger', :'east', 'monthly', '2026-01-01',
  '[{"weight_min":0,"weight_max":100,"unit_price":5,"labour_rate":2,"tax_percent":5}]'))->>'success' = 'true', 'price');

SELECT pg_temp.sf_phone('admin', :'sf_admin_claims'::jsonb);
SELECT pg_temp.sf_phone('supervisor', :'supervisor_claims'::jsonb);
SELECT pg_temp.sf_phone('staff', :'staff_claims'::jsonb);
SELECT pg_temp.sf_phone('reader', :'reader_claims'::jsonb);

-- ---------------------------------------------------------------------------------------------------------------------------------
-- B3. Format 2: the stored format, the start answer and copy key of every role, a changes answer; a format-1 copy reloads.
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT pg_temp.sf_first_load(p) FROM unnest(ARRAY['admin', 'supervisor', 'staff', 'reader']) p;
SELECT pg_temp.sf_assert((SELECT count(*) = 4 AND bool_and((answer->>pg_temp.sf('f_format'))::int >= 3 AND split_part(answer->>pg_temp.sf('f_copy'), '.', 1) = answer->>pg_temp.sf('f_format'))
    FROM pg_temp.sf_answer WHERE kind = 'start'),
  'B3: get_sync_start answers format 3 or later and a copy key of that same format to every role: '
  || (SELECT string_agg(phone || ' ' || COALESCE(answer->>pg_temp.sf('f_format'), '(none)'), ', ') FROM pg_temp.sf_answer WHERE kind = 'start'));
SELECT pg_temp.sf_changes_once('admin') AS plain_changes \gset
SELECT pg_temp.sf_assert((:'plain_changes'::jsonb->>pg_temp.sf('f_format'))::int >= 3 AND :'plain_changes'::jsonb->>'success' = 'true',
  'B3: get_sync_changes answers format 3 or later: ' || left(:'plain_changes', 300));
SELECT (:'plain_changes'::jsonb->>pg_temp.sf('f_format'))::int - 1 AS older_format \gset
SELECT pg_temp.sf_changes_once('admin', NULL, regexp_replace(copy, '^[0-9]+\.', :'older_format' || '.')) AS old_copy FROM pg_temp.sf_device WHERE phone = 'admin' \gset
SELECT pg_temp.sf_assert(:'old_copy'::jsonb#>>ARRAY[pg_temp.sf('f_reload_all'), pg_temp.sf('f_reason')] = pg_temp.sf('r_format'),
  'B3: a copy key of the format before the current one answers reload_all FORMAT_CHANGED: ' || left(:'old_copy', 300));

-- ---------------------------------------------------------------------------------------------------------------------------------
-- B1. The documents, with "invoice as goods leave" on. Each GRN has one lot of 10 bags.
-- ---------------------------------------------------------------------------------------------------------------------------------
UPDATE warehouse_security.charging_rule SET invoice_as_goods_leave = true WHERE id;
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'CSA', :'east'::uuid, pg_temp.sf_lines(:'ginger'::uuid, 1, 'CSA')) AS grn_a \gset
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'CSB', :'east'::uuid, pg_temp.sf_lines(:'ginger'::uuid, 1, 'CSB')) AS grn_b \gset
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'CSC', :'east'::uuid, pg_temp.sf_lines(:'ginger'::uuid, 1, 'CSC')) AS grn_c \gset
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'CSD', :'east'::uuid, pg_temp.sf_lines(:'ginger'::uuid, 1, 'CSD')) AS grn_d \gset
SELECT id AS lot_a FROM public.goodsreceived_trl WHERE gr_id = :'grn_a' \gset
SELECT id AS lot_b FROM public.goodsreceived_trl WHERE gr_id = :'grn_b' \gset
SELECT id AS lot_c FROM public.goodsreceived_trl WHERE gr_id = :'grn_c' \gset
SELECT id AS lot_d FROM public.goodsreceived_trl WHERE gr_id = :'grn_d' \gset
SELECT pg_temp.is_expect(:'grn_a', 'not_invoiced', 'a new GRN');
-- A first load (get_sync_page) carries the field too, not only a change.
SELECT pg_temp.sf_first_load('staff');
SELECT pg_temp.sf_assert(pg_temp.is_bad('staff') = '', 'B1 first load: every grn_lock row of a page carries the server''s state: ' || pg_temp.is_bad('staff'));

-- Lot stock change by a dispatch, then an invoice issued.
SELECT pg_temp.sf_dispatch(:'sf_admin_claims'::jsonb, 'CSA1', :'lot_a'::uuid, 4) AS disp_a1 \gset
SELECT pg_temp.is_expect(:'grn_a', 'not_invoiced', 'dispatched, not invoiced');
SELECT pg_temp.is_invoice(:'sf_admin_claims'::jsonb, 7001, :'disp_a1'::uuid) AS inv_a1 \gset
SELECT pg_temp.is_expect(:'grn_a', 'partly_invoiced', 'invoice issued while stock remains');
SELECT pg_temp.sf_assert(pg_temp.sf_ops('staff', pg_temp.sf('e_grn_lock'), :'grn_a', pg_temp.sf_last_pull('staff')) = pg_temp.sf('op_upsert'),
  'B1: the invoice reached staff as an upsert of the GRN''s grn_lock');
SELECT pg_temp.sf_dispatch(:'sf_admin_claims'::jsonb, 'CSA2', :'lot_a'::uuid, 6) AS disp_a2 \gset
SELECT pg_temp.is_expect(:'grn_a', 'partly_invoiced', 'the rest left, its line not invoiced');
SELECT pg_temp.is_invoice(:'sf_admin_claims'::jsonb, 7002, :'disp_a2'::uuid) AS inv_a2 \gset
SELECT pg_temp.is_expect(:'grn_a', 'invoiced', 'every line invoiced, no stock');
-- A lot's stock changed on its own (no dispatch, no invoice).
UPDATE public.goodsreceived_trl SET stock = 2 WHERE id = :'lot_a';
SELECT pg_temp.is_expect(:'grn_a', 'partly_invoiced', 'lot stock raised');
UPDATE public.goodsreceived_trl SET stock = 0 WHERE id = :'lot_a';
SELECT pg_temp.is_expect(:'grn_a', 'invoiced', 'lot stock back to zero');
-- Invoices cancelled.
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.cancel_invoice(%L::uuid, %L, NULL)', :'inv_a2', 'Copy state test'))->>'success' = 'true', 'cancel 7002');
SELECT pg_temp.is_expect(:'grn_a', 'partly_invoiced', 'one invoice cancelled');
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.cancel_invoice(%L::uuid, %L, NULL)', :'inv_a1', 'Copy state test'))->>'success' = 'true', 'cancel 7001');
SELECT pg_temp.is_expect(:'grn_a', 'not_invoiced', 'both invoices cancelled');

-- B stays partly invoiced with stock in store: the GRN the setting switch changes.
SELECT pg_temp.sf_dispatch(:'sf_admin_claims'::jsonb, 'CSB1', :'lot_b'::uuid, 4) AS disp_b1 \gset
SELECT pg_temp.is_invoice(:'sf_admin_claims'::jsonb, 7003, :'disp_b1'::uuid) AS inv_b1 \gset
SELECT pg_temp.is_expect(:'grn_b', 'partly_invoiced', 'GRN B partly invoiced');

-- C: a dispatch soft-deleted, restored, then deleted through the app's function; then an invoice deleted.
SELECT pg_temp.sf_dispatch(:'sf_admin_claims'::jsonb, 'CSC1', :'lot_c'::uuid, 4) AS disp_c1 \gset
SELECT pg_temp.sf_dispatch(:'sf_admin_claims'::jsonb, 'CSC2', :'lot_c'::uuid, 6) AS disp_c2 \gset
SELECT pg_temp.is_invoice(:'sf_admin_claims'::jsonb, 7004, :'disp_c1'::uuid) AS inv_c1 \gset
SELECT pg_temp.is_expect(:'grn_c', 'partly_invoiced', 'GRN C with a free dispatch line');
UPDATE public.dispatch SET deleted_at = now() WHERE id = :'disp_c2';
SELECT pg_temp.is_expect(:'grn_c', 'invoiced', 'the free dispatch soft-deleted');
UPDATE public.dispatch SET deleted_at = NULL WHERE id = :'disp_c2';
SELECT pg_temp.is_expect(:'grn_c', 'partly_invoiced', 'the dispatch restored');
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.delete_dispatch_with_order_cleanup(%L::uuid, %L::uuid)', :'disp_c2', :'sf_admin_profile'))->>'success' = 'true',
  'delete dispatch CSC2');
SELECT pg_temp.is_expect(:'grn_c', 'partly_invoiced', 'dispatch deleted, its stock back in store');
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.delete_invoice(%L::uuid)', :'inv_c1'))->>'success' = 'true', 'delete invoice 7004');
SELECT pg_temp.is_expect(:'grn_c', 'not_invoiced', 'invoice deleted');

-- D: imported_billed_dispatches. Two lines leave, one is invoiced; an imported invoice exists but takes no line yet.
SELECT pg_temp.sf_dispatch(:'sf_admin_claims'::jsonb, 'CSD1', :'lot_d'::uuid, 5) AS disp_d1 \gset
SELECT pg_temp.sf_dispatch(:'sf_admin_claims'::jsonb, 'CSD2', :'lot_d'::uuid, 5) AS disp_d2 \gset
SELECT pg_temp.is_invoice(:'sf_admin_claims'::jsonb, 7005, :'disp_d1'::uuid) AS inv_d1 \gset
INSERT INTO public.invoice (inv_fin_year, inv_no, gr_id, gr_no, customer_id, customer_name, inv_date, total, tax_amount, discount, duration_mode)
  VALUES (2026, 7901, :'grn_d', 'CSD', :'east', 'Copy State East', '2026-06-02T12:00:00Z', 0, 0, 0, 'legacy') RETURNING id AS inv_imp \gset
SELECT id AS line_d2 FROM public.dispatch_trl WHERE disp_id = :'disp_d2' \gset
SELECT pg_temp.is_expect(:'grn_d', 'partly_invoiced', 'one line not billed');
-- Only imported_billed_dispatches changes in each of the next three transactions.
INSERT INTO public.imported_billed_dispatches (disp_trl_id, invoice_id) VALUES (:'line_d2', :'inv_imp');
SELECT pg_temp.is_expect(:'grn_d', 'invoiced', 'a line taken as billed (imported_billed_dispatches insert)');
SELECT pg_temp.sf_assert(pg_temp.sf_ops(p, pg_temp.sf('e_grn_lock'), :'grn_d', pg_temp.sf_last_pull(p)) = pg_temp.sf('op_upsert'),
  'B1: the imported_billed_dispatches insert logged the GRN''s grn_lock for ' || p) FROM unnest(ARRAY['admin', 'supervisor', 'staff']) p;
DELETE FROM public.imported_billed_dispatches WHERE disp_trl_id = :'line_d2';
SELECT pg_temp.is_expect(:'grn_d', 'partly_invoiced', 'imported_billed_dispatches row removed');
-- As an import writes it (user triggers off): the feed trigger fires all the same.
BEGIN;
SET LOCAL session_replication_role = replica;
INSERT INTO public.imported_billed_dispatches (disp_trl_id, invoice_id) VALUES (:'line_d2', :'inv_imp');
COMMIT;
SELECT pg_temp.is_expect(:'grn_d', 'invoiced', 'imported_billed_dispatches written with the user triggers off');

-- A customer account holds no grn_lock: all of the above reaches it without one, and its pull is answered.
SELECT pg_temp.sf_pull('reader');
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM pg_temp.sf_entry WHERE phone = 'reader' AND e = pg_temp.sf('e_grn_lock'))
  AND pg_temp.sf_held('reader', pg_temp.sf('e_grn_lock')) = '{}', 'B1: a customer account receives no grn_lock');
SELECT pg_temp.sf_assert(pg_temp.sf_diff('reader') = '', 'B1: the customer account''s copy equals a fresh load: ' || pg_temp.sf_diff('reader'));

-- ---------------------------------------------------------------------------------------------------------------------------------
-- B1. The setting switched: every role that holds grn_lock (staff too, who never receive the setting itself) is told to reload it.
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT pg_temp.sf_assert(pg_temp.is_state(p, :'grn_b') = 'partly_invoiced', 'premise: ' || p || ' holds GRN B as partly invoiced')
  FROM unnest(ARRAY['admin', 'supervisor', 'staff']) p;
UPDATE warehouse_security.charging_rule SET invoice_as_goods_leave = false WHERE id;
SELECT pg_temp.sf_assert(warehouse_security.grn_invoice_state(:'grn_b') = 'invoiced', 'premise: with the setting off a live invoice means invoiced');
SELECT pg_temp.sf_pull('admin') AS off_admin \gset
SELECT pg_temp.sf_pull('supervisor') AS off_supervisor \gset
SELECT pg_temp.sf_pull('staff') AS off_staff \gset
SELECT pg_temp.sf_pull('reader') AS off_reader \gset
SELECT pg_temp.sf_assert(:'off_admin'::jsonb->'reload' ? pg_temp.sf('e_grn_lock') AND :'off_supervisor'::jsonb->'reload' ? pg_temp.sf('e_grn_lock')
  AND :'off_staff'::jsonb->'reload' ? pg_temp.sf('e_grn_lock'),
  'B1: switching the setting off orders a reload of grn_lock: admin ' || :'off_admin' || ' supervisor ' || :'off_supervisor' || ' staff ' || :'off_staff');
SELECT pg_temp.sf_assert(NOT (:'off_reader'::jsonb->'reload' ? pg_temp.sf('e_grn_lock')), 'B1: a customer account is not told to reload grn_lock: ' || :'off_reader');
SELECT pg_temp.sf_assert(pg_temp.is_state(p, :'grn_b') = 'invoiced' AND pg_temp.is_bad(p) = '',
  format('B1 setting off: %s holds GRN B as %s; disagreements: %s', p, pg_temp.is_state(p, :'grn_b'), pg_temp.is_bad(p)))
  FROM unnest(ARRAY['admin', 'supervisor', 'staff']) p;
SELECT pg_temp.sf_assert(pg_temp.sf_diff(p) = '', 'B1 setting off: the copy of ' || p || ' equals a fresh load: ' || pg_temp.sf_diff(p))
  FROM unnest(ARRAY['admin', 'supervisor', 'staff']) p;
-- Ordered once: the next pull has nothing to reload.
SELECT pg_temp.sf_pull('staff') AS idle_staff \gset
SELECT pg_temp.sf_assert(:'idle_staff'::jsonb->'reload' = '[]', 'B1: the reload is ordered once, not at every later pull: ' || :'idle_staff');

UPDATE warehouse_security.charging_rule SET invoice_as_goods_leave = true WHERE id;
SELECT pg_temp.sf_pull('admin') AS on_admin \gset
SELECT pg_temp.sf_pull('supervisor') AS on_supervisor \gset
SELECT pg_temp.sf_pull('staff') AS on_staff \gset
SELECT pg_temp.sf_assert(:'on_admin'::jsonb->'reload' ? pg_temp.sf('e_grn_lock') AND :'on_supervisor'::jsonb->'reload' ? pg_temp.sf('e_grn_lock')
  AND :'on_staff'::jsonb->'reload' ? pg_temp.sf('e_grn_lock'),
  'B1: switching the setting on orders a reload of grn_lock: admin ' || :'on_admin' || ' supervisor ' || :'on_supervisor' || ' staff ' || :'on_staff');
SELECT pg_temp.sf_assert(pg_temp.is_state(p, :'grn_b') = 'partly_invoiced' AND pg_temp.is_bad(p) = '',
  format('B1 setting on: %s holds GRN B as %s; disagreements: %s', p, pg_temp.is_state(p, :'grn_b'), pg_temp.is_bad(p)))
  FROM unnest(ARRAY['admin', 'supervisor', 'staff']) p;

-- A save of the charging rule that leaves the setting as it was orders no reload.
UPDATE warehouse_security.charging_rule SET invoice_as_goods_leave = invoice_as_goods_leave, updated_at = now() WHERE id;
SELECT pg_temp.sf_pull('admin') AS same_admin \gset
SELECT pg_temp.sf_pull('staff') AS same_staff \gset
SELECT pg_temp.sf_assert(pg_temp.sf_ops('admin', pg_temp.sf('e_settings'), pg_temp.sf('settings_charging_rule'), pg_temp.sf_last_pull('admin')) = pg_temp.sf('op_upsert'),
  'premise: the administrator received the saved charging rule');
SELECT pg_temp.sf_assert(NOT (:'same_admin'::jsonb->'reload' ? pg_temp.sf('e_grn_lock')) AND NOT (:'same_staff'::jsonb->'reload' ? pg_temp.sf('e_grn_lock')),
  'B1: an unchanged setting orders no reload of grn_lock: admin ' || :'same_admin' || ' staff ' || :'same_staff');

-- Left as the shared setup leaves it, for the suites that follow in this database.
UPDATE warehouse_security.charging_rule SET invoice_as_goods_leave = false WHERE id;

\echo 'WH-299 sync GRN invoice state (format 2, B1 and B3) checks passed.'

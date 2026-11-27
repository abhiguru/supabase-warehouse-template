-- WH-328, feed side, updated for WH-381 (feed format 8): orders, order lines, payments and dispatches are NO LONGER feed entities;
-- their write paths emit zero entity rows for any role while keeping grn_lock (on_order / dispatched_qty), goodsreceived_trl stock,
-- money stale marks, and B5 "stable order reads" (online get_order_with_items) intact.
-- Contract: ~/ws/fresh/product/tech/app-offline-scope-cut.md Section 1 (superseding app-offline-orders-payments.md feed entities).
-- tests/migrations.sh pipes tests/fixtures/gst_details.sql and tests/sync_feed_contract.sql in front of this file, in the sync
-- feed database of its own; this file commits. Fictional data only.
--
-- Cases: B1 zero orders/order_items/payments/dispatch in any role's copy + grn_lock/stock kept; B2 every order/payment/dispatch write
-- path emits zero dropped-entity entries while preserving grn_lock, stock and money marks; B3 moved order; B4 format 8+; B5 deterministic
-- online order reads (get_order_with_items).
\set ON_ERROR_STOP on

CREATE FUNCTION pg_temp.of_lock_on_order(p text, grn uuid, lot uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT COALESCE((SELECT (l->>'on_order')::boolean
    FROM pg_temp.sf_copy c, jsonb_array_elements(c.row->pg_temp.sf('lock_lines')) l
   WHERE c.slot = p AND c.e = pg_temp.sf('e_grn_lock') AND c.id = grn::text AND l->>pg_temp.sf('lock_line_id') = lot::text), false) $$;
CREATE FUNCTION pg_temp.of_marks(p text) RETURNS text[] LANGUAGE sql STABLE AS $$
  SELECT COALESCE(array_agg(d ORDER BY d), '{}') FROM (SELECT DISTINCT detail AS d FROM pg_temp.sf_event
    WHERE phone = p AND kind = 'stale' AND pull = pg_temp.sf_last_pull(p)) t $$;

-- WH-381: no role may hold orders, order_items, payments or dispatch rows in its phone copy.
CREATE FUNCTION pg_temp.of_truth(p text, cust uuid DEFAULT NULL) RETURNS text LANGUAGE plpgsql AS $$
DECLARE probs text[] := '{}';
BEGIN
  IF cardinality(pg_temp.sf_held(p, 'orders')) <> 0 THEN
    probs := probs || format('orders: copy %s, expected 0 (WH-381)', cardinality(pg_temp.sf_held(p, 'orders'))); END IF;
  IF cardinality(pg_temp.sf_held(p, 'order_items')) <> 0 THEN
    probs := probs || format('order_items: copy %s, expected 0 (WH-381)', cardinality(pg_temp.sf_held(p, 'order_items'))); END IF;
  IF cardinality(pg_temp.sf_held(p, 'payments')) <> 0 THEN
    probs := probs || format('payments: copy %s, expected 0 (WH-381)', cardinality(pg_temp.sf_held(p, 'payments'))); END IF;
  IF cardinality(pg_temp.sf_held(p, 'dispatch')) <> 0 THEN
    probs := probs || format('dispatch: copy %s, expected 0 (WH-381)', cardinality(pg_temp.sf_held(p, 'dispatch'))); END IF;
  RETURN array_to_string(probs, '; ');
END $$;

-- One step: every phone pulls; each copy equals a fresh load and holds exactly what its role may hold.
CREATE FUNCTION pg_temp.of_step(step text, north uuid, south uuid) RETURNS void LANGUAGE plpgsql AS $$
DECLARE p text; bad text;
BEGIN
  FOREACH p IN ARRAY ARRAY['admin', 'supervisor', 'staff', 'c1', 'c2'] LOOP
    PERFORM pg_temp.sf_pull(p);
    bad := pg_temp.sf_diff(p);
    PERFORM pg_temp.sf_assert(bad = '', format('%s: the copy of %s differs from a fresh load: %s', step, p, bad));
    bad := pg_temp.of_truth(p, CASE p WHEN 'c1' THEN north WHEN 'c2' THEN south END);
    PERFORM pg_temp.sf_assert(bad = '', format('%s: %s holds what its role may not, or lacks what it may: %s', step, p, bad));
  END LOOP;
END $$;

CREATE FUNCTION pg_temp.of_cart(claims jsonb, cust uuid) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  r := pg_temp.sf_as(claims, format('SELECT to_jsonb(public.get_or_create_cart(%L::uuid))', cust));
  PERFORM pg_temp.sf_assert(r IS NOT NULL AND jsonb_typeof(r) = 'string', 'fixture: cart: ' || COALESCE(r::text, 'NULL'));
  RETURN (r #>> '{}')::uuid;
END $$;
CREATE FUNCTION pg_temp.of_add(claims jsonb, ord uuid, lot uuid, qty int) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  r := pg_temp.sf_as(claims, format('SELECT public.add_item_to_order(%L::uuid, %L::uuid, %s)', ord, lot, qty));
  PERFORM pg_temp.sf_assert(r->>'success' = 'true', 'fixture: add_item_to_order: ' || left(r::text, 300));
  RETURN (SELECT id FROM public.order_items WHERE order_id = ord AND grn_items_id = lot);
END $$;
-- A dispatch made from an order (source_order_id), one lot.
CREATE FUNCTION pg_temp.of_dispatch(claims jsonb, disp_no text, lot uuid, qty int, ord uuid) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE r jsonb; cust uuid; cname text;
BEGIN
  SELECT g.customer_id, g.customer_name INTO cust, cname FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id = t.gr_id WHERE t.id = lot;
  r := pg_temp.sf_as(claims, format('SELECT public.create_dispatch_with_stock_check(%L::jsonb, ARRAY[%L::jsonb], 0, %L)',
    jsonb_build_object('disp_no', disp_no, 'disp_date', '2026-06-01', 'customer_id', cust, 'customer_name', cname, 'source_order_id', ord,
      'supervisor_id', (SELECT id FROM public.user_profiles WHERE mobile = '919888897001'), 'supervisor_name', 'Sync Feed Administrator'),
    jsonb_build_object('gr_trl_id', lot, 'disp_qty', qty), 'orders-feed-' || disp_no));
  PERFORM pg_temp.sf_assert(r->>'success' = 'true', 'fixture: order dispatch ' || disp_no || ': ' || left(r::text, 300));
  RETURN (SELECT id FROM public.dispatch WHERE dispatch.disp_no = of_dispatch.disp_no);
END $$;
-- Bills the one line of a dispatch (as the invoice-state suite does); returns the invoice id.
CREATE FUNCTION pg_temp.of_invoice(claims jsonb, bill int, disp uuid) RETURNS uuid LANGUAGE plpgsql AS $$
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
CREATE FUNCTION pg_temp.of_pay(claims jsonb, inv uuid, amount numeric, req text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  r := pg_temp.sf_as(claims, format('SELECT public.record_payment(%L::uuid, DATE %L, %s, %L, NULL, %L)', inv, '2026-06-03', amount, 'cash', req));
  PERFORM pg_temp.sf_assert(r->>'success' = 'true', 'fixture: record_payment: ' || left(r::text, 300));
  RETURN (r#>>'{payment,id}')::uuid;
END $$;

-- ---------------------------------------------------------------------------------------------------------------------------------
-- Fixture. Phones: admin, supervisor, staff, c1 (account of North), c2 (account of South). Customers North, South, Dormant (deactivated
-- after its order exists), Fresh (no order yet). Orders: ON (2 lines), OS (1 line), OD (Dormant, 1 line).
-- ---------------------------------------------------------------------------------------------------------------------------------
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888897502', 'Order Feed Staff Person', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888897503', 'Order Feed Supervisor', 'supervisor', true, 'approved'),
 (gen_random_uuid(), '919888897511', 'Order Feed North Reader', 'customer', true, 'approved'),
 (gen_random_uuid(), '919888897512', 'Order Feed South Reader', 'customer', true, 'approved');
SELECT pg_temp.sf_login('9888897502') AS staff_claims \gset
SELECT pg_temp.sf_login('9888897503') AS supervisor_claims \gset
SELECT pg_temp.sf_login('9888897511') AS c1_claims \gset
SELECT pg_temp.sf_login('9888897512') AS c2_claims \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_customer(''Order Feed North'', ''9888897521'')')->>'success' = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_customer(''Order Feed South'', ''9888897522'')')->>'success' = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_customer(''Order Feed Dormant'', ''9888897523'')')->>'success' = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_customer(''Order Feed Fresh'', ''9888897524'')')->>'success' = 'true', 'customers');
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_item(''Order Feed Onion'', ''Bag'')')->>'success' = 'true', 'item');
SELECT id AS north FROM public.customers WHERE name = 'Order Feed North' \gset
SELECT id AS south FROM public.customers WHERE name = 'Order Feed South' \gset
SELECT id AS dormant FROM public.customers WHERE name = 'Order Feed Dormant' \gset
SELECT id AS fresh FROM public.customers WHERE name = 'Order Feed Fresh' \gset
SELECT id AS onion FROM public.items WHERE name = 'Order Feed Onion' \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT to_jsonb(public.assign_customer_to_user(%L, %L::uuid, %L))', '919888897511', :'north', 'Order feed fixture'))::text = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT to_jsonb(public.assign_customer_to_user(%L, %L::uuid, %L))', '919888897512', :'south', 'Order feed fixture'))::text = 'true',
  'customer accounts assigned');
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.replace_item_rates(%L::uuid, %L::uuid, %L, %L::date, %L::jsonb)', :'onion', :'north', 'monthly', '2026-01-01',
  '[{"weight_min":0,"weight_max":100,"unit_price":5,"labour_rate":2,"tax_percent":5}]'))->>'success' = 'true', 'price for North');
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.set_record_payments(true)')->>'success' = 'true', 'payments on');

SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'OFN1', :'north'::uuid, pg_temp.sf_lines(:'onion'::uuid, 4, 'ON', 20)) AS grn_n \gset
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'OFS1', :'south'::uuid, pg_temp.sf_lines(:'onion'::uuid, 2, 'OS', 20)) AS grn_s \gset
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'OFD1', :'dormant'::uuid, pg_temp.sf_lines(:'onion'::uuid, 1, 'OD', 20)) AS grn_d \gset
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'OFF1', :'fresh'::uuid, pg_temp.sf_lines(:'onion'::uuid, 1, 'OF', 20)) AS grn_f \gset
SELECT id AS lot_n1 FROM public.goodsreceived_trl WHERE gr_id = :'grn_n' AND package_mark = 'ON1' \gset
SELECT id AS lot_n2 FROM public.goodsreceived_trl WHERE gr_id = :'grn_n' AND package_mark = 'ON2' \gset
SELECT id AS lot_n3 FROM public.goodsreceived_trl WHERE gr_id = :'grn_n' AND package_mark = 'ON3' \gset
SELECT id AS lot_n4 FROM public.goodsreceived_trl WHERE gr_id = :'grn_n' AND package_mark = 'ON4' \gset
SELECT id AS lot_s1 FROM public.goodsreceived_trl WHERE gr_id = :'grn_s' AND package_mark = 'OS1' \gset
SELECT id AS lot_s2 FROM public.goodsreceived_trl WHERE gr_id = :'grn_s' AND package_mark = 'OS2' \gset
SELECT id AS lot_d1 FROM public.goodsreceived_trl WHERE gr_id = :'grn_d' \gset
SELECT id AS lot_f1 FROM public.goodsreceived_trl WHERE gr_id = :'grn_f' \gset

SELECT pg_temp.of_cart(:'sf_admin_claims'::jsonb, :'north'::uuid) AS ord_n \gset
SELECT pg_temp.of_cart(:'sf_admin_claims'::jsonb, :'south'::uuid) AS ord_s \gset
SELECT pg_temp.of_cart(:'sf_admin_claims'::jsonb, :'dormant'::uuid) AS ord_d \gset
SELECT pg_temp.of_add(:'sf_admin_claims'::jsonb, :'ord_n'::uuid, :'lot_n1'::uuid, 5) AS line_n1 \gset
SELECT pg_temp.of_add(:'sf_admin_claims'::jsonb, :'ord_n'::uuid, :'lot_n2'::uuid, 6) AS line_n2 \gset
SELECT pg_temp.of_add(:'sf_admin_claims'::jsonb, :'ord_s'::uuid, :'lot_s1'::uuid, 4) AS line_s1 \gset
SELECT pg_temp.of_add(:'sf_admin_claims'::jsonb, :'ord_d'::uuid, :'lot_d1'::uuid, 3) AS line_d1 \gset
UPDATE public.customers SET active = false WHERE id = :'dormant';
SELECT pg_temp.sf_assert(NOT (SELECT active FROM public.customers WHERE id = :'dormant'), 'premise: Dormant is deactivated');

-- Payments: one invoice for North, one for South, each with one payment; a payment with no invoice (old accounting link).
-- An invoice needs a GRN with no stock left: one-lot GRNs of 4 bags, dispatched in full, are the ones billed.
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'OFN2', :'north'::uuid, pg_temp.sf_lines(:'onion'::uuid, 1, 'NB', 4)) AS grn_nb \gset
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'OFS2', :'south'::uuid, pg_temp.sf_lines(:'onion'::uuid, 1, 'SB', 4)) AS grn_sb \gset
SELECT id AS lot_nb FROM public.goodsreceived_trl WHERE gr_id = :'grn_nb' \gset
SELECT id AS lot_sb FROM public.goodsreceived_trl WHERE gr_id = :'grn_sb' \gset
SELECT pg_temp.sf_dispatch(:'sf_admin_claims'::jsonb, 'OFND1', :'lot_nb'::uuid, 4) AS disp_n \gset
SELECT pg_temp.sf_dispatch(:'sf_admin_claims'::jsonb, 'OFSD1', :'lot_sb'::uuid, 4) AS disp_s \gset
SELECT pg_temp.of_invoice(:'sf_admin_claims'::jsonb, 8001, :'disp_n'::uuid) AS inv_n \gset
SELECT pg_temp.of_invoice(:'sf_admin_claims'::jsonb, 8002, :'disp_s'::uuid) AS inv_s \gset
SELECT pg_temp.of_pay(:'sf_admin_claims'::jsonb, :'inv_n'::uuid, 1, 'orders-feed-pay-n1') AS pay_n1 \gset
SELECT pg_temp.of_pay(:'sf_admin_claims'::jsonb, :'inv_s'::uuid, 1, 'orders-feed-pay-s1') AS pay_s1 \gset
INSERT INTO public.payments(id, payment_no, payment_date, customer_id, customer_name, amount, invoice_id)
  VALUES (gen_random_uuid(), 'OLD-NOLINK-1', '2026-05-01T12:00:00Z', :'north', 'Order Feed North', 7, NULL) RETURNING id AS pay_nolink \gset

SELECT pg_temp.sf_phone('admin', :'sf_admin_claims'::jsonb);
SELECT pg_temp.sf_phone('supervisor', :'supervisor_claims'::jsonb);
SELECT pg_temp.sf_phone('staff', :'staff_claims'::jsonb);
SELECT pg_temp.sf_phone('c1', :'c1_claims'::jsonb);
SELECT pg_temp.sf_phone('c2', :'c2_claims'::jsonb);

-- ---------------------------------------------------------------------------------------------------------------------------------
-- B4. Format 8+: every role's start and copy key, a changes answer; a copy of the prior format is told to reload everything.
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT pg_temp.sf_first_load(p) FROM unnest(ARRAY['admin', 'supervisor', 'staff', 'c1', 'c2']) p;
SELECT pg_temp.sf_assert((SELECT count(*) = 5 AND bool_and((answer->>pg_temp.sf('f_format'))::int >= 8 AND split_part(answer->>pg_temp.sf('f_copy'), '.', 1) = answer->>pg_temp.sf('f_format'))
    FROM pg_temp.sf_answer WHERE kind = 'start'),
  'B4 / WH-381: get_sync_start answers format 8 or later and a copy key of that same format to every role: '
  || (SELECT string_agg(phone || ' ' || COALESCE(answer->>pg_temp.sf('f_format'), '(none)'), ', ') FROM pg_temp.sf_answer WHERE kind = 'start'));
SELECT pg_temp.sf_changes_once('admin') AS plain_changes \gset
SELECT pg_temp.sf_assert((:'plain_changes'::jsonb->>pg_temp.sf('f_format'))::int >= 8, 'B4 / WH-381: get_sync_changes answers format 8 or later: ' || left(:'plain_changes', 300));
SELECT (:'plain_changes'::jsonb->>pg_temp.sf('f_format'))::int - 1 AS older_format \gset
SELECT pg_temp.sf_changes_once('admin', NULL, regexp_replace(copy, '^[0-9]+\.', :'older_format' || '.')) AS old_copy FROM pg_temp.sf_device WHERE phone = 'admin' \gset
SELECT pg_temp.sf_assert(:'old_copy'::jsonb#>>ARRAY[pg_temp.sf('f_reload_all'), pg_temp.sf('f_reason')] = pg_temp.sf('r_format'),
  'B4: a copy key of the format before the current one answers reload_all FORMAT_CHANGED: ' || left(:'old_copy', 300));

-- ---------------------------------------------------------------------------------------------------------------------------------
-- B1 (WH-381). No role loads orders, order_items, payments or dispatch; staff-side roles still receive grn_lock.on_order for ordered lots.
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT pg_temp.sf_assert((SELECT bool_and(NOT (entities && ARRAY['orders', 'order_items'])) FROM pg_temp.sf_device WHERE phone IN ('admin', 'supervisor', 'staff', 'c1', 'c2')),
  'B1 / WH-381: no role loads orders or order_items');
SELECT pg_temp.sf_assert((SELECT bool_and(NOT (entities && ARRAY['payments', 'dispatch', 'dispatch_trl', 'invoice', 'invoice_trl'])) FROM pg_temp.sf_device WHERE phone IN ('admin', 'supervisor', 'staff', 'c1', 'c2')),
  'B1 / WH-381: no role loads payments, dispatch or invoice entities');
SELECT pg_temp.sf_assert(pg_temp.of_truth(p, CASE p WHEN 'c1' THEN :'north'::uuid WHEN 'c2' THEN :'south'::uuid END) = '',
  'B1 / WH-381: first load of ' || p || ': ' || pg_temp.of_truth(p, CASE p WHEN 'c1' THEN :'north'::uuid WHEN 'c2' THEN :'south'::uuid END))
  FROM unnest(ARRAY['admin', 'supervisor', 'staff', 'c1', 'c2']) p;
SELECT pg_temp.sf_assert(pg_temp.sf_held('c1', 'orders') = '{}' AND pg_temp.sf_held('c1', 'order_items') = '{}' AND pg_temp.sf_held('c1', 'payments') = '{}'
  AND pg_temp.sf_held('c2', 'orders') = '{}', 'B1 / WH-381: customer accounts hold zero orders, order_items or payments rows');
SELECT pg_temp.sf_assert(pg_temp.of_lock_on_order(p, :'grn_n'::uuid, :'lot_n1'::uuid) AND pg_temp.of_lock_on_order(p, :'grn_n'::uuid, :'lot_n2'::uuid)
  AND pg_temp.of_lock_on_order(p, :'grn_d'::uuid, :'lot_d1'::uuid),
  'B1 / WH-381: ' || p || ' still holds grn_lock on_order=true for ordered lots (including dormant customer)') FROM unnest(ARRAY['admin', 'supervisor', 'staff']) p;
SELECT pg_temp.sf_assert(NOT (:'ord_d' = ANY (pg_temp.sf_held(p, 'orders'))), 'B1 / WH-381: ' || p || ' does not hold dormant customer order') FROM unnest(ARRAY['c1', 'c2']) p;
SELECT pg_temp.sf_assert(NOT (:'pay_nolink' = ANY (pg_temp.sf_held(p, 'payments'))), 'B1 / WH-381: the payment without an invoice is sent to nobody (' || p || ')')
  FROM unnest(ARRAY['admin', 'supervisor', 'c1', 'c2']) p;
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM pg_temp.sf_entry WHERE phone = 'staff' AND e = 'payments')
  AND NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy WHERE slot = 'staff' AND e = 'payments'), 'B1: staff never receive a payments row');
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy WHERE slot = p AND e IN ('orders', 'order_items')),
  'B1 / WH-381: ' || p || ' holds zero orders or order_items rows') FROM unnest(ARRAY['admin', 'supervisor', 'staff']) p;
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy WHERE slot = p AND e IN ('payments', 'dispatch', 'dispatch_trl')),
  'B1 / WH-381: ' || p || ' holds zero payments or dispatch rows') FROM unnest(ARRAY['admin', 'supervisor', 'staff']) p;
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy WHERE slot = p AND e IN ('orders', 'order_items', 'payments', 'dispatch')),
  'B1 / WH-381: customer account ' || p || ' holds zero dropped-entity rows') FROM unnest(ARRAY['c1', 'c2']) p;
SELECT pg_temp.sf_assert(:'grn_n' = ANY (pg_temp.sf_held(p, 'goodsreceived')) AND :'lot_n1' = ANY (pg_temp.sf_held(p, 'goodsreceived_trl')),
  'B1 / WH-381: ' || p || ' still holds kept goodsreceived and goodsreceived_trl rows') FROM unnest(ARRAY['admin', 'staff']) p;
SELECT pg_temp.sf_assert(:'grn_n' = ANY (pg_temp.sf_held('c1', 'goodsreceived')) AND NOT (:'grn_s' = ANY (pg_temp.sf_held('c1', 'goodsreceived'))),
  'B1 / WH-381: c1 still holds only its own customer''s GRNs');
SELECT pg_temp.sf_assert(:'grn_s' = ANY (pg_temp.sf_held('c2', 'goodsreceived')) AND NOT (:'grn_n' = ANY (pg_temp.sf_held('c2', 'goodsreceived'))),
  'B1 / WH-381: c2 still holds only its own customer''s GRNs');

-- Order dispatch: updates lot stock and grn_lock without adding any dispatch row to the copy.
SELECT pg_temp.of_dispatch(:'sf_admin_claims'::jsonb, 'OFND2', :'lot_n1'::uuid, 2, :'ord_n'::uuid) AS disp_n2 \gset
SELECT pg_temp.of_step('B2 dispatch from an order', :'north'::uuid, :'south'::uuid);
SELECT pg_temp.sf_assert(NOT (:'disp_n2' = ANY (pg_temp.sf_held(p, 'dispatch')))
  AND (SELECT (c.row->>'stock')::int FROM pg_temp.sf_copy c WHERE c.slot = p AND c.e = 'goodsreceived_trl' AND c.id = :'lot_n1') = 18,
  'B1 / WH-381: ' || p || ' holds no dispatch row and has lot stock 18 after order dispatch') FROM unnest(ARRAY['admin', 'supervisor', 'staff']) p;
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy c WHERE c.slot = 'c1' AND c.e = 'dispatch'),
  'B1 / WH-381: a customer account holds no dispatch rows');
SELECT pg_temp.sf_assert(NOT (:'disp_n' = ANY (pg_temp.sf_held('admin', 'dispatch'))),
  'B1 / WH-381: a non-order dispatch is also absent from the copy');
SELECT pg_temp.sf_assert((SELECT requested_quantity FROM public.order_items WHERE id = :'line_n1') = 3, 'premise: the order dispatch lowered the line from 5 to 3');
SELECT pg_temp.sf_assert(pg_temp.sf_ops(p, 'order_items', :'line_n1', pg_temp.sf_last_pull(p)) = '' AND pg_temp.sf_ops(p, 'dispatch', :'disp_n2', pg_temp.sf_last_pull(p)) = '',
  'B2 / WH-381: after the order dispatch ' || p || ' receives zero order_items or dispatch entries') FROM unnest(ARRAY['admin', 'staff', 'c1']) p;

-- Profile rename: emits zero orders or dispatch entries; staff still receives people upsert.
UPDATE public.user_profiles SET name = 'Order Feed Renamed' WHERE mobile = '919888897001';
SELECT pg_temp.of_step('rename of a profile', :'north'::uuid, :'south'::uuid);
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM pg_temp.sf_entry WHERE phone = 'staff' AND pull = pg_temp.sf_last_pull('staff') AND e IN ('orders', 'dispatch'))
  AND EXISTS (SELECT 1 FROM pg_temp.sf_copy c WHERE c.slot = 'staff' AND c.e = 'people' AND c.row->>'name' = 'Order Feed Renamed'),
  'B2 / WH-381: profile rename updates staff people without emitting orders or dispatch entries');
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy c WHERE c.slot = 'staff' AND c.e = 'dispatch'),
  'B2 / WH-381: staff holds zero dispatch rows after profile rename');
UPDATE public.user_profiles SET name = 'Sync Feed Administrator' WHERE mobile = '919888897001';
SELECT pg_temp.of_step('rename back', :'north'::uuid, :'south'::uuid);

-- ---------------------------------------------------------------------------------------------------------------------------------
-- B2 (WH-381). Write paths: zero orders/order_items/payments/dispatch entries, while grn_lock, stock and money marks stay intact.
-- ---------------------------------------------------------------------------------------------------------------------------------
-- add_item_to_order into an existing order.
SELECT pg_temp.of_add(:'sf_admin_claims'::jsonb, :'ord_s'::uuid, :'lot_s2'::uuid, 2) AS line_s2 \gset
SELECT pg_temp.of_step('B2 add_item_to_order', :'north'::uuid, :'south'::uuid);
SELECT pg_temp.sf_assert(pg_temp.sf_ops(p, 'order_items', :'line_s2', pg_temp.sf_last_pull(p)) = '' AND pg_temp.sf_ops(p, 'orders', :'ord_s', pg_temp.sf_last_pull(p)) = '',
  'B2 / WH-381: ' || p || ' got zero order_items/orders entries on add_item_to_order') FROM unnest(ARRAY['admin', 'supervisor', 'staff', 'c2']) p;
SELECT pg_temp.sf_assert(pg_temp.of_lock_on_order('staff', :'grn_s'::uuid, :'lot_s2'::uuid) AND pg_temp.sf_ops('c1', 'order_items', :'line_s2', pg_temp.sf_last_pull('c1')) = '',
  'B2 / WH-381: staff grn_lock reflects on_order=true for lot_s2 and c1 got nothing');
-- add_item_to_order without an order (the customer's cart is made): Fresh.
SELECT pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.add_item_to_order(p_grn_item_id => %L::uuid, p_quantity => 2, p_customer_id => %L::uuid)', :'lot_f1', :'fresh'))->>'success' AS made \gset
SELECT pg_temp.sf_assert(:'made' = 'true', 'fixture: add_item_to_order without an order');
SELECT id AS ord_f FROM public.orders WHERE customer_id = :'fresh' \gset
SELECT pg_temp.of_step('B2 add_item_to_order creating the order', :'north'::uuid, :'south'::uuid);
SELECT pg_temp.sf_assert(pg_temp.sf_ops(p, 'orders', :'ord_f', pg_temp.sf_last_pull(p)) = '' AND pg_temp.of_lock_on_order(p, :'grn_f'::uuid, :'lot_f1'::uuid),
  'B2 / WH-381: ' || p || ' got no orders row and holds grn_lock on_order=true for Fresh') FROM unnest(ARRAY['admin', 'supervisor', 'staff']) p;
-- update_order_item_quantity.
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.update_order_item_quantity(%L::uuid, 9)', :'line_n1'))->>'success' = 'true', 'update_order_item_quantity');
SELECT pg_temp.of_step('B2 update_order_item_quantity', :'north'::uuid, :'south'::uuid);
SELECT pg_temp.sf_assert(pg_temp.sf_ops(p, 'order_items', :'line_n1', pg_temp.sf_last_pull(p)) = '',
  'B2 / WH-381: ' || p || ' got zero order_items entries on update_order_item_quantity') FROM unnest(ARRAY['admin', 'staff', 'c1']) p;
-- remove_item_from_order: clears grn_lock on_order for lot_n2; emits zero order_items entries.
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.remove_item_from_order(%L::uuid)', :'line_n2'))->>'success' = 'true', 'remove_item_from_order');
SELECT pg_temp.of_step('B2 remove_item_from_order', :'north'::uuid, :'south'::uuid);
SELECT pg_temp.sf_assert(pg_temp.sf_ops(p, 'order_items', :'line_n2', pg_temp.sf_last_pull(p)) = '' AND NOT (:'line_n2' = ANY (pg_temp.sf_held(p, 'order_items')))
  AND (p = 'c1' OR NOT pg_temp.of_lock_on_order(p, :'grn_n'::uuid, :'lot_n2'::uuid)),
  'B2 / WH-381: ' || p || ' got zero order_items entries and grn_lock cleared on_order for lot_n2') FROM unnest(ARRAY['admin', 'supervisor', 'staff', 'c1']) p;
-- get_or_create_cart reuse changes nothing and logs nothing visible.
SELECT pg_temp.sf_assert(pg_temp.of_cart(:'sf_admin_claims'::jsonb, :'north'::uuid) = :'ord_n'::uuid, 'premise: the cart is reused');
SELECT pg_temp.of_step('B2 get_or_create_cart reuse', :'north'::uuid, :'south'::uuid);
-- delete_dispatch_with_order_cleanup of the order dispatch: lot stock returns to 20, zero dispatch/order_items entries.
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.delete_dispatch_with_order_cleanup(%L::uuid, %L::uuid)', :'disp_n2', :'sf_admin_profile'))->>'success' = 'true',
  'delete_dispatch_with_order_cleanup');
SELECT pg_temp.of_step('B2 delete_dispatch_with_order_cleanup', :'north'::uuid, :'south'::uuid);
SELECT pg_temp.sf_assert(pg_temp.sf_ops(p, 'dispatch', :'disp_n2', pg_temp.sf_last_pull(p)) = '', 'B2 / WH-381: ' || p || ' got zero dispatch entries on delete')
  FROM unnest(ARRAY['admin', 'staff', 'c1']) p;
SELECT pg_temp.sf_assert((SELECT (c.row->>'stock')::int FROM pg_temp.sf_copy c WHERE c.slot = p AND c.e = 'goodsreceived_trl' AND c.id = :'lot_n1') = 20,
  'B2 / WH-381: ' || p || ' holds restored lot stock 20 after order dispatch delete') FROM unnest(ARRAY['admin', 'staff', 'c1']) p;

-- Payments: record, update, imported, null-invoice, delete — ZERO payments/invoice entries, money marks STILL delivered to admin/supervisor/c1.
SELECT pg_temp.of_pay(:'sf_admin_claims'::jsonb, :'inv_n'::uuid, 1, 'orders-feed-pay-n2') AS pay_n2 \gset
SELECT pg_temp.of_step('B2 record_payment', :'north'::uuid, :'south'::uuid);
SELECT pg_temp.sf_assert(pg_temp.sf_ops(p, 'payments', :'pay_n2', pg_temp.sf_last_pull(p)) = '' AND pg_temp.of_marks(p) = ARRAY[:'north'],
  'B2 / WH-381: ' || p || ' got zero payments entries and received North money mark on record_payment')
  FROM unnest(ARRAY['admin', 'supervisor', 'c1']) p;
SELECT pg_temp.sf_assert(pg_temp.sf_ops(p, 'payments', :'pay_n2', pg_temp.sf_last_pull(p)) = '' AND pg_temp.of_marks(p) = '{}',
  'B2 / WH-381: ' || p || ' got neither payments entries nor North money mark')
  FROM unnest(ARRAY['staff', 'c2']) p;
SELECT updated_at AS pay_n2_version FROM public.payments WHERE id = :'pay_n2' \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.update_payment(%L::uuid, DATE %L, 2, %L, %L::timestamptz)', :'pay_n2', '2026-06-03', 'cash', :'pay_n2_version'))->>'success' = 'true', 'update_payment');
SELECT pg_temp.of_step('B2 update_payment', :'north'::uuid, :'south'::uuid);
SELECT pg_temp.sf_assert(pg_temp.sf_ops(p, 'payments', :'pay_n2', pg_temp.sf_last_pull(p)) = '' AND pg_temp.of_marks(p) = ARRAY[:'north'],
  'B2 / WH-381: ' || p || ' got zero payments entries and North money mark on update_payment') FROM unnest(ARRAY['admin', 'c1']) p;
INSERT INTO public.payments(id, payment_no, payment_date, customer_id, customer_name, amount, invoice_id)
  VALUES (gen_random_uuid(), 'OLD-IMPORT-1', '2026-05-02T12:00:00Z', :'north', 'Order Feed North', 1, :'inv_n'::uuid) RETURNING id AS pay_imp \gset
SELECT pg_temp.of_step('B2 imported payment', :'north'::uuid, :'south'::uuid);
SELECT pg_temp.sf_assert(pg_temp.sf_ops(p, 'payments', :'pay_imp', pg_temp.sf_last_pull(p)) = '' AND pg_temp.of_marks(p) = ARRAY[:'north'],
  'B2 / WH-381: ' || p || ' got zero payments entries and North money mark on imported payment') FROM unnest(ARRAY['admin', 'c1']) p;
UPDATE public.payments SET invoice_id = NULL WHERE id = :'pay_imp';
SELECT pg_temp.of_step('B2 payment loses its invoice', :'north'::uuid, :'south'::uuid);
SELECT pg_temp.sf_assert(pg_temp.sf_ops(p, 'payments', :'pay_imp', pg_temp.sf_last_pull(p)) = '' AND NOT (:'pay_imp' = ANY (pg_temp.sf_held(p, 'payments'))),
  'B2 / WH-381: ' || p || ' got zero payments entries when payment lost its invoice') FROM unnest(ARRAY['admin', 'supervisor', 'c1']) p;
SELECT updated_at AS pay_n2_version2 FROM public.payments WHERE id = :'pay_n2' \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.delete_payment(%L::uuid, %L::timestamptz)', :'pay_n2', :'pay_n2_version2'))->>'success' = 'true', 'delete_payment');
SELECT pg_temp.of_step('B2 delete_payment', :'north'::uuid, :'south'::uuid);
SELECT pg_temp.sf_assert(pg_temp.sf_ops(p, 'payments', :'pay_n2', pg_temp.sf_last_pull(p)) = '' AND pg_temp.of_marks(p) = ARRAY[:'north'],
  'B2 / WH-381: ' || p || ' got zero payments entries and North money mark on delete_payment')
  FROM unnest(ARRAY['admin', 'supervisor', 'c1']) p;

-- ---------------------------------------------------------------------------------------------------------------------------------
-- B3 (WH-381). Moving an order between customers emits zero orders/order_items entries for any account.
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_customer(''Order Feed Parked'', ''9888897525'')')->>'success' = 'true', 'customer for South''s order to step aside to');
SELECT id AS parked FROM public.customers WHERE name = 'Order Feed Parked' \gset
UPDATE public.orders SET customer_id = :'parked', customer_name = 'Order Feed Parked' WHERE id = :'ord_s';
UPDATE public.orders SET customer_id = :'south', customer_name = 'Order Feed South' WHERE id = :'ord_n';
SELECT pg_temp.of_step('B3 order moved to South', :'north'::uuid, :'south'::uuid);
SELECT pg_temp.sf_assert(pg_temp.sf_ops('c1', 'orders', :'ord_n', pg_temp.sf_last_pull('c1')) = '' AND pg_temp.sf_ops('c1', 'order_items', :'line_n1', pg_temp.sf_last_pull('c1')) = ''
  AND NOT (:'ord_n' = ANY (pg_temp.sf_held('c1', 'orders'))) AND NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy c WHERE c.slot = 'c1' AND c.e = 'order_items'),
  'B3 / WH-381: North''s account got zero orders/order_items entries on move');
SELECT pg_temp.sf_assert(NOT (:'ord_n' = ANY (pg_temp.sf_held('c2', 'orders'))) AND NOT (:'line_n1' = ANY (pg_temp.sf_held('c2', 'order_items'))),
  'B3 / WH-381: South''s account holds neither moved order nor its line');
UPDATE public.orders SET customer_id = :'north', customer_name = 'Order Feed North' WHERE id = :'ord_n';
UPDATE public.orders SET customer_id = :'south', customer_name = 'Order Feed South' WHERE id = :'ord_s';
SELECT pg_temp.of_step('B3 order moved back', :'north'::uuid, :'south'::uuid);

-- ---------------------------------------------------------------------------------------------------------------------------------
-- Deletes (WH-381): soft-deleted and hard-deleted orders emit zero orders entries while clearing grn_lock.on_order.
-- ---------------------------------------------------------------------------------------------------------------------------------
UPDATE public.orders SET deleted_at = now() WHERE id = :'ord_s';
SELECT pg_temp.of_step('soft-deleted order', :'north'::uuid, :'south'::uuid);
SELECT pg_temp.sf_assert(pg_temp.sf_ops(p, 'orders', :'ord_s', pg_temp.sf_last_pull(p)) = ''
  AND NOT pg_temp.of_lock_on_order(p, :'grn_s'::uuid, :'lot_s1'::uuid),
  'soft delete / WH-381: ' || p || ' got zero orders entries and grn_lock cleared on_order') FROM unnest(ARRAY['admin', 'supervisor', 'staff']) p;
SELECT pg_temp.sf_assert(pg_temp.sf_ops('c2', 'orders', :'ord_s', pg_temp.sf_last_pull('c2')) = '' AND NOT (:'ord_s' = ANY (pg_temp.sf_held('c2', 'orders'))),
  'soft delete / WH-381: South''s account got zero orders entries');
DELETE FROM public.order_items WHERE order_id = :'ord_f';
DELETE FROM public.orders WHERE id = :'ord_f';
SELECT pg_temp.of_step('hard-deleted order', :'north'::uuid, :'south'::uuid);
SELECT pg_temp.sf_assert(pg_temp.sf_ops(p, 'orders', :'ord_f', pg_temp.sf_last_pull(p)) = ''
  AND NOT pg_temp.of_lock_on_order(p, :'grn_f'::uuid, :'lot_f1'::uuid),
  'hard delete / WH-381: ' || p || ' got zero orders entries and grn_lock cleared on_order') FROM unnest(ARRAY['admin', 'supervisor', 'staff']) p;

-- ---------------------------------------------------------------------------------------------------------------------------------
-- B5. "Stable order reads": one answer per call. Two dispatches of one order with the same created_at: the lower id is named, in
-- both calls; with a later created_at the later one is named (Product PQ5: the latest). Lines with equal sort_order and created_at
-- come in id order.
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT pg_temp.of_cart(:'sf_admin_claims'::jsonb, :'fresh'::uuid) AS ord_t \gset
SELECT pg_temp.of_add(:'sf_admin_claims'::jsonb, :'ord_t'::uuid, :'lot_f1'::uuid, 1) AS line_t1 \gset
-- set_audit_columns (trigger_dispatch_audit) sets created_at to now() on insert and keeps it on update, so the fixture's own created_at
-- values only stand with that trigger off for the two statements that write them.
ALTER TABLE public.dispatch DISABLE TRIGGER trigger_dispatch_audit;
INSERT INTO public.dispatch(id, disp_no, disp_date, customer_id, customer_name, source_order_id, created_at) VALUES
  ('00000000-0000-4000-8000-0000000000b2', 'OFT-B', '2026-06-01', :'fresh', 'Order Feed Fresh', :'ord_t', '2026-06-01 10:00:00+00'),
  ('00000000-0000-4000-8000-0000000000b1', 'OFT-A', '2026-06-01', :'fresh', 'Order Feed Fresh', :'ord_t', '2026-06-01 10:00:00+00');
SELECT pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.get_order_with_items(%L::uuid)', :'ord_t')) AS read1 \gset
SELECT pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.get_order_with_items(%L::uuid)', :'ord_t')) AS read2 \gset
SELECT pg_temp.sf_assert(:'read1'::jsonb = :'read2'::jsonb AND :'read1'::jsonb#>>'{data,order_data,dispatch_id}' = '00000000-0000-4000-8000-0000000000b1',
  'B5: with tied created_at the order read names the dispatch with the lowest id, in both calls: ' || (:'read1'::jsonb#>>'{data,order_data,dispatch_id}'));
UPDATE public.dispatch SET created_at = '2026-06-02 10:00:00+00' WHERE id = '00000000-0000-4000-8000-0000000000b2';
ALTER TABLE public.dispatch ENABLE TRIGGER trigger_dispatch_audit;
SELECT pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.get_order_with_items(%L::uuid)', :'ord_t')) AS read3 \gset
SELECT pg_temp.sf_assert(:'read3'::jsonb#>>'{data,order_data,dispatch_id}' = '00000000-0000-4000-8000-0000000000b2',
  'B5 / PQ5: the order read names the latest dispatch: ' || (:'read3'::jsonb#>>'{data,order_data,dispatch_id}'));
SELECT pg_temp.of_add(:'sf_admin_claims'::jsonb, :'ord_n'::uuid, :'lot_n2'::uuid, 3) AS line_n2b \gset
SELECT pg_temp.of_add(:'sf_admin_claims'::jsonb, :'ord_n'::uuid, :'lot_n4'::uuid, 1) AS line_n4 \gset
UPDATE public.order_items SET sort_order = 0, created_at = '2026-06-01 09:00:00+00' WHERE order_id = :'ord_n';
SELECT pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.get_order_with_items(%L::uuid)', :'ord_n')) AS read_lines \gset
SELECT pg_temp.sf_assert((SELECT COALESCE(array_agg(i->>'id' ORDER BY n), '{}') = COALESCE(array_agg(i->>'id' ORDER BY i->>'id'), '{}')
    FROM jsonb_array_elements(:'read_lines'::jsonb#>'{data,items}') WITH ORDINALITY t(i, n)),
  'B5: lines with equal sort_order and created_at come in id order');

SELECT pg_temp.of_step('end', :'north'::uuid, :'south'::uuid);

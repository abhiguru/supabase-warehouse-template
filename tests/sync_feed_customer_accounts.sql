-- WH-306, backend slice (test-first, nothing built): the customer account's offline copy. Cases B0 to B9 of
-- ~/ws/fresh/product/tech/app-offline-customer-accounts.md (section 11), with Product's PQ1-PQ7 and Design's DQ1-DQ9 of the card, and
-- the server side of the parity cases R1-R12 (the readers of section 3, called as a customer account). Backend topics by name:
-- "customer account reads match its copy", "money marks reach customer accounts"; no migration number is used here.
-- tests/migrations.sh pipes tests/fixtures/gst_details.sql and tests/sync_feed_contract.sql in front of this file, in the sync feed
-- database of its own; this file commits. Fictional data only.
--
-- What this file adds to the suites that already run as a customer account (sync_feed_deletes_scope.sql: rows, hidden columns, moved and
-- soft-deleted documents, ACCESS_CHANGED on a lost assignment; sync_feed_orders_payments.sql: orders and payments): an account with
-- several customers, the key inventory of the reads (B0, B7), the entity list and the "never" list as one exact statement (B1), the
-- format step, role change and assignment added (B4), checksums (B5), marks incl. 'all' (B6), a deactivated and a deleted customer
-- (B8, PQ4) and a time bound on a small set (B9).
--
-- AGREE WITH DEVELOPMENT (WH-306), the guesses of this file. All are in the block below or marked here:
--   1. Format step: the number of the feed after this set. WH-304 and WH-305 also claim 4 (WH-305's brief says 5 once WH-304 is built
--      first), so the number is cc_format below and nowhere else. If Development finds in B0 that no feed change is needed (contract 9,
--      topic 3), this value is the format at assembly and the format assertions only repeat the set's.
--   2. The key inventory (B0/B7): every key that a row of a customer read answers must be a key of some row of the account's own copy,
--      or be listed in cc_renamed (a key the reader renames from a copy column, R1) or cc_computed (a key the phone works out). This
--      file lists the keys it knows (cc_renamed, cc_computed); a key Development must add to either list needs a stated derivation.
--      The failure message names read and key: it is the inventory B0 asks for. Reads without a flat row list (the reports of R9) and
--      the two kept answers (R10, R11) are checked for forbidden keys only; their key inventory waits for Development's B0.
--   3. Product PQ3: a read answers a customer account no staff field beyond supervisor_name and sender_name (cc_forbidden). A read that
--      does is a bug card for Product; the test stays failing until the read loses the field.
--   4. Product PQ4: a deactivated customer's goods stay in the account's copy; a deleted customer's rows (the customer and its GRNs,
--      dispatches, invoices) leave it. Today the feed keeps a deleted customer's live documents (scope is the assignment): if so the
--      B8 assertion "a deleted customer's documents leave the copy" fails and names the product gap.
--   5. An account whose profile is deactivated is refused by the feed calls (not a success answer); the exact refusal is not asserted.
-- Cases NOT covered here: the large set of B9 (60,000 GRNs, on demand by Test), the reports' key inventory (see 2), the reader output
-- equal to the golden answer (app-side, R1-R14 of Jest), photos (grn_images need Storage objects: sync_feed_deletes_scope.sql).
\set ON_ERROR_STOP on

-- =================================================================================================================================
-- AGREE WITH DEVELOPMENT (WH-306): the names this file takes from the build.
-- =================================================================================================================================
CREATE TEMP TABLE cc_contract(k text PRIMARY KEY, v text NOT NULL);
INSERT INTO pg_temp.cc_contract(k, v) VALUES
  ('cc_format', '4'),    -- see 1 above
  -- Contract section 0: what a customer account's copy holds, as a set.
  ('entities', 'customers,items,goodsreceived,goodsreceived_trl,grn_images,dispatch,dispatch_trl,dispatch_images,invoice,invoice_trl,orders,order_items,payments,grn_rates'),
  -- Contract section 0 and decision O5: never in a customer account's copy (entity names; the three rate entities are the staff ones).
  ('never', 'settings,people,grn_lock,user_profiles,users_customers_new,item_storage_prices,standard_rate_tiers,item_price_history,grn_replacements'),
  -- Keys no customer read may answer (the Q1 columns, plus the staff fields PQ3 forbids). supervisor_name and sender_name are allowed.
  ('forbidden', 'created_by,updated_by,deleted_by,supervisor_id,sender_id,import_batch_id,uploaded_by,created_by_name,updated_by_name,updated_by_display_name,user_access'),
  -- Keys a reader renames from a copy column, and keys the phone works out (see 2 above).
  ('cc_renamed', 'grn_item_id,grns_id,grns_gr_no,grns_date,grn_id'),
  ('cc_computed', 'image_url'),
  ('stale_entry', 'money');
-- Reads whose answer rows are checked against the copy's keys (B0/B7): label = function name, as cc_read is called.
CREATE TEMP TABLE cc_row_reads(label text PRIMARY KEY);
INSERT INTO pg_temp.cc_row_reads VALUES ('get_customer_grn_items'), ('get_customer_dispatch_list'), ('get_grn_details'), ('get_dispatch_details'),
  ('get_grn_item_dispatches'), ('get_orders_list'), ('get_order_with_items'), ('get_customer_invoice_summary'), ('get_invoice_data'),
  ('get_invoice_detail'), ('get_invoice_items_detailed');

CREATE FUNCTION pg_temp.cc(key text) RETURNS text LANGUAGE sql STABLE AS $$ SELECT v FROM pg_temp.cc_contract WHERE k = key $$;
CREATE FUNCTION pg_temp.cc_list(key text) RETURNS text[] LANGUAGE sql STABLE AS $$ SELECT string_to_array(pg_temp.cc(key), ',') $$;
CREATE FUNCTION pg_temp.cc_sorted(a text[]) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT array_to_string(ARRAY(SELECT DISTINCT x FROM unnest(a) x ORDER BY x), ',') $$;

-- The key names of an answer. only_rows: only keys of objects inside a list (the rows), at any depth below.
CREATE FUNCTION pg_temp.cc_keys(j jsonb, only_rows boolean, in_row boolean DEFAULT false) RETURNS SETOF text LANGUAGE plpgsql AS $$
DECLARE k text; v jsonb; e jsonb;
BEGIN
  IF jsonb_typeof(j) = 'object' THEN
    FOR k, v IN SELECT * FROM jsonb_each(j) LOOP
      IF in_row OR NOT only_rows THEN RETURN NEXT k; END IF;
      RETURN QUERY SELECT * FROM pg_temp.cc_keys(v, only_rows, in_row);
    END LOOP;
  ELSIF jsonb_typeof(j) = 'array' THEN
    FOR e IN SELECT * FROM jsonb_array_elements(j) LOOP
      RETURN QUERY SELECT * FROM pg_temp.cc_keys(e, only_rows, true);
    END LOOP;
  END IF;
END $$;

-- Every read of a customer account is kept here: who, which function, the answer.
CREATE TEMP TABLE cc_answer(seq bigserial PRIMARY KEY, who text, label text, answer jsonb);
CREATE FUNCTION pg_temp.cc_read(p text, label text, stmt text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE d record; ans jsonb;
BEGIN
  SELECT * INTO d FROM pg_temp.sf_device WHERE phone = p;
  ans := pg_temp.sf_as(d.claims, stmt);
  PERFORM pg_temp.sf_assert(ans->>'success' = 'true', format('premise: %s as %s answered a success: %s', label, p, left(COALESCE(ans::text, 'NULL'), 300)));
  INSERT INTO pg_temp.cc_answer(who, label, answer) VALUES (p, label, ans);
END $$;
-- The ids found under a key in an answer (any depth).
CREATE FUNCTION pg_temp.cc_ids(j jsonb, k text) RETURNS text[] LANGUAGE sql STABLE AS $$
  SELECT COALESCE(array_agg(DISTINCT x ORDER BY x), '{}') FROM jsonb_path_query(j, ('lax $.**.' || k)::jsonpath) v, LATERAL (SELECT v #>> '{}' AS x) t(x)
  WHERE jsonb_typeof(v) = 'string' $$;
-- The key names of every row of a phone's copy (one list), and the rows of one entity of one customer.
CREATE FUNCTION pg_temp.cc_copy_keys(p text) RETURNS text[] LANGUAGE sql STABLE AS $$
  SELECT COALESCE(array_agg(DISTINCT k), '{}') FROM pg_temp.sf_copy c, jsonb_object_keys(c.row) k WHERE c.slot = p $$;
CREATE FUNCTION pg_temp.cc_copy_ids(p text, ent text, cust uuid) RETURNS text[] LANGUAGE sql STABLE AS $$
  SELECT COALESCE(array_agg(c.id ORDER BY c.id), '{}') FROM pg_temp.sf_copy c WHERE c.slot = p AND c.e = ent AND c.row->>'customer_id' = cust::text $$;
CREATE FUNCTION pg_temp.cc_lot_ids(p text, cust uuid) RETURNS text[] LANGUAGE sql STABLE AS $$
  SELECT COALESCE(array_agg(t.id ORDER BY t.id), '{}') FROM pg_temp.sf_copy t JOIN pg_temp.sf_copy g ON g.slot = p AND g.e = 'goodsreceived' AND g.id = t.row->>'gr_id'
  WHERE t.slot = p AND t.e = 'goodsreceived_trl' AND g.row->>'customer_id' = cust::text $$;
-- The money marks a phone met in its last pull, sorted and distinct.
CREATE FUNCTION pg_temp.cc_marks(p text) RETURNS text[] LANGUAGE sql STABLE AS $$
  SELECT COALESCE(array_agg(d ORDER BY d), '{}') FROM (SELECT DISTINCT detail AS d FROM pg_temp.sf_event
    WHERE phone = p AND kind = 'stale' AND pull = pg_temp.sf_last_pull(p)) t $$;
-- One step: every phone pulls and equals a fresh load of itself.
CREATE FUNCTION pg_temp.cc_step(step text, phones text[]) RETURNS void LANGUAGE plpgsql AS $$
DECLARE p text; bad text;
BEGIN
  FOREACH p IN ARRAY phones LOOP
    PERFORM pg_temp.sf_pull(p);
    bad := pg_temp.sf_diff(p);
    PERFORM pg_temp.sf_assert(bad = '', format('%s: the copy of %s differs from a fresh load: %s', step, p, bad));
  END LOOP;
END $$;

-- Fixtures through today's RPCs (the helpers the orders suite uses, under this suite's names).
CREATE FUNCTION pg_temp.cc_cart(claims jsonb, cust uuid) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  r := pg_temp.sf_as(claims, format('SELECT to_jsonb(public.get_or_create_cart(%L::uuid))', cust));
  PERFORM pg_temp.sf_assert(r IS NOT NULL AND jsonb_typeof(r) = 'string', 'fixture: cart: ' || COALESCE(r::text, 'NULL'));
  RETURN (r #>> '{}')::uuid;
END $$;
CREATE FUNCTION pg_temp.cc_add(claims jsonb, ord uuid, lot uuid, qty int) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  r := pg_temp.sf_as(claims, format('SELECT public.add_item_to_order(%L::uuid, %L::uuid, %s)', ord, lot, qty));
  PERFORM pg_temp.sf_assert(r->>'success' = 'true', 'fixture: add_item_to_order: ' || left(r::text, 300));
  RETURN (SELECT id FROM public.order_items WHERE order_id = ord AND grn_items_id = lot);
END $$;
CREATE FUNCTION pg_temp.cc_invoice(claims jsonb, bill int, disp uuid) RETURNS uuid LANGUAGE plpgsql AS $$
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
CREATE FUNCTION pg_temp.cc_pay(claims jsonb, inv uuid, amount numeric, req text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  r := pg_temp.sf_as(claims, format('SELECT public.record_payment(%L::uuid, DATE %L, %s, %L, NULL, %L)', inv, '2026-06-03', amount, 'cash', req));
  PERFORM pg_temp.sf_assert(r->>'success' = 'true', 'fixture: record_payment: ' || left(r::text, 300));
  RETURN (r#>>'{payment,id}')::uuid;
END $$;

-- ---------------------------------------------------------------------------------------------------------------------------------
-- Fixture. Phones: admin; c1 (account of North only); c2 (account of South only); c3 (account of North, South and West: three customers).
-- Documents: North CCN1 (two lots), CCN2 (one lot, dispatched in full, billed, paid), CCN3 (second dispatch, for the order);
-- South CCS1; West CCW1 (two lots, one dispatched), CCW2. One order each for North and South.
-- ---------------------------------------------------------------------------------------------------------------------------------
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888897301', 'Customer Copy North Reader', 'customer', true, 'approved'),
 (gen_random_uuid(), '919888897302', 'Customer Copy South Reader', 'customer', true, 'approved'),
 (gen_random_uuid(), '919888897303', 'Customer Copy Three Reader', 'customer', true, 'approved');
SELECT pg_temp.sf_login('9888897301') AS c1_claims \gset
SELECT pg_temp.sf_login('9888897302') AS c2_claims \gset
SELECT pg_temp.sf_login('9888897303') AS c3_claims \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_customer(''Customer Copy North'', ''9888897321'')')->>'success' = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_customer(''Customer Copy South'', ''9888897322'')')->>'success' = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_customer(''Customer Copy West'', ''9888897323'')')->>'success' = 'true', 'customers');
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_item(''Customer Copy Garlic'', ''Bag'')')->>'success' = 'true', 'item');
SELECT id AS north FROM public.customers WHERE name = 'Customer Copy North' \gset
SELECT id AS south FROM public.customers WHERE name = 'Customer Copy South' \gset
SELECT id AS west FROM public.customers WHERE name = 'Customer Copy West' \gset
SELECT id AS garlic FROM public.items WHERE name = 'Customer Copy Garlic' \gset
SELECT pg_temp.sf_assert(
  pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT to_jsonb(public.assign_customer_to_user(%L, %L::uuid, %L))', '919888897301', :'north', 'Customer copy fixture'))::text = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT to_jsonb(public.assign_customer_to_user(%L, %L::uuid, %L))', '919888897302', :'south', 'Customer copy fixture'))::text = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT to_jsonb(public.assign_customer_to_user(%L, %L::uuid, %L))', '919888897303', :'north', 'Customer copy fixture'))::text = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT to_jsonb(public.assign_customer_to_user(%L, %L::uuid, %L))', '919888897303', :'south', 'Customer copy fixture'))::text = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT to_jsonb(public.assign_customer_to_user(%L, %L::uuid, %L))', '919888897303', :'west', 'Customer copy fixture'))::text = 'true',
  'customer accounts assigned');
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.replace_item_rates(%L::uuid, %L::uuid, %L, %L::date, %L::jsonb)', :'garlic', c, 'monthly', '2026-01-01',
  '[{"weight_min":0,"weight_max":100,"unit_price":5,"labour_rate":2,"tax_percent":5}]'))->>'success' = 'true', 'rate for ' || c)
  FROM unnest(ARRAY[:'north', :'south', :'west']) c;
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.set_record_payments(true)')->>'success' = 'true', 'payments on');

SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'CCN1', :'north'::uuid, pg_temp.sf_lines(:'garlic'::uuid, 2, 'CN', 20)) AS grn_n1 \gset
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'CCN2', :'north'::uuid, pg_temp.sf_lines(:'garlic'::uuid, 1, 'CM', 4)) AS grn_n2 \gset
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'CCN3', :'north'::uuid, pg_temp.sf_lines(:'garlic'::uuid, 1, 'CK', 20)) AS grn_n3 \gset
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'CCS1', :'south'::uuid, pg_temp.sf_lines(:'garlic'::uuid, 2, 'CS', 20)) AS grn_s1 \gset
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'CCW1', :'west'::uuid, pg_temp.sf_lines(:'garlic'::uuid, 2, 'CW', 20)) AS grn_w1 \gset
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'CCW2', :'west'::uuid, pg_temp.sf_lines(:'garlic'::uuid, 1, 'CV', 20)) AS grn_w2 \gset
SELECT id AS lot_n1a FROM public.goodsreceived_trl WHERE gr_id = :'grn_n1' AND package_mark = 'CN1' \gset
SELECT id AS lot_n2 FROM public.goodsreceived_trl WHERE gr_id = :'grn_n2' \gset
SELECT id AS lot_n3 FROM public.goodsreceived_trl WHERE gr_id = :'grn_n3' \gset
SELECT id AS lot_s1a FROM public.goodsreceived_trl WHERE gr_id = :'grn_s1' AND package_mark = 'CS1' \gset
SELECT id AS lot_w1a FROM public.goodsreceived_trl WHERE gr_id = :'grn_w1' AND package_mark = 'CW1' \gset
SELECT pg_temp.sf_dispatch(:'sf_admin_claims'::jsonb, 'CCND1', :'lot_n2'::uuid, 4) AS disp_n1 \gset
SELECT pg_temp.sf_dispatch(:'sf_admin_claims'::jsonb, 'CCND2', :'lot_n3'::uuid, 5) AS disp_n2 \gset
SELECT pg_temp.sf_dispatch(:'sf_admin_claims'::jsonb, 'CCWD1', :'lot_w1a'::uuid, 3) AS disp_w1 \gset
SELECT pg_temp.cc_invoice(:'sf_admin_claims'::jsonb, 8301, :'disp_n1'::uuid) AS inv_n \gset
SELECT pg_temp.cc_pay(:'sf_admin_claims'::jsonb, :'inv_n'::uuid, 1, 'cust-copy-pay-n1') AS pay_n \gset
SELECT pg_temp.cc_cart(:'sf_admin_claims'::jsonb, :'north'::uuid) AS ord_n \gset
SELECT pg_temp.cc_cart(:'sf_admin_claims'::jsonb, :'south'::uuid) AS ord_s \gset
SELECT pg_temp.cc_add(:'sf_admin_claims'::jsonb, :'ord_n'::uuid, :'lot_n1a'::uuid, 5) AS line_n \gset
SELECT pg_temp.cc_add(:'sf_admin_claims'::jsonb, :'ord_s'::uuid, :'lot_s1a'::uuid, 4) AS line_s \gset

SELECT pg_temp.sf_phone('admin', :'sf_admin_claims'::jsonb);
SELECT pg_temp.sf_phone('c1', :'c1_claims'::jsonb);
SELECT pg_temp.sf_phone('c2', :'c2_claims'::jsonb);
SELECT pg_temp.sf_phone('c3', :'c3_claims'::jsonb);
SELECT clock_timestamp() AS t_load0 \gset
SELECT pg_temp.sf_first_load(p) FROM unnest(ARRAY['admin', 'c1', 'c2', 'c3']) p;
SELECT clock_timestamp() AS t_load1 \gset

-- ---------------------------------------------------------------------------------------------------------------------------------
-- Format step. Every customer account's start and copy key carry the agreed format; a copy of the format before it is told to reload.
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT pg_temp.sf_assert((SELECT count(*) = 3 AND bool_and(answer->>pg_temp.sf('f_format') = pg_temp.cc('cc_format') AND answer->>pg_temp.sf('f_copy') LIKE pg_temp.cc('cc_format') || '.%')
    FROM pg_temp.sf_answer WHERE kind = 'start' AND phone IN ('c1', 'c2', 'c3')),
  'format: get_sync_start answers format ' || pg_temp.cc('cc_format') || ' and a copy key of it to every customer account: '
  || (SELECT string_agg(phone || ' ' || COALESCE(answer->>pg_temp.sf('f_format'), '(none)'), ', ') FROM pg_temp.sf_answer WHERE kind = 'start' AND phone IN ('c1', 'c2', 'c3')));
SELECT pg_temp.sf_changes_once('c3', NULL, regexp_replace(copy, '^[0-9]+\.', (pg_temp.cc('cc_format')::int - 1)::text || '.')) AS old_copy FROM pg_temp.sf_device WHERE phone = 'c3' \gset
SELECT pg_temp.sf_assert(:'old_copy'::jsonb#>>ARRAY[pg_temp.sf('f_reload_all'), pg_temp.sf('f_reason')] = pg_temp.sf('r_format'),
  'format: a customer account''s copy key of the format before answers reload_all FORMAT_CHANGED: ' || left(:'old_copy', 300));

-- ---------------------------------------------------------------------------------------------------------------------------------
-- B1. As a customer account: the entities are exactly contract section 0's list, none of the "never" list, only its active
-- assignments' rows, no hidden column in any stored row.
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT pg_temp.sf_assert(pg_temp.cc_sorted((SELECT entities FROM pg_temp.sf_device WHERE phone = p)) = pg_temp.cc_sorted(pg_temp.cc_list('entities')),
  format('B1: the entities of %s are exactly the contract list. Got %s', p, (SELECT array_to_string(entities, ',') FROM pg_temp.sf_device WHERE phone = p)))
  FROM unnest(ARRAY['c1', 'c2', 'c3']) p;
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM pg_temp.sf_device d WHERE d.phone IN ('c1', 'c2', 'c3') AND d.entities && pg_temp.cc_list('never'))
  AND NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy c WHERE c.slot IN ('c1', 'c2', 'c3') AND c.e = ANY (pg_temp.cc_list('never')))
  AND NOT EXISTS (SELECT 1 FROM pg_temp.sf_entry x WHERE x.phone IN ('c1', 'c2', 'c3') AND x.e = ANY (pg_temp.cc_list('never'))),
  'B1: a customer account receives no entity of the never list (O5)');
SELECT pg_temp.sf_assert(pg_temp.sf_held('c1', 'customers') = ARRAY[:'north']::text[] AND pg_temp.sf_held('c2', 'customers') = ARRAY[:'south']::text[]
  AND pg_temp.sf_held('c3', 'customers') = (SELECT array_agg(x ORDER BY x) FROM unnest(ARRAY[:'north', :'south', :'west']) x),
  'B1: each account holds the customers of its assignments and no other: c3 ' || array_to_string(pg_temp.sf_held('c3', 'customers'), ','));
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy c WHERE c.slot = 'c1' AND c.e IN ('goodsreceived', 'dispatch', 'invoice', 'orders') AND c.row->>'customer_id' <> :'north')
  AND NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy c WHERE c.slot = 'c2' AND c.e IN ('goodsreceived', 'dispatch', 'invoice', 'orders') AND c.row->>'customer_id' <> :'south')
  AND (SELECT count(DISTINCT c.row->>'customer_id') FROM pg_temp.sf_copy c WHERE c.slot = 'c3' AND c.e = 'goodsreceived') = 3,
  'B1: a one-customer account holds only its customer''s documents; c3 holds all three customers''');
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy c, jsonb_object_keys(c.row) k WHERE c.slot IN ('c1', 'c2', 'c3')
    AND k = ANY (pg_temp.sf_list('q1_customer_hidden_columns'))),
  'B1: no key of customer_hidden_columns in any stored row of a customer account: '
  || COALESCE((SELECT string_agg(DISTINCT c.slot || ' ' || c.e || '.' || k, ', ') FROM pg_temp.sf_copy c, jsonb_object_keys(c.row) k
      WHERE c.slot IN ('c1', 'c2', 'c3') AND k = ANY (pg_temp.sf_list('q1_customer_hidden_columns'))), ''));
SELECT pg_temp.sf_assert(EXISTS (SELECT 1 FROM pg_temp.sf_copy WHERE slot = 'c3' AND e = 'payments') AND EXISTS (SELECT 1 FROM pg_temp.sf_copy WHERE slot = 'c3' AND e = 'orders')
  AND EXISTS (SELECT 1 FROM pg_temp.sf_copy WHERE slot = 'c3' AND e = 'grn_rates') AND EXISTS (SELECT 1 FROM pg_temp.sf_copy WHERE slot = 'c3' AND e = 'invoice'),
  'B1: premise: c3''s copy holds rows of payments, orders, grn_rates and invoice (the entity check above is not vacuous)');
SELECT pg_temp.sf_assert(pg_temp.sf_check_direct(p, pg_temp.sf_list('q1_customer_hidden_columns'), true) = '',
  'B1: the copy of ' || p || ' equals its direct reads: ' || pg_temp.sf_check_direct(p, pg_temp.sf_list('q1_customer_hidden_columns'), true)) FROM unnest(ARRAY['c1', 'c3']) p;

-- B9 (small set). First load of the four phones, and each pull below, within 8 seconds; no page above the limit (sf_load asserts it).
SELECT pg_temp.sf_assert(extract(epoch FROM (:'t_load1'::timestamptz - :'t_load0'::timestamptz)) < 8,
  'B9: the first load of three customer accounts and an administrator took ' || (:'t_load1'::timestamptz - :'t_load0'::timestamptz) || ' (limit 8 s, small set; the 60,000-GRN set is Test''s)');

-- ---------------------------------------------------------------------------------------------------------------------------------
-- B0 / B7. Every read of contract section 3, called as a customer account on the fixture. Kept in cc_answer.
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT pg_temp.cc_read('c3', t.label, t.stmt) FROM (VALUES
  ('get_customer_grn_items', format('SELECT public.get_customer_grn_items(%L::uuid, NULL, NULL, ''{}''::jsonb, ''date'', ''desc'', 2000, 0)', :'north')),
  ('get_customer_grn_items', format('SELECT public.get_customer_grn_items(%L::uuid, NULL, NULL, ''{}''::jsonb, ''date'', ''desc'', 2000, 0)', :'south')),
  ('get_customer_grn_items', format('SELECT public.get_customer_grn_items(%L::uuid, NULL, NULL, ''{}''::jsonb, ''date'', ''desc'', 2000, 0)', :'west')),
  ('get_grn_details', format('SELECT public.get_grn_details(%L::uuid)', :'grn_n1')),
  ('get_grn_item_dispatches', format('SELECT public.get_grn_item_dispatches(%L::uuid)', :'lot_n2')),
  ('get_grn_item_rates', format('SELECT public.get_grn_item_rates(%L::uuid)', :'grn_n1')),
  ('get_customer_dispatch_list', format('SELECT public.get_customer_dispatch_list(%L::uuid, 2000, 0, true)', :'north')),
  ('get_customer_dispatch_list', format('SELECT public.get_customer_dispatch_list(%L::uuid, 2000, 0, true)', :'west')),
  ('get_dispatch_details', format('SELECT public.get_dispatch_details(%L::uuid)', :'disp_n1')),
  ('get_orders_list', format('SELECT public.get_orders_list(p_customer_id => %L::uuid)', :'north')),
  ('get_customer_order', format('SELECT public.get_customer_order(%L::uuid)', :'north')),
  ('get_order_with_items', format('SELECT public.get_order_with_items(%L::uuid)', :'ord_n')),
  ('get_customer_invoice_summary', format('SELECT public.get_customer_invoice_summary(p_customer_uuid => %L::uuid)', :'north')),
  ('get_invoice_data', format('SELECT public.get_invoice_data(%L::uuid)', :'inv_n')),
  ('get_invoice_detail', format('SELECT public.get_invoice_detail(%L::uuid)', :'inv_n')),
  ('get_invoice_items_detailed', format('SELECT public.get_invoice_items_detailed(%L::uuid)', :'inv_n')),
  ('get_customer_stock_summary', format('SELECT public.get_customer_stock_summary(%L::uuid)', :'north')),
  ('get_item_wise_stock_list', format('SELECT public.get_item_wise_stock_list(p_customer_id => %L::uuid, p_limit => 2000)', :'north')),
  ('get_stock_aging_report', format('SELECT public.get_stock_aging_report(p_customer_uuid => %L::uuid)', :'north')),
  ('get_customer_grn_activity', format('SELECT public.get_customer_grn_activity(p_customer_uuid => %L::uuid)', :'north')),
  ('get_customer_dispatch_activity', format('SELECT public.get_customer_dispatch_activity(%L::uuid, NULL, NULL)', :'north')),
  ('get_customer_activity_detail', format('SELECT public.get_customer_activity_detail(%L::uuid, NULL, NULL)', :'north')),
  ('get_customer_statement', format('SELECT public.get_customer_statement(%L::uuid)', :'north'))
) t(label, stmt);
SELECT pg_temp.cc_read('c1', 'get_grn_details', format('SELECT public.get_grn_details(%L::uuid)', :'grn_n1'));
SELECT pg_temp.cc_read('c1', 'get_customer_grn_items', format('SELECT public.get_customer_grn_items(%L::uuid, NULL, NULL, ''{}''::jsonb, ''date'', ''desc'', 2000, 0)', :'north'));

-- B0, PQ3: no read answers a customer account a key of the forbidden list, at any depth.
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM pg_temp.cc_answer a, LATERAL pg_temp.cc_keys(a.answer, false) k WHERE k = ANY (pg_temp.cc_list('forbidden'))),
  'B0/PQ3: a read answered a customer account a staff-only key (bug card for Product: the read should lose it): '
  || COALESCE((SELECT string_agg(DISTINCT a.label || '.' || k, ', ') FROM pg_temp.cc_answer a, LATERAL pg_temp.cc_keys(a.answer, false) k WHERE k = ANY (pg_temp.cc_list('forbidden'))), ''));

-- B0 / B7: every row key of the row reads is producible from the account's own copy (see 2 above).
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM pg_temp.cc_answer a JOIN pg_temp.cc_row_reads r ON r.label = a.label, LATERAL pg_temp.cc_keys(a.answer->'data', true) k
    WHERE a.who = 'c3' AND k <> ALL (pg_temp.cc_copy_keys('c3') || pg_temp.cc_list('cc_renamed') || pg_temp.cc_list('cc_computed'))),
  'B0/B7: a customer read answers a key the account''s copy cannot produce (topic 1 closes this): '
  || COALESCE((SELECT string_agg(DISTINCT a.label || '.' || k, ', ') FROM pg_temp.cc_answer a JOIN pg_temp.cc_row_reads r ON r.label = a.label,
       LATERAL pg_temp.cc_keys(a.answer->'data', true) k
       WHERE a.who = 'c3' AND k <> ALL (pg_temp.cc_copy_keys('c3') || pg_temp.cc_list('cc_renamed') || pg_temp.cc_list('cc_computed'))), ''));
SELECT pg_temp.sf_assert((SELECT count(DISTINCT label) FROM pg_temp.cc_answer a JOIN pg_temp.cc_row_reads r USING (label)) = (SELECT count(*) FROM pg_temp.cc_row_reads)
  AND (SELECT count(*) FROM pg_temp.cc_answer a, LATERAL pg_temp.cc_keys(a.answer->'data', true) k WHERE a.label = 'get_customer_grn_items') > 10,
  'B0/B7: premise: every row read answered and the grn items read has rows (the key check above is not vacuous)');

-- B7: the rows a list read answers are the rows of the copy for that customer (membership, per customer). The read of each customer
-- is the one whose first row names it; the lots are compared as sets.
CREATE FUNCTION pg_temp.cc_answer_for(p text, lbl text, cust uuid) RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT answer FROM pg_temp.cc_answer WHERE who = p AND label = lbl AND answer#>>'{data,items,0,customer_id}' = cust::text ORDER BY seq DESC LIMIT 1 $$;
SELECT pg_temp.sf_assert(pg_temp.cc_answer_for('c3', 'get_customer_grn_items', c.cust) IS NOT NULL
  AND pg_temp.cc_ids(pg_temp.cc_answer_for('c3', 'get_customer_grn_items', c.cust)->'data'->'items', 'id') = pg_temp.cc_lot_ids('c3', c.cust),
  format('B7: get_customer_grn_items as c3 for %s answers lots %s, the copy holds %s', c.name,
    pg_temp.cc_ids(pg_temp.cc_answer_for('c3', 'get_customer_grn_items', c.cust)->'data'->'items', 'id'), pg_temp.cc_lot_ids('c3', c.cust)))
  FROM (VALUES ('North', :'north'::uuid), ('South', :'south'::uuid), ('West', :'west'::uuid)) c(name, cust);
SELECT pg_temp.sf_assert(pg_temp.cc_ids(answer, 'id') @> pg_temp.cc_copy_ids('c3', 'dispatch', :'north'::uuid)
  AND pg_temp.cc_copy_ids('c3', 'dispatch', :'north'::uuid) <> '{}',
  'B7: get_customer_dispatch_list as c3 for North answers every dispatch of North that the copy holds: copy ' || pg_temp.cc_copy_ids('c3', 'dispatch', :'north'::uuid)::text)
  FROM pg_temp.cc_answer WHERE who = 'c3' AND label = 'get_customer_dispatch_list' ORDER BY seq LIMIT 1;

-- R10 server side: a customer account's read for a customer it is not assigned to is refused, and its copy holds nothing of that customer.
SELECT pg_temp.sf_try('authenticated', :'c1_claims'::jsonb, format('SELECT public.get_customer_grn_items(%L::uuid, NULL, NULL, ''{}''::jsonb, ''date'', ''desc'', 50, 0)', :'south')) AS c1_south \gset
SELECT pg_temp.sf_assert(:'c1_south'::jsonb ? 'sqlstate' OR COALESCE(:'c1_south'::jsonb#>>'{answer,success}', 'false') <> 'true',
  'R10: North''s account reading South''s GRN items is refused: ' || left(:'c1_south', 300));
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy c WHERE c.slot = 'c1' AND c.row->>'customer_id' = :'south'),
  'R10: c1''s copy holds no row of South');
SELECT pg_temp.sf_try('authenticated', :'c1_claims'::jsonb, format('SELECT public.get_grn_details(%L::uuid)', :'grn_s1')) AS c1_south_grn \gset
SELECT pg_temp.sf_assert(:'c1_south_grn'::jsonb ? 'sqlstate' OR COALESCE(:'c1_south_grn'::jsonb#>>'{answer,success}', 'false') <> 'true',
  'R10: North''s account opening South''s GRN is refused: ' || left(:'c1_south_grn', 300));

-- ---------------------------------------------------------------------------------------------------------------------------------
-- B5. Checksums as a customer account: for every settled entity, count and sum equal what the phone holds over its rows.
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT pg_temp.sf_pull(p) FROM unnest(ARRAY['c1', 'c3']) p;
CREATE FUNCTION pg_temp.cc_sums_bad(p text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE d record; sums jsonb; bad text;
BEGIN
  SELECT * INTO d FROM pg_temp.sf_device WHERE phone = p;
  sums := pg_temp.sf_as(d.claims, format(pg_temp.sf('call_checksums'), d.position, d.copy));
  PERFORM pg_temp.sf_assert(sums->>'success' = 'true', 'B5: checksums answered to ' || p || ': ' || left(sums::text, 300));
  PERFORM pg_temp.sf_assert(jsonb_array_length(sums->pg_temp.sf('f_entities')) = cardinality(pg_temp.cc_list('entities')),
    'B5: the checksums of ' || p || ' list exactly the customer entities: ' || left(sums::text, 300));
  SELECT string_agg(format('%s %s/%s', e, count, held), '; ') INTO bad FROM (
    SELECT s->>pg_temp.sf('f_e') AS e, (s->>pg_temp.sf('f_count'))::bigint AS count, (s->>pg_temp.sf('f_settled'))::boolean AS settled,
      (s->>pg_temp.sf('f_sum'))::numeric AS sum,
      (SELECT count(*) FROM pg_temp.sf_copy c WHERE c.slot = p AND c.e = s->>pg_temp.sf('f_e')) AS held,
      (SELECT COALESCE(sum(('x' || lpad(left(c.v, 15), 16, '0'))::bit(64)::bigint::numeric), 0) % 1152921504606846976
         FROM pg_temp.sf_copy c WHERE c.slot = p AND c.e = s->>pg_temp.sf('f_e')) AS held_sum
    FROM jsonb_array_elements(sums->pg_temp.sf('f_entities')) s) t
    WHERE settled AND (count <> held OR sum <> held_sum);
  RETURN COALESCE(bad, '');
END $$;
SELECT pg_temp.sf_assert(pg_temp.cc_sums_bad(p) = '', 'B5: the checksums of ' || p || ' differ from its copy: ' || pg_temp.cc_sums_bad(p)) FROM unnest(ARRAY['c1', 'c3']) p;
SELECT pg_temp.sf_assert((SELECT count(*) FROM jsonb_array_elements(
    pg_temp.sf_as(d.claims, format(pg_temp.sf('call_checksums'), d.position, d.copy))->pg_temp.sf('f_entities')) s
    WHERE (s->>pg_temp.sf('f_settled'))::boolean) >= 10, 'B5: premise: most entities of c1 are settled and compared')
  FROM pg_temp.sf_device d WHERE d.phone = 'c1';

-- ---------------------------------------------------------------------------------------------------------------------------------
-- B6. Money marks: a mark for an own customer arrives, another customer's never; the mark 'all' (a setting) reaches every customer
-- account (topic 2; shared with WH-305's sync_feed_money_marks.sql, which asserts the same on its fixture).
-- ---------------------------------------------------------------------------------------------------------------------------------
UPDATE public.goodsreceived SET note = 'customer copy: mark' WHERE id = :'grn_n1';
SELECT pg_temp.cc_step('B6 a GRN of North', ARRAY['admin', 'c1', 'c2', 'c3']);
SELECT pg_temp.sf_assert(pg_temp.cc_marks('c1') = ARRAY[:'north'] AND pg_temp.cc_marks('c2') = '{}' AND pg_temp.cc_marks('c3') = ARRAY[:'north'],
  format('B6: a change of North''s GRN marks North for c1 and c3 and nothing for c2: c1 %s, c2 %s, c3 %s', pg_temp.cc_marks('c1'), pg_temp.cc_marks('c2'), pg_temp.cc_marks('c3')));
SELECT record_payments AS payments_before FROM warehouse_security.charging_rule WHERE id \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.set_record_payments(%L::boolean)', NOT :'payments_before'::boolean))->>'changed' = 'true', 'fixture: set_record_payments changes the setting');
SELECT pg_temp.cc_step('B6 a setting (all)', ARRAY['admin', 'c1', 'c2', 'c3']);
SELECT pg_temp.sf_assert(pg_temp.cc_marks(p) = ARRAY['all'], format('B6: the mark all reaches %s exactly once: %s', p, pg_temp.cc_marks(p))) FROM unnest(ARRAY['c1', 'c2', 'c3']) p;
SELECT pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.set_record_payments(%L::boolean)', :'payments_before'::boolean)) IS NOT NULL AS payments_restored \gset
SELECT pg_temp.cc_step('B6 setting restored', ARRAY['admin', 'c1', 'c2', 'c3']);

-- ---------------------------------------------------------------------------------------------------------------------------------
-- B2. A GRN moved: the account of the old customer gets a delete, of the new one the rows, an account of neither gets no entry.
-- CCN1 North -> South: c1 delete, c2 upsert, c3 (holds both) upsert. CCW2 West -> North: c2 nothing, c1 upsert, c3 upsert.
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT pg_temp.sf_update_grn(:'sf_admin_claims'::jsonb, :'grn_n1'::uuid, pg_temp.sf_current_lines(:'grn_n1'::uuid), :'south'::uuid);
SELECT pg_temp.cc_step('B2 CCN1 to South', ARRAY['admin', 'c1', 'c2', 'c3']);
SELECT pg_temp.sf_assert(pg_temp.sf_ops('c1', 'goodsreceived', :'grn_n1', pg_temp.sf_last_pull('c1')) = pg_temp.sf('op_delete')
  AND NOT (:'grn_n1' = ANY (pg_temp.sf_held('c1', 'goodsreceived')))
  AND NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy c WHERE c.slot = 'c1' AND c.e = 'goodsreceived_trl' AND c.row->>'gr_id' = :'grn_n1'),
  'B2: North''s account got the moved GRN as a delete and holds neither it nor its lots');
SELECT pg_temp.sf_assert(pg_temp.sf_ops('c2', 'goodsreceived', :'grn_n1', pg_temp.sf_last_pull('c2')) = pg_temp.sf('op_upsert') AND :'grn_n1' = ANY (pg_temp.sf_held('c2', 'goodsreceived')),
  'B2: South''s account got the moved GRN as an upsert');
SELECT pg_temp.sf_assert(pg_temp.sf_ops('c3', 'goodsreceived', :'grn_n1', pg_temp.sf_last_pull('c3')) = pg_temp.sf('op_upsert')
  AND (SELECT row->>'customer_id' FROM pg_temp.sf_copy WHERE slot = 'c3' AND e = 'goodsreceived' AND id = :'grn_n1') = :'south',
  'B2: the account of both customers holds the moved GRN under South, without a delete');
SELECT pg_temp.sf_update_grn(:'sf_admin_claims'::jsonb, :'grn_w2'::uuid, pg_temp.sf_current_lines(:'grn_w2'::uuid), :'north'::uuid);
SELECT pg_temp.cc_step('B2 CCW2 to North', ARRAY['admin', 'c1', 'c2', 'c3']);
SELECT pg_temp.sf_assert(pg_temp.sf_ops('c2', 'goodsreceived', :'grn_w2', pg_temp.sf_last_pull('c2')) = ''
  AND NOT EXISTS (SELECT 1 FROM pg_temp.sf_entry x WHERE x.phone = 'c2' AND x.id = :'grn_w2'),
  'B2: an account of neither customer got no entry, not even a delete, for the GRN moved West to North');
SELECT pg_temp.sf_assert(pg_temp.sf_ops('c1', 'goodsreceived', :'grn_w2', pg_temp.sf_last_pull('c1')) = pg_temp.sf('op_upsert'), 'B2: North''s account got the GRN from West as an upsert');
-- The read follows the copy after a move (B7): North's list as c1 holds the lots of CCW2 and not those of CCN1.
SELECT pg_temp.cc_read('c1', 'get_customer_grn_items', format('SELECT public.get_customer_grn_items(%L::uuid, NULL, NULL, ''{}''::jsonb, ''date'', ''desc'', 2000, 0)', :'north'));
SELECT pg_temp.sf_assert((SELECT pg_temp.cc_ids(answer->'data'->'items', 'id') FROM pg_temp.cc_answer WHERE who = 'c1' AND label = 'get_customer_grn_items' ORDER BY seq DESC LIMIT 1)
    = pg_temp.cc_lot_ids('c1', :'north'::uuid),
  'B7: after the moves the read of North''s GRN items as c1 answers the lots its copy holds');

-- ---------------------------------------------------------------------------------------------------------------------------------
-- B3. A soft-deleted GRN, dispatch, invoice and order reach a customer account as deletes (its lots, lines and payments with them).
-- ---------------------------------------------------------------------------------------------------------------------------------
UPDATE public.dispatch SET deleted_at = now() WHERE id = :'disp_n2';
UPDATE public.orders SET deleted_at = now() WHERE id = :'ord_n';
UPDATE public.invoice SET deleted_at = now() WHERE id = :'inv_n';
UPDATE public.goodsreceived SET deleted_at = now() WHERE id = :'grn_n3';
SELECT pg_temp.cc_step('B3 soft deletes', ARRAY['admin', 'c1', 'c3']);
SELECT pg_temp.sf_assert(pg_temp.sf_ops(p, 'dispatch', :'disp_n2', pg_temp.sf_last_pull(p)) = pg_temp.sf('op_delete')
  AND pg_temp.sf_ops(p, 'orders', :'ord_n', pg_temp.sf_last_pull(p)) = pg_temp.sf('op_delete')
  AND pg_temp.sf_ops(p, 'invoice', :'inv_n', pg_temp.sf_last_pull(p)) = pg_temp.sf('op_delete')
  AND pg_temp.sf_ops(p, 'goodsreceived', :'grn_n3', pg_temp.sf_last_pull(p)) = pg_temp.sf('op_delete'),
  'B3: ' || p || ' got the soft-deleted dispatch, order, invoice and GRN as deletes') FROM unnest(ARRAY['c1', 'c3']) p;
SELECT pg_temp.sf_assert(NOT (:'disp_n2' = ANY (pg_temp.sf_held(p, 'dispatch'))) AND NOT (:'ord_n' = ANY (pg_temp.sf_held(p, 'orders')))
  AND NOT (:'inv_n' = ANY (pg_temp.sf_held(p, 'invoice'))) AND NOT (:'grn_n3' = ANY (pg_temp.sf_held(p, 'goodsreceived')))
  AND NOT (:'line_n' = ANY (pg_temp.sf_held(p, 'order_items'))) AND NOT (:'pay_n' = ANY (pg_temp.sf_held(p, 'payments'))),
  'B3: ' || p || ' holds none of them, nor the order line or the payment of the deleted invoice') FROM unnest(ARRAY['c1', 'c3']) p;

-- ---------------------------------------------------------------------------------------------------------------------------------
-- B8 (PQ4). A deactivated customer still assigned: goods stay. A deleted customer: its rows leave the copy. The read and the copy agree.
-- ---------------------------------------------------------------------------------------------------------------------------------
UPDATE public.customers SET active = false WHERE id = :'west';
SELECT pg_temp.cc_step('B8 West deactivated', ARRAY['admin', 'c3']);
SELECT pg_temp.sf_assert(:'west' = ANY (pg_temp.sf_held('c3', 'customers')) AND :'grn_w1' = ANY (pg_temp.sf_held('c3', 'goodsreceived'))
  AND :'disp_w1' = ANY (pg_temp.sf_held('c3', 'dispatch')),
  'B8/PQ4: a deactivated customer''s customer row, GRNs and dispatches stay in the account''s copy');
SELECT pg_temp.cc_read('c3', 'get_customer_grn_items', format('SELECT public.get_customer_grn_items(%L::uuid, NULL, NULL, ''{}''::jsonb, ''date'', ''desc'', 2000, 0)', :'west'));
SELECT pg_temp.sf_assert((SELECT pg_temp.cc_ids(answer->'data'->'items', 'id') FROM pg_temp.cc_answer WHERE who = 'c3' AND label = 'get_customer_grn_items' ORDER BY seq DESC LIMIT 1)
    = pg_temp.cc_lot_ids('c3', :'west'::uuid),
  'B8/PQ4: the read of a deactivated customer''s GRN items as c3 answers what the copy holds (the goods stay visible)');
UPDATE public.customers SET active = true WHERE id = :'west';
UPDATE public.customers SET deleted_at = now() WHERE id = :'west';
SELECT pg_temp.cc_step('B8 West deleted', ARRAY['admin', 'c3']);
SELECT pg_temp.sf_assert(NOT (:'west' = ANY (pg_temp.sf_held('c3', 'customers'))), 'B8/PQ4: a deleted customer''s customer row leaves the account''s copy');
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy c WHERE c.slot = 'c3' AND c.row->>'customer_id' = :'west')
  AND NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy c WHERE c.slot = 'c3' AND c.e = 'goodsreceived_trl' AND c.row->>'gr_id' = :'grn_w1'),
  'B8/PQ4 (product gap if it fails: the feed scopes by assignment, not by the customer being live): a deleted customer''s documents leave the copy: left '
  || (SELECT count(*) FROM pg_temp.sf_copy c WHERE c.slot = 'c3' AND c.row->>'customer_id' = :'west') || ' rows with its customer id');
SELECT pg_temp.sf_try('authenticated', :'c3_claims'::jsonb, format('SELECT public.get_customer_grn_items(%L::uuid, NULL, NULL, ''{}''::jsonb, ''date'', ''desc'', 2000, 0)', :'west')) AS west_deleted_read \gset
SELECT pg_temp.sf_assert(CASE WHEN :'west_deleted_read'::jsonb ? 'sqlstate' THEN true
    ELSE pg_temp.cc_ids(:'west_deleted_read'::jsonb#>'{answer,data,items}', 'id') = pg_temp.cc_lot_ids('c3', :'west'::uuid) END,
  'B8/PQ4: the read of a deleted customer''s GRN items answers what the copy holds (nothing) or is refused: ' || left(:'west_deleted_read', 300));

-- ---------------------------------------------------------------------------------------------------------------------------------
-- B4. Assignment added: c1 is assigned to South too, a new copy key, reload_all ACCESS_CHANGED, the new rows. Removed again: the same.
-- A role change both ways. A deactivated profile is refused.
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT to_jsonb(public.assign_customer_to_user(%L, %L::uuid, %L))', '919888897301', :'south', 'Customer copy B4'))::text = 'true',
  'fixture: c1 assigned to South');
SELECT pg_temp.sf_pull('c1') AS c1_added \gset
SELECT pg_temp.sf_assert(:'c1_added'::jsonb->'reload_all' ? pg_temp.sf('r_access'), 'B4: an assignment added answers ACCESS_CHANGED: ' || :'c1_added');
SELECT pg_temp.sf_assert(:'south' = ANY (pg_temp.sf_held('c1', 'customers')) AND :'grn_s1' = ANY (pg_temp.sf_held('c1', 'goodsreceived')),
  'B4: after the reload c1 holds South and its GRN');
SELECT pg_temp.sf_assert(pg_temp.sf_diff('c1') = '', 'B4: c1''s copy equals a fresh load: ' || pg_temp.sf_diff('c1'));
SELECT pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT to_jsonb(public.remove_customer_assignment(%L, %L::uuid))', '919888897301', :'south')) AS c1_unassigned \gset
SELECT pg_temp.sf_pull('c1') AS c1_removed \gset
SELECT pg_temp.sf_assert(:'c1_removed'::jsonb->'reload_all' ? pg_temp.sf('r_access') AND NOT (:'south' = ANY (pg_temp.sf_held('c1', 'customers')))
  AND NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy c WHERE c.slot = 'c1' AND c.row->>'customer_id' = :'south'),
  'B4: an assignment removed answers ACCESS_CHANGED and the copy holds nothing of South: ' || :'c1_removed');
-- Role change: customer -> staff: the next call reloads for the staff entities; the copy then holds staff entities and no customer-only scope.
UPDATE public.user_profiles SET role = 'staff' WHERE mobile = '919888897302';
SELECT pg_temp.sf_pull('c2') AS c2_staff \gset
SELECT pg_temp.sf_assert(:'c2_staff'::jsonb->'reload_all' ? pg_temp.sf('r_access'), 'B4: customer to staff answers ACCESS_CHANGED: ' || :'c2_staff');
SELECT pg_temp.sf_assert(pg_temp.sf_diff('c2') = '' AND pg_temp.sf_held('c2', 'customers') @> ARRAY[:'north', :'south']::text[],
  'B4: after the role change c2 holds what staff hold (all customers), equal to a fresh load');
UPDATE public.user_profiles SET role = 'customer' WHERE mobile = '919888897302';
SELECT pg_temp.sf_pull('c2') AS c2_back \gset
SELECT pg_temp.sf_assert(:'c2_back'::jsonb->'reload_all' ? pg_temp.sf('r_access') AND pg_temp.sf_held('c2', 'customers') = ARRAY[:'south']::text[]
  AND NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy c WHERE c.slot = 'c2' AND c.e = ANY (pg_temp.cc_list('never'))),
  'B4: staff to customer answers ACCESS_CHANGED and the copy is the account''s again: ' || :'c2_back');
SELECT pg_temp.sf_assert(pg_temp.sf_diff('c2') = '', 'B4: c2''s copy equals a fresh load after the round trip: ' || pg_temp.sf_diff('c2'));
-- Deactivated profile: refused (guess 5).
UPDATE public.user_profiles SET active = false WHERE mobile = '919888897302';
SELECT pg_temp.sf_try('authenticated', :'c2_claims'::jsonb, pg_temp.sf('call_start')) AS c2_off \gset
SELECT pg_temp.sf_assert(:'c2_off'::jsonb ? 'sqlstate' OR COALESCE(:'c2_off'::jsonb#>>'{answer,success}', 'false') <> 'true',
  'B4: a deactivated account''s start is refused, not answered with a copy: ' || left(:'c2_off', 300));
UPDATE public.user_profiles SET active = true WHERE mobile = '919888897302';

-- B9 (small set): every pull of this file stayed within the page limit (asserted by the stand-in) and a full catch-up is quick.
SELECT clock_timestamp() AS t_pull0 \gset
SELECT pg_temp.sf_pull(p) FROM unnest(ARRAY['c1', 'c2', 'c3']) p;
SELECT pg_temp.sf_assert(extract(epoch FROM (clock_timestamp() - :'t_pull0'::timestamptz)) < 8, 'B9: three customer accounts caught up in under 8 s (small set)');
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM pg_temp.sf_entry x WHERE x.phone IN ('c1', 'c2', 'c3') AND x.e = ANY (pg_temp.cc_list('never'))),
  'B1: at the end no customer account received an entry of the never list');
SELECT pg_temp.sf_assert(pg_temp.sf_diff(p) = '', 'at the end the copy of ' || p || ' equals a fresh load: ' || pg_temp.sf_diff(p)) FROM unnest(ARRAY['admin', 'c1', 'c2', 'c3']) p;

\echo 'WH-306 customer account copy (B0-B9, server side of R1-R12) checks passed.'

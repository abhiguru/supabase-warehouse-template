-- WH-299 backend change "sync lot emptied time" (PR3), case B2 of ~/ws/fresh/product/tech/app-offline-read-from-copy.md
-- (sections 6 and 13): the feed's goodsreceived_trl row carries emptied_at = MAX(stock_movements.created_at) with
-- balance_after = 0 for the lot, null when there is none, so that a phone can build the "emptied in the last 360 days" section of
-- get_customer_stock_summary. tests/migrations.sh pipes tests/fixtures/gst_details.sql and tests/sync_feed_contract.sql in front
-- of this file, in the sync feed database of its own; this file commits. Fictional data only.
--
-- The writers of stock_movements today (create_dispatch_with_stock_check, update_dispatch_smart,
-- delete_dispatch_with_order_cleanup) are each driven here: after every one the phone's copy must equal a fresh load, so the
-- changed value is logged.
--
-- AGREE WITH DEVELOPMENT (WH-299): the new name is 'emptied_at'; every other feed name is in tests/sync_feed_contract.sql.
\set ON_ERROR_STOP on

-- The server's value for a lot.
CREATE FUNCTION pg_temp.et_server(lot uuid) RETURNS timestamptz LANGUAGE sql STABLE AS $$
  SELECT max(m.created_at) FROM public.stock_movements m WHERE m.gr_trl_id = lot AND m.balance_after = 0 $$;
-- The phone's value for a lot (the row must be held).
CREATE FUNCTION pg_temp.et_phone(p text, lot uuid) RETURNS timestamptz LANGUAGE plpgsql STABLE AS $$
DECLARE r jsonb;
BEGIN
  SELECT c.row INTO r FROM pg_temp.sf_copy c WHERE c.slot = p AND c.e = 'goodsreceived_trl' AND c.id = lot::text;
  PERFORM pg_temp.sf_assert(r IS NOT NULL, format('B2: %s does not hold lot %s', p, lot));
  PERFORM pg_temp.sf_assert(r ? 'emptied_at', format('B2: the lot row of %s has no emptied_at key', p));
  RETURN (r->>'emptied_at')::timestamptz;
END $$;
-- Lots held by a phone that lack the key or differ from the server's value.
CREATE FUNCTION pg_temp.et_bad(p text) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT COALESCE(string_agg(what, '; '), '') FROM (
    SELECT format('%s phone %s server %s', c.row->>'package_mark',
        CASE WHEN c.row ? 'emptied_at' THEN COALESCE(c.row->>'emptied_at', 'null') ELSE '(no key)' END,
        COALESCE(pg_temp.et_server(c.id::uuid)::text, 'null')) AS what
    FROM pg_temp.sf_copy c WHERE c.slot = p AND c.e = 'goodsreceived_trl'
      AND (NOT c.row ? 'emptied_at' OR (c.row->>'emptied_at')::timestamptz IS DISTINCT FROM pg_temp.et_server(c.id::uuid))
    ORDER BY c.row->>'package_mark' LIMIT 12) t $$;
-- The "emptied in the last 360 days" lots of a customer as '<grn id> <mark> <day>', from the server's report ...
CREATE FUNCTION pg_temp.et_summary(claims jsonb, cust uuid) RETURNS text[] LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  r := pg_temp.sf_as(claims, format('SELECT public.get_customer_stock_summary(%L::uuid)', cust));
  PERFORM pg_temp.sf_assert(r ? 'out_of_stock_items' AND NOT r ? 'error', 'get_customer_stock_summary answered: ' || left(r::text, 300));
  RETURN ARRAY(SELECT format('%s %s %s', g->>'grn_id', g->>'package_mark', g->>'emptied_date')
    FROM jsonb_array_elements(r->'out_of_stock_items') i, jsonb_array_elements(COALESCE(NULLIF(i->'grns', 'null'), '[]'::jsonb)) g ORDER BY 1);
END $$;
-- ... and as a phone works it out from its copy alone (the server's rule over emptied_at).
CREATE FUNCTION pg_temp.et_from_copy(p text, cust uuid) RETURNS text[] LANGUAGE sql STABLE AS $$
  SELECT ARRAY(SELECT format('%s %s %s', g.id, l.row->>'package_mark',
      to_char(warehouse_security.business_date((l.row->>'emptied_at')::timestamptz), 'YYYY-MM-DD'))
    FROM pg_temp.sf_copy l JOIN pg_temp.sf_copy g ON g.slot = p AND g.e = 'goodsreceived' AND g.id = l.row->>'gr_id'
    WHERE l.slot = p AND l.e = 'goodsreceived_trl' AND g.row->>'customer_id' = cust::text
      AND (l.row->>'stock')::int = 0 AND (l.row->>'qty')::int > 0
      AND (l.row->>'emptied_at')::timestamptz >= warehouse_security.business_day_start(warehouse_security.business_date(now()) - 360)
    ORDER BY 1) $$;
-- One pull of the administrator, staff and customer phones: each equals a fresh load, every lot has the server's value, and the
-- section built from the copy equals the report, which holds `emptied` lots.
CREATE FUNCTION pg_temp.et_check(cust uuid, emptied int, step text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE p text; bad text; d record; server text[]; mine text[];
BEGIN
  FOREACH p IN ARRAY ARRAY['admin', 'staff', 'reader'] LOOP
    PERFORM pg_temp.sf_pull(p);
    bad := pg_temp.sf_diff(p);
    PERFORM pg_temp.sf_assert(bad = '', format('B2 %s: the copy of %s differs from a fresh load: %s', step, p, bad));
    bad := pg_temp.et_bad(p);
    PERFORM pg_temp.sf_assert(bad = '', format('B2 %s: emptied_at on %s is not the server''s: %s', step, p, bad));
    SELECT * INTO STRICT d FROM pg_temp.sf_device WHERE phone = p;
    server := pg_temp.et_summary(d.claims, cust);
    mine := pg_temp.et_from_copy(p, cust);
    PERFORM pg_temp.sf_assert(cardinality(server) = emptied,
      format('premise (%s): the report of %s lists %s emptied lots, expected %s: %s', step, p, cardinality(server), emptied, server::text));
    PERFORM pg_temp.sf_assert(mine = server, format('B2 %s: the emptied section from %s''s copy %s differs from the report %s', step, p, mine::text, server::text));
  END LOOP;
END $$;

INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888897402', 'Copy Emptied Staff Person', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888897411', 'Copy Emptied Reader', 'customer', true, 'approved');
SELECT pg_temp.sf_login('9888897402') AS staff_claims \gset
SELECT pg_temp.sf_login('9888897411') AS reader_claims \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_customer(''Copy Emptied West'', ''9888897421'')')->>'success' = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_item(''Copy Emptied Turmeric'', ''Bag'')')->>'success' = 'true', 'customer and item');
SELECT id AS west FROM public.customers WHERE name = 'Copy Emptied West' \gset
SELECT id AS turmeric FROM public.items WHERE name = 'Copy Emptied Turmeric' \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT to_jsonb(public.assign_customer_to_user(%L, %L::uuid, %L))', '919888897411', :'west', 'Copy emptied fixture'))::text = 'true',
  'the customer account is assigned');

SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'CEA', :'west'::uuid, pg_temp.sf_lines(:'turmeric'::uuid, 3, 'CE')) AS grn_e \gset
SELECT id AS lot_1 FROM public.goodsreceived_trl WHERE gr_id = :'grn_e' AND package_mark = 'CE1' \gset
SELECT id AS lot_2 FROM public.goodsreceived_trl WHERE gr_id = :'grn_e' AND package_mark = 'CE2' \gset
SELECT id AS lot_3 FROM public.goodsreceived_trl WHERE gr_id = :'grn_e' AND package_mark = 'CE3' \gset
SELECT pg_temp.sf_phone('admin', :'sf_admin_claims'::jsonb);
SELECT pg_temp.sf_phone('staff', :'staff_claims'::jsonb);
SELECT pg_temp.sf_phone('reader', :'reader_claims'::jsonb);
SELECT pg_temp.sf_first_load(p) FROM unnest(ARRAY['admin', 'staff', 'reader']) p;

-- A lot never emptied: the key is there, with JSON null.
SELECT pg_temp.sf_assert((SELECT count(*) = 3 AND bool_and(COALESCE(row->'emptied_at' = 'null'::jsonb, false)) FROM pg_temp.sf_copy
    WHERE slot = p AND e = 'goodsreceived_trl' AND row->>'gr_id' = :'grn_e'),
  'B2: a first load of ' || p || ' carries emptied_at null on the three untouched lots') FROM unnest(ARRAY['admin', 'staff', 'reader']) p;
SELECT pg_temp.et_check(:'west', 0, 'first load');

-- A dispatch that leaves stock: still null.
SELECT pg_temp.sf_dispatch(:'sf_admin_claims'::jsonb, 'CED1', :'lot_1'::uuid, 4) AS disp_1 \gset
SELECT pg_temp.et_check(:'west', 0, 'part dispatched');
SELECT pg_temp.sf_assert(pg_temp.et_phone(p, :'lot_1') IS NULL, 'B2: a lot with stock left has no emptied time on ' || p) FROM unnest(ARRAY['admin', 'staff', 'reader']) p;

-- The dispatch that empties it.
SELECT pg_temp.sf_dispatch(:'sf_admin_claims'::jsonb, 'CED2', :'lot_1'::uuid, 6) AS disp_2 \gset
SELECT pg_temp.et_server(:'lot_1') AS first_empty \gset
SELECT pg_temp.et_check(:'west', 1, 'emptied by a dispatch');
SELECT pg_temp.sf_assert(pg_temp.et_phone(p, :'lot_1') = :'first_empty'::timestamptz AND pg_temp.et_phone(p, :'lot_2') IS NULL,
  'B2: the emptied lot has the time of the emptying movement on ' || p || ' and its neighbour none') FROM unnest(ARRAY['admin', 'staff', 'reader']) p;
SELECT pg_temp.sf_assert(pg_temp.sf_ops(p, 'goodsreceived_trl', :'lot_1', pg_temp.sf_last_pull(p)) = pg_temp.sf('op_upsert'),
  'B2: the emptied lot reached ' || p || ' as an upsert') FROM unnest(ARRAY['admin', 'staff', 'reader']) p;

-- Refilled by deleting that dispatch: out of the report; the value stays the server's (the earlier zero movement, not the later one).
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.delete_dispatch_with_order_cleanup(%L::uuid, %L::uuid)', :'disp_2', :'sf_admin_profile'))->>'success' = 'true',
  'delete dispatch CED2');
SELECT pg_temp.sf_assert((SELECT stock = 6 FROM public.goodsreceived_trl WHERE id = :'lot_1')
  AND (SELECT max(created_at) FROM public.stock_movements WHERE gr_trl_id = :'lot_1') > :'first_empty'::timestamptz, 'premise: a later movement refilled the lot');
SELECT pg_temp.et_check(:'west', 0, 'refilled by a dispatch delete');
SELECT pg_temp.sf_assert(pg_temp.et_phone(p, :'lot_1') = :'first_empty'::timestamptz,
  'B2: a refill does not move the emptied time (only movements that leave zero count) on ' || p) FROM unnest(ARRAY['admin', 'staff', 'reader']) p;

-- Emptied again: the latest of the two.
SELECT pg_temp.sf_dispatch(:'sf_admin_claims'::jsonb, 'CED3', :'lot_1'::uuid, 6) AS disp_3 \gset
SELECT pg_temp.et_server(:'lot_1') AS second_empty \gset
SELECT pg_temp.sf_assert(:'second_empty'::timestamptz > :'first_empty'::timestamptz, 'premise: the second emptying is later');
SELECT pg_temp.et_check(:'west', 1, 'emptied a second time');
SELECT pg_temp.sf_assert(pg_temp.et_phone(p, :'lot_1') = :'second_empty'::timestamptz, 'B2: a lot emptied twice has the later time on ' || p)
  FROM unnest(ARRAY['admin', 'staff', 'reader']) p;

-- Through "Edit dispatch": a quantity raised to the whole lot, a new line that takes a whole lot, a line removed, a quantity lowered.
SELECT pg_temp.sf_dispatch(:'sf_admin_claims'::jsonb, 'CED4', :'lot_2'::uuid, 4) AS disp_4 \gset
CREATE FUNCTION pg_temp.et_edit(claims jsonb, disp uuid, VARIADIC lines jsonb[]) RETURNS void LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  r := pg_temp.sf_as(claims, format('SELECT public.update_dispatch_smart(%L::uuid, NULL, %L::jsonb[])', disp, lines));
  PERFORM pg_temp.sf_assert(r->>'success' = 'true', 'fixture: edit dispatch: ' || left(r::text, 300));
END $$;
SELECT pg_temp.et_edit(:'sf_admin_claims'::jsonb, :'disp_4', jsonb_build_object('gr_trl_id', :'lot_2', 'disp_qty', 10));
SELECT pg_temp.et_server(:'lot_2') AS edit_empty \gset
SELECT pg_temp.et_check(:'west', 2, 'emptied by a raised quantity');
SELECT pg_temp.sf_assert(pg_temp.et_phone(p, :'lot_2') = :'edit_empty'::timestamptz, 'B2: an edit that empties a lot gives it the time on ' || p)
  FROM unnest(ARRAY['admin', 'staff', 'reader']) p;
SELECT pg_temp.et_edit(:'sf_admin_claims'::jsonb, :'disp_4', jsonb_build_object('gr_trl_id', :'lot_2', 'disp_qty', 10),
  jsonb_build_object('gr_trl_id', :'lot_3', 'disp_qty', 10));
SELECT pg_temp.et_server(:'lot_3') AS added_empty \gset
SELECT pg_temp.et_check(:'west', 3, 'emptied by a line added in an edit');
SELECT pg_temp.sf_assert(pg_temp.et_phone(p, :'lot_3') = :'added_empty'::timestamptz, 'B2: a line added by an edit empties its lot with the time on ' || p)
  FROM unnest(ARRAY['admin', 'staff', 'reader']) p;
SELECT pg_temp.et_edit(:'sf_admin_claims'::jsonb, :'disp_4', jsonb_build_object('gr_trl_id', :'lot_3', 'disp_qty', 10));
SELECT pg_temp.et_check(:'west', 2, 'refilled by removing a line');
SELECT pg_temp.sf_assert(pg_temp.et_phone(p, :'lot_2') = :'edit_empty'::timestamptz, 'B2: removing the line leaves the earlier emptied time on ' || p)
  FROM unnest(ARRAY['admin', 'staff', 'reader']) p;
SELECT pg_temp.et_edit(:'sf_admin_claims'::jsonb, :'disp_4', jsonb_build_object('gr_trl_id', :'lot_3', 'disp_qty', 7));
SELECT pg_temp.et_check(:'west', 1, 'refilled by a lowered quantity');
SELECT pg_temp.sf_assert(pg_temp.et_phone(p, :'lot_3') = :'added_empty'::timestamptz, 'B2: lowering the quantity leaves the earlier emptied time on ' || p)
  FROM unnest(ARRAY['admin', 'staff', 'reader']) p;

-- Emptied more than 360 days ago, and an imported lot at zero with no movement. The feed sends the stored time whatever its age
-- (the phone applies the 360 days); no movement is null. Both are read by a new first load.
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'CEB', :'west'::uuid, pg_temp.sf_lines(:'turmeric'::uuid, 1, 'OLD')) AS grn_old \gset
SELECT id AS lot_old FROM public.goodsreceived_trl WHERE gr_id = :'grn_old' \gset
SELECT pg_temp.sf_dispatch(:'sf_admin_claims'::jsonb, 'CED5', :'lot_old'::uuid, 10) AS disp_5 \gset
UPDATE public.stock_movements SET created_at = now() - interval '400 days' WHERE gr_trl_id = :'lot_old';
SELECT gen_random_uuid() AS grn_imp, gen_random_uuid() AS lot_imp \gset
BEGIN;
SET LOCAL session_replication_role = replica;
INSERT INTO public.goodsreceived(id, gr_no, date, customer_id, customer_name, invoiced, pricing_mode)
  VALUES (:'grn_imp', 'CEI', '2026-04-02T10:00:00Z', :'west', 'Copy Emptied West', false, 'MONTHLY');
INSERT INTO public.goodsreceived_trl(id, gr_id, item_id, item_name, packaging, qty, weight, stock, rack, package_mark)
  VALUES (:'lot_imp', :'grn_imp', :'turmeric', 'Copy Emptied Turmeric', 'Bag', 5, 5, 0, 'R2', 'IMP');
COMMIT;
SELECT pg_temp.sf_first_load(p) FROM unnest(ARRAY['admin', 'staff', 'reader']) p;
SELECT pg_temp.sf_assert(pg_temp.et_server(:'lot_old') < now() - interval '399 days' AND pg_temp.et_server(:'lot_imp') IS NULL, 'premise: one old time, one lot without a movement');
SELECT pg_temp.sf_assert(pg_temp.et_phone(p, :'lot_old') = pg_temp.et_server(:'lot_old') AND pg_temp.et_phone(p, :'lot_imp') IS NULL,
  'B2: ' || p || ' holds the 400-day-old emptied time as stored, and null for a lot at zero with no movement') FROM unnest(ARRAY['admin', 'staff', 'reader']) p;
SELECT pg_temp.et_check(:'west', 1, 'old and imported lots');

\echo 'WH-299 sync lot emptied time (B2) checks passed.'

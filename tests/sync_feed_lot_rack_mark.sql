-- WH-302 B11: a change made by set_lot_rack_and_mark (topic "lot rack and mark change") reaches the phones through the change feed with
-- no feed change: the lot row (rack, package_mark) and its GRN row (updated_at, updated_by, the edit token) arrive as upserts for staff and
-- for the lot's customer account, a customer account of another customer receives neither, and the two log entries are one transaction.
-- Contract ~/ws/fresh/product/tech/app-offline-quick-change.md section 2.1 ("GRN change mark") and section 6 B11. tests/migrations.sh pipes
-- tests/fixtures/gst_details.sql and tests/sync_feed_contract.sql in front of this file, in the sync feed database of its own; this file
-- commits. Every other feed name is in tests/sync_feed_contract.sql. Fictional data only.
\set ON_ERROR_STOP on

-- One call of the function as a caller; the answer must be a success.
CREATE FUNCTION pg_temp.lm_change(claims jsonb, lot uuid, changes jsonb, request_key text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  r := pg_temp.sf_as(claims, format('SELECT public.set_lot_rack_and_mark(%L::uuid, %L::jsonb, %L)', lot, changes, request_key));
  PERFORM pg_temp.sf_assert(r->>'success' = 'true', 'B11: set_lot_rack_and_mark: ' || left(r::text, 300));
  RETURN r;
END $$;
-- The row a phone holds.
CREATE FUNCTION pg_temp.lm_row(p text, ent text, rid uuid) RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT c.row FROM pg_temp.sf_copy c WHERE c.slot = p AND c.e = ent AND c.id = rid::text $$;

INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888897702', 'Lot Mark Feed Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888897711', 'Lot Mark Feed Reader', 'customer', true, 'approved'),
 (gen_random_uuid(), '919888897712', 'Lot Mark Feed Outsider', 'customer', true, 'approved');
SELECT pg_temp.sf_login('9888897702') AS staff_claims \gset
SELECT pg_temp.sf_login('9888897711') AS reader_claims \gset
SELECT pg_temp.sf_login('9888897712') AS outsider_claims \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_customer(''Lot Mark Feed West'', ''9888897721'')')->>'success' = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_customer(''Lot Mark Feed East'', ''9888897722'')')->>'success' = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_item(''Lot Mark Feed Cumin'', ''Bag'')')->>'success' = 'true', 'customers and item');
SELECT id AS west FROM public.customers WHERE name = 'Lot Mark Feed West' \gset
SELECT id AS east FROM public.customers WHERE name = 'Lot Mark Feed East' \gset
SELECT id AS cumin FROM public.items WHERE name = 'Lot Mark Feed Cumin' \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT to_jsonb(public.assign_customer_to_user(%L, %L::uuid, %L))', '919888897711', :'west', 'Lot mark feed fixture'))::text = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT to_jsonb(public.assign_customer_to_user(%L, %L::uuid, %L))', '919888897712', :'east', 'Lot mark feed fixture'))::text = 'true',
  'the customer accounts are assigned');
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'LMF1', :'west'::uuid, pg_temp.sf_lines(:'cumin'::uuid, 2, 'LM')) AS grn_a \gset
SELECT id AS lot_a1 FROM public.goodsreceived_trl WHERE gr_id = :'grn_a' AND package_mark = 'LM1' \gset
SELECT id AS lot_a2 FROM public.goodsreceived_trl WHERE gr_id = :'grn_a' AND package_mark = 'LM2' \gset
SELECT pg_temp.sf_phone('admin', :'sf_admin_claims'::jsonb);
SELECT pg_temp.sf_phone('staff', :'staff_claims'::jsonb);
SELECT pg_temp.sf_phone('reader', :'reader_claims'::jsonb);
SELECT pg_temp.sf_phone('outsider', :'outsider_claims'::jsonb);
SELECT pg_temp.sf_first_load(p) FROM unnest(ARRAY['admin', 'staff', 'reader', 'outsider']) p;
SELECT pg_temp.sf_assert(pg_temp.lm_row(p, 'goodsreceived_trl', :'lot_a1'::uuid)->>'rack' = 'R1', 'premise: ' || p || ' holds the lot on R1')
  FROM unnest(ARRAY['admin', 'staff', 'reader']) p;
SELECT pg_temp.sf_assert(pg_temp.lm_row('outsider', 'goodsreceived_trl', :'lot_a1'::uuid) IS NULL, 'premise: another customer''s account does not hold the lot');
SELECT updated_at AS token_before FROM public.goodsreceived WHERE id = :'grn_a' \gset

-- The change, made by staff.
SELECT pg_temp.lm_change(:'staff_claims'::jsonb, :'lot_a1'::uuid,
  '{"rack":{"to":"FEED-R","from":"R1"},"package_mark":{"to":"FEED-M","from":"LM1"}}', 'lm-feed-1') AS answer \gset
SELECT pg_temp.sf_assert((SELECT rack = 'FEED-R' AND package_mark = 'FEED-M' FROM public.goodsreceived_trl WHERE id = :'lot_a1'::uuid), 'premise: the server holds the new rack and mark');
SELECT pg_temp.sf_assert((SELECT updated_at > :'token_before'::timestamptz FROM public.goodsreceived WHERE id = :'grn_a'), 'premise: the GRN change mark moved');

SELECT pg_temp.sf_pull(p) FROM unnest(ARRAY['admin', 'staff', 'reader', 'outsider']) p;
SELECT pg_temp.sf_assert(pg_temp.sf_diff(p) = '', 'B11: the copy of ' || p || ' equals a fresh load after the change: ' || pg_temp.sf_diff(p))
  FROM unnest(ARRAY['admin', 'staff', 'reader', 'outsider']) p;
SELECT pg_temp.sf_assert(pg_temp.lm_row(p, 'goodsreceived_trl', :'lot_a1'::uuid)->>'rack' = 'FEED-R'
  AND pg_temp.lm_row(p, 'goodsreceived_trl', :'lot_a1'::uuid)->>'package_mark' = 'FEED-M',
  'B11: ' || p || ' holds the new rack and mark of the lot')
  FROM unnest(ARRAY['admin', 'staff', 'reader']) p;
SELECT pg_temp.sf_assert(pg_temp.sf_ops(p, 'goodsreceived_trl', :'lot_a1', pg_temp.sf_last_pull(p)) = pg_temp.sf('op_upsert'),
  'B11: the lot reached ' || p || ' as an upsert') FROM unnest(ARRAY['admin', 'staff', 'reader']) p;
-- The GRN row came with it, carrying the edit token an open "Edit GRN" is checked against.
SELECT pg_temp.sf_assert(pg_temp.sf_ops(p, 'goodsreceived', :'grn_a', pg_temp.sf_last_pull(p)) = pg_temp.sf('op_upsert')
  AND date_trunc('milliseconds', (pg_temp.lm_row(p, 'goodsreceived', :'grn_a'::uuid)->>'updated_at')::timestamptz)
    = (SELECT date_trunc('milliseconds', updated_at) FROM public.goodsreceived WHERE id = :'grn_a'),
  'B11: the GRN reached ' || p || ' as an upsert with its new updated_at') FROM unnest(ARRAY['admin', 'staff', 'reader']) p;
-- The neighbouring lot did not change; the outsider received neither row.
SELECT pg_temp.sf_assert(pg_temp.lm_row('staff', 'goodsreceived_trl', :'lot_a2'::uuid)->>'rack' = 'R1' AND pg_temp.lm_row('staff', 'goodsreceived_trl', :'lot_a2'::uuid)->>'package_mark' = 'LM2',
  'B11: the other lot of the GRN is as it was on the staff phone');
SELECT pg_temp.sf_assert(pg_temp.lm_row('outsider', 'goodsreceived_trl', :'lot_a1'::uuid) IS NULL AND pg_temp.lm_row('outsider', 'goodsreceived', :'grn_a'::uuid) IS NULL
  AND pg_temp.sf_ops('outsider', 'goodsreceived_trl', :'lot_a1', pg_temp.sf_last_pull('outsider')) = '',
  'B11: another customer''s account receives neither the lot nor the GRN');
-- One transaction: the lot's last log entry and the GRN's last log entry carry the same transaction id.
SELECT xid::text AS lot_xid FROM warehouse_sync.change_log WHERE tbl = 'goodsreceived_trl' AND row_key = :'lot_a1' ORDER BY xid DESC LIMIT 1 \gset
SELECT xid::text AS grn_xid FROM warehouse_sync.change_log WHERE tbl = 'goodsreceived' AND row_key = :'grn_a' ORDER BY xid DESC LIMIT 1 \gset
SELECT pg_temp.sf_assert(:'lot_xid' = :'grn_xid', 'B11: the lot row and the GRN row of the change are one transaction in the change log (' || :'lot_xid' || ' and ' || :'grn_xid' || ')');

-- A call that writes nothing (to equal to stored) logs nothing: the phones have nothing to pull.
SELECT pg_temp.lm_change(:'staff_claims'::jsonb, :'lot_a1'::uuid, '{"rack":{"to":"FEED-R","from":"FEED-R"}}', 'lm-feed-noop') AS noop \gset
SELECT pg_temp.sf_pull('staff') AS quiet \gset
SELECT pg_temp.sf_assert(pg_temp.sf_ops('staff', 'goodsreceived_trl', :'lot_a1', pg_temp.sf_last_pull('staff')) = ''
  AND pg_temp.sf_ops('staff', 'goodsreceived', :'grn_a', pg_temp.sf_last_pull('staff')) = '', 'B11: a call that writes nothing logs nothing for the lot or the GRN');

\echo 'WH-302 sync feed lot rack and mark (B11) checks passed.'

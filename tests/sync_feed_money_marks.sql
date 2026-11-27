-- WH-305, backend slice (test-first, nothing built): money marks for goods, rates and settings, and the feed format step.
-- Contract ~/ws/fresh/product/tech/app-offline-dues-statement.md section 7 and cases B1-B4 of section 9, with Product's PQ1-PQ6 and
-- Design's DQ answers of the card (none of them changes the server side). Backend topic by name: "money marks for goods, rates and
-- settings"; no migration number is used here.
-- tests/migrations.sh pipes tests/fixtures/gst_details.sql and tests/sync_feed_contract.sql in front of this file, in the sync feed
-- database of its own; this file commits. Fictional data only.
--
-- AGREE WITH DEVELOPMENT (WH-305), the guesses of this file:
--   1. A mark is the entry {"e":"money","id":<customer id or 'all'>,"op":"stale"} and nothing else (contract 7.2: the shape is unchanged).
--   2. The tables of 7.1 mark the customer of the row, for the old and the new value: goodsreceived, goodsreceived_trl, dispatch,
--      dispatch_trl, grn_rates (through their GRN or dispatch) and customers. A write that changes a column of the customer row
--      "name or active" marks the customer; this file writes the name and the active flag and asserts no other column.
--   3. 'all' (the row_key of the mark) follows a change of an item rate (item_storage_prices, here through replace_item_rates), the
--      charging rule (set_charging_rule), the GST settings (set_gst_details) and the record-payments setting (set_record_payments).
--      A phone that gets 'all' gets exactly that one mark for the change, not one per customer.
--   4. 'all' reaches admin, supervisor and every customer account (each account gets it, whatever its customer), never staff.
--   5. The feed format is 4 after this set (it is 3 at the base commit); the copy key is '<format>.<log id>.<access>' as today.
--      sync_feed_invoice_state.sql and sync_feed_orders_payments.sql assert format 3 and must be moved to 4 when the step is
--      assembled (not changed here: not this card's files).
--   6. An existing database whose log trigger fires on a no-change UPDATE is not relied upon: every write below changes a value.
-- Cases: B1 each table of 7.1 (old and new customer), B2 the four settings, B3 who receives what (every round), B4 the format step.
-- B5 (dues and statement figures unchanged) is tests/dues-figures-unchanged-wh305.test.mjs plus Test's dues-figures-snapshot.mjs run.
\set ON_ERROR_STOP on

-- The money marks a phone met in its last pull, sorted and distinct.
CREATE FUNCTION pg_temp.mm_marks(p text) RETURNS text[] LANGUAGE sql STABLE AS $$
  SELECT COALESCE(array_agg(d ORDER BY d), '{}') FROM (SELECT DISTINCT detail AS d FROM pg_temp.sf_event
    WHERE phone = p AND kind = 'stale' AND pull = pg_temp.sf_last_pull(p)) t $$;
CREATE FUNCTION pg_temp.mm_sorted(a text[]) RETURNS text[] LANGUAGE sql IMMUTABLE AS $$ SELECT COALESCE(array_agg(x ORDER BY x), '{}') FROM unnest(a) x $$;

-- One round: every phone pulls, then B3. Administrator and supervisor hold the marks of want_admin, the customer accounts those of
-- want_c1 and want_c2, staff none (the first B1 round also shows staff hear of the change itself, so "none" is not a dead phone).
CREATE FUNCTION pg_temp.mm_round(label text, want_admin text[], want_c1 text[], want_c2 text[]) RETURNS void LANGUAGE plpgsql AS $$
DECLARE p text;
BEGIN
  FOREACH p IN ARRAY ARRAY['admin', 'supervisor', 'staff', 'c1', 'c2'] LOOP PERFORM pg_temp.sf_pull(p); END LOOP;
  PERFORM pg_temp.sf_assert(pg_temp.mm_marks('admin') = pg_temp.mm_sorted(want_admin),
    format('%s: administrator marks %s, expected %s', label, pg_temp.mm_marks('admin'), pg_temp.mm_sorted(want_admin)));
  PERFORM pg_temp.sf_assert(pg_temp.mm_marks('supervisor') = pg_temp.mm_sorted(want_admin),
    format('%s: supervisor marks %s, expected %s', label, pg_temp.mm_marks('supervisor'), pg_temp.mm_sorted(want_admin)));
  PERFORM pg_temp.sf_assert(pg_temp.mm_marks('staff') = '{}',
    format('B3 %s: staff receive no money mark, got %s', label, pg_temp.mm_marks('staff')));
  PERFORM pg_temp.sf_assert(pg_temp.mm_marks('c1') = pg_temp.mm_sorted(want_c1),
    format('%s: North''s account marks %s, expected %s', label, pg_temp.mm_marks('c1'), pg_temp.mm_sorted(want_c1)));
  PERFORM pg_temp.sf_assert(pg_temp.mm_marks('c2') = pg_temp.mm_sorted(want_c2),
    format('%s: South''s account marks %s, expected %s', label, pg_temp.mm_marks('c2'), pg_temp.mm_sorted(want_c2)));
END $$;

-- ---------------------------------------------------------------------------------------------------------------------------------
-- Fixture. Phones: admin, supervisor, staff, c1 (account of North), c2 (account of South). One item, a monthly rate for North and
-- South (so that their GRNs carry grn_rates rows).
-- ---------------------------------------------------------------------------------------------------------------------------------
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888897602', 'Money Mark Staff Person', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888897603', 'Money Mark Supervisor', 'supervisor', true, 'approved'),
 (gen_random_uuid(), '919888897611', 'Money Mark North Reader', 'customer', true, 'approved'),
 (gen_random_uuid(), '919888897612', 'Money Mark South Reader', 'customer', true, 'approved');
SELECT pg_temp.sf_login('9888897602') AS staff_claims \gset
SELECT pg_temp.sf_login('9888897603') AS supervisor_claims \gset
SELECT pg_temp.sf_login('9888897611') AS c1_claims \gset
SELECT pg_temp.sf_login('9888897612') AS c2_claims \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_customer(''Money Mark North'', ''9888897621'')')->>'success' = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_customer(''Money Mark South'', ''9888897622'')')->>'success' = 'true', 'customers');
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_item(''Money Mark Garlic'', ''Bag'')')->>'success' = 'true', 'item');
SELECT id AS north FROM public.customers WHERE name = 'Money Mark North' \gset
SELECT id AS south FROM public.customers WHERE name = 'Money Mark South' \gset
SELECT id AS garlic FROM public.items WHERE name = 'Money Mark Garlic' \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT to_jsonb(public.assign_customer_to_user(%L, %L::uuid, %L))', '919888897611', :'north', 'Money mark fixture'))::text = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT to_jsonb(public.assign_customer_to_user(%L, %L::uuid, %L))', '919888897612', :'south', 'Money mark fixture'))::text = 'true',
  'customer accounts assigned');
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.replace_item_rates(%L::uuid, %L::uuid, %L, %L::date, %L::jsonb)', :'garlic', :'north', 'monthly', '2026-01-01',
  '[{"weight_min":0,"weight_max":100,"unit_price":5,"labour_rate":2,"tax_percent":5}]'))->>'success' = 'true', 'monthly rate for North');
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.replace_item_rates(%L::uuid, %L::uuid, %L, %L::date, %L::jsonb)', :'garlic', :'south', 'monthly', '2026-01-01',
  '[{"weight_min":0,"weight_max":100,"unit_price":5,"labour_rate":2,"tax_percent":5}]'))->>'success' = 'true', 'monthly rate for South');

-- One GRN each (North's has two lots), one dispatch of North's.
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'MMN1', :'north'::uuid, pg_temp.sf_lines(:'garlic'::uuid, 2, 'MN')) AS grn_n \gset
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'MMS1', :'south'::uuid, pg_temp.sf_lines(:'garlic'::uuid, 1, 'MS')) AS grn_s \gset
SELECT id AS lot_n1 FROM public.goodsreceived_trl WHERE gr_id = :'grn_n' AND package_mark = 'MN1' \gset
SELECT id AS lot_n2 FROM public.goodsreceived_trl WHERE gr_id = :'grn_n' AND package_mark = 'MN2' \gset
SELECT pg_temp.sf_dispatch(:'sf_admin_claims'::jsonb, 'MMND1', :'lot_n2'::uuid, 2) AS disp_n \gset
SELECT id AS disp_line FROM public.dispatch_trl WHERE disp_id = :'disp_n' \gset
SELECT pg_temp.sf_assert((SELECT count(*) > 0 FROM public.grn_rates WHERE gr_id = :'grn_n'),
  'premise: the GRN of North has a grn_rates row (the monthly rate was applied at save)');

SELECT pg_temp.sf_phone('admin', :'sf_admin_claims'::jsonb);
SELECT pg_temp.sf_phone('supervisor', :'supervisor_claims'::jsonb);
SELECT pg_temp.sf_phone('staff', :'staff_claims'::jsonb);
SELECT pg_temp.sf_phone('c1', :'c1_claims'::jsonb);
SELECT pg_temp.sf_phone('c2', :'c2_claims'::jsonb);
SELECT pg_temp.sf_first_load(p) FROM unnest(ARRAY['admin', 'supervisor', 'staff', 'c1', 'c2']) p;

-- B4 (part 1): the format step. Every role's start and copy key say format 4, and a copy key of format 3 (an app that loaded before
-- the step) is told to load everything again, as at every earlier step.
SELECT pg_temp.sf_assert((SELECT count(*) = 5 AND bool_and(answer->>pg_temp.sf('f_format') = '4' AND answer->>pg_temp.sf('f_copy') LIKE '4.%')
    FROM pg_temp.sf_answer WHERE kind = 'start'),
  'B4: get_sync_start answers format 4 and a format-4 copy key to every role: '
  || (SELECT string_agg(phone || ' ' || COALESCE(answer->>pg_temp.sf('f_format'), '(none)'), ', ') FROM pg_temp.sf_answer WHERE kind = 'start'));
SELECT pg_temp.sf_changes_once('admin') AS plain_changes \gset
SELECT pg_temp.sf_assert(:'plain_changes'::jsonb->>pg_temp.sf('f_format') = '4', 'B4: get_sync_changes answers format 4: ' || left(:'plain_changes', 300));
SELECT pg_temp.sf_changes_once('admin', NULL, regexp_replace(copy, '^[0-9]+\.', '3.')) AS old_copy FROM pg_temp.sf_device WHERE phone = 'admin' \gset
SELECT pg_temp.sf_assert(:'old_copy'::jsonb#>>ARRAY[pg_temp.sf('f_reload_all'), pg_temp.sf('f_reason')] = pg_temp.sf('r_format'),
  'B4: a copy key of format 3 answers reload_all FORMAT_CHANGED: ' || left(:'old_copy', 300));
SELECT pg_temp.sf_assert(pg_temp.sf_diff(p) = '', 'fixture: the copy of ' || p || ' equals a fresh load: ' || pg_temp.sf_diff(p))
  FROM unnest(ARRAY['admin', 'supervisor', 'staff', 'c1', 'c2']) p;
SELECT pg_temp.mm_round('fixture', '{}', '{}', '{}');

-- ---------------------------------------------------------------------------------------------------------------------------------
-- B1. One table per round, one value changed by a plain update (no function writes a second table), the customer's mark for the old
-- and for the new customer. North and South hold one GRN each.
-- ---------------------------------------------------------------------------------------------------------------------------------
-- goodsreceived: a note on North's GRN.
UPDATE public.goodsreceived SET note = 'money mark: goodsreceived' WHERE id = :'grn_n';
SELECT pg_temp.mm_round('B1 goodsreceived', ARRAY[:'north'], ARRAY[:'north'], '{}');
SELECT pg_temp.sf_assert(pg_temp.sf_ops('staff', 'goodsreceived', :'grn_n', pg_temp.sf_last_pull('staff')) = pg_temp.sf('op_upsert'),
  'B3: staff still hear of the GRN change itself (the empty mark list above is not a dead phone)');

-- goodsreceived_trl: the rack of one lot.
UPDATE public.goodsreceived_trl SET rack = 'R9' WHERE id = :'lot_n1';
SELECT pg_temp.mm_round('B1 goodsreceived_trl', ARRAY[:'north'], ARRAY[:'north'], '{}');

-- dispatch: a note on North's dispatch.
UPDATE public.dispatch SET note = 'money mark: dispatch' WHERE id = :'disp_n';
SELECT pg_temp.mm_round('B1 dispatch', ARRAY[:'north'], ARRAY[:'north'], '{}');

-- dispatch_trl: a column of the dispatch line that no other table mirrors.
UPDATE public.dispatch_trl SET cart_quantity_consumed = cart_quantity_consumed + 1 WHERE id = :'disp_line';
SELECT pg_temp.mm_round('B1 dispatch_trl', ARRAY[:'north'], ARRAY[:'north'], '{}');

-- grn_rates: the unit price of one rate row of North's GRN.
UPDATE public.grn_rates SET unit_price = unit_price + 1 WHERE id = (SELECT id FROM public.grn_rates WHERE gr_id = :'grn_n' ORDER BY id LIMIT 1);
SELECT pg_temp.mm_round('B1 grn_rates', ARRAY[:'north'], ARRAY[:'north'], '{}');

-- customers: the name, then the active flag (off and on again within the round: the customer's own account must be live when it pulls).
UPDATE public.customers SET name = 'Money Mark North Renamed' WHERE id = :'north';
SELECT pg_temp.mm_round('B1 customers name', ARRAY[:'north'], ARRAY[:'north'], '{}');
UPDATE public.customers SET active = false WHERE id = :'south';
UPDATE public.customers SET active = true WHERE id = :'south';
SELECT pg_temp.mm_round('B1 customers active', ARRAY[:'south'], '{}', ARRAY[:'south']);

-- A GRN moved between customers marks both: North's second GRN (new) is saved, then moved to South by update_grn.
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'MMN2', :'north'::uuid, pg_temp.sf_lines(:'garlic'::uuid, 1, 'MM')) AS grn_m \gset
SELECT pg_temp.mm_round('B1 a new GRN', ARRAY[:'north'], ARRAY[:'north'], '{}');
SELECT pg_temp.sf_update_grn(:'sf_admin_claims'::jsonb, :'grn_m'::uuid, pg_temp.sf_current_lines(:'grn_m'::uuid), :'south'::uuid);
SELECT pg_temp.sf_assert((SELECT customer_id FROM public.goodsreceived WHERE id = :'grn_m') = :'south'::uuid, 'premise: MMN2 belongs to South');
SELECT pg_temp.mm_round('B1 a GRN moved from North to South', ARRAY[:'north', :'south'], ARRAY[:'north'], ARRAY[:'south']);

-- ---------------------------------------------------------------------------------------------------------------------------------
-- B2. The four settings each write one mark 'all', which reaches the administrator, the supervisor and every customer account.
-- ---------------------------------------------------------------------------------------------------------------------------------
-- An item rate (the customer rate of North, a new price).
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.replace_item_rates(%L::uuid, %L::uuid, %L, %L::date, %L::jsonb)', :'garlic', :'north', 'monthly', '2026-01-01',
  '[{"weight_min":0,"weight_max":100,"unit_price":6,"labour_rate":2,"tax_percent":5}]'))->>'success' = 'true', 'fixture: a new price for North');
SELECT pg_temp.mm_round('B2 item rate', ARRAY['all'], ARRAY['all'], ARRAY['all']);

-- The charging rule.
SELECT warehouse_security.charging_rule_json(r)::text AS rule_before FROM warehouse_security.charging_rule r WHERE r.id \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, $q$SELECT public.set_charging_rule('{"step_days":30,"minimum_days":60,"days_counted":"standard","rounding":"nearest"}'::jsonb)$q$)->>'success' = 'true', 'fixture: set_charging_rule');
SELECT pg_temp.sf_assert((SELECT warehouse_security.charging_rule_json(r)::text FROM warehouse_security.charging_rule r WHERE r.id) <> :'rule_before',
  'premise: the charging rule changed (a rule equal to the stored one writes nothing)');
SELECT pg_temp.mm_round('B2 charging rule', ARRAY['all'], ARRAY['all'], ARRAY['all']);

-- The GST settings.
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, $q$SELECT public.set_gst_details('{"registered":true,"gstin":"24AAAAA0000A1Z5","address":"1 Demo Road, Demo City","legal_name":"Money Mark Cold Storage One"}'::jsonb)$q$)->>'success' = 'true', 'fixture: set_gst_details');
SELECT pg_temp.mm_round('B2 GST settings', ARRAY['all'], ARRAY['all'], ARRAY['all']);

-- The record-payments setting (the other way from what it is now).
SELECT record_payments AS payments_before FROM warehouse_security.charging_rule WHERE id \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.set_record_payments(%L::boolean)', NOT :'payments_before'::boolean))->>'changed' = 'true', 'fixture: set_record_payments changes the setting');
SELECT pg_temp.mm_round('B2 record payments', ARRAY['all'], ARRAY['all'], ARRAY['all']);

-- ---------------------------------------------------------------------------------------------------------------------------------
-- B4 (part 2): the mark's shape is unchanged, so an older app that applies the feed meets nothing new: every money entry of every
-- phone in this run is exactly {e, id, op:'stale'}; and nothing but customers' ids and 'all' is ever a mark id.
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT pg_temp.sf_assert((SELECT count(*) > 10 FROM pg_temp.sf_entry WHERE e = pg_temp.sf('e_money')), 'premise: the run met many money entries');
SELECT pg_temp.sf_assert((SELECT count(*) = 0 FROM pg_temp.sf_entry
    WHERE e = pg_temp.sf('e_money') AND entry IS DISTINCT FROM jsonb_build_object('e', 'money', 'id', id, 'op', 'stale')),
  'B4: every money entry is exactly {e, id, op: stale}: ' || COALESCE((SELECT entry::text FROM pg_temp.sf_entry
    WHERE e = pg_temp.sf('e_money') AND entry IS DISTINCT FROM jsonb_build_object('e', 'money', 'id', id, 'op', 'stale') LIMIT 1), ''));
SELECT pg_temp.sf_assert((SELECT count(*) = 0 FROM pg_temp.sf_entry
    WHERE e = pg_temp.sf('e_money') AND id NOT IN (SELECT id::text FROM public.customers) AND id <> 'all'),
  'a mark id is a customer id or all');
SELECT pg_temp.sf_assert(pg_temp.sf_diff(p) = '', 'at the end the copy of ' || p || ' equals a fresh load: ' || pg_temp.sf_diff(p))
  FROM unnest(ARRAY['admin', 'supervisor', 'staff', 'c1', 'c2']) p;

\echo 'WH-305 money marks for goods, rates and settings (B1-B4) checks passed.'

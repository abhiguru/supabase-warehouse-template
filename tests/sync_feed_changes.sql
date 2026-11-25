-- WH-297, criteria 1 and 13 (no change missed; pages within the limit) and the feed's refusals, run one transaction after another in
-- one session. The concurrent half (several sessions saving while a phone polls, a long open transaction) is
-- tests/sync_feed_concurrency.sh. tests/migrations.sh pipes tests/sync_feed_contract.sql in front of this file, in the sync feed
-- database of its own; this file commits. Section numbers refer to ~/ws/fresh/product/tech/server-change-log-feed.md.
--
-- AGREE WITH DEVELOPMENT: every feed name used here is in the marked block of tests/sync_feed_contract.sql; this file adds none.
--
-- Phones (pg_temp.sf_device): admin, supervisor and staff, each signed in; each check compares a phone's copy with a fresh first
-- load of the same caller (pg_temp.sf_diff) and, where it says so, with a direct table read (pg_temp.sf_check_direct).
\set ON_ERROR_STOP on

-- Fixture people and the catalogue.
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888897002', 'Sync Feed Staff Person', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888897003', 'Sync Feed Supervisor', 'supervisor', true, 'approved'),
 (gen_random_uuid(), '919888897004', 'Sync Feed Leaver', 'staff', true, 'approved');
SELECT pg_temp.sf_login('9888897002') AS staff_claims \gset
SELECT pg_temp.sf_login('9888897003') AS supervisor_claims \gset
SELECT pg_temp.sf_login('9888897004') AS leaver_claims \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_customer(''Sync Feed North'', ''9888897021'')')->>'success' = 'true', 'customer North');
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_item(''Sync Feed Onions'', ''Bag'')')->>'success' = 'true', 'item');
SELECT id AS north FROM public.customers WHERE name = 'Sync Feed North' \gset
SELECT id AS onions FROM public.items WHERE name = 'Sync Feed Onions' \gset

-- ---------------------------------------------------------------------------------------------------------------------------------
-- Refusals [3, 10]: no session, a deactivated account, bad input.
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT pg_temp.sf_try('anon', NULL, pg_temp.sf('call_start')) AS anon_start \gset
SELECT pg_temp.sf_assert(:'anon_start'::jsonb ? 'sqlstate', 'anon is refused get_sync_start: ' || :'anon_start');
SELECT pg_temp.sf_try('anon', NULL, format(pg_temp.sf('call_changes'), '1', 'x', 10)) AS anon_changes \gset
SELECT pg_temp.sf_assert(:'anon_changes'::jsonb ? 'sqlstate', 'anon is refused get_sync_changes: ' || :'anon_changes');
UPDATE public.user_profiles SET active = false WHERE mobile = '919888897004';
SELECT pg_temp.sf_try('authenticated', :'leaver_claims'::jsonb, pg_temp.sf('call_start')) AS leaver_start \gset
SELECT pg_temp.sf_assert(:'leaver_start'::jsonb->>'sqlstate' = '42501', 'a deactivated account is refused get_sync_start (42501): ' || :'leaver_start');
SELECT pg_temp.sf_try('authenticated', :'leaver_claims'::jsonb, format(pg_temp.sf('call_page'), 'goodsreceived', NULL, 10)) AS leaver_page \gset
SELECT pg_temp.sf_assert(:'leaver_page'::jsonb->>'sqlstate' = '42501', 'a deactivated account is refused get_sync_page (42501): ' || :'leaver_page');

SELECT pg_temp.sf_phone('admin', :'sf_admin_claims'::jsonb);
SELECT pg_temp.sf_phone('supervisor', :'supervisor_claims'::jsonb);
SELECT pg_temp.sf_phone('staff', :'staff_claims'::jsonb);
SELECT pg_temp.sf_first_load('admin');
SELECT pg_temp.sf_first_load('supervisor');
SELECT pg_temp.sf_first_load('staff');
SELECT position AS admin_first_position, copy AS admin_copy FROM pg_temp.sf_device WHERE phone = 'admin' \gset
SELECT pg_temp.sf_assert(pg_temp.sf_diff('admin') = '', 'premise: a copy just loaded equals a fresh load');

SELECT pg_temp.sf_as(:'sf_admin_claims'::jsonb, format(pg_temp.sf('call_changes'), 'not-a-position', :'admin_copy', 10)) AS bad_position \gset
SELECT pg_temp.sf_assert(:'bad_position'::jsonb->>'success' = 'false' AND :'bad_position'::jsonb->>pg_temp.sf('f_refusal') = pg_temp.sf('err_position'),
  'a position that is not a decimal id is refused: ' || :'bad_position');
SELECT pg_temp.sf_as(:'sf_admin_claims'::jsonb, format(pg_temp.sf('call_changes'), :'admin_first_position', 'not-a-copy-key', 10)) AS bad_copy \gset
SELECT pg_temp.sf_assert(:'bad_copy'::jsonb->>'success' = 'false' AND :'bad_copy'::jsonb->>pg_temp.sf('f_refusal') = pg_temp.sf('err_copy'),
  'an unknown copy key is refused: ' || :'bad_copy');
SELECT pg_temp.sf_as(:'sf_admin_claims'::jsonb, format(pg_temp.sf('call_page'), 'no_such_table', NULL, 10)) AS bad_entity \gset
SELECT pg_temp.sf_assert(:'bad_entity'::jsonb->>'success' = 'false' AND :'bad_entity'::jsonb->>pg_temp.sf('f_refusal') = pg_temp.sf('err_entity'),
  'an unknown entity is refused: ' || :'bad_entity');

-- Criterion 12d: staff load no user_profiles, no assignments and no charging rule; asking for user_profiles is an unknown entity.
SELECT pg_temp.sf_assert(NOT ('user_profiles' = ANY (entities)) AND NOT ('users_customers_new' = ANY (entities)), '12d: staff load no user_profiles or assignments: ' || entities::text)
  FROM pg_temp.sf_device WHERE phone = 'staff';
SELECT pg_temp.sf_as(:'staff_claims'::jsonb, format(pg_temp.sf('call_page'), 'user_profiles', NULL, 10)) AS staff_profiles \gset
SELECT pg_temp.sf_assert(:'staff_profiles'::jsonb->>pg_temp.sf('f_refusal') = pg_temp.sf('err_entity'), '12d: staff asking for user_profiles get the unknown-entity refusal: ' || :'staff_profiles');
SELECT pg_temp.sf_assert(NOT (pg_temp.sf('settings_charging_rule') = ANY (pg_temp.sf_held('staff', pg_temp.sf('e_settings')))), '12d: staff hold no charging rule');
SELECT pg_temp.sf_assert(pg_temp.sf('settings_charging_rule') = ANY (pg_temp.sf_held('admin', pg_temp.sf('e_settings'))), 'premise: the administrator holds the charging rule');
SELECT pg_temp.sf_assert(pg_temp.sf_check_direct('admin') = '', '12a: the administrator''s first load equals the direct reads: ' || pg_temp.sf_check_direct('admin'));
SELECT pg_temp.sf_assert(pg_temp.sf_check_direct('supervisor') = '', '12a: the supervisor''s first load equals the direct reads: ' || pg_temp.sf_check_direct('supervisor'));
SELECT pg_temp.sf_assert(pg_temp.sf_check_direct('staff') = '', '12a: the staff first load equals the direct reads: ' || pg_temp.sf_check_direct('staff'));

-- ---------------------------------------------------------------------------------------------------------------------------------
-- 1. Saves committed one after another, two of them in one transaction by two people; a settings change staff must not get.
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'SFA1', :'north'::uuid, pg_temp.sf_lines(:'onions'::uuid, 3, 'M')) AS grn_a1 \gset
SELECT pg_temp.sf_save_grn(:'staff_claims'::jsonb, 'SFA2', :'north'::uuid, pg_temp.sf_lines(:'onions'::uuid, 2, 'N')) AS grn_a2 \gset
BEGIN;
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'SFA3', :'north'::uuid, pg_temp.sf_lines(:'onions'::uuid, 2, 'O')) AS grn_a3 \gset
SELECT pg_temp.sf_save_grn(:'staff_claims'::jsonb, 'SFA4', :'north'::uuid, pg_temp.sf_lines(:'onions'::uuid, 2, 'P')) AS grn_a4 \gset
COMMIT;
UPDATE warehouse_security.charging_rule SET invoice_as_goods_leave = true WHERE id;
UPDATE warehouse_security.charging_rule SET invoice_as_goods_leave = false WHERE id;
-- A photo the administrator registered and left pending: staff never get another person's pending photo (12d).
SELECT pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.register_grn_image_upload(%L::uuid, %L, %L, 32, %L)', :'grn_a1', 'header', 'a.webp', 'image/webp')) AS pending_photo \gset
SELECT (:'pending_photo'::jsonb->>'image_id') AS pending_photo_id \gset
SELECT pg_temp.sf_assert(pg_temp.sf_diff('admin') <> '', 'premise: the saves are not in the administrator''s copy before a pull');
SELECT pg_temp.sf_pull('admin');
SELECT pg_temp.sf_pull('supervisor');
SELECT pg_temp.sf_pull('staff') AS staff_pull_1 \gset
SELECT pg_temp.sf_assert(pg_temp.sf_diff('admin') = '', '1: after one pull the administrator''s copy equals a fresh load: ' || pg_temp.sf_diff('admin'));
SELECT pg_temp.sf_assert(pg_temp.sf_diff('supervisor') = '', '1: the supervisor''s copy equals a fresh load: ' || pg_temp.sf_diff('supervisor'));
SELECT pg_temp.sf_assert(pg_temp.sf_diff('staff') = '', '1: the staff copy equals a fresh load: ' || pg_temp.sf_diff('staff'));
SELECT pg_temp.sf_assert(pg_temp.sf_held('admin', 'goodsreceived') @> ARRAY[:'grn_a1', :'grn_a2', :'grn_a3', :'grn_a4']::text[]
  AND (SELECT count(*) FROM pg_temp.sf_copy c WHERE c.slot = 'admin' AND c.e = 'goodsreceived_trl' AND c.row->>'gr_id' IN (:'grn_a1', :'grn_a2', :'grn_a3', :'grn_a4')) = 9,
  '1: the four GRNs and their nine lots are in the administrator''s copy');
SELECT pg_temp.sf_assert(pg_temp.sf_ops('staff', pg_temp.sf('e_settings'), pg_temp.sf('settings_charging_rule')) = ''
  AND pg_temp.sf_ops('admin', pg_temp.sf('e_settings'), pg_temp.sf('settings_charging_rule')) LIKE '%' || pg_temp.sf('op_upsert') || '%',
  '12d: the charging rule change reached the administrator and not staff');
SELECT pg_temp.sf_assert(:'pending_photo_id' = ANY (pg_temp.sf_held('admin', 'grn_images')) AND NOT (:'pending_photo_id' = ANY (pg_temp.sf_held('staff', 'grn_images')))
  AND pg_temp.sf_ops('staff', 'grn_images', :'pending_photo_id') = '', '12d: the administrator''s pending photo is in the administrator''s copy and never reached staff');

-- ---------------------------------------------------------------------------------------------------------------------------------
-- 1c. "Edit GRN" (update_grn): rack and quantity of one lot, the mark of another, one lot left out (deleted), one new line.
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT t.id AS lot_m1 FROM public.goodsreceived_trl t WHERE t.gr_id = :'grn_a1' AND t.package_mark = 'M1' \gset
SELECT t.id AS lot_m2 FROM public.goodsreceived_trl t WHERE t.gr_id = :'grn_a1' AND t.package_mark = 'M2' \gset
SELECT t.id AS lot_m3 FROM public.goodsreceived_trl t WHERE t.gr_id = :'grn_a1' AND t.package_mark = 'M3' \gset
SELECT pg_temp.sf_update_grn(:'staff_claims'::jsonb, :'grn_a1'::uuid,
  (SELECT jsonb_agg(CASE l->>'package_mark' WHEN 'M1' THEN l || '{"rack":"R9","qty":12}' WHEN 'M2' THEN l || '{"package_mark":"M2X"}' ELSE l END)
     FROM jsonb_array_elements(pg_temp.sf_current_lines(:'grn_a1'::uuid)) l WHERE l->>'package_mark' <> 'M3')
  || jsonb_build_array(jsonb_build_object('item_id', :'onions', 'item_name', 'Sync Feed Onions', 'packaging', 'Bag', 'qty', 7, 'weight', 5, 'rack', 'R4', 'package_mark', 'M4')));
SELECT t.id AS lot_m4 FROM public.goodsreceived_trl t WHERE t.gr_id = :'grn_a1' AND t.package_mark = 'M4' \gset
SELECT pg_temp.sf_assert((SELECT rack = 'R9' AND qty = 12 FROM public.goodsreceived_trl WHERE id = :'lot_m1') AND NOT EXISTS (SELECT 1 FROM public.goodsreceived_trl WHERE id = :'lot_m3'),
  'premise: the edit changed M1 and removed M3');
SELECT pg_temp.sf_assert(pg_temp.sf_diff('admin') <> '', 'premise: the edit is not in the copy before a pull');
SELECT pg_temp.sf_pull('admin');
SELECT pg_temp.sf_assert(pg_temp.sf_diff('admin') = '', '1c: after an "Edit GRN" save the copy equals a fresh load: ' || pg_temp.sf_diff('admin'));
SELECT pg_temp.sf_assert((SELECT row->>'rack' = 'R9' AND (row->>'qty')::int = 12 FROM pg_temp.sf_copy WHERE slot = 'admin' AND e = 'goodsreceived_trl' AND id = :'lot_m1')
  AND (SELECT row->>'package_mark' FROM pg_temp.sf_copy WHERE slot = 'admin' AND e = 'goodsreceived_trl' AND id = :'lot_m2') = 'M2X'
  AND :'lot_m4' = ANY (pg_temp.sf_held('admin', 'goodsreceived_trl')) AND NOT (:'lot_m3' = ANY (pg_temp.sf_held('admin', 'goodsreceived_trl'))),
  '1c: the copy has M1 on R9 with 12, M2 renamed, the new M4 and no M3');
SELECT pg_temp.sf_assert(pg_temp.sf_ops('admin', 'goodsreceived', :'grn_a1', pg_temp.sf_last_pull('admin')) = pg_temp.sf('op_upsert')
  AND pg_temp.sf_ops('admin', 'goodsreceived_trl', :'lot_m1', pg_temp.sf_last_pull('admin')) = pg_temp.sf('op_upsert')
  AND pg_temp.sf_ops('admin', 'goodsreceived_trl', :'lot_m2', pg_temp.sf_last_pull('admin')) = pg_temp.sf('op_upsert')
  AND pg_temp.sf_ops('admin', 'goodsreceived_trl', :'lot_m4', pg_temp.sf_last_pull('admin')) = pg_temp.sf('op_upsert')
  AND pg_temp.sf_ops('admin', 'goodsreceived_trl', :'lot_m3', pg_temp.sf_last_pull('admin')) = pg_temp.sf('op_delete'),
  '1c: the pull carried the GRN with every current lot (fan-out [5]) and the removed lot as a delete');

-- ---------------------------------------------------------------------------------------------------------------------------------
-- 1d. A dispatch lowers a lot's stock: the lot with the new stock and grn_lock with the dispatched quantity.
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT t.id AS lot_n1 FROM public.goodsreceived_trl t WHERE t.gr_id = :'grn_a2' AND t.package_mark = 'N1' \gset
SELECT pg_temp.sf_dispatch(:'sf_admin_claims'::jsonb, 'SFD1', :'lot_n1'::uuid, 4) AS disp_1 \gset
SELECT pg_temp.sf_assert((SELECT stock FROM public.goodsreceived_trl WHERE id = :'lot_n1') = 6, 'premise: 6 of 10 left after the dispatch');
SELECT pg_temp.sf_pull('admin');
SELECT pg_temp.sf_pull('staff');
SELECT pg_temp.sf_assert(pg_temp.sf_diff('admin') = '' AND pg_temp.sf_diff('staff') = '', '1d: after a dispatch both copies equal a fresh load: '
  || pg_temp.sf_diff('admin') || ' / ' || pg_temp.sf_diff('staff'));
SELECT pg_temp.sf_assert((SELECT (row->>'stock')::int FROM pg_temp.sf_copy WHERE slot = 'admin' AND e = 'goodsreceived_trl' AND id = :'lot_n1') = 6,
  '1d: the lot in the copy has stock 6');
SELECT pg_temp.sf_assert((SELECT (l->>pg_temp.sf('lock_dispatched'))::int FROM pg_temp.sf_copy c, jsonb_array_elements(c.row->pg_temp.sf('lock_lines')) l
    WHERE c.slot = 'admin' AND c.e = pg_temp.sf('e_grn_lock') AND c.id = :'grn_a2' AND l->>pg_temp.sf('lock_line_id') = :'lot_n1') = 4,
  '1d: grn_lock of the GRN says 4 dispatched from the lot');
SELECT pg_temp.sf_assert(:'disp_1' = ANY (pg_temp.sf_held('admin', 'dispatch')) AND (SELECT count(*) FROM pg_temp.sf_copy WHERE slot = 'admin' AND e = 'dispatch_trl' AND row->>'disp_id' = :'disp_1') = 1,
  '1d: the dispatch and its line are in the copy');

-- ---------------------------------------------------------------------------------------------------------------------------------
-- 1e. Rows written with the user triggers off (session_replication_role = replica), not an import: still logged and delivered.
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT gen_random_uuid() AS grn_r1 \gset
BEGIN;
SET LOCAL session_replication_role = replica;
INSERT INTO public.goodsreceived(id, gr_no, date, customer_id, customer_name, invoiced, pricing_mode)
  VALUES (:'grn_r1', 'SFR1', '2026-04-02T10:00:00Z', :'north', 'Sync Feed North', false, 'MONTHLY');
INSERT INTO public.goodsreceived_trl(id, gr_id, item_id, item_name, packaging, qty, weight, stock, rack, package_mark)
  SELECT gen_random_uuid(), :'grn_r1', :'onions', 'Sync Feed Onions', 'Bag', 5, 5, 5, 'R2', 'Q' || g FROM generate_series(1, 3) g;
COMMIT;
SELECT pg_temp.sf_assert(pg_temp.sf_diff('admin') <> '', 'premise: the replica-role rows are not in the copy before a pull');
SELECT pg_temp.sf_pull('admin');
SELECT pg_temp.sf_assert(pg_temp.sf_diff('admin') = '', '1e: rows written with the user triggers off arrive (ENABLE ALWAYS trigger): ' || pg_temp.sf_diff('admin'));
SELECT pg_temp.sf_assert((SELECT count(*) FROM pg_temp.sf_copy WHERE slot = 'admin' AND e = 'goodsreceived_trl' AND row->>'gr_id' = :'grn_r1') = 3,
  '1e: the three lots written with the triggers off are in the copy');

-- ---------------------------------------------------------------------------------------------------------------------------------
-- Paging [6]: two transactions of 0.6 x the page limit each never share a page and are never split.
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT pg_temp.sf('page_limit')::int * 6 / 10 AS part, pg_temp.sf('page_limit')::int + 50 AS oversize \gset
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'SFP1', :'north'::uuid, pg_temp.sf_lines(:'onions'::uuid, :part, 'PA', 1)) AS grn_p1 \gset
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'SFP2', :'north'::uuid, pg_temp.sf_lines(:'onions'::uuid, :part, 'PB', 1)) AS grn_p2 \gset
SELECT pg_temp.sf_pull('admin') AS paged \gset
SELECT pg_temp.sf_assert(pg_temp.sf_diff('admin') = '', '6: after the two large saves the copy equals a fresh load: ' || pg_temp.sf_diff('admin'));
CREATE TEMP TABLE sf_pages_of AS
  SELECT t.gr_id::text AS grn, array_agg(DISTINCT x.page) AS pages, count(DISTINCT t.id) AS lots_seen
  FROM public.goodsreceived_trl t JOIN pg_temp.sf_entry x ON x.phone = 'admin' AND x.pull = pg_temp.sf_last_pull('admin') AND x.e = 'goodsreceived_trl' AND x.id = t.id::text
  WHERE t.gr_id IN (:'grn_p1', :'grn_p2') GROUP BY t.gr_id;
SELECT pg_temp.sf_assert((SELECT count(*) FROM pg_temp.sf_pages_of WHERE cardinality(pages) = 1 AND lots_seen = :part) = 2,
  '6: each large transaction came whole in one page: ' || (SELECT string_agg(grn || ' pages ' || pages::text || ' lots ' || lots_seen, '; ') FROM pg_temp.sf_pages_of));
SELECT pg_temp.sf_assert((SELECT pages FROM pg_temp.sf_pages_of WHERE grn = :'grn_p1') <> (SELECT pages FROM pg_temp.sf_pages_of WHERE grn = :'grn_p2'),
  '6: the two large transactions are on different pages (together they exceed the limit)');

-- A single transaction over the limit [6]: reload of its entities, none of its rows as changes, the position moves past it, and a
-- later small save arrives in the same pull.
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'SFO1', :'north'::uuid, pg_temp.sf_lines(:'onions'::uuid, :oversize, 'OV', 1)) AS grn_o1 \gset
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'SFO2', :'north'::uuid, pg_temp.sf_lines(:'onions'::uuid, 2, 'OW')) AS grn_o2 \gset
SELECT pg_temp.sf_pull('admin') AS over \gset
SELECT pg_temp.sf_assert(:'over'::jsonb->'reload' ? 'goodsreceived_trl' AND :'over'::jsonb->'reload' ? 'goodsreceived',
  '6: a transaction over the limit is answered with a reload of goodsreceived and goodsreceived_trl: ' || :'over');
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM pg_temp.sf_entry x JOIN public.goodsreceived_trl t ON t.id::text = x.id AND t.gr_id = :'grn_o1'
    WHERE x.phone = 'admin' AND x.pull = pg_temp.sf_last_pull('admin') AND x.e = 'goodsreceived_trl'),
  '6: no lot of the oversize transaction came as a change (never split)');
SELECT pg_temp.sf_assert(pg_temp.sf_ops('admin', 'goodsreceived', :'grn_o2', pg_temp.sf_last_pull('admin')) = pg_temp.sf('op_upsert'),
  '6: the save after the oversize transaction arrived in the same pull');
SELECT pg_temp.sf_assert(pg_temp.sf_diff('admin') = '', '6: after the reload the copy equals a fresh load: ' || pg_temp.sf_diff('admin'));
SELECT pg_temp.sf_assert((SELECT count(*) FROM pg_temp.sf_copy WHERE slot = 'admin' AND e = 'goodsreceived_trl' AND row->>'gr_id' = :'grn_o1') = :oversize,
  '6: every lot of the oversize transaction is in the copy after the reload');
-- 13d: p_limit above the limit is clamped (more than 2,000 lots exist now).
SELECT pg_temp.sf_as(:'sf_admin_claims'::jsonb, format(pg_temp.sf('call_page'), 'goodsreceived_trl', NULL, 5000)) AS clamped \gset
SELECT pg_temp.sf_assert(jsonb_array_length(:'clamped'::jsonb->pg_temp.sf('f_rows')) = pg_temp.sf('page_limit')::int,
  '13d: p_limit 5000 answers exactly the page limit of rows: ' || jsonb_array_length(:'clamped'::jsonb->pg_temp.sf('f_rows')));
SELECT pg_temp.sf_assert(pg_temp.sf_check_direct('admin') = '', '12a: the administrator''s copy equals the direct reads: ' || pg_temp.sf_check_direct('admin'));
SELECT pg_temp.sf_pull('staff');
SELECT pg_temp.sf_pull('supervisor');
SELECT pg_temp.sf_assert(pg_temp.sf_check_direct('staff') = '', '12a: the staff copy equals the direct reads: ' || pg_temp.sf_check_direct('staff'));
SELECT pg_temp.sf_assert(pg_temp.sf_check_direct('supervisor') = '', '12a: the supervisor''s copy equals the direct reads: ' || pg_temp.sf_check_direct('supervisor'));

-- Nothing finished since the last pull: no entries, no reload [6].
SELECT pg_temp.sf_pull('admin') AS idle \gset
SELECT pg_temp.sf_assert((:'idle'::jsonb->>'entries')::int = 0 AND :'idle'::jsonb->'reload_all' = '[]' AND :'idle'::jsonb->'reload' = '[]',
  '6: a pull with nothing new carries nothing: ' || :'idle');

-- Checksums [3.4]: for every settled entity, count and sum equal what the copy holds.
SELECT position AS admin_position, copy AS admin_copy FROM pg_temp.sf_device WHERE phone = 'admin' \gset
SELECT pg_temp.sf_as(:'sf_admin_claims'::jsonb, format(pg_temp.sf('call_checksums'), :'admin_position', :'admin_copy')) AS sums \gset
SELECT pg_temp.sf_assert(:'sums'::jsonb->>'success' = 'true', 'checksums answered: ' || left(:'sums', 300));
CREATE TEMP TABLE sf_sums AS
  SELECT s->>pg_temp.sf('f_e') AS e, (s->>pg_temp.sf('f_count'))::bigint AS count, (s->>pg_temp.sf('f_sum'))::numeric AS sum, (s->>pg_temp.sf('f_settled'))::boolean AS settled,
    (SELECT count(*) FROM pg_temp.sf_copy c WHERE c.slot = 'admin' AND c.e = s->>pg_temp.sf('f_e')) AS held,
    (SELECT COALESCE(sum(('x' || lpad(left(c.v, 15), 16, '0'))::bit(64)::bigint::numeric), 0) % 1152921504606846976
       FROM pg_temp.sf_copy c WHERE c.slot = 'admin' AND c.e = s->>pg_temp.sf('f_e')) AS held_sum
  FROM jsonb_array_elements(:'sums'::jsonb->pg_temp.sf('f_entities')) s;
SELECT pg_temp.sf_assert((SELECT settled FROM pg_temp.sf_sums WHERE e = 'goodsreceived_trl'), 'checksums: goodsreceived_trl is listed and settled');
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM pg_temp.sf_sums WHERE settled AND (count <> held OR sum <> held_sum)),
  'checksums: every settled entity has the count and sum of the copy: ' || (SELECT string_agg(format('%s %s/%s %s/%s', e, count, held, sum, held_sum), '; ') FROM pg_temp.sf_sums WHERE count <> held OR sum <> held_sum));

-- ---------------------------------------------------------------------------------------------------------------------------------
-- 1g. The feed trigger is ENABLE ALWAYS on every logged table; the dead switch-off of "Edit GRN" is gone [9].
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM unnest(pg_temp.sf_list('logged_tables')) tbl
    WHERE NOT EXISTS (SELECT 1 FROM pg_trigger tg WHERE tg.tgrelid = tbl::regclass AND tg.tgname = pg_temp.sf('feed_trigger') AND tg.tgenabled = 'A')),
  '1g: the feed trigger is ENABLE ALWAYS on every logged table; missing on: ' || COALESCE((SELECT string_agg(tbl, ', ') FROM unnest(pg_temp.sf_list('logged_tables')) tbl
    WHERE NOT EXISTS (SELECT 1 FROM pg_trigger tg WHERE tg.tgrelid = tbl::regclass AND tg.tgname = pg_temp.sf('feed_trigger') AND tg.tgenabled = 'A')), ''));
SELECT pg_temp.sf_assert(to_regprocedure('public.safe_disable_grn_trl_triggers()') IS NULL AND to_regprocedure('public.safe_enable_grn_trl_triggers()') IS NULL
  AND position('safe_disable_grn_trl_triggers' IN pg_get_functiondef('public.update_grn'::regproc)) = 0,
  '1g: update_grn no longer switches lot triggers off and both switch functions are dropped');

-- ---------------------------------------------------------------------------------------------------------------------------------
-- 1h. Answers that make the phone reload everything [3.3, 8, 9]. Format, rotation and purge run in transactions rolled back.
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT position AS admin_position, copy AS admin_copy FROM pg_temp.sf_device WHERE phone = 'admin' \gset
BEGIN;
SELECT pg_temp.sf_exec(pg_temp.sf('bump_format'));
SELECT pg_temp.sf_changes_once('admin') AS after_format \gset
ROLLBACK;
SELECT pg_temp.sf_assert(:'after_format'::jsonb#>>ARRAY[pg_temp.sf('f_reload_all'), pg_temp.sf('f_reason')] = pg_temp.sf('r_format'), '1h: a changed format answers FORMAT_CHANGED: ' || :'after_format');
BEGIN;
SELECT pg_temp.sf_exec(format(pg_temp.sf('rotate_log'), pg_temp.sf('r_restored')));
SELECT pg_temp.sf_changes_once('admin') AS after_restore \gset
ROLLBACK;
SELECT pg_temp.sf_assert(:'after_restore'::jsonb#>>ARRAY[pg_temp.sf('f_reload_all'), pg_temp.sf('f_reason')] = pg_temp.sf('r_restored'), '1h: rotate_log after a restore answers RESTORED: ' || :'after_restore');
SELECT pg_temp.sf_changes_once('admin', (pg_current_xact_id()::text::numeric + 1000000)::text) AS ahead \gset
SELECT pg_temp.sf_assert(:'ahead'::jsonb#>>ARRAY[pg_temp.sf('f_reload_all'), pg_temp.sf('f_reason')] = pg_temp.sf('r_ahead'), '1h: a position above the current id answers POSITION_AHEAD: ' || :'ahead');
SELECT pg_temp.sf_assert((SELECT days FROM warehouse_maintenance.retention_policy WHERE key = pg_temp.sf('retention_key')) = pg_temp.sf('retention_days')::int,
  '1h: the change log is kept ' || pg_temp.sf('retention_days') || ' days (retention_policy)');
BEGIN;
-- Only the change log ages out: every other policy is held at its longest for this transaction.
UPDATE warehouse_maintenance.retention_policy SET days = 3650 WHERE key <> pg_temp.sf('retention_key');
-- The run is dated in the future, so it would also delete the phones' sessions (expires_at < that date) and the next call would be refused 42501; keep them for this transaction.
UPDATE warehouse_security.refresh_sessions SET expires_at = now() + interval '3650 days';
SELECT warehouse_maintenance.run_database_retention(now() + make_interval(days => pg_temp.sf('retention_days')::int + 1), true) AS purge_run \gset
CREATE TEMP TABLE sf_floor(v text) ON COMMIT DROP;
SELECT pg_temp.sf_exec(format('INSERT INTO pg_temp.sf_floor %s', pg_temp.sf('floor_query')));
SELECT v AS floor_after FROM pg_temp.sf_floor \gset
SELECT pg_temp.sf_changes_once('admin', :'admin_first_position') AS purged \gset
ROLLBACK;
SELECT pg_temp.sf_assert(:'floor_after'::numeric > :'admin_first_position'::numeric, '1h: the purge raised the floor above the old position: ' || :'floor_after');
SELECT pg_temp.sf_assert(:'purged'::jsonb#>>ARRAY[pg_temp.sf('f_reload_all'), pg_temp.sf('f_reason')] = pg_temp.sf('r_purged'), '1h: a position below the floor answers LOG_PURGED: ' || :'purged');

-- 1e. A bulk import (an import_batches row with its rows written as replica): every phone reloads everything.
SELECT gen_random_uuid() AS grn_i1 \gset
BEGIN;
SET LOCAL session_replication_role = replica;
INSERT INTO warehouse_security.import_batches(files, counts, applied_at) VALUES ('[{"name":"sync-feed.csv","sha256":"00","rows":3}]', '{"grn":1}', now());
INSERT INTO public.goodsreceived(id, gr_no, date, customer_id, customer_name, invoiced, pricing_mode)
  VALUES (:'grn_i1', 'SFI1', '2026-04-03T10:00:00Z', :'north', 'Sync Feed North', false, 'MONTHLY');
INSERT INTO public.goodsreceived_trl(id, gr_id, item_id, item_name, packaging, qty, weight, stock, rack, package_mark)
  SELECT gen_random_uuid(), :'grn_i1', :'onions', 'Sync Feed Onions', 'Bag', 5, 5, 5, 'R3', 'I' || g FROM generate_series(1, 2) g;
COMMIT;
SELECT pg_temp.sf_pull('admin') AS imported \gset
SELECT pg_temp.sf_pull('staff') AS imported_staff \gset
SELECT pg_temp.sf_assert(:'imported'::jsonb->'reload_all' ? pg_temp.sf('r_bulk') AND :'imported_staff'::jsonb->'reload_all' ? pg_temp.sf('r_bulk'),
  '1e: after a bulk import every phone is told to reload everything (BULK_IMPORT): ' || :'imported' || ' / ' || :'imported_staff');
SELECT pg_temp.sf_assert(pg_temp.sf_diff('admin') = '' AND pg_temp.sf_diff('staff') = '', '1e: after the reload both copies equal a fresh load');
SELECT pg_temp.sf_assert(:'grn_i1' = ANY (pg_temp.sf_held('admin', 'goodsreceived')), '1e: the imported GRN is in the reloaded copy');

\echo 'WH-297 sync feed changes (criteria 1 and 13, refusals) checks passed.'

-- WH-297, criteria 2 and 12: deletes through the server's own functions, a GRN moved to another customer, soft-deleted rows, a lost
-- customer assignment, and what a customer account may hold. tests/migrations.sh pipes tests/sync_feed_contract.sql in front of
-- this file, in the sync feed database of its own (after tests/sync_feed_changes.sql); this file commits. Section and case
-- numbers refer to ~/ws/fresh/product/tech/server-change-log-feed.md.
--
-- AGREE WITH DEVELOPMENT: every feed name used here is in the marked block of tests/sync_feed_contract.sql; this file adds none.
--
-- Phones: admin, staff, c1 (a customer account assigned to North) and c2 (assigned to South).
\set ON_ERROR_STOP on

INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888897111', 'Sync Scope North Reader', 'customer', true, 'approved'),
 (gen_random_uuid(), '919888897112', 'Sync Scope South Reader', 'customer', true, 'approved');
SELECT pg_temp.sf_login('9888897111') AS c1_claims \gset
SELECT pg_temp.sf_login('9888897112') AS c2_claims \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_customer(''Sync Scope North'', ''9888897121'')')->>'success' = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_customer(''Sync Scope South'', ''9888897122'')')->>'success' = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_customer(''Sync Scope West'', ''9888897123'')')->>'success' = 'true', 'customers');
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_item(''Sync Scope Garlic'', ''Bag'')')->>'success' = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_item(''Sync Scope Unused'', ''Bag'')')->>'success' = 'true', 'items');
SELECT id AS north FROM public.customers WHERE name = 'Sync Scope North' \gset
SELECT id AS south FROM public.customers WHERE name = 'Sync Scope South' \gset
SELECT id AS west FROM public.customers WHERE name = 'Sync Scope West' \gset
SELECT id AS garlic FROM public.items WHERE name = 'Sync Scope Garlic' \gset
SELECT id AS unused_item FROM public.items WHERE name = 'Sync Scope Unused' \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT to_jsonb(public.assign_customer_to_user(%L, %L::uuid, %L))', '919888897111', :'north', 'Sync feed fixture'))::text = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT to_jsonb(public.assign_customer_to_user(%L, %L::uuid, %L))', '919888897112', :'south', 'Sync feed fixture'))::text = 'true',
  'customer accounts assigned');
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.replace_item_rates(%L::uuid, %L::uuid, %L, %L::date, %L::jsonb)', :'garlic', :'north', 'monthly', '2026-01-01',
  '[{"weight_min":0,"weight_max":100,"unit_price":5,"labour_rate":2,"tax_percent":5}]'))->>'success' = 'true', 'price for North');

SELECT pg_temp.sf_phone('admin', :'sf_admin_claims'::jsonb);
SELECT pg_temp.sf_phone('c1', :'c1_claims'::jsonb);
SELECT pg_temp.sf_phone('c2', :'c2_claims'::jsonb);
SELECT pg_temp.sf_first_load('admin');
SELECT pg_temp.sf_first_load('c1');
SELECT pg_temp.sf_first_load('c2');
-- A staff member who joins after the customer accounts loaded: their profile row is a logged change no customer may receive.
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888897102', 'Sync Scope Staff Person', 'staff', true, 'approved');
SELECT pg_temp.sf_login('9888897102') AS staff_claims \gset
SELECT pg_temp.sf_phone('staff', :'staff_claims'::jsonb);
SELECT pg_temp.sf_first_load('staff');

-- Documents. North: DSA1 (to be moved), DSA2 (deleted), DSA3 (its dispatch deleted), DSA4 (dispatched in full and invoiced),
-- DSA5 (soft-deleted). South: DSB1 with a dispatch.
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'DSA1', :'north'::uuid, pg_temp.sf_lines(:'garlic'::uuid, 2, 'NA')) AS grn_a1 \gset
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'DSA2', :'north'::uuid, pg_temp.sf_lines(:'garlic'::uuid, 2, 'NB')) AS grn_a2 \gset
SELECT pg_temp.sf_save_grn(:'staff_claims'::jsonb, 'DSA3', :'north'::uuid, pg_temp.sf_lines(:'garlic'::uuid, 2, 'NC')) AS grn_a3 \gset
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'DSA5', :'north'::uuid, pg_temp.sf_lines(:'garlic'::uuid, 1, 'NE')) AS grn_a5 \gset
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'DSB1', :'south'::uuid, pg_temp.sf_lines(:'garlic'::uuid, 1, 'SOUTHMARK')) AS grn_b1 \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.save_grn(p_sender_name => %L, p_supervisor_id => %L::uuid, p_supervisor_name => %L, p_gr_no => %L,'
  ' p_date => %L::timestamptz, p_customer_id => %L::uuid, p_customer_name => %L, p_pricing_mode => %L, p_items => %L::jsonb, p_idempotency_key => %L)',
  'Fixture Sender', :'sf_admin_profile', 'Fixture Supervisor', 'DSA4', '2026-04-01T12:00:00Z', :'north', 'Sync Scope North', 'ONE_TIME',
  pg_temp.sf_lines(:'garlic'::uuid, 1, 'ND', 20), 'sync-feed-DSA4'))->>'success' = 'true', 'fixture: DSA4');
SELECT id AS grn_a4 FROM public.goodsreceived WHERE gr_no = 'DSA4' \gset
SELECT pg_temp.sf_dispatch(:'sf_admin_claims'::jsonb, 'DSAD1', (SELECT id FROM public.goodsreceived_trl WHERE gr_id = :'grn_a3' AND package_mark = 'NC1'), 3) AS disp_a1 \gset
SELECT pg_temp.sf_dispatch(:'sf_admin_claims'::jsonb, 'DSAD2', (SELECT id FROM public.goodsreceived_trl WHERE gr_id = :'grn_a4'), 20) AS disp_a2 \gset
SELECT pg_temp.sf_dispatch(:'sf_admin_claims'::jsonb, 'DSBD1', (SELECT id FROM public.goodsreceived_trl WHERE gr_id = :'grn_b1'), 2) AS disp_b1 \gset
SELECT pg_temp.sf_as(:'staff_claims'::jsonb, format('SELECT public.save_invoice(NULL::uuid, %L::jsonb, ARRAY(SELECT jsonb_build_object(%L, t.id, %L, t.gr_trl_id, %L, 1, %L, 5, %L, 5, %L, 2) FROM public.dispatch_trl t WHERE t.gr_id = %L::uuid))',
  jsonb_build_object('inv_fin_year', 2026, 'inv_no', 5, 'customer_id', :'north', 'customer_name', 'Sync Scope North', 'inv_date', '2026-06-02T12:00:00Z',
    'total', 0, 'tax_amount', 0, 'labour', 0, 'discount', 0, 'duration_mode', 'legacy', 'gr_id', :'grn_a4', 'gr_no', 'DSA4'),
  'disp_trl_id', 'grn_item_id', 'duration', 'charge', 'tax', 'labour_rate', :'grn_a4')) AS invoiced \gset
SELECT pg_temp.sf_assert(:'invoiced'::jsonb->>'success' = 'true', 'fixture: invoice of DSA4: ' || :'invoiced');
SELECT (:'invoiced'::jsonb->>'invoice_id') AS inv_a4 \gset

SELECT pg_temp.sf_pull('admin');
SELECT pg_temp.sf_pull('staff');
SELECT pg_temp.sf_pull('c1');
SELECT pg_temp.sf_pull('c2');
SELECT pg_temp.sf_assert(pg_temp.sf_diff(p) = '', 'after the fixture the copy of ' || p || ' equals a fresh load: ' || pg_temp.sf_diff(p))
  FROM unnest(ARRAY['admin', 'staff', 'c1', 'c2']) p;

-- ---------------------------------------------------------------------------------------------------------------------------------
-- Criterion 12: what a customer account holds.
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT pg_temp.sf_assert(NOT (entities && ARRAY['user_profiles', 'users_customers_new', pg_temp.sf('e_people'), pg_temp.sf('e_grn_lock'), pg_temp.sf('e_settings')]),
  '12b: a customer account loads no user_profiles, assignments, people, grn_lock or settings: ' || entities::text)
  FROM pg_temp.sf_device WHERE phone IN ('c1', 'c2');
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM pg_temp.sf_entry WHERE phone IN ('c1', 'c2')
    AND e IN ('user_profiles', 'users_customers_new', pg_temp.sf('e_people'), pg_temp.sf('e_grn_lock'), pg_temp.sf('e_settings'))),
  '12b: no feed entry of those entities reached a customer account');
SELECT pg_temp.sf_assert(pg_temp.sf_check_direct('c1', pg_temp.sf_list('q1_customer_hidden_columns'), true) = '',
  '12a: c1''s copy equals its direct reads, without the Q1 columns: ' || pg_temp.sf_check_direct('c1', pg_temp.sf_list('q1_customer_hidden_columns'), true));
SELECT pg_temp.sf_assert(pg_temp.sf_check_direct('c2', pg_temp.sf_list('q1_customer_hidden_columns'), true) = '',
  '12a: c2''s copy equals its direct reads, without the Q1 columns: ' || pg_temp.sf_check_direct('c2', pg_temp.sf_list('q1_customer_hidden_columns'), true));
SELECT pg_temp.sf_assert(pg_temp.sf_check_direct('admin') = '', '12a: the administrator''s copy equals the direct reads: ' || pg_temp.sf_check_direct('admin'));
SELECT pg_temp.sf_assert(pg_temp.sf_check_direct('staff') = '', '12a: the staff copy equals the direct reads: ' || pg_temp.sf_check_direct('staff'));
SELECT pg_temp.sf_assert(pg_temp.sf_held('c1', 'customers') = ARRAY[:'north']::text[]
  AND (SELECT count(*) FROM pg_temp.sf_copy WHERE slot = 'c1' AND e = 'goodsreceived') = 5
  AND NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy WHERE slot = 'c1' AND e IN ('goodsreceived', 'dispatch', 'invoice') AND row->>'customer_id' <> :'north')
  AND NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy l WHERE l.slot = 'c1' AND l.e = 'goodsreceived_trl'
    AND NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy g WHERE g.slot = 'c1' AND g.e = 'goodsreceived' AND g.id = l.row->>'gr_id'))
  AND NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy l WHERE l.slot = 'c1' AND l.e = 'dispatch_trl'
    AND NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy d WHERE d.slot = 'c1' AND d.e = 'dispatch' AND d.id = l.row->>'disp_id')),
  '12: c1 holds North, its five GRNs and only rows of them');
SELECT pg_temp.sf_assert(:'inv_a4' = ANY (pg_temp.sf_held('c1', 'invoice')) AND NOT (:'inv_a4' = ANY (pg_temp.sf_held('c2', 'invoice'))), '12: the invoice of North is in c1''s copy only');
SELECT pg_temp.sf_assert(EXISTS (SELECT 1 FROM pg_temp.sf_event WHERE phone = 'admin' AND kind = 'stale' AND detail = :'north')
  AND EXISTS (SELECT 1 FROM pg_temp.sf_event WHERE phone = 'c1' AND kind = 'stale' AND detail = :'north')
  AND NOT EXISTS (SELECT 1 FROM pg_temp.sf_event WHERE phone IN ('c1', 'c2') AND kind = 'stale' AND detail <> (CASE phone WHEN 'c1' THEN :'north' ELSE :'south' END)),
  '12b: the invoice marked North''s money stale for the administrator and c1, and a customer account gets money marks only for its own customers');

-- ---------------------------------------------------------------------------------------------------------------------------------
-- 2b. DSA1 moved from North to South by update_grn.
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT pg_temp.sf_update_grn(:'sf_admin_claims'::jsonb, :'grn_a1'::uuid, pg_temp.sf_current_lines(:'grn_a1'::uuid), :'south'::uuid);
SELECT pg_temp.sf_assert((SELECT customer_id FROM public.goodsreceived WHERE id = :'grn_a1') = :'south'::uuid, 'premise: DSA1 belongs to South');
SELECT pg_temp.sf_pull(p) FROM unnest(ARRAY['admin', 'staff', 'c1', 'c2']) p;
SELECT pg_temp.sf_assert(pg_temp.sf_ops('c1', 'goodsreceived', :'grn_a1', pg_temp.sf_last_pull('c1')) = pg_temp.sf('op_delete'),
  '2b: North''s account got DSA1 as a delete: ' || pg_temp.sf_ops('c1', 'goodsreceived', :'grn_a1', pg_temp.sf_last_pull('c1')));
SELECT pg_temp.sf_assert(NOT (:'grn_a1' = ANY (pg_temp.sf_held('c1', 'goodsreceived')))
  AND NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy WHERE slot = 'c1' AND e = 'goodsreceived_trl' AND row->>'gr_id' = :'grn_a1'),
  '2b: c1 holds neither DSA1 nor its lots');
SELECT pg_temp.sf_assert(pg_temp.sf_ops('c2', 'goodsreceived', :'grn_a1', pg_temp.sf_last_pull('c2')) = pg_temp.sf('op_upsert')
  AND (SELECT count(*) FROM pg_temp.sf_copy WHERE slot = 'c2' AND e = 'goodsreceived_trl' AND row->>'gr_id' = :'grn_a1') = 2,
  '2b: South''s account got DSA1 with its two lots');
SELECT pg_temp.sf_assert(pg_temp.sf_diff(p) = '', '2b: the copy of ' || p || ' equals a fresh load: ' || pg_temp.sf_diff(p)) FROM unnest(ARRAY['admin', 'staff', 'c1', 'c2']) p;

-- ---------------------------------------------------------------------------------------------------------------------------------
-- 2a. Hard deletes through the server's functions: a GRN, a dispatch, an invoice, an item.
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT array_agg(id::text) AS lots_a2 FROM public.goodsreceived_trl WHERE gr_id = :'grn_a2' \gset
SELECT array_agg(id::text) AS lines_d1 FROM public.dispatch_trl WHERE disp_id = :'disp_a1' \gset
SELECT array_agg(id::text) AS lines_inv FROM public.invoice_trl WHERE invoice_id = :'inv_a4' \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.delete_grn_safe(%L::uuid)', :'grn_a2'))->>'success' = 'true', 'delete_grn_safe DSA2');
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.delete_dispatch_with_order_cleanup(%L::uuid, %L::uuid)', :'disp_a1', :'sf_admin_profile'))->>'success' = 'true',
  'delete_dispatch_with_order_cleanup DSAD1');
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.delete_invoice(%L::uuid)', :'inv_a4'))->>'success' = 'true', 'delete_invoice');
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.delete_item_safe(%L::uuid)', :'unused_item'))->>'success' = 'true', 'delete_item_safe');
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE id = :'grn_a2') AND NOT EXISTS (SELECT 1 FROM public.dispatch WHERE id = :'disp_a1')
  AND NOT EXISTS (SELECT 1 FROM public.invoice WHERE id = :'inv_a4') AND NOT EXISTS (SELECT 1 FROM public.items WHERE id = :'unused_item'), 'premise: the four rows are gone for good');
SELECT pg_temp.sf_pull(p) FROM unnest(ARRAY['admin', 'staff', 'c1']) p;
SELECT pg_temp.sf_assert(pg_temp.sf_ops(p, 'goodsreceived', :'grn_a2', pg_temp.sf_last_pull(p)) = pg_temp.sf('op_delete')
  AND pg_temp.sf_ops(p, 'dispatch', :'disp_a1', pg_temp.sf_last_pull(p)) = pg_temp.sf('op_delete')
  AND pg_temp.sf_ops(p, 'invoice', :'inv_a4', pg_temp.sf_last_pull(p)) = pg_temp.sf('op_delete')
  AND pg_temp.sf_ops(p, 'items', :'unused_item', pg_temp.sf_last_pull(p)) = pg_temp.sf('op_delete'),
  '2a: ' || p || ' got the GRN, the dispatch, the invoice and the item each as a delete') FROM unnest(ARRAY['admin', 'staff', 'c1']) p;
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy c WHERE c.slot = p AND (
    (c.e = 'goodsreceived' AND c.id = :'grn_a2') OR (c.e = 'goodsreceived_trl' AND c.id = ANY (:'lots_a2'::text[]))
    OR (c.e = 'dispatch' AND c.id = :'disp_a1') OR (c.e = 'dispatch_trl' AND c.id = ANY (:'lines_d1'::text[]))
    OR (c.e = 'invoice' AND c.id = :'inv_a4') OR (c.e = 'invoice_trl' AND c.id = ANY (:'lines_inv'::text[]))
    OR (c.e = 'items' AND c.id = :'unused_item') OR (c.e = pg_temp.sf('e_grn_lock') AND c.id = :'grn_a2'))),
  '2a: ' || p || ' holds no row of the deleted documents (with the cascade)') FROM unnest(ARRAY['admin', 'staff', 'c1']) p;
SELECT pg_temp.sf_assert((SELECT (row->>'stock')::int FROM pg_temp.sf_copy WHERE slot = 'c1' AND e = 'goodsreceived_trl' AND row->>'gr_id' = :'grn_a3' AND row->>'package_mark' = 'NC1') = 10,
  '2a: the stock the deleted dispatch gave back is in c1''s copy');
SELECT pg_temp.sf_assert(pg_temp.sf_diff(p) = '', '2a: the copy of ' || p || ' equals a fresh load: ' || pg_temp.sf_diff(p)) FROM unnest(ARRAY['admin', 'staff', 'c1']) p;

-- ---------------------------------------------------------------------------------------------------------------------------------
-- 2d (Q4 as decided): soft-deleted rows. Staff roles get them with deleted_at set; a customer account gets a delete.
-- ---------------------------------------------------------------------------------------------------------------------------------
UPDATE public.goodsreceived SET deleted_at = now() WHERE id = :'grn_a5';
UPDATE public.dispatch SET deleted_at = now() WHERE id = :'disp_a2';
UPDATE public.customers SET deleted_at = now() WHERE id = :'west';
SELECT pg_temp.sf_pull(p) FROM unnest(ARRAY['admin', 'staff', 'c1']) p;
SELECT pg_temp.sf_assert(pg_temp.sf_ops(p, 'goodsreceived', :'grn_a5', pg_temp.sf_last_pull(p)) = pg_temp.sf('op_upsert')
  AND pg_temp.sf_ops(p, 'dispatch', :'disp_a2', pg_temp.sf_last_pull(p)) = pg_temp.sf('op_upsert')
  AND pg_temp.sf_ops(p, 'customers', :'west', pg_temp.sf_last_pull(p)) = pg_temp.sf('op_upsert')
  AND (SELECT bool_and(row->>pg_temp.sf('soft_delete_column') IS NOT NULL) FROM pg_temp.sf_copy
       WHERE slot = p AND ((e = 'goodsreceived' AND id = :'grn_a5') OR (e = 'dispatch' AND id = :'disp_a2') OR (e = 'customers' AND id = :'west')))
  AND (SELECT count(*) FROM pg_temp.sf_copy WHERE slot = p AND ((e = 'goodsreceived' AND id = :'grn_a5') OR (e = 'dispatch' AND id = :'disp_a2') OR (e = 'customers' AND id = :'west'))) = 3,
  '2d: ' || p || ' holds the soft-deleted GRN, dispatch and customer with deleted_at set') FROM unnest(ARRAY['admin', 'staff']) p;
SELECT pg_temp.sf_assert(pg_temp.sf_ops('c1', 'goodsreceived', :'grn_a5', pg_temp.sf_last_pull('c1')) = pg_temp.sf('op_delete')
  AND pg_temp.sf_ops('c1', 'dispatch', :'disp_a2', pg_temp.sf_last_pull('c1')) = pg_temp.sf('op_delete')
  AND NOT (:'grn_a5' = ANY (pg_temp.sf_held('c1', 'goodsreceived'))) AND NOT (:'disp_a2' = ANY (pg_temp.sf_held('c1', 'dispatch')))
  AND NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy WHERE slot = 'c1' AND e = 'goodsreceived_trl' AND row->>'gr_id' = :'grn_a5'),
  '2d: the customer account got the soft-deleted GRN and dispatch as deletes and holds neither (nor the lot)');
SELECT pg_temp.sf_assert(pg_temp.sf_diff(p) = '', '2d: the copy of ' || p || ' equals a fresh load: ' || pg_temp.sf_diff(p)) FROM unnest(ARRAY['admin', 'staff', 'c1']) p;
SELECT pg_temp.sf_assert(pg_temp.sf_check_direct('staff') = '', '2d: the staff copy equals the staff direct reads (soft-deleted rows included): ' || pg_temp.sf_check_direct('staff'));
SELECT pg_temp.sf_assert(pg_temp.sf_check_direct('c1', pg_temp.sf_list('q1_customer_hidden_columns'), true) = '',
  '2d: c1''s copy equals its live direct reads: ' || pg_temp.sf_check_direct('c1', pg_temp.sf_list('q1_customer_hidden_columns'), true));

-- ---------------------------------------------------------------------------------------------------------------------------------
-- 2c. c1 loses North: the next call reloads everything for the new access, and the copy holds nothing of North.
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT to_jsonb(public.remove_customer_assignment(%L, %L::uuid))', '919888897111', :'north')) AS removed \gset
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM public.users_customers_new u JOIN public.user_profiles p ON p.id = u.user_profile_id
  WHERE p.mobile = '919888897111' AND u.customer_id = :'north' AND u.active), 'premise: c1 is no longer assigned to North: ' || :'removed');
SELECT pg_temp.sf_pull('c1') AS c1_lost \gset
SELECT pg_temp.sf_pull('c2') AS c2_kept \gset
SELECT pg_temp.sf_assert(:'c1_lost'::jsonb->'reload_all' ? pg_temp.sf('r_access'), '2c: c1''s next call answered ACCESS_CHANGED: ' || :'c1_lost');
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy WHERE slot = 'c1'
    AND e IN ('customers', 'goodsreceived', 'goodsreceived_trl', 'grn_images', 'dispatch', 'dispatch_trl', 'dispatch_images', 'invoice', 'invoice_trl')),
  '2c: after the reload c1 holds no customer, document or line');
SELECT pg_temp.sf_assert(pg_temp.sf_diff('c1') = '', '2c: c1''s copy equals a fresh load: ' || pg_temp.sf_diff('c1'));
SELECT pg_temp.sf_assert(:'c2_kept'::jsonb->'reload_all' = '[]', '2c: c2, whose access did not change, is not told to reload: ' || :'c2_kept');

-- ---------------------------------------------------------------------------------------------------------------------------------
-- 12c and 12b, over every answer the customer accounts received in this file.
-- ---------------------------------------------------------------------------------------------------------------------------------
CREATE TEMP TABLE sf_south_only AS
  SELECT unnest(ARRAY[:'south', :'grn_b1', :'disp_b1', :'west']::text[]) AS id
  UNION ALL SELECT id::text FROM public.goodsreceived_trl WHERE gr_id = :'grn_b1'
  UNION ALL SELECT id::text FROM public.dispatch_trl WHERE disp_id = :'disp_b1';
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM pg_temp.sf_entry x JOIN pg_temp.sf_south_only s ON s.id = x.id WHERE x.phone = 'c1'),
  '12c: c1 never got an entry, not even a delete, for a row of South or West alone: '
  || COALESCE((SELECT string_agg(x.e || ' ' || x.op, ', ') FROM pg_temp.sf_entry x JOIN pg_temp.sf_south_only s ON s.id = x.id WHERE x.phone = 'c1'), ''));
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM pg_temp.sf_answer WHERE phone = 'c1'
    AND (answer::text LIKE '%Sync Scope South%' OR answer::text LIKE '%Sync Scope West%' OR answer::text LIKE '%SOUTHMARK%'
         OR answer::text LIKE '%Sync Scope Staff Person%' OR answer::text LIKE '%9888897102%' OR answer::text LIKE '%9888897001%')),
  '12b: no answer to c1 carried another customer''s name or mark, a staff member''s name, or a staff phone number');
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM pg_temp.sf_answer a, unnest(pg_temp.sf_list('q1_customer_hidden_columns')) col
    WHERE a.phone IN ('c1', 'c2') AND a.answer::text LIKE '%"' || col || '":%'),
  '12b: no answer to a customer account carried a Q1 column: ' || COALESCE((SELECT string_agg(DISTINCT col, ', ') FROM pg_temp.sf_answer a, unnest(pg_temp.sf_list('q1_customer_hidden_columns')) col
    WHERE a.phone IN ('c1', 'c2') AND a.answer::text LIKE '%"' || col || '":%'), ''));
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM pg_temp.sf_answer a, information_schema.columns c
    WHERE c.table_schema = 'public' AND c.table_name = 'invoice' AND NOT has_column_privilege('authenticated', 'public.invoice', c.column_name, 'SELECT')
      AND a.answer::text LIKE '%"' || c.column_name || '":%'),
  '12: no answer to any phone carried an invoice column the app roles may not read');

\echo 'WH-297 sync feed deletes and customer scope (criteria 2 and 12) checks passed.'

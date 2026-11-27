-- WH-381, backend feed scope cut (contract-first, failing until Dev builds topic migration "sync_scope_grn_and_stock_only", feed format 8).
-- Contract: ~/ws/fresh/product/tech/app-offline-scope-cut.md Section 1 and ~/ws/fresh/product/specs/offline-capture.md criterion 14a.
-- tests/migrations.sh pipes tests/fixtures/gst_details.sql and tests/sync_feed_contract.sql in front of this file, in the sync feed
-- database of its own; this file commits. Fictional data only (phone range 98888979xx).
--
-- AGREE WITH DEVELOPMENT (WH-381):
--   1. warehouse_sync.state.format = 8 (and column default = 8); get_sync_start() answers format 8; get_sync_changes() and
--      get_sync_checksums() given a format-7 copy key ('7.<log_id>.<access>') answer reload_all {reason: 'FORMAT_CHANGED'}.
--   2. warehouse_sync.entities(p_role) drops 'dispatch', 'dispatch_trl', 'dispatch_images', 'invoice', 'invoice_trl', 'payments',
--      'orders', 'order_items' for all roles, while keeping all 16 GRN/stock/rate/lock/meta entities per existing role guards.
--   3. warehouse_sync.log_change() emits ZERO change_log rows for the 8 dropped tables, while still emitting 'grn_lock' rows
--      (on dispatch, dispatch_trl, invoice, invoice_trl, orders, order_items, grn_rates, imported_documents, imported_billed_dispatches),
--      'money' marks (op = 'stale', on goodsreceived, goodsreceived_trl, dispatch, dispatch_trl, invoice, invoice_trl, payments,
--      grn_rates, customers, item_storage_prices, charging_rule, system_settings), and goodsreceived/goodsreceived_trl (stock, emptied_at).
--   4. warehouse_sync.caller_log() filters out pre-migration legacy change_log rows for the 8 dropped entities so get_sync_changes()
--      never returns or stalls on them; warehouse_sync.expand() removes goodsreceived -> invoice and dispatch_trl -> invoice branches.
--   5. warehouse_sync.affected(p_tbl) returns none of the 8 dropped entities for kept tables (e.g. goodsreceived, user_profiles) OR for
--      any dropped table name (narrowed to kept entities / empty); warehouse_sync.existing_ids(p_entity, p_ids) returns '{}' for all 8
--      dropped entities while still returning matching ids for kept table entities.
--   6. public.dispatch_images may have its zz_change_feed trigger dropped or be a no-op in log_change(); either way mutations emit zero
--      change_log rows.
\set ON_ERROR_STOP on

CREATE FUNCTION pg_temp.sc381_dropped() RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY['dispatch', 'dispatch_trl', 'dispatch_images', 'invoice', 'invoice_trl', 'payments', 'orders', 'order_items'] $$;
CREATE FUNCTION pg_temp.sc381_sorted(a text[]) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(array_to_string(ARRAY(SELECT DISTINCT x FROM unnest(a) x ORDER BY x), ','), '') $$;
CREATE FUNCTION pg_temp.sc381_dropped_logs(since_xid xid8) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT COALESCE(string_agg(DISTINCT tbl, ',' ORDER BY tbl), '')
    FROM warehouse_sync.change_log
   WHERE xid >= since_xid AND tbl = ANY (pg_temp.sc381_dropped()) $$;
CREATE FUNCTION pg_temp.sc381_has_log(since_xid xid8, p_tbl text, p_key text) RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM warehouse_sync.change_log WHERE xid >= since_xid AND tbl = p_tbl AND row_key = p_key) $$;
CREATE FUNCTION pg_temp.sc381_marks(p text) RETURNS text[] LANGUAGE sql STABLE AS $$
  SELECT COALESCE(array_agg(d ORDER BY d), '{}') FROM (SELECT DISTINCT detail AS d FROM pg_temp.sf_event
    WHERE phone = p AND kind = 'stale' AND pull = pg_temp.sf_last_pull(p)) t $$;
CREATE FUNCTION pg_temp.sc381_lock(p text, grn uuid) RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT c.row FROM pg_temp.sf_copy c WHERE c.slot = p AND c.e = pg_temp.sf('e_grn_lock') AND c.id = grn::text $$;
CREATE FUNCTION pg_temp.sc381_pull_all(step text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE p text; bad text; leak text;
BEGIN
  FOREACH p IN ARRAY ARRAY['admin', 'supervisor', 'staff', 'c1', 'c2'] LOOP
    PERFORM pg_temp.sf_pull(p);
    bad := pg_temp.sf_diff(p);
    PERFORM pg_temp.sf_assert(bad = '', format('%s: copy of %s differs from a fresh load: %s', step, p, bad));
    SELECT string_agg(DISTINCT e, ',' ORDER BY e) INTO leak FROM pg_temp.sf_copy WHERE slot = p AND e = ANY (pg_temp.sc381_dropped());
    PERFORM pg_temp.sf_assert(leak IS NULL, format('%s: %s copy holds dropped entities: %s', step, p, COALESCE(leak, '')));
    SELECT string_agg(DISTINCT e, ',' ORDER BY e) INTO leak FROM pg_temp.sf_entry
     WHERE phone = p AND pull = pg_temp.sf_last_pull(p) AND e = ANY (pg_temp.sc381_dropped());
    PERFORM pg_temp.sf_assert(leak IS NULL, format('%s: %s received dropped-entity entries in pull: %s', step, p, COALESCE(leak, '')));
  END LOOP;
END $$;
CREATE FUNCTION pg_temp.sc381_invoice(claims jsonb, bill int, disp uuid) RETURNS uuid LANGUAGE plpgsql AS $$
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

-- ---------------------------------------------------------------------------------------------------------------------------------
-- Fixture: 4 roles (admin, supervisor, staff, customer c1/c2), 2 customers, 1 item, 4 GRNs.
-- ---------------------------------------------------------------------------------------------------------------------------------
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888897902', 'Scope Cut 381 Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888897903', 'Scope Cut 381 Supervisor', 'supervisor', true, 'approved'),
 (gen_random_uuid(), '919888897911', 'Scope Cut 381 North Reader', 'customer', true, 'approved'),
 (gen_random_uuid(), '919888897912', 'Scope Cut 381 South Reader', 'customer', true, 'approved');
SELECT pg_temp.sf_login('9888897902') AS staff_claims \gset
SELECT pg_temp.sf_login('9888897903') AS supervisor_claims \gset
SELECT pg_temp.sf_login('9888897911') AS c1_claims \gset
SELECT pg_temp.sf_login('9888897912') AS c2_claims \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_customer(''Scope Cut 381 North'', ''9888897921'')')->>'success' = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_customer(''Scope Cut 381 South'', ''9888897922'')')->>'success' = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_item(''Scope Cut 381 Pepper'', ''Bag'')')->>'success' = 'true', 'customers and item');
SELECT id AS north FROM public.customers WHERE name = 'Scope Cut 381 North' \gset
SELECT id AS south FROM public.customers WHERE name = 'Scope Cut 381 South' \gset
SELECT id AS pepper FROM public.items WHERE name = 'Scope Cut 381 Pepper' \gset
SELECT pg_temp.sf_assert(
  pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT to_jsonb(public.assign_customer_to_user(%L, %L::uuid, %L))', '919888897911', :'north', 'WH-381 fixture'))::text = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT to_jsonb(public.assign_customer_to_user(%L, %L::uuid, %L))', '919888897912', :'south', 'WH-381 fixture'))::text = 'true',
  'customer accounts assigned');
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.replace_item_rates(%L::uuid, %L::uuid, %L, %L::date, %L::jsonb)', :'pepper', c, 'monthly', '2026-01-01',
  '[{"weight_min":0,"weight_max":100,"unit_price":5,"labour_rate":2,"tax_percent":5}]'))->>'success' = 'true', 'item rate for ' || c)
  FROM unnest(ARRAY[:'north', :'south']) c;
SELECT record_payments AS orig_record_payments FROM warehouse_security.charging_rule WHERE id \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.set_record_payments(true)')->>'success' = 'true', 'payments enabled for fixture');

SELECT jsonb_build_array(jsonb_build_object('scope', 'grn', 'item_id', :'pepper', 'weight_min', 0, 'weight_max', 100, 'unit_price', 5, 'labour_rate', 2, 'tax_percent', 5)) AS sc_rates \gset
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'SC381G1', :'north'::uuid, pg_temp.sf_lines(:'pepper'::uuid, 2, 'SCG1', 10), :'sc_rates'::jsonb) AS grn_g1 \gset
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'SC381G2', :'north'::uuid, pg_temp.sf_lines(:'pepper'::uuid, 1, 'SCG2', 10), :'sc_rates'::jsonb) AS grn_g2 \gset
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'SC381G3', :'north'::uuid, pg_temp.sf_lines(:'pepper'::uuid, 1, 'SCG3', 10), :'sc_rates'::jsonb) AS grn_g3 \gset
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'SC381S1', :'south'::uuid, pg_temp.sf_lines(:'pepper'::uuid, 1, 'SCS1', 10), :'sc_rates'::jsonb) AS grn_s1 \gset
SELECT id AS lot_g1a FROM public.goodsreceived_trl WHERE gr_id = :'grn_g1' AND package_mark = 'SCG11' \gset
SELECT id AS lot_g2 FROM public.goodsreceived_trl WHERE gr_id = :'grn_g2' \gset
SELECT id AS lot_g3 FROM public.goodsreceived_trl WHERE gr_id = :'grn_g3' \gset
SELECT pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.register_grn_image_upload(%L::uuid, %L, %L, 32, %L)', :'grn_g1', 'header', 'sc381.webp', 'image/webp'))->>'image_id' AS grn_img_1 \gset

SELECT pg_temp.sf_phone('admin', :'sf_admin_claims'::jsonb);
SELECT pg_temp.sf_phone('supervisor', :'supervisor_claims'::jsonb);
SELECT pg_temp.sf_phone('staff', :'staff_claims'::jsonb);
SELECT pg_temp.sf_phone('c1', :'c1_claims'::jsonb);
SELECT pg_temp.sf_phone('c2', :'c2_claims'::jsonb);
SELECT pg_temp.sf_first_load(p) FROM unnest(ARRAY['admin', 'supervisor', 'staff', 'c1', 'c2']) p;

-- ---------------------------------------------------------------------------------------------------------------------------------
-- 1. Format 8: state.format = 8 (and column default = 8); get_sync_start() returns format 8; format-7 copy key answers FORMAT_CHANGED.
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT pg_temp.sf_assert((SELECT format FROM warehouse_sync.state) = 8,
  '1.4: warehouse_sync.state.format must be 8, got ' || (SELECT format::text FROM warehouse_sync.state));
SELECT pg_temp.sf_assert((SELECT pg_get_expr(d.adbin, d.adrelid) FROM pg_attribute a JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
    WHERE a.attrelid = 'warehouse_sync.state'::regclass AND a.attname = 'format') = '8',
  '1.4: warehouse_sync.state.format default must be 8');
SELECT pg_temp.sf_assert((SELECT count(*) = 5 AND bool_and((answer->>pg_temp.sf('f_format'))::int = 8 AND split_part(answer->>pg_temp.sf('f_copy'), '.', 1) = '8')
    FROM pg_temp.sf_answer WHERE kind = 'start'),
  '1.4: get_sync_start() returns format = 8 and copy key starting with 8. for every role: '
  || (SELECT string_agg(phone || '=' || COALESCE(answer->>pg_temp.sf('f_format'), 'null'), ', ') FROM pg_temp.sf_answer WHERE kind = 'start'));
SELECT pg_temp.sf_changes_once('admin') AS f8_changes \gset
SELECT pg_temp.sf_assert(:'f8_changes'::jsonb->>'success' = 'true' AND (:'f8_changes'::jsonb->>pg_temp.sf('f_format'))::int = 8
  AND :'f8_changes'::jsonb->pg_temp.sf('f_reload_all') = 'null'::jsonb,
  '1.4: get_sync_changes() with format-8 copy key succeeds with format = 8: ' || left(:'f8_changes', 300));
SELECT pg_temp.sf_changes_once('admin', NULL, regexp_replace(copy, '^[0-9]+\.', '7.')) AS f7_ans
  FROM pg_temp.sf_device WHERE phone = 'admin' \gset
SELECT pg_temp.sf_assert(:'f7_ans'::jsonb->>'success' = 'true' AND (:'f7_ans'::jsonb->>pg_temp.sf('f_format'))::int = 8
  AND :'f7_ans'::jsonb#>>ARRAY[pg_temp.sf('f_reload_all'), pg_temp.sf('f_reason')] = pg_temp.sf('r_format'),
  '1.4: format-7 admin client calling get_sync_changes receives reload_all FORMAT_CHANGED: ' || left(:'f7_ans', 300));
SELECT pg_temp.sf_changes_once('c1', NULL, regexp_replace(copy, '^[0-9]+\.', '7.')) AS f7_cust_ans
  FROM pg_temp.sf_device WHERE phone = 'c1' \gset
SELECT pg_temp.sf_assert(:'f7_cust_ans'::jsonb#>>ARRAY[pg_temp.sf('f_reload_all'), pg_temp.sf('f_reason')] = pg_temp.sf('r_format'),
  '1.4: format-7 customer client calling get_sync_changes receives reload_all FORMAT_CHANGED: ' || left(:'f7_cust_ans', 300));
SELECT pg_temp.sf_as(d.claims, format(pg_temp.sf('call_checksums'), d.position, regexp_replace(d.copy, '^[0-9]+\.', '7.'))) AS f7_sums
  FROM pg_temp.sf_device d WHERE d.phone = 'admin' \gset
SELECT pg_temp.sf_assert(:'f7_sums'::jsonb#>>ARRAY[pg_temp.sf('f_reload_all'), pg_temp.sf('f_reason')] = pg_temp.sf('r_format'),
  '1.4: format-7 client calling get_sync_checksums receives reload_all FORMAT_CHANGED: ' || left(:'f7_sums', 300));

-- ---------------------------------------------------------------------------------------------------------------------------------
-- 2. warehouse_sync.entities(p_role) and RPC entity guards across all 4 roles (admin, supervisor, staff, customer).
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT pg_temp.sf_assert(NOT (warehouse_sync.entities(r) && pg_temp.sc381_dropped()),
  format('1.1: warehouse_sync.entities(%L) must not contain any dropped entity, got %s', r, warehouse_sync.entities(r)::text))
  FROM unnest(ARRAY['admin', 'supervisor', 'staff', 'customer']) r;

SELECT pg_temp.sf_assert(pg_temp.sc381_sorted(warehouse_sync.entities('admin')) = pg_temp.sc381_sorted(ARRAY[
    'customers', 'items', 'settings', 'goodsreceived', 'goodsreceived_trl', 'grn_images', 'grn_lock',
    'user_profiles', 'users_customers_new', 'grn_rates', 'item_storage_prices', 'standard_rate_tiers',
    'item_price_history', 'grn_replacements', 'held_items']),
  '1.1: admin kept entities exact set: got ' || pg_temp.sc381_sorted(warehouse_sync.entities('admin')));
SELECT pg_temp.sf_assert(pg_temp.sc381_sorted(warehouse_sync.entities('supervisor')) = pg_temp.sc381_sorted(warehouse_sync.entities('admin')),
  '1.1: supervisor kept entities match admin: got ' || pg_temp.sc381_sorted(warehouse_sync.entities('supervisor')));
SELECT pg_temp.sf_assert(pg_temp.sc381_sorted(warehouse_sync.entities('staff')) = pg_temp.sc381_sorted(ARRAY[
    'customers', 'items', 'settings', 'people', 'goodsreceived', 'goodsreceived_trl', 'grn_images',
    'grn_lock', 'grn_replacements', 'held_items']),
  '1.1: staff kept entities exact set (includes people; excludes rates, user_profiles, assignments): got '
  || pg_temp.sc381_sorted(warehouse_sync.entities('staff')));
SELECT pg_temp.sf_assert(pg_temp.sc381_sorted(warehouse_sync.entities('customer')) = pg_temp.sc381_sorted(ARRAY[
    'customers', 'items', 'goodsreceived', 'goodsreceived_trl', 'grn_images', 'grn_rates']),
  '1.1: customer kept entities exact set: got ' || pg_temp.sc381_sorted(warehouse_sync.entities('customer')));

-- get_sync_start() entities match warehouse_sync.entities(role) for each phone, and sf_copy holds zero dropped-entity rows.
SELECT pg_temp.sf_assert(pg_temp.sc381_sorted(d.entities) = pg_temp.sc381_sorted(warehouse_sync.entities(r.role)),
  format('1.1: get_sync_start() entities for %s (%s) differ from warehouse_sync.entities(%s)', r.phone, d.entities::text, r.role))
  FROM (VALUES ('admin', 'admin'), ('supervisor', 'supervisor'), ('staff', 'staff'), ('c1', 'customer')) r(phone, role)
  JOIN pg_temp.sf_device d ON d.phone = r.phone;
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy WHERE e = ANY (pg_temp.sc381_dropped())),
  '14a: no phone copy holds any row of the 8 dropped entities after first load');

-- get_sync_page and get_sync_checksums refuse every dropped entity with SYNC_UNKNOWN_ENTITY for admin and customer.
DO $$
DECLARE ent text; ans jsonb; d_admin record; d_cust record;
BEGIN
  SELECT * INTO STRICT d_admin FROM pg_temp.sf_device WHERE phone = 'admin';
  SELECT * INTO STRICT d_cust FROM pg_temp.sf_device WHERE phone = 'c1';
  FOREACH ent IN ARRAY pg_temp.sc381_dropped() LOOP
    ans := pg_temp.sf_as(d_admin.claims, format(pg_temp.sf('call_page'), ent, NULL, 10));
    PERFORM pg_temp.sf_assert(ans->>'success' = 'false' AND ans->>pg_temp.sf('f_refusal') = pg_temp.sf('err_entity'),
      format('1.1: admin get_sync_page(%L) must return SYNC_UNKNOWN_ENTITY, got %s', ent, left(ans::text, 200)));
    ans := pg_temp.sf_as(d_cust.claims, format(pg_temp.sf('call_page'), ent, NULL, 10));
    PERFORM pg_temp.sf_assert(ans->>'success' = 'false' AND ans->>pg_temp.sf('f_refusal') = pg_temp.sf('err_entity'),
      format('1.1: customer get_sync_page(%L) must return SYNC_UNKNOWN_ENTITY, got %s', ent, left(ans::text, 200)));
    ans := pg_temp.sf_as(d_admin.claims, format('SELECT public.get_sync_checksums(%L, %L, ARRAY[%L])', d_admin.position, d_admin.copy, ent));
    PERFORM pg_temp.sf_assert(ans->>'success' = 'false' AND ans->>pg_temp.sf('f_refusal') = pg_temp.sf('err_entity'),
      format('1.1: admin get_sync_checksums([%L]) must return SYNC_UNKNOWN_ENTITY, got %s', ent, left(ans::text, 200)));
  END LOOP;
  ans := pg_temp.sf_as(d_admin.claims, format(pg_temp.sf('call_checksums'), d_admin.position, d_admin.copy));
  PERFORM pg_temp.sf_assert(ans->>'success' = 'true' AND NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(ans->pg_temp.sf('f_entities')) x WHERE (x->>pg_temp.sf('f_e')) = ANY (pg_temp.sc381_dropped())),
    '1.1: admin get_sync_checksums(NULL) lists zero dropped entities');
END $$;

-- ---------------------------------------------------------------------------------------------------------------------------------
-- 3. warehouse_sync.log_change(): ZERO entity rows for the 8 dropped tables, ALL side-effect logging preserved.
-- ---------------------------------------------------------------------------------------------------------------------------------
-- 3a. dispatch & dispatch_trl: INSERT (partial), UPDATE dispatch.disp_date, UPDATE dispatch_trl, INSERT (full -> emptied_at), soft-delete, hard-delete.
SELECT pg_current_xact_id()::text AS m_xid \gset
SELECT pg_temp.sf_dispatch(:'sf_admin_claims'::jsonb, 'SC381D1', :'lot_g1a'::uuid, 4) AS disp_1 \gset
SELECT id AS dt_1 FROM public.dispatch_trl WHERE disp_id = :'disp_1' \gset
SELECT pg_temp.sf_assert(pg_temp.sc381_dropped_logs(:'m_xid'::xid8) = '',
  '1.2: creating a dispatch must emit zero dropped-entity log rows, got: ' || pg_temp.sc381_dropped_logs(:'m_xid'::xid8));
SELECT pg_temp.sf_assert(pg_temp.sc381_has_log(:'m_xid'::xid8, 'grn_lock', :'grn_g1')
  AND pg_temp.sc381_has_log(:'m_xid'::xid8, 'money', :'north')
  AND pg_temp.sc381_has_log(:'m_xid'::xid8, 'goodsreceived_trl', :'lot_g1a'),
  '1.2: creating a dispatch still logs grn_lock, money mark and goodsreceived_trl stock change');
SELECT pg_temp.sc381_pull_all('3a dispatch insert');
SELECT pg_temp.sf_assert((SELECT (row->>'stock')::int FROM pg_temp.sf_copy WHERE slot = 'admin' AND e = 'goodsreceived_trl' AND id = :'lot_g1a') = 6
  AND (SELECT (l->>pg_temp.sf('lock_dispatched'))::int FROM jsonb_array_elements(pg_temp.sc381_lock('admin', :'grn_g1'::uuid)->pg_temp.sf('lock_lines')) l
        WHERE l->>pg_temp.sf('lock_line_id') = :'lot_g1a') = 4
  AND pg_temp.sc381_lock('admin', :'grn_g1'::uuid)->>'first_dispatch_date' = '2026-06-01',
  '1.2: phone copy gets updated lot stock (6) and grn_lock (dispatched_qty=4, first_dispatch_date=2026-06-01)');
SELECT pg_temp.sf_assert(pg_temp.sc381_marks('admin') = ARRAY[:'north'] AND pg_temp.sc381_marks('supervisor') = ARRAY[:'north']
  AND pg_temp.sc381_marks('c1') = ARRAY[:'north'] AND pg_temp.sc381_marks('staff') = '{}' AND pg_temp.sc381_marks('c2') = '{}',
  '1.2: dispatch insert money mark reaches admin, supervisor, c1 only');

-- Direct dispatch UPDATE (changes first_dispatch_date on grn_lock without touching dispatch_trl or goodsreceived_trl).
SELECT pg_current_xact_id()::text AS m_xid \gset
UPDATE public.dispatch SET disp_date = '2026-05-15' WHERE id = :'disp_1';
SELECT pg_temp.sf_assert(pg_temp.sc381_dropped_logs(:'m_xid'::xid8) = '',
  '1.2: updating dispatch must emit zero dropped-entity log rows, got: ' || pg_temp.sc381_dropped_logs(:'m_xid'::xid8));
SELECT pg_temp.sf_assert(pg_temp.sc381_has_log(:'m_xid'::xid8, 'grn_lock', :'grn_g1')
  AND pg_temp.sc381_has_log(:'m_xid'::xid8, 'money', :'north'),
  '1.2: updating dispatch directly still emits grn_lock and money mark');
SELECT pg_temp.sc381_pull_all('3a dispatch update');
SELECT pg_temp.sf_assert(pg_temp.sc381_lock('staff', :'grn_g1'::uuid)->>'first_dispatch_date' = '2026-05-15'
  AND pg_temp.sc381_marks('c1') = ARRAY[:'north'] AND pg_temp.sc381_marks('staff') = '{}',
  '1.2: dispatch date update updates grn_lock.first_dispatch_date on staff and marks North money stale on c1');

-- Direct dispatch_trl UPDATE.
SELECT pg_current_xact_id()::text AS m_xid \gset
UPDATE public.dispatch_trl SET cart_quantity_consumed = cart_quantity_consumed + 1 WHERE id = :'dt_1';
SELECT pg_temp.sf_assert(pg_temp.sc381_dropped_logs(:'m_xid'::xid8) = '',
  '1.2: updating dispatch_trl must emit zero dropped-entity log rows, got: ' || pg_temp.sc381_dropped_logs(:'m_xid'::xid8));
SELECT pg_temp.sf_assert(pg_temp.sc381_has_log(:'m_xid'::xid8, 'grn_lock', :'grn_g1')
  AND pg_temp.sc381_has_log(:'m_xid'::xid8, 'money', :'north'),
  '1.2: updating dispatch_trl still emits grn_lock and money mark');
SELECT pg_temp.sc381_pull_all('3a dispatch_trl update');
SELECT pg_temp.sf_assert(pg_temp.sc381_marks('admin') = ARRAY[:'north'] AND pg_temp.sc381_marks('c1') = ARRAY[:'north']
  AND pg_temp.sf_ops('staff', pg_temp.sf('e_grn_lock'), :'grn_g1', pg_temp.sf_last_pull('staff')) = pg_temp.sf('op_upsert'),
  '1.2: dispatch_trl update delivers grn_lock upsert to staff and money mark to admin/c1');

-- Full dispatch emptying lot_g2 -> goodsreceived_trl stock = 0 and emptied_at set.
SELECT pg_current_xact_id()::text AS m_xid \gset
SELECT pg_temp.sf_dispatch(:'sf_admin_claims'::jsonb, 'SC381D2', :'lot_g2'::uuid, 10) AS disp_2 \gset
SELECT id AS dt_2 FROM public.dispatch_trl WHERE disp_id = :'disp_2' \gset
SELECT pg_temp.sf_assert(pg_temp.sc381_dropped_logs(:'m_xid'::xid8) = '',
  '1.2: emptying dispatch must emit zero dropped-entity log rows, got: ' || pg_temp.sc381_dropped_logs(:'m_xid'::xid8));
SELECT pg_temp.sc381_pull_all('3a emptying dispatch');
SELECT pg_temp.sf_assert((SELECT (row->>'stock')::int = 0 AND row->>'emptied_at' IS NOT NULL
    FROM pg_temp.sf_copy WHERE slot = p AND e = 'goodsreceived_trl' AND id = :'lot_g2'),
  '1.2: ' || p || ' receives goodsreceived_trl stock=0 and non-null emptied_at on emptying dispatch')
  FROM unnest(ARRAY['admin', 'staff', 'c1']) p;

-- Soft-delete and restore dispatch, then hard-delete dispatch via delete_dispatch_with_order_cleanup.
SELECT pg_current_xact_id()::text AS m_xid \gset
UPDATE public.dispatch SET deleted_at = now() WHERE id = :'disp_1';
SELECT pg_temp.sf_assert(pg_temp.sc381_dropped_logs(:'m_xid'::xid8) = ''
  AND pg_temp.sc381_has_log(:'m_xid'::xid8, 'grn_lock', :'grn_g1')
  AND pg_temp.sc381_has_log(:'m_xid'::xid8, 'money', :'north'),
  '1.2: soft-deleting dispatch logs grn_lock + money and zero dropped-entity rows');
UPDATE public.dispatch SET deleted_at = NULL WHERE id = :'disp_1';
SELECT pg_temp.sc381_pull_all('3a dispatch soft delete and restore');
SELECT pg_current_xact_id()::text AS m_xid \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.delete_dispatch_with_order_cleanup(%L::uuid, %L::uuid)', :'disp_1', :'sf_admin_profile'))->>'success' = 'true',
  'fixture: delete_dispatch_with_order_cleanup SC381D1');
SELECT pg_temp.sf_assert(pg_temp.sc381_dropped_logs(:'m_xid'::xid8) = '',
  '1.2: deleting dispatch must emit zero dropped-entity log rows, got: ' || pg_temp.sc381_dropped_logs(:'m_xid'::xid8));
SELECT pg_temp.sc381_pull_all('3a dispatch delete');
SELECT pg_temp.sf_assert((SELECT (row->>'stock')::int FROM pg_temp.sf_copy WHERE slot = 'c1' AND e = 'goodsreceived_trl' AND id = :'lot_g1a') = 10
  AND (SELECT (l->>pg_temp.sf('lock_dispatched'))::int FROM jsonb_array_elements(pg_temp.sc381_lock('admin', :'grn_g1'::uuid)->pg_temp.sf('lock_lines')) l
        WHERE l->>pg_temp.sf('lock_line_id') = :'lot_g1a') = 0
  AND pg_temp.sc381_marks('c1') = ARRAY[:'north'],
  '1.2: deleting dispatch restores lot stock (10), resets grn_lock dispatched_qty (0), and marks money stale');

-- 3b. dispatch_images: INSERT, UPDATE, DELETE emit zero change_log rows for any dropped entity.
SELECT pg_current_xact_id()::text AS m_xid \gset
INSERT INTO public.dispatch_images(dispatch_id, storage_path, original_filename, file_size, mime_type, status)
  VALUES (:'disp_2', 'sc381/d2.webp', 'd2.webp', 64, 'image/webp', 'confirmed') RETURNING id AS disp_img_1 \gset
INSERT INTO public.dispatch_images(dispatch_id, storage_path, original_filename, file_size, mime_type, status)
  VALUES (:'disp_2', 'sc381/d2-del.webp', 'd2-del.webp', 64, 'image/webp', 'confirmed') RETURNING id AS disp_img_del \gset
UPDATE public.dispatch_images SET display_order = 2 WHERE id = :'disp_img_1';
DELETE FROM public.dispatch_images WHERE id = :'disp_img_del';
SELECT pg_temp.sf_assert(pg_temp.sc381_dropped_logs(:'m_xid'::xid8) = '',
  '1.2: dispatch_images insert/update/delete must emit zero dropped-entity log rows, got: ' || pg_temp.sc381_dropped_logs(:'m_xid'::xid8));
SELECT pg_temp.sc381_pull_all('3b dispatch_images');

-- 3c. invoice & invoice_trl: INSERT, direct UPDATE on invoice_trl, payments (3d), cancel_invoice, delete_invoice.
SELECT pg_current_xact_id()::text AS m_xid \gset
SELECT pg_temp.sc381_invoice(:'sf_admin_claims'::jsonb, 8801, :'disp_2'::uuid) AS inv_1 \gset
SELECT id AS inv_line_1 FROM public.invoice_trl WHERE invoice_id = :'inv_1' \gset
SELECT pg_temp.sf_assert(pg_temp.sc381_dropped_logs(:'m_xid'::xid8) = '',
  '1.2: save_invoice must emit zero dropped-entity log rows, got: ' || pg_temp.sc381_dropped_logs(:'m_xid'::xid8));
SELECT pg_temp.sf_assert(pg_temp.sc381_has_log(:'m_xid'::xid8, 'grn_lock', :'grn_g2')
  AND pg_temp.sc381_has_log(:'m_xid'::xid8, 'money', :'north'),
  '1.2: save_invoice still emits grn_lock and money mark');
SELECT pg_temp.sc381_pull_all('3c invoice insert');
SELECT pg_temp.sf_assert(pg_temp.sc381_lock('staff', :'grn_g2'::uuid)->>'invoice_state' = 'invoiced'
  AND (SELECT (l->>'on_invoice')::boolean FROM jsonb_array_elements(pg_temp.sc381_lock('staff', :'grn_g2'::uuid)->pg_temp.sf('lock_lines')) l
        WHERE l->>pg_temp.sf('lock_line_id') = :'lot_g2')
  AND pg_temp.sc381_marks('admin') = ARRAY[:'north'] AND pg_temp.sc381_marks('c1') = ARRAY[:'north'] AND pg_temp.sc381_marks('staff') = '{}',
  '1.2: invoice creation updates grn_lock (invoice_state=invoiced, on_invoice=true) and marks money stale');

-- Direct invoice_trl UPDATE (used to also log 'invoice' under migration 221): must emit zero invoice/invoice_trl rows, still grn_lock + money.
SELECT pg_current_xact_id()::text AS m_xid \gset
UPDATE public.invoice_trl SET charge = 6 WHERE id = :'inv_line_1';
SELECT pg_temp.sf_assert(pg_temp.sc381_dropped_logs(:'m_xid'::xid8) = '',
  '1.2: updating invoice_trl must emit zero dropped-entity log rows (no invoice or invoice_trl), got: ' || pg_temp.sc381_dropped_logs(:'m_xid'::xid8));
SELECT pg_temp.sf_assert(pg_temp.sc381_has_log(:'m_xid'::xid8, 'grn_lock', :'grn_g2')
  AND pg_temp.sc381_has_log(:'m_xid'::xid8, 'money', :'north'),
  '1.2: updating invoice_trl still emits grn_lock and money mark');
SELECT pg_temp.sc381_pull_all('3c invoice_trl update');
SELECT pg_temp.sf_assert(pg_temp.sc381_marks('c1') = ARRAY[:'north'], '1.2: invoice_trl update delivers money mark to c1');

-- 3d. payments: record_payment, update_payment, delete_payment (used to log 'payments' AND 'invoice' under migrations 214/219).
SELECT pg_current_xact_id()::text AS m_xid \gset
SELECT pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.record_payment(%L::uuid, DATE %L, 1, %L, NULL, %L)', :'inv_1', '2026-06-03', 'cash', 'sc381-pay-1')) AS pay_ans \gset
SELECT pg_temp.sf_assert(:'pay_ans'::jsonb->>'success' = 'true', 'fixture: record_payment: ' || left(:'pay_ans', 300));
SELECT (:'pay_ans'::jsonb#>>'{payment,id}') AS pay_1 \gset
SELECT pg_temp.sf_assert(pg_temp.sc381_dropped_logs(:'m_xid'::xid8) = '',
  '1.2: record_payment must emit zero dropped-entity log rows (no payments or invoice), got: ' || pg_temp.sc381_dropped_logs(:'m_xid'::xid8));
SELECT pg_temp.sf_assert(pg_temp.sc381_has_log(:'m_xid'::xid8, 'money', :'north'), '1.2: record_payment still emits money mark');
SELECT pg_temp.sc381_pull_all('3d record_payment');
SELECT pg_temp.sf_assert(pg_temp.sc381_marks('admin') = ARRAY[:'north'] AND pg_temp.sc381_marks('supervisor') = ARRAY[:'north']
  AND pg_temp.sc381_marks('c1') = ARRAY[:'north'] AND pg_temp.sc381_marks('staff') = '{}' AND pg_temp.sc381_marks('c2') = '{}',
  '1.2: record_payment money mark reaches admin, supervisor, c1 only');

SELECT updated_at AS pay_ver FROM public.payments WHERE id = :'pay_1' \gset
SELECT pg_current_xact_id()::text AS m_xid \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.update_payment(%L::uuid, DATE %L, 2, %L, %L::timestamptz)', :'pay_1', '2026-06-03', 'cash', :'pay_ver'))->>'success' = 'true',
  'fixture: update_payment');
SELECT pg_temp.sf_assert(pg_temp.sc381_dropped_logs(:'m_xid'::xid8) = '' AND pg_temp.sc381_has_log(:'m_xid'::xid8, 'money', :'north'),
  '1.2: update_payment emits money mark and zero dropped-entity rows');
SELECT pg_temp.sc381_pull_all('3d update_payment');

SELECT updated_at AS pay_ver2 FROM public.payments WHERE id = :'pay_1' \gset
SELECT pg_current_xact_id()::text AS m_xid \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.delete_payment(%L::uuid, %L::timestamptz)', :'pay_1', :'pay_ver2'))->>'success' = 'true',
  'fixture: delete_payment');
SELECT pg_temp.sf_assert(pg_temp.sc381_dropped_logs(:'m_xid'::xid8) = '' AND pg_temp.sc381_has_log(:'m_xid'::xid8, 'money', :'north'),
  '1.2: delete_payment emits money mark and zero dropped-entity rows');
SELECT pg_temp.sc381_pull_all('3d delete_payment');

-- Cancel and delete invoice: zero invoice/invoice_trl rows, grn_lock updated, money marked.
SELECT pg_current_xact_id()::text AS m_xid \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.cancel_invoice(%L::uuid, %L, NULL)', :'inv_1', 'WH-381 cancel test'))->>'success' = 'true',
  'fixture: cancel_invoice 8801');
SELECT pg_temp.sf_assert(pg_temp.sc381_dropped_logs(:'m_xid'::xid8) = ''
  AND pg_temp.sc381_has_log(:'m_xid'::xid8, 'grn_lock', :'grn_g2')
  AND pg_temp.sc381_has_log(:'m_xid'::xid8, 'money', :'north'),
  '1.2: cancel_invoice emits grn_lock + money mark and zero dropped-entity rows');
SELECT pg_temp.sc381_pull_all('3c cancel_invoice');
SELECT pg_temp.sf_assert(pg_temp.sc381_lock('staff', :'grn_g2'::uuid)->>'invoice_state' = 'not_invoiced'
  AND NOT (SELECT (l->>'on_invoice')::boolean FROM jsonb_array_elements(pg_temp.sc381_lock('staff', :'grn_g2'::uuid)->pg_temp.sf('lock_lines')) l
            WHERE l->>pg_temp.sf('lock_line_id') = :'lot_g2'),
  '1.2: cancel_invoice clears on_invoice and sets invoice_state=not_invoiced on staff grn_lock');

SELECT pg_current_xact_id()::text AS m_xid \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.delete_invoice(%L::uuid)', :'inv_1'))->>'success' = 'true',
  'fixture: delete_invoice 8801');
SELECT pg_temp.sf_assert(pg_temp.sc381_dropped_logs(:'m_xid'::xid8) = ''
  AND pg_temp.sc381_has_log(:'m_xid'::xid8, 'grn_lock', :'grn_g2')
  AND pg_temp.sc381_has_log(:'m_xid'::xid8, 'money', :'north'),
  '1.2: delete_invoice emits grn_lock + money mark and zero dropped-entity rows');
SELECT pg_temp.sc381_pull_all('3c delete_invoice');

-- 3e. orders & order_items: create cart, add item, update qty, soft-delete order, profile rename, remove item.
SELECT pg_current_xact_id()::text AS m_xid \gset
SELECT (pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT to_jsonb(public.get_or_create_cart(%L::uuid))', :'north')) #>> '{}')::uuid AS ord_1 \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.add_item_to_order(%L::uuid, %L::uuid, 3)', :'ord_1', :'lot_g3'))->>'success' = 'true',
  'fixture: add_item_to_order');
SELECT id AS oi_1 FROM public.order_items WHERE order_id = :'ord_1' AND grn_items_id = :'lot_g3' \gset
SELECT pg_temp.sf_assert(pg_temp.sc381_dropped_logs(:'m_xid'::xid8) = '',
  '1.2: orders/order_items insert must emit zero dropped-entity log rows, got: ' || pg_temp.sc381_dropped_logs(:'m_xid'::xid8));
SELECT pg_temp.sf_assert(pg_temp.sc381_has_log(:'m_xid'::xid8, 'grn_lock', :'grn_g3'),
  '1.2: adding order_items still emits grn_lock for the ordered GRN');
SELECT pg_temp.sc381_pull_all('3e order insert');
SELECT pg_temp.sf_assert((SELECT (l->>'on_order')::boolean FROM jsonb_array_elements(pg_temp.sc381_lock('staff', :'grn_g3'::uuid)->pg_temp.sf('lock_lines')) l
    WHERE l->>pg_temp.sf('lock_line_id') = :'lot_g3'),
  '1.2: staff grn_lock reflects on_order = true after add_item_to_order');

SELECT pg_current_xact_id()::text AS m_xid \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.update_order_item_quantity(%L::uuid, 5)', :'oi_1'))->>'success' = 'true',
  'fixture: update_order_item_quantity');
SELECT pg_temp.sf_assert(pg_temp.sc381_dropped_logs(:'m_xid'::xid8) = '' AND pg_temp.sc381_has_log(:'m_xid'::xid8, 'grn_lock', :'grn_g3'),
  '1.2: update_order_item_quantity emits grn_lock and zero dropped-entity rows');
SELECT pg_temp.sc381_pull_all('3e order_items update');

-- Soft-delete order: grn_lock clears on_order; zero 'orders' log row.
SELECT pg_current_xact_id()::text AS m_xid \gset
UPDATE public.orders SET deleted_at = now() WHERE id = :'ord_1';
SELECT pg_temp.sf_assert(pg_temp.sc381_dropped_logs(:'m_xid'::xid8) = '' AND pg_temp.sc381_has_log(:'m_xid'::xid8, 'grn_lock', :'grn_g3'),
  '1.2: soft-deleting orders emits grn_lock and zero dropped-entity rows');
SELECT pg_temp.sc381_pull_all('3e order soft delete');
SELECT pg_temp.sf_assert(NOT (SELECT (l->>'on_order')::boolean FROM jsonb_array_elements(pg_temp.sc381_lock('staff', :'grn_g3'::uuid)->pg_temp.sf('lock_lines')) l
    WHERE l->>pg_temp.sf('lock_line_id') = :'lot_g3'),
  '1.2: soft-deleting order clears on_order on staff grn_lock');
UPDATE public.orders SET deleted_at = NULL WHERE id = :'ord_1';
SELECT pg_temp.sc381_pull_all('3e order restore');

-- Renaming the user_profiles row that updated_by the order (migration 213 used to emit an 'orders' log row here!).
SELECT pg_current_xact_id()::text AS m_xid \gset
UPDATE public.user_profiles SET name = 'Scope Cut 381 Admin Renamed' WHERE mobile = '919888897001';
UPDATE public.user_profiles SET name = 'Sync Feed Administrator' WHERE mobile = '919888897001';
SELECT pg_temp.sf_assert(pg_temp.sc381_dropped_logs(:'m_xid'::xid8) = '',
  '1.2: renaming user_profiles must not emit orders or dispatch log rows, got: ' || pg_temp.sc381_dropped_logs(:'m_xid'::xid8));
SELECT pg_temp.sc381_pull_all('3e profile rename');

-- Removing an order item and deleting an order (South's GRN): zero dropped-entity rows, grn_lock cleared.
SELECT id AS lot_s1 FROM public.goodsreceived_trl WHERE gr_id = :'grn_s1' \gset
SELECT (pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT to_jsonb(public.get_or_create_cart(%L::uuid))', :'south')) #>> '{}')::uuid AS ord_s \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.add_item_to_order(%L::uuid, %L::uuid, 2)', :'ord_s', :'lot_s1'))->>'success' = 'true',
  'fixture: add_item_to_order South');
SELECT id AS oi_s FROM public.order_items WHERE order_id = :'ord_s' AND grn_items_id = :'lot_s1' \gset
SELECT pg_temp.sc381_pull_all('3e south order insert');
SELECT pg_current_xact_id()::text AS m_xid \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.remove_item_from_order(%L::uuid)', :'oi_s'))->>'success' = 'true',
  'fixture: remove_item_from_order South');
DELETE FROM public.orders WHERE id = :'ord_s';
SELECT pg_temp.sf_assert(pg_temp.sc381_dropped_logs(:'m_xid'::xid8) = '' AND pg_temp.sc381_has_log(:'m_xid'::xid8, 'grn_lock', :'grn_s1'),
  '1.2: removing order_items and deleting orders emits grn_lock and zero dropped-entity rows');
SELECT pg_temp.sc381_pull_all('3e south order delete');
SELECT pg_temp.sf_assert(NOT (SELECT (l->>'on_order')::boolean FROM jsonb_array_elements(pg_temp.sc381_lock('staff', :'grn_s1'::uuid)->pg_temp.sf('lock_lines')) l
    WHERE l->>pg_temp.sf('lock_line_id') = :'lot_s1'),
  '1.2: removing order_items clears on_order on staff grn_lock');

-- 3f. Kept grn_lock sources (grn_rates, imported_documents) and kept money-mark sources (goodsreceived, customers, item_storage_prices, charging_rule, system_settings).
SELECT pg_current_xact_id()::text AS m_xid \gset
UPDATE public.grn_rates SET unit_price = 7 WHERE id = (SELECT id FROM public.grn_rates WHERE gr_id = :'grn_g1' ORDER BY id LIMIT 1);
SELECT pg_temp.sf_assert(pg_temp.sc381_dropped_logs(:'m_xid'::xid8) = ''
  AND pg_temp.sc381_has_log(:'m_xid'::xid8, 'grn_rates', (SELECT id::text FROM public.grn_rates WHERE gr_id = :'grn_g1' ORDER BY id LIMIT 1))
  AND pg_temp.sc381_has_log(:'m_xid'::xid8, 'grn_lock', :'grn_g1')
  AND pg_temp.sc381_has_log(:'m_xid'::xid8, 'money', :'north'),
  '1.2: grn_rates update still logs grn_rates, grn_lock and money mark');
SELECT pg_temp.sc381_pull_all('3f grn_rates');

INSERT INTO warehouse_security.import_batches(files, counts, applied_at)
  VALUES ('[{"name":"sc381.csv","sha256":"00","rows":1}]', '{"grn":1}', now()) RETURNING id AS sc_batch \gset
SELECT pg_temp.sc381_pull_all('3f import batch reload');
SELECT pg_current_xact_id()::text AS m_xid \gset
INSERT INTO warehouse_security.imported_documents(kind, doc_key, doc_id, batch_id, content_hash)
  VALUES ('grn', 'SC381G3|2026-04-01', :'grn_g3', :'sc_batch', md5('sc381-g3'));
SELECT pg_temp.sf_assert(pg_temp.sc381_dropped_logs(:'m_xid'::xid8) = '' AND pg_temp.sc381_has_log(:'m_xid'::xid8, 'grn_lock', :'grn_g3'),
  '1.2: imported_documents insert still logs grn_lock');
SELECT pg_temp.sc381_pull_all('3f imported_documents');
SELECT pg_temp.sf_assert((pg_temp.sc381_lock('staff', :'grn_g3'::uuid)->>'imported')::boolean,
  '1.2: imported_documents insert flips grn_lock.imported = true on staff');

SELECT pg_current_xact_id()::text AS m_xid \gset
UPDATE public.goodsreceived SET note = 'sc381 money mark' WHERE id = :'grn_g1';
SELECT pg_temp.sf_assert(pg_temp.sc381_dropped_logs(:'m_xid'::xid8) = '' AND pg_temp.sc381_has_log(:'m_xid'::xid8, 'money', :'north'),
  '1.2: goodsreceived update still logs money mark and zero dropped-entity rows');
SELECT pg_temp.sc381_pull_all('3f goodsreceived');
SELECT pg_temp.sf_assert(pg_temp.sc381_marks('admin') = ARRAY[:'north'] AND pg_temp.sc381_marks('c1') = ARRAY[:'north'] AND pg_temp.sc381_marks('staff') = '{}',
  '1.2: goodsreceived money mark delivered to admin and c1, not staff');

SELECT pg_current_xact_id()::text AS m_xid \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.replace_item_rates(%L::uuid, %L::uuid, %L, %L::date, %L::jsonb)', :'pepper', :'north', 'monthly', '2026-01-01',
  '[{"weight_min":0,"weight_max":100,"unit_price":6,"labour_rate":2,"tax_percent":5}]'))->>'success' = 'true', 'fixture: replace_item_rates');
SELECT pg_temp.sf_assert(pg_temp.sc381_dropped_logs(:'m_xid'::xid8) = '' AND pg_temp.sc381_has_log(:'m_xid'::xid8, 'money', 'all'),
  '1.2: item_storage_prices update still logs money all mark');
SELECT pg_temp.sc381_pull_all('3f item_storage_prices');
SELECT pg_temp.sf_assert(pg_temp.sc381_marks('admin') = ARRAY['all'] AND pg_temp.sc381_marks('c1') = ARRAY['all'] AND pg_temp.sc381_marks('c2') = ARRAY['all'] AND pg_temp.sc381_marks('staff') = '{}',
  '1.2: money all mark delivered to admin, c1, c2, not staff');

-- ---------------------------------------------------------------------------------------------------------------------------------
-- 4. caller_log() legacy row filtering (never returns or stalls on pre-migration rows) and expand() cleanup.
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT pg_current_xact_id()::text AS legacy_from \gset
INSERT INTO warehouse_sync.change_log(tbl, row_key, op, old_customer, new_customer, grn_id, disp_id)
  SELECT t, gen_random_uuid()::text, 'U', :'north'::uuid, :'north'::uuid, :'grn_g1'::uuid, :'disp_2'::uuid
    FROM unnest(pg_temp.sc381_dropped()) t;
SELECT pg_current_xact_id()::text AS legacy_to \gset

-- caller_log() filters out all 8 legacy dropped-entity rows for every role.
SELECT pg_temp.sf_assert((SELECT count(*) FROM warehouse_sync.caller_log(r.role, r.custs, :'legacy_from'::xid8, :'legacy_to'::xid8, 2000)) = 0,
  format('1.3: caller_log(%L) must filter out legacy dropped-entity rows, got %s rows',
    r.role, (SELECT count(*) FROM warehouse_sync.caller_log(r.role, r.custs, :'legacy_from'::xid8, :'legacy_to'::xid8, 2000))))
  FROM (VALUES ('admin', '{}'::uuid[]), ('supervisor', '{}'::uuid[]), ('staff', '{}'::uuid[]), ('customer', ARRAY[:'north'::uuid])) r(role, custs);

-- get_sync_changes advances cleanly past legacy rows with zero entries and zero reloads.
SELECT pg_temp.sf_pull('admin') AS leg_admin, pg_temp.sf_pull('supervisor') AS leg_sup, pg_temp.sf_pull('staff') AS leg_staff, pg_temp.sf_pull('c1') AS leg_c1 \gset
SELECT pg_temp.sf_assert((:'leg_admin'::jsonb->>'entries')::int = 0 AND :'leg_admin'::jsonb->'reload' = '[]' AND :'leg_admin'::jsonb->'reload_all' = '[]'
  AND (:'leg_c1'::jsonb->>'entries')::int = 0 AND :'leg_c1'::jsonb->'reload' = '[]' AND :'leg_c1'::jsonb->'reload_all' = '[]',
  '1.3: get_sync_changes returns zero entries and zero reloads over legacy dropped-entity log rows');

-- No-stall pagination: 25 legacy dropped-entity rows in ONE transaction (> p_limit = 10) followed by one kept GRN update.
-- Without caller_log() filtering, p_limit = 10 would stall or trigger a bogus oversize-transaction reload instead of delivering the GRN in one call.
INSERT INTO warehouse_sync.change_log(tbl, row_key, op, old_customer, new_customer, grn_id, disp_id)
  SELECT (pg_temp.sc381_dropped())[1 + (g % 8)], gen_random_uuid()::text, 'U', :'north'::uuid, :'north'::uuid, :'grn_g1'::uuid, :'disp_2'::uuid
    FROM generate_series(1, 25) g;
UPDATE public.goodsreceived SET note = 'sc381 after legacy burst' WHERE id = :'grn_g1';
SELECT pg_temp.sf_changes_once('admin', NULL, NULL, 10) AS burst_admin,
       pg_temp.sf_changes_once('c1', NULL, NULL, 10) AS burst_c1 \gset
SELECT pg_temp.sf_assert(:'burst_admin'::jsonb->>'success' = 'true' AND (:'burst_admin'::jsonb->>'more')::boolean = false
  AND :'burst_admin'::jsonb->'reload' = '[]'::jsonb AND :'burst_admin'::jsonb->'reload_all' = 'null'::jsonb
  AND EXISTS (SELECT 1 FROM jsonb_array_elements(:'burst_admin'::jsonb->'changes') x WHERE x->>'e' = 'goodsreceived' AND x->>'id' = :'grn_g1')
  AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(:'burst_admin'::jsonb->'changes') x WHERE (x->>'e') = ANY (pg_temp.sc381_dropped())),
  '1.3: admin get_sync_changes(p_limit=10) skips 25 legacy dropped rows without stalling and delivers the kept GRN immediately: ' || left(:'burst_admin', 300));
SELECT pg_temp.sf_assert(:'burst_c1'::jsonb->>'success' = 'true' AND (:'burst_c1'::jsonb->>'more')::boolean = false
  AND :'burst_c1'::jsonb->'reload' = '[]'::jsonb AND :'burst_c1'::jsonb->'reload_all' = 'null'::jsonb
  AND EXISTS (SELECT 1 FROM jsonb_array_elements(:'burst_c1'::jsonb->'changes') x WHERE x->>'e' = 'goodsreceived' AND x->>'id' = :'grn_g1')
  AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(:'burst_c1'::jsonb->'changes') x WHERE (x->>'e') = ANY (pg_temp.sc381_dropped())),
  '1.3: customer get_sync_changes(p_limit=10) skips 25 legacy dropped rows without stalling and delivers the kept GRN immediately: ' || left(:'burst_c1', 300));
SELECT pg_temp.sc381_pull_all('4 legacy burst catch-up');

-- expand(): create a live invoice on disp_2/grn_g2 so joins to invoice/invoice_trl WOULD match if not removed, plus a live payment.
SELECT pg_temp.sc381_invoice(:'sf_admin_claims'::jsonb, 8802, :'disp_2'::uuid) AS inv_2 \gset
SELECT id AS inv_line_2 FROM public.invoice_trl WHERE invoice_id = :'inv_2' \gset
SELECT (pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.record_payment(%L::uuid, DATE %L, 1, %L, NULL, %L)', :'inv_2', '2026-06-03', 'cash', 'sc381-pay-2'))#>>'{payment,id}') AS pay_2 \gset

SELECT pg_temp.sf_assert(NOT EXISTS (
    SELECT 1 FROM warehouse_sync.expand(r, ARRAY[ROW(pg_current_xact_id(), now(), 'goodsreceived'::text, :'grn_g2'::text, 'U'::"char", :'north'::uuid, :'north'::uuid, :'grn_g2'::uuid, NULL::uuid)::warehouse_sync.change_log]) k
     WHERE k.e = ANY (pg_temp.sc381_dropped()))
  AND EXISTS (
    SELECT 1 FROM warehouse_sync.expand(r, ARRAY[ROW(pg_current_xact_id(), now(), 'goodsreceived'::text, :'grn_g2'::text, 'U'::"char", :'north'::uuid, :'north'::uuid, :'grn_g2'::uuid, NULL::uuid)::warehouse_sync.change_log]) k
     WHERE k.e = 'goodsreceived_trl' AND k.id = :'lot_g2'),
  format('1.3: expand(%L, goodsreceived) emits goodsreceived_trl and zero dropped entities (no invoice fan-out)', r))
  FROM unnest(ARRAY['admin', 'supervisor', 'staff', 'customer']) r;

SELECT pg_temp.sf_assert(NOT EXISTS (
    SELECT 1 FROM warehouse_sync.expand(r, ARRAY[ROW(pg_current_xact_id(), now(), 'dispatch_trl'::text, :'dt_2'::text, 'U'::"char", :'north'::uuid, :'north'::uuid, :'grn_g2'::uuid, :'disp_2'::uuid)::warehouse_sync.change_log]) k
     WHERE k.e = ANY (pg_temp.sc381_dropped())),
  format('1.3: expand(%L, dispatch_trl) emits zero dropped entities (no invoice/invoice_trl fan-out)', r))
  FROM unnest(ARRAY['admin', 'supervisor', 'staff', 'customer']) r;

SELECT pg_temp.sf_assert(NOT EXISTS (
    SELECT 1 FROM warehouse_sync.expand('admin', ARRAY[ROW(pg_current_xact_id(), now(), 'user_profiles'::text, :'sf_admin_profile'::text, 'U'::"char", NULL::uuid, NULL::uuid, NULL::uuid, NULL::uuid)::warehouse_sync.change_log]) k
     WHERE k.e = ANY (pg_temp.sc381_dropped()))
  AND EXISTS (
    SELECT 1 FROM warehouse_sync.expand('admin', ARRAY[ROW(pg_current_xact_id(), now(), 'user_profiles'::text, :'sf_admin_profile'::text, 'U'::"char", NULL::uuid, NULL::uuid, NULL::uuid, NULL::uuid)::warehouse_sync.change_log]) k
     WHERE k.e = 'settings' AND k.id = 'gst_details'),
  '1.3: expand(admin, user_profiles) keeps settings/gst_details and drops orders/dispatch fan-out');

-- Verify the dead invoice expansion branches are actually removed from expand()'s definition, not merely masked by entities().
SELECT pg_temp.sf_assert(
  position('''invoice''' IN pg_get_functiondef('warehouse_sync.expand(text, warehouse_sync.change_log[])'::regprocedure)) = 0
  AND position('''invoice_trl''' IN pg_get_functiondef('warehouse_sync.expand(text, warehouse_sync.change_log[])'::regprocedure)) = 0,
  '1.3: warehouse_sync.expand() no longer contains goodsreceived->invoice or dispatch_trl->invoice branches');

-- ---------------------------------------------------------------------------------------------------------------------------------
-- 5. affected() and existing_ids() narrowed to kept entities.
-- ---------------------------------------------------------------------------------------------------------------------------------
SELECT pg_temp.sf_assert(pg_temp.sc381_sorted(warehouse_sync.affected('goodsreceived')) = 'goodsreceived,goodsreceived_trl,grn_images,grn_lock,grn_rates',
  '1.3: affected(goodsreceived) narrowed to kept entities (no invoice/invoice_trl), got ' || pg_temp.sc381_sorted(warehouse_sync.affected('goodsreceived')));
SELECT pg_temp.sf_assert(pg_temp.sc381_sorted(warehouse_sync.affected('goodsreceived_trl')) = 'goodsreceived_trl,grn_lock',
  '1.3: affected(goodsreceived_trl) stays goodsreceived_trl,grn_lock, got ' || pg_temp.sc381_sorted(warehouse_sync.affected('goodsreceived_trl')));
SELECT pg_temp.sf_assert(pg_temp.sc381_sorted(warehouse_sync.affected('user_profiles')) = 'people,settings,user_profiles',
  '1.3: affected(user_profiles) narrowed to kept entities (no orders/dispatch), got ' || pg_temp.sc381_sorted(warehouse_sync.affected('user_profiles')));
SELECT pg_temp.sf_assert(NOT (warehouse_sync.affected(tbl) && pg_temp.sc381_dropped()),
  format('1.3: affected(%L) must not return any dropped entity, got %s', tbl, warehouse_sync.affected(tbl)::text))
  FROM unnest(ARRAY['customers', 'items', 'settings', 'goodsreceived', 'goodsreceived_trl', 'grn_images', 'grn_lock',
                    'user_profiles', 'users_customers_new', 'grn_rates', 'item_storage_prices', 'standard_rate_tiers',
                    'item_price_history', 'grn_replacements', 'held_items', 'lot_rate', 'reload', 'money']
              || pg_temp.sc381_dropped()) tbl;

-- existing_ids(): returns '{}' for every one of the 8 dropped entities even when given a REAL existing row id,
-- and still returns matching ids for kept table entities.
SELECT pg_temp.sf_assert(warehouse_sync.existing_ids(e, ARRAY[rid]) = '{}'::text[],
  format('1.3: existing_ids(%L, [%s]) must return empty array for dropped entity, got %s', e, rid, warehouse_sync.existing_ids(e, ARRAY[rid])::text))
  FROM (VALUES
    ('dispatch', :'disp_2'), ('dispatch_trl', :'dt_2'), ('dispatch_images', :'disp_img_1'),
    ('invoice', :'inv_2'), ('invoice_trl', :'inv_line_2'), ('payments', :'pay_2'),
    ('orders', :'ord_1'), ('order_items', :'oi_1')
  ) dropped(e, rid);
SELECT pg_temp.sf_assert(warehouse_sync.existing_ids(e, ARRAY[rid]) = ARRAY[rid],
  format('1.3: existing_ids(%L, [%s]) must still find kept table row, got %s', e, rid, warehouse_sync.existing_ids(e, ARRAY[rid])::text))
  FROM (VALUES
    ('customers', :'north'), ('items', :'pepper'), ('goodsreceived', :'grn_g1'),
    ('goodsreceived_trl', :'lot_g1a'), ('grn_images', :'grn_img_1'), ('user_profiles', :'sf_admin_profile')
  ) kept(e, rid);

-- Restore record_payments setting for any suite that runs afterwards.
SELECT pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.set_record_payments(%L::boolean)', :'orig_record_payments'::boolean)) IS NOT NULL AS restored_rp \gset
SELECT pg_temp.sc381_pull_all('end');

\echo 'WH-381 sync feed scope cut (format 8, Section 1) checks passed.'

-- Migration 68: the dispatch and invoice read figures (external review 2026-10-13, I6-I11).
--
-- The fixture is the review's own (evidence integrity.focused.sql): receipt W2G1 holds lots A and B
-- of 10 bags x 5 kg, dispatch W2DA takes 10 + 10 and invoice 90101 bills both lines at duration 1.5,
-- charge 10, tax 5 %, labour 2. Per line: storage round(10 x 10 x 1.5) = 150, labour 2 x 10 = 20,
-- base 170, tax 8.50, line 178.50; the header the save code stores is ceil(340 + ceil(17)) = 357.
-- Added: receipts W2G2 and W2G3 (one lot of 20 bags each) dispatched together as W2DB and invoiced
-- separately as 90102 and 90103 (357 each: equal totals, so a SUM(DISTINCT total) would give 357,
-- not 714); and a ONE_TIME receipt W2G4 (10 bags, dispatch W2DC) invoiced as 104 at charge 4,
-- labour 2, tax 5 %: base 40 (no duration, no labour), tax 2, line 42, header 42.
--
--   I6  get_dispatch_details(W2DA): invoices_summary total_invoices 1, total_amount 357 (was 714: the
--       invoice summed once per line); statistics.total_invoice_amount 357 (was 30: charge x duration).
--       W2DB: 714 and 714.
--   I7  get_all_dispatch_items: limit 1 / offset 0 gives 1 item (was 2), offset 1 another item (was 0).
--   I8  staff get the rows they are counted (was items [] with total 2); customers stay refused.
--   I9  get_invoices_list total_qty of 90101 is 20 billed bags (was 10: SUM(DISTINCT lot qty)).
--   I10 get_customer_invoice_summary line_items: quantity 10, rate 10, labour_amount 20, tax_percent 5,
--       tax_amount 8.5, line_total 178.5 (were 1.5, 6.67, 3, 50, 5, 18); total_quantity 20 (was 3.0);
--       the lines add up to the header (357; ONE_TIME 42).
--   I11 invoice numbers longer than four digits are not cut: 2026-90101 (was 2026-9010) in the invoice
--       history and the activity detail; 104 is still 0104. get_grn_invoices (dormant, it cannot run:
--       it reads a table that does not exist) and the get_invoices_list search get the same expression.
--
-- Each answer is read as the role under test and compared after RESET ROLE.
-- Runs ONLY in migrations.sh's fresh, network-disabled database. All fixture rows roll back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.dirf_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'dispatch and invoice read figures: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.dirf_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.dirf_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- One field of every element of an array, in the returned order.
CREATE FUNCTION pg_temp.dirf_col(arr jsonb, value_key text) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(x->>value_key ORDER BY ord), '{}')
  FROM jsonb_array_elements(arr) WITH ORDINALITY AS t(x, ord) $$;
-- The element of an array whose key has that value, NULL when absent.
CREATE FUNCTION pg_temp.dirf_row(arr jsonb, key_name text, key_value text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT x FROM jsonb_array_elements(arr) AS t(x) WHERE x->>key_name = key_value $$;
-- The error text when the statement raises 42501, else 'answered'.
CREATE FUNCTION pg_temp.dirf_refusal(statement text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN EXECUTE statement; RETURN 'answered';
EXCEPTION WHEN insufficient_privilege THEN RETURN SQLERRM;
END $$;
-- The keys of an object, sorted bytewise, as one text.
CREATE FUNCTION pg_temp.dirf_keys(o jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(k, ',' ORDER BY k COLLATE "C") FROM jsonb_object_keys(o) AS t(k) $$;

-- ---------------------------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------------------------
INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888886801', 'Read Figures Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888886802', 'Read Figures Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888886803', 'Read Figures Juniper Reader', 'customer', true, 'approved');
SELECT id AS admin_profile FROM public.user_profiles WHERE mobile = '919888886801' \gset
SELECT pg_temp.dirf_login('9888886801') AS admin_claims \gset
SELECT pg_temp.dirf_login('9888886802') AS staff_claims \gset
SELECT pg_temp.dirf_login('9888886803') AS juniper_claims \gset
INSERT INTO public.customers(name, mobile) VALUES ('Read Figures Juniper Cold', '9888886811') RETURNING id AS juniper \gset
INSERT INTO public.items(name, packaging) VALUES ('Read Figures Potatoes', 'Bag') RETURNING id AS potatoes \gset
INSERT INTO public.users_customers_new(user_profile_id, customer_id, active)
 SELECT id, :'juniper'::uuid, true FROM public.user_profiles WHERE mobile = '919888886803';

SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.dirf_assert(public.save_grn(p_gr_no => 'W2G1', p_date => '2026-04-01T12:00:00Z', p_customer_id => :'juniper'::uuid,
  p_customer_name => 'Read Figures Juniper Cold', p_pricing_mode => 'MONTHLY', p_idempotency_key => 'read-figures-g1',
  p_items => jsonb_build_array(
    jsonb_build_object('item_id', :'potatoes', 'item_name', 'Read Figures Potatoes', 'qty', 10, 'weight', 5, 'package_mark', 'A'),
    jsonb_build_object('item_id', :'potatoes', 'item_name', 'Read Figures Potatoes', 'qty', 10, 'weight', 5, 'package_mark', 'B')))->>'success' = 'true',
  'fixture receipt W2G1');
SELECT pg_temp.dirf_assert(public.save_grn(p_gr_no => 'W2G' || n, p_date => '2026-04-02T12:00:00Z', p_customer_id => :'juniper'::uuid,
  p_customer_name => 'Read Figures Juniper Cold', p_pricing_mode => 'MONTHLY', p_idempotency_key => 'read-figures-g' || n,
  p_items => jsonb_build_array(
    jsonb_build_object('item_id', :'potatoes', 'item_name', 'Read Figures Potatoes', 'qty', 20, 'weight', 5, 'package_mark', 'M' || n)))->>'success' = 'true',
  'fixture receipt W2G' || n)
FROM generate_series(2, 3) AS n;
SELECT pg_temp.dirf_assert(public.save_grn(p_gr_no => 'W2G4', p_date => '2026-04-03T12:00:00Z', p_customer_id => :'juniper'::uuid,
  p_customer_name => 'Read Figures Juniper Cold', p_pricing_mode => 'ONE_TIME', p_idempotency_key => 'read-figures-g4',
  p_items => jsonb_build_array(
    jsonb_build_object('item_id', :'potatoes', 'item_name', 'Read Figures Potatoes', 'qty', 10, 'weight', 5, 'package_mark', 'O')))->>'success' = 'true',
  'fixture receipt W2G4');
SELECT id AS g1 FROM public.goodsreceived WHERE gr_no = 'W2G1' \gset
SELECT id AS g2 FROM public.goodsreceived WHERE gr_no = 'W2G2' \gset
SELECT id AS g3 FROM public.goodsreceived WHERE gr_no = 'W2G3' \gset
SELECT id AS g4 FROM public.goodsreceived WHERE gr_no = 'W2G4' \gset
SELECT id AS la FROM public.goodsreceived_trl WHERE gr_id = :'g1' AND package_mark = 'A' \gset
SELECT id AS lb FROM public.goodsreceived_trl WHERE gr_id = :'g1' AND package_mark = 'B' \gset
SELECT id AS l2 FROM public.goodsreceived_trl WHERE gr_id = :'g2' \gset
SELECT id AS l3 FROM public.goodsreceived_trl WHERE gr_id = :'g3' \gset
SELECT id AS l4 FROM public.goodsreceived_trl WHERE gr_id = :'g4' \gset
SELECT pg_temp.dirf_assert(public.create_dispatch_with_stock_check(jsonb_build_object('disp_no', d.no, 'disp_date', d.day,
    'customer_id', :'juniper', 'customer_name', 'Read Figures Juniper Cold',
    'supervisor_id', :'admin_profile', 'supervisor_name', 'Read Figures Administrator'),
  d.lines, 0, 'read-figures-' || d.no)->>'success' = 'true', 'fixture dispatch ' || d.no)
FROM (VALUES
  ('W2DA', '2026-05-02', ARRAY[jsonb_build_object('gr_trl_id', :'la', 'disp_qty', 10), jsonb_build_object('gr_trl_id', :'lb', 'disp_qty', 10)]),
  ('W2DB', '2026-05-03', ARRAY[jsonb_build_object('gr_trl_id', :'l2', 'disp_qty', 20), jsonb_build_object('gr_trl_id', :'l3', 'disp_qty', 20)]),
  ('W2DC', '2026-05-04', ARRAY[jsonb_build_object('gr_trl_id', :'l4', 'disp_qty', 10)])
) AS d(no, day, lines);
SELECT id AS da FROM public.dispatch WHERE disp_no = 'W2DA' \gset
SELECT id AS db FROM public.dispatch WHERE disp_no = 'W2DB' \gset
SELECT id AS dta FROM public.dispatch_trl WHERE disp_id = :'da' AND gr_trl_id = :'la' \gset
SELECT id AS dtb FROM public.dispatch_trl WHERE disp_id = :'da' AND gr_trl_id = :'lb' \gset
SELECT id AS dt2 FROM public.dispatch_trl WHERE gr_trl_id = :'l2' \gset
SELECT id AS dt3 FROM public.dispatch_trl WHERE gr_trl_id = :'l3' \gset
SELECT id AS dt4 FROM public.dispatch_trl WHERE gr_trl_id = :'l4' \gset
-- The invoices, as integrity.focused.sql saves 90101.
SELECT pg_temp.dirf_assert(public.save_invoice(NULL::uuid, jsonb_build_object('inv_no', v.no, 'inv_fin_year', 2026,
    'customer_id', :'juniper', 'customer_name', 'Read Figures Juniper Cold', 'inv_date', v.day, 'total', 0, 'tax_amount', 0,
    'labour', 0, 'discount', 0, 'duration_mode', 'legacy', 'gr_id', v.grn, 'gr_no', v.gr_no), v.lines)->>'success' = 'true',
  'fixture invoice ' || v.no)
FROM (VALUES
  (90101, '2026-05-02', :'g1'::uuid, 'W2G1', ARRAY[
     jsonb_build_object('disp_trl_id', :'dta', 'grn_item_id', :'la', 'duration', 1.5, 'charge', 10, 'tax', 5, 'labour_rate', 2),
     jsonb_build_object('disp_trl_id', :'dtb', 'grn_item_id', :'lb', 'duration', 1.5, 'charge', 10, 'tax', 5, 'labour_rate', 2)]),
  (90102, '2026-05-03', :'g2'::uuid, 'W2G2', ARRAY[
     jsonb_build_object('disp_trl_id', :'dt2', 'grn_item_id', :'l2', 'duration', 1.5, 'charge', 10, 'tax', 5, 'labour_rate', 2)]),
  (90103, '2026-05-03', :'g3'::uuid, 'W2G3', ARRAY[
     jsonb_build_object('disp_trl_id', :'dt3', 'grn_item_id', :'l3', 'duration', 1.5, 'charge', 10, 'tax', 5, 'labour_rate', 2)]),
  (104, '2026-05-04', :'g4'::uuid, 'W2G4', ARRAY[
     jsonb_build_object('disp_trl_id', :'dt4', 'grn_item_id', :'l4', 'duration', 1.5, 'charge', 4, 'tax', 5, 'labour_rate', 2)])
) AS v(no, day, grn, gr_no, lines);
RESET ROLE;
SELECT pg_temp.dirf_assert((SELECT string_agg(inv_no || ':' || total, ' ' ORDER BY inv_no) FROM public.invoice
    WHERE customer_id = :'juniper'::uuid) = '104:42.00 90101:357.00 90102:357.00 90103:357.00',
  'fixture: the stored totals are 42, 357, 357, 357');

-- ---------------------------------------------------------------------------
-- The answers
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.get_dispatch_details(:'da'::uuid)::text AS details_a \gset
SELECT public.get_dispatch_details(:'db'::uuid)::text AS details_b \gset
SELECT public.get_all_dispatch_items(p_filters => '{"disp_no": "W2DA"}', p_limit => 1, p_offset => 0)::text AS admin_page1 \gset
SELECT public.get_all_dispatch_items(p_filters => '{"disp_no": "W2DA"}', p_limit => 1, p_offset => 1)::text AS admin_page2 \gset
SELECT public.get_all_dispatch_items(p_filters => '{"disp_no": "W2D"}', p_sort_by => 'date', p_sort_order => 'desc', p_limit => 2, p_offset => 0)::text AS admin_sorted1 \gset
SELECT public.get_all_dispatch_items(p_filters => '{"disp_no": "W2D"}', p_sort_by => 'date', p_sort_order => 'desc', p_limit => 2, p_offset => 2)::text AS admin_sorted2 \gset
SELECT public.get_invoices_list(p_customer_id => :'juniper'::uuid)::text AS invoice_list \gset
SELECT public.get_invoices_list(p_customer_id => :'juniper'::uuid, p_search => '2026-90101')::text AS invoice_search \gset
SELECT public.get_customer_invoice_summary(:'juniper'::uuid, '2026-04-01', '2026-06-01', 2026)::text AS summary \gset
SELECT public.get_customer_activity_detail(:'juniper'::uuid, '2026-04-01', '2026-06-01')::text AS activity \gset
RESET ROLE;

SELECT set_config('request.jwt.claims', :'staff_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.dirf_assert(warehouse_security.active_role() = 'staff', 'actual staff role');
SELECT public.get_all_dispatch_items(p_filters => '{"disp_no": "W2DA"}', p_limit => 20, p_offset => 0)::text AS staff_items \gset
RESET ROLE;

-- get_all_dispatch_items is a warehouse-role function (migration 45): a customer is refused by the guard,
-- before and after this migration, so its customer branch is not reachable from the app.
SELECT set_config('request.jwt.claims', :'juniper_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.dirf_assert(warehouse_security.active_role() = 'customer', 'actual customer role');
SELECT pg_temp.dirf_refusal('SELECT public.get_all_dispatch_items(p_limit => 20, p_offset => 0)') AS juniper_items \gset
RESET ROLE;

-- get_grn_invoices is granted to no app role (dormant); read as the owner.
SELECT public.get_grn_invoices(:'g1'::uuid)::text AS grn_invoices \gset

-- ---------------------------------------------------------------------------
-- I6 get_dispatch_details
-- ---------------------------------------------------------------------------
SELECT pg_temp.dirf_assert((:'details_a'::jsonb#>>'{data,dispatch,invoices_summary,total_invoices}')::int = 1
  AND (:'details_a'::jsonb#>>'{data,dispatch,invoices_summary,total_amount}')::numeric = 357
  AND :'details_a'::jsonb#>'{data,dispatch,invoices_summary,invoice_numbers}' = '[90101]'::jsonb,
  'I6: W2DA has one invoice of 357 (90101): ' || (:'details_a'::jsonb#>'{data,dispatch,invoices_summary}')::text);
SELECT pg_temp.dirf_assert((:'details_a'::jsonb#>>'{data,dispatch,statistics,total_invoice_amount}')::numeric = 357
  AND (:'details_a'::jsonb#>>'{data,dispatch,statistics,total_invoiced_items}')::int = 2
  AND (:'details_a'::jsonb#>>'{data,dispatch,statistics,total_dispatched_qty}')::int = 20,
  'I6: W2DA statistics: the invoiced amount of its lines is 357: ' || (:'details_a'::jsonb#>'{data,dispatch,statistics}')::text);
-- Two invoices with the same total: both count.
SELECT pg_temp.dirf_assert((:'details_b'::jsonb#>>'{data,dispatch,invoices_summary,total_invoices}')::int = 2
  AND (:'details_b'::jsonb#>>'{data,dispatch,invoices_summary,total_amount}')::numeric = 714
  AND :'details_b'::jsonb#>'{data,dispatch,invoices_summary,invoice_numbers}' = '[90102, 90103]'::jsonb
  AND (:'details_b'::jsonb#>>'{data,dispatch,statistics,total_invoice_amount}')::numeric = 714,
  'I6: W2DB has two invoices of 357, 714 in all: ' || (:'details_b'::jsonb#>'{data,dispatch,invoices_summary}')::text
    || ' ' || (:'details_b'::jsonb#>'{data,dispatch,statistics}')::text);
-- The keys of both objects are what they were.
SELECT pg_temp.dirf_assert(pg_temp.dirf_keys(:'details_a'::jsonb#>'{data,dispatch,invoices_summary}') = 'invoice_numbers,total_amount,total_invoices'
  AND pg_temp.dirf_keys(:'details_a'::jsonb#>'{data,dispatch,statistics}')
      = 'avg_duration,avg_no_of_days,total_dispatched_qty,total_invoice_amount,total_invoiced_items,total_items,unique_grns',
  'I6: the keys of invoices_summary and statistics are unchanged');

-- ---------------------------------------------------------------------------
-- I7, I8 get_all_dispatch_items
-- ---------------------------------------------------------------------------
SELECT pg_temp.dirf_assert(jsonb_array_length(:'admin_page1'::jsonb#>'{data,items}') = 1
  AND (:'admin_page1'::jsonb#>>'{data,pagination,total}')::int = 2,
  'I7: limit 1 gives one row of two: ' || (:'admin_page1'::jsonb#>'{data,pagination}')::text
    || ' items ' || jsonb_array_length(:'admin_page1'::jsonb#>'{data,items}'));
SELECT pg_temp.dirf_assert(jsonb_array_length(:'admin_page2'::jsonb#>'{data,items}') = 1
  AND (:'admin_page2'::jsonb#>>'{data,items,0,id}') IS DISTINCT FROM (:'admin_page1'::jsonb#>>'{data,items,0,id}')
  AND ARRAY[(:'admin_page1'::jsonb#>>'{data,items,0,id}'), (:'admin_page2'::jsonb#>>'{data,items,0,id}')] <@ ARRAY[:'dta', :'dtb'],
  'I7: offset 1 gives the other row: ' || (:'admin_page2'::jsonb#>'{data,items}')::text);
-- Pages follow the sort: date descending puts W2DC (05-04), W2DB (05-03, two lines) and W2DA (05-02, two lines).
SELECT pg_temp.dirf_assert(pg_temp.dirf_col(:'admin_sorted1'::jsonb#>'{data,items}', 'disp_no') = ARRAY['W2DC', 'W2DB']
  AND pg_temp.dirf_col(:'admin_sorted2'::jsonb#>'{data,items}', 'disp_no') = ARRAY['W2DB', 'W2DA']
  AND (:'admin_sorted1'::jsonb#>>'{data,pagination,total}')::int = 5,
  'I7: pages of two by date descending: ' || pg_temp.dirf_col(:'admin_sorted1'::jsonb#>'{data,items}', 'disp_no')::text
    || ' then ' || pg_temp.dirf_col(:'admin_sorted2'::jsonb#>'{data,items}', 'disp_no')::text);
SELECT pg_temp.dirf_assert(jsonb_array_length(:'staff_items'::jsonb#>'{data,items}') = 2
  AND (:'staff_items'::jsonb#>>'{data,pagination,total}')::int = 2
  AND (:'staff_items'::jsonb#>>'{data,aggregations,total_dispatch_qty}')::int = 20,
  'I8: staff get the two rows they are counted: ' || left(:'staff_items', 300));
SELECT pg_temp.dirf_assert(:'juniper_items' = 'Staff access required',
  'I8: a customer is still refused by the guard: ' || :'juniper_items');

-- ---------------------------------------------------------------------------
-- I9 mv_invoice_list / get_invoices_list (no manual refresh: the triggers keep it current)
-- ---------------------------------------------------------------------------
SELECT pg_temp.dirf_assert((pg_temp.dirf_row(:'invoice_list'::jsonb->'data', 'invoice_number', '90101')->>'total_qty')::numeric = 20
  AND (pg_temp.dirf_row(:'invoice_list'::jsonb->'data', 'invoice_number', '90102')->>'total_qty')::numeric = 20
  AND (pg_temp.dirf_row(:'invoice_list'::jsonb->'data', 'invoice_number', '104')->>'total_qty')::numeric = 10,
  'I9: total_qty is the billed bags (90101: 20): ' || left(:'invoice_list', 300));
SELECT pg_temp.dirf_assert((SELECT relispopulated FROM pg_class WHERE oid = 'public.mv_invoice_list'::regclass)
  AND (SELECT count(*) FROM pg_index WHERE indrelid = 'public.mv_invoice_list'::regclass) = 7
  AND (SELECT indisunique FROM pg_index WHERE indexrelid = 'public.idx_mv_invoice_list_pk'::regclass)
  AND NOT has_table_privilege('authenticated', 'public.mv_invoice_list', 'SELECT')
  AND NOT has_table_privilege('anon', 'public.mv_invoice_list', 'SELECT')
  AND has_table_privilege('service_role', 'public.mv_invoice_list', 'SELECT'),
  'I9: mv_invoice_list is populated, has its seven indexes (one unique) and its grants');
SELECT pg_temp.dirf_assert(pg_temp.dirf_col(:'invoice_search'::jsonb->'data', 'invoice_number') = ARRAY['90101'],
  'I11: searching 2026-90101 finds 90101: ' || left(:'invoice_search', 300));

-- ---------------------------------------------------------------------------
-- I10, I11 get_customer_invoice_summary
-- ---------------------------------------------------------------------------
SELECT pg_temp.dirf_row(:'summary'::jsonb#>'{data,invoices}', 'invoice_id', i.id::text)::text AS inv90101
FROM public.invoice i WHERE i.inv_no = 90101 AND i.inv_fin_year = 2026 \gset
SELECT pg_temp.dirf_row(:'summary'::jsonb#>'{data,invoices}', 'invoice_id', i.id::text)::text AS inv104
FROM public.invoice i WHERE i.inv_no = 104 AND i.inv_fin_year = 2026 \gset
SELECT pg_temp.dirf_assert(:'inv90101'::jsonb->>'invoice_number' = '2026-90101'
  AND :'inv104'::jsonb->>'invoice_number' = '2026-0104',
  'I11: invoice numbers are not cut and short ones keep four digits: ' || (:'inv90101'::jsonb->>'invoice_number')
    || ' ' || (:'inv104'::jsonb->>'invoice_number'));
SELECT pg_temp.dirf_assert((SELECT bool_and((x->>'quantity')::numeric = 10 AND (x->>'rate')::numeric = 10
      AND (x->>'labour_amount')::numeric = 20 AND (x->>'tax_percent')::numeric = 5
      AND (x->>'tax_amount')::numeric = 8.5 AND (x->>'line_total')::numeric = 178.5) AND count(*) = 2
    FROM jsonb_array_elements(:'inv90101'::jsonb->'line_items') AS t(x)),
  'I10: each line of 90101 is 10 bags at 10, labour 20, tax 5 % = 8.50, 178.50: ' || (:'inv90101'::jsonb->'line_items')::text);
SELECT pg_temp.dirf_assert((:'inv90101'::jsonb->>'total_quantity')::numeric = 20
  AND (SELECT sum((x->>'line_total')::numeric) FROM jsonb_array_elements(:'inv90101'::jsonb->'line_items') AS t(x))
      = (:'inv90101'::jsonb->>'total')::numeric
  AND (:'inv90101'::jsonb->>'total')::numeric = 357,
  'I10: 90101 holds 20 bags and its lines add up to its total 357: ' || (:'inv90101'::jsonb->>'total_quantity'));
SELECT pg_temp.dirf_assert((SELECT bool_and((x->>'quantity')::numeric = 10 AND (x->>'rate')::numeric = 4
      AND (x->>'labour_amount')::numeric = 0 AND (x->>'tax_amount')::numeric = 2 AND (x->>'line_total')::numeric = 42) AND count(*) = 1
    FROM jsonb_array_elements(:'inv104'::jsonb->'line_items') AS t(x))
  AND (:'inv104'::jsonb->>'total')::numeric = 42,
  'I10: the ONE_TIME line is 10 bags at 4, no labour, tax 2, 42 = the header: ' || (:'inv104'::jsonb->'line_items')::text);
-- Keys and row count unchanged: one row per invoice, the line keys as before.
SELECT pg_temp.dirf_assert(jsonb_array_length(:'summary'::jsonb#>'{data,invoices}') = 4
  AND (:'summary'::jsonb#>>'{data,summary,total_amount}')::numeric = 1113
  AND (SELECT bool_and(pg_temp.dirf_keys(x) = 'charge,grn_item_ref,item_id,item_name,labour_amount,labour_rate,line_total,no_of_days,packaging,quantity,rate,tax_amount,tax_percent')
       FROM jsonb_array_elements(:'inv90101'::jsonb->'line_items') AS t(x)),
  'I10: four invoices, 1113 in all, the line keys unchanged');

-- ---------------------------------------------------------------------------
-- I11 get_customer_activity_detail and get_grn_invoices
-- ---------------------------------------------------------------------------
SELECT pg_temp.dirf_assert(pg_temp.dirf_col(:'activity'::jsonb#>'{data,recent_invoices}', 'invoice_number')
    @> ARRAY['2026-90101', '2026-90102', '2026-90103', '2026-0104'],
  'I11: the recent invoices show full numbers: ' || pg_temp.dirf_col(:'activity'::jsonb#>'{data,recent_invoices}', 'invoice_number')::text);
-- get_grn_invoices cannot answer (it reads a table user_customers that no migration creates; it is
-- granted to no app role): its text is checked instead, with the same expression as the two reports.
SELECT pg_temp.dirf_assert(:'grn_invoices'::jsonb->>'error' LIKE '%relation "user_customers" does not exist%',
  'get_grn_invoices still fails as before (dormant): ' || left(:'grn_invoices', 200));
SELECT pg_temp.dirf_assert(position('LPAD(inv.inv_no::text, GREATEST(4, LENGTH(inv.inv_no::text)), ''0'')' IN pg_get_functiondef(p.oid)) > 0
  AND position('LPAD(inv.inv_no::text, 4, ''0'')' IN pg_get_functiondef(p.oid)) = 0,
  'I11: get_grn_invoices pads to at least four digits without cutting')
FROM pg_proc p WHERE p.oid = 'public.get_grn_invoices(uuid)'::regprocedure;
SELECT pg_temp.dirf_assert(position('lpad(m.inv_no::text, 4, ''0'')' IN pg_get_functiondef(p.oid)) = 0,
  'I11: get_invoices_list compares the search with the uncut number')
FROM pg_proc p WHERE p.oid = 'public.get_invoices_list(integer,integer,uuid,integer,text,text,text,text,integer,integer,text,timestamp with time zone,timestamp with time zone,uuid[])'::regprocedure;

-- ---------------------------------------------------------------------------
-- The patched functions keep SECURITY DEFINER, their settings and grants
-- ---------------------------------------------------------------------------
SELECT pg_temp.dirf_assert(p.prosecdef AND p.proconfig IS NOT NULL
    AND pg_get_functiondef(p.oid) ~ ('BEGIN\s+PERFORM warehouse_security\.authorize_rpc\(''' || p.proname || ''','),
  'SECURITY DEFINER, settings and the guard first in ' || p.proname)
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
  AND p.proname IN ('get_dispatch_details', 'get_all_dispatch_items', 'get_customer_invoice_summary', 'get_customer_activity_detail', 'get_invoices_list');
SELECT pg_temp.dirf_assert(has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE'),
  'grants of ' || p.proname)
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
  AND p.proname IN ('get_dispatch_details', 'get_all_dispatch_items', 'get_customer_invoice_summary', 'get_customer_activity_detail', 'get_invoices_list');
SELECT pg_temp.dirf_assert(NOT has_function_privilege('authenticated', 'public.get_grn_invoices(uuid)', 'EXECUTE'),
  'get_grn_invoices stays ungranted');

ROLLBACK;

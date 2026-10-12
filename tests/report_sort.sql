-- Report sort (migration 52): the item-wise stock list sorts and totals at the server, and the
-- three all-customers lists order by the number, not by its text.
--
-- Fixture, so that right and wrong orders differ (text order would put 9 above 100 above 10):
--   item          stock  received  receipts   customer         stock  received*  dispatched*
--   Almond           10        10         1   Aspen Traders       10         10          100
--   Barley          100       100         2   Birch Foods        100        100            9
--   Cumin Seed        9         9         1   Cedar Mart           9          9           10
--   Dill Seed        10        10         3   Dogwood Stores      10         10            -
--   Fennel           30       120         1   Elm Agro            30          -            -
--   (* in the last seven days. "Outbound" lots, received 30 days ago and dispatched in full,
--    give the dispatched totals without leaving stock; Fennel was received 30 and dispatched
--    20 days ago, so its received quantity differs from its stock.)
-- Runs ONLY in migrations.sh's fresh, network-disabled database. All fixture rows roll back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.rs_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'report sort: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.rs_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.rs_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- One field of every element of a list, in the order the function returned them, without the
-- fixture prefix. Elements of other tests' rows (there are none in a fresh database) are left out.
CREATE FUNCTION pg_temp.rs_column(list jsonb, name_key text, value_key text) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(replace(x->>value_key, 'Sort Report ', '') ORDER BY ord), '{}')
  FROM jsonb_array_elements(list) WITH ORDINALITY AS t(x, ord) WHERE x->>name_key LIKE 'Sort Report %' $$;
CREATE FUNCTION pg_temp.rs_items(result jsonb) RETURNS text[] LANGUAGE sql AS $$
  SELECT pg_temp.rs_column(result#>'{data,items}', 'item_name', 'item_name') $$;
CREATE FUNCTION pg_temp.rs_customers(list jsonb) RETURNS text[] LANGUAGE sql AS $$
  SELECT pg_temp.rs_column(list, 'customer_name', 'customer_name') $$;
-- The whole item list (all customers) in one page, sorted as asked.
CREATE FUNCTION pg_temp.rs_sorted(sort_by text, sort_order text) RETURNS text[] LANGUAGE sql AS $$
  SELECT pg_temp.rs_items(public.get_item_wise_stock_list(p_limit => 100, p_sort_by => sort_by, p_sort_order => sort_order)) $$;
-- One page of the list sorted by stock, largest first.
CREATE FUNCTION pg_temp.rs_page(page_size integer, skip integer) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.get_item_wise_stock_list(p_limit => page_size, p_offset => skip, p_sort_by => 'total_stock', p_sort_order => 'desc') $$;
-- True when the guard refuses the statement: a raw 42501, or, from the three all-customers
-- lists whose catch-all handler turns it into an answer, success = false carrying one of the
-- guard's messages. An answer or any other error is false.
CREATE FUNCTION pg_temp.rs_refused(statement text) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  EXECUTE statement INTO answer;
  RETURN answer->>'success' = 'false'
    AND COALESCE(answer->>'error', '') ~ '(Staff access required|Customer access denied|Active account required)';
EXCEPTION WHEN insufficient_privilege THEN RETURN true;
  WHEN OTHERS THEN RETURN false;
END $$;
CREATE FUNCTION pg_temp.rs_summary(total_stock integer, total_qty integer, item_count integer) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('total_stock', total_stock, 'total_qty', total_qty, 'item_count', item_count) $$;

-- ---------------------------------------------------------------------------
-- The function itself: one function, same guard, same grants
-- ---------------------------------------------------------------------------
SELECT pg_temp.rs_assert((SELECT count(*) = 1 AND min(pg_get_function_identity_arguments(oid)) =
    'p_customer_id uuid, p_search_query text, p_limit integer, p_offset integer, p_sort_by text, p_sort_order text'
  FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'get_item_wise_stock_list'),
  'exactly one get_item_wise_stock_list, with the two new parameters last');
SELECT pg_temp.rs_assert(has_function_privilege('authenticated', p.oid, 'execute') AND has_function_privilege('service_role', p.oid, 'execute')
    AND NOT has_function_privilege('anon', p.oid, 'execute')
    AND NOT EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0)
    AND p.prosecdef AND pg_get_functiondef(p.oid) LIKE '%SET search_path TO ''pg_catalog'', ''public'', ''extensions'', ''utils'', ''pg_temp''%',
  'signed-in callers only, definer rights and the search path of the other guarded RPCs')
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'get_item_wise_stock_list';
SELECT pg_temp.rs_assert(pg_get_functiondef(p.oid) ~
    'BEGIN\s+PERFORM warehouse_security\.authorize_rpc\(''get_item_wise_stock_list'',jsonb_build_object\(''p_customer_id'',p_customer_id\)\);',
  'the guard is still the first statement, with the customer id')
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'get_item_wise_stock_list';
SELECT pg_temp.rs_assert(pg_get_functiondef(p.oid) !~* '\mexecute\M' AND pg_get_functiondef(p.oid) !~* '\mformat\s*\(',
  'the list builds no SQL text')
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'get_item_wise_stock_list';
-- The three patched lists are still single, guarded and no longer order by text.
SELECT pg_temp.rs_assert(count(*) = 3 AND bool_and(pg_get_functiondef(p.oid) ~ ('PERFORM warehouse_security\.authorize_rpc\(''' || p.proname || ''',')
    AND pg_get_functiondef(p.oid) !~ 'ORDER BY customer_data->>''total_(qty|stock)'' DESC'
    AND pg_get_functiondef(p.oid) LIKE '%::numeric END DESC NULLS LAST, customer_data->>''customer_name''%'),
  'the three all-customers lists are guarded and order by the number')
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
  AND p.proname IN ('get_all_dispatch_activity', 'get_all_grn_activity', 'get_all_stock_summary');

-- ---------------------------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------------------------
INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888888521', 'Sort Report Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888888522', 'Sort Report Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888888523', 'Sort Report Customer', 'customer', true, 'approved');
SELECT id AS admin_profile FROM public.user_profiles WHERE mobile = '919888888521' \gset
SELECT pg_temp.rs_login('9888888521') AS admin_claims \gset
SELECT pg_temp.rs_login('9888888522') AS staff_claims \gset
SELECT pg_temp.rs_login('9888888523') AS customer_claims \gset
-- Dogwood is created before Aspen: equal totals must come back by name, not in creation order.
INSERT INTO public.customers(name, mobile) VALUES ('Sort Report Dogwood Stores', '9888888534') RETURNING id AS dogwood \gset
INSERT INTO public.customers(name, mobile) VALUES ('Sort Report Aspen Traders', '9888888531') RETURNING id AS aspen \gset
INSERT INTO public.customers(name, mobile) VALUES ('Sort Report Birch Foods', '9888888532') RETURNING id AS birch \gset
INSERT INTO public.customers(name, mobile) VALUES ('Sort Report Cedar Mart', '9888888533') RETURNING id AS cedar \gset
INSERT INTO public.customers(name, mobile) VALUES ('Sort Report Elm Agro', '9888888535') RETURNING id AS elm \gset
INSERT INTO public.items(name, packaging) VALUES ('Sort Report Dill Seed', 'Bag') RETURNING id AS dill \gset
INSERT INTO public.items(name, packaging) VALUES ('Sort Report Almond', 'Bag') RETURNING id AS almond \gset
INSERT INTO public.items(name, packaging) VALUES ('Sort Report Barley', 'Bag') RETURNING id AS barley \gset
INSERT INTO public.items(name, packaging) VALUES ('Sort Report Cumin Seed', 'Bag') RETURNING id AS cumin \gset
INSERT INTO public.items(name, packaging) VALUES ('Sort Report Fennel', 'Bag') RETURNING id AS fennel \gset
INSERT INTO public.items(name, packaging) VALUES ('Sort Report Outbound', 'Bag') RETURNING id AS outbound \gset
-- The customer login is assigned to Aspen only.
INSERT INTO public.users_customers_new(user_profile_id, customer_id, active)
 SELECT id, :'aspen'::uuid, true FROM public.user_profiles WHERE mobile = '919888888523';
-- A hostile sort value must not reach this table.
CREATE TEMP TABLE report_sort_canary (id integer);

SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rs_assert((public.get_item_wise_stock_list()#>>'{data,total_count}')::integer = 0
  AND public.get_item_wise_stock_list()#>'{data,summary}' = pg_temp.rs_summary(0, 0, 0),
  'a database without stock lists nothing and totals nothing: ' || public.get_item_wise_stock_list()::text);
SELECT pg_temp.rs_assert(public.save_grn(p_gr_no => r.gr_no, p_date => ((CURRENT_DATE - r.days_ago)::text || 'T12:00:00Z')::timestamptz,
  p_customer_id => r.customer, p_customer_name => 'Sort Report ' || r.customer_name, p_idempotency_key => 'report-sort-' || r.gr_no,
  p_items => jsonb_build_array(jsonb_build_object('item_id', r.item, 'item_name', 'Sort Report ' || r.item_name, 'packaging', 'Bag',
    'qty', r.qty, 'weight', 5)))->>'success' = 'true', 'fixture receipt ' || r.gr_no)
FROM (VALUES
  ('RSR1', 30, :'elm'::uuid, 'Elm Agro', :'fennel'::uuid, 'Fennel', 120),
  ('RSR2', 30, :'aspen'::uuid, 'Aspen Traders', :'outbound'::uuid, 'Outbound', 100),
  ('RSR3', 30, :'birch'::uuid, 'Birch Foods', :'outbound'::uuid, 'Outbound', 9),
  ('RSR4', 30, :'cedar'::uuid, 'Cedar Mart', :'outbound'::uuid, 'Outbound', 10),
  ('RSR5', 2, :'aspen'::uuid, 'Aspen Traders', :'almond'::uuid, 'Almond', 10),
  ('RSR6', 3, :'birch'::uuid, 'Birch Foods', :'barley'::uuid, 'Barley', 60),
  ('RSR7', 2, :'birch'::uuid, 'Birch Foods', :'barley'::uuid, 'Barley', 40),
  ('RSR8', 2, :'cedar'::uuid, 'Cedar Mart', :'cumin'::uuid, 'Cumin Seed', 9),
  ('RSR9', 3, :'dogwood'::uuid, 'Dogwood Stores', :'dill'::uuid, 'Dill Seed', 4),
  ('RSR10', 2, :'dogwood'::uuid, 'Dogwood Stores', :'dill'::uuid, 'Dill Seed', 3),
  ('RSR11', 1, :'dogwood'::uuid, 'Dogwood Stores', :'dill'::uuid, 'Dill Seed', 3)
) AS r(gr_no, days_ago, customer, customer_name, item, item_name, qty);
SELECT pg_temp.rs_assert(public.create_dispatch_with_stock_check(jsonb_build_object('disp_no', d.disp_no,
    'disp_date', (CURRENT_DATE - d.days_ago)::text || 'T12:00:00Z', 'customer_id', g.customer_id, 'customer_name', g.customer_name,
    'supervisor_id', :'admin_profile', 'supervisor_name', 'Sort Report Administrator'),
  ARRAY[jsonb_build_object('gr_trl_id', t.id, 'disp_qty', d.qty)], 0, 'report-sort-' || d.disp_no)->>'success' = 'true',
  'fixture dispatch ' || d.disp_no)
FROM (VALUES ('RSD1', 'RSR1', 90, 20), ('RSD2', 'RSR2', 100, 1), ('RSD3', 'RSR3', 9, 1), ('RSD4', 'RSR4', 10, 2)) AS d(disp_no, gr_no, qty, days_ago)
JOIN public.goodsreceived g ON g.gr_no = d.gr_no JOIN public.goodsreceived_trl t ON t.gr_id = g.id;

-- ---------------------------------------------------------------------------
-- Item-wise stock list, as the administrator
-- ---------------------------------------------------------------------------
-- Every sort, both directions. Almond and Dill Seed have equal stock and equal received
-- quantity; Almond, Cumin Seed and Fennel have one receipt each: equal rows come by name.
SELECT pg_temp.rs_assert(pg_temp.rs_sorted(c.sort_by, c.sort_order) = c.expected,
  format('sorted by %s %s: %s', c.sort_by, c.sort_order, pg_temp.rs_sorted(c.sort_by, c.sort_order)))
FROM (VALUES
  ('item_name', 'asc', ARRAY['Almond', 'Barley', 'Cumin Seed', 'Dill Seed', 'Fennel']),
  ('item_name', 'desc', ARRAY['Fennel', 'Dill Seed', 'Cumin Seed', 'Barley', 'Almond']),
  ('total_stock', 'asc', ARRAY['Cumin Seed', 'Almond', 'Dill Seed', 'Fennel', 'Barley']),
  ('total_stock', 'desc', ARRAY['Barley', 'Fennel', 'Almond', 'Dill Seed', 'Cumin Seed']),
  ('total_qty', 'asc', ARRAY['Cumin Seed', 'Almond', 'Dill Seed', 'Barley', 'Fennel']),
  ('total_qty', 'desc', ARRAY['Fennel', 'Barley', 'Almond', 'Dill Seed', 'Cumin Seed']),
  ('grn_count', 'asc', ARRAY['Almond', 'Cumin Seed', 'Fennel', 'Barley', 'Dill Seed']),
  ('grn_count', 'desc', ARRAY['Dill Seed', 'Barley', 'Almond', 'Cumin Seed', 'Fennel']),
  -- Upper case is the same value.
  ('TOTAL_STOCK', 'DESC', ARRAY['Barley', 'Fennel', 'Almond', 'Dill Seed', 'Cumin Seed']),
  ('Grn_Count', 'Desc', ARRAY['Dill Seed', 'Barley', 'Almond', 'Cumin Seed', 'Fennel']),
  -- Anything else is the default of that parameter: item_name, asc.
  ('weight', 'asc', ARRAY['Almond', 'Barley', 'Cumin Seed', 'Dill Seed', 'Fennel']),
  ('', '', ARRAY['Almond', 'Barley', 'Cumin Seed', 'Dill Seed', 'Fennel']),
  (NULL, NULL, ARRAY['Almond', 'Barley', 'Cumin Seed', 'Dill Seed', 'Fennel']),
  ('item_name', 'sideways', ARRAY['Almond', 'Barley', 'Cumin Seed', 'Dill Seed', 'Fennel']),
  ('weight', 'sideways', ARRAY['Almond', 'Barley', 'Cumin Seed', 'Dill Seed', 'Fennel']),
  ('total_stock', 'sideways', ARRAY['Cumin Seed', 'Almond', 'Dill Seed', 'Fennel', 'Barley']),
  ('weight', 'desc', ARRAY['Fennel', 'Dill Seed', 'Cumin Seed', 'Barley', 'Almond']),
  -- Text that would be SQL if it were pasted into a query selects nothing and is the default.
  ('item_name; drop table x', 'asc', ARRAY['Almond', 'Barley', 'Cumin Seed', 'Dill Seed', 'Fennel']),
  ('total_stock; DROP TABLE pg_temp.report_sort_canary; --', 'asc', ARRAY['Almond', 'Barley', 'Cumin Seed', 'Dill Seed', 'Fennel']),
  ('total_stock'' DESC; DROP TABLE report_sort_canary; --', 'asc', ARRAY['Almond', 'Barley', 'Cumin Seed', 'Dill Seed', 'Fennel']),
  ('total_stock', 'desc; DROP TABLE report_sort_canary; --', ARRAY['Cumin Seed', 'Almond', 'Dill Seed', 'Fennel', 'Barley']),
  ('total_stock', 'desc, (SELECT pg_sleep(600))', ARRAY['Cumin Seed', 'Almond', 'Dill Seed', 'Fennel', 'Barley'])
) AS c(sort_by, sort_order, expected);
SELECT pg_temp.rs_assert(to_regclass('pg_temp.report_sort_canary') IS NOT NULL, 'the canary table survived the hostile sort values');
-- The rows carry the numbers the order was made from.
SELECT pg_temp.rs_assert(pg_temp.rs_column(pg_temp.rs_page(100, 0)#>'{data,items}', 'item_name', 'total_stock') = ARRAY['100', '30', '10', '10', '9']
  AND pg_temp.rs_column(pg_temp.rs_page(100, 0)#>'{data,items}', 'item_name', 'total_qty') = ARRAY['100', '120', '10', '10', '9']
  AND pg_temp.rs_column(pg_temp.rs_page(100, 0)#>'{data,items}', 'item_name', 'grn_count') = ARRAY['2', '1', '1', '3', '1'],
  'stock, received quantity and receipt count of each row: ' || (pg_temp.rs_page(100, 0)#>'{data,items}')::text);

-- A call with the four old parameters, by name or with none at all, answers in the old order.
SELECT pg_temp.rs_assert(pg_temp.rs_items(public.get_item_wise_stock_list(p_customer_id => NULL, p_search_query => NULL, p_limit => 50, p_offset => 0))
    = ARRAY['Almond', 'Barley', 'Cumin Seed', 'Dill Seed', 'Fennel']
  AND pg_temp.rs_items(public.get_item_wise_stock_list()) = ARRAY['Almond', 'Barley', 'Cumin Seed', 'Dill Seed', 'Fennel']
  AND pg_temp.rs_items(public.get_item_wise_stock_list(NULL, NULL, 2, 1)) = ARRAY['Barley', 'Cumin Seed'],
  'the four old parameters still work and keep item_name ascending');
-- Every old key is still there; summary is the only new one.
SELECT pg_temp.rs_assert((SELECT array_agg(k ORDER BY k) = ARRAY['data', 'success'] FROM jsonb_object_keys(r) k)
  AND (SELECT array_agg(k ORDER BY k) = ARRAY['items', 'summary', 'total_count'] FROM jsonb_object_keys(r->'data') k)
  AND (SELECT array_agg(k ORDER BY k) = ARRAY['grn_count', 'item_id', 'item_name', 'packaging', 'total_qty', 'total_stock'] FROM jsonb_object_keys(r#>'{data,items,0}') k)
  AND (SELECT array_agg(k ORDER BY k) = ARRAY['item_count', 'total_qty', 'total_stock'] FROM jsonb_object_keys(r#>'{data,summary}') k)
  AND r->>'success' = 'true' AND r#>>'{data,items,0,item_id}' = :'almond' AND r#>>'{data,items,0,packaging}' = 'Bag'
  AND jsonb_typeof(r#>'{data,summary,total_stock}') = 'number' AND jsonb_typeof(r#>'{data,total_count}') = 'number',
  'response keys: ' || r::text)
FROM (SELECT public.get_item_wise_stock_list() AS r) answer;

-- Pages of two, largest stock first: every item exactly once, none on a second page. The
-- summary and the count are those of all five items on every page, the empty one included.
SELECT pg_temp.rs_assert(pg_temp.rs_items(pg_temp.rs_page(2, 0)) = ARRAY['Barley', 'Fennel']
  AND pg_temp.rs_items(pg_temp.rs_page(2, 2)) = ARRAY['Almond', 'Dill Seed']
  AND pg_temp.rs_items(pg_temp.rs_page(2, 4)) = ARRAY['Cumin Seed']
  AND pg_temp.rs_items(pg_temp.rs_page(2, 6)) = '{}',
  'pages of two by stock: ' || pg_temp.rs_items(pg_temp.rs_page(2, 0))::text || pg_temp.rs_items(pg_temp.rs_page(2, 2))::text
    || pg_temp.rs_items(pg_temp.rs_page(2, 4))::text || pg_temp.rs_items(pg_temp.rs_page(2, 6))::text);
SELECT pg_temp.rs_assert(bool_and(pg_temp.rs_page(2, skip)#>'{data,summary}' = pg_temp.rs_summary(159, 249, 5)
    AND (pg_temp.rs_page(2, skip)#>>'{data,total_count}')::integer = 5),
  'the summary and the count cover all five items on every page: ' || string_agg((pg_temp.rs_page(2, skip)->'data'->'summary')::text, ' '))
FROM unnest(ARRAY[0, 2, 4, 6]) AS skip;
-- Pages of three split the two items of equal stock; pages of one walk the whole order.
SELECT pg_temp.rs_assert(pg_temp.rs_items(pg_temp.rs_page(3, 0)) = ARRAY['Barley', 'Fennel', 'Almond']
  AND pg_temp.rs_items(pg_temp.rs_page(3, 3)) = ARRAY['Dill Seed', 'Cumin Seed'],
  'equal stock on either side of a page break: ' || pg_temp.rs_items(pg_temp.rs_page(3, 0))::text || pg_temp.rs_items(pg_temp.rs_page(3, 3))::text);
SELECT pg_temp.rs_assert(array_agg((pg_temp.rs_items(pg_temp.rs_page(1, skip)))[1] ORDER BY skip) = ARRAY['Barley', 'Fennel', 'Almond', 'Dill Seed', 'Cumin Seed']
    AND bool_and(cardinality(pg_temp.rs_items(pg_temp.rs_page(1, skip))) = 1),
  'pages of one by stock: ' || array_agg((pg_temp.rs_items(pg_temp.rs_page(1, skip)))[1] ORDER BY skip)::text)
FROM generate_series(0, 4) AS skip;
SELECT pg_temp.rs_assert(array_agg((pg_temp.rs_items(public.get_item_wise_stock_list(p_limit => 1, p_offset => skip, p_sort_by => 'grn_count', p_sort_order => 'asc')))[1] ORDER BY skip)
    = ARRAY['Almond', 'Cumin Seed', 'Fennel', 'Barley', 'Dill Seed'], 'pages of one by receipt count, three equal rows')
FROM generate_series(0, 4) AS skip;

-- The summary follows the search and the customer, not the page.
SELECT pg_temp.rs_assert(pg_temp.rs_items(r) = ARRAY['Dill Seed', 'Cumin Seed'] AND r#>'{data,summary}' = pg_temp.rs_summary(19, 19, 2)
  AND (r#>>'{data,total_count}')::integer = 2, 'search "seed": ' || r::text)
FROM (SELECT public.get_item_wise_stock_list(p_search_query => 'seed', p_sort_by => 'total_stock', p_sort_order => 'desc') AS r) answer;
SELECT pg_temp.rs_assert(pg_temp.rs_items(r) = ARRAY['Cumin Seed'] AND r#>'{data,summary}' = pg_temp.rs_summary(19, 19, 2)
  AND (r#>>'{data,total_count}')::integer = 2, 'search "seed", second page of one: ' || r::text)
FROM (SELECT public.get_item_wise_stock_list(p_search_query => 'seed', p_limit => 1, p_offset => 1, p_sort_by => 'total_stock', p_sort_order => 'desc') AS r) answer;
SELECT pg_temp.rs_assert(pg_temp.rs_items(r) = ARRAY['Barley'] AND r#>'{data,summary}' = pg_temp.rs_summary(100, 100, 1)
  AND (r#>>'{data,total_count}')::integer = 1 AND r#>>'{data,items,0,grn_count}' = '2', 'one customer, Birch: ' || r::text)
FROM (SELECT public.get_item_wise_stock_list(p_customer_id => :'birch'::uuid, p_sort_by => 'total_qty', p_sort_order => 'desc') AS r) answer;
SELECT pg_temp.rs_assert(pg_temp.rs_items(r) = ARRAY['Fennel'] AND r#>'{data,summary}' = pg_temp.rs_summary(30, 120, 1),
  'one customer, Elm: stock 30 of 120 received: ' || r::text)
FROM (SELECT public.get_item_wise_stock_list(p_customer_id => :'elm'::uuid) AS r) answer;
SELECT pg_temp.rs_assert(pg_temp.rs_items(r) = ARRAY['Dill Seed'] AND r#>'{data,summary}' = pg_temp.rs_summary(10, 10, 1)
  AND r#>>'{data,items,0,grn_count}' = '3', 'customer and search together, Dogwood "seed": ' || r::text)
FROM (SELECT public.get_item_wise_stock_list(p_customer_id => :'dogwood'::uuid, p_search_query => 'seed') AS r) answer;
SELECT pg_temp.rs_assert(r->>'success' = 'true' AND r#>'{data,items}' = '[]'::jsonb AND r#>'{data,summary}' = pg_temp.rs_summary(0, 0, 0)
  AND (r#>>'{data,total_count}')::integer = 0, 'a filter that matches nothing totals nothing: ' || r::text)
FROM (SELECT public.get_item_wise_stock_list(p_customer_id => :'birch'::uuid, p_search_query => 'seed', p_sort_by => 'total_stock', p_sort_order => 'desc') AS r) answer;

-- ---------------------------------------------------------------------------
-- The three all-customers lists, as the administrator
-- ---------------------------------------------------------------------------
-- Text order would be 9, 30, 100, 10, 10 (stock), 9, 100, 10, 10 (received) and 9, 100, 10 (dispatched).
SELECT pg_temp.rs_assert(pg_temp.rs_customers(r->'customers') = ARRAY['Birch Foods', 'Elm Agro', 'Aspen Traders', 'Dogwood Stores', 'Cedar Mart']
  AND pg_temp.rs_column(r->'customers', 'customer_name', 'total_stock') = ARRAY['100', '30', '10', '10', '9'],
  'stock summary, largest stock first: ' || (r->'customers')::text)
FROM (SELECT public.get_all_stock_summary() AS r) answer;
SELECT pg_temp.rs_assert(pg_temp.rs_customers(r->'by_customer') = ARRAY['Birch Foods', 'Aspen Traders', 'Dogwood Stores', 'Cedar Mart']
  AND pg_temp.rs_column(r->'by_customer', 'customer_name', 'total_qty') = ARRAY['100', '10', '10', '9'],
  'receipt activity of the last seven days, largest quantity first: ' || (r->'by_customer')::text)
FROM (SELECT public.get_all_grn_activity(CURRENT_DATE - 7, CURRENT_DATE) AS r) answer;
SELECT pg_temp.rs_assert(pg_temp.rs_customers(r->'by_customer') = ARRAY['Aspen Traders', 'Cedar Mart', 'Birch Foods']
  AND pg_temp.rs_column(r->'by_customer', 'customer_name', 'total_qty') = ARRAY['100', '10', '9'],
  'dispatch activity of the last seven days, largest quantity first: ' || (r->'by_customer')::text)
FROM (SELECT public.get_all_dispatch_activity(CURRENT_DATE - 7, CURRENT_DATE) AS r) answer;
-- Forty days: other totals, other text traps (text order would start with 19, and with 90 and 9).
SELECT pg_temp.rs_assert(pg_temp.rs_customers(r->'by_customer') = ARRAY['Elm Agro', 'Aspen Traders', 'Birch Foods', 'Cedar Mart', 'Dogwood Stores']
  AND pg_temp.rs_column(r->'by_customer', 'customer_name', 'total_qty') = ARRAY['120', '110', '109', '19', '10'],
  'receipt activity of forty days: ' || (r->'by_customer')::text)
FROM (SELECT public.get_all_grn_activity(CURRENT_DATE - 40, CURRENT_DATE) AS r) answer;
SELECT pg_temp.rs_assert(pg_temp.rs_customers(r->'by_customer') = ARRAY['Aspen Traders', 'Elm Agro', 'Cedar Mart', 'Birch Foods']
  AND pg_temp.rs_column(r->'by_customer', 'customer_name', 'total_qty') = ARRAY['100', '90', '10', '9'],
  'dispatch activity of forty days: ' || (r->'by_customer')::text)
FROM (SELECT public.get_all_dispatch_activity(CURRENT_DATE - 40, CURRENT_DATE) AS r) answer;
-- Nothing else in the three answers moved.
SELECT pg_temp.rs_assert((SELECT array_agg(k ORDER BY k) = ARRAY['customers', 'success', 'summary'] FROM jsonb_object_keys(public.get_all_stock_summary()) k)
  AND (SELECT array_agg(k ORDER BY k) = ARRAY['customer_id', 'customer_name', 'grn_count', 'item_count', 'latest_date', 'oldest_date', 'total_stock', 'total_weight']
       FROM jsonb_object_keys(public.get_all_stock_summary()#>'{customers,0}') k)
  AND (public.get_all_stock_summary()#>>'{summary,total_quantity}')::integer = 159
  AND (SELECT array_agg(k ORDER BY k) = ARRAY['by_customer', 'by_date', 'success', 'summary'] FROM jsonb_object_keys(public.get_all_grn_activity(CURRENT_DATE - 7, CURRENT_DATE)) k)
  AND (SELECT array_agg(k ORDER BY k) = ARRAY['customer_id', 'customer_name', 'grn_count', 'latest_grn', 'total_qty', 'total_weight']
       FROM jsonb_object_keys(public.get_all_grn_activity(CURRENT_DATE - 7, CURRENT_DATE)#>'{by_customer,0}') k)
  AND (public.get_all_grn_activity(CURRENT_DATE - 7, CURRENT_DATE)#>>'{summary,total_quantity}')::integer = 129
  AND (SELECT array_agg(k ORDER BY k) = ARRAY['by_customer', 'by_date', 'success', 'summary'] FROM jsonb_object_keys(public.get_all_dispatch_activity(CURRENT_DATE - 7, CURRENT_DATE)) k)
  AND (SELECT array_agg(k ORDER BY k) = ARRAY['customer_id', 'customer_name', 'dispatch_count', 'latest_dispatch', 'total_qty']
       FROM jsonb_object_keys(public.get_all_dispatch_activity(CURRENT_DATE - 7, CURRENT_DATE)#>'{by_customer,0}') k)
  AND (public.get_all_dispatch_activity(CURRENT_DATE - 7, CURRENT_DATE)#>>'{summary,total_quantity}')::integer = 119,
  'keys and totals of the three all-customers answers');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Authorization is what it was
-- ---------------------------------------------------------------------------
-- Staff: every list, for all customers and for one.
SELECT set_config('request.jwt.claims', :'staff_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rs_assert(warehouse_security.active_role() = 'staff', 'actual staff role');
SELECT pg_temp.rs_assert(pg_temp.rs_sorted('total_stock', 'desc') = ARRAY['Barley', 'Fennel', 'Almond', 'Dill Seed', 'Cumin Seed']
  AND pg_temp.rs_page(2, 2)#>'{data,summary}' = pg_temp.rs_summary(159, 249, 5)
  AND pg_temp.rs_items(public.get_item_wise_stock_list()) = ARRAY['Almond', 'Barley', 'Cumin Seed', 'Dill Seed', 'Fennel']
  AND pg_temp.rs_items(public.get_item_wise_stock_list(p_customer_id => :'birch'::uuid, p_sort_by => 'total_stock', p_sort_order => 'desc')) = ARRAY['Barley'],
  'staff run the item list, sorted, for all customers and for one: ' || pg_temp.rs_sorted('total_stock', 'desc')::text);
SELECT pg_temp.rs_assert(pg_temp.rs_customers(public.get_all_stock_summary()->'customers') = ARRAY['Birch Foods', 'Elm Agro', 'Aspen Traders', 'Dogwood Stores', 'Cedar Mart']
  AND pg_temp.rs_customers(public.get_all_grn_activity(CURRENT_DATE - 7, CURRENT_DATE)->'by_customer') = ARRAY['Birch Foods', 'Aspen Traders', 'Dogwood Stores', 'Cedar Mart']
  AND pg_temp.rs_customers(public.get_all_dispatch_activity(CURRENT_DATE - 7, CURRENT_DATE)->'by_customer') = ARRAY['Aspen Traders', 'Cedar Mart', 'Birch Foods'],
  'staff run the three all-customers lists, in the same order');
RESET ROLE;

-- A customer account: its own customer, sorted and totalled; nothing else.
SELECT set_config('request.jwt.claims', :'customer_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rs_assert(warehouse_security.active_role() = 'customer', 'actual customer role');
SELECT pg_temp.rs_assert(r->>'success' = 'true' AND pg_temp.rs_items(r) = ARRAY['Almond'] AND r#>'{data,summary}' = pg_temp.rs_summary(10, 10, 1)
  AND (r#>>'{data,total_count}')::integer = 1, 'customer account, own customer, sorted: ' || r::text)
FROM (SELECT public.get_item_wise_stock_list(p_customer_id => :'aspen'::uuid, p_sort_by => 'total_stock', p_sort_order => 'desc') AS r) answer;
SELECT pg_temp.rs_assert(pg_temp.rs_items(public.get_item_wise_stock_list(p_customer_id => :'aspen'::uuid, p_search_query => NULL, p_limit => 50, p_offset => 0)) = ARRAY['Almond']
  AND pg_temp.rs_items(public.get_item_wise_stock_list(:'aspen'::uuid)) = ARRAY['Almond'], 'customer account, own customer, old parameters');
-- The ids are the fixture's: read as this customer, public.customers holds only its own row.
SELECT pg_temp.rs_assert((SELECT count(*) = 0 FROM public.customers WHERE id = :'birch'), 'the customer account cannot read the other customer row');
SELECT pg_temp.rs_assert(pg_temp.rs_refused(statement), 'a customer account was answered: ' || statement)
FROM (VALUES
  (format('SELECT public.get_item_wise_stock_list(p_customer_id => %L::uuid)', :'birch')),
  (format('SELECT public.get_item_wise_stock_list(p_customer_id => %L::uuid, p_sort_by => ''total_stock'', p_sort_order => ''desc'')', :'birch')),
  (format('SELECT public.get_item_wise_stock_list(%L::uuid, NULL, 50, 0)', :'elm')),
  ('SELECT public.get_item_wise_stock_list()'),
  ('SELECT public.get_item_wise_stock_list(p_sort_by => ''total_stock'', p_sort_order => ''desc'')'),
  ('SELECT public.get_item_wise_stock_list(p_search_query => ''seed'', p_limit => 100)'),
  ('SELECT public.get_all_stock_summary()'),
  ('SELECT public.get_all_grn_activity(CURRENT_DATE - 7, CURRENT_DATE)'),
  ('SELECT public.get_all_dispatch_activity(CURRENT_DATE - 7, CURRENT_DATE)')
) AS s(statement);
-- The refusal helper can tell an answer from a refusal.
SELECT pg_temp.rs_assert(NOT pg_temp.rs_refused(format('SELECT public.get_item_wise_stock_list(p_customer_id => %L::uuid)', :'aspen')),
  'the refusal check itself answers false for an allowed call');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Equal name, equal numbers: the item id decides, in either direction
-- ---------------------------------------------------------------------------
-- Two items whose lines carry the same name and quantity. The first created has the larger id,
-- so an order by creation, by line or by chance is not the order by id.
INSERT INTO public.customers(name, mobile) VALUES ('Sort Report Fir Depot', '9888888536') RETURNING id AS fir \gset
INSERT INTO public.items(id, name, packaging) VALUES ('ffffffff-0000-4000-8000-00000000a001', 'Sort Report Twin One', 'Bag');
INSERT INTO public.items(id, name, packaging) VALUES ('00000000-0000-4000-8000-00000000a002', 'Sort Report Twin Two', 'Bag');
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rs_assert(public.save_grn(p_gr_no => 'RSR12', p_date => now() - interval '1 day', p_customer_id => :'fir'::uuid,
  p_customer_name => 'Sort Report Fir Depot', p_idempotency_key => 'report-sort-RSR12',
  p_items => jsonb_build_array(
    jsonb_build_object('item_id', 'ffffffff-0000-4000-8000-00000000a001', 'item_name', 'Sort Report Twin', 'packaging', 'Bag', 'qty', 7, 'weight', 5),
    jsonb_build_object('item_id', '00000000-0000-4000-8000-00000000a002', 'item_name', 'Sort Report Twin', 'packaging', 'Bag', 'qty', 7, 'weight', 5)))->>'success' = 'true',
  'fixture receipt RSR12');
SELECT pg_temp.rs_assert(pg_temp.rs_column(r#>'{data,items}', 'item_name', 'item_id') = ARRAY['00000000-0000-4000-8000-00000000a002', 'ffffffff-0000-4000-8000-00000000a001']
  AND pg_temp.rs_items(r) = ARRAY['Twin', 'Twin'] AND r#>'{data,summary}' = pg_temp.rs_summary(14, 14, 2),
  format('equal rows sorted by %s %s come by item id: %s', c.sort_by, c.sort_order, r#>'{data,items}'))
FROM (VALUES ('item_name', 'asc'), ('item_name', 'desc'), ('total_stock', 'asc'), ('total_stock', 'desc'),
             ('total_qty', 'desc'), ('grn_count', 'desc')) AS c(sort_by, sort_order)
CROSS JOIN LATERAL (SELECT public.get_item_wise_stock_list(p_customer_id => :'fir'::uuid, p_sort_by => c.sort_by, p_sort_order => c.sort_order) AS r) answer;
SELECT pg_temp.rs_assert(public.get_item_wise_stock_list(p_customer_id => :'fir'::uuid, p_limit => 1, p_offset => 0, p_sort_by => 'total_stock', p_sort_order => 'desc')
    #>>'{data,items,0,item_id}' = '00000000-0000-4000-8000-00000000a002'
  AND public.get_item_wise_stock_list(p_customer_id => :'fir'::uuid, p_limit => 1, p_offset => 1, p_sort_by => 'total_stock', p_sort_order => 'desc')
    #>>'{data,items,0,item_id}' = 'ffffffff-0000-4000-8000-00000000a001',
  'two equal rows on two pages of one: each exactly once');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- A total that is not a number comes last and raises nothing
-- ---------------------------------------------------------------------------
-- dispatch_trl.disp_qty may be NULL, and then the customer's total is a JSON null. Read as text
-- and sorted downwards it came first. (The two receipt totals are sums of NOT NULL columns.)
UPDATE public.dispatch_trl SET disp_qty = NULL WHERE disp_id = (SELECT id FROM public.dispatch WHERE disp_no = 'RSD2');
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rs_assert(pg_temp.rs_customers(r->'by_customer') = ARRAY['Cedar Mart', 'Birch Foods', 'Aspen Traders']
  AND r#>'{by_customer,2,total_qty}' = 'null'::jsonb AND r->>'success' = 'true',
  'a customer without a dispatched total comes last: ' || (r->'by_customer')::text)
FROM (SELECT public.get_all_dispatch_activity(CURRENT_DATE - 7, CURRENT_DATE) AS r) answer;
RESET ROLE;
-- The answers for "no customer to list" carry the same keys. A service-role call takes that
-- path today: it passes the guard, is not a warehouse role and has no assigned customers.
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);
SELECT pg_temp.rs_assert(r->>'success' = 'true' AND r#>'{data,items}' = '[]'::jsonb AND r#>'{data,summary}' = pg_temp.rs_summary(0, 0, 0)
  AND (r#>>'{data,total_count}')::integer = 0, 'the empty answer has a summary of zeros: ' || r::text)
FROM (SELECT public.get_item_wise_stock_list(p_sort_by => 'total_stock', p_sort_order => 'desc') AS r) answer;
ROLLBACK;
SELECT 'report sort: item list order, paging and summary, numeric order of the three customer lists, and unchanged authorization passed' AS result;

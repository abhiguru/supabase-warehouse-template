-- The customer dispatch activity report returns weights (migration 58).
--
-- get_customer_dispatch_activity listed each dispatch with its quantity but no weight; only the
-- summary carried total_weight. Since migration 58 every line of a dispatch carries weight (kg:
-- the dispatched quantity times the per-bag weight of the received line, goodsreceived_trl.weight,
-- 0 when that is null), every dispatch carries total_weight (the sum of its lines), and
-- summary.total_weight is the sum of the dispatches' total_weight.
--
--   receipt  customer  line             bags  kg per bag
--   DWG1     Quince    Cumin             100     25
--   DWG1     Quince    Fennel            100     50
--   DWG2     Quince    Fennel             40   NULL (set to null after the receipt: save_grn stores 0)
--   DWG3     Rowan     Fennel             60     40
--
--   dispatch  customer  day         lines (bags)                    kg
--   DWT1      Quince    10 Oct      Cumin 3, Fennel 5 (DWG1)        3*25 + 5*50 = 75 + 250 = 325
--   DWT2      Quince    11 Oct      Fennel 4 (DWG2, null weight)    0
--   DWT3      Quince    12 Oct      Fennel 2 (DWG1)                 2*50 = 100
--   DWT4      Quince    11 Oct      Fennel 1 (DWG1), DELETED        never listed, never counted
--   DWT5      Rowan     11 Oct      Fennel 7 (DWG3)                 7*40 = 280, another customer's
--   DWT6      Hazel     10 Oct      no lines at all                 0
-- 10..12 Oct for Quince: DWT3, DWT2, DWT1 and summary 425; 11..12: 100; 10..11: 325; 10..10: 325.
-- A wrong formula tells itself apart: the per-bag weight alone gives 75 for DWT1, the quantity
-- alone 8, the lot's weight 7500; counting the deleted or the other customer's dispatch gives
-- 475 or 705.
--
-- Each answer is read as the role under test and compared AFTER the role is dropped. The
-- dispatch RPC stores a dispatch at the start of its date in the session zone (UTC here,
-- asserted), which is the same India day.
-- Runs ONLY in migrations.sh's fresh, network-disabled database. All fixture rows roll back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.dwt_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'report dispatch weight: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.dwt_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.dwt_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- A dispatch of the fixture: lines is [{gr_no, item, qty}, ...]; each is taken from the received
-- line of that item on that receipt. Called as the administrator.
CREATE FUNCTION pg_temp.dwt_dispatch(p_no text, p_day text, p_customer uuid, p_customer_name text, p_supervisor text, p_lines jsonb) RETURNS void LANGUAGE plpgsql AS $$
DECLARE lines jsonb[];
BEGIN
  SELECT array_agg(jsonb_build_object('gr_trl_id', t.id, 'disp_qty', (e.l->>'qty')::int) ORDER BY e.ord) INTO lines
  FROM jsonb_array_elements(p_lines) WITH ORDINALITY AS e(l, ord)
  JOIN public.goodsreceived g ON g.gr_no = e.l->>'gr_no'
  JOIN public.goodsreceived_trl t ON t.gr_id = g.id AND t.item_name = e.l->>'item';
  PERFORM pg_temp.dwt_assert(COALESCE(cardinality(lines), 0) = jsonb_array_length(p_lines), 'fixture lines found for ' || p_no);
  PERFORM pg_temp.dwt_assert(public.create_dispatch_with_stock_check(jsonb_build_object('disp_no', p_no,
      'disp_date', p_day, 'customer_id', p_customer, 'customer_name', p_customer_name,
      'supervisor_id', p_supervisor, 'supervisor_name', 'Dispatch Weight Administrator'),
    lines, 0, 'report-dispatch-weight-' || p_no)->>'success' = 'true', 'fixture dispatch ' || p_no);
END $$;
-- One field of every dispatch of an answer, in the returned order.
CREATE FUNCTION pg_temp.dwt_column(answer jsonb, value_key text) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(x->>value_key ORDER BY ord), '{}')
  FROM jsonb_array_elements(answer->'dispatches') WITH ORDINALITY AS t(x, ord) $$;
-- The lines of one dispatch of an answer as "item=bags:kg", in the returned order. A dispatch
-- without lines (items is JSON null) gives an empty array; a line without weight gives NULL here,
-- which no comparison below accepts.
CREATE FUNCTION pg_temp.dwt_lines(answer jsonb, p_no text) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg((i->>'item_name') || '=' || (i->>'qty') || ':' || (i->>'weight') ORDER BY ord), '{}')
  FROM jsonb_array_elements(answer->'dispatches') AS t(x)
  CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(x->'items') = 'array' THEN x->'items' ELSE '[]'::jsonb END) WITH ORDINALITY AS l(i, ord)
  WHERE x->>'disp_no' = p_no $$;
-- The sum of the weight of the lines of one dispatch object (0 when it has none).
CREATE FUNCTION pg_temp.dwt_line_sum(dispatch jsonb) RETURNS numeric LANGUAGE sql AS $$
  SELECT COALESCE(sum((i->>'weight')::numeric), 0)
  FROM jsonb_array_elements(CASE WHEN jsonb_typeof(dispatch->'items') = 'array' THEN dispatch->'items' ELSE '[]'::jsonb END) AS l(i) $$;
-- The sum of total_weight over the dispatches of an answer.
CREATE FUNCTION pg_temp.dwt_dispatch_sum(answer jsonb) RETURNS numeric LANGUAGE sql AS $$
  SELECT COALESCE(sum((x->>'total_weight')::numeric), 0) FROM jsonb_array_elements(answer->'dispatches') AS t(x) $$;
-- The keys of an object, sorted bytewise, as one text.
CREATE FUNCTION pg_temp.dwt_keys(o jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(k, ',' ORDER BY k COLLATE "C") FROM jsonb_object_keys(o) AS t(k) $$;
-- 'Customer access denied' (the guard's message) when the statement is refused with 42501;
-- 'answered: ...' when it returns. Any other error stops the test.
CREATE FUNCTION pg_temp.dwt_refusal(statement text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  EXECUTE statement INTO answer;
  RETURN 'answered: ' || left(answer::text, 120);
EXCEPTION WHEN insufficient_privilege THEN RETURN SQLERRM;
END $$;

SELECT pg_temp.dwt_assert(current_setting('TimeZone') = 'UTC', 'the session time zone is UTC, so a dispatch stored at the start of its date is on that India day');

-- ---------------------------------------------------------------------------
-- The function: single, guarded, and otherwise as before
-- ---------------------------------------------------------------------------
SELECT pg_temp.dwt_assert(count(*) = 1, 'exactly one function named get_customer_dispatch_activity, in any schema')
FROM pg_proc p WHERE p.proname = 'get_customer_dispatch_activity';
SELECT pg_temp.dwt_assert(p.prosecdef AND pg_get_functiondef(p.oid) ~ 'BEGIN\s+PERFORM warehouse_security\.authorize_rpc\(''get_customer_dispatch_activity'',',
  'SECURITY DEFINER, and the guard comes first')
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'get_customer_dispatch_activity';
-- The search_path and the grants are the sibling's, as before the migration.
SELECT pg_temp.dwt_assert(p.proconfig IS NOT NULL AND p.proconfig::text LIKE '%search_path=%'
    AND p.proconfig IS NOT DISTINCT FROM (SELECT s.proconfig FROM pg_proc s WHERE s.oid = 'public.get_customer_stock_summary(uuid)'::regprocedure),
  'search_path is a fixed one, as its sibling get_customer_stock_summary: ' || COALESCE(p.proconfig::text, 'none'))
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'get_customer_dispatch_activity';
SELECT pg_temp.dwt_assert(has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
    AND p.proacl IS NOT DISTINCT FROM (SELECT s.proacl FROM pg_proc s WHERE s.oid = 'public.get_customer_stock_summary(uuid)'::regprocedure),
  'grants: authenticated may execute, anon may not, as its sibling get_customer_stock_summary: ' || COALESCE(p.proacl::text, 'none'))
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'get_customer_dispatch_activity';
-- Each new key is written once, the summary's own total is still written once, disp_id (migration
-- 57) and the India day cut (migration 56) are kept.
SELECT pg_temp.dwt_assert((length(pg_get_functiondef(p.oid)) - length(replace(pg_get_functiondef(p.oid), '''weight'', COALESCE(gt.weight::numeric * dt.disp_qty, 0)', ''))) / length('''weight'', COALESCE(gt.weight::numeric * dt.disp_qty, 0)') = 1
    AND (length(pg_get_functiondef(p.oid)) - length(replace(pg_get_functiondef(p.oid), '''total_weight'', (', ''))) / length('''total_weight'', (') = 1
    AND (length(pg_get_functiondef(p.oid)) - length(replace(pg_get_functiondef(p.oid), '''total_weight'', COALESCE(SUM(gt.weight::numeric * dt.disp_qty), 0)', ''))) / length('''total_weight'', COALESCE(SUM(gt.weight::numeric * dt.disp_qty), 0)') = 1,
  'the line weight, the dispatch total_weight and the summary total_weight are each written once')
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'get_customer_dispatch_activity';
SELECT pg_temp.dwt_assert((length(pg_get_functiondef(p.oid)) - length(replace(pg_get_functiondef(p.oid), '''disp_id'', d.id,', ''))) / length('''disp_id'', d.id,') = 1
    AND pg_get_functiondef(p.oid) LIKE '%d.disp_date >= warehouse_security.business_day_start(p_from_date)%'
    AND pg_get_functiondef(p.oid) LIKE '%''disp_date'', warehouse_security.business_date(d.disp_date),%',
  'disp_id of migration 57 and the India day cut of migration 56 are kept')
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'get_customer_dispatch_activity';

-- ---------------------------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------------------------
INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888889201', 'Dispatch Weight Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888889202', 'Dispatch Weight Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888889203', 'Dispatch Weight Customer', 'customer', true, 'approved');
SELECT id AS admin_profile FROM public.user_profiles WHERE mobile = '919888889201' \gset
SELECT pg_temp.dwt_login('9888889201') AS admin_claims \gset
SELECT pg_temp.dwt_login('9888889202') AS staff_claims \gset
SELECT pg_temp.dwt_login('9888889203') AS customer_claims \gset
INSERT INTO public.customers(name, mobile) VALUES ('Dispatch Weight Quince Cold', '9888889211') RETURNING id AS quince \gset
INSERT INTO public.customers(name, mobile) VALUES ('Dispatch Weight Rowan Agro', '9888889212') RETURNING id AS rowan \gset
INSERT INTO public.customers(name, mobile) VALUES ('Dispatch Weight Hazel Stores', '9888889213') RETURNING id AS hazel \gset
INSERT INTO public.items(name, packaging) VALUES ('Dispatch Weight Fennel', 'Bag') RETURNING id AS fennel \gset
INSERT INTO public.items(name, packaging) VALUES ('Dispatch Weight Cumin', 'Bag') RETURNING id AS cumin \gset
-- The customer login is assigned to Quince only.
INSERT INTO public.users_customers_new(user_profile_id, customer_id, active)
 SELECT id, :'quince'::uuid, true FROM public.user_profiles WHERE mobile = '919888889203';

SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.dwt_assert(public.save_grn(p_gr_no => r.gr_no, p_date => '2026-08-14T12:00:00Z'::timestamptz,
  p_customer_id => r.customer, p_customer_name => r.customer_name, p_idempotency_key => 'report-dispatch-weight-' || r.gr_no,
  p_items => r.lines)->>'success' = 'true', 'fixture receipt ' || r.gr_no)
FROM (VALUES
  ('DWG1', :'quince'::uuid, 'Dispatch Weight Quince Cold', jsonb_build_array(
     jsonb_build_object('item_id', :'cumin', 'item_name', 'Dispatch Weight Cumin', 'packaging', 'Bag', 'qty', 100, 'weight', 25),
     jsonb_build_object('item_id', :'fennel', 'item_name', 'Dispatch Weight Fennel', 'packaging', 'Bag', 'qty', 100, 'weight', 50))),
  ('DWG2', :'quince'::uuid, 'Dispatch Weight Quince Cold', jsonb_build_array(
     jsonb_build_object('item_id', :'fennel', 'item_name', 'Dispatch Weight Fennel', 'packaging', 'Bag', 'qty', 40, 'weight', 30))),
  ('DWG3', :'rowan'::uuid, 'Dispatch Weight Rowan Agro', jsonb_build_array(
     jsonb_build_object('item_id', :'fennel', 'item_name', 'Dispatch Weight Fennel', 'packaging', 'Bag', 'qty', 60, 'weight', 40)))
) AS r(gr_no, customer, customer_name, lines);
RESET ROLE;
-- save_grn stores a missing weight as 0, so the line without a per-bag weight is made as a
-- column that holds NULL (the column allows it).
UPDATE public.goodsreceived_trl t SET weight = NULL FROM public.goodsreceived g WHERE g.id = t.gr_id AND g.gr_no = 'DWG2';
SELECT pg_temp.dwt_assert((SELECT string_agg(g.gr_no || '/' || t.item_name || '=' || COALESCE(t.weight::text, 'NULL'), ' ' ORDER BY g.gr_no, t.item_name)
      FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id = t.gr_id WHERE g.gr_no LIKE 'DWG%')
    = 'DWG1/Dispatch Weight Cumin=25 DWG1/Dispatch Weight Fennel=50 DWG2/Dispatch Weight Fennel=NULL DWG3/Dispatch Weight Fennel=40',
  'fixture: the per-bag weights of the received lines, one of them NULL');

SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.dwt_dispatch('DWT1', '2026-10-10', :'quince'::uuid, 'Dispatch Weight Quince Cold', :'admin_profile',
  '[{"gr_no":"DWG1","item":"Dispatch Weight Cumin","qty":3},{"gr_no":"DWG1","item":"Dispatch Weight Fennel","qty":5}]');
SELECT pg_temp.dwt_dispatch('DWT2', '2026-10-11', :'quince'::uuid, 'Dispatch Weight Quince Cold', :'admin_profile',
  '[{"gr_no":"DWG2","item":"Dispatch Weight Fennel","qty":4}]');
SELECT pg_temp.dwt_dispatch('DWT3', '2026-10-12', :'quince'::uuid, 'Dispatch Weight Quince Cold', :'admin_profile',
  '[{"gr_no":"DWG1","item":"Dispatch Weight Fennel","qty":2}]');
SELECT pg_temp.dwt_dispatch('DWT4', '2026-10-11', :'quince'::uuid, 'Dispatch Weight Quince Cold', :'admin_profile',
  '[{"gr_no":"DWG1","item":"Dispatch Weight Fennel","qty":1}]');
SELECT pg_temp.dwt_dispatch('DWT5', '2026-10-11', :'rowan'::uuid, 'Dispatch Weight Rowan Agro', :'admin_profile',
  '[{"gr_no":"DWG3","item":"Dispatch Weight Fennel","qty":7}]');
RESET ROLE;
-- DWT4 is deleted, as the delete RPC leaves a dispatch: the report must not list it or count its weight.
UPDATE public.dispatch SET deleted_at = now() WHERE disp_no = 'DWT4';
-- DWT6 has no lines at all (no RPC makes one; the table allows it).
INSERT INTO public.dispatch(disp_no, disp_date, customer_id, customer_name, supervisor_name)
 VALUES ('DWT6', '2026-10-10T00:00:00Z', :'hazel'::uuid, 'Dispatch Weight Hazel Stores', 'Dispatch Weight Administrator');
SELECT pg_temp.dwt_assert((SELECT count(*) FROM public.dispatch WHERE disp_no LIKE 'DWT%') = 6
  AND (SELECT count(*) FROM public.dispatch WHERE disp_no LIKE 'DWT%' AND deleted_at IS NOT NULL) = 1
  AND (SELECT string_agg(disp_no || '@' || to_char(disp_date AT TIME ZONE 'Asia/Kolkata', 'MM-DD'), ' ' ORDER BY disp_no) FROM public.dispatch WHERE disp_no LIKE 'DWT%')
    = 'DWT1@10-10 DWT2@10-11 DWT3@10-12 DWT4@10-11 DWT5@10-11 DWT6@10-10'
  AND (SELECT count(*) FROM public.dispatch_trl dt JOIN public.dispatch d ON d.id = dt.disp_id WHERE d.disp_no = 'DWT6') = 0
  AND (SELECT string_agg(d.disp_no || '=' || dt.disp_qty, ' ' ORDER BY d.disp_no, dt.disp_qty) FROM public.dispatch_trl dt JOIN public.dispatch d ON d.id = dt.disp_id WHERE d.disp_no LIKE 'DWT%')
    = 'DWT1=3 DWT1=5 DWT2=4 DWT3=2 DWT4=1 DWT5=7',
  'fixture: six dispatches on the intended India days, one deleted, one without lines, with the intended bags');
-- What the table says, worked out apart from the function: the kilograms of the Quince dispatches
-- that are not deleted, and the same for each day range used below.
SELECT COALESCE(sum(dt.disp_qty * COALESCE(t.weight, 0)), 0) AS table_quince_all
FROM public.dispatch d JOIN public.dispatch_trl dt ON dt.disp_id = d.id JOIN public.goodsreceived_trl t ON t.id = dt.gr_trl_id
WHERE d.customer_id = :'quince'::uuid AND d.deleted_at IS NULL \gset
SELECT pg_temp.dwt_assert(:'table_quince_all' = '425', 'the table holds 425 kg for the Quince dispatches that are not deleted: ' || :'table_quince_all');

-- ---------------------------------------------------------------------------
-- The answers, each read as the role under test
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.get_customer_dispatch_activity(:'quince'::uuid, '2026-10-10', '2026-10-12')::text AS admin_quince \gset
RESET ROLE;

SELECT set_config('request.jwt.claims', :'staff_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.dwt_assert(warehouse_security.active_role() = 'staff', 'actual staff role');
SELECT public.get_customer_dispatch_activity(:'quince'::uuid, '2026-10-10', '2026-10-12')::text AS staff_quince \gset
SELECT public.get_customer_dispatch_activity(:'quince'::uuid, '2026-10-11', '2026-10-12')::text AS staff_quince_11_12 \gset
SELECT public.get_customer_dispatch_activity(:'quince'::uuid, '2026-10-10', '2026-10-11')::text AS staff_quince_10_11 \gset
SELECT public.get_customer_dispatch_activity(:'quince'::uuid, '2026-10-10', '2026-10-10')::text AS staff_quince_10_10 \gset
SELECT public.get_customer_dispatch_activity(:'quince'::uuid, '2026-09-01', '2026-09-30')::text AS staff_quince_none \gset
SELECT public.get_customer_dispatch_activity(:'rowan'::uuid, '2026-10-10', '2026-10-12')::text AS staff_rowan \gset
SELECT public.get_customer_dispatch_activity(:'hazel'::uuid, '2026-10-10', '2026-10-12')::text AS staff_hazel \gset
RESET ROLE;

SELECT set_config('request.jwt.claims', :'customer_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.dwt_assert(warehouse_security.active_role() = 'customer', 'actual customer role');
SELECT public.get_customer_dispatch_activity(:'quince'::uuid, '2026-10-10', '2026-10-12')::text AS customer_quince \gset
SELECT pg_temp.dwt_refusal(format('SELECT public.get_customer_dispatch_activity(%L::uuid, %L::date, %L::date)', :'rowan', '2026-10-10', '2026-10-12')) AS customer_rowan \gset
SELECT pg_temp.dwt_refusal(format('SELECT public.get_customer_dispatch_activity(%L::uuid, %L::date, %L::date)', :'quince', '2026-10-10', '2026-10-12')) AS customer_quince_check \gset
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Staff: the weight of each line, of each dispatch, and of the summary
-- ---------------------------------------------------------------------------
-- The dispatches are the three that count, newest day first, with their kilograms.
SELECT pg_temp.dwt_assert(pg_temp.dwt_column(:'staff_quince'::jsonb, 'disp_no') = ARRAY['DWT3', 'DWT2', 'DWT1']
  AND pg_temp.dwt_column(:'staff_quince'::jsonb, 'total_weight') = ARRAY['100', '0', '325']
  AND pg_temp.dwt_column(:'staff_quince'::jsonb, 'total_qty') = ARRAY['2', '4', '8'],
  'staff: Quince dispatches, their total_weight and their bags: ' || :'staff_quince');
-- The weight of each line is its bags times the per-bag weight of its received line (lines are in
-- item name order: Cumin before Fennel).
SELECT pg_temp.dwt_assert(pg_temp.dwt_lines(:'staff_quince'::jsonb, 'DWT1') = ARRAY['Dispatch Weight Cumin=3:75', 'Dispatch Weight Fennel=5:250']
  AND pg_temp.dwt_lines(:'staff_quince'::jsonb, 'DWT3') = ARRAY['Dispatch Weight Fennel=2:100'],
  'staff: the weight of each line is its bags times the per-bag weight (3*25, 5*50, 2*50): ' || :'staff_quince');
-- A received line without a per-bag weight weighs 0, a number and not a null.
SELECT pg_temp.dwt_assert(pg_temp.dwt_lines(:'staff_quince'::jsonb, 'DWT2') = ARRAY['Dispatch Weight Fennel=4:0']
  AND jsonb_typeof((:'staff_quince'::jsonb)#>'{dispatches,1,items,0,weight}') = 'number'
  AND jsonb_typeof((:'staff_quince'::jsonb)#>'{dispatches,1,total_weight}') = 'number',
  'staff: a line whose received line has no per-bag weight weighs 0: ' || :'staff_quince');
-- Every weight is a JSON number, and a dispatch's total is the sum of its lines' weights.
SELECT pg_temp.dwt_assert(count(*) = 3 AND bool_and(jsonb_typeof(x->'total_weight') = 'number')
    AND bool_and((SELECT bool_and(jsonb_typeof(i->'weight') = 'number') FROM jsonb_array_elements(x->'items') AS l(i)))
    AND bool_and((x->>'total_weight')::numeric = pg_temp.dwt_line_sum(x)),
  'staff: every weight is a number and each total_weight is the sum of its lines: ' || :'staff_quince')
FROM jsonb_array_elements((:'staff_quince'::jsonb)->'dispatches') AS t(x);
-- The summary is the sum of the dispatches' total_weight, and the table says the same.
SELECT pg_temp.dwt_assert((:'staff_quince'::jsonb)#>>'{summary,total_weight}' = '425'
  AND (:'staff_quince'::jsonb)#>>'{summary,total_weight}' = pg_temp.dwt_dispatch_sum(:'staff_quince'::jsonb)::text
  AND (:'staff_quince'::jsonb)#>>'{summary,total_weight}' = :'table_quince_all'
  AND (:'staff_quince'::jsonb)#>>'{summary,total_dispatches}' = '3' AND (:'staff_quince'::jsonb)#>>'{summary,total_quantity}' = '14'
  AND jsonb_typeof((:'staff_quince'::jsonb)#>'{summary,total_weight}') = 'number',
  'staff: summary.total_weight is 425, the sum of the dispatches'' total_weight and the table''s: ' || :'staff_quince');
-- The earlier keys and values are all still there, and the only new keys are weight and total_weight:
-- the exact key set of the answer, its summary, a dispatch and a line.
SELECT pg_temp.dwt_assert(pg_temp.dwt_keys(:'staff_quince'::jsonb) = 'dispatches,summary'
  AND pg_temp.dwt_keys((:'staff_quince'::jsonb)->'summary') = 'total_dispatches,total_quantity,total_weight'
  AND pg_temp.dwt_column(:'staff_quince'::jsonb, 'disp_date') = ARRAY['2026-10-12', '2026-10-11', '2026-10-10']
  AND pg_temp.dwt_column(:'staff_quince'::jsonb, 'supervisor_name') = ARRAY['Dispatch Weight Administrator', 'Dispatch Weight Administrator', 'Dispatch Weight Administrator'],
  'staff: the keys of the answer and of its summary, the days and the supervisors');
SELECT pg_temp.dwt_assert(count(*) = 4
    AND bool_and(pg_temp.dwt_keys(x) = 'disp_date,disp_id,disp_no,items,supervisor_name,total_qty,total_weight')
    AND bool_and(pg_temp.dwt_keys(i) = 'item_name,orig_qty,package_mark,qty,rack,source_grn,source_grn_id,weight')
    AND bool_and(x->>'disp_id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
  'staff: the keys of each dispatch and of each of its lines')
FROM jsonb_array_elements((:'staff_quince'::jsonb)->'dispatches') AS t(x)
CROSS JOIN LATERAL jsonb_array_elements(x->'items') AS l(i);
-- The deleted dispatch and the other customer's are not in the answer, in a number or a weight.
SELECT pg_temp.dwt_assert(position('DWT4' in :'staff_quince') = 0 AND position('DWT5' in :'staff_quince') = 0 AND position('DWT6' in :'staff_quince') = 0
  AND pg_temp.dwt_dispatch_sum(:'staff_quince'::jsonb) <> 475 AND pg_temp.dwt_dispatch_sum(:'staff_quince'::jsonb) <> 705,
  'staff: the Quince answer holds neither the deleted dispatch nor another customer''s: ' || :'staff_quince');
-- An administrator is answered the same.
SELECT pg_temp.dwt_assert(:'admin_quince'::jsonb = :'staff_quince'::jsonb, 'administrator and staff are answered alike: ' || :'admin_quince');

-- ---------------------------------------------------------------------------
-- Periods: a dispatch outside the period is outside the summary's weight
-- ---------------------------------------------------------------------------
-- 11..12 Oct leaves DWT1 (325 kg) out; 10..11 leaves DWT3 (100 kg) out; 10..10 holds DWT1 only; September holds nothing.
SELECT pg_temp.dwt_assert(pg_temp.dwt_column(:'staff_quince_11_12'::jsonb, 'disp_no') = ARRAY['DWT3', 'DWT2']
  AND pg_temp.dwt_column(:'staff_quince_11_12'::jsonb, 'total_weight') = ARRAY['100', '0']
  AND (:'staff_quince_11_12'::jsonb)#>>'{summary,total_weight}' = '100'
  AND (:'staff_quince_11_12'::jsonb)#>>'{summary,total_weight}' = pg_temp.dwt_dispatch_sum(:'staff_quince_11_12'::jsonb)::text
  AND (:'staff_quince_11_12'::jsonb)#>>'{summary,total_dispatches}' = '2',
  'staff: 11..12 Oct leaves out the 325 kg of DWT1: ' || :'staff_quince_11_12');
SELECT pg_temp.dwt_assert(pg_temp.dwt_column(:'staff_quince_10_11'::jsonb, 'disp_no') = ARRAY['DWT2', 'DWT1']
  AND pg_temp.dwt_column(:'staff_quince_10_11'::jsonb, 'total_weight') = ARRAY['0', '325']
  AND (:'staff_quince_10_11'::jsonb)#>>'{summary,total_weight}' = '325'
  AND (:'staff_quince_10_11'::jsonb)#>>'{summary,total_weight}' = pg_temp.dwt_dispatch_sum(:'staff_quince_10_11'::jsonb)::text
  AND (:'staff_quince_10_11'::jsonb)#>>'{summary,total_dispatches}' = '2',
  'staff: 10..11 Oct leaves out the 100 kg of DWT3: ' || :'staff_quince_10_11');
SELECT pg_temp.dwt_assert(pg_temp.dwt_column(:'staff_quince_10_10'::jsonb, 'disp_no') = ARRAY['DWT1']
  AND (:'staff_quince_10_10'::jsonb)#>>'{summary,total_weight}' = '325'
  AND pg_temp.dwt_lines(:'staff_quince_10_10'::jsonb, 'DWT1') = ARRAY['Dispatch Weight Cumin=3:75', 'Dispatch Weight Fennel=5:250'],
  'staff: 10..10 Oct holds DWT1 and its 325 kg: ' || :'staff_quince_10_10');
SELECT pg_temp.dwt_assert(jsonb_array_length((:'staff_quince_none'::jsonb)->'dispatches') = 0
  AND (:'staff_quince_none'::jsonb)#>>'{summary,total_weight}' = '0' AND (:'staff_quince_none'::jsonb)#>>'{summary,total_dispatches}' = '0'
  AND jsonb_typeof((:'staff_quince_none'::jsonb)#>'{summary,total_weight}') = 'number',
  'staff: a period without dispatches weighs 0: ' || :'staff_quince_none');

-- ---------------------------------------------------------------------------
-- Another customer's dispatch has its own weight; a dispatch without lines weighs 0
-- ---------------------------------------------------------------------------
SELECT pg_temp.dwt_assert(pg_temp.dwt_column(:'staff_rowan'::jsonb, 'disp_no') = ARRAY['DWT5']
  AND pg_temp.dwt_column(:'staff_rowan'::jsonb, 'total_weight') = ARRAY['280']
  AND pg_temp.dwt_lines(:'staff_rowan'::jsonb, 'DWT5') = ARRAY['Dispatch Weight Fennel=7:280']
  AND (:'staff_rowan'::jsonb)#>>'{summary,total_weight}' = '280'
  AND position('DWT1' in :'staff_rowan') = 0 AND position('DWT3' in :'staff_rowan') = 0,
  'staff: Rowan''s dispatch weighs 7*40 = 280 kg and none of Quince''s is in it: ' || :'staff_rowan');
-- No lines: total_weight 0 (a number), no lines listed, and the summary, which counts lines, 0.
SELECT pg_temp.dwt_assert(pg_temp.dwt_column(:'staff_hazel'::jsonb, 'disp_no') = ARRAY['DWT6']
  AND pg_temp.dwt_column(:'staff_hazel'::jsonb, 'total_weight') = ARRAY['0']
  AND jsonb_typeof((:'staff_hazel'::jsonb)#>'{dispatches,0,total_weight}') = 'number'
  AND pg_temp.dwt_lines(:'staff_hazel'::jsonb, 'DWT6') = '{}'
  AND (:'staff_hazel'::jsonb)#>>'{summary,total_weight}' = '0'
  AND (:'staff_hazel'::jsonb)#>>'{summary,total_weight}' = pg_temp.dwt_dispatch_sum(:'staff_hazel'::jsonb)::text,
  'staff: a dispatch without lines weighs 0: ' || :'staff_hazel');

-- ---------------------------------------------------------------------------
-- A customer account: its own customer's weights, nobody else's
-- ---------------------------------------------------------------------------
SELECT pg_temp.dwt_assert(:'customer_quince'::jsonb = :'staff_quince'::jsonb
  AND pg_temp.dwt_column(:'customer_quince'::jsonb, 'total_weight') = ARRAY['100', '0', '325']
  AND (:'customer_quince'::jsonb)#>>'{summary,total_weight}' = '425',
  'customer account: its own customer''s dispatches carry their weights: ' || :'customer_quince');
-- The refusal check can tell an answer from a refusal: the same call for its own customer is answered.
SELECT pg_temp.dwt_assert(:'customer_quince_check' LIKE 'answered: %', 'the refusal check answers "answered" for an allowed call: ' || :'customer_quince_check');
-- Another customer's id is refused by the guard, so no weight of Rowan's can be learned here.
SELECT pg_temp.dwt_assert(:'customer_rowan' = 'Customer access denied'
  AND position('280' in :'customer_rowan') = 0,
  'customer account: another customer''s dispatch activity was not refused: ' || :'customer_rowan');

ROLLBACK;
SELECT 'report dispatch weight: each line and each dispatch of the customer dispatch activity carries its weight in kg, summary.total_weight is the sum of the dispatches'' weights, the other keys are unchanged, and a customer account still gets only its own customer' AS result;

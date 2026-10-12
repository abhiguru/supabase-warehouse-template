-- The GRN activity reports count weight as bags times kilograms per bag (migration 59).
--
-- get_customer_grn_activity added up the per-bag weights of a receipt's lines without the bags
-- (SUM(weight)), so total_weight of a receipt, total_weight of a customer and total_weight_kg of
-- the summary were not weights. Since migration 59 each is the kg of the RECEIVED lines: the sum
-- of qty x per-bag weight (goodsreceived_trl.weight, kg per bag, null counts as 0), not the stock
-- left. The line's own weight (items[].weight) stays the per-bag weight. get_all_grn_activity
-- already multiplied and is unchanged; it is checked here as well, and against the other function.
--
--   receipt  customer  day (period 10..12 Mar)  lines: bags x kg per bag
--   GWR1     Quince    10 Mar                   Cumin 100 x 25, Fennel 40 x 50          = 2500 + 2000 = 4500
--   GWR2     Quince    11 Mar                   Fennel 60 x 30, Cumin 10 x NULL         = 1800 + 0    = 1800
--   GWR3     Quince    12 Mar                   Fennel 20 x 40                          = 800
--   GWR4     Quince    11 Mar                   Fennel 5 x 100, DELETED                 never listed, never counted (500)
--   GWR5     Quince    20 Feb                   Fennel 7 x 70, before the period        = 490, counted only when the period reaches it
--   GWR6     Rowan     11 Mar                   Fennel 8 x 35, Cumin 3 x 10             = 280 + 30    = 310
--   GWR7     Hazel     10 Mar                   Cumin 4 x NULL                          = 0 (every line without a weight)
--   GWD1, GWD2 dispatch 30 bags of Cumin from GWR1 and 10 bags of Fennel from GWR3 (12 Mar), so the
--   stock left (GWR1 Cumin 70, GWR3 Fennel 10) differs from the quantity received.
-- Quince, 10..12 Mar: GWR3, GWR2, GWR1 = 800, 1800, 4500 and the summary 7100; 11..12: 2600; 10..10: 4500;
-- 20 Feb..12 Mar: 7590. All customers, 10..12 Mar: Quince 7100, Rowan 310, Hazel 0, together 7410.
-- A wrong formula tells itself apart: the old sum of per-bag weights gives 75, 30, 40 (summary 145;
-- all customers 190); weight x stock gives 5950 for Quince; counting the deleted receipt 7600 and the
-- one before the period 7590; the quantity alone 230.
--
-- Each answer is read as the role under test and compared AFTER the role is dropped.
-- Runs ONLY in migrations.sh's fresh, network-disabled database. All fixture rows roll back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.gw_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'report grn weight: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.gw_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.gw_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- A dispatch of the fixture: lines is [{gr_no, item, qty}, ...]; each is taken from the received
-- line of that item on that receipt. Called as the administrator.
CREATE FUNCTION pg_temp.gw_dispatch(p_no text, p_day text, p_customer uuid, p_customer_name text, p_supervisor text, p_lines jsonb) RETURNS void LANGUAGE plpgsql AS $$
DECLARE lines jsonb[];
BEGIN
  SELECT array_agg(jsonb_build_object('gr_trl_id', t.id, 'disp_qty', (e.l->>'qty')::int) ORDER BY e.ord) INTO lines
  FROM jsonb_array_elements(p_lines) WITH ORDINALITY AS e(l, ord)
  JOIN public.goodsreceived g ON g.gr_no = e.l->>'gr_no'
  JOIN public.goodsreceived_trl t ON t.gr_id = g.id AND t.item_name = e.l->>'item';
  PERFORM pg_temp.gw_assert(COALESCE(cardinality(lines), 0) = jsonb_array_length(p_lines), 'fixture lines found for ' || p_no);
  PERFORM pg_temp.gw_assert(public.create_dispatch_with_stock_check(jsonb_build_object('disp_no', p_no,
      'disp_date', p_day, 'customer_id', p_customer, 'customer_name', p_customer_name,
      'supervisor_id', p_supervisor, 'supervisor_name', 'Grn Weight Administrator'),
    lines, 0, 'report-grn-weight-' || p_no)->>'success' = 'true', 'fixture dispatch ' || p_no);
END $$;
-- One field of every receipt of a one-customer answer, in the returned order.
CREATE FUNCTION pg_temp.gw_column(answer jsonb, value_key text) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(x->>value_key ORDER BY ord), '{}')
  FROM jsonb_array_elements(answer#>'{data,grns}') WITH ORDINALITY AS t(x, ord) $$;
-- The lines of one receipt of a one-customer answer as "item=bags:kg per bag" (a line without a
-- per-bag weight gives "null"), sorted by item name.
CREATE FUNCTION pg_temp.gw_lines(answer jsonb, p_no text) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg((i->>'item_name') || '=' || (i->>'quantity') || ':' || COALESCE(i->>'weight', 'null') ORDER BY i->>'item_name'), '{}')
  FROM jsonb_array_elements(answer#>'{data,grns}') AS t(x)
  CROSS JOIN LATERAL jsonb_array_elements(x->'items') AS l(i)
  WHERE x->>'gr_no' = p_no $$;
-- The kg of one receipt object worked out from its own lines: bags x per-bag weight, null as 0.
CREATE FUNCTION pg_temp.gw_line_sum(grn jsonb) RETURNS numeric LANGUAGE sql AS $$
  SELECT COALESCE(sum((i->>'quantity')::numeric * COALESCE((i->>'weight')::numeric, 0)), 0)
  FROM jsonb_array_elements(grn->'items') AS l(i) $$;
-- The kg of one receipt worked out from the tables: received bags x per-bag weight, null as 0.
CREATE FUNCTION pg_temp.gw_table_kg(p_no text) RETURNS numeric LANGUAGE sql AS $$
  SELECT COALESCE(sum(t.qty::numeric * COALESCE(t.weight, 0)), 0)
  FROM public.goodsreceived g JOIN public.goodsreceived_trl t ON t.gr_id = g.id WHERE g.gr_no = p_no $$;
-- The sum of total_weight over the receipts of a one-customer answer.
CREATE FUNCTION pg_temp.gw_receipt_sum(answer jsonb) RETURNS numeric LANGUAGE sql AS $$
  SELECT COALESCE(sum((x->>'total_weight')::numeric), 0) FROM jsonb_array_elements(answer#>'{data,grns}') AS t(x) $$;
-- The customer row of a by_customer array, by name.
CREATE FUNCTION pg_temp.gw_customer(rows jsonb, p_name text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT x FROM jsonb_array_elements(rows) AS t(x) WHERE x->>'customer_name' = p_name $$;
-- The customer names of a by_customer array, in the returned order.
CREATE FUNCTION pg_temp.gw_names(rows jsonb) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(x->>'customer_name' ORDER BY ord), '{}') FROM jsonb_array_elements(rows) WITH ORDINALITY AS t(x, ord) $$;
-- The keys of an object, sorted bytewise, as one text.
CREATE FUNCTION pg_temp.gw_keys(o jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(k, ',' ORDER BY k COLLATE "C") FROM jsonb_object_keys(o) AS t(k) $$;
-- 'refused: <message>' when the call is refused: either the guard raises 42501 or, as these report
-- functions do, the refusal comes back as data ({success: false, error: ...}); 'answered: ...' when it
-- returns a report. Any other error stops the test.
CREATE FUNCTION pg_temp.gw_refusal(statement text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  EXECUTE statement INTO answer;
  IF answer->>'success' = 'false' THEN RETURN 'refused: ' || COALESCE(answer->>'error', ''); END IF;
  RETURN 'answered: ' || left(answer::text, 120);
EXCEPTION WHEN insufficient_privilege THEN RETURN 'refused: ' || SQLERRM;
END $$;
-- How many times a text occurs in the definition of a function (by its signature).
CREATE FUNCTION pg_temp.gw_count(signature text, needle text) RETURNS integer LANGUAGE sql AS $$
  SELECT (length(pg_get_functiondef(signature::regprocedure)) - length(replace(pg_get_functiondef(signature::regprocedure), needle, ''))) / length(needle) $$;

-- ---------------------------------------------------------------------------
-- The functions: single, guarded, and otherwise as before
-- ---------------------------------------------------------------------------
SELECT pg_temp.gw_assert(count(*) = 1, 'exactly one function named ' || n || ', in any schema')
FROM unnest(ARRAY['get_customer_grn_activity', 'get_all_grn_activity']) AS names(n) JOIN pg_proc p ON p.proname = n GROUP BY n;
SELECT pg_temp.gw_assert(p.prosecdef AND pg_get_functiondef(p.oid) ~ ('BEGIN\s+PERFORM warehouse_security\.authorize_rpc\(''' || p.proname || ''','),
  'SECURITY DEFINER, and the guard comes first in ' || p.proname)
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('get_customer_grn_activity', 'get_all_grn_activity');
-- The search_path (and jit setting) and the grants are what they were: the sibling's fixed path, execute for
-- authenticated and not for anon.
SELECT pg_temp.gw_assert(p.proconfig IS NOT NULL AND p.proconfig::text LIKE '%search_path=%'
    AND p.proconfig @> (SELECT s.proconfig FROM pg_proc s WHERE s.oid = 'public.get_customer_stock_summary(uuid)'::regprocedure)
    AND (p.proname = 'get_all_grn_activity' OR p.proconfig @> ARRAY['jit=off'])
    AND has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
    AND p.proacl IS NOT DISTINCT FROM (SELECT s.proacl FROM pg_proc s WHERE s.oid = 'public.get_customer_stock_summary(uuid)'::regprocedure),
  'search_path, jit and grants of ' || p.proname || ': ' || COALESCE(p.proconfig::text, 'none') || ' ' || COALESCE(p.proacl::text, 'none'))
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('get_customer_grn_activity', 'get_all_grn_activity');
-- The totals of get_customer_grn_activity are written as bags x per-bag weight (the CTE of each branch), the old
-- sum of per-bag weights is gone, the line's own weight is still the raw per-bag weight, and the figures
-- built on the CTE still read it. The India day cut of migration 56 is kept.
SELECT pg_temp.gw_assert(pg_temp.gw_count('public.get_customer_grn_activity(uuid,date,date)', 'COALESCE(SUM(grt.weight::numeric * grt.qty), 0) as total_weight') = 2
    AND pg_temp.gw_count('public.get_customer_grn_activity(uuid,date,date)', 'SUM(grt.weight) as total_weight') = 0
    AND pg_temp.gw_count('public.get_customer_grn_activity(uuid,date,date)', '''weight'', grt.weight,') = 1
    AND pg_temp.gw_count('public.get_customer_grn_activity(uuid,date,date)', 'COALESCE(gi.total_weight, 0) as total_weight,') = 1
    AND pg_temp.gw_count('public.get_customer_grn_activity(uuid,date,date)', '''total_weight_kg'', COALESCE(SUM(total_weight), 0),') = 1
    AND pg_temp.gw_count('public.get_customer_grn_activity(uuid,date,date)', 'COALESCE(SUM(gi.total_weight), 0) as total_weight,') = 1
    AND pg_temp.gw_count('public.get_customer_grn_activity(uuid,date,date)', '''total_weight_kg'', COALESCE((SELECT SUM(gi.total_weight) FROM grn_data gd LEFT JOIN grn_items gi ON gd.grn_id = gi.gr_id), 0)') = 1
    AND pg_temp.gw_count('public.get_customer_grn_activity(uuid,date,date)', 'gr.date >= warehouse_security.business_day_start(v_from_date) AND gr.date < warehouse_security.business_day_start(v_to_date + 1)') = 2,
  'get_customer_grn_activity: the weight totals, the per-bag line weight and the India day cut');
SELECT pg_temp.gw_assert(pg_temp.gw_count('public.get_all_grn_activity(date,date)', '''total_weight'', COALESCE(SUM(gt.weight::numeric * gt.qty), 0)') = 1
    AND pg_temp.gw_count('public.get_all_grn_activity(date,date)', '''total_weight'', SUM(gt.weight::numeric * gt.qty)') = 1
    AND pg_temp.gw_count('public.get_all_grn_activity(date,date)', 'SUM(gt.weight)') = 0
    AND pg_temp.gw_count('public.get_all_grn_activity(date,date)', 'g.date >= warehouse_security.business_day_start(p_from_date)') = 3,
  'get_all_grn_activity: both totals are bags x per-bag weight, and the India day cut is kept');

-- ---------------------------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------------------------
INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888889301', 'Grn Weight Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888889302', 'Grn Weight Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888889303', 'Grn Weight Customer', 'customer', true, 'approved');
SELECT id AS admin_profile FROM public.user_profiles WHERE mobile = '919888889301' \gset
SELECT pg_temp.gw_login('9888889301') AS admin_claims \gset
SELECT pg_temp.gw_login('9888889302') AS staff_claims \gset
SELECT pg_temp.gw_login('9888889303') AS customer_claims \gset
INSERT INTO public.customers(name, mobile) VALUES ('Grn Weight Quince Cold', '9888889311') RETURNING id AS quince \gset
INSERT INTO public.customers(name, mobile) VALUES ('Grn Weight Rowan Agro', '9888889312') RETURNING id AS rowan \gset
INSERT INTO public.customers(name, mobile) VALUES ('Grn Weight Hazel Stores', '9888889313') RETURNING id AS hazel \gset
INSERT INTO public.items(name, packaging) VALUES ('Grn Weight Fennel', 'Bag') RETURNING id AS fennel \gset
INSERT INTO public.items(name, packaging) VALUES ('Grn Weight Cumin', 'Bag') RETURNING id AS cumin \gset
-- The customer login is assigned to Quince only.
INSERT INTO public.users_customers_new(user_profile_id, customer_id, active)
 SELECT id, :'quince'::uuid, true FROM public.user_profiles WHERE mobile = '919888889303';

SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
-- A receipt is stored at 12:00 UTC of its day, 17:30 on the same India day.
SELECT pg_temp.gw_assert(public.save_grn(p_gr_no => r.gr_no, p_date => (r.day || 'T12:00:00Z')::timestamptz,
  p_customer_id => r.customer, p_customer_name => r.customer_name, p_idempotency_key => 'report-grn-weight-' || r.gr_no,
  p_items => r.lines)->>'success' = 'true', 'fixture receipt ' || r.gr_no)
FROM (VALUES
  ('GWR1', '2026-03-10', :'quince'::uuid, 'Grn Weight Quince Cold', jsonb_build_array(
     jsonb_build_object('item_id', :'cumin', 'item_name', 'Grn Weight Cumin', 'packaging', 'Bag', 'qty', 100, 'weight', 25),
     jsonb_build_object('item_id', :'fennel', 'item_name', 'Grn Weight Fennel', 'packaging', 'Bag', 'qty', 40, 'weight', 50))),
  ('GWR2', '2026-03-11', :'quince'::uuid, 'Grn Weight Quince Cold', jsonb_build_array(
     jsonb_build_object('item_id', :'fennel', 'item_name', 'Grn Weight Fennel', 'packaging', 'Bag', 'qty', 60, 'weight', 30),
     jsonb_build_object('item_id', :'cumin', 'item_name', 'Grn Weight Cumin', 'packaging', 'Bag', 'qty', 10, 'weight', 99))),
  ('GWR3', '2026-03-12', :'quince'::uuid, 'Grn Weight Quince Cold', jsonb_build_array(
     jsonb_build_object('item_id', :'fennel', 'item_name', 'Grn Weight Fennel', 'packaging', 'Bag', 'qty', 20, 'weight', 40))),
  ('GWR4', '2026-03-11', :'quince'::uuid, 'Grn Weight Quince Cold', jsonb_build_array(
     jsonb_build_object('item_id', :'fennel', 'item_name', 'Grn Weight Fennel', 'packaging', 'Bag', 'qty', 5, 'weight', 100))),
  ('GWR5', '2026-02-20', :'quince'::uuid, 'Grn Weight Quince Cold', jsonb_build_array(
     jsonb_build_object('item_id', :'fennel', 'item_name', 'Grn Weight Fennel', 'packaging', 'Bag', 'qty', 7, 'weight', 70))),
  ('GWR6', '2026-03-11', :'rowan'::uuid, 'Grn Weight Rowan Agro', jsonb_build_array(
     jsonb_build_object('item_id', :'fennel', 'item_name', 'Grn Weight Fennel', 'packaging', 'Bag', 'qty', 8, 'weight', 35),
     jsonb_build_object('item_id', :'cumin', 'item_name', 'Grn Weight Cumin', 'packaging', 'Bag', 'qty', 3, 'weight', 10))),
  ('GWR7', '2026-03-10', :'hazel'::uuid, 'Grn Weight Hazel Stores', jsonb_build_array(
     jsonb_build_object('item_id', :'cumin', 'item_name', 'Grn Weight Cumin', 'packaging', 'Bag', 'qty', 4, 'weight', 99)))
) AS r(gr_no, day, customer, customer_name, lines);
RESET ROLE;
-- save_grn stores a missing weight as 0, so a line without a per-bag weight is made as a column that
-- holds NULL (the column allows it): the Cumin of GWR2 and the only line of GWR7.
UPDATE public.goodsreceived_trl t SET weight = NULL FROM public.goodsreceived g
 WHERE g.id = t.gr_id AND ((g.gr_no = 'GWR2' AND t.item_name = 'Grn Weight Cumin') OR g.gr_no = 'GWR7');
-- GWR4 is deleted, as the delete RPC leaves a receipt: the reports must not list it or count its weight.
UPDATE public.goodsreceived SET deleted_at = now() WHERE gr_no = 'GWR4';

SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.gw_dispatch('GWD1', '2026-03-12', :'quince'::uuid, 'Grn Weight Quince Cold', :'admin_profile',
  '[{"gr_no":"GWR1","item":"Grn Weight Cumin","qty":30}]');
SELECT pg_temp.gw_dispatch('GWD2', '2026-03-12', :'quince'::uuid, 'Grn Weight Quince Cold', :'admin_profile',
  '[{"gr_no":"GWR3","item":"Grn Weight Fennel","qty":10}]');
RESET ROLE;

SELECT pg_temp.gw_assert((SELECT count(*) FROM public.goodsreceived WHERE gr_no LIKE 'GWR%') = 7
  AND (SELECT count(*) FROM public.goodsreceived WHERE gr_no LIKE 'GWR%' AND deleted_at IS NOT NULL) = 1
  AND (SELECT string_agg(gr_no || '@' || to_char(date AT TIME ZONE 'Asia/Kolkata', 'MM-DD'), ' ' ORDER BY gr_no) FROM public.goodsreceived WHERE gr_no LIKE 'GWR%')
    = 'GWR1@03-10 GWR2@03-11 GWR3@03-12 GWR4@03-11 GWR5@02-20 GWR6@03-11 GWR7@03-10',
  'fixture: seven receipts on the intended India days, one deleted');
SELECT pg_temp.gw_assert((SELECT string_agg(g.gr_no || '/' || t.item_name || '=' || t.qty || 'x' || COALESCE(t.weight::text, 'NULL') || '/stock' || t.stock, ' ' ORDER BY g.gr_no, t.item_name)
      FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id = t.gr_id WHERE g.gr_no LIKE 'GWR%')
    = 'GWR1/Grn Weight Cumin=100x25/stock70 GWR1/Grn Weight Fennel=40x50/stock40 GWR2/Grn Weight Cumin=10xNULL/stock10 GWR2/Grn Weight Fennel=60x30/stock60 '
      || 'GWR3/Grn Weight Fennel=20x40/stock10 GWR4/Grn Weight Fennel=5x100/stock5 GWR5/Grn Weight Fennel=7x70/stock7 GWR6/Grn Weight Cumin=3x10/stock3 '
      || 'GWR6/Grn Weight Fennel=8x35/stock8 GWR7/Grn Weight Cumin=4xNULL/stock4',
  'fixture: bags x kg per bag of every received line (two without a per-bag weight), and the stock left after the two dispatches');
-- What the tables say, worked out apart from the functions: the kg received by the receipts that are not
-- deleted, per customer and period (a period is the India days, from the first moment of the first day to
-- before the first moment of the day after the last one), and, to tell the two meanings apart, the figures
-- the old and the stock-based formulas would give for Quince, 10..12 Mar.
SELECT COALESCE(sum(t.qty::numeric * COALESCE(t.weight, 0)), 0) AS table_quince_p
FROM public.goodsreceived g JOIN public.goodsreceived_trl t ON t.gr_id = g.id
WHERE g.customer_id = :'quince'::uuid AND g.deleted_at IS NULL
  AND g.date >= warehouse_security.business_day_start('2026-03-10') AND g.date < warehouse_security.business_day_start('2026-03-13') \gset
SELECT COALESCE(sum(t.qty::numeric * COALESCE(t.weight, 0)), 0) AS table_all_p
FROM public.goodsreceived g JOIN public.goodsreceived_trl t ON t.gr_id = g.id
WHERE g.deleted_at IS NULL
  AND g.date >= warehouse_security.business_day_start('2026-03-10') AND g.date < warehouse_security.business_day_start('2026-03-13') \gset
SELECT COALESCE(sum(t.weight), 0) AS old_quince_p, COALESCE(sum(t.stock::numeric * COALESCE(t.weight, 0)), 0) AS stock_quince_p
FROM public.goodsreceived g JOIN public.goodsreceived_trl t ON t.gr_id = g.id
WHERE g.customer_id = :'quince'::uuid AND g.deleted_at IS NULL
  AND g.date >= warehouse_security.business_day_start('2026-03-10') AND g.date < warehouse_security.business_day_start('2026-03-13') \gset
SELECT pg_temp.gw_assert(:'table_quince_p' = '7100' AND :'table_all_p' = '7410' AND :'old_quince_p' = '145' AND :'stock_quince_p' = '5950',
  'the tables hold 7100 kg received for Quince and 7410 for everyone, 10..12 Mar (the old formula would give ' || :'old_quince_p' || ', weight x stock ' || :'stock_quince_p' || '): '
  || :'table_quince_p' || ' ' || :'table_all_p');

-- ---------------------------------------------------------------------------
-- The answers, each read as the role under test
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.get_customer_grn_activity(:'quince'::uuid, '2026-03-10', '2026-03-12')::text AS admin_quince \gset
SELECT public.get_customer_grn_activity(NULL, '2026-03-10', '2026-03-12')::text AS admin_everyone \gset
SELECT public.get_all_grn_activity('2026-03-10', '2026-03-12')::text AS admin_all \gset
RESET ROLE;

SELECT set_config('request.jwt.claims', :'staff_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.gw_assert(warehouse_security.active_role() = 'staff', 'actual staff role');
SELECT public.get_customer_grn_activity(:'quince'::uuid, '2026-03-10', '2026-03-12')::text AS staff_quince \gset
SELECT public.get_customer_grn_activity(:'quince'::uuid, '2026-03-11', '2026-03-12')::text AS staff_quince_11_12 \gset
SELECT public.get_customer_grn_activity(:'quince'::uuid, '2026-03-10', '2026-03-10')::text AS staff_quince_10_10 \gset
SELECT public.get_customer_grn_activity(:'quince'::uuid, '2026-02-20', '2026-03-12')::text AS staff_quince_wide \gset
SELECT public.get_customer_grn_activity(:'quince'::uuid, '2026-09-01', '2026-09-30')::text AS staff_quince_none \gset
SELECT public.get_customer_grn_activity(:'rowan'::uuid, '2026-03-10', '2026-03-12')::text AS staff_rowan \gset
SELECT public.get_customer_grn_activity(:'hazel'::uuid, '2026-03-10', '2026-03-12')::text AS staff_hazel \gset
SELECT public.get_customer_grn_activity(NULL, '2026-03-10', '2026-03-12')::text AS staff_everyone \gset
SELECT public.get_customer_grn_activity(NULL, '2026-09-01', '2026-09-30')::text AS staff_everyone_none \gset
SELECT public.get_all_grn_activity('2026-03-10', '2026-03-12')::text AS staff_all \gset
SELECT public.get_all_grn_activity('2026-09-01', '2026-09-30')::text AS staff_all_none \gset
RESET ROLE;

SELECT set_config('request.jwt.claims', :'customer_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.gw_assert(warehouse_security.active_role() = 'customer', 'actual customer role');
SELECT public.get_customer_grn_activity(:'quince'::uuid, '2026-03-10', '2026-03-12')::text AS customer_quince \gset
SELECT pg_temp.gw_refusal(format('SELECT public.get_customer_grn_activity(%L::uuid, %L::date, %L::date)', :'rowan', '2026-03-10', '2026-03-12')) AS customer_rowan \gset
SELECT pg_temp.gw_refusal(format('SELECT public.get_customer_grn_activity(%L::uuid, %L::date, %L::date)', :'quince', '2026-03-10', '2026-03-12')) AS customer_quince_check \gset
SELECT pg_temp.gw_refusal(format('SELECT public.get_customer_grn_activity(NULL::uuid, %L::date, %L::date)', '2026-03-10', '2026-03-12')) AS customer_everyone \gset
SELECT pg_temp.gw_refusal(format('SELECT public.get_all_grn_activity(%L::date, %L::date)', '2026-03-10', '2026-03-12')) AS customer_all \gset
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Staff, one customer: the weight of each receipt and of the summary is bags x kg per bag
-- ---------------------------------------------------------------------------
-- The receipts are the three that count, newest day first, with their kilograms and bags.
SELECT pg_temp.gw_assert(pg_temp.gw_column(:'staff_quince'::jsonb, 'gr_no') = ARRAY['GWR3', 'GWR2', 'GWR1']
  AND pg_temp.gw_column(:'staff_quince'::jsonb, 'total_weight') = ARRAY['800', '1800', '4500']
  AND pg_temp.gw_column(:'staff_quince'::jsonb, 'total_qty') = ARRAY['20', '70', '140']
  AND pg_temp.gw_column(:'staff_quince'::jsonb, 'total_items') = ARRAY['1', '2', '2'],
  'staff: Quince receipts, their total_weight (20x40, 60x30 + 10 with no weight, 100x25 + 40x50), bags and lines: ' || :'staff_quince');
-- The line's own weight is still the per-bag weight (a line without one is null); the quantity is the bags received.
SELECT pg_temp.gw_assert(pg_temp.gw_lines(:'staff_quince'::jsonb, 'GWR1') = ARRAY['Grn Weight Cumin=100:25', 'Grn Weight Fennel=40:50']
  AND pg_temp.gw_lines(:'staff_quince'::jsonb, 'GWR2') = ARRAY['Grn Weight Cumin=10:null', 'Grn Weight Fennel=60:30']
  AND pg_temp.gw_lines(:'staff_quince'::jsonb, 'GWR3') = ARRAY['Grn Weight Fennel=20:40'],
  'staff: items[].weight is the kg per bag as typed in, quantity the bags: ' || :'staff_quince');
-- The weight received is not the weight left: GWR1 has 70 of its 100 bags of Cumin in stock and weighs 4500, not 3750.
SELECT pg_temp.gw_assert((SELECT bool_and((x#>>'{dispatch_summary,current_stock}')::int = c.stock) FROM jsonb_array_elements((:'staff_quince'::jsonb)#>'{data,grns}') AS t(x)
      JOIN (VALUES ('GWR1', 110), ('GWR2', 70), ('GWR3', 10)) AS c(gr_no, stock) ON c.gr_no = x->>'gr_no')
  AND (SELECT (x->>'total_weight')::numeric FROM jsonb_array_elements((:'staff_quince'::jsonb)#>'{data,grns}') AS t(x) WHERE x->>'gr_no' = 'GWR1') = 4500,
  'staff: GWR1 has 110 bags left of 140 and still weighs the 4500 kg received: ' || :'staff_quince');
-- Every receipt's total is the sum of its own lines' bags x per-bag weight, and the table's figure for that receipt.
SELECT pg_temp.gw_assert(count(*) = 3 AND bool_and(jsonb_typeof(x->'total_weight') = 'number')
    AND bool_and((x->>'total_weight')::numeric = pg_temp.gw_line_sum(x))
    AND bool_and((x->>'total_weight')::numeric = pg_temp.gw_table_kg(x->>'gr_no')),
  'staff: every total_weight is a number, the sum of its lines'' bags x kg per bag, and the table''s figure: ' || :'staff_quince')
FROM jsonb_array_elements((:'staff_quince'::jsonb)#>'{data,grns}') AS t(x);
-- The summary is the sum of the receipts' total_weight and the table's figure; the other counts are as they were.
SELECT pg_temp.gw_assert((:'staff_quince'::jsonb)#>>'{data,summary,total_weight_kg}' = '7100'
  AND (:'staff_quince'::jsonb)#>>'{data,summary,total_weight_kg}' = pg_temp.gw_receipt_sum(:'staff_quince'::jsonb)::text
  AND (:'staff_quince'::jsonb)#>>'{data,summary,total_weight_kg}' = :'table_quince_p'
  AND jsonb_typeof((:'staff_quince'::jsonb)#>'{data,summary,total_weight_kg}') = 'number'
  AND (:'staff_quince'::jsonb)#>>'{data,summary,total_grns}' = '3' AND (:'staff_quince'::jsonb)#>>'{data,summary,total_quantity}' = '230'
  AND (:'staff_quince'::jsonb)#>>'{data,summary,total_items}' = '5' AND (:'staff_quince'::jsonb)#>>'{data,summary,total_invoiced_grns}' = '0',
  'staff: summary.total_weight_kg is 7100, the sum of the receipts'' total_weight and the table''s: ' || :'staff_quince');
-- None of the wrong figures: the old sum of per-bag weights (145), weight x stock (5950), the deleted receipt
-- counted (7600), the receipt before the period counted (7590), the bags alone (230).
SELECT pg_temp.gw_assert((:'staff_quince'::jsonb)#>>'{data,summary,total_weight_kg}' NOT IN ('145', '5950', '7600', '7590', '230'),
  'staff: the summary weight is none of the wrong figures: ' || :'staff_quince');
-- The exact key sets of the answer, its summary, a receipt and a line are the earlier ones.
SELECT pg_temp.gw_assert(pg_temp.gw_keys(:'staff_quince'::jsonb) = 'data,metadata,success'
  AND pg_temp.gw_keys((:'staff_quince'::jsonb)->'data') = 'grns,summary'
  AND pg_temp.gw_keys((:'staff_quince'::jsonb)#>'{data,summary}') = 'total_grns,total_images,total_invoiced_grns,total_items,total_quantity,total_weight_kg'
  AND pg_temp.gw_keys((:'staff_quince'::jsonb)->'metadata') = 'customer_id,from_date,retrieved_at,to_date',
  'staff: the keys of the answer, of data, of the summary and of the metadata: ' || :'staff_quince');
SELECT pg_temp.gw_assert(count(*) = 3
    AND bool_and(pg_temp.gw_keys(x) = 'dispatch_summary,gr_no,grn_date,grn_id,image_count,invoice_status,items,note,registration,sender_name,supervisor_name,total_items,total_qty,total_weight')
    AND bool_and((SELECT bool_and(pg_temp.gw_keys(i) = 'current_stock,dispatched_qty,item_name,package_mark,packaging,quantity,rack,weight') FROM jsonb_array_elements(x->'items') AS l(i))),
  'staff: the keys of each receipt and of each of its lines')
FROM jsonb_array_elements((:'staff_quince'::jsonb)#>'{data,grns}') AS t(x);
-- The deleted receipt, the one before the period and the other customers' are not in the answer.
SELECT pg_temp.gw_assert(position('GWR4' in :'staff_quince') = 0 AND position('GWR5' in :'staff_quince') = 0
  AND position('GWR6' in :'staff_quince') = 0 AND position('GWR7' in :'staff_quince') = 0,
  'staff: the Quince answer holds neither the deleted receipt, nor the earlier one, nor another customer''s: ' || :'staff_quince');
-- An administrator is answered the same, for one customer and for all.
SELECT pg_temp.gw_assert(:'admin_quince'::jsonb = :'staff_quince'::jsonb, 'administrator and staff are answered alike, one customer: ' || :'admin_quince');
SELECT pg_temp.gw_assert(:'admin_everyone'::jsonb = :'staff_everyone'::jsonb, 'administrator and staff are answered alike, all customers: ' || :'admin_everyone');
SELECT pg_temp.gw_assert(:'admin_all'::jsonb = :'staff_all'::jsonb, 'administrator and staff are answered alike by get_all_grn_activity: ' || :'admin_all');

-- ---------------------------------------------------------------------------
-- Periods: a receipt outside the period is outside the weight
-- ---------------------------------------------------------------------------
-- 11..12 Mar leaves GWR1 (4500 kg) out; 10..10 holds GWR1 only; from 20 Feb the earlier receipt GWR5 (7 x 70 = 490) is in;
-- September holds nothing, and says 0 as a number.
SELECT pg_temp.gw_assert(pg_temp.gw_column(:'staff_quince_11_12'::jsonb, 'gr_no') = ARRAY['GWR3', 'GWR2']
  AND pg_temp.gw_column(:'staff_quince_11_12'::jsonb, 'total_weight') = ARRAY['800', '1800']
  AND (:'staff_quince_11_12'::jsonb)#>>'{data,summary,total_weight_kg}' = '2600'
  AND (:'staff_quince_11_12'::jsonb)#>>'{data,summary,total_weight_kg}' = pg_temp.gw_receipt_sum(:'staff_quince_11_12'::jsonb)::text
  AND (:'staff_quince_11_12'::jsonb)#>>'{data,summary,total_grns}' = '2' AND (:'staff_quince_11_12'::jsonb)#>>'{data,summary,total_quantity}' = '90',
  'staff: 11..12 Mar leaves out the 4500 kg of GWR1: ' || :'staff_quince_11_12');
SELECT pg_temp.gw_assert(pg_temp.gw_column(:'staff_quince_10_10'::jsonb, 'gr_no') = ARRAY['GWR1']
  AND pg_temp.gw_column(:'staff_quince_10_10'::jsonb, 'total_weight') = ARRAY['4500']
  AND (:'staff_quince_10_10'::jsonb)#>>'{data,summary,total_weight_kg}' = '4500',
  'staff: 10..10 Mar holds GWR1 and its 4500 kg: ' || :'staff_quince_10_10');
SELECT pg_temp.gw_assert(pg_temp.gw_column(:'staff_quince_wide'::jsonb, 'gr_no') = ARRAY['GWR3', 'GWR2', 'GWR1', 'GWR5']
  AND pg_temp.gw_column(:'staff_quince_wide'::jsonb, 'total_weight') = ARRAY['800', '1800', '4500', '490']
  AND (:'staff_quince_wide'::jsonb)#>>'{data,summary,total_weight_kg}' = '7590'
  AND (:'staff_quince_wide'::jsonb)#>>'{data,summary,total_weight_kg}' = pg_temp.gw_receipt_sum(:'staff_quince_wide'::jsonb)::text
  AND pg_temp.gw_lines(:'staff_quince_wide'::jsonb, 'GWR5') = ARRAY['Grn Weight Fennel=7:70'],
  'staff: 20 Feb..12 Mar also holds GWR5 (7 x 70 = 490), 7590 in all: ' || :'staff_quince_wide');
SELECT pg_temp.gw_assert(jsonb_array_length((:'staff_quince_none'::jsonb)#>'{data,grns}') = 0
  AND (:'staff_quince_none'::jsonb)#>>'{data,summary,total_weight_kg}' = '0' AND (:'staff_quince_none'::jsonb)#>>'{data,summary,total_grns}' = '0'
  AND jsonb_typeof((:'staff_quince_none'::jsonb)#>'{data,summary,total_weight_kg}') = 'number',
  'staff: a period without receipts weighs 0: ' || :'staff_quince_none');

-- ---------------------------------------------------------------------------
-- Other customers: their own weights; a receipt whose lines have no per-bag weight weighs 0
-- ---------------------------------------------------------------------------
SELECT pg_temp.gw_assert(pg_temp.gw_column(:'staff_rowan'::jsonb, 'gr_no') = ARRAY['GWR6']
  AND pg_temp.gw_column(:'staff_rowan'::jsonb, 'total_weight') = ARRAY['310']
  AND pg_temp.gw_lines(:'staff_rowan'::jsonb, 'GWR6') = ARRAY['Grn Weight Cumin=3:10', 'Grn Weight Fennel=8:35']
  AND (:'staff_rowan'::jsonb)#>>'{data,summary,total_weight_kg}' = '310'
  AND position('GWR1' in :'staff_rowan') = 0 AND position('GWR3' in :'staff_rowan') = 0,
  'staff: Rowan''s receipt weighs 3x10 + 8x35 = 310 kg and none of Quince''s is in it: ' || :'staff_rowan');
SELECT pg_temp.gw_assert(pg_temp.gw_column(:'staff_hazel'::jsonb, 'gr_no') = ARRAY['GWR7']
  AND pg_temp.gw_column(:'staff_hazel'::jsonb, 'total_weight') = ARRAY['0']
  AND jsonb_typeof((:'staff_hazel'::jsonb)#>'{data,grns,0,total_weight}') = 'number'
  AND pg_temp.gw_lines(:'staff_hazel'::jsonb, 'GWR7') = ARRAY['Grn Weight Cumin=4:null']
  AND (:'staff_hazel'::jsonb)#>>'{data,summary,total_weight_kg}' = '0'
  AND jsonb_typeof((:'staff_hazel'::jsonb)#>'{data,summary,total_weight_kg}') = 'number'
  AND (:'staff_hazel'::jsonb)#>>'{data,summary,total_quantity}' = '4',
  'staff: a receipt whose only line has no per-bag weight weighs 0, a number: ' || :'staff_hazel');

-- ---------------------------------------------------------------------------
-- Staff, all customers of get_customer_grn_activity (no customer given)
-- ---------------------------------------------------------------------------
SELECT pg_temp.gw_assert((:'staff_everyone'::jsonb)#>>'{data,summary,total_weight_kg}' = '7410'
  AND (:'staff_everyone'::jsonb)#>>'{data,summary,total_weight_kg}' = :'table_all_p'
  AND jsonb_typeof((:'staff_everyone'::jsonb)#>'{data,summary,total_weight_kg}') = 'number'
  AND (:'staff_everyone'::jsonb)#>>'{data,summary,total_grns}' = '5' AND (:'staff_everyone'::jsonb)#>>'{data,summary,total_customers}' = '3'
  AND (:'staff_everyone'::jsonb)#>>'{data,summary,total_quantity}' = '245' AND (:'staff_everyone'::jsonb)#>>'{data,summary,total_items}' = '245',
  'staff, all customers: the summary weighs 7410 kg (the table''s figure; the old formula gave 190) over 5 receipts and 245 bags: ' || :'staff_everyone');
SELECT pg_temp.gw_assert(pg_temp.gw_customer((:'staff_everyone'::jsonb)#>'{data,by_customer}', 'Grn Weight Quince Cold')
      @> '{"grn_count": 3, "total_quantity": 230, "total_weight": 7100}'
  AND pg_temp.gw_customer((:'staff_everyone'::jsonb)#>'{data,by_customer}', 'Grn Weight Rowan Agro') @> '{"grn_count": 1, "total_quantity": 11, "total_weight": 310}'
  AND pg_temp.gw_customer((:'staff_everyone'::jsonb)#>'{data,by_customer}', 'Grn Weight Hazel Stores') @> '{"grn_count": 1, "total_quantity": 4, "total_weight": 0}'
  AND (SELECT bool_and(jsonb_typeof(x->'total_weight') = 'number') FROM jsonb_array_elements((:'staff_everyone'::jsonb)#>'{data,by_customer}') AS t(x))
  AND (SELECT sum((x->>'total_weight')::numeric) FROM jsonb_array_elements((:'staff_everyone'::jsonb)#>'{data,by_customer}') AS t(x))
    = ((:'staff_everyone'::jsonb)#>>'{data,summary,total_weight_kg}')::numeric
  AND (pg_temp.gw_names((:'staff_everyone'::jsonb)#>'{data,by_customer}'))[1] = 'Grn Weight Quince Cold'
  AND jsonb_array_length((:'staff_everyone'::jsonb)#>'{data,by_customer}') = 3,
  'staff, all customers: each customer''s total_weight is bags x kg per bag (7100, 310, 0) and they add up to the summary: ' || :'staff_everyone');
SELECT pg_temp.gw_assert(pg_temp.gw_keys(:'staff_everyone'::jsonb) = 'data,metadata,success'
  AND pg_temp.gw_keys((:'staff_everyone'::jsonb)->'data') = 'by_customer,summary'
  AND pg_temp.gw_keys((:'staff_everyone'::jsonb)#>'{data,summary}') = 'total_customers,total_grns,total_items,total_quantity,total_weight_kg'
  AND pg_temp.gw_keys((:'staff_everyone'::jsonb)->'metadata') = 'from_date,retrieved_at,to_date'
  AND (SELECT bool_and(pg_temp.gw_keys(x) = 'customer_id,customer_name,grn_count,latest_grn_date,total_quantity,total_weight')
      FROM jsonb_array_elements((:'staff_everyone'::jsonb)#>'{data,by_customer}') AS t(x)),
  'staff, all customers: the keys of the answer, of the summary and of a customer row: ' || :'staff_everyone');
SELECT pg_temp.gw_assert(jsonb_array_length((:'staff_everyone_none'::jsonb)#>'{data,by_customer}') = 0
  AND (:'staff_everyone_none'::jsonb)#>>'{data,summary,total_weight_kg}' = '0'
  AND jsonb_typeof((:'staff_everyone_none'::jsonb)#>'{data,summary,total_weight_kg}') = 'number',
  'staff, all customers: a period without receipts weighs 0: ' || :'staff_everyone_none');

-- ---------------------------------------------------------------------------
-- get_all_grn_activity: not changed by migration 59, and the same figures as the function above
-- ---------------------------------------------------------------------------
SELECT pg_temp.gw_assert((:'staff_all'::jsonb)#>>'{summary,total_weight}' = '7410'
  AND (:'staff_all'::jsonb)#>>'{summary,total_weight}' = :'table_all_p'
  AND (:'staff_all'::jsonb)#>>'{summary,total_weight}' = (:'staff_everyone'::jsonb)#>>'{data,summary,total_weight_kg}'
  AND jsonb_typeof((:'staff_all'::jsonb)#>'{summary,total_weight}') = 'number'
  AND (:'staff_all'::jsonb)#>>'{summary,total_grns}' = '5' AND (:'staff_all'::jsonb)#>>'{summary,total_customers}' = '3'
  AND (:'staff_all'::jsonb)#>>'{summary,total_quantity}' = '245',
  'get_all_grn_activity: the summary weighs 7410 kg, the table''s figure and the other function''s: ' || :'staff_all');
SELECT pg_temp.gw_assert(pg_temp.gw_names((:'staff_all'::jsonb)->'by_customer') = ARRAY['Grn Weight Quince Cold', 'Grn Weight Rowan Agro', 'Grn Weight Hazel Stores']
  AND pg_temp.gw_customer((:'staff_all'::jsonb)->'by_customer', 'Grn Weight Quince Cold') @> '{"grn_count": 3, "total_qty": 230, "total_weight": 7100}'
  AND pg_temp.gw_customer((:'staff_all'::jsonb)->'by_customer', 'Grn Weight Rowan Agro') @> '{"grn_count": 1, "total_qty": 11, "total_weight": 310}'
  AND pg_temp.gw_customer((:'staff_all'::jsonb)->'by_customer', 'Grn Weight Hazel Stores') @> '{"grn_count": 1, "total_qty": 4}'
  -- Left as it was, and not covered by the rule (this function already multiplies): a customer whose lines ALL have
  -- a null per-bag weight has nothing to add up, so its total_weight is a JSON null here, not 0.
  AND jsonb_typeof(pg_temp.gw_customer((:'staff_all'::jsonb)->'by_customer', 'Grn Weight Hazel Stores')->'total_weight') = 'null',
  'get_all_grn_activity: Quince 7100 and Rowan 310 kg (bags x kg per bag), in order of bags; Hazel, no weights, null: ' || :'staff_all');
SELECT pg_temp.gw_assert(pg_temp.gw_keys(:'staff_all'::jsonb) = 'by_customer,by_date,success,summary'
  AND pg_temp.gw_keys((:'staff_all'::jsonb)->'summary') = 'from_date,to_date,total_customers,total_grns,total_quantity,total_weight'
  AND (SELECT bool_and(pg_temp.gw_keys(x) = 'customer_id,customer_name,grn_count,latest_grn,total_qty,total_weight') FROM jsonb_array_elements((:'staff_all'::jsonb)->'by_customer') AS t(x))
  AND (SELECT bool_and(pg_temp.gw_keys(x) = 'customer_count,date,grn_count,total_qty') FROM jsonb_array_elements((:'staff_all'::jsonb)->'by_date') AS t(x)),
  'get_all_grn_activity: the keys of the answer, of the summary, of a customer row and of a day row: ' || :'staff_all');
SELECT pg_temp.gw_assert((:'staff_all_none'::jsonb)#>>'{summary,total_weight}' = '0' AND jsonb_typeof((:'staff_all_none'::jsonb)#>'{summary,total_weight}') = 'number'
  AND jsonb_array_length((:'staff_all_none'::jsonb)->'by_customer') = 0,
  'get_all_grn_activity: a period without receipts weighs 0: ' || :'staff_all_none');

-- ---------------------------------------------------------------------------
-- A customer account: its own customer's weights, nobody else's
-- ---------------------------------------------------------------------------
SELECT pg_temp.gw_assert(:'customer_quince'::jsonb = :'staff_quince'::jsonb
  AND pg_temp.gw_column(:'customer_quince'::jsonb, 'total_weight') = ARRAY['800', '1800', '4500']
  AND (:'customer_quince'::jsonb)#>>'{data,summary,total_weight_kg}' = '7100',
  'customer account: its own customer''s receipts carry their weights: ' || :'customer_quince');
-- The refusal check can tell an answer from a refusal: the same call for its own customer is answered.
SELECT pg_temp.gw_assert(:'customer_quince_check' LIKE 'answered: %', 'the refusal check answers "answered" for an allowed call: ' || :'customer_quince_check');
-- Another customer's id, no customer at all and the all-customers function are refused by the guard,
-- so no weight of anyone else's can be learned here.
SELECT pg_temp.gw_assert(:'customer_rowan' = 'refused: Failed to retrieve GRN activity: Customer access denied' AND position('310' in :'customer_rowan') = 0,
  'customer account: another customer''s GRN activity was not refused: ' || :'customer_rowan');
SELECT pg_temp.gw_assert(:'customer_everyone' LIKE 'refused: %' AND :'customer_all' LIKE 'refused: %',
  'customer account: all-customers GRN activity was not refused: ' || :'customer_everyone' || ' / ' || :'customer_all');

ROLLBACK;
SELECT 'report grn weight: the weight totals of the GRN activity reports are bags times kg per bag (a receipt, a customer, the summaries), the line weight is still per bag, get_all_grn_activity is unchanged and agrees, the key sets are unchanged, and a customer account still gets only its own customer' AS result;

-- The receipt list includes the last day of its date filter (migration 55).
--
-- get_grn_list compared the end day of its filter (p_date_to, a date) with the timestamptz column
-- goodsreceived.date, which reads it as midnight at the start of that day: every receipt on the
-- last day was left out. Each receipt below carries a quantity that is a power of two, so every
-- total names exactly the receipts it counted.
--
-- Days, with E the end day (three days ago) and S the start day (four days before E):
--   receipt  moment (India)  qty   in the filter S..E?
--   GLE1     S   12:00          1   yes, start day
--   GLE2     E   02:00          2   yes, end day (was left out)
--   GLE3     E   23:30          4   yes, end day (was left out)
--   GLE4     E+1 02:00          8   no, the day after
--   GLE5     S-1 23:30         16   no, the day before (start side, unchanged)
-- Filter S..E: 3 receipts, 7 in all (before migration 55: 1 receipt, 1 in all).
--
-- The moments are India times (UTC+05:30): since migration 56 a day in this filter is a day in
-- India, whatever the session time zone (UTC here, asserted below). tests/report_ist_day.sql
-- covers the hours where an India day and a UTC day differ.
-- Runs ONLY in migrations.sh's fresh, network-disabled database. All fixture rows roll back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.gl_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'grn list end day: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.gl_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.gl_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- Receipt numbers of this test (GLE*) in a list answer, in the order the function returned them.
CREATE FUNCTION pg_temp.gl_numbers(answer jsonb) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(x->>'gr_no' ORDER BY ord), '{}')
  FROM jsonb_array_elements(answer#>'{data,grns}') WITH ORDINALITY AS t(x, ord) WHERE x->>'gr_no' LIKE 'GLE%' $$;
-- "count/quantity" from the summary of a list answer.
CREATE FUNCTION pg_temp.gl_figures(answer jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT (answer#>>'{data,summary,total_grns}') || '/' || (answer#>>'{data,summary,total_qty}') $$;

SELECT pg_temp.gl_assert(current_setting('TimeZone') = 'UTC', 'the session time zone is UTC, not India''s');

-- ---------------------------------------------------------------------------
-- The function: still single, guarded and sorted as before; no bare end-day comparison left
-- ---------------------------------------------------------------------------
SELECT pg_temp.gl_assert(count(*) = 1 AND bool_and(p.prosecdef)
    AND bool_and(pg_get_functiondef(p.oid) ~ ('BEGIN\s+PERFORM warehouse_security\.authorize_rpc\(''' || p.proname || ''','))
    AND bool_and(pg_get_functiondef(p.oid) !~ 'gr\.date <= %L')
    AND bool_and(pg_get_functiondef(p.oid) LIKE '%format(''gr.date >= %L'', warehouse_security.business_day_start(p_date_from))%')
    AND bool_and(pg_get_functiondef(p.oid) LIKE '%format(''gr.date < %L'', warehouse_security.business_day_start(p_date_to + 1))%')
    AND bool_and(pg_get_functiondef(p.oid) LIKE '%warehouse_security.document_number_sort_key(ga.gr_no)%'),
  'get_grn_list is single, guarded, sorted by document key and ends the filter before the day after')
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'get_grn_list';

-- ---------------------------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------------------------
SELECT CURRENT_DATE - 3 AS end_day, CURRENT_DATE - 7 AS start_day, CURRENT_DATE - 2 AS next_day,
       CURRENT_DATE - 8 AS day_before \gset
INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888888561', 'GRN List Day Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888888562', 'GRN List Day Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888888563', 'GRN List Day Customer', 'customer', true, 'approved');
SELECT pg_temp.gl_login('9888888561') AS admin_claims \gset
SELECT pg_temp.gl_login('9888888562') AS staff_claims \gset
SELECT pg_temp.gl_login('9888888563') AS customer_claims \gset
INSERT INTO public.customers(name, mobile) VALUES ('GRN List Day Quince Cold', '9888888571') RETURNING id AS quince \gset
INSERT INTO public.items(name, packaging) VALUES ('GRN List Day Turmeric', 'Bag') RETURNING id AS turmeric \gset
-- The customer login is assigned to Quince.
INSERT INTO public.users_customers_new(user_profile_id, customer_id, active)
 SELECT id, :'quince'::uuid, true FROM public.user_profiles WHERE mobile = '919888888563';

SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.gl_assert(public.save_grn(p_gr_no => r.gr_no, p_date => (r.day::text || 'T' || r.at || '+05:30')::timestamptz,
  p_customer_id => :'quince'::uuid, p_customer_name => 'GRN List Day Quince Cold', p_idempotency_key => 'grn-list-end-day-' || r.gr_no,
  p_items => jsonb_build_array(jsonb_build_object('item_id', :'turmeric', 'item_name', 'GRN List Day Turmeric', 'packaging', 'Bag',
    'qty', r.qty, 'weight', 5)))->>'success' = 'true', 'fixture receipt ' || r.gr_no)
FROM (VALUES
  ('GLE1', :'start_day'::date, '12:00:00', 1),
  ('GLE2', :'end_day'::date, '02:00:00', 2),
  ('GLE3', :'end_day'::date, '23:30:00', 4),
  ('GLE4', :'next_day'::date, '02:00:00', 8),
  ('GLE5', :'day_before'::date, '23:30:00', 16)
) AS r(gr_no, day, at, qty);
RESET ROLE;
SELECT pg_temp.gl_assert((SELECT string_agg(gr_no || '@' || to_char(date AT TIME ZONE 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI'), ' ' ORDER BY gr_no)
    FROM public.goodsreceived WHERE gr_no LIKE 'GLE%')
  = format('GLE1@%s 12:00 GLE2@%s 02:00 GLE3@%s 23:30 GLE4@%s 02:00 GLE5@%s 23:30',
           :'start_day', :'end_day', :'end_day', :'next_day', :'day_before'),
  'fixture receipts at the intended moments');

-- ---------------------------------------------------------------------------
-- Staff: the end day is in, the day after is out
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims', :'staff_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.gl_assert(warehouse_security.active_role() = 'staff', 'actual staff role');
-- Only this fixture's receipts match the customer filter used below (the end is a day past the
-- last receipt, so this holds with or without migration 55).
SELECT pg_temp.gl_assert(pg_temp.gl_figures(public.get_grn_list(:'day_before', (:'next_day'::date + 1), 'date', 'desc', 50, 0,
    jsonb_build_object('customer_ids', jsonb_build_array(:'quince')))) = '5/31',
  'the days around the filter hold exactly the five fixture receipts');
-- S..E, newest first: both end-day receipts in (before migration 55 only GLE1), GLE4 and GLE5 out.
SELECT pg_temp.gl_assert(pg_temp.gl_numbers(r) = ARRAY['GLE3', 'GLE2', 'GLE1'] AND pg_temp.gl_figures(r) = '3/7'
  AND r#>>'{data,pagination,total_count}' = '3',
  'staff, receipts S..E newest first, end day included, next day out: ' || r::text)
FROM (SELECT public.get_grn_list(:'start_day', :'end_day', 'date', 'desc', 50, 0,
  jsonb_build_object('customer_ids', jsonb_build_array(:'quince'))) AS r) answer;
-- The same filter in the other order and by receipt number.
SELECT pg_temp.gl_assert(pg_temp.gl_numbers(public.get_grn_list(:'start_day', :'end_day', 'date', 'asc', 50, 0,
      jsonb_build_object('customer_ids', jsonb_build_array(:'quince')))) = ARRAY['GLE1', 'GLE2', 'GLE3']
  AND pg_temp.gl_numbers(public.get_grn_list(:'start_day', :'end_day', 'gr_no', 'desc', 50, 0,
      jsonb_build_object('customer_ids', jsonb_build_array(:'quince')))) = ARRAY['GLE3', 'GLE2', 'GLE1'],
  'staff, receipts S..E oldest first and by number');
-- The end day alone: both of its receipts, 02:00 and 23:30.
SELECT pg_temp.gl_assert(pg_temp.gl_numbers(public.get_grn_list(:'end_day', :'end_day', 'date', 'desc', 50, 0,
      jsonb_build_object('customer_ids', jsonb_build_array(:'quince')))) = ARRAY['GLE3', 'GLE2'],
  'staff, receipts E..E: the whole end day');
-- The rows left out are real: a filter one day longer at either end takes them in.
SELECT pg_temp.gl_assert(pg_temp.gl_numbers(public.get_grn_list(:'start_day', :'next_day', 'date', 'desc', 50, 0,
      jsonb_build_object('customer_ids', jsonb_build_array(:'quince')))) = ARRAY['GLE4', 'GLE3', 'GLE2', 'GLE1']
  AND pg_temp.gl_numbers(public.get_grn_list(:'day_before', :'end_day', 'date', 'desc', 50, 0,
      jsonb_build_object('customer_ids', jsonb_build_array(:'quince')))) = ARRAY['GLE3', 'GLE2', 'GLE1', 'GLE5'],
  'staff, receipts S..E+1 and S-1..E');
-- One end only, and the receipt-number filter instead of a customer filter.
SELECT pg_temp.gl_assert(pg_temp.gl_numbers(public.get_grn_list(NULL, :'end_day', 'date', 'desc', 50, 0,
      jsonb_build_object('gr_no', 'GLE'))) = ARRAY['GLE3', 'GLE2', 'GLE1', 'GLE5']
  AND pg_temp.gl_numbers(public.get_grn_list(:'start_day', NULL, 'date', 'desc', 50, 0,
      jsonb_build_object('gr_no', 'GLE'))) = ARRAY['GLE4', 'GLE3', 'GLE2', 'GLE1'],
  'staff, receipts with only an end day (up to E) and only a start day (from S)');
-- Migration 87: a total weight above int4 is summed as numeric, not an overflow error.
-- One more receipt: 50000 bags of 50000 kg = 2500000000 kg (an int4 product would overflow).
SELECT pg_temp.gl_assert(public.save_grn(p_gr_no => 'GLEW1', p_date => (:'end_day'::date::text || 'T10:00:00+05:30')::timestamptz,
  p_customer_id => :'quince'::uuid, p_customer_name => 'GRN List Day Quince Cold', p_idempotency_key => 'grn-list-end-day-GLEW1',
  p_items => jsonb_build_array(jsonb_build_object('item_id', :'turmeric', 'item_name', 'GRN List Day Turmeric', 'packaging', 'Bag',
    'qty', 50000, 'weight', 50000)))->>'success' = 'true', 'fixture receipt GLEW1 with a huge weight');
SELECT pg_temp.gl_assert(r->>'success' = 'true'
  AND (SELECT (x->>'total_weight')::numeric FROM jsonb_array_elements(r#>'{data,grns}') x WHERE x->>'gr_no' = 'GLEW1') = 2500000000,
  'a receipt of 50000 x 50000 kg lists total_weight 2500000000: ' || r::text)
FROM (SELECT public.get_grn_list(:'end_day', :'end_day', 'date', 'desc', 50, 0,
  jsonb_build_object('gr_no', 'GLEW1')) AS r) answer;
-- The dispatch list sums the same way: a dispatch of the whole receipt weighs 2500000000 kg, not an overflow.
RESET ROLE;
SELECT id AS admin_profile FROM public.user_profiles WHERE mobile = '919888888561' \gset
SELECT id AS huge_lot FROM public.goodsreceived_trl WHERE gr_id = (SELECT id FROM public.goodsreceived WHERE gr_no = 'GLEW1') \gset
-- (A dispatch this size cannot be made through create_dispatch_with_stock_check: its figures stop with
-- "integer out of range". The rows are written directly with the triggers off,
-- because the point here is get_dispatch_list_with_items.)
SET LOCAL session_replication_role = replica;
INSERT INTO public.dispatch(disp_no, disp_date, customer_id, customer_name)
 VALUES ('GLEWD1', '2026-05-02', :'quince'::uuid, 'GRN List Day Quince Cold');
INSERT INTO public.dispatch_trl(gr_id, gr_trl_id, disp_id, disp_qty)
 SELECT t.gr_id, t.id, (SELECT id FROM public.dispatch WHERE disp_no = 'GLEWD1'), 50000
 FROM public.goodsreceived_trl t WHERE t.id = :'huge_lot'::uuid;
SET LOCAL session_replication_role = origin;
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.gl_assert(r->>'success' = 'true'
  AND (SELECT (x->>'total_weight')::numeric FROM jsonb_array_elements(r#>'{data,dispatches}') x WHERE x->>'disp_no' = 'GLEWD1') = 2500000000,
  'a dispatch of 50000 x 50000 kg lists total_weight 2500000000: ' || r::text)
FROM (SELECT public.get_dispatch_list_with_items(:'quince'::uuid, '{}'::jsonb, 'dispatch_date', 'desc', 1, 50, false) AS r) answer;
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Authorization is what it was: the list is for staff, a customer account is refused
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims', :'customer_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.gl_assert(warehouse_security.active_role() = 'customer', 'actual customer role');
SELECT pg_temp.gl_assert(r->>'success' = 'false' AND r#>>'{error,details}' = 'Staff access required' AND pg_temp.gl_numbers(r) = '{}',
  'a customer account was answered: ' || r::text)
FROM (SELECT public.get_grn_list(:'start_day', :'end_day', 'date', 'desc', 50, 0, '{}'::jsonb) AS r) answer;
RESET ROLE;
ROLLBACK;
SELECT 'grn list end day: the last day of the date filter is in get_grn_list, the day after is out' AS result;

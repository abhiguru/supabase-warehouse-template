-- Report periods include their last day (migration 54).
--
-- get_all_dispatch_activity, get_all_grn_activity, get_customer_grn_activity and
-- get_customer_invoice_summary compared the end day of the period (a date) with a timestamptz
-- column, which reads it as midnight at the start of that day: every row on the last day was
-- left out. Each receipt, dispatch and invoice below carries a quantity (or total) that is a
-- power of two, so every sum names exactly the rows it counted.
--
-- Days, with E the end day (three days ago) and S the start day (four days before E):
--   row    customer  moment (UTC)    qty   in the period S..E?
--   1      Juniper   S   12:00          1   yes, start day
--   2      Juniper   E   02:00          2   yes, end day (was left out)
--   3      Juniper   E   23:30          4   yes, end day (was left out)
--   4      Juniper   E+1 02:00          8   no, the day after
--   5      Juniper   S-1 23:30         16   no, the day before (start side, unchanged)
--   6      Laurel    E   23:30         32   yes, end day (was left out; Laurel was missing)
--   7      Laurel    E+1 00:30         64   no, the day after
-- Receipts EDR1..EDR7, dispatches EDD1..EDD7 (from two stock lots received ten days before S)
-- and one invoice per receipt, all at these moments. In the period: 4 rows, 39 in all
-- (Juniper 7, Laurel 32); before migration 54: 1 row, 1 in all, no Laurel.
--
-- A day here is a day in the session time zone, UTC (asserted below), not India's: migration 54
-- did not change the zone. If the zone is ever changed on purpose, these days move with it.
-- Runs ONLY in migrations.sh's fresh, network-disabled database. All fixture rows roll back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.td_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'report to date: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.td_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.td_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- One field of every element of a list, in the order the function returned them, for this
-- test's customers only, without the fixture prefix.
CREATE FUNCTION pg_temp.td_column(list jsonb, name_key text, value_key text) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(replace(x->>value_key, 'End Day Report ', '') ORDER BY ord), '{}')
  FROM jsonb_array_elements(list) WITH ORDINALITY AS t(x, ord) WHERE x->>name_key LIKE 'End Day Report %' $$;
-- "customer: total" for each customer of a by_customer list, in the returned order.
CREATE FUNCTION pg_temp.td_by_customer(list jsonb, total_key text) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(replace(x->>'customer_name', 'End Day Report ', '') || ': ' || (x->>total_key) ORDER BY ord), '{}')
  FROM jsonb_array_elements(list) WITH ORDINALITY AS t(x, ord) WHERE x->>'customer_name' LIKE 'End Day Report %' $$;
-- "day: count/total" for each element of a by_date list, in the returned order.
CREATE FUNCTION pg_temp.td_by_date(list jsonb, count_key text) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg((x->>'date') || ': ' || (x->>count_key) || '/' || (x->>'total_qty') ORDER BY ord), '{}')
  FROM jsonb_array_elements(list) WITH ORDINALITY AS t(x, ord) $$;
-- Document numbers of a row list (receipts EDR*), in the returned order.
CREATE FUNCTION pg_temp.td_numbers(list jsonb, number_key text) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(x->>number_key ORDER BY ord), '{}')
  FROM jsonb_array_elements(list) WITH ORDINALITY AS t(x, ord) WHERE x->>number_key LIKE 'EDR%' $$;
-- Summary figures as "count/total", from an answer's summary object.
CREATE FUNCTION pg_temp.td_figures(summary jsonb, count_key text, total_key text) RETURNS text LANGUAGE sql AS $$
  SELECT (summary->>count_key) || '/' || (summary->>total_key) $$;
-- True when the guard refuses the statement: a raw 42501, or, from the bodies whose catch-all
-- handler turns it into an answer, success = false carrying one of the guard's messages.
CREATE FUNCTION pg_temp.td_refused(statement text) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  EXECUTE statement INTO answer;
  RETURN answer->>'success' = 'false'
    AND COALESCE(answer->>'error', '') ~ '(Staff access required|Customer access denied|Active account required)';
EXCEPTION WHEN insufficient_privilege THEN RETURN true;
  WHEN OTHERS THEN RETURN false;
END $$;

SELECT pg_temp.td_assert(current_setting('TimeZone') = 'UTC', 'the session time zone is UTC, so a day below is a UTC day');

-- ---------------------------------------------------------------------------
-- The four functions: still single and guarded, no bare end-day comparison left
-- ---------------------------------------------------------------------------
SELECT pg_temp.td_assert(count(*) = 4
    AND bool_and(pg_get_functiondef(p.oid) ~ ('BEGIN\s+PERFORM warehouse_security\.authorize_rpc\(''' || p.proname || ''','))
    AND bool_and(p.prosecdef)
    AND bool_and(pg_get_functiondef(p.oid) !~ '(disp_date|\.date) <= p_to_date' AND pg_get_functiondef(p.oid) !~ 'BETWEEN v_from_date AND v_to_date')
    AND bool_and(pg_get_functiondef(p.oid) ~ '< (p_to_date|v_to_date) \+ 1'),
  'the four patched report functions are single, guarded, and end the period before the day after')
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
  AND p.proname IN ('get_all_dispatch_activity', 'get_all_grn_activity', 'get_customer_grn_activity', 'get_customer_invoice_summary');
-- The migration 52 order of the two all-customers lists survived the patch.
SELECT pg_temp.td_assert(count(*) = 2 AND bool_and(pg_get_functiondef(p.oid) LIKE '%::numeric END DESC NULLS LAST, customer_data->>''customer_name''%'),
  'the numeric customer order of migration 52 is still there')
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('get_all_dispatch_activity', 'get_all_grn_activity');

-- ---------------------------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------------------------
SELECT CURRENT_DATE - 3 AS end_day, CURRENT_DATE - 7 AS start_day, CURRENT_DATE - 2 AS next_day,
       CURRENT_DATE - 8 AS day_before, CURRENT_DATE - 17 AS stock_day \gset
INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888888541', 'End Day Report Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888888542', 'End Day Report Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888888543', 'End Day Report Customer', 'customer', true, 'approved');
SELECT id AS admin_profile FROM public.user_profiles WHERE mobile = '919888888541' \gset
SELECT pg_temp.td_login('9888888541') AS admin_claims \gset
SELECT pg_temp.td_login('9888888542') AS staff_claims \gset
SELECT pg_temp.td_login('9888888543') AS customer_claims \gset
INSERT INTO public.customers(name, mobile) VALUES ('End Day Report Juniper Cold', '9888888551') RETURNING id AS juniper \gset
INSERT INTO public.customers(name, mobile) VALUES ('End Day Report Laurel Agro', '9888888552') RETURNING id AS laurel \gset
INSERT INTO public.items(name, packaging) VALUES ('End Day Report Ginger', 'Bag') RETURNING id AS ginger \gset
-- The customer login is assigned to Juniper only.
INSERT INTO public.users_customers_new(user_profile_id, customer_id, active)
 SELECT id, :'juniper'::uuid, true FROM public.user_profiles WHERE mobile = '919888888543';
-- The dispatches: number, stock lot, day, time of day (UTC), quantity.
CREATE TEMP TABLE report_to_date_dispatches (disp_no text, gr_no text, day date, at text, qty integer);
INSERT INTO report_to_date_dispatches VALUES
  ('EDD1', 'EDS1', :'start_day', '12:00:00', 1),
  ('EDD2', 'EDS1', :'end_day', '02:00:00', 2),
  ('EDD3', 'EDS1', :'end_day', '23:30:00', 4),
  ('EDD4', 'EDS1', :'next_day', '02:00:00', 8),
  ('EDD5', 'EDS1', :'day_before', '23:30:00', 16),
  ('EDD6', 'EDS2', :'end_day', '23:30:00', 32),
  ('EDD7', 'EDS2', :'next_day', '00:30:00', 64);
GRANT SELECT ON report_to_date_dispatches TO authenticated;

SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
-- Nothing from another test lies in or around the period: every figure below is this fixture's.
SELECT pg_temp.td_assert(pg_temp.td_figures(public.get_all_grn_activity(:'day_before', :'next_day')->'summary', 'total_grns', 'total_quantity') = '0/0'
  AND pg_temp.td_figures(public.get_all_dispatch_activity(:'day_before', :'next_day')->'summary', 'total_dispatches', 'total_quantity') = '0/0'
  AND pg_temp.td_figures(public.get_customer_grn_activity(NULL, :'day_before', :'next_day')#>'{data,summary}', 'total_grns', 'total_quantity') = '0/0'
  AND pg_temp.td_figures(public.get_customer_invoice_summary(NULL, :'day_before', :'next_day')#>'{data,summary}', 'total_invoices', 'total_amount') = '0/0',
  'the period and the days around it are empty before the fixture');
SELECT pg_temp.td_assert(public.save_grn(p_gr_no => r.gr_no, p_date => (r.day::text || 'T' || r.at || 'Z')::timestamptz,
  p_customer_id => r.customer, p_customer_name => r.customer_name, p_idempotency_key => 'report-to-date-' || r.gr_no,
  p_items => jsonb_build_array(jsonb_build_object('item_id', :'ginger', 'item_name', 'End Day Report Ginger', 'packaging', 'Bag',
    'qty', r.qty, 'weight', 5)))->>'success' = 'true', 'fixture receipt ' || r.gr_no)
FROM (VALUES
  ('EDS1', :'stock_day'::date, '12:00:00', :'juniper'::uuid, 'End Day Report Juniper Cold', 100),
  ('EDS2', :'stock_day'::date, '12:00:00', :'laurel'::uuid, 'End Day Report Laurel Agro', 100),
  ('EDR1', :'start_day'::date, '12:00:00', :'juniper'::uuid, 'End Day Report Juniper Cold', 1),
  ('EDR2', :'end_day'::date, '02:00:00', :'juniper'::uuid, 'End Day Report Juniper Cold', 2),
  ('EDR3', :'end_day'::date, '23:30:00', :'juniper'::uuid, 'End Day Report Juniper Cold', 4),
  ('EDR4', :'next_day'::date, '02:00:00', :'juniper'::uuid, 'End Day Report Juniper Cold', 8),
  ('EDR5', :'day_before'::date, '23:30:00', :'juniper'::uuid, 'End Day Report Juniper Cold', 16),
  ('EDR6', :'end_day'::date, '23:30:00', :'laurel'::uuid, 'End Day Report Laurel Agro', 32),
  ('EDR7', :'next_day'::date, '00:30:00', :'laurel'::uuid, 'End Day Report Laurel Agro', 64)
) AS r(gr_no, day, at, customer, customer_name, qty);
-- create_dispatch_with_stock_check stores a dispatch at the start of its date (date::timestamptz),
-- which the old end-day comparison happened to include. A dispatch with a time of day (another
-- write path, or data from before) was left out, so the dispatches are moved to their moments
-- below, as the owner of the tables.
SELECT pg_temp.td_assert(public.create_dispatch_with_stock_check(jsonb_build_object('disp_no', d.disp_no,
    'disp_date', d.day::text, 'customer_id', g.customer_id, 'customer_name', g.customer_name,
    'supervisor_id', :'admin_profile', 'supervisor_name', 'End Day Report Administrator'),
  ARRAY[jsonb_build_object('gr_trl_id', t.id, 'disp_qty', d.qty)], 0, 'report-to-date-' || d.disp_no)->>'success' = 'true',
  'fixture dispatch ' || d.disp_no)
FROM report_to_date_dispatches d
JOIN public.goodsreceived g ON g.gr_no = d.gr_no JOIN public.goodsreceived_trl t ON t.gr_id = g.id;
RESET ROLE;
UPDATE public.dispatch SET disp_date = (d.day::text || 'T' || d.at || 'Z')::timestamptz
 FROM report_to_date_dispatches d WHERE public.dispatch.disp_no = d.disp_no;
-- One invoice per receipt EDR1..EDR7, dated at the receipt's moment, total = its quantity.
-- Written directly, as tests/list_search.sql does: only the dates matter here.
INSERT INTO public.invoice(inv_fin_year, inv_no, gr_id, gr_no, customer_id, customer_name, inv_date, total)
 SELECT 2026, 9100 + substr(g.gr_no, 4)::integer, g.id, g.gr_no, g.customer_id, g.customer_name, g.date, t.qty
 FROM public.goodsreceived g JOIN public.goodsreceived_trl t ON t.gr_id = g.id WHERE g.gr_no LIKE 'EDR%';
SELECT pg_temp.td_assert((SELECT count(*) FROM public.invoice WHERE gr_no LIKE 'EDR%') = 7
  AND (SELECT string_agg(disp_no || '@' || to_char(disp_date AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || '/' || t.disp_qty, ' ' ORDER BY disp_no)
       FROM public.dispatch d JOIN public.dispatch_trl t ON t.disp_id = d.id WHERE disp_no LIKE 'EDD%')
    = format('EDD1@%s 12:00/1 EDD2@%s 02:00/2 EDD3@%s 23:30/4 EDD4@%s 02:00/8 EDD5@%s 23:30/16 EDD6@%s 23:30/32 EDD7@%s 00:30/64',
             :'start_day', :'end_day', :'end_day', :'next_day', :'day_before', :'end_day', :'next_day')
  AND (SELECT string_agg(gr_no || '@' || to_char(date AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'), ' ' ORDER BY gr_no) FROM public.goodsreceived WHERE gr_no LIKE 'EDR%')
    = format('EDR1@%s 12:00 EDR2@%s 02:00 EDR3@%s 23:30 EDR4@%s 02:00 EDR5@%s 23:30 EDR6@%s 23:30 EDR7@%s 00:30',
             :'start_day', :'end_day', :'end_day', :'next_day', :'day_before', :'end_day', :'next_day'),
  'fixture rows at the intended moments');

SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
-- ---------------------------------------------------------------------------
-- get_all_grn_activity
-- ---------------------------------------------------------------------------
SELECT pg_temp.td_assert(pg_temp.td_figures(r->'summary', 'total_grns', 'total_quantity') = '4/39'
  AND (r#>>'{summary,total_customers}')::integer = 2 AND r#>>'{summary,to_date}' = :'end_day',
  'receipt activity S..E: both end-day receipts in, the next day out: ' || (r->'summary')::text)
FROM (SELECT public.get_all_grn_activity(:'start_day', :'end_day') AS r) answer;
SELECT pg_temp.td_assert(pg_temp.td_by_customer(r->'by_customer', 'total_qty') = ARRAY['Laurel Agro: 32', 'Juniper Cold: 7'],
  'receipt activity S..E by customer: ' || (r->'by_customer')::text)
FROM (SELECT public.get_all_grn_activity(:'start_day', :'end_day') AS r) answer;
SELECT pg_temp.td_assert(pg_temp.td_by_date(r->'by_date', 'grn_count') = ARRAY[:'end_day' || ': 3/38', :'start_day' || ': 1/1'],
  'receipt activity S..E by day: ' || (r->'by_date')::text)
FROM (SELECT public.get_all_grn_activity(:'start_day', :'end_day') AS r) answer;
-- The rows left out are real: a period one day longer at either end takes them in.
SELECT pg_temp.td_assert(pg_temp.td_figures(public.get_all_grn_activity(:'start_day', :'next_day')->'summary', 'total_grns', 'total_quantity') = '6/111'
  AND pg_temp.td_figures(public.get_all_grn_activity(:'day_before', :'end_day')->'summary', 'total_grns', 'total_quantity') = '5/55',
  'receipt activity S..E+1 and S-1..E');
-- A period of the end day alone.
SELECT pg_temp.td_assert(pg_temp.td_figures(public.get_all_grn_activity(:'end_day', :'end_day')->'summary', 'total_grns', 'total_quantity') = '3/38',
  'receipt activity E..E: the whole end day');

-- ---------------------------------------------------------------------------
-- get_all_dispatch_activity
-- ---------------------------------------------------------------------------
SELECT pg_temp.td_assert(pg_temp.td_figures(r->'summary', 'total_dispatches', 'total_quantity') = '4/39'
  AND (r#>>'{summary,total_customers}')::integer = 2 AND r#>>'{summary,to_date}' = :'end_day',
  'dispatch activity S..E: both end-day dispatches in, the next day out: ' || (r->'summary')::text)
FROM (SELECT public.get_all_dispatch_activity(:'start_day', :'end_day') AS r) answer;
SELECT pg_temp.td_assert(pg_temp.td_by_customer(r->'by_customer', 'total_qty') = ARRAY['Laurel Agro: 32', 'Juniper Cold: 7'],
  'dispatch activity S..E by customer: ' || (r->'by_customer')::text)
FROM (SELECT public.get_all_dispatch_activity(:'start_day', :'end_day') AS r) answer;
SELECT pg_temp.td_assert(pg_temp.td_by_date(r->'by_date', 'dispatch_count') = ARRAY[:'end_day' || ': 3/38', :'start_day' || ': 1/1'],
  'dispatch activity S..E by day: ' || (r->'by_date')::text)
FROM (SELECT public.get_all_dispatch_activity(:'start_day', :'end_day') AS r) answer;
SELECT pg_temp.td_assert(pg_temp.td_figures(public.get_all_dispatch_activity(:'start_day', :'next_day')->'summary', 'total_dispatches', 'total_quantity') = '6/111'
  AND pg_temp.td_figures(public.get_all_dispatch_activity(:'day_before', :'end_day')->'summary', 'total_dispatches', 'total_quantity') = '5/55'
  AND pg_temp.td_figures(public.get_all_dispatch_activity(:'end_day', :'end_day')->'summary', 'total_dispatches', 'total_quantity') = '3/38',
  'dispatch activity S..E+1, S-1..E and E..E');

-- ---------------------------------------------------------------------------
-- get_customer_grn_activity: one customer (the receipt list) and all customers
-- ---------------------------------------------------------------------------
SELECT pg_temp.td_assert(pg_temp.td_numbers(r#>'{data,grns}', 'gr_no') = ARRAY['EDR3', 'EDR2', 'EDR1']
  AND pg_temp.td_figures(r#>'{data,summary}', 'total_grns', 'total_quantity') = '3/7' AND r#>>'{metadata,to_date}' = :'end_day',
  'Juniper receipts S..E, newest first: ' || r::text)
FROM (SELECT public.get_customer_grn_activity(:'juniper'::uuid, :'start_day', :'end_day') AS r) answer;
SELECT pg_temp.td_assert(pg_temp.td_numbers(public.get_customer_grn_activity(:'juniper'::uuid, :'start_day', :'next_day')#>'{data,grns}', 'gr_no') = ARRAY['EDR4', 'EDR3', 'EDR2', 'EDR1']
  AND pg_temp.td_numbers(public.get_customer_grn_activity(:'juniper'::uuid, :'day_before', :'end_day')#>'{data,grns}', 'gr_no') = ARRAY['EDR3', 'EDR2', 'EDR1', 'EDR5']
  AND pg_temp.td_numbers(public.get_customer_grn_activity(:'laurel'::uuid, :'start_day', :'end_day')#>'{data,grns}', 'gr_no') = ARRAY['EDR6'],
  'Juniper receipts S..E+1 and S-1..E; Laurel S..E');
SELECT pg_temp.td_assert(pg_temp.td_figures(r#>'{data,summary}', 'total_grns', 'total_quantity') = '4/39'
  AND (r#>>'{data,summary,total_customers}')::integer = 2
  AND pg_temp.td_by_customer(r#>'{data,by_customer}', 'grn_count') = ARRAY['Juniper Cold: 3', 'Laurel Agro: 1']
  AND pg_temp.td_by_customer(r#>'{data,by_customer}', 'total_quantity') = ARRAY['Juniper Cold: 7', 'Laurel Agro: 32'],
  'all customers receipts S..E: ' || r::text)
FROM (SELECT public.get_customer_grn_activity(NULL, :'start_day', :'end_day') AS r) answer;
SELECT pg_temp.td_assert(pg_temp.td_figures(public.get_customer_grn_activity(NULL, :'start_day', :'next_day')#>'{data,summary}', 'total_grns', 'total_quantity') = '6/111',
  'all customers receipts S..E+1');

-- ---------------------------------------------------------------------------
-- get_customer_invoice_summary: one customer (the invoice list) and all customers
-- ---------------------------------------------------------------------------
SELECT pg_temp.td_assert(pg_temp.td_numbers(r#>'{data,invoices}', 'grn_ref') = ARRAY['EDR3', 'EDR2', 'EDR1']
  AND pg_temp.td_figures(r#>'{data,summary}', 'total_invoices', 'total_amount') = '3/7.00' AND r#>>'{metadata,to_date}' = :'end_day',
  'Juniper invoices S..E, newest first: ' || r::text)
FROM (SELECT public.get_customer_invoice_summary(:'juniper'::uuid, :'start_day', :'end_day') AS r) answer;
SELECT pg_temp.td_assert(pg_temp.td_numbers(public.get_customer_invoice_summary(:'juniper'::uuid, :'start_day', :'next_day')#>'{data,invoices}', 'grn_ref') = ARRAY['EDR4', 'EDR3', 'EDR2', 'EDR1']
  AND pg_temp.td_numbers(public.get_customer_invoice_summary(:'juniper'::uuid, :'day_before', :'end_day')#>'{data,invoices}', 'grn_ref') = ARRAY['EDR3', 'EDR2', 'EDR1', 'EDR5'],
  'Juniper invoices S..E+1 and S-1..E');
SELECT pg_temp.td_assert(pg_temp.td_figures(r#>'{data,summary}', 'total_invoices', 'total_amount') = '4/39.00'
  AND (r#>>'{data,summary,total_customers}')::integer = 2
  AND pg_temp.td_by_customer(r#>'{data,by_customer}', 'total_amount') = ARRAY['Laurel Agro: 32.00', 'Juniper Cold: 7.00']
  AND (SELECT sum((m->>'invoice_count')::integer) FROM jsonb_array_elements(r#>'{data,by_month}') m) = 4,
  'all customers invoices S..E: ' || r::text)
FROM (SELECT public.get_customer_invoice_summary(NULL, :'start_day', :'end_day') AS r) answer;
SELECT pg_temp.td_assert(pg_temp.td_figures(public.get_customer_invoice_summary(NULL, :'start_day', :'next_day')#>'{data,summary}', 'total_invoices', 'total_amount') = '6/111.00',
  'all customers invoices S..E+1');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Authorization is what it was
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims', :'staff_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.td_assert(warehouse_security.active_role() = 'staff', 'actual staff role');
SELECT pg_temp.td_assert(r->>'success' = 'true' AND pg_temp.td_figures(r->'summary', 'total_dispatches', 'total_quantity') = '4/39'
  AND pg_temp.td_by_customer(r->'by_customer', 'total_qty') = ARRAY['Laurel Agro: 32', 'Juniper Cold: 7'],
  'staff run the all-customers dispatch activity, end day included: ' || r::text)
FROM (SELECT public.get_all_dispatch_activity(:'start_day', :'end_day') AS r) answer;
RESET ROLE;

SELECT set_config('request.jwt.claims', :'customer_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.td_assert(warehouse_security.active_role() = 'customer', 'actual customer role');
-- Its own customer, end day included.
SELECT pg_temp.td_assert(r->>'success' = 'true' AND pg_temp.td_numbers(r#>'{data,grns}', 'gr_no') = ARRAY['EDR3', 'EDR2', 'EDR1'],
  'customer account, own customer receipts S..E: ' || r::text)
FROM (SELECT public.get_customer_grn_activity(:'juniper'::uuid, :'start_day', :'end_day') AS r) answer;
SELECT pg_temp.td_assert(pg_temp.td_refused(format(s.statement, :'start_day', :'end_day', :'laurel')), 'a customer account was answered: ' || s.statement)
FROM (VALUES
  ('SELECT public.get_all_dispatch_activity(%L::date, %L::date)'),
  ('SELECT public.get_all_grn_activity(%L::date, %L::date)'),
  ('SELECT public.get_customer_grn_activity(NULL, %L::date, %L::date)'),
  ('SELECT public.get_customer_invoice_summary(NULL, %L::date, %L::date)'),
  ('SELECT public.get_customer_grn_activity(%3$L::uuid, %1$L::date, %2$L::date)'),
  ('SELECT public.get_customer_invoice_summary(%3$L::uuid, %1$L::date, %2$L::date)')
) AS s(statement);
-- The refusal helper can tell an answer from a refusal.
SELECT pg_temp.td_assert(NOT pg_temp.td_refused(format('SELECT public.get_customer_grn_activity(%L::uuid, %L::date, %L::date)', :'juniper', :'start_day', :'end_day')),
  'the refusal check itself answers false for an allowed call');
RESET ROLE;
ROLLBACK;
SELECT 'report to date: the last day of a period is in the four report RPCs, the day after is out, and authorization is unchanged' AS result;

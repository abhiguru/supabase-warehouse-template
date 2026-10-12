-- Report days follow India's calendar (migration 56).
--
-- The eight report functions and get_grn_list cut their days in the session time zone (UTC on
-- this image), so activity between 00:00 and 05:30 in India counted against the day before and a
-- period took in the first 5.5 hours after its last day. Each receipt below carries a quantity
-- that is a power of two, its dispatch ten times that, and its invoice the receipt quantity as its
-- total, so every sum names exactly the rows it counted.
--
--   row  moment (UTC)          in India              qty  India day  UTC day (before 56)
--   1    2026-10-09 18:29:59   09 Oct 23:59:59         1  9 Oct      9 Oct
--   2    2026-10-09 18:30:00   10 Oct 00:00:00         2  10 Oct     9 Oct
--   3    2026-10-11 20:00:00   12 Oct 01:30            4  12 Oct     11 Oct
--   4    2026-10-12 18:00:00   12 Oct 23:30            8  12 Oct     12 Oct
--   5    2026-10-12 18:45:00   13 Oct 00:15           16  13 Oct     12 Oct
--   6    2026-10-12 18:30:00   13 Oct 00:00:00        32  13 Oct     12 Oct
--   7    2026-09-30 19:00:00   01 Oct 00:30           64  1 Oct      30 Sep
--   8    2026-09-30 18:00:00   30 Sep 23:30          128  30 Sep     30 Sep
-- Receipts ISR1..ISR8 (customer Saffron), dispatches ISD1..ISD8 from one stock lot ISS1 of 3000
-- received on 14 Aug, and one invoice per receipt, all at these moments.
--
-- Periods, India days (before migration 56 in brackets):
--   12..12   rows 3, 4        2 / 12    [4, 5, 6: 3 / 56]
--   10..12   rows 2, 3, 4     3 / 14    [3, 4, 5, 6: 4 / 60]
--   13..13   rows 5, 6        2 / 48    [none]
--   9..9     row 1            1 / 1     [1, 2: 2 / 3]
--   Sep..Oct all, by month    2026-10: 7 / 127, 2026-09: 1 / 128    [6 / 63, 2 / 192]
--
-- The session time zone is UTC (asserted), so the old functions would cut UTC days; the answers
-- are also checked once with the session in another zone, where they must not move.
-- Runs ONLY in migrations.sh's fresh, network-disabled database. All fixture rows roll back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.ist_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'report ist day: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.ist_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.ist_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- "count/total" from two keys of an object.
CREATE FUNCTION pg_temp.ist_figures(o jsonb, count_key text, total_key text) RETURNS text LANGUAGE sql AS $$
  SELECT (o->>count_key) || '/' || (o->>total_key) $$;
-- One field of every element of a list, in the returned order, for elements whose filter key
-- starts with the prefix (NULL: all elements).
CREATE FUNCTION pg_temp.ist_column(list jsonb, value_key text, filter_key text DEFAULT NULL, prefix text DEFAULT NULL) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(x->>value_key ORDER BY ord), '{}')
  FROM jsonb_array_elements(list) WITH ORDINALITY AS t(x, ord)
  WHERE filter_key IS NULL OR x->>filter_key LIKE prefix || '%' $$;
-- "key: a/b" for each element of a list, in the returned order.
CREATE FUNCTION pg_temp.ist_keyed(list jsonb, key_name text, a text, b text) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg((x->>key_name) || ': ' || (x->>a) || '/' || (x->>b) ORDER BY ord), '{}')
  FROM jsonb_array_elements(list) WITH ORDINALITY AS t(x, ord) $$;
-- The same, sorted by key (for lists the function does not order).
CREATE FUNCTION pg_temp.ist_keyed_sorted(list jsonb, key_name text, a text, b text) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg((x->>key_name) || ': ' || (x->>a) || '/' || (x->>b) ORDER BY x->>key_name DESC), '{}')
  FROM jsonb_array_elements(list) AS t(x) $$;
-- The element of a list whose key_name starts with the prefix (exactly one expected).
CREATE FUNCTION pg_temp.ist_element(list jsonb, key_name text, prefix text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT CASE WHEN count(*) = 1 THEN min(x::text)::jsonb END
  FROM jsonb_array_elements(list) AS t(x) WHERE x->>key_name LIKE prefix || '%' $$;
-- True when the guard refuses the statement: a raw 42501, or, from the bodies whose catch-all
-- handler turns it into an answer, success = false carrying one of the guard's messages.
CREATE FUNCTION pg_temp.ist_refused(statement text) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  EXECUTE statement INTO answer;
  RETURN answer->>'success' = 'false'
    AND COALESCE(answer->>'error', '') ~ '(Staff access required|Customer access denied|Active account required|Access denied)';
EXCEPTION WHEN insufficient_privilege THEN RETURN true;
  WHEN OTHERS THEN RETURN false;
END $$;
-- The plan of a statement, as one text.
CREATE FUNCTION pg_temp.ist_plan(statement text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE line text; plan text := '';
BEGIN
  FOR line IN EXECUTE 'EXPLAIN (COSTS OFF) ' || statement LOOP plan := plan || line || E'\n'; END LOOP;
  RETURN plan;
END $$;

SELECT pg_temp.ist_assert(current_setting('TimeZone') = 'UTC', 'the session time zone is UTC, so an unconverted day below would be a UTC day');

-- ---------------------------------------------------------------------------
-- The day helpers
-- ---------------------------------------------------------------------------
SELECT pg_temp.ist_assert(warehouse_security.business_day_start('2026-10-12') = '2026-10-11T18:30:00Z'
  AND warehouse_security.business_day_start('2026-04-01') = '2026-03-31T18:30:00Z',
  'a day in India starts at 18:30 UTC the day before');
-- business_day_start is the inverse of migration 41's business_date, every day of two years.
SELECT pg_temp.ist_assert(bool_and(warehouse_security.business_date(warehouse_security.business_day_start(d)) = d
    AND warehouse_security.business_date(warehouse_security.business_day_start(d) - interval '1 microsecond') = d - 1),
  'business_day_start and business_date agree on every day')
FROM generate_series('2026-01-01'::date, '2027-12-31'::date, interval '1 day') AS s(t) CROSS JOIN LATERAL (SELECT t::date AS d) day;
-- Private, like business_date; inlined (no SET clause), so a period compares the column with
-- constants and the index on the column serves it.
SELECT pg_temp.ist_assert(p.proconfig IS NULL AND NOT p.prosecdef AND p.provolatile = 's'
    AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE'),
  'business_day_start is private, inlinable and not SECURITY DEFINER')
FROM pg_proc p WHERE p.oid = 'warehouse_security.business_day_start(date)'::regprocedure;
SET LOCAL enable_seqscan = off;
-- (The receipt query is ordered by date so that, on the near-empty table, the planner picks the
-- date index rather than another partial index of the same size.)
SELECT pg_temp.ist_assert(plan ~ 'idx_goodsreceived_date_active' AND plan ~ 'Index Cond: \(\(date >= ''2026-10-09 18:30:00\+00''::timestamp with time zone\) AND \(date < ''2026-10-12 18:30:00\+00''',
  'a period on goodsreceived.date is an index condition on two constants: ' || plan)
FROM (SELECT pg_temp.ist_plan($q$SELECT id FROM public.goodsreceived WHERE deleted_at IS NULL
  AND date >= warehouse_security.business_day_start('2026-10-10') AND date < warehouse_security.business_day_start(date '2026-10-12' + 1)
  ORDER BY date DESC$q$) AS plan) p;
SELECT pg_temp.ist_assert(plan ~ 'idx_dispatch_disp_date' AND plan ~ 'Index Cond: \(\(disp_date >= ''2026-10-09 18:30:00\+00''',
  'a period on dispatch.disp_date uses its index: ' || plan)
FROM (SELECT pg_temp.ist_plan($q$SELECT id FROM public.dispatch
  WHERE disp_date >= warehouse_security.business_day_start('2026-10-10') AND disp_date < warehouse_security.business_day_start(date '2026-10-12' + 1)$q$) AS plan) p;
SELECT pg_temp.ist_assert(plan ~ 'idx_invoice_inv_date' AND plan ~ 'Index Cond: \(\(inv_date >= ''2026-10-09 18:30:00\+00''',
  'a period on invoice.inv_date uses its index: ' || plan)
FROM (SELECT pg_temp.ist_plan($q$SELECT id FROM public.invoice
  WHERE inv_date >= warehouse_security.business_day_start('2026-10-10') AND inv_date < warehouse_security.business_day_start(date '2026-10-12' + 1)$q$) AS plan) p;
SET LOCAL enable_seqscan = on;

-- ---------------------------------------------------------------------------
-- The nine functions: still single and guarded, and no UTC day cut left
-- ---------------------------------------------------------------------------
SELECT pg_temp.ist_assert(count(*) = 9
    AND bool_and(p.prosecdef)
    AND bool_and(pg_get_functiondef(p.oid) ~ ('BEGIN\s+PERFORM warehouse_security\.authorize_rpc\(''' || p.proname || ''','))
    AND bool_and(pg_get_functiondef(p.oid) LIKE '%warehouse_security.business_day_start(%')
    AND NOT bool_or(pg_get_functiondef(p.oid) ~* 'CURRENT_DATE')
    AND NOT bool_or(pg_get_functiondef(p.oid) ~ '(disp_date|inv_date|[ .(]date)::date')
    AND NOT bool_or(pg_get_functiondef(p.oid) ~ '(date|disp_date|inv_date) (>=|<=|<|>) (p_from_date|p_to_date|v_from_date|v_to_date)')
    AND NOT bool_or(pg_get_functiondef(p.oid) ~ 'BETWEEN p_from_date AND p_to_date')
    AND NOT bool_or(pg_get_functiondef(p.oid) ~* '(date_trunc\(''month'', (gr\.date|d\.disp_date|inv_date)\)|to_char\((invoice_date|inv_date),)')
    AND bool_and(pg_get_functiondef(p.oid) NOT LIKE '%format(''gr.date >= %L'', p_date_from)%')
    AND bool_and(pg_get_functiondef(p.oid) NOT LIKE '%format(''gr.date < %L'', p_date_to + 1)%'),
  'the nine functions are single, guarded, cut India days, and keep no session-zone day or CURRENT_DATE')
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
  AND p.proname IN ('get_all_dispatch_activity', 'get_all_grn_activity', 'get_all_customer_activity_summary',
    'get_customer_dispatch_activity', 'get_customer_grn_activity', 'get_customer_activity_detail',
    'get_customer_invoice_summary', 'get_operations_dashboard', 'get_grn_list');
-- Earlier patches survived: migration 52's numeric customer order, the receipt list's sort key.
SELECT pg_temp.ist_assert(count(*) = 2 AND bool_and(pg_get_functiondef(p.oid) LIKE '%::numeric END DESC NULLS LAST, customer_data->>''customer_name''%'),
  'the numeric customer order of migration 52 is still there')
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('get_all_dispatch_activity', 'get_all_grn_activity');
SELECT pg_temp.ist_assert(pg_get_functiondef('public.get_grn_list(date,date,text,text,integer,integer,jsonb)'::regprocedure)
  LIKE '%warehouse_security.document_number_sort_key(ga.gr_no)%', 'the receipt list still sorts by document key');

-- ---------------------------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------------------------
INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888888581', 'IST Day Report Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888888582', 'IST Day Report Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888888583', 'IST Day Report Customer', 'customer', true, 'approved');
SELECT id AS admin_profile FROM public.user_profiles WHERE mobile = '919888888581' \gset
SELECT pg_temp.ist_login('9888888581') AS admin_claims \gset
SELECT pg_temp.ist_login('9888888582') AS staff_claims \gset
SELECT pg_temp.ist_login('9888888583') AS customer_claims \gset
INSERT INTO public.customers(name, mobile) VALUES ('IST Day Report Saffron Cold', '9888888591') RETURNING id AS saffron \gset
INSERT INTO public.customers(name, mobile) VALUES ('IST Day Report Tamarind Agro', '9888888592') RETURNING id AS tamarind \gset
INSERT INTO public.items(name, packaging) VALUES ('IST Day Report Cardamom', 'Bag') RETURNING id AS cardamom \gset
-- The customer login is assigned to Saffron only.
INSERT INTO public.users_customers_new(user_profile_id, customer_id, active)
 SELECT id, :'saffron'::uuid, true FROM public.user_profiles WHERE mobile = '919888888583';
CREATE TEMP TABLE report_ist_day_rows (n integer, at timestamptz, qty integer);
INSERT INTO report_ist_day_rows VALUES
  (1, '2026-10-09T18:29:59Z', 1), (2, '2026-10-09T18:30:00Z', 2), (3, '2026-10-11T20:00:00Z', 4),
  (4, '2026-10-12T18:00:00Z', 8), (5, '2026-10-12T18:45:00Z', 16), (6, '2026-10-12T18:30:00Z', 32),
  (7, '2026-09-30T19:00:00Z', 64), (8, '2026-09-30T18:00:00Z', 128);
GRANT SELECT ON report_ist_day_rows TO authenticated;

SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
-- Nothing from another test lies in or around the periods: every figure below is this fixture's.
SELECT pg_temp.ist_assert(pg_temp.ist_figures(public.get_all_grn_activity('2026-08-01', '2026-11-30')->'summary', 'total_grns', 'total_quantity') = '0/0'
  AND pg_temp.ist_figures(public.get_all_dispatch_activity('2026-08-01', '2026-11-30')->'summary', 'total_dispatches', 'total_quantity') = '0/0'
  AND pg_temp.ist_figures(public.get_customer_invoice_summary(NULL, '2026-08-01', '2026-11-30')#>'{data,summary}', 'total_invoices', 'total_amount') = '0/0',
  'the months around the fixture are empty before it');
SELECT pg_temp.ist_assert(public.save_grn(p_gr_no => r.gr_no, p_date => r.at,
  p_customer_id => :'saffron'::uuid, p_customer_name => 'IST Day Report Saffron Cold', p_idempotency_key => 'report-ist-day-' || r.gr_no,
  p_items => jsonb_build_array(jsonb_build_object('item_id', :'cardamom', 'item_name', 'IST Day Report Cardamom', 'packaging', 'Bag',
    'qty', r.qty, 'weight', 5)))->>'success' = 'true', 'fixture receipt ' || r.gr_no)
FROM (SELECT 'ISS1' AS gr_no, '2026-08-14T12:00:00Z'::timestamptz AS at, 3000 AS qty
      UNION ALL SELECT 'ISR' || n, at, qty FROM report_ist_day_rows) AS r;
-- Dispatches from the stock lot, then moved to their moments as the owner of the table (the
-- dispatch RPC stores the start of its date).
SELECT pg_temp.ist_assert(public.create_dispatch_with_stock_check(jsonb_build_object('disp_no', 'ISD' || r.n,
    'disp_date', (r.at AT TIME ZONE 'UTC')::date::text, 'customer_id', :'saffron', 'customer_name', 'IST Day Report Saffron Cold',
    'supervisor_id', :'admin_profile', 'supervisor_name', 'IST Day Report Administrator'),
  ARRAY[jsonb_build_object('gr_trl_id', t.id, 'disp_qty', 10 * r.qty)], 0, 'report-ist-day-ISD' || r.n)->>'success' = 'true',
  'fixture dispatch ISD' || r.n)
FROM report_ist_day_rows r
CROSS JOIN public.goodsreceived g JOIN public.goodsreceived_trl t ON t.gr_id = g.id WHERE g.gr_no = 'ISS1';
RESET ROLE;
UPDATE public.dispatch SET disp_date = r.at FROM report_ist_day_rows r WHERE public.dispatch.disp_no = 'ISD' || r.n;
-- One invoice per receipt, dated at the receipt's moment, total = its quantity. Written directly,
-- as tests/report_to_date.sql does: only the dates and totals matter here.
INSERT INTO public.invoice(inv_fin_year, inv_no, gr_id, gr_no, customer_id, customer_name, inv_date, total)
 SELECT 2026, 9300 + substr(g.gr_no, 4)::integer, g.id, g.gr_no, g.customer_id, g.customer_name, g.date, t.qty
 FROM public.goodsreceived g JOIN public.goodsreceived_trl t ON t.gr_id = g.id WHERE g.gr_no LIKE 'ISR%';
SELECT pg_temp.ist_assert(
  (SELECT string_agg(gr_no || '@' || to_char(date AT TIME ZONE 'UTC', 'MM-DD HH24:MI:SS'), ' ' ORDER BY gr_no) FROM public.goodsreceived WHERE gr_no LIKE 'ISR%')
    = 'ISR1@10-09 18:29:59 ISR2@10-09 18:30:00 ISR3@10-11 20:00:00 ISR4@10-12 18:00:00 ISR5@10-12 18:45:00 ISR6@10-12 18:30:00 ISR7@09-30 19:00:00 ISR8@09-30 18:00:00'
  AND (SELECT string_agg(disp_no || '@' || to_char(disp_date AT TIME ZONE 'UTC', 'MM-DD HH24:MI:SS') || '/' || t.disp_qty, ' ' ORDER BY disp_no)
       FROM public.dispatch d JOIN public.dispatch_trl t ON t.disp_id = d.id WHERE disp_no LIKE 'ISD%')
    = 'ISD1@10-09 18:29:59/10 ISD2@10-09 18:30:00/20 ISD3@10-11 20:00:00/40 ISD4@10-12 18:00:00/80 ISD5@10-12 18:45:00/160 ISD6@10-12 18:30:00/320 ISD7@09-30 19:00:00/640 ISD8@09-30 18:00:00/1280'
  AND (SELECT string_agg(gr_no || '@' || to_char(inv_date AT TIME ZONE 'UTC', 'MM-DD HH24:MI:SS') || '/' || total, ' ' ORDER BY gr_no) FROM public.invoice WHERE gr_no LIKE 'ISR%')
    = 'ISR1@10-09 18:29:59/1.00 ISR2@10-09 18:30:00/2.00 ISR3@10-11 20:00:00/4.00 ISR4@10-12 18:00:00/8.00 ISR5@10-12 18:45:00/16.00 ISR6@10-12 18:30:00/32.00 ISR7@09-30 19:00:00/64.00 ISR8@09-30 18:00:00/128.00',
  'fixture rows at the intended moments');

SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
-- ---------------------------------------------------------------------------
-- get_all_grn_activity
-- ---------------------------------------------------------------------------
-- A period ending on the 12th: 01:30 and 23:30 on the 12th in, 00:00 and 00:15 on the 13th out.
SELECT pg_temp.ist_assert(pg_temp.ist_figures(r->'summary', 'total_grns', 'total_quantity') = '2/12'
  AND pg_temp.ist_keyed(r->'by_date', 'date', 'grn_count', 'total_qty') = ARRAY['2026-10-12: 2/12'],
  'receipt activity 12..12: ' || r::text)
FROM (SELECT public.get_all_grn_activity('2026-10-12', '2026-10-12') AS r) answer;
SELECT pg_temp.ist_assert(pg_temp.ist_figures(r->'summary', 'total_grns', 'total_quantity') = '3/14'
  AND pg_temp.ist_keyed(r->'by_date', 'date', 'grn_count', 'total_qty') = ARRAY['2026-10-12: 2/12', '2026-10-10: 1/2']
  AND pg_temp.ist_keyed(r->'by_customer', 'customer_name', 'grn_count', 'total_qty') = ARRAY['IST Day Report Saffron Cold: 3/14'],
  'receipt activity 10..12 (midnight on the 10th in, a second before it out): ' || r::text)
FROM (SELECT public.get_all_grn_activity('2026-10-10', '2026-10-12') AS r) answer;
SELECT pg_temp.ist_assert(pg_temp.ist_figures(public.get_all_grn_activity('2026-10-13', '2026-10-13')->'summary', 'total_grns', 'total_quantity') = '2/48'
  AND pg_temp.ist_figures(public.get_all_grn_activity('2026-10-09', '2026-10-09')->'summary', 'total_grns', 'total_quantity') = '1/1',
  'receipt activity 13..13 and 9..9');
-- The latest receipt of 9..13 is 18:45 UTC on the 12th, which is the 13th in India.
SELECT pg_temp.ist_assert(r#>>'{by_customer,0,latest_grn}' = '2026-10-13' AND pg_temp.ist_figures(r->'summary', 'total_grns', 'total_quantity') = '6/63',
  'receipt activity 9..13, latest receipt day: ' || r::text)
FROM (SELECT public.get_all_grn_activity('2026-10-09', '2026-10-13') AS r) answer;

-- ---------------------------------------------------------------------------
-- get_all_dispatch_activity
-- ---------------------------------------------------------------------------
SELECT pg_temp.ist_assert(pg_temp.ist_figures(r->'summary', 'total_dispatches', 'total_quantity') = '2/120'
  AND pg_temp.ist_keyed(r->'by_date', 'date', 'dispatch_count', 'total_qty') = ARRAY['2026-10-12: 2/120'],
  'dispatch activity 12..12: ' || r::text)
FROM (SELECT public.get_all_dispatch_activity('2026-10-12', '2026-10-12') AS r) answer;
SELECT pg_temp.ist_assert(pg_temp.ist_figures(r->'summary', 'total_dispatches', 'total_quantity') = '3/140'
  AND pg_temp.ist_keyed(r->'by_date', 'date', 'dispatch_count', 'total_qty') = ARRAY['2026-10-12: 2/120', '2026-10-10: 1/20']
  AND pg_temp.ist_keyed(r->'by_customer', 'customer_name', 'dispatch_count', 'total_qty') = ARRAY['IST Day Report Saffron Cold: 3/140'],
  'dispatch activity 10..12: ' || r::text)
FROM (SELECT public.get_all_dispatch_activity('2026-10-10', '2026-10-12') AS r) answer;
SELECT pg_temp.ist_assert(r#>>'{by_customer,0,latest_dispatch}' = '2026-10-13'
  AND pg_temp.ist_figures(public.get_all_dispatch_activity('2026-10-13', '2026-10-13')->'summary', 'total_dispatches', 'total_quantity') = '2/480',
  'dispatch activity 9..13 latest day, and 13..13: ' || r::text)
FROM (SELECT public.get_all_dispatch_activity('2026-10-09', '2026-10-13') AS r) answer;

-- ---------------------------------------------------------------------------
-- get_all_customer_activity_summary
-- ---------------------------------------------------------------------------
SELECT pg_temp.ist_assert(c->>'total_grns' = '2' AND c->>'total_dispatches' = '2' AND (c->>'total_invoice_amount')::numeric = 12
  AND (c->>'last_activity_date')::timestamptz = '2026-10-12T18:00:00Z' AND c->>'last_activity_type' IN ('grn', 'dispatch'),
  'customer activity 12..12 for Saffron: ' || c::text)
FROM (SELECT pg_temp.ist_element(public.get_all_customer_activity_summary('2026-10-12', '2026-10-12')#>'{data,customers}',
  'customer_name', 'IST Day Report Saffron') AS c) answer;
SELECT pg_temp.ist_assert(c->>'total_grns' = '3' AND c->>'total_dispatches' = '3' AND (c->>'total_invoice_amount')::numeric = 14,
  'customer activity 10..12 for Saffron: ' || c::text)
FROM (SELECT pg_temp.ist_element(public.get_all_customer_activity_summary('2026-10-10', '2026-10-12')#>'{data,customers}',
  'customer_name', 'IST Day Report Saffron') AS c) answer;

-- ---------------------------------------------------------------------------
-- get_customer_dispatch_activity
-- ---------------------------------------------------------------------------
SELECT pg_temp.ist_assert(pg_temp.ist_figures(r->'summary', 'total_dispatches', 'total_quantity') = '3/140'
  AND pg_temp.ist_column(r->'dispatches', 'disp_date') = ARRAY['2026-10-12', '2026-10-12', '2026-10-10']
  AND pg_temp.ist_column(r->'dispatches', 'disp_no') @> ARRAY['ISD2', 'ISD3', 'ISD4'] AND jsonb_array_length(r->'dispatches') = 3,
  'Saffron dispatches 10..12, each on its India day: ' || r::text)
FROM (SELECT public.get_customer_dispatch_activity(:'saffron'::uuid, '2026-10-10', '2026-10-12') AS r) answer;
SELECT pg_temp.ist_assert(pg_temp.ist_figures(public.get_customer_dispatch_activity(:'saffron'::uuid, '2026-10-12', '2026-10-12')->'summary', 'total_dispatches', 'total_quantity') = '2/120',
  'Saffron dispatches 12..12');

-- ---------------------------------------------------------------------------
-- get_customer_grn_activity: one customer and all customers
-- ---------------------------------------------------------------------------
SELECT pg_temp.ist_assert(pg_temp.ist_column(r#>'{data,grns}', 'gr_no') = ARRAY['ISR4', 'ISR3']
  AND pg_temp.ist_figures(r#>'{data,summary}', 'total_grns', 'total_quantity') = '2/12',
  'Saffron receipts 12..12, newest first: ' || r::text)
FROM (SELECT public.get_customer_grn_activity(:'saffron'::uuid, '2026-10-12', '2026-10-12') AS r) answer;
SELECT pg_temp.ist_assert(pg_temp.ist_column(public.get_customer_grn_activity(:'saffron'::uuid, '2026-10-10', '2026-10-12')#>'{data,grns}', 'gr_no') = ARRAY['ISR4', 'ISR3', 'ISR2']
  AND pg_temp.ist_column(public.get_customer_grn_activity(:'saffron'::uuid, '2026-10-13', '2026-10-13')#>'{data,grns}', 'gr_no') = ARRAY['ISR5', 'ISR6'],
  'Saffron receipts 10..12 and 13..13');
SELECT pg_temp.ist_assert(pg_temp.ist_figures(r#>'{data,summary}', 'total_grns', 'total_quantity') = '2/12'
  AND pg_temp.ist_keyed(r#>'{data,by_customer}', 'customer_name', 'grn_count', 'total_quantity') = ARRAY['IST Day Report Saffron Cold: 2/12'],
  'all customers receipts 12..12: ' || r::text)
FROM (SELECT public.get_customer_grn_activity(NULL, '2026-10-12', '2026-10-12') AS r) answer;
-- Without days the period is the last ten days up to today in India.
SELECT pg_temp.ist_assert(r#>>'{metadata,to_date}' = (now() AT TIME ZONE 'Asia/Kolkata')::date::text
  AND r#>>'{metadata,from_date}' = ((now() AT TIME ZONE 'Asia/Kolkata')::date - 10)::text,
  'receipt activity without days ends today in India: ' || (r->'metadata')::text)
FROM (SELECT public.get_customer_grn_activity(:'saffron'::uuid) AS r) answer;

-- ---------------------------------------------------------------------------
-- get_customer_activity_detail
-- ---------------------------------------------------------------------------
SELECT pg_temp.ist_assert(pg_temp.ist_figures(r#>'{data,summary}', 'total_grns', 'total_grn_quantity') = '2/12'
  AND pg_temp.ist_figures(r#>'{data,summary}', 'total_dispatches', 'total_dispatch_quantity') = '2/120'
  AND (r#>>'{data,summary,total_invoice_amount}')::numeric = 12,
  'Saffron detail 12..12: ' || (r#>'{data,summary}')::text)
FROM (SELECT public.get_customer_activity_detail(:'saffron'::uuid, '2026-10-12', '2026-10-12') AS r) answer;
-- Months of the India calendar: 00:30 on 1 Oct is October, 23:30 on 30 Sep is September; the
-- stock at the end of September counts what was received and dispatched up to its last minute.
SELECT pg_temp.ist_assert(pg_temp.ist_keyed(r#>'{data,monthly_trends}', 'month', 'grn_count', 'grn_quantity') = ARRAY['2026-09: 1/128', '2026-10: 7/127']
  AND pg_temp.ist_keyed(r#>'{data,monthly_trends}', 'month', 'dispatch_count', 'dispatch_quantity') = ARRAY['2026-09: 1/1280', '2026-10: 7/1270']
  AND pg_temp.ist_keyed(r#>'{data,monthly_trends}', 'month', 'invoice_amount', 'stock_level_end') = ARRAY['2026-09: 128.00/1848', '2026-10: 127.00/705'],
  'Saffron detail Sep..Oct by month: ' || (r#>'{data,monthly_trends}')::text)
FROM (SELECT public.get_customer_activity_detail(:'saffron'::uuid, '2026-09-01', '2026-10-31') AS r) answer;
-- Stock age in India days, computed here without the helpers.
RESET ROLE;
SELECT ROUND(SUM(grt.stock * ((now() AT TIME ZONE 'Asia/Kolkata')::date - (gr.date AT TIME ZONE 'Asia/Kolkata')::date)) / SUM(grt.stock)) AS expected_age,
       SUM(grt.stock) AS expected_stock
FROM public.goodsreceived gr JOIN public.goodsreceived_trl grt ON grt.gr_id = gr.id
WHERE gr.customer_id = :'saffron'::uuid AND gr.deleted_at IS NULL AND grt.stock > 0 \gset
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ist_assert((r#>>'{data,summary,average_stock_age_days}')::numeric = :'expected_age'::numeric
  AND :'expected_stock'::numeric = 705
  AND (SELECT sum((b.value->>'total_quantity')::numeric) FROM jsonb_each(r#>'{data,by_bucket}') b) = 705,
  'Saffron stock age in India days: ' || (r#>'{data,summary}')::text || ' expected ' || :'expected_age')
FROM (SELECT public.get_customer_activity_detail(:'saffron'::uuid, '2026-09-01', '2026-10-31') AS r) answer;

-- ---------------------------------------------------------------------------
-- get_customer_invoice_summary: one customer and all customers
-- ---------------------------------------------------------------------------
SELECT pg_temp.ist_assert(pg_temp.ist_column(r#>'{data,invoices}', 'grn_ref') = ARRAY['ISR4', 'ISR3']
  AND pg_temp.ist_figures(r#>'{data,summary}', 'total_invoices', 'total_amount') = '2/12.00',
  'Saffron invoices 12..12, newest first: ' || r::text)
FROM (SELECT public.get_customer_invoice_summary(:'saffron'::uuid, '2026-10-12', '2026-10-12') AS r) answer;
SELECT pg_temp.ist_assert(pg_temp.ist_keyed_sorted(r#>'{data,by_month}', 'month', 'invoice_count', 'total_amount') = ARRAY['2026-10: 7/127.00', '2026-09: 1/128.00'],
  'Saffron invoices Sep..Oct by month: ' || (r#>'{data,by_month}')::text)
FROM (SELECT public.get_customer_invoice_summary(:'saffron'::uuid, '2026-09-01', '2026-10-31') AS r) answer;
SELECT pg_temp.ist_assert(pg_temp.ist_figures(public.get_customer_invoice_summary(NULL, '2026-10-12', '2026-10-12')#>'{data,summary}', 'total_invoices', 'total_amount') = '2/12.00'
  AND pg_temp.ist_keyed_sorted(r#>'{data,by_month}', 'month', 'invoice_count', 'total_amount') = ARRAY['2026-10: 7/127.00', '2026-09: 1/128.00'],
  'all customers invoices 12..12, and Sep..Oct by month: ' || (r#>'{data,by_month}')::text)
FROM (SELECT public.get_customer_invoice_summary(NULL, '2026-09-01', '2026-10-31') AS r) answer;
SELECT pg_temp.ist_assert(r#>>'{metadata,to_date}' = (now() AT TIME ZONE 'Asia/Kolkata')::date::text
  AND r#>>'{metadata,from_date}' = ((now() AT TIME ZONE 'Asia/Kolkata')::date - 30)::text,
  'invoice summary without days ends today in India: ' || (r->'metadata')::text)
FROM (SELECT public.get_customer_invoice_summary(:'saffron'::uuid) AS r) answer;

-- ---------------------------------------------------------------------------
-- get_operations_dashboard
-- ---------------------------------------------------------------------------
SELECT pg_temp.ist_assert(r#>>'{kpis,total_grns}' = '3' AND r#>>'{kpis,total_dispatches}' = '3'
  AND pg_temp.ist_keyed(r#>'{trends,grn_daily}', 'date', 'count', 'count') = ARRAY['2026-10-10: 1/1', '2026-10-12: 2/2']
  AND pg_temp.ist_keyed(r#>'{trends,dispatch_daily}', 'date', 'count', 'count') = ARRAY['2026-10-10: 1/1', '2026-10-12: 2/2'],
  'dashboard 10..12: ' || (r - 'recent_activity')::text)
FROM (SELECT public.get_operations_dashboard('2026-10-10', '2026-10-12') AS r) answer;
SELECT pg_temp.ist_assert(r#>>'{kpis,total_grns}' = '2' AND r#>>'{kpis,total_dispatches}' = '2'
  AND pg_temp.ist_keyed(r#>'{trends,grn_daily}', 'date', 'count', 'count') = ARRAY['2026-10-13: 2/2'],
  'dashboard 13..13: ' || (r - 'recent_activity')::text)
FROM (SELECT public.get_operations_dashboard('2026-10-13', '2026-10-13') AS r) answer;

-- ---------------------------------------------------------------------------
-- get_grn_list
-- ---------------------------------------------------------------------------
SELECT pg_temp.ist_assert(pg_temp.ist_column(r#>'{data,grns}', 'gr_no', 'gr_no', 'ISR') = ARRAY['ISR4', 'ISR3', 'ISR2']
  AND pg_temp.ist_figures(r#>'{data,summary}', 'total_grns', 'total_qty') = '3/14',
  'receipt list 10..12, newest first: ' || r::text)
FROM (SELECT public.get_grn_list('2026-10-10', '2026-10-12', 'date', 'desc', 50, 0,
  jsonb_build_object('customer_ids', jsonb_build_array(:'saffron'))) AS r) answer;
SELECT pg_temp.ist_assert(pg_temp.ist_column(public.get_grn_list('2026-10-12', '2026-10-12', 'date', 'desc', 50, 0,
      jsonb_build_object('customer_ids', jsonb_build_array(:'saffron')))#>'{data,grns}', 'gr_no', 'gr_no', 'ISR') = ARRAY['ISR4', 'ISR3']
  AND pg_temp.ist_column(public.get_grn_list(NULL, '2026-10-09', 'date', 'desc', 50, 0,
      jsonb_build_object('customer_ids', jsonb_build_array(:'saffron')))#>'{data,grns}', 'gr_no', 'gr_no', 'ISR') = ARRAY['ISR1', 'ISR7', 'ISR8']
  AND pg_temp.ist_column(public.get_grn_list('2026-10-13', NULL, 'date', 'desc', 50, 0,
      jsonb_build_object('customer_ids', jsonb_build_array(:'saffron')))#>'{data,grns}', 'gr_no', 'gr_no', 'ISR') = ARRAY['ISR5', 'ISR6'],
  'receipt list 12..12, up to the 9th, and from the 13th');

-- ---------------------------------------------------------------------------
-- The defaults of the two all-customers activity reports: the last seven days up to today in
-- India, evaluated with the caller's rights.
-- ---------------------------------------------------------------------------
SELECT pg_temp.ist_assert(r->>'success' = 'true' AND r#>>'{summary,to_date}' = (now() AT TIME ZONE 'Asia/Kolkata')::date::text
  AND r#>>'{summary,from_date}' = ((now() AT TIME ZONE 'Asia/Kolkata')::date - 7)::text
  AND public.get_all_dispatch_activity()#>>'{summary,to_date}' = (now() AT TIME ZONE 'Asia/Kolkata')::date::text,
  'activity reports without days end today in India: ' || (r->'summary')::text)
FROM (SELECT public.get_all_grn_activity() AS r) answer;

-- ---------------------------------------------------------------------------
-- The session time zone does not move a day
-- ---------------------------------------------------------------------------
SET LOCAL TimeZone = 'America/Los_Angeles';
SELECT pg_temp.ist_assert(pg_temp.ist_figures(public.get_all_grn_activity('2026-10-12', '2026-10-12')->'summary', 'total_grns', 'total_quantity') = '2/12'
  AND pg_temp.ist_keyed(public.get_all_dispatch_activity('2026-10-10', '2026-10-12')->'by_date', 'date', 'dispatch_count', 'total_qty') = ARRAY['2026-10-12: 2/120', '2026-10-10: 1/20']
  AND pg_temp.ist_column(public.get_grn_list('2026-10-10', '2026-10-12', 'date', 'desc', 50, 0,
      jsonb_build_object('customer_ids', jsonb_build_array(:'saffron')))#>'{data,grns}', 'gr_no', 'gr_no', 'ISR') = ARRAY['ISR4', 'ISR3', 'ISR2']
  AND pg_temp.ist_keyed_sorted(public.get_customer_invoice_summary(:'saffron'::uuid, '2026-09-01', '2026-10-31')#>'{data,by_month}', 'month', 'invoice_count', 'total_amount')
      = ARRAY['2026-10: 7/127.00', '2026-09: 1/128.00'],
  'with the session in Los Angeles the days and months are the same');
SET LOCAL TimeZone = 'UTC';
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Authorization is what it was
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims', :'staff_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ist_assert(warehouse_security.active_role() = 'staff', 'actual staff role');
SELECT pg_temp.ist_assert(r->>'success' = 'true' AND pg_temp.ist_figures(r->'summary', 'total_dispatches', 'total_quantity') = '2/120'
  AND pg_temp.ist_column(public.get_grn_list('2026-10-12', '2026-10-12', 'date', 'desc', 50, 0,
      jsonb_build_object('customer_ids', jsonb_build_array(:'saffron')))#>'{data,grns}', 'gr_no', 'gr_no', 'ISR') = ARRAY['ISR4', 'ISR3'],
  'staff run the all-customers dispatch activity and the receipt list on India days: ' || r::text)
FROM (SELECT public.get_all_dispatch_activity('2026-10-12', '2026-10-12') AS r) answer;
RESET ROLE;

SELECT set_config('request.jwt.claims', :'customer_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ist_assert(warehouse_security.active_role() = 'customer', 'actual customer role');
-- Its own customer, on India days.
SELECT pg_temp.ist_assert(r->>'success' = 'true' AND pg_temp.ist_column(r#>'{data,grns}', 'gr_no') = ARRAY['ISR4', 'ISR3']
  AND pg_temp.ist_column(public.get_customer_invoice_summary(:'saffron'::uuid, '2026-10-12', '2026-10-12')#>'{data,invoices}', 'grn_ref') = ARRAY['ISR4', 'ISR3']
  AND pg_temp.ist_figures(public.get_customer_dispatch_activity(:'saffron'::uuid, '2026-10-12', '2026-10-12')->'summary', 'total_dispatches', 'total_quantity') = '2/120',
  'customer account, own customer 12..12: ' || r::text)
FROM (SELECT public.get_customer_grn_activity(:'saffron'::uuid, '2026-10-12', '2026-10-12') AS r) answer;
SELECT pg_temp.ist_assert(pg_temp.ist_refused(format(s.statement, '2026-10-10', '2026-10-12', :'tamarind')), 'a customer account was answered: ' || s.statement)
FROM (VALUES
  ('SELECT public.get_all_dispatch_activity(%L::date, %L::date)'),
  ('SELECT public.get_all_grn_activity(%L::date, %L::date)'),
  ('SELECT public.get_all_customer_activity_summary(%L::date, %L::date)'),
  ('SELECT public.get_operations_dashboard(%L::date, %L::date)'),
  ('SELECT public.get_grn_list(%L::date, %L::date)'),
  ('SELECT public.get_customer_grn_activity(NULL, %L::date, %L::date)'),
  ('SELECT public.get_customer_invoice_summary(NULL, %L::date, %L::date)'),
  ('SELECT public.get_customer_grn_activity(%3$L::uuid, %1$L::date, %2$L::date)'),
  ('SELECT public.get_customer_invoice_summary(%3$L::uuid, %1$L::date, %2$L::date)'),
  ('SELECT public.get_customer_dispatch_activity(%3$L::uuid, %1$L::date, %2$L::date)'),
  ('SELECT public.get_customer_activity_detail(%3$L::uuid, %1$L::date, %2$L::date)')
) AS s(statement);
-- The refusal helper can tell an answer from a refusal.
SELECT pg_temp.ist_assert(NOT pg_temp.ist_refused(format('SELECT public.get_customer_grn_activity(%L::uuid, %L::date, %L::date)', :'saffron', '2026-10-10', '2026-10-12')),
  'the refusal check itself answers false for an allowed call');
RESET ROLE;
ROLLBACK;
SELECT 'report ist day: the report functions and the receipt list cut India days, the session zone does not move them, and authorization is unchanged' AS result;

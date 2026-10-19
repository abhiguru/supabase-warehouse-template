-- Parity of public.get_invoices_list across migration 106 (the list moves from mv_invoice_list to the tables).
-- tests/migrations.sh runs this file twice on fresh databases and requires identical output: once with migrations
-- up to 105 applied (the old function, reading the materialized view) and once with 106 applied (the tables).
-- It seeds a fixed set of invoices (fixed ids and dates, so the answers are comparable), prints one line per case,
-- "label<TAB>answer", for every sort and direction, each filter, several pages and four kinds of caller (two of them refused), and rolls
-- everything back. No two invoices tie on every sort key, so the old function's order is fully determined.
\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on
BEGIN;
\o /dev/null
CREATE FUNCTION pg_temp.par_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'invoice list parity: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.par_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.par_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;

INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888888771', 'Parity Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888888772', 'Parity Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888888773', 'Parity Customer Two', 'customer', true, 'approved'),
 (gen_random_uuid(), '919888888774', 'Parity Customer None', 'customer', true, 'approved');
SELECT pg_temp.par_login('9888888771') AS admin_claims \gset
SELECT pg_temp.par_login('9888888772') AS staff_claims \gset
SELECT pg_temp.par_login('9888888773') AS cust2_claims \gset
SELECT pg_temp.par_login('9888888774') AS cust0_claims \gset

-- Six customers; the sixth is deleted and has invoices that must not appear. The names differ in case and
-- digits so that the name sort and the search have something to tell apart.
INSERT INTO public.customers(id, name, mobile, city, address) VALUES
 (md5('par-c1')::uuid, 'Par Alpha Foods',   '9888880001', 'Surat',  '1 Mill Road'),
 (md5('par-c2')::uuid, 'par alpha traders', '9888880002', 'Rajkot', '2 Mill Road'),
 (md5('par-c3')::uuid, 'Par Beta Mart',     '9888880003', 'Surat',  '3 Mill Road'),
 (md5('par-c4')::uuid, 'Par Gamma 9',       '9888880004', 'Vapi',   '4 Mill Road'),
 (md5('par-c5')::uuid, 'Par Gamma 10',      '9888880005', 'Vapi',   '5 Mill Road'),
 (md5('par-c6')::uuid, 'Par Deleted Co',    '9888880006', 'Surat',  '6 Mill Road');
UPDATE public.customers SET deleted_at = '2026-01-01 00:00+00' WHERE id = md5('par-c6')::uuid;
INSERT INTO public.users_customers_new(user_profile_id, customer_id, active)
 SELECT p.id, c.id, true FROM public.user_profiles p, public.customers c
 WHERE p.mobile = '919888888773' AND c.id IN (md5('par-c1')::uuid, md5('par-c2')::uuid);
INSERT INTO public.items(id, name, packaging) VALUES (md5('par-item')::uuid, 'Par Item', 'Bag');

-- 44 invoices. n = 1..12 are financial year 2025, 13..42 are 2026, 43..44 are 2027. Invoice numbers repeat across
-- years and every fifth is above 100; dates and totals are all different. Invoices 37..42 belong to the deleted
-- customer. Every ninth invoice has no lines.
CREATE TEMP TABLE par_n ON COMMIT DROP AS SELECT n,
  CASE WHEN n <= 12 THEN 2025 WHEN n <= 42 THEN 2026 ELSE 2027 END AS fy,
  CASE WHEN n <= 12 THEN n WHEN n <= 42 THEN n - 12 ELSE n - 42 END + CASE WHEN n % 5 = 0 THEN 100 ELSE 0 END AS inv_no,
  CASE WHEN n BETWEEN 37 AND 42 THEN md5('par-c6')::uuid ELSE md5('par-c' || (n % 5 + 1))::uuid END AS customer_id
  FROM generate_series(1, 44) n;
INSERT INTO public.goodsreceived(id, gr_no, date, customer_id, customer_name, sender_name, supervisor_name, registration)
 SELECT md5('par-g' || n)::uuid, 'PG-' || n, '2026-01-01 08:00+00'::timestamptz + n * interval '17 hours', customer_id,
        (SELECT name FROM public.customers WHERE id = par_n.customer_id), 'Sender ' || n % 3, 'Supervisor ' || n % 4, 'GJ05AB' || lpad(n::text, 4, '0')
 FROM par_n;
INSERT INTO public.goodsreceived_trl(id, gr_id, item_id, item_name, qty, weight, stock)
 SELECT md5('par-gt' || n || '-' || k)::uuid, md5('par-g' || n)::uuid, md5('par-item')::uuid, 'Par Item', 20, 5, 20 FROM par_n, generate_series(1, 2) k;
INSERT INTO public.dispatch(id, disp_no, disp_date, customer_id, customer_name)
 SELECT md5('par-d' || n)::uuid, 'PD-' || n, '2026-01-02 08:00+00'::timestamptz + n * interval '17 hours', customer_id,
        (SELECT name FROM public.customers WHERE id = par_n.customer_id) FROM par_n WHERE n % 9 <> 0;
INSERT INTO public.dispatch_trl(id, gr_id, gr_trl_id, disp_id, disp_qty)
 SELECT md5('par-dt' || n || '-' || k)::uuid, md5('par-g' || n)::uuid, md5('par-gt' || n || '-' || k)::uuid, md5('par-d' || n)::uuid, n % 7 + k
 FROM par_n, generate_series(1, 2) k WHERE n % 9 <> 0 AND (k = 1 OR n % 2 = 0);
INSERT INTO public.invoice(id, inv_fin_year, inv_no, gr_id, gr_no, customer_id, customer_name, inv_date, total, discount, labour, tax_amount,
                           one_time_charge, inv_name, notes)
 SELECT md5('par-i' || n)::uuid, fy, inv_no, md5('par-g' || n)::uuid, 'PG-' || n, customer_id,
        (SELECT name FROM public.customers WHERE id = par_n.customer_id),
        '2026-02-01 06:30+00'::timestamptz + n * interval '19 hours', 100 + (n * 53) % 997, n % 4, n % 6, n % 3, n % 2 = 0, 'Invoice ' || n, 'Note ' || n
 FROM par_n;
INSERT INTO public.invoice_trl(id, invoice_id, disp_trl_id)
 SELECT md5('par-it' || n || '-' || k)::uuid, md5('par-i' || n)::uuid, md5('par-dt' || n || '-' || k)::uuid
 FROM par_n, generate_series(1, 2) k WHERE n % 9 <> 0 AND (k = 1 OR n % 2 = 0);
-- One invoice that is soft-deleted: it must not appear either.
UPDATE public.invoice SET deleted_at = '2026-03-01 00:00+00' WHERE id = md5('par-i20')::uuid;
-- The old function reads the materialized view; refresh it when it is still there (the writes above only marked it).
DO $$ BEGIN
  IF to_regclass('public.mv_invoice_list') IS NOT NULL THEN EXECUTE 'REFRESH MATERIALIZED VIEW public.mv_invoice_list'; END IF;
END $$;

CREATE FUNCTION pg_temp.par_call(who text, a jsonb) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', CASE who WHEN 'admin' THEN current_setting('test.par_admin') WHEN 'staff' THEN current_setting('test.par_staff')
    WHEN 'cust2' THEN current_setting('test.par_cust2') WHEN 'svc2' THEN current_setting('test.par_svc2')
    WHEN 'svc0' THEN current_setting('test.par_svc0') ELSE current_setting('test.par_cust0') END, true);
  RETURN public.get_invoices_list(
    p_limit => COALESCE((a->>'limit')::integer, 50), p_offset => COALESCE((a->>'offset')::integer, 0),
    p_customer_id => (a->>'cust')::uuid, p_financial_year => (a->>'fy')::integer,
    p_search_invoice_no => a->>'sin', p_search_grn_no => a->>'sgn',
    p_sort_field => COALESCE(a->>'sf', 'inv_date'), p_sort_direction => COALESCE(a->>'sd', 'desc'),
    p_inv_no_from => (a->>'from')::integer, p_inv_no_to => (a->>'to')::integer, p_search => a->>'q',
    p_date_from => (a->>'df')::timestamptz, p_date_to => (a->>'dt')::timestamptz,
    p_customer_ids => CASE WHEN a ? 'cids' THEN ARRAY(SELECT jsonb_array_elements_text(a->'cids')::uuid) END)::text;
EXCEPTION WHEN OTHERS THEN
  RETURN 'ERROR ' || SQLSTATE || ' ' || SQLERRM;
END $$;
SELECT set_config('test.par_admin', :'admin_claims', true), set_config('test.par_staff', :'staff_claims', true),
       set_config('test.par_cust2', :'cust2_claims', true), set_config('test.par_cust0', :'cust0_claims', true),
       -- The user_accessible_customers() branch: the service role with a customer's own subject (a customer account itself is refused).
       set_config('test.par_svc2', jsonb_build_object('role', 'service_role', 'sub', (:'cust2_claims'::jsonb)->>'sub')::text, true),
       set_config('test.par_svc0', jsonb_build_object('role', 'service_role', 'sub', (:'cust0_claims'::jsonb)->>'sub')::text, true) \gset

-- The cases: who, label, arguments.
CREATE TEMP TABLE par_cases(ord serial, who text, label text, args jsonb) ON COMMIT DROP;
-- Every sort field in both directions and an invalid one, first page, a middle page and the last page.
INSERT INTO par_cases(who, label, args)
 SELECT 'admin', 'sort ' || sf || ' ' || sd || ' offset ' || off, jsonb_build_object('sf', sf, 'sd', sd, 'limit', 7, 'offset', off)
 FROM unnest(ARRAY['inv_date','inv_no','invoice_number','customer_name','grn_number','gr_no','total','financial_year','bogus']) sf,
      unnest(ARRAY['asc','desc','sideways']) sd, unnest(ARRAY[0, 14, 35]) off;
INSERT INTO par_cases(who, label, args) VALUES
 ('admin', 'defaults', '{}'),
 ('admin', 'one big page', '{"limit": 1000}'),
 ('admin', 'page 1 of 5', '{"limit": 5, "offset": 0}'), ('admin', 'page 2 of 5', '{"limit": 5, "offset": 5}'), ('admin', 'page 9 of 5', '{"limit": 5, "offset": 40}'),
 ('admin', 'past the end', '{"limit": 5, "offset": 500}'), ('admin', 'limit 0', '{"limit": 0}'), ('admin', 'limit 1', '{"limit": 1}'),
 ('admin', 'customer 1', jsonb_build_object('cust', md5('par-c1')::uuid)),
 ('admin', 'customer 6 (deleted)', jsonb_build_object('cust', md5('par-c6')::uuid)),
 ('admin', 'customer 3 sort total asc', jsonb_build_object('cust', md5('par-c3')::uuid, 'sf', 'total', 'sd', 'asc')),
 ('admin', 'fy 2025', '{"fy": 2025}'), ('admin', 'fy 2026', '{"fy": 2026}'), ('admin', 'fy 2027', '{"fy": 2027}'), ('admin', 'fy 1999', '{"fy": 1999}'),
 ('admin', 'invoice no 1', '{"sin": "1"}'), ('admin', 'invoice no 10', '{"sin": "10"}'), ('admin', 'invoice no empty', '{"sin": ""}'), ('admin', 'invoice no 105', '{"sin": "105"}'),
 ('admin', 'grn 1', '{"sgn": "PG-1"}'), ('admin', 'grn 3', '{"sgn": "pg-3"}'), ('admin', 'grn empty', '{"sgn": ""}'), ('admin', 'grn no match', '{"sgn": "zzz"}'),
 ('admin', 'range 5..12', '{"from": 5, "to": 12}'), ('admin', 'range from 100', '{"from": 100}'), ('admin', 'range to 3', '{"to": 3}'), ('admin', 'range empty', '{"from": 9, "to": 3}'),
 ('admin', 'date from', '{"df": "2026-03-01T00:00:00+00"}'), ('admin', 'date to', '{"dt": "2026-03-01T00:00:00+00"}'),
 ('admin', 'date both', '{"df": "2026-02-10T00:00:00+00", "dt": "2026-03-10T00:00:00+00"}'),
 ('admin', 'date exact first', '{"df": "2026-02-02T01:30:00+00", "dt": "2026-02-02T01:30:00+00"}'),
 ('admin', 'customer ids two', jsonb_build_object('cids', jsonb_build_array(md5('par-c2')::uuid, md5('par-c4')::uuid))),
 ('admin', 'customer ids empty', '{"cids": []}'),
 ('admin', 'customer ids with deleted', jsonb_build_object('cids', jsonb_build_array(md5('par-c6')::uuid))),
 ('admin', 'search one word', '{"q": "alpha"}'), ('admin', 'search case', '{"q": "ALPHA"}'), ('admin', 'search two words', '{"q": "alpha foods"}'),
 ('admin', 'search two words across columns', '{"q": "gamma PG-4"}'), ('admin', 'search number', '{"q": "7"}'), ('admin', 'search year-number', '{"q": "2026-3"}'),
 ('admin', 'search padded', '{"q": "2026-0003"}'), ('admin', 'search padded 3 digits', '{"q": "2026-0105"}'), ('admin', 'search percent', '{"q": "%"}'),
 ('admin', 'search underscore', '{"q": "_"}'), ('admin', 'search backslash', '{"q": "\\"}'), ('admin', 'search blank', '{"q": "   "}'),
 ('admin', 'search no match', '{"q": "nothing here"}'), ('admin', 'search nine words', '{"q": "a b c d e f g h i"}'), ('admin', 'search deleted customer name', '{"q": "deleted"}'),
 ('admin', 'search sort name asc', '{"q": "par", "sf": "customer_name", "sd": "asc", "limit": 9}'),
 ('admin', 'everything at once', jsonb_build_object('cust', md5('par-c1')::uuid, 'fy', 2026, 'sin', '1', 'sgn', 'PG', 'from', 1, 'to', 200, 'q', 'alpha',
   'df', '2026-01-01T00:00:00+00', 'dt', '2027-01-01T00:00:00+00', 'cids', jsonb_build_array(md5('par-c1')::uuid), 'sf', 'total', 'sd', 'desc', 'limit', 3, 'offset', 1));
INSERT INTO par_cases(who, label, args)
 SELECT w, 'caller ' || w || ' ' || c.label, c.args
 FROM unnest(ARRAY['staff', 'cust2', 'cust0']) w, par_cases c WHERE c.who = 'admin' AND c.label IN
  ('defaults', 'one big page', 'sort total asc offset 0', 'sort customer_name desc offset 0', 'sort inv_no asc offset 14', 'fy 2026', 'search one word', 'search two words',
   'customer 1', 'customer 6 (deleted)', 'customer ids two', 'date both', 'range 5..12');
-- The exact call of the GRN Invoices tab (customer + receipt-number search, oldest first, 200 rows), and the
-- user_accessible_customers() branch: the service role with a customer's subject, who sees only the assigned
-- businesses (c1 and c2); a customer with none sees nothing.
INSERT INTO par_cases(who, label, args) VALUES
 ('admin', 'grn tab c2 PG-1 inv_date asc', jsonb_build_object('cust', md5('par-c2')::uuid, 'sgn', 'PG-1', 'sf', 'inv_date', 'sd', 'asc', 'limit', 200)),
 ('admin', 'grn tab c1 PG- inv_date asc', jsonb_build_object('cust', md5('par-c1')::uuid, 'sgn', 'PG-', 'sf', 'inv_date', 'sd', 'asc', 'limit', 200)),
 ('staff', 'grn tab c2 PG-1 inv_date asc', jsonb_build_object('cust', md5('par-c2')::uuid, 'sgn', 'PG-1', 'sf', 'inv_date', 'sd', 'asc', 'limit', 200)),
 ('svc2', 'accessible defaults', '{}'), ('svc2', 'accessible one big page', '{"limit": 1000}'),
 ('svc2', 'accessible total asc', '{"sf": "total", "sd": "asc", "limit": 6}'),
 ('svc2', 'accessible search alpha', '{"q": "alpha"}'),
 ('svc2', 'accessible customer 1', jsonb_build_object('cust', md5('par-c1')::uuid)),
 ('svc2', 'accessible customer 3 (not assigned)', jsonb_build_object('cust', md5('par-c3')::uuid)),
 ('svc2', 'accessible grn tab c2', jsonb_build_object('cust', md5('par-c2')::uuid, 'sgn', 'PG-1', 'sf', 'inv_date', 'sd', 'asc', 'limit', 200)),
 ('svc0', 'no business defaults', '{}'), ('svc0', 'no business customer 1', jsonb_build_object('cust', md5('par-c1')::uuid));
INSERT INTO par_cases(who, label, args) VALUES
 ('cust2', 'caller cust2 asks for the other customer', jsonb_build_object('cust', md5('par-c3')::uuid)),
 ('cust0', 'caller cust0 asks for a customer', jsonb_build_object('cust', md5('par-c1')::uuid));

GRANT SELECT ON par_cases TO authenticated;
-- Sanity: the fixture is what the cases assume.
SET LOCAL ROLE authenticated;
SELECT pg_temp.par_assert((pg_temp.par_call('admin', '{"limit": 1000}')::jsonb #>> '{pagination,total_count}') = '37', 'the administrator sees 37 invoices (44 - 6 of the deleted customer - 1 deleted)');
-- A customer account is refused by authorize_rpc before the function reads anything (both before and after 106).
SELECT pg_temp.par_assert(pg_temp.par_call('cust2', '{}') = 'ERROR 42501 Staff access required' AND pg_temp.par_call('cust0', '{}') = 'ERROR 42501 Staff access required',
  'a customer account is refused: ' || pg_temp.par_call('cust2', '{}'));
SELECT pg_temp.par_assert((pg_temp.par_call('staff', '{"limit": 1000}')::jsonb #>> '{pagination,total_count}') = '37', 'staff see the same 37');
SELECT pg_temp.par_assert(pg_temp.par_call('admin', '{"limit": 1000}')::jsonb #>> '{data,0,total_qty}' IS NOT NULL, 'the answer carries total_qty');
SELECT pg_temp.par_assert((pg_temp.par_call('svc2', '{"limit": 1000}')::jsonb #>> '{pagination,total_count}') IS DISTINCT FROM '37'
  AND (pg_temp.par_call('svc2', '{"limit": 1000}')::jsonb #>> '{pagination,total_count}') IS NOT NULL
  AND (pg_temp.par_call('svc0', '{}')::jsonb #>> '{pagination,total_count}') = '0', 'the accessible-customers branch answers: ' || pg_temp.par_call('svc2', '{}'));
SELECT pg_temp.par_assert((pg_temp.par_call('admin', jsonb_build_object('cust', md5('par-c2')::uuid, 'sgn', 'PG-1', 'limit', 200))::jsonb #>> '{pagination,total_count}') = '3', 'the GRN tab call finds 3 invoices');
SELECT pg_temp.par_assert((SELECT count(*) FROM par_cases) > 150, 'the case list is built');

-- The answers.
\o
SELECT c.label || E'\t' || pg_temp.par_call(c.who, c.args) FROM par_cases c ORDER BY c.ord;
ROLLBACK;

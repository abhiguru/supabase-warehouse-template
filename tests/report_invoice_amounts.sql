-- The invoice amounts in the reports are the invoice's total (migration 61).
--
-- Three report functions built a "net" figure as total + labour + tax_amount - discount, which adds
-- the labour and the tax a second time and takes the discount off a second time (the header total
-- already holds all three: warehouse_security.recalculate_invoice_header). Since migration 61 the
-- invoice amount of every such key is invoice.total, so net_total = total, net_amount =
-- total_amount, paid + pending = total_amount; and get_customer_invoice_summary lists and sums an
-- invoice once however many rows it has in payments (it listed it once per payment row).
--
-- Every invoice is made by public.save_invoice, so its header is computed by the real code. One bag
-- per example, a monthly receipt dispatched within 30 days (one period); the rates are per bag.
--
--   no    customer  inv_date  bags charge labour tax  discount  labour  tax  total  old sum  payments
--   6101  Quince    20 Sep      1    10    2.50   5%      0       2.50    1     14    17.50   one row, 14 (the worked example)
--   6104  Quince    25 Sep      2    40    4      12%    10       8      11     89    98      none
--   6102  Quince    05 Oct      4    25    3      5%      7.50   12       6    111   121.50   TWO rows, 60 (10 Oct) and 51 (20 Oct)
--   6103  Quince    12 Oct     10     8    1.20   18%     0      12      17    109   138      none
--   6105  Quince    15 Jul      3    20    2      0%      0       6       0     66    72      none (outside the period)
--   6107  Rowan     15 Sep      2    30    5      5%      3      10       4     71    82      one row, 71
--   6106  Rowan     08 Oct      6    15    2      5%      0      12       6    108   126      none
-- (old sum = total + labour + tax - discount.) The period used is 1 Sep to 31 Oct 2026.
--
--   Quince, period:  total 323 (old net 375); paid = 6101 + 6102 = 14 + 111 = 125; pending = 6103 + 6104
--                    = 109 + 89 = 198; Oct 220 (paid 111, pending 109), Sep 103 (paid 14, pending 89).
--   Rowan, period:   total 179 (old 208); paid 71, pending 108.
--   all customers:   502 in 6 invoices (old 583), tax 45; Oct 328 in 3, Sep 174 in 3.
--   activity detail: total_invoice_amount 323, months Sep 103 and Oct 220, total_paid_amount 125
--                    (all three payment rows), total_pending_amount 198; the five latest invoices
--                    (no period) 109, 111, 89, 14, 66.
-- A wrong sum or a repeated invoice tells itself apart: the old sum gives 375, 139 paid and 236
-- pending; the old join lists 6102 twice (5 invoices) and sums it twice.
--
-- Migration 62 changed what Paid and Pending mean (the money received, not "has a payment row"), which these
-- fixtures do not touch: every invoice here is paid in full by its payment rows or has none, so the statuses and sums
-- below read the same under both rules. The only line that moved is the key set of an invoice (two new keys).
-- tests/report_invoice_paid.sql covers part payments, the 0.50 tolerance and over-payments.
--
-- Each answer is read as the role under test and compared AFTER the role is dropped.
-- Runs ONLY in migrations.sh's fresh, network-disabled database. All fixture rows roll back.
\set ON_ERROR_STOP on
BEGIN;
-- The one-argument save_invoice(jsonb) is gone (migration 123): the app's save, a header and an array of lines, is used. This takes
-- the header with its lines under 'items' (as the old call did) and adds what the save asks of each line: its lot and a duration of 1.
CREATE FUNCTION pg_temp.save_invoice_doc(doc jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.save_invoice(NULL::uuid, doc - 'items', ARRAY(
    SELECT jsonb_build_object('grn_item_id', (SELECT d.gr_trl_id FROM public.dispatch_trl d WHERE d.id = (i->>'disp_trl_id')::uuid), 'duration', 1) || i
    FROM jsonb_array_elements(doc->'items') i)) $$;
CREATE FUNCTION pg_temp.ria_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'report invoice amounts: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.ria_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.ria_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- A receipt of one item, its full dispatch and an invoice for that dispatch, as the administrator:
-- bags, the three dates (receipt, dispatch, invoice), the rates per bag and the discount.
CREATE FUNCTION pg_temp.ria_invoice(p_no integer, p_customer uuid, p_customer_name text, p_item uuid, p_supervisor text,
  p_bags integer, p_grn_day text, p_disp_day text, p_inv_day text, p_charge numeric, p_labour numeric, p_tax numeric, p_discount numeric)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE trl_id uuid; grn_id uuid; line_id uuid; saved jsonb;
BEGIN
  PERFORM pg_temp.ria_assert(public.save_grn(p_gr_no => 'RIAG' || p_no, p_date => (p_grn_day || 'T12:00:00Z')::timestamptz,
      p_customer_id => p_customer, p_customer_name => p_customer_name, p_pricing_mode => 'MONTHLY',
      p_idempotency_key => 'report-invoice-amounts-g' || p_no,
      p_items => jsonb_build_array(jsonb_build_object('item_id', p_item, 'item_name', 'Invoice Amounts Fennel', 'packaging', 'Bag',
        'qty', p_bags, 'weight', 10)))->>'success' = 'true', 'fixture receipt RIAG' || p_no);
  SELECT g.id, t.id INTO grn_id, trl_id FROM public.goodsreceived g JOIN public.goodsreceived_trl t ON t.gr_id = g.id WHERE g.gr_no = 'RIAG' || p_no;
  PERFORM pg_temp.ria_assert(public.create_dispatch_with_stock_check(jsonb_build_object('disp_no', 'RIAD' || p_no,
      'disp_date', p_disp_day, 'customer_id', p_customer, 'customer_name', p_customer_name,
      'supervisor_id', p_supervisor, 'supervisor_name', 'Invoice Amounts Administrator'),
    ARRAY[jsonb_build_object('gr_trl_id', trl_id, 'disp_qty', p_bags)], 0, 'report-invoice-amounts-d' || p_no)->>'success' = 'true',
    'fixture dispatch RIAD' || p_no);
  SELECT dt.id INTO line_id FROM public.dispatch_trl dt JOIN public.dispatch d ON d.id = dt.disp_id WHERE d.disp_no = 'RIAD' || p_no;
  saved := pg_temp.save_invoice_doc(jsonb_build_object('inv_no', p_no, 'inv_fin_year', 2026, 'gr_id', grn_id, 'gr_no', 'RIAG' || p_no,
    'customer_id', p_customer, 'customer_name', p_customer_name, 'inv_date', p_inv_day || 'T12:00:00Z',
    'discount', p_discount, 'duration_mode', 'legacy',
    'items', jsonb_build_array(jsonb_build_object('disp_trl_id', line_id, 'charge', p_charge, 'tax', p_tax, 'labour_rate', p_labour))));
  PERFORM pg_temp.ria_assert(saved->>'success' = 'true', 'fixture invoice ' || p_no || ': ' || saved::text);
END $$;
-- One field of every element of an array, in the returned order, as text and as numbers.
CREATE FUNCTION pg_temp.ria_col(arr jsonb, value_key text) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(x->>value_key ORDER BY ord), '{}')
  FROM jsonb_array_elements(arr) WITH ORDINALITY AS t(x, ord) $$;
CREATE FUNCTION pg_temp.ria_nums(arr jsonb, value_key text) RETURNS numeric[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg((x->>value_key)::numeric ORDER BY ord), '{}')
  FROM jsonb_array_elements(arr) WITH ORDINALITY AS t(x, ord) $$;
-- The keys of an object, sorted bytewise, as one text.
CREATE FUNCTION pg_temp.ria_keys(o jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(k, ',' ORDER BY k COLLATE "C") FROM jsonb_object_keys(o) AS t(k) $$;
-- The invoice of an answer's invoices[] with that number (as a whole object), NULL when absent.
CREATE FUNCTION pg_temp.ria_invoice_of(answer jsonb, number_text text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT x FROM jsonb_array_elements(answer#>'{data,invoices}') AS t(x) WHERE x->>'invoice_number' = number_text $$;
-- The element of an array whose key has that value, NULL when absent.
CREATE FUNCTION pg_temp.ria_row(arr jsonb, key_name text, key_value text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT x FROM jsonb_array_elements(arr) AS t(x) WHERE x->>key_name = key_value $$;
-- 'answered: ...' when the statement returns an answer with success true; 'refused: <code> <error>' when it
-- returns the guard's refusal (these reports catch the 42501 and answer success false with its text), or the
-- error text when the statement itself raises 42501. Any other error stops the test.
CREATE FUNCTION pg_temp.ria_refusal(statement text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  EXECUTE statement INTO answer;
  IF answer->>'success' = 'true' THEN RETURN 'answered: ' || left(answer::text, 120); END IF;
  RETURN 'refused: ' || COALESCE(answer->>'error_code', '') || ' ' || COALESCE(answer->>'error', '');
EXCEPTION WHEN insufficient_privilege THEN RETURN SQLERRM;
END $$;
-- The number of times a text occurs in another.
CREATE FUNCTION pg_temp.ria_count(haystack text, needle text) RETURNS integer LANGUAGE sql AS $$
  SELECT (length(haystack) - length(replace(haystack, needle, ''))) / length(needle) $$;

SELECT pg_temp.ria_assert(current_setting('TimeZone') = 'UTC', 'the session time zone is UTC');

-- ---------------------------------------------------------------------------
-- The three functions: single, guarded first, the sum is gone, the rest is as before
-- ---------------------------------------------------------------------------
SELECT pg_temp.ria_assert((SELECT count(*) FROM pg_proc p WHERE p.proname = f.name) = 1,
  'exactly one function named ' || f.name || ', in any schema')
FROM (VALUES ('get_customer_invoice_summary'), ('get_customer_activity_detail'), ('get_all_customer_activity_summary')) AS f(name);
SELECT pg_temp.ria_assert(p.prosecdef
    AND pg_get_functiondef(p.oid) ~ ('BEGIN\s+PERFORM warehouse_security\.authorize_rpc\(''' || p.proname || ''','),
  'SECURITY DEFINER, and the guard comes first in ' || p.proname)
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
  AND p.proname IN ('get_customer_invoice_summary', 'get_customer_activity_detail', 'get_all_customer_activity_summary');
-- The search_path and the grants are what they were: a fixed search_path (with jit off, as these three
-- have had since the baseline), the app role may execute, the anonymous role may not.
SELECT pg_temp.ria_assert(p.proconfig = ARRAY['search_path=pg_catalog, public, extensions, utils, pg_temp', 'jit=off'],
  'search_path and jit of ' || p.proname || ': ' || COALESCE(p.proconfig::text, 'none'))
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
  AND p.proname IN ('get_customer_invoice_summary', 'get_customer_activity_detail', 'get_all_customer_activity_summary');
SELECT pg_temp.ria_assert(has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
    AND p.proacl IS NOT DISTINCT FROM (SELECT s.proacl FROM pg_proc s WHERE s.oid = 'public.get_customer_stock_summary(uuid)'::regprocedure),
  'grants of ' || p.proname || ': authenticated may execute, anon may not, as its sibling get_customer_stock_summary: ' || COALESCE(p.proacl::text, 'none'))
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
  AND p.proname IN ('get_customer_invoice_summary', 'get_customer_activity_detail', 'get_all_customer_activity_summary');
-- The double count is gone from the text of all three, and the invoice amount is written the
-- stated number of times; the India day cuts of migrations 54 and 56 are kept.
SELECT pg_temp.ria_assert(pg_get_functiondef(p.oid) NOT LIKE '%COALESCE(labour, 0)%' AND pg_get_functiondef(p.oid) NOT LIKE '%COALESCE(i.labour, 0)%'
    AND pg_get_functiondef(p.oid) NOT LIKE '%COALESCE(tax_amount, 0)%' AND pg_get_functiondef(p.oid) NOT LIKE '%COALESCE(i.tax_amount, 0)%'
    AND pg_get_functiondef(p.oid) NOT LIKE '%COALESCE(discount, 0)%' AND pg_get_functiondef(p.oid) NOT LIKE '%COALESCE(i.discount, 0)%',
  'no sum of total, labour, tax and discount is left in ' || p.proname)
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
  AND p.proname IN ('get_customer_invoice_summary', 'get_customer_activity_detail', 'get_all_customer_activity_summary');
SELECT pg_temp.ria_assert(pg_temp.ria_count(pg_get_functiondef(p.oid), 'COALESCE(i.total, 0) as net_total') = 2
    AND pg_temp.ria_count(pg_get_functiondef(p.oid), 'DISTINCT ON (p.invoice_id)') = 1
    AND pg_temp.ria_count(pg_get_functiondef(p.oid), 'ORDER BY p.invoice_id, p.payment_date DESC, p.payment_no DESC') = 1
    AND pg_get_functiondef(p.oid) LIKE '%i.inv_date >= warehouse_security.business_day_start(v_from_date)%'
    AND pg_get_functiondef(p.oid) LIKE '%TO_CHAR(warehouse_security.business_date(invoice_date), ''YYYY-MM'')%',
  'get_customer_invoice_summary: net_total twice, one payment row per invoice, the India day cut kept')
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'get_customer_invoice_summary';
SELECT pg_temp.ria_assert(pg_temp.ria_count(pg_get_functiondef(p.oid), 'SUM(COALESCE(total, 0)), 0)') = 2
    AND pg_temp.ria_count(pg_get_functiondef(p.oid), 'COALESCE(i.total, 0) as net_total') = 1
    AND pg_get_functiondef(p.oid) LIKE '%inv_date >= warehouse_security.business_day_start(p_from_date)%',
  'get_customer_activity_detail: the invoice amount is the total in the period, its months and the recent invoices, the India day cut kept')
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'get_customer_activity_detail';
SELECT pg_temp.ria_assert(pg_temp.ria_count(pg_get_functiondef(p.oid), 'SUM(COALESCE(total, 0)) as total_invoice_amount') = 1
    AND pg_get_functiondef(p.oid) LIKE '%inv_date >= warehouse_security.business_day_start(p_from_date)%',
  'get_all_customer_activity_summary: the invoice amount per customer is the total, the India day cut kept')
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'get_all_customer_activity_summary';

-- ---------------------------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------------------------
INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888889501', 'Invoice Amounts Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888889502', 'Invoice Amounts Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888889503', 'Invoice Amounts Customer', 'customer', true, 'approved');
SELECT id AS admin_profile FROM public.user_profiles WHERE mobile = '919888889501' \gset
SELECT pg_temp.ria_login('9888889501') AS admin_claims \gset
SELECT pg_temp.ria_login('9888889502') AS staff_claims \gset
SELECT pg_temp.ria_login('9888889503') AS customer_claims \gset
INSERT INTO public.customers(name, mobile) VALUES ('Invoice Amounts Quince Cold', '9888889511') RETURNING id AS quince \gset
INSERT INTO public.customers(name, mobile) VALUES ('Invoice Amounts Rowan Agro', '9888889512') RETURNING id AS rowan \gset
INSERT INTO public.items(name, packaging) VALUES ('Invoice Amounts Fennel', 'Bag') RETURNING id AS fennel \gset
-- The customer login is assigned to Quince only.
INSERT INTO public.users_customers_new(user_profile_id, customer_id, active)
 SELECT id, :'quince'::uuid, true FROM public.user_profiles WHERE mobile = '919888889503';
-- No invoice, payment or other customer is in the way of the all-customers figures.
SELECT pg_temp.ria_assert((SELECT count(*) FROM public.invoice) = 0 AND (SELECT count(*) FROM public.payments) = 0,
  'the database holds no invoice or payment before the fixture');

SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
--                      no    customer             name                          item        supervisor       bags receipt        dispatch     invoice      charge labour tax  discount
SELECT pg_temp.ria_invoice(6101, :'quince'::uuid, 'Invoice Amounts Quince Cold', :'fennel'::uuid, :'admin_profile', 1, '2026-09-01', '2026-09-10', '2026-09-20', 10, 2.5, 5, 0);
SELECT pg_temp.ria_invoice(6104, :'quince'::uuid, 'Invoice Amounts Quince Cold', :'fennel'::uuid, :'admin_profile', 2, '2026-09-03', '2026-09-12', '2026-09-25', 40, 4, 12, 10);
SELECT pg_temp.ria_invoice(6102, :'quince'::uuid, 'Invoice Amounts Quince Cold', :'fennel'::uuid, :'admin_profile', 4, '2026-09-05', '2026-10-01', '2026-10-05', 25, 3, 5, 7.5);
SELECT pg_temp.ria_invoice(6103, :'quince'::uuid, 'Invoice Amounts Quince Cold', :'fennel'::uuid, :'admin_profile', 10, '2026-10-01', '2026-10-06', '2026-10-12', 8, 1.2, 18, 0);
SELECT pg_temp.ria_invoice(6105, :'quince'::uuid, 'Invoice Amounts Quince Cold', :'fennel'::uuid, :'admin_profile', 3, '2026-07-01', '2026-07-10', '2026-07-15', 20, 2, 0, 0);
SELECT pg_temp.ria_invoice(6107, :'rowan'::uuid, 'Invoice Amounts Rowan Agro', :'fennel'::uuid, :'admin_profile', 2, '2026-09-02', '2026-09-08', '2026-09-15', 30, 5, 5, 3);
SELECT pg_temp.ria_invoice(6106, :'rowan'::uuid, 'Invoice Amounts Rowan Agro', :'fennel'::uuid, :'admin_profile', 6, '2026-10-01', '2026-10-04', '2026-10-08', 15, 2, 5, 0);
RESET ROLE;

-- Payments, written as the superuser the way the Tally functions write them (one row per allocation):
-- 6101 one row; 6102 TWO rows, the later date carries the LOWER payment number and is inserted first,
-- so that "the latest" cannot be taken for the highest number or the last inserted; 6107 one row.
INSERT INTO public.payments(payment_no, payment_date, customer_id, customer_name, amount, payment_mode, cheque_no, online_ref, invoice_id)
SELECT p.payment_no, p.payment_date::timestamptz, i.customer_id, i.customer_name, p.amount, p.payment_mode, p.cheque_no, p.online_ref, i.id
FROM (VALUES
  ('RIAP-1',  '2026-09-22T12:00:00Z', 14, 'ONLINE', NULL,     'UTR-1', 6101),
  ('RIAP-2A', '2026-10-20T06:00:00Z', 51, 'ONLINE', NULL,     'UTR-9', 6102),
  ('RIAP-2B', '2026-10-10T06:00:00Z', 60, 'CHEQUE', '000123', NULL,    6102),
  ('RIAP-3',  '2026-09-30T12:00:00Z', 71, 'ONLINE', NULL,     'UTR-3', 6107)
) AS p(payment_no, payment_date, amount, payment_mode, cheque_no, online_ref, inv_no)
JOIN public.invoice i ON i.inv_fin_year = 2026 AND i.inv_no = p.inv_no;
SELECT pg_temp.ria_assert((SELECT count(*) FROM public.payments) = 4
  AND (SELECT count(*) FROM public.payments WHERE invoice_id = (SELECT id FROM public.invoice WHERE inv_no = 6102)) = 2,
  'fixture: four payment rows, two of them for invoice 6102');

-- What the table says, worked out apart from the functions: each header as the real save code computed it,
-- and the old sum, which differs from the total for every one of them.
SELECT pg_temp.ria_assert((SELECT string_agg(inv_no || ':' || total || '/' || labour || '/' || tax_amount || '/' || discount, ' ' ORDER BY inv_no)
      FROM public.invoice)
    = '6101:14.00/2.50/1.00/0.00 6102:111.00/12.00/6.00/7.50 6103:109.00/12.00/17.00/0.00 6104:89.00/8.00/11.00/10.00 6105:66.00/6.00/0.00/0.00 6106:108.00/12.00/6.00/0.00 6107:71.00/10.00/4.00/3.00',
  'fixture: the headers the save code computed (inv_no:total/labour/tax/discount)');
SELECT pg_temp.ria_assert((SELECT string_agg((total + labour + tax_amount - discount)::text, ' ' ORDER BY inv_no) FROM public.invoice)
    = '17.50 121.50 138.00 98.00 72.00 126.00 82.00'
  AND (SELECT bool_and(total + labour + tax_amount - discount <> total) FROM public.invoice),
  'fixture: the old sum differs from the total for every invoice');
SELECT COALESCE(sum(total), 0) AS table_quince_period FROM public.invoice
 WHERE customer_id = :'quince'::uuid AND inv_date >= '2026-09-01T00:00:00+05:30' AND inv_date < '2026-11-01T00:00:00+05:30' \gset
SELECT COALESCE(sum(total), 0) AS table_all_period FROM public.invoice
 WHERE inv_date >= '2026-09-01T00:00:00+05:30' AND inv_date < '2026-11-01T00:00:00+05:30' \gset
SELECT pg_temp.ria_assert(:'table_quince_period' = '323.00' AND :'table_all_period' = '502.00',
  'the table holds 323 for Quince and 502 for everyone in the period: ' || :'table_quince_period' || ' / ' || :'table_all_period');

-- ---------------------------------------------------------------------------
-- The answers, each read as the role under test
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.get_customer_invoice_summary(:'quince'::uuid, '2026-09-01', '2026-10-31')::text AS admin_quince \gset
SELECT public.get_customer_invoice_summary(:'rowan'::uuid, '2026-09-01', '2026-10-31')::text AS admin_rowan \gset
SELECT public.get_customer_invoice_summary(NULL, '2026-09-01', '2026-10-31')::text AS admin_all \gset
SELECT public.get_customer_activity_detail(:'quince'::uuid, '2026-09-01', '2026-10-31')::text AS admin_detail \gset
SELECT public.get_all_customer_activity_summary('2026-09-01', '2026-10-31')::text AS admin_activity \gset
RESET ROLE;

SELECT set_config('request.jwt.claims', :'staff_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ria_assert(warehouse_security.active_role() = 'staff', 'actual staff role');
SELECT public.get_customer_invoice_summary(:'quince'::uuid, '2026-09-01', '2026-10-31')::text AS staff_quince \gset
SELECT public.get_customer_invoice_summary(:'rowan'::uuid, '2026-09-01', '2026-10-31')::text AS staff_rowan \gset
SELECT public.get_customer_invoice_summary(NULL, '2026-09-01', '2026-10-31')::text AS staff_all \gset
SELECT public.get_customer_activity_detail(:'quince'::uuid, '2026-09-01', '2026-10-31')::text AS staff_detail \gset
SELECT public.get_customer_activity_detail(:'rowan'::uuid, '2026-09-01', '2026-10-31')::text AS staff_detail_rowan \gset
SELECT public.get_all_customer_activity_summary('2026-09-01', '2026-10-31')::text AS staff_activity \gset
SELECT public.get_customer_invoice_summary(:'quince'::uuid, '2026-10-01', '2026-10-31')::text AS staff_quince_oct \gset
SELECT public.get_customer_invoice_summary(:'quince'::uuid, '2026-09-01', '2026-09-30')::text AS staff_quince_sep \gset
RESET ROLE;

SELECT set_config('request.jwt.claims', :'customer_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ria_assert(warehouse_security.active_role() = 'customer', 'actual customer role');
SELECT public.get_customer_invoice_summary(:'quince'::uuid, '2026-09-01', '2026-10-31')::text AS customer_quince \gset
SELECT public.get_customer_activity_detail(:'quince'::uuid, '2026-09-01', '2026-10-31')::text AS customer_detail \gset
SELECT pg_temp.ria_refusal(format('SELECT public.get_customer_invoice_summary(%L::uuid, %L::date, %L::date)', :'rowan', '2026-09-01', '2026-10-31')) AS customer_rowan \gset
SELECT pg_temp.ria_refusal(format('SELECT public.get_customer_activity_detail(%L::uuid, %L::date, %L::date)', :'rowan', '2026-09-01', '2026-10-31')) AS customer_detail_rowan \gset
SELECT pg_temp.ria_refusal(format('SELECT public.get_customer_invoice_summary(NULL, %L::date, %L::date)', '2026-09-01', '2026-10-31')) AS customer_all \gset
SELECT pg_temp.ria_refusal(format('SELECT public.get_all_customer_activity_summary(%L::date, %L::date)', '2026-09-01', '2026-10-31')) AS customer_activity \gset
SELECT pg_temp.ria_refusal(format('SELECT public.get_customer_invoice_summary(%L::uuid, %L::date, %L::date)', :'quince', '2026-09-01', '2026-10-31')) AS customer_quince_check \gset
SELECT pg_temp.ria_refusal(format('SELECT public.get_customer_activity_detail(%L::uuid, %L::date, %L::date)', :'quince', '2026-09-01', '2026-10-31')) AS customer_detail_check \gset
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Invoice history, one customer (Quince): every invoice once, every amount the invoice's own
-- ---------------------------------------------------------------------------
-- The four invoices of the period, newest first: 6103, 6102, 6104, 6101. 6102 has two payment rows and
-- is listed ONCE; the count is 4, not 5.
SELECT pg_temp.ria_assert(pg_temp.ria_col(:'staff_quince'::jsonb#>'{data,invoices}', 'invoice_number') = ARRAY['2026-6103', '2026-6102', '2026-6104', '2026-6101']
  AND jsonb_array_length(:'staff_quince'::jsonb#>'{data,invoices}') = 4
  AND (:'staff_quince'::jsonb#>>'{data,summary,total_invoices}') = '4',
  'staff: Quince has four invoices, 6102 (two payment rows) once: ' || :'staff_quince');
-- Each invoice's total is its own, net_total is the same number (it was total + labour + tax - discount: 138,
-- 121.50, 98, 17.50), and labour, tax and discount are the header's.
SELECT pg_temp.ria_assert(pg_temp.ria_nums(:'staff_quince'::jsonb#>'{data,invoices}', 'total') = ARRAY[109, 111, 89, 14]::numeric[]
  AND pg_temp.ria_nums(:'staff_quince'::jsonb#>'{data,invoices}', 'net_total') = ARRAY[109, 111, 89, 14]::numeric[]
  AND pg_temp.ria_nums(:'staff_quince'::jsonb#>'{data,invoices}', 'labour') = ARRAY[12, 12, 8, 2.5]::numeric[]
  AND pg_temp.ria_nums(:'staff_quince'::jsonb#>'{data,invoices}', 'tax_amount') = ARRAY[17, 6, 11, 1]::numeric[]
  AND pg_temp.ria_nums(:'staff_quince'::jsonb#>'{data,invoices}', 'discount') = ARRAY[0, 7.5, 10, 0]::numeric[],
  'staff: total and net_total of each Quince invoice are 109, 111, 89, 14, and labour, tax and discount are the header''s: ' || :'staff_quince');
SELECT pg_temp.ria_assert(bool_and((x->>'net_total')::numeric = (x->>'total')::numeric AND jsonb_typeof(x->'net_total') = 'number'),
  'staff: net_total equals total on every Quince invoice and is a number')
FROM jsonb_array_elements(:'staff_quince'::jsonb#>'{data,invoices}') AS t(x);
-- The worked example: 1 bag, charge 10, labour 2.50, tax 5%: total 14 (not 17.50).
SELECT pg_temp.ria_assert((pg_temp.ria_invoice_of(:'staff_quince'::jsonb, '2026-6101')->>'total')::numeric = 14
  AND (pg_temp.ria_invoice_of(:'staff_quince'::jsonb, '2026-6101')->>'net_total')::numeric = 14,
  'staff: the worked example is 14, not 17.50: ' || COALESCE(pg_temp.ria_invoice_of(:'staff_quince'::jsonb, '2026-6101')::text, 'missing'));
-- The payment status: one entry per invoice. 6101 one row; 6102 the sum of its rows (111), the reference, mode
-- and date of the LATEST row (20 Oct, UTR-9, ONLINE; the earlier 10 Oct row is a cheque 000123); the others pending.
SELECT pg_temp.ria_assert((SELECT array_agg(x#>>'{payment_status,status}' ORDER BY ord) FROM jsonb_array_elements(:'staff_quince'::jsonb#>'{data,invoices}') WITH ORDINALITY AS t(x, ord))
    = ARRAY['pending', 'paid', 'pending', 'paid'],
  'staff: paid for 6102 and 6101, pending for 6103 and 6104: ' || :'staff_quince');
SELECT pg_temp.ria_assert((pg_temp.ria_invoice_of(:'staff_quince'::jsonb, '2026-6102')#>>'{payment_status,amount}')::numeric = 111
  AND (pg_temp.ria_invoice_of(:'staff_quince'::jsonb, '2026-6102')#>>'{payment_status,payment_ref}') = 'UTR-9'
  AND (pg_temp.ria_invoice_of(:'staff_quince'::jsonb, '2026-6102')#>>'{payment_status,payment_mode}') = 'ONLINE'
  AND (pg_temp.ria_invoice_of(:'staff_quince'::jsonb, '2026-6102')#>>'{payment_status,paid_date}')::timestamptz = '2026-10-20T06:00:00Z'::timestamptz
  AND pg_temp.ria_keys(pg_temp.ria_invoice_of(:'staff_quince'::jsonb, '2026-6102')->'payment_status') = 'amount,paid_date,payment_mode,payment_ref,status',
  'staff: 6102 is paid with the sum of its two rows (111) and the date, reference and mode of the latest: ' || COALESCE(pg_temp.ria_invoice_of(:'staff_quince'::jsonb, '2026-6102')::text, 'missing'));
SELECT pg_temp.ria_assert((pg_temp.ria_invoice_of(:'staff_quince'::jsonb, '2026-6101')#>>'{payment_status,amount}')::numeric = 14
  AND (pg_temp.ria_invoice_of(:'staff_quince'::jsonb, '2026-6101')#>>'{payment_status,payment_ref}') = 'UTR-1'
  AND (pg_temp.ria_invoice_of(:'staff_quince'::jsonb, '2026-6101')#>>'{payment_status,payment_mode}') = 'ONLINE'
  AND (pg_temp.ria_invoice_of(:'staff_quince'::jsonb, '2026-6101')#>>'{payment_status,paid_date}')::timestamptz = '2026-09-22T12:00:00Z'::timestamptz
  AND pg_temp.ria_keys(pg_temp.ria_invoice_of(:'staff_quince'::jsonb, '2026-6101')->'payment_status') = 'amount,paid_date,payment_mode,payment_ref,status',
  'staff: 6101, one payment row, is answered as before: ' || COALESCE(pg_temp.ria_invoice_of(:'staff_quince'::jsonb, '2026-6101')::text, 'missing'));
SELECT pg_temp.ria_assert(pg_temp.ria_keys(pg_temp.ria_invoice_of(:'staff_quince'::jsonb, '2026-6103')->'payment_status') = 'paid_date,payment_ref,status'
  AND (pg_temp.ria_invoice_of(:'staff_quince'::jsonb, '2026-6103')#>>'{payment_status,status}') = 'pending'
  AND pg_temp.ria_keys(pg_temp.ria_invoice_of(:'staff_quince'::jsonb, '2026-6104')->'payment_status') = 'paid_date,payment_ref,status',
  'staff: an invoice without a payment row is pending with the keys it had: ' || COALESCE(pg_temp.ria_invoice_of(:'staff_quince'::jsonb, '2026-6103')::text, 'missing'));
-- The summary: net_amount = total_amount, paid + pending = total_amount (it was 375, 139 and 236); the counts
-- count 6102 once; labour, tax and discount are sums of the header's.
SELECT pg_temp.ria_assert((:'staff_quince'::jsonb#>>'{data,summary,total_amount}')::numeric = 323
  AND (:'staff_quince'::jsonb#>>'{data,summary,net_amount}')::numeric = 323
  AND (:'staff_quince'::jsonb#>>'{data,summary,paid_amount}')::numeric = 125
  AND (:'staff_quince'::jsonb#>>'{data,summary,pending_amount}')::numeric = 198
  AND (:'staff_quince'::jsonb#>>'{data,summary,paid_amount}')::numeric + (:'staff_quince'::jsonb#>>'{data,summary,pending_amount}')::numeric
      = (:'staff_quince'::jsonb#>>'{data,summary,total_amount}')::numeric
  AND (:'staff_quince'::jsonb#>>'{data,summary,paid_count}') = '2' AND (:'staff_quince'::jsonb#>>'{data,summary,pending_count}') = '2'
  AND (:'staff_quince'::jsonb#>>'{data,summary,total_labour}')::numeric = 34.5
  AND (:'staff_quince'::jsonb#>>'{data,summary,total_tax}')::numeric = 35
  AND (:'staff_quince'::jsonb#>>'{data,summary,total_discount}')::numeric = 17.5
  AND (:'staff_quince'::jsonb#>>'{data,summary,total_amount}') = :'table_quince_period',
  'staff: Quince summary is total 323 = net 323 = paid 125 + pending 198, from the table''s 323: ' || :'staff_quince');
SELECT pg_temp.ria_assert(jsonb_typeof(:'staff_quince'::jsonb#>'{data,summary,net_amount}') = 'number'
  AND jsonb_typeof(:'staff_quince'::jsonb#>'{data,summary,paid_amount}') = 'number'
  AND jsonb_typeof(:'staff_quince'::jsonb#>'{data,summary,pending_amount}') = 'number'
  AND jsonb_typeof(:'staff_quince'::jsonb#>'{data,summary,total_amount}') = 'number',
  'staff: the amounts of the summary are numbers');
-- By month, newest first: October 6102 (paid) and 6103 (pending), September 6101 (paid) and 6104 (pending).
SELECT pg_temp.ria_assert(pg_temp.ria_col(:'staff_quince'::jsonb#>'{data,by_month}', 'month') = ARRAY['2026-10', '2026-09']
  AND pg_temp.ria_col(:'staff_quince'::jsonb#>'{data,by_month}', 'invoice_count') = ARRAY['2', '2']
  AND pg_temp.ria_nums(:'staff_quince'::jsonb#>'{data,by_month}', 'total_amount') = ARRAY[220, 103]::numeric[]
  AND pg_temp.ria_nums(:'staff_quince'::jsonb#>'{data,by_month}', 'paid_amount') = ARRAY[111, 14]::numeric[]
  AND pg_temp.ria_nums(:'staff_quince'::jsonb#>'{data,by_month}', 'pending_amount') = ARRAY[109, 89]::numeric[],
  'staff: Quince by month: Oct 220 = 111 + 109, Sep 103 = 14 + 89: ' || :'staff_quince');
-- A period of one month reads the same way (October only; September only).
SELECT pg_temp.ria_assert((:'staff_quince_oct'::jsonb#>>'{data,summary,total_amount}')::numeric = 220
  AND (:'staff_quince_oct'::jsonb#>>'{data,summary,net_amount}')::numeric = 220
  AND (:'staff_quince_oct'::jsonb#>>'{data,summary,paid_amount}')::numeric = 111
  AND (:'staff_quince_oct'::jsonb#>>'{data,summary,pending_amount}')::numeric = 109
  AND (:'staff_quince_oct'::jsonb#>>'{data,summary,total_invoices}') = '2'
  AND (:'staff_quince_sep'::jsonb#>>'{data,summary,total_amount}')::numeric = 103
  AND (:'staff_quince_sep'::jsonb#>>'{data,summary,net_amount}')::numeric = 103
  AND (:'staff_quince_sep'::jsonb#>>'{data,summary,paid_amount}')::numeric = 14
  AND (:'staff_quince_sep'::jsonb#>>'{data,summary,pending_amount}')::numeric = 89,
  'staff: October alone is 220 (paid 111, pending 109) and September alone 103 (paid 14, pending 89): ' || :'staff_quince_oct' || ' / ' || :'staff_quince_sep');
-- The keys of the answer, the summary, an invoice and a month are the same as before.
SELECT pg_temp.ria_assert(pg_temp.ria_keys(:'staff_quince'::jsonb) = 'data,metadata,success'
  AND pg_temp.ria_keys(:'staff_quince'::jsonb->'data') = 'by_month,invoices,summary'
  AND pg_temp.ria_keys(:'staff_quince'::jsonb#>'{data,summary}') = 'net_amount,paid_amount,paid_count,pending_amount,pending_count,total_amount,total_discount,total_invoices,total_labour,total_tax'
  AND pg_temp.ria_keys(:'staff_quince'::jsonb#>'{data,by_month,0}') = 'invoice_count,month,paid_amount,pending_amount,total_amount',
  'staff: the keys of the Quince answer, its summary and its months: ' || :'staff_quince');
-- Migration 62 adds balance_amount and paid_amount to each invoice (tests/report_invoice_paid.sql checks their values).
SELECT pg_temp.ria_assert(count(*) = 4 AND bool_and(pg_temp.ria_keys(x) = 'balance_amount,discount,financial_year,grn_id,grn_ref,invoice_date,invoice_id,invoice_number,item_count,labour,line_items,net_total,notes,paid_amount,payment_status,tax_amount,total,total_quantity'),
  'staff: the keys of each Quince invoice')
FROM jsonb_array_elements(:'staff_quince'::jsonb#>'{data,invoices}') AS t(x);
-- An administrator is answered the same (everything but the time of the answer).
SELECT pg_temp.ria_assert((:'admin_quince'::jsonb)->'data' = (:'staff_quince'::jsonb)->'data', 'administrator and staff are answered alike: ' || :'admin_quince');

-- Rowan: 6106 pending (108), 6107 paid with one row (71).
SELECT pg_temp.ria_assert(pg_temp.ria_col(:'staff_rowan'::jsonb#>'{data,invoices}', 'invoice_number') = ARRAY['2026-6106', '2026-6107']
  AND pg_temp.ria_nums(:'staff_rowan'::jsonb#>'{data,invoices}', 'total') = ARRAY[108, 71]::numeric[]
  AND pg_temp.ria_nums(:'staff_rowan'::jsonb#>'{data,invoices}', 'net_total') = ARRAY[108, 71]::numeric[]
  AND (:'staff_rowan'::jsonb#>>'{data,summary,total_amount}')::numeric = 179
  AND (:'staff_rowan'::jsonb#>>'{data,summary,net_amount}')::numeric = 179
  AND (:'staff_rowan'::jsonb#>>'{data,summary,paid_amount}')::numeric = 71
  AND (:'staff_rowan'::jsonb#>>'{data,summary,pending_amount}')::numeric = 108
  AND pg_temp.ria_col(:'staff_rowan'::jsonb#>'{data,by_month}', 'month') = ARRAY['2026-10', '2026-09']
  AND pg_temp.ria_nums(:'staff_rowan'::jsonb#>'{data,by_month}', 'paid_amount') = ARRAY[0, 71]::numeric[]
  AND pg_temp.ria_nums(:'staff_rowan'::jsonb#>'{data,by_month}', 'pending_amount') = ARRAY[108, 0]::numeric[]
  AND position('2026-6101' in :'staff_rowan') = 0,
  'staff: Rowan total 179 = net 179 = paid 71 + pending 108, none of Quince''s invoices: ' || :'staff_rowan');

-- ---------------------------------------------------------------------------
-- Invoice history, all customers
-- ---------------------------------------------------------------------------
SELECT pg_temp.ria_assert((:'staff_all'::jsonb#>>'{data,summary,total_invoices}') = '6'
  AND (:'staff_all'::jsonb#>>'{data,summary,total_customers}') = '2'
  AND (:'staff_all'::jsonb#>>'{data,summary,total_amount}')::numeric = 502
  AND (:'staff_all'::jsonb#>>'{data,summary,net_amount}')::numeric = 502
  AND (:'staff_all'::jsonb#>>'{data,summary,total_tax}')::numeric = 45
  AND (:'staff_all'::jsonb#>>'{data,summary,total_amount}') = :'table_all_period'
  AND jsonb_typeof(:'staff_all'::jsonb#>'{data,summary,net_amount}') = 'number'
  AND pg_temp.ria_keys(:'staff_all'::jsonb#>'{data,summary}') = 'net_amount,total_amount,total_customers,total_invoices,total_tax',
  'staff: all customers: 6 invoices, total 502 = net 502 (it was 583), tax 45: ' || :'staff_all');
SELECT pg_temp.ria_assert(pg_temp.ria_col(:'staff_all'::jsonb#>'{data,by_customer}', 'customer_name') = ARRAY['Invoice Amounts Quince Cold', 'Invoice Amounts Rowan Agro']
  AND pg_temp.ria_col(:'staff_all'::jsonb#>'{data,by_customer}', 'invoice_count') = ARRAY['4', '2']
  AND pg_temp.ria_nums(:'staff_all'::jsonb#>'{data,by_customer}', 'total_amount') = ARRAY[323, 179]::numeric[]
  AND pg_temp.ria_nums(:'staff_all'::jsonb#>'{data,by_customer}', 'net_amount') = ARRAY[323, 179]::numeric[]
  AND pg_temp.ria_keys(:'staff_all'::jsonb#>'{data,by_customer,0}') = 'customer_id,customer_name,invoice_count,latest_invoice_date,net_amount,total_amount',
  'staff: all customers by customer: Quince 323 = 323 and Rowan 179 = 179 (they were 375 and 208): ' || :'staff_all');
SELECT pg_temp.ria_assert(pg_temp.ria_col(:'staff_all'::jsonb#>'{data,by_month}', 'month') = ARRAY['2026-10', '2026-09']
  AND pg_temp.ria_col(:'staff_all'::jsonb#>'{data,by_month}', 'invoice_count') = ARRAY['3', '3']
  AND pg_temp.ria_nums(:'staff_all'::jsonb#>'{data,by_month}', 'total_amount') = ARRAY[328, 174]::numeric[]
  AND pg_temp.ria_keys(:'staff_all'::jsonb#>'{data,by_month,0}') = 'invoice_count,month,total_amount'
  AND pg_temp.ria_keys(:'staff_all'::jsonb->'data') = 'by_customer,by_month,summary',
  'staff: all customers by month: Oct 328 in 3, Sep 174 in 3: ' || :'staff_all');
SELECT pg_temp.ria_assert((:'admin_all'::jsonb)->'data' = (:'staff_all'::jsonb)->'data'
  AND (:'admin_rowan'::jsonb)->'data' = (:'staff_rowan'::jsonb)->'data',
  'administrator and staff are answered alike for Rowan and for all customers: ' || :'admin_all');

-- ---------------------------------------------------------------------------
-- Customer activity detail (Quince)
-- ---------------------------------------------------------------------------
-- The period's invoice amount is the sum of the totals (it was 375), the pending amount is that minus the three
-- payment rows (125): 198 (it was 250). Both agree with the invoice history above.
SELECT pg_temp.ria_assert((:'staff_detail'::jsonb#>>'{data,summary,total_invoice_amount}')::numeric = 323
  AND (:'staff_detail'::jsonb#>>'{data,summary,total_paid_amount}')::numeric = 125
  AND (:'staff_detail'::jsonb#>>'{data,summary,total_pending_amount}')::numeric = 198
  AND (:'staff_detail'::jsonb#>>'{data,summary,total_invoice_amount}')::numeric = (:'staff_quince'::jsonb#>>'{data,summary,total_amount}')::numeric
  AND (:'staff_detail'::jsonb#>>'{data,summary,total_pending_amount}')::numeric = (:'staff_quince'::jsonb#>>'{data,summary,pending_amount}')::numeric
  AND (:'staff_detail'::jsonb#>>'{data,summary,total_invoice_amount}') = :'table_quince_period'
  AND jsonb_typeof(:'staff_detail'::jsonb#>'{data,summary,total_invoice_amount}') = 'number'
  AND jsonb_typeof(:'staff_detail'::jsonb#>'{data,summary,total_pending_amount}') = 'number',
  'staff: activity detail: invoiced 323, paid 125, pending 198: ' || :'staff_detail');
SELECT pg_temp.ria_assert(pg_temp.ria_col(:'staff_detail'::jsonb#>'{data,monthly_trends}', 'month') = ARRAY['2026-09', '2026-10']
  AND pg_temp.ria_nums(:'staff_detail'::jsonb#>'{data,monthly_trends}', 'invoice_amount') = ARRAY[103, 220]::numeric[],
  'staff: activity detail months: Sep 103 and Oct 220 (they were 115.50 and 259.50): ' || (:'staff_detail'::jsonb#>>'{data,monthly_trends}'));
-- The five latest invoices (the period does not apply): 6103, 6102, 6104, 6101, then 6105 of July. 6102 once.
SELECT pg_temp.ria_assert(pg_temp.ria_col(:'staff_detail'::jsonb#>'{data,recent_invoices}', 'invoice_number') = ARRAY['2026-6103', '2026-6102', '2026-6104', '2026-6101', '2026-6105']
  AND pg_temp.ria_nums(:'staff_detail'::jsonb#>'{data,recent_invoices}', 'net_total') = ARRAY[109, 111, 89, 14, 66]::numeric[]
  AND pg_temp.ria_col(:'staff_detail'::jsonb#>'{data,recent_invoices}', 'status') = ARRAY['pending', 'paid', 'pending', 'paid', 'pending']
  AND jsonb_typeof(:'staff_detail'::jsonb#>'{data,recent_invoices,0,net_total}') = 'number',
  'staff: activity detail recent invoices: 109, 111, 89, 14, 66 (they were 138, 121.50, 98, 17.50, 72): ' || (:'staff_detail'::jsonb#>>'{data,recent_invoices}'));
-- Key sets.
SELECT pg_temp.ria_assert(pg_temp.ria_keys(:'staff_detail'::jsonb) = 'data,metadata,success'
  AND pg_temp.ria_keys(:'staff_detail'::jsonb->'data') = 'by_bucket,customer_city,customer_id,customer_name,monthly_trends,recent_dispatches,recent_grns,recent_invoices,summary,top_stock_items'
  AND pg_temp.ria_keys(:'staff_detail'::jsonb#>'{data,summary}') = 'average_stock_age_days,current_stock,total_dispatch_quantity,total_dispatches,total_grn_quantity,total_grns,total_invoice_amount,total_paid_amount,total_pending_amount'
  AND pg_temp.ria_keys(:'staff_detail'::jsonb#>'{data,monthly_trends,0}') = 'dispatch_count,dispatch_quantity,grn_count,grn_quantity,invoice_amount,month,stock_level_end'
  AND pg_temp.ria_keys(:'staff_detail'::jsonb#>'{data,recent_invoices,0}') = 'invoice_date,invoice_id,invoice_number,net_total,status',
  'staff: the keys of the activity detail: ' || :'staff_detail');
-- Rowan's detail is Rowan's: 179 invoiced, 71 paid, 108 pending.
SELECT pg_temp.ria_assert((:'staff_detail_rowan'::jsonb#>>'{data,summary,total_invoice_amount}')::numeric = 179
  AND (:'staff_detail_rowan'::jsonb#>>'{data,summary,total_paid_amount}')::numeric = 71
  AND (:'staff_detail_rowan'::jsonb#>>'{data,summary,total_pending_amount}')::numeric = 108
  AND pg_temp.ria_nums(:'staff_detail_rowan'::jsonb#>'{data,monthly_trends}', 'invoice_amount') = ARRAY[71, 108]::numeric[]
  AND pg_temp.ria_nums(:'staff_detail_rowan'::jsonb#>'{data,recent_invoices}', 'net_total') = ARRAY[108, 71]::numeric[],
  'staff: Rowan activity detail: invoiced 179, paid 71, pending 108: ' || :'staff_detail_rowan');
SELECT pg_temp.ria_assert((:'admin_detail'::jsonb)->'data' = (:'staff_detail'::jsonb)->'data',
  'administrator and staff are answered alike for the activity detail: ' || :'admin_detail');

-- ---------------------------------------------------------------------------
-- All-customers activity summary
-- ---------------------------------------------------------------------------
SELECT pg_temp.ria_assert((pg_temp.ria_row(:'staff_activity'::jsonb#>'{data,customers}', 'customer_id', :'quince')->>'total_invoice_amount')::numeric = 323
  AND (pg_temp.ria_row(:'staff_activity'::jsonb#>'{data,customers}', 'customer_id', :'rowan')->>'total_invoice_amount')::numeric = 179
  AND (:'staff_activity'::jsonb#>>'{data,summary,total_invoice_amount}')::numeric = 502
  AND (:'staff_activity'::jsonb#>>'{data,summary,total_invoice_amount}')::numeric = (SELECT sum((x->>'total_invoice_amount')::numeric) FROM jsonb_array_elements(:'staff_activity'::jsonb#>'{data,customers}') AS t(x))
  AND (:'staff_activity'::jsonb#>>'{data,summary,total_invoice_amount}') = :'table_all_period'
  AND (:'staff_activity'::jsonb#>>'{data,summary,total_customers}') = '2'
  AND jsonb_typeof(:'staff_activity'::jsonb#>'{data,summary,total_invoice_amount}') = 'number'
  AND jsonb_typeof(:'staff_activity'::jsonb#>'{data,customers,0,total_invoice_amount}') = 'number',
  'staff: all-customers activity: Quince 323, Rowan 179, together 502 (they were 375, 208, 583): ' || :'staff_activity');
SELECT pg_temp.ria_assert(pg_temp.ria_keys(:'staff_activity'::jsonb) = 'data,metadata,success'
  AND pg_temp.ria_keys(:'staff_activity'::jsonb->'data') = 'customers,summary'
  AND pg_temp.ria_keys(:'staff_activity'::jsonb#>'{data,summary}') = 'total_current_stock,total_customers,total_dispatches,total_grns,total_invoice_amount'
  AND pg_temp.ria_keys(:'staff_activity'::jsonb#>'{data,customers,0}') = 'current_stock,customer_city,customer_id,customer_name,last_activity_date,last_activity_type,total_dispatches,total_grns,total_invoice_amount',
  'staff: the keys of the all-customers activity answer: ' || :'staff_activity');
SELECT pg_temp.ria_assert((:'admin_activity'::jsonb)->'data' = (:'staff_activity'::jsonb)->'data',
  'administrator and staff are answered alike for the all-customers activity: ' || :'admin_activity');

-- ---------------------------------------------------------------------------
-- A customer account: its own customer's figures, nobody else's
-- ---------------------------------------------------------------------------
SELECT pg_temp.ria_assert((:'customer_quince'::jsonb)->'data' = (:'staff_quince'::jsonb)->'data'
  AND (:'customer_quince'::jsonb#>>'{data,summary,net_amount}')::numeric = 323
  AND (:'customer_detail'::jsonb)->'data' = (:'staff_detail'::jsonb)->'data'
  AND (:'customer_detail'::jsonb#>>'{data,summary,total_invoice_amount}')::numeric = 323,
  'customer account: its own customer''s invoice history and activity carry the real amounts: ' || :'customer_quince');
-- The refusal check can tell an answer from a refusal: the same calls for its own customer are answered.
SELECT pg_temp.ria_assert(:'customer_quince_check' LIKE 'answered: %' AND :'customer_detail_check' LIKE 'answered: %',
  'the refusal check answers "answered" for allowed calls: ' || :'customer_quince_check' || ' / ' || :'customer_detail_check');
-- Another customer's id, all customers and the all-customers activity are refused, so none of Rowan's amounts can be learned.
SELECT pg_temp.ria_assert(:'customer_rowan' = 'refused: 42501 Failed to retrieve invoice summary: Customer access denied'
  AND :'customer_detail_rowan' = 'refused: 42501 Failed to retrieve customer activity detail: Customer access denied'
  AND :'customer_all' = 'refused: 42501 Failed to retrieve invoice summary: Customer access denied'
  AND :'customer_activity' = 'refused: 42501 Failed to retrieve customer activity summary: Staff access required',
  'customer account: another customer, all customers and the all-customers activity were not refused: ' || :'customer_rowan' || ' | ' || :'customer_detail_rowan' || ' | ' || :'customer_all' || ' | ' || :'customer_activity');

ROLLBACK;
SELECT 'report invoice amounts: the invoice amounts of the invoice history, the customer activity detail and the all-customers activity are the invoice total, an invoice with two payment rows is listed and summed once, the keys are unchanged, and a customer account still gets only its own customer' AS result;

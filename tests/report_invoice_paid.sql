-- Paid and Pending in the invoice reports follow the money (migration 62).
--
-- The owner's rule: "Paid is the money received and Pending is what is still owed. An invoice counts as
-- Paid only when nothing is owed; a part-paid invoice stays Pending with the balance." Per invoice:
-- received = the sum of its payments.amount, never below 0 and never above its total; balance = total -
-- received; status 'paid' when balance <= 0.50 (the tolerance get_open_invoices_for_customer uses),
-- otherwise 'pending'. Before migration 62 an invoice was paid as soon as ANY payment row named it, and its
-- whole total counted as paid.
--
-- Every invoice is made by public.save_invoice, so its total is computed by the real code (rates as in
-- tests/report_invoice_amounts.sql, one period each: total 14, 89, 111, 109, 66, 71, 108, 66, and 0).
-- Payments are inserted as the superuser, the way the Tally functions write them.
--
--   no    customer inv_date  total  payments (rows)             received  balance  status   (migration 61: status, paid)
--   6201  Quince   20 Sep      14   4.00                           4.00    10.00   pending  paid, 14     part payment
--   6202  Quince   25 Sep      89   none                           0       89.00   pending  pending      unpaid
--   6203  Quince   05 Oct     111   51.00 (20 Oct) + 60.00 (10 Oct) 111      0      paid     paid, 111    two rows that pay in full
--   6204  Quince   08 Oct     109   108.50                       108.50     0.50    paid     paid, 109    0.50 owed: within the tolerance
--   6205  Quince   12 Oct      66   65.49                         65.49     0.51    pending  paid, 66     0.51 owed: just outside it
--   6207  Rowan    15 Sep      71   71.00                           71       0      paid     paid, 71     exact payment
--   6208  Rowan    08 Oct     108   120.00                         108       0      paid     paid, 108    over-payment (12 too much)
--   6209  Rowan    10 Oct      66   66.50                           66       0      paid     paid, 66     over-payment by 0.50
--   6210  Rowan    11 Oct       0   none                             0       0      paid     pending      nothing is owed on an invoice of 0
-- The period used is 1 Sep to 31 Oct 2026.
--
--   Quince, period:  total 389; Paid (received) 4 + 111 + 108.50 + 65.49 = 288.99; Pending (balances) 10 + 89 + 0.50
--                    + 0.51 = 100.01; paid_count 2 (6203, 6204), pending_count 3. Oct: total 286 = 284.99 + 1.01,
--                    Sep: 103 = 4 + 99. (Migration 61 said Paid 300 and Pending 89, paid_count 4.)
--   Rowan, period:   total 245; Paid 71 + 108 + 66 + 0 = 245 (not the 257.50 paid); Pending 0; paid_count 4.
--   all customers:   634 in 9 invoices (nothing paid or pending is returned there: the branch is untouched).
--   activity detail: Quince invoiced 389, total_paid_amount 288.99 (the payments, unchanged), total_pending_amount
--                    100.01; recent invoices (5 latest) pending, paid, paid, pending, pending. Rowan invoiced 245,
--                    total_paid_amount 257.50 (the payments, over-payments included: unchanged), total_pending_amount
--                    0 (it was 245 - 257.50 = -12.50); recent invoices all paid.
--
-- A wrong rule tells itself apart on this data: the old "any row" status gives 6201 and 6205 paid and 6210 pending;
-- a received figure that is not capped gives Rowan Paid 257.50 and a negative Pending in the detail; a tolerance
-- of 0 gives 6204 pending, a tolerance of 0.51 gives 6205 paid.
--
-- Each answer is read as the role under test and compared AFTER the role is dropped.
-- Runs ONLY in migrations.sh's fresh, network-disabled database. All fixture rows roll back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.rip_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'report invoice paid: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.rip_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.rip_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- A receipt of one item, its full dispatch and an invoice for that dispatch, as the administrator:
-- bags, the three dates (receipt, dispatch, invoice), the rates per bag and the discount.
CREATE FUNCTION pg_temp.rip_invoice(p_no integer, p_customer uuid, p_customer_name text, p_item uuid, p_supervisor text,
  p_bags integer, p_grn_day text, p_disp_day text, p_inv_day text, p_charge numeric, p_labour numeric, p_tax numeric, p_discount numeric)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE trl_id uuid; grn_id uuid; line_id uuid; saved jsonb;
BEGIN
  PERFORM pg_temp.rip_assert(public.save_grn(p_gr_no => 'RIPG' || p_no, p_date => (p_grn_day || 'T12:00:00Z')::timestamptz,
      p_customer_id => p_customer, p_customer_name => p_customer_name, p_pricing_mode => 'MONTHLY',
      p_idempotency_key => 'report-invoice-paid-g' || p_no,
      p_items => jsonb_build_array(jsonb_build_object('item_id', p_item, 'item_name', 'Invoice Paid Fennel', 'packaging', 'Bag',
        'qty', p_bags, 'weight', 10)))->>'success' = 'true', 'fixture receipt RIPG' || p_no);
  SELECT g.id, t.id INTO grn_id, trl_id FROM public.goodsreceived g JOIN public.goodsreceived_trl t ON t.gr_id = g.id WHERE g.gr_no = 'RIPG' || p_no;
  PERFORM pg_temp.rip_assert(public.create_dispatch_with_stock_check(jsonb_build_object('disp_no', 'RIPD' || p_no,
      'disp_date', p_disp_day, 'customer_id', p_customer, 'customer_name', p_customer_name,
      'supervisor_id', p_supervisor, 'supervisor_name', 'Invoice Paid Administrator'),
    ARRAY[jsonb_build_object('gr_trl_id', trl_id, 'disp_qty', p_bags)], 0, 'report-invoice-paid-d' || p_no)->>'success' = 'true',
    'fixture dispatch RIPD' || p_no);
  SELECT dt.id INTO line_id FROM public.dispatch_trl dt JOIN public.dispatch d ON d.id = dt.disp_id WHERE d.disp_no = 'RIPD' || p_no;
  saved := public.save_invoice(jsonb_build_object('inv_no', p_no, 'inv_fin_year', 2026, 'gr_id', grn_id, 'gr_no', 'RIPG' || p_no,
    'customer_id', p_customer, 'customer_name', p_customer_name, 'inv_date', p_inv_day || 'T12:00:00Z',
    'discount', p_discount, 'duration_mode', 'legacy',
    'items', jsonb_build_array(jsonb_build_object('disp_trl_id', line_id, 'charge', p_charge, 'tax', p_tax, 'labour_rate', p_labour))));
  PERFORM pg_temp.rip_assert(saved->>'success' = 'true', 'fixture invoice ' || p_no || ': ' || saved::text);
END $$;
-- One field of every element of an array, in the returned order, as text and as numbers.
CREATE FUNCTION pg_temp.rip_col(arr jsonb, value_key text) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(x->>value_key ORDER BY ord), '{}')
  FROM jsonb_array_elements(arr) WITH ORDINALITY AS t(x, ord) $$;
CREATE FUNCTION pg_temp.rip_nums(arr jsonb, value_key text) RETURNS numeric[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg((x->>value_key)::numeric ORDER BY ord), '{}')
  FROM jsonb_array_elements(arr) WITH ORDINALITY AS t(x, ord) $$;
-- The same for a key inside each element's payment_status.
CREATE FUNCTION pg_temp.rip_pay(arr jsonb, value_key text) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(x#>>ARRAY['payment_status', value_key] ORDER BY ord), '{}')
  FROM jsonb_array_elements(arr) WITH ORDINALITY AS t(x, ord) $$;
-- The keys of an object, sorted bytewise, as one text.
CREATE FUNCTION pg_temp.rip_keys(o jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(k, ',' ORDER BY k COLLATE "C") FROM jsonb_object_keys(o) AS t(k) $$;
-- The invoice of an answer's invoices[] with that number (as a whole object), NULL when absent.
CREATE FUNCTION pg_temp.rip_invoice_of(answer jsonb, number_text text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT x FROM jsonb_array_elements(answer#>'{data,invoices}') AS t(x) WHERE x->>'invoice_number' = number_text $$;
-- The element of an array whose key has that value, NULL when absent.
CREATE FUNCTION pg_temp.rip_row(arr jsonb, key_name text, key_value text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT x FROM jsonb_array_elements(arr) AS t(x) WHERE x->>key_name = key_value $$;
-- 'answered: ...' when the statement returns an answer with success true; 'refused: <code> <error>' when it
-- returns the guard's refusal (these reports catch the 42501 and answer success false with its text), or the
-- error text when the statement itself raises 42501. Any other error stops the test.
CREATE FUNCTION pg_temp.rip_refusal(statement text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  EXECUTE statement INTO answer;
  IF answer->>'success' = 'true' THEN RETURN 'answered: ' || left(answer::text, 120); END IF;
  RETURN 'refused: ' || COALESCE(answer->>'error_code', '') || ' ' || COALESCE(answer->>'error', '');
EXCEPTION WHEN insufficient_privilege THEN RETURN SQLERRM;
END $$;
-- The number of times a text occurs in another.
CREATE FUNCTION pg_temp.rip_count(haystack text, needle text) RETURNS integer LANGUAGE sql AS $$
  SELECT (length(haystack) - length(replace(haystack, needle, ''))) / length(needle) $$;

SELECT pg_temp.rip_assert(current_setting('TimeZone') = 'UTC', 'the session time zone is UTC');

-- ---------------------------------------------------------------------------
-- The functions: single, guarded first, the old status is gone, the rest is as before
-- ---------------------------------------------------------------------------
SELECT pg_temp.rip_assert((SELECT count(*) FROM pg_proc p WHERE p.proname = f.name) = 1,
  'exactly one function named ' || f.name || ', in any schema')
FROM (VALUES ('get_customer_invoice_summary'), ('get_customer_activity_detail'), ('get_all_customer_activity_summary')) AS f(name);
SELECT pg_temp.rip_assert(p.prosecdef
    AND pg_get_functiondef(p.oid) ~ ('BEGIN\s+PERFORM warehouse_security\.authorize_rpc\(''' || p.proname || ''','),
  'SECURITY DEFINER, and the guard comes first in ' || p.proname)
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
  AND p.proname IN ('get_customer_invoice_summary', 'get_customer_activity_detail', 'get_all_customer_activity_summary');
-- The search_path and the grants are what they were: a fixed search_path (with jit off), the app role may
-- execute, the anonymous role may not, as the sibling report get_customer_stock_summary.
SELECT pg_temp.rip_assert(p.proconfig = ARRAY['search_path=pg_catalog, public, extensions, utils, pg_temp', 'jit=off'],
  'search_path and jit of ' || p.proname || ': ' || COALESCE(p.proconfig::text, 'none'))
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
  AND p.proname IN ('get_customer_invoice_summary', 'get_customer_activity_detail', 'get_all_customer_activity_summary');
SELECT pg_temp.rip_assert(has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
    AND p.proacl IS NOT DISTINCT FROM (SELECT s.proacl FROM pg_proc s WHERE s.oid = 'public.get_customer_stock_summary(uuid)'::regprocedure),
  'grants of ' || p.proname || ': authenticated may execute, anon may not, as its sibling get_customer_stock_summary: ' || COALESCE(p.proacl::text, 'none'))
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
  AND p.proname IN ('get_customer_invoice_summary', 'get_customer_activity_detail', 'get_all_customer_activity_summary');
-- The text: the sums of the old "any row" status are gone and the rule is written the stated number of times; the
-- India day cuts (migrations 54, 56), the payment status of migration 61 and the net_total of migration 61 are kept.
SELECT pg_temp.rip_assert(pg_get_functiondef(p.oid) NOT LIKE '%THEN net_total ELSE 0 END%'
    AND pg_get_functiondef(p.oid) NOT LIKE '%FROM invoices_full WHERE (payment_status->>''status'') = ''paid''), 0)%'
    AND pg_get_functiondef(p.oid) NOT LIKE '%FROM invoices_full WHERE (payment_status->>''status'') = ''pending''), 0)%'
    AND pg_temp.rip_count(pg_get_functiondef(p.oid), 'jsonb_set(') = 1
    AND pg_temp.rip_count(pg_get_functiondef(p.oid), 'WHEN bal.balance <= 0.50 THEN') = 1
    AND pg_temp.rip_count(pg_get_functiondef(p.oid), 'GREATEST(0, LEAST(COALESCE(ps.paid_sum, 0), COALESCE(id.total, 0)))') = 1
    AND pg_temp.rip_count(pg_get_functiondef(p.oid), 'SUM(received_amount)') = 2
    AND pg_temp.rip_count(pg_get_functiondef(p.oid), 'SUM(balance_amount)') = 2
    AND pg_temp.rip_count(pg_get_functiondef(p.oid), '''paid_amount'', received_amount,') = 1
    AND pg_temp.rip_count(pg_get_functiondef(p.oid), '''balance_amount'', balance_amount,') = 1
    AND pg_temp.rip_count(pg_get_functiondef(p.oid), 'FROM invoices_full WHERE (payment_status->>''status'') = ''paid'')') = 1
    AND pg_temp.rip_count(pg_get_functiondef(p.oid), 'FROM invoices_full WHERE (payment_status->>''status'') = ''pending'')') = 1
    AND pg_temp.rip_count(pg_get_functiondef(p.oid), 'COALESCE(i.total, 0) as net_total') = 2
    AND pg_temp.rip_count(pg_get_functiondef(p.oid), 'DISTINCT ON (p.invoice_id)') = 1
    AND pg_get_functiondef(p.oid) LIKE '%i.inv_date >= warehouse_security.business_day_start(v_from_date)%'
    AND pg_get_functiondef(p.oid) LIKE '%TO_CHAR(warehouse_security.business_date(invoice_date), ''YYYY-MM'')%',
  'get_customer_invoice_summary: the rule is written once for the status and twice each for the sums, the counts read the status, the earlier fixes are kept')
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'get_customer_invoice_summary';
SELECT pg_temp.rip_assert(pg_get_functiondef(p.oid) NOT LIKE '%EXISTS (SELECT 1 FROM payments p WHERE p.invoice_id = i.id)%'
    AND pg_get_functiondef(p.oid) NOT LIKE '%COALESCE(id.total_invoice_amount, 0) - COALESCE(pd.total_paid_amount, 0)%'
    AND pg_temp.rip_count(pg_get_functiondef(p.oid), '<= 0.50') = 1
    AND pg_temp.rip_count(pg_get_functiondef(p.oid), 'GREATEST(0, LEAST(') = 2
    AND pg_temp.rip_count(pg_get_functiondef(p.oid), '''total_pending_amount'', COALESCE(id.total_pending_amount, 0),') = 1
    AND pg_temp.rip_count(pg_get_functiondef(p.oid), 'COALESCE(SUM(p.amount), 0) as total_paid_amount') = 1
    AND pg_temp.rip_count(pg_get_functiondef(p.oid), 'SUM(COALESCE(total, 0)), 0)') = 2
    AND pg_temp.rip_count(pg_get_functiondef(p.oid), 'COALESCE(i.total, 0) as net_total') = 1
    AND pg_get_functiondef(p.oid) LIKE '%inv_date >= warehouse_security.business_day_start(p_from_date)%',
  'get_customer_activity_detail: the status and the pending amount follow the rule, the paid amount is still the payments, the earlier fixes are kept')
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'get_customer_activity_detail';
-- The all-customers activity summary returns no paid or pending figure and does not read payments.
SELECT pg_temp.rip_assert(pg_get_functiondef(p.oid) NOT LIKE '%payments%' AND pg_get_functiondef(p.oid) NOT LIKE '%paid%' AND pg_get_functiondef(p.oid) NOT LIKE '%pending%',
  'get_all_customer_activity_summary has no paid or pending figure')
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'get_all_customer_activity_summary';

-- ---------------------------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------------------------
INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888889601', 'Invoice Paid Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888889602', 'Invoice Paid Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888889603', 'Invoice Paid Customer', 'customer', true, 'approved');
SELECT id AS admin_profile FROM public.user_profiles WHERE mobile = '919888889601' \gset
SELECT pg_temp.rip_login('9888889601') AS admin_claims \gset
SELECT pg_temp.rip_login('9888889602') AS staff_claims \gset
SELECT pg_temp.rip_login('9888889603') AS customer_claims \gset
INSERT INTO public.customers(name, mobile) VALUES ('Invoice Paid Quince Cold', '9888889611') RETURNING id AS quince \gset
INSERT INTO public.customers(name, mobile) VALUES ('Invoice Paid Rowan Agro', '9888889612') RETURNING id AS rowan \gset
INSERT INTO public.items(name, packaging) VALUES ('Invoice Paid Fennel', 'Bag') RETURNING id AS fennel \gset
-- The customer login is assigned to Quince only.
INSERT INTO public.users_customers_new(user_profile_id, customer_id, active)
 SELECT id, :'quince'::uuid, true FROM public.user_profiles WHERE mobile = '919888889603';
-- No invoice, payment or other customer is in the way of the all-customers figures.
SELECT pg_temp.rip_assert((SELECT count(*) FROM public.invoice) = 0 AND (SELECT count(*) FROM public.payments) = 0,
  'the database holds no invoice or payment before the fixture');

SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
--                      no    customer             name                         item        supervisor       bags receipt        dispatch     invoice      charge labour tax  discount
SELECT pg_temp.rip_invoice(6201, :'quince'::uuid, 'Invoice Paid Quince Cold', :'fennel'::uuid, :'admin_profile', 1, '2026-09-01', '2026-09-10', '2026-09-20', 10, 2.5, 5, 0);
SELECT pg_temp.rip_invoice(6202, :'quince'::uuid, 'Invoice Paid Quince Cold', :'fennel'::uuid, :'admin_profile', 2, '2026-09-03', '2026-09-12', '2026-09-25', 40, 4, 12, 10);
SELECT pg_temp.rip_invoice(6203, :'quince'::uuid, 'Invoice Paid Quince Cold', :'fennel'::uuid, :'admin_profile', 4, '2026-09-05', '2026-10-01', '2026-10-05', 25, 3, 5, 7.5);
SELECT pg_temp.rip_invoice(6204, :'quince'::uuid, 'Invoice Paid Quince Cold', :'fennel'::uuid, :'admin_profile', 10, '2026-10-01', '2026-10-06', '2026-10-08', 8, 1.2, 18, 0);
SELECT pg_temp.rip_invoice(6205, :'quince'::uuid, 'Invoice Paid Quince Cold', :'fennel'::uuid, :'admin_profile', 3, '2026-10-02', '2026-10-09', '2026-10-12', 20, 2, 0, 0);
SELECT pg_temp.rip_invoice(6207, :'rowan'::uuid, 'Invoice Paid Rowan Agro', :'fennel'::uuid, :'admin_profile', 2, '2026-09-02', '2026-09-08', '2026-09-15', 30, 5, 5, 3);
SELECT pg_temp.rip_invoice(6208, :'rowan'::uuid, 'Invoice Paid Rowan Agro', :'fennel'::uuid, :'admin_profile', 6, '2026-10-01', '2026-10-04', '2026-10-08', 15, 2, 5, 0);
SELECT pg_temp.rip_invoice(6209, :'rowan'::uuid, 'Invoice Paid Rowan Agro', :'fennel'::uuid, :'admin_profile', 3, '2026-10-02', '2026-10-05', '2026-10-10', 20, 2, 0, 0);
SELECT pg_temp.rip_invoice(6210, :'rowan'::uuid, 'Invoice Paid Rowan Agro', :'fennel'::uuid, :'admin_profile', 1, '2026-10-03', '2026-10-04', '2026-10-11', 0, 0, 0, 0);
RESET ROLE;

-- Payments, written as the superuser the way the Tally functions write them (one row per allocation):
-- 6203 has TWO rows, the later date carries the LOWER payment number and is inserted first, so that "the latest"
-- cannot be taken for the highest number or the last inserted. 6202 and 6210 have none.
INSERT INTO public.payments(payment_no, payment_date, customer_id, customer_name, amount, payment_mode, cheque_no, online_ref, invoice_id)
SELECT p.payment_no, p.payment_date::timestamptz, i.customer_id, i.customer_name, p.amount, p.payment_mode, p.cheque_no, p.online_ref, i.id
FROM (VALUES
  ('RIPP-1',  '2026-09-22T12:00:00Z',   4.00, 'ONLINE', NULL,     'UTR-1', 6201),
  ('RIPP-3A', '2026-10-20T06:00:00Z',  51.00, 'ONLINE', NULL,     'UTR-9', 6203),
  ('RIPP-3B', '2026-10-10T06:00:00Z',  60.00, 'CHEQUE', '000123', NULL,    6203),
  ('RIPP-4',  '2026-10-09T12:00:00Z', 108.50, 'ONLINE', NULL,     'UTR-4', 6204),
  ('RIPP-5',  '2026-10-13T12:00:00Z',  65.49, 'ONLINE', NULL,     'UTR-5', 6205),
  ('RIPP-7',  '2026-09-30T12:00:00Z',  71.00, 'ONLINE', NULL,     'UTR-7', 6207),
  ('RIPP-8',  '2026-10-09T12:00:00Z', 120.00, 'ONLINE', NULL,     'UTR-8', 6208),
  ('RIPP-9',  '2026-10-11T12:00:00Z',  66.50, 'ONLINE', NULL,     'UTR-9B', 6209)
) AS p(payment_no, payment_date, amount, payment_mode, cheque_no, online_ref, inv_no)
JOIN public.invoice i ON i.inv_fin_year = 2026 AND i.inv_no = p.inv_no;
SELECT pg_temp.rip_assert((SELECT count(*) FROM public.payments) = 8
  AND (SELECT count(*) FROM public.payments WHERE invoice_id = (SELECT id FROM public.invoice WHERE inv_no = 6203)) = 2,
  'fixture: eight payment rows, two of them for invoice 6203');

-- What the tables say, worked out apart from the functions: each header as the real save code computed it ...
SELECT pg_temp.rip_assert((SELECT string_agg(inv_no || ':' || total, ' ' ORDER BY inv_no) FROM public.invoice)
    = '6201:14.00 6202:89.00 6203:111.00 6204:109.00 6205:66.00 6207:71.00 6208:108.00 6209:66.00 6210:0.00',
  'fixture: the totals the save code computed (inv_no:total)');
-- ... and the paid and pending figures of the rule, from the tables with plain CASE arithmetic (no GREATEST/LEAST).
CREATE TEMP TABLE rip_money ON COMMIT DROP AS
SELECT i.id, i.customer_id, i.inv_no, i.inv_date, i.total,
       COALESCE((SELECT sum(p.amount) FROM public.payments p WHERE p.invoice_id = i.id), 0) AS pay
FROM public.invoice i;
SELECT COALESCE(sum(total), 0) AS table_q_total,
       COALESCE(sum(CASE WHEN pay >= total THEN total WHEN pay <= 0 THEN 0 ELSE pay END), 0) AS table_q_paid,
       COALESCE(sum(CASE WHEN pay >= total THEN 0 WHEN pay <= 0 THEN total ELSE total - pay END), 0) AS table_q_pending,
       count(*) FILTER (WHERE total - pay <= 0.50) AS table_q_paid_count,
       count(*) FILTER (WHERE total - pay > 0.50) AS table_q_pending_count,
       COALESCE(sum(pay), 0) AS table_q_payments
FROM rip_money WHERE customer_id = :'quince'::uuid AND inv_date >= '2026-09-01T00:00:00+05:30' AND inv_date < '2026-11-01T00:00:00+05:30' \gset
SELECT COALESCE(sum(total), 0) AS table_r_total,
       COALESCE(sum(CASE WHEN pay >= total THEN total WHEN pay <= 0 THEN 0 ELSE pay END), 0) AS table_r_paid,
       COALESCE(sum(CASE WHEN pay >= total THEN 0 WHEN pay <= 0 THEN total ELSE total - pay END), 0) AS table_r_pending,
       count(*) FILTER (WHERE total - pay <= 0.50) AS table_r_paid_count,
       COALESCE(sum(pay), 0) AS table_r_payments
FROM rip_money WHERE customer_id = :'rowan'::uuid AND inv_date >= '2026-09-01T00:00:00+05:30' AND inv_date < '2026-11-01T00:00:00+05:30' \gset
SELECT COALESCE(sum(total), 0) AS table_all_total FROM rip_money
 WHERE inv_date >= '2026-09-01T00:00:00+05:30' AND inv_date < '2026-11-01T00:00:00+05:30' \gset
SELECT pg_temp.rip_assert(:'table_q_total'::numeric = 389 AND :'table_q_paid'::numeric = 288.99 AND :'table_q_pending'::numeric = 100.01
    AND :'table_q_paid_count'::int = 2 AND :'table_q_pending_count'::int = 3 AND :'table_q_payments'::numeric = 288.99,
  'the tables hold for Quince: total 389, received 288.99, owed 100.01, 2 paid, 3 pending: '
    || :'table_q_total' || ' / ' || :'table_q_paid' || ' / ' || :'table_q_pending' || ' / ' || :'table_q_paid_count' || ' / ' || :'table_q_pending_count');
SELECT pg_temp.rip_assert(:'table_r_total'::numeric = 245 AND :'table_r_paid'::numeric = 245 AND :'table_r_pending'::numeric = 0
    AND :'table_r_paid_count'::int = 4 AND :'table_r_payments'::numeric = 257.50 AND :'table_all_total'::numeric = 634,
  'the tables hold for Rowan: total 245, received 245 (of 257.50 paid), owed 0, 4 paid; everyone 634: '
    || :'table_r_total' || ' / ' || :'table_r_paid' || ' / ' || :'table_r_pending' || ' / ' || :'table_r_paid_count' || ' / ' || :'table_r_payments' || ' / ' || :'table_all_total');
-- The data tells the old rule from the new: "any row" counts the whole total of Quince's invoices that have a payment row
-- (6201, 6203, 6204, 6205: 14 + 111 + 109 + 66 = 300) as paid, and Rowan's payments exceed his totals.
SELECT pg_temp.rip_assert((SELECT sum(total) FROM rip_money WHERE customer_id = :'quince'::uuid AND pay > 0) = 300
    AND (SELECT sum(pay) - sum(total) FROM rip_money WHERE customer_id = :'rowan'::uuid) = 12.50,
  'fixture: the old rule would count 300 as paid for Quince, and Rowan paid 12.50 too much');

-- ---------------------------------------------------------------------------
-- The answers, each read as the role under test
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.get_customer_invoice_summary(:'quince'::uuid, '2026-09-01', '2026-10-31')::text AS admin_quince \gset
SELECT public.get_customer_invoice_summary(:'rowan'::uuid, '2026-09-01', '2026-10-31')::text AS admin_rowan \gset
SELECT public.get_customer_invoice_summary(NULL, '2026-09-01', '2026-10-31')::text AS admin_all \gset
SELECT public.get_customer_activity_detail(:'quince'::uuid, '2026-09-01', '2026-10-31')::text AS admin_detail \gset
SELECT public.get_customer_activity_detail(:'rowan'::uuid, '2026-09-01', '2026-10-31')::text AS admin_detail_rowan \gset
SELECT public.get_all_customer_activity_summary('2026-09-01', '2026-10-31')::text AS admin_activity \gset
RESET ROLE;

SELECT set_config('request.jwt.claims', :'staff_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rip_assert(warehouse_security.active_role() = 'staff', 'actual staff role');
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
SELECT pg_temp.rip_assert(warehouse_security.active_role() = 'customer', 'actual customer role');
SELECT public.get_customer_invoice_summary(:'quince'::uuid, '2026-09-01', '2026-10-31')::text AS customer_quince \gset
SELECT public.get_customer_activity_detail(:'quince'::uuid, '2026-09-01', '2026-10-31')::text AS customer_detail \gset
SELECT pg_temp.rip_refusal(format('SELECT public.get_customer_invoice_summary(%L::uuid, %L::date, %L::date)', :'rowan', '2026-09-01', '2026-10-31')) AS customer_rowan \gset
SELECT pg_temp.rip_refusal(format('SELECT public.get_customer_activity_detail(%L::uuid, %L::date, %L::date)', :'rowan', '2026-09-01', '2026-10-31')) AS customer_detail_rowan \gset
SELECT pg_temp.rip_refusal(format('SELECT public.get_customer_invoice_summary(NULL, %L::date, %L::date)', '2026-09-01', '2026-10-31')) AS customer_all \gset
SELECT pg_temp.rip_refusal(format('SELECT public.get_all_customer_activity_summary(%L::date, %L::date)', '2026-09-01', '2026-10-31')) AS customer_activity \gset
SELECT pg_temp.rip_refusal(format('SELECT public.get_customer_invoice_summary(%L::uuid, %L::date, %L::date)', :'quince', '2026-09-01', '2026-10-31')) AS customer_quince_check \gset
SELECT pg_temp.rip_refusal(format('SELECT public.get_customer_activity_detail(%L::uuid, %L::date, %L::date)', :'quince', '2026-09-01', '2026-10-31')) AS customer_detail_check \gset
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Invoice history, one customer (Quince): the status, received and balance of every invoice
-- ---------------------------------------------------------------------------
-- The five invoices of the period, newest first: 6205, 6204, 6203, 6202, 6201. 6203 has two payment rows and is listed ONCE.
SELECT pg_temp.rip_assert(pg_temp.rip_col(:'staff_quince'::jsonb#>'{data,invoices}', 'invoice_number') = ARRAY['2026-6205', '2026-6204', '2026-6203', '2026-6202', '2026-6201']
  AND jsonb_array_length(:'staff_quince'::jsonb#>'{data,invoices}') = 5
  AND pg_temp.rip_nums(:'staff_quince'::jsonb#>'{data,invoices}', 'total') = ARRAY[66, 109, 111, 89, 14]::numeric[],
  'staff: Quince has five invoices, newest first, totals 66, 109, 111, 89, 14: ' || :'staff_quince');
-- The status is the rule's: only 6204 (0.50 owed) and 6203 (nothing owed) are paid. 6201 (4.00 of 14.00) and 6205 (0.51 owed)
-- have a payment row and are pending; 6202 has none. It was paid, pending, paid, paid... as soon as a row existed.
SELECT pg_temp.rip_assert(pg_temp.rip_pay(:'staff_quince'::jsonb#>'{data,invoices}', 'status') = ARRAY['pending', 'paid', 'paid', 'pending', 'pending'],
  'staff: statuses of 6205, 6204, 6203, 6202, 6201 are pending, paid, paid, pending, pending: ' || :'staff_quince');
-- The money received and the balance of each invoice (two new keys), and received + balance = total.
SELECT pg_temp.rip_assert(pg_temp.rip_nums(:'staff_quince'::jsonb#>'{data,invoices}', 'paid_amount') = ARRAY[65.49, 108.50, 111, 0, 4]::numeric[]
  AND pg_temp.rip_nums(:'staff_quince'::jsonb#>'{data,invoices}', 'balance_amount') = ARRAY[0.51, 0.50, 0, 89, 10]::numeric[],
  'staff: received 65.49, 108.50, 111, 0, 4 and balance 0.51, 0.50, 0, 89, 10: ' || :'staff_quince');
SELECT pg_temp.rip_assert(count(*) = 5
    AND bool_and((x->>'paid_amount')::numeric + (x->>'balance_amount')::numeric = (x->>'total')::numeric)
    AND bool_and(jsonb_typeof(x->'paid_amount') = 'number' AND jsonb_typeof(x->'balance_amount') = 'number')
    AND bool_and((x#>>'{payment_status,status}') = CASE WHEN (x->>'balance_amount')::numeric <= 0.50 THEN 'paid' ELSE 'pending' END),
  'staff: received + balance = total on every Quince invoice, both are numbers, and the status is paid exactly when the balance is 0.50 or less')
FROM jsonb_array_elements(:'staff_quince'::jsonb#>'{data,invoices}') AS t(x);
-- The part payment: 4.00 of 14.00 is Pending with a balance of 10.00 and keeps the payment details; the amount is the sum of the rows.
SELECT pg_temp.rip_assert((pg_temp.rip_invoice_of(:'staff_quince'::jsonb, '2026-6201')#>>'{payment_status,status}') = 'pending'
  AND (pg_temp.rip_invoice_of(:'staff_quince'::jsonb, '2026-6201')->>'paid_amount')::numeric = 4
  AND (pg_temp.rip_invoice_of(:'staff_quince'::jsonb, '2026-6201')->>'balance_amount')::numeric = 10
  AND (pg_temp.rip_invoice_of(:'staff_quince'::jsonb, '2026-6201')#>>'{payment_status,amount}')::numeric = 4
  AND (pg_temp.rip_invoice_of(:'staff_quince'::jsonb, '2026-6201')#>>'{payment_status,payment_ref}') = 'UTR-1'
  AND (pg_temp.rip_invoice_of(:'staff_quince'::jsonb, '2026-6201')#>>'{payment_status,payment_mode}') = 'ONLINE'
  AND (pg_temp.rip_invoice_of(:'staff_quince'::jsonb, '2026-6201')#>>'{payment_status,paid_date}')::timestamptz = '2026-09-22T12:00:00Z'::timestamptz
  AND pg_temp.rip_keys(pg_temp.rip_invoice_of(:'staff_quince'::jsonb, '2026-6201')->'payment_status') = 'amount,paid_date,payment_mode,payment_ref,status',
  'staff: 6201 (the worked example, 4.00 of 14.00) is pending with received 4 and balance 10: ' || COALESCE(pg_temp.rip_invoice_of(:'staff_quince'::jsonb, '2026-6201')::text, 'missing'));
-- Two rows that together pay in full (51.00 on 20 Oct, 60.00 on 10 Oct): paid, amount 111, the latest row's reference.
SELECT pg_temp.rip_assert((pg_temp.rip_invoice_of(:'staff_quince'::jsonb, '2026-6203')#>>'{payment_status,status}') = 'paid'
  AND (pg_temp.rip_invoice_of(:'staff_quince'::jsonb, '2026-6203')#>>'{payment_status,amount}')::numeric = 111
  AND (pg_temp.rip_invoice_of(:'staff_quince'::jsonb, '2026-6203')->>'paid_amount')::numeric = 111
  AND (pg_temp.rip_invoice_of(:'staff_quince'::jsonb, '2026-6203')->>'balance_amount')::numeric = 0
  AND (pg_temp.rip_invoice_of(:'staff_quince'::jsonb, '2026-6203')#>>'{payment_status,payment_ref}') = 'UTR-9'
  AND (pg_temp.rip_invoice_of(:'staff_quince'::jsonb, '2026-6203')#>>'{payment_status,paid_date}')::timestamptz = '2026-10-20T06:00:00Z'::timestamptz,
  'staff: 6203, two rows of 60 and 51, is paid with received 111 and balance 0: ' || COALESCE(pg_temp.rip_invoice_of(:'staff_quince'::jsonb, '2026-6203')::text, 'missing'));
-- The tolerance on both sides of 0.50: 108.50 of 109 leaves 0.50 (paid); 65.49 of 66 leaves 0.51 (pending).
SELECT pg_temp.rip_assert((pg_temp.rip_invoice_of(:'staff_quince'::jsonb, '2026-6204')#>>'{payment_status,status}') = 'paid'
  AND (pg_temp.rip_invoice_of(:'staff_quince'::jsonb, '2026-6204')->>'balance_amount')::numeric = 0.50
  AND (pg_temp.rip_invoice_of(:'staff_quince'::jsonb, '2026-6205')#>>'{payment_status,status}') = 'pending'
  AND (pg_temp.rip_invoice_of(:'staff_quince'::jsonb, '2026-6205')->>'balance_amount')::numeric = 0.51,
  'staff: 0.50 owed is paid (6204) and 0.51 owed is pending (6205): ' || :'staff_quince');
-- Unpaid: pending, received 0, balance = total, and no payment details (the keys it had).
SELECT pg_temp.rip_assert((pg_temp.rip_invoice_of(:'staff_quince'::jsonb, '2026-6202')#>>'{payment_status,status}') = 'pending'
  AND (pg_temp.rip_invoice_of(:'staff_quince'::jsonb, '2026-6202')->>'paid_amount')::numeric = 0
  AND (pg_temp.rip_invoice_of(:'staff_quince'::jsonb, '2026-6202')->>'balance_amount')::numeric = 89
  AND pg_temp.rip_keys(pg_temp.rip_invoice_of(:'staff_quince'::jsonb, '2026-6202')->'payment_status') = 'paid_date,payment_ref,status',
  'staff: 6202, no payment, is pending with received 0 and balance 89: ' || COALESCE(pg_temp.rip_invoice_of(:'staff_quince'::jsonb, '2026-6202')::text, 'missing'));
-- The keys of an invoice: the ones it had and the two new ones, nothing else.
SELECT pg_temp.rip_assert(count(*) = 5 AND bool_and(pg_temp.rip_keys(x) = 'balance_amount,discount,financial_year,grn_id,grn_ref,invoice_date,invoice_id,invoice_number,item_count,labour,line_items,net_total,notes,paid_amount,payment_status,tax_amount,total,total_quantity'),
  'staff: the keys of each Quince invoice are the earlier ones plus balance_amount and paid_amount')
FROM jsonb_array_elements(:'staff_quince'::jsonb#>'{data,invoices}') AS t(x);

-- ---------------------------------------------------------------------------
-- Invoice history, one customer (Quince): summary and months
-- ---------------------------------------------------------------------------
-- Paid is the money received, Pending the balances, and together the total: 288.99 + 100.01 = 389 (it was 300 + 89, 4 paid).
SELECT pg_temp.rip_assert((:'staff_quince'::jsonb#>>'{data,summary,total_amount}')::numeric = 389
  AND (:'staff_quince'::jsonb#>>'{data,summary,paid_amount}')::numeric = 288.99
  AND (:'staff_quince'::jsonb#>>'{data,summary,pending_amount}')::numeric = 100.01
  AND (:'staff_quince'::jsonb#>>'{data,summary,paid_amount}')::numeric + (:'staff_quince'::jsonb#>>'{data,summary,pending_amount}')::numeric
      = (:'staff_quince'::jsonb#>>'{data,summary,total_amount}')::numeric
  AND (:'staff_quince'::jsonb#>>'{data,summary,net_amount}')::numeric = 389
  AND (:'staff_quince'::jsonb#>>'{data,summary,paid_count}') = '2' AND (:'staff_quince'::jsonb#>>'{data,summary,pending_count}') = '3'
  AND (:'staff_quince'::jsonb#>>'{data,summary,total_invoices}') = '5'
  AND (:'staff_quince'::jsonb#>>'{data,summary,total_labour}')::numeric = 12 + 12 + 8 + 2.5 + 6
  AND (:'staff_quince'::jsonb#>>'{data,summary,total_tax}')::numeric = 35,
  'staff: Quince summary is total 389 = paid 288.99 + pending 100.01, 2 paid and 3 pending invoices: ' || :'staff_quince');
-- ... and it agrees with the tables worked out apart from the function.
SELECT pg_temp.rip_assert((:'staff_quince'::jsonb#>>'{data,summary,total_amount}')::numeric = :'table_q_total'::numeric
  AND (:'staff_quince'::jsonb#>>'{data,summary,paid_amount}')::numeric = :'table_q_paid'::numeric
  AND (:'staff_quince'::jsonb#>>'{data,summary,pending_amount}')::numeric = :'table_q_pending'::numeric
  AND (:'staff_quince'::jsonb#>>'{data,summary,paid_count}')::int = :'table_q_paid_count'::int
  AND (:'staff_quince'::jsonb#>>'{data,summary,pending_count}')::int = :'table_q_pending_count'::int,
  'staff: the Quince summary equals the figures worked out from the tables: ' || :'staff_quince');
SELECT pg_temp.rip_assert(jsonb_typeof(:'staff_quince'::jsonb#>'{data,summary,paid_amount}') = 'number'
  AND jsonb_typeof(:'staff_quince'::jsonb#>'{data,summary,pending_amount}') = 'number'
  AND jsonb_typeof(:'staff_quince'::jsonb#>'{data,summary,paid_count}') = 'number'
  AND jsonb_typeof(:'staff_quince'::jsonb#>'{data,summary,pending_count}') = 'number',
  'staff: the paid and pending figures of the summary are numbers');
-- By month, newest first: October (6203, 6204, 6205) 286 = 284.99 + 1.01, September (6201, 6202) 103 = 4 + 99.
SELECT pg_temp.rip_assert(pg_temp.rip_col(:'staff_quince'::jsonb#>'{data,by_month}', 'month') = ARRAY['2026-10', '2026-09']
  AND pg_temp.rip_col(:'staff_quince'::jsonb#>'{data,by_month}', 'invoice_count') = ARRAY['3', '2']
  AND pg_temp.rip_nums(:'staff_quince'::jsonb#>'{data,by_month}', 'total_amount') = ARRAY[286, 103]::numeric[]
  AND pg_temp.rip_nums(:'staff_quince'::jsonb#>'{data,by_month}', 'paid_amount') = ARRAY[284.99, 4]::numeric[]
  AND pg_temp.rip_nums(:'staff_quince'::jsonb#>'{data,by_month}', 'pending_amount') = ARRAY[1.01, 99]::numeric[],
  'staff: Quince by month: Oct 286 = 284.99 + 1.01, Sep 103 = 4 + 99: ' || :'staff_quince');
SELECT pg_temp.rip_assert(count(*) = 2 AND bool_and((x->>'paid_amount')::numeric + (x->>'pending_amount')::numeric = (x->>'total_amount')::numeric
      AND jsonb_typeof(x->'paid_amount') = 'number' AND jsonb_typeof(x->'pending_amount') = 'number'),
  'staff: paid + pending = total in each Quince month, and both are numbers')
FROM jsonb_array_elements(:'staff_quince'::jsonb#>'{data,by_month}') AS t(x);
-- A period of one month reads the same way (October only; September only).
SELECT pg_temp.rip_assert((:'staff_quince_oct'::jsonb#>>'{data,summary,total_amount}')::numeric = 286
  AND (:'staff_quince_oct'::jsonb#>>'{data,summary,paid_amount}')::numeric = 284.99
  AND (:'staff_quince_oct'::jsonb#>>'{data,summary,pending_amount}')::numeric = 1.01
  AND (:'staff_quince_oct'::jsonb#>>'{data,summary,paid_count}') = '2' AND (:'staff_quince_oct'::jsonb#>>'{data,summary,pending_count}') = '1'
  AND (:'staff_quince_sep'::jsonb#>>'{data,summary,total_amount}')::numeric = 103
  AND (:'staff_quince_sep'::jsonb#>>'{data,summary,paid_amount}')::numeric = 4
  AND (:'staff_quince_sep'::jsonb#>>'{data,summary,pending_amount}')::numeric = 99
  AND (:'staff_quince_sep'::jsonb#>>'{data,summary,paid_count}') = '0' AND (:'staff_quince_sep'::jsonb#>>'{data,summary,pending_count}') = '2',
  'staff: October alone is 286 (paid 284.99, pending 1.01) and September alone 103 (paid 4, pending 99): ' || :'staff_quince_oct' || ' / ' || :'staff_quince_sep');
-- The keys of the answer, the summary and a month are the ones they had (the two new keys are on the invoices only).
SELECT pg_temp.rip_assert(pg_temp.rip_keys(:'staff_quince'::jsonb) = 'data,metadata,success'
  AND pg_temp.rip_keys(:'staff_quince'::jsonb->'data') = 'by_month,invoices,summary'
  AND pg_temp.rip_keys(:'staff_quince'::jsonb#>'{data,summary}') = 'net_amount,paid_amount,paid_count,pending_amount,pending_count,total_amount,total_discount,total_invoices,total_labour,total_tax'
  AND pg_temp.rip_keys(:'staff_quince'::jsonb#>'{data,by_month,0}') = 'invoice_count,month,paid_amount,pending_amount,total_amount',
  'staff: the keys of the Quince answer, its summary and its months: ' || :'staff_quince');
-- An administrator is answered the same (everything but the time of the answer).
SELECT pg_temp.rip_assert((:'admin_quince'::jsonb)->'data' = (:'staff_quince'::jsonb)->'data', 'administrator and staff are answered alike: ' || :'admin_quince');

-- ---------------------------------------------------------------------------
-- Rowan: exact, over-paid by 12 and by 0.50, and an invoice of 0
-- ---------------------------------------------------------------------------
-- Newest first: 6210 (total 0, no payment: nothing is owed, so paid), 6209 (66.50 of 66), 6208 (120 of 108), 6207 (exact 71).
SELECT pg_temp.rip_assert(pg_temp.rip_col(:'staff_rowan'::jsonb#>'{data,invoices}', 'invoice_number') = ARRAY['2026-6210', '2026-6209', '2026-6208', '2026-6207']
  AND pg_temp.rip_nums(:'staff_rowan'::jsonb#>'{data,invoices}', 'total') = ARRAY[0, 66, 108, 71]::numeric[]
  AND pg_temp.rip_pay(:'staff_rowan'::jsonb#>'{data,invoices}', 'status') = ARRAY['paid', 'paid', 'paid', 'paid']
  AND pg_temp.rip_nums(:'staff_rowan'::jsonb#>'{data,invoices}', 'paid_amount') = ARRAY[0, 66, 108, 71]::numeric[]
  AND pg_temp.rip_nums(:'staff_rowan'::jsonb#>'{data,invoices}', 'balance_amount') = ARRAY[0, 0, 0, 0]::numeric[]
  AND pg_temp.rip_pay(:'staff_rowan'::jsonb#>'{data,invoices}', 'amount') = ARRAY[NULL, '66.50', '120.00', '71.00']::text[]
  AND position('2026-6201' in :'staff_rowan') = 0,
  'staff: Rowan: 6210 (0) paid, 6209 (66.50 of 66) and 6208 (120 of 108) received only their total, 6207 exact: ' || :'staff_rowan');
SELECT pg_temp.rip_assert((:'staff_rowan'::jsonb#>>'{data,summary,total_amount}')::numeric = 245
  AND (:'staff_rowan'::jsonb#>>'{data,summary,paid_amount}')::numeric = 245
  AND (:'staff_rowan'::jsonb#>>'{data,summary,pending_amount}')::numeric = 0
  AND (:'staff_rowan'::jsonb#>>'{data,summary,paid_count}') = '4' AND (:'staff_rowan'::jsonb#>>'{data,summary,pending_count}') = '0'
  AND (:'staff_rowan'::jsonb#>>'{data,summary,paid_amount}')::numeric = :'table_r_paid'::numeric
  AND (:'staff_rowan'::jsonb#>>'{data,summary,pending_amount}')::numeric = :'table_r_pending'::numeric
  AND pg_temp.rip_col(:'staff_rowan'::jsonb#>'{data,by_month}', 'month') = ARRAY['2026-10', '2026-09']
  AND pg_temp.rip_nums(:'staff_rowan'::jsonb#>'{data,by_month}', 'total_amount') = ARRAY[174, 71]::numeric[]
  AND pg_temp.rip_nums(:'staff_rowan'::jsonb#>'{data,by_month}', 'paid_amount') = ARRAY[174, 71]::numeric[]
  AND pg_temp.rip_nums(:'staff_rowan'::jsonb#>'{data,by_month}', 'pending_amount') = ARRAY[0, 0]::numeric[],
  'staff: Rowan summary: total 245 = paid 245 (the 257.50 paid is capped invoice by invoice) + pending 0: ' || :'staff_rowan');

-- ---------------------------------------------------------------------------
-- Invoice history, all customers: no paid or pending figure, nothing changes
-- ---------------------------------------------------------------------------
SELECT pg_temp.rip_assert((:'staff_all'::jsonb#>>'{data,summary,total_invoices}') = '9'
  AND (:'staff_all'::jsonb#>>'{data,summary,total_customers}') = '2'
  AND (:'staff_all'::jsonb#>>'{data,summary,total_amount}')::numeric = 634
  AND (:'staff_all'::jsonb#>>'{data,summary,net_amount}')::numeric = 634
  AND (:'staff_all'::jsonb#>>'{data,summary,total_tax}')::numeric = 45
  AND (:'staff_all'::jsonb#>>'{data,summary,total_amount}')::numeric = :'table_all_total'::numeric
  AND pg_temp.rip_keys(:'staff_all'::jsonb#>'{data,summary}') = 'net_amount,total_amount,total_customers,total_invoices,total_tax'
  AND pg_temp.rip_keys(:'staff_all'::jsonb->'data') = 'by_customer,by_month,summary'
  AND pg_temp.rip_keys(:'staff_all'::jsonb#>'{data,by_customer,0}') = 'customer_id,customer_name,invoice_count,latest_invoice_date,net_amount,total_amount'
  AND pg_temp.rip_keys(:'staff_all'::jsonb#>'{data,by_month,0}') = 'invoice_count,month,total_amount'
  AND pg_temp.rip_nums(:'staff_all'::jsonb#>'{data,by_customer}', 'total_amount') = ARRAY[389, 245]::numeric[]
  AND pg_temp.rip_col(:'staff_all'::jsonb#>'{data,by_customer}', 'invoice_count') = ARRAY['5', '4']
  AND pg_temp.rip_nums(:'staff_all'::jsonb#>'{data,by_month}', 'total_amount') = ARRAY[460, 174]::numeric[],
  'staff: all customers: 9 invoices, total 634, tax 45, with no paid or pending figure: ' || :'staff_all');
SELECT pg_temp.rip_assert((:'admin_all'::jsonb)->'data' = (:'staff_all'::jsonb)->'data'
  AND (:'admin_rowan'::jsonb)->'data' = (:'staff_rowan'::jsonb)->'data',
  'administrator and staff are answered alike for Rowan and for all customers: ' || :'admin_all');

-- ---------------------------------------------------------------------------
-- Customer activity detail
-- ---------------------------------------------------------------------------
-- Quince: invoiced 389, the payments of the period's invoices 288.99 (unchanged: the sum of the payments), pending 100.01
-- = the sum of the balances (it was 389 - 288.99 = 100.01, the same here: nothing is over-paid). Recent invoices: pending,
-- paid, paid, pending, pending (6205, 6204, 6203, 6202, 6201; it was paid for 6205 and 6201 as they have a row).
SELECT pg_temp.rip_assert((:'staff_detail'::jsonb#>>'{data,summary,total_invoice_amount}')::numeric = 389
  AND (:'staff_detail'::jsonb#>>'{data,summary,total_paid_amount}')::numeric = 288.99
  AND (:'staff_detail'::jsonb#>>'{data,summary,total_paid_amount}')::numeric = :'table_q_payments'::numeric
  AND (:'staff_detail'::jsonb#>>'{data,summary,total_pending_amount}')::numeric = 100.01
  AND (:'staff_detail'::jsonb#>>'{data,summary,total_pending_amount}')::numeric = (:'staff_quince'::jsonb#>>'{data,summary,pending_amount}')::numeric
  AND (:'staff_detail'::jsonb#>>'{data,summary,total_pending_amount}')::numeric = :'table_q_pending'::numeric
  AND jsonb_typeof(:'staff_detail'::jsonb#>'{data,summary,total_pending_amount}') = 'number',
  'staff: activity detail: invoiced 389, payments 288.99, pending 100.01 (the sum of the balances): ' || :'staff_detail');
SELECT pg_temp.rip_assert(pg_temp.rip_col(:'staff_detail'::jsonb#>'{data,recent_invoices}', 'invoice_number') = ARRAY['2026-6205', '2026-6204', '2026-6203', '2026-6202', '2026-6201']
  AND pg_temp.rip_col(:'staff_detail'::jsonb#>'{data,recent_invoices}', 'status') = ARRAY['pending', 'paid', 'paid', 'pending', 'pending']
  AND pg_temp.rip_nums(:'staff_detail'::jsonb#>'{data,recent_invoices}', 'net_total') = ARRAY[66, 109, 111, 89, 14]::numeric[]
  AND pg_temp.rip_col(:'staff_detail'::jsonb#>'{data,recent_invoices}', 'status') = pg_temp.rip_pay(:'staff_quince'::jsonb#>'{data,invoices}', 'status'),
  'staff: activity detail recent invoices: pending, paid, paid, pending, pending, as the invoice history says: ' || (:'staff_detail'::jsonb#>>'{data,recent_invoices}'));
-- Rowan: invoiced 245, payments 257.50 (12.50 and 0.50 too much; unchanged), pending 0 and not 245 - 257.50 = -12.50.
SELECT pg_temp.rip_assert((:'staff_detail_rowan'::jsonb#>>'{data,summary,total_invoice_amount}')::numeric = 245
  AND (:'staff_detail_rowan'::jsonb#>>'{data,summary,total_paid_amount}')::numeric = 257.50
  AND (:'staff_detail_rowan'::jsonb#>>'{data,summary,total_pending_amount}')::numeric = 0
  AND (:'staff_detail_rowan'::jsonb#>>'{data,summary,total_pending_amount}')::numeric >= 0
  AND pg_temp.rip_col(:'staff_detail_rowan'::jsonb#>'{data,recent_invoices}', 'invoice_number') = ARRAY['2026-6210', '2026-6209', '2026-6208', '2026-6207']
  AND pg_temp.rip_col(:'staff_detail_rowan'::jsonb#>'{data,recent_invoices}', 'status') = ARRAY['paid', 'paid', 'paid', 'paid']
  AND pg_temp.rip_nums(:'staff_detail_rowan'::jsonb#>'{data,recent_invoices}', 'net_total') = ARRAY[0, 66, 108, 71]::numeric[]
  AND pg_temp.rip_nums(:'staff_detail_rowan'::jsonb#>'{data,monthly_trends}', 'invoice_amount') = ARRAY[71, 174]::numeric[],
  'staff: Rowan activity detail: invoiced 245, payments 257.50, pending 0 (never negative), 6210 of 0 is paid: ' || :'staff_detail_rowan');
-- Key sets: unchanged.
SELECT pg_temp.rip_assert(pg_temp.rip_keys(:'staff_detail'::jsonb) = 'data,metadata,success'
  AND pg_temp.rip_keys(:'staff_detail'::jsonb->'data') = 'by_bucket,customer_city,customer_id,customer_name,monthly_trends,recent_dispatches,recent_grns,recent_invoices,summary,top_stock_items'
  AND pg_temp.rip_keys(:'staff_detail'::jsonb#>'{data,summary}') = 'average_stock_age_days,current_stock,total_dispatch_quantity,total_dispatches,total_grn_quantity,total_grns,total_invoice_amount,total_paid_amount,total_pending_amount'
  AND pg_temp.rip_keys(:'staff_detail'::jsonb#>'{data,monthly_trends,0}') = 'dispatch_count,dispatch_quantity,grn_count,grn_quantity,invoice_amount,month,stock_level_end'
  AND pg_temp.rip_keys(:'staff_detail'::jsonb#>'{data,recent_invoices,0}') = 'invoice_date,invoice_id,invoice_number,net_total,status',
  'staff: the keys of the activity detail are unchanged: ' || :'staff_detail');
SELECT pg_temp.rip_assert((:'admin_detail'::jsonb)->'data' = (:'staff_detail'::jsonb)->'data'
  AND (:'admin_detail_rowan'::jsonb)->'data' = (:'staff_detail_rowan'::jsonb)->'data',
  'administrator and staff are answered alike for the activity detail: ' || :'admin_detail');

-- ---------------------------------------------------------------------------
-- All-customers activity summary: no paid or pending figure, nothing changes
-- ---------------------------------------------------------------------------
SELECT pg_temp.rip_assert((pg_temp.rip_row(:'staff_activity'::jsonb#>'{data,customers}', 'customer_id', :'quince')->>'total_invoice_amount')::numeric = 389
  AND (pg_temp.rip_row(:'staff_activity'::jsonb#>'{data,customers}', 'customer_id', :'rowan')->>'total_invoice_amount')::numeric = 245
  AND (:'staff_activity'::jsonb#>>'{data,summary,total_invoice_amount}')::numeric = 634
  AND pg_temp.rip_keys(:'staff_activity'::jsonb->'data') = 'customers,summary'
  AND pg_temp.rip_keys(:'staff_activity'::jsonb#>'{data,summary}') = 'total_current_stock,total_customers,total_dispatches,total_grns,total_invoice_amount'
  AND pg_temp.rip_keys(:'staff_activity'::jsonb#>'{data,customers,0}') = 'current_stock,customer_city,customer_id,customer_name,last_activity_date,last_activity_type,total_dispatches,total_grns,total_invoice_amount'
  AND (:'admin_activity'::jsonb)->'data' = (:'staff_activity'::jsonb)->'data',
  'staff: all-customers activity: Quince 389, Rowan 245, together 634, the same keys: ' || :'staff_activity');

-- ---------------------------------------------------------------------------
-- A customer account: its own customer's figures, nobody else's
-- ---------------------------------------------------------------------------
SELECT pg_temp.rip_assert((:'customer_quince'::jsonb)->'data' = (:'staff_quince'::jsonb)->'data'
  AND (:'customer_quince'::jsonb#>>'{data,summary,paid_amount}')::numeric = 288.99
  AND (:'customer_quince'::jsonb#>>'{data,summary,pending_amount}')::numeric = 100.01
  AND (:'customer_detail'::jsonb)->'data' = (:'staff_detail'::jsonb)->'data'
  AND (:'customer_detail'::jsonb#>>'{data,summary,total_pending_amount}')::numeric = 100.01,
  'customer account: its own customer''s invoice history and activity carry the same paid and pending figures: ' || :'customer_quince');
-- The refusal check can tell an answer from a refusal: the same calls for its own customer are answered.
SELECT pg_temp.rip_assert(:'customer_quince_check' LIKE 'answered: %' AND :'customer_detail_check' LIKE 'answered: %',
  'the refusal check answers "answered" for allowed calls: ' || :'customer_quince_check' || ' / ' || :'customer_detail_check');
-- Another customer's id, all customers and the all-customers activity are refused, so none of Rowan's figures can be learned.
SELECT pg_temp.rip_assert(:'customer_rowan' = 'refused: 42501 Failed to retrieve invoice summary: Customer access denied'
  AND :'customer_detail_rowan' = 'refused: 42501 Failed to retrieve customer activity detail: Customer access denied'
  AND :'customer_all' = 'refused: 42501 Failed to retrieve invoice summary: Customer access denied'
  AND :'customer_activity' = 'refused: 42501 Failed to retrieve customer activity summary: Staff access required',
  'customer account: another customer, all customers and the all-customers activity were not refused: ' || :'customer_rowan' || ' | ' || :'customer_detail_rowan' || ' | ' || :'customer_all' || ' | ' || :'customer_activity');

ROLLBACK;
SELECT 'report invoice paid: Paid is the money received and Pending is what is still owed in the invoice history and the customer activity detail (a part-paid invoice is pending with its balance, 0.50 owed is paid and 0.51 is pending, an over-payment counts only the total), paid + pending is the total, the two new keys are on the invoices only, the other keys are unchanged, and a customer account still gets only its own customer' AS result;

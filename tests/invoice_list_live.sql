-- get_invoices_list reads the tables (migration 106): a write is listed at once, in the same transaction, with no
-- refresh. Checks the live visibility of writes, who sees what, every sort with its tie-breaks on crafted rows,
-- multi-word search, the filters, paging and total_count.
-- Runs ONLY in migrations.sh's fresh, network-disabled database. All fixture rows roll back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.live_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'invoice list live: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.live_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.live_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- The invoices of this test as "year-number", in the order the list returned them. The search word keeps the
-- list to this test's customers whatever else the database holds.
CREATE FUNCTION pg_temp.live_order(result jsonb) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg((x->>'inv_fin_year') || '-' || (x->>'invoice_number') ORDER BY ord), '{}')
  FROM jsonb_array_elements(result->'data') WITH ORDINALITY AS t(x, ord) $$;
CREATE FUNCTION pg_temp.live_sorted(field text, direction text) RETURNS text[] LANGUAGE sql AS $$
  SELECT pg_temp.live_order(public.get_invoices_list(p_search => 'livetest', p_sort_field => field, p_sort_direction => direction, p_limit => 100)) $$;

INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888888781', 'Live Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888888782', 'Live Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888888783', 'Live Customer', 'customer', true, 'approved'),
 (gen_random_uuid(), '919888888784', 'Live Customer Without Business', 'customer', true, 'approved');
SELECT pg_temp.live_login('9888888781') AS admin_claims \gset
SELECT pg_temp.live_login('9888888782') AS staff_claims \gset
SELECT pg_temp.live_login('9888888783') AS customer_claims \gset
SELECT pg_temp.live_login('9888888784') AS lonely_claims \gset

INSERT INTO public.customers(id, name, mobile, city) VALUES
 (md5('live-a')::uuid, 'Livetest Alpha', '9888880101', 'Surat'), (md5('live-b')::uuid, 'Livetest Beta', '9888880102', 'Rajkot');
INSERT INTO public.users_customers_new(user_profile_id, customer_id, active)
 SELECT id, md5('live-a')::uuid, true FROM public.user_profiles WHERE mobile = '919888888783';
-- Receipts G1..G5 (the invoices I5 and I6 share G5), and six invoices crafted to tie:
--   I1 2025-5 Alpha 03-01 total 300 G1     I2 2026-6 Beta  03-01 total 100 G2     I3 2026-7 Alpha 03-02 total 200 G3
--   I4 2026-9 Beta  03-02 total 200 G4     I5 2026-3 Alpha 02-20 total 100 G5     I6 2025-3 Alpha 02-10 total 150 G5
-- Same date: I1/I2 and I3/I4. Same number: I5/I6 (3). Same total: I3/I4 (200) and I2/I5 (100). Same receipt: I5/I6.
INSERT INTO public.goodsreceived(id, gr_no, date, customer_id, customer_name) VALUES
 (md5('live-g1')::uuid, 'LV-G1', '2026-01-01 08:00+00', md5('live-a')::uuid, 'Livetest Alpha'),
 (md5('live-g2')::uuid, 'LV-G2', '2026-01-02 08:00+00', md5('live-b')::uuid, 'Livetest Beta'),
 (md5('live-g3')::uuid, 'LV-G3', '2026-01-03 08:00+00', md5('live-a')::uuid, 'Livetest Alpha'),
 (md5('live-g4')::uuid, 'LV-G4', '2026-01-04 08:00+00', md5('live-b')::uuid, 'Livetest Beta'),
 (md5('live-g5')::uuid, 'LV-G5', '2026-01-05 08:00+00', md5('live-a')::uuid, 'Livetest Alpha');
INSERT INTO public.invoice(id, inv_fin_year, inv_no, gr_id, gr_no, customer_id, customer_name, inv_date, total)
 SELECT md5('live-i' || n)::uuid, fy, no, md5('live-g' || g)::uuid, 'LV-G' || g, md5('live-' || c)::uuid,
        CASE c WHEN 'a' THEN 'Livetest Alpha' ELSE 'Livetest Beta' END, d::timestamptz, total
 FROM (VALUES (1, 2025, 5, 1, 'a', '2026-03-01 10:00+00', 300), (2, 2026, 6, 2, 'b', '2026-03-01 10:00+00', 100),
              (3, 2026, 7, 3, 'a', '2026-03-02 10:00+00', 200), (4, 2026, 9, 4, 'b', '2026-03-02 10:00+00', 200),
              (5, 2026, 3, 5, 'a', '2026-02-20 10:00+00', 100), (6, 2025, 3, 5, 'a', '2026-02-10 10:00+00', 150)) AS v(n, fy, no, g, c, d, total);
-- Lines for I1: two dispatch lines of 4 and 6 bags (total_qty 10); the others have none (0).
INSERT INTO public.items(id, name, packaging) VALUES (md5('live-item')::uuid, 'Live Item', 'Bag');
INSERT INTO public.goodsreceived_trl(id, gr_id, item_id, item_name, qty, weight, stock) VALUES
 (md5('live-gt1')::uuid, md5('live-g1')::uuid, md5('live-item')::uuid, 'Live Item', 20, 5, 10),
 (md5('live-gt2')::uuid, md5('live-g1')::uuid, md5('live-item')::uuid, 'Live Item', 20, 5, 10);
INSERT INTO public.dispatch(id, disp_no, disp_date, customer_id, customer_name) VALUES (md5('live-d1')::uuid, 'LV-D1', '2026-02-28 08:00+00', md5('live-a')::uuid, 'Livetest Alpha');
INSERT INTO public.dispatch_trl(id, gr_id, gr_trl_id, disp_id, disp_qty) VALUES
 (md5('live-dt1')::uuid, md5('live-g1')::uuid, md5('live-gt1')::uuid, md5('live-d1')::uuid, 4),
 (md5('live-dt2')::uuid, md5('live-g1')::uuid, md5('live-gt2')::uuid, md5('live-d1')::uuid, 6);
INSERT INTO public.invoice_trl(id, invoice_id, disp_trl_id) VALUES
 (md5('live-it1')::uuid, md5('live-i1')::uuid, md5('live-dt1')::uuid), (md5('live-it2')::uuid, md5('live-i1')::uuid, md5('live-dt2')::uuid);

SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;

-- Each sort with its tie-breaks (the labels are year-number).
SELECT pg_temp.live_assert(pg_temp.live_sorted('inv_date', 'desc') = ARRAY['2026-9','2026-7','2026-6','2025-5','2026-3','2025-3'], 'date desc, same date by number desc: ' || pg_temp.live_sorted('inv_date', 'desc')::text);
SELECT pg_temp.live_assert(pg_temp.live_sorted('inv_date', 'asc') = ARRAY['2025-3','2026-3','2026-6','2025-5','2026-9','2026-7'], 'date asc, same date still by number desc: ' || pg_temp.live_sorted('inv_date', 'asc')::text);
SELECT pg_temp.live_assert(pg_temp.live_sorted('inv_no', 'desc') = ARRAY['2026-9','2026-7','2026-6','2025-5','2026-3','2025-3'], 'number desc, the same number by date desc: ' || pg_temp.live_sorted('inv_no', 'desc')::text);
SELECT pg_temp.live_assert(pg_temp.live_sorted('inv_no', 'asc') = ARRAY['2026-3','2025-3','2025-5','2026-6','2026-7','2026-9'], 'number asc, the same number by date desc: ' || pg_temp.live_sorted('inv_no', 'asc')::text);
SELECT pg_temp.live_assert(pg_temp.live_sorted('invoice_number', 'asc') = pg_temp.live_sorted('inv_no', 'asc')
  AND pg_temp.live_sorted('invoice_number', 'desc') = pg_temp.live_sorted('inv_no', 'desc'), 'invoice_number is an alias of inv_no');
SELECT pg_temp.live_assert(pg_temp.live_sorted('customer_name', 'asc') = ARRAY['2026-7','2025-5','2026-3','2025-3','2026-9','2026-6'], 'customer asc, then date desc: ' || pg_temp.live_sorted('customer_name', 'asc')::text);
SELECT pg_temp.live_assert(pg_temp.live_sorted('customer_name', 'desc') = ARRAY['2026-9','2026-6','2026-7','2025-5','2026-3','2025-3'], 'customer desc, still date desc inside: ' || pg_temp.live_sorted('customer_name', 'desc')::text);
SELECT pg_temp.live_assert(pg_temp.live_sorted('gr_no', 'asc') = ARRAY['2025-5','2026-6','2026-7','2026-9','2026-3','2025-3'], 'receipt asc, one receipt by date desc: ' || pg_temp.live_sorted('gr_no', 'asc')::text);
SELECT pg_temp.live_assert(pg_temp.live_sorted('grn_number', 'desc') = ARRAY['2026-3','2025-3','2026-9','2026-7','2026-6','2025-5'], 'receipt desc (grn_number alias): ' || pg_temp.live_sorted('grn_number', 'desc')::text);
SELECT pg_temp.live_assert(pg_temp.live_sorted('total', 'desc') = ARRAY['2025-5','2026-9','2026-7','2025-3','2026-6','2026-3'], 'total desc, equal totals by date desc then number desc: ' || pg_temp.live_sorted('total', 'desc')::text);
SELECT pg_temp.live_assert(pg_temp.live_sorted('total', 'asc') = ARRAY['2026-6','2026-3','2025-3','2026-9','2026-7','2025-5'], 'total asc, equal totals by date desc then number desc: ' || pg_temp.live_sorted('total', 'asc')::text);
SELECT pg_temp.live_assert(pg_temp.live_sorted('financial_year', 'desc') = ARRAY['2026-9','2026-7','2026-6','2026-3','2025-5','2025-3'], 'year desc, then number desc: ' || pg_temp.live_sorted('financial_year', 'desc')::text);
SELECT pg_temp.live_assert(pg_temp.live_sorted('financial_year', 'asc') = ARRAY['2025-5','2025-3','2026-9','2026-7','2026-6','2026-3'], 'year asc, then number desc: ' || pg_temp.live_sorted('financial_year', 'asc')::text);
SELECT pg_temp.live_assert(pg_temp.live_sorted('bogus', 'asc') = ARRAY['2026-9','2026-7','2026-6','2025-5','2026-3','2025-3'], 'an unknown field falls back to date desc, number desc: ' || pg_temp.live_sorted('bogus', 'asc')::text);
SELECT pg_temp.live_assert(pg_temp.live_sorted('inv_date', 'sideways') = ARRAY['2026-9','2026-7','2026-6','2025-5','2026-3','2025-3'], 'an unknown direction leaves number desc, then date desc: ' || pg_temp.live_sorted('inv_date', 'sideways')::text);
SELECT pg_temp.live_assert(pg_temp.live_sorted('total', 'asc') <> pg_temp.live_sorted('total', 'desc'), 'the two total orders differ');

-- Paging and total_count.
SELECT public.get_invoices_list(p_search => 'livetest', p_limit => 2, p_offset => 2) AS page_mid \gset
SELECT pg_temp.live_assert(pg_temp.live_order(:'page_mid'::jsonb) = ARRAY['2026-6','2025-5'] AND (:'page_mid'::jsonb#>>'{pagination,total_count}') = '6'
  AND (:'page_mid'::jsonb#>>'{pagination,has_more}') = 'true', 'middle page: ' || :'page_mid');
SELECT public.get_invoices_list(p_search => 'livetest', p_limit => 2, p_offset => 4) AS page_last \gset
SELECT pg_temp.live_assert(pg_temp.live_order(:'page_last'::jsonb) = ARRAY['2026-3','2025-3'] AND (:'page_last'::jsonb#>>'{pagination,has_more}') = 'false', 'last page: ' || :'page_last');
SELECT public.get_invoices_list(p_search => 'livetest', p_limit => 2, p_offset => 10) AS page_past \gset
SELECT pg_temp.live_assert(pg_temp.live_order(:'page_past'::jsonb) = '{}' AND (:'page_past'::jsonb#>>'{pagination,total_count}') = '6', 'a page past the end is empty but still counts 6: ' || :'page_past');

-- total_qty and the answer shape.
SELECT public.get_invoices_list(p_search => 'livetest', p_sort_field => 'inv_no', p_sort_direction => 'asc', p_inv_no_from => 5, p_inv_no_to => 5, p_financial_year => 2025) AS one \gset
SELECT pg_temp.live_assert((:'one'::jsonb#>>'{data,0,total_qty}')::numeric = 10 AND (:'one'::jsonb#>>'{data,0,financial_year}') = '2025-2026'
  AND (:'one'::jsonb#>>'{data,0,customer,name}') = 'Livetest Alpha' AND (:'one'::jsonb#>>'{data,0,grn,gr_no}') = 'LV-G1'
  AND (:'one'::jsonb#>>'{data,0,total}')::numeric = 300 AND (:'one'::jsonb#>>'{success}') = 'true', 'total_qty 10 from the two lines, the shape of the row: ' || :'one');
SELECT pg_temp.live_assert((public.get_invoices_list(p_search => 'livetest', p_inv_no_from => 7, p_inv_no_to => 7)#>>'{data,0,total_qty}')::numeric = 0, 'an invoice without lines has total_qty 0');

-- Search: every word must match, in the number, the customer, the receipt, "year-number" or the padded number.
SELECT pg_temp.live_assert(pg_temp.live_order(public.get_invoices_list(p_search => 'livetest alpha')) = ARRAY['2026-7','2025-5','2026-3','2025-3'], 'two words, one customer: Alpha only');
SELECT pg_temp.live_assert(pg_temp.live_order(public.get_invoices_list(p_search => 'alpha beta')) = '{}'
  AND (public.get_invoices_list(p_search => 'alpha beta')#>>'{pagination,total_count}') = '0', 'every word must match: nothing is both Alpha and Beta');
SELECT pg_temp.live_assert(pg_temp.live_order(public.get_invoices_list(p_search => 'livetest lv-g4')) = ARRAY['2026-9'], 'a receipt number plus a name');
SELECT pg_temp.live_assert(pg_temp.live_order(public.get_invoices_list(p_search => 'livetest 2026-7')) = ARRAY['2026-7'], 'year-number');
SELECT pg_temp.live_assert(pg_temp.live_order(public.get_invoices_list(p_search => 'livetest 2025-0005')) = ARRAY['2025-5'], 'year-padded number');
SELECT pg_temp.live_assert(pg_temp.live_order(public.get_invoices_list(p_search => 'BETA 2026')) = ARRAY['2026-9','2026-6'], 'case-insensitive, two words in two columns');
SELECT pg_temp.live_assert(pg_temp.live_order(public.get_invoices_list(p_search => '%')) = '{}' AND pg_temp.live_order(public.get_invoices_list(p_search => '_')) = '{}', 'wildcards are literal');
SELECT pg_temp.live_assert((public.get_invoices_list(p_search => '   ')#>>'{pagination,total_count}')::integer >= 6, 'a blank search is no search');

-- Two invoices with the same date and number in different financial years: the order ends with the invoice id.
RESET ROLE;
INSERT INTO public.invoice(id, inv_fin_year, inv_no, gr_id, gr_no, customer_id, customer_name, inv_date, total)
 VALUES (md5('live-tie-a')::uuid, 2031, 77, md5('live-g2')::uuid, 'LV-G2', md5('live-b')::uuid, 'Livetest Beta', '2030-06-01 10:00+00', 10),
        (md5('live-tie-b')::uuid, 2032, 77, md5('live-g2')::uuid, 'LV-G2', md5('live-b')::uuid, 'Livetest Beta', '2030-06-01 10:00+00', 10);
SET LOCAL ROLE authenticated;
SELECT pg_temp.live_assert(
  (SELECT array_agg(x->>'invoice_id' ORDER BY ord) FROM jsonb_array_elements(public.get_invoices_list(p_search => 'livetest', p_inv_no_from => 77, p_inv_no_to => 77, p_sort_field => 'inv_date', p_sort_direction => 'asc')->'data') WITH ORDINALITY t(x, ord))
  = (SELECT array_agg(id::text ORDER BY id) FROM public.invoice WHERE inv_no = 77 AND id IN (md5('live-tie-a')::uuid, md5('live-tie-b')::uuid)),
  'equal date and number in two financial years: the invoice id breaks the tie (ascending)');
SELECT pg_temp.live_assert(
  (SELECT array_agg(x->>'invoice_id' ORDER BY ord) FROM jsonb_array_elements(public.get_invoices_list(p_search => 'livetest', p_inv_no_from => 77, p_inv_no_to => 77, p_sort_field => 'inv_date', p_sort_direction => 'desc')->'data') WITH ORDINALITY t(x, ord))
  = (SELECT array_agg(id::text ORDER BY id) FROM public.invoice WHERE inv_no = 77 AND id IN (md5('live-tie-a')::uuid, md5('live-tie-b')::uuid)),
  'the same two with the date descending: the id tie-break stays ascending');
RESET ROLE;
DELETE FROM public.invoice WHERE id IN (md5('live-tie-a')::uuid, md5('live-tie-b')::uuid);
SET LOCAL ROLE authenticated;

-- The other filters.
SELECT pg_temp.live_assert(pg_temp.live_order(public.get_invoices_list(p_search => 'livetest', p_financial_year => 2025, p_sort_field => 'inv_no', p_sort_direction => 'desc')) = ARRAY['2025-5','2025-3'], 'financial year');
SELECT pg_temp.live_assert(pg_temp.live_order(public.get_invoices_list(p_search => 'livetest', p_inv_no_from => 6, p_inv_no_to => 7, p_sort_field => 'inv_no', p_sort_direction => 'asc')) = ARRAY['2026-6','2026-7'], 'number range');
SELECT pg_temp.live_assert(pg_temp.live_order(public.get_invoices_list(p_search => 'livetest', p_date_from => '2026-03-01 10:00+00', p_date_to => '2026-03-01 10:00+00')) = ARRAY['2026-6','2025-5'], 'a date range is inclusive at both ends');
SELECT pg_temp.live_assert(pg_temp.live_order(public.get_invoices_list(p_search => 'livetest', p_customer_id => md5('live-b')::uuid, p_sort_field => 'inv_no', p_sort_direction => 'asc')) = ARRAY['2026-6','2026-9'], 'customer id');
SELECT pg_temp.live_assert(pg_temp.live_order(public.get_invoices_list(p_search => 'livetest', p_customer_ids => ARRAY[md5('live-b')::uuid], p_sort_field => 'inv_no', p_sort_direction => 'asc')) = ARRAY['2026-6','2026-9']
  AND (public.get_invoices_list(p_search => 'livetest', p_customer_ids => ARRAY[]::uuid[])#>>'{pagination,total_count}') = '6', 'customer ids; an empty list is no filter');
SELECT pg_temp.live_assert(pg_temp.live_order(public.get_invoices_list(p_search_invoice_no => '3', p_search => 'livetest', p_sort_field => 'inv_no', p_sort_direction => 'asc')) = ARRAY['2026-3','2025-3'], 'invoice number contains');
SELECT pg_temp.live_assert(pg_temp.live_order(public.get_invoices_list(p_search_grn_no => 'lv-g5', p_sort_field => 'inv_no', p_sort_direction => 'asc')) = ARRAY['2026-3','2025-3'], 'receipt number contains (the GRN Invoices tab)');

-- A write is listed at once, in the same transaction: no refresh runs anywhere.
RESET ROLE;
INSERT INTO public.invoice(id, inv_fin_year, inv_no, gr_id, gr_no, customer_id, customer_name, inv_date, total)
 VALUES (md5('live-i7')::uuid, 2026, 10, md5('live-g2')::uuid, 'LV-G2', md5('live-b')::uuid, 'Livetest Beta', '2026-04-01 10:00+00', 55);
SET LOCAL ROLE authenticated;
SELECT pg_temp.live_assert((pg_temp.live_sorted('inv_date', 'desc'))[1] = '2026-10' AND (public.get_invoices_list(p_search => 'livetest')#>>'{pagination,total_count}') = '7',
  'a new invoice is the first row and counted at once: ' || pg_temp.live_sorted('inv_date', 'desc')::text);
RESET ROLE;
UPDATE public.customers SET name = 'Livetest Beta Renamed' WHERE id = md5('live-b')::uuid;
SET LOCAL ROLE authenticated;
SELECT pg_temp.live_assert((public.get_invoices_list(p_search => 'renamed')#>>'{pagination,total_count}') = '3'
  AND (public.get_invoices_list(p_search => 'renamed')#>>'{data,0,customer,name}') = 'Livetest Beta Renamed', 'a renamed customer is found by the new name at once');
RESET ROLE;
UPDATE public.invoice SET deleted_at = now() WHERE id = md5('live-i7')::uuid;
SET LOCAL ROLE authenticated;
SELECT pg_temp.live_assert((pg_temp.live_sorted('inv_date', 'desc'))[1] = '2026-9' AND (public.get_invoices_list(p_search => 'livetest')#>>'{pagination,total_count}') = '6', 'a deleted invoice leaves the list at once');
RESET ROLE;
UPDATE public.customers SET deleted_at = now() WHERE id = md5('live-b')::uuid;
SET LOCAL ROLE authenticated;
SELECT pg_temp.live_assert(pg_temp.live_sorted('inv_date', 'desc') = ARRAY['2026-7','2025-5','2026-3','2025-3'], 'the invoices of a deleted customer are not listed to an administrator');
RESET ROLE;
UPDATE public.customers SET deleted_at = NULL WHERE id = md5('live-b')::uuid;
SET LOCAL ROLE authenticated;
SELECT pg_temp.live_assert((public.get_invoices_list(p_search => 'livetest')#>>'{pagination,total_count}') = '6', 'a restored customer lists again');

-- Staff see what the administrator sees; a customer account is refused by the guard; an account with no business sees nothing.
SELECT set_config('request.jwt.claims', :'staff_claims', true);
SELECT pg_temp.live_assert(pg_temp.live_sorted('inv_date', 'desc') = ARRAY['2026-9','2026-7','2026-6','2025-5','2026-3','2025-3'], 'staff see the same six');
SELECT set_config('request.jwt.claims', :'customer_claims', true);
DO $$ BEGIN
  PERFORM public.get_invoices_list(p_search => 'livetest');
  RAISE EXCEPTION 'invoice list live: a customer account was answered';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
-- The path for any other signed-in caller goes through user_accessible_customers(): reached through the service role
-- with the customer's own subject. The customer sees only the business assigned to it; one without a business sees none.
RESET ROLE;
SELECT set_config('request.jwt.claims', jsonb_build_object('role', 'service_role', 'sub', (:'customer_claims'::jsonb)->>'sub')::text, true);
SELECT pg_temp.live_assert(pg_temp.live_sorted('inv_date', 'desc') = ARRAY['2026-7','2025-5','2026-3','2025-3']
  AND (public.get_invoices_list(p_search => 'livetest')#>>'{pagination,total_count}') = '4', 'a customer user sees only the invoices of the assigned business: ' || pg_temp.live_sorted('inv_date', 'desc')::text);
SELECT set_config('request.jwt.claims', jsonb_build_object('role', 'service_role', 'sub', (:'lonely_claims'::jsonb)->>'sub')::text, true);
SELECT pg_temp.live_assert(pg_temp.live_order(public.get_invoices_list(p_search => 'livetest')) = '{}' AND (public.get_invoices_list(p_search => 'livetest')#>>'{pagination,total_count}') = '0', 'a user with no business sees nothing');
SELECT set_config('request.jwt.claims', jsonb_build_object('role', 'service_role')::text, true);
SELECT pg_temp.live_assert((public.get_invoices_list(p_search => 'livetest')#>>'{pagination,total_count}') = '0', 'no signed-in user: nothing');
ROLLBACK;
SELECT 'invoice list: live writes, roles, sorts with tie-breaks, search, filters and paging passed' AS result;

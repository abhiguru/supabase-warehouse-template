-- Migration 138: get_dispatch_list_with_items and get_invoices_list clamp their page size.
--   p_limit 100000 answers 200 rows; p_limit 0 or negative answers 1 row; p_page 0 or negative is page 1;
--   p_offset negative is offset 0 (it used to fail); has_more stays right at the clamped size.
-- 250 dispatches and 250 invoices of one fictional customer are written as the owner and read as the administrator.
-- Runs ONLY in migrations.sh's fresh, network-disabled database. All rows roll back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.lc_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'list clamps 138: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.lc_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.lc_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
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
SELECT warehouse_security.bootstrap_first_admin('9888888001', 'Clamp Rule Administrator');
SELECT pg_temp.lc_login('9888888001') AS admin_claims \gset
INSERT INTO public.customers(name, mobile) VALUES ('Clamp Rule Cold', '9888888011') RETURNING id AS cust \gset
INSERT INTO public.goodsreceived(gr_no, customer_id, customer_name, date) VALUES ('CLR1', :'cust', 'Clamp Rule Cold', now()) RETURNING id AS gr \gset
INSERT INTO public.dispatch(disp_no, disp_date, customer_id, customer_name)
 SELECT 'CLD' || lpad(i::text, 4, '0'), now() - (i || ' minutes')::interval, :'cust', 'Clamp Rule Cold' FROM generate_series(1, 250) i;
INSERT INTO public.invoice(inv_fin_year, inv_no, gr_id, gr_no, customer_id, customer_name, inv_date, total)
 SELECT 2098, i, :'gr', 'CLR1', :'cust', 'Clamp Rule Cold', now() - (i || ' minutes')::interval, 10 FROM generate_series(1, 250) i;
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;

-- dispatches: the page size
SELECT public.get_dispatch_list_with_items(p_customer_id => :'cust', p_page => 1, p_limit => 100000) AS big \gset
SELECT pg_temp.lc_assert(:'big'::jsonb->>'success' = 'true' AND jsonb_array_length(:'big'::jsonb#>'{data,dispatches}') = 200
  AND (:'big'::jsonb#>>'{data,limit}')::int = 200 AND (:'big'::jsonb#>>'{data,total_count}')::int = 250 AND (:'big'::jsonb#>>'{data,total_pages}')::int = 2,
  'dispatch list: p_limit 100000 answers 200 of 250 rows in 2 pages: ' || left(:'big', 300));
SELECT public.get_dispatch_list_with_items(p_customer_id => :'cust', p_page => 1, p_limit => 200) AS exact \gset
SELECT pg_temp.lc_assert(jsonb_array_length(:'exact'::jsonb#>'{data,dispatches}') = 200 AND :'exact'::jsonb#>'{data,dispatches}' = :'big'::jsonb#>'{data,dispatches}',
  'dispatch list: p_limit 200 and p_limit 100000 answer the same page');
SELECT public.get_dispatch_list_with_items(p_customer_id => :'cust', p_page => 2, p_limit => 100000) AS second \gset
SELECT pg_temp.lc_assert(jsonb_array_length(:'second'::jsonb#>'{data,dispatches}') = 50 AND (:'second'::jsonb#>>'{data,current_page}')::int = 2,
  'dispatch list: page 2 of the clamped size holds the last 50 rows');
SELECT public.get_dispatch_list_with_items(p_customer_id => :'cust', p_page => 1, p_limit => 0) AS zero \gset
SELECT pg_temp.lc_assert(:'zero'::jsonb->>'success' = 'true' AND jsonb_array_length(:'zero'::jsonb#>'{data,dispatches}') = 1 AND (:'zero'::jsonb#>>'{data,limit}')::int = 1,
  'dispatch list: p_limit 0 answers 1 row: ' || left(:'zero', 300));
SELECT public.get_dispatch_list_with_items(p_customer_id => :'cust', p_page => 1, p_limit => -7) AS negative \gset
SELECT pg_temp.lc_assert(:'negative'::jsonb->>'success' = 'true' AND jsonb_array_length(:'negative'::jsonb#>'{data,dispatches}') = 1 AND (:'negative'::jsonb#>>'{data,limit}')::int = 1
  AND :'negative'::jsonb#>'{data,dispatches}' = :'zero'::jsonb#>'{data,dispatches}', 'dispatch list: a negative p_limit answers the same 1 row');
-- dispatches: the page number
SELECT public.get_dispatch_list_with_items(p_customer_id => :'cust', p_page => 0, p_limit => 10) AS page_zero \gset
SELECT public.get_dispatch_list_with_items(p_customer_id => :'cust', p_page => -4, p_limit => 10) AS page_negative \gset
SELECT public.get_dispatch_list_with_items(p_customer_id => :'cust', p_page => 1, p_limit => 10) AS page_one \gset
SELECT pg_temp.lc_assert(:'page_zero'::jsonb->>'success' = 'true' AND (:'page_zero'::jsonb#>>'{data,current_page}')::int = 1
  AND :'page_zero'::jsonb#>'{data,dispatches}' = :'page_one'::jsonb#>'{data,dispatches}' AND jsonb_array_length(:'page_zero'::jsonb#>'{data,dispatches}') = 10,
  'dispatch list: p_page 0 is page 1: ' || left(:'page_zero', 300));
SELECT pg_temp.lc_assert(:'page_negative'::jsonb->>'success' = 'true' AND (:'page_negative'::jsonb#>>'{data,current_page}')::int = 1
  AND :'page_negative'::jsonb#>'{data,dispatches}' = :'page_one'::jsonb#>'{data,dispatches}', 'dispatch list: a negative p_page is page 1');
-- a page number whose offset passes the integer range answers an empty page (the offset is computed in bigint)
SELECT public.get_dispatch_list_with_items(p_customer_id => :'cust', p_page => 20000000, p_limit => 200) AS page_far \gset
SELECT pg_temp.lc_assert(:'page_far'::jsonb->>'success' = 'true' AND jsonb_array_length(:'page_far'::jsonb#>'{data,dispatches}') = 0
  AND (:'page_far'::jsonb#>>'{data,total_count}')::int = 250, 'dispatch list: p_page 20000000 answers an empty page, not an overflow: ' || left(:'page_far', 300));

-- invoices: the page size
SELECT public.get_invoices_list(p_limit => 100000, p_offset => 0, p_customer_id => :'cust') AS inv_big \gset
SELECT pg_temp.lc_assert(:'inv_big'::jsonb->>'success' = 'true' AND jsonb_array_length(:'inv_big'::jsonb->'data') = 200
  AND (:'inv_big'::jsonb#>>'{pagination,total_count}')::int = 250 AND (:'inv_big'::jsonb#>>'{pagination,has_more}')::boolean,
  'invoice list: p_limit 100000 answers 200 of 250 rows with more to come: ' || left(:'inv_big', 300));
SELECT public.get_invoices_list(p_limit => 200, p_offset => 0, p_customer_id => :'cust') AS inv_exact \gset
SELECT pg_temp.lc_assert(:'inv_exact'::jsonb->'data' = :'inv_big'::jsonb->'data', 'invoice list: p_limit 200 and p_limit 100000 answer the same page');
SELECT public.get_invoices_list(p_limit => 100000, p_offset => 200, p_customer_id => :'cust') AS inv_last \gset
SELECT pg_temp.lc_assert(jsonb_array_length(:'inv_last'::jsonb->'data') = 50 AND NOT (:'inv_last'::jsonb#>>'{pagination,has_more}')::boolean,
  'invoice list: the clamped size reaches the last 50 rows and has_more turns false');
SELECT public.get_invoices_list(p_limit => 0, p_offset => 0, p_customer_id => :'cust') AS inv_zero \gset
SELECT public.get_invoices_list(p_limit => -9, p_offset => 0, p_customer_id => :'cust') AS inv_negative \gset
SELECT pg_temp.lc_assert(jsonb_array_length(:'inv_zero'::jsonb->'data') = 1 AND (:'inv_zero'::jsonb#>>'{pagination,has_more}')::boolean
  AND :'inv_negative'::jsonb->'data' = :'inv_zero'::jsonb->'data', 'invoice list: p_limit 0 and a negative p_limit answer 1 row');
-- invoices: the offset
SELECT public.get_invoices_list(p_limit => 5, p_offset => -3, p_customer_id => :'cust') AS inv_off \gset
SELECT public.get_invoices_list(p_limit => 5, p_offset => 0, p_customer_id => :'cust') AS inv_off0 \gset
SELECT pg_temp.lc_assert(:'inv_off'::jsonb->>'success' = 'true' AND jsonb_array_length(:'inv_off'::jsonb->'data') = 5 AND :'inv_off'::jsonb->'data' = :'inv_off0'::jsonb->'data',
  'invoice list: a negative p_offset is offset 0: ' || left(:'inv_off', 300));
-- a huge offset does not overflow has_more
SELECT public.get_invoices_list(p_limit => 200, p_offset => 2147483600, p_customer_id => :'cust') AS inv_far \gset
SELECT pg_temp.lc_assert(:'inv_far'::jsonb->>'success' = 'true' AND jsonb_array_length(:'inv_far'::jsonb->'data') = 0 AND NOT (:'inv_far'::jsonb#>>'{pagination,has_more}')::boolean,
  'invoice list: an offset near the integer limit answers an empty page: ' || left(:'inv_far', 300));
RESET ROLE;
ROLLBACK;

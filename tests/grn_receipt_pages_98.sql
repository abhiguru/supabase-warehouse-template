-- Migration 98: the GRN lists page by receipt when p_filters.page_by = 'receipt', and filter low stock.
-- Runs ONLY in migrations.sh's fresh, network-disabled database. All fixture rows roll back.
-- Fixtures: RPG1 (5 lines) RPG2 (12) RPG3 (4) RPG4 (3) RPG5 (3) of customer A, RPG6 (2) of customer B.
-- 29 lines in all. RPG4 and RPG5 carry the same date. In line mode, lines 11-20 by number are
-- 7 lines of RPG2 and 3 of RPG3: a receipt split across a page.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.rp_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'receipt pages: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.rp_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.rp_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- Receipt numbers of the lines of a response, one entry per line, in the response's own order.
CREATE FUNCTION pg_temp.rp_staff_lines(result jsonb) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(l->>'gr_no' ORDER BY ord), '{}') FROM jsonb_array_elements(result->'data') WITH ORDINALITY AS t(l, ord) $$;
CREATE FUNCTION pg_temp.rp_staff_marks(result jsonb) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(l->>'package_mark' ORDER BY l->>'package_mark'), '{}') FROM jsonb_array_elements(result->'data') AS t(l) $$;
CREATE FUNCTION pg_temp.rp_cust_lines(result jsonb) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(l->>'gr_no' ORDER BY ord), '{}') FROM jsonb_array_elements(result#>'{data,items}') WITH ORDINALITY AS t(l, ord) $$;
CREATE FUNCTION pg_temp.rp_cust_marks(result jsonb) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(l->>'package_mark' ORDER BY l->>'package_mark'), '{}') FROM jsonb_array_elements(result#>'{data,items}') AS t(l) $$;
-- The same line list, collapsed to its receipts in first-seen order.
CREATE FUNCTION pg_temp.rp_receipts(lines text[]) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(n ORDER BY first_seen), '{}') FROM (SELECT n, min(ord) AS first_seen FROM unnest(lines) WITH ORDINALITY AS t(n, ord) GROUP BY n) s $$;
-- No receipt appears in two separate runs of lines.
CREATE FUNCTION pg_temp.rp_contiguous(lines text[]) RETURNS boolean LANGUAGE sql AS $$
  SELECT count(*) = count(DISTINCT n) FROM (SELECT n FROM (SELECT n, lag(n) OVER (ORDER BY ord) AS prev FROM unnest(lines) WITH ORDINALITY AS t(n, ord)) s
    WHERE prev IS DISTINCT FROM n) runs $$;

INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888888771', 'Receipt Pages Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888888774', 'Receipt Pages Customer', 'customer', true, 'approved');
SELECT pg_temp.rp_login('9888888771') AS admin_claims \gset
SELECT pg_temp.rp_login('9888888774') AS customer_claims \gset
INSERT INTO public.customers(name, mobile) VALUES ('Receipt Pages Alpha', '9888888761') RETURNING id AS alpha \gset
INSERT INTO public.customers(name, mobile) VALUES ('Receipt Pages Beta', '9888888762') RETURNING id AS beta \gset
INSERT INTO public.items(name, packaging) VALUES ('Receipt Pages Garlic', 'Bag') RETURNING id AS garlic \gset
INSERT INTO public.users_customers_new(user_profile_id, customer_id, active)
 SELECT id, :'alpha'::uuid, true FROM public.user_profiles WHERE mobile = '919888888774';

SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
CREATE FUNCTION pg_temp.rp_save(gr_no text, customer uuid, customer_name text, at timestamptz, lines integer) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_temp.rp_assert((public.save_grn(p_gr_no => gr_no, p_date => at, p_customer_id => customer, p_customer_name => customer_name,
    p_idempotency_key => 'rp-' || gr_no,
    p_items => (SELECT jsonb_agg(jsonb_build_object('item_id', current_setting('test.rp_garlic'), 'item_name', 'Receipt Pages Garlic',
      'packaging', 'Bag', 'qty', 100, 'weight', 5, 'package_mark', gr_no || '-' || n) ORDER BY n) FROM generate_series(1, lines) AS n)))->>'success' = 'true',
    'fixture ' || gr_no);
END $$;
SELECT set_config('test.rp_garlic', :'garlic', true);
SELECT pg_temp.rp_save('RPG1', :'alpha'::uuid, 'Receipt Pages Alpha', date_trunc('second', now()) - interval '10 days', 5);
SELECT pg_temp.rp_save('RPG2', :'alpha'::uuid, 'Receipt Pages Alpha', date_trunc('second', now()) - interval '9 days', 12);
SELECT pg_temp.rp_save('RPG3', :'alpha'::uuid, 'Receipt Pages Alpha', date_trunc('second', now()) - interval '8 days', 4);
SELECT pg_temp.rp_save('RPG4', :'alpha'::uuid, 'Receipt Pages Alpha', date_trunc('second', now()) - interval '1 day', 3);
SELECT pg_temp.rp_save('RPG5', :'alpha'::uuid, 'Receipt Pages Alpha', date_trunc('second', now()) - interval '1 day', 3);
SELECT pg_temp.rp_save('RPG6', :'beta'::uuid, 'Receipt Pages Beta', date_trunc('second', now()) - interval '2 days', 2);
RESET ROLE;
-- Stock of RPG3's four lines (qty 100): 0 is out of stock, 10 and 19 are below 20%, 20 is exactly 20% (not low).
UPDATE public.goodsreceived_trl SET stock = CASE package_mark WHEN 'RPG3-1' THEN 0 WHEN 'RPG3-2' THEN 10 WHEN 'RPG3-3' THEN 19 ELSE 20 END
 WHERE package_mark IN ('RPG3-1', 'RPG3-2', 'RPG3-3', 'RPG3-4');
SELECT pg_temp.rp_assert((SELECT count(*) = 29 AND count(*) FILTER (WHERE stock = qty) = 25 FROM public.goodsreceived_trl WHERE package_mark LIKE 'RPG%'),
  'fixture: 29 lines, 25 of them with full stock');

-- Staff list ------------------------------------------------------------------------------------
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
CREATE FUNCTION pg_temp.staff(filters jsonb, sort_by text, direction text, page_size integer, skip integer) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.get_all_grn_items(p_filters => '{"search": "rpg"}'::jsonb || filters, p_sort_by => sort_by, p_sort_order => direction,
    p_limit => page_size, p_offset => skip) $$;
-- Line mode is as before: lines 11-20 by number split RPG2 (7 lines) from RPG3 (3 lines).
SELECT pg_temp.rp_assert(pg_temp.rp_staff_lines(pg_temp.staff('{}', 'gr_no', 'asc', 10, 10))
  = ARRAY['RPG2','RPG2','RPG2','RPG2','RPG2','RPG2','RPG2','RPG3','RPG3','RPG3'], 'staff line mode: a receipt is split across a page: ' || pg_temp.rp_staff_lines(pg_temp.staff('{}', 'gr_no', 'asc', 10, 10))::text);
SELECT pg_temp.rp_assert(pg_temp.staff('{}', 'gr_no', 'asc', 10, 10)#>>'{pagination,total_count}' = '29'
  AND pg_temp.staff('{}', 'gr_no', 'asc', 10, 10)#>>'{pagination,unit}' = 'line'
  AND pg_temp.staff('{"page_by": "line"}', 'gr_no', 'asc', 10, 10)#>>'{pagination,unit}' = 'line', 'staff line mode counts lines');
SELECT pg_temp.rp_assert(pg_temp.staff('{}', 'gr_no', 'asc', 10, 10)#>'{data}' = pg_temp.staff('{"page_by": "line"}', 'gr_no', 'asc', 10, 10)#>'{data}'
  AND pg_temp.staff('{}', 'gr_no', 'asc', 10, 10)->'aggregates' = pg_temp.staff('{"page_by": "line"}', 'gr_no', 'asc', 10, 10)->'aggregates', 'staff line mode: page_by line equals no key');
SELECT pg_temp.rp_assert(pg_temp.staff('{}', 'item_name', 'asc', 10, 0)->>'success' = 'true', 'staff line mode still sorts by item_name');
-- Receipt mode: the page size counts receipts and the receipt stays whole.
SELECT pg_temp.rp_assert(pg_temp.rp_staff_lines(pg_temp.staff('{"page_by": "receipt"}', 'gr_no', 'asc', 1, 1)) = array_fill('RPG2'::text, ARRAY[12]),
  'staff receipt mode: page 2 of size 1 is all 12 lines of RPG2: ' || pg_temp.rp_staff_lines(pg_temp.staff('{"page_by": "receipt"}', 'gr_no', 'asc', 1, 1))::text);
SELECT pg_temp.rp_assert(pg_temp.rp_receipts(pg_temp.rp_staff_lines(pg_temp.staff('{"page_by": "receipt"}', 'gr_no', 'asc', 2, 0))) = ARRAY['RPG1', 'RPG2']
  AND cardinality(pg_temp.rp_staff_lines(pg_temp.staff('{"page_by": "receipt"}', 'gr_no', 'asc', 2, 0))) = 17, 'staff receipt mode: two receipts, 17 lines');
SELECT pg_temp.rp_assert(pg_temp.rp_staff_lines(pg_temp.staff('{"page_by": "receipt"}', 'gr_no', 'asc', 2, 4)) = ARRAY['RPG5','RPG5','RPG5','RPG6','RPG6'],
  'staff receipt mode: last page holds RPG5 and RPG6');
SELECT pg_temp.rp_assert(pg_temp.rp_staff_lines(pg_temp.staff('{"page_by": "receipt"}', 'gr_no', 'asc', 2, 6)) = '{}', 'staff receipt mode: past the end is empty');
SELECT pg_temp.rp_assert(pg_temp.staff('{"page_by": "receipt"}', 'gr_no', 'asc', 1, 1)#>>'{pagination,total_count}' = '6'
  AND pg_temp.staff('{"page_by": "receipt"}', 'gr_no', 'asc', 1, 1)#>>'{pagination,unit}' = 'receipt'
  AND pg_temp.staff('{"page_by": "receipt"}', 'gr_no', 'asc', 1, 1)#>>'{pagination,limit}' = '1'
  AND pg_temp.staff('{"page_by": "receipt"}', 'gr_no', 'asc', 1, 1)#>>'{aggregates,total_qty}' = '2900', 'staff receipt mode counts receipts (6), aggregates stay over all 29 lines');
-- Same date: RPG4 and RPG5 order by number and never interleave; the default sort is the date.
SELECT pg_temp.rp_assert(pg_temp.rp_staff_lines(pg_temp.staff('{"page_by": "receipt"}', 'date', 'desc', 6, 0))
  = ARRAY['RPG4','RPG4','RPG4','RPG5','RPG5','RPG5','RPG6','RPG6','RPG3','RPG3','RPG3','RPG3','RPG2','RPG2','RPG2','RPG2','RPG2','RPG2','RPG2','RPG2','RPG2','RPG2','RPG2','RPG2','RPG1','RPG1','RPG1','RPG1','RPG1'],
  'staff receipt mode, date descending: ' || pg_temp.rp_staff_lines(pg_temp.staff('{"page_by": "receipt"}', 'date', 'desc', 6, 0))::text);
SELECT pg_temp.rp_assert(pg_temp.rp_staff_lines(pg_temp.staff('{"page_by": "receipt"}', NULL, 'desc', 1, 0)) = ARRAY['RPG4','RPG4','RPG4'],
  'staff receipt mode: no sort means date; newest first, ties by number');
SELECT pg_temp.rp_assert(pg_temp.rp_receipts(pg_temp.rp_staff_lines(pg_temp.staff('{"page_by": "receipt"}', 'customer_name', 'desc', 6, 0)))
  = ARRAY['RPG6', 'RPG1', 'RPG2', 'RPG3', 'RPG4', 'RPG5'] AND pg_temp.rp_contiguous(pg_temp.rp_staff_lines(pg_temp.staff('{"page_by": "receipt"}', 'customer_name', 'desc', 6, 0))),
  'staff receipt mode, customer name descending: Beta first, Alpha receipts by number');
-- Line-level sorts are refused in receipt mode only.
SELECT pg_temp.rp_assert(pg_temp.staff('{"page_by": "receipt"}', 'item_name', 'asc', 10, 0) = '{"success": false, "message": "Invalid list parameters", "data": null}'::jsonb
  AND pg_temp.staff('{"page_by": "receipt"}', 'qty', 'asc', 10, 0)->>'success' = 'false'
  AND pg_temp.staff('{"page_by": "receipt"}', 'gr_no', 'asc', 10, 0)->>'success' = 'true', 'staff receipt mode refuses line sorts');
-- Filters apply before the ranks: only RPG3 has a low-stock line, so it is page 1 and the only receipt.
SELECT pg_temp.rp_assert(pg_temp.rp_staff_marks(pg_temp.staff('{"stock_status": "low_stock"}', 'gr_no', 'asc', 100, 0)) = ARRAY['RPG3-2', 'RPG3-3'],
  'staff low_stock: 0 < stock < 20% of qty only: ' || pg_temp.rp_staff_marks(pg_temp.staff('{"stock_status": "low_stock"}', 'gr_no', 'asc', 100, 0))::text);
SELECT pg_temp.rp_assert(pg_temp.rp_staff_marks(pg_temp.staff('{"stock_status": "out_of_stock"}', 'gr_no', 'asc', 100, 0)) = ARRAY['RPG3-1']
  AND cardinality(pg_temp.rp_staff_marks(pg_temp.staff('{"stock_status": "in_stock"}', 'gr_no', 'asc', 100, 0))) = 28
  AND cardinality(pg_temp.rp_staff_marks(pg_temp.staff('{"stock_status": "all"}', 'gr_no', 'asc', 100, 0))) = 29, 'staff out_of_stock, in_stock and all are unchanged');
SELECT pg_temp.rp_assert(pg_temp.rp_staff_marks(pg_temp.staff('{"stock_status": "low_stock", "page_by": "receipt"}', 'gr_no', 'asc', 1, 0)) = ARRAY['RPG3-2', 'RPG3-3']
  AND pg_temp.staff('{"stock_status": "low_stock", "page_by": "receipt"}', 'gr_no', 'asc', 1, 0)#>>'{pagination,total_count}' = '1', 'staff receipt mode with low_stock: one receipt, only its low lines');
RESET ROLE;

-- Customer list ---------------------------------------------------------------------------------
SELECT set_config('request.jwt.claims', :'customer_claims', true);
SET LOCAL ROLE authenticated;
CREATE FUNCTION pg_temp.mine(filters jsonb, sort_by text, direction text, page_size integer, skip integer) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.get_customer_grn_items(p_customer_id => current_setting('test.rp_alpha')::uuid, p_filters => '{"search": "rpg"}'::jsonb || filters,
    p_sort_by => sort_by, p_sort_order => direction, p_limit => page_size, p_offset => skip) $$;
SELECT set_config('test.rp_alpha', :'alpha', true);
-- Line mode is as before; the customer sees 27 lines, never RPG6.
SELECT pg_temp.rp_assert(pg_temp.rp_cust_lines(pg_temp.mine('{}', 'gr_no', 'asc', 10, 10))
  = ARRAY['RPG2','RPG2','RPG2','RPG2','RPG2','RPG2','RPG2','RPG3','RPG3','RPG3'], 'customer line mode: a receipt is split across a page: ' || pg_temp.rp_cust_lines(pg_temp.mine('{}', 'gr_no', 'asc', 10, 10))::text);
SELECT pg_temp.rp_assert(pg_temp.mine('{}', 'gr_no', 'asc', 10, 10)#>>'{data,pagination,total_count}' = '27'
  AND pg_temp.mine('{}', 'gr_no', 'asc', 10, 10)#>>'{data,pagination,total}' = '27'
  AND pg_temp.mine('{}', 'gr_no', 'asc', 10, 10)#>>'{data,pagination,unit}' = 'line'
  AND pg_temp.mine('{}', 'gr_no', 'asc', 10, 10)#>>'{data,pagination,has_more}' = 'true'
  AND pg_temp.mine('{"page_by": "line"}', 'gr_no', 'asc', 10, 10)#>>'{data,pagination,unit}' = 'line', 'customer line mode counts lines');
SELECT pg_temp.rp_assert(pg_temp.mine('{}', 'gr_no', 'asc', 10, 10)#>'{data,items}' = pg_temp.mine('{"page_by": "line"}', 'gr_no', 'asc', 10, 10)#>'{data,items}'
  AND pg_temp.mine('{}', 'item_name', 'asc', 10, 0)->>'success' = 'true', 'customer line mode: page_by line equals no key, item_name sort allowed');
-- Receipt mode.
SELECT pg_temp.rp_assert(pg_temp.rp_cust_lines(pg_temp.mine('{"page_by": "receipt"}', 'gr_no', 'asc', 1, 1)) = array_fill('RPG2'::text, ARRAY[12]),
  'customer receipt mode: page 2 of size 1 is all 12 lines of RPG2: ' || pg_temp.rp_cust_lines(pg_temp.mine('{"page_by": "receipt"}', 'gr_no', 'asc', 1, 1))::text);
SELECT pg_temp.rp_assert(pg_temp.rp_receipts(pg_temp.rp_cust_lines(pg_temp.mine('{"page_by": "receipt"}', 'gr_no', 'asc', 2, 0))) = ARRAY['RPG1', 'RPG2']
  AND cardinality(pg_temp.rp_cust_lines(pg_temp.mine('{"page_by": "receipt"}', 'gr_no', 'asc', 2, 0))) = 17, 'customer receipt mode: two receipts, 17 lines');
SELECT pg_temp.rp_assert(pg_temp.rp_cust_lines(pg_temp.mine('{"page_by": "receipt"}', 'gr_no', 'asc', 2, 4)) = ARRAY['RPG5','RPG5','RPG5'], 'customer receipt mode: last page holds RPG5 only');
SELECT pg_temp.rp_assert(pg_temp.mine('{"page_by": "receipt"}', 'gr_no', 'asc', 2, 0)#>>'{data,pagination,total_count}' = '5'
  AND pg_temp.mine('{"page_by": "receipt"}', 'gr_no', 'asc', 2, 0)#>>'{data,pagination,total}' = '5'
  AND pg_temp.mine('{"page_by": "receipt"}', 'gr_no', 'asc', 2, 0)#>>'{data,aggregations,total_count}' = '5'
  AND pg_temp.mine('{"page_by": "receipt"}', 'gr_no', 'asc', 2, 0)#>>'{data,pagination,unit}' = 'receipt'
  AND pg_temp.mine('{"page_by": "receipt"}', 'gr_no', 'asc', 2, 0)#>>'{data,pagination,has_more}' = 'true'
  AND pg_temp.mine('{"page_by": "receipt"}', 'gr_no', 'asc', 2, 4)#>>'{data,pagination,has_more}' = 'false'
  AND pg_temp.mine('{"page_by": "receipt"}', 'gr_no', 'asc', 2, 0)#>>'{data,aggregations,total_qty}' = '2700', 'customer receipt mode counts receipts (5), totals stay over all 27 lines');
SELECT pg_temp.rp_assert(pg_temp.rp_cust_lines(pg_temp.mine('{"page_by": "receipt"}', 'date', 'desc', 5, 0))
  = ARRAY['RPG4','RPG4','RPG4','RPG5','RPG5','RPG5','RPG3','RPG3','RPG3','RPG3','RPG2','RPG2','RPG2','RPG2','RPG2','RPG2','RPG2','RPG2','RPG2','RPG2','RPG2','RPG2','RPG1','RPG1','RPG1','RPG1','RPG1'],
  'customer receipt mode, date descending: same-date RPG4, RPG5 by number, no interleaving: ' || pg_temp.rp_cust_lines(pg_temp.mine('{"page_by": "receipt"}', 'date', 'desc', 5, 0))::text);
SELECT pg_temp.rp_assert(pg_temp.rp_cust_lines(pg_temp.mine('{"page_by": "receipt"}', 'date', 'asc', 5, 0))
  = ARRAY['RPG1','RPG1','RPG1','RPG1','RPG1','RPG2','RPG2','RPG2','RPG2','RPG2','RPG2','RPG2','RPG2','RPG2','RPG2','RPG2','RPG2','RPG3','RPG3','RPG3','RPG3','RPG4','RPG4','RPG4','RPG5','RPG5','RPG5'],
  'customer receipt mode, date ascending');
SELECT pg_temp.rp_assert(pg_temp.mine('{"page_by": "receipt"}', 'item_name', 'asc', 10, 0) = '{"success": false, "message": "Invalid list parameters", "data": null}'::jsonb
  AND pg_temp.mine('{"page_by": "receipt"}', 'stock', 'asc', 10, 0)->>'success' = 'false'
  AND pg_temp.mine('{"page_by": "receipt"}', 'customer_name', 'asc', 10, 0)->>'success' = 'true'
  AND pg_temp.mine('{"page_by": "receipt"}', 'gr_no', 'asc', 0, 0)->>'success' = 'false'
  AND pg_temp.mine('{"page_by": "receipt"}', 'gr_no', 'asc', 101, 0)->>'success' = 'false', 'customer receipt mode refuses line sorts; the limit check stays');
SELECT pg_temp.rp_assert(pg_temp.rp_cust_marks(pg_temp.mine('{"stock_status": "low_stock"}', 'gr_no', 'asc', 100, 0)) = ARRAY['RPG3-2', 'RPG3-3'],
  'customer low_stock: 0 < stock < 20% of qty only: ' || pg_temp.rp_cust_marks(pg_temp.mine('{"stock_status": "low_stock"}', 'gr_no', 'asc', 100, 0))::text);
SELECT pg_temp.rp_assert(pg_temp.rp_cust_marks(pg_temp.mine('{"stock_status": "out_of_stock"}', 'gr_no', 'asc', 100, 0)) = ARRAY['RPG3-1']
  AND cardinality(pg_temp.rp_cust_marks(pg_temp.mine('{"stock_status": "in_stock"}', 'gr_no', 'asc', 100, 0))) = 26
  AND cardinality(pg_temp.rp_cust_marks(pg_temp.mine('{"stock_status": "all"}', 'gr_no', 'asc', 100, 0))) = 27
  AND cardinality(pg_temp.rp_cust_marks(pg_temp.mine('{"stock_status": "nonsense"}', 'gr_no', 'asc', 100, 0))) = 0, 'customer out_of_stock, in_stock, all and unknown values are unchanged');
SELECT pg_temp.rp_assert(pg_temp.rp_cust_marks(pg_temp.mine('{"stock_status": "low_stock", "page_by": "receipt"}', 'gr_no', 'asc', 1, 0)) = ARRAY['RPG3-2', 'RPG3-3']
  AND pg_temp.mine('{"stock_status": "low_stock", "page_by": "receipt"}', 'gr_no', 'asc', 1, 0)#>>'{data,pagination,total_count}' = '1', 'customer receipt mode with low_stock');
-- Only own receipts, in either mode.
SELECT pg_temp.rp_assert(NOT ('RPG6' = ANY (pg_temp.rp_cust_lines(pg_temp.mine('{"page_by": "receipt"}', 'gr_no', 'asc', 100, 0))))
  AND NOT ('RPG6' = ANY (pg_temp.rp_cust_lines(pg_temp.mine('{}', 'gr_no', 'asc', 100, 0)))), 'customer never sees the other customer''s receipt');
RESET ROLE;

-- The functions keep their access rules and their document-number key.
SELECT pg_temp.rp_assert((SELECT bool_and(prosecdef) AND count(*) = 2 FROM pg_proc WHERE oid IN (
  'public.get_all_grn_items(timestamptz,timestamptz,jsonb,text,text,integer,integer)'::regprocedure,
  'public.get_customer_grn_items(uuid,timestamptz,timestamptz,jsonb,text,text,integer,integer)'::regprocedure)), 'both stay SECURITY DEFINER');
SELECT pg_temp.rp_assert(NOT has_function_privilege('anon', 'public.get_all_grn_items(timestamptz,timestamptz,jsonb,text,text,integer,integer)', 'execute')
  AND NOT has_function_privilege('anon', 'public.get_customer_grn_items(uuid,timestamptz,timestamptz,jsonb,text,text,integer,integer)', 'execute'), 'anon still cannot call them');
ROLLBACK;

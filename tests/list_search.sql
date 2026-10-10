-- Quick search and document-order number ranges on the receipt lists (migration 35) and on the
-- dispatch, invoice and order lists (migration 36).
-- Runs ONLY in migrations.sh's fresh, network-disabled database. All fixture rows roll back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.search_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'list search: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.search_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.search_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- The receipt numbers in a list response, whatever its envelope, restricted to this test's rows.
CREATE FUNCTION pg_temp.receipts(result jsonb) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(DISTINCT n ORDER BY n), '{}')
  FROM (SELECT x #>> '{}' AS n FROM jsonb_path_query(result, '$.**.gr_no') AS x) s WHERE n LIKE 'SRB%' $$;

-- The helper itself.
SELECT pg_temp.search_assert(warehouse_security.search_terms('  Lake   50%_x\ ') = ARRAY['%Lake%', '%50\%\_x\\%'], 'words are split and wildcards escaped');
SELECT pg_temp.search_assert(warehouse_security.search_terms(NULL) = '{}' AND warehouse_security.search_terms('   ') = '{}', 'empty search has no terms');
SELECT pg_temp.search_assert(cardinality(warehouse_security.search_terms('a b c d e f g h i j')) = 8, 'at most eight words');
SELECT pg_temp.search_assert(NOT has_function_privilege('authenticated', 'warehouse_security.search_terms(text)', 'execute'), 'helper is not an API function');

INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888888761', 'Search Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888888764', 'Search Customer', 'customer', true, 'approved');
SELECT pg_temp.search_login('9888888761') AS admin_claims \gset
SELECT pg_temp.search_login('9888888764') AS customer_claims \gset
INSERT INTO public.customers(name, mobile) VALUES ('Search Lakeview Spices', '9888888751') RETURNING id AS lakeview \gset
INSERT INTO public.customers(name, mobile) VALUES ('Search Hilltop Mart', '9888888752') RETURNING id AS hilltop \gset
INSERT INTO public.items(name, packaging) VALUES ('Search Garlic', 'Bag') RETURNING id AS garlic \gset
INSERT INTO public.items(name, packaging) VALUES ('Search Onion', 'Bag') RETURNING id AS onion \gset
INSERT INTO public.users_customers_new(user_profile_id, customer_id, active)
 SELECT id, :'lakeview'::uuid, true FROM public.user_profiles WHERE mobile = '919888888764';

SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
-- SRB9: Lakeview, garlic, package PKG-RED, rack R7, vehicle GJ01SR0001.
-- SRB10: Lakeview, onion.   SRB100: Hilltop, garlic, package PKG_50%.
SELECT pg_temp.search_assert((public.save_grn(p_gr_no => 'SRB9', p_date => now() - interval '3 days', p_customer_id => :'lakeview'::uuid,
  p_customer_name => 'Search Lakeview Spices', p_registration => 'GJ01SR0001', p_idempotency_key => 'search-srb9',
  p_items => jsonb_build_array(jsonb_build_object('item_id', :'garlic', 'item_name', 'Search Garlic', 'packaging', 'Bag',
    'qty', 10, 'weight', 5, 'package_mark', 'PKG-RED', 'rack', 'R7'))))->>'success' = 'true', 'fixture SRB9');
SELECT pg_temp.search_assert((public.save_grn(p_gr_no => 'SRB10', p_date => now() - interval '2 days', p_customer_id => :'lakeview'::uuid,
  p_customer_name => 'Search Lakeview Spices', p_idempotency_key => 'search-srb10',
  p_items => jsonb_build_array(jsonb_build_object('item_id', :'onion', 'item_name', 'Search Onion', 'packaging', 'Bag',
    'qty', 10, 'weight', 5))))->>'success' = 'true', 'fixture SRB10');
SELECT pg_temp.search_assert((public.save_grn(p_gr_no => 'SRB100', p_date => now() - interval '1 day', p_customer_id => :'hilltop'::uuid,
  p_customer_name => 'Search Hilltop Mart', p_idempotency_key => 'search-srb100',
  p_items => jsonb_build_array(jsonb_build_object('item_id', :'garlic', 'item_name', 'Search Garlic', 'packaging', 'Bag',
    'qty', 10, 'weight', 5, 'package_mark', 'PKG_50%'))))->>'success' = 'true', 'fixture SRB100');

-- Staff list: one case per column, then combinations and literals.
CREATE FUNCTION pg_temp.staff(filters jsonb) RETURNS text[] LANGUAGE sql AS $$
  SELECT pg_temp.receipts(public.get_all_grn_items(p_filters => filters, p_sort_by => 'gr_no', p_sort_order => 'asc', p_limit => 100, p_offset => 0)) $$;
SELECT pg_temp.search_assert(pg_temp.staff('{}') = ARRAY['SRB10', 'SRB100', 'SRB9'], 'no search lists all three: ' || pg_temp.staff('{}')::text);
SELECT pg_temp.search_assert(pg_temp.staff('{"search": "srb9"}') = ARRAY['SRB9'], 'receipt number');
SELECT pg_temp.search_assert(pg_temp.staff('{"search": "HILLTOP"}') = ARRAY['SRB100'], 'customer, any case');
SELECT pg_temp.search_assert(pg_temp.staff('{"search": "garlic"}') = ARRAY['SRB100', 'SRB9'], 'item');
SELECT pg_temp.search_assert(pg_temp.staff('{"search": "pkg-red"}') = ARRAY['SRB9'], 'package');
SELECT pg_temp.search_assert(pg_temp.staff('{"search": "r7"}') = ARRAY['SRB9'], 'rack');
SELECT pg_temp.search_assert(pg_temp.staff('{"search": "gj01sr"}') = ARRAY['SRB9'], 'vehicle number');
SELECT pg_temp.search_assert(pg_temp.staff('{"search": "lakeview garlic"}') = ARRAY['SRB9'], 'two words in different columns');
SELECT pg_temp.search_assert(pg_temp.staff('{"search": "lakeview hilltop"}') = '{}', 'every word must match');
SELECT pg_temp.search_assert(pg_temp.staff('{"search": "50%"}') = ARRAY['SRB100'], 'percent is literal');
SELECT pg_temp.search_assert(pg_temp.staff('{"search": "pkg_red"}') = '{}', 'underscore is literal, not "any character"');
SELECT pg_temp.search_assert(pg_temp.staff('{"search": "   "}') = ARRAY['SRB10', 'SRB100', 'SRB9'], 'blank search is no search');
SELECT pg_temp.search_assert(pg_temp.staff('{"search": "garlic", "customer_ids": []}') = ARRAY['SRB100', 'SRB9'], 'search with another filter key');
-- Ranges follow document order: plain text would find nothing between SRB9 and SRB10.
SELECT pg_temp.search_assert(pg_temp.staff('{"gr_no_from": "SRB9", "gr_no_to": "SRB10"}') = ARRAY['SRB10', 'SRB9'], 'range SRB9..SRB10');
SELECT pg_temp.search_assert(pg_temp.staff('{"gr_no_from": "SRB10"}') = ARRAY['SRB10', 'SRB100'], 'from SRB10');
SELECT pg_temp.search_assert(pg_temp.staff('{"gr_no_to": "SRB9"}') = ARRAY['SRB9'], 'up to SRB9');
RESET ROLE;

-- Customer list: same rule, own customers only.
SELECT set_config('request.jwt.claims', :'customer_claims', true);
SET LOCAL ROLE authenticated;
CREATE FUNCTION pg_temp.mine(customer uuid, filters jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.get_customer_grn_items(p_customer_id => customer, p_filters => filters, p_sort_by => 'gr_no', p_sort_order => 'asc', p_limit => 100, p_offset => 0) $$;
SELECT pg_temp.search_assert(pg_temp.receipts(pg_temp.mine(:'lakeview', '{}')) = ARRAY['SRB10', 'SRB9'], 'customer sees own receipts');
SELECT pg_temp.search_assert(pg_temp.receipts(pg_temp.mine(:'lakeview', '{"search": "garlic"}')) = ARRAY['SRB9'], 'customer search by item');
SELECT pg_temp.search_assert(pg_temp.receipts(pg_temp.mine(:'lakeview', '{"search": "lakeview onion"}')) = ARRAY['SRB10'], 'customer search, two words');
SELECT pg_temp.search_assert(pg_temp.receipts(pg_temp.mine(:'lakeview', '{"search": "hilltop"}')) = '{}', 'customer cannot find another customer by name');
SELECT pg_temp.search_assert(pg_temp.receipts(pg_temp.mine(:'lakeview', '{"gr_no_from": "SRB9", "gr_no_to": "SRB10"}')) = ARRAY['SRB10', 'SRB9'], 'customer range in document order');
DO $$ DECLARE result jsonb; BEGIN
  BEGIN
    result := pg_temp.mine((SELECT id FROM public.customers WHERE name = 'Search Hilltop Mart'), '{"search": "garlic"}');
    PERFORM pg_temp.search_assert(result->>'success' = 'false', 'another customer''s list must be refused');
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;

-- Dispatch, invoice and order lists (migration 36).
-- SDB9: Lakeview, vehicle GJ05DS0009, line of SRB9 (garlic, PKG-RED, R7).
-- SDB10: Lakeview, line of SRB10 (onion).   SDB100: Hilltop, line of SRB100 (garlic, PKG_50%).
UPDATE public.customers SET city = 'Rajkot' WHERE id = :'hilltop';
INSERT INTO public.dispatch(disp_no, disp_date, customer_id, customer_name, registration)
 VALUES ('SDB9', now() - interval '2 days', :'lakeview', 'Search Lakeview Spices', 'GJ05DS0009') RETURNING id AS d9 \gset
INSERT INTO public.dispatch(disp_no, disp_date, customer_id, customer_name)
 VALUES ('SDB10', now() - interval '1 day', :'lakeview', 'Search Lakeview Spices') RETURNING id AS d10 \gset
INSERT INTO public.dispatch(disp_no, disp_date, customer_id, customer_name)
 VALUES ('SDB100', now(), :'hilltop', 'Search Hilltop Mart') RETURNING id AS d100 \gset
INSERT INTO public.dispatch_trl(gr_id, gr_trl_id, disp_id, disp_qty)
 SELECT t.gr_id, t.id, CASE g.gr_no WHEN 'SRB9' THEN :'d9'::uuid WHEN 'SRB10' THEN :'d10'::uuid ELSE :'d100'::uuid END, 2
 FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id = t.gr_id WHERE g.gr_no IN ('SRB9', 'SRB10', 'SRB100');
-- Invoices 2026-12 (Lakeview, SRB9), 2026-120 (Hilltop, SRB100) and 2025-7 (Lakeview, SRB10, over a year old).
INSERT INTO public.invoice(inv_fin_year, inv_no, gr_id, gr_no, customer_id, customer_name, inv_date, total)
 SELECT v.fin_year, v.inv_no, g.id, g.gr_no, g.customer_id, g.customer_name, now() - v.age, 100
 FROM (VALUES (2026, 12, 'SRB9', interval '2 days'), (2026, 120, 'SRB100', interval '1 day'), (2025, 7, 'SRB10', interval '400 days'))
   AS v(fin_year, inv_no, gr_no, age) JOIN public.goodsreceived g ON g.gr_no = v.gr_no;
REFRESH MATERIALIZED VIEW public.mv_invoice_list;
SELECT t.id AS lot9 FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id = t.gr_id WHERE g.gr_no = 'SRB9' \gset
SELECT t.id AS lot100 FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id = t.gr_id WHERE g.gr_no = 'SRB100' \gset

-- The functions that gained parameters replaced the old ones, with the same grants.
SELECT pg_temp.search_assert((SELECT count(*) = 2 FROM pg_proc WHERE pronamespace = 'public'::regnamespace
  AND proname IN ('get_invoices_list', 'get_orders_list')), 'one invoice list and one order list function');
SELECT pg_temp.search_assert(bool_and(has_function_privilege('authenticated', oid, 'execute') AND NOT has_function_privilege('anon', oid, 'execute')),
  'list functions are for signed-in callers only') FROM pg_proc
  WHERE pronamespace = 'public'::regnamespace AND proname IN ('get_invoices_list', 'get_orders_list');

-- This test's rows in each list. The dispatch list reports an error as success = false: raise it.
CREATE FUNCTION pg_temp.dispatches(filters jsonb) RETURNS text[] LANGUAGE plpgsql AS $$
DECLARE result jsonb := public.get_dispatch_list_with_items(p_filters => filters, p_limit => 100);
BEGIN
  IF result->>'success' <> 'true' THEN RAISE EXCEPTION 'dispatch list failed: %', result->>'message'; END IF;
  RETURN (SELECT COALESCE(array_agg(n ORDER BY n), '{}')
    FROM (SELECT x #>> '{}' AS n FROM jsonb_path_query(result, '$.data.dispatches[*].disp_no') AS x) s WHERE n LIKE 'SDB%');
END $$;
CREATE FUNCTION pg_temp.invoices(result jsonb) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(n ORDER BY n), '{}')
  FROM (SELECT (x->>'inv_fin_year') || '-' || (x->>'invoice_number') AS n, x#>>'{grn,gr_no}' AS gr_no
        FROM jsonb_path_query(result, '$.data[*]') AS x) s WHERE gr_no LIKE 'SRB%' $$;
CREATE FUNCTION pg_temp.orders(search text) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(n ORDER BY n), '{}')
  FROM (SELECT x #>> '{}' AS n FROM jsonb_path_query(public.get_orders_list(p_search => search, p_limit => 100),
    '$.data.orders[*].customer.name') AS x) s WHERE n LIKE 'Search %' $$;

SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'lakeview'::uuid) AS cart_lakeview \gset
SELECT public.get_or_create_cart(:'hilltop'::uuid) AS cart_hilltop \gset
SELECT pg_temp.search_assert(public.add_item_to_order(:'cart_lakeview'::uuid, :'lot9'::uuid, 1)->>'success' = 'true', 'fixture cart Lakeview');
SELECT pg_temp.search_assert(public.add_item_to_order(:'cart_hilltop'::uuid, :'lot100'::uuid, 1)->>'success' = 'true', 'fixture cart Hilltop');

-- Dispatches.
SELECT pg_temp.search_assert(pg_temp.dispatches('{}') = ARRAY['SDB10', 'SDB100', 'SDB9'], 'dispatches: all three: ' || pg_temp.dispatches('{}')::text);
SELECT pg_temp.search_assert(pg_temp.dispatches('{"search": "sdb9"}') = ARRAY['SDB9'], 'dispatches: number');
SELECT pg_temp.search_assert(pg_temp.dispatches('{"search": "HILLTOP"}') = ARRAY['SDB100'], 'dispatches: customer, any case');
SELECT pg_temp.search_assert(pg_temp.dispatches('{"search": "gj05ds"}') = ARRAY['SDB9'], 'dispatches: vehicle number');
SELECT pg_temp.search_assert(pg_temp.dispatches('{"search": "garlic"}') = ARRAY['SDB100', 'SDB9'], 'dispatches: item of a line');
SELECT pg_temp.search_assert(pg_temp.dispatches('{"search": "pkg-red"}') = ARRAY['SDB9'], 'dispatches: package of a line');
SELECT pg_temp.search_assert(pg_temp.dispatches('{"search": "r7"}') = ARRAY['SDB9'], 'dispatches: rack of a line');
SELECT pg_temp.search_assert(pg_temp.dispatches('{"search": "srb9"}') = ARRAY['SDB9'], 'dispatches: receipt number of a line');
SELECT pg_temp.search_assert(pg_temp.dispatches('{"search": "lakeview garlic"}') = ARRAY['SDB9'], 'dispatches: two words, header and line');
SELECT pg_temp.search_assert(pg_temp.dispatches('{"search": "lakeview hilltop"}') = '{}', 'dispatches: every word must match');
SELECT pg_temp.search_assert(pg_temp.dispatches('{"search": "50%"}') = ARRAY['SDB100'], 'dispatches: percent is literal');
SELECT pg_temp.search_assert(pg_temp.dispatches('{"search": "pkg_red"}') = '{}', 'dispatches: underscore is literal');
SELECT pg_temp.search_assert(pg_temp.dispatches('{"search": "  "}') = ARRAY['SDB10', 'SDB100', 'SDB9'], 'dispatches: blank search is no search');
SELECT pg_temp.search_assert(pg_temp.dispatches('{"package_mark": "pkg-red"}') = ARRAY['SDB9'], 'dispatches: package filter');
SELECT pg_temp.search_assert(pg_temp.dispatches('{"package_mark": "pkg"}') = ARRAY['SDB100', 'SDB9'], 'dispatches: package filter, part of the name');
SELECT pg_temp.search_assert(pg_temp.dispatches('{"package_mark": "pkg_red"}') = '{}', 'dispatches: package filter takes underscore literally');
SELECT pg_temp.search_assert(pg_temp.dispatches('{"package_mark": "pkg", "search": "hilltop"}') = ARRAY['SDB100'], 'dispatches: package filter with search');
SELECT pg_temp.search_assert(pg_temp.dispatches('{"disp_no_from": "SDB9", "disp_no_to": "SDB10"}') = ARRAY['SDB10', 'SDB9'], 'dispatches: range SDB9..SDB10');
SELECT pg_temp.search_assert(pg_temp.dispatches('{"disp_no_from": "SDB10"}') = ARRAY['SDB10', 'SDB100'], 'dispatches: from SDB10');
SELECT pg_temp.search_assert(pg_temp.dispatches('{"disp_no_to": "SDB9"}') = ARRAY['SDB9'], 'dispatches: up to SDB9');

-- Invoices.
SELECT pg_temp.search_assert(pg_temp.invoices(public.get_invoices_list()) = ARRAY['2025-7', '2026-12', '2026-120'], 'invoices: all three: ' || pg_temp.invoices(public.get_invoices_list())::text);
SELECT pg_temp.search_assert(pg_temp.invoices(public.get_invoices_list(p_search => '120')) = ARRAY['2026-120'], 'invoices: number');
SELECT pg_temp.search_assert(pg_temp.invoices(public.get_invoices_list(p_search => '2026-12')) = ARRAY['2026-12', '2026-120'], 'invoices: year-number');
SELECT pg_temp.search_assert(pg_temp.invoices(public.get_invoices_list(p_search => '2026-0012')) = ARRAY['2026-12'], 'invoices: year and padded number');
SELECT pg_temp.search_assert(pg_temp.invoices(public.get_invoices_list(p_search => 'hilltop')) = ARRAY['2026-120'], 'invoices: customer');
SELECT pg_temp.search_assert(pg_temp.invoices(public.get_invoices_list(p_search => 'srb9')) = ARRAY['2026-12'], 'invoices: receipt number');
SELECT pg_temp.search_assert(pg_temp.invoices(public.get_invoices_list(p_search => 'lakeview srb10')) = ARRAY['2025-7'], 'invoices: two words in different columns');
SELECT pg_temp.search_assert(pg_temp.invoices(public.get_invoices_list(p_search => 'lakeview hilltop')) = '{}', 'invoices: every word must match');
SELECT pg_temp.search_assert(pg_temp.invoices(public.get_invoices_list(p_search => '%')) = '{}', 'invoices: percent is literal');
SELECT pg_temp.search_assert(pg_temp.invoices(public.get_invoices_list(p_search => '  ')) = ARRAY['2025-7', '2026-12', '2026-120'], 'invoices: blank search is no search');
SELECT pg_temp.search_assert(pg_temp.invoices(public.get_invoices_list(p_date_from => now() - interval '3 days')) = ARRAY['2026-12', '2026-120'], 'invoices: from a date');
SELECT pg_temp.search_assert(pg_temp.invoices(public.get_invoices_list(p_date_to => now() - interval '300 days')) = ARRAY['2025-7'], 'invoices: up to a date');
SELECT pg_temp.search_assert(pg_temp.invoices(public.get_invoices_list(p_date_from => now() - interval '3 days', p_date_to => now() - interval '36 hours')) = ARRAY['2026-12'], 'invoices: between dates');
SELECT pg_temp.search_assert(pg_temp.invoices(public.get_invoices_list(p_customer_ids => ARRAY[:'lakeview'::uuid])) = ARRAY['2025-7', '2026-12'], 'invoices: one customer of a list');
SELECT pg_temp.search_assert(pg_temp.invoices(public.get_invoices_list(p_customer_ids => ARRAY[:'lakeview'::uuid, :'hilltop'::uuid])) = ARRAY['2025-7', '2026-12', '2026-120'], 'invoices: several customers');
SELECT pg_temp.search_assert(pg_temp.invoices(public.get_invoices_list(p_customer_ids => ARRAY[]::uuid[])) = ARRAY['2025-7', '2026-12', '2026-120'], 'invoices: an empty customer list is no filter');
SELECT pg_temp.search_assert(pg_temp.invoices(public.get_invoices_list(p_customer_ids => ARRAY[:'lakeview'::uuid], p_search => 'srb9', p_financial_year => 2026)) = ARRAY['2026-12'], 'invoices: new and old filters together');
SELECT pg_temp.search_assert((public.get_invoices_list(p_search => 'hilltop')#>>'{pagination,total_count}')::integer >= 1
  AND (public.get_invoices_list(p_search => 'lakeview hilltop')#>>'{pagination,total_count}')::integer = 0, 'invoices: the count follows the search');

-- Orders.
SELECT pg_temp.search_assert(pg_temp.orders(NULL) = ARRAY['Search Hilltop Mart', 'Search Lakeview Spices'], 'orders: both carts: ' || pg_temp.orders(NULL)::text);
SELECT pg_temp.search_assert(pg_temp.orders('LAKEVIEW') = ARRAY['Search Lakeview Spices'], 'orders: customer, any case');
SELECT pg_temp.search_assert(pg_temp.orders('rajkot') = ARRAY['Search Hilltop Mart'], 'orders: city');
SELECT pg_temp.search_assert(pg_temp.orders('garlic') = ARRAY['Search Hilltop Mart', 'Search Lakeview Spices'], 'orders: item of a line');
SELECT pg_temp.search_assert(pg_temp.orders('pkg-red') = ARRAY['Search Lakeview Spices'], 'orders: package of a line');
SELECT pg_temp.search_assert(pg_temp.orders('srb100') = ARRAY['Search Hilltop Mart'], 'orders: receipt number of a line');
SELECT pg_temp.search_assert(pg_temp.orders('rajkot garlic') = ARRAY['Search Hilltop Mart'], 'orders: two words, customer and line');
SELECT pg_temp.search_assert(pg_temp.orders('lakeview rajkot') = '{}', 'orders: every word must match');
SELECT pg_temp.search_assert(pg_temp.orders('50%') = ARRAY['Search Hilltop Mart'], 'orders: percent is literal');
SELECT pg_temp.search_assert(pg_temp.orders('item_status') = '{}', 'orders: field names are not searched');
SELECT pg_temp.search_assert(pg_temp.orders('  ') = ARRAY['Search Hilltop Mart', 'Search Lakeview Spices'], 'orders: blank search is no search');
SELECT pg_temp.search_assert((public.get_orders_list(p_search => 'rajkot')#>>'{data,pagination,total_count}')::integer = 1, 'orders: the count follows the search');
RESET ROLE;

-- A customer account searches its own records only.
SELECT set_config('request.jwt.claims', :'customer_claims', true);
SET LOCAL ROLE authenticated;
-- The staff dispatch list is not for customer accounts, with or without a search.
SELECT pg_temp.search_assert(public.get_dispatch_list_with_items(p_filters => '{"search": "garlic"}')->>'success' = 'false'
  AND jsonb_array_length(public.get_dispatch_list_with_items(p_filters => '{"search": "garlic"}')#>'{data,dispatches}') = 0,
  'customer account is refused the staff dispatch list');
SELECT pg_temp.search_assert(pg_temp.orders(NULL) = ARRAY['Search Lakeview Spices'], 'customer sees own cart');
SELECT pg_temp.search_assert(pg_temp.orders('garlic') = ARRAY['Search Lakeview Spices'], 'customer order search by item');
SELECT pg_temp.search_assert(pg_temp.orders('hilltop') = '{}' AND pg_temp.orders('rajkot') = '{}', 'customer cannot find another customer''s cart');
DO $$ DECLARE listed text[]; BEGIN
  BEGIN
    listed := pg_temp.invoices(public.get_invoices_list(p_search => 'srb', p_customer_ids => (SELECT array_agg(id) FROM public.customers)));
    PERFORM pg_temp.search_assert(NOT listed @> ARRAY['2026-120'], 'customer must not list another customer''s invoice');
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
ROLLBACK;
SELECT 'list search, filters and document-order ranges passed' AS result;

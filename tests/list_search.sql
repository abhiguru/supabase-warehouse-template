-- Quick search and document-order number ranges on the receipt lists (migration 35).
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
ROLLBACK;
SELECT 'receipt list search and document-order ranges passed' AS result;

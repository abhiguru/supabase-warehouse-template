-- The GRN activity of one customer lists each receipt once, whatever its number of invoices (migration 63).
--
-- get_customer_grn_activity joined every non-deleted invoice straight to the receipt, so a receipt with
-- two invoices (old data: before migration 41 a second save for a receipt succeeded under a new invoice
-- number, and migration 41 changes no earlier row) came out twice, and total_grns, total_items,
-- total_quantity, total_weight_kg and total_invoiced_grns of the summary counted it twice. Since migration
-- 63 invoice_status is one row per receipt: the LATEST non-deleted invoice (invoice date, then financial
-- year, then number, then id) and the new key invoice_count, the number of non-deleted invoices.
--
-- The invoices are inserted as the superuser, the way old data holds them (the save code of today cannot
-- make a second invoice for a receipt), as tests/report_invoice_paid.sql does for payments. The receipts
-- are made by public.save_grn. Period: 10 to 12 Mar 2026; a receipt is stored at 12:00 UTC of its day.
--
--   receipt  customer  day     bags x kg per bag   kg    invoices (inv_date; the number is fin year-no)
--   GIR1     Quince    10 Mar  1 x 10              10    2026-7102 (10 Mar) and 2026-7101 (11 Mar)  -> latest by DATE is 7101
--                                                         and 2026-7103 (12 Mar), DELETED            -> not counted, not the latest
--   GIR2     Quince    11 Mar  3 x 10              30    2026-7104 (11 Mar)
--   GIR3     Quince    12 Mar  3 x 10              30    2026-7105 (12 Mar), DELETED                -> not invoiced
--   GIR4     Hazel     10 Mar  1 x 10              10    2025-9001, 2026-7201 and 2026-7202, all on 10 Mar at the same moment
--                                                         -> latest: the financial year before the number, so 2026-7202
--
-- Quince, 10..12 Mar: 3 receipts / 3 lines / 7 bags / 70 kg, 2 of them invoiced; GIR3, GIR2, GIR1 (newest day
-- first), invoice_count 0, 1, 2. Before migration 63 the same call gave 4 / 4 / 8 / 80 and 3 invoiced, and GIR1
-- twice (the reviewer's case: 3 receipts / 7 bags / 70 kg became 4 / 8 / 80). Hazel: 1 receipt, invoice_count 3.
-- All customers (the branch with no invoice join), 10..12 Mar: 4 receipts / 8 bags / 80 kg.
--
-- Each answer is read as the role under test and compared AFTER the role is dropped.
-- Runs ONLY in migrations.sh's fresh, network-disabled database. All fixture rows roll back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.gi_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'report grn invoices: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.gi_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.gi_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- One field of every receipt of a one-customer answer, in the returned order.
CREATE FUNCTION pg_temp.gi_column(answer jsonb, value_key text) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(x->>value_key ORDER BY ord), '{}')
  FROM jsonb_array_elements(answer#>'{data,grns}') WITH ORDINALITY AS t(x, ord) $$;
-- One field of every receipt's invoice_status, in the returned order.
CREATE FUNCTION pg_temp.gi_status(answer jsonb, value_key text) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(x#>>ARRAY['invoice_status', value_key] ORDER BY ord), '{}')
  FROM jsonb_array_elements(answer#>'{data,grns}') WITH ORDINALITY AS t(x, ord) $$;
-- The receipt of a one-customer answer with that number, as a whole object, NULL when absent.
CREATE FUNCTION pg_temp.gi_receipt(answer jsonb, p_no text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT x FROM jsonb_array_elements(answer#>'{data,grns}') AS t(x) WHERE x->>'gr_no' = p_no $$;
-- The customer row of a by_customer array, by name.
CREATE FUNCTION pg_temp.gi_customer(rows jsonb, p_name text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT x FROM jsonb_array_elements(rows) AS t(x) WHERE x->>'customer_name' = p_name $$;
-- The keys of an object, sorted bytewise, as one text.
CREATE FUNCTION pg_temp.gi_keys(o jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(k, ',' ORDER BY k COLLATE "C") FROM jsonb_object_keys(o) AS t(k) $$;
-- 'refused: <message>' when the call is refused: either the guard raises 42501 or, as these report
-- functions do, the refusal comes back as data ({success: false, error: ...}); 'answered: ...' when it
-- returns a report. Any other error stops the test.
CREATE FUNCTION pg_temp.gi_refusal(statement text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  EXECUTE statement INTO answer;
  IF answer->>'success' = 'false' THEN RETURN 'refused: ' || COALESCE(answer->>'error', ''); END IF;
  RETURN 'answered: ' || left(answer::text, 120);
EXCEPTION WHEN insufficient_privilege THEN RETURN 'refused: ' || SQLERRM;
END $$;
-- How many times a text occurs in the definition of a function (by its signature).
CREATE FUNCTION pg_temp.gi_count(signature text, needle text) RETURNS integer LANGUAGE sql AS $$
  SELECT (length(pg_get_functiondef(signature::regprocedure)) - length(replace(pg_get_functiondef(signature::regprocedure), needle, ''))) / length(needle) $$;

-- ---------------------------------------------------------------------------
-- The functions: single, guarded first, and otherwise as before
-- ---------------------------------------------------------------------------
SELECT pg_temp.gi_assert(count(*) = 1, 'exactly one function named ' || n || ', in any schema')
FROM unnest(ARRAY['get_customer_grn_activity', 'get_all_grn_activity']) AS names(n) JOIN pg_proc p ON p.proname = n GROUP BY n;
SELECT pg_temp.gi_assert(p.prosecdef AND pg_get_functiondef(p.oid) ~ ('BEGIN\s+PERFORM warehouse_security\.authorize_rpc\(''' || p.proname || ''','),
  'SECURITY DEFINER, and the guard comes first in ' || p.proname)
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('get_customer_grn_activity', 'get_all_grn_activity');
-- The search_path (and jit setting) and the grants are what they were: the sibling's fixed path, execute for
-- authenticated and not for anon.
SELECT pg_temp.gi_assert(p.proconfig IS NOT NULL AND p.proconfig::text LIKE '%search_path=%'
    AND p.proconfig @> (SELECT s.proconfig FROM pg_proc s WHERE s.oid = 'public.get_customer_stock_summary(uuid)'::regprocedure)
    AND (p.proname = 'get_all_grn_activity' OR p.proconfig @> ARRAY['jit=off'])
    AND has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
    AND p.proacl IS NOT DISTINCT FROM (SELECT s.proacl FROM pg_proc s WHERE s.oid = 'public.get_customer_stock_summary(uuid)'::regprocedure),
  'search_path, jit and grants of ' || p.proname || ': ' || COALESCE(p.proconfig::text, 'none') || ' ' || COALESCE(p.proacl::text, 'none'))
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('get_customer_grn_activity', 'get_all_grn_activity');
-- The text: invoice_status is one row per receipt (DISTINCT ON, the order of the four keys and the id, the window count), a
-- receipt without an invoice has count 0, the join, the receipt count, the invoiced count and the whole status are as the fix
-- relies on them, and the earlier fixes are kept (the weight of migration 59, the India day cut of migration 56).
SELECT pg_temp.gi_assert(pg_temp.gi_count('public.get_customer_grn_activity(uuid,date,date)', 'SELECT DISTINCT ON (i.gr_id)') = 1
    AND pg_temp.gi_count('public.get_customer_grn_activity(uuid,date,date)', 'DISTINCT ON') = 1
    AND pg_temp.gi_count('public.get_customer_grn_activity(uuid,date,date)', 'ORDER BY i.gr_id, i.inv_date DESC, i.inv_fin_year DESC, i.inv_no DESC, i.id DESC') = 1
    AND pg_temp.gi_count('public.get_customer_grn_activity(uuid,date,date)', '''invoice_count'', COUNT(*) OVER (PARTITION BY i.gr_id)') = 1
    AND pg_temp.gi_count('public.get_customer_grn_activity(uuid,date,date)', '''invoice_number'', null, ''invoice_count'', 0)) as invoice_status,') = 1
    AND pg_temp.gi_count('public.get_customer_grn_activity(uuid,date,date)', '''invoice_count''') = 2
    AND pg_temp.gi_count('public.get_customer_grn_activity(uuid,date,date)', 'FROM invoice i') = 1
    AND pg_temp.gi_count('public.get_customer_grn_activity(uuid,date,date)', 'WHERE i.deleted_at IS NULL') = 1
    AND pg_temp.gi_count('public.get_customer_grn_activity(uuid,date,date)', 'LEFT JOIN invoice_status inv ON gd.grn_id = inv.gr_id') = 1
    AND pg_temp.gi_count('public.get_customer_grn_activity(uuid,date,date)', '''total_grns'', COUNT(*),') = 1
    AND pg_temp.gi_count('public.get_customer_grn_activity(uuid,date,date)', '''total_invoiced_grns'', COUNT(*) FILTER (WHERE (invoice_status->>''is_invoiced'')::boolean = true),') = 1
    AND pg_temp.gi_count('public.get_customer_grn_activity(uuid,date,date)', '''invoice_status'', invoice_status,') = 1
    AND pg_temp.gi_count('public.get_customer_grn_activity(uuid,date,date)', 'COALESCE(SUM(grt.weight::numeric * grt.qty), 0) as total_weight') = 2
    AND pg_temp.gi_count('public.get_customer_grn_activity(uuid,date,date)', 'gr.date >= warehouse_security.business_day_start(v_from_date) AND gr.date < warehouse_security.business_day_start(v_to_date + 1)') = 2
    AND pg_temp.gi_count('public.get_customer_grn_activity(uuid,date,date)', 'ORDER BY grn_date DESC') = 1,
  'get_customer_grn_activity: invoice_status is one row per receipt, the join, the counts and the earlier fixes are as the fix relies on them');
-- get_all_grn_activity has no invoice join (and the all-customers branch of the other function has none either): nothing to fix there.
SELECT pg_temp.gi_assert(pg_get_functiondef(p.oid) NOT LIKE '%invoice%', 'get_all_grn_activity does not read invoices')
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'get_all_grn_activity';

-- ---------------------------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------------------------
SELECT pg_temp.gi_assert((SELECT count(*) FROM public.goodsreceived) = 0 AND (SELECT count(*) FROM public.invoice) = 0,
  'the database holds no receipt or invoice before the fixture');
INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888889701', 'Grn Invoices Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888889702', 'Grn Invoices Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888889703', 'Grn Invoices Customer', 'customer', true, 'approved');
SELECT pg_temp.gi_login('9888889701') AS admin_claims \gset
SELECT pg_temp.gi_login('9888889702') AS staff_claims \gset
SELECT pg_temp.gi_login('9888889703') AS customer_claims \gset
INSERT INTO public.customers(name, mobile) VALUES ('Grn Invoices Quince Cold', '9888889711') RETURNING id AS quince \gset
INSERT INTO public.customers(name, mobile) VALUES ('Grn Invoices Hazel Stores', '9888889712') RETURNING id AS hazel \gset
INSERT INTO public.items(name, packaging) VALUES ('Grn Invoices Cumin', 'Bag') RETURNING id AS cumin \gset
-- The customer login is assigned to Quince only.
INSERT INTO public.users_customers_new(user_profile_id, customer_id, active)
 SELECT id, :'quince'::uuid, true FROM public.user_profiles WHERE mobile = '919888889703';

SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.gi_assert(public.save_grn(p_gr_no => r.gr_no, p_date => (r.day || 'T12:00:00Z')::timestamptz,
  p_customer_id => r.customer, p_customer_name => r.customer_name, p_idempotency_key => 'report-grn-invoices-' || r.gr_no,
  p_items => jsonb_build_array(jsonb_build_object('item_id', :'cumin', 'item_name', 'Grn Invoices Cumin', 'packaging', 'Bag',
    'qty', r.bags, 'weight', 10)))->>'success' = 'true', 'fixture receipt ' || r.gr_no)
FROM (VALUES
  ('GIR1', '2026-03-10', :'quince'::uuid, 'Grn Invoices Quince Cold', 1),
  ('GIR2', '2026-03-11', :'quince'::uuid, 'Grn Invoices Quince Cold', 3),
  ('GIR3', '2026-03-12', :'quince'::uuid, 'Grn Invoices Quince Cold', 3),
  ('GIR4', '2026-03-10', :'hazel'::uuid, 'Grn Invoices Hazel Stores', 1)
) AS r(gr_no, day, customer, customer_name, bags);
RESET ROLE;

-- The invoices, as old data holds them: written as the superuser (the app roles cannot write a business table
-- and the save code refuses a second invoice for a receipt). GIR1's two live invoices are inserted with the HIGHER
-- number first and the LATER date second, so "the latest" cannot be taken for the last inserted or the highest
-- number; the third, newest one is deleted. GIR4's three share one moment: only the financial year and the number
-- tell them apart, and 2025-9001 has the highest number.
INSERT INTO public.invoice(inv_fin_year, inv_no, gr_id, gr_no, customer_id, customer_name, inv_date, total, deleted_at)
SELECT v.fin_year, v.inv_no, g.id, g.gr_no, g.customer_id, g.customer_name, v.inv_date::timestamptz, v.total,
       CASE WHEN v.deleted THEN now() END
FROM (VALUES
  (2026, 7102, 'GIR1', '2026-03-10T12:00:00Z', 100, false),
  (2026, 7101, 'GIR1', '2026-03-11T12:00:00Z', 110, false),
  (2026, 7103, 'GIR1', '2026-03-12T12:00:00Z', 120, true),
  (2026, 7104, 'GIR2', '2026-03-11T12:00:00Z', 330, false),
  (2026, 7105, 'GIR3', '2026-03-12T12:00:00Z', 330, true),
  (2025, 9001, 'GIR4', '2026-03-10T12:00:00Z',  10, false),
  (2026, 7201, 'GIR4', '2026-03-10T12:00:00Z',  10, false),
  (2026, 7202, 'GIR4', '2026-03-10T12:00:00Z',  10, false)
) AS v(fin_year, inv_no, gr_no, inv_date, total, deleted)
JOIN public.goodsreceived g ON g.gr_no = v.gr_no;

SELECT id AS id_7101 FROM public.invoice WHERE inv_fin_year = 2026 AND inv_no = 7101 \gset
SELECT id AS id_7102 FROM public.invoice WHERE inv_fin_year = 2026 AND inv_no = 7102 \gset
SELECT id AS id_7104 FROM public.invoice WHERE inv_fin_year = 2026 AND inv_no = 7104 \gset
SELECT id AS id_7202 FROM public.invoice WHERE inv_fin_year = 2026 AND inv_no = 7202 \gset
-- What the tables say, worked out apart from the functions.
SELECT pg_temp.gi_assert((SELECT string_agg(g.gr_no || '=' || t.qty || 'x' || t.weight, ' ' ORDER BY g.gr_no)
      FROM public.goodsreceived g JOIN public.goodsreceived_trl t ON t.gr_id = g.id)
    = 'GIR1=1x10 GIR2=3x10 GIR3=3x10 GIR4=1x10'
  AND (SELECT string_agg(g.gr_no || ':' || (SELECT count(*) FROM public.invoice i WHERE i.gr_id = g.id AND i.deleted_at IS NULL)
        || '/' || (SELECT count(*) FROM public.invoice i WHERE i.gr_id = g.id), ' ' ORDER BY g.gr_no) FROM public.goodsreceived g)
    = 'GIR1:2/3 GIR2:1/1 GIR3:0/1 GIR4:3/3',
  'fixture: four receipts (1, 3, 3 and 1 bags of 10 kg) with 2 live of 3 invoices, 1, 0 live of 1, and 3');
-- The receipts of Quince: 3 receipts, 7 bags, 70 kg. A join of receipts to ALL their invoices (what the old function did)
-- gives 4 rows, 8 bags, 80 kg, and 3 invoiced rows.
SELECT count(*) AS table_rows, sum(t.qty) AS table_bags, sum(t.qty::numeric * t.weight) AS table_kg,
       count(*) FILTER (WHERE i.id IS NOT NULL) AS table_invoiced_rows
FROM public.goodsreceived g JOIN public.goodsreceived_trl t ON t.gr_id = g.id
LEFT JOIN public.invoice i ON i.gr_id = g.id AND i.deleted_at IS NULL
WHERE g.customer_id = :'quince'::uuid \gset
SELECT pg_temp.gi_assert(:'table_rows' = '4' AND :'table_bags' = '8' AND :'table_kg' = '80' AND :'table_invoiced_rows' = '3'
  AND (SELECT count(DISTINCT g.id) FROM public.goodsreceived g WHERE g.customer_id = :'quince'::uuid) = 3
  AND (SELECT sum(t.qty) FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id = t.gr_id WHERE g.customer_id = :'quince'::uuid) = 7,
  'the tables hold 3 receipts and 7 bags for Quince; a receipt-to-invoices join would show 4 rows / 8 bags / 80 kg / 3 invoiced: '
    || :'table_rows' || ' / ' || :'table_bags' || ' / ' || :'table_kg' || ' / ' || :'table_invoiced_rows');

-- ---------------------------------------------------------------------------
-- The answers, each read as the role under test
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.get_customer_grn_activity(:'quince'::uuid, '2026-03-10', '2026-03-12')::text AS admin_quince \gset
SELECT public.get_customer_grn_activity(NULL, '2026-03-10', '2026-03-12')::text AS admin_everyone \gset
RESET ROLE;

SELECT set_config('request.jwt.claims', :'staff_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.gi_assert(warehouse_security.active_role() = 'staff', 'actual staff role');
SELECT public.get_customer_grn_activity(:'quince'::uuid, '2026-03-10', '2026-03-12')::text AS staff_quince \gset
SELECT public.get_customer_grn_activity(:'quince'::uuid, '2026-03-11', '2026-03-12')::text AS staff_quince_11_12 \gset
SELECT public.get_customer_grn_activity(:'quince'::uuid, '2026-03-10', '2026-03-10')::text AS staff_quince_10_10 \gset
SELECT public.get_customer_grn_activity(:'quince'::uuid, '2026-09-01', '2026-09-30')::text AS staff_quince_none \gset
SELECT public.get_customer_grn_activity(:'hazel'::uuid, '2026-03-10', '2026-03-12')::text AS staff_hazel \gset
SELECT public.get_customer_grn_activity(NULL, '2026-03-10', '2026-03-12')::text AS staff_everyone \gset
SELECT public.get_all_grn_activity('2026-03-10', '2026-03-12')::text AS staff_all \gset
RESET ROLE;

SELECT set_config('request.jwt.claims', :'customer_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.gi_assert(warehouse_security.active_role() = 'customer', 'actual customer role');
SELECT public.get_customer_grn_activity(:'quince'::uuid, '2026-03-10', '2026-03-12')::text AS customer_quince \gset
SELECT pg_temp.gi_refusal(format('SELECT public.get_customer_grn_activity(%L::uuid, %L::date, %L::date)', :'hazel', '2026-03-10', '2026-03-12')) AS customer_hazel \gset
SELECT pg_temp.gi_refusal(format('SELECT public.get_customer_grn_activity(%L::uuid, %L::date, %L::date)', :'quince', '2026-03-10', '2026-03-12')) AS customer_quince_check \gset
SELECT pg_temp.gi_refusal(format('SELECT public.get_customer_grn_activity(NULL::uuid, %L::date, %L::date)', '2026-03-10', '2026-03-12')) AS customer_everyone \gset
SELECT pg_temp.gi_refusal(format('SELECT public.get_all_grn_activity(%L::date, %L::date)', '2026-03-10', '2026-03-12')) AS customer_all \gset
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Staff, one customer: each receipt once, the figures of the receipts, the latest invoice and the count
-- ---------------------------------------------------------------------------
-- Exactly the three receipts, once each, newest day first.
SELECT pg_temp.gi_assert(pg_temp.gi_column(:'staff_quince'::jsonb, 'gr_no') = ARRAY['GIR3', 'GIR2', 'GIR1']
  AND jsonb_array_length((:'staff_quince'::jsonb)#>'{data,grns}') = 3
  AND (SELECT count(DISTINCT x->>'grn_id') FROM jsonb_array_elements((:'staff_quince'::jsonb)#>'{data,grns}') AS t(x)) = 3,
  'staff: Quince has three receipts, GIR3, GIR2 and GIR1, each listed once: ' || :'staff_quince');
-- The quantities and the weight are the receipts' own, not changed by the second invoice of GIR1.
SELECT pg_temp.gi_assert(pg_temp.gi_column(:'staff_quince'::jsonb, 'total_qty') = ARRAY['3', '3', '1']
  AND pg_temp.gi_column(:'staff_quince'::jsonb, 'total_weight') = ARRAY['30', '30', '10']
  AND pg_temp.gi_column(:'staff_quince'::jsonb, 'total_items') = ARRAY['1', '1', '1'],
  'staff: the receipts hold 3, 3 and 1 bags weighing 30, 30 and 10 kg, one line each: ' || :'staff_quince');
-- The summary counts each receipt once: 3 receipts, 3 lines, 7 bags, 70 kg, 2 invoiced receipts (it was 4, 4, 8, 80 and 3).
SELECT pg_temp.gi_assert((:'staff_quince'::jsonb)#>>'{data,summary,total_grns}' = '3'
  AND (:'staff_quince'::jsonb)#>>'{data,summary,total_items}' = '3'
  AND (:'staff_quince'::jsonb)#>>'{data,summary,total_quantity}' = '7'
  AND (:'staff_quince'::jsonb)#>>'{data,summary,total_weight_kg}' = '70'
  AND (:'staff_quince'::jsonb)#>>'{data,summary,total_invoiced_grns}' = '2'
  AND (:'staff_quince'::jsonb)#>>'{data,summary,total_images}' = '0',
  'staff: the summary says 3 receipts, 3 lines, 7 bags, 70 kg, 2 invoiced (not 4, 4, 8, 80, 3): ' || :'staff_quince');
-- The summary is the sum of what is listed (the receipts), and none of the inflated figures.
SELECT pg_temp.gi_assert((:'staff_quince'::jsonb)#>>'{data,summary,total_quantity}' = (SELECT sum((x->>'total_qty')::numeric)::text FROM jsonb_array_elements((:'staff_quince'::jsonb)#>'{data,grns}') AS t(x))
  AND (:'staff_quince'::jsonb)#>>'{data,summary,total_weight_kg}' = (SELECT sum((x->>'total_weight')::numeric)::text FROM jsonb_array_elements((:'staff_quince'::jsonb)#>'{data,grns}') AS t(x))
  AND (:'staff_quince'::jsonb)#>>'{data,summary,total_invoiced_grns}' = (SELECT count(*)::text FROM jsonb_array_elements((:'staff_quince'::jsonb)#>'{data,grns}') AS t(x) WHERE (x#>>'{invoice_status,is_invoiced}')::boolean)
  AND (:'staff_quince'::jsonb)#>>'{data,summary,total_quantity}' <> '8' AND (:'staff_quince'::jsonb)#>>'{data,summary,total_weight_kg}' <> '80'
  AND (:'staff_quince'::jsonb)#>>'{data,summary,total_grns}' <> '4' AND (:'staff_quince'::jsonb)#>>'{data,summary,total_invoiced_grns}' <> '3',
  'staff: the summary adds up the listed receipts and is none of the inflated figures: ' || :'staff_quince');
-- total_invoiced_grns counts RECEIPTS: GIR1 has two live invoices and counts once; GIR3 has only a deleted one and does not count.
-- The latest invoice of GIR1 is the one with the latest DATE (2026-7101, 11 Mar), not the higher number (7102), the first
-- inserted, or the deleted one (7103, 12 Mar); GIR2 has its only one; GIR3 has none.
SELECT pg_temp.gi_assert(pg_temp.gi_status(:'staff_quince'::jsonb, 'invoice_number') = ARRAY[NULL, '2026-7104', '2026-7101']::text[]
  AND pg_temp.gi_status(:'staff_quince'::jsonb, 'invoice_id') = ARRAY[NULL, :'id_7104', :'id_7101']::text[]
  AND pg_temp.gi_status(:'staff_quince'::jsonb, 'is_invoiced') = ARRAY['false', 'true', 'true']
  AND pg_temp.gi_status(:'staff_quince'::jsonb, 'invoice_count') = ARRAY['0', '1', '2']
  AND :'id_7101' <> :'id_7102',
  'staff: invoice_status of GIR3, GIR2, GIR1 is (none, 0), (2026-7104, 1) and (2026-7101, 2): ' || :'staff_quince');
-- The types of invoice_status: a number for the count, a boolean, and the id and number as text or null.
SELECT pg_temp.gi_assert(count(*) = 3
    AND bool_and(jsonb_typeof(x#>'{invoice_status,invoice_count}') = 'number')
    AND bool_and(jsonb_typeof(x#>'{invoice_status,is_invoiced}') = 'boolean')
    AND bool_and(jsonb_typeof(x#>'{invoice_status,invoice_id}') = CASE WHEN (x#>>'{invoice_status,is_invoiced}')::boolean THEN 'string' ELSE 'null' END)
    AND bool_and(jsonb_typeof(x#>'{invoice_status,invoice_number}') = CASE WHEN (x#>>'{invoice_status,is_invoiced}')::boolean THEN 'string' ELSE 'null' END),
  'staff: invoice_count is a number, is_invoiced a boolean, invoice_id and invoice_number text (null without an invoice): ' || :'staff_quince')
FROM jsonb_array_elements((:'staff_quince'::jsonb)#>'{data,grns}') AS t(x);
-- The key sets: invoice_count is the only new key, in invoice_status; the answer, the summary, the metadata, a receipt and a line are the earlier ones.
SELECT pg_temp.gi_assert(pg_temp.gi_keys(:'staff_quince'::jsonb) = 'data,metadata,success'
  AND pg_temp.gi_keys((:'staff_quince'::jsonb)->'data') = 'grns,summary'
  AND pg_temp.gi_keys((:'staff_quince'::jsonb)#>'{data,summary}') = 'total_grns,total_images,total_invoiced_grns,total_items,total_quantity,total_weight_kg'
  AND pg_temp.gi_keys((:'staff_quince'::jsonb)->'metadata') = 'customer_id,from_date,retrieved_at,to_date',
  'staff: the keys of the answer, of data, of the summary and of the metadata are the earlier ones: ' || :'staff_quince');
SELECT pg_temp.gi_assert(count(*) = 3
    AND bool_and(pg_temp.gi_keys(x) = 'dispatch_summary,gr_no,grn_date,grn_id,image_count,invoice_status,items,note,registration,sender_name,supervisor_name,total_items,total_qty,total_weight')
    AND bool_and(pg_temp.gi_keys(x->'invoice_status') = 'invoice_count,invoice_id,invoice_number,is_invoiced')
    AND bool_and(pg_temp.gi_keys(x->'dispatch_summary') = 'current_stock,dispatch_count,is_fully_dispatched,last_dispatch_date,total_dispatched')
    AND bool_and((SELECT bool_and(pg_temp.gi_keys(i) = 'current_stock,dispatched_qty,item_name,package_mark,packaging,quantity,rack,weight') FROM jsonb_array_elements(x->'items') AS l(i))),
  'staff: the keys of each receipt, of its invoice_status (the one new key, invoice_count), of its dispatch summary and of its lines')
FROM jsonb_array_elements((:'staff_quince'::jsonb)#>'{data,grns}') AS t(x);
-- The doubled receipt is in the answer once, with its own figures.
SELECT pg_temp.gi_assert((SELECT count(*) FROM jsonb_array_elements((:'staff_quince'::jsonb)#>'{data,grns}') AS t(x) WHERE x->>'gr_no' = 'GIR1') = 1
  AND (pg_temp.gi_receipt(:'staff_quince'::jsonb, 'GIR1')->>'total_qty') = '1' AND (pg_temp.gi_receipt(:'staff_quince'::jsonb, 'GIR1')->>'total_weight') = '10'
  AND (pg_temp.gi_receipt(:'staff_quince'::jsonb, 'GIR1')->'items'->0->>'item_name') = 'Grn Invoices Cumin'
  AND jsonb_array_length(pg_temp.gi_receipt(:'staff_quince'::jsonb, 'GIR1')->'items') = 1,
  'staff: GIR1 is listed once, with its one line of 1 bag, 10 kg: ' || :'staff_quince');
-- The deleted invoice and another customer's are not in the answer: the numbers 7102 (older), 7103 and 7105 (deleted) and the Hazel ones.
SELECT pg_temp.gi_assert(position('7102' in :'staff_quince') = 0 AND position('7103' in :'staff_quince') = 0 AND position('7105' in :'staff_quince') = 0
  AND position('7201' in :'staff_quince') = 0 AND position('7202' in :'staff_quince') = 0 AND position('GIR4' in :'staff_quince') = 0,
  'staff: the answer names only the latest invoice of each receipt, and nothing of another customer: ' || :'staff_quince');
-- An administrator is answered the same, for one customer and for all.
SELECT pg_temp.gi_assert(:'admin_quince'::jsonb = :'staff_quince'::jsonb, 'administrator and staff are answered alike, one customer: ' || :'admin_quince');
SELECT pg_temp.gi_assert(:'admin_everyone'::jsonb = :'staff_everyone'::jsonb, 'administrator and staff are answered alike, all customers: ' || :'admin_everyone');

-- ---------------------------------------------------------------------------
-- Periods and the other customer
-- ---------------------------------------------------------------------------
-- 11..12 Mar leaves GIR1 out (and with it its two invoices); 10..10 holds GIR1 only: still once, still count 2; September holds nothing.
SELECT pg_temp.gi_assert(pg_temp.gi_column(:'staff_quince_11_12'::jsonb, 'gr_no') = ARRAY['GIR3', 'GIR2']
  AND pg_temp.gi_status(:'staff_quince_11_12'::jsonb, 'invoice_count') = ARRAY['0', '1']
  AND (:'staff_quince_11_12'::jsonb)#>>'{data,summary,total_grns}' = '2' AND (:'staff_quince_11_12'::jsonb)#>>'{data,summary,total_quantity}' = '6'
  AND (:'staff_quince_11_12'::jsonb)#>>'{data,summary,total_weight_kg}' = '60' AND (:'staff_quince_11_12'::jsonb)#>>'{data,summary,total_invoiced_grns}' = '1',
  'staff: 11..12 Mar holds GIR3 and GIR2: 2 receipts, 6 bags, 60 kg, 1 invoiced: ' || :'staff_quince_11_12');
SELECT pg_temp.gi_assert(pg_temp.gi_column(:'staff_quince_10_10'::jsonb, 'gr_no') = ARRAY['GIR1']
  AND pg_temp.gi_status(:'staff_quince_10_10'::jsonb, 'invoice_number') = ARRAY['2026-7101']
  AND pg_temp.gi_status(:'staff_quince_10_10'::jsonb, 'invoice_count') = ARRAY['2']
  AND (:'staff_quince_10_10'::jsonb)#>>'{data,summary,total_grns}' = '1' AND (:'staff_quince_10_10'::jsonb)#>>'{data,summary,total_quantity}' = '1'
  AND (:'staff_quince_10_10'::jsonb)#>>'{data,summary,total_weight_kg}' = '10' AND (:'staff_quince_10_10'::jsonb)#>>'{data,summary,total_invoiced_grns}' = '1',
  'staff: 10..10 Mar holds GIR1 once, with its latest invoice and count 2: 1 receipt, 1 bag, 10 kg, 1 invoiced: ' || :'staff_quince_10_10');
SELECT pg_temp.gi_assert(jsonb_array_length((:'staff_quince_none'::jsonb)#>'{data,grns}') = 0
  AND (:'staff_quince_none'::jsonb)#>>'{data,summary,total_grns}' = '0' AND (:'staff_quince_none'::jsonb)#>>'{data,summary,total_invoiced_grns}' = '0'
  AND (:'staff_quince_none'::jsonb)#>>'{data,summary,total_weight_kg}' = '0',
  'staff: a period without receipts counts 0 everywhere: ' || :'staff_quince_none');
-- Hazel's receipt has three live invoices on one moment: the latest by financial year, then number (2026-7202, not 2025-9001, the
-- highest number), counted 3, listed once.
SELECT pg_temp.gi_assert(pg_temp.gi_column(:'staff_hazel'::jsonb, 'gr_no') = ARRAY['GIR4']
  AND pg_temp.gi_status(:'staff_hazel'::jsonb, 'invoice_number') = ARRAY['2026-7202']
  AND pg_temp.gi_status(:'staff_hazel'::jsonb, 'invoice_id') = ARRAY[:'id_7202']::text[]
  AND pg_temp.gi_status(:'staff_hazel'::jsonb, 'invoice_count') = ARRAY['3']
  AND (:'staff_hazel'::jsonb)#>>'{data,summary,total_grns}' = '1' AND (:'staff_hazel'::jsonb)#>>'{data,summary,total_quantity}' = '1'
  AND (:'staff_hazel'::jsonb)#>>'{data,summary,total_weight_kg}' = '10' AND (:'staff_hazel'::jsonb)#>>'{data,summary,total_invoiced_grns}' = '1',
  'staff: Hazel''s receipt is listed once with 2026-7202 as the latest of three invoices: ' || :'staff_hazel');

-- ---------------------------------------------------------------------------
-- The all-customers branch and get_all_grn_activity: no invoice join, unchanged, and in agreement
-- ---------------------------------------------------------------------------
SELECT pg_temp.gi_assert((:'staff_everyone'::jsonb)#>>'{data,summary,total_grns}' = '4' AND (:'staff_everyone'::jsonb)#>>'{data,summary,total_customers}' = '2'
  AND (:'staff_everyone'::jsonb)#>>'{data,summary,total_quantity}' = '8' AND (:'staff_everyone'::jsonb)#>>'{data,summary,total_weight_kg}' = '80'
  AND pg_temp.gi_customer((:'staff_everyone'::jsonb)#>'{data,by_customer}', 'Grn Invoices Quince Cold') @> '{"grn_count": 3, "total_quantity": 7, "total_weight": 70}'
  AND pg_temp.gi_customer((:'staff_everyone'::jsonb)#>'{data,by_customer}', 'Grn Invoices Hazel Stores') @> '{"grn_count": 1, "total_quantity": 1, "total_weight": 10}'
  AND pg_temp.gi_keys((:'staff_everyone'::jsonb)#>'{data,summary}') = 'total_customers,total_grns,total_items,total_quantity,total_weight_kg',
  'staff, all customers: 4 receipts, 8 bags, 80 kg (3 and 7 bags for Quince, 1 for Hazel): ' || :'staff_everyone');
SELECT pg_temp.gi_assert((:'staff_all'::jsonb)#>>'{summary,total_grns}' = '4' AND (:'staff_all'::jsonb)#>>'{summary,total_customers}' = '2'
  AND (:'staff_all'::jsonb)#>>'{summary,total_quantity}' = '8' AND (:'staff_all'::jsonb)#>>'{summary,total_weight}' = '80'
  AND pg_temp.gi_customer((:'staff_all'::jsonb)->'by_customer', 'Grn Invoices Quince Cold') @> '{"grn_count": 3, "total_qty": 7, "total_weight": 70}'
  AND (:'staff_all'::jsonb)#>>'{summary,total_grns}' = (:'staff_everyone'::jsonb)#>>'{data,summary,total_grns}'
  AND (:'staff_all'::jsonb)#>>'{summary,total_weight}' = (:'staff_everyone'::jsonb)#>>'{data,summary,total_weight_kg}',
  'get_all_grn_activity: 4 receipts, 8 bags, 80 kg, the same as the one-customer function without a customer: ' || :'staff_all');
-- The one-customer answer for Quince agrees with the all-customers one: 3 receipts, 7 bags, 70 kg for Quince.
SELECT pg_temp.gi_assert((:'staff_quince'::jsonb)#>>'{data,summary,total_grns}' = (pg_temp.gi_customer((:'staff_all'::jsonb)->'by_customer', 'Grn Invoices Quince Cold')->>'grn_count')
  AND (:'staff_quince'::jsonb)#>>'{data,summary,total_quantity}' = (pg_temp.gi_customer((:'staff_all'::jsonb)->'by_customer', 'Grn Invoices Quince Cold')->>'total_qty')
  AND (:'staff_quince'::jsonb)#>>'{data,summary,total_weight_kg}' = (pg_temp.gi_customer((:'staff_all'::jsonb)->'by_customer', 'Grn Invoices Quince Cold')->>'total_weight'),
  'the one-customer summary agrees with the all-customers row of Quince (receipts, bags, kg): ' || :'staff_quince' || ' / ' || :'staff_all');

-- ---------------------------------------------------------------------------
-- A customer account: its own customer's receipts, nobody else's
-- ---------------------------------------------------------------------------
SELECT pg_temp.gi_assert(:'customer_quince'::jsonb = :'staff_quince'::jsonb
  AND pg_temp.gi_status(:'customer_quince'::jsonb, 'invoice_count') = ARRAY['0', '1', '2']
  AND (:'customer_quince'::jsonb)#>>'{data,summary,total_grns}' = '3',
  'customer account: its own customer''s receipts, once each, with their invoice counts: ' || :'customer_quince');
-- The refusal check can tell an answer from a refusal: the same call for its own customer is answered.
SELECT pg_temp.gi_assert(:'customer_quince_check' LIKE 'answered: %', 'the refusal check answers "answered" for an allowed call: ' || :'customer_quince_check');
-- Another customer's id, no customer at all and the all-customers function are refused by the guard.
SELECT pg_temp.gi_assert(:'customer_hazel' = 'refused: Failed to retrieve GRN activity: Customer access denied' AND position('2026-7202' in :'customer_hazel') = 0,
  'customer account: another customer''s GRN activity was not refused: ' || :'customer_hazel');
SELECT pg_temp.gi_assert(:'customer_everyone' LIKE 'refused: %' AND :'customer_all' LIKE 'refused: %',
  'customer account: all-customers GRN activity was not refused: ' || :'customer_everyone' || ' / ' || :'customer_all');

ROLLBACK;
SELECT 'report grn invoices: the GRN activity of one customer lists each receipt once whatever its number of invoices (the quantities, the weight and the summary count it once), shows the latest invoice and the new invoice_count (a deleted invoice is not counted), changes no other key, leaves the all-customers figures and get_all_grn_activity as they were, and a customer account still gets only its own customer' AS result;

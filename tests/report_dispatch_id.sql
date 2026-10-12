-- The customer dispatch activity report returns each dispatch's id (migration 57).
--
-- get_customer_dispatch_activity listed each dispatch with disp_no, disp_date, supervisor_name,
-- total_qty and items, but never the dispatch's id, so the app's report could not offer "Open
-- dispatch" (it opens /dispatch-details/<disp_id>, which calls get_dispatch_details with the
-- dispatch's id). Since migration 57 every element of dispatches[] also carries disp_id, the id
-- of the row in public.dispatch.
--
--   dispatch  customer  day         qty  state
--   DID1      Quince    10 Oct        5  listed
--   DID2      Quince    11 Oct       20  listed
--   DID3      Rowan     11 Oct        7  listed, but another customer's
--   DID4      Quince    11 Oct        1  deleted (deleted_at set), so never listed
-- One stock lot per customer (DIS1 Quince, DIS2 Rowan), 100 bags of 5 kg, received 14 Aug.
--
-- Each answer is read as the role under test and compared AFTER the role is dropped, against the
-- table itself: the pairs "disp_no=disp_id" of the answer must be the pairs of public.dispatch.
-- The dispatch RPC stores a dispatch at the start of its date in the session zone (UTC here,
-- asserted), which is the same India day, so the period 10..12 Oct holds DID1 and DID2.
-- Runs ONLY in migrations.sh's fresh, network-disabled database. All fixture rows roll back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.did_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'report dispatch id: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.did_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.did_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- "disp_no=disp_id" for each dispatch of an answer, in the returned order. A dispatch without
-- disp_id gives NULL here, which no comparison below accepts.
CREATE FUNCTION pg_temp.did_pairs(answer jsonb) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg((x->>'disp_no') || '=' || (x->>'disp_id') ORDER BY ord), '{}')
  FROM jsonb_array_elements(answer->'dispatches') WITH ORDINALITY AS t(x, ord) $$;
-- The same pairs from the table, newest day first, for a customer's dispatches that are not deleted.
CREATE FUNCTION pg_temp.did_table_pairs(customer uuid) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(disp_no || '=' || id ORDER BY disp_date DESC), '{}')
  FROM public.dispatch WHERE customer_id = customer AND deleted_at IS NULL AND disp_no LIKE 'DID%' $$;
-- One field of every dispatch of an answer, in the returned order.
CREATE FUNCTION pg_temp.did_column(answer jsonb, value_key text) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(x->>value_key ORDER BY ord), '{}')
  FROM jsonb_array_elements(answer->'dispatches') WITH ORDINALITY AS t(x, ord) $$;
-- The keys of an object, sorted bytewise, as one text.
CREATE FUNCTION pg_temp.did_keys(o jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(k, ',' ORDER BY k COLLATE "C") FROM jsonb_object_keys(o) AS t(k) $$;
-- 'Customer access denied' (the guard's message) when the statement is refused with 42501;
-- 'answered: ...' when it returns. Any other error stops the test.
CREATE FUNCTION pg_temp.did_refusal(statement text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  EXECUTE statement INTO answer;
  RETURN 'answered: ' || left(answer::text, 120);
EXCEPTION WHEN insufficient_privilege THEN RETURN SQLERRM;
END $$;

SELECT pg_temp.did_assert(current_setting('TimeZone') = 'UTC', 'the session time zone is UTC, so a dispatch stored at the start of its date is on that India day');

-- ---------------------------------------------------------------------------
-- The function: single, guarded, and otherwise as before
-- ---------------------------------------------------------------------------
SELECT pg_temp.did_assert(count(*) = 1, 'exactly one function named get_customer_dispatch_activity, in any schema')
FROM pg_proc p WHERE p.proname = 'get_customer_dispatch_activity';
SELECT pg_temp.did_assert(p.prosecdef AND pg_get_functiondef(p.oid) ~ 'BEGIN\s+PERFORM warehouse_security\.authorize_rpc\(''get_customer_dispatch_activity'',',
  'SECURITY DEFINER, and the guard comes first')
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'get_customer_dispatch_activity';
-- The search_path is the hardened one every public RPC carries (its sibling's), not the one the
-- function was created with.
SELECT pg_temp.did_assert(p.proconfig IS NOT NULL AND p.proconfig::text LIKE '%search_path=%'
    AND p.proconfig IS NOT DISTINCT FROM (SELECT s.proconfig FROM pg_proc s WHERE s.oid = 'public.get_customer_stock_summary(uuid)'::regprocedure),
  'search_path is a fixed one, as its sibling get_customer_stock_summary: ' || COALESCE(p.proconfig::text, 'none'))
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'get_customer_dispatch_activity';
SELECT pg_temp.did_assert(has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
    AND p.proacl IS NOT DISTINCT FROM (SELECT s.proacl FROM pg_proc s WHERE s.oid = 'public.get_customer_stock_summary(uuid)'::regprocedure),
  'grants: authenticated may execute, anon may not, as its sibling get_customer_stock_summary: ' || COALESCE(p.proacl::text, 'none'))
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'get_customer_dispatch_activity';
-- disp_id is written once, right before disp_no; the India day cut of migration 56 is kept.
SELECT pg_temp.did_assert((length(pg_get_functiondef(p.oid)) - length(replace(pg_get_functiondef(p.oid), '''disp_id'', d.id,', ''))) / length('''disp_id'', d.id,') = 1
    AND pg_get_functiondef(p.oid) ~ '''disp_id'', d\.id,\s+''disp_no'', d\.disp_no,',
  'disp_id is written once, right before disp_no')
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'get_customer_dispatch_activity';
SELECT pg_temp.did_assert(pg_get_functiondef(p.oid) LIKE '%d.disp_date >= warehouse_security.business_day_start(p_from_date)%'
    AND pg_get_functiondef(p.oid) LIKE '%''disp_date'', warehouse_security.business_date(d.disp_date),%',
  'the India day cut of migration 56 is kept')
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'get_customer_dispatch_activity';

-- ---------------------------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------------------------
INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888889101', 'Dispatch Id Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888889102', 'Dispatch Id Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888889103', 'Dispatch Id Customer', 'customer', true, 'approved');
SELECT id AS admin_profile FROM public.user_profiles WHERE mobile = '919888889101' \gset
SELECT pg_temp.did_login('9888889101') AS admin_claims \gset
SELECT pg_temp.did_login('9888889102') AS staff_claims \gset
SELECT pg_temp.did_login('9888889103') AS customer_claims \gset
INSERT INTO public.customers(name, mobile) VALUES ('Dispatch Id Quince Cold', '9888889111') RETURNING id AS quince \gset
INSERT INTO public.customers(name, mobile) VALUES ('Dispatch Id Rowan Agro', '9888889112') RETURNING id AS rowan \gset
INSERT INTO public.items(name, packaging) VALUES ('Dispatch Id Fennel', 'Bag') RETURNING id AS fennel \gset
-- The customer login is assigned to Quince only.
INSERT INTO public.users_customers_new(user_profile_id, customer_id, active)
 SELECT id, :'quince'::uuid, true FROM public.user_profiles WHERE mobile = '919888889103';

SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.did_assert(public.save_grn(p_gr_no => r.gr_no, p_date => '2026-08-14T12:00:00Z'::timestamptz,
  p_customer_id => r.customer, p_customer_name => r.customer_name, p_idempotency_key => 'report-dispatch-id-' || r.gr_no,
  p_items => jsonb_build_array(jsonb_build_object('item_id', :'fennel', 'item_name', 'Dispatch Id Fennel', 'packaging', 'Bag',
    'qty', 100, 'weight', 5)))->>'success' = 'true', 'fixture receipt ' || r.gr_no)
FROM (VALUES ('DIS1', :'quince'::uuid, 'Dispatch Id Quince Cold'), ('DIS2', :'rowan'::uuid, 'Dispatch Id Rowan Agro')) AS r(gr_no, customer, customer_name);
SELECT pg_temp.did_assert(public.create_dispatch_with_stock_check(jsonb_build_object('disp_no', d.disp_no,
    'disp_date', d.day, 'customer_id', g.customer_id, 'customer_name', g.customer_name,
    'supervisor_id', :'admin_profile', 'supervisor_name', 'Dispatch Id Administrator'),
  ARRAY[jsonb_build_object('gr_trl_id', t.id, 'disp_qty', d.qty)], 0, 'report-dispatch-id-' || d.disp_no)->>'success' = 'true',
  'fixture dispatch ' || d.disp_no)
FROM (VALUES ('DID1', 'DIS1', '2026-10-10', 5), ('DID2', 'DIS1', '2026-10-11', 20),
             ('DID3', 'DIS2', '2026-10-11', 7), ('DID4', 'DIS1', '2026-10-11', 1)) AS d(disp_no, gr_no, day, qty)
JOIN public.goodsreceived g ON g.gr_no = d.gr_no JOIN public.goodsreceived_trl t ON t.gr_id = g.id;
RESET ROLE;
-- DID4 is deleted, as the delete RPC leaves a dispatch: the report must not list it, id or otherwise.
UPDATE public.dispatch SET deleted_at = now() WHERE disp_no = 'DID4';
SELECT id AS id_did1 FROM public.dispatch WHERE disp_no = 'DID1' \gset
SELECT id AS id_did2 FROM public.dispatch WHERE disp_no = 'DID2' \gset
SELECT id AS id_did3 FROM public.dispatch WHERE disp_no = 'DID3' \gset
SELECT id AS id_did4 FROM public.dispatch WHERE disp_no = 'DID4' \gset
SELECT pg_temp.did_assert((SELECT count(*) FROM public.dispatch WHERE disp_no LIKE 'DID%') = 4
  AND (SELECT count(DISTINCT id) FROM public.dispatch WHERE disp_no LIKE 'DID%') = 4
  AND (SELECT count(*) FROM public.dispatch WHERE disp_no LIKE 'DID%' AND deleted_at IS NOT NULL) = 1
  AND (SELECT string_agg(disp_no || '@' || to_char(disp_date AT TIME ZONE 'Asia/Kolkata', 'MM-DD'), ' ' ORDER BY disp_no) FROM public.dispatch WHERE disp_no LIKE 'DID%')
    = 'DID1@10-10 DID2@10-11 DID3@10-11 DID4@10-11',
  'fixture: four dispatches with four different ids on the intended India days, one deleted');

-- ---------------------------------------------------------------------------
-- The answers, each read as the role under test
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.get_customer_dispatch_activity(:'quince'::uuid, '2026-10-10', '2026-10-12')::text AS admin_quince \gset
RESET ROLE;

SELECT set_config('request.jwt.claims', :'staff_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.did_assert(warehouse_security.active_role() = 'staff', 'actual staff role');
SELECT public.get_customer_dispatch_activity(:'quince'::uuid, '2026-10-10', '2026-10-12')::text AS staff_quince \gset
SELECT public.get_customer_dispatch_activity(:'rowan'::uuid, '2026-10-10', '2026-10-12')::text AS staff_rowan \gset
RESET ROLE;

SELECT set_config('request.jwt.claims', :'customer_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.did_assert(warehouse_security.active_role() = 'customer', 'actual customer role');
SELECT public.get_customer_dispatch_activity(:'quince'::uuid, '2026-10-10', '2026-10-12')::text AS customer_quince \gset
SELECT pg_temp.did_refusal(format('SELECT public.get_customer_dispatch_activity(%L::uuid, %L::date, %L::date)', :'rowan', '2026-10-10', '2026-10-12')) AS customer_rowan \gset
SELECT pg_temp.did_refusal(format('SELECT public.get_customer_dispatch_activity(%L::uuid, %L::date, %L::date)', :'quince', '2026-10-10', '2026-10-12')) AS customer_quince_check \gset
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Staff: each dispatch carries its own id, and nothing else moved
-- ---------------------------------------------------------------------------
-- The pairs of the answer are the pairs of the table (a missing, null, other or swapped id fails),
-- in the order newest day first, and the two ids differ.
SELECT pg_temp.did_assert(pg_temp.did_pairs(:'staff_quince'::jsonb) = ARRAY['DID2=' || :'id_did2', 'DID1=' || :'id_did1']
  AND pg_temp.did_pairs(:'staff_quince'::jsonb) = pg_temp.did_table_pairs(:'quince'::uuid)
  AND :'id_did1' <> :'id_did2',
  'staff: Quince dispatches carry the id of their own row: ' || :'staff_quince');
-- Each disp_id is a JSON string holding a uuid.
SELECT pg_temp.did_assert(count(*) = 2 AND bool_and(jsonb_typeof(x->'disp_id') = 'string')
    AND bool_and((x->>'disp_id') ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
  'staff: disp_id is a uuid string')
FROM jsonb_array_elements((:'staff_quince'::jsonb)->'dispatches') AS t(x);
-- disp_no and the values next to it are as they were.
SELECT pg_temp.did_assert(pg_temp.did_column(:'staff_quince'::jsonb, 'disp_no') = ARRAY['DID2', 'DID1']
  AND pg_temp.did_column(:'staff_quince'::jsonb, 'disp_date') = ARRAY['2026-10-11', '2026-10-10']
  AND pg_temp.did_column(:'staff_quince'::jsonb, 'total_qty') = ARRAY['20', '5']
  AND pg_temp.did_column(:'staff_quince'::jsonb, 'supervisor_name') = ARRAY['Dispatch Id Administrator', 'Dispatch Id Administrator']
  AND (:'staff_quince'::jsonb)#>>'{summary,total_dispatches}' = '2' AND (:'staff_quince'::jsonb)#>>'{summary,total_quantity}' = '25'
  AND (:'staff_quince'::jsonb)#>>'{summary,total_weight}' = '125',
  'staff: numbers, days, quantities and the summary of the Quince answer: ' || :'staff_quince');
-- The other keys are all still there, and no key besides disp_id is new (migration 58 later added
-- total_weight to a dispatch and weight to an item, which are in the sets below): the exact key set
-- of a dispatch and of its items.
SELECT pg_temp.did_assert(count(*) = 2
    AND bool_and(pg_temp.did_keys(x) = 'disp_date,disp_id,disp_no,items,supervisor_name,total_qty,total_weight')
    AND bool_and(jsonb_array_length(x->'items') = 1)
    AND bool_and(pg_temp.did_keys(x#>'{items,0}') = 'item_name,orig_qty,package_mark,qty,rack,source_grn,source_grn_id,weight')
    AND bool_and(x#>>'{items,0,item_name}' = 'Dispatch Id Fennel' AND x#>>'{items,0,source_grn}' = 'DIS1'),
  'staff: the keys of each dispatch and of its items')
FROM jsonb_array_elements((:'staff_quince'::jsonb)->'dispatches') AS t(x);
SELECT pg_temp.did_assert(pg_temp.did_keys(:'staff_quince'::jsonb) = 'dispatches,summary'
  AND pg_temp.did_keys((:'staff_quince'::jsonb)->'summary') = 'total_dispatches,total_quantity,total_weight',
  'staff: the keys of the answer and of its summary');
-- The deleted dispatch and the other customer's are not in the answer, id or number.
SELECT pg_temp.did_assert(position(:'id_did3' in :'staff_quince') = 0 AND position(:'id_did4' in :'staff_quince') = 0
  AND position('DID3' in :'staff_quince') = 0 AND position('DID4' in :'staff_quince') = 0,
  'staff: the Quince answer holds neither the deleted dispatch nor Rowan''s');
-- The other customer's answer has its own dispatch and id only.
SELECT pg_temp.did_assert(pg_temp.did_pairs(:'staff_rowan'::jsonb) = ARRAY['DID3=' || :'id_did3']
  AND pg_temp.did_pairs(:'staff_rowan'::jsonb) = pg_temp.did_table_pairs(:'rowan'::uuid)
  AND pg_temp.did_keys(((:'staff_rowan'::jsonb)#>'{dispatches,0}')) = 'disp_date,disp_id,disp_no,items,supervisor_name,total_qty,total_weight'
  AND position(:'id_did1' in :'staff_rowan') = 0 AND position(:'id_did2' in :'staff_rowan') = 0,
  'staff: Rowan''s dispatch carries its own id and none of Quince''s: ' || :'staff_rowan');
-- An administrator is answered the same.
SELECT pg_temp.did_assert(:'admin_quince'::jsonb = :'staff_quince'::jsonb, 'administrator and staff are answered alike: ' || :'admin_quince');

-- ---------------------------------------------------------------------------
-- A customer account: its own customer's dispatches with their ids, nobody else's
-- ---------------------------------------------------------------------------
SELECT pg_temp.did_assert(:'customer_quince'::jsonb = :'staff_quince'::jsonb
  AND pg_temp.did_pairs(:'customer_quince'::jsonb) = ARRAY['DID2=' || :'id_did2', 'DID1=' || :'id_did1']
  AND pg_temp.did_pairs(:'customer_quince'::jsonb) = pg_temp.did_table_pairs(:'quince'::uuid),
  'customer account: its own customer''s dispatches carry their ids: ' || :'customer_quince');
-- The refusal check can tell an answer from a refusal: the same call for its own customer is answered.
SELECT pg_temp.did_assert(:'customer_quince_check' LIKE 'answered: %', 'the refusal check answers "answered" for an allowed call: ' || :'customer_quince_check');
-- Another customer's id is refused by the guard, so no dispatch id of Rowan's can be learned here.
SELECT pg_temp.did_assert(:'customer_rowan' = 'Customer access denied'
  AND position(:'id_did3' in :'customer_rowan') = 0,
  'customer account: another customer''s dispatch activity was not refused: ' || :'customer_rowan');

ROLLBACK;
SELECT 'report dispatch id: each dispatch of the customer dispatch activity carries its own disp_id, the other keys are unchanged, and a customer account still gets only its own customer' AS result;

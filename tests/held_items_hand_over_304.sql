-- WH-304, backend topics "held items store" and "hand over held items" (contract ~/ws/fresh/product/tech/app-offline-holding-list.md
-- sections 2.1, 2.2 and 8: B-H1 to B-H6): public.hold_items(p_items jsonb, p_recorder uuid DEFAULT NULL) writes the refused items of a phone
-- to public.held_items and answers { success, held: [{ request_key, id, state, idempotent? }] }.
-- Written before the build: it fails until the topics exist. Fictional data; rolls back at the end.
--
-- Names the test takes from the contract (change here if Development names them otherwise):
--   table public.held_items (columns of 2.1: request_key, kind, body, source, follows, phone_seq, recorded_by, recorded_at, phone, handed_by,
--     handed_at, customer_id, what, reason, reason_code, reason_data, state, needs_decision), read as the database owner;
--   function warehouse_security.held_reason(code text) RETURNS text, the one map from a code to its family (2.1);
--   item members request_key, kind, body, seq, recorded_at, follows_key, what, customer_id, refusal { code, reason, data } (2.2);
--   public.get_held_items(p_limit, p_offset) answers { rows: [...], total } with recorded_by_name and reason_data (2.3), used here only to
--     read the moved row's names (B-H4);
--   errors: the gate raises 42501; a whole-call refusal is any answer whose success is not true (or a raise) and writes nothing;
--     REQUEST_KEY_REUSED and HELD_BODY_TOO_LARGE are looked for by name in the answer's text.
-- What the suite guards (label prefix): H1 the rows of a hand-over, H2 a repeat is the first answer, H3 key reuse, H4 who may hand over
-- and for whom, H5 reason families, H6 limits and one transaction, H7 an item follows only an item of the same recorder (WH-382), H8 the held
-- row's customer comes from the saved body, not from the phone's field (WH-383), H9 an administrator's move needs a recorder with a warehouse
-- role (WH-384; migration topic "held photos after accept").
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.hh_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'held items hand over 304: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.hh_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c jsonb; l jsonb; claims jsonb;
BEGIN
  c := public.operator_prepare_otp(phone);
  PERFORM pg_temp.hh_assert(c->>'success' = 'true', 'challenge prepared for ' || phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  l := public.operator_verify_otp(phone, c#>>'{data,otp_code}');
  PERFORM pg_temp.hh_assert(l#>>'{data,action}' = 'login', 'login for ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', r.id) INTO claims
    FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- The jsonb answer of a statement run as the signed-in caller, or {"raised": message, "state": sqlstate}.
CREATE FUNCTION pg_temp.hh_as(claims jsonb, statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims', claims::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN answer := jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  EXECUTE 'RESET ROLE';
  RETURN answer;
END $$;
-- hold_items as a caller; recorder is another person's auth id or NULL.
CREATE FUNCTION pg_temp.hh_hold(claims jsonb, items jsonb, recorder uuid DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.hh_as(claims, format('SELECT public.hold_items(%L::jsonb, %L::uuid)', items, recorder)) $$;
-- True when an answer is a refusal: a raise, or success not true.
CREATE FUNCTION pg_temp.hh_refused(a jsonb) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT a ? 'raised' OR a->>'success' IS DISTINCT FROM 'true' $$;
CREATE FUNCTION pg_temp.hh_n() RETURNS bigint LANGUAGE sql AS $$ SELECT count(*) FROM public.held_items $$;
-- One item of a hand-over (a refused dispatch of customer cust unless extra changes it).
CREATE FUNCTION pg_temp.hh_item(key text, kind text, seq int, cust uuid, extra jsonb DEFAULT '{}'::jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('request_key', key, 'kind', kind, 'body', jsonb_build_object('note', 'frozen ' || key) ||
      CASE WHEN kind = 'newDispatch' THEN jsonb_build_object('args', jsonb_build_object('p_dispatch_data', jsonb_build_object('customer_id', cust))) ELSE '{}'::jsonb END, 'seq', seq,
    'recorded_at', now() - interval '2 hours', 'what', jsonb_build_object('document', 'dispatch', 'number', 'D-' || key), 'customer_id', cust,
    'refusal', jsonb_build_object('code', 'STOCK_SHORT', 'reason', 'Insufficient stock', 'data', jsonb_build_object('lines', '[]'::jsonb))) || extra $$;

-- ===== people and the catalogue =====
INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST'
 WHERE id = (SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888885001', 'Held Administrator') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888885002', 'Held Supervisor', 'supervisor', true, 'approved'),
 (gen_random_uuid(), '919888885003', 'Held Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888885004', 'Held Customer Account', 'customer', true, 'approved'),
 (gen_random_uuid(), '919888885005', 'Held Other Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888885006', 'Held Became Customer', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888885007', 'Held Left Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888885008', 'Held Deleted Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888885009', 'Held No Role', 'user', true, 'approved');
SELECT pg_temp.hh_login('9888885001') AS admin_claims \gset
SELECT pg_temp.hh_login('9888885002') AS supervisor_claims \gset
SELECT pg_temp.hh_login('9888885003') AS staff_claims \gset
SELECT pg_temp.hh_login('9888885004') AS customer_claims \gset
SELECT pg_temp.hh_login('9888885008') AS deleted_claims \gset
SELECT id AS deleted_profile FROM public.user_profiles WHERE mobile = '919888885008' \gset
SELECT auth_user_id AS deleted_auth FROM public.user_profiles WHERE mobile = '919888885008' \gset
SELECT auth_user_id AS norole_auth FROM public.user_profiles WHERE mobile = '919888885009' \gset
SELECT id AS staff_profile FROM public.user_profiles WHERE mobile = '919888885003' \gset
SELECT auth_user_id AS staff_auth FROM public.user_profiles WHERE mobile = '919888885003' \gset
SELECT auth_user_id AS other_auth FROM public.user_profiles WHERE mobile = '919888885005' \gset
SELECT id AS became_profile FROM public.user_profiles WHERE mobile = '919888885006' \gset
SELECT auth_user_id AS became_auth FROM public.user_profiles WHERE mobile = '919888885006' \gset
SELECT id AS left_profile FROM public.user_profiles WHERE mobile = '919888885007' \gset
SELECT auth_user_id AS left_auth FROM public.user_profiles WHERE mobile = '919888885007' \gset
-- Two of the recorders change after the fact: one is now a customer account, one is deactivated (spec step 27, B-H4).
UPDATE public.user_profiles SET role = 'customer' WHERE id = :'became_profile'::uuid;
UPDATE public.user_profiles SET active = false WHERE id = :'left_profile'::uuid;
-- One recorder deleted the account (the real call: the profile keeps its row and its staff role, WH-384).
SELECT pg_temp.hh_as(:'deleted_claims'::jsonb, 'SELECT public.delete_user_account()') AS fx_deleted \gset
SELECT pg_temp.hh_assert(:'fx_deleted'::jsonb->>'success' = 'true' AND (SELECT deleted_at IS NOT NULL AND NOT active FROM public.user_profiles WHERE id = :'deleted_profile'::uuid),
  'fixture: the account of Held Deleted Staff is deleted: ' || :'fx_deleted');
-- The handing session is a known phone.
UPDATE warehouse_security.refresh_sessions SET user_agent = 'Held Test Phone/1.0' WHERE id = (:'staff_claims'::jsonb->>'session_id')::uuid;
INSERT INTO public.customers(name, mobile) VALUES ('Held Customer A', '9888885011');
SELECT id AS ca FROM public.customers WHERE name = 'Held Customer A' \gset
SELECT pg_temp.hh_assert(pg_temp.hh_n() = 0, 'premise: no held items yet');

-- ===== H1. A refused dispatch and the photos item that follows it: two rows, the follower with no decision of its own =====
SELECT pg_temp.hh_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hh_item('hh-k1', 'newDispatch', 1, :'ca'::uuid),
  pg_temp.hh_item('hh-k2', 'photos', 2, :'ca'::uuid, jsonb_build_object('follows_key', 'hh-k1', 'refusal', NULL)))) AS h1 \gset
SELECT pg_temp.hh_assert(:'h1'::jsonb->>'success' = 'true' AND jsonb_array_length(:'h1'::jsonb->'held') = 2
  AND :'h1'::jsonb#>>'{held,0,request_key}' = 'hh-k1' AND :'h1'::jsonb#>>'{held,0,state}' = 'held'
  AND :'h1'::jsonb#>>'{held,1,request_key}' = 'hh-k2' AND :'h1'::jsonb#>>'{held,1,state}' = 'held', 'H1: both items answered held: ' || :'h1');
SELECT id AS k1_id FROM public.held_items WHERE request_key = 'hh-k1' \gset
SELECT pg_temp.hh_assert((SELECT kind = 'newDispatch' AND source = 'refused' AND follows IS NULL AND phone_seq = 1 AND needs_decision
    AND state = 'held' AND reason = 'stockShort' AND reason_code = 'STOCK_SHORT' AND recorded_by = :'staff_profile'::uuid
    AND handed_by = :'staff_profile'::uuid AND customer_id = :'ca'::uuid AND phone = 'Held Test Phone/1.0'
    AND body = jsonb_build_object('note', 'frozen hh-k1', 'args', jsonb_build_object('p_dispatch_data', jsonb_build_object('customer_id', :'ca')))
    AND what->>'number' = 'D-hh-k1' AND decided_by IS NULL
  FROM public.held_items WHERE request_key = 'hh-k1'), 'H1: the refused dispatch is stored as the phone froze it, held, with its reason, recorder and phone');
SELECT pg_temp.hh_assert((SELECT kind = 'photos' AND source = 'follows' AND follows = :'k1_id'::uuid AND NOT needs_decision AND state = 'held'
    AND reason = 'followsHeld' AND recorded_by = :'staff_profile'::uuid FROM public.held_items WHERE request_key = 'hh-k2'),
  'H1: the photos item follows the dispatch, has no decision of its own and reads followsHeld');
SELECT pg_temp.hh_assert((SELECT recorded_at <= now() AND recorded_at > now() - interval '3 hours' FROM public.held_items WHERE request_key = 'hh-k1'),
  'H1: the recorded time is the phone time');
-- A phone clock ahead of the server is clamped to the server's now.
SELECT pg_temp.hh_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hh_item('hh-future', 'newDispatch', 3, :'ca'::uuid, jsonb_build_object('recorded_at', now() + interval '5 days')))) AS h1_future \gset
SELECT pg_temp.hh_assert((SELECT recorded_at <= now() FROM public.held_items WHERE request_key = 'hh-future'), 'H1: a recorded time ahead of the server is clamped to now: ' || :'h1_future');

-- ===== H2. The same call again, and one item alone again: the same ids, nothing written =====
SELECT array_agg(request_key || '=' || id::text || '@' || handed_at::text ORDER BY request_key) AS before_rows FROM public.held_items \gset
SELECT pg_temp.hh_n() AS n_before \gset
SELECT pg_temp.hh_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hh_item('hh-k1', 'newDispatch', 1, :'ca'::uuid),
  pg_temp.hh_item('hh-k2', 'photos', 2, :'ca'::uuid, jsonb_build_object('follows_key', 'hh-k1', 'refusal', NULL)))) AS h2_again \gset
SELECT pg_temp.hh_assert(:'h2_again'::jsonb->>'success' = 'true' AND jsonb_array_length(:'h2_again'::jsonb->'held') = 2
  AND :'h2_again'::jsonb#>>'{held,0,id}' = :'h1'::jsonb#>>'{held,0,id}' AND :'h2_again'::jsonb#>>'{held,1,id}' = :'h1'::jsonb#>>'{held,1,id}'
  AND :'h2_again'::jsonb#>>'{held,0,idempotent}' = 'true' AND :'h2_again'::jsonb#>>'{held,1,idempotent}' = 'true',
  'H2: the same call answers the same ids, each marked idempotent: ' || :'h2_again');
SELECT pg_temp.hh_hold(:'staff_claims'::jsonb, jsonb_build_array(pg_temp.hh_item('hh-k1', 'newDispatch', 1, :'ca'::uuid))) AS h2_alone \gset
SELECT pg_temp.hh_assert(:'h2_alone'::jsonb->>'success' = 'true' AND :'h2_alone'::jsonb#>>'{held,0,id}' = :'h1'::jsonb#>>'{held,0,id}'
  AND :'h2_alone'::jsonb#>>'{held,0,idempotent}' = 'true', 'H2: one item alone again answers its row: ' || :'h2_alone');
-- Another caller who may hand over (a supervisor) repeating the key also gets the first answer, whatever the delay: the row stays the staff person's.
UPDATE public.held_items SET handed_at = handed_at - interval '30 days' WHERE request_key = 'hh-k1';
SELECT pg_temp.hh_hold(:'staff_claims'::jsonb, jsonb_build_array(pg_temp.hh_item('hh-k1', 'newDispatch', 1, :'ca'::uuid))) AS h2_late \gset
SELECT pg_temp.hh_assert(:'h2_late'::jsonb->>'success' = 'true' AND :'h2_late'::jsonb#>>'{held,0,id}' = :'k1_id' AND :'h2_late'::jsonb#>>'{held,0,idempotent}' = 'true',
  'H2: a repeat after 30 days still answers the first row: ' || :'h2_late');
UPDATE public.held_items SET handed_at = handed_at + interval '30 days' WHERE request_key = 'hh-k1';
SELECT pg_temp.hh_assert(pg_temp.hh_n() = :'n_before' AND (SELECT array_agg(request_key || '=' || id::text || '@' || handed_at::text ORDER BY request_key)
  FROM public.held_items) = :'before_rows'::text[], 'H2: the repeats wrote nothing and changed no row');

-- ===== H3. The same key for another kind or another recorder: REQUEST_KEY_REUSED for that item only =====
SELECT pg_temp.hh_n() AS n_h3 \gset
SELECT pg_temp.hh_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hh_item('hh-k1', 'newGrn', 1, :'ca'::uuid),
  pg_temp.hh_item('hh-k3', 'newDispatch', 4, :'ca'::uuid))) AS h3_kind \gset
SELECT pg_temp.hh_assert(:'h3_kind'::text LIKE '%REQUEST_KEY_REUSED%', 'H3: the same key for another kind is REQUEST_KEY_REUSED: ' || :'h3_kind');
SELECT pg_temp.hh_assert((SELECT kind FROM public.held_items WHERE request_key = 'hh-k1') = 'newDispatch'
  AND (SELECT count(*) FROM public.held_items WHERE request_key = 'hh-k3' AND state = 'held') = 1 AND pg_temp.hh_n() = :'n_h3'::bigint + 1,
  'H3: the reused key leaves its row as it was, and the other item of the call is held');
-- The administrator hands the same key over for another person.
SELECT pg_temp.hh_hold(:'admin_claims'::jsonb, jsonb_build_array(pg_temp.hh_item('hh-k1', 'newDispatch', 1, :'ca'::uuid)), :'other_auth'::uuid) AS h3_person \gset
SELECT pg_temp.hh_assert(:'h3_person'::text LIKE '%REQUEST_KEY_REUSED%' AND (SELECT recorded_by FROM public.held_items WHERE request_key = 'hh-k1') = :'staff_profile'::uuid,
  'H3: the same key for another recorder is REQUEST_KEY_REUSED and the row keeps its recorder: ' || :'h3_person');

-- ===== H4. Who may hand over, and for whom =====
SELECT pg_temp.hh_n() AS n_h4 \gset
SELECT pg_temp.hh_hold(:'customer_claims'::jsonb, jsonb_build_array(pg_temp.hh_item('hh-cust', 'newDispatch', 1, :'ca'::uuid))) AS h4_customer \gset
SELECT pg_temp.hh_assert(:'h4_customer'::jsonb->>'state' = '42501', 'H4: a customer account is refused by the gate: ' || :'h4_customer');
SELECT pg_temp.hh_hold(jsonb_build_object('role', 'authenticated', 'sub', gen_random_uuid()), jsonb_build_array(pg_temp.hh_item('hh-norole', 'newDispatch', 1, :'ca'::uuid))) AS h4_norole \gset
SELECT pg_temp.hh_assert(:'h4_norole'::jsonb->>'state' = '42501', 'H4: a caller with no profile and so no role is refused by the gate: ' || :'h4_norole');
SELECT pg_temp.hh_hold(:'staff_claims'::jsonb, jsonb_build_array(pg_temp.hh_item('hh-st-other', 'newDispatch', 1, :'ca'::uuid)), :'other_auth'::uuid) AS h4_staff \gset
SELECT pg_temp.hh_hold(:'supervisor_claims'::jsonb, jsonb_build_array(pg_temp.hh_item('hh-sv-other', 'newDispatch', 1, :'ca'::uuid)), :'other_auth'::uuid) AS h4_super \gset
SELECT pg_temp.hh_assert(pg_temp.hh_refused(:'h4_staff'::jsonb) AND pg_temp.hh_refused(:'h4_super'::jsonb)
  AND pg_temp.hh_n() = :'n_h4'::bigint, 'H4: staff and a supervisor handing over for another person are refused and write nothing: ' || :'h4_staff' || ' / ' || :'h4_super');
-- Staff for themselves with their own auth id as recorder is allowed (p_recorder NULL or the caller's own id).
SELECT pg_temp.hh_hold(:'staff_claims'::jsonb, jsonb_build_array(pg_temp.hh_item('hh-st-self', 'newDispatch', 5, :'ca'::uuid)), :'staff_auth'::uuid) AS h4_self \gset
SELECT pg_temp.hh_assert(:'h4_self'::jsonb->>'success' = 'true' AND (SELECT source = 'refused' AND recorded_by = :'staff_profile'::uuid
  FROM public.held_items WHERE request_key = 'hh-st-self'), 'H4: staff naming themselves as the recorder is an ordinary hand-over: ' || :'h4_self');
-- An unknown person is refused even for the administrator.
SELECT pg_temp.hh_hold(:'admin_claims'::jsonb, jsonb_build_array(pg_temp.hh_item('hh-nobody', 'newDispatch', 1, :'ca'::uuid)), gen_random_uuid()) AS h4_nobody \gset
SELECT pg_temp.hh_assert(pg_temp.hh_refused(:'h4_nobody'::jsonb) AND NOT EXISTS (SELECT 1 FROM public.held_items WHERE request_key = 'hh-nobody'),
  'H4: a recorder who is no profile of this facility is refused: ' || :'h4_nobody');
-- The administrator moves an item for a person now a customer account (WH-384: refused, H9 has the detail) and for a deactivated one: source moved, reason moved, recorder that person.
SELECT pg_temp.hh_hold(:'admin_claims'::jsonb, jsonb_build_array(
  pg_temp.hh_item('hh-mv-cust', 'newDispatch', 1, :'ca'::uuid, jsonb_build_object('refusal', NULL))), :'became_auth'::uuid) AS h4_move_cust \gset
SELECT pg_temp.hh_hold(:'admin_claims'::jsonb, jsonb_build_array(
  pg_temp.hh_item('hh-mv-left', 'newDispatch', 1, :'ca'::uuid, jsonb_build_object('refusal', NULL))), :'left_auth'::uuid) AS h4_move_left \gset
SELECT pg_temp.hh_assert(pg_temp.hh_refused(:'h4_move_cust'::jsonb) AND :'h4_move_left'::jsonb->>'success' = 'true',
  'H4: the administrator moves items for the deactivated person and not for the one who is now a customer account: ' || :'h4_move_cust' || ' / ' || :'h4_move_left');
SELECT pg_temp.hh_assert(NOT EXISTS (SELECT 1 FROM public.held_items WHERE request_key = 'hh-mv-cust'),
  'H4: nothing was written for a person who is now a customer account');
SELECT pg_temp.hh_assert((SELECT source = 'moved' AND reason = 'moved' AND recorded_by = :'left_profile'::uuid FROM public.held_items WHERE request_key = 'hh-mv-left'),
  'H4: an item moved for a deactivated person is source moved, reason moved, recorded by that person');
-- The list row names that person (not the administrator), and its reason_data names the administrator and the date.
SELECT pg_temp.hh_as(:'admin_claims'::jsonb, 'SELECT public.get_held_items(200, 0)') AS h4_list \gset
SELECT pg_temp.hh_assert((SELECT r->>'recorded_by_name' = 'Held Left Staff' AND r#>>'{reason_data,admin_name}' = 'Held Administrator'
    AND r#>>'{reason_data,recorder_name}' = 'Held Left Staff' AND (r#>>'{reason_data,moved_at}') IS NOT NULL
  FROM jsonb_array_elements(:'h4_list'::jsonb->'rows') r WHERE r->>'reason' = 'moved' AND r->>'recorded_by_name' = 'Held Left Staff'),
  'H4: the moved row of a deactivated person lists that person as recorder and names the administrator and the date in reason_data: ' || left(:'h4_list', 600));
SELECT pg_temp.hh_assert((SELECT count(*) FROM jsonb_array_elements(:'h4_list'::jsonb->'rows') r WHERE r->>'recorded_by_name' = 'Held Left Staff' AND r->>'reason' = 'moved') = 1,
  'H4: the moved row of a deactivated person lists that person as recorder');

-- ===== H5. The reason family of a code =====
CREATE TEMP TABLE hh_family(code text, family text);
INSERT INTO hh_family(code, family) VALUES
 ('STOCK_SHORT', 'stockShort'), ('NUMBER_TAKEN', 'numberUsed'), ('NUMBER_FORMAT', 'numberFormat'), ('GRN_NUMBER_SPACES', 'numberFormat'),
 ('DISPATCH_NUMBER_SPACES', 'numberFormat'), ('GRN_DATE_FUTURE', 'dateRefused'), ('DISPATCH_DATE_FUTURE', 'dateRefused'),
 ('DISPATCH_BEFORE_GRN', 'dateRefused'), ('GRN_DATE_AFTER_DISPATCH', 'dateRefused'), ('RECORDED_TIME_FUTURE', 'dateRefused'),
 ('POSSIBLE_DUPLICATE', 'duplicate'), ('RATE_MISSING', 'noRate'), ('LOT_NOT_FOUND', 'deleted'), ('GRN_NOT_FOUND', 'deleted'), ('RECORD_DELETED', 'deleted'),
 ('GRN_DATE_LOCKED', 'locked'), ('GRN_INVOICED', 'locked'), ('LOT_INVOICED', 'locked'), ('LOT_DISPATCHED', 'locked'),
 ('LINE_DISPATCHED_BEFORE', 'locked'), ('LINE_ON_ORDER', 'locked'), ('GRN_CUSTOMER_LOCKED', 'locked'), ('GRN_PRICING_MODE_LOCKED', 'locked'),
 ('QTY_BELOW_DISPATCHED', 'belowDispatched'),
 ('IMPORTED_READ_ONLY', 'other'), ('RATES_NEED_MANAGER', 'other'), ('RATES_WOULD_DROP', 'other'), ('GRN_LINES_REQUIRED', 'other'),
 ('SERIES_FULL', 'other'), ('NUMBER_REQUIRED', 'other'), ('NUMBER_NOT_EXPECTED', 'other'), ('CUSTOMER_INACTIVE', 'other'),
 ('REQUEST_KEY_REUSED', 'other'), ('LOT_CHANGE_INVALID', 'other'), ('RACK_TOO_LONG', 'other'), ('MARK_TOO_LONG', 'other'), ('42501', 'other'),
 ('A_CODE_THE_SERVER_NEVER_HEARD_OF', 'other');
SELECT pg_temp.hh_assert(NOT EXISTS (SELECT 1 FROM hh_family f WHERE warehouse_security.held_reason(f.code) IS DISTINCT FROM f.family),
  'H5: every code of the table maps to its family: ' || COALESCE((SELECT string_agg(f.code || '->' || COALESCE(warehouse_security.held_reason(f.code), 'NULL') || ' (want ' || f.family || ')', ', ')
    FROM hh_family f WHERE warehouse_security.held_reason(f.code) IS DISTINCT FROM f.family), ''));
SELECT pg_temp.hh_assert(warehouse_security.held_reason(NULL) = 'other' AND warehouse_security.held_reason('') = 'other', 'H5: no code and an empty code are other, never an error');
-- Through the hand-over: a known code stores its family, the code and the figures; an unknown code is other and the hand-over still succeeds.
SELECT pg_temp.hh_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hh_item('hh-r-taken', 'newGrn', 6, :'ca'::uuid, jsonb_build_object('refusal', jsonb_build_object('code', 'NUMBER_TAKEN', 'data', jsonb_build_object('number', 'A0007')))),
  pg_temp.hh_item('hh-r-odd', 'newGrn', 7, :'ca'::uuid, jsonb_build_object('refusal', jsonb_build_object('code', 'A_CODE_THE_SERVER_NEVER_HEARD_OF', 'reason', 'Something new'))),
  pg_temp.hh_item('hh-r-none', 'newGrn', 8, :'ca'::uuid, jsonb_build_object('refusal', jsonb_build_object('reason', 'Plain text only'))))) AS h5 \gset
SELECT pg_temp.hh_assert(:'h5'::jsonb->>'success' = 'true', 'H5: a hand-over with an unknown code and one with no code succeeds: ' || :'h5');
SELECT pg_temp.hh_assert((SELECT reason = 'numberUsed' AND reason_code = 'NUMBER_TAKEN' AND reason_data->>'number' = 'A0007' FROM public.held_items WHERE request_key = 'hh-r-taken'),
  'H5: NUMBER_TAKEN is stored as numberUsed with its code and the number in reason_data');
SELECT pg_temp.hh_assert((SELECT reason = 'other' AND reason_code = 'A_CODE_THE_SERVER_NEVER_HEARD_OF' FROM public.held_items WHERE request_key = 'hh-r-odd')
  AND (SELECT reason = 'other' AND reason_code IS NULL FROM public.held_items WHERE request_key = 'hh-r-none'), 'H5: an unknown code and no code are stored as other');

-- ===== H6. 50 items are the most; 51, an unknown kind and a body over 64 kB are refused and write nothing =====
SELECT pg_temp.hh_n() AS n_h6 \gset
SELECT pg_temp.hh_hold(:'staff_claims'::jsonb, (SELECT jsonb_agg(pg_temp.hh_item('hh-big-' || g, 'newDispatch', 100 + g, :'ca'::uuid)) FROM generate_series(1, 51) g)) AS h6_51 \gset
SELECT pg_temp.hh_assert(pg_temp.hh_refused(:'h6_51'::jsonb) AND pg_temp.hh_n() = :'n_h6'::bigint, 'H6: 51 items are refused and none is written: ' || left(:'h6_51', 300));
SELECT pg_temp.hh_hold(:'staff_claims'::jsonb, (SELECT jsonb_agg(pg_temp.hh_item('hh-fifty-' || g, 'newDispatch', 100 + g, :'ca'::uuid)) FROM generate_series(1, 50) g)) AS h6_50 \gset
SELECT pg_temp.hh_assert(:'h6_50'::jsonb->>'success' = 'true' AND pg_temp.hh_n() = :'n_h6'::bigint + 50, 'H6: exactly 50 items are accepted: ' || left(:'h6_50', 300));
SELECT pg_temp.hh_n() AS n_h6b \gset
SELECT pg_temp.hh_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hh_item('hh-good-1', 'newDispatch', 200, :'ca'::uuid), pg_temp.hh_item('hh-bad-kind', 'newInvoice', 201, :'ca'::uuid))) AS h6_kind \gset
SELECT pg_temp.hh_assert(pg_temp.hh_refused(:'h6_kind'::jsonb) AND pg_temp.hh_n() = :'n_h6b'::bigint
  AND NOT EXISTS (SELECT 1 FROM public.held_items WHERE request_key IN ('hh-good-1', 'hh-bad-kind')), 'H6: an unknown kind refuses the call and writes nothing, the valid item too: ' || left(:'h6_kind', 300));
SELECT pg_temp.hh_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hh_item('hh-good-2', 'newDispatch', 202, :'ca'::uuid),
  pg_temp.hh_item('hh-huge', 'newDispatch', 203, :'ca'::uuid, jsonb_build_object('body', jsonb_build_object('filler', repeat('x', 66000)))))) AS h6_size \gset
SELECT pg_temp.hh_assert(pg_temp.hh_refused(:'h6_size'::jsonb) AND :'h6_size'::text LIKE '%HELD_BODY_TOO_LARGE%' AND pg_temp.hh_n() = :'n_h6b'::bigint
  AND NOT EXISTS (SELECT 1 FROM public.held_items WHERE request_key IN ('hh-good-2', 'hh-huge')),
  'H6: a 65 kB body is HELD_BODY_TOO_LARGE and nothing of the call is written: ' || left(:'h6_size', 300));
SELECT pg_temp.hh_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hh_item('hh-notobject', 'newDispatch', 204, :'ca'::uuid, jsonb_build_object('body', '"just text"'::jsonb)))) AS h6_body \gset
SELECT pg_temp.hh_assert(pg_temp.hh_refused(:'h6_body'::jsonb) AND NOT EXISTS (SELECT 1 FROM public.held_items WHERE request_key = 'hh-notobject'),
  'H6: a body that is not an object is refused: ' || left(:'h6_body', 300));
-- ===== H7. WH-382: an item follows only an item of the same recorder =====
-- The supervisor hands over an item with the key hh-k1 (the staff person's dispatch: REQUEST_KEY_REUSED, not written) and a photos item that
-- names hh-k1 as the item it follows. The key is in the call, so the pre-check passes, but the row it names is not the supervisor's.
SELECT id AS supervisor_profile FROM public.user_profiles WHERE mobile = '919888885002' \gset
SELECT pg_temp.hh_hold(:'supervisor_claims'::jsonb, jsonb_build_array(
  pg_temp.hh_item('hh-k1', 'newDispatch', 1, :'ca'::uuid),
  pg_temp.hh_item('hh-w2', 'photos', 2, :'ca'::uuid, jsonb_build_object('follows_key', 'hh-k1', 'refusal', NULL)))) AS h7_other \gset
SELECT pg_temp.hh_assert(:'h7_other'::text LIKE '%REQUEST_KEY_REUSED%' AND :'h7_other'::jsonb->>'success' = 'true' AND :'h7_other'::jsonb#>>'{held,1,state}' = 'held',
  'H7: the other person''s key is REQUEST_KEY_REUSED for item one and the photos item is held: ' || :'h7_other');
SELECT pg_temp.hh_assert((SELECT follows IS NULL AND recorded_by = :'supervisor_profile'::uuid AND needs_decision FROM public.held_items WHERE request_key = 'hh-w2'),
  'H7: a photos item that names another person''s key is not linked under that person''s item, and keeps a decision of its own');
SELECT pg_temp.hh_assert(NOT EXISTS (SELECT 1 FROM public.held_items WHERE follows = :'k1_id'::uuid AND recorded_by <> :'staff_profile'::uuid),
  'H7: nothing of another recorder follows the staff person''s dispatch hh-k1');
-- A key that is neither in the call nor held for this recorder is still refused (the pre-check), nothing written.
SELECT pg_temp.hh_n() AS n_h7 \gset
SELECT pg_temp.hh_hold(:'supervisor_claims'::jsonb, jsonb_build_array(
  pg_temp.hh_item('hh-w6', 'photos', 3, :'ca'::uuid, jsonb_build_object('follows_key', 'hh-k1', 'refusal', NULL)))) AS h7_alone \gset
SELECT pg_temp.hh_assert(pg_temp.hh_refused(:'h7_alone'::jsonb) AND pg_temp.hh_n() = :'n_h7'::bigint, 'H7: following another person''s key with the item not in the call is refused: ' || :'h7_alone');
-- Controls: the same recorder still links, in the same call and to an item held by an earlier call, and the administrator's move links under the moved person.
SELECT pg_temp.hh_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hh_item('hh-w3', 'newDispatch', 10, :'ca'::uuid),
  pg_temp.hh_item('hh-w4', 'photos', 11, :'ca'::uuid, jsonb_build_object('follows_key', 'hh-w3', 'refusal', NULL)),
  pg_temp.hh_item('hh-w5', 'photos', 12, :'ca'::uuid, jsonb_build_object('follows_key', 'hh-k1', 'refusal', NULL)))) AS h7_same \gset
SELECT pg_temp.hh_hold(:'admin_claims'::jsonb, jsonb_build_array(
  pg_temp.hh_item('hh-w7', 'photos', 13, :'ca'::uuid, jsonb_build_object('follows_key', 'hh-k1', 'refusal', NULL))), :'staff_auth'::uuid) AS h7_move \gset
SELECT pg_temp.hh_assert(:'h7_same'::jsonb->>'success' = 'true' AND :'h7_move'::jsonb->>'success' = 'true', 'H7: the same recorder''s hand-overs succeed: ' || :'h7_same' || ' / ' || :'h7_move');
SELECT pg_temp.hh_assert((SELECT follows = (SELECT id FROM public.held_items WHERE request_key = 'hh-w3') AND NOT needs_decision AND recorded_by = :'staff_profile'::uuid
    FROM public.held_items WHERE request_key = 'hh-w4'), 'H7: the same recorder''s photos item follows the item of the same call');
SELECT pg_temp.hh_assert((SELECT follows = :'k1_id'::uuid AND NOT needs_decision AND recorded_by = :'staff_profile'::uuid FROM public.held_items WHERE request_key = 'hh-w5'),
  'H7: the same recorder''s photos item follows its item handed over in an earlier call');
SELECT pg_temp.hh_assert((SELECT follows = :'k1_id'::uuid AND NOT needs_decision AND recorded_by = :'staff_profile'::uuid AND handed_by <> recorded_by FROM public.held_items WHERE request_key = 'hh-w7'),
  'H7: an administrator''s move follows the moved person''s item (the recorder, not the caller, is the one that counts)');

-- ===== H8. WH-383: the held row's customer is the customer of the saved body, never the phone's customer_id field =====
INSERT INTO public.customers(name, mobile) VALUES ('Held Customer B', '9888885012');
SELECT id AS cb FROM public.customers WHERE name = 'Held Customer B' \gset
-- Phone field says A; the bodies say B (a new GRN: args.p_customer_id; a new dispatch: args.p_dispatch_data.customer_id).
SELECT pg_temp.hh_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hh_item('hh-c-grn', 'newGrn', 20, :'ca'::uuid, jsonb_build_object('body', jsonb_build_object('args', jsonb_build_object('p_customer_id', :'cb')))),
  pg_temp.hh_item('hh-c-disp', 'newDispatch', 21, :'ca'::uuid, jsonb_build_object('body',
    jsonb_build_object('args', jsonb_build_object('p_dispatch_data', jsonb_build_object('customer_id', :'cb'))))),
  pg_temp.hh_item('hh-c-nogrn', 'newGrn', 22, :'ca'::uuid, jsonb_build_object('body', jsonb_build_object('args', jsonb_build_object('p_gr_no', 'X')))),
  pg_temp.hh_item('hh-c-nodisp', 'newDispatch', 23, :'ca'::uuid, jsonb_build_object('body', jsonb_build_object('note', 'no customer in the body'))),
  pg_temp.hh_item('hh-c-unknown', 'newGrn', 24, :'ca'::uuid, jsonb_build_object('body',
    jsonb_build_object('args', jsonb_build_object('p_customer_id', gen_random_uuid())))),
  pg_temp.hh_item('hh-c-text', 'newGrn', 25, :'ca'::uuid, jsonb_build_object('body', jsonb_build_object('args', jsonb_build_object('p_customer_id', 'not a uuid')))))) AS h8 \gset
SELECT pg_temp.hh_assert(:'h8'::jsonb->>'success' = 'true', 'fixture: H8 hand-over: ' || :'h8');
SELECT pg_temp.hh_assert((SELECT customer_id = :'cb'::uuid FROM public.held_items WHERE request_key = 'hh-c-grn')
  AND (SELECT customer_id = :'cb'::uuid FROM public.held_items WHERE request_key = 'hh-c-disp'),
  'H8: a new GRN and a new dispatch take the customer of their saved body, not the phone''s field');
SELECT pg_temp.hh_assert((SELECT bool_and(customer_id IS NULL) AND count(*) = 4 FROM public.held_items WHERE request_key IN ('hh-c-nogrn', 'hh-c-nodisp', 'hh-c-unknown', 'hh-c-text')),
  'H8: a body with no customer, an unknown customer or a customer that is no uuid leaves the row''s customer empty (the phone''s field is never used)');
SELECT pg_temp.hh_as(:'admin_claims'::jsonb, 'SELECT public.get_held_items(500, 0)') AS h8_list \gset
SELECT pg_temp.hh_assert((SELECT count(*) = 2 AND bool_and(r->>'customer_name' = 'Held Customer B')
  FROM jsonb_array_elements(:'h8_list'::jsonb->'rows') r WHERE (r->>'id')::uuid IN (pg_temp.hh_hid('hh-c-grn'), pg_temp.hh_hid('hh-c-disp'))),
  'H8: the holding list shows the body''s customer (Held Customer B) for both: ' || left(:'h8_list', 300));
SELECT pg_temp.hh_assert((SELECT r->'customer_name' = 'null'::jsonb FROM jsonb_array_elements(:'h8_list'::jsonb->'rows') r WHERE (r->>'id')::uuid = pg_temp.hh_hid('hh-c-nogrn')),
  'H8: a held row with no customer in its body shows no customer name, not the phone''s Held Customer A');

-- ===== H9. WH-384: the recorder of an administrator's move has a warehouse role =====
SELECT pg_temp.hh_n() AS n_h9 \gset
SELECT pg_temp.hh_hold(:'admin_claims'::jsonb, jsonb_build_array(pg_temp.hh_item('hh-r-cust', 'newDispatch', 30, :'ca'::uuid)), :'became_auth'::uuid) AS h9_cust \gset
SELECT pg_temp.hh_hold(:'admin_claims'::jsonb, jsonb_build_array(pg_temp.hh_item('hh-r-user', 'newDispatch', 31, :'ca'::uuid)), :'norole_auth'::uuid) AS h9_user \gset
SELECT pg_temp.hh_hold(:'admin_claims'::jsonb, jsonb_build_array(pg_temp.hh_item('hh-r-ok-first', 'newDispatch', 32, :'ca'::uuid), pg_temp.hh_item('hh-r-user2', 'newDispatch', 33, :'ca'::uuid)),
  :'norole_auth'::uuid) AS h9_two \gset
SELECT pg_temp.hh_assert(pg_temp.hh_refused(:'h9_cust'::jsonb) AND :'h9_cust'::text LIKE '%HELD_RECORDER_INVALID%'
  AND pg_temp.hh_refused(:'h9_user'::jsonb) AND :'h9_user'::text LIKE '%HELD_RECORDER_INVALID%' AND pg_temp.hh_refused(:'h9_two'::jsonb) AND :'h9_two'::text LIKE '%HELD_RECORDER_INVALID%'
  AND pg_temp.hh_n() = :'n_h9'::bigint AND NOT EXISTS (SELECT 1 FROM public.held_items WHERE request_key IN ('hh-r-cust', 'hh-r-user', 'hh-r-ok-first', 'hh-r-user2')),
  'H9: a recorder who is a customer account or has no warehouse role is HELD_RECORDER_INVALID and nothing is written: ' || :'h9_cust' || ' / ' || :'h9_user' || ' / ' || :'h9_two');
-- A deactivated staff recorder is allowed; an id that is no profile keeps HELD_RECORDER_UNKNOWN (and is not INVALID).
SELECT pg_temp.hh_hold(:'admin_claims'::jsonb, jsonb_build_array(pg_temp.hh_item('hh-r-left', 'newDispatch', 34, :'ca'::uuid, jsonb_build_object('refusal', NULL))), :'left_auth'::uuid) AS h9_left \gset
SELECT pg_temp.hh_hold(:'admin_claims'::jsonb, jsonb_build_array(pg_temp.hh_item('hh-r-nobody', 'newDispatch', 35, :'ca'::uuid)), gen_random_uuid()) AS h9_nobody \gset
SELECT pg_temp.hh_assert(:'h9_left'::jsonb->>'success' = 'true' AND (SELECT recorded_by = :'left_profile'::uuid AND source = 'moved' FROM public.held_items WHERE request_key = 'hh-r-left'),
  'H9: a deactivated staff recorder is allowed: ' || :'h9_left');
SELECT pg_temp.hh_assert(pg_temp.hh_refused(:'h9_nobody'::jsonb) AND :'h9_nobody'::text LIKE '%HELD_RECORDER_UNKNOWN%' AND :'h9_nobody'::text NOT LIKE '%HELD_RECORDER_INVALID%'
  AND NOT EXISTS (SELECT 1 FROM public.held_items WHERE request_key = 'hh-r-nobody'), 'H9: an id that is no profile is HELD_RECORDER_UNKNOWN: ' || :'h9_nobody');
-- A deleted account keeps its row and its staff role (delete_user_account): it is "never a deleted profile" (Product, WH-384).
SELECT pg_temp.hh_hold(:'admin_claims'::jsonb, jsonb_build_array(pg_temp.hh_item('hh-r-deleted', 'newDispatch', 36, :'ca'::uuid)), :'deleted_auth'::uuid) AS h9_deleted \gset
SELECT pg_temp.hh_assert(pg_temp.hh_refused(:'h9_deleted'::jsonb) AND :'h9_deleted'::text LIKE '%HELD_RECORDER_INVALID%'
  AND NOT EXISTS (SELECT 1 FROM public.held_items WHERE request_key = 'hh-r-deleted'),
  'H9: a recorder whose account is deleted is HELD_RECORDER_INVALID and nothing is written: ' || :'h9_deleted');
ROLLBACK;
\echo 'WH-304 held items hand over (B-H1 to B-H6) checks passed.'

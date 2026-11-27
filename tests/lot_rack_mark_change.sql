-- WH-302 (B1-B10, B12 data checks of B13): the narrow server function "lot rack and mark change", public.set_lot_rack_and_mark(p_lot_id,
-- p_changes, p_request_key), contract ~/ws/fresh/product/tech/app-offline-quick-change.md section 2.1 with Product's PQ5 (a deactivated customer's
-- lots are allowed). Written before the build: it must FAIL on a database without the function. B11 (the feed) is
-- tests/sync_feed_lot_rack_mark.sql, B12 (two sessions at once) tests/lot_rack_mark_race.sh. Refer to migrations by topic: "lot rack and mark change",
-- "imported read only", "invoice keeps issued marking".
--
-- Names the test takes from the contract (change here if Development names them otherwise):
--   function and arguments  set_lot_rack_and_mark(p_lot_id uuid, p_changes jsonb, p_request_key text) RETURNS jsonb
--   refusals (warehouse_security.refuse: success false, reason, error_code WH409): LOT_CHANGE_INVALID, RACK_TOO_LONG / MARK_TOO_LONG (with limit),
--     LOT_NOT_FOUND; the role gate raises 42501.
--   answer: { success, lot { id, gr_id, rack, package_mark }, grn { id, gr_no, updated_at }, changed [field...], replaced [{ field, newer, sent }] };
--     a replay adds idempotent: true.
--
-- What the suite holds (the behaviour each guards is named where it is asserted):
--   B1 roles, B2 normalise and limit, B3 only the sent fields are written, B4 dispatched, billed and on-order lots, B5 imported lots (and the
--   exemption does not outlive the call), B6 blank sender or supervisor, B7 deleted lot or GRN, B8 last sent wins per field and the replaced list,
--   B9 the GRN's change mark, B10 the request key (another lot: REQUEST_KEY_REUSED), B13 two lots / two fields changed from two phones, B14 a deactivated customer's lots,
--   B15 the phone time (p_changes.recorded_at) of an entry; B2 and B8 also cover recorded_at.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database; rolls back (so updated_at, which is now(), is moved
-- back by the suite before a call that is to move it: pg_temp.lc_age).
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.lc_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'lot rack and mark change: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.lc_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c jsonb; l jsonb; claims jsonb;
BEGIN
  c := public.operator_prepare_otp(phone);
  PERFORM pg_temp.lc_assert(c->>'success' = 'true', 'challenge prepared for ' || phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  l := public.operator_verify_otp(phone, c#>>'{data,otp_code}');
  PERFORM pg_temp.lc_assert(l#>>'{data,action}' = 'login', 'login for ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', r.id) INTO claims
    FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- The jsonb answer of a statement run as the signed-in caller, or {"raised": message, "state": sqlstate}.
CREATE FUNCTION pg_temp.lc_as(claims jsonb, statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims', claims::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN answer := jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  EXECUTE 'RESET ROLE';
  RETURN answer;
END $$;
-- One call of the function as a caller.
CREATE FUNCTION pg_temp.lc_call(claims jsonb, lot uuid, changes jsonb, request_key text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.lc_as(claims, format('SELECT public.set_lot_rack_and_mark(%L::uuid, %L::jsonb, %L)', lot, changes, request_key)) $$;
-- Whether a statement (run as the database owner) raises this SQLSTATE.
CREATE FUNCTION pg_temp.lc_raises(statement text, expected text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE statement;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = expected THEN RETURN true; END IF;
    RAISE EXCEPTION 'expected SQLSTATE %, got % (%) for: %', expected, SQLSTATE, SQLERRM, left(statement, 120);
  END;
  RETURN false;
END $$;
-- {"rack": ..., "package_mark": ...} as stored.
CREATE FUNCTION pg_temp.lc_lot(lot uuid) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('rack', t.rack, 'package_mark', t.package_mark) FROM public.goodsreceived_trl t WHERE t.id = lot $$;
-- Everything stored for a GRN: its row and all its lot rows (whole rows, so a write to any column shows).
CREATE FUNCTION pg_temp.lc_world(grn uuid) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('grn', (SELECT to_jsonb(g) FROM public.goodsreceived g WHERE g.id = grn),
    'lots', (SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.id), '[]') FROM public.goodsreceived_trl t WHERE t.gr_id = grn)) $$;
-- The GRN's updated_at moved to one hour ago (owner write, no triggers), so that a call that moves it is seen; returns the value.
CREATE FUNCTION pg_temp.lc_age(grn uuid) RETURNS timestamptz LANGUAGE plpgsql AS $$
DECLARE t timestamptz := date_trunc('milliseconds', now() - interval '1 hour');
BEGIN
  SET LOCAL session_replication_role = replica;
  UPDATE public.goodsreceived SET updated_at = t WHERE id = grn;
  RESET session_replication_role;
  RETURN t;
END $$;
-- save_grn as a caller (one-time pricing, free sender and supervisor given); one lot per mark, rack R1, R2, ... in order. Returns the GRN id.
CREATE FUNCTION pg_temp.lc_save(claims jsonb, gr_no text, cust uuid, item uuid, marks text[], qty int DEFAULT 10) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE r jsonb; gid uuid; items jsonb;
BEGIN
  SELECT jsonb_agg(jsonb_build_object('item_id', item, 'item_name', i.name, 'packaging', 'Bag', 'qty', qty, 'weight', 10,
      'rack', 'R' || m.n, 'package_mark', m.mark) ORDER BY m.n) INTO items
    FROM unnest(marks) WITH ORDINALITY AS m(mark, n) CROSS JOIN public.items i WHERE i.id = item;
  r := pg_temp.lc_as(claims, format('SELECT public.save_grn(p_sender_name => %L, p_supervisor_id => (SELECT id FROM public.user_profiles WHERE mobile = %L),'
    ' p_supervisor_name => %L, p_gr_no => %L, p_date => %L::timestamptz, p_customer_id => %L::uuid, p_customer_name => (SELECT name FROM public.customers WHERE id = %L::uuid),'
    ' p_pricing_mode => %L, p_idempotency_key => %L, p_items => %L::jsonb)',
    'Lot Change Sender', '919888884003', 'Lot Change Supervisor', gr_no, '2026-04-01T12:00:00Z', cust, cust, 'ONE_TIME', 'lc-grn-' || gr_no, items));
  PERFORM pg_temp.lc_assert(r->>'success' = 'true', 'fixture: save_grn ' || gr_no || ': ' || left(r::text, 300));
  SELECT id INTO gid FROM public.goodsreceived WHERE goodsreceived.gr_no = lc_save.gr_no;
  RETURN gid;
END $$;
-- The lines of a GRN as update_grn takes them back (every line as stored, rack and mark included).
CREATE FUNCTION pg_temp.lc_lines(grn uuid) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_agg(jsonb_build_object('id', t.id, 'item_id', t.item_id, 'item_name', t.item_name, 'packaging', t.packaging, 'qty', t.qty,
    'weight', t.weight, 'rack', t.rack, 'package_mark', t.package_mark) ORDER BY t.id) FROM public.goodsreceived_trl t WHERE t.gr_id = grn $$;
-- The same lines with one lot's rack replaced (an "Edit GRN" that carries an old or a new rack).
CREATE FUNCTION pg_temp.lc_lines_with_rack(grn uuid, lot uuid, rack text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_agg(CASE WHEN l->>'id' = lot::text THEN l || jsonb_build_object('rack', rack) ELSE l END ORDER BY l->>'id')
  FROM jsonb_array_elements(pg_temp.lc_lines(grn)) l $$;
-- update_grn as a caller with these lines and an optional edit token.
CREATE FUNCTION pg_temp.lc_edit(claims jsonb, grn uuid, lines jsonb, token timestamptz DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.lc_as(claims, format('SELECT public.update_grn(p_grn_id => %L::uuid, p_items => %L::jsonb, p_expected_updated_at => %L::timestamptz)', grn, lines, token)) $$;

-- ===== people and the catalogue =====
INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST'
 WHERE id = (SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888884001', 'Lot Change Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id = :'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888884002', 'Lot Change Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888884003', 'Lot Change Supervisor', 'supervisor', true, 'approved'),
 (gen_random_uuid(), '919888884004', 'Lot Change Customer User', 'customer', true, 'approved');
SELECT id AS staff_profile FROM public.user_profiles WHERE mobile = '919888884002' \gset
SELECT id AS supervisor_profile FROM public.user_profiles WHERE mobile = '919888884003' \gset
SELECT pg_temp.lc_login('9888884001') AS admin_claims \gset
SELECT pg_temp.lc_login('9888884002') AS staff_claims \gset
SELECT pg_temp.lc_login('9888884003') AS supervisor_claims \gset
SELECT pg_temp.lc_login('9888884004') AS customer_claims \gset
SELECT pg_temp.lc_assert(pg_temp.lc_as(:'admin_claims'::jsonb, $q$SELECT public.create_customer('Lot Change Traders', '9888884011')$q$)->>'success' = 'true', 'customer');
SELECT pg_temp.lc_assert(pg_temp.lc_as(:'admin_claims'::jsonb, $q$SELECT public.create_customer('Lot Change Dormant', '9888884012')$q$)->>'success' = 'true', 'second customer');
SELECT pg_temp.lc_assert(pg_temp.lc_as(:'admin_claims'::jsonb, $q$SELECT public.create_item('Lot Change Cumin', 'Bag')$q$)->>'success' = 'true', 'item');
SELECT id AS cust FROM public.customers WHERE name = 'Lot Change Traders' \gset
SELECT id AS dormant FROM public.customers WHERE name = 'Lot Change Dormant' \gset
SELECT id AS item_id FROM public.items WHERE name = 'Lot Change Cumin' \gset
INSERT INTO public.users_customers_new(user_profile_id, customer_id, active) SELECT id, :'cust'::uuid, true FROM public.user_profiles WHERE mobile = '919888884004';
SELECT pg_temp.lc_assert(pg_temp.lc_as(:'admin_claims'::jsonb, format($q$SELECT public.replace_item_rates(%L::uuid, %L::uuid, 'monthly', '2026-01-01'::date,
  '[{"weight_min":0,"weight_max":100,"unit_price":5,"labour_rate":2,"tax_percent":5}]'::jsonb)$q$, :'item_id', :'cust'))->>'success' = 'true', 'rates for billing');

-- The first GRN: three lots M1, M2, M3 on racks R1, R2, R3.
SELECT pg_temp.lc_save(:'admin_claims'::jsonb, 'LC1', :'cust'::uuid, :'item_id'::uuid, ARRAY['M1', 'M2', 'M3']) AS grn1 \gset
SELECT id AS lot1 FROM public.goodsreceived_trl WHERE gr_id = :'grn1' AND package_mark = 'M1' \gset
SELECT id AS lot2 FROM public.goodsreceived_trl WHERE gr_id = :'grn1' AND package_mark = 'M2' \gset
SELECT id AS lot3 FROM public.goodsreceived_trl WHERE gr_id = :'grn1' AND package_mark = 'M3' \gset
SELECT pg_temp.lc_assert(pg_temp.lc_lot(:'lot1'::uuid) = '{"rack":"R1","package_mark":"M1"}', 'premise: lot 1 holds R1 and M1');

-- ===== B1. Staff, supervisor and administrator each change a rack; a customer account is refused by the gate =====
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot1'::uuid, '{"rack":{"to":"A-1","from":"R1"}}', 'lc-b1-admin') AS b1_admin \gset
SELECT pg_temp.lc_call(:'supervisor_claims'::jsonb, :'lot2'::uuid, '{"rack":{"to":"S-2","from":"R2"}}', 'lc-b1-supervisor') AS b1_sup \gset
SELECT pg_temp.lc_call(:'staff_claims'::jsonb, :'lot3'::uuid, '{"rack":{"to":"T-3","from":"R3"}}', 'lc-b1-staff') AS b1_staff \gset
SELECT pg_temp.lc_assert(:'b1_admin'::jsonb->>'success' = 'true' AND :'b1_admin'::jsonb#>>'{lot,id}' = :'lot1' AND :'b1_admin'::jsonb#>>'{lot,gr_id}' = :'grn1'
  AND :'b1_admin'::jsonb#>>'{lot,rack}' = 'A-1' AND :'b1_admin'::jsonb#>>'{lot,package_mark}' = 'M1' AND :'b1_admin'::jsonb#>>'{grn,gr_no}' = 'LC1'
  AND :'b1_admin'::jsonb->'changed' = '["rack"]'::jsonb AND :'b1_admin'::jsonb->'replaced' = '[]'::jsonb AND NOT :'b1_admin'::jsonb ? 'idempotent',
  'B1: an administrator changes a rack and the answer carries the lot, the GRN, changed and replaced: ' || :'b1_admin');
SELECT pg_temp.lc_assert(pg_temp.lc_lot(:'lot1'::uuid) = '{"rack":"A-1","package_mark":"M1"}', 'B1: the administrator''s rack is stored');
SELECT pg_temp.lc_assert(:'b1_sup'::jsonb->>'success' = 'true' AND pg_temp.lc_lot(:'lot2'::uuid) = '{"rack":"S-2","package_mark":"M2"}',
  'B1: a supervisor changes a rack: ' || :'b1_sup');
SELECT pg_temp.lc_assert(:'b1_staff'::jsonb->>'success' = 'true' AND pg_temp.lc_lot(:'lot3'::uuid) = '{"rack":"T-3","package_mark":"M3"}',
  'B1: staff change a rack: ' || :'b1_staff');
SELECT pg_temp.lc_world(:'grn1'::uuid) AS b1_world \gset
SELECT pg_temp.lc_call(:'customer_claims'::jsonb, :'lot1'::uuid, '{"rack":{"to":"C-9","from":"A-1"}}', 'lc-b1-customer') AS b1_customer \gset
SELECT pg_temp.lc_assert(:'b1_customer'::jsonb->>'state' = '42501', 'B1: a customer account is refused by the gate (42501): ' || :'b1_customer');
SELECT pg_temp.lc_assert(pg_temp.lc_world(:'grn1'::uuid) = :'b1_world'::jsonb, 'B1: the refused customer wrote nothing');
-- A call with no session at all is refused too.
SELECT pg_temp.lc_assert(NOT has_function_privilege('anon', 'public.set_lot_rack_and_mark(uuid, jsonb, text)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.set_lot_rack_and_mark(uuid, jsonb, text)', 'EXECUTE'),
  'B1: the function is granted to signed-in users and not to anon');

-- ===== B2. Trim, Gujarati digits to 0-9, blank to NULL; the limits after normalising =====
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot1'::uuid, '{"rack":{"to":"   B-2   ","from":"A-1"}}', 'lc-b2-trim') AS b2_trim \gset
SELECT pg_temp.lc_assert(:'b2_trim'::jsonb->>'success' = 'true' AND pg_temp.lc_lot(:'lot1'::uuid) = '{"rack":"B-2","package_mark":"M1"}'
  AND :'b2_trim'::jsonb#>>'{lot,rack}' = 'B-2', 'B2: a padded rack is stored trimmed and answered trimmed: ' || :'b2_trim');
SELECT jsonb_build_object('rack', jsonb_build_object('to', U&'C-\0AE7\0AE8', 'from', 'B-2'),
                          'package_mark', jsonb_build_object('to', U&'G\0AE9 \0AEA', 'from', 'M1'))::text AS b2_guj_body \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot1'::uuid, :'b2_guj_body'::jsonb, 'lc-b2-gujarati') AS b2_guj \gset
SELECT pg_temp.lc_assert(:'b2_guj'::jsonb->>'success' = 'true' AND pg_temp.lc_lot(:'lot1'::uuid) = '{"rack":"C-12","package_mark":"G3 4"}',
  'B2: Gujarati digits are stored as 0-9 in rack and mark: ' || pg_temp.lc_lot(:'lot1'::uuid)::text);
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot1'::uuid, '{"package_mark":{"to":"     ","from":"G3 4"}}', 'lc-b2-blank') AS b2_blank \gset
SELECT pg_temp.lc_assert(:'b2_blank'::jsonb->>'success' = 'true' AND (SELECT package_mark IS NULL AND rack = 'C-12' FROM public.goodsreceived_trl WHERE id = :'lot1'::uuid)
  AND :'b2_blank'::jsonb#>'{lot,package_mark}' = 'null'::jsonb, 'B2: a blank mark is stored as NULL and the rack is untouched: ' || :'b2_blank');
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot1'::uuid, '{"rack":{"to":null,"from":"C-12"}}', 'lc-b2-null') AS b2_null \gset
SELECT pg_temp.lc_assert(:'b2_null'::jsonb->>'success' = 'true' AND (SELECT rack IS NULL FROM public.goodsreceived_trl WHERE id = :'lot1'::uuid), 'B2: a null rack clears it');
-- Exactly at the limits (after normalising, the padding does not count): 30 and 60.
SELECT jsonb_build_object('rack', jsonb_build_object('to', repeat('r', 30) || '   ', 'from', NULL),
                          'package_mark', jsonb_build_object('to', repeat('m', 60), 'from', NULL))::text AS b2_edge_body \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot1'::uuid, :'b2_edge_body'::jsonb, 'lc-b2-edge') AS b2_edge \gset
SELECT pg_temp.lc_assert(:'b2_edge'::jsonb->>'success' = 'true' AND (SELECT rack = repeat('r', 30) AND package_mark = repeat('m', 60)
  FROM public.goodsreceived_trl WHERE id = :'lot1'::uuid), 'B2: 30 characters of rack and 60 of mark are accepted: ' || :'b2_edge');
SELECT pg_temp.lc_world(:'grn1'::uuid) AS b2_world \gset
SELECT jsonb_build_object('rack', jsonb_build_object('to', repeat('r', 31), 'from', repeat('r', 30)))::text AS b2_rack31 \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot1'::uuid, :'b2_rack31'::jsonb, 'lc-b2-rack31') AS b2_long_rack \gset
SELECT pg_temp.lc_assert(:'b2_long_rack'::jsonb->>'success' = 'false' AND :'b2_long_rack'::jsonb->>'reason' = 'RACK_TOO_LONG'
  AND :'b2_long_rack'::jsonb->>'error_code' = 'WH409' AND (:'b2_long_rack'::jsonb->>'limit')::int = 30, 'B2: 31 characters of rack are refused by code with the limit: ' || :'b2_long_rack');
SELECT jsonb_build_object('package_mark', jsonb_build_object('to', repeat('m', 61), 'from', repeat('m', 60)))::text AS b2_mark61 \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot1'::uuid, :'b2_mark61'::jsonb, 'lc-b2-mark61') AS b2_long_mark \gset
SELECT pg_temp.lc_assert(:'b2_long_mark'::jsonb->>'success' = 'false' AND :'b2_long_mark'::jsonb->>'reason' = 'MARK_TOO_LONG'
  AND (:'b2_long_mark'::jsonb->>'limit')::int = 60, 'B2: 61 characters of mark are refused by code with the limit: ' || :'b2_long_mark');
-- A good rack sent with a too long mark: neither is written.
SELECT jsonb_build_object('rack', jsonb_build_object('to', 'GOOD-1', 'from', repeat('r', 30)),
                          'package_mark', jsonb_build_object('to', repeat('m', 61), 'from', repeat('m', 60)))::text AS b2_mixed \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot1'::uuid, :'b2_mixed'::jsonb, 'lc-b2-mixed') AS b2_mixed_answer \gset
SELECT pg_temp.lc_assert(:'b2_mixed_answer'::jsonb->>'reason' = 'MARK_TOO_LONG' AND pg_temp.lc_world(:'grn1'::uuid) = :'b2_world'::jsonb,
  'B2: a refusal writes nothing, not even the valid field: ' || :'b2_mixed_answer');
-- Invalid bodies: nothing, an unknown key (alone or beside a valid one), no request key.
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot1'::uuid, '{}', 'lc-b2-empty') AS b2_empty \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot1'::uuid, '{"qty":{"to":"1","from":"2"}}', 'lc-b2-unknown') AS b2_unknown \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot1'::uuid, '{"rack":{"to":"GOOD-2","from":null},"stock":{"to":"0","from":"10"}}', 'lc-b2-beside') AS b2_beside \gset
SELECT pg_temp.lc_assert(:'b2_empty'::jsonb->>'reason' = 'LOT_CHANGE_INVALID' AND :'b2_unknown'::jsonb->>'reason' = 'LOT_CHANGE_INVALID'
  AND :'b2_beside'::jsonb->>'reason' = 'LOT_CHANGE_INVALID' AND pg_temp.lc_world(:'grn1'::uuid) = :'b2_world'::jsonb,
  'B2: no key, an unknown key, or an unknown key beside a valid one is LOT_CHANGE_INVALID and writes nothing: ' || :'b2_empty' || :'b2_unknown' || :'b2_beside');
SELECT pg_temp.lc_as(:'admin_claims'::jsonb, format('SELECT public.set_lot_rack_and_mark(%L::uuid, %L::jsonb, NULL)', :'lot1', '{"rack":{"to":"NOKEY","from":null}}')) AS b2_nokey \gset
SELECT pg_temp.lc_assert(COALESCE(:'b2_nokey'::jsonb->>'success', 'false') <> 'true' AND pg_temp.lc_world(:'grn1'::uuid) = :'b2_world'::jsonb,
  'B2: a call without a request key is refused and writes nothing: ' || :'b2_nokey');
-- Phone time (contract section 2.1, revised 2026-11-26): recorded_at beside a field is accepted and is no field (nothing of the lot but the
-- sent field is written); alone, or not a time, it is LOT_CHANGE_INVALID.
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot1'::uuid, '{"rack":{"to":"REC-1","from":null},"recorded_at":"2026-04-01T10:00:00Z"}', 'lc-b2-recorded') AS b2_recorded \gset
SELECT pg_temp.lc_assert(:'b2_recorded'::jsonb->>'success' = 'true' AND :'b2_recorded'::jsonb->'changed' = '["rack"]'::jsonb
  AND pg_temp.lc_lot(:'lot1'::uuid) = jsonb_build_object('rack', 'REC-1', 'package_mark', repeat('m', 60)),
  'B2: recorded_at beside a field is accepted, is not written to the lot and is not a changed field: ' || :'b2_recorded');
SELECT pg_temp.lc_world(:'grn1'::uuid) AS b2_rec_world \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot1'::uuid, '{"recorded_at":"2026-04-01T10:00:00Z"}', 'lc-b2-recorded-alone') AS b2_rec_alone \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot1'::uuid, '{"rack":{"to":"REC-2","from":"REC-1"},"recorded_at":"not a time"}', 'lc-b2-recorded-text') AS b2_rec_text \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot1'::uuid, '{"rack":{"to":"REC-2","from":"REC-1"},"recorded_at":5}', 'lc-b2-recorded-number') AS b2_rec_number \gset
SELECT pg_temp.lc_assert(:'b2_rec_alone'::jsonb->>'reason' = 'LOT_CHANGE_INVALID' AND :'b2_rec_text'::jsonb->>'reason' = 'LOT_CHANGE_INVALID'
  AND :'b2_rec_number'::jsonb->>'reason' = 'LOT_CHANGE_INVALID' AND pg_temp.lc_world(:'grn1'::uuid) = :'b2_rec_world'::jsonb,
  'B2: recorded_at alone, or a value that is not a timestamp, is LOT_CHANGE_INVALID and writes nothing: ' || :'b2_rec_alone' || :'b2_rec_text' || :'b2_rec_number');
-- Back to known values for the next sections.
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot1'::uuid, '{"rack":{"to":"R1","from":null},"package_mark":{"to":"M1","from":null}}', 'lc-b2-reset') AS b2_reset \gset
SELECT pg_temp.lc_assert(pg_temp.lc_lot(:'lot1'::uuid) = '{"rack":"R1","package_mark":"M1"}', 'premise: lot 1 is back to R1 and M1');

-- ===== B3. Only the keys sent are written; nothing else of the lot, its neighbours or the GRN changes =====
SELECT pg_temp.lc_lot(:'lot2'::uuid) AS lot2_before \gset
SELECT pg_temp.lc_age(:'grn1'::uuid) AS b3_token \gset
SELECT to_jsonb(t) - 'rack' - 'package_mark' AS lot2_rest FROM public.goodsreceived_trl t WHERE t.id = :'lot2' \gset
SELECT to_jsonb(t) AS lot1_row FROM public.goodsreceived_trl t WHERE t.id = :'lot1' \gset
SELECT to_jsonb(t) AS lot3_row FROM public.goodsreceived_trl t WHERE t.id = :'lot3' \gset
SELECT to_jsonb(g) - 'updated_at' - 'updated_by' AS grn_rest FROM public.goodsreceived g WHERE g.id = :'grn1' \gset
SELECT (SELECT count(*) FROM public.grn_images) AS images_before, (SELECT count(*) FROM public.grn_rates) AS rates_before,
       (SELECT count(*) FROM public.stock_movements) AS movements_before, (SELECT count(*) FROM public.goodsreceived_trl) AS lots_before \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot2'::uuid, '{"rack":{"to":"ONLY-RACK","from":"S-2"}}', 'lc-b3-rack') AS b3_rack \gset
SELECT pg_temp.lc_assert(:'b3_rack'::jsonb->>'success' = 'true' AND :'b3_rack'::jsonb->'changed' = '["rack"]'::jsonb,
  'B3: a rack-only change reports only the rack: ' || :'b3_rack');
SELECT pg_temp.lc_assert((SELECT package_mark = :'lot2_before'::jsonb->>'package_mark' AND rack = 'ONLY-RACK' FROM public.goodsreceived_trl WHERE id = :'lot2'::uuid),
  'B3: a rack-only change leaves the mark as stored');
SELECT pg_temp.lc_assert((SELECT to_jsonb(t) - 'rack' - 'package_mark' FROM public.goodsreceived_trl t WHERE t.id = :'lot2') = :'lot2_rest'::jsonb,
  'B3: no other column of the changed lot is written');
SELECT pg_temp.lc_assert((SELECT to_jsonb(t) FROM public.goodsreceived_trl t WHERE t.id = :'lot1') = :'lot1_row'::jsonb
  AND (SELECT to_jsonb(t) FROM public.goodsreceived_trl t WHERE t.id = :'lot3') = :'lot3_row'::jsonb, 'B3: the other lots of the GRN are byte for byte as they were');
SELECT pg_temp.lc_assert((SELECT to_jsonb(g) - 'updated_at' - 'updated_by' FROM public.goodsreceived g WHERE g.id = :'grn1') = :'grn_rest'::jsonb,
  'B3: the GRN row (sender, supervisor, customer, note, flags, rates mode) is unchanged apart from its change mark');
SELECT pg_temp.lc_assert((SELECT count(*) FROM public.grn_images) = :'images_before'::bigint AND (SELECT count(*) FROM public.grn_rates) = :'rates_before'::bigint
  AND (SELECT count(*) FROM public.stock_movements) = :'movements_before'::bigint AND (SELECT count(*) FROM public.goodsreceived_trl) = :'lots_before'::bigint,
  'B3: photos, rates, stock movements and lots are not added or removed');
SELECT pg_temp.lc_assert((SELECT updated_by = :'admin_profile'::uuid AND updated_at > :'b3_token'::timestamptz FROM public.goodsreceived WHERE id = :'grn1'),
  'B3: the GRN''s change mark and author are the only GRN columns written');
-- A mark-only change leaves the rack.
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot2'::uuid, '{"package_mark":{"to":"ONLY-MARK","from":"M2"}}', 'lc-b3-mark') AS b3_mark \gset
SELECT pg_temp.lc_assert(:'b3_mark'::jsonb->'changed' = '["package_mark"]'::jsonb AND pg_temp.lc_lot(:'lot2'::uuid) = '{"rack":"ONLY-RACK","package_mark":"ONLY-MARK"}',
  'B3: a mark-only change leaves the rack: ' || :'b3_mark');
-- Both at once report both fields.
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot2'::uuid, '{"rack":{"to":"BOTH-R","from":"ONLY-RACK"},"package_mark":{"to":"BOTH-M","from":"ONLY-MARK"}}', 'lc-b3-both') AS b3_both \gset
SELECT pg_temp.lc_assert(jsonb_array_length(:'b3_both'::jsonb->'changed') = 2 AND :'b3_both'::jsonb->'changed' @> '["rack","package_mark"]'::jsonb
  AND pg_temp.lc_lot(:'lot2'::uuid) = '{"rack":"BOTH-R","package_mark":"BOTH-M"}', 'B3: two fields at once are both written and both reported: ' || :'b3_both');

-- ===== B4. A dispatched, a billed and an on-order lot are accepted; an issued invoice keeps its marking =====
-- Dispatched in full.
SELECT pg_temp.lc_save(:'admin_claims'::jsonb, 'LC2', :'cust'::uuid, :'item_id'::uuid, ARRAY['D1'], 20) AS grn_d \gset
SELECT id AS lot_d FROM public.goodsreceived_trl WHERE gr_id = :'grn_d' \gset
SELECT pg_temp.lc_assert(pg_temp.lc_as(:'admin_claims'::jsonb, format($q$SELECT public.create_dispatch_with_stock_check(%L::jsonb, ARRAY[%L::jsonb], 0, 'lc-dispatch-1')$q$,
  jsonb_build_object('customer_id', :'cust', 'customer_name', 'Lot Change Traders', 'supervisor_id', :'admin_profile', 'supervisor_name', 'Lot Change Administrator',
    'disp_date', '2026-05-02', 'disp_no', 'LCD1'), jsonb_build_object('gr_trl_id', :'lot_d', 'disp_qty', 20)))->>'success' = 'true', 'fixture: dispatch LCD1');
SELECT pg_temp.lc_assert((SELECT stock = 0 FROM public.goodsreceived_trl WHERE id = :'lot_d'::uuid), 'premise: the lot is dispatched in full');
SELECT pg_temp.lc_call(:'staff_claims'::jsonb, :'lot_d'::uuid, '{"rack":{"to":"OUT-1","from":"R1"}}', 'lc-b4-dispatched') AS b4_disp \gset
SELECT pg_temp.lc_assert(:'b4_disp'::jsonb->>'success' = 'true' AND pg_temp.lc_lot(:'lot_d'::uuid)->>'rack' = 'OUT-1'
  AND (SELECT stock = 0 FROM public.goodsreceived_trl WHERE id = :'lot_d'::uuid), 'B4: a fully dispatched lot accepts the change and keeps its stock: ' || :'b4_disp');
-- Dispatched and billed: the invoice of WH-308 keeps what it was issued with; the lot takes the new values.
SELECT pg_temp.lc_save(:'admin_claims'::jsonb, 'LC3', :'cust'::uuid, :'item_id'::uuid, ARRAY['AB-12'], 20) AS grn_b \gset
SELECT id AS lot_b FROM public.goodsreceived_trl WHERE gr_id = :'grn_b' \gset
SELECT pg_temp.lc_assert(pg_temp.lc_as(:'admin_claims'::jsonb, format($q$SELECT public.create_dispatch_with_stock_check(%L::jsonb, ARRAY[%L::jsonb], 0, 'lc-dispatch-2')$q$,
  jsonb_build_object('customer_id', :'cust', 'customer_name', 'Lot Change Traders', 'supervisor_id', :'admin_profile', 'supervisor_name', 'Lot Change Administrator',
    'disp_date', '2026-05-02', 'disp_no', 'LCD2'), jsonb_build_object('gr_trl_id', :'lot_b', 'disp_qty', 20)))->>'success' = 'true', 'fixture: dispatch LCD2');
SELECT pg_temp.lc_assert(pg_temp.lc_as(:'staff_claims'::jsonb, format($q$SELECT public.save_invoice(NULL::uuid, %L::jsonb, ARRAY(SELECT jsonb_build_object('disp_trl_id', t.id,
  'grn_item_id', t.gr_trl_id, 'duration', 1, 'charge', 5, 'tax', 5, 'labour_rate', 2) FROM public.dispatch_trl t WHERE t.gr_id = %L::uuid))$q$,
  jsonb_build_object('inv_fin_year', 2026, 'inv_no', 32, 'customer_id', :'cust', 'customer_name', 'Lot Change Traders', 'inv_date', '2026-05-02T12:00:00Z',
    'total', 0, 'tax_amount', 0, 'labour', 0, 'discount', 0, 'duration_mode', 'legacy', 'gr_id', :'grn_b', 'gr_no', 'LC3'), :'grn_b'))->>'success' = 'true', 'fixture: invoice 32');
SELECT id AS inv_b FROM public.invoice WHERE inv_no = 32 AND inv_fin_year = 2026 \gset
SELECT pg_temp.lc_assert((SELECT invoiced FROM public.goodsreceived WHERE id = :'grn_b'::uuid), 'premise: the GRN is billed');
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_b'::uuid, '{"rack":{"to":"R9","from":"R1"},"package_mark":{"to":"AB-15","from":"AB-12"}}', 'lc-b4-billed') AS b4_billed \gset
SELECT pg_temp.lc_assert(:'b4_billed'::jsonb->>'success' = 'true' AND pg_temp.lc_lot(:'lot_b'::uuid) = '{"rack":"R9","package_mark":"AB-15"}',
  'B4: a billed lot accepts the change: ' || :'b4_billed');
SELECT pg_temp.lc_as(:'staff_claims'::jsonb, format('SELECT public.get_invoice_detail(%L::uuid)', :'inv_b')) AS b4_detail \gset
SELECT pg_temp.lc_assert(:'b4_detail'::jsonb#>>'{items,0,package_mark}' = 'AB-12' AND :'b4_detail'::jsonb#>>'{items,0,rack}' = 'R1',
  'B4: the issued invoice still shows the rack and marking it was issued with (topic "invoice keeps issued marking"): ' || :'b4_detail');
-- On an open order.
SELECT pg_temp.lc_save(:'admin_claims'::jsonb, 'LC4', :'cust'::uuid, :'item_id'::uuid, ARRAY['O1'], 20) AS grn_o \gset
SELECT id AS lot_o FROM public.goodsreceived_trl WHERE gr_id = :'grn_o' \gset
SELECT pg_temp.lc_as(:'admin_claims'::jsonb, format('SELECT to_jsonb(public.get_or_create_cart(%L::uuid))', :'cust')) #>> '{}' AS cart \gset
SELECT pg_temp.lc_assert(pg_temp.lc_as(:'admin_claims'::jsonb, format('SELECT public.add_item_to_order(%L::uuid, %L::uuid, 5)', :'cart', :'lot_o'))->>'success' = 'true', 'fixture: the lot is on an order');
SELECT pg_temp.lc_call(:'staff_claims'::jsonb, :'lot_o'::uuid, '{"rack":{"to":"ORD-1","from":"R1"}}', 'lc-b4-order') AS b4_order \gset
SELECT pg_temp.lc_assert(:'b4_order'::jsonb->>'success' = 'true' AND pg_temp.lc_lot(:'lot_o'::uuid)->>'rack' = 'ORD-1'
  AND (SELECT count(*) = 1 FROM public.order_items WHERE order_id = :'cart'::uuid), 'B4: a lot on an order accepts the change and stays on it: ' || :'b4_order');
-- B14 (PQ5): the lots of a deactivated customer are accepted for the three roles (the function does not copy update_grn's gate).
SELECT pg_temp.lc_save(:'admin_claims'::jsonb, 'LC5', :'dormant'::uuid, :'item_id'::uuid, ARRAY['Q1', 'Q2', 'Q3']) AS grn_q \gset
SELECT id AS lot_q1 FROM public.goodsreceived_trl WHERE gr_id = :'grn_q' AND package_mark = 'Q1' \gset
SELECT id AS lot_q2 FROM public.goodsreceived_trl WHERE gr_id = :'grn_q' AND package_mark = 'Q2' \gset
SELECT id AS lot_q3 FROM public.goodsreceived_trl WHERE gr_id = :'grn_q' AND package_mark = 'Q3' \gset
UPDATE public.customers SET active = false WHERE id = :'dormant'::uuid;
SELECT pg_temp.lc_call(:'staff_claims'::jsonb, :'lot_q1'::uuid, '{"rack":{"to":"MOVED-1","from":"R1"}}', 'lc-b14-staff') AS b14_staff \gset
SELECT pg_temp.lc_call(:'supervisor_claims'::jsonb, :'lot_q2'::uuid, '{"rack":{"to":"MOVED-2","from":"R2"},"package_mark":{"to":"MM-2","from":"Q2"}}', 'lc-b14-supervisor') AS b14_sup \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_q3'::uuid, '{"rack":{"to":"MOVED-3","from":"R3"}}', 'lc-b14-admin') AS b14_admin \gset
SELECT pg_temp.lc_assert((SELECT NOT active FROM public.customers WHERE id = :'dormant'::uuid), 'B14 premise: the customer is still deactivated');
SELECT pg_temp.lc_assert(:'b14_staff'::jsonb->>'success' = 'true' AND pg_temp.lc_lot(:'lot_q1'::uuid)->>'rack' = 'MOVED-1',
  'B14: staff change a lot of a deactivated customer: ' || :'b14_staff');
SELECT pg_temp.lc_assert(:'b14_sup'::jsonb->>'success' = 'true' AND pg_temp.lc_lot(:'lot_q2'::uuid) = '{"rack":"MOVED-2","package_mark":"MM-2"}',
  'B14: a supervisor changes a lot of a deactivated customer: ' || :'b14_sup');
SELECT pg_temp.lc_assert(:'b14_admin'::jsonb->>'success' = 'true' AND pg_temp.lc_lot(:'lot_q3'::uuid)->>'rack' = 'MOVED-3',
  'B14: an administrator changes a lot of a deactivated customer: ' || :'b14_admin');

-- ===== B5. An imported lot accepts rack and mark through this function only =====
INSERT INTO warehouse_security.import_batches(applied_at) VALUES (now()) RETURNING id AS batch \gset
SELECT gen_random_uuid() AS grn_i, gen_random_uuid() AS lot_i \gset
SET LOCAL session_replication_role = replica;
INSERT INTO public.goodsreceived(id, gr_no, date, customer_id, customer_name, invoiced, pricing_mode, import_batch_id, sender_name, supervisor_name)
  VALUES (:'grn_i', 'LCI1', '2025-04-02T10:00:00Z', :'cust', 'Lot Change Traders', false, 'MONTHLY', :'batch', 'Lot Change Sender', 'Lot Change Supervisor');
INSERT INTO public.goodsreceived_trl(id, gr_id, item_id, item_name, packaging, qty, weight, stock, rack, package_mark)
  VALUES (:'lot_i', :'grn_i', :'item_id', 'Lot Change Cumin', 'Bag', 40, 10, 25, 'IR1', 'IM1');
RESET session_replication_role;
-- Premise: the guard holds. An edit through update_grn and a direct write are refused today, as the topic "imported read only" says.
SELECT pg_temp.lc_edit(:'admin_claims'::jsonb, :'grn_i'::uuid, pg_temp.lc_lines_with_rack(:'grn_i'::uuid, :'lot_i'::uuid, 'VIA-EDIT')) AS b5_edit \gset
SELECT pg_temp.lc_assert(:'b5_edit'::jsonb->>'reason' = 'IMPORTED_READ_ONLY', 'B5 premise: update_grn still refuses a rack change on an imported GRN: ' || :'b5_edit');
SELECT pg_temp.lc_assert(pg_temp.lc_raises(format('UPDATE public.goodsreceived_trl SET rack = %L WHERE id = %L::uuid', 'DIRECT', :'lot_i'), 'WH423'),
  'B5 premise: a direct table write of the rack is refused');
SELECT pg_temp.lc_world(:'grn_i'::uuid) AS b5_world \gset
SELECT pg_temp.lc_age(:'grn_i'::uuid) AS b5_token \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_i'::uuid, '{"rack":{"to":"IR2","from":"IR1"},"package_mark":{"to":"IM2","from":"IM1"}}', 'lc-b5-admin') AS b5_admin \gset
SELECT pg_temp.lc_assert(:'b5_admin'::jsonb->>'success' = 'true' AND pg_temp.lc_lot(:'lot_i'::uuid) = '{"rack":"IR2","package_mark":"IM2"}',
  'B5: the function changes rack and mark of an imported lot: ' || :'b5_admin');
SELECT pg_temp.lc_call(:'staff_claims'::jsonb, :'lot_i'::uuid, '{"rack":{"to":"IR3","from":"IR2"}}', 'lc-b5-staff') AS b5_staff \gset
SELECT pg_temp.lc_assert(:'b5_staff'::jsonb->>'success' = 'true' AND pg_temp.lc_lot(:'lot_i'::uuid)->>'rack' = 'IR3', 'B5: staff change an imported lot too: ' || :'b5_staff');
-- Nothing else of the imported GRN or lot moved; its change mark did.
SELECT pg_temp.lc_assert((pg_temp.lc_world(:'grn_i'::uuid) #- '{grn,updated_at}' #- '{grn,updated_by}' #- '{lots,0,rack}' #- '{lots,0,package_mark}')
  = (:'b5_world'::jsonb #- '{grn,updated_at}' #- '{grn,updated_by}' #- '{lots,0,rack}' #- '{lots,0,package_mark}'),
  'B5: nothing of the imported GRN or lot is written beyond rack, mark and the GRN change mark');
SELECT pg_temp.lc_assert((SELECT updated_at > :'b5_token'::timestamptz FROM public.goodsreceived WHERE id = :'grn_i'::uuid), 'B5: the imported GRN''s change mark moved');
-- The exemption does not outlive the call: the same transaction, no function, is refused again for rack, mark and any other column.
SELECT pg_temp.lc_assert(pg_temp.lc_raises(format('UPDATE public.goodsreceived_trl SET rack = %L WHERE id = %L::uuid', 'AFTER-R', :'lot_i'), 'WH423'),
  'B5: after the call a direct write of the rack is refused again');
SELECT pg_temp.lc_assert(pg_temp.lc_raises(format('UPDATE public.goodsreceived_trl SET package_mark = %L WHERE id = %L::uuid', 'AFTER-M', :'lot_i'), 'WH423'),
  'B5: after the call a direct write of the mark is refused again');
SELECT pg_temp.lc_assert(pg_temp.lc_raises(format('UPDATE public.goodsreceived_trl SET qty = qty + 1 WHERE id = %L::uuid', :'lot_i'), 'WH423'),
  'B5: after the call any other column of the imported line is still refused (the guard was opened for rack and mark only)');
SELECT pg_temp.lc_assert(pg_temp.lc_raises(format('UPDATE public.goodsreceived SET note = %L WHERE id = %L::uuid', 'AFTER-N', :'grn_i'), 'WH423'),
  'B5: after the call another column of the imported GRN is still refused');
SELECT pg_temp.lc_assert(pg_temp.lc_raises(format('DELETE FROM public.goodsreceived_trl WHERE id = %L::uuid', :'lot_i'), 'WH423'),
  'B5: after the call the imported line still cannot be deleted');
-- update_grn after the call: still the imported refusal.
SELECT pg_temp.lc_edit(:'admin_claims'::jsonb, :'grn_i'::uuid, pg_temp.lc_lines_with_rack(:'grn_i'::uuid, :'lot_i'::uuid, 'VIA-EDIT-2')) AS b5_edit2 \gset
SELECT pg_temp.lc_assert(:'b5_edit2'::jsonb->>'reason' = 'IMPORTED_READ_ONLY' AND pg_temp.lc_lot(:'lot_i'::uuid)->>'rack' = 'IR3',
  'B5: update_grn on the imported GRN is still refused after the call: ' || :'b5_edit2');
-- A normal lot is not affected by the imported path: the same direct write on LC1 is the guard-free path, so only the imported rule is tested above.

-- ===== B6. A GRN with a blank sender or supervisor is accepted, and stays as stored =====
SELECT pg_temp.lc_save(:'admin_claims'::jsonb, 'LC6', :'cust'::uuid, :'item_id'::uuid, ARRAY['N1']) AS grn_n \gset
SELECT id AS lot_n FROM public.goodsreceived_trl WHERE gr_id = :'grn_n' \gset
UPDATE public.goodsreceived SET sender_name = NULL, supervisor_id = NULL, supervisor_name = NULL WHERE id = :'grn_n'::uuid;
-- Premise: the edit path refuses this GRN (WH-248), so this function's acceptance is a real difference.
SELECT pg_temp.lc_edit(:'admin_claims'::jsonb, :'grn_n'::uuid, pg_temp.lc_lines_with_rack(:'grn_n'::uuid, :'lot_n'::uuid, 'VIA-EDIT')) AS b6_edit \gset
SELECT pg_temp.lc_assert(:'b6_edit'::jsonb->>'reason' IN ('SENDER_REQUIRED', 'SUPERVISOR_REQUIRED'), 'B6 premise: update_grn refuses a rack change on a GRN without sender and supervisor: ' || :'b6_edit');
SELECT pg_temp.lc_call(:'staff_claims'::jsonb, :'lot_n'::uuid, '{"rack":{"to":"BLANK-1","from":"R1"}}', 'lc-b6-blank') AS b6_blank \gset
SELECT pg_temp.lc_assert(:'b6_blank'::jsonb->>'success' = 'true' AND pg_temp.lc_lot(:'lot_n'::uuid)->>'rack' = 'BLANK-1'
  AND (SELECT sender_name IS NULL AND supervisor_id IS NULL AND supervisor_name IS NULL FROM public.goodsreceived WHERE id = :'grn_n'::uuid),
  'B6: a GRN with no sender and no supervisor accepts the change and keeps them empty: ' || :'b6_blank');
-- Half-filled: a supervisor name with no supervisor.
UPDATE public.goodsreceived SET sender_name = 'Lot Change Sender', supervisor_id = NULL, supervisor_name = 'Half Filled Name' WHERE id = :'grn_n'::uuid;
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_n'::uuid, '{"rack":{"to":"BLANK-2","from":"BLANK-1"}}', 'lc-b6-half') AS b6_half \gset
SELECT pg_temp.lc_assert(:'b6_half'::jsonb->>'success' = 'true' AND (SELECT supervisor_id IS NULL AND supervisor_name = 'Half Filled Name' AND sender_name = 'Lot Change Sender'
  FROM public.goodsreceived WHERE id = :'grn_n'::uuid), 'B6: a half-filled supervisor is accepted and left as stored: ' || :'b6_half');

-- ===== B7. A deleted lot or GRN is LOT_NOT_FOUND, nothing written =====
SELECT pg_temp.lc_save(:'admin_claims'::jsonb, 'LC7', :'cust'::uuid, :'item_id'::uuid, ARRAY['X1', 'X2']) AS grn_x \gset
SELECT id AS lot_x1 FROM public.goodsreceived_trl WHERE gr_id = :'grn_x' AND package_mark = 'X1' \gset
SELECT id AS lot_x2 FROM public.goodsreceived_trl WHERE gr_id = :'grn_x' AND package_mark = 'X2' \gset
SELECT pg_temp.lc_world(:'grn1'::uuid) AS b7_world \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, gen_random_uuid(), '{"rack":{"to":"NONE","from":null}}', 'lc-b7-unknown') AS b7_unknown \gset
SELECT pg_temp.lc_assert(:'b7_unknown'::jsonb->>'success' = 'false' AND :'b7_unknown'::jsonb->>'reason' = 'LOT_NOT_FOUND' AND pg_temp.lc_world(:'grn1'::uuid) = :'b7_world'::jsonb,
  'B7: a lot that never existed is LOT_NOT_FOUND: ' || :'b7_unknown');
SELECT pg_temp.lc_assert(pg_temp.lc_as(:'admin_claims'::jsonb, format('SELECT public.delete_grn_safe(%L::uuid)', :'grn_x'))->>'success' = 'true', 'fixture: the GRN is deleted');
SELECT (SELECT count(*) FROM public.goodsreceived_trl) AS lots_after_delete \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_x1'::uuid, '{"rack":{"to":"GONE","from":"R1"}}', 'lc-b7-deleted') AS b7_deleted \gset
SELECT pg_temp.lc_assert(:'b7_deleted'::jsonb->>'success' = 'false' AND :'b7_deleted'::jsonb->>'reason' = 'LOT_NOT_FOUND'
  AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE id = :'grn_x'::uuid) AND (SELECT count(*) FROM public.goodsreceived_trl) = :'lots_after_delete'::bigint,
  'B7: a lot of a deleted GRN is LOT_NOT_FOUND and nothing is created: ' || :'b7_deleted');
-- A GRN marked deleted (the soft delete the feed knows): its lot is gone for this function too, and keeps its rack.
SELECT pg_temp.lc_save(:'admin_claims'::jsonb, 'LC8', :'cust'::uuid, :'item_id'::uuid, ARRAY['Y1']) AS grn_y \gset
SELECT id AS lot_y FROM public.goodsreceived_trl WHERE gr_id = :'grn_y' \gset
SET LOCAL session_replication_role = replica;
UPDATE public.goodsreceived SET deleted_at = now() WHERE id = :'grn_y'::uuid;
RESET session_replication_role;
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_y'::uuid, '{"rack":{"to":"GONE","from":"R1"}}', 'lc-b7-soft') AS b7_soft \gset
SELECT pg_temp.lc_assert(:'b7_soft'::jsonb->>'reason' = 'LOT_NOT_FOUND' AND pg_temp.lc_lot(:'lot_y'::uuid)->>'rack' = 'R1',
  'B7: a lot of a soft-deleted GRN is LOT_NOT_FOUND and keeps its rack: ' || :'b7_soft');

-- ===== B8. Last sent wins, per field; "replaced" names what was put over =====
SELECT pg_temp.lc_save(:'admin_claims'::jsonb, 'LC9', :'cust'::uuid, :'item_id'::uuid, ARRAY['W1']) AS grn_w \gset
SELECT id AS lot_w FROM public.goodsreceived_trl WHERE gr_id = :'grn_w' \gset
-- stored = from: a plain change, nothing replaced.
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_w'::uuid, '{"rack":{"to":"S2","from":"R1"}}', 'lc-b8-plain') AS b8_plain \gset
SELECT pg_temp.lc_assert(:'b8_plain'::jsonb->>'success' = 'true' AND :'b8_plain'::jsonb->'replaced' = '[]'::jsonb, 'B8: stored equal to "from" replaces nothing: ' || :'b8_plain');
-- Someone else set S3 meanwhile; this phone, which saw S2, sends S4: written, and the answer names what it replaced.
SELECT pg_temp.lc_call(:'supervisor_claims'::jsonb, :'lot_w'::uuid, '{"rack":{"to":"S3","from":"S2"}}', 'lc-b8-other') AS b8_other \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_w'::uuid, '{"rack":{"to":"S4","from":"S2"}}', 'lc-b8-over') AS b8_over \gset
SELECT pg_temp.lc_assert(:'b8_over'::jsonb->>'success' = 'true' AND pg_temp.lc_lot(:'lot_w'::uuid)->>'rack' = 'S4' AND :'b8_over'::jsonb->'changed' = '["rack"]'::jsonb
  AND jsonb_array_length(:'b8_over'::jsonb->'replaced') = 1 AND :'b8_over'::jsonb#>>'{replaced,0,field}' = 'rack'
  AND :'b8_over'::jsonb#>>'{replaced,0,newer}' = 'S3' AND :'b8_over'::jsonb#>>'{replaced,0,sent}' = 'S4',
  'B8: stored differing from both "from" and "to": written, and replaced names the field, the newer value and the sent value: ' || :'b8_over');
-- Two fields, only the mark was replaced: the rack is not named.
SELECT pg_temp.lc_call(:'supervisor_claims'::jsonb, :'lot_w'::uuid, '{"package_mark":{"to":"MK-NEW","from":"W1"}}', 'lc-b8-other-mark') AS b8_other_mark \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_w'::uuid, '{"rack":{"to":"S5","from":"S4"},"package_mark":{"to":"MK-MINE","from":"W1"}}', 'lc-b8-two') AS b8_two \gset
SELECT pg_temp.lc_assert(:'b8_two'::jsonb->>'success' = 'true' AND pg_temp.lc_lot(:'lot_w'::uuid) = '{"rack":"S5","package_mark":"MK-MINE"}'
  AND jsonb_array_length(:'b8_two'::jsonb->'replaced') = 1 AND :'b8_two'::jsonb#>>'{replaced,0,field}' = 'package_mark'
  AND :'b8_two'::jsonb#>>'{replaced,0,newer}' = 'MK-NEW' AND :'b8_two'::jsonb#>>'{replaced,0,sent}' = 'MK-MINE',
  'B8: only the field that was put over another value is in replaced: ' || :'b8_two');
-- A stored NULL with a NULL "from" is no replacement.
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_w'::uuid, '{"package_mark":{"to":null,"from":"MK-MINE"}}', 'lc-b8-clear') AS b8_clear \gset
SELECT pg_temp.lc_call(:'staff_claims'::jsonb, :'lot_w'::uuid, '{"package_mark":{"to":"FROM-NULL","from":null}}', 'lc-b8-nullfrom') AS b8_nullfrom \gset
SELECT pg_temp.lc_assert(:'b8_nullfrom'::jsonb->>'success' = 'true' AND :'b8_nullfrom'::jsonb->'replaced' = '[]'::jsonb AND pg_temp.lc_lot(:'lot_w'::uuid)->>'package_mark' = 'FROM-NULL',
  'B8: a NULL stored value that matches a NULL "from" replaces nothing: ' || :'b8_nullfrom');
-- "to" equal to stored: nothing written, change mark not moved, nothing replaced (also when "from" is out of date).
SELECT pg_temp.lc_age(:'grn_w'::uuid) AS b8_token \gset
SELECT pg_temp.lc_world(:'grn_w'::uuid) AS b8_world \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_w'::uuid, '{"rack":{"to":"S5","from":"S5"}}', 'lc-b8-noop') AS b8_noop \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_w'::uuid, '{"rack":{"to":"S5","from":"OLD-SEEN"}}', 'lc-b8-noop-old') AS b8_noop_old \gset
SELECT pg_temp.lc_assert(:'b8_noop'::jsonb->>'success' = 'true' AND :'b8_noop'::jsonb->'changed' = '[]'::jsonb AND :'b8_noop'::jsonb->'replaced' = '[]'::jsonb
  AND :'b8_noop_old'::jsonb->>'success' = 'true' AND :'b8_noop_old'::jsonb->'changed' = '[]'::jsonb AND :'b8_noop_old'::jsonb->'replaced' = '[]'::jsonb,
  'B8: "to" equal to the stored value reports no change and no replacement: ' || :'b8_noop' || :'b8_noop_old');
SELECT pg_temp.lc_assert(pg_temp.lc_world(:'grn_w'::uuid) = :'b8_world'::jsonb AND (SELECT updated_at = :'b8_token'::timestamptz FROM public.goodsreceived WHERE id = :'grn_w'::uuid),
  'B8: a call that writes nothing does not move the GRN''s change mark');

-- WH-302 phone time: a call that sent no recorded_at records an entry with recorded_at NULL, in the answer and in the table.
SELECT pg_temp.lc_assert(:'b8_over'::jsonb#>'{replaced,0,recorded_at}' = 'null'::jsonb
  AND (SELECT r.recorded_at IS NULL AND r.sent_at = now() FROM warehouse_security.grn_replacements r WHERE r.id = (:'b8_over'::jsonb#>>'{replaced,0,id}')::uuid),
  'B8: an entry made by a call with no recorded_at carries recorded_at NULL and sent_at = the server time: ' || :'b8_over');
-- B8 (own value, PQ4): a value last set by the caller (from another phone) is replaced with no entry; the value is still written.
SELECT pg_temp.lc_save(:'admin_claims'::jsonb, 'LC13', :'cust'::uuid, :'item_id'::uuid, ARRAY['V1']) AS grn_v \gset
SELECT id AS lot_v FROM public.goodsreceived_trl WHERE gr_id = :'grn_v' \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_v'::uuid, '{"rack":{"to":"OWN-1","from":"R1"}}', 'lc-b8-own-1') AS b8_own_1 \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_v'::uuid, '{"rack":{"to":"OWN-2","from":"R1"}}', 'lc-b8-own-2') AS b8_own_2 \gset
SELECT pg_temp.lc_assert(:'b8_own_2'::jsonb->>'success' = 'true' AND pg_temp.lc_lot(:'lot_v'::uuid)->>'rack' = 'OWN-2' AND :'b8_own_2'::jsonb->'replaced' = '[]'::jsonb
  AND :'b8_own_2'::jsonb->'changed' = '["rack"]'::jsonb,
  'B8: a stored value the caller set themselves is replaced, written, and not listed in replaced: ' || :'b8_own_2');
-- The same situation with the value set by another person is listed (the contrast that makes the line above mean something).
SELECT pg_temp.lc_call(:'supervisor_claims'::jsonb, :'lot_v'::uuid, '{"rack":{"to":"THEIRS","from":"OWN-2"}}', 'lc-b8-theirs') AS b8_theirs \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_v'::uuid, '{"rack":{"to":"OWN-3","from":"OWN-2"}}', 'lc-b8-own-3') AS b8_own_3 \gset
SELECT pg_temp.lc_assert(jsonb_array_length(:'b8_own_3'::jsonb->'replaced') = 1 AND :'b8_own_3'::jsonb#>>'{replaced,0,newer}' = 'THEIRS',
  'B8: a stored value another person set is listed as replaced: ' || :'b8_own_3');
-- No field mark (a lot written with no trigger, as a row from before the marks): counts as someone else's.
SELECT gen_random_uuid() AS grn_nm, gen_random_uuid() AS lot_nm \gset
SET LOCAL session_replication_role = replica;
INSERT INTO public.goodsreceived(id, gr_no, date, customer_id, customer_name, invoiced, pricing_mode, sender_name, supervisor_name)
  VALUES (:'grn_nm', 'LC14', '2026-04-02T10:00:00Z', :'cust', 'Lot Change Traders', false, 'MONTHLY', 'Lot Change Sender', 'Lot Change Supervisor');
INSERT INTO public.goodsreceived_trl(id, gr_id, item_id, item_name, packaging, qty, weight, stock, rack, package_mark)
  VALUES (:'lot_nm', :'grn_nm', :'item_id', 'Lot Change Cumin', 'Bag', 5, 10, 5, 'NM1', 'NMK');
RESET session_replication_role;
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_nm'::uuid, '{"rack":{"to":"NM2","from":"OLD-SEEN"}}', 'lc-b8-nomark') AS b8_nomark \gset
SELECT pg_temp.lc_assert(:'b8_nomark'::jsonb->>'success' = 'true' AND jsonb_array_length(:'b8_nomark'::jsonb->'replaced') = 1
  AND :'b8_nomark'::jsonb#>>'{replaced,0,newer}' = 'NM1' AND :'b8_nomark'::jsonb#>>'{replaced,0,sent}' = 'NM2',
  'B8: a stored value with no field mark counts as someone else''s: ' || :'b8_nomark');

-- ===== B9. The GRN's change mark moves, so an "Edit GRN" opened before is refused as out of date =====
SELECT pg_temp.lc_save(:'admin_claims'::jsonb, 'LC10', :'cust'::uuid, :'item_id'::uuid, ARRAY['T1', 'T2']) AS grn_t \gset
SELECT id AS lot_t1 FROM public.goodsreceived_trl WHERE gr_id = :'grn_t' AND package_mark = 'T1' \gset
SELECT pg_temp.lc_age(:'grn_t'::uuid) AS opened_at \gset
SELECT pg_temp.lc_lines(:'grn_t'::uuid) AS opened_lines \gset
SELECT pg_temp.lc_call(:'staff_claims'::jsonb, :'lot_t1'::uuid, '{"rack":{"to":"NEW-R","from":"R1"}}', 'lc-b9') AS b9 \gset
SELECT pg_temp.lc_assert((SELECT updated_at > :'opened_at'::timestamptz AND updated_by = :'staff_profile'::uuid FROM public.goodsreceived WHERE id = :'grn_t'::uuid),
  'B9: the GRN''s change mark moved and names the person who changed the lot');
SELECT pg_temp.lc_assert(date_trunc('milliseconds', (:'b9'::jsonb#>>'{grn,updated_at}')::timestamptz) = (SELECT date_trunc('milliseconds', updated_at) FROM public.goodsreceived WHERE id = :'grn_t'::uuid),
  'B9: the answer''s grn.updated_at is the new change mark: ' || :'b9');
SELECT pg_temp.lc_as(:'admin_claims'::jsonb, format('SELECT public.update_grn(p_grn_id => %L::uuid, p_items => %L::jsonb, p_expected_updated_at => %L::timestamptz)',
  :'grn_t', :'opened_lines', :'opened_at')) AS b9_stale \gset
SELECT pg_temp.lc_assert(:'b9_stale'::jsonb->>'reason' = 'STALE_RECORD' AND pg_temp.lc_lot(:'lot_t1'::uuid)->>'rack' = 'NEW-R',
  'B9: an Edit GRN opened before the change is refused STALE_RECORD and the old rack is not put back: ' || :'b9_stale');
-- With the new change mark the same edit is accepted (the token in the answer is the right one) and keeps the new rack.
SELECT pg_temp.lc_edit(:'admin_claims'::jsonb, :'grn_t'::uuid, pg_temp.lc_lines(:'grn_t'::uuid), (:'b9'::jsonb#>>'{grn,updated_at}')::timestamptz) AS b9_fresh \gset
SELECT pg_temp.lc_assert(:'b9_fresh'::jsonb->>'success' = 'true' AND pg_temp.lc_lot(:'lot_t1'::uuid)->>'rack' = 'NEW-R',
  'B9: an edit that carries the answer''s change mark is accepted: ' || :'b9_fresh');

-- ===== B10. The request key: a repeat gets the first answer, writes nothing =====
SELECT pg_temp.lc_save(:'admin_claims'::jsonb, 'LC11', :'cust'::uuid, :'item_id'::uuid, ARRAY['K1', 'K2']) AS grn_k \gset
SELECT id AS lot_k1 FROM public.goodsreceived_trl WHERE gr_id = :'grn_k' AND package_mark = 'K1' \gset
SELECT id AS lot_k2 FROM public.goodsreceived_trl WHERE gr_id = :'grn_k' AND package_mark = 'K2' \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_k1'::uuid, '{"rack":{"to":"KEY-1","from":"R1"}}', 'lc-b10-key') AS k_first \gset
SELECT pg_temp.lc_assert(:'k_first'::jsonb->>'success' = 'true' AND NOT :'k_first'::jsonb ? 'idempotent', 'premise: the first call writes: ' || :'k_first');
SELECT pg_temp.lc_age(:'grn_k'::uuid) AS k_token \gset
-- Someone else changes the rack meanwhile; the resend must not undo it, move the mark or replace anything.
SELECT pg_temp.lc_call(:'supervisor_claims'::jsonb, :'lot_k1'::uuid, '{"rack":{"to":"KEY-OTHER","from":"KEY-1"}}', 'lc-b10-other') AS k_other \gset
SELECT pg_temp.lc_age(:'grn_k'::uuid) AS k_token2 \gset
SELECT pg_temp.lc_world(:'grn_k'::uuid) AS k_world \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_k1'::uuid, '{"rack":{"to":"KEY-1","from":"R1"}}', 'lc-b10-key') AS k_again \gset
SELECT pg_temp.lc_assert((:'k_again'::jsonb - 'idempotent') = :'k_first'::jsonb AND :'k_again'::jsonb->>'idempotent' = 'true',
  'B10: the same key again returns the first answer with idempotent: ' || :'k_again');
SELECT pg_temp.lc_assert(pg_temp.lc_world(:'grn_k'::uuid) = :'k_world'::jsonb AND pg_temp.lc_lot(:'lot_k1'::uuid)->>'rack' = 'KEY-OTHER'
  AND (SELECT updated_at = :'k_token2'::timestamptz FROM public.goodsreceived WHERE id = :'grn_k'::uuid),
  'B10: the repeat writes nothing, does not undo what another person set and does not move the change mark');
-- After 8 days (the store's own 7-day rule does not apply to this function).
UPDATE public.idempotency_keys SET created_at = created_at - interval '8 days', expires_at = expires_at - interval '8 days' WHERE idempotency_key = 'lc-b10-key';
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_k1'::uuid, '{"rack":{"to":"KEY-1","from":"R1"}}', 'lc-b10-key') AS k_late \gset
SELECT pg_temp.lc_assert((:'k_late'::jsonb - 'idempotent') = :'k_first'::jsonb AND :'k_late'::jsonb->>'idempotent' = 'true'
  AND pg_temp.lc_lot(:'lot_k1'::uuid)->>'rack' = 'KEY-OTHER', 'B10: the key is still answered 8 days later: ' || :'k_late');
-- The same key for another lot is refused, never replayed.
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_k2'::uuid, '{"rack":{"to":"KEY-2","from":"R2"}}', 'lc-b10-key') AS k_other_lot \gset
SELECT pg_temp.lc_assert(COALESCE(:'k_other_lot'::jsonb->>'success', 'false') <> 'true' AND :'k_other_lot'::jsonb->>'reason' = 'REQUEST_KEY_REUSED' AND NOT :'k_other_lot'::jsonb ? 'idempotent'
  AND pg_temp.lc_lot(:'lot_k2'::uuid)->>'rack' = 'R2', 'B10: the same key with another lot is refused REQUEST_KEY_REUSED, not replayed, and writes nothing: ' || :'k_other_lot');
-- The saved answer is found by get_submission_result (own keys only).
SELECT pg_temp.lc_as(:'admin_claims'::jsonb, $q$SELECT public.get_submission_result('lc-b10-key')$q$) AS k_found \gset
SELECT pg_temp.lc_as(:'staff_claims'::jsonb, $q$SELECT public.get_submission_result('lc-b10-key')$q$) AS k_not_mine \gset
SELECT pg_temp.lc_as(:'admin_claims'::jsonb, $q$SELECT public.get_submission_result('lc-b10-never-used')$q$) AS k_none \gset
SELECT pg_temp.lc_assert(:'k_found'::jsonb->>'found' = 'true' AND :'k_found'::jsonb#>>'{response,lot,id}' = :'lot_k1'
  AND :'k_not_mine'::jsonb->>'found' = 'false' AND :'k_none'::jsonb->>'found' = 'false',
  'B10: get_submission_result finds the caller''s own answer for this function and nobody else''s: ' || :'k_found' || :'k_not_mine');
-- A refusal is not stored: the same key can be sent again with a body that is valid.
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_k2'::uuid, '{"rack":{"to":"KEY-3","from":"R2"}}', 'lc-b10-after-refusal') AS k_valid \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_k2'::uuid, '{}', 'lc-b10-refused-key') AS k_refused \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_k2'::uuid, '{"rack":{"to":"KEY-4","from":"KEY-3"}}', 'lc-b10-refused-key') AS k_after_refusal \gset
SELECT pg_temp.lc_assert(:'k_refused'::jsonb->>'reason' = 'LOT_CHANGE_INVALID' AND :'k_after_refusal'::jsonb->>'success' = 'true' AND NOT :'k_after_refusal'::jsonb ? 'idempotent'
  AND pg_temp.lc_lot(:'lot_k2'::uuid)->>'rack' = 'KEY-4', 'B10: a refused call does not use up its request key: ' || :'k_after_refusal');

-- ===== B15. The phone time of a change sent over another person's value =====
SELECT pg_temp.lc_save(:'admin_claims'::jsonb, 'LC15', :'cust'::uuid, :'item_id'::uuid, ARRAY['F1']) AS grn_f \gset
SELECT id AS lot_f FROM public.goodsreceived_trl WHERE gr_id = :'grn_f' \gset
SELECT to_char((now() - interval '2 hours') AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS b15_two_hours_ago,
       to_char((now() + interval '1 day') AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS b15_tomorrow \gset
-- Two hours before the server time, over the supervisor's value: the entry keeps the phone time; sent_at is the server time.
SELECT pg_temp.lc_call(:'supervisor_claims'::jsonb, :'lot_f'::uuid, '{"rack":{"to":"F-SUP","from":"R1"}}', 'lc-b15-sup') AS b15_sup \gset
SELECT jsonb_build_object('rack', jsonb_build_object('to', 'F-ADM', 'from', 'R1'), 'recorded_at', :'b15_two_hours_ago')::text AS b15_body \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_f'::uuid, :'b15_body'::jsonb, 'lc-b15-late') AS b15_late \gset
SELECT pg_temp.lc_assert(:'b15_late'::jsonb->>'success' = 'true' AND jsonb_array_length(:'b15_late'::jsonb->'replaced') = 1
  AND :'b15_late'::jsonb#>>'{replaced,0,newer}' = 'F-SUP' AND :'b15_late'::jsonb#>>'{replaced,0,sent}' = 'F-ADM'
  AND (:'b15_late'::jsonb#>>'{replaced,0,recorded_at}')::timestamptz = now() - interval '2 hours'
  AND (:'b15_late'::jsonb#>>'{replaced,0,sent_at}')::timestamptz = now(),
  'B15: the answer''s entry carries the phone time (two hours ago) and the server time as sent_at: ' || :'b15_late');
SELECT pg_temp.lc_assert((SELECT count(*) = 1 AND bool_and(r.recorded_at = now() - interval '2 hours' AND r.sent_at = now())
    FROM warehouse_security.grn_replacements r WHERE r.lot_id = :'lot_f'::uuid AND r.sent_value = '"F-ADM"'::jsonb),
  'B15: the stored entry has the phone time as recorded_at and the server time as sent_at');
-- No recorded_at: the entry's recorded_at is NULL.
SELECT pg_temp.lc_call(:'supervisor_claims'::jsonb, :'lot_f'::uuid, '{"package_mark":{"to":"F-MSUP","from":"F1"}}', 'lc-b15-sup-mark') AS b15_sup_mark \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_f'::uuid, '{"package_mark":{"to":"F-MADM","from":"F1"}}', 'lc-b15-none') AS b15_none \gset
SELECT pg_temp.lc_assert(jsonb_array_length(:'b15_none'::jsonb->'replaced') = 1 AND :'b15_none'::jsonb#>'{replaced,0,recorded_at}' = 'null'::jsonb
  AND (SELECT r.recorded_at IS NULL FROM warehouse_security.grn_replacements r WHERE r.lot_id = :'lot_f'::uuid AND r.sent_value = '"F-MADM"'::jsonb),
  'B15: a call with no recorded_at makes an entry with recorded_at NULL: ' || :'b15_none');
-- A phone clock ahead of the server: not refused, stored as sent_at.
SELECT pg_temp.lc_call(:'supervisor_claims'::jsonb, :'lot_f'::uuid, '{"rack":{"to":"F-SUP2","from":"F-ADM"}}', 'lc-b15-sup-2') AS b15_sup_2 \gset
SELECT jsonb_build_object('rack', jsonb_build_object('to', 'F-ADM2', 'from', 'F-ADM'), 'recorded_at', :'b15_tomorrow')::text AS b15_future_body \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_f'::uuid, :'b15_future_body'::jsonb, 'lc-b15-future') AS b15_future \gset
SELECT pg_temp.lc_assert(:'b15_future'::jsonb->>'success' = 'true' AND jsonb_array_length(:'b15_future'::jsonb->'replaced') = 1
  AND (:'b15_future'::jsonb#>>'{replaced,0,recorded_at}')::timestamptz = now()
  AND (SELECT r.recorded_at = r.sent_at AND r.sent_at = now() FROM warehouse_security.grn_replacements r WHERE r.lot_id = :'lot_f'::uuid AND r.sent_value = '"F-ADM2"'::jsonb),
  'B15: a recorded_at later than the server time is not refused and is stored as sent_at: ' || :'b15_future');
-- A replay of the first key answers the first entry with its time and records none.
SELECT count(*) AS b15_entries_before FROM warehouse_security.grn_replacements WHERE lot_id = :'lot_f'::uuid \gset
SELECT jsonb_build_object('rack', jsonb_build_object('to', 'F-ADM', 'from', 'R1'), 'recorded_at', :'b15_tomorrow')::text AS b15_replay_body \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_f'::uuid, :'b15_replay_body'::jsonb, 'lc-b15-late') AS b15_replay \gset
SELECT pg_temp.lc_assert(:'b15_replay'::jsonb->>'idempotent' = 'true' AND (:'b15_replay'::jsonb - 'idempotent') = :'b15_late'::jsonb
  AND (:'b15_replay'::jsonb#>>'{replaced,0,recorded_at}')::timestamptz = now() - interval '2 hours'
  AND (SELECT count(*) = :'b15_entries_before'::int FROM warehouse_security.grn_replacements WHERE lot_id = :'lot_f'::uuid),
  'B15: a replay answers the first entry with its own phone time and records no second entry: ' || :'b15_replay');

-- ===== B13. Two lots of one GRN, or two fields of one lot, changed from two phones: both kept =====
SELECT pg_temp.lc_save(:'admin_claims'::jsonb, 'LC12', :'cust'::uuid, :'item_id'::uuid, ARRAY['P1', 'P2']) AS grn_p \gset
SELECT id AS lot_p1 FROM public.goodsreceived_trl WHERE gr_id = :'grn_p' AND package_mark = 'P1' \gset
SELECT id AS lot_p2 FROM public.goodsreceived_trl WHERE gr_id = :'grn_p' AND package_mark = 'P2' \gset
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_p1'::uuid, '{"rack":{"to":"PHONE-A","from":"R1"}}', 'lc-b13-a') AS b13_a \gset
SELECT pg_temp.lc_call(:'staff_claims'::jsonb, :'lot_p2'::uuid, '{"rack":{"to":"PHONE-B","from":"R2"}}', 'lc-b13-b') AS b13_b \gset
SELECT pg_temp.lc_assert(:'b13_a'::jsonb->'replaced' = '[]'::jsonb AND :'b13_b'::jsonb->'replaced' = '[]'::jsonb
  AND pg_temp.lc_lot(:'lot_p1'::uuid)->>'rack' = 'PHONE-A' AND pg_temp.lc_lot(:'lot_p2'::uuid)->>'rack' = 'PHONE-B',
  'B13: two lots of one GRN changed from two phones are both kept and replace nothing');
SELECT pg_temp.lc_call(:'admin_claims'::jsonb, :'lot_p1'::uuid, '{"rack":{"to":"SAME-R","from":"PHONE-A"}}', 'lc-b13-c') AS b13_c \gset
SELECT pg_temp.lc_call(:'staff_claims'::jsonb, :'lot_p1'::uuid, '{"package_mark":{"to":"SAME-M","from":"P1"}}', 'lc-b13-d') AS b13_d \gset
SELECT pg_temp.lc_assert(:'b13_c'::jsonb->'replaced' = '[]'::jsonb AND :'b13_d'::jsonb->'replaced' = '[]'::jsonb
  AND pg_temp.lc_lot(:'lot_p1'::uuid) = '{"rack":"SAME-R","package_mark":"SAME-M"}',
  'B13: two fields of one lot changed from two phones are both kept and replace nothing');
ROLLBACK;
\echo 'WH-302 lot rack and mark change (B1-B10, B13-B15) checks passed.'

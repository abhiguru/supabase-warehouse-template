-- WH-304, backend topics "holding list reads", "decide a held item", "held item photos" (rows) and "held outcome seen"
-- (contract ~/ws/fresh/product/tech/app-offline-holding-list.md sections 2.3, 2.4, 2.6, 2.8 and 8): B-R1 to B-R5, B-D1 to B-D13,
-- B-P1 (the rows of a held photo), B-S1, B-O1. Written before the build: it fails until the topics exist. Fictional data; rolls back.
--
-- Names the test takes from the contract (change here if Development names them otherwise; every shape that the contract leaves open
-- is read only in the helpers of the block "AGREE WITH DEVELOPMENT"):
--   public.get_held_items(p_limit, p_offset) -> { rows: [{ id, can_accept, needs_decision, recorded_by_name, ... }], total };
--   public.get_held_item(p_id) -> the row's members (accept_possible, reason, reason_code, reason_data, current[{field, current, held}],
--     body), read from the top level or from "item" (hd_get);
--   public.decide_held_item(p_id, p_action, p_decision_key, p_reason, p_body) -> { success, id, state, result, decided_by_name, decided_at,
--     now_acceptable[] } or { success:false, error_code | reason, ... }; the codes HELD_NOT_FOUND, HELD_ALREADY_DECIDED, HELD_NO_DECISION,
--     HELD_FOLLOWS_UNDECIDED, HELD_REASON_REQUIRED are looked for by name in the answer's text;
--   public.mark_held_item_seen(p_id) -> { success };
--   table public.held_items, public.held_item_photos(held_id, client_photo_id, path, role, line_ref, state);
--   columns goodsreceived.accepted_by and dispatch.accepted_by (2.6); goodsreceived.request_key, dispatch.request_key (WH-161);
--   body shapes: newGrn and newDispatch { args: {...} } (the arguments of save_grn without p_idempotency_key, or { data, items } of the
--     dispatch save); lotChange { lotId, grnId, recordedAt, changes } (C302); grnEdit { v:1, grnId, loadedAt, recordedAt, lots } (C303);
--     photos { doc:'grn', grnId } (C161 / C301);
--   result: the save's answer, read through hd_resno (gr_no / disp_no at the top or under data).
-- What the suite guards is named in each label: R1 list scope and order, R2 trial and the stored reason, R3 a trial writes nothing,
-- R4 current and held values, R5 a photos item with its own decision, D1 creator and time are the recorder's, D2 one decision, D3 refusal
-- keeps the item held, D4 accept with changes, D5 reject, D6 order of decisions, D7 a rejected first, D8 a key already saved, D9
-- deactivated recorder, D10 refused roles, D11 rebase of "from", D12 own item, D13 result numbers, P1 photos, S1 seen, O1 ordinary saves.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.hd_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'held items reads and decide 304: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.hd_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c jsonb; l jsonb; claims jsonb;
BEGIN
  c := public.operator_prepare_otp(phone);
  PERFORM pg_temp.hd_assert(c->>'success' = 'true', 'challenge prepared for ' || phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  l := public.operator_verify_otp(phone, c#>>'{data,otp_code}');
  PERFORM pg_temp.hd_assert(l#>>'{data,action}' = 'login', 'login for ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', r.id) INTO claims
    FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
CREATE FUNCTION pg_temp.hd_as(claims jsonb, statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims', claims::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN answer := jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  EXECUTE 'RESET ROLE';
  RETURN answer;
END $$;

-- ===== AGREE WITH DEVELOPMENT: the shapes the contract leaves open are read here and nowhere else =====
-- A member of get_held_item's answer: top level, or under "item".
CREATE FUNCTION pg_temp.hd_get(a jsonb, k text) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$ SELECT COALESCE(a->k, a->'item'->k, a->'data'->k) $$;
-- The number a decision's result carries (the GRN's or the dispatch's), at the top or under data.
CREATE FUNCTION pg_temp.hd_resno(r jsonb) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(r->'result'->>'gr_no', r->'result'#>>'{data,gr_no}', r->'result'->>'disp_no', r->'result'#>>'{data,disp_no}') $$;
-- hold_items as a caller.
CREATE FUNCTION pg_temp.hd_hold(claims jsonb, items jsonb, recorder uuid DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.hd_as(claims, format('SELECT public.hold_items(%L::jsonb, %L::uuid)', items, recorder)) $$;
CREATE FUNCTION pg_temp.hd_item(key text, kind text, seq int, cust uuid, body jsonb, extra jsonb DEFAULT '{}'::jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('request_key', key, 'kind', kind, 'body', body, 'seq', seq, 'recorded_at', now() - interval '2 hours',
    'what', jsonb_build_object('document', kind, 'number', key), 'customer_id', cust,
    'refusal', jsonb_build_object('code', 'STOCK_SHORT', 'reason', 'Insufficient stock')) || extra $$;
CREATE FUNCTION pg_temp.hd_decide(claims jsonb, id uuid, action text, key text, reason text DEFAULT NULL, body jsonb DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.hd_as(claims, format('SELECT public.decide_held_item(%L::uuid, %L, %L, %L, %L::jsonb)', id, action, key, reason, body)) $$;
CREATE FUNCTION pg_temp.hd_one(claims jsonb, id uuid) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.hd_as(claims, format('SELECT public.get_held_item(%L::uuid)', id)) $$;
CREATE FUNCTION pg_temp.hd_hid(key text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM public.held_items WHERE request_key = key $$;
CREATE FUNCTION pg_temp.hd_ok(a jsonb) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$ SELECT NOT (a ? 'raised') AND a->>'success' = 'true' $$;
CREATE FUNCTION pg_temp.hd_state(key text) RETURNS text LANGUAGE sql AS $$ SELECT state FROM public.held_items WHERE request_key = key $$;
-- The keys of a list answer's rows, in the order of the list.
CREATE FUNCTION pg_temp.hd_keys(a jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(string_agg(h.request_key, ',' ORDER BY r.n), '') FROM jsonb_array_elements(a->'rows') WITH ORDINALITY r(v, n)
    JOIN public.held_items h ON h.id = (r.v->>'id')::uuid $$;
CREATE FUNCTION pg_temp.hd_row(a jsonb, key text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT r.v FROM jsonb_array_elements(a->'rows') r(v) WHERE (r.v->>'id')::uuid = pg_temp.hd_hid(key) $$;
-- What a trial must not touch: documents, their lines, stock, saved answers, and the change log of the document tables.
CREATE FUNCTION pg_temp.hd_world() RETURNS text LANGUAGE sql AS $$
  SELECT (SELECT count(*) FROM public.goodsreceived)||'/'||(SELECT count(*) FROM public.goodsreceived_trl)||'/'||(SELECT count(*) FROM public.dispatch)
    ||'/'||(SELECT count(*) FROM public.dispatch_trl)||'/'||(SELECT count(*) FROM public.stock_movements)||'/'||(SELECT count(*) FROM public.idempotency_keys)
    ||'/'||(SELECT count(*) FROM warehouse_sync.change_log WHERE tbl IN ('goodsreceived', 'goodsreceived_trl', 'dispatch', 'dispatch_trl')) $$;
-- save_grn as a caller: items are given as jsonb; the key is the request key.
CREATE FUNCTION pg_temp.hd_save(claims jsonb, no text, cust uuid, item uuid, qty int, rack text, key text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE r jsonb; gid uuid;
BEGIN
  r := pg_temp.hd_as(claims, format('SELECT public.save_grn(p_sender_name => %L, p_supervisor_id => (SELECT id FROM public.user_profiles WHERE name = %L),'
    ' p_supervisor_name => %L, p_gr_no => %L, p_date => %L::timestamptz, p_customer_id => %L::uuid, p_customer_name => %L,'
    ' p_pricing_mode => %L, p_idempotency_key => %L, p_items => %L::jsonb)',
    'Held Sender', 'Held Administrator', 'Held Administrator', no, '2026-04-01T12:00:00Z', cust, 'Held Customer A', 'ONE_TIME', key,
    jsonb_build_array(jsonb_build_object('item_id', item, 'item_name', 'Held Cumin', 'packaging', 'Bag', 'qty', qty, 'weight', 10, 'rack', rack, 'package_mark', 'HM'))));
  PERFORM pg_temp.hd_assert(r->>'success' = 'true', 'fixture: save_grn ' || no || ': ' || left(r::text, 300));
  SELECT id INTO gid FROM public.goodsreceived WHERE gr_no = no;
  RETURN gid;
END $$;
-- The body of a held new GRN: the arguments of save_grn; a blank number is issued at accept.
CREATE FUNCTION pg_temp.hd_grn_body(cust uuid, item uuid, qty int, no text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('args', jsonb_build_object('p_sender_name', 'Held Sender',
    'p_supervisor_id', (SELECT id FROM public.user_profiles WHERE name = 'Held Administrator'), 'p_supervisor_name', 'Held Administrator',
    'p_gr_no', no, 'p_date', '2026-04-01T12:00:00Z', 'p_customer_id', cust, 'p_customer_name', 'Held Customer A', 'p_pricing_mode', 'ONE_TIME',
    'p_issue_number', no = '', 'p_recorded_at', now() - interval '2 hours',
    'p_items', jsonb_build_array(jsonb_build_object('item_id', item, 'item_name', 'Held Cumin', 'packaging', 'Bag', 'qty', qty, 'weight', 10, 'rack', 'N1', 'package_mark', 'NM')))) $$;
-- The body of a held new dispatch: data and one line.
CREATE FUNCTION pg_temp.hd_disp_body(cust uuid, no text, lot uuid, qty int) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('args', jsonb_build_object('p_dispatch_data', jsonb_build_object('disp_no', no, 'disp_date', '2026-05-02', 'customer_id', cust,
    'customer_name', 'Held Customer A', 'supervisor_id', (SELECT id FROM public.user_profiles WHERE name = 'Held Administrator'),
    'supervisor_name', 'Held Administrator', 'registration', 'GJ01HD0001'),
    'p_dispatch_items', jsonb_build_array(jsonb_build_object('gr_trl_id', lot, 'disp_qty', qty)), 'p_generate_invoice', false, 'p_retry_count', 0)) $$;
CREATE FUNCTION pg_temp.hd_lc_body(lot uuid, grn uuid, from_rack text, to_rack text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('lotId', lot, 'grnId', grn, 'recordedAt', now() - interval '2 hours',
    'changes', jsonb_build_object('rack', jsonb_build_object('from', from_rack, 'to', to_rack))) $$;
CREATE FUNCTION pg_temp.hd_rack(lot uuid) RETURNS text LANGUAGE sql AS $$ SELECT rack FROM public.goodsreceived_trl WHERE id = lot $$;
CREATE FUNCTION pg_temp.hd_entries(grn uuid) RETURNS bigint LANGUAGE sql AS $$ SELECT count(*) FROM warehouse_security.grn_replacements WHERE grn_id = grn $$;
-- A fresh GRN of one lot on rack A-1: returns the GRN id; the lot id by hd_lot.
CREATE FUNCTION pg_temp.hd_lot(grn uuid) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM public.goodsreceived_trl WHERE gr_id = grn $$;

-- ===== people and the catalogue =====
INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST'
 WHERE id = (SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888885101', 'Held Administrator') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888885102', 'Held Supervisor', 'supervisor', true, 'approved'),
 (gen_random_uuid(), '919888885103', 'Held Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888885104', 'Held Customer Account', 'customer', true, 'approved'),
 (gen_random_uuid(), '919888885105', 'Held Second Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888885106', 'Held Leaver', 'staff', true, 'approved');
SELECT pg_temp.hd_login('9888885101') AS admin_claims \gset
SELECT pg_temp.hd_login('9888885102') AS supervisor_claims \gset
SELECT pg_temp.hd_login('9888885103') AS staff_claims \gset
SELECT pg_temp.hd_login('9888885104') AS customer_claims \gset
SELECT pg_temp.hd_login('9888885105') AS staff2_claims \gset
SELECT pg_temp.hd_login('9888885106') AS leaver_claims \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE name = 'Held Administrator' \gset
SELECT id AS supervisor_profile FROM public.user_profiles WHERE mobile = '919888885102' \gset
SELECT id AS staff_profile FROM public.user_profiles WHERE mobile = '919888885103' \gset
SELECT id AS leaver_profile FROM public.user_profiles WHERE mobile = '919888885106' \gset
SELECT pg_temp.hd_assert(pg_temp.hd_as(:'admin_claims'::jsonb, $q$SELECT public.create_customer('Held Customer A', '9888885111')$q$)->>'success' = 'true', 'customer');
SELECT pg_temp.hd_assert(pg_temp.hd_as(:'admin_claims'::jsonb, $q$SELECT public.create_item('Held Cumin', 'Bag')$q$)->>'success' = 'true', 'item');
SELECT id AS ca FROM public.customers WHERE name = 'Held Customer A' \gset
SELECT id AS item_id FROM public.items WHERE name = 'Held Cumin' \gset
-- A stock lot of 10 bags for the dispatch cases, and a lot per rack chain below.
SELECT pg_temp.hd_save(:'admin_claims'::jsonb, 'HD1', :'ca'::uuid, :'item_id'::uuid, 10, 'A-1', 'hd-fixture-1') AS grn_stock \gset
SELECT pg_temp.hd_lot(:'grn_stock'::uuid) AS lot_stock \gset
SELECT pg_temp.hd_assert(pg_temp.hd_world() IS NOT NULL AND pg_temp.hd_rack(:'lot_stock'::uuid) = 'A-1', 'premise: the stock lot is on rack A-1');

-- ===== B-R1. The list: managers only, open items only, oldest first, followers under their item =====
-- Items by hand over (seq order = hand-over order): the short dispatch X1, a new GRN G1 and the photos item P1 that follows it, a dispatch X2.
SELECT pg_temp.hd_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hd_item('hd-x1', 'newDispatch', 1, :'ca'::uuid, pg_temp.hd_disp_body(:'ca'::uuid, 'HDD1', :'lot_stock'::uuid, 25)),
  pg_temp.hd_item('hd-g1', 'newGrn', 2, :'ca'::uuid, pg_temp.hd_grn_body(:'ca'::uuid, :'item_id'::uuid, 5, ''), jsonb_build_object('refusal', jsonb_build_object('code', 'NUMBER_TAKEN'))),
  pg_temp.hd_item('hd-p1', 'photos', 3, :'ca'::uuid, '{"doc":"grn"}', jsonb_build_object('follows_key', 'hd-g1', 'refusal', NULL)),
  pg_temp.hd_item('hd-x2', 'newDispatch', 4, :'ca'::uuid, pg_temp.hd_disp_body(:'ca'::uuid, 'HDD2', :'lot_stock'::uuid, 3)))) AS r1_hold \gset
SELECT pg_temp.hd_assert(:'r1_hold'::jsonb->>'success' = 'true', 'fixture: hand over: ' || :'r1_hold');
UPDATE public.held_items SET handed_at = now() - interval '4 hours' WHERE request_key = 'hd-x1';
UPDATE public.held_items SET handed_at = now() - interval '3 hours' WHERE request_key = 'hd-g1';
UPDATE public.held_items SET handed_at = now() - interval '3 hours' + interval '1 second' WHERE request_key = 'hd-p1';
UPDATE public.held_items SET handed_at = now() - interval '2 hours' WHERE request_key = 'hd-x2';
SELECT pg_temp.hd_as(:'admin_claims'::jsonb, 'SELECT public.get_held_items(50, 0)') AS r1_admin \gset
SELECT pg_temp.hd_as(:'supervisor_claims'::jsonb, 'SELECT public.get_held_items(50, 0)') AS r1_super \gset
SELECT pg_temp.hd_assert(pg_temp.hd_keys(:'r1_admin'::jsonb) = 'hd-x1,hd-g1,hd-p1,hd-x2' AND (:'r1_admin'::jsonb->>'total') = '4',
  'R1: the administrator sees the open items oldest first, the photos item directly under its GRN: ' || pg_temp.hd_keys(:'r1_admin'::jsonb));
SELECT pg_temp.hd_assert(pg_temp.hd_keys(:'r1_super'::jsonb) = 'hd-x1,hd-g1,hd-p1,hd-x2', 'R1: the supervisor sees the same list');
SELECT pg_temp.hd_assert((pg_temp.hd_row(:'r1_admin'::jsonb, 'hd-x1')->>'can_accept') = 'true' AND (pg_temp.hd_row(:'r1_admin'::jsonb, 'hd-g1')->>'can_accept') = 'true'
  AND (pg_temp.hd_row(:'r1_admin'::jsonb, 'hd-p1')->>'can_accept') = 'false' AND (pg_temp.hd_row(:'r1_admin'::jsonb, 'hd-p1')->>'needs_decision') = 'false'
  AND pg_temp.hd_row(:'r1_admin'::jsonb, 'hd-g1')->>'recorded_by_name' = 'Held Staff', 'R1: can_accept is false for the follower of a held item, true for the others; the recorder is named');
SELECT pg_temp.hd_as(:'admin_claims'::jsonb, 'SELECT public.get_held_items(2, 2)') AS r1_page \gset
SELECT pg_temp.hd_assert(pg_temp.hd_keys(:'r1_page'::jsonb) = 'hd-p1,hd-x2' AND (:'r1_page'::jsonb->>'total') = '4', 'R1: limit and offset page the list and total stays 4: ' || pg_temp.hd_keys(:'r1_page'::jsonb));

-- ===== B-D10. Staff and customer accounts are refused on list, read and decide =====
SELECT pg_temp.hd_as(:'staff_claims'::jsonb, 'SELECT public.get_held_items(50, 0)') AS d10_list_staff \gset
SELECT pg_temp.hd_as(:'customer_claims'::jsonb, 'SELECT public.get_held_items(50, 0)') AS d10_list_cust \gset
SELECT pg_temp.hd_one(:'staff_claims'::jsonb, pg_temp.hd_hid('hd-x1')) AS d10_read_staff \gset
SELECT pg_temp.hd_one(:'customer_claims'::jsonb, pg_temp.hd_hid('hd-x1')) AS d10_read_cust \gset
SELECT pg_temp.hd_decide(:'staff_claims'::jsonb, pg_temp.hd_hid('hd-x2'), 'accept', 'd10-staff') AS d10_dec_staff \gset
SELECT pg_temp.hd_decide(:'customer_claims'::jsonb, pg_temp.hd_hid('hd-x2'), 'reject', 'd10-cust', 'no') AS d10_dec_cust \gset
SELECT pg_temp.hd_assert(:'d10_list_staff'::jsonb->>'state' = '42501' AND :'d10_list_cust'::jsonb->>'state' = '42501'
  AND :'d10_read_staff'::jsonb->>'state' = '42501' AND :'d10_read_cust'::jsonb->>'state' = '42501'
  AND :'d10_dec_staff'::jsonb->>'state' = '42501' AND :'d10_dec_cust'::jsonb->>'state' = '42501', 'D10: staff and customer accounts are refused by the gate on list, read and decide');
SELECT pg_temp.hd_assert(pg_temp.hd_state('hd-x2') = 'held', 'D10: the refused decisions changed nothing');

-- ===== B-R2 / B-R3. The trial: stock short with the figures; after stock arrives true; the stored reason follows; a trial writes nothing =====
SELECT pg_temp.hd_world() AS world_before \gset
SELECT pg_temp.hd_as(:'admin_claims'::jsonb, $q$SELECT public.suggest_document_number('grn')$q$) AS grn_next_before \gset
SELECT pg_temp.hd_one(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-x1')) AS r2_short \gset
SELECT pg_temp.hd_assert(pg_temp.hd_get(:'r2_short'::jsonb, 'accept_possible') = 'false' AND pg_temp.hd_get(:'r2_short'::jsonb, 'reason') = '"stockShort"'
  AND pg_temp.hd_get(:'r2_short'::jsonb, 'reason_code') = '"STOCK_SHORT"' AND pg_temp.hd_get(:'r2_short'::jsonb, 'reason_data') IS NOT NULL
  AND pg_temp.hd_get(:'r2_short'::jsonb, 'reason_data') <> '{}'::jsonb, 'R2: a dispatch of 25 from a lot of 10 is not acceptable, stockShort with figures in reason_data: ' || :'r2_short');
SELECT pg_temp.hd_assert((SELECT reason_data FROM public.held_items WHERE request_key = 'hd-x1') = pg_temp.hd_get(:'r2_short'::jsonb, 'reason_data'),
  'R2: the trial stores the figures it found on the row, so the list and the recorder see today''s reason');
-- A GRN trial too (it would issue a number): get_held_item of G1.
SELECT pg_temp.hd_one(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-g1')) AS r3_grn \gset
SELECT pg_temp.hd_assert(pg_temp.hd_get(:'r3_grn'::jsonb, 'accept_possible') IS NOT NULL, 'R3: the trial of a new GRN answers: ' || :'r3_grn');
SELECT pg_temp.hd_assert(pg_temp.hd_world() = :'world_before' AND pg_temp.hd_as(:'admin_claims'::jsonb, $q$SELECT public.suggest_document_number('grn')$q$) = :'grn_next_before'::jsonb
  AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE request_key IN ('hd-g1', 'hd-x1')) AND NOT EXISTS (SELECT 1 FROM public.dispatch WHERE request_key = 'hd-x1'),
  'R3: two trials left no document, no stock movement, no stored key, no change-log entry for a document, and no number used');
-- The shortfall changes: someone dispatches 4 of the lot (10 -> 6 left); the trial shows the new figures and the row follows.
SELECT reason_data AS figures_before FROM public.held_items WHERE request_key = 'hd-x1' \gset
SELECT pg_temp.hd_as(:'admin_claims'::jsonb, format($q$SELECT public.create_dispatch_with_stock_check(%L::jsonb, ARRAY[%L::jsonb], false, 0, 'hd-fixture-d1')$q$,
  jsonb_build_object('disp_no', 'HDF1', 'disp_date', '2026-05-02', 'customer_id', :'ca', 'customer_name', 'Held Customer A', 'supervisor_id', :'admin_profile',
    'supervisor_name', 'Held Administrator', 'registration', 'GJ01HD0002'), jsonb_build_object('gr_trl_id', :'lot_stock', 'disp_qty', 4))) AS fixture_d1 \gset
SELECT pg_temp.hd_assert(:'fixture_d1'::jsonb->>'success' = 'true', 'fixture: dispatch of 4: ' || :'fixture_d1');
SELECT pg_temp.hd_one(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-x1')) AS r2_changed \gset
SELECT pg_temp.hd_assert(pg_temp.hd_get(:'r2_changed'::jsonb, 'accept_possible') = 'false' AND pg_temp.hd_get(:'r2_changed'::jsonb, 'reason_data') <> :'figures_before'::jsonb
  AND (SELECT reason_data FROM public.held_items WHERE request_key = 'hd-x1') = pg_temp.hd_get(:'r2_changed'::jsonb, 'reason_data'),
  'R2: when the shortfall changes the trial answers the new figures and the stored reason_data follows: ' || :'r2_changed');
-- Stock arrives: update_grn raises the lot to 40 bags; the same item is now acceptable.
SELECT pg_temp.hd_as(:'admin_claims'::jsonb, format($q$SELECT public.update_grn(p_grn_id => %L::uuid, p_items => %L::jsonb)$q$, :'grn_stock',
  (SELECT jsonb_agg(jsonb_build_object('id', t.id, 'item_id', t.item_id, 'item_name', t.item_name, 'packaging', t.packaging, 'qty', 40,
    'weight', t.weight, 'rack', t.rack, 'package_mark', t.package_mark)) FROM public.goodsreceived_trl t WHERE t.gr_id = :'grn_stock'::uuid))) AS fixture_up \gset
SELECT pg_temp.hd_assert(:'fixture_up'::jsonb->>'success' = 'true', 'fixture: stock arrives: ' || :'fixture_up');
SELECT pg_temp.hd_one(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-x1')) AS r2_now \gset
SELECT pg_temp.hd_assert(pg_temp.hd_get(:'r2_now'::jsonb, 'accept_possible') = 'true', 'R2: after stock arrives the trial says acceptable: ' || :'r2_now');
SELECT pg_temp.hd_assert(NOT EXISTS (SELECT 1 FROM public.dispatch WHERE disp_no = 'HDD1') AND pg_temp.hd_state('hd-x1') = 'held', 'R3: the acceptable trial still wrote no dispatch');

-- ===== B-D1. Accept a held new GRN: the recorder's creator and time, the accepting manager, a number issued now =====
-- The blank number of hd-g1 is issued by the server: the default GRN letters rule (migration 127) for this accept, then the free-text rule the run set for the typed numbers below.
SELECT warehouse_security.apply_document_numbering('grn', '{"scheme":"letters","first_letter":"A","width":4,"per_letter":1000}', NULL) AS _ \gset
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-g1'), 'accept', 'dk-g1') AS d1 \gset
SELECT warehouse_security.apply_document_numbering('grn', '{"scheme":"free"}', NULL) AS _ \gset
SELECT pg_temp.hd_assert(pg_temp.hd_ok(:'d1'::jsonb) AND :'d1'::jsonb->>'state' = 'accepted' AND pg_temp.hd_resno(:'d1'::jsonb) IS NOT NULL
  AND :'d1'::jsonb->>'decided_by_name' = 'Held Administrator', 'D1: the accept answers accepted with the number in result: ' || :'d1');
SELECT pg_temp.hd_assert((SELECT g.gr_no = pg_temp.hd_resno(:'d1'::jsonb) AND g.gr_no <> '' AND g.created_by = :'staff_profile'::uuid AND g.accepted_by = :'admin_profile'::uuid
    AND g.recorded_at = h.recorded_at AND g.request_key = 'hd-g1'
  FROM public.goodsreceived g, public.held_items h WHERE g.request_key = 'hd-g1' AND h.request_key = 'hd-g1'),
  'D1: the GRN carries the issued number, created_by and recorded_at of the recorder, accepted_by the administrator and the item''s key');
SELECT pg_temp.hd_assert((SELECT state = 'accepted' AND decided_by = :'admin_profile'::uuid AND decided_at IS NOT NULL AND decision_key = 'dk-g1'
    AND (result->>'gr_no' = pg_temp.hd_resno(:'d1'::jsonb) OR result#>>'{data,gr_no}' = pg_temp.hd_resno(:'d1'::jsonb)) FROM public.held_items WHERE request_key = 'hd-g1'),
  'D1: the held row records who decided, when, the decision key and the result');
-- ===== B-P1. The photos item that followed the GRN is accepted with it and its photos are on the GRN =====
SELECT pg_temp.hd_assert(pg_temp.hd_state('hd-p1') = 'accepted', 'P1: the follower with no decision of its own is accepted with its GRN');

-- ===== B-D2. Accept twice with one decision key: the first answer, one document; with another key: HELD_ALREADY_DECIDED =====
SELECT pg_temp.hd_world() AS world_d2 \gset
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-g1'), 'accept', 'dk-g1') AS d2_same \gset
SELECT pg_temp.hd_decide(:'supervisor_claims'::jsonb, pg_temp.hd_hid('hd-g1'), 'accept', 'dk-other') AS d2_other \gset
SELECT pg_temp.hd_assert(pg_temp.hd_ok(:'d2_same'::jsonb) AND :'d2_same'::jsonb->>'idempotent' = 'true' AND pg_temp.hd_resno(:'d2_same'::jsonb) = pg_temp.hd_resno(:'d1'::jsonb)
  AND :'d2_same'::jsonb->>'state' = 'accepted', 'D2: the same decision key answers the first answer, marked idempotent: ' || :'d2_same');
SELECT pg_temp.hd_assert(NOT pg_temp.hd_ok(:'d2_other'::jsonb) AND :'d2_other'::text LIKE '%HELD_ALREADY_DECIDED%' AND :'d2_other'::text LIKE '%Held Administrator%'
  AND :'d2_other'::text LIKE '%accepted%', 'D2: another key is HELD_ALREADY_DECIDED with who and the state: ' || :'d2_other');
SELECT pg_temp.hd_assert(pg_temp.hd_world() = :'world_d2', 'D2: no second document and no change from the repeats');
SELECT pg_temp.hd_assert((SELECT count(*) FROM public.goodsreceived WHERE request_key = 'hd-g1') = 1, 'D2: one GRN under the key');
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, gen_random_uuid(), 'accept', 'dk-none') AS d2_none \gset
SELECT pg_temp.hd_assert(:'d2_none'::text LIKE '%HELD_NOT_FOUND%', 'D2: an unknown id is HELD_NOT_FOUND: ' || :'d2_none');

-- ===== B-D3. Accept when the save refuses: still held, the new reason stored, nothing written =====
-- Put the stock back to 10 and the item asks for 25: STOCK_SHORT again.
UPDATE public.held_items SET reason = 'other', reason_code = NULL, reason_data = '{}' WHERE request_key = 'hd-x1';
SELECT pg_temp.hd_as(:'admin_claims'::jsonb, format($q$SELECT public.update_grn(p_grn_id => %L::uuid, p_items => %L::jsonb)$q$, :'grn_stock',
  (SELECT jsonb_agg(jsonb_build_object('id', t.id, 'item_id', t.item_id, 'item_name', t.item_name, 'packaging', t.packaging, 'qty', 10,
    'weight', t.weight, 'rack', t.rack, 'package_mark', t.package_mark)) FROM public.goodsreceived_trl t WHERE t.gr_id = :'grn_stock'::uuid))) AS fixture_down \gset
SELECT pg_temp.hd_assert(:'fixture_down'::jsonb->>'success' = 'true', 'fixture: stock back to 10: ' || :'fixture_down');
SELECT pg_temp.hd_world() AS world_d3 \gset
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-x1'), 'accept', 'dk-x1-a') AS d3 \gset
SELECT pg_temp.hd_assert(NOT pg_temp.hd_ok(:'d3'::jsonb) AND pg_temp.hd_state('hd-x1') = 'held' AND pg_temp.hd_world() = :'world_d3'
  AND (SELECT reason = 'stockShort' AND reason_code = 'STOCK_SHORT' AND decided_by IS NULL AND decision_key IS NULL FROM public.held_items WHERE request_key = 'hd-x1'),
  'D3: the refused save answers its own failure, the item stays held with the new reason stored and nothing is written: ' || :'d3');
SELECT pg_temp.hd_assert(:'d3'::text LIKE '%STOCK_SHORT%', 'D3: the save''s own code is answered unchanged: ' || :'d3');

-- ===== B-D4. Accept with changes: saved with the new body, accepted_body kept, body untouched =====
SELECT body AS x1_body FROM public.held_items WHERE request_key = 'hd-x1' \gset
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-x1'), 'accept', 'dk-x1-b', NULL, pg_temp.hd_disp_body(:'ca'::uuid, 'HDD1', :'lot_stock'::uuid, 5)) AS d4 \gset
SELECT pg_temp.hd_assert(pg_temp.hd_ok(:'d4'::jsonb) AND pg_temp.hd_state('hd-x1') = 'accepted', 'D4: accepted with a lower quantity: ' || :'d4');
SELECT pg_temp.hd_assert((SELECT t.disp_qty = 5 AND d.created_by = :'staff_profile'::uuid AND d.accepted_by = :'admin_profile'::uuid AND d.request_key = 'hd-x1'
    FROM public.dispatch d JOIN public.dispatch_trl t ON t.disp_id = d.id WHERE d.disp_no = 'HDD1'), 'D4: the dispatch holds 5 bags, the recorder as creator, the administrator as accepter');
SELECT pg_temp.hd_assert((SELECT body = :'x1_body'::jsonb AND accepted_body = pg_temp.hd_disp_body(:'ca'::uuid, 'HDD1', :'lot_stock'::uuid, 5) FROM public.held_items WHERE request_key = 'hd-x1'),
  'D4: body is as the phone froze it and accepted_body holds what was saved');

-- ===== B-D5. Reject: a reason is required; the followers are not rejected and become acceptable =====
-- Chain on its own lot: R1 (A-1 -> B-2) with follower R2 (B-2 -> C-2).
SELECT pg_temp.hd_save(:'admin_claims'::jsonb, 'HD5', :'ca'::uuid, :'item_id'::uuid, 10, 'A-1', 'hd-fixture-5') AS grn5 \gset
SELECT pg_temp.hd_lot(:'grn5'::uuid) AS lot5 \gset
SELECT pg_temp.hd_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hd_item('hd-c5a', 'lotChange', 10, :'ca'::uuid, pg_temp.hd_lc_body(:'lot5'::uuid, :'grn5'::uuid, 'A-1', 'B-2')),
  pg_temp.hd_item('hd-c5b', 'lotChange', 11, :'ca'::uuid, pg_temp.hd_lc_body(:'lot5'::uuid, :'grn5'::uuid, 'B-2', 'C-2'), jsonb_build_object('follows_key', 'hd-c5a', 'refusal', NULL)))) AS d5_hold \gset
SELECT pg_temp.hd_assert(:'d5_hold'::jsonb->>'success' = 'true', 'fixture: lot change chain: ' || :'d5_hold');
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-c5a'), 'reject', 'dk-c5a-0', NULL) AS d5_none \gset
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-c5a'), 'reject', 'dk-c5a-1', '   ') AS d5_blank \gset
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-c5a'), 'reject', 'dk-c5a-2', repeat('x', 501)) AS d5_long \gset
SELECT pg_temp.hd_assert(:'d5_none'::text LIKE '%HELD_REASON_REQUIRED%' AND :'d5_blank'::text LIKE '%HELD_REASON_REQUIRED%' AND :'d5_long'::text LIKE '%HELD_REASON_REQUIRED%'
  AND pg_temp.hd_state('hd-c5a') = 'held', 'D5: a reject with no reason, a blank one or one over 500 characters is HELD_REASON_REQUIRED and the item stays held');
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-c5a'), 'reject', 'dk-c5a-3', '  Wrong rack, checked on site  ') AS d5 \gset
SELECT pg_temp.hd_assert(pg_temp.hd_ok(:'d5'::jsonb) AND :'d5'::jsonb->>'state' = 'rejected', 'D5: a reject with a reason is rejected: ' || :'d5');
SELECT pg_temp.hd_assert((SELECT reject_reason = 'Wrong rack, checked on site' AND decided_by = :'admin_profile'::uuid AND decided_at IS NOT NULL FROM public.held_items WHERE request_key = 'hd-c5a')
  AND pg_temp.hd_state('hd-c5b') = 'held' AND pg_temp.hd_rack(:'lot5'::uuid) = 'A-1', 'D5: the reason is trimmed and stored, the follower is not rejected and the lot is untouched');
SELECT pg_temp.hd_as(:'admin_claims'::jsonb, 'SELECT public.get_held_items(50, 0)') AS d5_list \gset
SELECT pg_temp.hd_assert((pg_temp.hd_row(:'d5_list'::jsonb, 'hd-c5b')->>'can_accept') = 'true' AND pg_temp.hd_row(:'d5_list'::jsonb, 'hd-c5a') IS NULL
  AND :'d5'::jsonb->'now_acceptable' ? pg_temp.hd_hid('hd-c5b')::text,
  'D5: the follower is now acceptable (list and now_acceptable) and the decided item is no longer listed: ' || :'d5');
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-c5a'), 'accept', 'dk-c5a-late') AS d5_after \gset
SELECT pg_temp.hd_assert(:'d5_after'::text LIKE '%HELD_ALREADY_DECIDED%' AND :'d5_after'::text LIKE '%rejected%', 'D5: a rejected item cannot be accepted afterwards: ' || :'d5_after');

-- ===== B-D6. A follower accepted before its item: HELD_FOLLOWS_UNDECIDED; rejected before its item: rejected, the item before untouched =====
SELECT pg_temp.hd_save(:'admin_claims'::jsonb, 'HD6', :'ca'::uuid, :'item_id'::uuid, 10, 'A-1', 'hd-fixture-6') AS grn6 \gset
SELECT pg_temp.hd_lot(:'grn6'::uuid) AS lot6 \gset
SELECT pg_temp.hd_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hd_item('hd-c6a', 'lotChange', 20, :'ca'::uuid, pg_temp.hd_lc_body(:'lot6'::uuid, :'grn6'::uuid, 'A-1', 'B-2')),
  pg_temp.hd_item('hd-c6b', 'lotChange', 21, :'ca'::uuid, pg_temp.hd_lc_body(:'lot6'::uuid, :'grn6'::uuid, 'B-2', 'C-2'), jsonb_build_object('follows_key', 'hd-c6a', 'refusal', NULL)))) AS d6_hold \gset
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-c6b'), 'accept', 'dk-c6b-1') AS d6_accept \gset
SELECT pg_temp.hd_assert(NOT pg_temp.hd_ok(:'d6_accept'::jsonb) AND :'d6_accept'::text LIKE '%HELD_FOLLOWS_UNDECIDED%' AND pg_temp.hd_state('hd-c6b') = 'held'
  AND pg_temp.hd_rack(:'lot6'::uuid) = 'A-1', 'D6: accepting a follower before its item is HELD_FOLLOWS_UNDECIDED and writes nothing: ' || :'d6_accept');
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-c6b'), 'reject', 'dk-c6b-2', 'Not needed') AS d6_reject \gset
SELECT pg_temp.hd_assert(pg_temp.hd_ok(:'d6_reject'::jsonb) AND pg_temp.hd_state('hd-c6b') = 'rejected' AND pg_temp.hd_state('hd-c6a') = 'held'
  AND (SELECT decided_by IS NULL AND decided_at IS NULL AND reject_reason IS NULL AND decision_key IS NULL FROM public.held_items WHERE request_key = 'hd-c6a'),
  'D6: rejecting a follower before its item works, and the item before it is still held and untouched: ' || :'d6_reject');
-- A photos item with no decision of its own is not decided by itself.
SELECT pg_temp.hd_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hd_item('hd-g6', 'newGrn', 22, :'ca'::uuid, pg_temp.hd_grn_body(:'ca'::uuid, :'item_id'::uuid, 2, 'HD6G')),
  pg_temp.hd_item('hd-p6', 'photos', 23, :'ca'::uuid, '{"doc":"grn"}', jsonb_build_object('follows_key', 'hd-g6', 'refusal', NULL)))) AS d6_photos \gset
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-p6'), 'accept', 'dk-p6') AS d6_nodec \gset
SELECT pg_temp.hd_assert(:'d6_nodec'::text LIKE '%HELD_NO_DECISION%' AND pg_temp.hd_state('hd-p6') = 'held', 'D6: an item with no decision of its own is HELD_NO_DECISION: ' || :'d6_nodec');

-- ===== B-P1. A held GRN's photos: on the GRN after accept, kept with the item after reject; one row per client photo id =====
INSERT INTO public.held_item_photos(held_id, client_photo_id, path, role, line_ref, state, file_name, file_size, mime_type)
 VALUES (pg_temp.hd_hid('hd-g6'), 'hd-photo-1', 'held/hd-g6/hd-photo-1.jpg', 'header', NULL, 'confirmed', 'p.jpg', 1000, 'image/jpeg');
DO $$ BEGIN
  BEGIN
    INSERT INTO public.held_item_photos(held_id, client_photo_id, path, role, line_ref, state, file_name, file_size, mime_type)
      VALUES ((SELECT id FROM public.held_items WHERE request_key = 'hd-g6'), 'hd-photo-1', 'held/hd-g6/again.jpg', 'header', NULL, 'confirmed', 'p.jpg', 1000, 'image/jpeg');
    RAISE EXCEPTION 'held items reads and decide 304: P1: a photo registered twice by one client id made a second row';
  EXCEPTION WHEN unique_violation THEN NULL; END;
END $$;
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-g6'), 'accept', 'dk-g6') AS p1_accept \gset
SELECT pg_temp.hd_assert(pg_temp.hd_ok(:'p1_accept'::jsonb) AND pg_temp.hd_state('hd-p6') = 'accepted'
  AND (SELECT count(*) FROM public.grn_images WHERE grn_id = (SELECT id FROM public.goodsreceived WHERE request_key = 'hd-g6') AND image_type = 'header') = 1,
  'P1: after accept the held photo is on the new GRN as one header photo and the photos item is accepted: ' || :'p1_accept');
-- Reject: the photos stay with the held item and the photos item is rejected with it.
SELECT pg_temp.hd_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hd_item('hd-g7', 'newGrn', 24, :'ca'::uuid, pg_temp.hd_grn_body(:'ca'::uuid, :'item_id'::uuid, 2, 'HD7G')),
  pg_temp.hd_item('hd-p7', 'photos', 25, :'ca'::uuid, '{"doc":"grn"}', jsonb_build_object('follows_key', 'hd-g7', 'refusal', NULL)))) AS p1_hold7 \gset
INSERT INTO public.held_item_photos(held_id, client_photo_id, path, role, line_ref, state, file_name, file_size, mime_type)
 VALUES (pg_temp.hd_hid('hd-g7'), 'hd-photo-7', 'held/hd-g7/hd-photo-7.jpg', 'header', NULL, 'confirmed', 'p.jpg', 1000, 'image/jpeg');
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-g7'), 'reject', 'dk-g7', 'Duplicate of HD7') AS p1_reject \gset
SELECT pg_temp.hd_assert(pg_temp.hd_ok(:'p1_reject'::jsonb) AND pg_temp.hd_state('hd-p7') = 'rejected'
  AND (SELECT count(*) FROM public.held_item_photos WHERE held_id = pg_temp.hd_hid('hd-g7')) = 1 AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE request_key = 'hd-g7')
  AND (SELECT count(*) FROM public.grn_images) = 1, 'P1: a rejected GRN''s photos stay with the held item, no GRN is made, and its photos item is rejected: ' || :'p1_reject');

-- ===== B-R4. current and held per changed field of a held lotChange =====
SELECT pg_temp.hd_one(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-c6a')) AS r4 \gset
SELECT pg_temp.hd_assert((SELECT bool_or(c->>'field' = 'rack' AND c->'current' = '"A-1"'::jsonb AND c->'held' = '"B-2"'::jsonb)
    FROM jsonb_array_elements(pg_temp.hd_get(:'r4'::jsonb, 'current')) c), 'R4: a held lotChange shows the server''s rack A-1 as current and its own B-2 as held: ' || :'r4');
-- The server moves meanwhile: current follows.
SELECT pg_temp.hd_as(:'admin_claims'::jsonb, format($q$SELECT public.set_lot_rack_and_mark(%L::uuid, '{"rack":{"to":"Z-9","from":"A-1"}}'::jsonb, 'hd-r4-move')$q$, :'lot6')) AS r4_move \gset
SELECT pg_temp.hd_one(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-c6a')) AS r4_after \gset
SELECT pg_temp.hd_assert((SELECT bool_or(c->>'field' = 'rack' AND c->'current' = '"Z-9"'::jsonb AND c->'held' = '"B-2"'::jsonb)
    FROM jsonb_array_elements(pg_temp.hd_get(:'r4_after'::jsonb, 'current')) c), 'R4: current is read live from the server: ' || :'r4_after');
-- A held grnEdit lists its changed fields the same way.
SELECT pg_temp.hd_hold(:'staff_claims'::jsonb, jsonb_build_array(pg_temp.hd_item('hd-e4', 'grnEdit', 30, :'ca'::uuid,
  jsonb_build_object('v', 1, 'grnId', :'grn6', 'loadedAt', NULL, 'recordedAt', now() - interval '2 hours',
    'lots', jsonb_build_object(:'lot6', jsonb_build_object('rack', jsonb_build_object('from', 'Z-9', 'to', 'E-5'))))))) AS r4_edit_hold \gset
SELECT pg_temp.hd_one(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-e4')) AS r4_edit \gset
SELECT pg_temp.hd_assert((SELECT bool_or(c->>'field' = 'rack' AND c->'current' = '"Z-9"'::jsonb AND c->'held' = '"E-5"'::jsonb)
    FROM jsonb_array_elements(pg_temp.hd_get(:'r4_edit'::jsonb, 'current')) c), 'R4: a held grnEdit shows current and held per changed field: ' || :'r4_edit');

-- ===== B-R5. A photos item with its own decision: no trial; acceptable while its GRN exists, not once it is deleted =====
SELECT pg_temp.hd_save(:'admin_claims'::jsonb, 'HD8', :'ca'::uuid, :'item_id'::uuid, 1, 'A-1', 'hd-fixture-8') AS grn8 \gset
SELECT pg_temp.hd_hold(:'staff_claims'::jsonb, jsonb_build_array(pg_temp.hd_item('hd-ph8', 'photos', 40, :'ca'::uuid,
  jsonb_build_object('doc', 'grn', 'recordId', :'grn8'), jsonb_build_object('refusal', NULL)))) AS r5_hold \gset
SELECT pg_temp.hd_assert(:'r5_hold'::jsonb->>'success' = 'true' AND (SELECT needs_decision FROM public.held_items WHERE request_key = 'hd-ph8'), 'R5: a photos item on its own needs a decision: ' || :'r5_hold');
SELECT pg_temp.hd_world() AS world_r5 \gset
SELECT pg_temp.hd_one(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-ph8')) AS r5_exists \gset
SELECT pg_temp.hd_assert(pg_temp.hd_get(:'r5_exists'::jsonb, 'accept_possible') = 'true' AND pg_temp.hd_world() = :'world_r5',
  'R5: while its GRN exists the photos item is acceptable, and reading it writes nothing: ' || :'r5_exists');
SELECT pg_temp.hd_as(:'admin_claims'::jsonb, format('SELECT public.delete_grn_safe(%L::uuid)', :'grn8')) AS r5_delete \gset
SELECT pg_temp.hd_assert(:'r5_delete'::jsonb->>'success' = 'true', 'fixture: GRN deleted: ' || :'r5_delete');
SELECT pg_temp.hd_one(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-ph8')) AS r5_gone \gset
SELECT pg_temp.hd_assert(pg_temp.hd_get(:'r5_gone'::jsonb, 'accept_possible') = 'false', 'R5: once its GRN is deleted the photos item is not acceptable: ' || :'r5_gone');

-- ===== B-D7. The second follower after a rejected first still applies and records no entry naming the rejected value =====
SELECT pg_temp.hd_save(:'admin_claims'::jsonb, 'HD9', :'ca'::uuid, :'item_id'::uuid, 10, 'A-1', 'hd-fixture-9') AS grn9 \gset
SELECT pg_temp.hd_lot(:'grn9'::uuid) AS lot9 \gset
SELECT pg_temp.hd_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hd_item('hd-c9a', 'lotChange', 50, :'ca'::uuid, pg_temp.hd_lc_body(:'lot9'::uuid, :'grn9'::uuid, 'A-1', 'B-2')),
  pg_temp.hd_item('hd-c9b', 'lotChange', 51, :'ca'::uuid, pg_temp.hd_lc_body(:'lot9'::uuid, :'grn9'::uuid, 'B-2', 'C-2'), jsonb_build_object('follows_key', 'hd-c9a', 'refusal', NULL)),
  pg_temp.hd_item('hd-c9c', 'lotChange', 52, :'ca'::uuid, pg_temp.hd_lc_body(:'lot9'::uuid, :'grn9'::uuid, 'C-2', 'D-2'), jsonb_build_object('follows_key', 'hd-c9b', 'refusal', NULL)))) AS d7_hold \gset
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-c9a'), 'accept', 'dk-c9a') AS d7_a \gset
SELECT pg_temp.hd_assert(pg_temp.hd_ok(:'d7_a'::jsonb) AND pg_temp.hd_rack(:'lot9'::uuid) = 'B-2', 'D7: the first change is accepted and the lot is on B-2: ' || :'d7_a');
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-c9b'), 'reject', 'dk-c9b', 'Not that rack') AS d7_b \gset
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-c9c'), 'accept', 'dk-c9c') AS d7_c \gset
SELECT pg_temp.hd_assert(pg_temp.hd_ok(:'d7_b'::jsonb) AND pg_temp.hd_ok(:'d7_c'::jsonb) AND pg_temp.hd_rack(:'lot9'::uuid) = 'D-2'
  AND pg_temp.hd_entries(:'grn9'::uuid) = 0, 'D7: the change after a rejected one still applies (D-2) and no replacement entry is recorded: ' || :'d7_c');
SELECT pg_temp.hd_assert((SELECT body = pg_temp.hd_lc_body(:'lot9'::uuid, :'grn9'::uuid, 'C-2', 'D-2') - 'recordedAt' || jsonb_build_object('recordedAt', body->'recordedAt')
    FROM public.held_items WHERE request_key = 'hd-c9c'), 'D7: the stored body of the accepted follower still says it replaces C-2');

-- ===== B-D11. PQ6 rebase of "from" =====
-- (a) A-1 -> B-2 rejected; B-2 -> C-2 accepted: stored C-2, no entry (from rebased to A-1, which is what the server held).
SELECT pg_temp.hd_save(:'admin_claims'::jsonb, 'HD11A', :'ca'::uuid, :'item_id'::uuid, 10, 'A-1', 'hd-fixture-11a') AS grn11a \gset
SELECT pg_temp.hd_lot(:'grn11a'::uuid) AS lot11a \gset
SELECT pg_temp.hd_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hd_item('hd-a1', 'lotChange', 60, :'ca'::uuid, pg_temp.hd_lc_body(:'lot11a'::uuid, :'grn11a'::uuid, 'A-1', 'B-2')),
  pg_temp.hd_item('hd-a2', 'lotChange', 61, :'ca'::uuid, pg_temp.hd_lc_body(:'lot11a'::uuid, :'grn11a'::uuid, 'B-2', 'C-2'), jsonb_build_object('follows_key', 'hd-a1', 'refusal', NULL)))) AS d11a_hold \gset
SELECT body AS a2_body FROM public.held_items WHERE request_key = 'hd-a2' \gset
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-a1'), 'reject', 'dk-a1', 'No') AS d11a_r \gset
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-a2'), 'accept', 'dk-a2') AS d11a_a \gset
SELECT pg_temp.hd_assert(pg_temp.hd_ok(:'d11a_a'::jsonb) AND pg_temp.hd_rack(:'lot11a'::uuid) = 'C-2' AND pg_temp.hd_entries(:'grn11a'::uuid) = 0,
  'D11a: B-2 was never on the server, so C-2 replaces nothing: stored C-2 and no entry: ' || :'d11a_a');
SELECT pg_temp.hd_assert((SELECT body = :'a2_body'::jsonb FROM public.held_items WHERE request_key = 'hd-a2'), 'D11a: the held body is unchanged by the rebase');
-- (b) the same, but another person set D-4 after the first change was recorded: an entry that names D-4 and C-2, never B-2.
SELECT pg_temp.hd_save(:'admin_claims'::jsonb, 'HD11B', :'ca'::uuid, :'item_id'::uuid, 10, 'A-1', 'hd-fixture-11b') AS grn11b \gset
SELECT pg_temp.hd_lot(:'grn11b'::uuid) AS lot11b \gset
SELECT pg_temp.hd_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hd_item('hd-b1', 'lotChange', 62, :'ca'::uuid, pg_temp.hd_lc_body(:'lot11b'::uuid, :'grn11b'::uuid, 'A-1', 'B-2')),
  pg_temp.hd_item('hd-b2', 'lotChange', 63, :'ca'::uuid, pg_temp.hd_lc_body(:'lot11b'::uuid, :'grn11b'::uuid, 'B-2', 'C-2'), jsonb_build_object('follows_key', 'hd-b1', 'refusal', NULL)))) AS d11b_hold \gset
SELECT pg_temp.hd_as(:'supervisor_claims'::jsonb, format($q$SELECT public.set_lot_rack_and_mark(%L::uuid, '{"rack":{"to":"D-4","from":"A-1"}}'::jsonb, 'hd-d4-other')$q$, :'lot11b')) AS d11b_other \gset
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-b1'), 'reject', 'dk-b1', 'No') AS d11b_r \gset
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-b2'), 'accept', 'dk-b2') AS d11b_a \gset
SELECT pg_temp.hd_assert(pg_temp.hd_ok(:'d11b_a'::jsonb) AND pg_temp.hd_rack(:'lot11b'::uuid) = 'C-2' AND pg_temp.hd_entries(:'grn11b'::uuid) = 1
  AND (SELECT newer_value = '"D-4"'::jsonb AND sent_value = '"C-2"'::jsonb FROM warehouse_security.grn_replacements WHERE grn_id = :'grn11b'::uuid)
  AND NOT EXISTS (SELECT 1 FROM warehouse_security.grn_replacements WHERE grn_id = :'grn11b'::uuid AND (newer_value = '"B-2"'::jsonb OR sent_value = '"B-2"'::jsonb)),
  'D11b: someone else set D-4: the entry names D-4 and C-2 and never the rejected B-2: ' || :'d11b_a');
-- (c) a chain of two rejected: the third takes the first one's from, so D-2 replaces nothing.
SELECT pg_temp.hd_save(:'admin_claims'::jsonb, 'HD11C', :'ca'::uuid, :'item_id'::uuid, 10, 'A-1', 'hd-fixture-11c') AS grn11c \gset
SELECT pg_temp.hd_lot(:'grn11c'::uuid) AS lot11c \gset
SELECT pg_temp.hd_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hd_item('hd-k1', 'lotChange', 64, :'ca'::uuid, pg_temp.hd_lc_body(:'lot11c'::uuid, :'grn11c'::uuid, 'A-1', 'B-2')),
  pg_temp.hd_item('hd-k2', 'lotChange', 65, :'ca'::uuid, pg_temp.hd_lc_body(:'lot11c'::uuid, :'grn11c'::uuid, 'B-2', 'C-2'), jsonb_build_object('follows_key', 'hd-k1', 'refusal', NULL)),
  pg_temp.hd_item('hd-k3', 'lotChange', 66, :'ca'::uuid, pg_temp.hd_lc_body(:'lot11c'::uuid, :'grn11c'::uuid, 'C-2', 'D-2'), jsonb_build_object('follows_key', 'hd-k2', 'refusal', NULL)))) AS d11c_hold \gset
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-k1'), 'reject', 'dk-k1', 'No') AS d11c_1 \gset
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-k2'), 'reject', 'dk-k2', 'No') AS d11c_2 \gset
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-k3'), 'accept', 'dk-k3') AS d11c_3 \gset
SELECT pg_temp.hd_assert(pg_temp.hd_ok(:'d11c_3'::jsonb) AND pg_temp.hd_rack(:'lot11c'::uuid) = 'D-2' AND pg_temp.hd_entries(:'grn11c'::uuid) = 0,
  'D11c: after two rejected changes the third rebases to the first one''s from: D-2 stored, no entry: ' || :'d11c_3');
-- (d) the item before was accepted with changes: B-3 is on the server set by the recorder, so no entry for the follower.
SELECT pg_temp.hd_save(:'admin_claims'::jsonb, 'HD11D', :'ca'::uuid, :'item_id'::uuid, 10, 'A-1', 'hd-fixture-11d') AS grn11d \gset
SELECT pg_temp.hd_lot(:'grn11d'::uuid) AS lot11d \gset
SELECT pg_temp.hd_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hd_item('hd-m1', 'lotChange', 67, :'ca'::uuid, pg_temp.hd_lc_body(:'lot11d'::uuid, :'grn11d'::uuid, 'A-1', 'B-2')),
  pg_temp.hd_item('hd-m2', 'lotChange', 68, :'ca'::uuid, pg_temp.hd_lc_body(:'lot11d'::uuid, :'grn11d'::uuid, 'B-2', 'C-2'), jsonb_build_object('follows_key', 'hd-m1', 'refusal', NULL)))) AS d11d_hold \gset
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-m1'), 'accept', 'dk-m1', NULL, pg_temp.hd_lc_body(:'lot11d'::uuid, :'grn11d'::uuid, 'A-1', 'B-3')) AS d11d_1 \gset
SELECT pg_temp.hd_assert(pg_temp.hd_ok(:'d11d_1'::jsonb) AND pg_temp.hd_rack(:'lot11d'::uuid) = 'B-3', 'D11d: the first change is accepted with changes: B-3: ' || :'d11d_1');
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-m2'), 'accept', 'dk-m2') AS d11d_2 \gset
SELECT pg_temp.hd_assert(pg_temp.hd_ok(:'d11d_2'::jsonb) AND pg_temp.hd_rack(:'lot11d'::uuid) = 'C-2' AND pg_temp.hd_entries(:'grn11d'::uuid) = 0,
  'D11d: B-3 was set by the recorder (through the accept), so C-2 over it records no entry: ' || :'d11d_2');

-- ===== B-D8. An item whose key the server already saved: accept answers that document, accepted, no second one =====
SELECT pg_temp.hd_as(:'staff_claims'::jsonb, format($q$SELECT public.save_grn(p_sender_name => 'Held Sender', p_supervisor_id => %L::uuid, p_supervisor_name => 'Held Administrator',
  p_gr_no => 'HD12', p_date => '2026-04-01T12:00:00Z'::timestamptz, p_customer_id => %L::uuid, p_customer_name => 'Held Customer A', p_pricing_mode => 'ONE_TIME',
  p_idempotency_key => 'hd-k12', p_recorded_at => now() - interval '2 hours', p_items => %L::jsonb)$q$, :'admin_profile', :'ca', jsonb_build_array(jsonb_build_object('item_id', :'item_id', 'item_name', 'Held Cumin',
    'packaging', 'Bag', 'qty', 3, 'weight', 10, 'rack', 'N1', 'package_mark', 'NM')))) AS d8_first \gset
SELECT pg_temp.hd_assert(:'d8_first'::jsonb->>'success' = 'true', 'fixture: the phone''s first send was saved: ' || :'d8_first');
SELECT pg_temp.hd_hold(:'staff_claims'::jsonb, jsonb_build_array(pg_temp.hd_item('hd-k12', 'newGrn', 70, :'ca'::uuid, pg_temp.hd_grn_body(:'ca'::uuid, :'item_id'::uuid, 3, 'HD12')))) AS d8_hold \gset
SELECT pg_temp.hd_assert(:'d8_hold'::jsonb->>'success' = 'true', 'fixture: the lost-answer item was handed over: ' || :'d8_hold');
-- Eight days on: the saved answer is gone; the document keeps its key.
DELETE FROM public.idempotency_keys WHERE idempotency_key = 'hd-k12';
SELECT count(*) AS grns_before FROM public.goodsreceived \gset
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-k12'), 'accept', 'dk-k12') AS d8 \gset
SELECT pg_temp.hd_assert(pg_temp.hd_ok(:'d8'::jsonb) AND pg_temp.hd_state('hd-k12') = 'accepted' AND pg_temp.hd_resno(:'d8'::jsonb) = 'HD12'
  AND (SELECT count(*) FROM public.goodsreceived) = :'grns_before'::bigint AND (SELECT count(*) FROM public.goodsreceived WHERE gr_no = 'HD12') = 1,
  'D8: the item whose key the server had saved is accepted with that GRN''s answer, even with the saved answer gone, and no second GRN: ' || :'d8');

-- ===== B-D9. The recorder is deactivated: a supervisor still accepts =====
SELECT pg_temp.hd_hold(:'leaver_claims'::jsonb, jsonb_build_array(pg_temp.hd_item('hd-leave', 'newGrn', 80, :'ca'::uuid, pg_temp.hd_grn_body(:'ca'::uuid, :'item_id'::uuid, 2, 'HD13')))) AS d9_hold \gset
SELECT pg_temp.hd_assert(:'d9_hold'::jsonb->>'success' = 'true', 'fixture: the leaver handed over before leaving: ' || :'d9_hold');
UPDATE public.user_profiles SET active = false WHERE id = :'leaver_profile'::uuid;
SELECT pg_temp.hd_decide(:'supervisor_claims'::jsonb, pg_temp.hd_hid('hd-leave'), 'accept', 'dk-leave') AS d9 \gset
SELECT pg_temp.hd_assert(pg_temp.hd_ok(:'d9'::jsonb) AND (SELECT created_by = :'leaver_profile'::uuid AND accepted_by = :'supervisor_profile'::uuid FROM public.goodsreceived WHERE request_key = 'hd-leave'),
  'D9: a supervisor accepts a deactivated person''s item; the GRN is that person''s, accepted by the supervisor: ' || :'d9');
-- What staff may not send is judged by the accepting role: a staff body that carries rates (RATES_NEED_MANAGER for staff) is saved when a manager accepts it.
SELECT pg_temp.hd_hold(:'staff_claims'::jsonb, jsonb_build_array(pg_temp.hd_item('hd-rates', 'newGrn', 81, :'ca'::uuid,
  jsonb_set(pg_temp.hd_grn_body(:'ca'::uuid, :'item_id'::uuid, 2, 'HD14'), '{args,p_rates}',
    jsonb_build_array(jsonb_build_object('scope', 'grn', 'item_id', :'item_id', 'weight_min', 0, 'weight_max', 100, 'unit_price', 5, 'labour_rate', 2, 'tax_percent', 5))),
  jsonb_build_object('refusal', jsonb_build_object('code', 'RATES_NEED_MANAGER'))))) AS d9_rates_hold \gset
SELECT pg_temp.hd_decide(:'supervisor_claims'::jsonb, pg_temp.hd_hid('hd-rates'), 'accept', 'dk-rates') AS d9_rates \gset
SELECT pg_temp.hd_assert(pg_temp.hd_ok(:'d9_rates'::jsonb) AND (SELECT created_by = :'staff_profile'::uuid FROM public.goodsreceived WHERE request_key = 'hd-rates'),
  'D9: the role checks are the accepting manager''s: a staff GRN with rates is saved when a supervisor accepts it: ' || :'d9_rates');

-- ===== B-D12. A supervisor accepts their own item and rejects an administrator's =====
SELECT pg_temp.hd_hold(:'supervisor_claims'::jsonb, jsonb_build_array(pg_temp.hd_item('hd-sv-own', 'newGrn', 90, :'ca'::uuid, pg_temp.hd_grn_body(:'ca'::uuid, :'item_id'::uuid, 2, 'HD15')))) AS d12_hold_s \gset
SELECT pg_temp.hd_hold(:'admin_claims'::jsonb, jsonb_build_array(pg_temp.hd_item('hd-ad-own', 'newGrn', 91, :'ca'::uuid, pg_temp.hd_grn_body(:'ca'::uuid, :'item_id'::uuid, 2, 'HD16')))) AS d12_hold_a \gset
SELECT pg_temp.hd_decide(:'supervisor_claims'::jsonb, pg_temp.hd_hid('hd-sv-own'), 'accept', 'dk-sv-own') AS d12_acc \gset
SELECT pg_temp.hd_decide(:'supervisor_claims'::jsonb, pg_temp.hd_hid('hd-ad-own'), 'reject', 'dk-ad-own', 'Entered twice') AS d12_rej \gset
SELECT pg_temp.hd_assert(pg_temp.hd_ok(:'d12_acc'::jsonb) AND (SELECT created_by = :'supervisor_profile'::uuid AND accepted_by = :'supervisor_profile'::uuid FROM public.goodsreceived WHERE request_key = 'hd-sv-own')
  AND (SELECT decided_by = :'supervisor_profile'::uuid FROM public.held_items WHERE request_key = 'hd-sv-own'), 'D12: a supervisor accepts their own item, decided_by is the supervisor: ' || :'d12_acc');
SELECT pg_temp.hd_assert(pg_temp.hd_ok(:'d12_rej'::jsonb) AND (SELECT state = 'rejected' AND decided_by = :'supervisor_profile'::uuid AND recorded_by = :'admin_profile'::uuid FROM public.held_items WHERE request_key = 'hd-ad-own'),
  'D12: a supervisor rejects an administrator''s item: ' || :'d12_rej');
SELECT pg_temp.hd_hold(:'admin_claims'::jsonb, jsonb_build_array(pg_temp.hd_item('hd-ad-own2', 'newGrn', 92, :'ca'::uuid, pg_temp.hd_grn_body(:'ca'::uuid, :'item_id'::uuid, 2, 'HD17')))) AS d12_hold_a2 \gset
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-ad-own2'), 'accept', 'dk-ad-own2') AS d12_self \gset
SELECT pg_temp.hd_assert(pg_temp.hd_ok(:'d12_self'::jsonb), 'D12: an administrator accepts their own item too: ' || :'d12_self');

-- ===== B-D13. The result of a grnEdit, lotChange and photos accept carries the gr_no of the GRN it changed =====
SELECT pg_temp.hd_save(:'admin_claims'::jsonb, 'HD18', :'ca'::uuid, :'item_id'::uuid, 10, 'A-1', 'hd-fixture-18') AS grn18 \gset
SELECT pg_temp.hd_lot(:'grn18'::uuid) AS lot18 \gset
SELECT pg_temp.hd_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hd_item('hd-n-lc', 'lotChange', 95, :'ca'::uuid, pg_temp.hd_lc_body(:'lot18'::uuid, :'grn18'::uuid, 'A-1', 'L-1')),
  pg_temp.hd_item('hd-n-ge', 'grnEdit', 96, :'ca'::uuid, jsonb_build_object('v', 1, 'grnId', :'grn18', 'loadedAt', NULL, 'recordedAt', now() - interval '2 hours',
    'lots', jsonb_build_object(:'lot18', jsonb_build_object('rack', jsonb_build_object('from', 'L-1', 'to', 'E-1')))), jsonb_build_object('follows_key', 'hd-n-lc', 'refusal', NULL)),
  pg_temp.hd_item('hd-n-ph', 'photos', 97, :'ca'::uuid, jsonb_build_object('doc', 'grn', 'recordId', :'grn18'), jsonb_build_object('follows_key', 'hd-n-ge', 'refusal', NULL)))) AS d13_hold \gset
SELECT pg_temp.hd_assert(:'d13_hold'::jsonb->>'success' = 'true', 'fixture: lotChange, grnEdit and photos handed over: ' || :'d13_hold');
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-n-lc'), 'accept', 'dk-n-lc') AS d13_lc \gset
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-n-ge'), 'accept', 'dk-n-ge') AS d13_ge \gset
SELECT pg_temp.hd_decide(:'admin_claims'::jsonb, pg_temp.hd_hid('hd-n-ph'), 'accept', 'dk-n-ph') AS d13_ph \gset
SELECT pg_temp.hd_assert(pg_temp.hd_ok(:'d13_lc'::jsonb) AND pg_temp.hd_resno(:'d13_lc'::jsonb) = 'HD18', 'D13: a lotChange result carries the GRN number HD18: ' || :'d13_lc');
SELECT pg_temp.hd_assert(pg_temp.hd_ok(:'d13_ge'::jsonb) AND pg_temp.hd_resno(:'d13_ge'::jsonb) = 'HD18' AND pg_temp.hd_rack(:'lot18'::uuid) = 'E-1', 'D13: a grnEdit result carries HD18 and the edit is applied: ' || :'d13_ge');
SELECT pg_temp.hd_assert(pg_temp.hd_ok(:'d13_ph'::jsonb) AND pg_temp.hd_resno(:'d13_ph'::jsonb) = 'HD18', 'D13: a photos result carries HD18: ' || :'d13_ph');

-- ===== B-S1. mark_held_item_seen: the recorder only, a decided item only, a repeat writes nothing =====
SELECT pg_temp.hd_as(:'staff_claims'::jsonb, format('SELECT public.mark_held_item_seen(%L::uuid)', pg_temp.hd_hid('hd-x2'))) AS s1_open \gset
SELECT pg_temp.hd_assert(NOT pg_temp.hd_ok(:'s1_open'::jsonb) AND (SELECT seen_at IS NULL FROM public.held_items WHERE request_key = 'hd-x2'),
  'S1: an item still held cannot be marked seen: ' || :'s1_open');
SELECT pg_temp.hd_as(:'staff2_claims'::jsonb, format('SELECT public.mark_held_item_seen(%L::uuid)', pg_temp.hd_hid('hd-g1'))) AS s1_other \gset
SELECT pg_temp.hd_as(:'admin_claims'::jsonb, format('SELECT public.mark_held_item_seen(%L::uuid)', pg_temp.hd_hid('hd-g1'))) AS s1_admin \gset
SELECT pg_temp.hd_as(:'customer_claims'::jsonb, format('SELECT public.mark_held_item_seen(%L::uuid)', pg_temp.hd_hid('hd-g1'))) AS s1_cust \gset
SELECT pg_temp.hd_assert(NOT pg_temp.hd_ok(:'s1_other'::jsonb) AND NOT pg_temp.hd_ok(:'s1_admin'::jsonb) AND NOT pg_temp.hd_ok(:'s1_cust'::jsonb)
  AND (SELECT seen_at IS NULL FROM public.held_items WHERE request_key = 'hd-g1'), 'S1: another staff person, the deciding administrator and a customer account cannot mark the recorder''s item seen');
SELECT pg_temp.hd_as(:'staff_claims'::jsonb, format('SELECT public.mark_held_item_seen(%L::uuid)', pg_temp.hd_hid('hd-g1'))) AS s1_ok \gset
SELECT seen_at AS seen_first FROM public.held_items WHERE request_key = 'hd-g1' \gset
SELECT pg_temp.hd_assert(pg_temp.hd_ok(:'s1_ok'::jsonb) AND :'seen_first' IS NOT NULL AND :'seen_first' <> '', 'S1: the recorder marks a decided item seen: ' || :'s1_ok');
SELECT pg_temp.hd_world() AS world_s1 \gset
UPDATE public.held_items SET seen_at = seen_at - interval '1 hour' WHERE request_key = 'hd-g1';
SELECT seen_at AS seen_aged FROM public.held_items WHERE request_key = 'hd-g1' \gset
SELECT pg_temp.hd_as(:'staff_claims'::jsonb, format('SELECT public.mark_held_item_seen(%L::uuid)', pg_temp.hd_hid('hd-g1'))) AS s1_again \gset
SELECT pg_temp.hd_assert(pg_temp.hd_ok(:'s1_again'::jsonb) AND (SELECT seen_at = :'seen_aged'::timestamptz FROM public.held_items WHERE request_key = 'hd-g1'),
  'S1: a repeat answers success and does not move seen_at');

-- ===== B-O1. Feature untouched: an ordinary save and its repeated key answer as before the topics =====
SELECT pg_temp.hd_as(:'staff_claims'::jsonb, format($q$SELECT public.save_grn(p_sender_name => 'Held Sender', p_supervisor_id => %L::uuid, p_supervisor_name => 'Held Administrator',
  p_gr_no => 'HD19', p_date => '2026-04-01T12:00:00Z'::timestamptz, p_customer_id => %L::uuid, p_customer_name => 'Held Customer A', p_pricing_mode => 'ONE_TIME',
  p_idempotency_key => 'hd-o1', p_items => %L::jsonb)$q$, :'admin_profile', :'ca', jsonb_build_array(jsonb_build_object('item_id', :'item_id', 'item_name', 'Held Cumin',
    'packaging', 'Bag', 'qty', 1, 'weight', 10, 'rack', 'N1', 'package_mark', 'NM')))) AS o1_first \gset
SELECT pg_temp.hd_as(:'staff_claims'::jsonb, format($q$SELECT public.save_grn(p_sender_name => 'Held Sender', p_supervisor_id => %L::uuid, p_supervisor_name => 'Held Administrator',
  p_gr_no => 'HD19', p_date => '2026-04-01T12:00:00Z'::timestamptz, p_customer_id => %L::uuid, p_customer_name => 'Held Customer A', p_pricing_mode => 'ONE_TIME',
  p_idempotency_key => 'hd-o1', p_items => %L::jsonb)$q$, :'admin_profile', :'ca', jsonb_build_array(jsonb_build_object('item_id', :'item_id', 'item_name', 'Held Cumin',
    'packaging', 'Bag', 'qty', 1, 'weight', 10, 'rack', 'N1', 'package_mark', 'NM')))) AS o1_again \gset
SELECT pg_temp.hd_assert(:'o1_first'::jsonb->>'success' = 'true' AND :'o1_again'::jsonb->>'success' = 'true' AND :'o1_again'::jsonb->>'idempotent' = 'true'
  AND (:'o1_again'::jsonb#>>'{data,gr_no}') = 'HD19' AND (SELECT count(*) FROM public.goodsreceived WHERE gr_no = 'HD19') = 1
  AND (SELECT created_by = :'staff_profile'::uuid AND accepted_by IS NULL FROM public.goodsreceived WHERE gr_no = 'HD19'),
  'O1: an ordinary save is the caller''s own, has no accepter, and its repeated key answers the first save once: ' || :'o1_again');
ROLLBACK;
\echo 'WH-304 held items reads and decide (B-R, B-D, B-P1, B-S1, B-O1) checks passed.'

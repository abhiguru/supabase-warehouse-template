-- WH-303 "edit GRN by field changes" (contract ~/ws/fresh/product/tech/app-offline-edit-grn.md, 5.1-5.4 and cases B1-B10; Product PQ1,
-- PQ3, PQ6, PQ8; Design DQ3). Written before the build; every case fails until public.apply_grn_changes, the field marks and the
-- replaced entries exist. tests/migrations.sh pipes tests/fixtures/gst_details.sql and tests/sync_feed_contract.sql in front of this
-- file, in the sync feed database of its own: it needs COMMITTED statements, because a replacement needs "the value set after the
-- person loaded the GRN" and now() does not move inside one transaction. Every action below is its own statement. Fictional data.
--
-- AGREE WITH DEVELOPMENT (WH-303): names the contract proposes. If one changes, change it here and nowhere else.
--   public.apply_grn_changes(p_grn_id uuid, p_changes jsonb, p_request_key text) -> jsonb       (5.2)
--   body (3.2): v, grnId, loadedAt, recordedAt, header{field:{from,to}}, lots{lotId:{field:{from,to}}}, linesAdded[], linesRemoved[]
--   answer (5.2): success, applied{header[],lots{id:[field]}}, lines_added[{client_line_id,id}], lines_removed[], replaced[],
--     idempotent; refusals as update_grn: top-level reason, message, data fields (lot_id, item_name, dispatched_qty, requested) and
--     refused[{path,code}] listing every refused change (5.2, PQ1)
--   table public.grn_replacements (5.4): grn_id, lot_id, kind ('field'|'line_added'), field, newer_value, newer_by, newer_at,
--     sent_value, sent_by, sent_at, recorded_at, request_key (values are compared as text, by the words they contain)
\set ON_ERROR_STOP on

CREATE FUNCTION pg_temp.fc_apply(claims jsonb, grn uuid, body jsonb, key text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.sf_as(claims, format('SELECT public.apply_grn_changes(%L::uuid, %L::jsonb, %L)', grn, body, key)) $$;
CREATE FUNCTION pg_temp.fc_body(grn uuid, loaded timestamptz, recorded timestamptz, parts jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('v', 1, 'grnId', grn, 'loadedAt', loaded, 'recordedAt', recorded) || parts $$;
CREATE FUNCTION pg_temp.fc_token(grn uuid) RETURNS timestamptz LANGUAGE sql STABLE AS $$ SELECT updated_at FROM public.goodsreceived WHERE id = grn $$;
CREATE FUNCTION pg_temp.fc_entries(grn uuid, k text DEFAULT NULL) RETURNS bigint LANGUAGE sql STABLE AS $$
  SELECT count(*) FROM public.grn_replacements r WHERE r.grn_id = grn AND (k IS NULL OR r.kind = k) $$;
CREATE FUNCTION pg_temp.fc_has(v anyelement, word text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$ SELECT strpos(v::text, word) > 0 $$;

INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888897811', 'Field Change Staff A', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888897812', 'Field Change Staff B', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888897813', 'Field Change Supervisor', 'supervisor', true, 'approved'),
 (gen_random_uuid(), '919888897814', 'Field Change Reader', 'customer', true, 'approved');
SELECT pg_temp.sf_login('9888897811') AS a_claims \gset
SELECT pg_temp.sf_login('9888897812') AS b_claims \gset
SELECT pg_temp.sf_login('9888897813') AS sup_claims \gset
SELECT pg_temp.sf_login('9888897814') AS reader_claims \gset
SELECT id AS a_profile FROM public.user_profiles WHERE mobile = '919888897811' \gset
SELECT id AS b_profile FROM public.user_profiles WHERE mobile = '919888897812' \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_customer(''Field Change West'', ''9888897821'')')->>'success' = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_item(''Field Change Cumin'', ''Bag'')')->>'success' = 'true', 'customer and item');
SELECT id AS west FROM public.customers WHERE name = 'Field Change West' \gset
SELECT id AS cumin FROM public.items WHERE name = 'Field Change Cumin' \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT to_jsonb(public.assign_customer_to_user(%L, %L::uuid, %L))', '919888897814', :'west', 'Field change fixture'))::text = 'true',
  'the customer account is assigned');

-- Fixture: GRN FCG1, two lots of 50 bags (marks FA1 = lot_a, FA2 = lot_b, rack R1), 10 bags of lot_a dispatched.
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'FCG1', :'west'::uuid, pg_temp.sf_lines(:'cumin'::uuid, 2, 'FA', 50)) AS grn \gset
SELECT id AS lot_a FROM public.goodsreceived_trl WHERE gr_id = :'grn' AND package_mark = 'FA1' \gset
SELECT id AS lot_b FROM public.goodsreceived_trl WHERE gr_id = :'grn' AND package_mark = 'FA2' \gset
SELECT pg_temp.sf_dispatch(:'sf_admin_claims'::jsonb, 'FCD1', :'lot_a'::uuid, 10) AS disp \gset
SELECT pg_temp.fc_token(:'grn') AS tok0 \gset

-- B3 / B1: the administrator sets the note after the person loaded; the person's later send replaces it and the notice names both.
SELECT pg_temp.fc_apply(:'sf_admin_claims'::jsonb, :'grn', pg_temp.fc_body(:'grn', :'tok0', now(),
  jsonb_build_object('header', jsonb_build_object('note', jsonb_build_object('from', NULL, 'to', 'Admin note')))), 'fc-1') AS r1 \gset
SELECT pg_temp.sf_assert(:'r1'::jsonb->>'success' = 'true' AND :'r1'::jsonb#>'{applied,header}' ? 'note'
  AND (SELECT note = 'Admin note' FROM public.goodsreceived WHERE id = :'grn') AND pg_temp.fc_entries(:'grn') = 0,
  'B1: the administrator''s first change is written and raises no entry (stored = from): ' || :'r1');

SELECT pg_temp.fc_apply(:'a_claims'::jsonb, :'grn', pg_temp.fc_body(:'grn', :'tok0', '2026-11-26T10:00:00Z',
  jsonb_build_object('header', jsonb_build_object('note', jsonb_build_object('from', NULL, 'to', 'Staff note')),
    'lots', jsonb_build_object(:'lot_b', jsonb_build_object('rack', jsonb_build_object('from', 'R1', 'to', 'R5'))))), 'fc-2') AS r2 \gset
SELECT pg_temp.sf_assert(:'r2'::jsonb->>'success' = 'true' AND :'r2'::jsonb#>'{applied,header}' ? 'note'
  AND :'r2'::jsonb->'applied'->'lots' ? :'lot_b',
  'B1: last sent wins, both fields applied: ' || :'r2');
SELECT pg_temp.sf_assert((SELECT note = 'Staff note' FROM public.goodsreceived WHERE id = :'grn')
  AND (SELECT rack = 'R5' FROM public.goodsreceived_trl WHERE id = :'lot_b')
  AND (SELECT qty = 50 AND stock = 40 AND rack = 'R1' FROM public.goodsreceived_trl WHERE id = :'lot_a'),
  'B1: only the sent fields changed, the other lot is as it was');
SELECT pg_temp.sf_assert(pg_temp.fc_entries(:'grn', 'field') = 1 AND jsonb_array_length(:'r2'::jsonb->'replaced') = 1,
  'B3: one entry (the note); the rack matched its from, so no entry: ' || :'r2');
SELECT pg_temp.sf_assert((SELECT r.field = 'note' AND r.lot_id IS NULL AND pg_temp.fc_has(r.newer_value, 'Admin note') AND pg_temp.fc_has(r.sent_value, 'Staff note')
    AND r.newer_by = :'sf_admin_profile'::uuid AND r.sent_by = :'a_profile'::uuid AND r.newer_at IS NOT NULL AND r.sent_at > r.newer_at
    AND r.recorded_at = '2026-11-26T10:00:00Z'::timestamptz AND r.request_key = 'fc-2' AND r.checked_by IS NULL AND r.checked_at IS NULL
    FROM public.grn_replacements r WHERE r.grn_id = :'grn'),
  'B3: the entry has the field, both values, both people, the stored time, the server time of the send and the phone time of the change');

-- B1: a line added by another session meanwhile is intact after a send that does not mention lines (nothing is resent whole).
SELECT pg_temp.fc_token(:'grn') AS tok1 \gset
SELECT pg_temp.fc_apply(:'sf_admin_claims'::jsonb, :'grn', pg_temp.fc_body(:'grn', :'tok1', now(),
  jsonb_build_object('linesAdded', jsonb_build_array(jsonb_build_object('clientLineId', 'c-1', 'item_id', :'cumin', 'item_name', 'Field Change Cumin',
    'packaging', 'Bag', 'qty', 7, 'weight', 5, 'rack', 'R7', 'package_mark', 'FA3')))), 'fc-3') AS r3 \gset
SELECT pg_temp.sf_assert(:'r3'::jsonb->>'success' = 'true' AND :'r3'::jsonb#>>'{lines_added,0,client_line_id}' = 'c-1' AND :'r3'::jsonb#>>'{lines_added,0,id}' IS NOT NULL
  AND (SELECT qty = 7 AND stock = 7 AND rack = 'R7' FROM public.goodsreceived_trl WHERE id = (:'r3'::jsonb#>>'{lines_added,0,id}')::uuid)
  AND jsonb_array_length(:'r3'::jsonb->'replaced') = 0 AND pg_temp.fc_entries(:'grn', 'line_added') = 0,
  'B9 / PQ6: one session alone adds a line: stored with stock = qty, mapped to its client id, and no "Lines added" entry: ' || :'r3');
SELECT (:'r3'::jsonb#>>'{lines_added,0,id}')::uuid AS lot_c \gset
SELECT pg_temp.fc_apply(:'a_claims'::jsonb, :'grn', pg_temp.fc_body(:'grn', :'tok0', now(),
  jsonb_build_object('lots', jsonb_build_object(:'lot_a', jsonb_build_object('rack', jsonb_build_object('from', 'R1', 'to', 'R2'))))), 'fc-4') AS r4 \gset
SELECT pg_temp.sf_assert(:'r4'::jsonb->>'success' = 'true' AND (SELECT count(*) = 3 FROM public.goodsreceived_trl WHERE gr_id = :'grn')
  AND (SELECT rack = 'R7' FROM public.goodsreceived_trl WHERE id = :'lot_c') AND (SELECT rack = 'R2' FROM public.goodsreceived_trl WHERE id = :'lot_a'),
  'B1: a send made from an older copy changes only its field; the line another session added meanwhile is still there: ' || :'r4');

-- B9: two sessions add a line after the same load: both are kept and two "Lines added" entries are written (PQ6, PQ8).
SELECT pg_temp.fc_token(:'grn') AS tok2 \gset
SELECT pg_temp.fc_apply(:'sf_admin_claims'::jsonb, :'grn', pg_temp.fc_body(:'grn', :'tok2', now(),
  jsonb_build_object('linesAdded', jsonb_build_array(jsonb_build_object('clientLineId', 'c-2', 'item_id', :'cumin', 'item_name', 'Field Change Cumin',
    'packaging', 'Bag', 'qty', 3, 'weight', 5, 'rack', 'R8', 'package_mark', 'FA4')))), 'fc-5') AS r5 \gset
SELECT pg_temp.sf_assert(:'r5'::jsonb->>'success' = 'true' AND pg_temp.fc_entries(:'grn', 'line_added') = 0, 'B9: the first of the two adds raises nothing: ' || :'r5');
SELECT pg_temp.fc_apply(:'a_claims'::jsonb, :'grn', pg_temp.fc_body(:'grn', :'tok2', '2026-11-26T11:00:00Z',
  jsonb_build_object('linesAdded', jsonb_build_array(jsonb_build_object('clientLineId', 'c-3', 'item_id', :'cumin', 'item_name', 'Field Change Cumin',
    'packaging', 'Bag', 'qty', 4, 'weight', 5, 'rack', 'R9', 'package_mark', 'FA5')))), 'fc-6') AS r6 \gset
SELECT pg_temp.sf_assert(:'r6'::jsonb->>'success' = 'true' AND (SELECT count(*) = 5 FROM public.goodsreceived_trl WHERE gr_id = :'grn')
  AND pg_temp.fc_entries(:'grn', 'line_added') = 2 AND jsonb_array_length(:'r6'::jsonb->'replaced') = 2,
  'B9: both lines are kept and there are two "Lines added" entries: ' || :'r6');
SELECT pg_temp.sf_assert((SELECT count(*) = 1 FROM public.grn_replacements r WHERE r.grn_id = :'grn' AND r.kind = 'line_added' AND r.sent_by = :'a_profile'::uuid
      AND r.recorded_at = '2026-11-26T11:00:00Z'::timestamptz AND pg_temp.fc_has(r.sent_value, 'Field Change Cumin') AND r.newer_by IS NULL AND r.newer_at IS NULL)
  AND (SELECT count(*) = 1 FROM public.grn_replacements r WHERE r.grn_id = :'grn' AND r.kind = 'line_added' AND r.sent_by = :'sf_admin_profile'::uuid
      AND r.recorded_at IS NULL AND r.sent_at IS NOT NULL AND r.newer_by IS NULL),
  'B9: this send''s line has its phone time, the other session''s line is by its adder with no phone time, neither has a "newer" value');

-- B3 (PQ8): a phone time later than the server time is stored as the server time.
SELECT pg_temp.fc_apply(:'b_claims'::jsonb, :'grn', pg_temp.fc_body(:'grn', :'tok0', now() + interval '2 hours',
  jsonb_build_object('header', jsonb_build_object('note', jsonb_build_object('from', 'Older', 'to', 'B note')))), 'fc-7') AS r7 \gset
SELECT pg_temp.sf_assert(:'r7'::jsonb->>'success' = 'true' AND (SELECT r.recorded_at = r.sent_at AND pg_temp.fc_has(r.newer_value, 'Staff note')
    FROM public.grn_replacements r WHERE r.request_key = 'fc-7'),
  'B3 / PQ8: a phone clock ahead is stored as the time of the send: ' || :'r7');

-- B3b: the stored value was last set by the sender (another phone of theirs): written, no entry, nothing in the answer.
SELECT pg_temp.fc_entries(:'grn', 'field') AS before_same \gset
SELECT pg_temp.fc_apply(:'b_claims'::jsonb, :'grn', pg_temp.fc_body(:'grn', :'tok0', now(),
  jsonb_build_object('header', jsonb_build_object('note', jsonb_build_object('from', 'Not what is stored', 'to', 'B again')))), 'fc-8') AS r8 \gset
SELECT pg_temp.sf_assert(:'r8'::jsonb->>'success' = 'true' AND (SELECT note = 'B again' FROM public.goodsreceived WHERE id = :'grn')
  AND jsonb_array_length(:'r8'::jsonb->'replaced') = 0 AND pg_temp.fc_entries(:'grn', 'field') = :before_same,
  'B3b: a value last set by the sender is replaced with no entry: ' || :'r8');
-- ... and the same stale send by someone else is an entry naming that person (the apply path sets the field mark).
SELECT pg_temp.fc_apply(:'a_claims'::jsonb, :'grn', pg_temp.fc_body(:'grn', :'tok0', now(),
  jsonb_build_object('header', jsonb_build_object('note', jsonb_build_object('from', 'Not what is stored', 'to', 'A over B')))), 'fc-9') AS r9 \gset
SELECT pg_temp.sf_assert((SELECT r.newer_by = :'b_profile'::uuid AND pg_temp.fc_has(r.newer_value, 'B again') AND r.sent_by = :'a_profile'::uuid
    FROM public.grn_replacements r WHERE r.request_key = 'fc-9'), 'B10: the field mark of an apply_grn_changes write names its writer: ' || :'r9');

-- B3b: no field mark (set before the topic existed): written, entry, newer_by NULL (DQ3: "someone"). Triggers are off for the set-up write.
BEGIN;
SET LOCAL session_replication_role = replica;
UPDATE public.goodsreceived_trl SET package_mark = 'FA2X' WHERE id = :'lot_b';
COMMIT;
SELECT pg_temp.fc_apply(:'b_claims'::jsonb, :'grn', pg_temp.fc_body(:'grn', :'tok0', now(),
  jsonb_build_object('lots', jsonb_build_object(:'lot_b', jsonb_build_object('package_mark', jsonb_build_object('from', 'FA2', 'to', 'FA2B'))))), 'fc-10') AS r10 \gset
SELECT pg_temp.sf_assert(:'r10'::jsonb->>'success' = 'true' AND (SELECT r.newer_by IS NULL AND r.newer_at IS NULL AND r.lot_id = :'lot_b'::uuid AND r.field = 'package_mark'
      AND pg_temp.fc_has(r.newer_value, 'FA2X') AND pg_temp.fc_has(r.sent_value, 'FA2B') FROM public.grn_replacements r WHERE r.request_key = 'fc-10'),
  'B3b: a stored value with no field mark counts as someone else''s, with the person not known: ' || :'r10');

-- B10: the mark follows update_grn writes too (the online save), then an offline send over it names that person.
SELECT pg_temp.sf_update_grn(:'b_claims'::jsonb, :'grn',
  (SELECT jsonb_agg(CASE WHEN l->>'id' = :'lot_b' THEN l || '{"rack":"R6"}'::jsonb ELSE l END) FROM jsonb_array_elements(pg_temp.sf_current_lines(:'grn')) l)) AS upd \gset
SELECT pg_temp.fc_apply(:'sf_admin_claims'::jsonb, :'grn', pg_temp.fc_body(:'grn', :'tok0', now(),
  jsonb_build_object('lots', jsonb_build_object(:'lot_b', jsonb_build_object('rack', jsonb_build_object('from', 'R5', 'to', 'R4'))))), 'fc-11') AS r11 \gset
SELECT pg_temp.sf_assert((SELECT r.newer_by = :'b_profile'::uuid AND pg_temp.fc_has(r.newer_value, 'R6') FROM public.grn_replacements r WHERE r.request_key = 'fc-11'),
  'B10: the field mark of an update_grn write names its writer: ' || :'r11');
-- B10: a line written by save_grn is marked as added by its creator: an offline add after an older load sees it (the creator is the administrator).
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'FCG3', :'west'::uuid, pg_temp.sf_lines(:'cumin'::uuid, 1, 'FC', 5)) AS grn3 \gset
SELECT pg_temp.fc_apply(:'a_claims'::jsonb, :'grn3', pg_temp.fc_body(:'grn3', '2026-01-01T00:00:00Z', now(),
  jsonb_build_object('linesAdded', jsonb_build_array(jsonb_build_object('clientLineId', 'c-9', 'item_id', :'cumin', 'item_name', 'Field Change Cumin',
    'packaging', 'Bag', 'qty', 1, 'weight', 5, 'rack', 'R1', 'package_mark', 'FC9')))), 'fc-12') AS r12 \gset
SELECT pg_temp.sf_assert((SELECT count(*) = 1 FROM public.grn_replacements r WHERE r.grn_id = :'grn3' AND r.kind = 'line_added' AND r.sent_by = :'sf_admin_profile'::uuid),
  'B10: a line written by save_grn carries its creator in the field mark `line`: ' || :'r12');

-- B2: the same key again answers the first answer, at once and after 8 days, and writes nothing; another person's use is refused.
SELECT pg_temp.fc_apply(:'a_claims'::jsonb, :'grn', pg_temp.fc_body(:'grn', pg_temp.fc_token(:'grn'), now(),
  jsonb_build_object('linesAdded', jsonb_build_array(jsonb_build_object('clientLineId', 'c-idem', 'item_id', :'cumin', 'item_name', 'Field Change Cumin',
    'packaging', 'Bag', 'qty', 2, 'weight', 5, 'rack', 'R3', 'package_mark', 'IDEM')))), 'fc-idem') AS idem1 \gset
SELECT pg_temp.fc_entries(:'grn') AS idem_entries \gset
SELECT pg_temp.fc_apply(:'a_claims'::jsonb, :'grn', pg_temp.fc_body(:'grn', pg_temp.fc_token(:'grn'), now(),
  jsonb_build_object('linesAdded', jsonb_build_array(jsonb_build_object('clientLineId', 'c-idem', 'item_id', :'cumin', 'item_name', 'Field Change Cumin',
    'packaging', 'Bag', 'qty', 2, 'weight', 5, 'rack', 'R3', 'package_mark', 'IDEM')))), 'fc-idem') AS idem2 \gset
SELECT pg_temp.sf_assert(:'idem1'::jsonb->>'success' = 'true' AND NOT :'idem1'::jsonb ? 'idempotent' AND :'idem2'::jsonb->>'idempotent' = 'true'
  AND :'idem2'::jsonb - 'idempotent' = :'idem1'::jsonb AND (SELECT count(*) = 1 FROM public.goodsreceived_trl WHERE gr_id = :'grn' AND package_mark = 'IDEM')
  AND pg_temp.fc_entries(:'grn') = :idem_entries, 'B2: the repeated send answers the first answer, adds no line and no entry: ' || :'idem2');
UPDATE public.idempotency_keys SET created_at = created_at - interval '8 days', expires_at = expires_at - interval '8 days' WHERE idempotency_key = 'fc-idem';
SELECT pg_temp.fc_apply(:'a_claims'::jsonb, :'grn', pg_temp.fc_body(:'grn', pg_temp.fc_token(:'grn'), now(),
  jsonb_build_object('linesAdded', jsonb_build_array(jsonb_build_object('clientLineId', 'c-idem', 'item_id', :'cumin', 'item_name', 'Field Change Cumin',
    'packaging', 'Bag', 'qty', 2, 'weight', 5, 'rack', 'R3', 'package_mark', 'IDEM')))), 'fc-idem') AS idem3 \gset
SELECT pg_temp.sf_assert(:'idem3'::jsonb->>'idempotent' = 'true' AND :'idem3'::jsonb - 'idempotent' = :'idem1'::jsonb
  AND (SELECT count(*) = 1 FROM public.goodsreceived_trl WHERE gr_id = :'grn' AND package_mark = 'IDEM'),
  'B2: 8 days later the same key still answers the first answer and writes nothing (no 7-day expiry): ' || :'idem3');
SELECT pg_temp.sf_as(:'a_claims'::jsonb, 'SELECT public.get_submission_result(''fc-idem'')') AS sub \gset
SELECT pg_temp.sf_assert(:'sub'::jsonb->>'found' = 'true' AND :'sub'::jsonb#>>'{response,grn_id}' = :'grn', 'B2: get_submission_result answers the key too: ' || :'sub');
SELECT pg_temp.fc_apply(:'sf_admin_claims'::jsonb, :'grn', pg_temp.fc_body(:'grn', pg_temp.fc_token(:'grn'), now(),
  jsonb_build_object('header', jsonb_build_object('note', jsonb_build_object('from', 'A over B', 'to', 'Stolen key')))), 'fc-idem') AS idem_other \gset
SELECT pg_temp.sf_assert(:'idem_other'::jsonb->>'success' = 'false' AND (SELECT note IS DISTINCT FROM 'Stolen key' FROM public.goodsreceived WHERE id = :'grn'),
  'B2: a key used by another person is refused and writes nothing: ' || :'idem_other');

-- B4: quantity. Below what has left: refused with the figures; one refused change refuses the whole item (PQ1) and the answer lists each.
SELECT note AS note_before FROM public.goodsreceived WHERE id = :'grn' \gset
SELECT pg_temp.fc_entries(:'grn') AS entries_before \gset
SELECT pg_temp.fc_apply(:'a_claims'::jsonb, :'grn', pg_temp.fc_body(:'grn', pg_temp.fc_token(:'grn'), now(),
  jsonb_build_object('header', jsonb_build_object('note', jsonb_build_object('from', :'note_before', 'to', 'Must roll back')),
    'lots', jsonb_build_object(:'lot_a', jsonb_build_object('qty', jsonb_build_object('from', 50, 'to', 8))))), 'fc-12b') AS below \gset
SELECT pg_temp.sf_assert(:'below'::jsonb->>'success' = 'false' AND :'below'::jsonb->>'reason' = 'QTY_BELOW_DISPATCHED' AND :'below'::jsonb->>'lot_id' = :'lot_a'
  AND :'below'::jsonb->>'item_name' = 'Field Change Cumin' AND :'below'::jsonb->>'dispatched_qty' = '10' AND :'below'::jsonb->>'requested' = '8',
  'B4: 8 bags where 10 have left is refused with the lot and the figures: ' || :'below');
SELECT pg_temp.sf_assert((SELECT note = :'note_before' FROM public.goodsreceived WHERE id = :'grn') AND (SELECT qty = 50 AND stock = 40 FROM public.goodsreceived_trl WHERE id = :'lot_a')
  AND pg_temp.fc_entries(:'grn') = :entries_before, 'B5 / PQ1: the other change of the refused item was not written, and no entry was made');
SELECT pg_temp.fc_apply(:'a_claims'::jsonb, :'grn', pg_temp.fc_body(:'grn', pg_temp.fc_token(:'grn'), now(),
  jsonb_build_object('header', jsonb_build_object('date', jsonb_build_object('from', '2026-04-01T12:00:00Z', 'to', '2999-01-01T00:00:00Z')),
    'lots', jsonb_build_object(:'lot_a', jsonb_build_object('qty', jsonb_build_object('from', 50, 'to', 8))))), 'fc-13') AS two_refused \gset
SELECT pg_temp.sf_assert(:'two_refused'::jsonb->>'success' = 'false' AND (SELECT array_agg(e->>'code' ORDER BY e->>'code') = ARRAY['GRN_DATE_FUTURE', 'QTY_BELOW_DISPATCHED']
      FROM jsonb_array_elements(:'two_refused'::jsonb->'refused') e) AND (SELECT bool_and(e->>'path' IS NOT NULL) FROM jsonb_array_elements(:'two_refused'::jsonb->'refused') e),
  'B5 / PQ1: two refused changes: the answer lists both with their paths: ' || :'two_refused');
-- a quantity at or above what has left is written, stock = qty - dispatched
SELECT pg_temp.fc_apply(:'a_claims'::jsonb, :'grn', pg_temp.fc_body(:'grn', pg_temp.fc_token(:'grn'), now(),
  jsonb_build_object('lots', jsonb_build_object(:'lot_a', jsonb_build_object('qty', jsonb_build_object('from', 50, 'to', 12))))), 'fc-14') AS above \gset
SELECT pg_temp.sf_assert(:'above'::jsonb->>'success' = 'true' AND (SELECT qty = 12 AND stock = 2 FROM public.goodsreceived_trl WHERE id = :'lot_a'),
  'B4: 12 bags where 10 have left is accepted, stock 2: ' || :'above');
SELECT pg_temp.fc_apply(:'a_claims'::jsonb, :'grn', pg_temp.fc_body(:'grn', pg_temp.fc_token(:'grn'), now(),
  jsonb_build_object('lots', jsonb_build_object(:'lot_a', jsonb_build_object('qty', jsonb_build_object('from', 12, 'to', 10))))), 'fc-14b') AS equal \gset
SELECT pg_temp.sf_assert(:'equal'::jsonb->>'success' = 'true' AND (SELECT qty = 10 AND stock = 0 FROM public.goodsreceived_trl WHERE id = :'lot_a'),
  'B4: a quantity equal to what has left is accepted: ' || :'equal');
-- a change whose "to" equals the stored value is applied and writes nothing
SELECT pg_temp.fc_entries(:'grn') AS entries_noop \gset
SELECT pg_temp.fc_apply(:'a_claims'::jsonb, :'grn', pg_temp.fc_body(:'grn', pg_temp.fc_token(:'grn'), now(),
  jsonb_build_object('lots', jsonb_build_object(:'lot_a', jsonb_build_object('qty', jsonb_build_object('from', 50, 'to', 10))))), 'fc-14c') AS noop \gset
SELECT pg_temp.sf_assert(:'noop'::jsonb->>'success' = 'true' AND pg_temp.fc_entries(:'grn') = :entries_noop AND (SELECT qty = 10 AND stock = 0 FROM public.goodsreceived_trl WHERE id = :'lot_a'),
  'B1: a change whose to equals the stored value is a success that writes nothing and raises no entry (the stored 10 differs from its from 50 but equals its to): ' || :'noop');

-- B5: the refusals that need no fixture of their own.
SELECT pg_temp.fc_apply(:'a_claims'::jsonb, gen_random_uuid(), pg_temp.fc_body(:'grn', now(), now(), jsonb_build_object('header', jsonb_build_object('note', jsonb_build_object('from', NULL, 'to', 'x')))), 'fc-15') AS no_grn \gset
SELECT pg_temp.sf_assert(:'no_grn'::jsonb->>'success' = 'false' AND :'no_grn'::jsonb->>'reason' = 'GRN_NOT_FOUND', 'B5: a GRN that does not exist is GRN_NOT_FOUND: ' || :'no_grn');
SELECT pg_temp.fc_apply(:'a_claims'::jsonb, :'grn', pg_temp.fc_body(:'grn', now(), now(), jsonb_build_object('lots', jsonb_build_object(gen_random_uuid()::text,
  jsonb_build_object('rack', jsonb_build_object('from', 'R1', 'to', 'R2'))))), 'fc-16') AS no_lot \gset
SELECT pg_temp.sf_assert(:'no_lot'::jsonb->>'success' = 'false' AND :'no_lot'::jsonb->>'reason' = 'LOT_NOT_FOUND', 'B5: a lot that does not exist is LOT_NOT_FOUND: ' || :'no_lot');
SELECT pg_temp.fc_apply(:'a_claims'::jsonb, :'grn', pg_temp.fc_body(:'grn', now(), now(), jsonb_build_object('linesRemoved', jsonb_build_array(
  jsonb_build_object('lotId', :'lot_a', 'item_name', 'Field Change Cumin', 'qty', 10)))), 'fc-17') AS rm_dispatched \gset
SELECT pg_temp.sf_assert(:'rm_dispatched'::jsonb->>'success' = 'false' AND :'rm_dispatched'::jsonb->>'reason' = 'LINE_DISPATCHED_BEFORE'
  AND (SELECT count(*) = 1 FROM public.goodsreceived_trl WHERE id = :'lot_a'), 'B5: a line with dispatches is not removed: ' || :'rm_dispatched');
-- a line nothing depends on is removed, and the answer lists it
SELECT pg_temp.fc_apply(:'a_claims'::jsonb, :'grn', pg_temp.fc_body(:'grn', pg_temp.fc_token(:'grn'), now(), jsonb_build_object('linesRemoved', jsonb_build_array(
  jsonb_build_object('lotId', :'lot_c', 'item_name', 'Field Change Cumin', 'qty', 7)))), 'fc-18') AS rm_free \gset
SELECT pg_temp.sf_assert(:'rm_free'::jsonb->>'success' = 'true' AND :'rm_free'::jsonb->'lines_removed' ? :'lot_c'
  AND (SELECT count(*) = 0 FROM public.goodsreceived_trl WHERE id = :'lot_c'), 'B5: an undispatched line is removed and listed: ' || :'rm_free');
-- a change to a line deleted meanwhile is refused (contract card: "A change to a line deleted meanwhile is refused")
SELECT pg_temp.fc_apply(:'b_claims'::jsonb, :'grn', pg_temp.fc_body(:'grn', :'tok0', now(), jsonb_build_object('lots', jsonb_build_object(:'lot_c',
  jsonb_build_object('rack', jsonb_build_object('from', 'R7', 'to', 'R1'))))), 'fc-19') AS deleted_line \gset
SELECT pg_temp.sf_assert(:'deleted_line'::jsonb->>'success' = 'false' AND :'deleted_line'::jsonb->>'reason' = 'LOT_NOT_FOUND', 'B5: a change to a line deleted meanwhile is refused: ' || :'deleted_line');

-- B6: an imported GRN refuses every field here.
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'FCG2', :'west'::uuid, pg_temp.sf_lines(:'cumin'::uuid, 1, 'FI', 5)) AS grn_imp \gset
BEGIN;
SET LOCAL session_replication_role = replica;
UPDATE public.goodsreceived SET import_batch_id = gen_random_uuid() WHERE id = :'grn_imp';
COMMIT;
SELECT pg_temp.fc_apply(:'a_claims'::jsonb, :'grn_imp', pg_temp.fc_body(:'grn_imp', pg_temp.fc_token(:'grn_imp'), now(),
  jsonb_build_object('header', jsonb_build_object('note', jsonb_build_object('from', NULL, 'to', 'Imported change')))), 'fc-20') AS imported \gset
SELECT pg_temp.sf_assert(:'imported'::jsonb->>'success' = 'false' AND :'imported'::jsonb->>'reason' = 'IMPORTED_READ_ONLY'
  AND (SELECT note IS DISTINCT FROM 'Imported change' FROM public.goodsreceived WHERE id = :'grn_imp'), 'B6: an imported GRN is IMPORTED_READ_ONLY: ' || :'imported');

-- B7: a success moves the version token: an online save made from the earlier token is refused as out of date.
BEGIN;
SET LOCAL session_replication_role = replica;
UPDATE public.goodsreceived SET updated_at = '2026-01-01T00:00:00Z' WHERE id = :'grn3';
COMMIT;
SELECT pg_temp.fc_apply(:'a_claims'::jsonb, :'grn3', pg_temp.fc_body(:'grn3', '2026-01-01T00:00:00Z', now(),
  jsonb_build_object('header', jsonb_build_object('note', jsonb_build_object('from', NULL, 'to', 'Moves the token')))), 'fc-21') AS moves \gset
SELECT pg_temp.sf_assert(:'moves'::jsonb->>'success' = 'true' AND pg_temp.fc_token(:'grn3') > '2026-01-01T00:00:00Z', 'B7: apply_grn_changes moves updated_at: ' || :'moves');
SELECT pg_temp.sf_as(:'b_claims'::jsonb, format('SELECT public.update_grn(p_grn_id => %L::uuid, p_note => %L, p_items => %L::jsonb, p_expected_updated_at => %L::timestamptz)',
  :'grn3', 'Online from the old token', pg_temp.sf_current_lines(:'grn3'), '2026-01-01T00:00:00Z')) AS stale \gset
SELECT pg_temp.sf_assert(:'stale'::jsonb->>'success' = 'false' AND :'stale'::jsonb->>'reason' = 'STALE_RECORD', 'B7: the online save from the older token is refused: ' || :'stale');

-- B8: who may send. Supervisor and staff may; a customer account and a caller with no role may not, and nothing is written.
SELECT pg_temp.fc_apply(:'sup_claims'::jsonb, :'grn3', pg_temp.fc_body(:'grn3', pg_temp.fc_token(:'grn3'), now(),
  jsonb_build_object('header', jsonb_build_object('note', jsonb_build_object('from', 'Moves the token', 'to', 'Supervisor note')))), 'fc-22') AS sup \gset
SELECT pg_temp.sf_assert(:'sup'::jsonb->>'success' = 'true', 'B8: a supervisor may send: ' || :'sup');
SELECT pg_temp.sf_try('authenticated', :'reader_claims'::jsonb, format('SELECT public.apply_grn_changes(%L::uuid, %L::jsonb, %L)', :'grn3',
  pg_temp.fc_body(:'grn3', now(), now(), jsonb_build_object('header', jsonb_build_object('note', jsonb_build_object('from', 'Supervisor note', 'to', 'Customer note')))), 'fc-23')) AS cust \gset
SELECT pg_temp.sf_try('authenticated', NULL, format('SELECT public.apply_grn_changes(%L::uuid, %L::jsonb, %L)', :'grn3',
  pg_temp.fc_body(:'grn3', now(), now(), jsonb_build_object('header', jsonb_build_object('note', jsonb_build_object('from', 'Supervisor note', 'to', 'Nobody note')))), 'fc-24')) AS nobody \gset
SELECT pg_temp.sf_assert(COALESCE(:'cust'::jsonb#>>'{answer,success}', 'raised') <> 'true' AND COALESCE(:'nobody'::jsonb#>>'{answer,success}', 'raised') <> 'true'
  AND (SELECT note = 'Supervisor note' FROM public.goodsreceived WHERE id = :'grn3'),
  'B8: a customer account and a caller with no role are refused and write nothing: ' || :'cust' || ' / ' || :'nobody');
SELECT pg_temp.sf_assert((SELECT NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'apply_grn_changes'), 'B8: apply_grn_changes is granted to the app role and not to anon');

\echo 'WH-303 edit GRN by field changes (B1-B10) checks passed.'

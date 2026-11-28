-- WH-304, backend topic "held item photos" (slice B-5; contract ~/ws/fresh/product/tech/app-offline-holding-list.md sections 2.5 and 11.6):
--   public.register_held_photo_upload(p_held_id, p_client_photo_id, p_role, p_file_name, p_file_size, p_mime_type, p_line_ref DEFAULT NULL)
--     -> { success, held_id, client_photo_id, storage_path, bucket, status }, a refusal is { success: false, code, ... };
--   public.confirm_held_photo_upload(p_held_id, p_client_photo_id) -> { success, ..., status: 'confirmed' } or a refusal;
--   warehouse_security.held_photo_refusal (no app role), held_photo_file_access(bucket, name, write) and held_photo_file_named(name)
--     (authenticated), and the staff / manager policies of scripts/configure-storage.sql that call them.
-- Written after the build, from migrations/00000000000240_held_item_photos_upload.sql. Fictional data; rolls back at the end. Runs only in migrations.sh
-- (the real Storage tables and the policies of configure-storage.sql are there; storage.allow_delete_query is 'true' for the suite).
-- What the suite guards (label prefix): G1 register then confirm, G2 a resend answers the same row, G3 refusals of register and confirm
-- (other people, decided items, bad input, missing file), G4 accept attaches only confirmed photos and reject keeps them, G5 staff storage
-- rights, G6 a manager cannot delete a file a held photo names, G7 who may execute what.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.hp_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'held items photos 304: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.hp_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c jsonb; l jsonb; claims jsonb;
BEGIN
  c := public.operator_prepare_otp(phone);
  PERFORM pg_temp.hp_assert(c->>'success' = 'true', 'challenge prepared for ' || phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  l := public.operator_verify_otp(phone, c#>>'{data,otp_code}');
  PERFORM pg_temp.hp_assert(l#>>'{data,action}' = 'login', 'login for ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', r.id) INTO claims
    FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- The jsonb answer of a statement run as the signed-in caller, or {"raised": message, "state": sqlstate}.
CREATE FUNCTION pg_temp.hp_as(claims jsonb, statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims', claims::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN answer := jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  EXECUTE 'RESET ROLE';
  RETURN answer;
END $$;
-- A data statement (insert, delete) as the signed-in caller: 'rows:<n>' or 'raised:<sqlstate>'.
CREATE FUNCTION pg_temp.hp_sql(claims jsonb, statement text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE n integer; result text;
BEGIN
  PERFORM set_config('request.jwt.claims', claims::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE statement; GET DIAGNOSTICS n = ROW_COUNT; result := 'rows:' || n;
  EXCEPTION WHEN OTHERS THEN result := 'raised:' || SQLSTATE; END;
  EXECUTE 'RESET ROLE';
  RETURN result;
END $$;
CREATE FUNCTION pg_temp.hp_ok(a jsonb) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$ SELECT NOT (a ? 'raised') AND a->>'success' = 'true' $$;
-- True when the answer is a refusal carrying the code (anywhere in its text) and not a success.
CREATE FUNCTION pg_temp.hp_refused(a jsonb, code text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT NOT (a ? 'raised') AND a->>'success' IS DISTINCT FROM 'true' AND a::text LIKE '%' || code || '%' $$;
CREATE FUNCTION pg_temp.hp_hid(key text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM public.held_items WHERE request_key = key $$;
CREATE FUNCTION pg_temp.hp_state(key text) RETURNS text LANGUAGE sql AS $$ SELECT state FROM public.held_items WHERE request_key = key $$;
CREATE FUNCTION pg_temp.hp_n() RETURNS bigint LANGUAGE sql AS $$ SELECT count(*) FROM public.held_item_photos $$;
CREATE FUNCTION pg_temp.hp_reg(claims jsonb, held uuid, cid text, role text, fname text, size integer, mime text, line text DEFAULT NULL) RETURNS jsonb
  LANGUAGE sql AS $$
  SELECT pg_temp.hp_as(claims, format('SELECT public.register_held_photo_upload(%L::uuid, %L, %L, %L, %L::integer, %L, %L)',
    held, cid, role, fname, size, mime, line)) $$;
CREATE FUNCTION pg_temp.hp_confirm(claims jsonb, held uuid, cid text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.hp_as(claims, format('SELECT public.confirm_held_photo_upload(%L::uuid, %L)', held, cid)) $$;
CREATE FUNCTION pg_temp.hp_path(held uuid, cid text) RETURNS text LANGUAGE sql AS $$
  SELECT path FROM public.held_item_photos WHERE held_id = held AND client_photo_id = cid $$;
CREATE FUNCTION pg_temp.hp_photo_state(held uuid, cid text) RETURNS text LANGUAGE sql AS $$
  SELECT state FROM public.held_item_photos WHERE held_id = held AND client_photo_id = cid $$;
CREATE FUNCTION pg_temp.hp_put(claims jsonb, bucket text, name text) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.hp_sql(claims, format('INSERT INTO storage.objects(bucket_id, name) VALUES (%L, %L)', bucket, name)) $$;
CREATE FUNCTION pg_temp.hp_del(claims jsonb, bucket text, name text) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.hp_sql(claims, format('DELETE FROM storage.objects WHERE bucket_id = %L AND name = %L', bucket, name)) $$;
CREATE FUNCTION pg_temp.hp_see(claims jsonb, bucket text, name text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.hp_as(claims, format('SELECT to_jsonb(count(*)) FROM storage.objects WHERE bucket_id = %L AND name = %L', bucket, name)) $$;
CREATE FUNCTION pg_temp.hp_access(claims jsonb, bucket text, name text, write boolean) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.hp_as(claims, format('SELECT to_jsonb(warehouse_security.held_photo_file_access(%L, %L, %L::boolean))', bucket, name, write)) $$;
CREATE FUNCTION pg_temp.hp_item(key text, kind text, seq int, cust uuid, body jsonb, extra jsonb DEFAULT '{}'::jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('request_key', key, 'kind', kind, 'body', body, 'seq', seq, 'recorded_at', now() - interval '2 hours',
    'what', jsonb_build_object('document', kind, 'number', key), 'customer_id', cust,
    'refusal', jsonb_build_object('code', 'STOCK_SHORT', 'reason', 'Insufficient stock')) || extra $$;
CREATE FUNCTION pg_temp.hp_grn_body(cust uuid, item uuid, qty int, no text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('args', jsonb_build_object('p_sender_name', 'Photo Sender',
    'p_supervisor_id', (SELECT id FROM public.user_profiles WHERE name = 'Photo Administrator'), 'p_supervisor_name', 'Photo Administrator',
    'p_gr_no', no, 'p_date', '2026-04-01T12:00:00Z', 'p_customer_id', cust, 'p_customer_name', 'Photo Customer A', 'p_pricing_mode', 'ONE_TIME',
    'p_issue_number', no = '', 'p_recorded_at', now() - interval '2 hours',
    'p_items', jsonb_build_array(jsonb_build_object('item_id', item, 'item_name', 'Photo Cumin', 'packaging', 'Bag', 'qty', qty, 'weight', 10, 'rack', 'N1', 'package_mark', 'NM')))) $$;
CREATE FUNCTION pg_temp.hp_hold(claims jsonb, items jsonb, recorder uuid DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.hp_as(claims, format('SELECT public.hold_items(%L::jsonb, %L::uuid)', items, recorder)) $$;
CREATE FUNCTION pg_temp.hp_decide(claims jsonb, id uuid, action text, key text, reason text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.hp_as(claims, format('SELECT public.decide_held_item(%L::uuid, %L, %L, %L, NULL::jsonb)', id, action, key, reason)) $$;

-- ===== people and the catalogue =====
INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST'
 WHERE id = (SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888885301', 'Photo Administrator') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888885302', 'Photo Supervisor', 'supervisor', true, 'approved'),
 (gen_random_uuid(), '919888885303', 'Photo Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888885304', 'Photo Customer Account', 'customer', true, 'approved'),
 (gen_random_uuid(), '919888885305', 'Photo Second Staff', 'staff', true, 'approved');
SELECT pg_temp.hp_login('9888885301') AS admin_claims \gset
SELECT pg_temp.hp_login('9888885302') AS supervisor_claims \gset
SELECT pg_temp.hp_login('9888885303') AS staff_claims \gset
SELECT pg_temp.hp_login('9888885304') AS customer_claims \gset
SELECT pg_temp.hp_login('9888885305') AS staff2_claims \gset
SELECT id AS staff_profile FROM public.user_profiles WHERE mobile = '919888885303' \gset
SELECT auth_user_id AS staff_auth FROM public.user_profiles WHERE mobile = '919888885303' \gset
SELECT pg_temp.hp_assert(pg_temp.hp_as(:'admin_claims'::jsonb, $q$SELECT public.create_customer('Photo Customer A', '9888885311')$q$)->>'success' = 'true', 'customer');
SELECT pg_temp.hp_assert(pg_temp.hp_as(:'admin_claims'::jsonb, $q$SELECT public.create_item('Photo Cumin', 'Bag')$q$)->>'success' = 'true', 'item');
SELECT id AS ca FROM public.customers WHERE name = 'Photo Customer A' \gset
SELECT id AS item_id FROM public.items WHERE name = 'Photo Cumin' \gset

-- Held items: g1 (accepted below), g2 (rejected below), g3 (stays held), m1 (moved by the administrator for the staff person).
SELECT pg_temp.hp_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hp_item('hp-g1', 'newGrn', 1, :'ca'::uuid, pg_temp.hp_grn_body(:'ca'::uuid, :'item_id'::uuid, 2, 'HPG1')),
  pg_temp.hp_item('hp-g2', 'newGrn', 2, :'ca'::uuid, pg_temp.hp_grn_body(:'ca'::uuid, :'item_id'::uuid, 2, 'HPG2')),
  pg_temp.hp_item('hp-g3', 'newGrn', 3, :'ca'::uuid, pg_temp.hp_grn_body(:'ca'::uuid, :'item_id'::uuid, 2, 'HPG3')))) AS fx_hold \gset
SELECT pg_temp.hp_assert(:'fx_hold'::jsonb->>'success' = 'true', 'fixture: hand over: ' || :'fx_hold');
SELECT pg_temp.hp_hold(:'admin_claims'::jsonb, jsonb_build_array(
  pg_temp.hp_item('hp-m1', 'newGrn', 4, :'ca'::uuid, pg_temp.hp_grn_body(:'ca'::uuid, :'item_id'::uuid, 2, 'HPM1'), jsonb_build_object('refusal', NULL))),
  :'staff_auth'::uuid) AS fx_move \gset
SELECT pg_temp.hp_assert(:'fx_move'::jsonb->>'success' = 'true' AND (SELECT recorded_by = :'staff_profile'::uuid AND handed_by <> recorded_by
  FROM public.held_items WHERE request_key = 'hp-m1'), 'fixture: the administrator moved hp-m1 for the staff person: ' || :'fx_move');
SELECT pg_temp.hp_hid('hp-g1') AS g1, pg_temp.hp_hid('hp-g2') AS g2, pg_temp.hp_hid('hp-g3') AS g3, pg_temp.hp_hid('hp-m1') AS m1 \gset
SELECT pg_temp.hp_assert(pg_temp.hp_n() = 0, 'premise: no held photos yet');

-- ===== G1. Register then confirm =====
SELECT pg_temp.hp_reg(:'staff_claims'::jsonb, :'g1'::uuid, 'ph-a', 'header', 'front.jpg', 1000, 'image/jpeg') AS g1_a \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'g1_a'::jsonb) AND :'g1_a'::jsonb->>'held_id' = :'g1' AND :'g1_a'::jsonb->>'client_photo_id' = 'ph-a'
  AND :'g1_a'::jsonb->>'bucket' = 'grn-images' AND :'g1_a'::jsonb->>'status' = 'pending'
  AND starts_with(:'g1_a'::jsonb->>'storage_path', 'held/' || :'g1' || '/') AND :'g1_a'::jsonb->>'storage_path' LIKE '%front.jpg',
  'G1: register answers the held path of grn-images and status pending: ' || :'g1_a');
SELECT pg_temp.hp_assert((SELECT state = 'pending' AND role = 'header' AND line_ref IS NULL AND file_name = 'front.jpg' AND file_size = 1000
    AND mime_type = 'image/jpeg' AND uploaded_by = :'staff_profile'::uuid AND path = :'g1_a'::jsonb->>'storage_path'
  FROM public.held_item_photos WHERE held_id = :'g1'::uuid AND client_photo_id = 'ph-a'), 'G1: the row is pending and keeps the file facts and the recorder as uploader');
SELECT pg_temp.hp_reg(:'staff_claims'::jsonb, :'g1'::uuid, 'ph-b', 'item', 'lot one.jpg', 2000, 'image/png', ' index:0 ') AS g1_b \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'g1_b'::jsonb) AND :'g1_b'::jsonb->>'bucket' = 'grn-images'
  AND :'g1_b'::jsonb->>'storage_path' LIKE '%lot_one.jpg' AND (SELECT line_ref = 'index:0' FROM public.held_item_photos WHERE held_id = :'g1'::uuid AND client_photo_id = 'ph-b'),
  'G1: an item photo keeps its trimmed line, an unsafe file name is made safe in the path: ' || :'g1_b');
SELECT pg_temp.hp_reg(:'staff_claims'::jsonb, :'g1'::uuid, 'ph-c', 'header', 'late.webp', 10485760, 'image/webp', 'ignored') AS g1_c \gset
SELECT pg_temp.hp_reg(:'staff_claims'::jsonb, :'g1'::uuid, 'ph-d', 'header', 'tiny.jpg', 1, 'image/jpeg') AS g1_d \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'g1_c'::jsonb) AND pg_temp.hp_ok(:'g1_d'::jsonb)
  AND (SELECT line_ref IS NULL FROM public.held_item_photos WHERE held_id = :'g1'::uuid AND client_photo_id = 'ph-c'),
  'G1: 10 MB and 1 byte are the accepted limits, and a header photo keeps no line: ' || :'g1_c' || ' / ' || :'g1_d');
SELECT pg_temp.hp_reg(:'staff_claims'::jsonb, :'g3'::uuid, 'ph-disp', 'dispatch', 'truck.jpg', 500, 'image/jpeg') AS g3_disp \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'g3_disp'::jsonb) AND :'g3_disp'::jsonb->>'bucket' = 'dispatch-images'
  AND starts_with(:'g3_disp'::jsonb->>'storage_path', 'held/' || :'g3' || '/'), 'G1: a dispatch photo goes to dispatch-images under the held id: ' || :'g3_disp');
-- Confirm before any file is there: the row stays pending.
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'g1'::uuid, 'ph-a') AS g1_nofile \gset
SELECT pg_temp.hp_assert(pg_temp.hp_refused(:'g1_nofile'::jsonb, 'IMAGE_NOT_VERIFIED') AND pg_temp.hp_photo_state(:'g1'::uuid, 'ph-a') = 'pending',
  'G3: confirm with no file in storage is IMAGE_NOT_VERIFIED and the row stays pending: ' || :'g1_nofile');
-- The phone uploads the files (G5 checks the storage rule on each): a, b and c; d only after the second confirm try.
SELECT pg_temp.hp_assert(pg_temp.hp_put(:'staff_claims'::jsonb, 'grn-images', pg_temp.hp_path(:'g1'::uuid, 'ph-a')) = 'rows:1', 'G5: staff upload their own pending held file a');
SELECT pg_temp.hp_assert(pg_temp.hp_put(:'staff_claims'::jsonb, 'grn-images', pg_temp.hp_path(:'g1'::uuid, 'ph-b')) = 'rows:1', 'G5: staff upload their own pending held file b');
SELECT pg_temp.hp_assert(pg_temp.hp_put(:'staff_claims'::jsonb, 'grn-images', pg_temp.hp_path(:'g1'::uuid, 'ph-c')) = 'rows:1', 'G5: staff upload their own pending held file c');
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'g1'::uuid, 'ph-a') AS g1_conf_a \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'g1_conf_a'::jsonb) AND :'g1_conf_a'::jsonb->>'status' = 'confirmed'
  AND :'g1_conf_a'::jsonb->>'storage_path' = pg_temp.hp_path(:'g1'::uuid, 'ph-a') AND pg_temp.hp_photo_state(:'g1'::uuid, 'ph-a') = 'confirmed',
  'G1: confirm with the file in storage marks the row confirmed: ' || :'g1_conf_a');
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'g1'::uuid, 'ph-a') AS g1_conf_a2 \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'g1_conf_a2'::jsonb) AND :'g1_conf_a2'::jsonb->>'status' = 'confirmed', 'G2: a second confirm answers the same confirmed row: ' || :'g1_conf_a2');
SELECT pg_temp.hp_assert(pg_temp.hp_ok(pg_temp.hp_confirm(:'staff_claims'::jsonb, :'g1'::uuid, 'ph-b')) AND pg_temp.hp_photo_state(:'g1'::uuid, 'ph-b') = 'confirmed',
  'G1: the item photo is confirmed too');
SELECT pg_temp.hp_assert(pg_temp.hp_photo_state(:'g1'::uuid, 'ph-c') = 'pending' AND pg_temp.hp_photo_state(:'g1'::uuid, 'ph-d') = 'pending',
  'G1: photos c (uploaded, never confirmed) and d (no file yet) are still pending');

-- ===== G2. A resend answers the same row =====
SELECT pg_temp.hp_n() AS n_g2 \gset
SELECT pg_temp.hp_reg(:'staff_claims'::jsonb, :'g1'::uuid, 'ph-a', 'header', 'front.jpg', 1000, 'image/jpeg') AS g2_again \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'g2_again'::jsonb) AND :'g2_again'::jsonb->>'storage_path' = :'g1_a'::jsonb->>'storage_path'
  AND :'g2_again'::jsonb->>'status' = 'confirmed' AND pg_temp.hp_n() = :'n_g2'::bigint,
  'G2: registering the same client photo id again answers the same path (now confirmed) and adds no row: ' || :'g2_again');
SELECT pg_temp.hp_reg(:'staff_claims'::jsonb, :'g1'::uuid, 'ph-c', 'header', 'renamed.webp', 20, 'image/webp') AS g2_pending \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'g2_pending'::jsonb) AND :'g2_pending'::jsonb->>'storage_path' = :'g1_c'::jsonb->>'storage_path'
  AND :'g2_pending'::jsonb->>'status' = 'pending' AND pg_temp.hp_n() = :'n_g2'::bigint
  AND (SELECT file_name = 'late.webp' AND file_size = 10485760 FROM public.held_item_photos WHERE held_id = :'g1'::uuid AND client_photo_id = 'ph-c'),
  'G2: a resend of a pending photo answers the first path and leaves the first file facts: ' || :'g2_pending');
-- The same client photo id under another held item is its own photo.
SELECT pg_temp.hp_reg(:'staff_claims'::jsonb, :'g2'::uuid, 'ph-a', 'header', 'front.jpg', 1000, 'image/jpeg') AS g2_other \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'g2_other'::jsonb) AND :'g2_other'::jsonb->>'storage_path' <> :'g1_a'::jsonb->>'storage_path'
  AND starts_with(:'g2_other'::jsonb->>'storage_path', 'held/' || :'g2' || '/'), 'G2: the same client photo id under another held item is a new row under that item: ' || :'g2_other');

-- ===== G3. Refusals while the item is still held: nothing is written =====
SELECT pg_temp.hp_n() AS n_g3 \gset
SELECT pg_temp.hp_reg(:'staff2_claims'::jsonb, :'g1'::uuid, 'ph-x', 'header', 'x.jpg', 10, 'image/jpeg') AS g3_other \gset
SELECT pg_temp.hp_reg(:'supervisor_claims'::jsonb, :'g1'::uuid, 'ph-x', 'header', 'x.jpg', 10, 'image/jpeg') AS g3_super \gset
SELECT pg_temp.hp_reg(:'admin_claims'::jsonb, :'g1'::uuid, 'ph-x', 'header', 'x.jpg', 10, 'image/jpeg') AS g3_admin_other \gset
SELECT pg_temp.hp_assert(pg_temp.hp_refused(:'g3_other'::jsonb, 'HELD_PHOTO_NOT_YOURS') AND pg_temp.hp_refused(:'g3_super'::jsonb, 'HELD_PHOTO_NOT_YOURS')
  AND pg_temp.hp_refused(:'g3_admin_other'::jsonb, 'HELD_PHOTO_NOT_YOURS') AND pg_temp.hp_n() = :'n_g3'::bigint,
  'G3: another staff person, a supervisor and an administrator who did not hand the item over get HELD_PHOTO_NOT_YOURS and write nothing: '
  || :'g3_other' || ' / ' || :'g3_super' || ' / ' || :'g3_admin_other');
SELECT pg_temp.hp_reg(:'customer_claims'::jsonb, :'g1'::uuid, 'ph-x', 'header', 'x.jpg', 10, 'image/jpeg') AS g3_customer \gset
SELECT pg_temp.hp_assert(:'g3_customer'::jsonb->>'state' = '42501' AND pg_temp.hp_n() = :'n_g3'::bigint, 'G3: a customer account is refused by the gate: ' || :'g3_customer');
SELECT pg_temp.hp_reg(jsonb_build_object('role', 'authenticated', 'sub', gen_random_uuid()), :'g1'::uuid, 'ph-x', 'header', 'x.jpg', 10, 'image/jpeg') AS g3_norole \gset
SELECT pg_temp.hp_assert(:'g3_norole'::jsonb->>'state' = '42501', 'G3: a caller with no profile is refused: ' || :'g3_norole');
SELECT pg_temp.hp_assert(pg_temp.hp_refused(pg_temp.hp_confirm(:'staff2_claims'::jsonb, :'g1'::uuid, 'ph-c'), 'HELD_PHOTO_NOT_YOURS')
  AND pg_temp.hp_refused(pg_temp.hp_confirm(:'supervisor_claims'::jsonb, :'g1'::uuid, 'ph-c'), 'HELD_PHOTO_NOT_YOURS')
  AND pg_temp.hp_confirm(:'customer_claims'::jsonb, :'g1'::uuid, 'ph-c')->>'state' = '42501' AND pg_temp.hp_photo_state(:'g1'::uuid, 'ph-c') = 'pending',
  'G3: other staff and a supervisor cannot confirm the recorder''s photo, a customer account is refused, the row stays pending');
SELECT pg_temp.hp_assert(pg_temp.hp_refused(pg_temp.hp_reg(:'staff_claims'::jsonb, gen_random_uuid(), 'ph-x', 'header', 'x.jpg', 10, 'image/jpeg'), 'HELD_NOT_FOUND')
  AND pg_temp.hp_refused(pg_temp.hp_confirm(:'staff_claims'::jsonb, gen_random_uuid(), 'ph-x'), 'HELD_NOT_FOUND'), 'G3: an unknown held item is HELD_NOT_FOUND');
SELECT pg_temp.hp_assert(pg_temp.hp_refused(pg_temp.hp_confirm(:'staff_claims'::jsonb, :'g1'::uuid, 'ph-never'), 'HELD_PHOTO_NOT_FOUND'),
  'G3: confirming a photo that was never registered is HELD_PHOTO_NOT_FOUND');
-- Bad input: each is HELD_PHOTO_INVALID.
SELECT pg_temp.hp_assert(bool_and(pg_temp.hp_refused(r, 'HELD_PHOTO_INVALID')) AND pg_temp.hp_n() = :'n_g3'::bigint,
  'G3: bad input is HELD_PHOTO_INVALID and writes nothing: ' || string_agg(left(r::text, 120), ' | '))
FROM (VALUES
  (pg_temp.hp_reg(:'staff_claims'::jsonb, :'g1'::uuid, 'ph-y', 'header', 'x.pdf', 10, 'application/pdf')),
  (pg_temp.hp_reg(:'staff_claims'::jsonb, :'g1'::uuid, 'ph-y', 'header', 'x.gif', 10, 'image/gif')),
  (pg_temp.hp_reg(:'staff_claims'::jsonb, :'g1'::uuid, 'ph-y', 'header', 'x.jpg', 10, NULL)),
  (pg_temp.hp_reg(:'staff_claims'::jsonb, :'g1'::uuid, 'ph-y', 'header', 'x.jpg', 0, 'image/jpeg')),
  (pg_temp.hp_reg(:'staff_claims'::jsonb, :'g1'::uuid, 'ph-y', 'header', 'x.jpg', 10485761, 'image/jpeg')),
  (pg_temp.hp_reg(:'staff_claims'::jsonb, :'g1'::uuid, 'ph-y', 'header', 'x.jpg', NULL, 'image/jpeg')),
  (pg_temp.hp_reg(:'staff_claims'::jsonb, :'g1'::uuid, 'ph-y', 'header', '   ', 10, 'image/jpeg')),
  (pg_temp.hp_reg(:'staff_claims'::jsonb, :'g1'::uuid, '  ', 'header', 'x.jpg', 10, 'image/jpeg')),
  (pg_temp.hp_reg(:'staff_claims'::jsonb, :'g1'::uuid, 'ph-y', 'banner', 'x.jpg', 10, 'image/jpeg')),
  (pg_temp.hp_reg(:'staff_claims'::jsonb, :'g1'::uuid, 'ph-y', NULL, 'x.jpg', 10, 'image/jpeg')),
  (pg_temp.hp_reg(:'staff_claims'::jsonb, :'g1'::uuid, 'ph-y', 'item', 'x.jpg', 10, 'image/jpeg')),
  (pg_temp.hp_reg(:'staff_claims'::jsonb, :'g1'::uuid, 'ph-y', 'item', 'x.jpg', 10, 'image/jpeg', '   ')),
  (pg_temp.hp_reg(:'staff_claims'::jsonb, :'g1'::uuid, repeat('i', 101), 'header', 'x.jpg', 10, 'image/jpeg'))) v(r);
-- The administrator who moved an item may add its photos; a supervisor may not.
SELECT pg_temp.hp_reg(:'admin_claims'::jsonb, :'m1'::uuid, 'ph-m', 'header', 'moved.jpg', 300, 'image/jpeg') AS g3_moved_admin \gset
SELECT pg_temp.hp_reg(:'staff_claims'::jsonb, :'m1'::uuid, 'ph-m2', 'header', 'moved.jpg', 300, 'image/jpeg') AS g3_moved_staff \gset
SELECT pg_temp.hp_reg(:'supervisor_claims'::jsonb, :'m1'::uuid, 'ph-m3', 'header', 'moved.jpg', 300, 'image/jpeg') AS g3_moved_super \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'g3_moved_admin'::jsonb) AND pg_temp.hp_ok(:'g3_moved_staff'::jsonb)
  AND pg_temp.hp_refused(:'g3_moved_super'::jsonb, 'HELD_PHOTO_NOT_YOURS'),
  'G3: for an item the administrator moved, the administrator and the recorder may add photos and a supervisor may not: ' || :'g3_moved_admin' || ' / ' || :'g3_moved_super');
SELECT pg_temp.hp_assert((SELECT uploaded_by = (SELECT id FROM public.user_profiles WHERE name = 'Photo Administrator') FROM public.held_item_photos
  WHERE held_id = :'m1'::uuid AND client_photo_id = 'ph-m'), 'G3: the administrator''s photo names the administrator as uploader');

-- ===== G5. Staff storage rights, before the decisions =====
SELECT pg_temp.hp_path(:'g1'::uuid, 'ph-a') AS path_a, pg_temp.hp_path(:'g1'::uuid, 'ph-b') AS path_b, pg_temp.hp_path(:'g1'::uuid, 'ph-c') AS path_c,
  pg_temp.hp_path(:'g1'::uuid, 'ph-d') AS path_d, pg_temp.hp_path(:'g3'::uuid, 'ph-disp') AS path_disp, pg_temp.hp_path(:'m1'::uuid, 'ph-m') AS path_m \gset
-- Not the recorder, a customer account, an unregistered held path, the wrong bucket: refused by row-level security.
SELECT pg_temp.hp_assert(pg_temp.hp_put(:'staff2_claims'::jsonb, 'grn-images', :'path_d') = 'raised:42501', 'G5: another staff person cannot upload the recorder''s pending file');
SELECT pg_temp.hp_assert(pg_temp.hp_put(:'customer_claims'::jsonb, 'grn-images', :'path_d') = 'raised:42501', 'G5: a customer account cannot upload a held file');
SELECT pg_temp.hp_assert(pg_temp.hp_put(:'staff_claims'::jsonb, 'grn-images', 'held/' || :'g1' || '/sneaky.jpg') = 'raised:42501',
  'G5: staff cannot upload a held path nothing registered');
SELECT pg_temp.hp_assert(pg_temp.hp_put(:'staff_claims'::jsonb, 'dispatch-images', :'path_d') = 'raised:42501',
  'G5: staff cannot upload the registered name into the other bucket');
SELECT pg_temp.hp_assert(pg_temp.hp_put(:'staff_claims'::jsonb, 'grn-images', :'path_disp') = 'raised:42501',
  'G5: staff cannot upload a dispatch photo''s name into grn-images');
SELECT pg_temp.hp_assert(pg_temp.hp_put(:'staff_claims'::jsonb, 'grn-images', :'path_m') = 'raised:42501',
  'G5: staff cannot upload the file of a photo the administrator registered');
SELECT pg_temp.hp_assert(pg_temp.hp_put(:'staff_claims'::jsonb, 'dispatch-images', :'path_disp') = 'rows:1', 'G5: staff upload their own pending dispatch photo into dispatch-images');
SELECT pg_temp.hp_assert(NOT EXISTS (SELECT 1 FROM storage.objects WHERE name IN (:'path_d', 'held/' || :'g1' || '/sneaky.jpg', :'path_m')), 'G5: no refused upload left a file');
-- A file by a staff person is a file to confirm: d's confirm now works.
SELECT pg_temp.hp_assert(pg_temp.hp_put(:'staff_claims'::jsonb, 'grn-images', :'path_d') = 'rows:1', 'G5: staff upload their own pending file d');
SELECT pg_temp.hp_assert(pg_temp.hp_ok(pg_temp.hp_confirm(:'staff_claims'::jsonb, :'g1'::uuid, 'ph-d')) AND pg_temp.hp_photo_state(:'g1'::uuid, 'ph-d') = 'confirmed',
  'G3: once the file is in storage the same confirm succeeds');
-- Reads: the recorder and managers see the file; another staff person and a customer account do not.
SELECT pg_temp.hp_assert(pg_temp.hp_see(:'staff_claims'::jsonb, 'grn-images', :'path_a') = '1' AND pg_temp.hp_see(:'admin_claims'::jsonb, 'grn-images', :'path_a') = '1'
  AND pg_temp.hp_see(:'supervisor_claims'::jsonb, 'grn-images', :'path_a') = '1', 'G5: the recorder, the administrator and a supervisor read the held file');
SELECT pg_temp.hp_assert(pg_temp.hp_see(:'staff2_claims'::jsonb, 'grn-images', :'path_a') = '0' AND pg_temp.hp_see(:'customer_claims'::jsonb, 'grn-images', :'path_a') = '0',
  'G5: another staff person and a customer account do not read the held file');
-- The helper: write only while the photo is pending and the item held; read for the recorder's items.
SELECT pg_temp.hp_assert(pg_temp.hp_access(:'staff_claims'::jsonb, 'grn-images', :'path_c', true) = 'true'
  AND pg_temp.hp_access(:'staff_claims'::jsonb, 'grn-images', :'path_c', false) = 'true'
  AND pg_temp.hp_access(:'staff_claims'::jsonb, 'grn-images', :'path_a', true) = 'false'
  AND pg_temp.hp_access(:'staff_claims'::jsonb, 'grn-images', :'path_a', false) = 'true'
  AND pg_temp.hp_access(:'staff_claims'::jsonb, 'dispatch-images', :'path_c', false) = 'false'
  AND pg_temp.hp_access(:'staff_claims'::jsonb, 'grn-images', 'held/' || :'g1' || '/nothing.jpg', false) = 'false'
  AND pg_temp.hp_access(:'staff2_claims'::jsonb, 'grn-images', :'path_c', true) = 'false'
  AND pg_temp.hp_access(:'staff2_claims'::jsonb, 'grn-images', :'path_a', false) = 'false'
  AND pg_temp.hp_access(:'customer_claims'::jsonb, 'grn-images', :'path_c', false) = 'false',
  'G5: held_photo_file_access writes only a pending file of the caller, reads the recorder''s files, and is false for a confirmed write, the wrong bucket, an unknown name and other people');

-- ===== G6. A manager cannot delete a file a held photo names =====
SELECT pg_temp.hp_assert(pg_temp.hp_as(:'staff_claims'::jsonb, format('SELECT to_jsonb(warehouse_security.held_photo_file_named(%L))', :'path_a')) = 'true'
  AND pg_temp.hp_as(:'staff_claims'::jsonb, $q$SELECT to_jsonb(warehouse_security.held_photo_file_named('held/none/unnamed.jpg'))$q$) = 'false',
  'G6: held_photo_file_named is true for a registered held path and false for another name');
INSERT INTO storage.objects(bucket_id, name) VALUES ('grn-images', 'held/unrelated/control.jpg');
SELECT pg_temp.hp_assert(pg_temp.hp_del(:'admin_claims'::jsonb, 'grn-images', :'path_a') = 'rows:0' AND pg_temp.hp_del(:'supervisor_claims'::jsonb, 'grn-images', :'path_a') = 'rows:0'
  AND pg_temp.hp_del(:'admin_claims'::jsonb, 'grn-images', :'path_c') = 'rows:0' AND pg_temp.hp_del(:'admin_claims'::jsonb, 'dispatch-images', :'path_disp') = 'rows:0'
  AND EXISTS (SELECT 1 FROM storage.objects WHERE bucket_id = 'grn-images' AND name = :'path_a'),
  'G6: the administrator and a supervisor delete no file a held photo names, confirmed or pending, in either bucket');
SELECT pg_temp.hp_assert(pg_temp.hp_del(:'admin_claims'::jsonb, 'grn-images', 'held/unrelated/control.jpg') = 'rows:1',
  'G6: control: the same administrator deletes a held-prefix file that no photo names');
SELECT pg_temp.hp_assert(pg_temp.hp_del(:'staff_claims'::jsonb, 'grn-images', :'path_a') = 'rows:0' AND pg_temp.hp_del(:'staff_claims'::jsonb, 'grn-images', :'path_c') = 'rows:0'
  AND EXISTS (SELECT 1 FROM storage.objects WHERE bucket_id = 'grn-images' AND name = :'path_c'), 'G6: staff delete no held file either');

-- ===== G4. Accept attaches only confirmed photos =====
SELECT pg_temp.hp_decide(:'admin_claims'::jsonb, :'g1'::uuid, 'accept', 'hp-dk-g1') AS g4_accept \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'g4_accept'::jsonb) AND pg_temp.hp_state('hp-g1') = 'accepted', 'G4: the held GRN is accepted: ' || :'g4_accept');
SELECT id AS g1_grn FROM public.goodsreceived WHERE request_key = 'hp-g1' \gset
SELECT id AS g1_line FROM public.goodsreceived_trl WHERE gr_id = :'g1_grn'::uuid \gset
SELECT pg_temp.hp_assert((SELECT count(*) = 3 AND bool_and(status = 'confirmed' AND uploaded_by = :'staff_profile'::uuid)
    AND count(*) FILTER (WHERE storage_path = :'path_a' AND image_type = 'header' AND grn_item_id IS NULL) = 1
    AND count(*) FILTER (WHERE storage_path = :'path_d' AND image_type = 'header') = 1
    AND count(*) FILTER (WHERE storage_path = :'path_b' AND image_type = 'item' AND grn_item_id = :'g1_line'::uuid) = 1
  FROM public.grn_images WHERE grn_id = :'g1_grn'::uuid),
  'G4: the new GRN has the three confirmed photos (two header, one on its line), uploaded by the recorder, and not the unconfirmed c');
SELECT pg_temp.hp_assert(NOT EXISTS (SELECT 1 FROM public.grn_images WHERE storage_path = :'path_c'), 'G4: the unconfirmed photo c is attached to nothing');
SELECT pg_temp.hp_assert(pg_temp.hp_photo_state(:'g1'::uuid, 'ph-c') = 'pending' AND (SELECT count(*) FROM public.held_item_photos WHERE held_id = :'g1'::uuid) = 4,
  'G4: the held photo rows stay with the accepted item');
-- An accepted item still takes its photos (migration topic "held photos after accept"; was HELD_ALREADY_DECIDED before): the recorder registers a
-- new one, and confirms the pending c (its file was uploaded before the accept), which is attached to the GRN at once.
SELECT pg_temp.hp_n() AS n_g4 \gset
SELECT pg_temp.hp_reg(:'staff_claims'::jsonb, :'g1'::uuid, 'ph-late', 'header', 'late.jpg', 10, 'image/jpeg') AS g4_reg_acc \gset
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'g1'::uuid, 'ph-c') AS g4_conf_acc \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'g4_reg_acc'::jsonb) AND :'g4_reg_acc'::jsonb->>'status' = 'pending' AND pg_temp.hp_ok(:'g4_conf_acc'::jsonb)
  AND :'g4_conf_acc'::jsonb->>'status' = 'confirmed' AND pg_temp.hp_n() = :'n_g4'::bigint + 1 AND pg_temp.hp_photo_state(:'g1'::uuid, 'ph-c') = 'confirmed'
  AND pg_temp.hp_photo_state(:'g1'::uuid, 'ph-late') = 'pending'
  AND (SELECT count(*) = 1 AND bool_and(uploaded_by = :'staff_profile'::uuid AND status = 'confirmed' AND image_type = 'header') FROM public.grn_images
    WHERE grn_id = :'g1_grn'::uuid AND storage_path = :'path_c'),
  'G3: an accepted item takes a new registration and the confirm of its pending photo, which lands on the GRN once, uploaded by the recorder: ' || :'g4_reg_acc' || ' / ' || :'g4_conf_acc');
SELECT pg_temp.hp_assert(pg_temp.hp_access(:'staff_claims'::jsonb, 'grn-images', :'path_c', true) = 'false'
  AND pg_temp.hp_access(:'staff_claims'::jsonb, 'grn-images', :'path_c', false) = 'true'
  AND pg_temp.hp_access(:'staff_claims'::jsonb, 'grn-images', :'g4_reg_acc'::jsonb->>'storage_path', true) = 'true'
  AND pg_temp.hp_access(:'staff2_claims'::jsonb, 'grn-images', :'g4_reg_acc'::jsonb->>'storage_path', true) = 'false',
  'G5: on an accepted item staff may write only a still pending file of their own (not the confirmed c, not another person''s), and still read');
SELECT pg_temp.hp_assert(pg_temp.hp_del(:'admin_claims'::jsonb, 'grn-images', :'path_a') = 'rows:0', 'G6: the file now on a GRN stays undeletable (it is also a grn_images row)');

-- Reject keeps the photos with the item.
SELECT pg_temp.hp_reg(:'staff_claims'::jsonb, :'g2'::uuid, 'ph-r', 'header', 'rej.jpg', 800, 'image/jpeg') AS g4_r \gset
SELECT pg_temp.hp_put(:'staff_claims'::jsonb, 'grn-images', :'g4_r'::jsonb->>'storage_path') AS g4_r_put \gset
SELECT pg_temp.hp_assert(:'g4_r_put' = 'rows:1' AND pg_temp.hp_ok(pg_temp.hp_confirm(:'staff_claims'::jsonb, :'g2'::uuid, 'ph-r')), 'fixture: g2 has one confirmed photo');
SELECT pg_temp.hp_decide(:'admin_claims'::jsonb, :'g2'::uuid, 'reject', 'hp-dk-g2', 'Duplicate') AS g4_reject \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'g4_reject'::jsonb) AND pg_temp.hp_state('hp-g2') = 'rejected'
  AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE request_key = 'hp-g2')
  AND NOT EXISTS (SELECT 1 FROM public.grn_images WHERE storage_path IN (SELECT path FROM public.held_item_photos WHERE held_id = :'g2'::uuid))
  AND (SELECT count(*) = 2 AND count(*) FILTER (WHERE client_photo_id = 'ph-r' AND state = 'confirmed') = 1 FROM public.held_item_photos WHERE held_id = :'g2'::uuid),
  'G4: after reject no GRN and no image row exist, and both photo rows stay with the item: ' || :'g4_reject');
SELECT pg_temp.hp_assert(pg_temp.hp_del(:'admin_claims'::jsonb, 'grn-images', :'g4_r'::jsonb->>'storage_path') = 'rows:0'
  AND EXISTS (SELECT 1 FROM storage.objects WHERE bucket_id = 'grn-images' AND name = :'g4_r'::jsonb->>'storage_path'),
  'G6: the file of a photo kept with a rejected item cannot be deleted by a manager');
SELECT pg_temp.hp_reg(:'staff_claims'::jsonb, :'g2'::uuid, 'ph-r2', 'header', 'rej2.jpg', 800, 'image/jpeg') AS g4_rej_reg \gset
SELECT pg_temp.hp_assert(pg_temp.hp_refused(:'g4_rej_reg'::jsonb, 'HELD_ALREADY_DECIDED')
  AND pg_temp.hp_refused(pg_temp.hp_confirm(:'staff_claims'::jsonb, :'g2'::uuid, 'ph-r'), 'HELD_ALREADY_DECIDED'), 'G3: a rejected item is HELD_ALREADY_DECIDED too');
-- A rejected item's pending file cannot be written either (the storage rule lets only held and accepted items through).
SELECT pg_temp.hp_assert(pg_temp.hp_photo_state(:'g2'::uuid, 'ph-a') = 'pending'
  AND pg_temp.hp_access(:'staff_claims'::jsonb, 'grn-images', pg_temp.hp_path(:'g2'::uuid, 'ph-a'), true) = 'false'
  AND pg_temp.hp_put(:'staff_claims'::jsonb, 'grn-images', pg_temp.hp_path(:'g2'::uuid, 'ph-a')) = 'raised:42501',
  'G5: the pending file of a rejected item cannot be written by its recorder');
-- ===== G7. Who may execute what =====
SELECT pg_temp.hp_assert(has_function_privilege('authenticated', 'public.register_held_photo_upload(uuid,text,text,text,integer,text,text)', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.register_held_photo_upload(uuid,text,text,text,integer,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.register_held_photo_upload(uuid,text,text,text,integer,text,text)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.confirm_held_photo_upload(uuid,text)', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.confirm_held_photo_upload(uuid,text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.confirm_held_photo_upload(uuid,text)', 'EXECUTE'),
  'G7: the two RPCs are executable by authenticated and service_role, not by anon');
SELECT pg_temp.hp_assert(has_function_privilege('authenticated', 'warehouse_security.held_photo_file_access(text,text,boolean)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'warehouse_security.held_photo_file_named(text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'warehouse_security.held_photo_file_access(text,text,boolean)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'warehouse_security.held_photo_file_named(text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'warehouse_security.held_photo_refusal(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('service_role', 'warehouse_security.held_photo_refusal(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'warehouse_security.held_photo_refusal(uuid)', 'EXECUTE'),
  'G7: the two storage helpers are granted to authenticated alone, the caller check to no app role');
SELECT pg_temp.hp_assert(NOT has_table_privilege('authenticated', 'public.held_item_photos', 'SELECT') AND NOT has_table_privilege('authenticated', 'public.held_item_photos', 'INSERT')
  AND NOT has_table_privilege('service_role', 'public.held_item_photos', 'SELECT'), 'G7: no app role reads or writes held_item_photos directly');
SELECT pg_temp.hp_assert((SELECT count(*) = 3 FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects'
  AND policyname IN ('starter_held_photo_staff_read', 'starter_held_photo_staff_insert', 'starter_held_photo_staff_update')), 'G7: the three staff held-photo storage policies exist');

-- ===== G8. Missing photos (PQ11, migration topic "held photo missing"): the phone gave up on a photo =====
--   public.mark_held_photo_missing(p_held_id, p_client_photo_id, p_role, p_line_ref DEFAULT NULL, p_reason DEFAULT NULL)
--     -> { success, held_id, client_photo_id, status }, register's caller rule, creates the row when none, pending -> missing,
--     a confirmed photo stays confirmed, the first reason is kept; get_held_item's photos carry state, role, line_ref, reason and path NULL when missing.
CREATE FUNCTION pg_temp.hp_mark(claims jsonb, held uuid, cid text, role text, line text DEFAULT NULL, reason text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.hp_as(claims, format('SELECT public.mark_held_photo_missing(%L::uuid, %L, %L, %L, %L)', held, cid, role, line, reason)) $$;
CREATE FUNCTION pg_temp.hp_get_photo(a jsonb, cid text) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT p FROM jsonb_array_elements(COALESCE(a->'photos', a->'item'->'photos', a->'data'->'photos')) p WHERE p->>'client_photo_id' = cid $$;
SELECT pg_temp.hp_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hp_item('hp-n1', 'newGrn', 5, :'ca'::uuid, pg_temp.hp_grn_body(:'ca'::uuid, :'item_id'::uuid, 2, 'HPN1')))) AS g8_hold \gset
SELECT pg_temp.hp_assert(:'g8_hold'::jsonb->>'success' = 'true', 'fixture: hp-n1 handed over: ' || :'g8_hold');
SELECT pg_temp.hp_hid('hp-n1') AS n1 \gset
-- No row yet: the call creates it as missing, with the recorder and the first reason (trimmed).
SELECT pg_temp.hp_mark(:'staff_claims'::jsonb, :'n1'::uuid, 'pm-a', 'header', NULL, '  Photo refused: wrong type  ') AS g8_a \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'g8_a'::jsonb) AND :'g8_a'::jsonb->>'status' = 'missing' AND :'g8_a'::jsonb->>'held_id' = :'n1'
  AND :'g8_a'::jsonb->>'client_photo_id' = 'pm-a' AND (SELECT state = 'missing' AND reason = 'Photo refused: wrong type' AND role = 'header' AND line_ref IS NULL
    AND uploaded_by = :'staff_profile'::uuid FROM public.held_item_photos WHERE held_id = :'n1'::uuid AND client_photo_id = 'pm-a'),
  'G8: marking a photo that has no row creates it as missing with the trimmed reason and the recorder: ' || :'g8_a');
-- A repeat is idempotent and keeps the first reason.
SELECT pg_temp.hp_n() AS n_g8 \gset
SELECT pg_temp.hp_mark(:'staff_claims'::jsonb, :'n1'::uuid, 'pm-a', 'header', NULL, 'Another reason') AS g8_again \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'g8_again'::jsonb) AND :'g8_again'::jsonb->>'status' = 'missing' AND pg_temp.hp_n() = :'n_g8'::bigint
  AND (SELECT reason = 'Photo refused: wrong type' FROM public.held_item_photos WHERE held_id = :'n1'::uuid AND client_photo_id = 'pm-a'),
  'G8: a repeat answers missing, adds no row and keeps the first reason: ' || :'g8_again');
-- A pending row (registered, never uploaded) becomes missing and keeps its file facts.
SELECT pg_temp.hp_reg(:'staff_claims'::jsonb, :'n1'::uuid, 'pm-b', 'header', 'b.jpg', 321, 'image/jpeg') AS g8_reg_b \gset
SELECT pg_temp.hp_mark(:'staff_claims'::jsonb, :'n1'::uuid, 'pm-b', 'header', NULL, 'Gave up') AS g8_b \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'g8_b'::jsonb) AND :'g8_b'::jsonb->>'status' = 'missing' AND (SELECT state = 'missing' AND reason = 'Gave up'
    AND file_name = 'b.jpg' AND file_size = 321 AND path = :'g8_reg_b'::jsonb->>'storage_path' FROM public.held_item_photos WHERE held_id = :'n1'::uuid AND client_photo_id = 'pm-b'),
  'G8: a pending photo becomes missing and keeps its registered file facts and path: ' || :'g8_b');
-- A confirmed photo never turns missing.
SELECT pg_temp.hp_reg(:'staff_claims'::jsonb, :'n1'::uuid, 'pm-c', 'header', 'c.jpg', 100, 'image/jpeg') AS g8_reg_c \gset
SELECT pg_temp.hp_reg(:'staff_claims'::jsonb, :'n1'::uuid, 'pm-e', 'item', 'e.jpg', 100, 'image/jpeg', 'index:0') AS g8_reg_e \gset
SELECT pg_temp.hp_assert(pg_temp.hp_put(:'staff_claims'::jsonb, 'grn-images', :'g8_reg_c'::jsonb->>'storage_path') = 'rows:1'
  AND pg_temp.hp_put(:'staff_claims'::jsonb, 'grn-images', :'g8_reg_e'::jsonb->>'storage_path') = 'rows:1', 'G8: fixture: files of c and e uploaded');
SELECT pg_temp.hp_assert(pg_temp.hp_ok(pg_temp.hp_confirm(:'staff_claims'::jsonb, :'n1'::uuid, 'pm-c')) AND pg_temp.hp_ok(pg_temp.hp_confirm(:'staff_claims'::jsonb, :'n1'::uuid, 'pm-e')),
  'G8: fixture: c and e confirmed');
SELECT pg_temp.hp_mark(:'staff_claims'::jsonb, :'n1'::uuid, 'pm-c', 'header', NULL, 'Too late') AS g8_c \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'g8_c'::jsonb) AND :'g8_c'::jsonb->>'status' = 'confirmed' AND (SELECT state = 'confirmed' AND reason IS NULL
    FROM public.held_item_photos WHERE held_id = :'n1'::uuid AND client_photo_id = 'pm-c'), 'G8: marking a confirmed photo answers confirmed and changes nothing: ' || :'g8_c');
-- An item photo is marked with its line; a reason over 500 characters is cut to 500.
SELECT pg_temp.hp_mark(:'staff_claims'::jsonb, :'n1'::uuid, 'pm-d', 'item', ' index:0 ', repeat('r', 600)) AS g8_d \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'g8_d'::jsonb) AND (SELECT state = 'missing' AND role = 'item' AND line_ref = 'index:0' AND length(reason) = 500
    FROM public.held_item_photos WHERE held_id = :'n1'::uuid AND client_photo_id = 'pm-d'),
  'G8: an item photo is marked missing with its trimmed line, and a long reason is cut to 500: ' || :'g8_d');
-- The administrator who moved an item marks for it; the row names the administrator.
SELECT pg_temp.hp_mark(:'admin_claims'::jsonb, :'m1'::uuid, 'pm-m', 'header', NULL, 'Moved') AS g8_moved \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'g8_moved'::jsonb) AND (SELECT state = 'missing' AND uploaded_by = (SELECT id FROM public.user_profiles WHERE name = 'Photo Administrator')
  FROM public.held_item_photos WHERE held_id = :'m1'::uuid AND client_photo_id = 'pm-m'), 'G8: the administrator who moved the item may mark its photo: ' || :'g8_moved');
-- Refusals: as register, and nothing is written.
SELECT pg_temp.hp_n() AS n_g8r \gset
SELECT pg_temp.hp_assert(pg_temp.hp_refused(pg_temp.hp_mark(:'staff2_claims'::jsonb, :'n1'::uuid, 'pm-x', 'header'), 'HELD_PHOTO_NOT_YOURS')
  AND pg_temp.hp_refused(pg_temp.hp_mark(:'supervisor_claims'::jsonb, :'n1'::uuid, 'pm-x', 'header'), 'HELD_PHOTO_NOT_YOURS')
  AND pg_temp.hp_refused(pg_temp.hp_mark(:'admin_claims'::jsonb, :'n1'::uuid, 'pm-x', 'header'), 'HELD_PHOTO_NOT_YOURS')
  AND pg_temp.hp_refused(pg_temp.hp_mark(:'staff_claims'::jsonb, gen_random_uuid(), 'pm-x', 'header'), 'HELD_NOT_FOUND')
  AND pg_temp.hp_mark(:'customer_claims'::jsonb, :'n1'::uuid, 'pm-x', 'header')->>'state' = '42501'
  AND pg_temp.hp_mark(jsonb_build_object('role', 'authenticated', 'sub', gen_random_uuid()), :'n1'::uuid, 'pm-x', 'header')->>'state' = '42501'
  AND pg_temp.hp_refused(pg_temp.hp_mark(:'staff_claims'::jsonb, :'n1'::uuid, 'pm-x', 'item'), 'HELD_PHOTO_INVALID')
  AND pg_temp.hp_refused(pg_temp.hp_mark(:'staff_claims'::jsonb, :'n1'::uuid, 'pm-x', 'item', '  '), 'HELD_PHOTO_INVALID')
  AND pg_temp.hp_refused(pg_temp.hp_mark(:'staff_claims'::jsonb, :'n1'::uuid, 'pm-x', 'banner'), 'HELD_PHOTO_INVALID')
  AND pg_temp.hp_refused(pg_temp.hp_mark(:'staff_claims'::jsonb, :'n1'::uuid, 'pm-x', NULL), 'HELD_PHOTO_INVALID')
  AND pg_temp.hp_refused(pg_temp.hp_mark(:'staff_claims'::jsonb, :'n1'::uuid, '  ', 'header'), 'HELD_PHOTO_INVALID')
  AND pg_temp.hp_refused(pg_temp.hp_mark(:'staff_claims'::jsonb, :'n1'::uuid, repeat('i', 101), 'header'), 'HELD_PHOTO_INVALID')
  AND pg_temp.hp_n() = :'n_g8r'::bigint,
  'G8: other staff, a supervisor, a non-moving administrator, an unknown item, a customer, no profile and bad input are refused and write nothing');
-- The decider reads them: state, role, line, reason; path is NULL for a missing photo and kept for the others.
SELECT pg_temp.hp_as(:'admin_claims'::jsonb, format('SELECT public.get_held_item(%L::uuid)', :'n1')) AS g8_item \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'g8_item'::jsonb) AND jsonb_array_length(:'g8_item'::jsonb->'photos') = 5, 'G8: get_held_item lists the five photos: ' || left(:'g8_item', 600));
SELECT pg_temp.hp_assert(pg_temp.hp_get_photo(:'g8_item'::jsonb, 'pm-a')->>'state' = 'missing' AND pg_temp.hp_get_photo(:'g8_item'::jsonb, 'pm-a')->>'role' = 'header'
  AND pg_temp.hp_get_photo(:'g8_item'::jsonb, 'pm-a')->>'reason' = 'Photo refused: wrong type' AND pg_temp.hp_get_photo(:'g8_item'::jsonb, 'pm-a')->'path' = 'null'::jsonb
  AND pg_temp.hp_get_photo(:'g8_item'::jsonb, 'pm-d')->>'state' = 'missing' AND pg_temp.hp_get_photo(:'g8_item'::jsonb, 'pm-d')->>'line_ref' = 'index:0'
  AND pg_temp.hp_get_photo(:'g8_item'::jsonb, 'pm-d')->'path' = 'null'::jsonb AND pg_temp.hp_get_photo(:'g8_item'::jsonb, 'pm-b')->'path' = 'null'::jsonb,
  'G8: get_held_item shows a missing photo with state, role, line, reason and a null path (also a pending photo that became missing)');
SELECT pg_temp.hp_assert(pg_temp.hp_get_photo(:'g8_item'::jsonb, 'pm-c')->>'state' = 'confirmed' AND pg_temp.hp_get_photo(:'g8_item'::jsonb, 'pm-c')->>'path' = :'g8_reg_c'::jsonb->>'storage_path'
  AND pg_temp.hp_get_photo(:'g8_item'::jsonb, 'pm-c')->'reason' = 'null'::jsonb, 'G8: a confirmed photo keeps its path and has no reason in get_held_item');
-- Accept attaches the two confirmed photos only.
SELECT pg_temp.hp_decide(:'admin_claims'::jsonb, :'n1'::uuid, 'accept', 'hp-dk-n1') AS g8_accept \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'g8_accept'::jsonb) AND pg_temp.hp_state('hp-n1') = 'accepted', 'G8: the held GRN is accepted: ' || :'g8_accept');
SELECT id AS n1_grn FROM public.goodsreceived WHERE request_key = 'hp-n1' \gset
SELECT pg_temp.hp_assert((SELECT count(*) = 2 AND count(*) FILTER (WHERE image_type = 'header' AND storage_path = :'g8_reg_c'::jsonb->>'storage_path') = 1
    AND count(*) FILTER (WHERE image_type = 'item' AND storage_path = :'g8_reg_e'::jsonb->>'storage_path' AND grn_item_id IS NOT NULL) = 1
  FROM public.grn_images WHERE grn_id = :'n1_grn'::uuid)
  AND NOT EXISTS (SELECT 1 FROM public.grn_images WHERE storage_path LIKE '%/missing/%')
  AND (SELECT count(*) = 5 AND count(*) FILTER (WHERE state = 'missing') = 3 FROM public.held_item_photos WHERE held_id = :'n1'::uuid),
  'G8: accept attaches the two confirmed photos and not the three missing ones, which stay with the item');
SELECT pg_temp.hp_n() AS n_g8d \gset
SELECT pg_temp.hp_mark(:'staff_claims'::jsonb, :'n1'::uuid, 'pm-late', 'header') AS g8_late \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'g8_late'::jsonb) AND :'g8_late'::jsonb->>'status' = 'missing' AND pg_temp.hp_n() = :'n_g8d'::bigint + 1
  AND (SELECT state = 'missing' AND document_id = :'n1_grn'::uuid FROM public.held_item_photos WHERE held_id = :'n1'::uuid AND client_photo_id = 'pm-late')
  AND NOT EXISTS (SELECT 1 FROM public.grn_images WHERE grn_id = :'n1_grn'::uuid AND storage_path LIKE '%/missing/%'),
  'G8: an accepted item still takes a mark: the row is missing, linked to the GRN the accept made, and no image is attached: ' || :'g8_late');
SELECT pg_temp.hp_assert(has_function_privilege('authenticated', 'public.mark_held_photo_missing(uuid,text,text,text,text)', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.mark_held_photo_missing(uuid,text,text,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.mark_held_photo_missing(uuid,text,text,text,text)', 'EXECUTE'),
  'G8: mark_held_photo_missing is executable by authenticated and service_role, not anon');
-- A rejected item takes no mark (g2 was rejected in G4): the pending row stays pending and no row is added.
SELECT pg_temp.hp_n() AS n_g8rej \gset
SELECT pg_temp.hp_mark(:'staff_claims'::jsonb, :'g2'::uuid, 'ph-a', 'header', NULL, 'late') AS g8_rej_mark \gset
SELECT pg_temp.hp_mark(:'staff_claims'::jsonb, :'g2'::uuid, 'ph-new', 'header', NULL, 'late') AS g8_rej_new \gset
SELECT pg_temp.hp_assert(pg_temp.hp_refused(:'g8_rej_mark'::jsonb, 'HELD_ALREADY_DECIDED') AND pg_temp.hp_refused(:'g8_rej_new'::jsonb, 'HELD_ALREADY_DECIDED')
  AND pg_temp.hp_n() = :'n_g8rej'::bigint AND pg_temp.hp_photo_state(:'g2'::uuid, 'ph-a') = 'pending',
  'G8: a rejected item is HELD_ALREADY_DECIDED for mark-missing, and nothing is written: ' || :'g8_rej_mark' || ' / ' || :'g8_rej_new');

-- ===== G9. Photos that are still on their way when the item is accepted follow it (migration topic "held photos after accept") =====
-- Accept goes through with only the confirmed photo; afterwards the recorder (and only the recorder) confirms, registers or marks the others and each lands on
-- the document the accept made (header and item photos on the GRN, dispatch photos on the dispatch), uploaded_by the recorder, once.
SELECT pg_temp.hp_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hp_item('hp-a1', 'newGrn', 40, :'ca'::uuid, pg_temp.hp_grn_body(:'ca'::uuid, :'item_id'::uuid, 2, 'HPA1')))) AS g9_hold \gset
SELECT pg_temp.hp_assert(:'g9_hold'::jsonb->>'success' = 'true', 'fixture: hp-a1 handed over: ' || :'g9_hold');
SELECT pg_temp.hp_hid('hp-a1') AS a1 \gset
SELECT pg_temp.hp_reg(:'staff_claims'::jsonb, :'a1'::uuid, 'pa-conf', 'header', 'conf.jpg', 100, 'image/jpeg') AS a1_conf \gset
SELECT pg_temp.hp_reg(:'staff_claims'::jsonb, :'a1'::uuid, 'pa-pend', 'header', 'pend.jpg', 100, 'image/jpeg') AS a1_pend \gset
SELECT pg_temp.hp_reg(:'staff_claims'::jsonb, :'a1'::uuid, 'pa-line', 'item', 'line.jpg', 100, 'image/jpeg', 'index:0') AS a1_line \gset
SELECT pg_temp.hp_reg(:'staff_claims'::jsonb, :'a1'::uuid, 'pa-nofile', 'header', 'nofile.jpg', 100, 'image/jpeg') AS a1_nofile \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'a1_conf'::jsonb) AND pg_temp.hp_ok(:'a1_pend'::jsonb) AND pg_temp.hp_ok(:'a1_line'::jsonb) AND pg_temp.hp_ok(:'a1_nofile'::jsonb),
  'fixture: four photos registered on hp-a1');
SELECT pg_temp.hp_assert(pg_temp.hp_put(:'staff_claims'::jsonb, 'grn-images', :'a1_conf'::jsonb->>'storage_path') = 'rows:1'
  AND pg_temp.hp_put(:'staff_claims'::jsonb, 'grn-images', :'a1_pend'::jsonb->>'storage_path') = 'rows:1'
  AND pg_temp.hp_put(:'staff_claims'::jsonb, 'grn-images', :'a1_line'::jsonb->>'storage_path') = 'rows:1', 'fixture: files of conf, pend and line uploaded');
SELECT pg_temp.hp_assert(pg_temp.hp_ok(pg_temp.hp_confirm(:'staff_claims'::jsonb, :'a1'::uuid, 'pa-conf')), 'fixture: pa-conf confirmed before the accept');
SELECT pg_temp.hp_decide(:'admin_claims'::jsonb, :'a1'::uuid, 'accept', 'hp-dk-a1') AS g9_accept \gset
SELECT id AS a1_grn FROM public.goodsreceived WHERE request_key = 'hp-a1' \gset
SELECT id AS a1_line_id FROM public.goodsreceived_trl WHERE gr_id = :'a1_grn'::uuid \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'g9_accept'::jsonb) AND pg_temp.hp_state('hp-a1') = 'accepted'
  AND (SELECT count(*) = 1 AND bool_and(storage_path = :'a1_conf'::jsonb->>'storage_path' AND uploaded_by = :'staff_profile'::uuid) FROM public.grn_images WHERE grn_id = :'a1_grn'::uuid),
  'G9: the accept goes through with pending photos about, and attaches only the confirmed one: ' || :'g9_accept');
SELECT pg_temp.hp_assert((SELECT jsonb_typeof(item_mapping) = 'array' AND jsonb_array_length(item_mapping) = 1 AND item_mapping -> 0 ->> 'index' = '0'
    AND item_mapping -> 0 ->> 'item_id' = :'a1_line_id' FROM public.held_items WHERE id = :'a1'::uuid),
  'G9: held_items.item_mapping keeps the save''s mapping of line index 0 to the saved line');
-- Another staff person cannot confirm the pending photo; nothing changes.
SELECT pg_temp.hp_confirm(:'staff2_claims'::jsonb, :'a1'::uuid, 'pa-pend') AS a1_other \gset
SELECT pg_temp.hp_assert(pg_temp.hp_refused(:'a1_other'::jsonb, 'HELD_PHOTO_NOT_YOURS') AND pg_temp.hp_photo_state(:'a1'::uuid, 'pa-pend') = 'pending'
  AND (SELECT count(*) = 1 FROM public.grn_images WHERE grn_id = :'a1_grn'::uuid), 'G9: another staff person cannot confirm a pending photo of the accepted item: ' || :'a1_other');
-- The recorder confirms the header photo: it is attached to the GRN the accept created, by the recorder.
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'a1'::uuid, 'pa-pend') AS a1_c1 \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'a1_c1'::jsonb) AND :'a1_c1'::jsonb->>'status' = 'confirmed' AND pg_temp.hp_photo_state(:'a1'::uuid, 'pa-pend') = 'confirmed'
  AND (SELECT count(*) = 1 AND bool_and(image_type = 'header' AND grn_item_id IS NULL AND status = 'confirmed' AND uploaded_by = :'staff_profile'::uuid)
       FROM public.grn_images WHERE grn_id = :'a1_grn'::uuid AND storage_path = :'a1_pend'::jsonb->>'storage_path')
  AND (SELECT count(*) = 2 FROM public.grn_images WHERE grn_id = :'a1_grn'::uuid),
  'G9: the recorder''s late confirm of a header photo attaches it to the GRN, uploaded by the recorder: ' || :'a1_c1');
SELECT pg_temp.hp_assert((SELECT count(*) = 2 AND bool_and(document_id = :'a1_grn'::uuid) FROM public.held_item_photos WHERE held_id = :'a1'::uuid AND state = 'confirmed'),
  'G9: the confirmed photos of the item are linked to the GRN (document_id)');
-- A line photo goes onto its line through the stored item mapping.
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'a1'::uuid, 'pa-line') AS a1_c2 \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'a1_c2'::jsonb) AND (SELECT count(*) = 1 AND bool_and(image_type = 'item' AND grn_item_id = :'a1_line_id'::uuid AND uploaded_by = :'staff_profile'::uuid)
    FROM public.grn_images WHERE grn_id = :'a1_grn'::uuid AND storage_path = :'a1_line'::jsonb->>'storage_path'),
  'G9: a late line photo (index:0) is attached on the saved line: ' || :'a1_c2');
-- A repeat attaches nothing twice.
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'a1'::uuid, 'pa-pend') AS a1_r1 \gset
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'a1'::uuid, 'pa-line') AS a1_r2 \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'a1_r1'::jsonb) AND pg_temp.hp_ok(:'a1_r2'::jsonb)
  AND (SELECT count(*) = 3 AND count(DISTINCT storage_path) = 3 FROM public.grn_images WHERE grn_id = :'a1_grn'::uuid),
  'G9: a repeated confirm answers confirmed and attaches nothing twice (three images, three paths): ' || :'a1_r1' || ' / ' || :'a1_r2');
-- A photo whose file never arrived stays pending and attaches nothing; the phone then marks it missing: the row keeps its record, linked to the GRN.
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'a1'::uuid, 'pa-nofile') AS a1_nf \gset
SELECT pg_temp.hp_assert(pg_temp.hp_refused(:'a1_nf'::jsonb, 'IMAGE_NOT_VERIFIED') AND pg_temp.hp_photo_state(:'a1'::uuid, 'pa-nofile') = 'pending'
  AND (SELECT count(*) = 3 FROM public.grn_images WHERE grn_id = :'a1_grn'::uuid), 'G9: confirm with no file is IMAGE_NOT_VERIFIED after the accept too: ' || :'a1_nf');
SELECT pg_temp.hp_mark(:'staff2_claims'::jsonb, :'a1'::uuid, 'pa-nofile', 'header', NULL, 'not mine') AS a1_mark_other \gset
SELECT pg_temp.hp_mark(:'staff_claims'::jsonb, :'a1'::uuid, 'pa-nofile', 'header', NULL, '  File lost on the phone ') AS a1_mark \gset
SELECT pg_temp.hp_mark(:'staff_claims'::jsonb, :'a1'::uuid, 'pa-gone', 'header', NULL, 'Refused as invalid') AS a1_mark_new \gset
SELECT pg_temp.hp_assert(pg_temp.hp_refused(:'a1_mark_other'::jsonb, 'HELD_PHOTO_NOT_YOURS') AND pg_temp.hp_ok(:'a1_mark'::jsonb) AND :'a1_mark'::jsonb->>'status' = 'missing'
  AND pg_temp.hp_ok(:'a1_mark_new'::jsonb) AND :'a1_mark_new'::jsonb->>'status' = 'missing'
  AND (SELECT count(*) = 2 AND bool_and(state = 'missing' AND document_id = :'a1_grn'::uuid) AND count(*) FILTER (WHERE client_photo_id = 'pa-nofile' AND reason = 'File lost on the phone') = 1
        AND count(*) FILTER (WHERE client_photo_id = 'pa-gone' AND uploaded_by = :'staff_profile'::uuid AND reason = 'Refused as invalid') = 1
      FROM public.held_item_photos WHERE held_id = :'a1'::uuid AND state = 'missing')
  AND (SELECT count(*) = 3 FROM public.grn_images WHERE grn_id = :'a1_grn'::uuid),
  'G9: after the accept another person cannot mark, the recorder can (also a photo with no row), the missing rows keep state, reason and the GRN link, and no image is attached: '
  || :'a1_mark_other' || ' / ' || :'a1_mark' || ' / ' || :'a1_mark_new');
SELECT pg_temp.hp_mark(:'staff_claims'::jsonb, :'a1'::uuid, 'pa-pend', 'header', NULL, 'Too late') AS a1_mark_conf \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'a1_mark_conf'::jsonb) AND :'a1_mark_conf'::jsonb->>'status' = 'confirmed' AND pg_temp.hp_photo_state(:'a1'::uuid, 'pa-pend') = 'confirmed',
  'G9: a confirmed photo of an accepted item is not turned missing: ' || :'a1_mark_conf');
-- A NEW photo can still be registered for the accepted item (the migration lets register through for held and accepted): pending, its file only by the recorder, then confirm attaches it.
SELECT pg_temp.hp_reg(:'staff_claims'::jsonb, :'a1'::uuid, 'pa-new', 'header', 'new.jpg', 100, 'image/jpeg') AS a1_new \gset
SELECT pg_temp.hp_reg(:'staff2_claims'::jsonb, :'a1'::uuid, 'pa-x', 'header', 'x.jpg', 100, 'image/jpeg') AS a1_new_other \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'a1_new'::jsonb) AND :'a1_new'::jsonb->>'status' = 'pending' AND pg_temp.hp_refused(:'a1_new_other'::jsonb, 'HELD_PHOTO_NOT_YOURS'),
  'G9: the recorder can register a new photo for the accepted item, another staff person cannot: ' || :'a1_new' || ' / ' || :'a1_new_other');
SELECT pg_temp.hp_assert(pg_temp.hp_put(:'staff2_claims'::jsonb, 'grn-images', :'a1_new'::jsonb->>'storage_path') = 'raised:42501'
  AND pg_temp.hp_access(:'staff2_claims'::jsonb, 'grn-images', :'a1_new'::jsonb->>'storage_path', true) = 'false'
  AND pg_temp.hp_access(:'staff_claims'::jsonb, 'grn-images', :'a1_new'::jsonb->>'storage_path', true) = 'true'
  AND pg_temp.hp_put(:'staff_claims'::jsonb, 'grn-images', :'a1_new'::jsonb->>'storage_path') = 'rows:1',
  'G9: storage: the recorder may write the pending file of an accepted item, another staff person may not');
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'a1'::uuid, 'pa-new') AS a1_cnew \gset
SELECT count(*) AS a1_n_images FROM public.grn_images WHERE grn_id = :'a1_grn'::uuid \gset
SELECT count(*) AS a1_n_new FROM public.grn_images WHERE grn_id = :'a1_grn'::uuid AND storage_path = :'a1_new'::jsonb->>'storage_path' AND uploaded_by = :'staff_profile'::uuid \gset
SELECT pg_temp.hp_access(:'staff_claims'::jsonb, 'grn-images', :'a1_new'::jsonb->>'storage_path', true) AS a1_new_write \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'a1_cnew'::jsonb) AND :'a1_cnew'::jsonb->>'status' = 'confirmed', 'G9: confirm of the new photo of the accepted item answers confirmed: ' || :'a1_cnew');
SELECT pg_temp.hp_assert(:'a1_n_images'::int = 4 AND :'a1_n_new'::int = 1,
  'G9: the new photo is attached to the GRN once, uploaded by the recorder (images ' || :'a1_n_images' || ', of the new one ' || :'a1_n_new' || ', want 4 and 1)');
SELECT pg_temp.hp_assert(:'a1_new_write'::text = 'false', 'G9: the confirmed file of an accepted item is no longer writable (write access ' || :'a1_new_write' || ')');

-- The dispatch kind: a held new dispatch of one bag of the GRN above; its confirmed photo goes with the accept, the others follow.
SELECT pg_temp.hp_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hp_item('hp-a2', 'newDispatch', 41, :'ca'::uuid, jsonb_build_object('args', jsonb_build_object(
    'p_dispatch_data', jsonb_build_object('disp_no', 'HPD1', 'disp_date', '2026-05-02', 'customer_id', :'ca', 'customer_name', 'Photo Customer A',
      'supervisor_id', (SELECT id FROM public.user_profiles WHERE name = 'Photo Administrator'), 'supervisor_name', 'Photo Administrator', 'registration', 'GJ01HP0001'),
    'p_dispatch_items', jsonb_build_array(jsonb_build_object('gr_trl_id', :'g1_line', 'disp_qty', 1)), 'p_generate_invoice', false, 'p_retry_count', 0))))) AS g9d_hold \gset
SELECT pg_temp.hp_assert(:'g9d_hold'::jsonb->>'success' = 'true', 'fixture: hp-a2 handed over: ' || :'g9d_hold');
SELECT pg_temp.hp_hid('hp-a2') AS a2 \gset
SELECT pg_temp.hp_reg(:'staff_claims'::jsonb, :'a2'::uuid, 'pd-conf', 'dispatch', 'dconf.jpg', 100, 'image/jpeg') AS a2_conf \gset
SELECT pg_temp.hp_reg(:'staff_claims'::jsonb, :'a2'::uuid, 'pd-pend', 'dispatch', 'dpend.jpg', 100, 'image/jpeg') AS a2_pend \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'a2_conf'::jsonb) AND pg_temp.hp_ok(:'a2_pend'::jsonb), 'fixture: dispatch photos registered: ' || :'a2_conf' || ' / ' || :'a2_pend');
SELECT pg_temp.hp_put(:'staff_claims'::jsonb, 'dispatch-images', :'a2_conf'::jsonb->>'storage_path') AS a2_put \gset
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'a2'::uuid, 'pd-conf') AS a2_cconf \gset
SELECT pg_temp.hp_assert(:'a2_put' = 'rows:1' AND pg_temp.hp_ok(:'a2_cconf'::jsonb), 'fixture: pd-conf file uploaded and confirmed: ' || :'a2_put' || ' / ' || :'a2_cconf');
SELECT pg_temp.hp_decide(:'admin_claims'::jsonb, :'a2'::uuid, 'accept', 'hp-dk-a2') AS g9d_accept \gset
SELECT id AS a2_disp FROM public.dispatch WHERE request_key = 'hp-a2' \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'g9d_accept'::jsonb) AND pg_temp.hp_state('hp-a2') = 'accepted', 'G9: the dispatch is accepted: ' || :'g9d_accept');
SELECT count(*) AS a2_n1, count(*) FILTER (WHERE storage_path = :'a2_conf'::jsonb->>'storage_path' AND uploaded_by = :'staff_profile'::uuid) AS a2_n1_conf
  FROM public.dispatch_images WHERE dispatch_id = :'a2_disp'::uuid \gset
SELECT pg_temp.hp_assert(:'a2_n1'::int = 1 AND :'a2_n1_conf'::int = 1,
  'G9: only the confirmed dispatch photo is attached by the accept, uploaded by the recorder (images ' || :'a2_n1' || ', its own ' || :'a2_n1_conf' || ', want 1 and 1)');
-- The phone uploads the pending dispatch file after the accept (the storage rule), then confirms.
SELECT pg_temp.hp_put(:'staff2_claims'::jsonb, 'dispatch-images', :'a2_pend'::jsonb->>'storage_path') AS a2_put_other \gset
SELECT pg_temp.hp_put(:'staff_claims'::jsonb, 'dispatch-images', :'a2_pend'::jsonb->>'storage_path') AS a2_put_rec \gset
SELECT pg_temp.hp_assert(:'a2_put_other' = 'raised:42501' AND :'a2_put_rec' = 'rows:1',
  'G9: the recorder alone uploads a pending dispatch file after the accept (other staff ' || :'a2_put_other' || ', recorder ' || :'a2_put_rec' || ')');
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'a2'::uuid, 'pd-pend') AS a2_c1 \gset
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'a2'::uuid, 'pd-pend') AS a2_c2 \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'a2_c1'::jsonb) AND pg_temp.hp_ok(:'a2_c2'::jsonb), 'G9: confirm and its repeat answer success for a dispatch photo: ' || :'a2_c1' || ' / ' || :'a2_c2');
SELECT count(*) AS a2_n2, count(DISTINCT storage_path) AS a2_n2_paths, count(*) FILTER (WHERE uploaded_by = :'staff_profile'::uuid AND status = 'confirmed') AS a2_n2_ok
  FROM public.dispatch_images WHERE dispatch_id = :'a2_disp'::uuid \gset
SELECT count(*) AS a2_grn_leak FROM public.grn_images WHERE storage_path IN (:'a2_conf'::jsonb->>'storage_path', :'a2_pend'::jsonb->>'storage_path') \gset
SELECT count(*) AS a2_linked FROM public.held_item_photos WHERE held_id = :'a2'::uuid AND document_id = :'a2_disp'::uuid \gset
SELECT pg_temp.hp_assert(:'a2_n2'::int = 2 AND :'a2_n2_paths'::int = 2 AND :'a2_n2_ok'::int = 2,
  'G9: a late dispatch photo is attached once, by the recorder, confirmed (images ' || :'a2_n2' || ', paths ' || :'a2_n2_paths' || ', recorder+confirmed ' || :'a2_n2_ok' || ', want 2/2/2)');
SELECT pg_temp.hp_assert(:'a2_grn_leak'::int = 0 AND :'a2_linked'::int = 2,
  'G9: dispatch photos are on no GRN and their rows link to the dispatch (on a GRN ' || :'a2_grn_leak' || ', linked rows ' || :'a2_linked' || ', want 0 and 2)');
SELECT pg_temp.hp_mark(:'staff_claims'::jsonb, :'a2'::uuid, 'pd-gone', 'dispatch', NULL, 'Gave up') AS a2_mark \gset
SELECT state AS a2_gone_state, COALESCE(document_id::text, 'NULL') AS a2_gone_doc FROM public.held_item_photos WHERE held_id = :'a2'::uuid AND client_photo_id = 'pd-gone' \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'a2_mark'::jsonb) AND :'a2_gone_state' = 'missing' AND :'a2_gone_doc' = :'a2_disp',
  'G9: a dispatch photo marked missing after the accept is linked to the dispatch (answer ' || :'a2_mark' || ', state ' || :'a2_gone_state' || ', document ' || :'a2_gone_doc' || ', dispatch ' || :'a2_disp' || ')');

-- ===== G10. WH-382: the photos of an item that names another person's key never reach that person's GRN =====
SELECT pg_temp.hp_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hp_item('hp-s1', 'newGrn', 50, :'ca'::uuid, pg_temp.hp_grn_body(:'ca'::uuid, :'item_id'::uuid, 2, 'HPS1')),
  pg_temp.hp_item('hp-s2', 'newGrn', 51, :'ca'::uuid, pg_temp.hp_grn_body(:'ca'::uuid, :'item_id'::uuid, 2, 'HPS2')),
  pg_temp.hp_item('hp-s2-ph', 'photos', 52, :'ca'::uuid, '{"doc":"grn"}', jsonb_build_object('follows_key', 'hp-s2', 'refusal', NULL)))) AS g10_hold \gset
SELECT pg_temp.hp_assert(:'g10_hold'::jsonb->>'success' = 'true', 'fixture: hp-s1, hp-s2 and its photos item handed over: ' || :'g10_hold');
-- The second staff person names hp-s1 (not theirs: REQUEST_KEY_REUSED) and a photos item that follows it.
SELECT pg_temp.hp_hold(:'staff2_claims'::jsonb, jsonb_build_array(
  pg_temp.hp_item('hp-s1', 'newGrn', 1, :'ca'::uuid, pg_temp.hp_grn_body(:'ca'::uuid, :'item_id'::uuid, 2, 'HPS1')),
  pg_temp.hp_item('hp-x-ph', 'photos', 2, :'ca'::uuid, '{"doc":"grn"}', jsonb_build_object('follows_key', 'hp-s1', 'refusal', NULL)))) AS g10_other \gset
SELECT pg_temp.hp_assert(:'g10_other'::jsonb->>'success' = 'true' AND :'g10_other'::text LIKE '%REQUEST_KEY_REUSED%', 'fixture: the second person''s call: ' || :'g10_other');
SELECT pg_temp.hp_hid('hp-s1') AS s1, pg_temp.hp_hid('hp-s2') AS s2, pg_temp.hp_hid('hp-s2-ph') AS s2ph, pg_temp.hp_hid('hp-x-ph') AS xph \gset
SELECT COALESCE(follows::text, 'NULL') AS x_follows, needs_decision AS x_needs FROM public.held_items WHERE id = :'xph'::uuid \gset
SELECT COALESCE(follows::text, 'NULL') AS s_follows, needs_decision AS s_needs FROM public.held_items WHERE id = :'s2ph'::uuid \gset
SELECT pg_temp.hp_assert(:'x_follows' = 'NULL' AND :'x_needs' = 't', 'G10: the foreign follower is not linked and keeps a decision of its own (follows ' || :'x_follows' || ', needs_decision ' || :'x_needs' || ')');
SELECT pg_temp.hp_assert(:'s_follows' = :'s2' AND :'s_needs' = 'f', 'G10: the same recorder''s follower is linked under hp-s2 (follows ' || :'s_follows' || ', want ' || :'s2' || ', needs_decision ' || :'s_needs' || ')');
SELECT pg_temp.hp_reg(:'staff2_claims'::jsonb, :'xph'::uuid, 'px-1', 'header', 'x.jpg', 100, 'image/jpeg') AS g10_xreg \gset
SELECT pg_temp.hp_reg(:'staff_claims'::jsonb, :'s2ph'::uuid, 'ps-1', 'header', 's.jpg', 100, 'image/jpeg') AS g10_sreg \gset
SELECT pg_temp.hp_put(:'staff2_claims'::jsonb, 'grn-images', :'g10_xreg'::jsonb->>'storage_path') AS g10_xput \gset
SELECT pg_temp.hp_put(:'staff_claims'::jsonb, 'grn-images', :'g10_sreg'::jsonb->>'storage_path') AS g10_sput \gset
SELECT pg_temp.hp_confirm(:'staff2_claims'::jsonb, :'xph'::uuid, 'px-1') AS g10_xconf \gset
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'s2ph'::uuid, 'ps-1') AS g10_sconf \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'g10_xreg'::jsonb) AND pg_temp.hp_ok(:'g10_sreg'::jsonb) AND :'g10_xput' = 'rows:1' AND :'g10_sput' = 'rows:1'
  AND pg_temp.hp_ok(:'g10_xconf'::jsonb) AND pg_temp.hp_ok(:'g10_sconf'::jsonb),
  'fixture: one confirmed photo on each follower: ' || :'g10_xreg' || ' / ' || :'g10_sreg' || ' / ' || :'g10_xput' || ' / ' || :'g10_sput' || ' / ' || :'g10_xconf' || ' / ' || :'g10_sconf');
SELECT pg_temp.hp_decide(:'admin_claims'::jsonb, :'s1'::uuid, 'accept', 'hp-dk-s1') AS g10_acc1 \gset
SELECT pg_temp.hp_decide(:'admin_claims'::jsonb, :'s2'::uuid, 'accept', 'hp-dk-s2') AS g10_acc2 \gset
SELECT id AS s1_grn FROM public.goodsreceived WHERE request_key = 'hp-s1' \gset
SELECT id AS s2_grn FROM public.goodsreceived WHERE request_key = 'hp-s2' \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'g10_acc1'::jsonb) AND pg_temp.hp_ok(:'g10_acc2'::jsonb), 'G10: both GRNs are accepted: ' || :'g10_acc1' || ' / ' || :'g10_acc2');
SELECT count(*) AS s1_images FROM public.grn_images WHERE grn_id = :'s1_grn'::uuid \gset
SELECT count(*) AS x_anywhere FROM public.grn_images WHERE storage_path = :'g10_xreg'::jsonb->>'storage_path' \gset
SELECT pg_temp.hp_state('hp-x-ph') AS x_state \gset
SELECT pg_temp.hp_assert(:'s1_images'::int = 0 AND :'x_anywhere'::int = 0 AND :'x_state' = 'held',
  'G10: accepting the staff person''s GRN attaches nothing of the other person''s photos item, which stays held (images on hp-s1 ' || :'s1_images'
  || ', the foreign photo on any GRN ' || :'x_anywhere' || ', its state ' || :'x_state' || ')');
SELECT count(*) AS s2_images, count(*) FILTER (WHERE storage_path = :'g10_sreg'::jsonb->>'storage_path' AND uploaded_by = :'staff_profile'::uuid) AS s2_own FROM public.grn_images WHERE grn_id = :'s2_grn'::uuid \gset
SELECT pg_temp.hp_assert(:'s2_images'::int = 1 AND :'s2_own'::int = 1,
  'G10: control: the same recorder''s follower photo is attached to its GRN on accept (images ' || :'s2_images' || ', its own ' || :'s2_own' || ')');

-- ===== G11. The late attach takes only the photo being confirmed (held_attach_one, attached_at) and answers when its line or document is gone =====
-- A GRN with two lines, and a helper that registers a photo and uploads its file as its recorder.
CREATE FUNCTION pg_temp.hp_grn_body2(cust uuid, item uuid, no text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_set(pg_temp.hp_grn_body(cust, item, 2, no), '{args,p_items}', jsonb_build_array(
    jsonb_build_object('item_id', item, 'item_name', 'Photo Cumin', 'packaging', 'Bag', 'qty', 2, 'weight', 10, 'rack', 'N1', 'package_mark', 'NM'),
    jsonb_build_object('item_id', item, 'item_name', 'Photo Cumin', 'packaging', 'Bag', 'qty', 3, 'weight', 10, 'rack', 'N2', 'package_mark', 'N2'))) $$;
CREATE FUNCTION pg_temp.hp_reg_put(claims jsonb, held uuid, cid text, role text, fname text, line text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb; put text;
BEGIN
  r := pg_temp.hp_reg(claims, held, cid, role, fname, 100, 'image/jpeg', line);
  IF NOT pg_temp.hp_ok(r) THEN RAISE EXCEPTION 'held items photos 304: fixture: register % failed: %', cid, r; END IF;
  put := pg_temp.hp_put(claims, CASE role WHEN 'dispatch' THEN 'dispatch-images' ELSE 'grn-images' END, r->>'storage_path');
  IF put <> 'rows:1' THEN RAISE EXCEPTION 'held items photos 304: fixture: upload of % answered %', cid, put; END IF;
  RETURN r;
END $$;

-- (a) A photo removed from the saved GRN is never put back by a later confirm (header and line photo alike).
SELECT pg_temp.hp_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hp_item('hp-d1', 'newGrn', 60, :'ca'::uuid, pg_temp.hp_grn_body(:'ca'::uuid, :'item_id'::uuid, 2, 'HPD1G')))) AS g11a_hold \gset
SELECT pg_temp.hp_assert(:'g11a_hold'::jsonb->>'success' = 'true', 'fixture: hp-d1 handed over: ' || :'g11a_hold');
SELECT pg_temp.hp_hid('hp-d1') AS d1 \gset
SELECT pg_temp.hp_reg_put(:'staff_claims'::jsonb, :'d1'::uuid, 'pd1-h1', 'header', 'h1.jpg') AS d1_h1 \gset
SELECT pg_temp.hp_reg_put(:'staff_claims'::jsonb, :'d1'::uuid, 'pd1-h2', 'header', 'h2.jpg') AS d1_h2 \gset
SELECT pg_temp.hp_reg_put(:'staff_claims'::jsonb, :'d1'::uuid, 'pd1-l1', 'item', 'l1.jpg', 'index:0') AS d1_l1 \gset
SELECT pg_temp.hp_reg_put(:'staff_claims'::jsonb, :'d1'::uuid, 'pd1-b', 'header', 'b.jpg') AS d1_b \gset
SELECT pg_temp.hp_reg_put(:'staff_claims'::jsonb, :'d1'::uuid, 'pd1-c', 'item', 'c.jpg', 'index:0') AS d1_c \gset
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'d1'::uuid, 'pd1-h1') AS d1_ch1 \gset
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'d1'::uuid, 'pd1-h2') AS d1_ch2 \gset
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'d1'::uuid, 'pd1-l1') AS d1_cl1 \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'d1_ch1'::jsonb) AND pg_temp.hp_ok(:'d1_ch2'::jsonb) AND pg_temp.hp_ok(:'d1_cl1'::jsonb),
  'fixture: h1, h2 and l1 confirmed before the accept: ' || :'d1_ch1' || ' / ' || :'d1_ch2' || ' / ' || :'d1_cl1');
SELECT pg_temp.hp_decide(:'admin_claims'::jsonb, :'d1'::uuid, 'accept', 'hp-dk-d1') AS d1_accept \gset
SELECT id AS d1_grn FROM public.goodsreceived WHERE request_key = 'hp-d1' \gset
SELECT count(*) AS d1_n0 FROM public.grn_images WHERE grn_id = :'d1_grn'::uuid \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'d1_accept'::jsonb) AND :'d1_n0'::int = 3, 'G11a: the accept attached the three confirmed photos (images ' || :'d1_n0' || ', want 3): ' || :'d1_accept');
-- A manager removes h1 (header) and l1 (line photo) from the saved GRN with the product call.
SELECT id AS d1_h1_img FROM public.grn_images WHERE grn_id = :'d1_grn'::uuid AND storage_path = :'d1_h1'::jsonb->>'storage_path' \gset
SELECT id AS d1_l1_img FROM public.grn_images WHERE grn_id = :'d1_grn'::uuid AND storage_path = :'d1_l1'::jsonb->>'storage_path' \gset
SELECT pg_temp.hp_as(:'admin_claims'::jsonb, format('SELECT public.delete_grn_image(%L::uuid)', :'d1_h1_img')) AS d1_del1 \gset
SELECT pg_temp.hp_as(:'admin_claims'::jsonb, format('SELECT public.delete_grn_image(%L::uuid)', :'d1_l1_img')) AS d1_del2 \gset
SELECT count(*) AS d1_n1 FROM public.grn_images WHERE grn_id = :'d1_grn'::uuid \gset
SELECT pg_temp.hp_assert(:'d1_del1'::jsonb->>'success' = 'true' AND :'d1_del2'::jsonb->>'success' = 'true' AND :'d1_n1'::int = 1,
  'fixture: the manager removed h1 and l1 (images left ' || :'d1_n1' || ', want 1): ' || :'d1_del1' || ' / ' || :'d1_del2');
-- The still-uploading photos b (header) and c (line) are confirmed afterwards, and the removed ones are confirmed again.
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'d1'::uuid, 'pd1-b') AS d1_cb \gset
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'d1'::uuid, 'pd1-c') AS d1_cc \gset
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'d1'::uuid, 'pd1-h1') AS d1_rh1 \gset
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'d1'::uuid, 'pd1-l1') AS d1_rl1 \gset
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'d1'::uuid, 'pd1-b') AS d1_rb \gset
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'d1'::uuid, 'pd1-c') AS d1_rc \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'d1_cb'::jsonb) AND pg_temp.hp_ok(:'d1_cc'::jsonb) AND pg_temp.hp_ok(:'d1_rh1'::jsonb) AND pg_temp.hp_ok(:'d1_rl1'::jsonb)
  AND pg_temp.hp_ok(:'d1_rb'::jsonb) AND pg_temp.hp_ok(:'d1_rc'::jsonb), 'G11a: every confirm answers success: ' || :'d1_cb' || ' / ' || :'d1_cc' || ' / ' || :'d1_rh1' || ' / ' || :'d1_rl1');
SELECT count(*) AS d1_n2 FROM public.grn_images WHERE grn_id = :'d1_grn'::uuid \gset
SELECT count(*) AS d1_back FROM public.grn_images WHERE grn_id = :'d1_grn'::uuid AND storage_path IN (:'d1_h1'::jsonb->>'storage_path', :'d1_l1'::jsonb->>'storage_path') \gset
SELECT count(*) AS d1_b_n FROM public.grn_images WHERE grn_id = :'d1_grn'::uuid AND storage_path = :'d1_b'::jsonb->>'storage_path' AND image_type = 'header' AND uploaded_by = :'staff_profile'::uuid \gset
SELECT count(*) AS d1_c_n FROM public.grn_images WHERE grn_id = :'d1_grn'::uuid AND storage_path = :'d1_c'::jsonb->>'storage_path' AND image_type = 'item' AND grn_item_id IS NOT NULL AND uploaded_by = :'staff_profile'::uuid \gset
SELECT count(*) AS d1_h2_n FROM public.grn_images WHERE grn_id = :'d1_grn'::uuid AND storage_path = :'d1_h2'::jsonb->>'storage_path' \gset
SELECT pg_temp.hp_assert(:'d1_back'::int = 0, 'G11a: the header photo and the line photo the manager removed are not put back (back on the GRN: ' || :'d1_back' || ', want 0)');
SELECT pg_temp.hp_assert(:'d1_b_n'::int = 1 AND :'d1_c_n'::int = 1, 'G11a: the late header and line photos are attached once, by the recorder (b ' || :'d1_b_n' || ', c ' || :'d1_c_n' || ', want 1 and 1)');
SELECT pg_temp.hp_assert(:'d1_n2'::int = 3 AND :'d1_h2_n'::int = 1, 'G11a: the GRN has h2, b and c only, after repeats (images ' || :'d1_n2' || ', h2 ' || :'d1_h2_n' || ', want 3 and 1)');

-- (b) The line a photo is mapped to was deleted by a GRN edit, or the GRN was deleted: a refusal, nothing written, the photo stays pending.
SELECT pg_temp.hp_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hp_item('hp-d2', 'newGrn', 61, :'ca'::uuid, pg_temp.hp_grn_body2(:'ca'::uuid, :'item_id'::uuid, 'HPD2G')),
  pg_temp.hp_item('hp-d3', 'newGrn', 62, :'ca'::uuid, pg_temp.hp_grn_body(:'ca'::uuid, :'item_id'::uuid, 2, 'HPD3G')))) AS g11b_hold \gset
SELECT pg_temp.hp_assert(:'g11b_hold'::jsonb->>'success' = 'true', 'fixture: hp-d2 and hp-d3 handed over: ' || :'g11b_hold');
SELECT pg_temp.hp_hid('hp-d2') AS d2, pg_temp.hp_hid('hp-d3') AS d3 \gset
SELECT pg_temp.hp_reg_put(:'staff_claims'::jsonb, :'d2'::uuid, 'pd2-l0', 'item', 'l0.jpg', 'index:0') AS d2_l0 \gset
SELECT pg_temp.hp_reg_put(:'staff_claims'::jsonb, :'d2'::uuid, 'pd2-l1', 'item', 'l1.jpg', 'index:1') AS d2_l1 \gset
SELECT pg_temp.hp_reg_put(:'staff_claims'::jsonb, :'d2'::uuid, 'pd2-h', 'header', 'h.jpg') AS d2_h \gset
SELECT pg_temp.hp_reg_put(:'staff_claims'::jsonb, :'d3'::uuid, 'pd3-h', 'header', 'h.jpg') AS d3_h \gset
SELECT pg_temp.hp_reg_put(:'staff_claims'::jsonb, :'d3'::uuid, 'pd3-l', 'item', 'l.jpg', 'index:0') AS d3_l \gset
SELECT pg_temp.hp_decide(:'admin_claims'::jsonb, :'d2'::uuid, 'accept', 'hp-dk-d2') AS d2_accept \gset
SELECT pg_temp.hp_decide(:'admin_claims'::jsonb, :'d3'::uuid, 'accept', 'hp-dk-d3') AS d3_accept \gset
SELECT id AS d2_grn FROM public.goodsreceived WHERE request_key = 'hp-d2' \gset
SELECT id AS d3_grn FROM public.goodsreceived WHERE request_key = 'hp-d3' \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'d2_accept'::jsonb) AND pg_temp.hp_ok(:'d3_accept'::jsonb), 'fixture: both GRNs accepted with every photo still pending: ' || :'d2_accept' || ' / ' || :'d3_accept');
SELECT e ->> 'item_id' AS d2_line0 FROM public.held_items, jsonb_array_elements(item_mapping) e WHERE id = :'d2'::uuid AND e ->> 'index' = '0' \gset
SELECT e ->> 'item_id' AS d2_line1 FROM public.held_items, jsonb_array_elements(item_mapping) e WHERE id = :'d2'::uuid AND e ->> 'index' = '1' \gset
-- The administrator edits the GRN and leaves line 0 out: the product's edit deletes it.
SELECT pg_temp.hp_as(:'admin_claims'::jsonb, format('SELECT public.update_grn(p_grn_id => %L::uuid, p_items => %L::jsonb)', :'d2_grn',
  jsonb_build_array(jsonb_build_object('id', :'d2_line1', 'item_id', :'item_id', 'item_name', 'Photo Cumin', 'packaging', 'Bag', 'qty', 3, 'weight', 10, 'rack', 'N2', 'package_mark', 'N2')))) AS d2_edit \gset
SELECT count(*) AS d2_lines FROM public.goodsreceived_trl WHERE gr_id = :'d2_grn'::uuid \gset
SELECT count(*) AS d2_line0_left FROM public.goodsreceived_trl WHERE id = :'d2_line0'::uuid \gset
SELECT pg_temp.hp_assert(:'d2_edit'::jsonb->>'success' = 'true' AND :'d2_lines'::int = 1 AND :'d2_line0_left'::int = 0,
  'fixture: the edit deleted line 0 (lines ' || :'d2_lines' || ', line 0 left ' || :'d2_line0_left' || '): ' || :'d2_edit');
SELECT count(*) AS d2_n0 FROM public.grn_images WHERE grn_id = :'d2_grn'::uuid \gset
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'d2'::uuid, 'pd2-l0') AS d2_c0 \gset
SELECT pg_temp.hp_photo_state(:'d2'::uuid, 'pd2-l0') AS d2_s0 \gset
SELECT count(*) AS d2_n1 FROM public.grn_images WHERE grn_id = :'d2_grn'::uuid \gset
SELECT pg_temp.hp_assert(:'d2_c0'::jsonb->>'success' = 'false' AND NOT (:'d2_c0'::jsonb ? 'raised') AND :'d2_c0'::text LIKE '%HELD_PHOTO_LINE_GONE%',
  'G11b: confirming a photo whose line was deleted answers HELD_PHOTO_LINE_GONE as a refusal, not an exception: ' || :'d2_c0');
SELECT pg_temp.hp_assert(:'d2_s0' = 'pending' AND :'d2_n1'::int = :'d2_n0'::int, 'G11b: nothing was written for it: the photo is ' || :'d2_s0' || ' (want pending), images ' || :'d2_n0' || ' before and ' || :'d2_n1' || ' after');
SELECT pg_temp.hp_mark(:'staff_claims'::jsonb, :'d2'::uuid, 'pd2-l0', 'item', 'index:0', 'The line was deleted') AS d2_m0 \gset
SELECT state AS d2_ms, COALESCE(document_id::text, 'NULL') AS d2_md FROM public.held_item_photos WHERE held_id = :'d2'::uuid AND client_photo_id = 'pd2-l0' \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'d2_m0'::jsonb) AND :'d2_ms' = 'missing' AND :'d2_md' = :'d2_grn',
  'G11b: the phone can then mark it missing, linked to the GRN (answer ' || :'d2_m0' || ', state ' || :'d2_ms' || ', document ' || :'d2_md' || ')');
-- Another photo of the same item still attaches: a line that survives, and the header.
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'d2'::uuid, 'pd2-l1') AS d2_c1 \gset
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'d2'::uuid, 'pd2-h') AS d2_ch \gset
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'d2'::uuid, 'pd2-l1') AS d2_c1b \gset
SELECT count(*) AS d2_l1_n FROM public.grn_images WHERE grn_id = :'d2_grn'::uuid AND storage_path = :'d2_l1'::jsonb->>'storage_path' AND grn_item_id = :'d2_line1'::uuid AND uploaded_by = :'staff_profile'::uuid \gset
SELECT count(*) AS d2_h_n FROM public.grn_images WHERE grn_id = :'d2_grn'::uuid AND storage_path = :'d2_h'::jsonb->>'storage_path' AND image_type = 'header' \gset
SELECT count(*) AS d2_n2 FROM public.grn_images WHERE grn_id = :'d2_grn'::uuid \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'d2_c1'::jsonb) AND pg_temp.hp_ok(:'d2_ch'::jsonb) AND pg_temp.hp_ok(:'d2_c1b'::jsonb),
  'G11b: the surviving line photo and the header photo confirm: ' || :'d2_c1' || ' / ' || :'d2_ch' || ' / ' || :'d2_c1b');
SELECT pg_temp.hp_assert(:'d2_l1_n'::int = 1 AND :'d2_h_n'::int = 1 AND :'d2_n2'::int = 2,
  'G11b: the photo of the surviving line is on that line once, the header photo is attached, and the GRN has those two only (line photo ' || :'d2_l1_n' || ', header ' || :'d2_h_n' || ', images ' || :'d2_n2' || ', want 1, 1, 2)');
-- A deleted GRN.
SELECT pg_temp.hp_as(:'admin_claims'::jsonb, format('SELECT public.delete_grn_safe(%L::uuid)', :'d3_grn')) AS d3_del \gset
SELECT count(*) AS d3_n0 FROM public.grn_images WHERE grn_id = :'d3_grn'::uuid \gset
SELECT pg_temp.hp_assert(:'d3_del'::jsonb->>'success' = 'true', 'fixture: the GRN of hp-d3 is deleted: ' || :'d3_del');
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'d3'::uuid, 'pd3-h') AS d3_ch \gset
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'d3'::uuid, 'pd3-l') AS d3_cl \gset
SELECT pg_temp.hp_photo_state(:'d3'::uuid, 'pd3-h') AS d3_sh \gset
SELECT pg_temp.hp_photo_state(:'d3'::uuid, 'pd3-l') AS d3_sl \gset
SELECT count(*) AS d3_n1 FROM public.grn_images WHERE grn_id = :'d3_grn'::uuid \gset
SELECT pg_temp.hp_assert(:'d3_ch'::jsonb->>'success' = 'false' AND NOT (:'d3_ch'::jsonb ? 'raised') AND :'d3_ch'::text LIKE '%HELD_PHOTO_DOCUMENT_GONE%'
  AND :'d3_cl'::jsonb->>'success' = 'false' AND NOT (:'d3_cl'::jsonb ? 'raised') AND :'d3_cl'::text LIKE '%HELD_PHOTO_DOCUMENT_GONE%',
  'G11b: confirming a header and a line photo of a deleted GRN answers HELD_PHOTO_DOCUMENT_GONE as a refusal: ' || :'d3_ch' || ' / ' || :'d3_cl');
SELECT pg_temp.hp_assert(:'d3_sh' = 'pending' AND :'d3_sl' = 'pending' AND :'d3_n1'::int = :'d3_n0'::int,
  'G11b: nothing was written (states ' || :'d3_sh' || ' / ' || :'d3_sl' || ', want pending; images ' || :'d3_n0' || ' before and ' || :'d3_n1' || ' after)');
SELECT pg_temp.hp_mark(:'staff_claims'::jsonb, :'d3'::uuid, 'pd3-h', 'header', NULL, 'The GRN was deleted') AS d3_m \gset
SELECT state AS d3_ms FROM public.held_item_photos WHERE held_id = :'d3'::uuid AND client_photo_id = 'pd3-h' \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'d3_m'::jsonb) AND :'d3_ms' = 'missing', 'G11b: the phone can mark it missing after the GRN is gone (answer ' || :'d3_m' || ', state ' || :'d3_ms' || ')');

-- (c) Kinds that attach nothing late: an accepted lotChange and an accepted grnEdit keep their photos with the held item.
-- The migration answers success (the photo is confirmed) and attaches nothing; the photo is not linked to a document (held_document answers only for
-- newGrn, newDispatch and photos).
SELECT id AS e_line FROM public.goodsreceived_trl WHERE gr_id = :'s1_grn'::uuid \gset
SELECT pg_temp.hp_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hp_item('hp-lc', 'lotChange', 70, :'ca'::uuid, jsonb_build_object('lotId', :'a1_line_id', 'grnId', :'a1_grn', 'recordedAt', now() - interval '2 hours',
    'changes', jsonb_build_object('rack', jsonb_build_object('from', 'N1', 'to', 'N3')))),
  pg_temp.hp_item('hp-ge', 'grnEdit', 71, :'ca'::uuid, jsonb_build_object('v', 1, 'grnId', :'s1_grn', 'loadedAt', NULL, 'recordedAt', now() - interval '2 hours',
    'lots', jsonb_build_object(:'e_line', jsonb_build_object('rack', jsonb_build_object('from', 'N1', 'to', 'N4'))))))) AS g11c_hold \gset
SELECT pg_temp.hp_assert(:'g11c_hold'::jsonb->>'success' = 'true', 'fixture: hp-lc and hp-ge handed over: ' || :'g11c_hold');
SELECT pg_temp.hp_hid('hp-lc') AS lc, pg_temp.hp_hid('hp-ge') AS ge \gset
SELECT pg_temp.hp_reg_put(:'staff_claims'::jsonb, :'lc'::uuid, 'pl-h', 'header', 'lc.jpg') AS lc_h \gset
SELECT pg_temp.hp_reg_put(:'staff_claims'::jsonb, :'ge'::uuid, 'pg-h', 'header', 'ge.jpg') AS ge_h \gset
SELECT pg_temp.hp_decide(:'admin_claims'::jsonb, :'lc'::uuid, 'accept', 'hp-dk-lc') AS lc_accept \gset
SELECT pg_temp.hp_decide(:'admin_claims'::jsonb, :'ge'::uuid, 'accept', 'hp-dk-ge') AS ge_accept \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'lc_accept'::jsonb) AND pg_temp.hp_ok(:'ge_accept'::jsonb), 'fixture: lotChange and grnEdit accepted: ' || :'lc_accept' || ' / ' || :'ge_accept');
SELECT count(*) AS lc_n0 FROM public.grn_images WHERE grn_id = :'a1_grn'::uuid \gset
SELECT count(*) AS ge_n0 FROM public.grn_images WHERE grn_id = :'s1_grn'::uuid \gset
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'lc'::uuid, 'pl-h') AS lc_c \gset
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'ge'::uuid, 'pg-h') AS ge_c \gset
SELECT count(*) AS lc_n1 FROM public.grn_images WHERE grn_id = :'a1_grn'::uuid \gset
SELECT count(*) AS ge_n1 FROM public.grn_images WHERE grn_id = :'s1_grn'::uuid \gset
SELECT count(*) AS cx_any FROM public.grn_images WHERE storage_path IN (:'lc_h'::jsonb->>'storage_path', :'ge_h'::jsonb->>'storage_path') \gset
SELECT count(*) AS cx_doc FROM public.held_item_photos WHERE held_id IN (:'lc'::uuid, :'ge'::uuid) AND (document_id IS NOT NULL OR attached_at IS NOT NULL) \gset
SELECT pg_temp.hp_assert(pg_temp.hp_ok(:'lc_c'::jsonb) AND :'lc_c'::jsonb->>'status' = 'confirmed' AND pg_temp.hp_ok(:'ge_c'::jsonb) AND :'ge_c'::jsonb->>'status' = 'confirmed',
  'G11c: a late confirm of a lotChange or grnEdit photo answers success, confirmed: ' || :'lc_c' || ' / ' || :'ge_c');
SELECT pg_temp.hp_assert(:'lc_n1'::int = :'lc_n0'::int AND :'ge_n1'::int = :'ge_n0'::int AND :'cx_any'::int = 0,
  'G11c: nothing is attached to the GRN (images before/after: lotChange GRN ' || :'lc_n0' || '/' || :'lc_n1' || ', grnEdit GRN ' || :'ge_n0' || '/' || :'ge_n1' || ', on any GRN ' || :'cx_any' || ')');
SELECT pg_temp.hp_assert(:'cx_doc'::int = 0, 'G11c: the photos are linked to no document and not stamped attached (rows with a document or attached_at ' || :'cx_doc' || ', want 0)');
SELECT pg_temp.hp_assert(NOT has_function_privilege('authenticated', 'warehouse_security.held_attach_one(uuid,text)', 'EXECUTE')
  AND NOT has_function_privilege('service_role', 'warehouse_security.held_attach_one(uuid,text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'warehouse_security.held_attach_one(uuid,text)', 'EXECUTE'), 'G7: held_attach_one is executable by no app role');
-- The two new helpers are for the database owner's functions only: no app role runs them (no new public function, so no allowlist row).
SELECT pg_temp.hp_assert(NOT has_function_privilege('authenticated', 'warehouse_security.held_document(uuid,text)', 'EXECUTE')
  AND NOT has_function_privilege('service_role', 'warehouse_security.held_document(uuid,text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'warehouse_security.held_document(uuid,text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'warehouse_security.held_attach_late(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('service_role', 'warehouse_security.held_attach_late(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'warehouse_security.held_attach_late(uuid)', 'EXECUTE'),
  'G7: held_document and held_attach_late are executable by no app role');
ROLLBACK;
\echo 'WH-304 held item photos (B-5) checks passed.'

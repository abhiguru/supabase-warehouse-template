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
-- A decided item takes no more photos.
SELECT pg_temp.hp_n() AS n_g4 \gset
SELECT pg_temp.hp_reg(:'staff_claims'::jsonb, :'g1'::uuid, 'ph-late', 'header', 'late.jpg', 10, 'image/jpeg') AS g4_reg_acc \gset
SELECT pg_temp.hp_confirm(:'staff_claims'::jsonb, :'g1'::uuid, 'ph-c') AS g4_conf_acc \gset
SELECT pg_temp.hp_assert(pg_temp.hp_refused(:'g4_reg_acc'::jsonb, 'HELD_ALREADY_DECIDED') AND pg_temp.hp_refused(:'g4_conf_acc'::jsonb, 'HELD_ALREADY_DECIDED')
  AND pg_temp.hp_n() = :'n_g4'::bigint AND pg_temp.hp_photo_state(:'g1'::uuid, 'ph-c') = 'pending',
  'G3: an accepted item is HELD_ALREADY_DECIDED for register and confirm, and the pending photo stays pending: ' || :'g4_reg_acc' || ' / ' || :'g4_conf_acc');
SELECT pg_temp.hp_assert(pg_temp.hp_access(:'staff_claims'::jsonb, 'grn-images', :'path_c', true) = 'false'
  AND pg_temp.hp_access(:'staff_claims'::jsonb, 'grn-images', :'path_c', false) = 'true', 'G5: once the item is decided staff may no longer write its pending file, and still read it');
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
ROLLBACK;
\echo 'WH-304 held item photos (B-5) checks passed.'

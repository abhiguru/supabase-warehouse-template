-- Migration 130: GRN and dispatch input rules (reasons and data the app shows its own texts for).
--   D10   a GRN is not dated in the future (save_grn; update_grn when the date changes)
--   D15   a GRN keeps its last confirmed photo (delete_grn_image, update_grn)
--   D17   dispatch.registration holds 20 characters; beyond that a plain refusal
--   App34 dispatch and new GRN numbers have no whitespace
--   App42 an all-digit order search matches an exact weight or text
--   B15   a dispatch date with a time is the IST day of that moment
--   B19   unfinished photo uploads older than 24 hours are removed by the daily job
--   B20   a dispatch is deleted only through delete_dispatch_with_order_cleanup
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database. Every row rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.r130_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'rules 130: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.r130_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM pg_temp.r130_assert(challenge->>'success'='true','challenge for '||phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  login := public.operator_verify_otp(phone,challenge#>>'{data,otp_code}');
  PERFORM pg_temp.r130_assert(login#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id=p.auth_user_id
    WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- A receipt with one line, as the app saves it. Called as the administrator.
CREATE FUNCTION pg_temp.r130_grn(p_number text, p_date timestamptz DEFAULT now(), p_images jsonb DEFAULT '[]') RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.save_grn(p_gr_no => p_number, p_date => p_date, p_customer_id => current_setting('test.r130_customer')::uuid,
    p_customer_name => 'Rules 130 Customer',
    p_items => jsonb_build_array(jsonb_build_object('item_id', current_setting('test.r130_item'), 'item_name', 'Rules 130 Potatoes',
      'packaging', 'Bag', 'qty', 10, 'weight', 50, 'rack', '1', 'package_mark', 'MK4455')),
    p_images => p_images) $$;
-- The lines of a receipt, as an edit sends them back.
CREATE FUNCTION pg_temp.r130_lines(p_grn uuid) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_agg(jsonb_build_object('id', t.id, 'item_id', t.item_id, 'item_name', t.item_name, 'packaging', t.packaging,
    'qty', t.qty, 'weight', t.weight, 'rack', t.rack, 'package_mark', t.package_mark))
  FROM public.goodsreceived_trl t WHERE t.gr_id = p_grn $$;

INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888888901','Rules 130 Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
SELECT pg_temp.r130_login('9888888901') AS admin_claims \gset
INSERT INTO public.customers(name,mobile) VALUES ('Rules 130 Customer','9888888911') RETURNING id AS customer_id \gset
INSERT INTO public.items(name,packaging) VALUES ('Rules 130 Potatoes','Bag') RETURNING id AS item_id \gset
SELECT set_config('test.r130_customer', :'customer_id', true), set_config('test.r130_item', :'item_id', true) \gset
SELECT to_char(warehouse_security.business_date(now()), 'YYYY-MM-DD') AS today \gset
-- Numbers are free text here, so these tests meet the rules of this migration and not the facility's numbering.
SELECT warehouse_security.apply_document_numbering('grn', '{"scheme":"free"}', NULL) AS _ \gset
SELECT warehouse_security.apply_document_numbering('dispatch', '{"scheme":"free"}', NULL) AS _ \gset

-- ===== D10. A GRN is not dated in the future =====
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.r130_grn('A1301', now() + interval '2 days') AS future_save,
       pg_temp.r130_grn('A1302', now()) AS today_save \gset
RESET ROLE;
SELECT pg_temp.r130_assert(:'future_save'::jsonb->>'success' = 'false' AND :'future_save'::jsonb->>'reason' = 'GRN_DATE_FUTURE'
  AND :'future_save'::jsonb->>'today' = :'today' AND :'future_save'::jsonb->>'date' = to_char(warehouse_security.business_date(now() + interval '2 days'), 'YYYY-MM-DD')
  AND :'future_save'::jsonb->>'message' = format('A GRN can''t be dated in the future. Today is %s.', :'today')
  AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no = 'A1301'), 'a future GRN date is refused, nothing written: '||:'future_save');
SELECT pg_temp.r130_assert(:'today_save'::jsonb->>'success' = 'true', 'today is saved: '||:'today_save');
SELECT id AS grn_today FROM public.goodsreceived WHERE gr_no = 'A1302' \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id => :'grn_today'::uuid, p_date => now() + interval '3 days', p_items => pg_temp.r130_lines(:'grn_today'::uuid)) AS future_edit \gset
RESET ROLE;
SELECT pg_temp.r130_assert(:'future_edit'::jsonb->>'reason' = 'GRN_DATE_FUTURE' AND :'future_edit'::jsonb->>'today' = :'today'
  AND (SELECT warehouse_security.business_date(date) = warehouse_security.business_date(now()) FROM public.goodsreceived WHERE id = :'grn_today'::uuid),
  'an edit to a future date is refused and the date stays: '||:'future_edit');
-- A stored future date (old data) sent back as it is stays editable; a change to another future day is refused.
UPDATE public.goodsreceived SET date = now() + interval '5 days' WHERE id = :'grn_today'::uuid;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id => :'grn_today'::uuid, p_date => (SELECT date FROM public.goodsreceived WHERE id = :'grn_today'::uuid),
         p_note => 'same future day', p_items => pg_temp.r130_lines(:'grn_today'::uuid)) AS stored_future,
       public.update_grn(p_grn_id => :'grn_today'::uuid, p_date => now() + interval '9 days', p_items => pg_temp.r130_lines(:'grn_today'::uuid)) AS other_future,
       public.update_grn(p_grn_id => :'grn_today'::uuid, p_date => now() - interval '1 day', p_items => pg_temp.r130_lines(:'grn_today'::uuid)) AS to_past \gset
RESET ROLE;
SELECT pg_temp.r130_assert(:'stored_future'::jsonb->>'success' = 'true' AND :'other_future'::jsonb->>'reason' = 'GRN_DATE_FUTURE'
  AND :'to_past'::jsonb->>'success' = 'true', 'the stored future day is not rechecked, another one is refused, the past is fine: '||:'stored_future'||' '||:'other_future'||' '||:'to_past');

-- ===== D15. A GRN keeps its last confirmed photo =====
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.r130_grn('A1303') AS photo_grn \gset
RESET ROLE;
SELECT id AS grn_photo FROM public.goodsreceived WHERE gr_no = 'A1303' \gset
INSERT INTO public.grn_images(grn_id, image_type, storage_path, original_filename, file_size, mime_type, status, uploaded_by) VALUES
 (:'grn_photo'::uuid, 'header', 'grn/r130/one.jpg', 'one.jpg', 1000, 'image/jpeg', 'confirmed', :'admin_profile'::uuid),
 (:'grn_photo'::uuid, 'header', 'grn/r130/two.jpg', 'two.jpg', 1000, 'image/jpeg', 'confirmed', :'admin_profile'::uuid);
SELECT id AS photo_one FROM public.grn_images WHERE storage_path = 'grn/r130/one.jpg' \gset
SELECT id AS photo_two FROM public.grn_images WHERE storage_path = 'grn/r130/two.jpg' \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_grn_image(:'photo_one'::uuid) AS del_first,
       public.delete_grn_image(:'photo_two'::uuid) AS del_last \gset
RESET ROLE;
SELECT pg_temp.r130_assert(:'del_first'::jsonb->>'success' = 'true', 'one of two photos can be deleted: '||:'del_first');
SELECT pg_temp.r130_assert(:'del_last'::jsonb->>'success' = 'false' AND :'del_last'::jsonb->>'reason' = 'GRN_PHOTO_REQUIRED'
  AND :'del_last'::jsonb->>'gr_no' = 'A1303' AND :'del_last'::jsonb->>'grn_id' = :'grn_photo' AND :'del_last'::jsonb->>'image_id' = :'photo_two'
  AND EXISTS (SELECT 1 FROM public.grn_images WHERE id = :'photo_two'::uuid), 'the last photo stays: '||:'del_last');
-- An unfinished upload is not a photo of the GRN: deleting it is always allowed, and it does not count as the last one.
INSERT INTO public.grn_images(grn_id, image_type, storage_path, original_filename, file_size, mime_type, status, uploaded_by)
 VALUES (:'grn_photo'::uuid, 'header', 'grn/r130/pending.jpg', 'pending.jpg', 1000, 'image/jpeg', 'pending', :'admin_profile'::uuid);
SELECT id AS photo_pending FROM public.grn_images WHERE storage_path = 'grn/r130/pending.jpg' \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_grn_image(:'photo_two'::uuid) AS del_with_pending,
       public.update_grn(p_grn_id => :'grn_photo'::uuid, p_note => 'only an unfinished upload listed', p_items => pg_temp.r130_lines(:'grn_photo'::uuid),
         p_images => jsonb_build_array(jsonb_build_object('id', :'photo_pending', 'storage_path', 'grn/r130/pending.jpg', 'image_type', 'header'))) AS edit_drops_last,
       public.delete_grn_image(:'photo_pending'::uuid) AS del_pending,
       public.update_grn(p_grn_id => :'grn_photo'::uuid, p_note => 'the photo is listed', p_items => pg_temp.r130_lines(:'grn_photo'::uuid),
         p_images => jsonb_build_array(jsonb_build_object('id', :'photo_two', 'storage_path', 'grn/r130/two.jpg', 'image_type', 'header'))) AS edit_keeps \gset
RESET ROLE;
SELECT pg_temp.r130_assert(:'del_with_pending'::jsonb->>'reason' = 'GRN_PHOTO_REQUIRED', 'a pending row is not a second photo: '||:'del_with_pending');
SELECT pg_temp.r130_assert(:'edit_drops_last'::jsonb->>'success' = 'false' AND :'edit_drops_last'::jsonb->>'reason' = 'GRN_PHOTO_REQUIRED'
  AND :'edit_drops_last'::jsonb->>'gr_no' = 'A1303'
  AND EXISTS (SELECT 1 FROM public.grn_images WHERE id = :'photo_two'::uuid AND status = 'confirmed')
  AND (SELECT note IS DISTINCT FROM 'only an unfinished upload listed' FROM public.goodsreceived WHERE id = :'grn_photo'::uuid),
  'an edit that leaves no photo is refused and saves nothing: '||:'edit_drops_last');
SELECT pg_temp.r130_assert(:'edit_keeps'::jsonb->>'success' = 'true' AND :'del_pending'::jsonb->>'success' = 'true'
  AND NOT EXISTS (SELECT 1 FROM public.grn_images WHERE id = :'photo_pending'::uuid), 'listing the photo keeps it, and a pending row is deleted: '||:'edit_keeps'||' '||:'del_pending');

-- Photos of single items do not stand in for the GRN book photo: the last confirmed header photo stays whatever item photos exist, and an item photo can always go.
SELECT id AS photo_line FROM public.goodsreceived_trl WHERE gr_id = :'grn_photo'::uuid ORDER BY id LIMIT 1 \gset
INSERT INTO public.grn_images(grn_id, grn_item_id, image_type, storage_path, original_filename, file_size, mime_type, status, uploaded_by) VALUES
 (:'grn_photo'::uuid, :'photo_line'::uuid, 'item', 'grn/r130/item.jpg', 'item.jpg', 1000, 'image/jpeg', 'confirmed', :'admin_profile'::uuid);
SELECT id AS photo_item FROM public.grn_images WHERE storage_path = 'grn/r130/item.jpg' \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_grn_image(:'photo_two'::uuid) AS del_header_with_item,
       public.update_grn(p_grn_id => :'grn_photo'::uuid, p_note => 'only an item photo listed', p_items => pg_temp.r130_lines(:'grn_photo'::uuid),
         p_images => jsonb_build_array(jsonb_build_object('id', :'photo_item', 'storage_path', 'grn/r130/item.jpg', 'image_type', 'item', 'grn_item_id', :'photo_line'))) AS edit_item_only,
       public.delete_grn_image(:'photo_item'::uuid) AS del_item \gset
RESET ROLE;
SELECT pg_temp.r130_assert(:'del_header_with_item'::jsonb->>'reason' = 'GRN_PHOTO_REQUIRED' AND EXISTS (SELECT 1 FROM public.grn_images WHERE id = :'photo_two'::uuid),
  'an item photo is not a photo of the GRN: the last header photo stays: '||:'del_header_with_item');
SELECT pg_temp.r130_assert(:'edit_item_only'::jsonb->>'reason' = 'GRN_PHOTO_REQUIRED' AND EXISTS (SELECT 1 FROM public.grn_images WHERE id = :'photo_two'::uuid AND status = 'confirmed'),
  'an edit that lists only an item photo is refused: '||:'edit_item_only');
SELECT pg_temp.r130_assert(:'del_item'::jsonb->>'success' = 'true' AND NOT EXISTS (SELECT 1 FROM public.grn_images WHERE id = :'photo_item'::uuid),
  'an item photo can be deleted: '||:'del_item');

-- ===== A receipt and a dispatch header for the dispatch sections =====
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.r130_grn('A1304', now() - interval '2 days') AS lot_grn \gset
RESET ROLE;
SELECT t.id AS lot_id FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id = t.gr_id WHERE g.gr_no = 'A1304' \gset
SELECT jsonb_build_object('disp_date', :'today', 'customer_id', :'customer_id', 'customer_name', 'Rules 130 Customer',
  'supervisor_id', :'admin_profile', 'supervisor_name', 'Rules 130 Administrator') AS header \gset

-- ===== D17. A vehicle number of 20 characters =====
SELECT pg_temp.r130_assert((SELECT character_maximum_length = 20 FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'dispatch' AND column_name = 'registration'), 'dispatch.registration holds 20 characters');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'header'::jsonb || '{"disp_no":"R130D1","registration":"GJ01AB1234567890123X"}',
         ARRAY[jsonb_build_object('gr_trl_id', :'lot_id', 'disp_qty', 1)], false, 0, 'r130-reg-ok') AS reg_20,
       public.create_dispatch_with_stock_check(:'header'::jsonb || '{"disp_no":"R130D2","registration":"GJ01AB1234567890123XY"}',
         ARRAY[jsonb_build_object('gr_trl_id', :'lot_id', 'disp_qty', 1)], false, 0, 'r130-reg-long') AS reg_21 \gset
RESET ROLE;
SELECT pg_temp.r130_assert(:'reg_20'::jsonb->>'success' = 'true' AND (SELECT registration = 'GJ01AB1234567890123X' FROM public.dispatch WHERE disp_no = 'R130D1'),
  '20 characters are saved: '||:'reg_20');
SELECT pg_temp.r130_assert(:'reg_21'::jsonb->>'success' = 'false' AND :'reg_21'::jsonb->>'error_code' = 'registration_too_long'
  AND (:'reg_21'::jsonb#>>'{data,limit}')::int = 20 AND NOT EXISTS (SELECT 1 FROM public.dispatch WHERE disp_no = 'R130D2')
  AND (SELECT stock = 9 FROM public.goodsreceived_trl WHERE id = :'lot_id'::uuid), '21 characters are refused with a code, nothing written: '||:'reg_21');
SELECT id AS disp_one FROM public.dispatch WHERE disp_no = 'R130D1' \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_one'::uuid, '{"registration":"GJ01AB1234567890123XY"}'::jsonb, NULL) AS edit_21,
       public.update_dispatch_smart(:'disp_one'::uuid, '{"registration":"GJ01AB9999"}'::jsonb, NULL) AS edit_short \gset
RESET ROLE;
SELECT pg_temp.r130_assert(:'edit_21'::jsonb->>'error_code' = 'registration_too_long' AND :'edit_short'::jsonb->>'success' = 'true'
  AND (SELECT registration = 'GJ01AB9999' FROM public.dispatch WHERE id = :'disp_one'::uuid), 'an edit beyond 20 is refused, a short one saved: '||:'edit_21'||' '||:'edit_short');

-- ===== Registration. Surrounding spaces of a registration are not stored; the length counts the trimmed value =====
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_one'::uuid, '{"registration":"  GJ01AB1234567890123X  "}'::jsonb, NULL) AS edit_padded \gset
SELECT public.save_grn(p_gr_no => 'R130REG1', p_date => now(), p_customer_id => current_setting('test.r130_customer')::uuid,
    p_customer_name => 'Rules 130 Customer', p_registration => ' T31 X18 ',
    p_items => jsonb_build_array(jsonb_build_object('item_id', current_setting('test.r130_item'), 'item_name', 'Rules 130 Potatoes',
      'packaging', 'Bag', 'qty', 10, 'weight', 50, 'rack', '1', 'package_mark', 'MK4455'))) AS grn_padded \gset
RESET ROLE;
SELECT pg_temp.r130_assert(:'edit_padded'::jsonb->>'success' = 'true'
  AND (SELECT registration = 'GJ01AB1234567890123X' FROM public.dispatch WHERE id = :'disp_one'::uuid), 'a dispatch registration is trimmed (22 raw, 20 trimmed, accepted): '||:'edit_padded');
SELECT pg_temp.r130_assert(:'grn_padded'::jsonb->>'success' = 'true'
  AND (SELECT registration = 'T31 X18' FROM public.goodsreceived WHERE gr_no = 'R130REG1'), 'a new GRN registration is trimmed: '||:'grn_padded');
-- Tabs, line breaks and non-breaking spaces are trimmed too, and a blank registration is NULL (dispatch create, GRN create).
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'header'::jsonb || jsonb_build_object('disp_no','R130D3','registration',E'\t\u00a0GJ01AB1234\n '),
         ARRAY[jsonb_build_object('gr_trl_id', :'lot_id', 'disp_qty', 1)], false, 0, 'r130-reg-ws') AS reg_ws,
       public.create_dispatch_with_stock_check(:'header'::jsonb || jsonb_build_object('disp_no','R130D4','registration',E' \t\u00a0 '),
         ARRAY[jsonb_build_object('gr_trl_id', :'lot_id', 'disp_qty', 1)], false, 0, 'r130-reg-blank') AS reg_blank \gset
RESET ROLE;
SELECT pg_temp.r130_assert(:'reg_ws'::jsonb->>'success' = 'true' AND (SELECT registration = 'GJ01AB1234' FROM public.dispatch WHERE disp_no = 'R130D3'),
  'a dispatch registration is trimmed of tabs, line breaks and non-breaking spaces: '||:'reg_ws');
SELECT pg_temp.r130_assert(:'reg_blank'::jsonb->>'success' = 'true' AND (SELECT registration IS NULL FROM public.dispatch WHERE disp_no = 'R130D4'),
  'a blank dispatch registration is stored as NULL: '||:'reg_blank');
SELECT id AS grn_reg FROM public.goodsreceived WHERE gr_no = 'R130REG1' \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id => :'grn_reg'::uuid, p_registration => '  GJ01AB1234567890123X ', p_items => pg_temp.r130_lines(:'grn_reg'::uuid)) AS grn_edit_padded \gset
RESET ROLE;
SELECT pg_temp.r130_assert(:'grn_edit_padded'::jsonb->>'success' = 'true'
  AND (SELECT registration = 'GJ01AB1234567890123X' FROM public.goodsreceived WHERE id = :'grn_reg'::uuid), 'a GRN registration edit is trimmed: '||:'grn_edit_padded');

-- ===== App 34. No whitespace in a dispatch number or a new GRN number =====
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'header'::jsonb || '{"disp_no":"R130 D3"}',
         ARRAY[jsonb_build_object('gr_trl_id', :'lot_id', 'disp_qty', 1)], false, 0, 'r130-space-create') AS space_create,
       public.create_dispatch_with_stock_check(:'header'::jsonb || (E'{"disp_no":"R130D4\\t"}')::jsonb,
         ARRAY[jsonb_build_object('gr_trl_id', :'lot_id', 'disp_qty', 1)], false, 0, 'r130-tab-create') AS tab_create,
       public.update_dispatch_smart(:'disp_one'::uuid, '{"disp_no":"R130 D1"}'::jsonb, NULL) AS space_edit,
       public.check_dispatch_exists('R130 D1') AS space_check,
       public.check_dispatch_exists('R130D1') AS plain_check,
       pg_temp.r130_grn('A 1305') AS space_grn,
       pg_temp.r130_grn(' A1306') AS lead_grn,
       pg_temp.r130_grn('A1307') AS plain_grn \gset
RESET ROLE;
SELECT pg_temp.r130_assert(:'space_create'::jsonb->>'success' = 'false' AND :'space_create'::jsonb->>'reason' = 'DISPATCH_NUMBER_SPACES'
  AND :'space_create'::jsonb->>'number' = 'R130 D3' AND :'space_create'::jsonb->>'message' = 'A dispatch number can''t contain spaces.'
  AND :'tab_create'::jsonb->>'reason' = 'DISPATCH_NUMBER_SPACES'
  AND NOT EXISTS (SELECT 1 FROM public.dispatch WHERE disp_no ~ '^R130.D[34]'), 'create refuses a space and a tab, nothing written: '||:'space_create'||' '||:'tab_create');
SELECT pg_temp.r130_assert(:'space_edit'::jsonb->>'reason' = 'DISPATCH_NUMBER_SPACES'
  AND (SELECT disp_no = 'R130D1' FROM public.dispatch WHERE id = :'disp_one'::uuid), 'the edit refuses a changed number with a space: '||:'space_edit');
SELECT pg_temp.r130_assert(:'space_check'::jsonb->>'reason' = 'DISPATCH_NUMBER_SPACES' AND :'plain_check'::jsonb#>>'{data,exists}' = 'true',
  'the lookup refuses a number with a space and still finds R130D1: '||:'space_check'||' '||:'plain_check');
SELECT pg_temp.r130_assert(:'space_grn'::jsonb->>'reason' = 'GRN_NUMBER_SPACES' AND :'lead_grn'::jsonb->>'reason' = 'GRN_NUMBER_SPACES'
  AND :'space_grn'::jsonb->>'message' = 'A GRN number can''t contain spaces.' AND :'plain_grn'::jsonb->>'success' = 'true'
  AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no IN ('A 1305', ' A1306')), 'a new GRN number with a space is refused: '||:'space_grn'||' '||:'lead_grn');
-- Existing rows are untouched: a stored number with a space is edited and looked up as before, its own number sent back is accepted.
INSERT INTO public.dispatch(disp_no, customer_id) VALUES ('OLD 1', :'customer_id') RETURNING id AS disp_old \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_old'::uuid, '{"disp_no":"OLD 1","note":"same number sent back"}'::jsonb, NULL) AS old_sent_back \gset
RESET ROLE;
SELECT pg_temp.r130_assert((SELECT disp_no = 'OLD 1' AND note = 'same number sent back' FROM public.dispatch WHERE id = :'disp_old'::uuid),
  'the stored number with a space sent back is not refused: '||:'old_sent_back');

-- ===== App 42. An all-digit order search finds an exact weight or text =====
INSERT INTO public.customers(name,mobile) VALUES ('Rules 130 Search Customer','9888888912') RETURNING id AS search_customer \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_grn(p_gr_no => 'SRCH130', p_date => now(), p_customer_id => :'search_customer'::uuid, p_customer_name => 'Rules 130 Search Customer',
  p_items => jsonb_build_array(
    jsonb_build_object('item_id', :'item_id', 'item_name', 'Search Beans', 'packaging', 'Bag', 'qty', 10, 'weight', 50, 'rack', '1', 'package_mark', 'MK4455'),
    jsonb_build_object('item_id', :'item_id', 'item_name', 'Search Rice', 'packaging', 'Bag', 'qty', 10, 'weight', 4455, 'rack', '2', 'package_mark', 'R1'),
    jsonb_build_object('item_id', :'item_id', 'item_name', 'Search Corn', 'packaging', 'Bag', 'qty', 10, 'weight', 50, 'rack', '3', 'package_mark', 'C1'))) AS search_grn \gset
SELECT public.search_customer_items_for_order('4455', :'search_customer'::uuid) AS find_4455,
       public.search_customer_items_for_order('50', :'search_customer'::uuid) AS find_50,
       public.search_customer_items_for_order('4455', :'search_customer'::uuid, 'weight') AS find_weight_only,
       public.search_customer_items_for_order('Beans', :'search_customer'::uuid) AS find_text \gset
RESET ROLE;
SELECT pg_temp.r130_assert(:'search_grn'::jsonb->>'success' = 'true', 'search receipt: '||:'search_grn');
SELECT pg_temp.r130_assert((:'find_4455'::jsonb->>'total_count')::int = 2
  AND (SELECT array_agg(x->>'item_name' ORDER BY x->>'item_name') = ARRAY['Search Beans', 'Search Rice'] FROM jsonb_array_elements(:'find_4455'::jsonb->'items') x),
  '4455 finds the package mark MK4455 and the 4455 kg lot, not the others: '||:'find_4455');
SELECT pg_temp.r130_assert((:'find_50'::jsonb->>'total_count')::int = 2
  AND (SELECT array_agg(x->>'item_name' ORDER BY x->>'item_name') = ARRAY['Search Beans', 'Search Corn'] FROM jsonb_array_elements(:'find_50'::jsonb->'items') x),
  '50 still lists the 50 kg lots: '||:'find_50');
SELECT pg_temp.r130_assert((:'find_weight_only'::jsonb->>'total_count')::int = 1 AND (:'find_weight_only'::jsonb#>>'{items,0,item_name}') = 'Search Rice'
  AND (:'find_text'::jsonb->>'total_count')::int = 1, 'the type weight stays an exact weight, a word is a text search: '||:'find_weight_only');

-- ===== Backend 15. A dispatch date with a time is the IST day of that moment =====
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.r130_grn('A1309', '2026-04-01T12:00:00Z') AS old_grn \gset
RESET ROLE;
SELECT t.id AS old_lot FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id = t.gr_id WHERE g.gr_no = 'A1309' \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'header'::jsonb || '{"disp_no":"R130E1","disp_date":"2026-06-02T20:00:00Z"}',
         ARRAY[jsonb_build_object('gr_trl_id', :'old_lot', 'disp_qty', 1)], false, 0, 'r130-day-late') AS day_late,
       public.create_dispatch_with_stock_check(:'header'::jsonb || '{"disp_no":"R130E2","disp_date":"2026-06-02T10:00:00Z"}',
         ARRAY[jsonb_build_object('gr_trl_id', :'old_lot', 'disp_qty', 1)], false, 0, 'r130-day-early') AS day_early,
       public.create_dispatch_with_stock_check(:'header'::jsonb || jsonb_build_object('disp_no', 'R130E3', 'disp_date', :'today' || 'T20:00:00Z'),
         ARRAY[jsonb_build_object('gr_trl_id', :'old_lot', 'disp_qty', 1)], false, 0, 'r130-day-future') AS day_future \gset
RESET ROLE;
SELECT pg_temp.r130_assert(:'day_late'::jsonb->>'success' = 'true' AND :'day_early'::jsonb->>'success' = 'true'
  AND (SELECT warehouse_security.business_date(disp_date) = DATE '2026-06-03' FROM public.dispatch WHERE disp_no = 'R130E1')
  AND (SELECT warehouse_security.business_date(disp_date) = DATE '2026-06-02' FROM public.dispatch WHERE disp_no = 'R130E2'),
  '20:00Z is the next IST day, 10:00Z the same one: '||:'day_late'||' '||:'day_early');
SELECT pg_temp.r130_assert(:'day_future'::jsonb->>'reason' = 'DISPATCH_DATE_FUTURE'
  AND :'day_future'::jsonb->>'date' = to_char(DATE :'today' + 1, 'YYYY-MM-DD') AND NOT EXISTS (SELECT 1 FROM public.dispatch WHERE disp_no = 'R130E3'),
  'today 20:00Z is tomorrow in India and is refused as the future: '||:'day_future');
SELECT id AS disp_e2 FROM public.dispatch WHERE disp_no = 'R130E2' \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_e2'::uuid, '{"disp_date":"2026-06-02T20:00:00Z"}'::jsonb, NULL) AS edit_late,
       public.update_dispatch_smart(:'disp_e2'::uuid, jsonb_build_object('disp_date', :'today' || 'T20:00:00Z'), NULL) AS edit_future \gset
RESET ROLE;
SELECT pg_temp.r130_assert(:'edit_late'::jsonb->>'success' = 'true' AND :'edit_future'::jsonb->>'reason' = 'DISPATCH_DATE_FUTURE'
  AND (SELECT warehouse_security.business_date(disp_date) = DATE '2026-06-03' FROM public.dispatch WHERE id = :'disp_e2'::uuid),
  'the edit reads the IST day too: '||:'edit_late'||' '||:'edit_future');

-- ===== Backend 20. A dispatch is deleted only through delete_dispatch_with_order_cleanup =====
CREATE FUNCTION pg_temp.r130_error(statement text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE statement; EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE || ' ' || SQLERRM; END;
  RETURN 'no error';
END $$;
SELECT id AS disp_del FROM public.dispatch WHERE disp_no = 'R130E1' \gset
SELECT pg_temp.r130_error(format('DELETE FROM public.dispatch WHERE id = %L::uuid', :'disp_del')) AS direct_delete \gset
SELECT pg_temp.r130_assert(:'direct_delete' = 'WH409 Delete dispatches with delete_dispatch_with_order_cleanup.'
  AND EXISTS (SELECT 1 FROM public.dispatch WHERE id = :'disp_del'::uuid)
  AND EXISTS (SELECT 1 FROM public.dispatch_trl WHERE disp_id = :'disp_del'::uuid), 'a direct DELETE is refused and nothing changes: '||:'direct_delete');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_dispatch_with_order_cleanup(:'disp_del'::uuid, :'admin_profile'::uuid) AS rpc_delete \gset
RESET ROLE;
SELECT pg_temp.r130_assert(:'rpc_delete'::jsonb->>'success' = 'true' AND NOT EXISTS (SELECT 1 FROM public.dispatch WHERE id = :'disp_del'::uuid)
  AND (SELECT stock = 9 FROM public.goodsreceived_trl WHERE id = :'old_lot'::uuid), 'the function deletes and gives the stock back: '||:'rpc_delete');
SELECT id AS disp_after FROM public.dispatch WHERE disp_no = 'R130E2' \gset
SELECT pg_temp.r130_error(format('DELETE FROM public.dispatch WHERE id = %L::uuid', :'disp_after')) AS delete_after_rpc \gset
SELECT pg_temp.r130_assert(:'delete_after_rpc' LIKE 'WH409 %' AND EXISTS (SELECT 1 FROM public.dispatch WHERE id = :'disp_after'::uuid),
  'the permission to delete does not outlive the function: '||:'delete_after_rpc');

-- ===== Backend 19. Unfinished photo uploads older than 24 hours go with their file =====
INSERT INTO public.grn_images(grn_id, image_type, storage_path, original_filename, file_size, mime_type, status, uploaded_by, created_at) VALUES
 (:'grn_photo'::uuid, 'header', 'grn/r130/old-pending.jpg', 'a.jpg', 1000, 'image/jpeg', 'pending', :'admin_profile'::uuid, now() - interval '25 hours'),
 (:'grn_photo'::uuid, 'header', 'grn/r130/old-nofile.jpg', 'b.jpg', 1000, 'image/jpeg', 'pending', :'admin_profile'::uuid, now() - interval '26 hours'),
 (:'grn_photo'::uuid, 'header', 'grn/r130/fresh-pending.jpg', 'c.jpg', 1000, 'image/jpeg', 'pending', :'admin_profile'::uuid, now() - interval '1 hour'),
 (:'grn_photo'::uuid, 'header', 'grn/r130/old-confirmed.jpg', 'd.jpg', 1000, 'image/jpeg', 'confirmed', :'admin_profile'::uuid, now() - interval '30 hours');
INSERT INTO public.dispatch_images(dispatch_id, storage_path, original_filename, file_size, mime_type, status, uploaded_by, created_at) VALUES
 (:'disp_one'::uuid, 'dispatch/r130/old-pending.jpg', 'e.jpg', 1000, 'image/jpeg', 'pending', :'admin_profile'::uuid, now() - interval '25 hours'),
 (:'disp_one'::uuid, 'dispatch/r130/fresh-pending.jpg', 'f.jpg', 1000, 'image/jpeg', 'pending', :'admin_profile'::uuid, now() - interval '2 hours');
INSERT INTO storage.objects(bucket_id, name) VALUES
 ('grn-images', 'grn/r130/old-pending.jpg'), ('grn-images', 'grn/r130/fresh-pending.jpg'), ('grn-images', 'grn/r130/old-confirmed.jpg'),
 ('dispatch-images', 'dispatch/r130/old-pending.jpg'), ('dispatch-images', 'dispatch/r130/fresh-pending.jpg');
SELECT pg_temp.r130_assert((SELECT array_agg(n) = ARRAY['grn/r130/old-pending.jpg'] FROM warehouse_maintenance.expired_pending_images('grn-images', now()) n)
  AND (SELECT array_agg(n) = ARRAY['dispatch/r130/old-pending.jpg'] FROM warehouse_maintenance.expired_pending_images('dispatch-images', now()) n)
  AND NOT EXISTS (SELECT 1 FROM warehouse_maintenance.expired_pending_images('documents', now())),
  'only the old pending files are named, in their own bucket; fresh and confirmed ones are not');
-- A row whose file is still in storage is kept; one whose file never arrived is deleted.
SELECT warehouse_maintenance.delete_expired_pending_images(now()) AS first_delete \gset
SELECT pg_temp.r130_assert((:'first_delete'::jsonb->>'grn_images')::int = 1 AND (:'first_delete'::jsonb->>'dispatch_images')::int = 0
  AND NOT EXISTS (SELECT 1 FROM public.grn_images WHERE storage_path = 'grn/r130/old-nofile.jpg')
  AND EXISTS (SELECT 1 FROM public.grn_images WHERE storage_path = 'grn/r130/old-pending.jpg'), 'a row whose file is still stored stays: '||:'first_delete');
-- The Storage API removes the named files; the next run deletes their rows.
DELETE FROM storage.objects WHERE (bucket_id, name) IN (('grn-images', 'grn/r130/old-pending.jpg'), ('dispatch-images', 'dispatch/r130/old-pending.jpg'));
SELECT warehouse_maintenance.delete_expired_pending_images(now()) AS second_delete \gset
SELECT pg_temp.r130_assert((:'second_delete'::jsonb->>'grn_images')::int = 1 AND (:'second_delete'::jsonb->>'dispatch_images')::int = 1
  AND NOT EXISTS (SELECT 1 FROM public.grn_images WHERE storage_path = 'grn/r130/old-pending.jpg')
  AND NOT EXISTS (SELECT 1 FROM public.dispatch_images WHERE storage_path = 'dispatch/r130/old-pending.jpg')
  AND EXISTS (SELECT 1 FROM public.grn_images WHERE storage_path = 'grn/r130/fresh-pending.jpg')
  AND EXISTS (SELECT 1 FROM public.grn_images WHERE storage_path = 'grn/r130/old-confirmed.jpg')
  AND EXISTS (SELECT 1 FROM public.dispatch_images WHERE storage_path = 'dispatch/r130/fresh-pending.jpg'),
  'the old pending rows are gone the next day, the fresh pending and the confirmed rows stay: '||:'second_delete');
SELECT pg_temp.r130_assert(NOT has_function_privilege('authenticated', 'warehouse_maintenance.delete_expired_pending_images(timestamptz)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'warehouse_maintenance.expired_pending_images(text, timestamptz)', 'EXECUTE'), 'no API role runs the cleanup');

ROLLBACK;

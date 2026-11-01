-- A GRN save (update_grn) removes an unfinished photo upload only if it is the saver's own or older than 15 minutes.
--   * a staff member's recent pending upload survives an administrator's save
--   * the administrator's own pending row is removed
--   * a pending row older than 15 minutes (any uploader) is removed
--   * the confirmed photo listed in the save stays
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database. Every row rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.pp_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'pending photos: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.pp_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  login := public.operator_verify_otp(phone,challenge#>>'{data,otp_code}');
  PERFORM pg_temp.pp_assert(login#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id=p.auth_user_id
    WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;

INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888888931','Pending Photos Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status)
 VALUES (gen_random_uuid(),'919888888932','Pending Photos Staff','staff',true,'approved');
SELECT id AS staff_profile FROM public.user_profiles WHERE mobile='919888888932' \gset
SELECT pg_temp.pp_login('9888888931') AS admin_claims \gset
INSERT INTO public.customers(name,mobile) VALUES ('Pending Photos Customer','9888888941') RETURNING id AS customer_id \gset
INSERT INTO public.items(name,packaging) VALUES ('Pending Photos Potatoes','Bag') RETURNING id AS item_id \gset
SELECT warehouse_security.apply_document_numbering('grn', '{"scheme":"free"}', NULL) AS _ \gset

SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_grn(p_gr_no => 'PP1', p_date => now(), p_customer_id => :'customer_id'::uuid, p_customer_name => 'Pending Photos Customer',
  p_items => jsonb_build_array(jsonb_build_object('item_id', :'item_id', 'item_name', 'Pending Photos Potatoes',
    'packaging', 'Bag', 'qty', 10, 'weight', 50, 'rack', '1', 'package_mark', 'MK1'))) AS saved \gset
RESET ROLE;
SELECT pg_temp.pp_assert(:'saved'::jsonb->>'success' = 'true', 'GRN saved: '||:'saved');
SELECT id AS grn FROM public.goodsreceived WHERE gr_no = 'PP1' \gset
INSERT INTO public.grn_images(grn_id, image_type, storage_path, original_filename, file_size, mime_type, status, uploaded_by, created_at) VALUES
 (:'grn'::uuid, 'header', 'grn/pp/confirmed.jpg', 'c.jpg', 1000, 'image/jpeg', 'confirmed', :'admin_profile'::uuid, now() - interval '1 day'),
 (:'grn'::uuid, 'header', 'grn/pp/staff-fresh.jpg', 's.jpg', 1000, 'image/jpeg', 'pending', :'staff_profile'::uuid, now() - interval '2 minutes'),
 (:'grn'::uuid, 'header', 'grn/pp/staff-stale.jpg', 't.jpg', 1000, 'image/jpeg', 'pending', :'staff_profile'::uuid, now() - interval '16 minutes'),
 (:'grn'::uuid, 'header', 'grn/pp/admin-fresh.jpg', 'a.jpg', 1000, 'image/jpeg', 'pending', :'admin_profile'::uuid, now() - interval '1 minute');
SELECT id AS confirmed_photo FROM public.grn_images WHERE storage_path = 'grn/pp/confirmed.jpg' \gset

SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id => :'grn'::uuid, p_note => 'admin save',
  p_items => (SELECT jsonb_agg(jsonb_build_object('id', t.id, 'item_id', t.item_id, 'item_name', t.item_name, 'packaging', t.packaging,
    'qty', t.qty, 'weight', t.weight, 'rack', t.rack, 'package_mark', t.package_mark)) FROM public.goodsreceived_trl t WHERE t.gr_id = :'grn'::uuid),
  p_images => jsonb_build_array(jsonb_build_object('id', :'confirmed_photo', 'storage_path', 'grn/pp/confirmed.jpg', 'image_type', 'header'))) AS edit \gset
RESET ROLE;
SELECT pg_temp.pp_assert(:'edit'::jsonb->>'success' = 'true', 'the save works: '||:'edit');
SELECT pg_temp.pp_assert(EXISTS (SELECT 1 FROM public.grn_images WHERE storage_path = 'grn/pp/staff-fresh.jpg'),
  'staff recent pending upload survives the admin save');
SELECT pg_temp.pp_assert(NOT EXISTS (SELECT 1 FROM public.grn_images WHERE storage_path = 'grn/pp/admin-fresh.jpg'),
  'the saver''s own pending row is removed');
SELECT pg_temp.pp_assert(NOT EXISTS (SELECT 1 FROM public.grn_images WHERE storage_path = 'grn/pp/staff-stale.jpg'),
  'a pending row older than 15 minutes is removed');
SELECT pg_temp.pp_assert(EXISTS (SELECT 1 FROM public.grn_images WHERE storage_path = 'grn/pp/confirmed.jpg'),
  'the listed confirmed photo stays');
ROLLBACK;

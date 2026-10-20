-- Fictional regression for the manager Storage delete rule (BR-05b). Runs only in
-- migrations.sh's disposable database, after scripts/configure-storage.sql.
-- Administrators and supervisors may delete an image object only when no
-- grn_images / dispatch_images row and no document header column names it.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.sd_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'storage delete rules: %',label; END IF; END $$;
-- Deletes the named object as the current role and returns how many rows went.
CREATE FUNCTION pg_temp.sd_delete(p_bucket text, p_name text) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE affected integer;
BEGIN DELETE FROM storage.objects WHERE bucket_id=p_bucket AND name=p_name; GET DIAGNOSTICS affected=ROW_COUNT; RETURN affected; END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888888881','Storage Rule Administrator') AS admin_user \gset
SELECT public.operator_prepare_otp('9888888881') AS challenge \gset
SELECT public.operator_finish_otp((:'challenge'::jsonb#>>'{data,request_id}')::uuid,true,'mock-provider-only');
SELECT public.operator_verify_otp('9888888881',:'challenge'::jsonb#>>'{data,otp_code}') AS login \gset
SELECT pg_temp.sd_assert(:'login'::jsonb#>>'{data,action}'='login','administrator login');
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
-- A supervisor and a staff member.
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888882','Storage Rule Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919888888883','Storage Rule Staff','staff',true,'approved');
SELECT public.operator_prepare_otp('9888888882') AS sup_challenge \gset
SELECT public.operator_finish_otp((:'sup_challenge'::jsonb#>>'{data,request_id}')::uuid,true,'mock-provider-only');
SELECT public.operator_verify_otp('9888888882',:'sup_challenge'::jsonb#>>'{data,otp_code}') AS sup_login \gset
SELECT pg_temp.sd_assert(:'sup_login'::jsonb#>>'{data,action}'='login','supervisor login');
SELECT public.operator_prepare_otp('9888888883') AS staff_challenge \gset
SELECT public.operator_finish_otp((:'staff_challenge'::jsonb#>>'{data,request_id}')::uuid,true,'mock-provider-only');
SELECT public.operator_verify_otp('9888888883',:'staff_challenge'::jsonb#>>'{data,otp_code}') AS staff_login \gset
SELECT pg_temp.sd_assert(:'staff_login'::jsonb#>>'{data,action}'='login','staff login');
SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) AS sup_claims
FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
WHERE p.mobile='919888888882' ORDER BY r.created_at DESC LIMIT 1 \gset
SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) AS staff_claims
FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
WHERE p.mobile='919888888883' ORDER BY r.created_at DESC LIMIT 1 \gset
SELECT jsonb_build_object('role','authenticated','sub',:'admin_user',
 'session_id',(SELECT id FROM warehouse_security.refresh_sessions WHERE user_id=:'admin_user'::uuid LIMIT 1)) AS admin_claims \gset

-- Documents and their image rows, written directly (this test is about Storage).
INSERT INTO public.customers(name) VALUES ('Storage Rule Customer');
INSERT INTO public.goodsreceived(gr_no,customer_id,customer_name,date)
 SELECT 'SDGRN1',id,name,now() FROM public.customers WHERE name='Storage Rule Customer';
INSERT INTO public.goodsreceived(gr_no,customer_id,customer_name,date,gr_image_url)
 SELECT 'SDGRN2',id,name,now(),NULL FROM public.customers WHERE name='Storage Rule Customer';
INSERT INTO public.dispatch(disp_no,customer_id,customer_name,disp_date)
 SELECT 'SDDSP1',id,name,now() FROM public.customers WHERE name='Storage Rule Customer';
SELECT id AS grn_1 FROM public.goodsreceived WHERE gr_no='SDGRN1' \gset
SELECT id AS grn_2 FROM public.goodsreceived WHERE gr_no='SDGRN2' \gset
SELECT id AS disp_1 FROM public.dispatch WHERE disp_no='SDDSP1' \gset
-- Header column reference: SDGRN2 names a legacy file only in gr_image_url.
SELECT 'headers/' || :'grn_2' || '/legacy.webp' AS legacy_path \gset
UPDATE public.goodsreceived SET gr_image_url=:'legacy_path' WHERE id=:'grn_2'::uuid;
SELECT 'headers/' || :'grn_1' || '/photo.webp' AS grn_path \gset
SELECT :'disp_1' || '/photo.webp' AS disp_path \gset
INSERT INTO public.grn_images(grn_id,image_type,storage_path,original_filename,file_size,mime_type,status,uploaded_by)
 VALUES (:'grn_1'::uuid,'header',:'grn_path','photo.webp',32,'image/webp','confirmed',:'admin_profile'::uuid);
INSERT INTO public.dispatch_images(dispatch_id,storage_path,original_filename,file_size,mime_type,status,uploaded_by)
 VALUES (:'disp_1'::uuid,:'disp_path','photo.webp',32,'image/webp','confirmed',:'admin_profile'::uuid);
SELECT id AS grn_image FROM public.grn_images WHERE storage_path=:'grn_path' \gset
SELECT id AS disp_image FROM public.dispatch_images WHERE storage_path=:'disp_path' \gset
INSERT INTO storage.objects(bucket_id,name) VALUES
 ('grn-images',:'grn_path'),('dispatch-images',:'disp_path'),('grn-images',:'legacy_path'),
 ('grn-images','headers/'||:'grn_1'||'/loose.webp'),('dispatch-images','customer-a/logo.webp');

-- Administrator: referenced objects stay, unreferenced ones go.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.sd_assert(warehouse_security.active_role()='admin','actual administrator role');
SELECT pg_temp.sd_assert(pg_temp.sd_delete('grn-images',:'grn_path')=0,'admin cannot delete a GRN object that a grn_images row names');
SELECT pg_temp.sd_assert(pg_temp.sd_delete('dispatch-images',:'disp_path')=0,'admin cannot delete a dispatch object that a dispatch_images row names');
SELECT pg_temp.sd_assert(pg_temp.sd_delete('grn-images',:'legacy_path')=0,'admin cannot delete a file that gr_image_url names');
SELECT pg_temp.sd_assert((SELECT count(*)=5 FROM storage.objects),'admin still reads all five objects');
SELECT pg_temp.sd_assert(pg_temp.sd_delete('grn-images','headers/'||:'grn_1'||'/loose.webp')=1,'admin deletes an unreferenced GRN object');
SELECT pg_temp.sd_assert(pg_temp.sd_delete('dispatch-images','customer-a/logo.webp')=1,'admin deletes an unreferenced dispatch-images object');
-- Metadata first through the RPC, then the object.
SELECT pg_temp.sd_assert(public.delete_grn_image(:'grn_image'::uuid)->>'success'='true','admin deletes the GRN image row');
SELECT pg_temp.sd_assert(public.delete_dispatch_image(:'disp_image'::uuid)->>'success'='true','admin deletes the dispatch image row');
SELECT pg_temp.sd_assert(pg_temp.sd_delete('grn-images',:'grn_path')=1,'admin deletes the GRN object after its row is gone');
SELECT pg_temp.sd_assert(pg_temp.sd_delete('dispatch-images',:'disp_path')=1,'admin deletes the dispatch object after its row is gone');
RESET ROLE;
-- Supervisor: same rule, also for the file of a deleted document.
INSERT INTO public.grn_images(grn_id,image_type,storage_path,original_filename,file_size,mime_type,status,uploaded_by)
 VALUES (:'grn_1'::uuid,'header',:'grn_path','photo.webp',32,'image/webp','confirmed',:'admin_profile'::uuid);
INSERT INTO storage.objects(bucket_id,name) VALUES ('grn-images',:'grn_path');
SELECT set_config('request.jwt.claims',:'sup_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.sd_assert(warehouse_security.active_role()='supervisor','actual supervisor role');
SELECT pg_temp.sd_assert(pg_temp.sd_delete('grn-images',:'grn_path')=0,'supervisor cannot delete a referenced object');
RESET ROLE;
DELETE FROM public.grn_images WHERE storage_path=:'grn_path';
UPDATE public.goodsreceived SET deleted_at=now() WHERE id=:'grn_1'::uuid;
SET LOCAL ROLE authenticated;
SELECT pg_temp.sd_assert(pg_temp.sd_delete('grn-images',:'grn_path')=1,'supervisor deletes the unreferenced file of a deleted document');
RESET ROLE;
-- Staff rule unchanged: no deleting a referenced object; an unreferenced file in a live document's folder goes.
INSERT INTO public.grn_images(grn_id,image_type,storage_path,original_filename,file_size,mime_type,status,uploaded_by)
 VALUES (:'grn_2'::uuid,'header','headers/'||:'grn_2'||'/ref.webp','ref.webp',32,'image/webp','confirmed',:'admin_profile'::uuid);
INSERT INTO storage.objects(bucket_id,name) VALUES ('dispatch-images','customer-a/logo.webp'),('grn-images','headers/'||:'grn_2'||'/ref.webp'),('grn-images','headers/'||:'grn_2'||'/free.webp');
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.sd_assert(warehouse_security.active_role()='staff','actual staff role');
SELECT pg_temp.sd_assert(pg_temp.sd_delete('grn-images','headers/'||:'grn_2'||'/ref.webp')=0,'staff cannot delete a referenced object');
SELECT pg_temp.sd_assert(pg_temp.sd_delete('grn-images','headers/'||:'grn_2'||'/free.webp')=1,'staff deletes an unreferenced file of a live document');
SELECT pg_temp.sd_assert(pg_temp.sd_delete('dispatch-images','customer-a/logo.webp')=0,'staff cannot delete an unreferenced file outside a live dispatch folder');
RESET ROLE;
ROLLBACK;
\echo 'Manager Storage delete rules passed.'

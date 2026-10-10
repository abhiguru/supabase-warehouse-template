-- Migration 43: an image row is confirmed only for a file in its own
-- document's folder. Every entry point that attaches a path is tried with
-- another document's path, a path with no file and a line of another receipt;
-- the register/upload/confirm flow and the update_grn answer the app relies on
-- are asserted unchanged. Fictional data; runs only in migrations.sh's
-- disposable, network-disabled database (storage.objects rows stand in for
-- uploaded files, as in staff_grn_access.sql).
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.img_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'image path rules: %',label; END IF; END $$;
-- True when the statement is refused with a text matching the pattern, whether
-- it raises or answers {"success": false, ...}.
CREATE FUNCTION pg_temp.img_refused(statement text, pattern text) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE result jsonb;
BEGIN
  BEGIN EXECUTE statement INTO result; EXCEPTION WHEN OTHERS THEN RETURN SQLERRM LIKE pattern; END;
  RETURN result->>'success'='false' AND result::text LIKE pattern;
END $$;
CREATE FUNCTION pg_temp.img_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.img_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.img_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888888821','Image Rule Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888822','Image Rule Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888823','Image Rule Reader A','customer',true,'approved'),
 (gen_random_uuid(),'919888888824','Image Rule Reader B','customer',true,'approved');
SELECT pg_temp.img_login('9888888821') AS admin_claims \gset
SELECT pg_temp.img_login('9888888822') AS staff_claims \gset
SELECT pg_temp.img_login('9888888823') AS reader_a_claims \gset
SELECT pg_temp.img_login('9888888824') AS reader_b_claims \gset

-- Fixture, as the administrator: customers A and B, one receipt and one
-- dispatch each.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.img_assert(public.create_customer('Image Rule Customer A','9888888825')->>'success'='true','customer A');
SELECT pg_temp.img_assert(public.create_customer('Image Rule Customer B','9888888826')->>'success'='true','customer B');
SELECT pg_temp.img_assert(public.create_item('Image Rule Onions','Bag')->>'success'='true','catalog item');
SELECT id AS customer_a FROM public.customers WHERE name='Image Rule Customer A' \gset
SELECT id AS customer_b FROM public.customers WHERE name='Image Rule Customer B' \gset
SELECT id AS item_id FROM public.items WHERE name='Image Rule Onions' \gset
SELECT pg_temp.img_assert(public.save_grn(p_gr_no=>'IMGA',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_a'::uuid,
 p_customer_name=>'Image Rule Customer A',p_idempotency_key=>'image-rule-a',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Image Rule Onions',
 'packaging','Bag','qty',20,'weight',10,'rack','R1')))->>'success'='true','receipt IMGA');
SELECT pg_temp.img_assert(public.save_grn(p_gr_no=>'IMGB',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_b'::uuid,
 p_customer_name=>'Image Rule Customer B',p_idempotency_key=>'image-rule-b',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Image Rule Onions',
 'packaging','Bag','qty',20,'weight',10,'rack','R2')))->>'success'='true','receipt IMGB');
SELECT id AS grn_a FROM public.goodsreceived WHERE gr_no='IMGA' \gset
SELECT id AS grn_b FROM public.goodsreceived WHERE gr_no='IMGB' \gset
SELECT id AS lot_a FROM public.goodsreceived_trl WHERE gr_id=:'grn_a'::uuid \gset
SELECT id AS lot_b FROM public.goodsreceived_trl WHERE gr_id=:'grn_b'::uuid \gset
SELECT pg_temp.img_assert(public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','IMGDA','disp_date','2026-05-02T12:00:00Z',
 'customer_id',:'customer_a','customer_name','Image Rule Customer A','supervisor_id',:'admin_profile','supervisor_name','Image Rule Administrator'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a','disp_qty',1)],0,'image-rule-dispatch-a')->>'success'='true','dispatch IMGDA');
SELECT pg_temp.img_assert(public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','IMGDB','disp_date','2026-05-02T12:00:00Z',
 'customer_id',:'customer_b','customer_name','Image Rule Customer B','supervisor_id',:'admin_profile','supervisor_name','Image Rule Administrator'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_b','disp_qty',1)],0,'image-rule-dispatch-b')->>'success'='true','dispatch IMGDB');
SELECT id AS dispatch_a FROM public.dispatch WHERE disp_no='IMGDA' \gset
SELECT id AS dispatch_b FROM public.dispatch WHERE disp_no='IMGDB' \gset
RESET ROLE;
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active)
 SELECT id,:'customer_a'::uuid,true FROM public.user_profiles WHERE mobile='919888888823';
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active)
 SELECT id,:'customer_b'::uuid,true FROM public.user_profiles WHERE mobile='919888888824';
-- update_grn replaces the line list, so every edit below sends B's one line.
SELECT jsonb_build_array(jsonb_build_object('id',:'lot_b','item_id',:'item_id','item_name','Image Rule Onions',
 'packaging','Bag','qty',20,'weight',10,'rack','R2')) AS lines_b \gset

-- 1. The app's flow, as staff: register, upload to the issued path, confirm.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.register_grn_image_upload(:'grn_a'::uuid,'header','a-header.webp',32,'image/webp') AS reg_a \gset
SELECT pg_temp.img_assert(:'reg_a'::jsonb->>'success'='true','staff registers a header photo for receipt A');
SELECT :'reg_a'::jsonb->>'storage_path' AS path_a \gset
SELECT pg_temp.img_assert(starts_with(:'path_a','headers/'||:'grn_a'||'/'),'the issued path is in receipt A''s folder');
-- Confirming before the file is there is refused and leaves the row pending.
SELECT pg_temp.img_assert(pg_temp.img_refused(format('SELECT public.confirm_grn_image_upload(%L::uuid,%L::uuid)',
 :'reg_a'::jsonb->>'image_id',:'reg_a'::jsonb->>'upload_token'),'%Image file is not in storage%'),'confirm without a file is refused');
SELECT pg_temp.img_assert((SELECT status='pending' FROM public.grn_images WHERE id=(:'reg_a'::jsonb->>'image_id')::uuid),'unconfirmed row stays pending');
INSERT INTO storage.objects(bucket_id,name) VALUES ('grn-images',:'path_a');
SELECT pg_temp.img_assert(public.confirm_grn_image_upload((:'reg_a'::jsonb->>'image_id')::uuid,
 (:'reg_a'::jsonb->>'upload_token')::uuid)->>'success'='true','confirm after the upload succeeds');
SELECT pg_temp.img_assert((SELECT status='confirmed' AND upload_token IS NULL FROM public.grn_images WHERE id=(:'reg_a'::jsonb->>'image_id')::uuid),'row confirmed');
-- An item photo is registered for a line of the same receipt only.
SELECT pg_temp.img_assert(pg_temp.img_refused(format('SELECT public.register_grn_image_upload(%L::uuid,''item'',''line.webp'',32,''image/webp'',%L::uuid)',
 :'grn_b',:'lot_a'),'%Image line does not belong to this GRN%'),'register refuses a line of another receipt');
SELECT public.register_grn_image_upload(:'grn_b'::uuid,'item','b-line.webp',32,'image/webp',:'lot_b'::uuid) AS reg_b_item \gset
SELECT pg_temp.img_assert(starts_with(:'reg_b_item'::jsonb->>'storage_path','items/'||:'grn_b'||'/'||:'lot_b'||'/'),'item path is in receipt B''s folder');
INSERT INTO storage.objects(bucket_id,name) VALUES ('grn-images',:'reg_b_item'::jsonb->>'storage_path');
SELECT pg_temp.img_assert(public.confirm_grn_image_upload((:'reg_b_item'::jsonb->>'image_id')::uuid,
 (:'reg_b_item'::jsonb->>'upload_token')::uuid)->>'success'='true','item photo confirmed');

-- 2. Staff cannot attach receipt A's file to receipt B through any entry point.
SELECT pg_temp.img_assert(pg_temp.img_refused(format(
 'SELECT public.upload_grn_image(%L::uuid,''header'',%L,''x.webp'',32,''image/webp'')',:'grn_b',:'path_a'),
 '%Image path does not belong to this GRN%'),'upload_grn_image refuses another receipt''s path');
SELECT pg_temp.img_assert(pg_temp.img_refused(format(
 'SELECT public.save_grn(p_gr_no=>''IMGX'',p_date=>now(),p_customer_id=>%L::uuid,p_customer_name=>''Image Rule Customer B'',p_items=>%L::jsonb,p_images=>%L::jsonb)',
 :'customer_b',jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Image Rule Onions','packaging','Bag','qty',1,'weight',1)),
 jsonb_build_array(jsonb_build_object('image_type','header','storage_path',:'path_a'))),
 '%Image path does not belong to this GRN%'),'save_grn refuses another receipt''s path');
SELECT pg_temp.img_assert(pg_temp.img_refused(format(
 'SELECT public.update_grn(p_grn_id=>%L::uuid,p_items=>%L::jsonb,p_images=>%L::jsonb)',:'grn_b',:'lines_b',
 jsonb_build_array(jsonb_build_object('image_type','header','storage_path',:'path_a'))),
 '%Image path does not belong to this GRN%'),'update_grn refuses another receipt''s path');
-- Naming the other receipt's image by its id does not move or re-link it.
SELECT pg_temp.img_assert(pg_temp.img_refused(format(
 'SELECT public.update_grn(p_grn_id=>%L::uuid,p_items=>%L::jsonb,p_images=>%L::jsonb)',:'grn_b',:'lines_b',
 jsonb_build_array(jsonb_build_object('id',:'reg_a'::jsonb->>'image_id','image_type','header','storage_path',:'path_a'))),
 '%Image path does not belong to this GRN%'),'update_grn refuses another receipt''s image id');
-- A path in the right folder with no file behind it.
SELECT pg_temp.img_assert(pg_temp.img_refused(format(
 'SELECT public.upload_grn_image(%L::uuid,''header'',%L,''x.webp'',32,''image/webp'')',:'grn_b','headers/'||:'grn_b'||'/never-uploaded.webp'),
 '%Image file is not in storage%'),'upload_grn_image refuses a path with no file');
SELECT pg_temp.img_assert(pg_temp.img_refused(format(
 'SELECT public.update_grn(p_grn_id=>%L::uuid,p_items=>%L::jsonb,p_images=>%L::jsonb)',:'grn_b',:'lines_b',
 jsonb_build_array(jsonb_build_object('image_type','header','storage_path','headers/'||:'grn_b'||'/never-uploaded.webp'))),
 '%Image file is not in storage%'),'update_grn refuses a path with no file');
-- Folder tricks.
SELECT pg_temp.img_assert(pg_temp.img_refused(format(
 'SELECT public.upload_grn_image(%L::uuid,''header'',%L,''x.webp'',32,''image/webp'')',:'grn_b','headers/'||:'grn_b'||'/../'||:'grn_a'||'/x.webp'),
 '%Image path does not belong to this GRN%'),'a parent-folder segment is refused');
SELECT pg_temp.img_assert(pg_temp.img_refused(format(
 'SELECT public.upload_grn_image(%L::uuid,''item'',%L,''x.webp'',32,''image/webp'',%L::uuid)',:'grn_b',:'reg_b_item'::jsonb->>'storage_path',:'lot_a'),
 '%Image line does not belong to this GRN%'),'upload_grn_image refuses a line of another receipt');
SELECT pg_temp.img_assert(pg_temp.img_refused(format(
 'SELECT public.update_grn(p_grn_id=>%L::uuid,p_items=>%L::jsonb,p_images=>%L::jsonb)',:'grn_b',:'lines_b',
 jsonb_build_array(jsonb_build_object('id',:'reg_b_item'::jsonb->>'image_id','image_type','item','grn_item_id',:'lot_a',
  'storage_path',:'reg_b_item'::jsonb->>'storage_path'))),
 '%Image line does not belong to this GRN%'),'update_grn refuses to link an image to a line of another receipt');
RESET ROLE;
SELECT pg_temp.img_assert((SELECT count(*)=1 AND bool_and(grn_id=:'grn_a'::uuid AND grn_item_id IS NULL) FROM public.grn_images WHERE storage_path=:'path_a'),
 'receipt A''s image is still one row on receipt A');
SELECT pg_temp.img_assert((SELECT count(*)=1 FROM public.grn_images WHERE grn_id=:'grn_b'::uuid),'receipt B has only its own item photo');
SELECT pg_temp.img_assert(NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no='IMGX'),'the refused save_grn created no receipt');

-- 3. A correct path works. The administrator may put a file in the bucket
-- without a registered row; staff may not (staff_grn_access.sql).
INSERT INTO storage.objects(bucket_id,name) VALUES
 ('grn-images','headers/'||:'grn_b'||'/direct.webp'),('grn-images','headers/'||:'grn_b'||'/by-edit.webp');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.upload_grn_image(:'grn_b'::uuid,'header','headers/'||:'grn_b'||'/direct.webp','direct.webp',32,'image/webp') AS direct \gset
SELECT pg_temp.img_assert(:'direct'::jsonb->>'success'='true','upload_grn_image attaches a file in the receipt''s own folder');
SELECT pg_temp.img_assert((SELECT status='confirmed' FROM public.grn_images WHERE storage_path='headers/'||:'grn_b'||'/direct.webp'),'the checked row is confirmed');
SELECT pg_temp.img_assert(pg_temp.img_refused(format(
 'SELECT public.upload_grn_image(%L::uuid,''header'',%L,''direct.webp'',32,''image/webp'')',:'grn_b','headers/'||:'grn_b'||'/direct.webp'),
 '%Image path is attached to a different image record%'),'a path is attached once');
-- update_grn as the app calls it: the images already on the receipt by id, plus
-- (not sent by the app, but allowed) a new file in the receipt's folder; a new
-- line in the same edit. The answer keeps item_mapping and grn.images.
SELECT id AS direct_image FROM public.grn_images WHERE storage_path='headers/'||:'grn_b'||'/direct.webp' \gset
SELECT public.update_grn(p_grn_id=>:'grn_b'::uuid,
 p_items=>:'lines_b'::jsonb || jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Image Rule Onions','packaging','Bag','qty',5,'weight',10,'rack','R9')),
 p_images=>jsonb_build_array(
  jsonb_build_object('id',:'direct_image','image_type','header','storage_path','headers/'||:'grn_b'||'/direct.webp'),
  -- kept without its id: matched by its path, not inserted a second time
  jsonb_build_object('image_type','item','grn_item_id',:'lot_b','storage_path',:'reg_b_item'::jsonb->>'storage_path'),
  jsonb_build_object('image_type','header','storage_path','headers/'||:'grn_b'||'/by-edit.webp','original_filename','by-edit.webp','file_size',32,'mime_type','image/webp'))) AS edited \gset
SELECT pg_temp.img_assert(:'edited'::jsonb->>'success'='true','update_grn keeps the receipt''s images and attaches a file in its folder');
SELECT pg_temp.img_assert(:'edited'::jsonb#>>'{stats,images_updated}'='2' AND :'edited'::jsonb#>>'{stats,images_added}'='1'
 AND :'edited'::jsonb#>>'{stats,images_deleted}'='0','two images kept, one added, none removed');
SELECT pg_temp.img_assert(jsonb_array_length(:'edited'::jsonb->'item_mapping')=1 AND :'edited'::jsonb#>>'{item_mapping,0,index}'='1'
 AND EXISTS (SELECT 1 FROM public.goodsreceived_trl WHERE gr_id=:'grn_b'::uuid AND id=(:'edited'::jsonb#>>'{item_mapping,0,grn_trl_item_id}')::uuid),
 'item_mapping names the new line by its position');
SELECT pg_temp.img_assert((SELECT count(*)=3 AND bool_and(e->>'id' IS NOT NULL) FROM jsonb_array_elements(:'edited'::jsonb#>'{grn,images}') e)
 AND :'edited'::jsonb#>'{grn,images}' @> jsonb_build_array(jsonb_build_object('id',:'direct_image'),jsonb_build_object('id',:'reg_b_item'::jsonb->>'image_id')),
 'grn.images lists every image of the receipt by id');
SELECT pg_temp.img_assert((SELECT count(*)=3 AND bool_and(status='confirmed') FROM public.grn_images WHERE grn_id=:'grn_b'::uuid),'receipt B has three confirmed images');

-- 4. Dispatch photos follow the same rule.
RESET ROLE;
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.register_dispatch_image_upload(:'dispatch_a'::uuid,'a-truck.webp',32,'image/webp') AS reg_da \gset
SELECT :'reg_da'::jsonb->>'storage_path' AS path_da \gset
SELECT pg_temp.img_assert(:'path_da' ~ ('^'||:'dispatch_a'||'/[0-9a-f-]{36}_a-truck\.webp$'),'the issued dispatch path is in the dispatch''s folder with a random part');
SELECT pg_temp.img_assert(pg_temp.img_refused(format('SELECT public.confirm_dispatch_image_upload(%L::uuid,%L::uuid)',
 :'reg_da'::jsonb->>'image_id',:'reg_da'::jsonb->>'upload_token'),'%Image file is not in storage%'),'dispatch confirm without a file is refused');
INSERT INTO storage.objects(bucket_id,name) VALUES ('dispatch-images',:'path_da');
SELECT pg_temp.img_assert(public.confirm_dispatch_image_upload((:'reg_da'::jsonb->>'image_id')::uuid,
 (:'reg_da'::jsonb->>'upload_token')::uuid)->>'success'='true','dispatch confirm after the upload succeeds');
RESET ROLE;
INSERT INTO storage.objects(bucket_id,name) VALUES ('dispatch-images',:'dispatch_b'||'/direct.webp');
-- upload_dispatch_image is not granted to the app role; it is exercised with
-- the administrator's and the staff member's session claims as the owner.
SELECT pg_temp.img_assert(NOT has_function_privilege('authenticated','public.upload_dispatch_image(uuid,text,text,integer,character varying,uuid)','EXECUTE'),
 'upload_dispatch_image stays outside the granted API');
SELECT pg_temp.img_assert(pg_temp.img_refused(format(
 'SELECT public.upload_dispatch_image(%L::uuid,%L,''x.webp'',32,''image/webp'')',:'dispatch_b',:'dispatch_b'||'/direct.webp'),
 '%Staff access required%'),'upload_dispatch_image is guarded');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SELECT pg_temp.img_assert(pg_temp.img_refused(format(
 'SELECT public.upload_dispatch_image(%L::uuid,%L,''x.webp'',32,''image/webp'')',:'dispatch_b',:'path_da'),
 '%Image path does not belong to this dispatch%'),'upload_dispatch_image refuses another dispatch''s path');
SELECT pg_temp.img_assert(pg_temp.img_refused(format(
 'SELECT public.upload_dispatch_image(%L::uuid,%L,''x.webp'',32,''image/webp'')',:'dispatch_b',:'dispatch_b'||'/never-uploaded.webp'),
 '%Image file is not in storage%'),'upload_dispatch_image refuses a path with no file');
SELECT pg_temp.img_assert(public.upload_dispatch_image(:'dispatch_b'::uuid,:'dispatch_b'||'/direct.webp','direct.webp',32,'image/webp')->>'success'='true',
 'upload_dispatch_image attaches a file in the dispatch''s own folder');
SELECT pg_temp.img_assert(pg_temp.img_refused(format(
 'SELECT public.upload_dispatch_image(%L::uuid,%L,''x.webp'',32,''image/webp'')',:'dispatch_b',:'dispatch_b'||'/direct.webp'),
 '%Image path is attached to a different image record%'),'a dispatch path is attached once');
SELECT pg_temp.img_assert((SELECT count(*)=1 AND bool_and(status='confirmed') FROM public.dispatch_images WHERE dispatch_id=:'dispatch_b'::uuid),'dispatch B has one confirmed image');

-- 5. What each customer can read: confirmed images of their own documents,
-- metadata and file alike, and nothing of a pending upload.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.register_grn_image_upload(:'grn_b'::uuid,'header','b-pending.webp',32,'image/webp') AS reg_b_pending \gset
INSERT INTO storage.objects(bucket_id,name) VALUES ('grn-images',:'reg_b_pending'::jsonb->>'storage_path');
RESET ROLE;
SELECT set_config('request.jwt.claims',:'reader_a_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.img_assert((SELECT count(*)=1 AND bool_and(name=:'path_a') FROM storage.objects WHERE bucket_id='grn-images'),'customer A reads only receipt A''s file');
SELECT pg_temp.img_assert((SELECT count(*)=1 AND bool_and(name=:'path_da') FROM storage.objects WHERE bucket_id='dispatch-images'),'customer A reads only dispatch A''s file');
SELECT pg_temp.img_assert((SELECT count(*)=1 AND bool_and(grn_id=:'grn_a'::uuid) FROM public.grn_images),'customer A reads only receipt A''s image row');
SELECT pg_temp.img_assert((SELECT count(*)=1 AND bool_and(dispatch_id=:'dispatch_a'::uuid) FROM public.dispatch_images),'customer A reads only dispatch A''s image row');
RESET ROLE;
SELECT set_config('request.jwt.claims',:'reader_b_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.img_assert((SELECT count(*)=3 AND bool_and(starts_with(name,'headers/'||:'grn_b'||'/') OR starts_with(name,'items/'||:'grn_b'||'/'))
 FROM storage.objects WHERE bucket_id='grn-images'),'customer B reads the three confirmed files of receipt B, not A''s and not the pending one');
SELECT pg_temp.img_assert((SELECT count(*)=1 AND bool_and(name=:'dispatch_b'||'/direct.webp') FROM storage.objects WHERE bucket_id='dispatch-images'),'customer B reads only dispatch B''s file');
SELECT pg_temp.img_assert((SELECT count(*)=3 AND bool_and(status='confirmed' AND upload_token IS NULL) FROM public.grn_images),
 'customer B reads the confirmed image rows only: no pending row, no upload token');
SELECT pg_temp.img_assert(pg_temp.img_refused(format('SELECT public.confirm_grn_image_upload(%L::uuid,%L::uuid)',
 :'reg_b_pending'::jsonb->>'image_id',:'reg_b_pending'::jsonb->>'upload_token'),'%Staff access required%'),'a customer cannot confirm an upload');
RESET ROLE;

-- 6. Rows that were not checked, and rows from before the rule.
SELECT pg_temp.img_assert((SELECT count(*)=0 FROM warehouse_maintenance.misplaced_image_paths()),'nothing the RPCs wrote is misplaced');
INSERT INTO public.grn_images(grn_id,image_type,storage_path,original_filename,file_size,mime_type)
 VALUES (:'grn_b'::uuid,'header','headers/'||:'grn_a'||'/legacy.webp','legacy.webp',32,'image/webp') RETURNING status AS unchecked_status \gset
SELECT pg_temp.img_assert(:'unchecked_status'='pending','a row inserted without a status is pending');
INSERT INTO public.dispatch_images(dispatch_id,storage_path,original_filename,file_size,mime_type,status)
 VALUES (:'dispatch_b'::uuid,'legacy/elsewhere.webp','legacy.webp',32,'image/webp','confirmed');
SELECT pg_temp.img_assert((SELECT count(*)=2 AND count(*) FILTER (WHERE kind='grn' AND document_id=:'grn_b'::uuid AND reason LIKE 'outside%')=1
 AND count(*) FILTER (WHERE kind='dispatch' AND document_id=:'dispatch_b'::uuid AND reason LIKE 'outside%')=1
 FROM warehouse_maintenance.misplaced_image_paths()),'rows outside their document''s folder are listed for the operator');
SELECT pg_temp.img_assert((SELECT count(*)=2 FROM pg_indexes WHERE schemaname='public'
 AND indexname IN ('grn_images_storage_path_key','dispatch_images_storage_path_key') AND indexdef LIKE 'CREATE UNIQUE INDEX%'),
 'a storage path is unique per image table');
SELECT pg_temp.img_assert(NOT has_function_privilege('authenticated','warehouse_maintenance.misplaced_image_paths()','EXECUTE')
 AND NOT has_function_privilege('authenticated','warehouse_security.image_path_refusal(text,uuid,text,text,uuid)','EXECUTE')
 AND NOT has_function_privilege('authenticated','warehouse_security.require_image_path(text,uuid,text,text)','EXECUTE'),
 'the helpers are not callable by the app role');
ROLLBACK;
SELECT 'image path rules: foreign path, missing file and foreign line refused at every entry point; own-folder path, customer read boundary and legacy listing passed' AS result;

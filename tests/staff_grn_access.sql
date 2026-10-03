-- Policy regression ONLY in migrations.sh's fresh network-disabled database.
-- Fictional profiles are seeded locally; every session uses random ordinary
-- operator OTP prepare/mock-provider finish/verify. All fixture rows roll back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.grn_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'staff GRN policy: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.grn_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM pg_temp.grn_assert(challenge->>'success'='true','ordinary challenge');
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  login := public.operator_verify_otp(phone,challenge#>>'{data,otp_code}');
  PERFORM pg_temp.grn_assert(login#>>'{data,action}'='login','ordinary login');
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id=p.auth_user_id
    WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
CREATE FUNCTION pg_temp.grn_denied(statement text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE result jsonb;
BEGIN
  BEGIN
    EXECUTE statement INTO result;
    PERFORM pg_temp.grn_assert(result->>'success'='false' AND
      (result::text LIKE '%42501%' OR result::text LIKE '%Staff access required%' OR
       result::text LIKE '%Administrator required%' OR result::text LIKE '%Customer access denied%' OR
       result::text LIKE '%Active account required%'), 'privileged RPC must return authorization denial');
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888888861','GRN Policy Administrator');
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888862','GRN Policy Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888863','GRN Policy Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919888888864','GRN Policy Customer','customer',true,'approved');
SELECT pg_temp.grn_login('9888888861') AS admin_claims \gset
SELECT pg_temp.grn_login('9888888862') AS staff_claims \gset
SELECT pg_temp.grn_login('9888888863') AS supervisor_claims \gset
SELECT pg_temp.grn_login('9888888864') AS customer_claims \gset
INSERT INTO public.customers(name,mobile) VALUES ('GRN Policy A','9888888851') RETURNING id AS customer_a \gset
INSERT INTO public.customers(name,mobile) VALUES ('GRN Policy B','9888888852') RETURNING id AS customer_b \gset
INSERT INTO public.items(name,packaging) VALUES ('GRN Policy Potatoes','Bag') RETURNING id AS item_id \gset
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active)
 SELECT id,:'customer_a'::uuid,true FROM public.user_profiles WHERE mobile='919888888864';
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_grn(p_gr_no=>'STAFFA',p_date=>now(),p_customer_id=>:'customer_a'::uuid,
 p_customer_name=>'GRN Policy A',p_items=>jsonb_build_array(jsonb_build_object(
 'item_id',:'item_id','item_name','GRN Policy Potatoes','packaging','Bag','qty',10,'weight',5)),
 p_idempotency_key=>'staff-policy-admin-receipt') AS admin_receipt \gset
SELECT pg_temp.grn_assert(:'admin_receipt'::jsonb->>'success'='true','admin receipt');
RESET ROLE;
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.grn_assert(warehouse_security.active_role()='staff','actual active staff role');
SELECT pg_temp.grn_assert((SELECT count(*)=2 FROM public.customers WHERE name LIKE 'GRN Policy %'),'customer lookup across warehouse');
SELECT pg_temp.grn_assert(public.search_customers('GRN Policy')->>'success'='true','customer RPC lookup');
SELECT pg_temp.grn_assert(public.get_supervisors()->>'success'='true','supervisor lookup');
SELECT pg_temp.grn_assert(public.get_next_grn_number() IS NOT NULL,'number suggestion');
SELECT public.save_grn(p_gr_no=>'STAFFB',p_date=>now(),p_customer_id=>:'customer_b'::uuid,
 p_customer_name=>'GRN Policy B',p_items=>jsonb_build_array(jsonb_build_object(
 'item_id',:'item_id','item_name','GRN Policy Potatoes','packaging','Bag','qty',10,'weight',5)),
 p_idempotency_key=>'staff-policy-staff-receipt') AS staff_receipt \gset
SELECT pg_temp.grn_assert(:'staff_receipt'::jsonb->>'success'='true','staff creates receipt for unassigned customer');
SELECT id AS grn_a FROM public.goodsreceived WHERE gr_no='STAFFA' \gset
SELECT id AS grn_b FROM public.goodsreceived WHERE gr_no='STAFFB' \gset
SELECT id AS lot_b FROM public.goodsreceived_trl WHERE gr_id=:'grn_b'::uuid \gset
SELECT pg_temp.grn_assert(public.get_grn_details(:'grn_a'::uuid)->>'success'='true','staff views other customer GRN');
SELECT pg_temp.grn_assert(public.get_grn_details(:'grn_b'::uuid)#>>'{data,grn,dispatches_summary,total_dispatches}'='0','authorized edit dispatch summary');
SELECT pg_temp.grn_assert(public.get_grn_list()->>'success'='true','GRN list');
SELECT pg_temp.grn_assert(jsonb_array_length(public.get_all_grn_items(p_filters=>'{}'::jsonb)->'data')=2,'mobile GRN list includes both customers');
SELECT pg_temp.grn_assert((public.get_all_grn_items(p_catalog_id=>:'item_id'::uuid)#>>'{data,total_count}')::integer=2,'legacy GRN list includes both customers');
SELECT pg_temp.grn_assert(public.get_all_grn_activity(current_date,current_date)->>'success'='true','GRN activity');
SELECT public.update_grn(p_grn_id=>:'grn_b'::uuid,p_note=>'Staff edited receipt',
 p_items=>jsonb_build_array(jsonb_build_object('id',:'lot_b','item_id',:'item_id',
 'item_name','GRN Policy Potatoes','packaging','Bag','qty',12,'weight',5))) AS edited \gset
SELECT pg_temp.grn_assert(:'edited'::jsonb->>'success'='true','staff edits receipt');
SELECT pg_temp.grn_assert((SELECT note='Staff edited receipt' FROM public.goodsreceived WHERE id=:'grn_b'::uuid),'edited header persisted');
SELECT pg_temp.grn_assert((SELECT qty=12 AND stock=12 FROM public.goodsreceived_trl WHERE id=:'lot_b'::uuid),'edited quantity and stock reconcile');
SELECT pg_temp.grn_assert(
 (public.get_all_grn_items(p_grn_id=>:'grn_b'::uuid)#>>'{data,items,0,stock}')::integer=12,
 'legacy GRN stock refreshes after the staff edit');
-- A failed bulk edit must roll back both the header and any intermediate
-- materialized refresh, and restore the temporarily suppressed dirty trigger.
DO $$ DECLARE receipt uuid; lot uuid; catalog uuid; BEGIN
 SELECT g.id,t.id,t.item_id INTO receipt,lot,catalog
 FROM public.goodsreceived g JOIN public.goodsreceived_trl t ON t.gr_id=g.id
 WHERE g.gr_no='STAFFB';
 BEGIN
  PERFORM public.update_grn(p_grn_id=>receipt,p_note=>'Must roll back',
    p_items=>jsonb_build_array(jsonb_build_object('id',lot,'item_id',catalog,
      'item_name','GRN Policy Potatoes','qty','invalid-quantity')));
  RAISE EXCEPTION 'Invalid GRN edit was accepted';
 EXCEPTION WHEN invalid_text_representation THEN NULL; END;
END $$;
SELECT pg_temp.grn_assert((SELECT note='Staff edited receipt' FROM public.goodsreceived WHERE id=:'grn_b'::uuid),'failed edit rolls back header');
SELECT pg_temp.grn_assert((SELECT qty=12 AND stock=12 FROM public.goodsreceived_trl WHERE id=:'lot_b'::uuid),'failed edit preserves underlying stock');
SELECT pg_temp.grn_assert(
 (public.get_all_grn_items(p_grn_id=>:'grn_b'::uuid)#>>'{data,items,0,stock}')::integer=12,
 'failed edit preserves cached stock');
SELECT pg_temp.grn_denied('SELECT warehouse_security.refresh_dirty_lists()');
RESET ROLE;
SELECT pg_temp.grn_assert((SELECT current_stock=12 AND grn_qty=12 FROM public.mv_customer_stock_summary WHERE customer_id=:'customer_b'::uuid AND item_id=:'item_id'::uuid),'customer stock cache refreshed');
SELECT pg_temp.grn_assert((SELECT total_qty=12 FROM public.mv_grn_daily_summary WHERE customer_id=:'customer_b'::uuid),'daily receipt aggregate refreshed');
SELECT pg_temp.grn_assert((SELECT current_stock=10 FROM public.mv_customer_stock_summary WHERE customer_id=:'customer_a'::uuid AND item_id=:'item_id'::uuid),'unrelated customer cache unchanged');
SELECT pg_temp.grn_assert((SELECT tgenabled='O' FROM pg_trigger WHERE tgrelid='public.goodsreceived_trl'::regclass AND tgname='trg_mark_stock_mvs_dirty_grn'),'dirty trigger restored after failed edit');
SELECT pg_temp.grn_assert(NOT EXISTS(SELECT 1 FROM public.mv_refresh_queue WHERE needs_refresh),'successful edit consumes refresh queue');
SET LOCAL ROLE authenticated;
SELECT public.register_grn_image_upload(:'grn_b'::uuid,'header','fictional.webp',32,'image/webp') AS upload \gset
SELECT pg_temp.grn_assert(:'upload'::jsonb->>'success'='true','staff registers attachment');
INSERT INTO storage.objects(bucket_id,name,owner)
 VALUES ('grn-images',:'upload'::jsonb->>'storage_path',auth.uid());
SELECT pg_temp.grn_assert((SELECT count(*)=1 FROM storage.objects),'own pending upload readable');
UPDATE storage.objects SET name=name WHERE bucket_id='grn-images';
DO $$ BEGIN
 BEGIN
  INSERT INTO storage.objects(bucket_id,name,owner) VALUES ('grn-images','unregistered.webp',auth.uid());
  RAISE EXCEPTION 'unregistered staff upload accepted';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN
  INSERT INTO storage.objects(bucket_id,name,owner) VALUES ('dispatch-images','unrelated.webp',auth.uid());
  RAISE EXCEPTION 'unrelated bucket staff upload accepted';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;

SELECT pg_temp.grn_assert(public.confirm_grn_image_upload((:'upload'::jsonb->>'image_id')::uuid,
 (:'upload'::jsonb->>'upload_token')::uuid)->>'success'='true','staff confirms own attachment');
SELECT pg_temp.grn_assert((SELECT count(*)=1 FROM public.grn_images WHERE grn_id=:'grn_b'::uuid),'confirmed attachment readable');
SELECT pg_temp.grn_assert((SELECT count(*)=1 FROM storage.objects),'confirmed GRN object readable');
DO $$ DECLARE affected integer; BEGIN
 UPDATE storage.objects SET name=name; GET DIAGNOSTICS affected=ROW_COUNT;
 PERFORM pg_temp.grn_assert(affected=0,'confirmed object cannot be overwritten by staff');
 DELETE FROM storage.objects; GET DIAGNOSTICS affected=ROW_COUNT;
 PERFORM pg_temp.grn_assert(affected=0,'confirmed object cannot be deleted by staff');
END $$;

SELECT pg_temp.grn_denied(format('SELECT public.delete_grn_safe(%L::uuid)',:'grn_b'));
SELECT pg_temp.grn_denied('SELECT public.get_users_list()');
SELECT pg_temp.grn_denied('SELECT public.save_invoice(''{}''::jsonb)');
SELECT pg_temp.grn_denied('SELECT public.create_customer(''Forbidden New Customer'',''9888888859'')');
SELECT pg_temp.grn_denied(format('SELECT public.delete_grn_image(%L::uuid)',:'upload'::jsonb->>'image_id'));
DO $$ DECLARE affected integer; BEGIN
 DELETE FROM public.goodsreceived WHERE gr_no='STAFFB'; GET DIAGNOSTICS affected=ROW_COUNT;
 PERFORM pg_temp.grn_assert(affected=0,'staff cannot directly delete GRN');
 UPDATE public.goodsreceived SET deleted_at=now() WHERE gr_no='STAFFB'; GET DIAGNOSTICS affected=ROW_COUNT;
 PERFORM pg_temp.grn_assert(affected=0,'staff cannot directly soft-delete GRN');
 UPDATE public.goodsreceived_trl SET stock=999; GET DIAGNOSTICS affected=ROW_COUNT;
 PERFORM pg_temp.grn_assert(affected=0,'staff cannot bypass stock checks');
END $$;
RESET ROLE;
SELECT set_config('request.jwt.claims',:'customer_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.grn_assert((SELECT count(*)=1 FROM public.customers WHERE name LIKE 'GRN Policy %'),'customer assignment boundary unchanged');
SELECT pg_temp.grn_assert((SELECT count(*)=0 FROM public.goodsreceived WHERE gr_no='STAFFB'),'customer cannot read foreign GRN');
SELECT pg_temp.grn_denied(format('SELECT public.get_grn_details(%L::uuid)',:'grn_b'));
SELECT pg_temp.grn_denied('SELECT public.get_grn_list()');
SELECT pg_temp.grn_denied(format('SELECT public.update_grn(%L::uuid,p_note=>''Forbidden'')',:'grn_a'));
RESET ROLE;
SAVEPOINT supervisor_deletion;
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.grn_assert(public.delete_grn_safe(:'grn_a'::uuid)->>'success'='true','supervisor deletion retained');
ROLLBACK TO supervisor_deletion;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.grn_assert(public.delete_grn_safe(:'grn_a'::uuid)->>'success'='true','admin deletion retained');
RESET ROLE;
UPDATE public.user_profiles SET active=false WHERE mobile='919888888862';
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.grn_assert((SELECT count(*)=0 FROM public.goodsreceived),'inactive staff loses direct GRN access');
SELECT pg_temp.grn_denied('SELECT public.get_grn_list()');
RESET ROLE;
UPDATE public.user_profiles SET active=true WHERE mobile='919888888862';
DELETE FROM warehouse_security.refresh_sessions WHERE user_id=(:'staff_claims'::jsonb->>'sub')::uuid;
SET LOCAL ROLE authenticated;
SELECT pg_temp.grn_assert((SELECT count(*)=0 FROM public.goodsreceived),'revoked staff loses GRN access');
SELECT pg_temp.grn_denied('SELECT public.get_grn_list()');
RESET ROLE;
ROLLBACK;
SELECT 'staff GRN create/read/update, deletion/other-role denials and revocation passed' AS result;

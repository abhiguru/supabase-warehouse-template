-- Fictional core-pilot regression. Runs only in migrations.sh's disposable,
-- network-disabled database. Uses the existing operator test-session lifecycle.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.core_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'staff dispatch/invoice: %',label; END IF; END $$;
-- A privileged RPC must refuse through the real guard: either a raw 42501 or
-- the function's own success:false envelope carrying the authorization text.
CREATE FUNCTION pg_temp.core_denied(statement text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE result jsonb;
BEGIN
  BEGIN
    EXECUTE statement INTO result;
    PERFORM pg_temp.core_assert(result->>'success'='false' AND
      (result::text LIKE '%42501%' OR result::text LIKE '%Staff access required%' OR
       result::text LIKE '%Administrator required%' OR result::text LIKE '%Customer access denied%' OR
       result::text LIKE '%Active account required%'), 'privileged RPC must return authorization denial: '||statement);
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888888871','Core Demo Administrator') AS admin_user \gset
SELECT public.operator_prepare_otp('9888888871') AS challenge \gset
SELECT pg_temp.core_assert(:'challenge'::jsonb->>'success'='true','operator challenge prepared');
SELECT public.operator_finish_otp((:'challenge'::jsonb#>>'{data,request_id}')::uuid,true,'mock-provider-only');
SELECT public.operator_verify_otp('9888888871',:'challenge'::jsonb#>>'{data,otp_code}') AS login \gset
SELECT pg_temp.core_assert(:'login'::jsonb#>>'{data,action}'='login','mocked operator login');
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset

INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status)
VALUES (gen_random_uuid(),'919888888865','Document Policy Staff','staff',true,'approved');
SELECT public.operator_prepare_otp('9888888865') AS staff_challenge \gset
SELECT pg_temp.core_assert(:'staff_challenge'::jsonb->>'success'='true','ordinary staff OTP challenge');
SELECT public.operator_finish_otp((:'staff_challenge'::jsonb#>>'{data,request_id}')::uuid,true,'mock-provider-only');
SELECT public.operator_verify_otp('9888888865',:'staff_challenge'::jsonb#>>'{data,otp_code}') AS staff_login \gset
SELECT pg_temp.core_assert(:'staff_login'::jsonb#>>'{data,action}'='login','ordinary staff login');
SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) AS staff_claims
FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
WHERE p.mobile='919888888865' ORDER BY r.created_at DESC LIMIT 1 \gset

SELECT set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',:'admin_user',
 'session_id',(SELECT id FROM warehouse_security.refresh_sessions WHERE user_id=:'admin_user'::uuid LIMIT 1))::text,true);
SET LOCAL ROLE authenticated;
SELECT public.create_customer('Core Demo Customer A','9888888872') AS customer \gset
SELECT pg_temp.core_assert(:'customer'::jsonb->>'success'='true','customer creation');
SELECT public.create_item('Core Demo Potatoes','Bag') AS item \gset
SELECT pg_temp.core_assert(:'item'::jsonb->>'success'='true','catalog creation');
SELECT id AS customer_id FROM public.customers WHERE name='Core Demo Customer A' \gset
SELECT id AS item_id FROM public.items WHERE name='Core Demo Potatoes' \gset
SELECT public.create_item_storage_price(p_item_id=>:'item_id'::uuid,p_price_type=>'monthly',p_unit_price=>5,
 p_weight_min=>0,p_weight_max=>100,p_labour_rate=>2,p_effective_from=>'2026-01-01',
 p_customer_id=>:'customer_id'::uuid,p_tax_percent=>5) AS price \gset
SELECT pg_temp.core_assert(:'price'::jsonb->>'success'='true','fictional price creation');
SELECT public.save_grn(p_gr_no=>'COREA',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_id'::uuid,
 p_customer_name=>'Core Demo Customer A',p_pricing_mode=>'MONTHLY',p_idempotency_key=>'core-receipt',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Core Demo Potatoes',
 'packaging','Bag','qty',100,'weight',10,'rack','DEMO'))) AS grn \gset
SELECT pg_temp.core_assert(:'grn'::jsonb->>'success'='true','receipt creation');
SELECT id AS grn_id FROM public.goodsreceived WHERE gr_no='COREA' \gset
SELECT id AS stock_id FROM public.goodsreceived_trl WHERE gr_id=:'grn_id'::uuid \gset
RESET ROLE;
SELECT pg_temp.core_assert((SELECT stock=100 FROM public.goodsreceived_trl WHERE id=:'stock_id'::uuid),'receipt stock 100');
SET LOCAL ROLE authenticated;
RESET ROLE;
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.core_assert(warehouse_security.active_role()='staff','actual staff role');
SELECT jsonb_build_object('disp_no','COREA','disp_date','2026-05-02T12:00:00Z','customer_id',:'customer_id',
 'customer_name','Core Demo Customer A','supervisor_id',:'admin_profile','supervisor_name','Core Demo Administrator') AS dispatch_data \gset
SELECT public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'stock_id','disp_qty',20)],false,0,'staff-document-partial') AS dispatch \gset
SELECT pg_temp.core_assert(:'dispatch'::jsonb->>'success'='true','partial dispatch');
SELECT public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'stock_id','disp_qty',20)],false,0,'staff-document-partial') AS retry \gset
SELECT pg_temp.core_assert(:'retry'::jsonb->>'success'='true','dispatch retry');
RESET ROLE;
SELECT pg_temp.core_assert((SELECT stock=80 FROM public.goodsreceived_trl WHERE id=:'stock_id'::uuid),'retry leaves 80 bags');
SET LOCAL ROLE authenticated;
SELECT pg_temp.core_assert(public.generate_invoice_data_for_grn_with_pricing(:'grn_id'::uuid)->>'success'='false','partial receipt cannot invoice');
SELECT public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb || '{"disp_no":"COREB"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'stock_id','disp_qty',80)],false,0,'staff-document-final') AS final_dispatch \gset
SELECT pg_temp.core_assert(:'final_dispatch'::jsonb->>'success'='true','final dispatch');
RESET ROLE;
SELECT pg_temp.core_assert((SELECT stock=0 FROM public.goodsreceived_trl WHERE id=:'stock_id'::uuid),'final stock zero');
SET LOCAL ROLE authenticated;
SELECT public.generate_invoice_data_for_grn_with_pricing(p_gr_id=>:'grn_id'::uuid,p_duration_mode=>'legacy') AS preview \gset
SELECT pg_temp.core_assert(:'preview'::jsonb->>'success'='true','invoice preview');
SELECT pg_temp.core_assert(:'preview'::jsonb->'totals'='{"subtotal":950,"tax":48,"total_tax":48,"grand_total":998,"total":998,"total_rows":2}'::jsonb,'fictional totals reconcile');
SELECT pg_temp.core_assert((SELECT jsonb_agg(jsonb_build_object('qty',r->'dispatch_qty','storage',r->'storage_amount',
 'labour',r->'labour_amount','tax',r->'tax_amount','total',r->'total_amount') ORDER BY (r->>'dispatch_qty')::numeric)
 FROM jsonb_array_elements(:'preview'::jsonb->'rows') r)='[{"qty":20,"storage":150,"labour":40,"tax":9.5,"total":199.5},{"qty":80,"storage":600,"labour":160,"tax":38,"total":798}]'::jsonb,'independent line amounts');
RESET ROLE;
SELECT jsonb_agg(jsonb_build_object('disp_trl_id',t.id,'charge',5,'tax',5,'labour_rate',2)) AS invoice_items
 FROM public.dispatch_trl t JOIN public.dispatch d ON d.id=t.disp_id WHERE d.disp_no IN ('COREA','COREB') \gset
SET LOCAL ROLE authenticated;
SELECT jsonb_build_object('inv_no',20260929,'inv_fin_year',2026,'gr_id',:'grn_id','gr_no','COREA',
 'customer_id',:'customer_id','customer_name','Core Demo Customer A','inv_date','2026-05-02T12:00:00Z',
 'total',998,'tax_amount',48,'discount',0,'duration_mode','legacy','items',:'invoice_items'::jsonb) AS invoice_data \gset
SELECT public.save_invoice(:'invoice_data'::jsonb) AS saved \gset
SELECT pg_temp.core_assert(:'saved'::jsonb->>'success'='true','save invoice');
RESET ROLE;
SELECT pg_temp.core_assert((SELECT total=998 AND tax_amount=48 AND discount=0 FROM public.invoice WHERE id=(:'saved'::jsonb->>'invoice_id')::uuid),'saved header matches preview');
SET LOCAL ROLE authenticated;
SELECT public.save_invoice(:'invoice_data'::jsonb || '{"inv_no":20260930,"items":[{"disp_trl_id":"00000000-0000-4000-8000-000000000000","charge":1}]}'::jsonb) AS invalid \gset
SELECT pg_temp.core_assert(:'invalid'::jsonb->>'success'='false','invalid dispatch invoice denied');
RESET ROLE;
SELECT pg_temp.core_assert(NOT EXISTS(SELECT 1 FROM public.invoice WHERE inv_no=20260930),'invalid invoice rolls back header');
SET LOCAL ROLE authenticated;

-- Migration 30: staff may discount an invoice only with a reason, and the
-- reason, author and time are recorded; an unchanged discount keeps them.
SELECT (:'invoice_data'::jsonb - 'items') AS invoice_header \gset
SELECT public.update_invoice((:'saved'::jsonb->>'invoice_id')::uuid, :'invoice_header'::jsonb || '{"discount":235}'::jsonb,
 ARRAY(SELECT jsonb_array_elements(:'invoice_items'::jsonb))) AS no_reason \gset
SELECT pg_temp.core_assert(:'no_reason'::jsonb->>'success'='false' AND :'no_reason'::jsonb::text LIKE '%reason is required%',
 'staff discount without a reason refused: ' || :'no_reason');
SELECT public.update_invoice((:'saved'::jsonb->>'invoice_id')::uuid, :'invoice_header'::jsonb || '{"discount":235,"discount_reason":"  Damaged bags  "}'::jsonb,
 ARRAY(SELECT jsonb_array_elements(:'invoice_items'::jsonb))) AS with_reason \gset
SELECT pg_temp.core_assert(:'with_reason'::jsonb->>'success'='true','staff discount with a reason saved: ' || :'with_reason');
SELECT public.update_invoice((:'saved'::jsonb->>'invoice_id')::uuid, :'invoice_header'::jsonb || '{"discount":235,"notes":"unchanged discount"}'::jsonb,
 ARRAY(SELECT jsonb_array_elements(:'invoice_items'::jsonb))) AS unchanged \gset
SELECT pg_temp.core_assert(:'unchanged'::jsonb->>'success'='true','staff edit with an unchanged discount needs no new reason');
RESET ROLE;
SELECT pg_temp.core_assert((SELECT discount=235 AND total=763 AND discount_reason='Damaged bags' AND discount_set_at IS NOT NULL
   AND discount_set_by=(SELECT id FROM public.user_profiles WHERE auth_user_id=(:'staff_claims'::jsonb->>'sub')::uuid)
 FROM public.invoice WHERE id=(:'saved'::jsonb->>'invoice_id')::uuid),'discount reason, author and total recorded');
SELECT pg_temp.core_assert((SELECT bool_and(pg_get_functiondef(f) LIKE '%warehouse.discount_reason%') FROM unnest(ARRAY[
 'public.save_invoice(jsonb)','public.save_invoice(uuid,jsonb,jsonb[])','public.update_invoice(uuid,jsonb,jsonb[])']::regprocedure[]) f),
 'every invoice save path forwards the discount reason');
SET LOCAL ROLE authenticated;

SELECT pg_temp.core_assert(public.get_invoice_data((:'saved'::jsonb->>'invoice_id')::uuid)->>'success'='true','staff reads invoice RPC');
SELECT pg_temp.core_assert(public.get_invoices_list()->>'success'='true','staff lists invoices');
SELECT public.get_dispatch_list() AS staff_dispatch_list \gset
SELECT pg_temp.core_assert(:'staff_dispatch_list'::jsonb->>'success'='true',
 'staff lists dispatches: ' || COALESCE(:'staff_dispatch_list'::jsonb->>'message','no message'));
-- Migration 23: the dispatch GRN picker and recent-dispatch feed work for an
-- unassigned customer, and pricing is reachable only through invoice generation.
SELECT public.get_customer_grns_with_stock_dispatch_sorted(:'customer_id'::uuid,10,0) AS staff_grn_picker \gset
SELECT pg_temp.core_assert(:'staff_grn_picker'::jsonb->>'success'='true',
 'staff dispatch GRN picker: ' || COALESCE(:'staff_grn_picker'::jsonb->>'error',:'staff_grn_picker'::jsonb->>'message','no message'));
SELECT public.get_recent_dispatched_orders(10,0) AS staff_recent \gset
SELECT pg_temp.core_assert(:'staff_recent'::jsonb->>'success'='true',
 'staff recent dispatched orders: ' || COALESCE(:'staff_recent'::jsonb->>'error',:'staff_recent'::jsonb->>'message','no message'));
-- Denials go through the real guarded RPCs; the previous direct authorize_rpc
-- probe could never fail because authenticated has no EXECUTE on the guard.
SELECT pg_temp.core_denied(format('SELECT public.delete_invoice(%L::uuid)',:'saved'::jsonb->>'invoice_id'));
SELECT pg_temp.core_denied(format('SELECT public.update_user_role(%L::uuid,''admin''::public.user_role)',:'admin_profile'));
SELECT pg_temp.core_denied(format('SELECT public.create_item_storage_price(p_item_id=>%L::uuid,p_price_type=>''monthly'',p_unit_price=>1,p_weight_min=>0,p_weight_max=>1,p_labour_rate=>0,p_effective_from=>''2026-01-01'')',:'item_id'));
SELECT pg_temp.core_denied('SELECT public.get_item_storage_prices()');
SELECT pg_temp.core_denied(format('SELECT public.get_item_storage_prices(%L::jsonb)',jsonb_build_object('customer_id',:'customer_id')::text));
RESET ROLE;
SELECT pg_temp.core_assert((SELECT count(*)=1 FROM public.invoice WHERE id=(:'saved'::jsonb->>'invoice_id')::uuid AND deleted_at IS NULL),'denied deletion leaves the invoice');
SELECT pg_temp.core_assert((SELECT role='admin' FROM public.user_profiles WHERE id=:'admin_profile'::uuid),'denied role change leaves the administrator');
SELECT pg_temp.core_assert((SELECT count(*)=1 FROM public.item_storage_prices),'denied pricing mutation leaves one price');
SET LOCAL ROLE authenticated;


-- Migration 22 caller-RLS regression: actual PDF joins, no direct writes,
-- pending-image ownership, reciprocal customer isolation and session revocation.
SELECT pg_temp.core_assert((SELECT count(*)=2 FROM public.dispatch),'staff sees warehouse dispatch headers');
SELECT pg_temp.core_assert((SELECT count(*)=2 FROM public.dispatch_trl),'staff sees warehouse dispatch lines');
SELECT pg_temp.core_assert((SELECT count(*)=1 FROM public.invoice),'staff sees invoice header');
SELECT pg_temp.core_assert((SELECT count(*)=2 FROM public.invoice_trl t
 JOIN public.dispatch_trl d ON d.id=t.disp_trl_id JOIN public.goodsreceived_trl g ON g.id=d.gr_trl_id
 WHERE t.invoice_id=(:'saved'::jsonb->>'invoice_id')::uuid),'caller-RLS PDF line joins complete');
SELECT pg_temp.core_assert((SELECT count(*)=0 FROM public.item_storage_prices),'no direct pricing read grant');
DO $$ DECLARE tbl text; affected integer; BEGIN
 FOREACH tbl IN ARRAY ARRAY['dispatch','dispatch_trl','invoice','invoice_trl'] LOOP
  EXECUTE format('UPDATE public.%I SET id=id',tbl); GET DIAGNOSTICS affected=ROW_COUNT;
  PERFORM pg_temp.core_assert(affected=0,'staff direct update denied: '||tbl);
  EXECUTE format('DELETE FROM public.%I',tbl); GET DIAGNOSTICS affected=ROW_COUNT;
  PERFORM pg_temp.core_assert(affected=0,'staff direct delete denied: '||tbl);
 END LOOP;
END $$;
RESET ROLE;
INSERT INTO public.customers(name,mobile) VALUES ('Document Policy Other Customer','9888888855') RETURNING id AS foreign_customer \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888866','Document Policy A Reader','customer',true,'approved'),
 (gen_random_uuid(),'919888888867','Document Policy B Reader','customer',true,'approved');
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active)
 SELECT id,:'customer_id'::uuid,true FROM public.user_profiles WHERE mobile='919888888866';
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active)
 SELECT id,:'foreign_customer'::uuid,true FROM public.user_profiles WHERE mobile='919888888867';
CREATE FUNCTION pg_temp.document_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.core_assert(c->>'success'='true','ordinary customer challenge');
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.core_assert(l#>>'{data,action}'='login','ordinary customer login');
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
SELECT pg_temp.document_login('9888888866') AS customer_a_claims \gset
SELECT pg_temp.document_login('9888888867') AS customer_b_claims \gset
INSERT INTO public.dispatch_images(dispatch_id,storage_path,original_filename,file_size,mime_type,status,uploaded_by)
 SELECT d.id,'document-policy/'||v.label,'fixture.webp',32,'image/webp',v.status,
  CASE WHEN v.label='own-pending' THEN (SELECT id FROM public.user_profiles WHERE mobile='919888888865') ELSE :'admin_profile'::uuid END
 FROM public.dispatch d CROSS JOIN (VALUES ('confirmed','confirmed'),('own-pending','pending'),('foreign-pending','pending')) v(label,status)
 WHERE d.disp_no='COREA';
SELECT id AS foreign_pending_image FROM public.dispatch_images WHERE storage_path='document-policy/foreign-pending' \gset
SELECT id AS own_pending_image FROM public.dispatch_images WHERE storage_path='document-policy/own-pending' \gset
SELECT id AS dispatch_a FROM public.dispatch WHERE disp_no='COREA' \gset
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.core_assert((SELECT count(*)=2 FROM public.dispatch_images),'staff reads confirmed and own pending metadata only');
-- Migration 23: cancellation is bound to the registering profile; staff attach
-- dispatch photos through register/upload/confirm exactly like GRN photos.
SELECT pg_temp.core_assert(public.cancel_dispatch_image_upload(:'foreign_pending_image'::uuid)->>'success'='false','staff cannot cancel another profile''s pending upload');
SELECT pg_temp.core_assert(public.cancel_dispatch_image_upload(:'own_pending_image'::uuid)->>'success'='true','staff cancels own pending upload');
SELECT pg_temp.core_assert((SELECT count(*)=1 FROM public.dispatch_images),'cancelled own pending metadata removed');
SELECT public.register_dispatch_image_upload(:'dispatch_a'::uuid,'fixture.webp',32,'image/webp') AS dispatch_upload \gset
SELECT pg_temp.core_assert(:'dispatch_upload'::jsonb->>'success'='true','staff registers dispatch attachment: '||COALESCE(:'dispatch_upload'::jsonb->>'error',''));
INSERT INTO storage.objects(bucket_id,name) VALUES ('dispatch-images',:'dispatch_upload'::jsonb->>'storage_path');
SELECT pg_temp.core_assert((SELECT count(*)=1 FROM storage.objects WHERE bucket_id='dispatch-images'),'own pending dispatch object readable');
DO $$ BEGIN
 BEGIN
  INSERT INTO storage.objects(bucket_id,name) VALUES ('dispatch-images','unregistered.webp');
  RAISE EXCEPTION 'unregistered staff dispatch upload accepted';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SELECT pg_temp.core_assert(public.confirm_dispatch_image_upload((:'dispatch_upload'::jsonb->>'image_id')::uuid,
 (:'dispatch_upload'::jsonb->>'upload_token')::uuid)->>'success'='true','staff confirms own dispatch attachment');
SELECT pg_temp.core_assert((SELECT count(*)=1 FROM storage.objects WHERE bucket_id='dispatch-images'),'confirmed dispatch object readable');
SELECT pg_temp.core_assert((SELECT count(*)=2 FROM public.dispatch_images),'staff reads fixture and own confirmed metadata');
DO $$ DECLARE affected integer; BEGIN
 UPDATE storage.objects SET name=name WHERE bucket_id='dispatch-images'; GET DIAGNOSTICS affected=ROW_COUNT;
 PERFORM pg_temp.core_assert(affected=0,'confirmed dispatch object cannot be overwritten by staff');
 DELETE FROM storage.objects WHERE bucket_id='dispatch-images'; GET DIAGNOSTICS affected=ROW_COUNT;
 PERFORM pg_temp.core_assert(affected=0,'confirmed dispatch object cannot be deleted by staff');
END $$;
RESET ROLE;
SELECT pg_temp.core_assert((SELECT count(*)=3 FROM public.dispatch_images),'foreign pending upload survives the staff cancel attempt');
SELECT set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',:'admin_user',
 'session_id',(SELECT id FROM warehouse_security.refresh_sessions WHERE user_id=:'admin_user'::uuid LIMIT 1))::text,true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.core_assert(public.cancel_dispatch_image_upload(:'foreign_pending_image'::uuid)->>'success'='true','administrator cancels any pending upload');
RESET ROLE;
SELECT set_config('request.jwt.claims',:'customer_a_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.core_assert((SELECT count(*)=1 FROM public.invoice),'assigned customer retains invoice access');
SELECT pg_temp.core_assert((SELECT count(*)=2 FROM public.dispatch),'assigned customer retains dispatch access');
SELECT pg_temp.core_assert((SELECT count(*)=0 FROM public.customers WHERE id=:'foreign_customer'::uuid),'A cannot read B customer');
RESET ROLE;
SELECT set_config('request.jwt.claims',:'customer_b_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.core_assert((SELECT count(*)=0 FROM public.invoice),'B cannot read A invoice');
SELECT pg_temp.core_assert((SELECT count(*)=0 FROM public.invoice_trl),'B cannot read A invoice lines');
SELECT pg_temp.core_assert((SELECT count(*)=0 FROM public.dispatch),'B cannot read A dispatch');
SELECT pg_temp.core_assert((SELECT count(*)=0 FROM public.dispatch_trl),'B cannot read A dispatch lines');
SELECT pg_temp.core_assert((SELECT count(*)=0 FROM public.dispatch_images),'B cannot read A image metadata');
RESET ROLE;
UPDATE public.user_profiles SET active=false WHERE mobile='919888888865';
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.core_assert((SELECT count(*)=0 FROM public.invoice),'disabled staff loses invoice reads');
SELECT pg_temp.core_assert((SELECT count(*)=0 FROM public.dispatch),'disabled staff loses dispatch reads');
SELECT pg_temp.core_assert((SELECT count(*)=0 FROM public.dispatch_images),'disabled staff loses image metadata');
RESET ROLE;
UPDATE public.user_profiles SET active=true WHERE mobile='919888888865';
-- Revocation is local to this rolled-back disposable test fixture.
DELETE FROM warehouse_security.refresh_sessions WHERE id=(:'staff_claims'::jsonb->>'session_id')::uuid;
SET LOCAL ROLE authenticated;
SELECT pg_temp.core_assert((SELECT count(*)=0 FROM public.invoice),'revoked staff loses invoice reads');
SELECT pg_temp.core_assert((SELECT count(*)=0 FROM public.dispatch),'revoked staff loses dispatch reads');
SELECT pg_temp.core_assert((SELECT count(*)=0 FROM public.invoice_trl),'revoked staff loses invoice lines');
SELECT pg_temp.core_assert((SELECT count(*)=0 FROM public.dispatch_trl),'revoked staff loses dispatch lines');
SELECT pg_temp.core_assert((SELECT count(*)=0 FROM public.dispatch_images),'revoked staff loses image metadata');

RESET ROLE;
ROLLBACK;
\echo 'Staff ordinary login, partial/final dispatch, retry, invoice and restricted-action checks passed.'

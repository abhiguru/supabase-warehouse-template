-- Migration 45: what each role may call (owner decision, 2026-10-11).
--
-- 1. Catalog: every function the app role may execute is classified below, and
--    every guarded one still calls warehouse_security.authorize_rpc. A function
--    granted later fails this test until it is added to the table.
-- 2. Denial sweeps: a customer account is refused every function that is not
--    its own, also with another customer's id; staff are refused everything
--    outside their allowlist.
-- 3. Per role: each newly admitted call succeeds, and the calls that must stay
--    refused are refused (supervisor on an administrator, on the own profile
--    and on granting the administrator role; staff on user management; a
--    customer on the all-customers reports, pricing and sensors).
-- 4. The other changes of migration 45: supervisor contact details, the
--    supervisor picker, the staff order policy, printer_status, the role read
--    from the database.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled
-- database (storage.objects rows stand in for uploaded files).
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.ra_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'role allowlist: %',label; END IF; END $$;
-- 'refused' when the guard stops the statement: a raw 42501, or a function's
-- own error envelope carrying one of the guard's four messages. Otherwise
-- 'ok: <answer>' or 'error: <message>'. A refused statement changes nothing.
CREATE FUNCTION pg_temp.ra_outcome(statement text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE answer text;
BEGIN
  BEGIN
    EXECUTE format('SELECT (SELECT to_jsonb(q) FROM (%s) q LIMIT 1)::text', statement) INTO answer;
  EXCEPTION WHEN insufficient_privilege THEN RETURN 'refused';
    WHEN OTHERS THEN RETURN 'error: ' || SQLERRM;
  END;
  IF answer ~ '(Staff access required|Administrator required|Customer access denied|Active account required)' THEN
    RETURN 'refused';
  END IF;
  RETURN 'ok: ' || COALESCE(answer,'null');
END $$;
CREATE FUNCTION pg_temp.ra_refused(statement text) RETURNS boolean LANGUAGE sql AS $$
  SELECT pg_temp.ra_outcome(statement) = 'refused' $$;
-- The single jsonb answer of an RPC, or {"raised": message}.
CREATE FUNCTION pg_temp.ra_call(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.ra_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.ra_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.ra_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;

-- ---------------------------------------------------------------------------
-- The classification. One row per function name the app role may execute.
--   staff     the staff role is admitted (for the two photo deletes: within
--             the rule the guard applies)
--   customer  'any' every signed-in account; 'own' only with a document or
--             customer of the account; 'no' never
-- Administrators and supervisors are admitted to every row; the user
-- management bodies restrict a supervisor further (section 5).
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE ra_rpc(name text PRIMARY KEY, staff boolean NOT NULL, customer text NOT NULL CHECK (customer IN ('any','own','no')));
INSERT INTO ra_rpc(name,staff,customer) VALUES
 -- every signed-in account
 ('get_items',true,'any'),('get_item',true,'any'),('search_items_autocomplete',true,'any'),
 ('get_orders_list',true,'any'),('delete_user_account',true,'any'),
 -- a customer's own documents, carts and reports; staff for every customer
 ('get_grn_details',true,'own'),('get_grn_item_dispatches',true,'own'),('get_dispatch_details',true,'own'),
 ('get_invoice_data',true,'own'),('get_invoice_detail',true,'own'),('get_invoice_items_detailed',true,'own'),
 ('get_order_with_items',true,'own'),('get_cart_dispatches',true,'own'),('add_item_to_order',true,'own'),
 ('update_order_item_quantity',true,'own'),('remove_item_from_order',true,'own'),('get_order_change_log',true,'own'),
 ('get_or_create_cart',true,'own'),('search_customer_items_for_order',true,'own'),
 ('get_customer_items_for_order_selection',true,'own'),
 ('get_customer_grn_activity',true,'own'),('get_customer_grn_items',true,'own'),
 ('get_customer_grns_with_stock_dispatch_sorted',true,'own'),
 ('get_customer_dispatch_list',true,'own'),('get_customer_dispatch_items',true,'own'),
 ('get_customer_invoice_summary',true,'own'),
 -- admitted for staff by migration 45; a customer with an own customer id
 ('get_customer_stock_summary',true,'own'),('get_customer_activity_detail',true,'own'),
 ('get_customer_dispatch_activity',true,'own'),
 ('get_stock_aging_report',true,'own'),('get_item_wise_stock_list',true,'own'),
 -- customer-scoped, used by no staff screen
 ('get_customer_stock_analysis_v2',false,'own'),
 -- warehouse-wide: staff documents (migrations 18 to 28)
 ('save_grn',true,'no'),('update_grn',true,'no'),('check_grn_exists',true,'no'),('get_next_grn_number',true,'no'),
 ('get_all_grn_items',true,'no'),('get_grn_list',true,'no'),('get_grn_autocomplete',true,'no'),
 ('get_grn_prefixes_with_stock',true,'no'),('get_all_grn_activity',true,'no'),
 ('search_customers',true,'no'),('get_supervisors',true,'no'),('get_vehicle_suggestions',true,'no'),
 ('register_grn_image_upload',true,'no'),('confirm_grn_image_upload',true,'no'),
 ('cancel_grn_image_upload',true,'no'),('upload_grn_image',true,'no'),
 ('register_dispatch_image_upload',true,'no'),('confirm_dispatch_image_upload',true,'no'),
 ('cancel_dispatch_image_upload',true,'no'),
 ('create_dispatch_with_stock_check',true,'no'),('update_dispatch_smart',true,'no'),
 ('check_dispatch_exists',true,'no'),('get_next_dispatch_number',true,'no'),('get_dispatch_autocomplete',true,'no'),
 ('get_dispatch_list',true,'no'),('get_dispatch_list_with_items',true,'no'),
 ('get_all_dispatch_items',true,'no'),('get_all_dispatch_activity',true,'no'),('get_recent_dispatched_orders',true,'no'),
 ('save_invoice',true,'no'),('update_invoice',true,'no'),('get_next_invoice_number',true,'no'),
 ('get_invoiceable_grns',true,'no'),('get_invoices_list',true,'no'),
 ('generate_invoice_data_for_grn_with_pricing',true,'no'),
 -- warehouse-wide: admitted for staff by migration 45
 ('get_all_stock_summary',true,'no'),('get_all_customer_activity_summary',true,'no'),
 ('get_item_storage_prices',true,'no'),('find_or_create_item_storage_price',true,'no'),
 ('create_item_storage_price',true,'no'),('update_item_storage_price',true,'no'),('delete_item_storage_price',true,'no'),
 ('get_sensor_polling_data',true,'no'),('get_sensor_history',true,'no'),
 ('delete_grn_image',true,'no'),('delete_dispatch_image',true,'no'),
 -- administrators and supervisors only
 ('update_user_role',false,'no'),('update_user_status',false,'no'),
 ('assign_customer_to_user',false,'no'),('remove_customer_assignment',false,'no'),
 ('get_users_list',false,'no'),('get_user_details',false,'no'),('get_operations_dashboard',false,'no'),
 ('create_customer',false,'no'),('update_customer',false,'no'),('safe_delete_customer',false,'no'),('restore_customer',false,'no'),
 ('create_item',false,'no'),('update_item',false,'no'),('delete_item_safe',false,'no'),
 ('delete_grn_safe',false,'no'),('delete_dispatch_with_order_cleanup',false,'no'),('delete_invoice',false,'no'),
 ('update_order_metadata',false,'no');
GRANT SELECT ON ra_rpc TO authenticated;
-- Granted functions that do not go through the guard: session plumbing and
-- own-account calls that authorize themselves.
CREATE FUNCTION pg_temp.ra_unguarded() RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY['check_session','refresh_jwt_token','logout_session','get_current_user_profile_id',
    'get_current_user_role','user_accessible_customers','get_my_language','set_my_language',
    'operator_review_enrollment','get_available_stock'] $$;
-- Runs as the caller. Calls every granted, guarded function whose name is not
-- in `admitted` and names those the guard did NOT refuse; the result is empty
-- when all are refused. Every argument is NULL, except that with `unknown_ids`
-- each uuid argument is a random id that names nothing.
CREATE FUNCTION pg_temp.ra_not_refused(admitted text[], unknown_ids boolean DEFAULT false) RETURNS text LANGUAGE plpgsql AS $$
DECLARE r record; outcome text; open text := '';
BEGIN
  FOR r IN SELECT p.proname,
      (SELECT string_agg(CASE WHEN unknown_ids AND a.t='uuid'::regtype THEN format('%L::uuid',gen_random_uuid())
                              ELSE 'NULL::'||format_type(a.t,NULL) END, ',' ORDER BY a.ord)
         FROM unnest(p.proargtypes::oid[]) WITH ORDINALITY a(t,ord)) AS arguments
    FROM pg_proc p
    WHERE p.pronamespace='public'::regnamespace AND p.prokind='f'
      AND has_function_privilege('authenticated',p.oid,'EXECUTE')
      AND p.proname <> ALL(admitted) AND p.proname <> ALL(pg_temp.ra_unguarded())
    ORDER BY p.oid::regprocedure::text LOOP
    outcome := pg_temp.ra_outcome(format('SELECT public.%I(%s)', r.proname, COALESCE(r.arguments,'')));
    -- get_invoiceable_grns(integer,integer) cannot be told from its
    -- three-argument overload in a positional call; that overload is swept.
    CONTINUE WHEN outcome LIKE 'error: function % is not unique';
    IF outcome <> 'refused' THEN open := open || ' ' || r.proname || ' -> ' || left(outcome,70) || ';'; END IF;
  END LOOP;
  RETURN open;
END $$;
-- Three list RPCs (migrations 11 and 12) answer a missing id with a fixed
-- "id required" message before they reach the guard. With NULL arguments they
-- are checked for that answer; the unknown-id sweep takes them to the guard.
CREATE FUNCTION pg_temp.ra_id_checked_first() RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY['get_customer_dispatch_list','get_customer_grn_items','get_grn_item_dispatches'] $$;
-- Runs as the caller. Calls every granted function that takes a customer id
-- with `customer` in that argument and NULL elsewhere, and names those the
-- guard did not refuse.
CREATE FUNCTION pg_temp.ra_not_refused_for(customer uuid, admitted text[]) RETURNS text LANGUAGE plpgsql AS $$
DECLARE r record; outcome text; open text := '';
BEGIN
  FOR r IN SELECT p.proname,
      (SELECT string_agg(CASE WHEN p.proargnames[a.ord] IN ('p_customer_id','p_customer_uuid')
                              THEN format('%L::uuid',customer) ELSE 'NULL::'||format_type(a.t,NULL) END, ',' ORDER BY a.ord)
         FROM unnest(p.proargtypes::oid[]) WITH ORDINALITY a(t,ord)) AS arguments
    FROM pg_proc p
    WHERE p.pronamespace='public'::regnamespace AND p.prokind='f'
      AND has_function_privilege('authenticated',p.oid,'EXECUTE')
      AND p.proargnames && ARRAY['p_customer_id','p_customer_uuid']
      AND p.proname <> ALL(admitted) AND p.proname <> ALL(pg_temp.ra_unguarded())
    ORDER BY p.oid::regprocedure::text LOOP
    outcome := pg_temp.ra_outcome(format('SELECT public.%I(%s)', r.proname, r.arguments));
    IF outcome <> 'refused' THEN open := open || ' ' || r.proname || ' -> ' || left(outcome,70) || ';'; END IF;
  END LOOP;
  RETURN open;
END $$;

-- ---------------------------------------------------------------------------
-- 1. Catalog
-- ---------------------------------------------------------------------------
SELECT pg_temp.ra_assert(unclassified IS NULL, 'granted function is not classified in tests/role_allowlist.sql: '||unclassified)
FROM (SELECT string_agg(DISTINCT p.proname, ', ') AS unclassified FROM pg_proc p
  WHERE p.pronamespace='public'::regnamespace AND p.prokind='f' AND has_function_privilege('authenticated',p.oid,'EXECUTE')
    AND p.proname <> ALL(pg_temp.ra_unguarded()) AND NOT EXISTS (SELECT 1 FROM ra_rpc c WHERE c.name=p.proname)) q;
SELECT pg_temp.ra_assert(stale IS NULL, 'classified name is not a granted function any more: '||stale)
FROM (SELECT string_agg(c.name, ', ') AS stale FROM (SELECT name FROM ra_rpc UNION ALL SELECT unnest(pg_temp.ra_unguarded())) c
  WHERE NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname=c.name
    AND has_function_privilege('authenticated',p.oid,'EXECUTE'))) q;
-- A patch that replaces body text must not lose the guard call.
SELECT pg_temp.ra_assert(unguarded IS NULL, 'classified function does not call authorize_rpc: '||unguarded)
FROM (SELECT string_agg(p.oid::regprocedure::text, ', ') AS unguarded FROM pg_proc p JOIN ra_rpc c ON c.name=p.proname
  WHERE p.pronamespace='public'::regnamespace AND has_function_privilege('authenticated',p.oid,'EXECUTE')
    AND pg_get_functiondef(p.oid) !~ ('PERFORM\s+warehouse_security\.authorize_rpc\(\s*'||quote_literal(p.proname)||'\s*,')) q;
SELECT pg_temp.ra_assert((SELECT bool_and(pg_get_functiondef(p.oid) NOT LIKE '%authorize_rpc(%') FROM pg_proc p
  WHERE p.pronamespace='public'::regnamespace AND p.proname=ANY(pg_temp.ra_unguarded())
    AND has_function_privilege('authenticated',p.oid,'EXECUTE')),'the unguarded list names only functions without the guard');
SELECT pg_temp.ra_assert((SELECT array_agg(p.proname::text ORDER BY p.proname)=ARRAY['check_session','logout_session','refresh_jwt_token']
  FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND has_function_privilege('anon',p.oid,'EXECUTE')),
 'the anonymous function list is unchanged');
-- is_admin_or_supervisor() is true for staff as well, so it keeps staff out of
-- nothing. These are the granted functions that call it; the five that staff
-- may run are meant to treat staff like a supervisor, and the staff sweep
-- below proves the guard refuses the others. delete_dispatch_with_order_cleanup
-- left this list in migration 46: its body asks is_admin_or_supervisor_strict().
SELECT pg_temp.ra_assert((SELECT array_agg(DISTINCT p.proname::text ORDER BY p.proname::text)=ARRAY['assign_customer_to_user','create_customer','create_item',
    'delete_item_safe','get_item_wise_stock_list','get_order_change_log',
    'get_order_with_items','get_orders_list','remove_customer_assignment','search_customer_items_for_order',
    'update_customer','update_item']
  FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND has_function_privilege('authenticated',p.oid,'EXECUTE')
    AND pg_get_functiondef(p.oid) LIKE '%is_admin_or_supervisor()%'),
 'a granted function newly relies on is_admin_or_supervisor(), which admits staff: classify it here');
SELECT pg_temp.ra_assert((SELECT bool_and(c.staff = (c.name IN ('get_item_wise_stock_list','get_order_change_log',
    'get_order_with_items','get_orders_list','search_customer_items_for_order')))
  FROM ra_rpc c WHERE c.name IN ('assign_customer_to_user','create_customer','create_item',
    'delete_item_safe','get_item_wise_stock_list','get_order_change_log',
    'get_order_with_items','get_orders_list','remove_customer_assignment','search_customer_items_for_order',
    'update_customer','update_item')),'only the five order and stock reads among them are open to staff');
-- No report body takes the caller's role from the token any more.
SELECT pg_temp.ra_assert((SELECT bool_and(pg_get_functiondef(p.oid) NOT LIKE '%request.jwt.claims%'
    AND pg_get_functiondef(p.oid) LIKE '%warehouse_security.active_role()%')
  FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname IN ('get_customer_dispatch_activity',
    'get_customer_stock_summary','get_operations_dashboard','get_recent_dispatched_orders')),
 'the four report bodies read the role from the database');
SELECT pg_temp.ra_assert((SELECT count(*)=0 FROM pg_proc p WHERE p.pronamespace='public'::regnamespace
    AND has_function_privilege('authenticated',p.oid,'EXECUTE')
    AND pg_get_functiondef(p.oid) ~ 'request\.jwt\.claims[^;]*(user_role|user_metadata)'),
 'no granted function reads user_role from the token');
-- Tables.
SELECT pg_temp.ra_assert(NOT has_table_privilege('anon','public.printer_status','SELECT')
  AND has_table_privilege('authenticated','public.printer_status','SELECT')
  AND has_table_privilege('anon','public.feature_flags','SELECT'),
 'printer_status needs a sign-in; feature_flags stays public');
SELECT pg_temp.ra_assert((SELECT count(*)=1 AND bool_and(cmd='SELECT' AND roles='{authenticated}')
  FROM pg_policies WHERE schemaname='public' AND tablename='orders' AND policyname='starter_order_staff_read'),
 'staff order policy is read-only');
SELECT pg_temp.ra_assert(has_function_privilege('authenticated','warehouse_security.image_file_unreferenced(text,text)','EXECUTE')
  AND NOT has_function_privilege('anon','warehouse_security.image_file_unreferenced(text,text)','EXECUTE')
  AND has_function_privilege('authenticated','warehouse_security.staff_may_remove_image_file(text,text)','EXECUTE')
  AND NOT has_function_privilege('anon','warehouse_security.staff_may_remove_image_file(text,text)','EXECUTE'),
 'the storage helpers are for signed-in sessions only');
SELECT pg_temp.ra_assert((SELECT count(*)=2 AND bool_and(qual LIKE '%staff_may_remove_image_file(bucket_id, name)%')
  FROM pg_policies WHERE schemaname='storage' AND tablename='objects'
    AND policyname IN ('starter_staff_removed_image_read','starter_staff_removed_image_delete')),
 'both staff photo-removal policies use the narrowed helper');

-- ---------------------------------------------------------------------------
-- Fixture accounts and documents
-- ---------------------------------------------------------------------------
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888888931','Role Matrix Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888932','Role Matrix Second Admin','admin',true,'approved'),
 (gen_random_uuid(),'919888888933','Role Matrix Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919888888934','Role Matrix Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888935','Role Matrix Two Customers','customer',true,'approved'),
 (gen_random_uuid(),'919888888936','Role Matrix Former Staff','staff',false,'disabled'),
 (gen_random_uuid(),'919888888937','Role Matrix Managed Person','customer',true,'approved'),
 (gen_random_uuid(),'919888888938','Role Matrix Rejected Request','customer',false,'rejected'),
 (gen_random_uuid(),'919888888939','Role Matrix Pending Request','customer',false,'pending');
SELECT id AS admin2_profile FROM public.user_profiles WHERE mobile='919888888932' \gset
SELECT id AS supervisor_profile FROM public.user_profiles WHERE mobile='919888888933' \gset
SELECT id AS staff_profile FROM public.user_profiles WHERE mobile='919888888934' \gset
SELECT id AS managed_profile FROM public.user_profiles WHERE mobile='919888888937' \gset
SELECT id AS rejected_profile FROM public.user_profiles WHERE mobile='919888888938' \gset
SELECT id AS pending_profile FROM public.user_profiles WHERE mobile='919888888939' \gset
SELECT pg_temp.ra_login('9888888931') AS admin_claims \gset
SELECT pg_temp.ra_login('9888888933') AS supervisor_claims \gset
SELECT pg_temp.ra_login('9888888934') AS staff_claims \gset
SELECT pg_temp.ra_login('9888888935') AS customer_claims \gset

-- Documents, written by the administrator through the RPCs.
--   Alpha  receipt RMA 30 bags (5 dispatched on RMDA), receipt RMX
--   Beta   receipt RMB 20 bags
--   Gamma  receipt RMG 10 bags (2 dispatched on RMDG)
-- The customer login is assigned to Alpha and Beta, never to Gamma.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ra_assert(warehouse_security.active_role()='admin','actual administrator role');
SELECT pg_temp.ra_assert(public.create_customer('Role Matrix Alpha','9888888941')->>'success'='true','customer Alpha');
SELECT pg_temp.ra_assert(public.create_customer('Role Matrix Beta','9888888942')->>'success'='true','customer Beta');
SELECT pg_temp.ra_assert(public.create_customer('Role Matrix Gamma','9888888943')->>'success'='true','customer Gamma');
SELECT pg_temp.ra_assert(public.create_item('Role Matrix Rice','Bag')->>'success'='true','catalog item');
SELECT id AS alpha FROM public.customers WHERE name='Role Matrix Alpha' \gset
SELECT id AS beta FROM public.customers WHERE name='Role Matrix Beta' \gset
SELECT id AS gamma FROM public.customers WHERE name='Role Matrix Gamma' \gset
SELECT id AS item_id FROM public.items WHERE name='Role Matrix Rice' \gset
SELECT pg_temp.ra_assert(public.assign_customer_to_user('919888888935',:'alpha'::uuid,'Role matrix fixture')
  AND public.assign_customer_to_user('919888888935',:'beta'::uuid,'Role matrix fixture'),'customer login assigned to Alpha and Beta');
SELECT pg_temp.ra_assert(public.create_item_storage_price(p_item_id=>:'item_id'::uuid,p_price_type=>'monthly',p_unit_price=>5,
 p_weight_min=>0,p_weight_max=>100,p_labour_rate=>2,p_effective_from=>'2026-01-01',
 p_customer_id=>:'gamma'::uuid,p_tax_percent=>5)->>'success'='true','Gamma''s monthly price');
SELECT pg_temp.ra_assert(public.save_grn(p_gr_no=>'RM'||c.code,p_date=>'2026-04-01T12:00:00Z',p_customer_id=>c.id,
 p_customer_name=>'Role Matrix '||c.label,p_supervisor_id=>:'supervisor_profile'::uuid,p_supervisor_name=>'Role Matrix Supervisor',
 p_pricing_mode=>'MONTHLY',p_idempotency_key=>'role-matrix-'||c.code,
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Role Matrix Rice',
 'packaging','Bag','qty',c.qty,'weight',10,'rack','R'||c.code)))->>'success'='true','receipt RM'||c.code)
FROM (VALUES ('A',:'alpha'::uuid,'Alpha',30),('X',:'alpha'::uuid,'Alpha',4),('B',:'beta'::uuid,'Beta',20),('G',:'gamma'::uuid,'Gamma',10)) c(code,id,label,qty);
SELECT id AS grn_a FROM public.goodsreceived WHERE gr_no='RMA' \gset
SELECT id AS grn_x FROM public.goodsreceived WHERE gr_no='RMX' \gset
SELECT id AS grn_g FROM public.goodsreceived WHERE gr_no='RMG' \gset
SELECT id AS lot_a FROM public.goodsreceived_trl WHERE gr_id=:'grn_a'::uuid \gset
SELECT id AS lot_g FROM public.goodsreceived_trl WHERE gr_id=:'grn_g'::uuid \gset
SELECT pg_temp.ra_assert(public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','RMDA','disp_date',(CURRENT_DATE-1)::text||'T12:00:00Z',
 'customer_id',:'alpha','customer_name','Role Matrix Alpha','supervisor_id',:'supervisor_profile','supervisor_name','Role Matrix Supervisor'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a','disp_qty',5)],0,'role-matrix-dispatch-a')->>'success'='true','dispatch RMDA');
SELECT pg_temp.ra_assert(public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','RMDG','disp_date',(CURRENT_DATE-1)::text||'T12:00:00Z',
 'customer_id',:'gamma','customer_name','Role Matrix Gamma','supervisor_id',:'supervisor_profile','supervisor_name','Role Matrix Supervisor'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_g','disp_qty',2)],0,'role-matrix-dispatch-g')->>'success'='true','dispatch RMDG');
SELECT id AS dispatch_a FROM public.dispatch WHERE disp_no='RMDA' \gset
SELECT id AS dispatch_g FROM public.dispatch WHERE disp_no='RMDG' \gset
SELECT public.get_or_create_cart(:'alpha'::uuid) AS cart_a \gset
SELECT public.get_or_create_cart(:'gamma'::uuid) AS cart_g \gset
-- Photos: RMA has two confirmed header photos and one upload the supervisor
-- has registered but not confirmed; RMX (deleted below) and RMDA one each.
SELECT public.register_grn_image_upload(:'grn_a'::uuid,'header','a-one.webp',32,'image/webp') AS img_a1 \gset
SELECT public.register_grn_image_upload(:'grn_a'::uuid,'header','a-two.webp',32,'image/webp') AS img_a2 \gset
SELECT public.register_grn_image_upload(:'grn_x'::uuid,'header','x-one.webp',32,'image/webp') AS img_x \gset
SELECT public.register_dispatch_image_upload(:'dispatch_a'::uuid,'a-truck.webp',32,'image/webp') AS img_da \gset
RESET ROLE;
INSERT INTO storage.objects(bucket_id,name) VALUES
 ('grn-images',:'img_a1'::jsonb->>'storage_path'),('grn-images',:'img_a2'::jsonb->>'storage_path'),
 ('grn-images',:'img_x'::jsonb->>'storage_path'),('dispatch-images',:'img_da'::jsonb->>'storage_path');
SET LOCAL ROLE authenticated;
SELECT pg_temp.ra_assert(public.confirm_grn_image_upload((:'img_a1'::jsonb->>'image_id')::uuid,(:'img_a1'::jsonb->>'upload_token')::uuid)->>'success'='true'
 AND public.confirm_grn_image_upload((:'img_a2'::jsonb->>'image_id')::uuid,(:'img_a2'::jsonb->>'upload_token')::uuid)->>'success'='true'
 AND public.confirm_grn_image_upload((:'img_x'::jsonb->>'image_id')::uuid,(:'img_x'::jsonb->>'upload_token')::uuid)->>'success'='true'
 AND public.confirm_dispatch_image_upload((:'img_da'::jsonb->>'image_id')::uuid,(:'img_da'::jsonb->>'upload_token')::uuid)->>'success'='true',
 'fixture photos confirmed');
RESET ROLE;
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.register_grn_image_upload(:'grn_a'::uuid,'header','a-pending.webp',32,'image/webp') AS img_pending \gset
RESET ROLE;
INSERT INTO storage.objects(bucket_id,name) VALUES ('grn-images',:'img_pending'::jsonb->>'storage_path');
UPDATE public.goodsreceived SET deleted_at=now() WHERE id=:'grn_x'::uuid;
-- Files no image row names that staff must not reach (migration 47): in the
-- folder of the deleted receipt, outside any document folder, in the folder of
-- a dispatch that does not exist, and one the legacy header column of RMA names.
SELECT 'headers/'||:'grn_x'||'/left-behind.webp' AS orphan_deleted, 'stray/left-behind.webp' AS orphan_stray,
       gen_random_uuid()::text||'/left-behind.webp' AS orphan_dispatch, 'headers/'||:'grn_a'||'/legacy.webp' AS orphan_legacy \gset
INSERT INTO storage.objects(bucket_id,name) VALUES ('grn-images',:'orphan_deleted'),('grn-images',:'orphan_stray'),
 ('dispatch-images',:'orphan_dispatch'),('grn-images',:'orphan_legacy');
UPDATE public.goodsreceived SET gr_image_url=:'orphan_legacy' WHERE id=:'grn_a'::uuid;
SELECT set_config('test.protected_orphans',:'orphan_deleted'||','||:'orphan_stray'||','||:'orphan_dispatch'||','||:'orphan_legacy',true);
INSERT INTO public.sensor_devices(device_name,mac_address,location) VALUES ('Role Matrix Chamber','AA:BB:CC:00:00:45','Chamber 1');
SELECT id AS sensor_id FROM public.sensor_devices WHERE device_name='Role Matrix Chamber' \gset
INSERT INTO public.printer_status(printer_name,status,last_error) VALUES ('role-matrix-printer','error','fictional error text');
SELECT (SELECT count(*) FROM public.orders) AS orders_total,
       (SELECT count(*) FROM public.item_storage_prices) AS prices_total \gset

-- ---------------------------------------------------------------------------
-- 2. Customer account (assigned to Alpha and Beta)
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'customer_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ra_assert(warehouse_security.active_role()='customer','actual customer role');
-- The sweep: every function that is not open to every signed-in account is
-- refused without a customer or document of the account. This covers every
-- all-customers report, pricing, sensors, user management and every write.
SELECT pg_temp.ra_assert(pg_temp.ra_not_refused(ARRAY(SELECT name FROM ra_rpc WHERE customer='any')||pg_temp.ra_id_checked_first())='',
 'customer is not refused:'||pg_temp.ra_not_refused(ARRAY(SELECT name FROM ra_rpc WHERE customer='any')||pg_temp.ra_id_checked_first()));
SELECT pg_temp.ra_assert(pg_temp.ra_not_refused(ARRAY(SELECT name FROM ra_rpc WHERE customer='any'),true)='',
 'customer is not refused with unknown ids:'||pg_temp.ra_not_refused(ARRAY(SELECT name FROM ra_rpc WHERE customer='any'),true));
SELECT pg_temp.ra_assert(public.get_customer_dispatch_list(NULL)->>'success'='false' AND public.get_customer_dispatch_list(NULL)->'data'='null'
 AND public.get_customer_grn_items(NULL)->>'success'='false' AND public.get_customer_grn_items(NULL)->'data'='null'
 AND public.get_grn_item_dispatches(NULL)->>'success'='false' AND NOT public.get_grn_item_dispatches(NULL) ? 'data',
 'the three id-first list RPCs answer a missing id with no data');
-- ... and with another customer's id in every customer argument.
SELECT pg_temp.ra_assert(pg_temp.ra_not_refused_for(:'gamma'::uuid,ARRAY(SELECT name FROM ra_rpc WHERE customer='any'))='',
 'customer is not refused for another customer:'||pg_temp.ra_not_refused_for(:'gamma'::uuid,ARRAY(SELECT name FROM ra_rpc WHERE customer='any')));
-- Named, because these are the calls the app makes for an account with
-- several customers and they must stay refused (the app has to change).
SELECT pg_temp.ra_assert(bool_and(pg_temp.ra_refused(statement)),'customer refused: '||string_agg(statement,' | ') FILTER (WHERE NOT pg_temp.ra_refused(statement)))
FROM (VALUES ('SELECT public.get_all_stock_summary()'),
  ('SELECT public.get_all_customer_activity_summary(CURRENT_DATE-30,CURRENT_DATE)'),
  ('SELECT public.get_all_dispatch_activity(CURRENT_DATE-30,CURRENT_DATE)'),
  ('SELECT public.get_all_grn_activity(CURRENT_DATE-30,CURRENT_DATE)'),
  ('SELECT public.get_customer_invoice_summary()'),
  ('SELECT public.get_stock_aging_report()'),
  ('SELECT public.get_item_wise_stock_list()'),
  ('SELECT public.get_item_storage_prices()'),
  ('SELECT public.get_sensor_polling_data()'),
  ('SELECT public.get_operations_dashboard(CURRENT_DATE-30,CURRENT_DATE)'),
  ('SELECT public.get_users_list()'),
  ('SELECT public.get_supervisors()')) s(statement);
SELECT pg_temp.ra_assert(pg_temp.ra_refused(format('SELECT public.get_sensor_history(%L::uuid,7)',:'sensor_id'))
 AND pg_temp.ra_refused(format('SELECT public.find_or_create_item_storage_price(%L::uuid,%L::uuid,10,''monthly'')',:'item_id',:'alpha'))
 AND pg_temp.ra_refused(format('SELECT public.delete_grn_image(%L::uuid)',:'img_a1'::jsonb->>'image_id'))
 AND pg_temp.ra_refused(format('SELECT public.update_user_role(%L::uuid,''staff''::public.user_role)',:'managed_profile')),
 'customer refused on sensors, pricing, photo removal and user management');
-- The per-customer calls the app should make instead work for each assigned
-- customer and return that customer only.
SELECT pg_temp.ra_assert(public.get_stock_aging_report(:'alpha'::uuid)->>'success'='true'
 AND public.get_stock_aging_report(:'alpha'::uuid)::text LIKE '%RMA%'
 AND public.get_stock_aging_report(:'alpha'::uuid)::text NOT LIKE '%RMB%'
 AND public.get_stock_aging_report(:'alpha'::uuid)::text NOT LIKE '%RMG%'
 AND public.get_stock_aging_report(:'beta'::uuid)::text LIKE '%RMB%'
 AND public.get_stock_aging_report(:'beta'::uuid)::text NOT LIKE '%RMA%',
 'customer runs the aging report for each own customer: '||public.get_stock_aging_report(:'alpha'::uuid)::text);
SELECT pg_temp.ra_assert(public.get_item_wise_stock_list(:'alpha'::uuid)->>'success'='true'
 AND (public.get_item_wise_stock_list(:'alpha'::uuid)#>>'{data,total_count}')::int=1
 AND public.get_item_wise_stock_list(:'beta'::uuid)->>'success'='true',
 'customer runs the item-wise stock list for each own customer: '||public.get_item_wise_stock_list(:'alpha'::uuid)::text);
SELECT pg_temp.ra_assert(public.get_customer_stock_summary(:'alpha'::uuid) ? 'summary'
 AND NOT public.get_customer_stock_summary(:'alpha'::uuid) ? 'error'
 AND NOT public.get_customer_dispatch_activity(:'alpha'::uuid,CURRENT_DATE-30,CURRENT_DATE) ? 'error'
 AND public.get_customer_dispatch_activity(:'alpha'::uuid,CURRENT_DATE-30,CURRENT_DATE)::text LIKE '%RMDA%'
 AND public.get_customer_activity_detail(:'beta'::uuid,CURRENT_DATE-30,CURRENT_DATE)->>'success'='true'
 AND public.get_customer_grn_activity(:'beta'::uuid,CURRENT_DATE-30,CURRENT_DATE)->>'success'='true'
 AND public.get_customer_invoice_summary(:'alpha'::uuid)->>'success'='true',
 'customer runs the per-customer reports for own customers');
-- Supervisor contact: the name, not the mobile number or the role.
SELECT public.get_grn_details(:'grn_a'::uuid)#>'{data,grn,supervisor_details}' AS customer_grn_supervisor \gset
SELECT public.get_dispatch_details(:'dispatch_a'::uuid)#>'{data,dispatch,supervisor_details}' AS customer_dispatch_supervisor \gset
SELECT pg_temp.ra_assert(:'customer_grn_supervisor'::jsonb->>'name'='Role Matrix Supervisor'
 AND :'customer_grn_supervisor'::jsonb ? 'id' AND NOT :'customer_grn_supervisor'::jsonb ? 'mobile'
 AND NOT :'customer_grn_supervisor'::jsonb ? 'role',
 'customer sees the receipt supervisor by name only: '||:'customer_grn_supervisor');
SELECT pg_temp.ra_assert(:'customer_dispatch_supervisor'::jsonb->>'name'='Role Matrix Supervisor'
 AND NOT :'customer_dispatch_supervisor'::jsonb ? 'mobile' AND NOT :'customer_dispatch_supervisor'::jsonb ? 'role',
 'customer sees the dispatch supervisor by name only: '||:'customer_dispatch_supervisor');
SELECT pg_temp.ra_assert(public.get_grn_details(:'grn_a'::uuid)::text NOT LIKE '%919888888933%'
 AND public.get_dispatch_details(:'dispatch_a'::uuid)::text NOT LIKE '%919888888933%',
 'the supervisor''s number is nowhere in the customer''s answers');
SELECT pg_temp.ra_assert((SELECT count(*)=0 FROM public.printer_status),'customer reads no printer status');
SELECT pg_temp.ra_assert((SELECT count(*)=1 AND bool_and(id=:'cart_a'::uuid) FROM public.orders),'customer reads only the own customers'' orders');
SELECT pg_temp.ra_assert((SELECT count(*)=0 FROM storage.objects WHERE name=:'img_pending'::jsonb->>'storage_path'),
 'customer does not read a pending file');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- 3. Staff
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ra_assert(warehouse_security.active_role()='staff','actual staff role');
-- Everything outside the staff allowlist is refused: user management, the
-- operations dashboard, catalog and customer administration, the deletes.
SELECT pg_temp.ra_assert(pg_temp.ra_not_refused(ARRAY(SELECT name FROM ra_rpc WHERE staff))='',
 'staff are not refused:'||pg_temp.ra_not_refused(ARRAY(SELECT name FROM ra_rpc WHERE staff)));
SELECT pg_temp.ra_assert(pg_temp.ra_not_refused(ARRAY(SELECT name FROM ra_rpc WHERE staff),true)='',
 'staff are not refused with unknown ids:'||pg_temp.ra_not_refused(ARRAY(SELECT name FROM ra_rpc WHERE staff),true));
SELECT pg_temp.ra_assert(bool_and(pg_temp.ra_refused(statement)),'staff refused: '||string_agg(statement,' | ') FILTER (WHERE NOT pg_temp.ra_refused(statement)))
FROM (VALUES (format('SELECT public.update_user_role(%L::uuid,''staff''::public.user_role)',:'managed_profile')),
  (format('SELECT public.update_user_status(%L::uuid,false)',:'managed_profile')),
  (format('SELECT public.assign_customer_to_user(''919888888937'',%L::uuid)',:'gamma')),
  (format('SELECT public.remove_customer_assignment(''919888888935'',%L::uuid)',:'alpha')),
  ('SELECT public.get_users_list()'),
  (format('SELECT public.get_user_details(%L::uuid)',:'managed_profile')),
  ('SELECT public.get_operations_dashboard(CURRENT_DATE-30,CURRENT_DATE)')) s(statement);
-- Reports: the all-customers variants and the per-customer drill-down.
SELECT pg_temp.ra_assert(public.get_all_stock_summary()->>'success'='true'
 AND public.get_all_stock_summary()::text LIKE '%Role Matrix Alpha%'
 AND public.get_all_stock_summary()::text LIKE '%Role Matrix Gamma%',
 'staff run the all-customers stock summary: '||public.get_all_stock_summary()::text);
SELECT pg_temp.ra_assert(public.get_customer_stock_summary(:'gamma'::uuid) ? 'summary'
 AND NOT public.get_customer_stock_summary(:'gamma'::uuid) ? 'error',
 'staff run one customer''s stock summary: '||public.get_customer_stock_summary(:'gamma'::uuid)::text);
SELECT pg_temp.ra_assert(public.get_all_customer_activity_summary(CURRENT_DATE-30,CURRENT_DATE)->>'success'='true'
 AND public.get_customer_activity_detail(:'gamma'::uuid,CURRENT_DATE-30,CURRENT_DATE)->>'success'='true',
 'staff run the customer activity report and its drill-down: '||public.get_customer_activity_detail(:'gamma'::uuid,CURRENT_DATE-30,CURRENT_DATE)::text);
SELECT pg_temp.ra_assert(NOT public.get_customer_dispatch_activity(:'gamma'::uuid,CURRENT_DATE-30,CURRENT_DATE) ? 'error'
 AND public.get_customer_dispatch_activity(:'gamma'::uuid,CURRENT_DATE-30,CURRENT_DATE)::text LIKE '%RMDG%',
 'staff run one customer''s dispatch activity: '||public.get_customer_dispatch_activity(:'gamma'::uuid,CURRENT_DATE-30,CURRENT_DATE)::text);
SELECT pg_temp.ra_assert(public.get_stock_aging_report()->>'success'='true'
 AND public.get_stock_aging_report()::text LIKE '%Role Matrix Alpha%' AND public.get_stock_aging_report()::text LIKE '%Role Matrix Gamma%'
 AND (public.get_stock_aging_report()#>>'{data,summary,total_customers}')::int=3
 AND public.get_stock_aging_report(:'gamma'::uuid)->>'success'='true'
 AND public.get_stock_aging_report(:'gamma'::uuid)::text LIKE '%RMG%'
 AND public.get_stock_aging_report(:'gamma'::uuid)::text NOT LIKE '%RMA%',
 'staff run the aging report for all customers and for one');
SELECT pg_temp.ra_assert(public.get_item_wise_stock_list()->>'success'='true'
 AND (public.get_item_wise_stock_list()#>>'{data,total_count}')::int>=1
 AND public.get_item_wise_stock_list(:'gamma'::uuid)->>'success'='true',
 'staff run the item-wise stock list: '||public.get_item_wise_stock_list()::text);
SELECT pg_temp.ra_assert(public.get_all_dispatch_activity(CURRENT_DATE-30,CURRENT_DATE)->>'success'='true'
 AND public.get_all_grn_activity(CURRENT_DATE-30,CURRENT_DATE)->>'success'='true'
 AND public.get_customer_invoice_summary()->>'success'='true','the reports staff already had still answer');
-- Sensors.
SELECT pg_temp.ra_assert(public.get_sensor_polling_data()->>'success'='true'
 AND public.get_sensor_polling_data()::text LIKE '%Role Matrix Chamber%',
 'staff read the sensor list: '||public.get_sensor_polling_data()::text);
SELECT pg_temp.ra_assert(public.get_sensor_history(:'sensor_id'::uuid,7)->>'success'='true',
 'staff read a sensor''s history: '||public.get_sensor_history(:'sensor_id'::uuid,7)::text);
-- Item pricing: read, and the write path of the pricing form. Staff can now
-- change prices (material change, docs/STAFF_GRN_POLICY.md).
SELECT public.get_item_storage_prices() AS staff_prices \gset
SELECT pg_temp.ra_assert(:'staff_prices'::jsonb->>'success'='true' AND :'staff_prices'::jsonb::text LIKE '%Role Matrix Rice%',
 'staff read the price list: '||:'staff_prices');
SELECT public.create_item_storage_price(p_item_id=>:'item_id'::uuid,p_price_type=>'monthly',p_unit_price=>7,
 p_weight_min=>0,p_weight_max=>100,p_labour_rate=>1,p_effective_from=>'2026-01-01',
 p_customer_id=>:'alpha'::uuid,p_tax_percent=>5) AS staff_price \gset
SELECT pg_temp.ra_assert(:'staff_price'::jsonb->>'success'='true','staff add a price: '||:'staff_price');
RESET ROLE;
SELECT id AS alpha_price FROM public.item_storage_prices WHERE customer_id=:'alpha'::uuid \gset
SELECT id AS gamma_price FROM public.item_storage_prices WHERE customer_id=:'gamma'::uuid \gset
SET LOCAL ROLE authenticated;
SELECT public.update_item_storage_price(p_id=>:'alpha_price'::uuid,p_unit_price=>8,p_weight_min=>0,p_weight_max=>100,
 p_labour_rate=>1,p_tax_percent=>5,p_effective_from=>'2026-01-01',p_effective_to=>NULL) AS staff_price_update \gset
SELECT pg_temp.ra_assert(:'staff_price_update'::jsonb->>'success'='true','staff change a price: '||:'staff_price_update');
SELECT public.find_or_create_item_storage_price(:'item_id'::uuid,:'beta'::uuid,10,'monthly') AS staff_price_found \gset
SELECT pg_temp.ra_assert(:'staff_price_found'::jsonb->>'success'='true','staff find or create a price: '||:'staff_price_found');
SELECT public.delete_item_storage_price(:'gamma_price'::uuid) AS staff_price_delete \gset
SELECT pg_temp.ra_assert(:'staff_price_delete'::jsonb->>'success'='true','staff delete a price: '||:'staff_price_delete');
RESET ROLE;
SELECT pg_temp.ra_assert((SELECT unit_price=8 FROM public.item_storage_prices WHERE id=:'alpha_price'::uuid)
 AND (SELECT count(*)=0 FROM public.item_storage_prices WHERE id=:'gamma_price'::uuid)
 AND (SELECT count(*)=1 FROM public.item_storage_prices WHERE customer_id=:'beta'::uuid),
 'the staff price changes are stored');
SET LOCAL ROLE authenticated;
SELECT pg_temp.ra_assert((SELECT count(*)=0 FROM public.item_storage_prices),'the price table itself stays closed to staff; prices are read through the RPC');
-- The order queue: staff read every order row (what Realtime checks), still
-- without a direct write.
SELECT pg_temp.ra_assert((SELECT count(*)=:orders_total AND count(*)>=2 FROM public.orders),'staff read every order');
SELECT pg_temp.ra_assert(pg_temp.ra_call(format('WITH changed AS (UPDATE public.orders SET note=''x'' WHERE id=%L RETURNING id) SELECT to_jsonb(count(*)) FROM changed',:'cart_a'))->>'state'='42501',
 'staff cannot write an order directly');
SELECT pg_temp.ra_assert((SELECT count(*)=1 FROM public.printer_status WHERE printer_name='role-matrix-printer'),'staff read the printer status');
-- Supervisor contact details stay complete for warehouse roles.
SELECT pg_temp.ra_assert(public.get_grn_details(:'grn_a'::uuid)#>>'{data,grn,supervisor_details,mobile}'='919888888933'
 AND public.get_grn_details(:'grn_a'::uuid)#>>'{data,grn,supervisor_details,role}'='supervisor'
 AND public.get_dispatch_details(:'dispatch_a'::uuid)#>>'{data,dispatch,supervisor_details,mobile}'='919888888933',
 'staff still receive the supervisor''s number and role');
-- The picker lists active profiles only.
SELECT public.get_supervisors() AS picker \gset
SELECT pg_temp.ra_assert(:'picker'::jsonb->>'success'='true' AND :'picker'::jsonb::text LIKE '%Role Matrix Supervisor%'
 AND :'picker'::jsonb::text LIKE '%Role Matrix Staff%' AND :'picker'::jsonb::text NOT LIKE '%Role Matrix Former Staff%',
 'the supervisor picker leaves out a deactivated profile: '||:'picker');
-- Staff pick a colleague by name; the mobile number is not in their answer (migration 47).
SELECT pg_temp.ra_assert(:'picker'::text NOT LIKE '%9198888889%'
 AND (SELECT bool_and(NOT person ? 'phone' AND NOT person ? 'mobile' AND person ?& ARRAY['id','name','display_name','role'])
        AND count(*)>=4 FROM jsonb_array_elements(:'picker'::jsonb->'data') AS person)
 AND (SELECT person->>'role'='supervisor' FROM jsonb_array_elements(:'picker'::jsonb->'data') AS person WHERE person->>'name'='Role Matrix Supervisor'),
 'staff receive id, name, display_name and role of each colleague and no mobile number: '||:'picker');
-- Photo removal. Refused: a photo of a deleted receipt, and an upload another
-- person has registered and not confirmed.
SELECT pg_temp.ra_assert(pg_temp.ra_refused(format('SELECT public.delete_grn_image(%L::uuid)',:'img_x'::jsonb->>'image_id')),
 'staff cannot remove a photo of a deleted receipt');
SELECT pg_temp.ra_assert(pg_temp.ra_refused(format('SELECT public.delete_grn_image(%L::uuid)',:'img_pending'::jsonb->>'image_id')),
 'staff cannot remove another person''s pending upload');
SELECT pg_temp.ra_assert(public.delete_grn_image(gen_random_uuid())->>'success'='false'
 AND NOT pg_temp.ra_refused(format('SELECT public.delete_grn_image(%L::uuid)',gen_random_uuid())),
 'an unknown photo id is answered as not found, not as a refusal');
-- Before the row is removed its file cannot be deleted by staff. Neither can
-- an unnamed file of a deleted receipt, of no document, or one the legacy
-- header column names; staff do not see those files either.
DO $$ DECLARE affected integer; BEGIN
 DELETE FROM storage.objects WHERE bucket_id IN ('grn-images','dispatch-images'); GET DIAGNOSTICS affected=ROW_COUNT;
 PERFORM pg_temp.ra_assert(affected=0,'staff cannot delete a file an image row still names, nor a file outside a live document, deleted '||affected);
 PERFORM pg_temp.ra_assert((SELECT count(*)=0 FROM storage.objects WHERE name=ANY(string_to_array(current_setting('test.protected_orphans'),','))),
  'staff cannot read an unnamed file of a deleted receipt or outside a document folder');
END $$;
SELECT public.delete_grn_image((:'img_a1'::jsonb->>'image_id')::uuid) AS removed_grn_photo \gset
SELECT pg_temp.ra_assert(:'removed_grn_photo'::jsonb->>'success'='true'
 AND :'removed_grn_photo'::jsonb#>>'{data,storage_path}'=:'img_a1'::jsonb->>'storage_path',
 'staff remove a confirmed receipt photo and get its path: '||:'removed_grn_photo');
SELECT public.delete_dispatch_image((:'img_da'::jsonb->>'image_id')::uuid) AS removed_dispatch_photo \gset
SELECT pg_temp.ra_assert(:'removed_dispatch_photo'::jsonb->>'success'='true'
 AND :'removed_dispatch_photo'::jsonb#>>'{data,storage_path}'=:'img_da'::jsonb->>'storage_path',
 'staff remove a confirmed dispatch photo: '||:'removed_dispatch_photo');
-- Now the two files belong to no row: staff can remove exactly those.
SELECT set_config('test.removed_paths',(:'img_a1'::jsonb->>'storage_path')||','||(:'img_da'::jsonb->>'storage_path'),true);
DO $$ DECLARE affected integer; BEGIN
 UPDATE storage.objects SET name=name; GET DIAGNOSTICS affected=ROW_COUNT;
 PERFORM pg_temp.ra_assert(affected=0,'staff cannot overwrite any stored file');
 DELETE FROM storage.objects WHERE bucket_id IN ('grn-images','dispatch-images'); GET DIAGNOSTICS affected=ROW_COUNT;
 PERFORM pg_temp.ra_assert(affected=2,'staff delete the files of the two removed photos and no other, deleted '||affected);
END $$;
RESET ROLE;
SELECT pg_temp.ra_assert((SELECT count(*)=0 FROM storage.objects WHERE name=ANY(string_to_array(current_setting('test.removed_paths'),',')))
 AND (SELECT count(*)=3 FROM storage.objects WHERE name IN (:'img_a2'::jsonb->>'storage_path',:'img_x'::jsonb->>'storage_path',:'img_pending'::jsonb->>'storage_path'))
 AND (SELECT count(*)=4 FROM storage.objects WHERE name=ANY(string_to_array(current_setting('test.protected_orphans'),',')))
 AND (SELECT count(*)=0 FROM public.grn_images WHERE id=(:'img_a1'::jsonb->>'image_id')::uuid)
 AND (SELECT count(*)=0 FROM public.dispatch_images WHERE id=(:'img_da'::jsonb->>'image_id')::uuid)
 AND (SELECT count(*)=3 FROM public.grn_images WHERE id IN ((:'img_a2'::jsonb->>'image_id')::uuid,(:'img_x'::jsonb->>'image_id')::uuid,(:'img_pending'::jsonb->>'image_id')::uuid)),
 'the removed photos are gone, row and file; the others are untouched');

-- ---------------------------------------------------------------------------
-- 4. A stale or forged role claim in the token changes nothing
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',(:'customer_claims'::jsonb||jsonb_build_object('user_role','admin',
 'user_metadata',jsonb_build_object('role','admin')))::text,true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ra_assert(pg_temp.ra_refused(format('SELECT public.get_customer_stock_summary(%L::uuid)',:'gamma'))
 AND pg_temp.ra_refused(format('SELECT public.get_customer_dispatch_activity(%L::uuid,CURRENT_DATE-30,CURRENT_DATE)',:'gamma'))
 AND pg_temp.ra_refused('SELECT public.get_operations_dashboard(CURRENT_DATE-30,CURRENT_DATE)')
 AND pg_temp.ra_refused('SELECT public.get_recent_dispatched_orders(10,0)'),
 'a customer session with an administrator claim is still a customer');
-- The storage helpers answer staff only (migration 47): nobody else learns from
-- them whether a path is in use.
SELECT pg_temp.ra_assert(NOT warehouse_security.staff_may_remove_image_file('grn-images','headers/'||:'grn_a'||'/never-uploaded.webp')
 AND NOT warehouse_security.image_file_unreferenced('grn-images','headers/'||:'grn_a'||'/never-uploaded.webp'),
 'a customer account gets false from the storage helpers for a free path in a live folder');
RESET ROLE;
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ra_assert(warehouse_security.staff_may_remove_image_file('grn-images','headers/'||:'grn_a'||'/never-uploaded.webp')
 AND warehouse_security.image_file_unreferenced('grn-images','headers/'||:'grn_a'||'/never-uploaded.webp')
 AND warehouse_security.staff_may_remove_image_file('grn-images','items/'||:'grn_a'||'/never-uploaded.webp')
 AND warehouse_security.staff_may_remove_image_file('dispatch-images',:'dispatch_a'||'/never-uploaded.webp')
 AND NOT warehouse_security.staff_may_remove_image_file('grn-images','headers/'||:'grn_x'||'/never-uploaded.webp')
 AND NOT warehouse_security.staff_may_remove_image_file('grn-images','headers/'||:'grn_a')
 AND NOT warehouse_security.staff_may_remove_image_file('grn-images','other/'||:'grn_a'||'/never-uploaded.webp')
 AND NOT warehouse_security.staff_may_remove_image_file('dispatch-images','headers/'||:'grn_a'||'/never-uploaded.webp')
 AND NOT warehouse_security.staff_may_remove_image_file('grn-images',:'img_a2'::jsonb->>'storage_path')
 AND NOT warehouse_security.staff_may_remove_image_file('customer-images',:'grn_a'||'/never-uploaded.webp'),
 'for staff a free path counts only inside the folder of a live receipt or dispatch');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- 5. Supervisor: user management for other people who are not administrators
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ra_assert(warehouse_security.active_role()='supervisor','actual supervisor role');
-- The picker keeps the mobile number for supervisors and administrators.
SELECT pg_temp.ra_assert((SELECT person->>'phone'='919888888934' AND person->>'role'='staff'
  FROM jsonb_array_elements(public.get_supervisors()->'data') AS person WHERE person->>'name'='Role Matrix Staff'),
 'a supervisor still receives a colleague''s mobile number from the picker');
SELECT public.get_users_list() AS supervisor_users \gset
SELECT pg_temp.ra_assert(:'supervisor_users'::jsonb->>'success'='true'
 AND :'supervisor_users'::jsonb::text LIKE '%Role Matrix Managed Person%'
 AND :'supervisor_users'::jsonb::text NOT LIKE '%Role Matrix Second Admin%',
 'supervisor lists users without the administrators');
SELECT pg_temp.ra_assert(public.get_user_details(:'managed_profile'::uuid)->>'success'='true'
 AND public.get_user_details(:'admin2_profile'::uuid)->>'success'='false',
 'supervisor opens a user, not an administrator');
-- Reports: a supervisor runs every one, the operations dashboard included.
SELECT public.get_operations_dashboard(CURRENT_DATE-30,CURRENT_DATE) AS supervisor_dashboard \gset
SELECT pg_temp.ra_assert(:'supervisor_dashboard'::jsonb ? 'kpis' AND :'supervisor_dashboard'::jsonb->'kpis' <> 'null'
 AND NOT :'supervisor_dashboard'::jsonb ? 'error','supervisor runs the operations dashboard: '||left(:'supervisor_dashboard',200));
SELECT pg_temp.ra_assert(public.get_stock_aging_report()->>'success'='true'
 AND public.get_item_wise_stock_list()->>'success'='true'
 AND public.get_all_stock_summary()->>'success'='true'
 AND public.get_customer_stock_summary(:'gamma'::uuid) ? 'summary' AND NOT public.get_customer_stock_summary(:'gamma'::uuid) ? 'error'
 AND NOT public.get_customer_dispatch_activity(:'gamma'::uuid,CURRENT_DATE-30,CURRENT_DATE) ? 'error'
 AND public.get_recent_dispatched_orders(10,0)->>'success'='true',
 'supervisor runs the stock and dispatch reports');
-- Admitted.
SELECT public.update_user_role(:'managed_profile'::uuid,'staff') AS s_role \gset
SELECT pg_temp.ra_assert(:'s_role'::jsonb->>'success'='true' AND :'s_role'::jsonb->>'new_role'='staff','supervisor changes a role: '||:'s_role');
SELECT public.update_user_role(:'managed_profile'::uuid,'supervisor') AS s_role_up \gset
SELECT pg_temp.ra_assert(:'s_role_up'::jsonb->>'success'='true','supervisor makes a user a supervisor: '||:'s_role_up');
SELECT public.update_user_role(:'managed_profile'::uuid,'customer') AS s_role_back \gset
SELECT pg_temp.ra_assert(:'s_role_back'::jsonb->>'success'='true','supervisor changes the role back: '||:'s_role_back');
SELECT public.update_user_status(:'managed_profile'::uuid,false) AS s_off \gset
SELECT pg_temp.ra_assert(:'s_off'::jsonb->>'success'='true','supervisor deactivates a user: '||:'s_off');
-- Giving access back is an administrator's decision (migration 47): the
-- deactivated profile is 'disabled', a state a supervisor cannot change.
SELECT public.update_user_status(:'managed_profile'::uuid,true) AS s_on \gset
SELECT public.update_user_role(:'managed_profile'::uuid,'staff') AS s_role_disabled \gset
SELECT pg_temp.ra_assert(:'s_on'::jsonb->>'success'='false' AND :'s_on'::jsonb->>'error'='ENROLLMENT_NOT_APPROVED'
 AND :'s_on'::jsonb->>'message'='Only an administrator can change a user whose access is not approved'
 AND :'s_role_disabled'::jsonb->>'success'='false' AND :'s_role_disabled'::jsonb->>'error'='ENROLLMENT_NOT_APPROVED',
 'supervisor cannot reactivate a user or change the role of a deactivated one: '||:'s_on'||:'s_role_disabled');
-- A rejected access request stays rejected, and a pending one stays reviewable.
SELECT public.update_user_status(:'rejected_profile'::uuid,true) AS s_rejected_on \gset
SELECT public.update_user_role(:'rejected_profile'::uuid,'supervisor') AS s_rejected_role \gset
SELECT public.update_user_status(:'pending_profile'::uuid,true) AS s_pending_on \gset
SELECT public.update_user_role(:'pending_profile'::uuid,'staff') AS s_pending_role \gset
SELECT pg_temp.ra_assert(:'s_rejected_on'::jsonb->>'success'='false' AND :'s_rejected_on'::jsonb->>'error'='ENROLLMENT_NOT_APPROVED'
 AND :'s_rejected_role'::jsonb->>'success'='false' AND :'s_rejected_role'::jsonb->>'error'='ENROLLMENT_NOT_APPROVED',
 'supervisor cannot re-approve a rejected access request or give it a role: '||:'s_rejected_on'||:'s_rejected_role');
SELECT pg_temp.ra_assert(:'s_pending_on'::jsonb->>'success'='false' AND :'s_pending_on'::jsonb->>'error'='ENROLLMENT_NOT_APPROVED'
 AND :'s_pending_role'::jsonb->>'success'='false' AND :'s_pending_role'::jsonb->>'error'='ENROLLMENT_PENDING',
 'supervisor cannot activate a pending access request or change its role: '||:'s_pending_on'||:'s_pending_role');
RESET ROLE;
SELECT pg_temp.ra_assert((SELECT NOT active AND enrollment_status='disabled' AND role='customer' FROM public.user_profiles WHERE id=:'managed_profile'::uuid)
 AND (SELECT NOT active AND enrollment_status='rejected' AND role='customer' FROM public.user_profiles WHERE id=:'rejected_profile'::uuid)
 AND (SELECT NOT active AND enrollment_status='pending' AND role='customer' FROM public.user_profiles WHERE id=:'pending_profile'::uuid),
 'the refused changes left the three profiles as they were');
-- The administrator gives access back; a pending request keeps its role for the administrator too.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_user_role(:'pending_profile'::uuid,'staff') AS a_pending_role \gset
SELECT pg_temp.ra_assert(:'a_pending_role'::jsonb->>'success'='false' AND :'a_pending_role'::jsonb->>'error'='ENROLLMENT_PENDING'
 AND :'a_pending_role'::jsonb->>'message'='Review the access request before changing the role',
 'the role of a pending access request cannot be changed before the review: '||:'a_pending_role');
SELECT pg_temp.ra_assert(public.operator_review_enrollment(:'pending_profile'::uuid,'rejected')->>'success'='true',
 'the pending access request is still reviewable');
SELECT pg_temp.ra_assert(public.update_user_status(:'managed_profile'::uuid,true)->>'success'='true',
 'administrator reactivates the user the supervisor deactivated');
RESET ROLE;
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ra_assert(public.assign_customer_to_user('919888888937',:'gamma'::uuid,'by supervisor'),'supervisor assigns a customer');
RESET ROLE;
SELECT pg_temp.ra_assert((SELECT role='customer' AND active AND enrollment_status='approved' FROM public.user_profiles WHERE id=:'managed_profile'::uuid)
 AND (SELECT count(*)=1 FROM public.users_customers_new WHERE user_profile_id=:'managed_profile'::uuid AND customer_id=:'gamma'::uuid AND active
        AND assigned_by=:'supervisor_profile'::uuid),'the supervisor''s changes are stored');
SET LOCAL ROLE authenticated;
SELECT pg_temp.ra_assert(public.remove_customer_assignment('919888888937',:'gamma'::uuid),'supervisor removes an assignment');
RESET ROLE;
SELECT pg_temp.ra_assert((SELECT count(*)=0 FROM public.users_customers_new WHERE user_profile_id=:'managed_profile'::uuid AND active),'assignment removed');
SET LOCAL ROLE authenticated;
-- Refused: an administrator as target.
SELECT public.update_user_role(:'admin2_profile'::uuid,'staff') AS s_admin_role \gset
SELECT public.update_user_status(:'admin2_profile'::uuid,false) AS s_admin_status \gset
SELECT pg_temp.ra_assert(:'s_admin_role'::jsonb->>'success'='false' AND :'s_admin_role'::jsonb->>'error'='PERMISSION_DENIED',
 'supervisor cannot change an administrator''s role: '||:'s_admin_role');
SELECT pg_temp.ra_assert(:'s_admin_status'::jsonb->>'success'='false' AND :'s_admin_status'::jsonb->>'error'='CANNOT_MODIFY_ADMIN',
 'supervisor cannot deactivate an administrator: '||:'s_admin_status');
SELECT pg_temp.ra_assert(pg_temp.ra_call(format('SELECT to_jsonb(public.assign_customer_to_user(''919888888932'',%L::uuid))',:'gamma'))->>'state'='42501'
 AND pg_temp.ra_call(format('SELECT to_jsonb(public.remove_customer_assignment(''919888888932'',%L::uuid))',:'gamma'))->>'state'='42501',
 'supervisor cannot change an administrator''s customer assignments');
-- Refused: granting the administrator role.
SELECT public.update_user_role(:'managed_profile'::uuid,'admin') AS s_grant \gset
SELECT pg_temp.ra_assert(:'s_grant'::jsonb->>'success'='false' AND :'s_grant'::jsonb->>'error'='CANNOT_PROMOTE_TO_ADMIN',
 'supervisor cannot make anyone an administrator: '||:'s_grant');
-- Refused: the own profile.
SELECT public.update_user_role(:'supervisor_profile'::uuid,'admin') AS s_self_role \gset
SELECT public.update_user_status(:'supervisor_profile'::uuid,false) AS s_self_status \gset
SELECT pg_temp.ra_assert(:'s_self_role'::jsonb->>'success'='false' AND :'s_self_role'::jsonb->>'error'='SELF_EDIT_FORBIDDEN'
 AND :'s_self_status'::jsonb->>'success'='false' AND :'s_self_status'::jsonb->>'error'='SELF_EDIT_FORBIDDEN',
 'supervisor cannot change the own role or status: '||:'s_self_role'||:'s_self_status');
SELECT pg_temp.ra_assert(pg_temp.ra_call(format('SELECT to_jsonb(public.assign_customer_to_user(''919888888933'',%L::uuid))',:'gamma'))->>'state'='42501'
 AND pg_temp.ra_call(format('SELECT to_jsonb(public.remove_customer_assignment(''919888888933'',%L::uuid))',:'gamma'))->>'state'='42501',
 'supervisor cannot change the own customer assignments');
-- Enrollment review stays with administrators.
SELECT pg_temp.ra_assert(pg_temp.ra_call(format('SELECT public.operator_review_enrollment(%L::uuid,''reject'',NULL)',:'managed_profile'))::text
   ~ '(Administrator|42501|not authorized|denied)','supervisor cannot review enrollments: '
   ||pg_temp.ra_call(format('SELECT public.operator_review_enrollment(%L::uuid,''reject'',NULL)',:'managed_profile'))::text);
RESET ROLE;
SELECT pg_temp.ra_assert((SELECT bool_and(role='admin' AND active) FROM public.user_profiles WHERE id IN (:'admin_profile'::uuid,:'admin2_profile'::uuid))
 AND (SELECT role='supervisor' AND active FROM public.user_profiles WHERE id=:'supervisor_profile'::uuid)
 AND (SELECT role='customer' AND active FROM public.user_profiles WHERE id=:'managed_profile'::uuid)
 AND (SELECT count(*)=0 FROM public.users_customers_new WHERE user_profile_id IN (:'admin2_profile'::uuid,:'supervisor_profile'::uuid)),
 'the refused changes left administrators, the supervisor and the user as they were');

-- ---------------------------------------------------------------------------
-- 6. Administrator: unchanged; the last administrator stays (migration 44)
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ra_assert(public.update_user_role(:'managed_profile'::uuid,'admin')->>'success'='true'
 AND public.update_user_role(:'managed_profile'::uuid,'customer')->>'success'='true',
 'administrator grants and takes back the administrator role');
SELECT pg_temp.ra_assert(public.assign_customer_to_user('919888888933',:'gamma'::uuid)
 AND public.remove_customer_assignment('919888888933',:'gamma'::uuid),'administrator changes a supervisor''s customer assignments');
SELECT pg_temp.ra_assert(public.update_user_status(:'admin2_profile'::uuid,false)->>'success'='true',
 'administrator deactivates the other administrator');
RESET ROLE;
-- One active administrator is left. A supervisor is stopped by the
-- administrator-target rule before the last-administrator rule is reached.
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_user_role(:'admin_profile'::uuid,'staff') AS s_last_role \gset
SELECT public.update_user_status(:'admin_profile'::uuid,false) AS s_last_status \gset
SELECT pg_temp.ra_assert(:'s_last_role'::jsonb->>'success'='false' AND :'s_last_status'::jsonb->>'success'='false',
 'supervisor cannot demote or deactivate the last administrator: '||:'s_last_role'||:'s_last_status');
RESET ROLE;
SELECT pg_temp.ra_assert((SELECT role='admin' AND active AND enrollment_status='approved' FROM public.user_profiles WHERE id=:'admin_profile'::uuid),
 'the last administrator is unchanged');
SELECT pg_temp.ra_assert(pg_get_functiondef('public.update_user_status(uuid,boolean)'::regprocedure) LIKE '%other_active_admin_exists(v_target_id)%'
 AND pg_get_functiondef('public.update_user_role(uuid,public.user_role)'::regprocedure) LIKE '%other_active_admin_exists(v_target_id)%',
 'both bodies keep the last-administrator rule of migration 44');
ROLLBACK;
\echo 'Role allowlist: catalog classification, customer and staff denial sweeps, staff reports/pricing/sensors/photo removal, supervisor user management and customer privacy passed.'

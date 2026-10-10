-- Orders screen regression (migrations 28 and 29) ONLY in migrations.sh's fresh
-- network-disabled database. Fictional profiles are seeded locally; every
-- session uses the ordinary operator OTP flow. All fixture rows roll back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.order_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'orders screen: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.order_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM pg_temp.order_assert(challenge->>'success'='true','ordinary challenge');
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  login := public.operator_verify_otp(phone,challenge#>>'{data,otp_code}');
  PERFORM pg_temp.order_assert(login#>>'{data,action}'='login','ordinary login');
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id=p.auth_user_id
    WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- The statement must be refused by the RPC guard: either the exception itself,
-- or (for older functions with a catch-all handler) a failure envelope carrying it.
CREATE FUNCTION pg_temp.order_denied(statement text, label text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE result jsonb;
BEGIN
  BEGIN
    EXECUTE statement INTO result;
  EXCEPTION WHEN insufficient_privilege THEN RETURN; END;
  IF result->>'success'='false' AND (result::text LIKE '%Customer access denied%'
     OR result::text LIKE '%Staff access required%') THEN RETURN; END IF;
  RAISE EXCEPTION 'orders screen: % was allowed: %', label, result;
END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888888701','Orders Administrator');
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888702','Orders Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888703','Orders Two-Customer Reader','customer',true,'approved'),
 (gen_random_uuid(),'919888888704','Orders A Reader','customer',true,'approved');
SELECT pg_temp.order_login('9888888701') AS admin_claims \gset
SELECT pg_temp.order_login('9888888702') AS staff_claims \gset
SELECT pg_temp.order_login('9888888703') AS multi_claims \gset
SELECT pg_temp.order_login('9888888704') AS single_claims \gset
INSERT INTO public.customers(name,mobile) VALUES ('Orders Customer A','9888888751') RETURNING id AS customer_a \gset
INSERT INTO public.customers(name,mobile) VALUES ('Orders Customer B','9888888752') RETURNING id AS customer_b \gset
INSERT INTO public.items(name,packaging) VALUES ('Orders Onions','Bag') RETURNING id AS item_id \gset
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active)
 SELECT p.id,c.id,true FROM public.user_profiles p CROSS JOIN (VALUES (:'customer_a'::uuid),(:'customer_b'::uuid)) c(id)
 WHERE p.mobile='919888888703';
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active)
 SELECT id,:'customer_a'::uuid,true FROM public.user_profiles WHERE mobile='919888888704';

-- Stock for both customers, received by the administrator.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_grn(p_gr_no=>'ORDA',p_date=>now(),p_customer_id=>:'customer_a'::uuid,
 p_customer_name=>'Orders Customer A',p_items=>jsonb_build_array(jsonb_build_object(
 'item_id',:'item_id','item_name','Orders Onions','packaging','Bag','qty',10,'weight',12)),
 p_idempotency_key=>'orders-screen-receipt-a') AS receipt_a \gset
SELECT public.save_grn(p_gr_no=>'ORDB',p_date=>now(),p_customer_id=>:'customer_b'::uuid,
 p_customer_name=>'Orders Customer B',p_items=>jsonb_build_array(jsonb_build_object(
 'item_id',:'item_id','item_name','Orders Onions','packaging','Bag','qty',10,'weight',15)),
 p_idempotency_key=>'orders-screen-receipt-b') AS receipt_b \gset
SELECT pg_temp.order_assert(:'receipt_a'::jsonb->>'success'='true' AND :'receipt_b'::jsonb->>'success'='true','receipts');
RESET ROLE;
SELECT t.id AS lot_a FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='ORDA' \gset
SELECT t.id AS lot_b FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='ORDB' \gset

-- A customer assigned to two customers edits both carts. The old `<> ANY`
-- ownership check denied every quantity change for such accounts.
SELECT set_config('request.jwt.claims',:'multi_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'customer_a'::uuid) AS cart_a \gset
SELECT public.get_or_create_cart(:'customer_b'::uuid) AS cart_b \gset
SELECT pg_temp.order_assert(public.add_item_to_order(:'cart_a'::uuid,:'lot_a'::uuid,5)->>'success'='true','add to cart A');
SELECT pg_temp.order_assert(public.add_item_to_order(:'cart_b'::uuid,:'lot_b'::uuid,2)->>'success'='true','add to cart B');
SELECT id AS item_a FROM public.order_items WHERE order_id=:'cart_a'::uuid \gset
SELECT id AS item_b FROM public.order_items WHERE order_id=:'cart_b'::uuid \gset
SELECT pg_temp.order_assert(public.update_order_item_quantity(:'item_a'::uuid,8)->>'success'='true','two-customer account changes quantity');
SELECT pg_temp.order_assert((SELECT requested_quantity=8 FROM public.order_items WHERE id=:'item_a'::uuid),'quantity stored');

-- Quantity rules.
SELECT pg_temp.order_assert(public.update_order_item_quantity(:'item_a'::uuid,11)->>'message' LIKE 'Insufficient stock%','quantity above stock rejected');
SELECT pg_temp.order_assert(public.update_order_item_quantity(:'item_a'::uuid,0)->>'success'='false','zero quantity rejected');
SELECT pg_temp.order_assert(public.update_order_item_quantity(:'item_a'::uuid,-3)->>'success'='false','negative quantity rejected');
SELECT pg_temp.order_assert((SELECT requested_quantity=8 FROM public.order_items WHERE id=:'item_a'::uuid),'rejected changes leave quantity');

-- A lot appears in a cart once.
SELECT pg_temp.order_assert(public.add_item_to_order(:'cart_a'::uuid,:'lot_a'::uuid,1)->>'message'='Item already exists in order','duplicate lot rejected');
SELECT pg_temp.order_assert(EXISTS (SELECT 1 FROM pg_constraint WHERE conname='order_items_order_grn_item_key'),'unique cart line constraint');

-- Weight search accepts decimals and ranges.
SELECT pg_temp.order_assert(jsonb_typeof(public.search_customer_items_for_order('12.5',:'customer_a'::uuid)->'items')='array','decimal weight search');
SELECT pg_temp.order_assert(jsonb_array_length(public.search_customer_items_for_order('10-13',:'customer_a'::uuid)->'items')=1,'weight range search');
SELECT pg_temp.order_assert(jsonb_array_length(public.search_customer_items_for_order('12',:'customer_a'::uuid)->'items')=1,'exact weight search');

-- Removal goes through the recorded RPC only.
SELECT pg_temp.order_denied($s$DELETE FROM public.order_items WHERE id='$s$||:'item_a'||$s$' RETURNING NULL::jsonb$s$,'direct customer delete');
SELECT pg_temp.order_assert(EXISTS (SELECT 1 FROM public.order_items WHERE id=:'item_a'::uuid),'direct customer delete has no effect');
SELECT pg_temp.order_assert(public.remove_item_from_order(:'item_a'::uuid)->>'success'='true','remove through RPC');
SELECT pg_temp.order_assert(NOT EXISTS (SELECT 1 FROM public.order_items WHERE id=:'item_a'::uuid),'item removed');

-- History: add, change and remove are three rows; failed attempts write nothing.
SELECT pg_temp.order_assert((SELECT count(*)=3 FROM public.order_revisions WHERE order_id=:'cart_a'::uuid),'three history rows readable by owner');
SELECT pg_temp.order_assert((SELECT entry->'cart_items' @> '[{"quantity":0}]'
  FROM public.order_revisions WHERE order_id=:'cart_a'::uuid ORDER BY changed_at DESC LIMIT 1),'removal recorded at quantity 0');
SELECT public.get_order_change_log(p_order_id=>:'cart_a'::uuid) AS history_a \gset
SELECT pg_temp.order_assert(:'history_a'::jsonb->>'success'='true','customer reads own order history');
SELECT pg_temp.order_assert(
  (SELECT array_agg(DISTINCT c->'change_details'->'quantity_change'->>'change_type' ORDER BY c->'change_details'->'quantity_change'->>'change_type')
     FROM jsonb_array_elements(:'history_a'::jsonb#>'{data,changes}') c)
  = ARRAY['added','increased','removed'],'history reports added, increased and removed');
SELECT pg_temp.order_assert(public.get_order_change_log(p_customer_id=>:'customer_b'::uuid)->>'success'='true','customer reads history by customer');
SELECT pg_temp.order_denied($s$SELECT public.get_order_change_log()$s$,'unscoped customer history');
SELECT pg_temp.order_denied($s$INSERT INTO public.order_revisions(order_id,changed_at,action,entry) VALUES ('$s$||:'cart_a'||$s$',now(),'UPDATE','{}') RETURNING NULL::jsonb$s$,'customer writes history');
SELECT pg_temp.order_assert(jsonb_array_length(public.get_orders_list()#>'{data,orders}')=2,'two-customer account lists both carts');
RESET ROLE;

-- A customer assigned only to A cannot touch B's cart or history.
SELECT set_config('request.jwt.claims',:'single_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.order_denied(format('SELECT public.update_order_item_quantity(%L::uuid,1)',:'item_b'),'foreign quantity change');
SELECT pg_temp.order_denied(format('SELECT public.remove_item_from_order(%L::uuid)',:'item_b'),'foreign removal');
SELECT pg_temp.order_denied(format('SELECT public.get_order_change_log(p_order_id=>%L::uuid)',:'cart_b'),'foreign order history');
SELECT pg_temp.order_denied(format('SELECT public.get_order_change_log(p_customer_id=>%L::uuid)',:'customer_b'),'foreign customer history');
SELECT pg_temp.order_denied(format('SELECT public.search_customer_items_for_order(%L,%L::uuid)','12',:'customer_b'),'foreign item search');
SELECT pg_temp.order_assert((SELECT count(*)=0 FROM public.order_revisions WHERE order_id=:'cart_b'::uuid),'foreign history rows hidden');
SELECT pg_temp.order_assert((SELECT count(*)=3 FROM public.order_revisions WHERE order_id=:'cart_a'::uuid),'own customer history visible');
SELECT pg_temp.order_assert(jsonb_array_length(public.get_orders_list()#>'{data,orders}')=1,'single-customer account lists one cart');
RESET ROLE;

-- Staff have full order access (decision 2026-10-09).
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.order_assert(warehouse_security.active_role()='staff','actual active staff role');
SELECT public.get_orders_list(p_has_items=>true) AS staff_list \gset
SELECT pg_temp.order_assert(:'staff_list'::jsonb->>'success'='true','staff lists orders');
SELECT pg_temp.order_assert(EXISTS (SELECT 1 FROM jsonb_array_elements(:'staff_list'::jsonb#>'{data,orders}') o
  WHERE o->>'id'=:'cart_b' AND (o->>'item_count')::int=1),'live list shows cart B item without a refresh');
SELECT pg_temp.order_assert(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(:'staff_list'::jsonb#>'{data,orders}') o
  WHERE o->>'id'=:'cart_a'),'live list drops emptied cart A from has_items');
SELECT pg_temp.order_assert(public.get_or_create_cart(:'customer_a'::uuid)::text=:'cart_a','staff opens a cart');
SELECT pg_temp.order_assert(public.get_order_with_items(:'cart_b'::uuid)->>'success'='true','staff reads cart');
SELECT pg_temp.order_assert(public.add_item_to_order(:'cart_a'::uuid,:'lot_a'::uuid,3)->>'success'='true','staff adds item');
SELECT pg_temp.order_assert(public.update_order_item_quantity(:'item_b'::uuid,4)->>'success'='true','staff changes quantity');
SELECT pg_temp.order_assert(public.get_order_change_log(p_order_id=>:'cart_a'::uuid)->>'success'='true','staff reads history');
SELECT pg_temp.order_assert(jsonb_typeof(public.get_customer_items_for_order_selection(:'customer_b'::uuid)->'data')='array','staff browses lots');
SELECT pg_temp.order_assert((SELECT count(*)=4 FROM public.order_revisions WHERE order_id=:'cart_a'::uuid),'staff reads history rows');
SELECT pg_temp.order_assert(jsonb_array_length(public.get_orders_list(p_limit=>1,p_offset=>0)#>'{data,orders}')=1
  AND (public.get_orders_list(p_limit=>1,p_offset=>0)#>>'{data,pagination,has_more}')::boolean,'orders list pages');
RESET ROLE;

-- The legacy column is pinned, history never reaches the audit log, and the
-- dropped RPCs and synchronous list rebuild are gone.
SELECT pg_temp.order_assert((SELECT bool_and(revisions='[]'::jsonb) FROM public.orders WHERE id IN (:'cart_a'::uuid,:'cart_b'::uuid)),'orders.revisions stays empty');
DO $$ BEGIN
  UPDATE public.orders SET revisions='[{}]'::jsonb WHERE customer_id IN (SELECT id FROM public.customers WHERE name LIKE 'Orders Customer %');
  RAISE EXCEPTION 'orders screen: writing orders.revisions was allowed';
EXCEPTION WHEN check_violation THEN NULL; END $$;
SELECT pg_temp.order_assert(NOT EXISTS (SELECT 1 FROM public.audit_log WHERE table_name='orders'
  AND COALESCE(new_data->>'id',old_data->>'id') IN (:'cart_a',:'cart_b')
  AND (COALESCE(new_data->'revisions','[]')<>'[]' OR COALESCE(old_data->'revisions','[]')<>'[]')),'audit rows carry no cart history');
SELECT pg_temp.order_assert(NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname IN ('convert_order_to_dispatch','update_order_after_dispatch_creation','trigger_refresh_orders_list_mv')),'dead order RPCs dropped');
SELECT pg_temp.order_assert(position('o.revisions' IN pg_get_functiondef('public.get_order_change_log(uuid,uuid,timestamp with time zone,timestamp with time zone,uuid,text,integer,integer)'::regprocedure))=0,'change log reads order_revisions');
SELECT pg_temp.order_assert(NOT has_function_privilege('authenticated','warehouse_security.record_order_revision(uuid,uuid,text,jsonb,jsonb)','EXECUTE'),'history helper is internal');
SELECT pg_temp.order_assert(NOT has_table_privilege('authenticated','public.v_orders_list','SELECT'),'live list view is not an API table');
ROLLBACK;

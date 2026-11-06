-- Migration 148 (WH-26, W16): staff can order and dispatch for a deactivated customer. A deactivated customer's stock still goes out on orders and
-- dispatches; only a new GRN is refused. Covers the four reads behind the order and dispatch screens as staff on a deactivated customer:
--   search_customer_items_for_order, get_orders_list, get_customer_grns_with_stock_dispatch_sorted and get_customer_items_for_order_selection;
-- and that nothing widens beyond that: a soft-deleted customer's orders stay out of the list, a customer account still reaches only its assigned
-- customers, a disabled staff account is refused, and user_accessible_customers() still lists active customers only.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database; rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.sd_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'staff deactivated customer 148: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.sd_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.sd_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.sd_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
-- The answer of a statement run as the signed-in caller, or {"raised": message, "state": sqlstate}.
CREATE FUNCTION pg_temp.sd_as(claims jsonb, statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',claims::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN answer := jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  EXECUTE 'RESET ROLE';
  RETURN answer;
END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='SDTEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9877777781','Dormant Test Administrator') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919877777782','Dormant Test Staff','staff',true,'approved'),
 (gen_random_uuid(),'919877777783','Dormant Test Disabled Staff','staff',true,'approved'),
 (gen_random_uuid(),'919877777784','Dormant Test Reader','customer',true,'approved');
SELECT pg_temp.sd_login('9877777781') AS admin_claims \gset
SELECT pg_temp.sd_login('9877777782') AS staff_claims \gset
SELECT pg_temp.sd_login('9877777783') AS disabled_claims \gset
SELECT pg_temp.sd_login('9877777784') AS customer_claims \gset
INSERT INTO public.customers(name,mobile) VALUES ('Dormant Test Customer','9877777791') RETURNING id AS dormant \gset
INSERT INTO public.customers(name,mobile) VALUES ('Dormant Test Active Customer','9877777792') RETURNING id AS livecust \gset
INSERT INTO public.customers(name,mobile) VALUES ('Dormant Test Gone Customer','9877777793') RETURNING id AS gone \gset
INSERT INTO public.items(name,packaging) VALUES ('Dormant Test Onions','Bag') RETURNING id AS item_id \gset
-- The customer account is assigned to the active customer only.
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active)
 SELECT id,:'livecust'::uuid,true FROM public.user_profiles WHERE mobile='919877777784';

-- Stock and an open order for each of the three customers, made while they are all still active.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.sd_assert(public.save_grn(p_gr_no=>n.no::varchar,p_date=>now(),p_customer_id=>n.c::uuid,p_customer_name=>n.nm::varchar,
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Dormant Test Onions','packaging','Bag','qty',10,'weight',12)),
 p_idempotency_key=>'dormant-148-'||n.no)->>'success'='true','receipt '||n.no)
FROM (VALUES ('DM1',:'dormant','Dormant Test Customer'),('DM2',:'livecust','Dormant Test Active Customer'),('DM3',:'gone','Dormant Test Gone Customer')) n(no,c,nm);
RESET ROLE;
SELECT t.id AS lot_dormant FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DM1' \gset
SELECT t.id AS lot_live FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DM2' \gset
SELECT t.id AS lot_gone FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DM3' \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'dormant'::uuid) AS cart_dormant \gset
SELECT public.get_or_create_cart(:'livecust'::uuid) AS cart_live \gset
SELECT public.get_or_create_cart(:'gone'::uuid) AS cart_gone \gset
SELECT pg_temp.sd_assert(public.add_item_to_order(:'cart_dormant'::uuid,:'lot_dormant'::uuid,3)->>'success'='true'
 AND public.add_item_to_order(:'cart_live'::uuid,:'lot_live'::uuid,3)->>'success'='true'
 AND public.add_item_to_order(:'cart_gone'::uuid,:'lot_gone'::uuid,3)->>'success'='true','order lines');
RESET ROLE;

-- Positive control, staff and an active customer: both screens' reads answer.
SELECT pg_temp.sd_as(:'staff_claims'::jsonb,format('SELECT public.search_customer_items_for_order(%L,%L::uuid)','',:'livecust')) AS live_search \gset
SELECT pg_temp.sd_assert(COALESCE(:'live_search'::jsonb->>'success','true')='true' AND jsonb_array_length(:'live_search'::jsonb->'items')=1,'staff, active customer: the item search answers: '||:'live_search');

-- The customer is deactivated and another is soft-deleted (the owner writes the rows, as the app's own RPCs do).
UPDATE public.customers SET active=false WHERE id=:'dormant'::uuid;
UPDATE public.customers SET active=false, deleted_at=now() WHERE id=:'gone'::uuid;

-- 1. search_customer_items_for_order: staff find the deactivated customer's stock.
SELECT pg_temp.sd_as(:'staff_claims'::jsonb,format('SELECT public.search_customer_items_for_order(%L,%L::uuid)','',:'dormant')) AS s_search \gset
SELECT pg_temp.sd_as(:'staff_claims'::jsonb,format('SELECT public.search_customer_items_for_order(%L,%L::uuid)','onions',:'dormant')) AS s_search_term \gset
SELECT pg_temp.sd_assert(COALESCE(:'s_search'::jsonb->>'success','true')='true' AND jsonb_array_length(:'s_search'::jsonb->'items')=1 AND (:'s_search'::jsonb->>'total_count')::int=1
 AND :'s_search'::jsonb::text LIKE '%Dormant Test Onions%' AND :'s_search'::jsonb->>'error' IS NULL,'staff: the item list of a deactivated customer: '||:'s_search');
SELECT pg_temp.sd_assert(COALESCE(:'s_search_term'::jsonb->>'success','true')='true' AND jsonb_array_length(:'s_search_term'::jsonb->'items')=1,'staff: a typed search for a deactivated customer: '||:'s_search_term');
-- Without a customer chosen, staff still search the active customers only.
SELECT pg_temp.sd_as(:'staff_claims'::jsonb,format('SELECT public.search_customer_items_for_order(%L)','')) AS s_search_all \gset
SELECT pg_temp.sd_assert(COALESCE(:'s_search_all'::jsonb->>'success','true')='true' AND jsonb_array_length(:'s_search_all'::jsonb->'items')=1
 AND (SELECT bool_and(i::text NOT LIKE '%'||:'lot_dormant'||'%') FROM jsonb_array_elements(:'s_search_all'::jsonb->'items') i),
 'staff: the all-customers search does not list the deactivated customer''s lots: '||:'s_search_all');
-- A customer account reaches only its assigned customer: the deactivated one is refused.
SELECT pg_temp.sd_as(:'customer_claims'::jsonb,format('SELECT public.search_customer_items_for_order(%L,%L::uuid)','',:'dormant')) AS c_search \gset
-- The refusal is raised (42501) by the guard, or answered as an error by the function: either way no item comes back.
SELECT pg_temp.sd_assert(((:'c_search'::jsonb->>'state'='42501') OR (:'c_search'::jsonb->>'success'='false' AND :'c_search'::jsonb->>'error'='Access denied to customer'))
 AND :'c_search'::jsonb::text NOT LIKE '%Dormant Test Onions%','a customer account is refused another customer: '||:'c_search');
SELECT pg_temp.sd_as(:'customer_claims'::jsonb,format('SELECT public.search_customer_items_for_order(%L,%L::uuid)','',:'livecust')) AS c_search_own \gset
SELECT pg_temp.sd_assert(COALESCE(:'c_search_own'::jsonb->>'success','true')='true' AND jsonb_array_length(:'c_search_own'::jsonb->'items')=1,'a customer account still reaches its own customer: '||:'c_search_own');
-- A disabled staff account is refused by the guard, deactivated customer or not.
UPDATE public.user_profiles SET active=false WHERE mobile='919877777783';
SELECT pg_temp.sd_as(:'disabled_claims'::jsonb,format('SELECT public.search_customer_items_for_order(%L,%L::uuid)','',:'dormant')) AS d_search \gset
SELECT pg_temp.sd_as(:'disabled_claims'::jsonb,'SELECT public.get_orders_list()') AS d_orders \gset
SELECT pg_temp.sd_assert(:'d_search'::jsonb->>'state'='42501' AND :'d_orders'::jsonb->>'state'='42501','a disabled staff account is refused: '||:'d_search'||:'d_orders');

-- 2. get_orders_list: a staff member's Orders list holds the deactivated customer's order, not the soft-deleted customer's.
SELECT pg_temp.sd_as(:'staff_claims'::jsonb,'SELECT public.get_orders_list()') AS s_orders \gset
SELECT pg_temp.sd_as(:'staff_claims'::jsonb,format('SELECT public.get_orders_list(%L::uuid)',:'dormant')) AS s_orders_one \gset
SELECT pg_temp.sd_assert(:'s_orders'::jsonb->>'success'='true'
 AND (SELECT count(*)=1 FROM jsonb_array_elements(:'s_orders'::jsonb#>'{data,orders}') o WHERE o->>'customer_id'=:'dormant')
 AND (SELECT count(*)=1 FROM jsonb_array_elements(:'s_orders'::jsonb#>'{data,orders}') o WHERE o->>'customer_id'=:'livecust')
 AND (SELECT count(*)=0 FROM jsonb_array_elements(:'s_orders'::jsonb#>'{data,orders}') o WHERE o->>'customer_id'=:'gone'),
 'staff: the list holds the deactivated customer''s order and the active one''s, and no soft-deleted customer''s: '||:'s_orders');
SELECT pg_temp.sd_assert(jsonb_array_length(:'s_orders_one'::jsonb#>'{data,orders}')=1 AND :'s_orders_one'::jsonb#>>'{data,orders,0,customer_id}'=:'dormant',
 'staff: the list filtered to the deactivated customer: '||:'s_orders_one');
SELECT pg_temp.sd_as(:'staff_claims'::jsonb,format('SELECT public.get_orders_list(%L::uuid)',:'gone')) AS s_orders_gone \gset
SELECT pg_temp.sd_assert(jsonb_array_length(:'s_orders_gone'::jsonb#>'{data,orders}')=0,'staff: a soft-deleted customer''s orders stay out even when asked for: '||:'s_orders_gone');
SELECT pg_temp.sd_as(:'customer_claims'::jsonb,'SELECT public.get_orders_list()') AS c_orders \gset
SELECT pg_temp.sd_as(:'customer_claims'::jsonb,format('SELECT public.get_orders_list(%L::uuid)',:'dormant')) AS c_orders_other \gset
SELECT pg_temp.sd_assert((SELECT count(*)=1 AND bool_and(o->>'customer_id'=:'livecust') FROM jsonb_array_elements(:'c_orders'::jsonb#>'{data,orders}') o)
 AND jsonb_array_length(:'c_orders_other'::jsonb#>'{data,orders}')=0,'a customer account sees only its own customer''s orders: '||:'c_orders'||:'c_orders_other');

-- 3. get_customer_grns_with_stock_dispatch_sorted (dispatch "Choose GRN") and 4. get_customer_items_for_order_selection (the order item list).
SELECT pg_temp.sd_as(:'staff_claims'::jsonb,format('SELECT public.get_customer_grns_with_stock_dispatch_sorted(%L::uuid)',:'dormant')) AS s_grns \gset
SELECT pg_temp.sd_assert(:'s_grns'::jsonb->>'success'='true' AND :'s_grns'::jsonb::text LIKE '%DM1%','staff: the receipts with stock of a deactivated customer: '||:'s_grns');
SELECT pg_temp.sd_as(:'staff_claims'::jsonb,format('SELECT public.get_customer_items_for_order_selection(%L::uuid)',:'dormant')) AS s_sel \gset
SELECT pg_temp.sd_assert(:'s_sel'::jsonb->>'success'='true' AND :'s_sel'::jsonb::text LIKE '%Dormant Test Onions%','staff: the order item list of a deactivated customer: '||:'s_sel');
SELECT pg_temp.sd_as(:'customer_claims'::jsonb,format('SELECT public.get_customer_grns_with_stock_dispatch_sorted(%L::uuid)',:'dormant')) AS c_grns \gset
SELECT pg_temp.sd_assert(((:'c_grns'::jsonb->>'state'='42501') OR (:'c_grns'::jsonb->>'success'='false'))
 AND :'c_grns'::jsonb::text NOT LIKE '%DM1%','a customer account is refused another customer''s receipts: '||:'c_grns');
SELECT pg_temp.sd_as(:'disabled_claims'::jsonb,format('SELECT public.get_customer_grns_with_stock_dispatch_sorted(%L::uuid)',:'dormant')) AS d_grns \gset
SELECT pg_temp.sd_assert(:'d_grns'::jsonb->>'state'='42501','a disabled staff account is refused: '||:'d_grns');

-- 5. Nothing else widened: the shared helper still lists active customers only, and a new GRN for a deactivated customer is still refused.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.user_accessible_customers() AS staff_list \gset
RESET ROLE;
SELECT pg_temp.sd_assert(NOT (:'staff_list'::text LIKE '%'||:'dormant'||'%') AND :'staff_list'::text LIKE '%'||:'livecust'||'%','user_accessible_customers() still lists active customers only: '||:'staff_list');
SELECT pg_temp.sd_as(:'admin_claims'::jsonb,format($q$SELECT public.save_grn(p_gr_no=>'DM9',p_date=>now(),p_customer_id=>%L::uuid,p_customer_name=>'Dormant Test Customer',
  p_items=>jsonb_build_array(jsonb_build_object('item_id',%L,'item_name','Dormant Test Onions','packaging','Bag','qty',1,'weight',12)),p_idempotency_key=>'dormant-148-new')$q$,:'dormant',:'item_id')) AS new_grn \gset
SELECT pg_temp.sd_assert(((:'new_grn'::jsonb->>'success'='false') OR (:'new_grn'::jsonb->>'raised' LIKE 'This business is deactivated.%')) AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no='DM9'),'a new GRN for a deactivated customer is still refused: '||:'new_grn');
ROLLBACK;

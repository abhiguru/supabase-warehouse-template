-- Migration 82 (2026-10-15): get_orders_list returns 'active' (customers.active) inside each row's
-- customer object, for the all-customers and the one-customer call, for an administrator and for a customer
-- login. A deactivated business is still listed. Fictional data; runs only in migrations.sh's disposable,
-- network-disabled database.
-- Also (owner decisions A and B, 2026-10-15): set_customer_active (roles, no stock check, restore clears
-- deleted_at), the data fix for soft-deleted businesses with data, a customer login still reading the past
-- records of a deactivated business, staff and administrators still seeing it in the readers, and no new
-- GRN or dispatch for a DELETED business. (safe_delete_customer and restore_customer, which this file also
-- tested, were dropped by migration 123: nothing called them. The not-deleted-with-data rule they carried
-- stays in the data fix below and in set_customer_active, which never deletes.)
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.oi_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'open items 82: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.oi_call(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.oi_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.oi_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.oi_assert(l#>>'{data,action}'='login','login for '||phone||': '||l::text);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9555560201','Open Items Admin') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919555560202','Open Items Customer','customer',true,'approved'),
 (gen_random_uuid(),'919555560203','Open Items Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919555560204','Open Items Staff','staff',true,'approved');
SELECT pg_temp.oi_login('9555560201') AS admin_claims \gset
SELECT pg_temp.oi_login('9555560202') AS customer_claims \gset
SELECT pg_temp.oi_login('9555560203') AS supervisor_claims \gset
SELECT pg_temp.oi_login('9555560204') AS staff_claims \gset
INSERT INTO public.customers(name,mobile) VALUES ('Open Items Business A','9555560211') RETURNING id AS cust_a \gset
INSERT INTO public.customers(name,mobile) VALUES ('Open Items Business B','9555560212') RETURNING id AS cust_b \gset
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active)
 SELECT p.id,c.id,true FROM public.user_profiles p CROSS JOIN (VALUES (:'cust_a'::uuid),(:'cust_b'::uuid)) c(id)
 WHERE p.mobile='919555560202';
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'cust_a'::uuid) AS cart_a \gset
SELECT public.get_or_create_cart(:'cust_b'::uuid) AS cart_b \gset
RESET ROLE;

-- both active: the flag is true on both rows
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_orders_list() AS list_all_1 \gset
RESET ROLE;
SELECT pg_temp.oi_assert((SELECT bool_and((o->'customer'->'active')='true'::jsonb) AND count(*)=2
   FROM jsonb_array_elements(:'list_all_1'::jsonb#>'{data,orders}') o WHERE o->>'customer_id' IN (:'cust_a',:'cust_b')),
 'active businesses: customer.active is true on both rows: '||:'list_all_1');
SELECT pg_temp.oi_assert((SELECT array_agg(k ORDER BY k) = ARRAY['active','city','id','mobile','name']
   FROM (SELECT jsonb_object_keys(o->'customer') k FROM jsonb_array_elements(:'list_all_1'::jsonb#>'{data,orders}') o LIMIT 5) s),
 'the customer object gains only the key active: '||:'list_all_1');

-- B is deactivated: still listed, flag false; A stays true
UPDATE public.customers SET active=false WHERE id=:'cust_b'::uuid;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_orders_list() AS list_all_2 \gset
SELECT public.get_orders_list(p_customer_id=>:'cust_b'::uuid) AS list_one_b \gset
SELECT public.get_orders_list(p_customer_id=>:'cust_a'::uuid) AS list_one_a \gset
RESET ROLE;
SELECT pg_temp.oi_assert((SELECT (o->'customer'->'active')='false'::jsonb FROM jsonb_array_elements(:'list_all_2'::jsonb#>'{data,orders}') o WHERE o->>'customer_id'=:'cust_b')
   AND (SELECT (o->'customer'->'active')='true'::jsonb FROM jsonb_array_elements(:'list_all_2'::jsonb#>'{data,orders}') o WHERE o->>'customer_id'=:'cust_a'),
 'administrator, all customers: B false, A true: '||:'list_all_2');
SELECT pg_temp.oi_assert(jsonb_array_length(:'list_one_b'::jsonb#>'{data,orders}')=1
   AND (:'list_one_b'::jsonb#>'{data,orders,0,customer,active}')='false'::jsonb
   AND jsonb_array_length(:'list_one_a'::jsonb#>'{data,orders}')=1
   AND (:'list_one_a'::jsonb#>'{data,orders,0,customer,active}')='true'::jsonb,
 'administrator, one customer: B false, A true: '||:'list_one_b'||:'list_one_a');

-- the customer login sees its deactivated business with the flag false
SELECT set_config('request.jwt.claims',:'customer_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_orders_list() AS list_cust \gset
RESET ROLE;
SELECT pg_temp.oi_assert(jsonb_array_length(:'list_cust'::jsonb#>'{data,orders}')=2
   AND (SELECT (o->'customer'->'active')='false'::jsonb FROM jsonb_array_elements(:'list_cust'::jsonb#>'{data,orders}') o WHERE o->>'customer_id'=:'cust_b')
   AND (SELECT (o->'customer'->'active')='true'::jsonb FROM jsonb_array_elements(:'list_cust'::jsonb#>'{data,orders}') o WHERE o->>'customer_id'=:'cust_a'),
 'customer login: B false, A true: '||:'list_cust');

-- staff login: the order of the deactivated business is listed with active=false 
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_orders_list() AS list_staff \gset
RESET ROLE;
SELECT pg_temp.oi_assert((SELECT (o->'customer'->'active')='false'::jsonb FROM jsonb_array_elements(:'list_staff'::jsonb#>'{data,orders}') o WHERE o->>'customer_id'=:'cust_b')
   AND (SELECT (o->'customer'->'active')='true'::jsonb FROM jsonb_array_elements(:'list_staff'::jsonb#>'{data,orders}') o WHERE o->>'customer_id'=:'cust_a'),
 'staff login: the order of the deactivated business is listed with active false, A true: '||:'list_staff');

-- ---- set_customer_active, the data fix
INSERT INTO public.items(name,packaging) VALUES ('Open Items Ginger','Bag') RETURNING id AS item_id \gset
INSERT INTO public.customers(name,mobile) VALUES ('Open Items D with data','9555560213') RETURNING id AS cust_d \gset
INSERT INTO public.customers(name,mobile) VALUES ('Open Items E empty cart','9555560214') RETURNING id AS cust_e \gset
INSERT INTO public.customers(name,mobile) VALUES ('Open Items F nothing','9555560215') RETURNING id AS cust_f \gset
INSERT INTO public.customers(name,mobile) VALUES ('Open Items G dispatched order','9555560216') RETURNING id AS cust_g \gset
INSERT INTO public.customers(name,mobile) VALUES ('Open Items H empty cart permanent','9555560217') RETURNING id AS cust_h \gset
INSERT INTO public.customers(name,mobile) VALUES ('Open Items I deleted nothing','9555560218') RETURNING id AS cust_i \gset
INSERT INTO public.customers(name,mobile) VALUES ('Open Items J payment','9555560219') RETURNING id AS cust_j \gset
INSERT INTO public.customers(name,mobile) VALUES ('Open Items K rate','9555560220') RETURNING id AS cust_k \gset
INSERT INTO public.customers(name,mobile) VALUES ('Open Items L assignment','9555560221') RETURNING id AS cust_l \gset
INSERT INTO public.customers(name,mobile) VALUES ('Open Items M deleted GRN','9555560222') RETURNING id AS cust_m \gset
INSERT INTO public.customers(name,mobile) VALUES ('Open Items N deleted dispatch','9555560223') RETURNING id AS cust_n \gset
INSERT INTO public.customers(name,mobile,active,deleted_at) VALUES ('Open Items Q deleted','9555560224',false,now()) RETURNING id AS cust_q \gset
INSERT INTO public.payments(payment_no,payment_date,customer_id,customer_name,amount) VALUES ('OI82P1',now(),:'cust_j'::uuid,'Open Items J payment',10);
INSERT INTO public.item_storage_prices(item_id,customer_id,price_type,unit_price,weight_min,weight_max,labour_rate,tax_percent,effective_from,unit_price_one_time,unit_price_monthly)
 VALUES (:'item_id'::uuid,:'cust_k'::uuid,'monthly',1,0,10,0,0,current_date,0,1);
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active)
 SELECT p.id,c.id,c.is_active FROM public.user_profiles p CROSS JOIN (VALUES (:'cust_l'::uuid,true),(:'cust_h'::uuid,false)) c(id,is_active)
 WHERE p.mobile='919555560202';
INSERT INTO public.goodsreceived(gr_no,customer_id,customer_name,date,deleted_at) VALUES ('OI82M',:'cust_m'::uuid,'Open Items M deleted GRN',now(),now());
INSERT INTO public.dispatch(disp_no,customer_id,customer_name,deleted_at) VALUES ('OI82N',:'cust_n'::uuid,'Open Items N deleted dispatch',now());
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active)
 SELECT p.id,:'cust_d'::uuid,true FROM public.user_profiles p WHERE p.mobile='919555560202';
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_grn(p_gr_no=>'OI82A',p_date=>now(),p_customer_id=>:'cust_d'::uuid,p_customer_name=>'Open Items D with data',
  p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Open Items Ginger','packaging','Bag','qty',7,'weight',10,'rack','A1')),
  p_idempotency_key=>'oi82-d') AS save_d \gset
SELECT public.get_or_create_cart(:'cust_e'::uuid) AS cart_e \gset
SELECT public.get_or_create_cart(:'cust_g'::uuid) AS cart_g \gset
SELECT public.get_or_create_cart(:'cust_h'::uuid) AS cart_h \gset
RESET ROLE;
SELECT pg_temp.oi_assert((:'save_d'::jsonb->>'success')='true','GRN saved for D: '||:'save_d');
SELECT g.id AS grn_d FROM public.goodsreceived g WHERE g.customer_id=:'cust_d'::uuid \gset
UPDATE public.orders SET status='DISPATCHED' WHERE customer_id=:'cust_g'::uuid;

-- second GRN of D, made while D is still active (migration 83: a deactivated business gets no NEW GRN)
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_grn(p_gr_no=>'OI82B',p_date=>now(),p_customer_id=>:'cust_d'::uuid,p_customer_name=>'Open Items D with data',
  p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Open Items Ginger','packaging','Bag','qty',3,'weight',10,'rack','A2')),
  p_idempotency_key=>'oi82-d2') AS save_d2 \gset
RESET ROLE;
SELECT pg_temp.oi_assert((:'save_d2'::jsonb->>'success')='true','second GRN saved for the active D: '||:'save_d2');

-- set_customer_active: staff and a customer login are refused, nothing changes
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.oi_call(format('SELECT public.set_customer_active(%L::uuid,false)',:'cust_d')) AS sca_staff \gset
RESET ROLE;
SELECT set_config('request.jwt.claims',:'customer_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.oi_call(format('SELECT public.set_customer_active(%L::uuid,false)',:'cust_d')) AS sca_customer \gset
RESET ROLE;
SELECT pg_temp.oi_assert(:'sca_staff'::jsonb->>'state'='42501' AND :'sca_customer'::jsonb->>'state'='42501'
 AND (SELECT active AND deleted_at IS NULL FROM public.customers WHERE id=:'cust_d'::uuid),
 'set_customer_active: staff and customer refused (42501), D unchanged: '||:'sca_staff'||:'sca_customer');
-- the supervisor deactivates D although it has stock: active=false only, deleted_at stays null
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.set_customer_active(:'cust_d'::uuid,false) AS sca_off \gset
SELECT public.set_customer_active(:'cust_d'::uuid,false) AS sca_off_again \gset
SELECT public.set_customer_active(gen_random_uuid(),true) AS sca_missing \gset
RESET ROLE;
SELECT pg_temp.oi_assert((:'sca_off'::jsonb->>'success')='true' AND (:'sca_off'::jsonb#>'{data,active}')='false'::jsonb
 AND (:'sca_off'::jsonb#>>'{data,id}')=:'cust_d'
 AND (SELECT NOT active AND deleted_at IS NULL FROM public.customers WHERE id=:'cust_d'::uuid)
 AND EXISTS (SELECT 1 FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.customer_id=:'cust_d'::uuid AND t.stock>0),
 'set_customer_active(false): supervisor, business with stock, active=false and deleted_at null: '||:'sca_off');
SELECT pg_temp.oi_assert((:'sca_off_again'::jsonb->>'success')='true' AND (:'sca_off_again'::jsonb->>'message') LIKE '%already inactive%'
 AND (:'sca_missing'::jsonb->>'success')='false' AND (:'sca_missing'::jsonb->>'message')='Customer not found',
 'set_customer_active: already inactive and unknown id answers: '||:'sca_off_again'||:'sca_missing');

-- a DELETED one is refused for GRN and for both dispatch overloads
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.oi_call(format($q$SELECT public.save_grn(p_gr_no=>'OI82Q',p_date=>now(),p_customer_id=>%L::uuid,p_customer_name=>'Open Items Q deleted',
  p_idempotency_key=>'oi82-q')$q$,:'cust_q')) AS save_q \gset
SELECT pg_temp.oi_call(format($q$SELECT public.create_dispatch_with_stock_check(%L::jsonb,ARRAY[]::jsonb[],false,0,'oi82-dq')$q$,
  jsonb_build_object('disp_no','OI82DQ','disp_date',now(),'customer_id',:'cust_q','customer_name','Open Items Q deleted')::text)) AS disp_q5 \gset
SELECT pg_temp.oi_call(format($q$SELECT public.create_dispatch_with_stock_check(%L::jsonb,ARRAY[]::jsonb[],0,'oi82-dq4')$q$,
  jsonb_build_object('disp_no','OI82DR','disp_date',now(),'customer_id',:'cust_q','customer_name','Open Items Q deleted')::text)) AS disp_q4 \gset
RESET ROLE;
-- (a NEW GRN for a deactivated business is refused since migration 83: see tests/grn_deactivated_83.sql)
SELECT pg_temp.oi_assert(:'save_q'::jsonb->>'raised'='Business is not active' AND :'save_q'::jsonb->>'state'='P0001'
 AND :'disp_q5'::jsonb->>'raised'='Business is not active' AND :'disp_q5'::jsonb->>'state'='P0001'
 AND :'disp_q4'::jsonb->>'raised'='Business is not active' AND :'disp_q4'::jsonb->>'state'='P0001'
 AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE customer_id=:'cust_q'::uuid)
 AND NOT EXISTS (SELECT 1 FROM public.dispatch WHERE customer_id=:'cust_q'::uuid),
 'a deleted business gets no GRN and no dispatch (both overloads): '||:'save_q'||:'disp_q5'||:'disp_q4');

-- update_grn: moving a GRN to a DELETED business is refused, nothing changes
SELECT g.id AS grn_d2 FROM public.goodsreceived g WHERE g.gr_no='OI82B' AND g.customer_id=:'cust_d'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.oi_call(format('SELECT public.update_grn(p_grn_id=>%L::uuid,p_customer_id=>%L::uuid)',:'grn_d2',:'cust_q')) AS upd_to_q \gset
RESET ROLE;
SELECT pg_temp.oi_assert(:'upd_to_q'::jsonb->>'raised'='Business is not active' AND :'upd_to_q'::jsonb->>'state'='P0001'
 AND (SELECT customer_id=:'cust_d'::uuid FROM public.goodsreceived WHERE id=:'grn_d2'::uuid),
 'update_grn: a move to a deleted business is refused, the GRN stays with D: '||:'upd_to_q');

-- the customer login still reads the past records of the deactivated D
SELECT set_config('request.jwt.claims',:'customer_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_grn_details(:'grn_d'::uuid) AS cust_grn \gset
SELECT public.get_customer_grn_items(:'cust_d'::uuid) AS cust_items \gset
SELECT public.get_customer_stock_summary(:'cust_d'::uuid) AS cust_stock \gset
RESET ROLE;
SELECT pg_temp.oi_assert((:'cust_grn'::jsonb->>'success')='true' AND position('OI82A' IN :'cust_grn')>0
 AND position('Open Items Ginger' IN :'cust_items')>0 AND position('Open Items Ginger' IN :'cust_stock')>0,
 'customer login reads GRN, GRN items and stock of its deactivated business: '||left(:'cust_grn',200)||left(:'cust_items',200)||left(:'cust_stock',200));

-- the staff picker: a known active business IS found (positive control), the deactivated one is not
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.search_customers('Open Items Business A') AS pick_active \gset
SELECT public.search_customers('Open Items D') AS pick_staff \gset
RESET ROLE;
SELECT pg_temp.oi_assert(position('Open Items Business A' IN :'pick_active')>0,'staff picker finds the active business A: '||:'pick_active');
SELECT pg_temp.oi_assert(position('Open Items D with data' IN :'pick_staff')=0,'staff picker hides the deactivated business: '||:'pick_staff');

-- staff and administrators still see the deactivated D (stock 10 bags in two GRNs) in the readers
INSERT INTO public.invoice(inv_fin_year,inv_no,gr_id,gr_no,customer_id,customer_name,inv_date,labour,tax_amount,total)
 VALUES (2026,8201,:'grn_d'::uuid,'OI82A',:'cust_d'::uuid,'Open Items D with data',current_date,0,0,0);
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_all_stock_summary()::text AS rd_a_stock, public.get_item_wise_stock_list()::text AS rd_a_wise,
  public.get_all_customer_activity_summary(current_date-1,current_date+1)::text AS rd_a_act,
  public.get_invoices_list(p_customer_id=>:'cust_d'::uuid)::text AS rd_a_inv,
  public.get_invoices_list()::text AS rd_a_inv_all \gset
RESET ROLE;
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_all_stock_summary()::text AS rd_s_stock, public.get_item_wise_stock_list()::text AS rd_s_wise,
  public.get_all_customer_activity_summary(current_date-1,current_date+1)::text AS rd_s_act,
  public.get_invoices_list(p_customer_id=>:'cust_d'::uuid)::text AS rd_s_inv,
  public.get_invoices_list()::text AS rd_s_inv_all \gset
RESET ROLE;
SELECT pg_temp.oi_assert(
  (SELECT (x#>>'{summary,total_quantity}')::int = 10
      AND (SELECT sum((c->>'total_stock')::int) FROM jsonb_array_elements(x->'customers') c) = 10
      AND jsonb_array_length(x->'customers') = 1
      AND x#>>'{customers,0,customer_id}' = :'cust_d'
    FROM (SELECT :'rd_a_stock'::jsonb x) q)
  AND (SELECT (x#>>'{summary,total_quantity}')::int = 10
      AND (SELECT sum((c->>'total_stock')::int) FROM jsonb_array_elements(x->'customers') c) = 10
    FROM (SELECT :'rd_s_stock'::jsonb x) q),
 'get_all_stock_summary: the deactivated business is listed and the rows add up to the totals (admin and staff): '||:'rd_a_stock'||:'rd_s_stock');
SELECT pg_temp.oi_assert(position('Open Items Ginger' IN :'rd_a_wise')>0 AND position('Open Items Ginger' IN :'rd_s_wise')>0,
 'get_item_wise_stock_list (all customers) lists the deactivated business stock: '||left(:'rd_a_wise',200)||left(:'rd_s_wise',200));
SELECT pg_temp.oi_assert(position('Open Items D with data' IN :'rd_a_act')>0 AND position('Open Items D with data' IN :'rd_s_act')>0,
 'get_all_customer_activity_summary lists the deactivated business: '||left(:'rd_a_act',200)||left(:'rd_s_act',200));
SELECT pg_temp.oi_assert(position('Open Items D with data' IN :'rd_a_inv')>0 AND position('Open Items D with data' IN :'rd_s_inv')>0
 AND position('Open Items D with data' IN :'rd_a_inv_all')>0 AND position('Open Items D with data' IN :'rd_s_inv_all')>0,
 'get_invoices_list lists the invoice of the deactivated business, with and without p_customer_id: '||left(:'rd_a_inv',200)||left(:'rd_s_inv',200));


-- A business without data is soft deleted (deleted_at set, active false), as the dropped safe_delete_customer did: E keeps its empty cart,
-- F has nothing.
UPDATE public.customers SET deleted_at = now(), active = false WHERE id IN (:'cust_e'::uuid, :'cust_f'::uuid);

-- get_orders_list leaves out the leftover empty cart of the now soft-deleted E, for admin and staff; G's order is listed
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_orders_list()::text AS ol_a_deleted \gset
RESET ROLE;
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_orders_list()::text AS ol_s_deleted \gset
RESET ROLE;
SELECT pg_temp.oi_assert((SELECT count(*)=1 FROM public.orders WHERE customer_id=:'cust_e'::uuid)
 AND position(:'cust_e' IN :'ol_a_deleted')=0 AND position(:'cust_e' IN :'ol_s_deleted')=0
 AND position(:'cust_g' IN :'ol_a_deleted')>0 AND position(:'cust_g' IN :'ol_s_deleted')>0,
 'get_orders_list: the empty cart of a deleted business is not listed, the order of a deactivated one is');

-- set_customer_active(true) brings a soft-deleted business back (F and E) and an inactive one (D); on an active one it answers that
-- it is already active
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.set_customer_active(:'cust_f'::uuid,true) AS sca_back \gset
SELECT public.set_customer_active(:'cust_e'::uuid,true) AS rest_e \gset
SELECT public.set_customer_active(:'cust_d'::uuid,true) AS rest_d \gset
SELECT public.set_customer_active(:'cust_d'::uuid,true) AS rest_d_again \gset
RESET ROLE;
SELECT pg_temp.oi_assert((:'sca_back'::jsonb->>'success')='true' AND (:'sca_back'::jsonb#>'{data,active}')='true'::jsonb
 AND (SELECT active AND deleted_at IS NULL AND deleted_by IS NULL FROM public.customers WHERE id=:'cust_f'::uuid),
 'set_customer_active(true): a soft-deleted business is active again, deleted_at cleared: '||:'sca_back');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_orders_list()::text AS ol_a_restored \gset
RESET ROLE;
SELECT pg_temp.oi_assert(position(:'cust_e' IN :'ol_a_restored')>0,'get_orders_list: the order of the restored business E is listed again');
SELECT pg_temp.oi_assert((:'rest_e'::jsonb->>'success')='true' AND (:'rest_d'::jsonb->>'success')='true'
 AND (SELECT active AND deleted_at IS NULL FROM public.customers WHERE id=:'cust_e'::uuid)
 AND (SELECT active AND deleted_at IS NULL FROM public.customers WHERE id=:'cust_d'::uuid)
 AND (:'rest_d_again'::jsonb->>'success')='true' AND (:'rest_d_again'::jsonb->>'message') LIKE '%already active%',
 'set_customer_active(true): a deleted and an inactive business become active, an active one is already active: '||:'rest_e'||:'rest_d'||:'rest_d_again');

-- Data fix of migration 82 (the same statement the migration runs once): a soft-deleted business WITH data of
-- any kind (GRN+invoice D, payment J, rate K, active assignment L, deleted GRN M, deleted dispatch N, a not-OPEN
-- order G, an order with a line R) becomes deactivated (deleted_at cleared, active false); one without data (I)
-- stays deleted.
INSERT INTO public.customers(name,mobile) VALUES ('Open Items R order with line','9555560225') RETURNING id AS cust_r \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'cust_r'::uuid) AS cart_r \gset
RESET ROLE;
INSERT INTO public.order_items(order_id,requested_quantity,grn_items_id,grn_items_item_id,grn_items_item_name,grn_items_package_mark,
  grn_items_packaging,grn_items_rack,grn_items_weight,grns_id,grns_gr_no,grns_date,grns_customer_id,grns_customer_name,item_status)
 SELECT :'cart_r'::uuid,1,t.id,:'item_id'::uuid,'Open Items Ginger','-','Bag','A1',10,g.id,g.gr_no,g.date,g.customer_id,g.customer_name,'pending'
 FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.id=:'grn_d'::uuid LIMIT 1;
UPDATE public.customers SET deleted_at=now(), active=false
 WHERE id IN (:'cust_d'::uuid,:'cust_g'::uuid,:'cust_i'::uuid,:'cust_j'::uuid,:'cust_k'::uuid,:'cust_l'::uuid,:'cust_m'::uuid,:'cust_n'::uuid,:'cust_r'::uuid);
UPDATE public.customers c SET deleted_at = NULL, deleted_by = NULL, active = false
  WHERE c.deleted_at IS NOT NULL
    AND (EXISTS (SELECT 1 FROM public.goodsreceived WHERE customer_id = c.id)
      OR EXISTS (SELECT 1 FROM public.dispatch WHERE customer_id = c.id)
      OR EXISTS (SELECT 1 FROM public.invoice WHERE customer_id = c.id)
      OR EXISTS (SELECT 1 FROM public.payments WHERE customer_id = c.id)
      OR EXISTS (SELECT 1 FROM public.item_storage_prices WHERE customer_id = c.id)
      OR EXISTS (SELECT 1 FROM public.users_customers_new WHERE customer_id = c.id AND active)
      OR EXISTS (SELECT 1 FROM public.orders o WHERE o.customer_id = c.id
                 AND (o.status <> 'OPEN' OR EXISTS (SELECT 1 FROM public.order_items oi WHERE oi.order_id = o.id))));
SELECT pg_temp.oi_assert((SELECT bool_and(deleted_at IS NULL AND NOT active) AND count(*)=8 FROM public.customers
   WHERE id IN (:'cust_d'::uuid,:'cust_g'::uuid,:'cust_j'::uuid,:'cust_k'::uuid,:'cust_l'::uuid,:'cust_m'::uuid,:'cust_n'::uuid,:'cust_r'::uuid))
 AND (SELECT deleted_at IS NOT NULL FROM public.customers WHERE id=:'cust_i'::uuid),
 'data fix: a business with a GRN, payment, rate, active assignment, deleted GRN, deleted dispatch, not-OPEN order or order line is deactivated not deleted; one without data stays deleted');
ROLLBACK;

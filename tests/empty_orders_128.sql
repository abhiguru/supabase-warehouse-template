-- Migration 128, section 4: no empty orders.
--   * An order is made by its first line (add_item_to_order with p_customer_id), never by reading it (get_customer_order).
--   * An order without a line is not listed by get_orders_list, whatever p_has_items says; its row, number and history stay.
--   * A line that comes back (the first line again, or a dispatch delete that gives lines back) makes the order appear again.
--   * add_item_to_order keeps working with an order id (the call of the released app) and still refuses another customer's item.
--   * get_or_create_cart (the released app's open) makes an invisible row; it no longer shows an "empty order".
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database. Every row rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.emp_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'empty orders: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.emp_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM pg_temp.emp_assert(challenge->>'success'='true','ordinary challenge');
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  login := public.operator_verify_otp(phone,challenge#>>'{data,otp_code}');
  PERFORM pg_temp.emp_assert(login#>>'{data,action}'='login','ordinary login');
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id=p.auth_user_id
    WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
CREATE FUNCTION pg_temp.emp_refused(statement text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE statement;
  EXCEPTION WHEN insufficient_privilege THEN RETURN true; END;
  RETURN false;
END $$;
-- How many orders of this customer the list shows, for p_has_items null, true and false.
CREATE FUNCTION pg_temp.emp_listed(customer uuid, has_items boolean DEFAULT NULL) RETURNS integer LANGUAGE sql AS $$
  SELECT jsonb_array_length(public.get_orders_list(p_customer_id => customer, p_has_items => has_items)#>'{data,orders}') $$;

INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888888821','Empty Orders Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888822','Empty Orders Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888823','Empty Orders A Reader','customer',true,'approved');
SELECT pg_temp.emp_login('9888888821') AS admin_claims \gset
SELECT pg_temp.emp_login('9888888822') AS staff_claims \gset
SELECT pg_temp.emp_login('9888888823') AS reader_claims \gset
INSERT INTO public.customers(name,mobile) VALUES ('Empty Orders Customer A','9888888871') RETURNING id AS customer_a \gset
INSERT INTO public.customers(name,mobile) VALUES ('Empty Orders Customer B','9888888872') RETURNING id AS customer_b \gset
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active)
 SELECT id,:'customer_a'::uuid,true FROM public.user_profiles WHERE mobile='919888888823';
INSERT INTO public.items(name,packaging) VALUES ('Empty Orders Onions','Bag') RETURNING id AS onion_item \gset
INSERT INTO public.items(name,packaging) VALUES ('Empty Orders Garlic','Bag') RETURNING id AS garlic_item \gset
INSERT INTO public.items(name,packaging) VALUES ('Empty Orders Beans','Bag') RETURNING id AS bean_item \gset
INSERT INTO public.items(name,packaging) VALUES ('Empty Orders Rice','Bag') RETURNING id AS rice_item \gset

SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_grn(p_gr_no=>'EMPA',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_a'::uuid,p_customer_name=>'Empty Orders Customer A',
 p_items=>jsonb_build_array(
  jsonb_build_object('item_id',:'onion_item','item_name','Empty Orders Onions','packaging','Bag','qty',20,'weight',10,'rack','R1'),
  jsonb_build_object('item_id',:'garlic_item','item_name','Empty Orders Garlic','packaging','Bag','qty',10,'weight',10,'rack','R2'),
  jsonb_build_object('item_id',:'bean_item','item_name','Empty Orders Beans','packaging','Bag','qty',10,'weight',10,'rack','R3')),
 p_idempotency_key=>'empty-grn-a') AS grn_a_answer \gset
SELECT public.save_grn(p_gr_no=>'EMPB',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_b'::uuid,p_customer_name=>'Empty Orders Customer B',
 p_items=>jsonb_build_array(
  jsonb_build_object('item_id',:'rice_item','item_name','Empty Orders Rice','packaging','Bag','qty',10,'weight',10,'rack','R4')),
 p_idempotency_key=>'empty-grn-b') AS grn_b_answer \gset
RESET ROLE;
SELECT pg_temp.emp_assert(:'grn_a_answer'::jsonb->>'success'='true' AND :'grn_b_answer'::jsonb->>'success'='true','receipts: '||:'grn_a_answer'||:'grn_b_answer');
SELECT t.id AS lot_onion FROM public.goodsreceived_trl t WHERE t.item_name='Empty Orders Onions' \gset
SELECT t.id AS lot_garlic FROM public.goodsreceived_trl t WHERE t.item_name='Empty Orders Garlic' \gset
SELECT t.id AS lot_bean FROM public.goodsreceived_trl t WHERE t.item_name='Empty Orders Beans' \gset
SELECT t.id AS lot_rice FROM public.goodsreceived_trl t WHERE t.item_name='Empty Orders Rice' \gset

-- 1. Reading an order makes none. A customer with no order: exists false, and no row appears.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_customer_order(:'customer_a'::uuid) AS read_none \gset
RESET ROLE;
SELECT pg_temp.emp_assert(:'read_none'::jsonb->>'success'='true' AND :'read_none'::jsonb#>>'{data,exists}'='false'
 AND :'read_none'::jsonb#>>'{data,order_id}' IS NULL AND (:'read_none'::jsonb#>>'{data,item_count}')::int=0,'no order yet: '||:'read_none');
SELECT pg_temp.emp_assert((SELECT count(*)=0 FROM public.orders WHERE customer_id IN (:'customer_a'::uuid,:'customer_b'::uuid)),'reading made no order row');

-- 2. The first line makes the order (a customer account, with its own customer id); the second line joins it.
SELECT set_config('request.jwt.claims',:'reader_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.add_item_to_order(p_grn_item_id=>:'lot_onion'::uuid,p_quantity=>5,p_customer_id=>:'customer_a'::uuid) AS first_line \gset
SELECT public.add_item_to_order(p_grn_item_id=>:'lot_garlic'::uuid,p_quantity=>2,p_customer_id=>:'customer_a'::uuid) AS second_line \gset
SELECT public.get_customer_order(:'customer_a'::uuid) AS read_one \gset
RESET ROLE;
SELECT pg_temp.emp_assert(:'first_line'::jsonb->>'success'='true' AND :'first_line'::jsonb#>>'{data,order_created}'='true'
 AND :'first_line'::jsonb#>>'{data,order_id}' IS NOT NULL AND :'first_line'::jsonb#>>'{data,order_no}' LIKE 'ORD-%','the first line makes the order: '||:'first_line');
SELECT :'first_line'::jsonb#>>'{data,order_id}' AS cart \gset
SELECT :'first_line'::jsonb#>>'{data,order_no}' AS order_no \gset
SELECT pg_temp.emp_assert(:'second_line'::jsonb->>'success'='true' AND :'second_line'::jsonb#>>'{data,order_created}'='false'
 AND :'second_line'::jsonb#>>'{data,order_id}'=:'cart','the second line joins it: '||:'second_line');
SELECT pg_temp.emp_assert((SELECT count(*)=1 AND bool_and(status='OPEN') FROM public.orders WHERE customer_id=:'customer_a'::uuid),'one OPEN order row for A');
SELECT pg_temp.emp_assert(:'read_one'::jsonb#>>'{data,exists}'='true' AND :'read_one'::jsonb#>>'{data,order_id}'=:'cart'
 AND (:'read_one'::jsonb#>>'{data,item_count}')::int=2 AND :'read_one'::jsonb#>>'{data,order_no}'=:'order_no' AND :'read_one'::jsonb#>>'{data,status}'='OPEN','the order is read: '||:'read_one');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.emp_assert(pg_temp.emp_listed(:'customer_a'::uuid)=1 AND pg_temp.emp_listed(:'customer_a'::uuid,true)=1 AND pg_temp.emp_listed(:'customer_a'::uuid,false)=0,'the order is listed');
RESET ROLE;

-- 3. The released app's call (an order id) still works, and the item/customer rules hold.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.add_item_to_order(:'cart'::uuid,:'lot_bean'::uuid,1) AS old_call \gset
SELECT public.add_item_to_order(p_order_id=>:'cart'::uuid,p_grn_item_id=>:'lot_bean'::uuid,p_quantity=>1) AS old_again \gset
SELECT public.add_item_to_order(p_grn_item_id=>:'lot_bean'::uuid,p_quantity=>1) AS no_target \gset
SELECT public.add_item_to_order(p_grn_item_id=>:'lot_bean'::uuid,p_quantity=>0,p_customer_id=>:'customer_a'::uuid) AS zero_qty \gset
RESET ROLE;
SELECT pg_temp.emp_assert(:'old_call'::jsonb->>'success'='true' AND :'old_call'::jsonb#>>'{data,order_created}'='false' AND :'old_call'::jsonb#>>'{data,order_id}'=:'cart'
 AND :'old_call'::jsonb#>>'{data,updated_at}' IS NOT NULL,'the call of the released app: '||:'old_call');
SELECT pg_temp.emp_assert(:'old_again'::jsonb->>'message'='Item already exists in order','the same lot twice is refused as before: '||:'old_again');
SELECT pg_temp.emp_assert(:'no_target'::jsonb->>'success'='false' AND :'no_target'::jsonb->>'message'='Order not found','neither an order nor a customer: '||:'no_target');
SELECT pg_temp.emp_assert(:'zero_qty'::jsonb->>'success'='false' AND :'zero_qty'::jsonb->>'message'='Quantity must be greater than zero','quantity rule: '||:'zero_qty');
SELECT set_config('request.jwt.claims',:'reader_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.emp_assert(pg_temp.emp_refused(format('SELECT public.add_item_to_order(p_grn_item_id=>%L::uuid,p_quantity=>1,p_customer_id=>%L::uuid)',:'lot_rice',:'customer_b')),
 'a customer account cannot make another customer''s order');
SELECT pg_temp.emp_assert(pg_temp.emp_refused(format('SELECT public.add_item_to_order(p_grn_item_id=>%L::uuid,p_quantity=>1,p_customer_id=>%L::uuid)',:'lot_rice',:'customer_a')),
 'another customer''s item does not go into the customer''s new order');
SELECT pg_temp.emp_assert(pg_temp.emp_refused(format('SELECT public.get_customer_order(%L::uuid)',:'customer_b')),'a customer account cannot read another customer''s order');
SELECT pg_temp.emp_assert(pg_temp.emp_refused('SELECT public.add_item_to_order()'),'no order and no customer: refused by the guard for a customer account');
RESET ROLE;

-- 4. The last line goes: the order is not listed any more, the row, its number and its history stay.
UPDATE public.orders SET note='Old note', priority='low' WHERE id=:'cart'::uuid;
SELECT count(*) AS revisions_before FROM public.order_revisions WHERE order_id=:'cart'::uuid \gset
SELECT id AS line_1 FROM public.order_items WHERE order_id=:'cart'::uuid AND grn_items_id=:'lot_onion'::uuid \gset
SELECT id AS line_2 FROM public.order_items WHERE order_id=:'cart'::uuid AND grn_items_id=:'lot_garlic'::uuid \gset
SELECT id AS line_3 FROM public.order_items WHERE order_id=:'cart'::uuid AND grn_items_id=:'lot_bean'::uuid \gset
SET LOCAL ROLE authenticated;
SELECT pg_temp.emp_assert(public.remove_item_from_order(:'line_1'::uuid)->>'success'='true' AND public.remove_item_from_order(:'line_2'::uuid)->>'success'='true','two lines removed');
SELECT pg_temp.emp_assert(pg_temp.emp_listed(:'customer_a'::uuid)=1,'with one line left the order is listed');
SELECT pg_temp.emp_assert(public.remove_item_from_order(:'line_3'::uuid)->>'success'='true','the last line removed');
SELECT pg_temp.emp_assert(pg_temp.emp_listed(:'customer_a'::uuid)=0 AND pg_temp.emp_listed(:'customer_a'::uuid,true)=0 AND pg_temp.emp_listed(:'customer_a'::uuid,false)=0,
 'an order without a line is not listed, whatever p_has_items says');
SELECT pg_temp.emp_assert(jsonb_array_length(public.get_orders_list()#>'{data,orders}')=0,'the unfiltered list is empty too');
SELECT public.get_customer_order(:'customer_a'::uuid) AS read_empty \gset
RESET ROLE;
SELECT pg_temp.emp_assert(:'read_empty'::jsonb#>>'{data,exists}'='false','the emptied order reads as no order yet: '||:'read_empty');
SELECT pg_temp.emp_assert((SELECT count(*)=1 FROM public.orders WHERE id=:'cart'::uuid AND order_no=:'order_no')
 AND (SELECT count(*)>:'revisions_before'::int FROM public.order_revisions WHERE order_id=:'cart'::uuid),'the row, its number and its history stay');

-- 4b. A refused first line writes nothing: the emptied order keeps its note, priority and status when the lot is unknown or the stock is short.
UPDATE public.orders SET status='DISPATCHED' WHERE id=:'cart'::uuid;
SELECT updated_at AS order_stamp FROM public.orders WHERE id=:'cart'::uuid \gset
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.add_item_to_order(p_grn_item_id=>gen_random_uuid(),p_quantity=>1,p_customer_id=>:'customer_a'::uuid) AS refused_unknown \gset
SELECT public.add_item_to_order(p_grn_item_id=>:'lot_onion'::uuid,p_quantity=>1000000,p_customer_id=>:'customer_a'::uuid) AS refused_stock \gset
RESET ROLE;
SELECT pg_temp.emp_assert(:'refused_unknown'::jsonb->>'success'='false' AND :'refused_unknown'::jsonb->>'message'='GRN item not found'
 AND :'refused_stock'::jsonb->>'success'='false' AND :'refused_stock'::jsonb->>'message' LIKE 'Insufficient stock%','both are refused: '||:'refused_unknown'||:'refused_stock');
SELECT pg_temp.emp_assert((SELECT note='Old note' AND priority='low' AND status='DISPATCHED' AND updated_at=:'order_stamp'::timestamptz FROM public.orders WHERE id=:'cart'::uuid),
 'a refused first line left the emptied order as it was');
-- The customer's own account: short stock on the customer's lot is refused, and the emptied order is untouched.
SELECT set_config('request.jwt.claims',:'reader_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.add_item_to_order(p_grn_item_id=>:'lot_onion'::uuid,p_quantity=>1000000,p_customer_id=>:'customer_a'::uuid) AS refused_stock_customer \gset
SELECT pg_temp.emp_refused(format('SELECT public.add_item_to_order(p_grn_item_id=>%L::uuid,p_quantity=>1,p_customer_id=>%L::uuid)',gen_random_uuid(),:'customer_a')) AS refused_unknown_customer \gset
RESET ROLE;
SELECT pg_temp.emp_assert(:'refused_stock_customer'::jsonb->>'success'='false' AND :'refused_stock_customer'::jsonb->>'message' LIKE 'Insufficient stock%'
 AND :'refused_unknown_customer'='t','a customer is refused for short stock and for an unknown lot: '||:'refused_stock_customer'||:'refused_unknown_customer');
SELECT pg_temp.emp_assert((SELECT note='Old note' AND priority='low' AND status='DISPATCHED' AND updated_at=:'order_stamp'::timestamptz FROM public.orders WHERE id=:'cart'::uuid),
 'the customer refusals left the emptied order as it was');
UPDATE public.orders SET status='OPEN' WHERE id=:'cart'::uuid;

-- 5. The first line again: the same order row comes back, as a new order (note and priority reset), with its number and history.
SELECT set_config('request.jwt.claims',:'reader_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.add_item_to_order(p_grn_item_id=>:'lot_onion'::uuid,p_quantity=>5,p_customer_id=>:'customer_a'::uuid) AS again \gset
SELECT pg_temp.emp_listed(:'customer_a'::uuid) AS listed_again \gset
RESET ROLE;
SELECT pg_temp.emp_assert(:'again'::jsonb->>'success'='true' AND :'again'::jsonb#>>'{data,order_created}'='true' AND :'again'::jsonb#>>'{data,order_id}'=:'cart'
 AND :'again'::jsonb#>>'{data,order_no}'=:'order_no','the first line again starts the order again under its number: '||:'again');
SELECT pg_temp.emp_assert(:'listed_again'::int=1 AND (SELECT note IS NULL AND priority='normal' AND status='OPEN' FROM public.orders WHERE id=:'cart'::uuid),'it is listed, with the old note and priority gone');

-- 6. A dispatch that takes the whole line empties the order; deleting it gives the line back and the order is listed again.
SELECT jsonb_build_object('disp_no','EMPD1','disp_date','2026-05-02T12:00:00Z','customer_id',:'customer_a',
 'customer_name','Empty Orders Customer A','supervisor_id',:'admin_profile','supervisor_name','Empty Orders Administrator') AS header \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'header'::jsonb,ARRAY[jsonb_build_object('gr_trl_id',:'lot_onion','disp_qty',5)],false,0,'empty-d1') AS disp \gset
SELECT pg_temp.emp_listed(:'customer_a'::uuid) AS listed_after_dispatch \gset
RESET ROLE;
SELECT pg_temp.emp_assert(:'disp'::jsonb->>'success'='true' AND :'disp'::jsonb#>>'{order_effects,0,change}'='removed'
 AND (:'disp'::jsonb#>>'{order_effects,0,order_lines_left}')::int=0,'the dispatch took the whole line: '||:'disp');
SELECT pg_temp.emp_assert(:'listed_after_dispatch'::int=0,'the order is gone from the list');
SELECT :'disp'::jsonb->>'dispatch_id' AS dispatch_id \gset
SET LOCAL ROLE authenticated;
SELECT public.delete_dispatch_with_order_cleanup(:'dispatch_id'::uuid,:'admin_profile'::uuid) AS deleted \gset
SELECT pg_temp.emp_listed(:'customer_a'::uuid) AS listed_after_delete \gset
SELECT public.get_customer_order(:'customer_a'::uuid) AS read_back \gset
RESET ROLE;
SELECT pg_temp.emp_assert(:'deleted'::jsonb->>'success'='true' AND :'listed_after_delete'::int=1,'the delete gives the line back and the order is listed again: '||:'deleted');
SELECT pg_temp.emp_assert(:'read_back'::jsonb#>>'{data,exists}'='true' AND :'read_back'::jsonb#>>'{data,order_id}'=:'cart' AND (:'read_back'::jsonb#>>'{data,item_count}')::int=1,'the order is read again: '||:'read_back');

-- 7. The released app's open (get_or_create_cart) makes a row but no "empty order".
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'customer_b'::uuid) AS cart_b \gset
SELECT pg_temp.emp_listed(:'customer_b'::uuid) AS listed_b \gset
SELECT public.get_customer_order(:'customer_b'::uuid) AS read_b \gset
SELECT public.add_item_to_order(p_order_id=>:'cart_b'::uuid,p_grn_item_id=>:'lot_rice'::uuid,p_quantity=>3) AS b_line \gset
SELECT pg_temp.emp_listed(:'customer_b'::uuid) AS listed_b_after \gset
RESET ROLE;
SELECT pg_temp.emp_assert(:'listed_b'::int=0 AND :'read_b'::jsonb#>>'{data,exists}'='false','opening makes no listed order: '||:'read_b');
SELECT pg_temp.emp_assert(:'b_line'::jsonb->>'success'='true' AND :'listed_b_after'::int=1,'its first line lists it: '||:'b_line');
SELECT pg_temp.emp_assert((SELECT count(*)=1 FROM public.orders WHERE customer_id=:'customer_b'::uuid),'one row for B throughout');
ROLLBACK;

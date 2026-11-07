-- Migration 156 (WH-129): deleting a dispatch no longer resets the other lines of its source order.
-- Two dispatches serve one order (dispatch 1 takes lot A, dispatch 2 takes lot B). Deleting dispatch 2 gives back what dispatch 2 took
-- (line B), leaves the line dispatch 1 serves (A) with its fulfilled quantity and status, leaves the out-of-stock and cancelled lines as
-- they were, and reopens the order. Deleting dispatch 1 afterwards gives A back. A direct dispatch (no source order) is unchanged.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database; rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.dod_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'dispatch delete other lines: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.dod_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.dod_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.dod_assert(l#>>'{data,action}'='login','login for '||phone);
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
SELECT warehouse_security.bootstrap_first_admin('9888888871','Delete Other Lines Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
SELECT pg_temp.dod_login('9888888871') AS admin_claims \gset

-- Fixture: receipt DOD1 with five lots (package marks A to E) and the customer's cart.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.dod_assert(public.create_customer('Delete Other Lines Customer','9888888872')->>'success'='true','customer');
SELECT pg_temp.dod_assert(public.create_item('Delete Other Lines Potatoes','Bag')->>'success'='true','catalog item');
SELECT id AS customer_id FROM public.customers WHERE name='Delete Other Lines Customer' \gset
SELECT id AS item_id FROM public.items WHERE name='Delete Other Lines Potatoes' \gset
SELECT pg_temp.dod_assert(public.save_grn(p_gr_no=>'DOD1',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_id'::uuid,
 p_customer_name=>'Delete Other Lines Customer',p_pricing_mode=>'MONTHLY',
 p_items=>(SELECT jsonb_agg(jsonb_build_object('item_id',:'item_id','item_name','Delete Other Lines Potatoes',
   'packaging','Bag','qty',q,'weight',5,'rack','R1','package_mark',m))
   FROM (VALUES ('A',10),('B',5),('C',10),('D',10),('E',10)) AS l(m,q)))->>'success'='true','receipt DOD1');
RESET ROLE;
SELECT t.id AS lot_a FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DOD1' AND t.package_mark='A' \gset
SELECT t.id AS lot_b FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DOD1' AND t.package_mark='B' \gset
SELECT t.id AS lot_c FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DOD1' AND t.package_mark='C' \gset
SELECT t.id AS lot_d FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DOD1' AND t.package_mark='D' \gset
SELECT t.id AS lot_e FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DOD1' AND t.package_mark='E' \gset
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'customer_id'::uuid) AS cart \gset
SELECT pg_temp.dod_assert(public.add_item_to_order(:'cart'::uuid,:'lot_a'::uuid,10)->>'success'='true','10 of A in the cart');
SELECT pg_temp.dod_assert(public.add_item_to_order(:'cart'::uuid,:'lot_b'::uuid,3)->>'success'='true','3 of B in the cart');
SELECT pg_temp.dod_assert(public.add_item_to_order(:'cart'::uuid,:'lot_c'::uuid,10)->>'success'='true','10 of C in the cart');
SELECT pg_temp.dod_assert(public.add_item_to_order(:'cart'::uuid,:'lot_d'::uuid,10)->>'success'='true','10 of D in the cart');
SELECT pg_temp.dod_assert(public.add_item_to_order(:'cart'::uuid,:'lot_e'::uuid,7)->>'success'='true','7 of E in the cart');
RESET ROLE;
-- Two lines of the cart that the dispatch does not touch carry other states.
UPDATE public.order_items SET item_status='out_of_stock' WHERE order_id=:'cart'::uuid AND grn_items_id=:'lot_c'::uuid;
UPDATE public.order_items SET item_status='cancelled' WHERE order_id=:'cart'::uuid AND grn_items_id=:'lot_d'::uuid;
SELECT jsonb_build_object('disp_date','2026-06-01','customer_id',:'customer_id','customer_name','Delete Other Lines Customer',
 'supervisor_id',:'admin_profile','supervisor_name','Delete Other Lines Administrator') AS header \gset

CREATE FUNCTION pg_temp.dod_lines(p_order uuid) RETURNS jsonb LANGUAGE sql AS $$
  SELECT COALESCE(jsonb_object_agg(t.package_mark, oi.fulfilled_quantity || ' ' || oi.item_status), '{}'::jsonb)
  FROM public.order_items oi JOIN public.goodsreceived_trl t ON t.id = oi.grn_items_id WHERE oi.order_id = p_order $$;

-- Dispatch 1 serves line A, dispatch 2 serves line B, both from the cart.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.dod_assert((public.create_dispatch_with_stock_check(:'header'::jsonb || jsonb_build_object('disp_no','DODX1','source_order_id',:'cart'),
  ARRAY[jsonb_build_object('gr_trl_id',:'lot_a','disp_qty',4)],0,'dod-key-1')->>'success')::boolean, 'dispatch 1 from the cart');
SELECT pg_temp.dod_assert((public.create_dispatch_with_stock_check(:'header'::jsonb || jsonb_build_object('disp_no','DODX2','source_order_id',:'cart'),
  ARRAY[jsonb_build_object('gr_trl_id',:'lot_b','disp_qty',3)],0,'dod-key-2')->>'success')::boolean, 'dispatch 2 from the cart');
RESET ROLE;
SELECT id AS disp1 FROM public.dispatch WHERE disp_no='DODX1' \gset
SELECT id AS disp2 FROM public.dispatch WHERE disp_no='DODX2' \gset
-- Since migration 67 a cart dispatch takes its quantity off the cart line (a line dispatched in full disappears; the delete gives it back).
-- The lines below carry a fulfilled quantity and a status of their own, as older data and the app's order screens can: A (part of it was
-- taken by dispatch 1) and E (not touched by either dispatch) are partially fulfilled by hand; C is out of stock and D cancelled.
UPDATE public.order_items SET fulfilled_quantity = 2, item_status = 'partially_fulfilled' WHERE order_id = :'cart'::uuid AND grn_items_id = :'lot_a'::uuid;
UPDATE public.order_items SET fulfilled_quantity = 3, item_status = 'partially_fulfilled' WHERE order_id = :'cart'::uuid AND grn_items_id = :'lot_e'::uuid;
SELECT pg_temp.dod_lines(:'cart'::uuid) AS before_delete \gset
SELECT pg_temp.dod_assert((:'before_delete'::jsonb->>'A') = '2 partially_fulfilled' AND (:'before_delete'::jsonb->>'E') = '3 partially_fulfilled'
  AND (:'before_delete'::jsonb->>'C') = '0 out_of_stock' AND (:'before_delete'::jsonb->>'D') = '0 cancelled' AND NOT (:'before_delete'::jsonb ? 'B'),
  'premise: A and E partly fulfilled, C out of stock, D cancelled, B dispatched in full: ' || :'before_delete');

-- Deleting dispatch 2.
SET LOCAL ROLE authenticated;
SELECT public.delete_dispatch_with_order_cleanup(:'disp2'::uuid, :'admin_profile'::uuid) AS deleted_2 \gset
RESET ROLE;
SELECT pg_temp.dod_assert((:'deleted_2'::jsonb->>'success')::boolean, 'dispatch 2 is deleted: ' || :'deleted_2');
SELECT pg_temp.dod_lines(:'cart'::uuid) AS after_delete \gset
SELECT pg_temp.dod_assert((:'after_delete'::jsonb->>'A') = '2 partially_fulfilled' AND (:'after_delete'::jsonb->>'E') = '3 partially_fulfilled',
  'the lines other dispatches served or nobody touched keep their fulfilled quantity and status: ' || :'before_delete' || ' -> ' || :'after_delete');
SELECT pg_temp.dod_assert((:'after_delete'::jsonb->>'B') = '0 pending', 'the line dispatch 2 served is given back: ' || :'after_delete');
SELECT pg_temp.dod_assert((:'after_delete'::jsonb->>'C') = '0 out_of_stock' AND (:'after_delete'::jsonb->>'D') = '0 cancelled',
  'the out-of-stock and cancelled lines keep their states: ' || :'after_delete');
SELECT pg_temp.dod_assert((SELECT status = 'OPEN' AND deleted_at IS NULL FROM public.orders WHERE id = :'cart'::uuid), 'the order is open');
SELECT pg_temp.dod_assert((SELECT stock FROM public.goodsreceived_trl WHERE id = :'lot_a'::uuid) = 6
  AND (SELECT stock FROM public.goodsreceived_trl WHERE id = :'lot_b'::uuid) = 5, 'stock: A still 6 (4 taken), B back to 5');

-- Deleting dispatch 1 gives line A back.
SET LOCAL ROLE authenticated;
SELECT public.delete_dispatch_with_order_cleanup(:'disp1'::uuid, :'admin_profile'::uuid) AS deleted_1 \gset
RESET ROLE;
SELECT pg_temp.dod_assert((:'deleted_1'::jsonb->>'success')::boolean, 'dispatch 1 is deleted');
SELECT pg_temp.dod_assert((pg_temp.dod_lines(:'cart'::uuid)->>'C') = '0 out_of_stock' AND (pg_temp.dod_lines(:'cart'::uuid)->>'D') = '0 cancelled' AND (pg_temp.dod_lines(:'cart'::uuid)->>'E') = '3 partially_fulfilled', 'after the second delete C, D and E are still as they were: ' || pg_temp.dod_lines(:'cart'::uuid)::text);
SELECT pg_temp.dod_assert((SELECT stock FROM public.goodsreceived_trl WHERE id = :'lot_a'::uuid) = 10, 'stock of A is back');

-- The trigger no longer touches the lines at all: a line set by hand stays when a dispatch of the order is deleted directly.
SELECT pg_temp.dod_assert(position('UPDATE order_items' IN pg_get_functiondef('public.restore_stock_on_dispatch_delete()'::regprocedure)) = 0
  AND position('WH-129' IN pg_get_functiondef('public.restore_stock_on_dispatch_delete()'::regprocedure)) > 0, 'the trigger function no longer resets order lines');
ROLLBACK;
\echo 'Dispatch delete keeps the other order lines (migration 156) checks passed.'

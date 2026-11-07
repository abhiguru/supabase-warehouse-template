-- Migration 161 (WH-113): a business has one order row for good. When it is soft-deleted:
--   * get_or_create_cart reuses it (same id, deleted_at and deleted_by cleared, status OPEN);
--   * add_item_to_order with p_customer_id reuses it instead of answering 'Order not found';
--   * the reused order restarts empty: its old lines are removed and ONE order revision (action UPDATE, changes.removed_items) records them;
--     a soft-deleted order with no lines writes no revision.
--   * add_item_to_order with an order id refuses a deleted business (BUSINESS_NOT_ACTIVE) and accepts a deactivated one.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database; rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.o_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'orders deleted row 161: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.o_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  login := public.operator_verify_otp(phone,challenge#>>'{data,otp_code}');
  PERFORM pg_temp.o_assert(login#>>'{data,action}'='login','login');
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id=p.auth_user_id
    WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888888881','Order Reuse Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
SELECT pg_temp.o_login('9888888881') AS admin_claims \gset
INSERT INTO public.customers(name,mobile) VALUES ('Order Reuse Customer One','9888888891') RETURNING id AS cust1 \gset
INSERT INTO public.customers(name,mobile) VALUES ('Order Reuse Customer Two','9888888892') RETURNING id AS cust2 \gset
INSERT INTO public.customers(name,mobile) VALUES ('Order Reuse Customer Three','9888888893') RETURNING id AS cust3 \gset
INSERT INTO public.items(name,packaging) VALUES ('Order Reuse Onions','Bag') RETURNING id AS onion \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.o_assert(public.save_grn(p_gr_no=>'ORU1',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'cust1'::uuid,p_customer_name=>'Order Reuse Customer One',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'onion','item_name','Order Reuse Onions','packaging','Bag','qty',20,'weight',10,'rack','R1'),
   jsonb_build_object('item_id',:'onion','item_name','Order Reuse Onions','packaging','Bag','qty',20,'weight',10,'rack','R2')),
 p_idempotency_key=>'order-reuse-g1')->>'success'='true','receipt for customer one');
SELECT pg_temp.o_assert(public.save_grn(p_gr_no=>'ORU2',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'cust2'::uuid,p_customer_name=>'Order Reuse Customer Two',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'onion','item_name','Order Reuse Onions','packaging','Bag','qty',20,'weight',10,'rack','R1')),
 p_idempotency_key=>'order-reuse-g2')->>'success'='true','receipt for customer two');
SELECT pg_temp.o_assert(public.save_grn(p_gr_no=>'ORU3',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'cust3'::uuid,p_customer_name=>'Order Reuse Customer Three',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'onion','item_name','Order Reuse Onions','packaging','Bag','qty',20,'weight',10,'rack','R1')),
 p_idempotency_key=>'order-reuse-g3')->>'success'='true','receipt for customer three');
RESET ROLE;
SELECT t.id AS lot1a FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='ORU1' AND t.rack='R1' \gset
SELECT t.id AS lot1b FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='ORU1' AND t.rack='R2' \gset
SELECT t.id AS lot2 FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='ORU2' \gset
SELECT t.id AS lot3 FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='ORU3' \gset

-- ===== get_or_create_cart reuses a soft-deleted row and restarts it empty =====
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'cust1'::uuid) AS cart1 \gset
SELECT pg_temp.o_assert(public.add_item_to_order(:'cart1'::uuid,:'lot1a'::uuid,5)->>'success'='true' AND public.add_item_to_order(:'cart1'::uuid,:'lot1b'::uuid,7)->>'success'='true','two lines in the cart');
RESET ROLE;
UPDATE public.orders SET deleted_at=now(), deleted_by=:'admin_profile'::uuid WHERE id=:'cart1'::uuid;
SELECT count(*) AS revisions_before FROM public.order_revisions WHERE order_id=:'cart1'::uuid \gset
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'cust1'::uuid) AS cart1_again \gset
RESET ROLE;
SELECT pg_temp.o_assert(:'cart1_again' = :'cart1', 'the soft-deleted row is reused: same id');
SELECT pg_temp.o_assert((SELECT deleted_at IS NULL AND deleted_by IS NULL AND status='OPEN' FROM public.orders WHERE id=:'cart1'::uuid), 'it is open again and not deleted');
SELECT pg_temp.o_assert((SELECT count(*) FROM public.orders WHERE customer_id=:'cust1'::uuid)=1, 'still one order row for the business');
SELECT pg_temp.o_assert((SELECT count(*) FROM public.order_items WHERE order_id=:'cart1'::uuid)=0, 'the old lines are gone: the reused order restarts empty');
SELECT pg_temp.o_assert((SELECT count(*)=:'revisions_before'::bigint+1 FROM public.order_revisions WHERE order_id=:'cart1'::uuid), 'ONE revision records the removal');
SELECT pg_temp.o_assert((SELECT r.action='UPDATE' AND jsonb_array_length(r.entry#>'{changes,removed_items}')=2
    AND (SELECT sum((x->>'requested_quantity')::int) FROM jsonb_array_elements(r.entry#>'{changes,removed_items}') x)=12
    FROM public.order_revisions r WHERE r.order_id=:'cart1'::uuid ORDER BY r.id DESC LIMIT 1),
  'the revision is an UPDATE listing both removed lines (5 and 7 requested): '||(SELECT left(entry::text,400) FROM public.order_revisions WHERE order_id=:'cart1'::uuid ORDER BY id DESC LIMIT 1));
-- Reading it again changes nothing more.
SET LOCAL ROLE authenticated;
SELECT pg_temp.o_assert(public.get_or_create_cart(:'cust1'::uuid)=:'cart1'::uuid, 'a second read returns the same order');
RESET ROLE;
SELECT pg_temp.o_assert((SELECT count(*)=:'revisions_before'::bigint+1 FROM public.order_revisions WHERE order_id=:'cart1'::uuid), 'no second revision');

-- ===== an empty soft-deleted row writes no revision =====
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'cust2'::uuid) AS cart2 \gset
RESET ROLE;
UPDATE public.orders SET deleted_at=now(), deleted_by=:'admin_profile'::uuid WHERE id=:'cart2'::uuid;
SELECT count(*) AS revisions2_before FROM public.order_revisions WHERE order_id=:'cart2'::uuid \gset
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'cust2'::uuid) AS cart2_again \gset
RESET ROLE;
SELECT pg_temp.o_assert(:'cart2_again'=:'cart2' AND (SELECT deleted_at IS NULL AND status='OPEN' FROM public.orders WHERE id=:'cart2'::uuid)
  AND (SELECT count(*)=:'revisions2_before'::bigint FROM public.order_revisions WHERE order_id=:'cart2'::uuid), 'an empty deleted order is reused and writes no revision');

-- ===== add_item_to_order with a customer reuses the row (it answered "Order not found") =====
SET LOCAL ROLE authenticated;
SELECT pg_temp.o_assert(public.add_item_to_order(p_grn_item_id=>:'lot3'::uuid,p_quantity=>4,p_customer_id=>:'cust3'::uuid)->>'success'='true','a first line makes the order for customer three');
RESET ROLE;
SELECT id AS order3 FROM public.orders WHERE customer_id=:'cust3'::uuid \gset
UPDATE public.orders SET deleted_at=now(), deleted_by=:'admin_profile'::uuid WHERE id=:'order3'::uuid;
SET LOCAL ROLE authenticated;
SELECT public.add_item_to_order(p_grn_item_id=>:'lot3'::uuid,p_quantity=>2,p_customer_id=>:'cust3'::uuid) AS reuse_answer \gset
RESET ROLE;
SELECT pg_temp.o_assert(:'reuse_answer'::jsonb->>'success'='true', 'adding by customer to a soft-deleted order succeeds: '||:'reuse_answer');
SELECT pg_temp.o_assert((SELECT count(*)=1 FROM public.orders WHERE customer_id=:'cust3'::uuid)
  AND (SELECT id=:'order3'::uuid AND deleted_at IS NULL AND deleted_by IS NULL AND status='OPEN' FROM public.orders WHERE customer_id=:'cust3'::uuid), 'the same row is reopened, no second row');
SELECT pg_temp.o_assert((SELECT count(*)=1 AND max(requested_quantity)=2 FROM public.order_items WHERE order_id=:'order3'::uuid), 'only the new line (2) is in the order; the old line (4) was removed');
SELECT pg_temp.o_assert((SELECT jsonb_array_length(entry#>'{changes,removed_items}')=1 FROM public.order_revisions WHERE order_id=:'order3'::uuid AND entry#>'{changes,removed_items}' IS NOT NULL ORDER BY id DESC LIMIT 1),
  'the removed old line is recorded in one revision');

-- ===== add_item_to_order with an order id: a deleted business is refused, a deactivated one is not =====
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'cust2'::uuid) AS cart2_open \gset
RESET ROLE;
UPDATE public.customers SET active=false WHERE id=:'cust2'::uuid;
SET LOCAL ROLE authenticated;
SELECT public.add_item_to_order(:'cart2_open'::uuid,:'lot2'::uuid,1) AS deactivated_answer \gset
RESET ROLE;
SELECT pg_temp.o_assert(:'deactivated_answer'::jsonb->>'success'='true', 'a deactivated business still orders: '||:'deactivated_answer');
UPDATE public.customers SET deleted_at=now() WHERE id=:'cust2'::uuid;
SET LOCAL ROLE authenticated;
SELECT public.add_item_to_order(:'cart2_open'::uuid,:'lot2'::uuid,1) AS deleted_answer \gset
RESET ROLE;
SELECT pg_temp.o_assert(:'deleted_answer'::jsonb->>'success'='false' AND :'deleted_answer'::jsonb->>'message'='Business is not active'
  AND :'deleted_answer'::jsonb#>>'{error,code}'='BUSINESS_NOT_ACTIVE', 'a deleted business is refused on the order-id path: '||:'deleted_answer');
SELECT pg_temp.o_assert((SELECT count(*)=1 FROM public.order_items WHERE order_id=:'cart2_open'::uuid), 'the refused add wrote no line (one line from the deactivated add)');
ROLLBACK;
\echo 'Orders deleted row and business check (migration 161) checks passed.'

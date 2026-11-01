-- Migration 128, sections 1 and 2: the order history.
--   * A "Quantity changed" entry shows the GRN quantity, rack, weight and packaging of ITS OWN line when the GRN has more than one
--     line (the lookups used to return any line of the GRN).
--   * An order save writes the whole cart, but a line whose quantity did not change is not listed again: its first appearance (the
--     addition) stays, the "30 -> 30" entries are gone.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database. Every row rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.ocl_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'order change log: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.ocl_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM pg_temp.ocl_assert(challenge->>'success'='true','ordinary challenge');
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  login := public.operator_verify_otp(phone,challenge#>>'{data,otp_code}');
  PERFORM pg_temp.ocl_assert(login#>>'{data,action}'='login','ordinary login');
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
SELECT warehouse_security.bootstrap_first_admin('9888888801','History Administrator');
SELECT pg_temp.ocl_login('9888888801') AS admin_claims \gset
INSERT INTO public.customers(name,mobile) VALUES ('History Customer','9888888851') RETURNING id AS customer_id \gset
INSERT INTO public.items(name,packaging) VALUES ('History Onions','Bag') RETURNING id AS onion_id \gset
INSERT INTO public.items(name,packaging) VALUES ('History Chillies','Bag') RETURNING id AS chilli_id \gset

-- One GRN with two lines that differ in quantity, weight and rack.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_grn(p_gr_no=>'HIST1',p_date=>now(),p_customer_id=>:'customer_id'::uuid,p_customer_name=>'History Customer',
 p_items=>jsonb_build_array(
  jsonb_build_object('item_id',:'onion_id','item_name','History Onions','packaging','Bag','qty',144,'weight',40,'rack','A8','package_mark','M1'),
  jsonb_build_object('item_id',:'chilli_id','item_name','History Chillies','packaging','Bag','qty',93,'weight',25,'rack','A5','package_mark','M2')),
 p_idempotency_key=>'history-receipt') AS receipt \gset
RESET ROLE;
SELECT pg_temp.ocl_assert(:'receipt'::jsonb->>'success'='true','receipt saved: '||:'receipt');
SELECT t.id AS onion_lot FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='HIST1' AND t.item_name='History Onions' \gset
SELECT t.id AS chilli_lot FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='HIST1' AND t.item_name='History Chillies' \gset
SELECT pg_temp.ocl_assert((SELECT rack='A8' AND weight=40 FROM public.goodsreceived_trl WHERE id=:'onion_lot'::uuid)
 AND (SELECT rack='A5' AND weight=25 FROM public.goodsreceived_trl WHERE id=:'chilli_lot'::uuid),'fixture: the two lines differ');

-- The order: Onions 10 (added), Chillies 5 (the cart now lists Onions 10 again), Onions 7 (Chillies 5 again).
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'customer_id'::uuid) AS cart \gset
SELECT pg_temp.ocl_assert(public.add_item_to_order(:'cart'::uuid,:'onion_lot'::uuid,10)->>'success'='true','add Onions');
SELECT pg_temp.ocl_assert(public.add_item_to_order(:'cart'::uuid,:'chilli_lot'::uuid,5)->>'success'='true','add Chillies');
RESET ROLE;
SELECT id AS onion_line FROM public.order_items WHERE order_id=:'cart'::uuid AND grn_items_id=:'onion_lot'::uuid \gset
SET LOCAL ROLE authenticated;
SELECT pg_temp.ocl_assert(public.update_order_item_quantity(:'onion_line'::uuid,7)->>'success'='true','lower Onions');
SELECT public.get_order_change_log(p_order_id=>:'cart'::uuid) AS history \gset
RESET ROLE;
SELECT pg_temp.ocl_assert(:'history'::jsonb->>'success'='true','the history is read: '||:'history');

-- Backend 21: each entry shows its own line.
SELECT pg_temp.ocl_assert(
  (SELECT count(*)>0 AND bool_and(c#>>'{change_details,grn_details,grn_item_rack}'='A8'
      AND (c#>>'{change_details,grn_details,grn_item_weight}')::numeric=40
      AND (c#>>'{change_details,grn_details,grn_qty}')::int=144
      AND (c#>>'{change_details,grn_details,grn_quantity}')::int=144
      AND c#>>'{change_details,grn_details,grn_item_packaging}'='Bag')
   FROM jsonb_array_elements(:'history'::jsonb#>'{data,changes}') c WHERE c->>'item_name' LIKE '%History Onions'),
 'every Onions entry shows rack A8, weight 40 and 144 bags: '||:'history');
SELECT pg_temp.ocl_assert(
  (SELECT count(*)>0 AND bool_and(c#>>'{change_details,grn_details,grn_item_rack}'='A5'
      AND (c#>>'{change_details,grn_details,grn_item_weight}')::numeric=25
      AND (c#>>'{change_details,grn_details,grn_qty}')::int=93)
   FROM jsonb_array_elements(:'history'::jsonb#>'{data,changes}') c WHERE c->>'item_name' LIKE '%History Chillies'),
 'every Chillies entry shows rack A5, weight 25 and 93 bags: '||:'history');

-- Backend 22: three entries (Onions added, Onions lowered, Chillies added); the repeated 10 -> 10 and 5 -> 5 are gone.
SELECT pg_temp.ocl_assert((SELECT count(*)=3 FROM jsonb_array_elements(:'history'::jsonb#>'{data,changes}') c WHERE c->>'change_category'='order_level'),
 'three order-level entries: '||:'history');
SELECT pg_temp.ocl_assert((:'history'::jsonb#>>'{data,total_count}')::int=3 AND (:'history'::jsonb#>>'{data,has_more}')='false','the count follows the filter: '||:'history');
SELECT pg_temp.ocl_assert(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(:'history'::jsonb#>'{data,changes}') c
   WHERE c#>>'{change_details,quantity_change,change_type}'='changed'
      OR c#>>'{change_details,quantity_change,previous_quantity}'=c#>>'{change_details,quantity_change,new_quantity}'),'no entry has the same quantity before and after');
SELECT pg_temp.ocl_assert(
  (SELECT array_agg(c#>>'{change_details,quantity_change,change_type}' || ':' || (c#>>'{change_details,quantity_change,new_quantity}')
          ORDER BY c->>'item_name', c->>'change_timestamp')
   FROM jsonb_array_elements(:'history'::jsonb#>'{data,changes}') c)
  = ARRAY['added:5','added:10','decreased:7'],'the entries are Chillies added 5, Onions added 10, Onions decreased to 7: '||:'history');
ROLLBACK;

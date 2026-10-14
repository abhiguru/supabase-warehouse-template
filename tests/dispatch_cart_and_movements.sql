-- Migration 67: deleting a dispatch gives back the cart quantity it took, and
-- stock movements are logged once, with one sign rule ('dispatch' negative,
-- 'return' positive, quantity = balance_after - balance_before) (backend review
-- 2026-10-13, I4 and I5). Fictional data; runs only in migrations.sh's
-- disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.dcm_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'dispatch cart and movements: %',label; END IF; END $$;
-- The error text of a statement, or 'no error' when it succeeds.
CREATE FUNCTION pg_temp.dcm_error(statement text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE statement; EXCEPTION WHEN OTHERS THEN RETURN SQLERRM; END;
  RETURN 'no error';
END $$;
CREATE FUNCTION pg_temp.dcm_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.dcm_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.dcm_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
-- A lot's movements as "type quantity before>after (reference type)", sorted.
CREATE FUNCTION pg_temp.dcm_moves(lot uuid) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(string_agg(movement_type || ' ' || quantity || ' ' || balance_before || '>' || balance_after
                             || ' (' || COALESCE(reference_type,'-') || ')', ', '
                             ORDER BY movement_type, quantity, balance_before), 'none')
  FROM public.stock_movements WHERE gr_trl_id = lot
$$;
-- A cart line of a lot as "requested/fulfilled status", or 'no line'.
CREATE FUNCTION pg_temp.dcm_cart(cart uuid, lot uuid) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE((SELECT string_agg(requested_quantity || '/' || fulfilled_quantity || ' ' || item_status, ', ')
                   FROM public.order_items WHERE order_id = cart AND grn_items_id = lot), 'no line')
$$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888888881','Cart Movement Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
SELECT pg_temp.dcm_login('9888888881') AS admin_claims \gset

-- Fixture: receipt DCM1 with nine lots (package marks A to I) and the
-- customer's cart holding 10 of A, 3 of B, 10 of C and 10 of D.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.dcm_assert(public.create_customer('Cart Movement Customer','9888888882')->>'success'='true','customer');
SELECT pg_temp.dcm_assert(public.create_item('Cart Movement Potatoes','Bag')->>'success'='true','catalog item');
SELECT pg_temp.dcm_assert(public.create_item('Cart Movement Garlic','Bag')->>'success'='true','second catalog item');
SELECT id AS customer_id FROM public.customers WHERE name='Cart Movement Customer' \gset
SELECT id AS item_id FROM public.items WHERE name='Cart Movement Potatoes' \gset
SELECT id AS garlic_id FROM public.items WHERE name='Cart Movement Garlic' \gset
SELECT pg_temp.dcm_assert(public.save_grn(p_gr_no=>'DCM1',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_id'::uuid,
 p_customer_name=>'Cart Movement Customer',p_pricing_mode=>'MONTHLY',
 p_items=>(SELECT jsonb_agg(jsonb_build_object('item_id',CASE WHEN m='G' THEN :'garlic_id' ELSE :'item_id' END,
   'item_name',CASE WHEN m='G' THEN 'Cart Movement Garlic' ELSE 'Cart Movement Potatoes' END,
   'packaging','Bag','qty',q,'weight',5,'rack','R1','package_mark',m))
   FROM (VALUES ('A',10),('B',5),('C',10),('D',10),('E',10),('F',8),('G',5),('H',6),('I',10)) AS l(m,q)))->>'success'='true','receipt DCM1');
RESET ROLE;
SELECT t.id AS lot_a FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DCM1' AND t.package_mark='A' \gset
SELECT t.id AS lot_b FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DCM1' AND t.package_mark='B' \gset
SELECT t.id AS lot_c FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DCM1' AND t.package_mark='C' \gset
SELECT t.id AS lot_d FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DCM1' AND t.package_mark='D' \gset
SELECT t.id AS lot_e FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DCM1' AND t.package_mark='E' \gset
SELECT t.id AS lot_f FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DCM1' AND t.package_mark='F' \gset
SELECT t.id AS lot_g FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DCM1' AND t.package_mark='G' \gset
SELECT t.id AS lot_h FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DCM1' AND t.package_mark='H' \gset
SELECT t.id AS lot_i FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DCM1' AND t.package_mark='I' \gset
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'customer_id'::uuid) AS cart \gset
SELECT pg_temp.dcm_assert(public.add_item_to_order(:'cart'::uuid,:'lot_a'::uuid,10)->>'success'='true','10 of A in the cart');
SELECT pg_temp.dcm_assert(public.add_item_to_order(:'cart'::uuid,:'lot_b'::uuid,3)->>'success'='true','3 of B in the cart');
SELECT pg_temp.dcm_assert(public.add_item_to_order(:'cart'::uuid,:'lot_c'::uuid,10)->>'success'='true','10 of C in the cart');
SELECT pg_temp.dcm_assert(public.add_item_to_order(:'cart'::uuid,:'lot_d'::uuid,10)->>'success'='true','10 of D in the cart');
RESET ROLE;
-- The dispatch header used below, completed per dispatch.
SELECT jsonb_build_object('disp_date','2026-06-01','customer_id',:'customer_id','customer_name','Cart Movement Customer',
 'supervisor_id',:'admin_profile','supervisor_name','Cart Movement Administrator') AS header \gset

-- ---------------------------------------------------------------------------
-- I4 (a). The review's reproduction: the cart asks for 10 of A, a dispatch from
-- the cart takes 4 (the cart line drops to 6), and the dispatch is deleted.
-- Before migration 67 the cart line stayed at 6.
-- ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'header'::jsonb || jsonb_build_object('disp_no','DCMA','source_order_id',:'cart'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a','disp_qty',4)],0,'dcm-a') AS made \gset
SELECT pg_temp.dcm_assert(:'made'::jsonb->>'success'='true','dispatch DCMA: ' || :'made');
SELECT pg_temp.dcm_assert(pg_temp.dcm_cart(:'cart'::uuid,:'lot_a'::uuid)='6/0 pending','the cart line of A drops to 6');
RESET ROLE;
SELECT id AS disp_a FROM public.dispatch WHERE disp_no='DCMA' \gset
SELECT source_type || ' ' || cart_quantity_consumed AS recorded_a FROM public.dispatch_trl WHERE disp_id=:'disp_a'::uuid \gset
SELECT pg_temp.dcm_assert(:'recorded_a'='cart 4','the dispatch line records 4 taken from the cart: ' || :'recorded_a');
-- I5: the dispatch is logged once, as a negative 'dispatch' movement.
SELECT pg_temp.dcm_assert(pg_temp.dcm_moves(:'lot_a'::uuid)='dispatch -4 10>6 (dispatch)','creation logs -4: ' || pg_temp.dcm_moves(:'lot_a'::uuid));
SET LOCAL ROLE authenticated;
SELECT public.delete_dispatch_with_order_cleanup(:'disp_a'::uuid,:'admin_profile'::uuid) AS deleted_a \gset
RESET ROLE;
SELECT pg_temp.dcm_assert(:'deleted_a'::jsonb->>'success'='true','DCMA deleted: ' || :'deleted_a');
SELECT pg_temp.dcm_assert(pg_temp.dcm_cart(:'cart'::uuid,:'lot_a'::uuid)='10/0 pending',
 'the cart asks for 10 of A again: ' || pg_temp.dcm_cart(:'cart'::uuid,:'lot_a'::uuid));
SELECT pg_temp.dcm_assert((SELECT stock=10 FROM public.goodsreceived_trl WHERE id=:'lot_a'::uuid),'A is back to 10 in stock');
SELECT pg_temp.dcm_assert(:'deleted_a'::jsonb#>>'{order_restoration,items_updated}'='1'
 AND :'deleted_a'::jsonb#>>'{order_restoration,total_items_restored}'='1'
 AND :'deleted_a'::jsonb#>>'{cart_restoration,updates_made}'='1'
 AND :'deleted_a'::jsonb->>'cart_lines_not_restored'='0'
 AND :'deleted_a'::jsonb#>>'{cart_restoration,lines_not_restored}'='0'
 AND :'deleted_a'::jsonb->>'message' LIKE 'Dispatch DCMA deleted successfully. 1 linked order(s) reset, 1 order items restored/recreated,%'
 AND :'deleted_a'::jsonb->>'message' NOT LIKE '%not returned%','the answer counts one cart line restored: ' || :'deleted_a');
-- I5: the deletion logs the return, positive.
SELECT pg_temp.dcm_assert(pg_temp.dcm_moves(:'lot_a'::uuid)='dispatch -4 10>6 (dispatch), return 4 6>10 (dispatch_delete)',
 'deletion logs +4: ' || pg_temp.dcm_moves(:'lot_a'::uuid));

-- I4 (b). The cart asks for 3 of B and a dispatch from the cart takes all 5:
-- the cart line is deleted. Deleting the dispatch brings back one pending line
-- of 3 (before migration 67: a line of 5, marked fulfilled).
SET LOCAL ROLE authenticated;
SELECT pg_temp.dcm_assert(public.create_dispatch_with_stock_check(:'header'::jsonb || jsonb_build_object('disp_no','DCMB','source_order_id',:'cart'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_b','disp_qty',5)],0,'dcm-b')->>'success'='true','dispatch DCMB');
SELECT pg_temp.dcm_assert(pg_temp.dcm_cart(:'cart'::uuid,:'lot_b'::uuid)='no line','the cart line of B is used up');
RESET ROLE;
SELECT id AS disp_b FROM public.dispatch WHERE disp_no='DCMB' \gset
SET LOCAL ROLE authenticated;
SELECT public.delete_dispatch_with_order_cleanup(:'disp_b'::uuid,:'admin_profile'::uuid) AS deleted_b \gset
SELECT pg_temp.dcm_assert(pg_temp.dcm_cart(:'cart'::uuid,:'lot_b'::uuid)='3/0 pending',
 'one pending line of 3 comes back: ' || pg_temp.dcm_cart(:'cart'::uuid,:'lot_b'::uuid));
RESET ROLE;
SELECT pg_temp.dcm_assert(:'deleted_b'::jsonb#>>'{order_restoration,items_recreated}'='1','the answer counts the recreated line: ' || :'deleted_b');

-- I4 (c). A direct dispatch (not from the cart) of 4 of C also lowers the cart
-- line from 10 to 6; deleting it gives the 4 back.
SET LOCAL ROLE authenticated;
SELECT pg_temp.dcm_assert(public.create_dispatch_with_stock_check(:'header'::jsonb || jsonb_build_object('disp_no','DCMC'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_c','disp_qty',4)],0,'dcm-c')->>'success'='true','dispatch DCMC');
SELECT pg_temp.dcm_assert(pg_temp.dcm_cart(:'cart'::uuid,:'lot_c'::uuid)='6/0 pending','the direct dispatch lowers the cart line of C to 6');
RESET ROLE;
SELECT id AS disp_c FROM public.dispatch WHERE disp_no='DCMC' \gset
SET LOCAL ROLE authenticated;
SELECT public.delete_dispatch_with_order_cleanup(:'disp_c'::uuid,:'admin_profile'::uuid) AS deleted_c \gset
SELECT pg_temp.dcm_assert(pg_temp.dcm_cart(:'cart'::uuid,:'lot_c'::uuid)='10/0 pending',
 'the cart asks for 10 of C again: ' || pg_temp.dcm_cart(:'cart'::uuid,:'lot_c'::uuid));
RESET ROLE;

-- I4 (d). A line saved before migration 67 has no record of what it took (here
-- the record is cleared by hand). Nothing is given back for it, and the answer
-- says so.
SET LOCAL ROLE authenticated;
SELECT pg_temp.dcm_assert(public.create_dispatch_with_stock_check(:'header'::jsonb || jsonb_build_object('disp_no','DCMD','source_order_id',:'cart'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_d','disp_qty',4)],0,'dcm-d')->>'success'='true','dispatch DCMD');
RESET ROLE;
SELECT id AS disp_d FROM public.dispatch WHERE disp_no='DCMD' \gset
UPDATE public.dispatch_trl SET source_type='direct',source_order_item_id=NULL,cart_quantity_consumed=0 WHERE disp_id=:'disp_d'::uuid;
SET LOCAL ROLE authenticated;
SELECT public.delete_dispatch_with_order_cleanup(:'disp_d'::uuid,:'admin_profile'::uuid) AS deleted_d \gset
SELECT pg_temp.dcm_assert(pg_temp.dcm_cart(:'cart'::uuid,:'lot_d'::uuid)='6/0 pending','nothing is given back to D: ' || pg_temp.dcm_cart(:'cart'::uuid,:'lot_d'::uuid));
RESET ROLE;
SELECT pg_temp.dcm_assert(:'deleted_d'::jsonb->>'success'='true' AND :'deleted_d'::jsonb->>'cart_lines_not_restored'='1'
 AND :'deleted_d'::jsonb#>>'{cart_restoration,lines_not_restored}'='1'
 AND :'deleted_d'::jsonb->>'message' LIKE '% 1 cart line(s) were saved before cart quantities were recorded; their quantities were not returned to the order.',
 'the answer names the line not given back: ' || :'deleted_d');
SELECT pg_temp.dcm_assert((SELECT stock=10 FROM public.goodsreceived_trl WHERE id=:'lot_d'::uuid),'D''s stock is restored all the same');

-- ---------------------------------------------------------------------------
-- I5. Movements of a dispatch edited several times (direct dispatch of 4 of E).
-- ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.dcm_assert(public.create_dispatch_with_stock_check(:'header'::jsonb || jsonb_build_object('disp_no','DCME'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_e','disp_qty',4)],0,'dcm-e')->>'success'='true','dispatch DCME');
RESET ROLE;
SELECT id AS disp_e FROM public.dispatch WHERE disp_no='DCME' \gset
SELECT pg_temp.dcm_assert(pg_temp.dcm_moves(:'lot_e'::uuid)='dispatch -4 10>6 (dispatch)','creation: ' || pg_temp.dcm_moves(:'lot_e'::uuid));
-- The review's reproduction: saved again unchanged. Before migration 67 a second
-- "dispatch -4 10>6" was logged although nothing moved.
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_e'::uuid,NULL,ARRAY[jsonb_build_object('gr_trl_id',:'lot_e','disp_qty',4)]) AS resaved \gset
RESET ROLE;
SELECT pg_temp.dcm_assert(:'resaved'::jsonb->>'success'='true','resave: ' || :'resaved');
SELECT pg_temp.dcm_assert(pg_temp.dcm_moves(:'lot_e'::uuid)='dispatch -4 10>6 (dispatch)','an unchanged resave logs nothing: ' || pg_temp.dcm_moves(:'lot_e'::uuid));
-- 4 -> 6: two more leave.
SET LOCAL ROLE authenticated;
SELECT pg_temp.dcm_assert(public.update_dispatch_smart(:'disp_e'::uuid,NULL,ARRAY[jsonb_build_object('gr_trl_id',:'lot_e','disp_qty',6)])->>'success'='true','4 to 6');
RESET ROLE;
SELECT pg_temp.dcm_assert(pg_temp.dcm_moves(:'lot_e'::uuid)='dispatch -4 10>6 (dispatch), dispatch -2 6>4 (dispatch_update)',
 'a raised quantity logs -2: ' || pg_temp.dcm_moves(:'lot_e'::uuid));
-- 6 -> 3: three come back (before migration 67 logged as a 'dispatch' of +3).
SET LOCAL ROLE authenticated;
SELECT pg_temp.dcm_assert(public.update_dispatch_smart(:'disp_e'::uuid,NULL,ARRAY[jsonb_build_object('gr_trl_id',:'lot_e','disp_qty',3)])->>'success'='true','6 to 3');
RESET ROLE;
SELECT pg_temp.dcm_assert(pg_temp.dcm_moves(:'lot_e'::uuid)='dispatch -4 10>6 (dispatch), dispatch -2 6>4 (dispatch_update), return 3 4>7 (dispatch_update)',
 'a lowered quantity logs a return of +3: ' || pg_temp.dcm_moves(:'lot_e'::uuid));
-- Adding lot F (8) with E unchanged logs F only.
SET LOCAL ROLE authenticated;
SELECT pg_temp.dcm_assert(public.update_dispatch_smart(:'disp_e'::uuid,NULL,ARRAY[jsonb_build_object('gr_trl_id',:'lot_e','disp_qty',3),
 jsonb_build_object('gr_trl_id',:'lot_f','disp_qty',8)])->>'success'='true','F added');
RESET ROLE;
SELECT pg_temp.dcm_assert(pg_temp.dcm_moves(:'lot_f'::uuid)='dispatch -8 8>0 (dispatch)','the added lot logs -8: ' || pg_temp.dcm_moves(:'lot_f'::uuid));
SELECT pg_temp.dcm_assert((SELECT count(*)=3 FROM public.stock_movements WHERE gr_trl_id=:'lot_e'::uuid),'nothing new for E: ' || pg_temp.dcm_moves(:'lot_e'::uuid));
-- Every movement so far follows the sign rule.
SELECT pg_temp.dcm_assert((SELECT bool_and(quantity = balance_after - balance_before
   AND ((movement_type='dispatch' AND quantity < 0) OR (movement_type='return' AND quantity > 0)))
 FROM public.stock_movements WHERE gr_trl_id IN (:'lot_a'::uuid,:'lot_b'::uuid,:'lot_c'::uuid,:'lot_d'::uuid,:'lot_e'::uuid,:'lot_f'::uuid)),
 'dispatch is negative, return positive, quantity = after - before');
-- Deleting the dispatch logs both returns.
SET LOCAL ROLE authenticated;
SELECT pg_temp.dcm_assert(public.delete_dispatch_with_order_cleanup(:'disp_e'::uuid,:'admin_profile'::uuid)->>'success'='true','DCME deleted');
RESET ROLE;
SELECT pg_temp.dcm_assert(pg_temp.dcm_moves(:'lot_f'::uuid)='dispatch -8 8>0 (dispatch), return 8 0>8 (dispatch_delete)','F returned: ' || pg_temp.dcm_moves(:'lot_f'::uuid));
SELECT pg_temp.dcm_assert(position('return 3 7>10 (dispatch_delete)' IN pg_temp.dcm_moves(:'lot_e'::uuid))>0,'E returned: ' || pg_temp.dcm_moves(:'lot_e'::uuid));

-- A lot emptied long ago stays out of the recently emptied list after an
-- unchanged resave (before migration 67 the resave logged a new movement ending
-- at 0, so the lot showed as emptied today).
SET LOCAL ROLE authenticated;
SELECT pg_temp.dcm_assert(public.create_dispatch_with_stock_check(:'header'::jsonb || jsonb_build_object('disp_no','DCMG'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_g','disp_qty',5)],0,'dcm-g')->>'success'='true','dispatch DCMG empties G');
RESET ROLE;
SELECT id AS disp_g FROM public.dispatch WHERE disp_no='DCMG' \gset
UPDATE public.stock_movements SET created_at=now()-interval '400 days' WHERE gr_trl_id=:'lot_g'::uuid;
SET LOCAL ROLE authenticated;
SELECT pg_temp.dcm_assert(NOT (public.get_customer_stock_summary(:'customer_id'::uuid)->'out_of_stock_items') @> jsonb_build_array(jsonb_build_object('item_id',:'garlic_id')),
 'G, emptied 400 days ago, is not in the recently emptied list');
SELECT pg_temp.dcm_assert(public.update_dispatch_smart(:'disp_g'::uuid,NULL,ARRAY[jsonb_build_object('gr_trl_id',:'lot_g','disp_qty',5)])->>'success'='true','DCMG resaved');
SELECT pg_temp.dcm_assert(NOT (public.get_customer_stock_summary(:'customer_id'::uuid)->'out_of_stock_items') @> jsonb_build_array(jsonb_build_object('item_id',:'garlic_id')),
 'after an unchanged resave G is still not recently emptied');
RESET ROLE;

-- The database owner deleting a dispatch row with its lines (the trigger
-- restore_stock_on_dispatch_delete): before migration 67 its movement type
-- 'dispatch_deleted' broke the movement check and the delete failed.
SET LOCAL ROLE authenticated;
SELECT pg_temp.dcm_assert(public.create_dispatch_with_stock_check(:'header'::jsonb || jsonb_build_object('disp_no','DCMH'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_h','disp_qty',6)],0,'dcm-h')->>'success'='true','dispatch DCMH');
RESET ROLE;
SELECT id AS disp_h FROM public.dispatch WHERE disp_no='DCMH' \gset
SELECT pg_temp.dcm_error(format('DELETE FROM public.dispatch WHERE id=%L::uuid',:'disp_h')) AS owner_delete \gset
SELECT pg_temp.dcm_assert(:'owner_delete'='no error','the owner''s delete succeeds: ' || :'owner_delete');
SELECT pg_temp.dcm_assert((SELECT stock=6 FROM public.goodsreceived_trl WHERE id=:'lot_h'::uuid)
 AND NOT EXISTS (SELECT 1 FROM public.dispatch_trl WHERE disp_id=:'disp_h'::uuid),'the trigger restored H and removed the lines');
SELECT pg_temp.dcm_assert(pg_temp.dcm_moves(:'lot_h'::uuid)='dispatch -6 6>0 (dispatch), return 6 0>6 (dispatch_delete)',
 'the trigger logs the return: ' || pg_temp.dcm_moves(:'lot_h'::uuid));

-- The trigger caps the restore at the received quantity and logs what really
-- came back (follow-up review 2026-10-13). Lot I (10): a dispatch of 6 leaves
-- 4; the stock is then raised by hand to 7, so the owner's delete can give back
-- only 3. Before the fix the trigger logged "return 6 4>10".
SET LOCAL ROLE authenticated;
SELECT pg_temp.dcm_assert(public.create_dispatch_with_stock_check(:'header'::jsonb || jsonb_build_object('disp_no','DCMI'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_i','disp_qty',6)],0,'dcm-i')->>'success'='true','dispatch DCMI');
RESET ROLE;
UPDATE public.goodsreceived_trl SET stock=7 WHERE id=:'lot_i'::uuid;
SELECT pg_temp.dcm_error(format('DELETE FROM public.dispatch WHERE disp_no=%L','DCMI')) AS capped_delete \gset
SELECT pg_temp.dcm_assert(:'capped_delete'='no error','the owner''s delete of DCMI succeeds: ' || :'capped_delete');
SELECT pg_temp.dcm_assert((SELECT stock=10 FROM public.goodsreceived_trl WHERE id=:'lot_i'::uuid),'I is capped at 10');
SELECT pg_temp.dcm_assert(pg_temp.dcm_moves(:'lot_i'::uuid)='dispatch -6 10>4 (dispatch), return 3 7>10 (dispatch_delete)',
 'the capped restore logs the 3 that came back, from 7 to 10: ' || pg_temp.dcm_moves(:'lot_i'::uuid));

-- ---------------------------------------------------------------------------
-- A direct dispatch that used a cart line up (so its link is NULL) gives back
-- only to the customer's OPEN cart (follow-up review 2026-10-13). A second
-- customer's cart asks for 3 each of J, K and L; three direct dispatches of 5
-- use the three lines up.
-- ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.dcm_assert(public.create_customer('Cart Movement Second Customer','9888888883')->>'success'='true','second customer');
SELECT id AS customer2 FROM public.customers WHERE name='Cart Movement Second Customer' \gset
SELECT pg_temp.dcm_assert(public.save_grn(p_gr_no=>'DCM2',p_date=>'2026-04-02T12:00:00Z',p_customer_id=>:'customer2'::uuid,
 p_customer_name=>'Cart Movement Second Customer',p_pricing_mode=>'MONTHLY',
 p_items=>(SELECT jsonb_agg(jsonb_build_object('item_id',:'item_id','item_name','Cart Movement Potatoes',
   'packaging','Bag','qty',10,'weight',5,'rack','R2','package_mark',m)) FROM unnest(ARRAY['J','K','L']) AS l(m)))->>'success'='true','receipt DCM2');
RESET ROLE;
SELECT t.id AS lot_j FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DCM2' AND t.package_mark='J' \gset
SELECT t.id AS lot_k FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DCM2' AND t.package_mark='K' \gset
SELECT t.id AS lot_l FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DCM2' AND t.package_mark='L' \gset
SELECT :'header'::jsonb || jsonb_build_object('customer_id',:'customer2','customer_name','Cart Movement Second Customer') AS header2 \gset
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'customer2'::uuid) AS cart2 \gset
SELECT pg_temp.dcm_assert(public.add_item_to_order(:'cart2'::uuid,:'lot_j'::uuid,3)->>'success'='true','3 of J in the second cart');
SELECT pg_temp.dcm_assert(public.add_item_to_order(:'cart2'::uuid,:'lot_k'::uuid,3)->>'success'='true','3 of K in the second cart');
SELECT pg_temp.dcm_assert(public.add_item_to_order(:'cart2'::uuid,:'lot_l'::uuid,3)->>'success'='true','3 of L in the second cart');
SELECT pg_temp.dcm_assert(public.create_dispatch_with_stock_check(:'header2'::jsonb || jsonb_build_object('disp_no','DCMJ'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_j','disp_qty',5)],0,'dcm-j')->>'success'='true','direct dispatch DCMJ');
SELECT pg_temp.dcm_assert(public.create_dispatch_with_stock_check(:'header2'::jsonb || jsonb_build_object('disp_no','DCMK'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_k','disp_qty',5)],0,'dcm-k')->>'success'='true','direct dispatch DCMK');
SELECT pg_temp.dcm_assert(public.create_dispatch_with_stock_check(:'header2'::jsonb || jsonb_build_object('disp_no','DCML'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_l','disp_qty',5)],0,'dcm-l')->>'success'='true','direct dispatch DCML');
RESET ROLE;
SELECT pg_temp.dcm_assert((SELECT count(*)=0 FROM public.order_items WHERE order_id=:'cart2'::uuid),'the three cart lines are used up');
SELECT pg_temp.dcm_assert((SELECT count(*)=3 AND bool_and(dt.source_order_item_id IS NULL AND dt.cart_quantity_consumed=3)
  FROM public.dispatch_trl dt JOIN public.dispatch d ON d.id=dt.disp_id WHERE d.disp_no IN ('DCMJ','DCMK','DCML')),
 'each direct dispatch line records 3 taken, its link NULL');
SELECT id AS disp_j FROM public.dispatch WHERE disp_no='DCMJ' \gset
SELECT id AS disp_k FROM public.dispatch WHERE disp_no='DCMK' \gset
SELECT id AS disp_l FROM public.dispatch WHERE disp_no='DCML' \gset
-- (e) The cart is still OPEN: the 3 of J come back to it.
SET LOCAL ROLE authenticated;
SELECT public.delete_dispatch_with_order_cleanup(:'disp_j'::uuid,:'admin_profile'::uuid) AS deleted_j \gset
RESET ROLE;
SELECT pg_temp.dcm_assert(pg_temp.dcm_cart(:'cart2'::uuid,:'lot_j'::uuid)='3/0 pending'
 AND (SELECT status='OPEN' FROM public.orders WHERE id=:'cart2'::uuid),
 'J is given back to the OPEN cart: ' || pg_temp.dcm_cart(:'cart2'::uuid,:'lot_j'::uuid) || ' ' || :'deleted_j');
SELECT pg_temp.dcm_assert(:'deleted_j'::jsonb->>'cart_lines_without_open_cart'='0','no line without an open cart: ' || :'deleted_j');
-- (f) The cart is closed by hand. Deleting DCMK leaves the closed order as it
-- is (one order per customer, one_cart_per_customer: no other can be made) and
-- the answer counts the line. Before the fix the pending line of K went into
-- the closed order.
UPDATE public.orders SET status='DISPATCHED' WHERE id=:'cart2'::uuid;
SELECT to_jsonb(o)::text AS closed_before FROM public.orders o WHERE o.id=:'cart2'::uuid \gset
SET LOCAL ROLE authenticated;
SELECT public.delete_dispatch_with_order_cleanup(:'disp_k'::uuid,:'admin_profile'::uuid) AS deleted_k \gset
RESET ROLE;
SELECT pg_temp.dcm_assert(pg_temp.dcm_cart(:'cart2'::uuid,:'lot_k'::uuid)='no line',
 'nothing goes into the closed order: ' || pg_temp.dcm_cart(:'cart2'::uuid,:'lot_k'::uuid));
SELECT pg_temp.dcm_assert((SELECT to_jsonb(o)::text FROM public.orders o WHERE o.id=:'cart2'::uuid)=:'closed_before'
 AND (SELECT string_agg(grn_items_id::text || ' ' || requested_quantity, ',') FROM public.order_items WHERE order_id=:'cart2'::uuid)=:'lot_j' || ' 3'
 AND (SELECT count(*)=1 FROM public.orders WHERE customer_id=:'customer2'::uuid),
 'the closed order and its lines are untouched, and no other order is made');
SELECT pg_temp.dcm_assert(:'deleted_k'::jsonb->>'success'='true'
 AND :'deleted_k'::jsonb->>'cart_lines_without_open_cart'='1'
 AND :'deleted_k'::jsonb#>>'{cart_restoration,lines_without_open_cart}'='1'
 AND :'deleted_k'::jsonb->>'cart_lines_not_restored'='0'
 AND :'deleted_k'::jsonb->>'message' LIKE '% 1 cart line(s) were not returned: the customer has no open cart and one could not be made.',
 'the answer counts the line without an open cart: ' || :'deleted_k');
SELECT pg_temp.dcm_assert((SELECT stock=10 FROM public.goodsreceived_trl WHERE id=:'lot_k'::uuid),'K''s stock is restored all the same');
-- (g) The customer's order is gone: deleting DCML makes a new OPEN cart, as
-- get_or_create_cart would, holding the pending line of 3 of L. Before the fix
-- nothing was given back.
DELETE FROM public.orders WHERE id=:'cart2'::uuid;
SET LOCAL ROLE authenticated;
SELECT public.delete_dispatch_with_order_cleanup(:'disp_l'::uuid,:'admin_profile'::uuid) AS deleted_l \gset
RESET ROLE;
SELECT COALESCE((SELECT o.id FROM public.orders o WHERE o.customer_id=:'customer2'::uuid),'00000000-0000-0000-0000-000000000000') AS cart3 \gset
SELECT pg_temp.dcm_assert(:'cart3'::uuid <> :'cart2'::uuid
 AND (SELECT status='OPEN' AND priority='normal' AND customer_name='Cart Movement Second Customer' AND customer_phone IS NOT NULL
        AND created_by=:'admin_profile'::uuid AND deleted_at IS NULL FROM public.orders WHERE id=:'cart3'::uuid)
 AND pg_temp.dcm_cart(:'cart3'::uuid,:'lot_l'::uuid)='3/0 pending'
 AND :'deleted_l'::jsonb->>'cart_lines_without_open_cart'='0' AND :'deleted_l'::jsonb->>'cart_lines_not_restored'='0',
 'a new OPEN cart holds the pending line of L: ' || pg_temp.dcm_cart(:'cart3'::uuid,:'lot_l'::uuid) || ' ' || :'deleted_l');

-- The patched functions keep their rights, settings and grants.
SELECT pg_temp.dcm_assert(bool_and(p.prosecdef) AND count(*)=4,'the four patched functions are still SECURITY DEFINER')
FROM pg_proc p WHERE p.oid IN ('public.create_dispatch_with_stock_check_internal(jsonb,jsonb[],boolean,text)'::regprocedure,
 'public.delete_dispatch_with_order_cleanup(uuid,uuid)'::regprocedure,'public.update_dispatch_smart(uuid,jsonb,jsonb[])'::regprocedure,
 'public.restore_stock_on_dispatch_delete()'::regprocedure);
SELECT pg_temp.dcm_assert(has_function_privilege('authenticated','public.delete_dispatch_with_order_cleanup(uuid,uuid)','EXECUTE')
 AND has_function_privilege('authenticated','public.update_dispatch_smart(uuid,jsonb,jsonb[])','EXECUTE')
 AND NOT has_function_privilege('anon','public.update_dispatch_smart(uuid,jsonb,jsonb[])','EXECUTE')
 AND NOT has_function_privilege('authenticated','public.create_dispatch_with_stock_check_internal(jsonb,jsonb[],boolean,text)','EXECUTE'),
 'grants as before');
ROLLBACK;

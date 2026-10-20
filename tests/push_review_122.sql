-- Migration 122 (review of the whole backend diff, 2026-10-20). Each case has a result a broken function would not give.
--   A  D4 lower after raise (cautious reading): a line raised past its order and lowered gives back only the bags that came from
--      the order and are no longer dispatched: 15 to 12 gives 0 back, 15 to 2 gives 8 back (the order held 10)
--   B  a source order that is not OPEN (status DISPATCHED, or soft-deleted) gets the give-back of an edit and is opened, as the delete does
--   C  a direct dispatch (no source order) takes from and gives back to the customer's OPEN order; a resend of a coded edit changes no order count
--   D  a save of lines alone moves the dispatch's version token (the row is backdated first, so a token that did not move would show)
--   E  the version token of every record kind moves on a real save (rows backdated with session_replication_role = replica),
--      and the invoice's trigger fires
--   F  remove_item_from_order is what makes a dispatch form opened earlier stale (ORDER_CHANGED)
--   G  restore_to_order's search_path ends with pg_temp
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.pr_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'push review 122: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.pr_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.pr_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.pr_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
CREATE FUNCTION pg_temp.pr_line(item uuid, name text, qty integer, mark text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('item_id',item,'item_name',name,'packaging','Bag','qty',qty,'weight',10,'rack','R1','package_mark',mark) $$;
CREATE FUNCTION pg_temp.pr_ts(p timestamptz) RETURNS text LANGUAGE sql AS $$ SELECT to_char(p AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') $$;
-- The lines of a GRN as update_grn wants them back (ids included).
CREATE FUNCTION pg_temp.pr_lines(p_grn uuid) RETURNS jsonb LANGUAGE sql AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id',t.id,'item_id',t.item_id,'item_name',t.item_name,'packaging',t.packaging,'qty',t.qty,
      'weight',t.weight,'rack',t.rack,'package_mark',t.package_mark) ORDER BY uuid_extract_timestamp(t.id), t.id),'[]'::jsonb)
  FROM public.goodsreceived_trl t WHERE t.gr_id=p_grn $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888888931','Push Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
SELECT pg_temp.pr_login('9888888931') AS admin_claims \gset

-- Fixture, as the administrator. Customers A to F, two items, and the receipts (all dated 2026-04-01):
--   PG1 A potatoes 100 (lot 1x), onions 100 (lot 1y)     PG2 B potatoes 50   PG3 C potatoes 50   PG4 D potatoes 50
--   PG5 E onions 40 (lot 5u)   PG6 E potatoes 10 (lot 6, fully dispatched and invoiced)   PG7 E onions 10 (receipt edit)
--   PG8 F potatoes 20 (lot 8a), onions 20 (lot 8b)
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.pr_assert(public.create_customer('Push Customer '||n,'98888889'||(40+i))->>'success'='true','customer '||n)
 FROM unnest(ARRAY['A','B','C','D','E','F']) WITH ORDINALITY AS t(n,i);
SELECT pg_temp.pr_assert(public.create_item('Push Potatoes','Bag')->>'success'='true','item potatoes');
SELECT pg_temp.pr_assert(public.create_item('Push Onions','Bag')->>'success'='true','item onions');
RESET ROLE;
SELECT id AS ca FROM public.customers WHERE name='Push Customer A' \gset
SELECT id AS cb FROM public.customers WHERE name='Push Customer B' \gset
SELECT id AS cc FROM public.customers WHERE name='Push Customer C' \gset
SELECT id AS cd FROM public.customers WHERE name='Push Customer D' \gset
SELECT id AS ce FROM public.customers WHERE name='Push Customer E' \gset
SELECT id AS cf FROM public.customers WHERE name='Push Customer F' \gset
SELECT id AS potatoes FROM public.items WHERE name='Push Potatoes' \gset
SELECT id AS onions FROM public.items WHERE name='Push Onions' \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.pr_assert(public.save_grn(p_gr_no=>g.no,p_date=>'2026-04-01T12:00:00Z',p_customer_id=>g.cust::uuid,p_customer_name=>g.cname,
  p_pricing_mode=>'MONTHLY',p_items=>g.items)->>'success'='true','receipt '||g.no)
FROM (VALUES
 ('PG1',:'ca','Push Customer A',jsonb_build_array(pg_temp.pr_line(:'potatoes','Push Potatoes',100,'PG1-X'),pg_temp.pr_line(:'onions','Push Onions',100,'PG1-Y'))),
 ('PG2',:'cb','Push Customer B',jsonb_build_array(pg_temp.pr_line(:'potatoes','Push Potatoes',50,'PG2-X'))),
 ('PG3',:'cc','Push Customer C',jsonb_build_array(pg_temp.pr_line(:'potatoes','Push Potatoes',50,'PG3-X'))),
 ('PG4',:'cd','Push Customer D',jsonb_build_array(pg_temp.pr_line(:'potatoes','Push Potatoes',50,'PG4-X'))),
 ('PG5',:'ce','Push Customer E',jsonb_build_array(pg_temp.pr_line(:'onions','Push Onions',40,'PG5-U'))),
 ('PG6',:'ce','Push Customer E',jsonb_build_array(pg_temp.pr_line(:'potatoes','Push Potatoes',10,'PG6-X'))),
 ('PG7',:'ce','Push Customer E',jsonb_build_array(pg_temp.pr_line(:'onions','Push Onions',10,'PG7-X'))),
 ('PG8',:'cf','Push Customer F',jsonb_build_array(pg_temp.pr_line(:'potatoes','Push Potatoes',20,'PG8-A'),pg_temp.pr_line(:'onions','Push Onions',20,'PG8-B')))
) AS g(no,cust,cname,items);
RESET ROLE;
SELECT id AS lot_1x FROM public.goodsreceived_trl WHERE package_mark='PG1-X' \gset
SELECT id AS lot_1y FROM public.goodsreceived_trl WHERE package_mark='PG1-Y' \gset
SELECT id AS lot_2 FROM public.goodsreceived_trl WHERE package_mark='PG2-X' \gset
SELECT id AS lot_3 FROM public.goodsreceived_trl WHERE package_mark='PG3-X' \gset
SELECT id AS lot_4 FROM public.goodsreceived_trl WHERE package_mark='PG4-X' \gset
SELECT id AS lot_5u FROM public.goodsreceived_trl WHERE package_mark='PG5-U' \gset
SELECT id AS lot_6 FROM public.goodsreceived_trl WHERE package_mark='PG6-X' \gset
SELECT id AS lot_8a FROM public.goodsreceived_trl WHERE package_mark='PG8-A' \gset
SELECT id AS lot_8b FROM public.goodsreceived_trl WHERE package_mark='PG8-B' \gset
SELECT id AS grn_6 FROM public.goodsreceived WHERE gr_no='PG6' \gset
SELECT id AS grn_7 FROM public.goodsreceived WHERE gr_no='PG7' \gset
SELECT jsonb_build_object('disp_date','2026-05-02','customer_id',:'ca','customer_name','Push Customer A','supervisor_id',:'admin_profile','supervisor_name','Push Administrator') AS for_a \gset
SELECT jsonb_build_object('disp_date','2026-05-02','customer_id',:'cb','customer_name','Push Customer B','supervisor_id',:'admin_profile','supervisor_name','Push Administrator') AS for_b \gset
SELECT jsonb_build_object('disp_date','2026-05-02','customer_id',:'cc','customer_name','Push Customer C','supervisor_id',:'admin_profile','supervisor_name','Push Administrator') AS for_c \gset
SELECT jsonb_build_object('disp_date','2026-05-02','customer_id',:'cd','customer_name','Push Customer D','supervisor_id',:'admin_profile','supervisor_name','Push Administrator') AS for_d \gset
SELECT jsonb_build_object('disp_date','2026-05-02','customer_id',:'ce','customer_name','Push Customer E','supervisor_id',:'admin_profile','supervisor_name','Push Administrator') AS for_e \gset
SELECT jsonb_build_object('disp_date','2026-05-02','customer_id',:'cf','customer_name','Push Customer F','supervisor_id',:'admin_profile','supervisor_name','Push Administrator') AS for_f \gset

-- ===========================================================================
-- A. Raise past the order, then lower. Customer A orders 10 of lot 1x and 10 of lot 1y; one dispatch takes both lines (10 each).
-- ===========================================================================
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'ca'::uuid) AS cart_a \gset
SELECT pg_temp.pr_assert(public.add_item_to_order(:'cart_a'::uuid,:'lot_1x'::uuid,10)->>'success'='true' AND public.add_item_to_order(:'cart_a'::uuid,:'lot_1y'::uuid,10)->>'success'='true','order lines for A');
SELECT public.create_dispatch_with_stock_check(:'for_a'::jsonb||jsonb_build_object('disp_no','PDA','source_order_id',:'cart_a'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_1x','disp_qty',10),jsonb_build_object('gr_trl_id',:'lot_1y','disp_qty',10)],0,'pr-dda') AS dda \gset
RESET ROLE;
SELECT (:'dda'::jsonb->>'dispatch_id')::uuid AS disp_a \gset
SELECT pg_temp.pr_assert(:'dda'::jsonb->>'success'='true' AND (SELECT count(*)=0 FROM public.order_items WHERE order_id=:'cart_a'::uuid)
 AND (SELECT bool_and(cart_quantity_consumed=10 AND disp_qty=10) FROM public.dispatch_trl WHERE disp_id=:'disp_a'::uuid),'fixture: PDA took both order lines (10 each): '||:'dda');
-- Raise both lines to 15: the order has nothing left, so nothing is taken and the dispatch still holds 10 from the order.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_a'::uuid,NULL,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_1x','disp_qty',15),jsonb_build_object('gr_trl_id',:'lot_1y','disp_qty',15)]) AS a_raise \gset
RESET ROLE;
SELECT pg_temp.pr_assert(:'a_raise'::jsonb->'order_sync'='{"taken": 0, "given_back": 0}'::jsonb
 AND (SELECT bool_and(cart_quantity_consumed=10 AND disp_qty=15) FROM public.dispatch_trl WHERE disp_id=:'disp_a'::uuid)
 AND (SELECT count(*)=0 FROM public.order_items WHERE order_id=:'cart_a'::uuid),'raise 10 to 15 with no order line left: nothing taken, 10 still held: '||:'a_raise');
-- Lower lot 1x 15 to 12 (10 held from the order, 12 still dispatched: nothing to give back) and lot 1y 15 to 2 (10 held, only 2 stay: 8 go back).
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_a'::uuid,NULL,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_1x','disp_qty',12),jsonb_build_object('gr_trl_id',:'lot_1y','disp_qty',2)]) AS a_lower \gset
RESET ROLE;
SELECT pg_temp.pr_assert(:'a_lower'::jsonb->'order_sync'='{"taken": 0, "given_back": 8}'::jsonb
 AND NOT EXISTS (SELECT 1 FROM public.order_items WHERE order_id=:'cart_a'::uuid AND grn_items_id=:'lot_1x'::uuid)
 AND (SELECT requested_quantity=8 AND item_status='pending' FROM public.order_items WHERE order_id=:'cart_a'::uuid AND grn_items_id=:'lot_1y'::uuid)
 AND (SELECT cart_quantity_consumed=10 AND disp_qty=12 FROM public.dispatch_trl WHERE disp_id=:'disp_a'::uuid AND gr_trl_id=:'lot_1x'::uuid)
 AND (SELECT cart_quantity_consumed=2 AND disp_qty=2 FROM public.dispatch_trl WHERE disp_id=:'disp_a'::uuid AND gr_trl_id=:'lot_1y'::uuid)
 AND (SELECT stock=88 FROM public.goodsreceived_trl WHERE id=:'lot_1x'::uuid) AND (SELECT stock=98 FROM public.goodsreceived_trl WHERE id=:'lot_1y'::uuid),
 '15 to 12 gives 0 back (no order line for 1x), 15 to 2 gives 8 back (1y order line 8, dispatch holds 2); stock 88 and 98: '||:'a_lower');

-- ===========================================================================
-- B. A source order that is not OPEN. Customer B: the order is DISPATCHED. Customer C: the order is soft-deleted (still OPEN in status).
-- ===========================================================================
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'cb'::uuid) AS cart_b \gset
SELECT public.get_or_create_cart(:'cc'::uuid) AS cart_c \gset
SELECT pg_temp.pr_assert(public.add_item_to_order(:'cart_b'::uuid,:'lot_2'::uuid,10)->>'success'='true' AND public.add_item_to_order(:'cart_c'::uuid,:'lot_3'::uuid,10)->>'success'='true','order lines for B and C');
SELECT public.create_dispatch_with_stock_check(:'for_b'::jsonb||jsonb_build_object('disp_no','PDB','source_order_id',:'cart_b'),ARRAY[jsonb_build_object('gr_trl_id',:'lot_2','disp_qty',10)],0,'pr-ddb') AS ddb \gset
SELECT public.create_dispatch_with_stock_check(:'for_c'::jsonb||jsonb_build_object('disp_no','PDC','source_order_id',:'cart_c'),ARRAY[jsonb_build_object('gr_trl_id',:'lot_3','disp_qty',10)],0,'pr-ddc') AS ddc \gset
RESET ROLE;
SELECT (:'ddb'::jsonb->>'dispatch_id')::uuid AS disp_b, (:'ddc'::jsonb->>'dispatch_id')::uuid AS disp_c \gset
UPDATE public.orders SET status='DISPATCHED' WHERE id=:'cart_b'::uuid;
UPDATE public.orders SET deleted_at=now() WHERE id=:'cart_c'::uuid;
SELECT pg_temp.pr_assert(:'ddb'::jsonb->>'success'='true' AND :'ddc'::jsonb->>'success'='true'
 AND (SELECT status='DISPATCHED' FROM public.orders WHERE id=:'cart_b'::uuid) AND (SELECT deleted_at IS NOT NULL FROM public.orders WHERE id=:'cart_c'::uuid)
 AND (SELECT count(*)=0 FROM public.order_items WHERE order_id IN (:'cart_b'::uuid,:'cart_c'::uuid)),'fixture: both orders used up and closed: '||:'ddb'||:'ddc');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_b'::uuid,NULL,ARRAY[jsonb_build_object('gr_trl_id',:'lot_2','disp_qty',4)]) AS b_lower \gset
SELECT public.update_dispatch_smart(:'disp_c'::uuid,NULL,ARRAY[jsonb_build_object('gr_trl_id',:'lot_3','disp_qty',4)]) AS c_lower \gset
RESET ROLE;
SELECT pg_temp.pr_assert(:'b_lower'::jsonb->'order_sync'='{"taken": 0, "given_back": 6}'::jsonb
 AND (SELECT status='OPEN' AND deleted_at IS NULL FROM public.orders WHERE id=:'cart_b'::uuid)
 AND (SELECT requested_quantity=6 AND item_status='pending' FROM public.order_items WHERE order_id=:'cart_b'::uuid AND grn_items_id=:'lot_2'::uuid)
 AND (SELECT cart_quantity_consumed=4 FROM public.dispatch_trl WHERE disp_id=:'disp_b'::uuid) AND (SELECT stock=46 FROM public.goodsreceived_trl WHERE id=:'lot_2'::uuid),
 '10 to 4 on a DISPATCHED source order: 6 go back into it and it is OPEN again (the dropped-bags result would be given_back 0 and the order closed): '||:'b_lower');
SELECT pg_temp.pr_assert(:'c_lower'::jsonb->'order_sync'='{"taken": 0, "given_back": 6}'::jsonb
 AND (SELECT status='OPEN' AND deleted_at IS NULL AND deleted_by IS NULL FROM public.orders WHERE id=:'cart_c'::uuid)
 AND (SELECT requested_quantity=6 FROM public.order_items WHERE order_id=:'cart_c'::uuid AND grn_items_id=:'lot_3'::uuid),
 '10 to 4 on a soft-deleted source order: 6 go back and the order is no longer deleted: '||:'c_lower');
-- A source order that stays OPEN is untouched in its status (the twin of A):.
SELECT pg_temp.pr_assert((SELECT status='OPEN' AND deleted_at IS NULL FROM public.orders WHERE id=:'cart_a'::uuid),'twin: the OPEN source order of A is still OPEN');

-- ===========================================================================
-- C. A direct dispatch (no source order) against the customer's OPEN order. Customer D orders 6 of lot 4; the dispatch takes 4.
-- ===========================================================================
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'cd'::uuid) AS cart_d \gset
SELECT pg_temp.pr_assert(public.add_item_to_order(:'cart_d'::uuid,:'lot_4'::uuid,6)->>'success'='true','order line for D (6)');
SELECT public.create_dispatch_with_stock_check(:'for_d'::jsonb||'{"disp_no":"PDD"}'::jsonb,ARRAY[jsonb_build_object('gr_trl_id',:'lot_4','disp_qty',4)],0,'pr-ddd') AS ddd \gset
RESET ROLE;
SELECT (:'ddd'::jsonb->>'dispatch_id')::uuid AS disp_d \gset
SELECT pg_temp.pr_assert(:'ddd'::jsonb->>'success'='true' AND (SELECT requested_quantity=2 FROM public.order_items WHERE order_id=:'cart_d'::uuid AND grn_items_id=:'lot_4'::uuid)
 AND (SELECT cart_quantity_consumed=4 FROM public.dispatch_trl WHERE disp_id=:'disp_d'::uuid),'fixture: the direct dispatch took 4 of the order line (6 to 2): '||:'ddd');
-- Raise 4 to 9: takes the 2 left (line gone), the dispatch holds 6 from the order.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_d'::uuid,NULL,ARRAY[jsonb_build_object('gr_trl_id',:'lot_4','disp_qty',9)]) AS c_raise \gset
RESET ROLE;
SELECT pg_temp.pr_assert(:'c_raise'::jsonb->'order_sync'='{"taken": 2, "given_back": 0}'::jsonb
 AND NOT EXISTS (SELECT 1 FROM public.order_items WHERE order_id=:'cart_d'::uuid AND grn_items_id=:'lot_4'::uuid)
 AND (SELECT cart_quantity_consumed=6 AND disp_qty=9 FROM public.dispatch_trl WHERE disp_id=:'disp_d'::uuid) AND (SELECT stock=41 FROM public.goodsreceived_trl WHERE id=:'lot_4'::uuid),
 'direct dispatch raised 4 to 9 takes the 2 left on the customer''s OPEN order: '||:'c_raise');
-- Lower 9 to 3: 6 held, 3 stay: 3 go back to the customer's OPEN order as a new line.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_d'::uuid,NULL,ARRAY[jsonb_build_object('gr_trl_id',:'lot_4','disp_qty',3)]) AS c_lower \gset
RESET ROLE;
SELECT pg_temp.pr_assert(:'c_lower'::jsonb->'order_sync'='{"taken": 0, "given_back": 3}'::jsonb
 AND (SELECT requested_quantity=3 AND item_status='pending' FROM public.order_items WHERE order_id=:'cart_d'::uuid AND grn_items_id=:'lot_4'::uuid)
 AND (SELECT cart_quantity_consumed=3 AND disp_qty=3 FROM public.dispatch_trl WHERE disp_id=:'disp_d'::uuid) AND (SELECT stock=47 FROM public.goodsreceived_trl WHERE id=:'lot_4'::uuid),
 'direct dispatch lowered 9 to 3 gives 3 back to the customer''s OPEN order: '||:'c_lower');
-- A coded edit (3 to 1 gives 2 back) sent twice: the second answer is the first, and no order or stock count moved again.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_d'::uuid,jsonb_build_object('request_key','pr-resend'),ARRAY[jsonb_build_object('gr_trl_id',:'lot_4','disp_qty',1)]) AS c_first \gset
RESET ROLE;
SELECT requested_quantity AS line_after_first FROM public.order_items WHERE order_id=:'cart_d'::uuid AND grn_items_id=:'lot_4'::uuid \gset
SELECT count(*) AS revisions_after_first FROM public.order_revisions WHERE order_id=:'cart_d'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_d'::uuid,jsonb_build_object('request_key','pr-resend'),ARRAY[jsonb_build_object('gr_trl_id',:'lot_4','disp_qty',1)]) AS c_resend \gset
RESET ROLE;
SELECT pg_temp.pr_assert(:'c_first'::jsonb->'order_sync'='{"taken": 0, "given_back": 2}'::jsonb AND :line_after_first=5 AND :'c_resend'::jsonb=:'c_first'::jsonb
 AND (SELECT requested_quantity=5 FROM public.order_items WHERE order_id=:'cart_d'::uuid AND grn_items_id=:'lot_4'::uuid)
 AND (SELECT count(*)=:revisions_after_first FROM public.order_revisions WHERE order_id=:'cart_d'::uuid)
 AND (SELECT cart_quantity_consumed=1 FROM public.dispatch_trl WHERE disp_id=:'disp_d'::uuid) AND (SELECT stock=49 FROM public.goodsreceived_trl WHERE id=:'lot_4'::uuid),
 'coded edit 3 to 1: 2 go back (order line 3 to 5) once; the resend answers the same, the order line stays 5, no new log row, stock stays 49: '||:'c_first'||:'c_resend');

-- ===========================================================================
-- D. A save of lines alone (no header data) moves the dispatch's token. Customer E, PDE: 5 bags of lot 5u. The row is backdated.
-- ===========================================================================
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'for_e'::jsonb||'{"disp_no":"PDE"}'::jsonb,ARRAY[jsonb_build_object('gr_trl_id',:'lot_5u','disp_qty',5)],0,'pr-dde') AS dde \gset
RESET ROLE;
SELECT (:'dde'::jsonb->>'dispatch_id')::uuid AS disp_e \gset
SET LOCAL session_replication_role = replica;
UPDATE public.dispatch SET updated_at=now()-interval '1 hour' WHERE id=:'disp_e'::uuid;
SET LOCAL session_replication_role = origin;
SELECT updated_at AS tok_e0 FROM public.dispatch WHERE id=:'disp_e'::uuid \gset
SELECT pg_temp.pr_assert(:'tok_e0'::timestamptz < now()-interval '59 minutes','fixture: the dispatch token is an hour old');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_e'::uuid,NULL,ARRAY[jsonb_build_object('gr_trl_id',:'lot_5u','disp_qty',6)]) AS e_lines \gset
RESET ROLE;
SELECT updated_at AS tok_e1 FROM public.dispatch WHERE id=:'disp_e'::uuid \gset
SELECT pg_temp.pr_assert(:'e_lines'::jsonb->>'success'='true' AND (:'e_lines'::jsonb->>'updated_at')::timestamptz=:'tok_e1'::timestamptz AND :'tok_e1'::timestamptz>:'tok_e0'::timestamptz
 AND (SELECT disp_qty=6 FROM public.dispatch_trl WHERE disp_id=:'disp_e'::uuid),
 'a lines-only save answers a token newer than the old one (an hour back) and stores it: '||:'e_lines'||' old '||:'tok_e0');
-- The form that was open before the save is now stale.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_e'::uuid,jsonb_build_object('note','stale form','expected_updated_at',pg_temp.pr_ts(:'tok_e0'::timestamptz)),NULL) AS e_stale \gset
SELECT public.update_dispatch_smart(:'disp_e'::uuid,jsonb_build_object('note','fresh form','expected_updated_at',pg_temp.pr_ts(:'tok_e1'::timestamptz)),NULL) AS e_fresh \gset
RESET ROLE;
SELECT pg_temp.pr_assert(:'e_stale'::jsonb->>'reason'='STALE_RECORD' AND :'e_fresh'::jsonb->>'success'='true','the token from before the lines-only save is stale, the answered one is accepted: '||:'e_stale'||:'e_fresh');

-- ===========================================================================
-- E. The token moves on a real save, for each record kind (rows backdated, so an unmoved token is visible)
-- ===========================================================================
-- Dispatch, with header data: the old token is accepted and the answered one is newer.
SET LOCAL session_replication_role = replica;
UPDATE public.dispatch SET updated_at=now()-interval '2 hours' WHERE id=:'disp_e'::uuid;
SET LOCAL session_replication_role = origin;
SELECT updated_at AS tok_d0 FROM public.dispatch WHERE id=:'disp_e'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_e'::uuid,jsonb_build_object('note','header save','expected_updated_at',pg_temp.pr_ts(:'tok_d0'::timestamptz)),NULL) AS tok_disp \gset
RESET ROLE;
SELECT pg_temp.pr_assert(:'tok_disp'::jsonb->>'success'='true' AND (:'tok_disp'::jsonb->>'updated_at')::timestamptz>:'tok_d0'::timestamptz
 AND (:'tok_disp'::jsonb->>'updated_at')::timestamptz=(SELECT updated_at FROM public.dispatch WHERE id=:'disp_e'::uuid),'dispatch header save: the answered token is newer than the old one: '||:'tok_disp');
-- GRN: PG7 backdated; the edit with its token answers a newer one.
SET LOCAL session_replication_role = replica;
UPDATE public.goodsreceived SET updated_at=now()-interval '2 hours' WHERE id=:'grn_7'::uuid;
SET LOCAL session_replication_role = origin;
SELECT updated_at AS tok_g0 FROM public.goodsreceived WHERE id=:'grn_7'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn_7'::uuid,p_note=>'token test',p_items=>pg_temp.pr_lines(:'grn_7'::uuid),p_expected_updated_at=>:'tok_g0'::timestamptz) AS tok_grn \gset
RESET ROLE;
SELECT pg_temp.pr_assert(:'tok_grn'::jsonb->>'success'='true' AND (:'tok_grn'::jsonb#>>'{grn,updated_at}')::timestamptz>:'tok_g0'::timestamptz
 AND (:'tok_grn'::jsonb#>>'{grn,updated_at}')::timestamptz=(SELECT updated_at FROM public.goodsreceived WHERE id=:'grn_7'::uuid),'GRN save: the answered token is newer than the old one: '||:'tok_grn');
-- Order line: backdated; the quantity change answers a newer token.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'ce'::uuid) AS cart_e \gset
SELECT public.add_item_to_order(:'cart_e'::uuid,:'lot_5u'::uuid,3)#>>'{data,order_item_id}' AS line_e \gset
RESET ROLE;
SET LOCAL session_replication_role = replica;
UPDATE public.order_items SET updated_at=now()-interval '2 hours' WHERE id=:'line_e'::uuid;
SET LOCAL session_replication_role = origin;
SELECT updated_at AS tok_l0 FROM public.order_items WHERE id=:'line_e'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_order_item_quantity(:'line_e'::uuid,4,:'tok_l0'::timestamptz) AS tok_line \gset
RESET ROLE;
SELECT pg_temp.pr_assert(:'tok_line'::jsonb->>'success'='true' AND (:'tok_line'::jsonb#>>'{data,updated_at}')::timestamptz>:'tok_l0'::timestamptz
 AND (:'tok_line'::jsonb#>>'{data,updated_at}')::timestamptz=(SELECT updated_at FROM public.order_items WHERE id=:'line_e'::uuid),'order line save: the answered token is newer than the old one: '||:'tok_line');
-- Invoice: PG6 is dispatched in full and invoiced; the invoice row is backdated, the edit answers a newer token, and the trigger fires.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'for_e'::jsonb||'{"disp_no":"PDI"}'::jsonb,ARRAY[jsonb_build_object('gr_trl_id',:'lot_6','disp_qty',10)],0,'pr-ddi') AS ddi \gset
RESET ROLE;
SELECT jsonb_build_object('inv_fin_year',2026,'customer_id',:'ce','customer_name','Push Customer E','inv_date','2026-06-20','total',0,'tax_amount',0,'labour',0,'discount',0,'duration_mode','legacy') AS inv_base \gset
SELECT jsonb_build_object('disp_trl_id',dt.id,'grn_item_id',dt.gr_trl_id,'duration',1,'charge',10,'tax',0,'labour_rate',2) AS line_i
 FROM public.dispatch_trl dt WHERE dt.disp_id=(:'ddi'::jsonb->>'dispatch_id')::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_invoice(NULL::uuid,:'inv_base'::jsonb||jsonb_build_object('inv_no',93001,'gr_id',:'grn_6','gr_no','PG6'),ARRAY[:'line_i'::jsonb]) AS inv_saved \gset
RESET ROLE;
SELECT pg_temp.pr_assert(:'inv_saved'::jsonb->>'success'='true','fixture: invoice 93001 saved: '||:'inv_saved');
SELECT (:'inv_saved'::jsonb->>'invoice_id')::uuid AS invoice_6 \gset
SELECT pg_temp.pr_assert((SELECT tgenabled='O' AND tgtype & 2 = 2 AND tgtype & 16 = 16 FROM pg_trigger WHERE tgrelid='public.invoice'::regclass AND tgname='trigger_invoice_updated_at'),
 'trigger_invoice_updated_at exists on invoice, enabled, BEFORE UPDATE');
SET LOCAL session_replication_role = replica;
UPDATE public.invoice SET updated_at=now()-interval '2 hours' WHERE id=:'invoice_6'::uuid;
SET LOCAL session_replication_role = origin;
SELECT updated_at AS tok_i0 FROM public.invoice WHERE id=:'invoice_6'::uuid \gset
-- A plain UPDATE of the backdated row (the trigger, no function): the token moves.
UPDATE public.invoice SET notes='trigger probe' WHERE id=:'invoice_6'::uuid;
SELECT pg_temp.pr_assert((SELECT updated_at>:'tok_i0'::timestamptz FROM public.invoice WHERE id=:'invoice_6'::uuid),'trigger_invoice_updated_at fires: a plain UPDATE of a backdated invoice moves updated_at');
SET LOCAL session_replication_role = replica;
UPDATE public.invoice SET updated_at=now()-interval '2 hours' WHERE id=:'invoice_6'::uuid;
SET LOCAL session_replication_role = origin;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_invoice(:'invoice_6'::uuid,:'inv_base'::jsonb||jsonb_build_object('inv_no',93001,'gr_id',:'grn_6','gr_no','PG6','notes','token test','expected_updated_at',pg_temp.pr_ts(:'tok_i0'::timestamptz)),ARRAY[:'line_i'::jsonb]) AS tok_inv \gset
RESET ROLE;
SELECT pg_temp.pr_assert(:'tok_inv'::jsonb->>'success'='true' AND (:'tok_inv'::jsonb->>'updated_at')::timestamptz>:'tok_i0'::timestamptz
 AND (:'tok_inv'::jsonb->>'updated_at')::timestamptz=(SELECT updated_at FROM public.invoice WHERE id=:'invoice_6'::uuid),'invoice save: the answered token is newer than the old one: '||:'tok_inv');

-- ===========================================================================
-- F. remove_item_from_order makes a dispatch form opened before it stale (D5). Customer F: order lines for lots 8a and 8b (5 each).
-- ===========================================================================
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'cf'::uuid) AS cart_f \gset
SELECT public.add_item_to_order(:'cart_f'::uuid,:'lot_8a'::uuid,5)#>>'{data,order_item_id}' AS line_8a \gset
SELECT public.add_item_to_order(:'cart_f'::uuid,:'lot_8b'::uuid,5)#>>'{data,order_item_id}' AS line_8b \gset
RESET ROLE;
-- The form was opened an hour ago.
SET LOCAL session_replication_role = replica;
UPDATE public.order_items SET updated_at=now()-interval '1 hour' WHERE order_id=:'cart_f'::uuid;
UPDATE public.orders SET updated_at=now()-interval '1 hour' WHERE id=:'cart_f'::uuid;
SET LOCAL session_replication_role = origin;
SELECT updated_at AS tok_f FROM public.orders WHERE id=:'cart_f'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.remove_item_from_order(:'line_8b'::uuid) AS f_remove \gset
SELECT public.create_dispatch_with_stock_check(:'for_f'::jsonb||jsonb_build_object('disp_no','PDF1','source_order_id',:'cart_f','source_order_updated_at',pg_temp.pr_ts(:'tok_f'::timestamptz)),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_8a','disp_qty',5)],0,'pr-ddf1') AS f_stale \gset
RESET ROLE;
SELECT pg_temp.pr_assert(:'f_remove'::jsonb->>'success'='true' AND :'f_stale'::jsonb->>'reason'='ORDER_CHANGED' AND NOT EXISTS (SELECT 1 FROM public.dispatch WHERE disp_no='PDF1')
 AND (SELECT stock=20 FROM public.goodsreceived_trl WHERE id=:'lot_8a'::uuid),'a line removed after the form opened: ORDER_CHANGED, no dispatch, stock untouched: '||:'f_remove'||:'f_stale');
SELECT updated_at AS tok_f2 FROM public.orders WHERE id=:'cart_f'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'for_f'::jsonb||jsonb_build_object('disp_no','PDF2','source_order_id',:'cart_f','source_order_updated_at',pg_temp.pr_ts(:'tok_f2'::timestamptz)),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_8a','disp_qty',5)],0,'pr-ddf2') AS f_ok \gset
RESET ROLE;
SELECT pg_temp.pr_assert(:'f_ok'::jsonb->>'success'='true','twin: the form reopened after the removal is dispatched: '||:'f_ok');

-- ===========================================================================
-- G. restore_to_order pins its search_path with pg_temp last
-- ===========================================================================
SELECT pg_temp.pr_assert((SELECT p.proconfig @> ARRAY['search_path=pg_catalog, public, pg_temp'] FROM pg_proc p
  WHERE p.oid='warehouse_security.restore_to_order(uuid,uuid,uuid,uuid,uuid,integer,uuid)'::regprocedure),'restore_to_order search_path ends with pg_temp');

-- Migration 39: a dispatch carries only its own customer's lots, and a receipt
-- with dispatches, invoices or cart lines keeps its customer. Also asserts the
-- migration 25 refusals of update_dispatch_smart, which had no test. Fictional
-- data; runs only in migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.lot_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'dispatch lot ownership: %',label; END IF; END $$;
-- True when the statement raises an error whose text matches the pattern.
CREATE FUNCTION pg_temp.lot_raises(statement text, pattern text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE statement; EXCEPTION WHEN OTHERS THEN RETURN SQLERRM LIKE pattern; END;
  RETURN false;
END $$;
CREATE FUNCTION pg_temp.lot_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.lot_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.lot_assert(l#>>'{data,action}'='login','login for '||phone);
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
SELECT warehouse_security.bootstrap_first_admin('9888888841','Lot Rule Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888842','Lot Rule Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888843','Lot Rule Customer Reader','customer',true,'approved');
SELECT pg_temp.lot_login('9888888841') AS admin_claims \gset
SELECT pg_temp.lot_login('9888888842') AS staff_claims \gset
SELECT pg_temp.lot_login('9888888843') AS customer_claims \gset

-- Fixture, as the administrator: customers A and B and five receipts.
--   LOTA   A, 100 bags: dispatched in full on LOTA1 + LOTA2 and invoiced
--   LOTA2  A, two lines of 50 and 30 bags: the editable dispatch LOTD1
--   LOTB   B, 40 bags: the foreign lot
--   LOTB2  B, 10 bags: in B's cart only
--   LOTB3  B, 10 bags: nothing depends on it
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.lot_assert(public.create_customer('Lot Rule Customer A','9888888844')->>'success'='true','customer A');
SELECT pg_temp.lot_assert(public.create_customer('Lot Rule Customer B','9888888845')->>'success'='true','customer B');
SELECT pg_temp.lot_assert(public.create_item('Lot Rule Potatoes','Bag')->>'success'='true','catalog item');
SELECT id AS customer_a FROM public.customers WHERE name='Lot Rule Customer A' \gset
SELECT id AS customer_b FROM public.customers WHERE name='Lot Rule Customer B' \gset
SELECT id AS item_id FROM public.items WHERE name='Lot Rule Potatoes' \gset
SELECT pg_temp.lot_assert(public.create_item_storage_price(p_item_id=>:'item_id'::uuid,p_price_type=>'monthly',p_unit_price=>5,
 p_weight_min=>0,p_weight_max=>100,p_labour_rate=>2,p_effective_from=>'2026-01-01',
 p_customer_id=>:'customer_a'::uuid,p_tax_percent=>5)->>'success'='true','price for A');
SELECT pg_temp.lot_assert(public.save_grn(p_gr_no=>'LOTA',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_a'::uuid,
 p_customer_name=>'Lot Rule Customer A',p_pricing_mode=>'MONTHLY',p_idempotency_key=>'lot-rule-a',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Lot Rule Potatoes',
 'packaging','Bag','qty',100,'weight',10,'rack','R1')))->>'success'='true','receipt LOTA');
SELECT pg_temp.lot_assert(public.save_grn(p_gr_no=>'LOTA2',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_a'::uuid,
 p_customer_name=>'Lot Rule Customer A',p_pricing_mode=>'MONTHLY',p_idempotency_key=>'lot-rule-a2',
 p_items=>jsonb_build_array(
  jsonb_build_object('item_id',:'item_id','item_name','Lot Rule Potatoes','packaging','Bag','qty',50,'weight',10,'rack','R2'),
  jsonb_build_object('item_id',:'item_id','item_name','Lot Rule Potatoes','packaging','Bag','qty',30,'weight',10,'rack','R3')))->>'success'='true','receipt LOTA2');
SELECT pg_temp.lot_assert(public.save_grn(p_gr_no=>'LOTB',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_b'::uuid,
 p_customer_name=>'Lot Rule Customer B',p_pricing_mode=>'MONTHLY',p_idempotency_key=>'lot-rule-b',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Lot Rule Potatoes',
 'packaging','Bag','qty',40,'weight',10,'rack','R4')))->>'success'='true','receipt LOTB');
SELECT pg_temp.lot_assert(public.save_grn(p_gr_no=>'LOTB2',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_b'::uuid,
 p_customer_name=>'Lot Rule Customer B',p_pricing_mode=>'MONTHLY',p_idempotency_key=>'lot-rule-b2',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Lot Rule Potatoes',
 'packaging','Bag','qty',10,'weight',10,'rack','R5')))->>'success'='true','receipt LOTB2');
SELECT pg_temp.lot_assert(public.save_grn(p_gr_no=>'LOTB3',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_b'::uuid,
 p_customer_name=>'Lot Rule Customer B',p_pricing_mode=>'MONTHLY',p_idempotency_key=>'lot-rule-b3',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Lot Rule Potatoes',
 'packaging','Bag','qty',10,'weight',10,'rack','R6')))->>'success'='true','receipt LOTB3');
SELECT id AS grn_a FROM public.goodsreceived WHERE gr_no='LOTA' \gset
SELECT id AS grn_a2 FROM public.goodsreceived WHERE gr_no='LOTA2' \gset
SELECT id AS grn_b FROM public.goodsreceived WHERE gr_no='LOTB' \gset
SELECT id AS grn_b2 FROM public.goodsreceived WHERE gr_no='LOTB2' \gset
SELECT id AS grn_b3 FROM public.goodsreceived WHERE gr_no='LOTB3' \gset
SELECT id AS lot_a FROM public.goodsreceived_trl WHERE gr_id=:'grn_a'::uuid \gset
SELECT id AS lot_a2 FROM public.goodsreceived_trl WHERE gr_id=:'grn_a2'::uuid AND qty=50 \gset
SELECT id AS lot_a3 FROM public.goodsreceived_trl WHERE gr_id=:'grn_a2'::uuid AND qty=30 \gset
SELECT id AS lot_b FROM public.goodsreceived_trl WHERE gr_id=:'grn_b'::uuid \gset
SELECT id AS lot_b2 FROM public.goodsreceived_trl WHERE gr_id=:'grn_b2'::uuid \gset
SELECT id AS lot_b3 FROM public.goodsreceived_trl WHERE gr_id=:'grn_b3'::uuid \gset
SELECT jsonb_build_object('disp_date','2026-05-02T12:00:00Z','customer_id',:'customer_a',
 'customer_name','Lot Rule Customer A','supervisor_id',:'admin_profile','supervisor_name','Lot Rule Administrator') AS for_a \gset

-- Creation with another customer's lot is refused for the administrator (the
-- four-argument wrapper) and for staff (the five-argument wrapper), alone or
-- mixed with an own lot, and leaves no dispatch and no stock change.
SELECT public.create_dispatch_with_stock_check(:'for_a'::jsonb || '{"disp_no":"LOTX1"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_b','disp_qty',1)],0,'lot-rule-foreign-admin') AS foreign_admin \gset
SELECT pg_temp.lot_assert(:'foreign_admin'::jsonb->>'success'='false' AND :'foreign_admin'::jsonb->>'error' LIKE 'Item belongs to another customer:%',
 'administrator cannot dispatch another customer''s lot: ' || :'foreign_admin');
RESET ROLE;
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.lot_assert(warehouse_security.active_role()='staff','actual staff role');
SELECT public.create_dispatch_with_stock_check(:'for_a'::jsonb || '{"disp_no":"LOTX2"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_b','disp_qty',1)],false,0,'lot-rule-foreign-staff') AS foreign_staff \gset
SELECT pg_temp.lot_assert(:'foreign_staff'::jsonb->>'success'='false' AND :'foreign_staff'::jsonb->>'error' LIKE 'Item belongs to another customer:%',
 'staff cannot dispatch another customer''s lot: ' || :'foreign_staff');
SELECT public.create_dispatch_with_stock_check(:'for_a'::jsonb || '{"disp_no":"LOTX3"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a2','disp_qty',1),jsonb_build_object('gr_trl_id',:'lot_b','disp_qty',1)],
 false,0,'lot-rule-mixed-staff') AS mixed_staff \gset
SELECT pg_temp.lot_assert(:'mixed_staff'::jsonb->>'success'='false' AND :'mixed_staff'::jsonb->>'error' LIKE 'Item belongs to another customer:%',
 'a dispatch mixing two customers'' lots is refused: ' || :'mixed_staff');
RESET ROLE;
SELECT pg_temp.lot_assert((SELECT count(*)=0 FROM public.dispatch WHERE disp_no IN ('LOTX1','LOTX2','LOTX3')),'refused creations leave no dispatch');
SELECT pg_temp.lot_assert((SELECT count(*)=0 FROM public.dispatch_trl WHERE gr_trl_id IN (:'lot_b'::uuid,:'lot_a2'::uuid)),'refused creations leave no lines');
SELECT pg_temp.lot_assert((SELECT stock=40 FROM public.goodsreceived_trl WHERE id=:'lot_b'::uuid),'the other customer''s stock is untouched');
SELECT pg_temp.lot_assert((SELECT stock=50 FROM public.goodsreceived_trl WHERE id=:'lot_a2'::uuid),'own stock is untouched by the refused mixed dispatch');
SET LOCAL ROLE authenticated;

-- Creation with own lots still works: LOTD1 for the editing checks, and LOTA
-- dispatched in full and invoiced for the invoiced-line check.
SELECT public.create_dispatch_with_stock_check(:'for_a'::jsonb || '{"disp_no":"LOTD1","note":"Original note"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a2','disp_qty',10)],false,0,'lot-rule-own') AS own \gset
SELECT pg_temp.lot_assert(:'own'::jsonb->>'success'='true','staff dispatches the customer''s own lot: ' || :'own');
SELECT (:'own'::jsonb->>'dispatch_id') AS dispatch_d1 \gset
SELECT public.create_dispatch_with_stock_check(:'for_a'::jsonb || '{"disp_no":"LOTA1"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a','disp_qty',20)],false,0,'lot-rule-a-partial') AS partial \gset
SELECT pg_temp.lot_assert(:'partial'::jsonb->>'success'='true','partial dispatch of LOTA');
SELECT public.create_dispatch_with_stock_check(:'for_a'::jsonb || '{"disp_no":"LOTA2"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a','disp_qty',80)],0,'lot-rule-a-final') AS final \gset
SELECT pg_temp.lot_assert(:'final'::jsonb->>'success'='true','final dispatch of LOTA through the four-argument wrapper');
SELECT (:'partial'::jsonb->>'dispatch_id') AS dispatch_a1 \gset
RESET ROLE;
SELECT pg_temp.lot_assert((SELECT stock=40 FROM public.goodsreceived_trl WHERE id=:'lot_a2'::uuid),'own dispatch takes 10 of 50');
SELECT pg_temp.lot_assert((SELECT stock=0 FROM public.goodsreceived_trl WHERE id=:'lot_a'::uuid),'LOTA fully dispatched');
SELECT jsonb_agg(jsonb_build_object('disp_trl_id',t.id,'charge',5,'tax',5,'labour_rate',2)) AS invoice_items
 FROM public.dispatch_trl t WHERE t.gr_trl_id=:'lot_a'::uuid \gset
SET LOCAL ROLE authenticated;
SELECT public.save_invoice(jsonb_build_object('inv_no',20261039,'inv_fin_year',2026,'gr_id',:'grn_a','gr_no','LOTA',
 'customer_id',:'customer_a','customer_name','Lot Rule Customer A','inv_date','2026-05-02T12:00:00Z',
 'total',998,'tax_amount',48,'discount',0,'duration_mode','legacy','items',:'invoice_items'::jsonb)) AS saved \gset
SELECT pg_temp.lot_assert(:'saved'::jsonb->>'success'='true','invoice for LOTA: ' || :'saved');

-- update_dispatch_smart, as staff. A plain edit works (10 -> 15 bags).
SELECT public.update_dispatch_smart(:'dispatch_d1'::uuid,'{"note":"Edited note"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a2','disp_qty',15)]) AS edited \gset
SELECT pg_temp.lot_assert(:'edited'::jsonb->>'success'='true','staff edits a dispatch: ' || :'edited');
-- Adding another customer's lot is refused and the whole edit rolls back.
SELECT public.update_dispatch_smart(:'dispatch_d1'::uuid,'{"note":"Must roll back"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a2','disp_qty',15),jsonb_build_object('gr_trl_id',:'lot_b','disp_qty',1)]) AS add_foreign \gset
SELECT pg_temp.lot_assert(:'add_foreign'::jsonb->>'success'='false' AND :'add_foreign'::jsonb->>'error' LIKE 'Item belongs to another customer:%',
 'edit cannot add another customer''s lot: ' || :'add_foreign');
-- Migration 25 refusal: more than the lot holds (35 left, 41 more asked).
SELECT public.update_dispatch_smart(:'dispatch_d1'::uuid,'{"note":"Must roll back"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a2','disp_qty',56)]) AS too_many \gset
SELECT pg_temp.lot_assert(:'too_many'::jsonb->>'success'='false' AND :'too_many'::jsonb->>'error' LIKE 'Insufficient stock:%',
 'edit beyond the stock is refused: ' || :'too_many');
-- Migration 25 refusal: a line already on an invoice, changed or removed.
SELECT public.update_dispatch_smart(:'dispatch_a1'::uuid,'{"note":"Must roll back"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a','disp_qty',19)]) AS invoiced_qty \gset
SELECT pg_temp.lot_assert(:'invoiced_qty'::jsonb->>'success'='false' AND :'invoiced_qty'::jsonb->>'error' LIKE 'Cannot modify invoiced items:%',
 'an invoiced line cannot change quantity: ' || :'invoiced_qty');
SELECT public.update_dispatch_smart(:'dispatch_a1'::uuid,NULL,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a3','disp_qty',1)]) AS invoiced_removed \gset
SELECT pg_temp.lot_assert(:'invoiced_removed'::jsonb->>'success'='false' AND :'invoiced_removed'::jsonb->>'error' LIKE 'Cannot modify invoiced items:%',
 'an invoiced line cannot be removed: ' || :'invoiced_removed');
-- The header customer cannot change while the lines stay with the old customer,
-- whether the lines are left alone or sent again unchanged.
SELECT public.update_dispatch_smart(:'dispatch_d1'::uuid,
 jsonb_build_object('customer_id',:'customer_b','customer_name','Lot Rule Customer B'),NULL) AS move_header \gset
SELECT pg_temp.lot_assert(:'move_header'::jsonb->>'success'='false' AND :'move_header'::jsonb->>'error' LIKE 'Cannot change the dispatch customer: items belong to another customer%',
 'header customer cannot change under existing lines: ' || :'move_header');
SELECT public.update_dispatch_smart(:'dispatch_d1'::uuid,
 jsonb_build_object('customer_id',:'customer_b','customer_name','Lot Rule Customer B'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a2','disp_qty',15)]) AS move_header_same_lines \gset
SELECT pg_temp.lot_assert(:'move_header_same_lines'::jsonb->>'success'='false' AND :'move_header_same_lines'::jsonb->>'error' LIKE 'Cannot change the dispatch customer: items belong to another customer%',
 'header customer cannot change when the same lines are sent again: ' || :'move_header_same_lines');
RESET ROLE;
SELECT pg_temp.lot_assert((SELECT note='Edited note' AND customer_id=:'customer_a'::uuid AND customer_name='Lot Rule Customer A'
 FROM public.dispatch WHERE id=:'dispatch_d1'::uuid),'refused edits leave the header as it was');
SELECT pg_temp.lot_assert((SELECT count(*)=1 AND bool_and(gr_trl_id=:'lot_a2'::uuid AND disp_qty=15)
 FROM public.dispatch_trl WHERE disp_id=:'dispatch_d1'::uuid),'refused edits leave the one line of 15');
SELECT pg_temp.lot_assert((SELECT stock=35 FROM public.goodsreceived_trl WHERE id=:'lot_a2'::uuid),'own stock reflects only the accepted edit');
SELECT pg_temp.lot_assert((SELECT stock=40 FROM public.goodsreceived_trl WHERE id=:'lot_b'::uuid),'the other customer''s stock is still untouched');
SELECT pg_temp.lot_assert((SELECT stock=30 FROM public.goodsreceived_trl WHERE id=:'lot_a3'::uuid),'the lot offered in place of an invoiced line is untouched');
SELECT pg_temp.lot_assert((SELECT count(*)=1 AND bool_and(disp_qty=20 AND gr_trl_id=:'lot_a'::uuid)
 FROM public.dispatch_trl WHERE disp_id=:'dispatch_a1'::uuid),'the invoiced line is unchanged');
SET LOCAL ROLE authenticated;
-- Adding a second own lot is still allowed.
SELECT public.update_dispatch_smart(:'dispatch_d1'::uuid,NULL,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a2','disp_qty',15),jsonb_build_object('gr_trl_id',:'lot_a3','disp_qty',5)]) AS add_own \gset
SELECT pg_temp.lot_assert(:'add_own'::jsonb->>'success'='true','edit adds a second own lot: ' || :'add_own');
RESET ROLE;
SELECT pg_temp.lot_assert((SELECT stock=25 FROM public.goodsreceived_trl WHERE id=:'lot_a3'::uuid),'the added own lot gives 5 of 30');
-- A customer account cannot edit a dispatch at all.
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active)
 SELECT id,:'customer_a'::uuid,true FROM public.user_profiles WHERE mobile='919888888843';
SELECT set_config('request.jwt.claims',:'customer_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'dispatch_d1'::uuid,'{"note":"Customer edit"}'::jsonb,NULL) AS customer_edit \gset
SELECT pg_temp.lot_assert(:'customer_edit'::jsonb->>'success'='false' AND :'customer_edit'::jsonb->>'error' LIKE '%Staff access required%',
 'a customer account cannot edit its own dispatch: ' || :'customer_edit');
RESET ROLE;
SELECT pg_temp.lot_assert((SELECT note='Edited note' FROM public.dispatch WHERE id=:'dispatch_d1'::uuid),'the customer''s attempt changed nothing');

-- Moving a dispatch to another customer is allowed when every line is replaced
-- by that customer's lots in the same edit (as the administrator).
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'dispatch_d1'::uuid,
 jsonb_build_object('customer_id',:'customer_b','customer_name','Lot Rule Customer B'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_b','disp_qty',4)]) AS moved \gset
SELECT pg_temp.lot_assert(:'moved'::jsonb->>'success'='true','customer and all lines change together: ' || :'moved');
RESET ROLE;
SELECT pg_temp.lot_assert((SELECT customer_id=:'customer_b'::uuid FROM public.dispatch WHERE id=:'dispatch_d1'::uuid),'dispatch now belongs to B');
SELECT pg_temp.lot_assert((SELECT stock=36 FROM public.goodsreceived_trl WHERE id=:'lot_b'::uuid),'B''s lot gives 4 of 40');
SELECT pg_temp.lot_assert((SELECT stock=50 FROM public.goodsreceived_trl WHERE id=:'lot_a2'::uuid)
 AND (SELECT stock=30 FROM public.goodsreceived_trl WHERE id=:'lot_a3'::uuid),'A''s lots get their stock back');
-- Records saved before this rule may already mix customers. The rule looks only
-- at what an edit adds or moves, so such a dispatch can still be edited.
UPDATE public.dispatch SET customer_id=:'customer_a'::uuid, customer_name='Lot Rule Customer A' WHERE id=:'dispatch_d1'::uuid;
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'dispatch_d1'::uuid,'{"note":"Older mixed record"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_b','disp_qty',3)]) AS legacy_edit \gset
SELECT pg_temp.lot_assert(:'legacy_edit'::jsonb->>'success'='true','an older mixed dispatch can still be edited: ' || :'legacy_edit');
RESET ROLE;
SELECT pg_temp.lot_assert((SELECT stock=37 FROM public.goodsreceived_trl WHERE id=:'lot_b'::uuid),'the older mixed line changes quantity');
UPDATE public.dispatch SET customer_id=:'customer_b'::uuid, customer_name='Lot Rule Customer B' WHERE id=:'dispatch_d1'::uuid;

-- update_grn, as staff: the customer of a receipt with dispatch lines (LOTB),
-- an invoice (LOTA) or a cart line (LOTB2) cannot change; LOTB3 has none.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'customer_b'::uuid) AS cart_b \gset
SELECT pg_temp.lot_assert(public.add_item_to_order(:'cart_b'::uuid,:'lot_b2'::uuid,2)->>'success'='true','LOTB2 goes into B''s cart');
SELECT pg_temp.lot_assert(pg_temp.lot_raises(format(
 'SELECT public.update_grn(p_grn_id=>%L::uuid,p_customer_id=>%L::uuid,p_customer_name=>''Lot Rule Customer A'',p_note=>''Must roll back'',p_items=>%L::jsonb)',
 :'grn_b',:'customer_a',jsonb_build_array(jsonb_build_object('id',:'lot_b','item_id',:'item_id','item_name','Lot Rule Potatoes','packaging','Bag','qty',40,'weight',10,'rack','R4'))::text),
 'Cannot change the customer of a GRN that has dispatches, invoices or order items'),'customer of a dispatched receipt cannot change');
SELECT pg_temp.lot_assert(pg_temp.lot_raises(format(
 'SELECT public.update_grn(p_grn_id=>%L::uuid,p_customer_id=>%L::uuid,p_customer_name=>''Lot Rule Customer B'',p_note=>''Must roll back'',p_items=>%L::jsonb)',
 :'grn_a',:'customer_b',jsonb_build_array(jsonb_build_object('id',:'lot_a','item_id',:'item_id','item_name','Lot Rule Potatoes','packaging','Bag','qty',100,'weight',10,'rack','R1'))::text),
 'Cannot change the customer of a GRN that has dispatches, invoices or order items'),'customer of an invoiced receipt cannot change');
SELECT pg_temp.lot_assert(pg_temp.lot_raises(format(
 'SELECT public.update_grn(p_grn_id=>%L::uuid,p_customer_id=>%L::uuid,p_customer_name=>''Lot Rule Customer A'',p_note=>''Must roll back'',p_items=>%L::jsonb)',
 :'grn_b2',:'customer_a',jsonb_build_array(jsonb_build_object('id',:'lot_b2','item_id',:'item_id','item_name','Lot Rule Potatoes','packaging','Bag','qty',10,'weight',10,'rack','R5'))::text),
 'Cannot change the customer of a GRN that has dispatches, invoices or order items'),'customer of a receipt in a cart cannot change');
-- Sending the same customer again is an ordinary edit of a dispatched receipt.
SELECT public.update_grn(p_grn_id=>:'grn_b'::uuid,p_customer_id=>:'customer_b'::uuid,p_customer_name=>'Lot Rule Customer B',p_note=>'Same customer',
 p_items=>jsonb_build_array(jsonb_build_object('id',:'lot_b','item_id',:'item_id','item_name','Lot Rule Potatoes','packaging','Bag','qty',40,'weight',10,'rack','R4'))) AS same_customer \gset
SELECT pg_temp.lot_assert(:'same_customer'::jsonb->>'success'='true','dispatched receipt edits with its own customer: ' || :'same_customer');
-- A receipt nothing depends on can move to another customer.
SELECT public.update_grn(p_grn_id=>:'grn_b3'::uuid,p_customer_id=>:'customer_a'::uuid,p_customer_name=>'Lot Rule Customer A',
 p_items=>jsonb_build_array(jsonb_build_object('id',:'lot_b3','item_id',:'item_id','item_name','Lot Rule Potatoes','packaging','Bag','qty',10,'weight',10,'rack','R6'))) AS moved_grn \gset
SELECT pg_temp.lot_assert(:'moved_grn'::jsonb->>'success'='true','receipt without dependants changes customer: ' || :'moved_grn');
RESET ROLE;
SELECT pg_temp.lot_assert((SELECT customer_id=:'customer_b'::uuid AND note='Same customer' FROM public.goodsreceived WHERE id=:'grn_b'::uuid),'dispatched receipt keeps B and takes the ordinary edit');
SELECT pg_temp.lot_assert((SELECT customer_id=:'customer_a'::uuid AND note IS DISTINCT FROM 'Must roll back' FROM public.goodsreceived WHERE id=:'grn_a'::uuid),'invoiced receipt keeps A');
SELECT pg_temp.lot_assert((SELECT customer_id=:'customer_b'::uuid AND note IS DISTINCT FROM 'Must roll back' FROM public.goodsreceived WHERE id=:'grn_b2'::uuid),'receipt in a cart keeps B');
SELECT pg_temp.lot_assert((SELECT customer_id=:'customer_a'::uuid AND customer_name='Lot Rule Customer A' FROM public.goodsreceived WHERE id=:'grn_b3'::uuid),'free receipt moved to A');
SELECT pg_temp.lot_assert((SELECT bool_and(tgenabled='O') FROM pg_trigger WHERE tgrelid='public.goodsreceived_trl'::regclass AND tgname='trg_mark_stock_mvs_dirty_grn'),
 'refused receipt edits leave the item triggers enabled');
ROLLBACK;
\echo 'Dispatch lot ownership, dispatch edit refusals and receipt customer change checks passed.'

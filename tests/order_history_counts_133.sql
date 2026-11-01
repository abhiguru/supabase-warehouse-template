-- Migration 133: the order history counts a dispatch's take and its give-back right (device re-test B13).
--   * An order line of 20; a dispatch made from the order takes 12 (20 -> 8): the entry says 20 -> 8, 12 taken.
--   * Deleting that dispatch gives 12 back: its entry carries total_quantity_restored 12 (was missing, the app showed 0).
--   * The give-back counts in the line's chain: a plain save to 18 afterwards reads 20 -> 18, not 8 -> 18.
--   * A dispatch that takes the whole line (18 -> 0, line removed) says 18 -> 0, not the quantity of an older event; its delete says 18.
--   * The first add of a line, and a line put back after it was removed, are both change_type 'added'.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database. Every row rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.och_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'order change log: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.och_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM pg_temp.och_assert(challenge->>'success'='true','ordinary challenge');
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  login := public.operator_verify_otp(phone,challenge#>>'{data,otp_code}');
  PERFORM pg_temp.och_assert(login#>>'{data,action}'='login','ordinary login');
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
SELECT warehouse_security.bootstrap_first_admin('9888888821','Counts Administrator');
SELECT pg_temp.och_login('9888888821') AS admin_claims \gset
-- Numbers are free text here (the facility's numbering is not what this test is about).
SELECT warehouse_security.apply_document_numbering('grn', '{"scheme":"free"}', NULL) AS _ \gset
SELECT warehouse_security.apply_document_numbering('dispatch', '{"scheme":"free"}', NULL) AS _ \gset
INSERT INTO public.customers(name,mobile) VALUES ('Counts Customer','9888888871') RETURNING id AS customer_id \gset
INSERT INTO public.items(name,packaging) VALUES ('Counts Onions','Bag') RETURNING id AS onion_id \gset


-- In production every save is its own transaction, so the times in the entries differ. Here everything runs in one transaction
-- (NOW() is the same for all), so each entry's own time is set to the moment its row was written (changed_at, clock_timestamp()).
CREATE FUNCTION pg_temp.och_times() RETURNS void LANGUAGE sql AS $$
  UPDATE public.order_revisions SET entry = entry
    || CASE WHEN entry ? 'timestamp' THEN jsonb_build_object('timestamp', changed_at) ELSE '{}'::jsonb END
    || CASE WHEN entry ? 'at' THEN jsonb_build_object('at', changed_at) ELSE '{}'::jsonb END $$;
-- The order-level entries in time order, as type:change:before>after[:taken] (dispatch deletions as dispatch_deleted:restored).
CREATE FUNCTION pg_temp.och_hist(p_order uuid) RETURNS text LANGUAGE plpgsql AS $$
DECLARE h jsonb; r text;
BEGIN
  SELECT public.get_order_change_log(p_order_id=>p_order, p_limit=>100) INTO h;
  IF h->>'success' <> 'true' THEN RAISE EXCEPTION 'history: %',h; END IF;
  SELECT string_agg(CASE c->>'change_type'
      WHEN 'dispatch_deleted' THEN 'dispatch_deleted:'||(c#>>'{change_details,total_quantity_restored}')
      WHEN 'quantity_reduced_by_dispatch' THEN 'quantity_reduced_by_dispatch:'||(c#>>'{change_details,quantity_change,change_type}')||':'||(c#>>'{change_details,quantity_change,previous_quantity}')||'>'||(c#>>'{change_details,quantity_change,new_quantity}')||':'||(c#>>'{change_details,dispatch_impact,dispatched_quantity}')
      ELSE 'quantity_changed:'||(c#>>'{change_details,quantity_change,change_type}')||':'||(c#>>'{change_details,quantity_change,previous_quantity}')||'>'||(c#>>'{change_details,quantity_change,new_quantity}') END,
    '|' ORDER BY (c->>'change_timestamp')::timestamptz)
  INTO r FROM jsonb_array_elements(h#>'{data,changes}') c WHERE c->>'change_category'='order_level';
  RETURN r;
END $$;

SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_grn(p_gr_no=>'CNT1',p_date=>now(),p_customer_id=>:'customer_id'::uuid,p_customer_name=>'Counts Customer',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'onion_id','item_name','Counts Onions','packaging','Bag','qty',100,'weight',40,'rack','A8','package_mark','X0001')),
 p_idempotency_key=>'counts-receipt') AS receipt \gset
RESET ROLE;
SELECT pg_temp.och_assert(:'receipt'::jsonb->>'success'='true','receipt saved: '||:'receipt');
SELECT t.id AS lot FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='CNT1' \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE mobile='919888888821' \gset
SELECT jsonb_build_object('disp_date',to_char(now() AT TIME ZONE 'Asia/Kolkata','YYYY-MM-DD"T"12:00:00"Z"'),'customer_id',:'customer_id','customer_name','Counts Customer',
 'supervisor_id',:'admin_profile','supervisor_name','Counts Administrator') AS header \gset

-- The order asks for 20 (the first add).
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'customer_id'::uuid) AS cart \gset
SELECT pg_temp.och_assert(public.add_item_to_order(:'cart'::uuid,:'lot'::uuid,20)->>'success'='true','add 20');
-- A dispatch made from the order takes 12.
SELECT public.create_dispatch_with_stock_check(:'header'::jsonb||jsonb_build_object('disp_no','CNTD1','source_order_id',:'cart'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot','disp_qty',12)],0,'counts-d1') AS d1 \gset
RESET ROLE;
SELECT pg_temp.och_assert(:'d1'::jsonb->>'success'='true','dispatch D1: '||:'d1');
SELECT (:'d1'::jsonb->>'dispatch_id')::uuid AS d1_id \gset
SELECT pg_temp.och_assert((SELECT requested_quantity=8 FROM public.order_items WHERE order_id=:'cart'::uuid),'the line is 8 after D1');
SELECT pg_temp.och_times() AS _t \gset
SELECT pg_temp.och_hist(:'cart'::uuid) AS h1 \gset
SELECT pg_temp.och_assert(:'h1' = 'quantity_changed:added:0>20|quantity_reduced_by_dispatch:decreased:20>8:12','after D1: first add, then D1 took 12 (20 -> 8): '||:'h1');

-- order_effects names the packaging of the line.
SELECT pg_temp.och_assert(:'d1'::jsonb#>>'{order_effects,0,packaging}'='Bag','the dispatch effect names the packaging: '||:'d1');

-- Deleting D1 gives the 12 back.
SELECT public.delete_dispatch_with_order_cleanup(:'d1_id'::uuid,:'admin_profile'::uuid) AS del1 \gset
SELECT pg_temp.och_assert(:'del1'::jsonb->>'success'='true' AND (SELECT requested_quantity=20 FROM public.order_items WHERE order_id=:'cart'::uuid),'D1 deleted, the line is 20: '||:'del1');
SELECT pg_temp.och_times() AS _t \gset
SELECT pg_temp.och_hist(:'cart'::uuid) AS h2 \gset
SELECT pg_temp.och_assert(:'h2' = 'quantity_changed:added:0>20|quantity_reduced_by_dispatch:decreased:20>8:12|dispatch_deleted:12','after the delete D1 gave 12 back: '||:'h2');

-- The give-back is in the line's chain: a plain save to 18 reads 20 -> 18.
SELECT id AS line FROM public.order_items WHERE order_id=:'cart'::uuid \gset
SET LOCAL ROLE authenticated;
SELECT pg_temp.och_assert(public.update_order_item_quantity(:'line'::uuid,18)->>'success'='true','lower to 18');
-- A second dispatch takes the whole line.
SELECT public.create_dispatch_with_stock_check(:'header'::jsonb||jsonb_build_object('disp_no','CNTD2','source_order_id',:'cart'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot','disp_qty',18)],0,'counts-d2') AS d2 \gset
RESET ROLE;
SELECT pg_temp.och_assert(:'d2'::jsonb->>'success'='true' AND NOT EXISTS (SELECT 1 FROM public.order_items WHERE order_id=:'cart'::uuid),'dispatch D2 took the whole line: '||:'d2');
SELECT (:'d2'::jsonb->>'dispatch_id')::uuid AS d2_id \gset
-- The line is gone after D2 (snapshot path): its effect still names the packaging.
SELECT pg_temp.och_assert(:'d2'::jsonb#>>'{order_effects,0,packaging}'='Bag' AND :'d2'::jsonb#>>'{order_effects,0,change}'='removed','D2 effect names the packaging of a removed line: '||:'d2');
SELECT public.delete_dispatch_with_order_cleanup(:'d2_id'::uuid,:'admin_profile'::uuid) AS del2 \gset
SELECT pg_temp.och_assert(:'del2'::jsonb->>'success'='true' AND (SELECT requested_quantity=18 FROM public.order_items WHERE order_id=:'cart'::uuid),'D2 deleted, the line is 18: '||:'del2');
SELECT pg_temp.och_times() AS _t \gset
SELECT pg_temp.och_hist(:'cart'::uuid) AS h3 \gset
SELECT pg_temp.och_assert(:'h3' = 'quantity_changed:added:0>20|quantity_reduced_by_dispatch:decreased:20>8:12|dispatch_deleted:12|quantity_changed:decreased:20>18|quantity_reduced_by_dispatch:removed:18>0:18|dispatch_deleted:18','the full history: '||:'h3');

-- A line put back after it was removed is "added" too (0 before).
SELECT id AS line2 FROM public.order_items WHERE order_id=:'cart'::uuid \gset
SET LOCAL ROLE authenticated;
SELECT pg_temp.och_assert(public.remove_item_from_order(:'line2'::uuid)->>'success'='true','remove the line');
SELECT pg_temp.och_assert(public.add_item_to_order(:'cart'::uuid,:'lot'::uuid,20)->>'success'='true','add 20 again');
RESET ROLE;
SELECT pg_temp.och_times() AS _t \gset
SELECT pg_temp.och_hist(:'cart'::uuid) AS h4 \gset
SELECT pg_temp.och_assert(:'h4' LIKE '%|quantity_changed:removed:18>0|quantity_changed:added:0>20','a removed line put back is added: '||:'h4');
-- ===== The device bug: a take right after a delete, with no save in between; a reduction without previous_quantity; two deletes in a row;
-- ===== an entry of the old format (before 121); a malformed entry.
INSERT INTO public.customers(name,mobile) VALUES ('Counts Customer B','9888888872') RETURNING id AS cust_b \gset
INSERT INTO public.customers(name,mobile) VALUES ('Counts Customer C','9888888873') RETURNING id AS cust_c \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_grn(p_gr_no=>'CNT2',p_date=>now(),p_customer_id=>:'cust_b'::uuid,p_customer_name=>'Counts Customer B',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'onion_id','item_name','Counts Onions','packaging','Bag','qty',100,'weight',40,'rack','A9','package_mark','X0002')),
 p_idempotency_key=>'counts-receipt-b') AS receipt_b \gset
SELECT public.save_grn(p_gr_no=>'CNT3',p_date=>now(),p_customer_id=>:'cust_c'::uuid,p_customer_name=>'Counts Customer C',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'onion_id','item_name','Counts Onions','packaging','Bag','qty',100,'weight',40,'rack','A10','package_mark','X0003')),
 p_idempotency_key=>'counts-receipt-c') AS receipt_c \gset
RESET ROLE;
SELECT pg_temp.och_assert(:'receipt_b'::jsonb->>'success'='true' AND :'receipt_c'::jsonb->>'success'='true','receipts B and C saved');
SELECT t.id AS lot_b FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='CNT2' \gset
SELECT t.id AS lot_c FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='CNT3' \gset
SELECT jsonb_build_object('disp_date',to_char(now() AT TIME ZONE 'Asia/Kolkata','YYYY-MM-DD"T"12:00:00"Z"'),'customer_id',:'cust_b','customer_name','Counts Customer B',
 'supervisor_id',:'admin_profile','supervisor_name','Counts Administrator') AS header_b \gset

-- Order B: 20; D1 takes 12 (20 -> 8); D1 is deleted (20 again); D5 takes all 20 at once, no save in between.
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'cust_b'::uuid) AS cart_b \gset
SELECT pg_temp.och_assert(public.add_item_to_order(:'cart_b'::uuid,:'lot_b'::uuid,20)->>'success'='true','B: add 20');
-- A preview answers the packaging too (same builder as the real save).
SELECT public.preview_create_dispatch(:'header_b'::jsonb||jsonb_build_object('disp_no','CNTB1','source_order_id',:'cart_b'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_b','disp_qty',12)]) AS pv \gset
SELECT pg_temp.och_assert(:'pv'::jsonb->>'success'='true' AND :'pv'::jsonb#>>'{order_effects,0,packaging}'='Bag','preview names the packaging: '||:'pv');
SELECT public.create_dispatch_with_stock_check(:'header_b'::jsonb||jsonb_build_object('disp_no','CNTB1','source_order_id',:'cart_b'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_b','disp_qty',12)],0,'counts-b1') AS b1 \gset
RESET ROLE;
SELECT pg_temp.och_assert(:'b1'::jsonb->>'success'='true','B: dispatch 1: '||:'b1');
SELECT (:'b1'::jsonb->>'dispatch_id')::uuid AS b1_id \gset
SELECT public.delete_dispatch_with_order_cleanup(:'b1_id'::uuid,:'admin_profile'::uuid) AS bdel1 \gset
SELECT pg_temp.och_assert(:'bdel1'::jsonb->>'success'='true' AND (SELECT requested_quantity=20 FROM public.order_items WHERE order_id=:'cart_b'::uuid),'B: D1 deleted, the line is 20: '||:'bdel1');
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'header_b'::jsonb||jsonb_build_object('disp_no','CNTB2','source_order_id',:'cart_b'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_b','disp_qty',20)],0,'counts-b2') AS b2 \gset
RESET ROLE;
SELECT pg_temp.och_assert(:'b2'::jsonb->>'success'='true' AND NOT EXISTS (SELECT 1 FROM public.order_items WHERE order_id=:'cart_b'::uuid),'B: dispatch 2 took all 20: '||:'b2');
SELECT pg_temp.och_times() AS _t \gset
SELECT pg_temp.och_hist(:'cart_b'::uuid) AS hb1 \gset
SELECT pg_temp.och_assert(:'hb1' = 'quantity_changed:added:0>20|quantity_reduced_by_dispatch:decreased:20>8:12|dispatch_deleted:12|quantity_reduced_by_dispatch:removed:20>0:20',
 'a take right after a delete starts from 20, not 8: '||:'hb1');

-- Two deletes in a row: B2 is deleted (20 back); then two small dispatches of 5, both deleted one after the other; a plain save to 18 reads 20 -> 18.
SELECT (:'b2'::jsonb->>'dispatch_id')::uuid AS b2_id \gset
SELECT public.delete_dispatch_with_order_cleanup(:'b2_id'::uuid,:'admin_profile'::uuid) AS bdel2 \gset
SELECT pg_temp.och_assert(:'bdel2'::jsonb->>'success'='true' AND (SELECT requested_quantity=20 FROM public.order_items WHERE order_id=:'cart_b'::uuid),'B: D2 deleted, the line is 20: '||:'bdel2');
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'header_b'::jsonb||jsonb_build_object('disp_no','CNTB3','source_order_id',:'cart_b'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_b','disp_qty',5)],0,'counts-b3') AS b3 \gset
SELECT public.create_dispatch_with_stock_check(:'header_b'::jsonb||jsonb_build_object('disp_no','CNTB4','source_order_id',:'cart_b'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_b','disp_qty',5)],0,'counts-b4') AS b4 \gset
RESET ROLE;
SELECT pg_temp.och_assert(:'b3'::jsonb->>'success'='true' AND :'b4'::jsonb->>'success'='true' AND (SELECT requested_quantity=10 FROM public.order_items WHERE order_id=:'cart_b'::uuid),'B: D3 and D4 took 5 each: '||:'b3'||:'b4');
SELECT public.delete_dispatch_with_order_cleanup((:'b3'::jsonb->>'dispatch_id')::uuid,:'admin_profile'::uuid)->>'success' AS bd3 \gset
SELECT public.delete_dispatch_with_order_cleanup((:'b4'::jsonb->>'dispatch_id')::uuid,:'admin_profile'::uuid)->>'success' AS bd4 \gset
SELECT pg_temp.och_assert(:'bd3'='true' AND :'bd4'='true' AND (SELECT requested_quantity=20 FROM public.order_items WHERE order_id=:'cart_b'::uuid),'B: D3 and D4 deleted, the line is 20');
SELECT id AS line_b FROM public.order_items WHERE order_id=:'cart_b'::uuid \gset
SET LOCAL ROLE authenticated;
SELECT pg_temp.och_assert(public.update_order_item_quantity(:'line_b'::uuid,18)->>'success'='true','B: lower to 18');
RESET ROLE;
SELECT pg_temp.och_times() AS _t \gset
SELECT pg_temp.och_hist(:'cart_b'::uuid) AS hb2 \gset
SELECT pg_temp.och_assert(:'hb2' = 'quantity_changed:added:0>20|quantity_reduced_by_dispatch:decreased:20>8:12|dispatch_deleted:12|quantity_reduced_by_dispatch:removed:20>0:20|dispatch_deleted:20'
   || '|quantity_reduced_by_dispatch:decreased:20>15:5|quantity_reduced_by_dispatch:decreased:15>10:5|dispatch_deleted:5|dispatch_deleted:5|quantity_changed:decreased:20>18',
 'two deletes in a row: both give-backs count, the save reads 20 > 18: '||:'hb2');

-- Order C: a reduction without previous_quantity (a fixture), and entries of the old format (before 121) that must not change the chain.
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'cust_c'::uuid) AS cart_c \gset
SELECT pg_temp.och_assert(public.add_item_to_order(:'cart_c'::uuid,:'lot_c'::uuid,20)->>'success'='true','C: add 20');
RESET ROLE;
-- A dispatch reduction with no previous_quantity: the line is measured from the event before it (20).
INSERT INTO public.order_revisions(order_id,changed_at,changed_by,action,entry) VALUES (:'cart_c'::uuid,clock_timestamp(),:'admin_profile'::uuid,'auto_quantity_reduction',
 jsonb_build_object('action','auto_quantity_reduction','timestamp',now(),'by',:'admin_profile','dispatch_id','00000000-0000-4000-8000-0000000000c1','dispatch_no','CNTOLD1',
   'grn_item_id',:'lot_c','new_quantity',8));
-- An old-format delete (before 121: every dispatch line, the dispatched quantity 30): no reduction of that dispatch carries previous_quantity.
INSERT INTO public.order_revisions(order_id,changed_at,changed_by,action,entry) VALUES (:'cart_c'::uuid,clock_timestamp(),:'admin_profile'::uuid,'dispatch_deleted',
 jsonb_build_object('action','dispatch_deleted','timestamp',now(),'by',:'admin_profile','dispatch_id','00000000-0000-4000-8000-0000000000c1','dispatch_no','CNTOLD1',
   'restored_items',jsonb_build_array(jsonb_build_object('item_name','Counts Onions','package_mark','X0003','grn_no','CNT3','quantity_restored',30))));
-- A malformed entry (the dispatch id is not a uuid): treated as absent, the history still answers.
INSERT INTO public.order_revisions(order_id,changed_at,changed_by,action,entry) VALUES (:'cart_c'::uuid,clock_timestamp(),:'admin_profile'::uuid,'dispatch_deleted',
 jsonb_build_object('action','dispatch_deleted','timestamp',now(),'by',:'admin_profile','dispatch_id','not-a-uuid','dispatch_no','CNTBAD',
   'restored_items',jsonb_build_array(jsonb_build_object('item_name','Counts Onions','package_mark','X0003','grn_no','CNT3','quantity_restored',7))));
-- Malformed entries for the old display arm: a quantity that is not a number, restored_items that is not an array, a timestamp that is not a time.
INSERT INTO public.order_revisions(order_id,changed_at,changed_by,action,entry) VALUES (:'cart_c'::uuid,clock_timestamp(),:'admin_profile'::uuid,'dispatch_deleted',
 jsonb_build_object('action','dispatch_deleted','timestamp',now(),'by',:'admin_profile','dispatch_id','00000000-0000-4000-8000-0000000000c2','dispatch_no','CNTBAD2',
   'restored_items',jsonb_build_array(jsonb_build_object('item_name','Counts Onions','package_mark','X0003','grn_no','CNT3','quantity_restored','many'))));
INSERT INTO public.order_revisions(order_id,changed_at,changed_by,action,entry) VALUES (:'cart_c'::uuid,clock_timestamp(),:'admin_profile'::uuid,'dispatch_deleted',
 jsonb_build_object('action','dispatch_deleted','timestamp',now(),'by',:'admin_profile','dispatch_id','00000000-0000-4000-8000-0000000000c3','dispatch_no','CNTBAD3',
   'restored_items',jsonb_build_object('item_name','Counts Onions')));
SELECT id AS line_c FROM public.order_items WHERE order_id=:'cart_c'::uuid \gset
SET LOCAL ROLE authenticated;
SELECT pg_temp.och_assert(public.update_order_item_quantity(:'line_c'::uuid,15)->>'success'='true','C: set 15');
RESET ROLE;
SELECT pg_temp.och_times() AS _t \gset
INSERT INTO public.order_revisions(order_id,changed_at,changed_by,action,entry) VALUES (:'cart_c'::uuid,clock_timestamp(),:'admin_profile'::uuid,'dispatch_deleted',
 jsonb_build_object('action','dispatch_deleted','timestamp','yesterday-ish','by',:'admin_profile','dispatch_id','00000000-0000-4000-8000-0000000000c4','dispatch_no','CNTBAD4',
   'restored_items',jsonb_build_array(jsonb_build_object('item_name','Counts Onions','package_mark','X0003','grn_no','CNT3','quantity_restored',5))));
SELECT pg_temp.och_hist(:'cart_c'::uuid) AS hc \gset
SELECT pg_temp.och_assert(:'hc' = 'quantity_changed:added:0>20|quantity_reduced_by_dispatch:decreased:20>8:12|dispatch_deleted:30|dispatch_deleted:7|quantity_changed:increased:8>15|dispatch_deleted:5',
 'old-format and malformed delete entries do not change the chain: '||:'hc');
ROLLBACK;

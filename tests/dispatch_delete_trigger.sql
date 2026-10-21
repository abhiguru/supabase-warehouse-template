-- Slimming round 2 (migration 123, S3): characterisation of trg_restore_stock_on_dispatch_delete (BEFORE DELETE ON public.dispatch).
-- delete_dispatch_with_order_cleanup, the only delete path, gives the stock and the cart quantities back itself and removes the dispatch
-- lines first, so the trigger's stock half finds nothing to do. Its other half is NOT redundant: it sets every line of the source order to
-- pending with nothing fulfilled, so a line that was out_of_stock or cancelled becomes pending again. The scenario below runs with the
-- trigger on and with it off (each run is undone); stock, movements, order status and the answer are equal, and the lines differ exactly
-- as pinned at the end. The trigger therefore stays (migration 123 does not drop it); drop it only on an owner decision about those lines.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.ddt_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'dispatch delete trigger: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.ddt_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.ddt_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.ddt_assert(l#>>'{data,action}'='login','login for '||phone);
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
SELECT warehouse_security.bootstrap_first_admin('9888888861','Delete Trigger Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
SELECT pg_temp.ddt_login('9888888861') AS admin_claims \gset

-- Fixture: receipt DDT1 with five lots (package marks A to E) and the customer's cart.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ddt_assert(public.create_customer('Delete Trigger Customer','9888888862')->>'success'='true','customer');
SELECT pg_temp.ddt_assert(public.create_item('Delete Trigger Potatoes','Bag')->>'success'='true','catalog item');
SELECT id AS customer_id FROM public.customers WHERE name='Delete Trigger Customer' \gset
SELECT id AS item_id FROM public.items WHERE name='Delete Trigger Potatoes' \gset
SELECT pg_temp.ddt_assert(public.save_grn(p_gr_no=>'DDT1',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_id'::uuid,
 p_customer_name=>'Delete Trigger Customer',p_pricing_mode=>'MONTHLY',
 p_items=>(SELECT jsonb_agg(jsonb_build_object('item_id',:'item_id','item_name','Delete Trigger Potatoes',
   'packaging','Bag','qty',q,'weight',5,'rack','R1','package_mark',m))
   FROM (VALUES ('A',10),('B',5),('C',10),('D',10),('E',10)) AS l(m,q)))->>'success'='true','receipt DDT1');
RESET ROLE;
SELECT t.id AS lot_a FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DDT1' AND t.package_mark='A' \gset
SELECT t.id AS lot_b FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DDT1' AND t.package_mark='B' \gset
SELECT t.id AS lot_c FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DDT1' AND t.package_mark='C' \gset
SELECT t.id AS lot_d FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DDT1' AND t.package_mark='D' \gset
SELECT t.id AS lot_e FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DDT1' AND t.package_mark='E' \gset
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'customer_id'::uuid) AS cart \gset
SELECT pg_temp.ddt_assert(public.add_item_to_order(:'cart'::uuid,:'lot_a'::uuid,10)->>'success'='true','10 of A in the cart');
SELECT pg_temp.ddt_assert(public.add_item_to_order(:'cart'::uuid,:'lot_b'::uuid,3)->>'success'='true','3 of B in the cart');
SELECT pg_temp.ddt_assert(public.add_item_to_order(:'cart'::uuid,:'lot_c'::uuid,10)->>'success'='true','10 of C in the cart');
SELECT pg_temp.ddt_assert(public.add_item_to_order(:'cart'::uuid,:'lot_d'::uuid,10)->>'success'='true','10 of D in the cart');
SELECT pg_temp.ddt_assert(public.add_item_to_order(:'cart'::uuid,:'lot_e'::uuid,7)->>'success'='true','7 of E in the cart');
RESET ROLE;
-- Two lines of the cart that the dispatch does not touch carry other states.
UPDATE public.order_items SET item_status='out_of_stock' WHERE order_id=:'cart'::uuid AND grn_items_id=:'lot_c'::uuid;
UPDATE public.order_items SET item_status='cancelled' WHERE order_id=:'cart'::uuid AND grn_items_id=:'lot_d'::uuid;
SELECT jsonb_build_object('disp_date','2026-06-01','customer_id',:'customer_id','customer_name','Delete Trigger Customer',
 'supervisor_id',:'admin_profile','supervisor_name','Delete Trigger Administrator') AS header \gset

-- One scenario: make a dispatch (from the cart, or direct), delete it through the RPC, read back what the screens read. The
-- scenario is undone at its end (an exception that is caught), so it can run again on the same fixture.
CREATE FUNCTION pg_temp.ddt_scenario(p_trigger boolean, p_from_cart boolean) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_header jsonb := current_setting('ddt.header')::jsonb;
  v_cart uuid := current_setting('ddt.cart')::uuid;
  v_disp uuid; v_deleted jsonb; v_snapshot jsonb;
BEGIN
  BEGIN
    IF p_trigger THEN
      ALTER TABLE public.dispatch ENABLE TRIGGER trg_restore_stock_on_dispatch_delete;
    ELSE
      ALTER TABLE public.dispatch DISABLE TRIGGER trg_restore_stock_on_dispatch_delete;
    END IF;
    PERFORM set_config('request.jwt.claims', current_setting('ddt.claims'), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    IF NOT (public.create_dispatch_with_stock_check(
        v_header || CASE WHEN p_from_cart THEN jsonb_build_object('disp_no','DDTX','source_order_id',v_cart) ELSE jsonb_build_object('disp_no','DDTX') END,
        ARRAY[jsonb_build_object('gr_trl_id',current_setting('ddt.lot_a'),'disp_qty',4),
              jsonb_build_object('gr_trl_id',current_setting('ddt.lot_b'),'disp_qty',5)],0,'ddt-key')->>'success')::boolean THEN
      RAISE EXCEPTION 'the dispatch was not made';
    END IF;
    EXECUTE 'RESET ROLE';
    SELECT id INTO v_disp FROM public.dispatch WHERE disp_no='DDTX';
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_deleted := public.delete_dispatch_with_order_cleanup(v_disp, current_setting('ddt.admin_profile')::uuid);
    EXECUTE 'RESET ROLE';
    IF NOT (v_deleted->>'success')::boolean THEN RAISE EXCEPTION 'the dispatch was not deleted: %', v_deleted; END IF;
    v_snapshot := jsonb_build_object(
      'answer_counts', jsonb_build_object('stock_updates', jsonb_array_length(v_deleted->'stock_updates'),
        'order_restoration', v_deleted->'order_restoration', 'statistics', v_deleted->'statistics'),
      'dispatch_left', EXISTS (SELECT 1 FROM public.dispatch WHERE id=v_disp),
      'dispatch_lines_left', (SELECT count(*) FROM public.dispatch_trl WHERE disp_id=v_disp),
      'stock', (SELECT jsonb_object_agg(package_mark, stock) FROM public.goodsreceived_trl WHERE id IN
                  (current_setting('ddt.lot_a')::uuid, current_setting('ddt.lot_b')::uuid, current_setting('ddt.lot_c')::uuid,
                   current_setting('ddt.lot_d')::uuid, current_setting('ddt.lot_e')::uuid)),
      'movements', (SELECT COALESCE(jsonb_agg(m.movement_type || ' ' || m.quantity || ' ' || m.balance_before || '>' || m.balance_after
                      || ' (' || COALESCE(m.reference_type,'-') || ')' ORDER BY t.package_mark, m.movement_type, m.quantity), '[]'::jsonb)
                    FROM public.stock_movements m JOIN public.goodsreceived_trl t ON t.id=m.gr_trl_id
                    WHERE m.created_at >= now() - interval '1 hour' AND m.reference_type IN ('dispatch','dispatch_delete')),
      'order', (SELECT jsonb_build_object('status',status,'deleted',deleted_at IS NOT NULL) FROM public.orders WHERE id=v_cart),
      'lines', (SELECT COALESCE(jsonb_agg(t.package_mark || ' ' || oi.requested_quantity || '/' || oi.fulfilled_quantity || ' ' || oi.item_status
                      ORDER BY t.package_mark), '[]'::jsonb)
                FROM public.order_items oi JOIN public.goodsreceived_trl t ON t.id=oi.grn_items_id WHERE oi.order_id=v_cart));
    RAISE EXCEPTION 'scenario done' USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
  END;
  RETURN v_snapshot;
END $$;
SELECT set_config('ddt.header',:'header',false), set_config('ddt.cart',:'cart',false), set_config('ddt.claims',:'admin_claims',false),
       set_config('ddt.lot_a',:'lot_a',false), set_config('ddt.lot_b',:'lot_b',false), set_config('ddt.lot_c',:'lot_c',false),
       set_config('ddt.lot_d',:'lot_d',false), set_config('ddt.lot_e',:'lot_e',false), set_config('ddt.admin_profile',:'admin_profile',false) \gset

SELECT pg_temp.ddt_scenario(true,true) AS cart_with \gset
SELECT pg_temp.ddt_scenario(false,true) AS cart_without \gset
SELECT pg_temp.ddt_scenario(true,false) AS direct_with \gset
SELECT pg_temp.ddt_scenario(false,false) AS direct_without \gset

-- Without the trigger: stock is back, the order is open, and the lines the dispatch did not touch keep their states.
SELECT pg_temp.ddt_assert(:'cart_without'::jsonb->'stock'='{"A":10,"B":5,"C":10,"D":10,"E":10}'::jsonb,
 'stock is back to what the receipt held: ' || (:'cart_without'::jsonb->'stock')::text);
SELECT pg_temp.ddt_assert(:'cart_without'::jsonb->'order'='{"status":"OPEN","deleted":false}'::jsonb,
 'the source order is open: ' || (:'cart_without'::jsonb->'order')::text);
SELECT pg_temp.ddt_assert(:'cart_without'::jsonb->'lines'='["A 10/0 pending","B 3/0 pending","C 10/0 out_of_stock","D 10/0 cancelled","E 7/0 pending"]'::jsonb,
 'the cart lines without the trigger: ' || (:'cart_without'::jsonb->'lines')::text);
-- With the trigger: the same, except that every line of the source order is pending again.
SELECT pg_temp.ddt_assert(:'cart_with'::jsonb->'lines'='["A 10/0 pending","B 3/0 pending","C 10/0 pending","D 10/0 pending","E 7/0 pending"]'::jsonb,
 'the cart lines with the trigger: ' || (:'cart_with'::jsonb->'lines')::text);
SELECT pg_temp.ddt_assert((:'cart_with'::jsonb - 'lines') = (:'cart_without'::jsonb - 'lines'),
 'everything but the lines is equal: ' || :'cart_with' || ' / ' || :'cart_without');
SELECT pg_temp.ddt_assert(:'cart_with'::jsonb->'movements'='["dispatch -4 10>6 (dispatch)","return 4 6>10 (dispatch_delete)","dispatch -5 5>0 (dispatch)","return 5 0>5 (dispatch_delete)"]'::jsonb,
 'one dispatch and one return movement per lot: ' || (:'cart_with'::jsonb->'movements')::text);
-- A direct dispatch has no source order: the trigger changes nothing.
SELECT pg_temp.ddt_assert(:'direct_with'::jsonb = :'direct_without'::jsonb,
 'a direct dispatch is deleted alike with and without the trigger: ' || :'direct_with' || ' / ' || :'direct_without');
ROLLBACK;

-- Migration 66: get_customer_stock_analysis_v2 with a date works out each lot's
-- balance at that moment (backend review 2026-10-13, I2). Fictional data; runs
-- only in migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.shc_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'stock history cutoff: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.shc_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.shc_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.shc_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
-- "grn/dispatch/stock" of the analysis, all items together, at a moment (null = now).
CREATE FUNCTION pg_temp.shc_figures(customer uuid, cutoff timestamptz, in_stock boolean DEFAULT NULL) RETURNS text LANGUAGE sql AS $$
  SELECT (r#>>'{data,aggregations,total_grn_qty}') || '/' || (r#>>'{data,aggregations,total_dispatch_qty}') || '/'
      || (r#>>'{data,aggregations,calculated_stock}') || ' items ' || (r#>>'{data,aggregations,item_count}')
  FROM (SELECT public.get_customer_stock_analysis_v2(customer, cutoff, '{}'::jsonb, in_stock) AS r) a
$$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888888871','Cutoff Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
SELECT pg_temp.shc_login('9888888871') AS admin_claims \gset

-- Fixture: 10 bags received on 2026-04-01, 4 of them dispatched on 2026-06-01.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.shc_assert(public.create_customer('Cutoff Customer','9888888872')->>'success'='true','customer');
SELECT pg_temp.shc_assert(public.create_item('Cutoff Onions','Bag')->>'success'='true','catalog item');
SELECT id AS customer_id FROM public.customers WHERE name='Cutoff Customer' \gset
SELECT id AS item_id FROM public.items WHERE name='Cutoff Onions' \gset
SELECT pg_temp.shc_assert(public.save_grn(p_gr_no=>'SHC1',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_id'::uuid,
 p_customer_name=>'Cutoff Customer',p_pricing_mode=>'MONTHLY',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Cutoff Onions','packaging','Bag','qty',10,'weight',5)))->>'success'='true','receipt SHC1');
SELECT t.id AS lot_10 FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='SHC1' \gset
SELECT pg_temp.shc_assert(public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','SHCD1','disp_date','2026-06-01T12:00:00Z',
 'customer_id',:'customer_id','customer_name','Cutoff Customer','supervisor_id',:'admin_profile','supervisor_name','Cutoff Administrator'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_10','disp_qty',4)],0,'shc-dispatch-1')->>'success'='true','4 of 10 dispatched');

-- The review's reproduction: on April 15 (before the dispatch) all 10 bags were
-- in. Before migration 66 the answer was 10 received, 0 dispatched, 6 in stock.
SELECT pg_temp.shc_figures(:'customer_id'::uuid,'2026-04-15T23:59:59Z') AS april_one_lot \gset
SELECT pg_temp.shc_assert(:'april_one_lot'='10/0/10 items 1','stock on April 15 is the 10 received: ' || :'april_one_lot');
SELECT (public.get_customer_stock_analysis_v2(:'customer_id'::uuid,'2026-04-15T23:59:59Z')#>>'{data,items,0,calculated_stock}') AS april_item \gset
SELECT pg_temp.shc_assert(:'april_item'='10','the item row says 10 as well: ' || :'april_item');

-- A second lot of 5 received the same day and wholly dispatched on 2026-06-01.
SELECT pg_temp.shc_assert(public.save_grn(p_gr_no=>'SHC2',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_id'::uuid,
 p_customer_name=>'Cutoff Customer',p_pricing_mode=>'MONTHLY',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Cutoff Onions','packaging','Bag','qty',5,'weight',5)))->>'success'='true','receipt SHC2');
SELECT t.id AS lot_5 FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='SHC2' \gset
SELECT pg_temp.shc_assert(public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','SHCD2','disp_date','2026-06-01T12:00:00Z',
 'customer_id',:'customer_id','customer_name','Cutoff Customer','supervisor_id',:'admin_profile','supervisor_name','Cutoff Administrator'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_5','disp_qty',5)],0,'shc-dispatch-2')->>'success'='true','5 of 5 dispatched');

-- April 15: the emptied lot was still full then (before migration 66 it was
-- left out because its stock today is 0: 10/0/6).
SELECT pg_temp.shc_figures(:'customer_id'::uuid,'2026-04-15T23:59:59Z') AS april_two_lots \gset
SELECT pg_temp.shc_assert(:'april_two_lots'='15/0/15 items 1','April 15 counts both lots in full: ' || :'april_two_lots');
-- The dispatch date is stored as the day (2026-06-01 00:00 UTC): one second
-- before it the same; from that moment the dispatches count.
SELECT pg_temp.shc_assert((SELECT bool_and(disp_date='2026-06-01T00:00:00Z') FROM public.dispatch WHERE disp_no IN ('SHCD1','SHCD2')),'dispatch day stored');
SELECT pg_temp.shc_assert(pg_temp.shc_figures(:'customer_id'::uuid,'2026-05-31T23:59:59Z')='15/0/15 items 1','just before the dispatches');
SELECT pg_temp.shc_assert(pg_temp.shc_figures(:'customer_id'::uuid,'2026-06-01T00:00:00Z')='10/4/6 items 1','at the dispatch moment the emptied lot drops out');
-- July 1: the emptied lot is out, the other has 6 left.
SELECT pg_temp.shc_figures(:'customer_id'::uuid,'2026-07-01T00:00:00Z') AS july \gset
SELECT pg_temp.shc_assert(:'july'='10/4/6 items 1','July 1: ' || :'july');
-- Without a date: the current figures, as before migration 66.
SELECT pg_temp.shc_figures(:'customer_id'::uuid,NULL) AS today \gset
SELECT pg_temp.shc_assert(:'today'='10/4/6 items 1','no date: ' || :'today');
-- Before anything was received there is nothing.
SELECT pg_temp.shc_assert(pg_temp.shc_figures(:'customer_id'::uuid,'2026-03-31T00:00:00Z')='0/0/0 items 0','before the receipts');
-- The in-stock filter applies to the balance at the date: on April 15 the item had stock.
SELECT pg_temp.shc_assert(pg_temp.shc_figures(:'customer_id'::uuid,'2026-04-15T23:59:59Z',true)='15/0/15 items 1','in stock only, April 15');
RESET ROLE;

-- Everything dispatched: the item has no stock today and none in July, but it
-- had 15 on April 15.
SET LOCAL ROLE authenticated;
SELECT pg_temp.shc_assert(public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','SHCD3','disp_date','2026-08-01T12:00:00Z',
 'customer_id',:'customer_id','customer_name','Cutoff Customer','supervisor_id',:'admin_profile','supervisor_name','Cutoff Administrator'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_10','disp_qty',6)],0,'shc-dispatch-3')->>'success'='true','the last 6 dispatched');
SELECT pg_temp.shc_assert(pg_temp.shc_figures(:'customer_id'::uuid,NULL)='0/0/0 items 0','no date, all dispatched');
SELECT pg_temp.shc_assert(pg_temp.shc_figures(:'customer_id'::uuid,'2026-07-01T00:00:00Z')='10/4/6 items 1','July 1 still had 6');
SELECT pg_temp.shc_assert(pg_temp.shc_figures(:'customer_id'::uuid,'2026-04-15T23:59:59Z',true)='15/0/15 items 1','April 15, in stock only');
RESET ROLE;

-- The patch kept the function single, SECURITY DEFINER, guarded first and granted as before.
SELECT pg_temp.shc_assert(count(*)=1 AND bool_and(p.prosecdef)
  AND bool_and(pg_get_functiondef(p.oid) ~ 'BEGIN\s+PERFORM warehouse_security\.authorize_rpc\(''get_customer_stock_analysis_v2'',')
  AND bool_and(has_function_privilege('authenticated',p.oid,'EXECUTE') AND NOT has_function_privilege('anon',p.oid,'EXECUTE'))
  AND bool_and(p.proconfig = ARRAY['search_path=pg_catalog, public, extensions, utils, pg_temp']),
 'get_customer_stock_analysis_v2 keeps its rights, guard and settings')
FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname='get_customer_stock_analysis_v2';
ROLLBACK;

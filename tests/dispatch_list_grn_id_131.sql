-- Migration 131, dispatch lists: each item object names the GRN it was taken from.
--   get_dispatch_list_with_items (with items): `grn_id` (goodsreceived.id) beside `grn_qty` and `gr_no`.
--   get_recent_dispatched_orders: `grn_id` and `grn_qty` beside `gr_no`.
--   Everything the lists answered before is still there, and a list without items has no item objects.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database. All fixture rows roll back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.dg_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'dispatch list grn id 131: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.dg_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.dg_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;

INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888888631', 'Dispatch Grn Id Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888888632', 'Dispatch Grn Id Staff', 'staff', true, 'approved');
SELECT pg_temp.dg_login('9888888631') AS admin_claims \gset
SELECT pg_temp.dg_login('9888888632') AS staff_claims \gset
INSERT INTO public.customers(name, mobile) VALUES ('Dispatch Grn Id Cold', '9888888633') RETURNING id AS cust \gset
INSERT INTO public.items(name, packaging) VALUES ('Dispatch Grn Id Cumin', 'Bag') RETURNING id AS cumin \gset

SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.dg_assert(public.save_grn(p_gr_no => 'DGI1', p_date => now(), p_customer_id => :'cust'::uuid,
  p_customer_name => 'Dispatch Grn Id Cold', p_idempotency_key => 'dispatch-grn-id-DGI1',
  p_items => jsonb_build_array(jsonb_build_object('item_id', :'cumin', 'item_name', 'Dispatch Grn Id Cumin', 'packaging', 'Bag',
    'qty', 40, 'weight', 25, 'package_mark', 'MK1', 'rack', 'F1/C4')))->>'success' = 'true', 'fixture receipt DGI1');
RESET ROLE;
SELECT id AS grn FROM public.goodsreceived WHERE gr_no = 'DGI1' \gset
SELECT id AS lot FROM public.goodsreceived_trl WHERE gr_id = :'grn'::uuid \gset
-- A dispatch of 15 of the 40 bags, written directly (the lists are what is tested); one of them came from an order.
SET LOCAL session_replication_role = replica;
INSERT INTO public.dispatch(disp_no, disp_date, customer_id, customer_name, source_order_id, source_order_no)
 VALUES ('DGID1', CURRENT_DATE, :'cust'::uuid, 'Dispatch Grn Id Cold', gen_random_uuid(), 'ORD-DGI');
INSERT INTO public.dispatch_trl(gr_id, gr_trl_id, disp_id, disp_qty)
 VALUES (:'grn'::uuid, :'lot'::uuid, (SELECT id FROM public.dispatch WHERE disp_no = 'DGID1'), 15);
SET LOCAL session_replication_role = origin;

SELECT set_config('request.jwt.claims', :'staff_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.dg_assert(warehouse_security.active_role() = 'staff', 'actual staff role');
-- The dispatch list with items.
SELECT pg_temp.dg_assert(r->>'success' = 'true'
  AND jsonb_array_length(r#>'{data,dispatches,0,items}') = 1
  AND r#>>'{data,dispatches,0,items,0,grn_id}' = :'grn'
  AND r#>>'{data,dispatches,0,items,0,grn_qty}' = '40'
  AND r#>>'{data,dispatches,0,items,0,packaging}' = 'Bag'
  AND r#>>'{data,dispatches,0,items,0,disp_qty}' = '15'
  AND r#>>'{data,dispatches,0,items,0,gr_no}' = 'DGI1'
  AND r#>>'{data,dispatches,0,items,0,grn_item_id}' = :'lot'
  AND r#>>'{data,dispatches,0,items,0,package_mark}' = 'MK1'
  AND r#>>'{data,dispatches,0,items,0,rack}' = 'F1/C4',
  'the dispatch list names the GRN of the line: ' || r::text)
FROM (SELECT public.get_dispatch_list_with_items(:'cust'::uuid, '{}'::jsonb, 'dispatch_date', 'desc', 1, 50, true) AS r) answer;
-- Without items there is no item list (as before).
SELECT pg_temp.dg_assert(r->>'success' = 'true' AND jsonb_array_length(r#>'{data,dispatches}') = 1
  AND COALESCE(jsonb_typeof(r#>'{data,dispatches,0,items}'), 'null') = 'null',
  'a list without items has no item objects: ' || r::text)
FROM (SELECT public.get_dispatch_list_with_items(:'cust'::uuid, '{}'::jsonb, 'dispatch_date', 'desc', 1, 50, false) AS r) answer;
-- The recently dispatched orders.
SELECT pg_temp.dg_assert(d->>'disp_no' = 'DGID1' AND d->>'order_no' = 'ORD-DGI'
  AND jsonb_array_length(d->'items') = 1
  AND d#>>'{items,0,grn_id}' = :'grn'
  AND d#>>'{items,0,grn_qty}' = '40'
  AND d#>>'{items,0,packaging}' = 'Bag'
  AND d#>>'{items,0,disp_qty}' = '15'
  AND d#>>'{items,0,gr_no}' = 'DGI1'
  AND d#>>'{items,0,package_mark}' = 'MK1'
  AND d#>>'{items,0,rack}' = 'F1/C4'
  AND d#>>'{items,0,weight}' = '25',
  'the recent orders list names the GRN of the line and its quantity: ' || d::text)
FROM (SELECT x AS d FROM jsonb_array_elements(public.get_recent_dispatched_orders(50, 0)#>'{data,dispatches}') x
      WHERE x->>'disp_no' = 'DGID1') found;
SELECT pg_temp.dg_assert((SELECT count(*) FROM jsonb_array_elements(public.get_recent_dispatched_orders(50, 0)#>'{data,dispatches}') x
      WHERE x->>'disp_no' = 'DGID1') = 1, 'the fixture dispatch is listed once');
RESET ROLE;
-- Both functions keep their guard and their signature (one function each).
SELECT pg_temp.dg_assert(count(*) = 1 AND bool_and(p.prosecdef) AND bool_and(pg_get_functiondef(p.oid) LIKE '%authorize_rpc(''' || p.proname || '''%')
    AND bool_and(pg_get_functiondef(p.oid) LIKE '%grn_id%'), 'the two lists are single, guarded and carry grn_id: ' || p.proname)
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('get_dispatch_list_with_items', 'get_recent_dispatched_orders')
GROUP BY p.proname;
ROLLBACK;
SELECT 'dispatch list grn id 131: both dispatch lists name the GRN of each line' AS result;

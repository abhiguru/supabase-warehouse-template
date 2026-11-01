-- Migration 137: the customer-callable RPCs that read the documents as SECURITY DEFINER (so past the row policies) treat a
-- deleted receipt or dispatch as the policies do: for a customer it is "not found" and its lines are left out; staff and
-- administrators still see it.
--   get_grn_details, get_dispatch_details, get_grn_item_dispatches, get_customer_dispatch_items, get_customer_stock_analysis_v2.
-- Fixture (customer one): receipt WA (live, lines A1 and A2, invoices IV1 live and IV2 deleted), receipt WD (deleted, line D1);
-- dispatches DL (live, takes 1 of A1), DX (deleted, takes 2 of A2), DY (live, takes 1 of D1).
-- Runs ONLY in migrations.sh's fresh, network-disabled database. All rows roll back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.cr_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'customer rpc deleted 137: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.cr_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.cr_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
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
SELECT warehouse_security.bootstrap_first_admin('9888889001', 'Deleted Rule Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888889003', 'Deleted Rule Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888889004', 'Deleted Rule Customer', 'customer', true, 'approved');
SELECT pg_temp.cr_login('9888889001') AS admin_claims \gset
SELECT pg_temp.cr_login('9888889003') AS staff_claims \gset
SELECT pg_temp.cr_login('9888889004') AS cust_claims \gset
INSERT INTO public.customers(name, mobile) VALUES ('Deleted Rule Cold', '9888889011') RETURNING id AS cust \gset
INSERT INTO public.items(name, packaging) VALUES ('Deleted Rule Garlic', 'Bag') RETURNING id AS garlic \gset
INSERT INTO public.users_customers_new(user_profile_id, customer_id, active)
 SELECT id, :'cust'::uuid, true FROM public.user_profiles WHERE mobile = '919888889004';
INSERT INTO public.goodsreceived(gr_no, customer_id, customer_name, date) VALUES
 ('DRA', :'cust', 'Deleted Rule Cold', now() - interval '2 days'), ('DRD', :'cust', 'Deleted Rule Cold', now() - interval '2 days');
INSERT INTO public.goodsreceived_trl(gr_id, item_id, item_name, qty, stock, package_mark)
 SELECT g.id, :'garlic', 'Deleted Rule Garlic', 10, 10, v.mark FROM public.goodsreceived g
 JOIN (VALUES ('DRA', 'A1'), ('DRA', 'A2'), ('DRD', 'D1')) v(gr_no, mark) ON v.gr_no = g.gr_no;
INSERT INTO public.dispatch(disp_no, disp_date, customer_id, customer_name) VALUES
 ('DRL', now() - interval '1 day', :'cust', 'Deleted Rule Cold'), ('DRX', now() - interval '1 day', :'cust', 'Deleted Rule Cold'),
 ('DRY', now() - interval '1 day', :'cust', 'Deleted Rule Cold');
INSERT INTO public.dispatch_trl(gr_id, gr_trl_id, disp_id, disp_qty)
 SELECT t.gr_id, t.id, d.id, v.q FROM (VALUES ('A1', 'DRL', 1), ('A2', 'DRX', 2), ('D1', 'DRY', 1)) v(mark, disp_no, q)
 JOIN public.goodsreceived_trl t ON t.package_mark = v.mark JOIN public.dispatch d ON d.disp_no = v.disp_no;
INSERT INTO public.invoice(inv_fin_year, inv_no, gr_id, gr_no, customer_id, customer_name, inv_date, total)
 SELECT 2097, v.n, g.id, 'DRA', :'cust', 'Deleted Rule Cold', now(), 100 FROM (VALUES (1), (2)) v(n), public.goodsreceived g WHERE g.gr_no = 'DRA';
UPDATE public.goodsreceived SET deleted_at = now() WHERE gr_no = 'DRD';
UPDATE public.dispatch SET deleted_at = now() WHERE disp_no = 'DRX';
UPDATE public.invoice SET deleted_at = now() WHERE inv_fin_year = 2097 AND inv_no = 2;
SELECT id AS gra FROM public.goodsreceived WHERE gr_no = 'DRA' \gset
SELECT id AS grd FROM public.goodsreceived WHERE gr_no = 'DRD' \gset
SELECT id AS dl FROM public.dispatch WHERE disp_no = 'DRL' \gset
SELECT id AS dx FROM public.dispatch WHERE disp_no = 'DRX' \gset
SELECT id AS a2 FROM public.goodsreceived_trl WHERE package_mark = 'A2' \gset
SELECT id AS d1 FROM public.goodsreceived_trl WHERE package_mark = 'D1' \gset

SELECT set_config('request.jwt.claims', :'cust_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.get_grn_details(:'gra') AS c_gra, public.get_grn_details(:'grd') AS c_grd,
       public.get_dispatch_details(:'dl') AS c_dl, public.get_dispatch_details(:'dx') AS c_dx,
       public.get_grn_item_dispatches(:'a2') AS c_a2, public.get_grn_item_dispatches(:'d1') AS c_d1,
       public.get_customer_dispatch_items(:'cust', NULL, NULL, '{}', 'disp_no', 'asc', 50, 0) AS c_items,
       public.get_customer_stock_analysis_v2(:'cust', now() + interval '1 day', '{}', false) AS c_stock \gset
RESET ROLE;
SELECT set_config('request.jwt.claims', :'staff_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.get_grn_details(:'gra') AS s_gra, public.get_grn_details(:'grd') AS s_grd,
       public.get_dispatch_details(:'dl') AS s_dl, public.get_dispatch_details(:'dx') AS s_dx,
       public.get_grn_item_dispatches(:'a2') AS s_a2, public.get_grn_item_dispatches(:'d1') AS s_d1,
       public.get_customer_dispatch_items(:'cust', NULL, NULL, '{}', 'disp_no', 'asc', 50, 0) AS s_items \gset
RESET ROLE;
-- get_customer_stock_analysis_v2 is not granted to staff (tests/role_allowlist.sql): the administrator is the reference.
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.get_customer_stock_analysis_v2(:'cust', now() + interval '1 day', '{}', false) AS a_stock \gset
RESET ROLE;

-- get_grn_details: a deleted receipt is not found for the customer, and a live receipt leaves its deleted dispatch and invoice out.
SELECT pg_temp.cr_assert(:'c_gra'::jsonb->>'success' = 'true' AND :'s_gra'::jsonb->>'success' = 'true', 'get_grn_details: the live receipt is answered to both');
SELECT pg_temp.cr_assert(:'c_grd'::jsonb->>'success' = 'false' AND :'c_grd'::jsonb->>'message' = 'GRN not found or access denied',
  'get_grn_details: a customer gets not-found for a deleted receipt: ' || :'c_grd');
SELECT pg_temp.cr_assert(:'s_grd'::jsonb->>'success' = 'true' AND :'s_grd'::jsonb#>>'{data,grn,gr_no}' = 'DRD', 'get_grn_details: staff still read the deleted receipt');
SELECT pg_temp.cr_assert((:'c_gra'::jsonb#>>'{data,grn,invoices_summary,total_invoices}')::int = 1 AND (:'s_gra'::jsonb#>>'{data,grn,invoices_summary,total_invoices}')::int = 1,
  'get_grn_details: the deleted invoice counts for nobody (migration 134 counts live invoices only, for every role)');
SELECT pg_temp.cr_assert((:'c_gra'::jsonb#>>'{data,grn,dispatches_summary,total_dispatches}')::int = 1 AND (:'s_gra'::jsonb#>>'{data,grn,dispatches_summary,total_dispatches}')::int = 2,
  'get_grn_details: the deleted dispatch counts for staff (2) and not for the customer (1)');
SELECT pg_temp.cr_assert((:'c_gra'::jsonb#>>'{data,grn,statistics,total_dispatched}')::int = 1 AND (:'s_gra'::jsonb#>>'{data,grn,statistics,total_dispatched}')::int = 3,
  'get_grn_details: the bags of the deleted dispatch count for staff (3) and not for the customer (1)');
-- get_dispatch_details
SELECT pg_temp.cr_assert(:'c_dl'::jsonb->>'success' = 'true' AND :'s_dl'::jsonb->>'success' = 'true', 'get_dispatch_details: the live dispatch is answered to both');
SELECT pg_temp.cr_assert(:'c_dx'::jsonb->>'success' = 'false' AND :'c_dx'::jsonb->>'message' = 'Dispatch not found or access denied',
  'get_dispatch_details: a customer gets not-found for a deleted dispatch: ' || :'c_dx');
SELECT pg_temp.cr_assert(:'s_dx'::jsonb->>'success' = 'true' AND :'s_dx'::jsonb#>>'{data,dispatch,disp_no}' = 'DRX', 'get_dispatch_details: staff still read the deleted dispatch');
-- get_grn_item_dispatches: line A2 was taken only by the deleted dispatch; line D1 belongs to the deleted receipt.
SELECT pg_temp.cr_assert(:'c_a2'::jsonb->>'success' = 'true' AND (:'c_a2'::jsonb#>>'{data,summary,total_dispatches}')::int = 0
  AND jsonb_array_length(:'c_a2'::jsonb#>'{data,dispatches}') = 0, 'get_grn_item_dispatches: the customer sees no dispatch of a line taken only by a deleted dispatch: ' || :'c_a2');
SELECT pg_temp.cr_assert((:'s_a2'::jsonb#>>'{data,summary,total_dispatches}')::int = 1 AND jsonb_array_length(:'s_a2'::jsonb#>'{data,dispatches}') = 1,
  'get_grn_item_dispatches: staff see the deleted dispatch');
SELECT pg_temp.cr_assert(:'c_d1'::jsonb->>'success' = 'false' AND :'c_d1'::jsonb->>'code' = 'ACCESS_DENIED',
  'get_grn_item_dispatches: a customer gets not-found for a line of a deleted receipt: ' || :'c_d1');
SELECT pg_temp.cr_assert(:'s_d1'::jsonb->>'success' = 'true' AND (:'s_d1'::jsonb#>>'{data,summary,total_dispatches}')::int = 1, 'get_grn_item_dispatches: staff still read a line of a deleted receipt');
-- get_customer_dispatch_items: DRL/A1 is the only line of a live receipt and a live dispatch.
SELECT pg_temp.cr_assert((:'c_items'::jsonb#>>'{data,pagination,total_count}')::int = 1 AND jsonb_array_length(:'c_items'::jsonb#>'{data,items}') = 1
  AND :'c_items'::jsonb#>>'{data,items,0,disp_no}' = 'DRL' AND (:'c_items'::jsonb#>>'{data,aggregations,total_dispatch_qty}')::int = 1,
  'get_customer_dispatch_items: the customer sees only the line of the live receipt and live dispatch: ' || :'c_items');
SELECT pg_temp.cr_assert((:'s_items'::jsonb#>>'{data,pagination,total_count}')::int = 3 AND (:'s_items'::jsonb#>>'{data,aggregations,total_dispatch_qty}')::int = 4,
  'get_customer_dispatch_items: staff see all three lines');
-- get_customer_stock_analysis_v2 as of tomorrow: the customer's lots are A1 and A2 (20 received); the deleted dispatch took nothing back.
SELECT pg_temp.cr_assert((:'c_stock'::jsonb#>>'{data,aggregations,total_grn_qty}')::int = 20 AND (:'c_stock'::jsonb#>>'{data,aggregations,total_dispatch_qty}')::int = 1
  AND (:'c_stock'::jsonb#>>'{data,aggregations,calculated_stock}')::int = 19, 'get_customer_stock_analysis_v2: the customer sees 20 received, 1 dispatched, 19 left: ' || :'c_stock');
SELECT pg_temp.cr_assert((:'a_stock'::jsonb#>>'{data,aggregations,total_grn_qty}')::int = 30 AND (:'a_stock'::jsonb#>>'{data,aggregations,total_dispatch_qty}')::int = 4
  AND (:'a_stock'::jsonb#>>'{data,aggregations,calculated_stock}')::int = 26, 'get_customer_stock_analysis_v2: the administrator sees everything (30, 4, 26): ' || :'a_stock');
ROLLBACK;

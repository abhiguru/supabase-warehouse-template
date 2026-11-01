-- Migration 133: get_items_without_rate names the items that have no default rate on a day (the lookup of the 'every line has a rate' check), for staff too; a customer is refused.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database. Every row rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.iwr_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'items without rate: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.iwr_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM pg_temp.iwr_assert(challenge->>'success'='true','ordinary challenge');
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  login := public.operator_verify_otp(phone,challenge#>>'{data,otp_code}');
  PERFORM pg_temp.iwr_assert(login#>>'{data,action}'='login','ordinary login');
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
SELECT warehouse_security.bootstrap_first_admin('9888888841','Rate Check Administrator');
SELECT pg_temp.iwr_login('9888888841') AS admin_claims \gset
-- Numbers are free text here (the facility's numbering is not what this test is about).
SELECT warehouse_security.apply_document_numbering('grn', '{"scheme":"free"}', NULL) AS _ \gset
SELECT warehouse_security.apply_document_numbering('dispatch', '{"scheme":"free"}', NULL) AS _ \gset
INSERT INTO public.customers(name,mobile) VALUES ('Rate Customer X','9888888891') RETURNING id AS cust_x \gset
INSERT INTO public.customers(name,mobile) VALUES ('Rate Customer Y','9888888892') RETURNING id AS cust_y \gset
INSERT INTO public.items(name,packaging) VALUES ('Rate Item A','Bag') RETURNING id AS item_a \gset
INSERT INTO public.items(name,packaging) VALUES ('Rate Item B','Bag') RETURNING id AS item_b \gset
INSERT INTO public.items(name,packaging) VALUES ('Rate Item C','Bag') RETURNING id AS item_c \gset
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888888842', 'Rate Check Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888888843', 'Rate Check Customer', 'customer', true, 'approved');
SELECT pg_temp.iwr_login('9888888842') AS staff_claims \gset
SELECT pg_temp.iwr_login('9888888843') AS customer_claims \gset
-- A: a default rate from 2026-01-01 for weights 0 to 100. B: none. C: a rate of customer X only.
INSERT INTO public.item_storage_prices(item_id,customer_id,price_type,unit_price,unit_price_one_time,unit_price_monthly,weight_min,weight_max,labour_rate,tax_percent,effective_from) VALUES
 (:'item_a',NULL,'monthly',5,5,5,0,100,0,0,'2026-01-01'),
 (:'item_c',:'cust_x','monthly',5,5,5,0,100,0,0,'2026-01-01');
-- A GRN with its own rate for item B (monthly, weights 0 to 100), and a second GRN with none.
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('IWR1', :'cust_y') RETURNING id AS gr_own \gset
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('IWR2', :'cust_y') RETURNING id AS gr_none \gset
INSERT INTO public.grn_rates(gr_id,item_id,price_type,weight_min,weight_max,unit_price,labour_rate,tax_percent) VALUES (:'gr_own',:'item_b','monthly',0,100,5,0,0);
CREATE FUNCTION pg_temp.iwr_refused() RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN PERFORM public.get_items_without_rate(NULL, ARRAY[]::uuid[], '2026-05-01'); RETURN false;
EXCEPTION WHEN SQLSTATE '42501' THEN RETURN true; END $$;
CREATE FUNCTION pg_temp.iwr_names(a jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT CASE WHEN a->>'success'='true' THEN COALESCE((SELECT string_agg(e->>'item_name', ',' ORDER BY e->>'item_name') FROM jsonb_array_elements(a#>'{data,items}') e), '') ELSE 'ERR:' || a::text END $$;

SELECT set_config('request.jwt.claims', :'staff_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.iwr_assert(warehouse_security.active_role() = 'staff', 'actual staff role');
-- Customer X: A has the item default, B has none, C has X's own rate.
SELECT public.get_items_without_rate(:'cust_x'::uuid, ARRAY[:'item_a',:'item_b',:'item_c']::uuid[], '2026-05-01') AS r1 \gset
SELECT pg_temp.iwr_assert(:'r1'::jsonb->>'success'='true' AND pg_temp.iwr_names(:'r1'::jsonb) = 'Rate Item B'
  AND :'r1'::jsonb#>>'{data,item_ids}' = jsonb_build_array(:'item_b'::text)::text, 'customer X: only B has no rate: ' || :'r1');
-- Customer Y: C has no rate of its own and no default.
SELECT public.get_items_without_rate(:'cust_y'::uuid, ARRAY[:'item_a',:'item_b',:'item_c']::uuid[], '2026-05-01') AS r2 \gset
SELECT pg_temp.iwr_assert(pg_temp.iwr_names(:'r2'::jsonb) = 'Rate Item B,Rate Item C', 'customer Y: B and C: ' || :'r2');
-- The first rate covers the days before it (migration 129); a later band is not covered by a weight outside it.
SELECT public.get_items_without_rate(:'cust_y'::uuid, ARRAY[:'item_a']::uuid[], '2025-06-01') AS r3 \gset
SELECT pg_temp.iwr_assert(pg_temp.iwr_names(:'r3'::jsonb) = '' AND :'r3'::jsonb#>>'{data,item_ids}' = '[]', 'a day before the first rate is covered: ' || :'r3');
SELECT public.get_items_without_rate(:'cust_y'::uuid, ARRAY[:'item_a']::uuid[], '2026-05-01', ARRAY[150]) AS r4 \gset
SELECT pg_temp.iwr_assert(pg_temp.iwr_names(:'r4'::jsonb) = 'Rate Item A', 'a weight outside every band has no rate: ' || :'r4');
-- The monthly rate does not cover a one-time GRN? (the lookup is by price type): A has only a monthly row.
SELECT public.get_items_without_rate(:'cust_y'::uuid, ARRAY[:'item_a']::uuid[], '2026-05-01', NULL, 'ONE_TIME') AS r5 \gset
SELECT pg_temp.iwr_assert(pg_temp.iwr_names(:'r5'::jsonb) = 'Rate Item A', 'one-time mode is looked up as one-time: ' || :'r5');
-- Nothing asked, nothing answered.
SELECT public.get_items_without_rate(:'cust_y'::uuid, ARRAY[]::uuid[], '2026-05-01') AS r6 \gset
SELECT pg_temp.iwr_assert(:'r6'::jsonb->>'success'='true' AND :'r6'::jsonb#>>'{data,item_ids}' = '[]', 'empty list: ' || :'r6');
-- The size limits: 201 items; a two-dimensional list of 2 x 101; more weights than items.
SELECT public.get_items_without_rate(:'cust_y'::uuid, (SELECT array_agg(gen_random_uuid()) FROM generate_series(1,201)), '2026-05-01') AS r7 \gset
SELECT pg_temp.iwr_assert(:'r7'::jsonb->>'success'='false', '201 items are refused: ' || :'r7');
SELECT public.get_items_without_rate(:'cust_y'::uuid, (SELECT array_agg(ARRAY[gen_random_uuid(), gen_random_uuid()]) FROM generate_series(1,101)), '2026-05-01') AS r8 \gset
SELECT pg_temp.iwr_assert(:'r8'::jsonb->>'success'='false', 'a two-dimensional list is refused: ' || :'r8');
SELECT public.get_items_without_rate(:'cust_y'::uuid, ARRAY[:'item_a']::uuid[], '2026-05-01', ARRAY[10, 20]) AS r9 \gset
SELECT pg_temp.iwr_assert(:'r9'::jsonb->>'success'='false', 'more weights than items are refused: ' || :'r9');
-- p_on left out: today's India date (item A's rate began 2026-01-01).
SELECT public.get_items_without_rate(:'cust_y'::uuid, ARRAY[:'item_a']::uuid[]) AS r10 \gset
SELECT pg_temp.iwr_assert(:'r10'::jsonb->>'success'='true' AND pg_temp.iwr_names(:'r10'::jsonb) = '', 'p_on defaults to today: ' || :'r10');
-- A GRN edit: the GRN's own rate counts. B has no default rate.
SELECT public.get_items_without_rate(:'cust_y'::uuid, ARRAY[:'item_b']::uuid[], '2026-05-01', NULL, 'monthly', :'gr_own'::uuid) AS r11 \gset
SELECT pg_temp.iwr_assert(pg_temp.iwr_names(:'r11'::jsonb) = '', 'the GRN''s own rate covers B: ' || :'r11');
SELECT public.get_items_without_rate(:'cust_y'::uuid, ARRAY[:'item_b']::uuid[], '2026-05-01') AS r12 \gset
SELECT pg_temp.iwr_assert(pg_temp.iwr_names(:'r12'::jsonb) = 'Rate Item B', 'without p_grn_id B has no rate: ' || :'r12');
SELECT public.get_items_without_rate(:'cust_y'::uuid, ARRAY[:'item_b']::uuid[], '2026-05-01', NULL, 'monthly', :'gr_none'::uuid) AS r13 \gset
SELECT pg_temp.iwr_assert(pg_temp.iwr_names(:'r13'::jsonb) = 'Rate Item B', 'another GRN''s rates do not count: ' || :'r13');
SELECT public.get_items_without_rate(:'cust_y'::uuid, ARRAY[:'item_b']::uuid[], '2026-05-01', ARRAY[150], 'monthly', :'gr_own'::uuid) AS r14 \gset
SELECT pg_temp.iwr_assert(pg_temp.iwr_names(:'r14'::jsonb) = 'Rate Item B', 'a weight outside the GRN rate band is not covered: ' || :'r14');
SELECT public.get_items_without_rate(:'cust_y'::uuid, ARRAY[:'item_b']::uuid[], '2026-05-01', NULL, 'ONE_TIME', :'gr_own'::uuid) AS r15 \gset
SELECT pg_temp.iwr_assert(pg_temp.iwr_names(:'r15'::jsonb) = 'Rate Item B', 'the GRN rate is of the other type for a one-time GRN: ' || :'r15');
RESET ROLE;

SELECT set_config('request.jwt.claims', :'customer_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.iwr_assert((SELECT count(*) FROM (SELECT 1) z WHERE pg_temp.iwr_refused())=1, 'a customer is refused');
RESET ROLE;
ROLLBACK;

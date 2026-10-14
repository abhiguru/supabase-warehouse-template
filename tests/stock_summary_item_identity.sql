-- Migration 70: the customer stock report lists an item once, whatever names its lots were received
-- under (external review 2026-10-13, EDGE-RENDER-1).
--
-- Each receipt line keeps the item name it was saved with. One item, renamed twice with update_item:
--   lot 1  10 bags x 5 kg  received 1 Apr as "Okra Bhindi"
--   lot 2  20 bags x 5 kg  received 2 Apr as "Okra Zest"   (after the first rename)
--   lot 3   5 bags x 5 kg  received 3 Apr as "Okra Lady"   (after the second rename)
-- The report grouped rows by item id AND name while each row's grns list matched the item id only, so
-- it had three rows, each listing all three lots: 105 bags and 525 kg in the rows against 35 bags and
-- 175 kg in its own summary (the PDF flattens the rows' lots). Now: one row, labelled with the name of
-- the latest receipt ("Okra Lady", neither the first nor the last name in alphabetical order), three
-- lots, 35 bags, 175 kg, and the flattened lots add up to the summary. The same for out_of_stock_items
-- once every lot is dispatched.
--
-- Runs ONLY in migrations.sh's fresh, network-disabled database. All fixture rows roll back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.ssi_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'stock summary item identity: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.ssi_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.ssi_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- The rows' names, and the sum of a key over every lot of every row (what the PDF prints).
CREATE FUNCTION pg_temp.ssi_names(arr jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(string_agg(x->>'item_name', ',' ORDER BY ord), '') FROM jsonb_array_elements(arr) WITH ORDINALITY AS t(x, ord) $$;
CREATE FUNCTION pg_temp.ssi_lot_sum(arr jsonb, key text) RETURNS numeric LANGUAGE sql AS $$
  SELECT COALESCE(sum((g->>key)::numeric), 0) FROM jsonb_array_elements(arr) AS t(x), jsonb_array_elements(x->'grns') AS l(g) $$;

INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888887001', 'Stock Identity Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888887002', 'Stock Identity Reader', 'customer', true, 'approved');
SELECT id AS admin_profile FROM public.user_profiles WHERE mobile = '919888887001' \gset
SELECT pg_temp.ssi_login('9888887001') AS admin_claims \gset
SELECT pg_temp.ssi_login('9888887002') AS reader_claims \gset
INSERT INTO public.customers(name, mobile) VALUES ('Stock Identity Willow Cold', '9888887011') RETURNING id AS willow \gset
INSERT INTO public.items(name, packaging) VALUES ('Okra Bhindi', 'Bag') RETURNING id AS okra \gset
INSERT INTO public.users_customers_new(user_profile_id, customer_id, active)
 SELECT id, :'willow'::uuid, true FROM public.user_profiles WHERE mobile = '919888887002';

SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
CREATE FUNCTION pg_temp.ssi_receive(p_no text, p_day text, p_name text, p_bags integer, p_customer uuid, p_item uuid) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_temp.ssi_assert(public.save_grn(p_gr_no => p_no, p_date => (p_day || 'T12:00:00Z')::timestamptz, p_customer_id => p_customer,
    p_customer_name => 'Stock Identity Willow Cold', p_pricing_mode => 'MONTHLY', p_idempotency_key => 'stock-identity-' || p_no,
    p_items => jsonb_build_array(jsonb_build_object('item_id', p_item, 'item_name', p_name, 'packaging', 'Bag',
      'qty', p_bags, 'weight', 5)))->>'success' = 'true', 'fixture receipt ' || p_no);
END $$;
SELECT pg_temp.ssi_receive('W2S1', '2026-04-01', 'Okra Bhindi', 10, :'willow'::uuid, :'okra'::uuid);
SELECT pg_temp.ssi_assert(public.update_item(:'okra'::uuid, 'Okra Zest', 'Bag')->>'success' = 'true', 'first rename');
SELECT pg_temp.ssi_receive('W2S2', '2026-04-02', 'Okra Zest', 20, :'willow'::uuid, :'okra'::uuid);
SELECT pg_temp.ssi_assert(public.update_item(:'okra'::uuid, 'Okra Lady', 'Bag')->>'success' = 'true', 'second rename');
SELECT pg_temp.ssi_receive('W2S3', '2026-04-03', 'Okra Lady', 5, :'willow'::uuid, :'okra'::uuid);
RESET ROLE;
SELECT pg_temp.ssi_assert((SELECT string_agg(g.gr_no || ':' || t.item_name || ':' || t.stock, ' ' ORDER BY g.gr_no)
    FROM public.goodsreceived g JOIN public.goodsreceived_trl t ON t.gr_id = g.id WHERE g.customer_id = :'willow'::uuid)
  = 'W2S1:Okra Bhindi:10 W2S2:Okra Zest:20 W2S3:Okra Lady:5',
  'fixture: three lots of one item under three names');

SELECT set_config('request.jwt.claims', :'reader_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ssi_assert(warehouse_security.active_role() = 'customer', 'actual customer role');
SELECT public.get_customer_stock_summary(:'willow'::uuid)::text AS in_stock \gset
RESET ROLE;
SELECT pg_temp.ssi_assert((:'in_stock'::jsonb#>>'{summary,total_quantity}')::numeric = 35
  AND (:'in_stock'::jsonb#>>'{summary,total_weight_kg}')::numeric = 175
  AND (:'in_stock'::jsonb#>>'{summary,total_items}')::int = 1,
  'the summary: one item, 35 bags, 175 kg: ' || (:'in_stock'::jsonb->'summary')::text);
SELECT pg_temp.ssi_assert(jsonb_array_length(:'in_stock'::jsonb->'items') = 1
  AND pg_temp.ssi_names(:'in_stock'::jsonb->'items') = 'Okra Lady',
  'one row, named as the latest receipt: ' || pg_temp.ssi_names(:'in_stock'::jsonb->'items'));
SELECT pg_temp.ssi_assert((:'in_stock'::jsonb#>>'{items,0,total_stock}')::numeric = 35
  AND (:'in_stock'::jsonb#>>'{items,0,total_weight}')::numeric = 175
  AND (:'in_stock'::jsonb#>>'{items,0,grn_count}')::int = 3
  AND jsonb_array_length(:'in_stock'::jsonb#>'{items,0,grns}') = 3
  AND :'in_stock'::jsonb#>>'{items,0,item_id}' = :'okra',
  'the row holds the three lots, 35 bags, 175 kg: ' || left(:'in_stock'::jsonb#>>'{items,0}', 300));
SELECT pg_temp.ssi_assert(pg_temp.ssi_lot_sum(:'in_stock'::jsonb->'items', 'stock') = (:'in_stock'::jsonb#>>'{summary,total_quantity}')::numeric,
  'the lots of every row add up to the summary (35): ' || pg_temp.ssi_lot_sum(:'in_stock'::jsonb->'items', 'stock'));
-- The keys of a row are what they were.
SELECT pg_temp.ssi_assert((SELECT string_agg(k, ',' ORDER BY k COLLATE "C") FROM jsonb_object_keys(:'in_stock'::jsonb#>'{items,0}') AS t(k))
  = 'grn_count,grns,item_id,item_name,packaging,total_stock,total_weight',
  'the keys of a row are unchanged');

-- Every lot dispatched: the item moves to out_of_stock_items, once, with its three lots.
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ssi_assert(public.create_dispatch_with_stock_check(jsonb_build_object('disp_no', 'W2SD', 'disp_date', '2026-05-02',
    'customer_id', :'willow', 'customer_name', 'Stock Identity Willow Cold',
    'supervisor_id', :'admin_profile', 'supervisor_name', 'Stock Identity Administrator'),
  ARRAY(SELECT jsonb_build_object('gr_trl_id', t.id, 'disp_qty', t.stock) FROM public.goodsreceived g
        JOIN public.goodsreceived_trl t ON t.gr_id = g.id WHERE g.customer_id = :'willow'::uuid ORDER BY g.gr_no),
  0, 'stock-identity-dispatch')->>'success' = 'true', 'fixture dispatch of every lot');
RESET ROLE;
SELECT set_config('request.jwt.claims', :'reader_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.get_customer_stock_summary(:'willow'::uuid)::text AS emptied \gset
RESET ROLE;
SELECT pg_temp.ssi_assert(jsonb_array_length(:'emptied'::jsonb->'items') = 0
  AND jsonb_array_length(:'emptied'::jsonb->'out_of_stock_items') = 1
  AND pg_temp.ssi_names(:'emptied'::jsonb->'out_of_stock_items') = 'Okra Lady'
  AND (:'emptied'::jsonb#>>'{out_of_stock_items,0,grn_count}')::int = 3
  AND jsonb_array_length(:'emptied'::jsonb#>'{out_of_stock_items,0,grns}') = 3
  AND pg_temp.ssi_lot_sum(:'emptied'::jsonb->'out_of_stock_items', 'orig_qty') = 35,
  'out_of_stock_items: one row, Okra Lady, three lots of 35 bags in all: ' || pg_temp.ssi_names(:'emptied'::jsonb->'out_of_stock_items')
    || ' lots ' || pg_temp.ssi_lot_sum(:'emptied'::jsonb->'out_of_stock_items', 'orig_qty'));

-- A receipt with no date does not name the row (follow-up review 2026-10-13): ORDER BY date DESC puts
-- NULL first, so an older lot whose receipt lost its date would name the row. Another customer, one
-- item: "Gourd Ridge" received 5 Apr, renamed, "Gourd Sponge" received 6 Apr, then the older
-- receipt's date is cleared. The row is "Gourd Sponge"; before the fix it was "Gourd Ridge".
INSERT INTO public.customers(name, mobile) VALUES ('Stock Identity Birch Cold', '9888887012') RETURNING id AS birch \gset
INSERT INTO public.items(name, packaging) VALUES ('Gourd Ridge', 'Bag') RETURNING id AS gourd \gset
INSERT INTO public.users_customers_new(user_profile_id, customer_id, active)
 SELECT id, :'birch'::uuid, true FROM public.user_profiles WHERE mobile = '919888887002';
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ssi_receive('W2N1', '2026-04-05', 'Gourd Ridge', 4, :'birch'::uuid, :'gourd'::uuid);
SELECT pg_temp.ssi_assert(public.update_item(:'gourd'::uuid, 'Gourd Sponge', 'Bag')->>'success' = 'true', 'gourd rename');
SELECT pg_temp.ssi_receive('W2N2', '2026-04-06', 'Gourd Sponge', 6, :'birch'::uuid, :'gourd'::uuid);
RESET ROLE;
UPDATE public.goodsreceived SET date = NULL WHERE gr_no = 'W2N1' AND customer_id = :'birch'::uuid;
SELECT pg_temp.ssi_assert((SELECT string_agg(g.gr_no || ':' || t.item_name || ':' || COALESCE(g.date::text, 'no date'), ' ' ORDER BY g.gr_no)
    FROM public.goodsreceived g JOIN public.goodsreceived_trl t ON t.gr_id = g.id WHERE g.customer_id = :'birch'::uuid)
  LIKE 'W2N1:Gourd Ridge:no date W2N2:Gourd Sponge:2026-04-06%',
  'fixture: the older receipt has no date');
SELECT set_config('request.jwt.claims', :'reader_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.get_customer_stock_summary(:'birch'::uuid)::text AS undated \gset
RESET ROLE;
SELECT pg_temp.ssi_assert(jsonb_array_length(:'undated'::jsonb->'items') = 1
  AND pg_temp.ssi_names(:'undated'::jsonb->'items') = 'Gourd Sponge'
  AND (:'undated'::jsonb#>>'{items,0,grn_count}')::int = 2
  AND (:'undated'::jsonb#>>'{items,0,total_stock}')::numeric = 10,
  'a receipt with no date does not name the row (expected Gourd Sponge, two lots, 10 bags): '
    || pg_temp.ssi_names(:'undated'::jsonb->'items') || ' ' || left(:'undated'::jsonb#>>'{items,0}', 200));

-- SECURITY DEFINER, settings and grants as before.
SELECT pg_temp.ssi_assert(p.prosecdef AND p.proconfig = ARRAY['search_path=pg_catalog, public, extensions, utils, pg_temp']
    AND has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE'),
  'get_customer_stock_summary keeps SECURITY DEFINER, its search_path and grants')
FROM pg_proc p WHERE p.oid = 'public.get_customer_stock_summary(uuid)'::regprocedure;

ROLLBACK;
